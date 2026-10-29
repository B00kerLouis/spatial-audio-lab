using System.Windows;

namespace SpeakerLayoutEditor;

public partial class App : Application {
    protected override void OnStartup(StartupEventArgs e) {
        System.Globalization.CultureInfo.DefaultThreadCurrentCulture = System.Globalization.CultureInfo.GetCultureInfo("zh-CN");
        System.Globalization.CultureInfo.DefaultThreadCurrentUICulture = System.Globalization.CultureInfo.GetCultureInfo("zh-CN");
        DispatcherUnhandledException += (_, error) => {
            try {
                var paths = SpatialAudioLab.Core.Runtime.RuntimePaths.ResolveForCurrentProcess();
                paths.EnsureUserDirectories();
                System.IO.File.WriteAllText(System.IO.Path.Combine(paths.LogsRoot, "studio-error.log"), error.Exception.ToString());
            } catch { }
            MessageBox.Show(error.Exception.Message, "工作室诊断", MessageBoxButton.OK, MessageBoxImage.Error);
            error.Handled = true;
        };
        base.OnStartup(e);
    }
}
