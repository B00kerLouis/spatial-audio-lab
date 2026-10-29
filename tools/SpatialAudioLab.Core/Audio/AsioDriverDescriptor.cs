namespace SpatialAudioLab.Core.Audio;

public sealed record AsioDriverDescriptor(string Name, string Clsid);

public sealed record AsioDeviceDescriptor(
    IReadOnlyList<string> OutputNames,
    int MinimumBufferFrames,
    int MaximumBufferFrames,
    int PreferredBufferFrames,
    int BufferGranularity,
    bool Supports48k);
