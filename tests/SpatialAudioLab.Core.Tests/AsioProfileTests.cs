using SpatialAudioLab.Core.Profiles;
using Xunit;

namespace SpatialAudioLab.Core.Tests;

public sealed class AsioProfileTests
{
    private const string Driver = "{11111111-2222-3333-4444-555555555555}";

    private static ProfileDocument Create(int count = 12) => new()
    {
        Id = Guid.NewGuid(), Name = "ASIO layout", LayoutId = "custom", MasterOutput = "asio",
        Speakers = Enumerable.Range(1, count).Select(index =>
            new SpeakerDefinition($"S{index}", index, 0, -1.5)).ToList(),
        Outputs = [new OutputRouteDefinition("asio",
            new EndpointIdentity("asio:" + Driver, "ASIO device", null, 512),
            Enumerable.Range(1, count).Select(index => $"S{index}").ToArray(), 12.5)
        {
            Backend = OutputBackend.Asio, AsioDriver = Driver,
            AsioChannels = Enumerable.Range(1, count).Select(index => index * 2).ToArray(),
            AsioBufferFrames = 256
        }]
    };

    [Theory]
    [InlineData(12)]
    [InlineData(128)]
    public void Studio_save_and_reload_preserves_sparse_mapping_and_settings(int count)
    {
        string path = Path.GetTempFileName();
        try
        {
            ProfileDocument source = Create(count);
            var document = SpeakerLayoutEditor.LayoutDocument.FromProfile(source);
            document.Save(path);
            var reloaded = SpeakerLayoutEditor.LayoutDocument.Load(path);
            OutputRouteDefinition route = reloaded.ToProfile().Outputs.Single();
            Assert.Equal(OutputBackend.Asio, route.Backend);
            Assert.Equal(Driver, route.AsioDriver);
            Assert.Equal(source.Outputs[0].AsioChannels, route.AsioChannels);
            Assert.Equal(256, route.AsioBufferFrames);
            Assert.Equal(12.5, route.DelayMilliseconds);
            Assert.Equal("ASIO2", reloaded.Outputs[0].PhysicalChannelName(0));
            Assert.Equal(count, reloaded.Speakers.Count);
        }
        finally { File.Delete(path); }
    }

    [Theory]
    [InlineData("1,1")]
    [InlineData("0,2")]
    [InlineData("1,513")]
    [InlineData("1")]
    public void Invalid_mapping_is_rejected_before_saving(string channels)
    {
        ProfileDocument profile = Create(2);
        profile.Outputs[0] = profile.Outputs[0] with
        {
            AsioChannels = channels.Split(',').Select(int.Parse).ToArray()
        };
        Assert.Throws<InvalidDataException>(profile.Validate);
    }

    [Fact]
    public void Mixed_backends_and_invalid_driver_or_buffer_are_rejected()
    {
        ProfileDocument profile = Create(2);
        var valid = profile.Outputs[0];
        profile.Outputs.Add(valid with { Name = "second", Backend = OutputBackend.Wasapi });
        Assert.Throws<InvalidDataException>(profile.Validate);
        profile.Outputs.RemoveAt(1);
        profile.Outputs[0] = valid with { AsioDriver = "not-a-clsid" };
        Assert.Throws<InvalidDataException>(profile.Validate);
        profile.Outputs[0] = valid with { AsioBufferFrames = -1 };
        Assert.Throws<InvalidDataException>(profile.Validate);
    }

    [Fact]
    public void Switching_to_wasapi_clears_asio_settings()
    {
        var document = SpeakerLayoutEditor.LayoutDocument.FromProfile(Create(2));
        var output = document.Outputs[0];
        output.ConfigureEndpoint(new SpatialAudioLab.Core.Audio.AudioEndpointDescriptor(
            "wasapi-id", "Speakers", null, false, 2, [2]));
        ProfileDocument converted = document.ToProfile();
        converted.Validate();
        Assert.Equal(OutputBackend.Wasapi, converted.Outputs[0].Backend);
        Assert.Null(converted.Outputs[0].AsioDriver);
        Assert.Empty(converted.Outputs[0].AsioChannels);
        Assert.Equal(0, converted.Outputs[0].AsioBufferFrames);
    }

    [Fact]
    public void Cli_example_can_be_imported_and_saved_by_studio()
    {
        string path = Path.GetTempFileName();
        try
        {
            string source = FindExample();
            var document = SpeakerLayoutEditor.LayoutDocument.Load(source);
            document.Save(path);
            Assert.Equal(OutputBackend.Asio, ProfileIniSerializer.Load(path).Outputs[0].Backend);
        }
        finally { File.Delete(path); }
    }

    private static string FindExample()
    {
        for (DirectoryInfo? directory = new(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            string path = Path.Combine(directory.FullName, "configs", "asio-714.ini");
            if (File.Exists(path)) return path;
        }
        throw new FileNotFoundException("ASIO example was not found.");
    }
}
