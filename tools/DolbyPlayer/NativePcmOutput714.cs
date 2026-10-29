using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using SpatialAudioLab.Core.Profiles;

namespace DolbyPlayer;

internal sealed class NativePcmOutput714 : IPlayerAudioOutput
{
    readonly PlayerPaths paths;
    readonly Pcm714Buffer queue;
    readonly float gain;
    readonly string profilePath;
    Process? engine;
    CancellationTokenSource? lifetime;
    Task? feeder;
    Task? monitor;
    volatile bool paused;
    volatile bool drained;
    Exception? failure;
    long played;
    long written;
    int targetFrames = 4800;
    double mediaBase;

    public NativePcmOutput714(PlayerPaths paths, ProfileDocument profile, Pcm714Buffer queue, float gain)
    {
        this.paths = paths;
        this.queue = queue;
        this.gain = gain;
        profilePath = Path.Combine(paths.Runtime.CacheRoot, $"cinema-output-{Environment.ProcessId}.ini");
        ProfileIniSerializer.Save(profilePath, profile);
        OutputName = string.Join(" + ", profile.Outputs.Select(output =>
            output.Backend == OutputBackend.Asio ? "ASIO " + (output.AsioDriverName ?? output.Endpoint.FriendlyName) : output.Endpoint.FriendlyName));
    }

    public string OutputName { get; }
    public double ClockSkewMilliseconds => double.NaN;
    public bool IsDrained => drained;
    public double MediaPositionSeconds
    {
        get
        {
            if (failure is { } error) throw new InvalidOperationException("原生音频输出失败：" + error.Message, error);
            return mediaBase + Interlocked.Read(ref played) / (double)Pcm714Buffer.SampleRate;
        }
    }

    public void ResetClock(double position)
    {
        Stop();
        mediaBase = position;
        Interlocked.Exchange(ref played, 0);
        Interlocked.Exchange(ref written, 0);
        failure = null;
        drained = false;
    }

    public void Play()
    {
        if (engine is not null) { paused = false; return; }
        if (!File.Exists(paths.Runtime.EngineExecutable)) throw new FileNotFoundException("缺少原生 ASIO 输出引擎", paths.Runtime.EngineExecutable);
        ProcessStartInfo start = new(paths.Runtime.EngineExecutable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (string argument in new[] { "render-pcm-stdin", profilePath, gain.ToString(CultureInfo.InvariantCulture) })
            start.ArgumentList.Add(argument);
        engine = Process.Start(start) ?? throw new InvalidOperationException("无法启动原生音频引擎");
        lifetime = new CancellationTokenSource();
        paused = false;
        drained = false;
        TaskCompletionSource<bool> ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
        monitor = MonitorAsync(engine, ready, lifetime.Token);
        feeder = FeedAsync(engine, lifetime.Token);
        try
        {
            ready.Task.WaitAsync(TimeSpan.FromSeconds(15)).GetAwaiter().GetResult();
        }
        catch (TimeoutException) { Stop(); throw new TimeoutException("音频设备启动超过 15 秒，请确认 Dante 已启动且未被其他程序占用。"); }
        catch { Stop(); throw; }
    }

    async Task MonitorAsync(Process child, TaskCompletionSource<bool> ready, CancellationToken cancellationToken)
    {
        Task<string> errors = child.StandardError.ReadToEndAsync(cancellationToken);
        try
        {
            while (await child.StandardOutput.ReadLineAsync(cancellationToken) is { } line)
            {
                if (!line.StartsWith('{')) continue;
                using JsonDocument message = JsonDocument.Parse(line);
                if (message.RootElement.TryGetProperty("prebufferFrames", out JsonElement prebuffer))
                {
                    Volatile.Write(ref targetFrames, Math.Max(4800, checked(prebuffer.GetInt32() + 960)));
                    ready.TrySetResult(true);
                }
                if (message.RootElement.TryGetProperty("playedFrames", out JsonElement frames))
                    Interlocked.Exchange(ref played, frames.GetInt64());
                if (message.RootElement.TryGetProperty("event", out JsonElement kind) && kind.GetString() == "done")
                    drained = true;
            }
            await child.WaitForExitAsync(cancellationToken);
            string detail = await errors;
            if (child.ExitCode != 0) { failure = new IOException(detail.Trim()); ready.TrySetException(failure); }
            else { drained = true; ready.TrySetException(new IOException("音频引擎在完成初始化前退出。")); }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception error) when (!cancellationToken.IsCancellationRequested) { failure = error; ready.TrySetException(error); }
    }

    async Task FeedAsync(Process child, CancellationToken cancellationToken)
    {
        const int chunkFrames = 480;
        float[] samples = new float[chunkFrames * Pcm714Buffer.Channels];
        byte[] bytes = new byte[samples.Length * sizeof(float)];
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                if (paused || Interlocked.Read(ref written) - Interlocked.Read(ref played) >= Volatile.Read(ref targetFrames))
                { await Task.Delay(5, cancellationToken); continue; }
                int frames = (int)Math.Min(chunkFrames, queue.BufferedFrames);
                if (frames == 0)
                {
                    if (queue.IsCompleted) break;
                    await Task.Delay(5, cancellationToken);
                    continue;
                }
                int count = frames * Pcm714Buffer.Channels;
                int copied = queue.ReadProjected(0, 0, Pcm714Buffer.Channels, samples.AsSpan(0, count), 1);
                for (int index = 0; index < copied * Pcm714Buffer.Channels; ++index)
                {
                    float sample = float.IsFinite(samples[index]) ? samples[index] : 0;
                    BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(index * sizeof(float), sizeof(float)), BitConverter.SingleToInt32Bits(sample));
                }
                await child.StandardInput.BaseStream.WriteAsync(bytes.AsMemory(0, copied * Pcm714Buffer.Channels * sizeof(float)), cancellationToken);
                Interlocked.Add(ref written, copied);
            }
            child.StandardInput.Close();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception error) when (!cancellationToken.IsCancellationRequested) { failure = error; }
    }

    public void Pause() => paused = true;

    public void Stop()
    {
        paused = true;
        lifetime?.Cancel();
        if (engine is not null)
        {
            if (!engine.HasExited) engine.Kill(entireProcessTree: true);
            engine.WaitForExit();
            try { Task.WaitAll(new[] { feeder, monitor }.OfType<Task>().ToArray(), 3000); } catch (AggregateException) { }
            engine.Dispose();
            engine = null;
        }
        lifetime?.Dispose();
        lifetime = null;
    }

    public void Dispose()
    {
        Stop();
        File.Delete(profilePath);
    }
}
