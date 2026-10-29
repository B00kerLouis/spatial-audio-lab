SpatialAudioLab ASIO - Windows x64 developer preview
First-party changes: B00kerLouis
Source: https://github.com/B00kerLouis/spatial-audio-lab
Original project: https://github.com/barralutz/spatial-audio-lab

This package includes Studio, Cinema, the ASIO/WASAPI CLI, the TrueHD streaming
helper, a test-signed Virtual Sink driver, mpv, FFmpeg and the .NET runtime.
Extract the complete archive to a writable folder. No SDK or Visual Studio is
needed on the playback computer. The package uses portable Data/Profiles,
Data/Logs and Data/Cache beside the applications.

1. Launch SpatialAudioLab.Studio.exe. Open Examples/asio-714.ini or import your
   own speaker profile. In Salidas, choose Actualizar ASIO, choose your installed
   x64 ASIO driver, set physical channel numbers and buffer frames, then apply
   and save. Install your audio interface manufacturer's ASIO driver first.
2. Test speakers at low gain. Speaker tests do not require the virtual driver.
3. Live spatial capture and Cinema require the Virtual Sink. This is a test
   driver, not a Microsoft production-signed driver. Follow Windows Advanced
   startup > Startup Settings > option 7 (disable driver signature enforcement)
   for a development boot, then run Driver/Install-Driver.ps1 in an elevated
   PowerShell. The installer imports the included public test certificate. It
   does not change Secure Boot, BCD or BitLocker settings. Return to a normal
   boot before using anti-cheat protected games. Remove the driver and its test
   certificate with Driver/Uninstall-Driver.ps1 when finished.
4. Run Studio as Administrator when starting live bridges (the capture ring is
   restricted to administrators). The current upstream GUI does not switch the
   Windows spatial provider automatically. Use Windows sound settings, or
   Tools/Set-SpatialProvider.ps1 -Mode Pcm/Atmos/NativeMat/DtsX with your actual
   -EndpointFilter and -DeviceInstanceId. These diagnostic scripts use Windows
   PowerShell 5.1. Dolby/DTS routes require the relevant licensed provider.
5. For Cinema, keep Studio's PCM 7.1.4 bridge running, then run Start-Cinema.ps1
   to select a Matroska movie. Cinema outputs to the Virtual Sink and the active
   ASIO bridge handles physical output. ASIO.md documents CLI playback and
   configuration, including noncontiguous channels and 48 kHz requirements.

The TrueHD helper is rebuilt from public pinned source. THDS v1 carries PCM and
object metadata to Cinema. ISF elements and multiple metadata timing blocks
are reported as unsupported; channel count/sample rate changes retain Cinema's
existing restrictions. Real hardware playback and long-duration stability
require an ASIO interface and the target Windows audio installation.

Third-party notices and license texts are in Licenses/. Cavern is by Bence
Sganetz (VoidX): https://github.com/VoidXH/Cavern and https://cavern.sbence.hu/ .
The exact Cavern fork and TrueHD source revisions are in build-manifest.json.
FFmpeg and mpv binary source/build references are in runtime-dependencies.json.
Microsoft's .NET runtime and MSVC runtime retain their included third-party
notices. The ASIO SDK is a build dependency; its SDK files are not bundled.
The archive's SHA256SUMS.txt is provided alongside the download.
