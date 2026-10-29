using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using SpatialAudioLab.Core.Audio;
using SpatialAudioLab.Core.Runtime;

namespace SpeakerLayoutEditor.Services;

internal sealed class EndpointQuery(RuntimePaths paths)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public async Task<IReadOnlyList<AudioEndpointDescriptor>> QueryAsync()
    {
        string output = await RunAsync("list-endpoints-json");
        List<AudioEndpointDescriptor> endpoints = [];
        foreach (string line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            AudioEndpointDescriptor? endpoint = JsonSerializer.Deserialize<AudioEndpointDescriptor>(
                line.TrimEnd('\r'),
                JsonOptions);
            if (endpoint is null || string.IsNullOrWhiteSpace(endpoint.Id))
            {
                throw new InvalidDataException("音频引擎返回了无效的设备信息。");
            }

            endpoints.Add(endpoint);
        }

        return endpoints;
    }

    public async Task<IReadOnlyList<AsioDriverDescriptor>> QueryAsioAsync()
    {
        string output = await RunAsync("list-asio-json");
        return output.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => JsonSerializer.Deserialize<AsioDriverDescriptor>(line, JsonOptions)
                ?? throw new InvalidDataException("ASIO 驱动信息无效。"))
            .ToList();
    }

    public async Task<AsioDeviceDescriptor> InspectAsioAsync(string clsid) =>
        JsonSerializer.Deserialize<AsioDeviceDescriptor>(
            await RunAsync("asio-device-json", clsid), JsonOptions)
        ?? throw new InvalidDataException("ASIO 设备信息无效。");

    private async Task<string> RunAsync(params string[] arguments)
    {
        if (!File.Exists(paths.EngineExecutable))
        {
            throw new FileNotFoundException(
                "找不到 SpatialAudioLab 音频引擎。",
                paths.EngineExecutable);
        }

        ProcessStartInfo start = new(paths.EngineExecutable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (string argument in arguments) start.ArgumentList.Add(argument);
        using Process process = Process.Start(start) ??
            throw new InvalidOperationException("无法查询音频设备。");
        Task<string> outputTask = process.StandardOutput.ReadToEndAsync();
        Task<string> errorTask = process.StandardError.ReadToEndAsync();
        using CancellationTokenSource timeout = new(TimeSpan.FromSeconds(15));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw new TimeoutException("音频设备查询超过 15 秒，请检查驱动与设备连接。");
        }
        string output = await outputTask;
        string error = await errorTask;
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(error)
                    ? "Fallo la consulta de endpoints."
                    : error.Trim());
        }

        return output;
    }
}
