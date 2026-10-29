using System.Diagnostics;
using System.Text;

namespace SpatialAudioLab.Core.Runtime;

public sealed class SpatialProviderController(RuntimePaths paths)
{
    public async Task PrepareAsync(BridgeMode mode, CancellationToken cancellationToken = default)
    {
        string script = Path.Combine(paths.ApplicationRoot, "Tools", "Prepare-SpatialAudio.ps1");
        if (!File.Exists(script)) script = Path.Combine(paths.ApplicationRoot, "tools", "Prepare-SpatialAudio.ps1");
        if (!File.Exists(script)) throw new FileNotFoundException("缺少空间音效配置工具，请解压完整安装包。", script);
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        ProcessStartInfo start = new(powershell)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        foreach (string value in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Mode", mode.ToString() }) start.ArgumentList.Add(value);
        using Process process = Process.Start(start) ?? throw new IOException("无法启动空间音效配置工具。");
        Task<string> output = process.StandardOutput.ReadToEndAsync(cancellationToken);
        Task<string> errors = process.StandardError.ReadToEndAsync(cancellationToken);
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(90));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            throw new TimeoutException("空间音效切换超时，请查看日志或重新连接虚拟音频端点。");
        }
        string text = await output + Environment.NewLine + await errors;
        paths.EnsureUserDirectories();
        string log = Path.Combine(paths.LogsRoot, $"spatial-provider-{mode}.log");
        await File.WriteAllTextAsync(log, text, Encoding.UTF8, cancellationToken);
        if (process.ExitCode != 0) throw new InvalidOperationException($"空间音效准备失败（{mode}）：\n{text.Trim()}\n日志：{log}");
    }
}
