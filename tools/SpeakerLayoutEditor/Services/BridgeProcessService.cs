using System.Diagnostics;
using System.IO;
using System.Text;
using SpatialAudioLab.Core.Runtime;

namespace SpeakerLayoutEditor.Services;

internal interface ISpatialProviderService
{
    Task ActivateAsync(BridgeMode mode);
}

internal sealed class WindowsSpatialProviderService(RuntimePaths paths) : ISpatialProviderService
{
    private readonly SpatialProviderController controller = new(paths);
    public Task ActivateAsync(BridgeMode mode) => controller.PrepareAsync(mode);
}

internal sealed class BridgeProcessService
{
    public async Task StartAsync(BridgeCommand command)
    {
        if (!File.Exists(command.Executable))
        {
            throw new FileNotFoundException(
                "找不到 SpatialAudioLab 音频引擎。",
                command.Executable);
        }

        if (!File.Exists(command.Arguments[2]))
        {
            throw new FileNotFoundException(
                "找不到当前配置。",
                command.Arguments[2]);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(command.LogPath)!);
        foreach (string path in new[] { command.LogPath, command.ErrorLogPath, command.PidPath })
        {
            File.Delete(path);
        }

        ProcessStartInfo start = new(command.Executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (string argument in command.Arguments)
        {
            start.ArgumentList.Add(argument);
        }

        Process process = Process.Start(start) ??
            throw new InvalidOperationException("无法启动 SpatialAudioLab 音频引擎。");
        File.WriteAllText(command.PidPath, $"{process.Id}\n", Encoding.ASCII);
        Task monitorTask = MonitorAsync(process, command);

        await Task.Delay(750);
        bool hasExited;
        try
        {
            process.Refresh();
            hasExited = process.HasExited;
        }
        catch (InvalidOperationException)
        {
            hasExited = true;
        }

        if (hasExited)
        {
            await monitorTask;
            string error = File.Exists(command.ErrorLogPath)
                ? await File.ReadAllTextAsync(command.ErrorLogPath)
                : string.Empty;
            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(error)
                    ? "音频引擎在启动时退出。"
                    : error.Trim());
        }
    }

    public async Task StopAsync(string pidPath)
    {
        if (!File.Exists(pidPath))
        {
            return;
        }

        string value = await File.ReadAllTextAsync(pidPath);
        if (!int.TryParse(value.Trim(), out int processId))
        {
            File.Delete(pidPath);
            return;
        }

        try
        {
            using Process process = Process.GetProcessById(processId);
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync();
            }
        }
        catch (ArgumentException)
        {
        }
        finally
        {
            File.Delete(pidPath);
        }
    }

    private static async Task MonitorAsync(Process process, BridgeCommand command)
    {
        int processId = process.Id;
        try
        {
            await using FileStream output = new(
                command.LogPath,
                FileMode.Create,
                FileAccess.Write,
                FileShare.Read);
            await using FileStream error = new(
                command.ErrorLogPath,
                FileMode.Create,
                FileAccess.Write,
                FileShare.Read);
            Task outputTask = process.StandardOutput.BaseStream.CopyToAsync(output);
            Task errorTask = process.StandardError.BaseStream.CopyToAsync(error);
            await process.WaitForExitAsync();
            await Task.WhenAll(outputTask, errorTask);
        }
        finally
        {
            try
            {
                if (File.Exists(command.PidPath) &&
                    int.TryParse(
                        (await File.ReadAllTextAsync(command.PidPath)).Trim(),
                        out int pid) &&
                    pid == processId)
                {
                    File.Delete(command.PidPath);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
            process.Dispose();
        }
    }
}
