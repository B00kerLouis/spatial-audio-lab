using SpatialAudioLab.Core.Profiles;

namespace DolbyPlayer;

internal interface IPlayerAudioOutput : IDisposable
{
    string OutputName { get; }
    double MediaPositionSeconds { get; }
    double ClockSkewMilliseconds { get; }
    bool IsDrained { get; }
    void ResetClock(double position);
    void Play();
    void Pause();
    void Stop();
}

internal static class PlayerAudioOutput
{
    public static IPlayerAudioOutput Create(PlayerPaths paths, ProfileDocument profile, Pcm714Buffer queue,
        float gain, string? diagnosticSink) => string.IsNullOrWhiteSpace(diagnosticSink)
        ? new NativePcmOutput714(paths, profile, queue, gain)
        : new PcmSinkOutput714(queue, paths.ResolveVirtualSinkFilter(diagnosticSink), gain);
}
