using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using SpatialAudioLab.Core.Runtime;

namespace SpatialAudioLab.Cinema;

public partial class App : Application
{
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] static extern uint GetConsoleProcessList(uint[] processes, uint count);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.GetCultureInfo("zh-CN");
        CultureInfo.DefaultThreadCurrentUICulture = CultureInfo.GetCultureInfo("zh-CN");
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        RuntimePaths paths = RuntimePaths.ResolveForCurrentProcess();
        paths.EnsureUserDirectories();
        try
        {
            string[] commands = ["inspect", "decode-test", "audio-test", "video-test", "play", "self-test-audio", "--help", "-h", "--version"];
            if (e.Args.Length > 0 && commands.Contains(e.Args[0], StringComparer.OrdinalIgnoreCase))
            {
                ProcessStartInfo start = new(Path.Combine(paths.ApplicationRoot, "SpatialAudioLab.Cinema.Engine.exe"))
                { UseShellExecute = false, CreateNoWindow = true };
                foreach (string argument in e.Args) start.ArgumentList.Add(argument);
                using Process child = Process.Start(start) ?? throw new IOException("无法启动影院播放引擎。");
                await child.WaitForExitAsync();
                Shutdown(child.ExitCode);
                return;
            }
            if (GetConsoleProcessList(new uint[2], 2) == 1) ShowWindow(GetConsoleWindow(), 0);
            ShutdownMode = ShutdownMode.OnMainWindowClose;
            MainWindow window = new(paths);
            MainWindow = window;
            if (e.Args.Length > 0 && File.Exists(e.Args[0])) window.SetMedia(e.Args[0]);
            for (int index = 1; index + 1 < e.Args.Length; index += 2) {
                if (!double.TryParse(e.Args[index + 1], NumberStyles.Float, CultureInfo.InvariantCulture, out double value)) continue;
                window.SetOption(e.Args[index], value);
            }
            window.Show();
        }
        catch (Exception error)
        {
            string log = Path.Combine(paths.LogsRoot, "cinema-startup.log");
            File.WriteAllText(log, error.ToString());
            MessageBox.Show($"影院启动失败：{error.Message}\n\n详细日志：{log}", "影院启动诊断", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
