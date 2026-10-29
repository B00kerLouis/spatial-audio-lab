#include "asio_renderer.h"
#include "asio_audio.h"
#include <iasiodrv.h>

#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <numeric>
#include <set>
#include <sstream>

namespace {
void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
template<class Function> void Reject(Function fn) {
    bool rejected = false;
    try { fn(); } catch (const std::exception&) { rejected = true; }
    Require(rejected, "Invalid operation was accepted");
}
struct MockDriver final : IASIO {
    long outputs = 128, period = 8, sampleType = 19;
    double rate = 44'100;
    bool initFails{}, startFails{}, createFails{}, latencyFails{}, rateFails{};
    bool supportsOutputReady = true, isRunning{};
    int opens{}, releases{}, stops{}, disposals{}, readyCalls{};
    ASIOCallbacks callbacks{};
    std::vector<std::array<std::vector<unsigned char>, 2>> storage;
    std::vector<long> mapped;
    unsigned long Release() override { ++releases; return 0; }
    ASIOBool init(void*) override { return !initFails; }
    ASIOError start() override { isRunning = !startFails; return startFails ? -1 : ASE_OK; }
    ASIOError stop() override { ++stops; isRunning = false; return ASE_OK; }
    ASIOError getChannels(long* input, long* output) override { *input = 0; *output = outputs; return ASE_OK; }
    ASIOError getLatencies(long* input, long* output) override {
        *input = 0; *output = period * 2; return latencyFails ? -1 : ASE_OK;
    }
    ASIOError getBufferSize(long* minimum, long* maximum, long* preferred, long* granularity) override {
        *minimum = *maximum = *preferred = period; *granularity = 0; return ASE_OK;
    }
    ASIOError canSampleRate(double) override { return rateFails ? -1 : ASE_OK; }
    ASIOError getSampleRate(double* value) override { *value = rate; return ASE_OK; }
    ASIOError setSampleRate(double value) override { rate = value; return ASE_OK; }
    ASIOError getChannelInfo(ASIOChannelInfo* info) override {
        if (info->channel < 0 || info->channel >= outputs || info->isInput) return -1;
        info->type = sampleType;
        std::strcpy(info->name, "Mock output");
        return ASE_OK;
    }
    ASIOError createBuffers(ASIOBufferInfo* buffers, long channels, long frames, ASIOCallbacks* cb) override {
        if (createFails) return -1;
        callbacks = *cb;
        mapped.clear(); storage.resize(static_cast<std::size_t>(channels));
        for (long channel = 0; channel < channels; ++channel) {
            Require(!buffers[channel].isInput, "ASIO opened an input channel");
            mapped.push_back(buffers[channel].channelNum);
            for (int half = 0; half < 2; ++half) {
                auto& data = storage[static_cast<std::size_t>(channel)][half];
                data.assign(static_cast<std::size_t>(frames) * dolby::asio::Format(sampleType).bytes, 0xaa);
                buffers[channel].buffers[half] = data.data();
            }
        }
        return ASE_OK;
    }
    ASIOError disposeBuffers() override { ++disposals; callbacks = {}; return ASE_OK; }
    ASIOError outputReady() override { ++readyCalls; return supportsOutputReady ? ASE_OK : ASE_NotPresent; }
    void Tick(long half) {
        Require(isRunning, "Mock callback called after stop");
        callbacks.bufferSwitch(half, ASIOFalse);
    }
    float Sample(std::size_t channel, int half, std::size_t frame) const {
        float sample = 0;
        std::memcpy(&sample, storage[channel][half].data() + frame * sizeof(float), sizeof(float));
        return sample;
    }
} driver;
int eventCount{};
std::uint64_t mockTicks{};
struct Event { bool signaled{}; };
const std::wstring driverId = L"{00000000-0000-0000-0000-000000000001}";

dolby::SpeakerLayout Layout(std::size_t count = 65) {
    dolby::SpeakerLayout layout;
    layout.name = L"Mock ASIO layout";
    dolby::OutputRouteDefinition route;
    route.name = L"interface";
    route.backend = dolby::OutputBackend::Asio;
    route.asioDriver = driverId;
    for (std::size_t index = 0; index < count; ++index) {
        layout.speakers.push_back({L"S" + std::to_wstring(index), 0, 0, 0});
        route.speakerIndices.push_back(index);
        route.asioChannels.push_back(static_cast<long>(std::max<std::size_t>(127, count-1) - index));
    }
    layout.outputs.push_back(route);
    return layout;
}
dolby::InterleavedPcmQueue Queue(std::size_t channels, std::size_t frames) {
    dolby::InterleavedPcmQueue queue(channels);
    std::vector<std::int16_t> samples(channels * frames);
    for (std::size_t frame = 0; frame < frames; ++frame)
        for (std::size_t channel = 0; channel < channels; ++channel)
            samples[frame * channels + channel] = static_cast<std::int16_t>(100 + frame + channel);
    queue.Append(std::move(samples));
    return queue;
}
void Reset() {
    Require(eventCount == 0, "ASIO leaked a Windows event");
    Require(!driver.isRunning, "ASIO left the driver running");
    driver = MockDriver{};
}
void DriverNameAndFloatPrecision() {
    using dolby::AsioDriverDescriptor;
    const std::vector<AsioDriverDescriptor> drivers = {
        {L"Other ASIO", L"other"}, {L"Dante Virtual Soundcard", L"legacy"},
        {L"Dante Virtual Soundcard (64x)", driverId}
    };
    Require(dolby::SelectAsioDriverByName(drivers, L"dante virtual soundcard") == driverId,
            "Dante default did not prefer the explicit 64-bit ASIO registration");
    Reject([&] { dolby::SelectAsioDriverByName(drivers, L"Dante Via"); });
    Reset();
    auto layout = Layout(2);
    dolby::InterleavedPcmQueue queue(2);
    const float quiet = 1.0f / 8388608.0f;
    queue.AppendFloat(std::vector<float>(16, quiet));
    {
        dolby::AsioRenderer renderer(layout, 1);
        renderer.Prime(queue); renderer.Start(); driver.Tick(0);
        Require(driver.Sample(0, 0, 0) == quiet, "Cinema PCM was quantized to 16-bit before ASIO output");
        renderer.Stop();
    }
}
void DeviceInspection() {
    Reset();
    driver.outputs = 16;
    const auto device = dolby::InspectAsioDevice(driverId);
    Require(device.outputNames.size() == 16 && device.outputNames.back() == L"Mock output",
            "Device query lost physical output names");
    Require(device.supports48k && device.preferredBufferFrames == 8,
            "Device query lost sample rate or buffer capability");
    Require(driver.rate == 44'100 && driver.storage.empty() && driver.releases == 1,
            "Device query changed the rate, allocated buffers or leaked the driver");
    driver.rateFails = true;
    Require(!dolby::InspectAsioDevice(driverId).supports48k, "Device query ignored unsupported 48 kHz");
    driver.outputs = 0;
    Reject([&] { dolby::InspectAsioDevice(driverId); });
}
void PlaybackAndDrain() {
    Reset();
    auto layout = Layout();
    layout.speakers[64].trimDb = -6.020599913279624;
    auto queue = Queue(65, 73);
    {
        dolby::AsioRenderer renderer(layout, 0.5);
        Require(driver.rate == 48'000, "ASIO failed to configure 48 kHz");
        Require(driver.mapped.size() == 65 && driver.mapped.front() == 127 && driver.mapped.back() == 63,
                "ASIO lost channels above 32 or changed physical mapping");
        Require(driver.Sample(64, 1, 7) == 0, "ASIO failed to silence initial buffers");
        renderer.Prime(queue);
        Require(renderer.MinimumFramesAvailable(queue) == 73, "Prebuffer frame count changed after priming");
        renderer.DiscardConsumed(queue);
        Require(queue.Sample(32, 64) == 196.0 / 32768.0, "Queue discard removed pending source audio");
        renderer.Start();
        Reject([&] { renderer.Prime(queue); });
        renderer.Start(); // idempotent
        std::size_t played = 0;
        int half = 0;
        while (!renderer.IsDrained(queue)) {
            driver.Tick(half);
            const auto count = std::min<std::size_t>(8, 73 - played);
            for (std::size_t frame = 0; frame < count; ++frame) {
                const float expected = static_cast<float>((100 + played + frame + 64) / 32768.0 * 0.25);
                Require(std::abs(driver.Sample(64, half, frame) - expected) < 1e-7f,
                        "High channel, trim, gain or frame ordering is incorrect");
            }
            played += count;
            renderer.Service(queue, false, 0);
            renderer.DiscardConsumed(queue);
            half = 1 - half;
            Require(played <= 73, "ASIO did not drain");
        }
        Require(played == 73, "ASIO discarded the final audio block");
        const auto stats = renderer.Stats().front();
        Require(stats.starvationFrames == 0 && stats.bufferFrames == 8,
                "ASIO statistics counted tail padding as starvation");
        renderer.Stop(); renderer.Stop();
        Require(!renderer.IsStarted() && driver.stops == 1, "ASIO stop is not idempotent");
        Reject([&] { renderer.Start(); });
    }
    Require(driver.releases == 1 && driver.disposals == 1 && eventCount == 0,
            "Successful ASIO playback leaked resources");
}
void UnderrunAndChanges() {
    Reset();
    driver.supportsOutputReady = false;
    auto queue = Queue(2, 2);
    {
        dolby::AsioRenderer renderer(Layout(2), 1.0);
        renderer.Prime(queue); renderer.Start(); renderer.Service(queue, true, 0);
        driver.Tick(0);
        Require(driver.Sample(1, 0, 0) == 101.0f / 32768.0f && driver.Sample(1, 0, 2) == 0,
                "ASIO underrun did not output silence after valid audio");
        Require(renderer.Stats().front().starvationFrames == 6 && driver.readyCalls == 1,
                "ASIO starvation or outputReady capability handling is incorrect");
        queue.Append({300, 400});
        renderer.Service(queue, false, 0);
        ASIOTime time;
        driver.callbacks.bufferSwitchTimeInfo(&time, 1, ASIOFalse);
        Require(driver.Sample(1, 1, 0) == 400.0f / 32768.0f,
                "ASIO failed to resume after starvation");
        driver.callbacks.sampleRateDidChange(44'100);
        driver.Tick(0);
        Require(driver.Sample(1, 0, 0) == 0, "ASIO did not silence after a sample rate change");
        Reject([&] { renderer.Service(queue, true, 0); });
    }
    for (long selector : {kAsioResetRequest, kAsioBufferSizeChange, kAsioResyncRequest}) {
        Reset();
        dolby::AsioRenderer renderer(Layout(2), 1.0);
        renderer.Prime(queue); renderer.Start();
        Require(driver.callbacks.asioMessage(selector, 0, nullptr, nullptr) == 1,
                "ASIO failed to acknowledge a configuration event");
        Reject([&] { renderer.Service(queue, true, 0); });
    }
    Reset();
    {
        dolby::AsioRenderer renderer(Layout(2), 1.0);
        renderer.Prime(queue); renderer.Start();
        driver.period = 16;
        driver.callbacks.asioMessage(kAsioLatenciesChanged, 0, nullptr, nullptr);
        renderer.Service(queue, true, 0);
        Require(renderer.Stats()[0].streamLatencyMilliseconds == 32.0 / 48.0,
                "ASIO latency notification did not refresh latency on the service thread");
        mockTicks += 6000;
        Reject([&] { renderer.Service(queue, true, 0); });
    }
}
void StartupFailures() {
    for (int failure = 0; failure < 6; ++failure) {
        Reset();
        driver.initFails = failure == 0; driver.createFails = failure == 1;
        driver.latencyFails = failure == 2; driver.rateFails = failure == 3;
        if (failure == 4) driver.sampleType = 40;
        if (failure == 5) driver.outputs = 32;
        Reject([] { dolby::AsioRenderer renderer(Layout(), 1.0); });
        Require(driver.releases == 1 && eventCount == 0, "Failed startup leaked resources");
        Require(driver.disposals == (failure == 2 ? 1 : 0), "ASIO disposed uncreated buffers or leaked created buffers");
    }
    Reset(); driver.startFails = true;
    {
        dolby::AsioRenderer renderer(Layout(), 1.0);
        Reject([&] { renderer.Start(); });
        Require(!renderer.IsStarted() && driver.stops == 1, "Failed start left the stream active");
    }
    Reset();
    {
        dolby::AsioRenderer first(Layout(), 1.0);
        Reject([] { dolby::AsioRenderer second(Layout(), 1.0); });
        Require(driver.opens == 1 && eventCount == 1, "Second renderer touched an active ASIO driver");
    }
    Reset();
    { dolby::AsioRenderer replacement(Layout(), 1.0); }
    Require(driver.releases == 1 && eventCount == 0, "ASIO singleton was not released");
    Reset();
    Reject([] { dolby::AsioRenderer renderer(Layout(), std::numeric_limits<double>::quiet_NaN()); });
    auto duplicate = Layout(); duplicate.outputs[0].speakerIndices[1] = 0;
    Reject([&] { dolby::AsioRenderer renderer(duplicate, 1.0); });
    auto mixed = Layout(); mixed.outputs.push_back({});
    Reject([&] { dolby::AsioRenderer renderer(mixed, 1.0); });
    Require(driver.opens == 0, "Invalid layout reached the driver");
}
void DelayAndLargeDevice() {
    Reset();
    driver.outputs = 512;
    {
        auto queue = Queue(512, 8);
        dolby::AsioRenderer renderer(Layout(512), 1.0);
        renderer.Prime(queue); renderer.Start(); driver.Tick(0);
        Require(driver.mapped.size() == 512 && driver.mapped.front() == 511 &&
                driver.Sample(511, 0, 0) == 611.0f / 32768.0f,
                "512-channel device was artificially limited or incorrectly routed");
        Require(renderer.IsDrained(queue), "Large device did not drain");
    }
    Reset();
    {
        auto layout = Layout(2);
        layout.outputs[0].delayMilliseconds = 0.25; // 12 source frames
        auto queue = Queue(2, 2);
        dolby::AsioRenderer renderer(layout, 1.0);
        Reject([&] { renderer.Prime(Queue(3, 1)); });
        renderer.Prime(queue); renderer.Start(); driver.Tick(0);
        Require(driver.Sample(1, 0, 7) == 0, "ASIO route delay was not silent");
        driver.Tick(1);
        Require(driver.Sample(1, 1, 3) == 0 && driver.Sample(1, 1, 4) == 101.0f / 32768.0f &&
                driver.Sample(1, 1, 6) == 0, "ASIO route delay shifted or dropped source frames");
        Require(renderer.IsDrained(queue), "Delayed route did not drain");
        driver.Tick(2);
        Reject([&] { renderer.Service(queue, false, 0); });
    }
}
void ProfileAndQueue() {
    const auto path = std::filesystem::temp_directory_path() / "sal-asio-mock-layout.ini";
    auto write = [&](const std::string& backend, const std::string& channels) {
        std::ofstream ini(path);
        ini << "[profile]\nversion=2\nname=128 channels\n[layout]\nspeakers=";
        for (int i = 0; i < 128; ++i) ini << (i ? "," : "") << "S" << i;
        ini << "\noutputs=interface\nmaster=interface\n[output.interface]\nbackend=" << backend
            << "\nasio_driver={00000000-0000-0000-0000-000000000001}\nasio_channels=" << channels
            << "\nspeakers=";
        for (int i = 0; i < 128; ++i) ini << (i ? "," : "") << "S" << i;
        for (int i = 0; i < 128; ++i)
            ini << "\n[speaker.S" << i << "]\nazimuth=" << i << "\nelevation=0\n";
    };
    write("asio", "");
    const auto layout = dolby::LoadSpeakerLayout(path);
    Require(layout.speakers.size() == 128 && layout.outputs[0].speakerIndices.size() == 128,
            "Profile parser retained the old 12-channel limit");
    auto queue = Queue(128, 5000);
    Reject([&] { queue.Append({1}); });
    Require(queue.EndFrame() == 5000 && queue.Channels() == 128, "PCM queue retained the old 32-channel limit");
    queue.DiscardBefore(4900);
    Require(queue.Sample(4899, 127) != 0 && queue.Sample(4898, 127) == 0,
            "PCM queue discard violated the interpolation history boundary");
    write("asio", "1,1"); Reject([&] { dolby::LoadSpeakerLayout(path); });
    write("unknown", ""); Reject([&] { dolby::LoadSpeakerLayout(path); });
    {
        std::ofstream ini(path);
        ini << "[layout]\nname=WASAPI legacy\nspeakers=FL,FR\noutputs=front\nmaster=front\n"
               "[output.front]\nendpoint=Speakers\nspeakers=FL,FR\n"
               "[speaker.FL]\nazimuth=-30\nelevation=0\n"
               "[speaker.FR]\nazimuth=30\nelevation=0\n";
    }
    const auto legacy = dolby::LoadSpeakerLayout(path);
    Require(legacy.outputs[0].backend == dolby::OutputBackend::Wasapi &&
            legacy.outputs[0].endpointFilter == L"Speakers", "Legacy WASAPI profile compatibility changed");
    std::filesystem::remove(path);
}
} // namespace

// Minimal fake platform implementation, only linked by Test-AsioPortable.py.
long RegCloseKey(HKEY) { return ERROR_SUCCESS; }
long RegGetValueW(HKEY, const wchar_t*, const wchar_t*, DWORD, DWORD*, void*, DWORD*) { return ERROR_FILE_NOT_FOUND; }
long RegOpenKeyExW(HKEY, const wchar_t*, DWORD, DWORD, HKEY*) { return ERROR_FILE_NOT_FOUND; }
long RegQueryInfoKeyW(HKEY, wchar_t*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, DWORD*, void*) { return 1; }
long RegEnumKeyExW(HKEY, DWORD, wchar_t*, DWORD*, DWORD*, wchar_t*, DWORD*, void*) { return ERROR_NO_MORE_ITEMS; }
HRESULT CLSIDFromString(const wchar_t* text, CLSID* id) {
    id->text = text; return id->text == driverId ? 0 : -1;
}
HRESULT CoCreateInstance(const CLSID&, void*, DWORD, const CLSID&, void** output) {
    ++driver.opens; *output = &driver; return 0;
}
HWND GetDesktopWindow() { return nullptr; }
HANDLE CreateEventW(void*, bool, bool signaled, const wchar_t*) { ++eventCount; return new Event{signaled}; }
bool CloseHandle(HANDLE event) { --eventCount; delete static_cast<Event*>(event); return true; }
bool SetEvent(HANDLE event) { static_cast<Event*>(event)->signaled = true; return true; }
DWORD WaitForSingleObject(HANDLE event, DWORD) {
    auto* value = static_cast<Event*>(event);
    const auto result = value->signaled ? WAIT_OBJECT_0 : WAIT_TIMEOUT;
    value->signaled = false;
    return result;
}
void Sleep(DWORD) {}
std::uint64_t GetTickCount64() { return mockTicks; }
DWORD GetPrivateProfileStringW(const wchar_t* section, const wchar_t* key, const wchar_t* fallback,
                               wchar_t* output, DWORD capacity, const char* file) {
    std::ifstream input(file);
    std::string line;
    std::wstring current, result(fallback);
    while (std::getline(input, line)) {
        const std::wstring wide(line.begin(), line.end());
        if (wide.empty()) continue;
        if (wide.front() == L'[' && wide.back() == L']') current = wide.substr(1, wide.size()-2);
        else if (current == section) {
            const auto equals = wide.find(L'=');
            if (equals != std::wstring::npos && wide.substr(0, equals) == key) result = wide.substr(equals+1);
        }
    }
    const auto length = std::min<std::size_t>(result.size(), capacity - 1);
    std::copy_n(result.data(), length, output); output[length] = 0;
    return static_cast<DWORD>(length);
}
int main() {
    try {
        DriverNameAndFloatPrecision(); DeviceInspection(); PlaybackAndDrain(); UnderrunAndChanges(); StartupFailures(); DelayAndLargeDevice(); ProfileAndQueue();
        Require(eventCount == 0, "ASIO tests leaked events");
        std::cout << "ASIO mock host tests passed (65-channel playback, 128-channel profiles, lifecycle and errors)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
