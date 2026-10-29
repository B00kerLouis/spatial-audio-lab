using SpatialAudioLab.Core.Runtime;

namespace SpatialAudioLab.Core.Profiles;

public static class DefaultProfileService
{
    public const string FileName = "default.ini";
    public static readonly Guid DefaultId = new("74147d7a-7140-4714-8140-daa7e0000001");
    public const string DanteDriverName = "Dante Virtual Soundcard";
    public static readonly string[] ChannelOrder =
        ["FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR", "TFL", "TFR", "TBL", "TBR"];

    public static string PathFor(RuntimePaths paths) => Path.Combine(paths.ApplicationRoot, FileName);

    public static ProfileDocument CreateDante714() => new()
    {
        Id = DefaultId, Name = "7.1.4 Dante ASIO", LayoutId = "7.1.4", MasterOutput = "dante",
        Speakers = ChannelOrder.Select(SpeakerCatalog.Get).ToList(),
        Outputs = [new OutputRouteDefinition("dante",
            new EndpointIdentity("asio-name:" + DanteDriverName, DanteDriverName, null, 12), ChannelOrder.ToList(), 0)
        {
            Backend = OutputBackend.Asio, AsioDriverName = DanteDriverName,
            AsioChannels = Enumerable.Range(1, 12).ToArray()
        }]
    };

    public static ProfileDocument LoadForStartup(RuntimePaths paths)
    {
        paths.EnsureUserDirectories();
        string path = PathFor(paths);
        ProfileDocument profile;
        if (File.Exists(path)) profile = ProfileIniSerializer.Load(path);
        else
        {
            profile = CreateDante714();
            ProfileIniSerializer.Save(path, profile);
        }
        ProfileRepository repository = new(paths.ProfilesRoot);
        repository.Save(profile);
        repository.SetActive(profile.Id);
        return profile;
    }

    public static void SaveIfDefault(RuntimePaths paths, ProfileDocument profile)
    {
        string path = PathFor(paths);
        if (File.Exists(path) && ProfileIniSerializer.Load(path).Id == profile.Id)
            ProfileIniSerializer.Save(path, profile);
    }

    public static string SpeakerLabel(string name) => name.ToUpperInvariant() switch
    {
        "FL" => "L 左前", "FR" => "R 右前", "FC" => "C 中置", "LFE" => "LF 低音",
        "SL" => "LS 左侧环绕", "SR" => "RS 右侧环绕", "BL" => "LSR 左后环绕", "BR" => "RSR 右后环绕",
        "TFL" => "LTF 左前顶部", "TFR" => "RTF 右前顶部", "TBL" => "LTR 左后顶部", "TBR" => "RTR 右后顶部",
        "TML" => "左中顶部", "TMR" => "右中顶部", _ => name
    };
}
