using Microsoft.Win32;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using SpatialAudioLab.Core.Audio;
using SpatialAudioLab.Core.Profiles;
using SpatialAudioLab.Core.Runtime;

namespace SpatialAudioLab.Cinema;

public partial class MainWindow : Window
{
    readonly RuntimePaths paths;
    Process? playback;
    string? media;
    bool closing;
    readonly SemaphoreSlim logGate = new(1, 1);
    string Engine => Path.Combine(paths.ApplicationRoot, "SpatialAudioLab.Cinema.Engine.exe");
    public MainWindow(RuntimePaths paths)
    {
        this.paths = paths;
        InitializeComponent();
        ProfileDocument profile = DefaultProfileService.LoadForStartup(paths);
        ProfileText.Text = $"默认配置：{DefaultProfileService.PathFor(paths)}\n{profile.Name}";
        Append("请选择影片。Dante Virtual Soundcard 应已在 ASIO 模式启动，采样率设为 48 kHz，输出不少于 12 声道。");
        Closed += (_, _) => { closing = true; StopPlayback(); };
    }

    public void SetMedia(string path)
    {
        media = Path.GetFullPath(path);
        MediaPathText.Text = media;
        PlayButton.IsEnabled = true;
    }
    public void SetOption(string option, double value) {
        if (option == "--gain") GainSlider.Value = Math.Clamp(value, 0, 1);
        if (option == "--av-delay-ms") AvDelayText.Text = Math.Clamp(value, -5000, 5000).ToString(CultureInfo.InvariantCulture);
    }
    void OpenClick(object sender, RoutedEventArgs e)
    {
        OpenFileDialog dialog = new() { Title = "打开空间音频影片", Filter = "Matroska 影片 (*.mkv;*.mka)|*.mkv;*.mka|所有文件 (*.*)|*.*" };
        if (dialog.ShowDialog(this) == true) SetMedia(dialog.FileName);
    }
    void Append(string line)
    {
        if (LogText.Text.Length > 40_000) LogText.Text = LogText.Text[^20_000..];
        LogText.AppendText(line + Environment.NewLine);
        LogText.ScrollToEnd();
    }
    async Task PumpAsync(StreamReader reader, StreamWriter log)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            await logGate.WaitAsync();
            try { await log.WriteLineAsync(line); } finally { logGate.Release(); }
            if (!closing) Append(line);
        }
    }
    async void PlayClick(object sender, RoutedEventArgs e)
    {
        if (media is null || playback is not null) return;
        try
        {
            // DVS's 64-bit ASIO driver must have one owner; stop this application's own live bridges first.
            foreach (string pidFile in Directory.EnumerateFiles(paths.LogsRoot, "bridge-*.pid"))
            {
                if (!int.TryParse(File.ReadAllText(pidFile).Trim(), out int pid)) continue;
                try
                {
                    using Process live = Process.GetProcessById(pid);
                    if (!live.HasExited && string.Equals(live.MainModule?.FileName, paths.EngineExecutable, StringComparison.OrdinalIgnoreCase))
                    { live.Kill(entireProcessTree: true); await live.WaitForExitAsync(); }
                }
                catch (ArgumentException) { }
            }
            DefaultProfileService.LoadForStartup(paths);
            ProcessStartInfo start = new(Engine)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            start.ArgumentList.Add("play"); start.ArgumentList.Add(media);
            if (!double.TryParse(AvDelayText.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out double delay) || !double.IsFinite(delay) || Math.Abs(delay) > 5000)
                throw new InvalidDataException("影音延迟必须为 -5000 到 5000 毫秒。");
            start.ArgumentList.Add("--gain"); start.ArgumentList.Add(GainSlider.Value.ToString(CultureInfo.InvariantCulture));
            start.ArgumentList.Add("--av-delay-ms"); start.ArgumentList.Add(delay.ToString(CultureInfo.InvariantCulture));
            Process child = Process.Start(start) ?? throw new IOException("无法启动播放引擎。");
            playback = child;
            PlayButton.IsEnabled = false; StopButton.IsEnabled = true;
            StatusText.Text = "正在解码与播放；视频窗口中可暂停、定位和选择字幕。";
            string logPath = Path.Combine(paths.LogsRoot, "cinema-playback.log");
            await using FileStream file = new(logPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite);
            await using StreamWriter log = new(file, Encoding.UTF8) { AutoFlush = true };
            Task stdout = PumpAsync(child.StandardOutput, log);
            Task stderr = PumpAsync(child.StandardError, log);
            await child.WaitForExitAsync();
            await Task.WhenAll(stdout, stderr);
            if (!closing) StatusText.Text = child.ExitCode == 0 ? "播放已结束。" : $"播放未完成（退出码 {child.ExitCode}）。请查看上方原因与日志：{logPath}";
            child.Dispose();
        }
        catch (Exception error)
        {
            if (!closing) { Append(error.ToString()); StatusText.Text = "播放失败：" + error.Message; }
        }
        finally
        {
            playback = null;
            if (!closing) { PlayButton.IsEnabled = media is not null; StopButton.IsEnabled = false; }
        }
    }
    void StopPlayback()
    {
        try { if (playback is { HasExited: false }) playback.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
    }
    void StopClick(object sender, RoutedEventArgs e) => StopPlayback();
    void StudioClick(object sender, RoutedEventArgs e) => Process.Start(new ProcessStartInfo(Path.Combine(paths.ApplicationRoot, "SpatialAudioLab.Studio.exe")) { UseShellExecute = true });
    void LogsClick(object sender, RoutedEventArgs e) => Process.Start(new ProcessStartInfo(paths.LogsRoot) { UseShellExecute = true });
    async void CheckDanteClick(object sender, RoutedEventArgs e)
    {
        try
        {
            ProcessStartInfo start = new(paths.EngineExecutable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            start.ArgumentList.Add("list-asio-json");
            using Process query = Process.Start(start) ?? throw new IOException("无法查询 ASIO 驱动。");
            Task<string> output = query.StandardOutput.ReadToEndAsync(), errors = query.StandardError.ReadToEndAsync();
            await query.WaitForExitAsync();
            string text = await output;
            if (query.ExitCode != 0) throw new IOException(await errors);
            var names = text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => JsonSerializer.Deserialize<AsioDriverDescriptor>(line, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!).Where(driver => driver.Name.Contains("Dante Virtual Soundcard", StringComparison.OrdinalIgnoreCase)).ToList();
            Append(names.Count == 0 ? "未找到 Dante Virtual Soundcard。请启动 DVS，选择 ASIO 模式及 48 kHz，再重试。" : "已检测到：" + string.Join("、", names.Select(driver => driver.Name)));
        }
        catch (Exception error) { Append("Dante 检查失败：" + error.Message); }
    }
}
