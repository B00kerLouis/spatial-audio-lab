using System.Diagnostics;
using SpatialAudioLab.Core.Profiles;

namespace DolbyPlayer;

internal static class PlayerCoordinator {
    const double PrebufferSeconds = 2.5;

    public static async Task PlayAsync(PlayerPaths paths, string input, MediaInfo media,
                                       AudioStreamInfo stream, ProfileDocument activeProfile,
                                       PlayerOptions options,
                                       CancellationToken cancellationToken) {
        Pcm714Buffer queue = new();
        await using IAtmosDecodePipeline decoder = stream.Codec == AtmosCodec.Eac3Joc
            ? new Eac3JocDecodePipeline(input, stream, media.DurationSeconds, queue)
            : new TrueHdStreamDecodePipeline(paths, input, stream, media.DurationSeconds, queue);
        using IPlayerAudioOutput audio = PlayerAudioOutput.Create(paths, activeProfile, queue, options.Gain, options.SinkFilter);
        await using MpvController mpv = new(paths.Mpv, input, options.StartSeconds);

        Console.WriteLine($"音轨： 0:{stream.Index} {stream.Codec}, {stream.Channels}ch/{stream.SampleRate} Hz " +
                          $"{stream.Language} {stream.Title}".TrimEnd());
        Console.WriteLine($"配置： {activeProfile.Name} ({activeProfile.LayoutId})");
        Console.WriteLine($"音频输出： {audio.OutputName}");
        Console.WriteLine("正在准备空间音频预缓冲…");

        await mpv.StartAsync(cancellationToken);
        await decoder.RestartAsync(options.StartSeconds, cancellationToken);
        await decoder.WaitForPrebufferAsync(PrebufferSeconds, cancellationToken);
        if (decoder.Failure != null) throw new InvalidOperationException("初始空间音频解码失败。", decoder.Failure);

        audio.ResetClock(options.StartSeconds);
        audio.Play();
        await mpv.SetPausedAsync(false, cancellationToken);
        Task? controlTest = options.ControlTest
            ? RunControlTestAsync(mpv, options.StartSeconds + 7, cancellationToken)
            : null;
        bool lastPaused = false;
        bool wasSeeking = false;
        double lastMpvPosition = options.StartSeconds;
        Stopwatch pollClock = Stopwatch.StartNew();
        TimeSpan lastPoll = pollClock.Elapsed;
        DateTime lastCorrection = DateTime.MinValue;
        DateTime internalSeekUntil = DateTime.MinValue;
        double speed = 1;
        double stopPosition = options.StopAfterSeconds.HasValue
            ? Math.Min(media.DurationSeconds, options.StartSeconds + options.StopAfterSeconds.Value)
            : media.DurationSeconds;
        double maximumDrift = 0;
        int softCorrections = 0;
        int hardCorrections = 0;
        Console.WriteLine("正在播放。可在视频窗口中暂停、定位、全屏及选择字幕。");

        while (!mpv.HasExited && !cancellationToken.IsCancellationRequested) {
            await Task.Delay(100, cancellationToken);
            if (decoder.Failure != null) throw new InvalidOperationException("空间音频解码器失败。", decoder.Failure);

            bool paused;
            bool seeking;
            double? positionValue;
            try {
                paused = await mpv.GetPausedAsync(cancellationToken);
                seeking = await mpv.GetSeekingAsync(cancellationToken);
                positionValue = await mpv.GetTimeAsync(cancellationToken);
            } catch (Exception exception) when ((exception is IOException || exception is EndOfStreamException) &&
                                                mpv.HasExited) {
                break;
            }
            if (!positionValue.HasValue) continue;
            double position = positionValue.Value;

            if (paused != lastPaused) {
                if (paused) audio.Pause();
                else audio.Play();
                lastPaused = paused;
            }

            TimeSpan now = pollClock.Elapsed;
            double elapsed = (now - lastPoll).TotalSeconds;
            double expectedAdvance = paused || wasSeeking ? 0 : elapsed * speed;
            bool internalSeek = DateTime.UtcNow < internalSeekUntil;
            bool userJump = !internalSeek && !seeking &&
                Math.Abs((position - lastMpvPosition) - expectedAdvance) > .75;
            if (userJump) {
                bool resume = !paused;
                Console.WriteLine($"Seek: {position:F3} s");
                await mpv.SetPausedAsync(true, cancellationToken);
                audio.Stop();
                await decoder.RestartAsync(position, cancellationToken);
                await decoder.WaitForPrebufferAsync(PrebufferSeconds, cancellationToken);
                audio.ResetClock(position);
                speed = 1;
                await mpv.SetSpeedAsync(speed, cancellationToken);
                if (resume) {
                    audio.Play();
                    await mpv.SetPausedAsync(false, cancellationToken);
                    paused = false;
                }
                lastMpvPosition = position;
                lastPoll = pollClock.Elapsed;
                wasSeeking = seeking;
                continue;
            }

            if (!paused && !seeking) {
                double audioPosition = audio.MediaPositionSeconds;
                double videoTarget = audioPosition + options.AvDelayMilliseconds / 1000;
                double drift = position - videoTarget;
                maximumDrift = Math.Max(maximumDrift, Math.Abs(drift));
                if (Math.Abs(drift) > .25 && queue.BufferedFrames > Pcm714Buffer.SampleRate / 2 &&
                    DateTime.UtcNow - lastCorrection > TimeSpan.FromSeconds(1)) {
                    await mpv.SeekAsync(videoTarget, cancellationToken);
                    lastCorrection = DateTime.UtcNow;
                    internalSeekUntil = DateTime.UtcNow + TimeSpan.FromSeconds(1);
                    position = videoTarget;
                    ++hardCorrections;
                } else if (Math.Abs(drift) <= .25) {
                    double wantedSpeed = Math.Clamp(1 - drift * .05, .995, 1.005);
                    if (Math.Abs(drift) < .005) wantedSpeed = 1;
                    if (Math.Abs(wantedSpeed - speed) >= .00025) {
                        speed = wantedSpeed;
                        await mpv.SetSpeedAsync(speed, cancellationToken);
                        ++softCorrections;
                    }
                }
            }

            if (audio.MediaPositionSeconds >= stopPosition - .02 && (!decoder.IsCompleted || audio.IsDrained)) break;
            if (decoder.IsCompleted && queue.BufferedFrames == 0 &&
                (audio is NativePcmOutput714 ? audio.IsDrained : queue.MediaPositionSeconds - audio.MediaPositionSeconds < .05)) break;
            if (!seeking) lastMpvPosition = position;
            lastPoll = now;
            wasSeeking = seeking;
        }

        double finalPosition = audio.MediaPositionSeconds;
        double finalSkew = audio.ClockSkewMilliseconds;
        audio.Stop();
        if (controlTest != null) await controlTest;
        Console.WriteLine($"Stopped at {finalPosition:F3} s; " +
                          $"starvation={queue.StarvationFrames} frames; " +
                          $"clock delta={finalSkew:F3} ms; max A/V drift={maximumDrift * 1000:F1} ms; " +
                          $"corrections={softCorrections} soft/{hardCorrections} hard.");
    }

    static async Task RunControlTestAsync(MpvController mpv, double seekTarget,
                                          CancellationToken cancellationToken) {
        await Task.Delay(2000, cancellationToken);
        Console.WriteLine("Control test: pause");
        await mpv.SetPausedAsync(true, cancellationToken);
        await Task.Delay(750, cancellationToken);
        Console.WriteLine($"Control test: seek {seekTarget:F3} s");
        await mpv.SeekAsync(seekTarget, cancellationToken);
        await Task.Delay(3000, cancellationToken);
        Console.WriteLine("Control test: resume");
        await mpv.SetPausedAsync(false, cancellationToken);
    }
}

internal sealed record PlayerOptions(int? AudioStreamIndex, double StartSeconds, float Gain,
                                     string? SinkFilter,
                                     double AvDelayMilliseconds, double? StopAfterSeconds,
                                     bool ControlTest);
