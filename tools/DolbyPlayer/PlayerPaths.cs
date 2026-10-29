using System.Text.Json;
using SpatialAudioLab.Core.Profiles;
using SpatialAudioLab.Core.Runtime;

namespace DolbyPlayer;

internal sealed class PlayerPaths
{
    private const string DefaultVirtualSinkName = "SpatialAudioLab Virtual Sink";

    public PlayerPaths() : this(RuntimePaths.ResolveForCurrentProcess())
    {
    }

    public PlayerPaths(RuntimePaths runtime)
    {
        Runtime = runtime ?? throw new ArgumentNullException(nameof(runtime));
        Runtime.EnsureUserDirectories();
        Ffprobe = Runtime.FfprobeExecutable;
        Mpv = Runtime.MpvExecutable;
        TrueHdStream = Runtime.TrueHdExecutable;
        CacheRoot = Path.Combine(Runtime.CacheRoot, "Cinema");
        ProductSettingsPath = Path.Combine(Runtime.DataRoot, "product-settings.json");
        VirtualSinkFilter = LoadVirtualSinkFilter(ProductSettingsPath);
    }

    public RuntimePaths Runtime { get; }

    public string Ffprobe { get; }

    public string TrueHdStream { get; }

    public string Mpv { get; }

    public string CacheRoot { get; }

    public string ProductSettingsPath { get; }

    public string VirtualSinkFilter { get; }

    public ProfileDocument RequireActiveProfile()
    {
        return DefaultProfileService.LoadForStartup(Runtime);
    }

    public string ResolveVirtualSinkFilter(string? diagnosticOverride)
    {
        return string.IsNullOrWhiteSpace(diagnosticOverride)
            ? VirtualSinkFilter
            : diagnosticOverride;
    }

    public void Validate(bool requireMpv)
    {
        if (!File.Exists(Ffprobe))
        {
            throw new FileNotFoundException("缺少包内 ffprobe 程序。", Ffprobe);
        }

        if (!File.Exists(TrueHdStream))
        {
            throw new FileNotFoundException(
                "缺少包内 TrueHD 串流解码器。",
                TrueHdStream);
        }

        if (requireMpv && !File.Exists(Mpv))
        {
            throw new FileNotFoundException("缺少包内 mpv 播放器。", Mpv);
        }

        Directory.CreateDirectory(CacheRoot);
    }

    private static string LoadVirtualSinkFilter(string path)
    {
        if (!File.Exists(path))
        {
            return DefaultVirtualSinkName;
        }

        using FileStream stream = File.OpenRead(path);
        using JsonDocument document = JsonDocument.Parse(stream);
        JsonElement root = document.RootElement;
        if (root.TryGetProperty("virtualSinkEndpointId", out JsonElement endpointId) &&
            !string.IsNullOrWhiteSpace(endpointId.GetString()))
        {
            return endpointId.GetString()!;
        }

        if (root.TryGetProperty("virtualSinkFriendlyName", out JsonElement friendlyName) &&
            !string.IsNullOrWhiteSpace(friendlyName.GetString()))
        {
            return friendlyName.GetString()!;
        }

        return DefaultVirtualSinkName;
    }
}
