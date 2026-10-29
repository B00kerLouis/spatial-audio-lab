using SpatialAudioLab.Core.Profiles;
using SpatialAudioLab.Core.Runtime;
using Xunit;

namespace SpatialAudioLab.Core.Tests;

public sealed class DefaultProfileTests
{
    [Fact]
    public void Default_is_exact_requested_714_order_and_name_selected_dante_asio()
    {
        var profile = DefaultProfileService.CreateDante714();
        profile.Validate();
        Assert.Equal(["FL","FR","FC","LFE","SL","SR","BL","BR","TFL","TFR","TBL","TBR"], profile.Speakers.Select(s => s.Name));
        var output = Assert.Single(profile.Outputs);
        Assert.Equal(OutputBackend.Asio, output.Backend);
        Assert.Null(output.AsioDriver);
        Assert.Equal("Dante Virtual Soundcard", output.AsioDriverName);
        Assert.Equal(Enumerable.Range(1,12), output.AsioChannels);
        Assert.Equal("LSR 左后环绕", DefaultProfileService.SpeakerLabel("BL"));
    }

    [Fact]
    public void Every_start_reloads_the_same_ini_and_preserves_user_edits()
    {
        string directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllText(Path.Combine(directory,"portable.flag"), "");
            var paths = RuntimePaths.Resolve(directory, directory);
            var first = DefaultProfileService.LoadForStartup(paths);
            first.Speakers[0] = first.Speakers[0] with { TrimDb = -3 };
            first.Outputs[0] = first.Outputs[0] with { AsioBufferFrames = 512 };
            DefaultProfileService.SaveIfDefault(paths, first);
            var second = DefaultProfileService.LoadForStartup(paths);
            Assert.Equal(first.Id, second.Id);
            Assert.Equal(-3, second.Speakers[0].TrimDb);
            Assert.Equal(512, second.Outputs[0].AsioBufferFrames);
            Assert.Equal(second.Id, new ProfileRepository(paths.ProfilesRoot).LoadActive()!.Id);
            var studio = SpeakerLayoutEditor.LayoutDocument.FromProfile(second);
            var roundTrip = studio.ToProfile();
            Assert.Equal("Dante Virtual Soundcard", roundTrip.Outputs[0].AsioDriverName);
        }
        finally { Directory.Delete(directory, true); }
    }
}
