#include "asio_renderer.h"
#include "asio_audio.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <cwctype>
#include <stdexcept>

#ifdef SAL_ENABLE_ASIO
#include <objbase.h>
#include <iasiodrv.h>
#endif

namespace dolby {
namespace {
[[maybe_unused, noreturn]] void AsioUnavailable() {
    throw std::runtime_error("ASIO was not enabled at build time; set SAL_ASIO_SDK_ROOT to the ASIO SDK root and rebuild");
}
#ifdef SAL_ENABLE_ASIO
void Check(ASIOError error, const char* operation) {
    if (error != ASE_OK && error != ASE_SUCCESS)
        throw std::runtime_error(std::string(operation) + " failed (ASIO " + std::to_string(error) + ")");
}
struct RegistryKey {
    HKEY value{};
    ~RegistryKey() { if (value) RegCloseKey(value); }
};
std::wstring RegistryString(HKEY key, const wchar_t* name) {
    DWORD bytes = 0;
    if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, nullptr, &bytes) != ERROR_SUCCESS)
        return {};
    std::vector<wchar_t> text(bytes / sizeof(wchar_t) + 1);
    if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, text.data(), &bytes) != ERROR_SUCCESS)
        return {};
    return text.data();
}
struct Driver {
    IASIO* value{};
    ~Driver() { if (value) value->Release(); }
    void Open(std::wstring_view id) {
        CLSID clsid{};
        const std::wstring terminated(id);
        if (FAILED(CLSIDFromString(terminated.c_str(), &clsid)))
            throw std::invalid_argument("asio_driver must be a driver CLSID from list-asio");
        // ASIO drivers expose their own CLSID as their interface identifier.
        if (FAILED(CoCreateInstance(clsid, nullptr, CLSCTX_INPROC_SERVER, clsid,
                                    reinterpret_cast<void**>(&value))))
            throw std::runtime_error("Could not load the ASIO driver; install a matching x64 driver");
        if (!value->init(GetDesktopWindow()))
            throw std::runtime_error("ASIO driver initialization failed; check that the device is connected and available");
    }
};
#endif
} // namespace

std::vector<AsioDriverDescriptor> EnumerateAsioDrivers() {
#ifndef SAL_ENABLE_ASIO
    AsioUnavailable();
#else
    RegistryKey root;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\ASIO", 0, KEY_READ, &root.value) != ERROR_SUCCESS)
        return {};
    DWORD maximumName = 0;
    if (RegQueryInfoKeyW(root.value, nullptr, nullptr, nullptr, nullptr, &maximumName,
                         nullptr, nullptr, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS)
        throw std::runtime_error("Cannot query the ASIO driver registry");
    std::vector<wchar_t> name(static_cast<std::size_t>(maximumName) + 2);
    std::vector<AsioDriverDescriptor> result;
    for (DWORD index = 0;; ++index) {
        DWORD length = static_cast<DWORD>(name.size());
        const auto status = RegEnumKeyExW(root.value, index, name.data(), &length,
                                          nullptr, nullptr, nullptr, nullptr);
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS) throw std::runtime_error("Cannot enumerate ASIO drivers");
        RegistryKey entry;
        if (RegOpenKeyExW(root.value, name.data(), 0, KEY_READ, &entry.value) != ERROR_SUCCESS) continue;
        auto clsid = RegistryString(entry.value, L"CLSID");
        auto description = RegistryString(entry.value, L"Description");
        if (!clsid.empty()) result.push_back({description.empty() ? name.data() : description, clsid});
    }
    return result;
#endif
}

std::wstring SelectAsioDriverByName(const std::vector<AsioDriverDescriptor>& drivers, std::wstring_view name) {
    const auto normalized = [](std::wstring text) {
        std::transform(text.begin(), text.end(), text.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
        return text;
    };
    const auto wanted = normalized(std::wstring(name));
    std::vector<AsioDriverDescriptor> matches;
    for (const auto& driver : drivers) {
        const auto actual = normalized(driver.name);
        if (actual == wanted || (wanted == L"dante virtual soundcard" &&
            (actual == wanted + L" (64x)" || actual == wanted + L" (x64)" || actual == wanted + L" (64-bit)")))
            matches.push_back(driver);
    }
    // The process enumerates the 64-bit registry. Prefer DVS's explicit 64-bit registration.
    if (wanted == L"dante virtual soundcard" && matches.size() > 1) {
        std::erase_if(matches, [&](const auto& driver) { return normalized(driver.name) == wanted; });
    }
    if (matches.size() != 1)
        throw std::runtime_error("未找到唯一的 ASIO 驱动。请以 ASIO 模式启动 Dante Virtual Soundcard，或在配置中指定驱动 CLSID。");
    return matches.front().clsid;
}

AsioDeviceDescriptor InspectAsioDevice(std::wstring_view clsid) {
#ifndef SAL_ENABLE_ASIO
    (void)clsid;
    AsioUnavailable();
#else
    Driver driver;
    driver.Open(clsid);
    long inputs = 0, outputs = 0;
    Check(driver.value->getChannels(&inputs, &outputs), "getChannels");
    if (outputs <= 0) throw std::runtime_error("ASIO driver has no output channels");
    AsioDeviceDescriptor result;
    for (long channel = 0; channel < outputs; ++channel) {
        ASIOChannelInfo info{};
        info.channel = channel;
        info.isInput = ASIOFalse;
        Check(driver.value->getChannelInfo(&info), "getChannelInfo");
        info.name[sizeof(info.name) - 1] = '\0';
        std::wstring name;
        for (const unsigned char c : std::string(info.name)) name += static_cast<wchar_t>(c);
        result.outputNames.push_back(std::move(name));
    }
    long minimum = 0, maximum = 0, preferred = 0, granularity = 0;
    Check(driver.value->getBufferSize(&minimum, &maximum, &preferred, &granularity), "getBufferSize");
    result.minimumBufferFrames = minimum;
    result.maximumBufferFrames = maximum;
    result.preferredBufferFrames = preferred;
    result.bufferGranularity = granularity;
    const auto rate = driver.value->canSampleRate(48'000.0);
    result.supports48k = rate == ASE_OK || rate == ASE_SUCCESS;
    return result;
#endif
}

void PrintAsioChannels(std::wstring_view clsid) {
    const auto device = InspectAsioDevice(clsid);
    std::wcout << L"ASIO outputs: " << device.outputNames.size() << L"\n";
    for (std::size_t channel = 0; channel < device.outputNames.size(); ++channel)
        std::wcout << channel + 1 << L"\t" << device.outputNames[channel] << L"\n";
    std::wcout << L"Buffer frames: min=" << device.minimumBufferFrames
               << L", max=" << device.maximumBufferFrames
               << L", preferred=" << device.preferredBufferFrames
               << L", granularity=" << device.bufferGranularity
               << L"\n48 kHz: " << (device.supports48k ? L"yes" : L"no") << L"\n";
}

struct AsioRenderer::Impl {
    SpeakerLayout layout;
    double gain{};
    double sourcePosition{};
    bool started{}, stopped{};
#ifdef SAL_ENABLE_ASIO
    Driver driver;
    HANDLE event{};
    long bufferFrames{}, outputLatency{};
    bool buffersCreated{}, outputReady{};
    std::vector<ASIOBufferInfo> buffers;
    std::vector<asio::SampleFormat> formats;
    std::vector<float> producerFrame, callbackFrame;
    std::vector<double> gains;
    std::unique_ptr<asio::FrameRing> ring;
    ASIOCallbacks callbacks{};
    std::atomic<bool> running{}, countStarvation{}, latenciesChanged{};
    std::atomic<int> reconfigure{};
    std::atomic<std::uint64_t> rendered{}, starvation{};
    std::uint64_t lastProgress{}, lastProgressTick{};
    // ASIO callbacks carry no user pointer. Own one driver per process explicitly.
    static std::atomic<Impl*> active;

    ~Impl() {
        running.store(false, std::memory_order_release);
        if (started) driver.value->stop();
        if (buffersCreated) driver.value->disposeBuffers();
        Impl* expected = this;
        active.compare_exchange_strong(expected, nullptr);
        if (event) CloseHandle(event);
    }
    static void BufferSwitch(long index, ASIOBool) noexcept {
        auto* self = active.load(std::memory_order_acquire);
        if (self && self->running.load(std::memory_order_acquire)) self->Render(index);
    }
    static ASIOTime* TimeSwitch(ASIOTime* time, long index, ASIOBool direct) noexcept {
        BufferSwitch(index, direct);
        return time;
    }
    static void SampleRateChanged(ASIOSampleRate rate) noexcept {
        if (rate == 48'000.0) return;
        if (auto* self = active.load(std::memory_order_acquire)) {
            self->reconfigure.store(1, std::memory_order_release);
            SetEvent(self->event);
        }
    }
    static long Message(long selector, long value, void*, double*) noexcept {
        switch (selector) {
        case kAsioSelectorSupported:
            return value == kAsioEngineVersion || value == kAsioResetRequest ||
                   value == kAsioBufferSizeChange || value == kAsioResyncRequest ||
                   value == kAsioLatenciesChanged || value == kAsioSupportsTimeInfo;
        case kAsioEngineVersion: return 2;
        case kAsioSupportsTimeInfo: return 1;
        case kAsioLatenciesChanged:
            if (auto* self = active.load(std::memory_order_acquire)) {
                self->latenciesChanged.store(true, std::memory_order_release);
                SetEvent(self->event);
            }
            return 1;
        case kAsioResetRequest:
        case kAsioBufferSizeChange:
        case kAsioResyncRequest:
            if (auto* self = active.load(std::memory_order_acquire)) {
                self->reconfigure.store(1, std::memory_order_release);
                SetEvent(self->event);
            }
            return 1;
        default: return 0;
        }
    }
    void Render(long index) noexcept {
        if (index != 0 && index != 1) {
            reconfigure.store(1, std::memory_order_release);
            SetEvent(event);
            return;
        }
        const bool failed = reconfigure.load(std::memory_order_acquire) != 0;
        std::uint64_t missing = 0;
        for (long frame = 0; frame < bufferFrames; ++frame) {
            if (failed || !ring->Pop(callbackFrame.data())) {
                std::fill(callbackFrame.begin(), callbackFrame.end(), 0.0f);
                ++missing;
            }
            for (std::size_t channel = 0; channel < buffers.size(); ++channel) {
                auto* target = static_cast<unsigned char*>(buffers[channel].buffers[index]) +
                    static_cast<std::size_t>(frame) * formats[channel].bytes;
                asio::WriteSample(target, formats[channel], callbackFrame[channel]);
            }
        }
        rendered.fetch_add(static_cast<std::uint64_t>(bufferFrames), std::memory_order_relaxed);
        if (countStarvation.load(std::memory_order_relaxed)) starvation.fetch_add(missing);
        if (outputReady) driver.value->outputReady();
        SetEvent(event);
    }
    void Initialize() {
        if (!std::isfinite(gain) || gain < 0.0 || gain > 1.0)
            throw std::invalid_argument("ASIO gain must be between 0 and 1");
        if (layout.outputs.size() != 1 || layout.masterOutput != 0)
            throw std::invalid_argument("An ASIO layout must have exactly one output route as master");
        const auto& route = layout.outputs.front();
        if (route.backend != OutputBackend::Asio || route.speakerIndices.empty())
            throw std::invalid_argument("Invalid ASIO output route");
        if (route.speakerIndices.size() != layout.speakers.size())
            throw std::invalid_argument("Every speaker must be assigned to the ASIO route");
        auto indices = route.speakerIndices;
        std::sort(indices.begin(), indices.end());
        if (indices.back() >= layout.speakers.size() ||
            std::adjacent_find(indices.begin(), indices.end()) != indices.end())
            throw std::invalid_argument("ASIO route contains duplicate or invalid speakers");
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event) throw std::runtime_error("Cannot create ASIO service event");
        // Reserve the process slot before loading a driver. Some COM drivers
        // return a shared instance, so opening a second one could disrupt audio.
        Impl* expected = nullptr;
        if (!active.compare_exchange_strong(expected, this))
            throw std::runtime_error("Only one ASIO renderer can be active in a process");
        const auto driverId = route.asioDriver.empty() || route.asioDriver == L"{00000000-0000-0000-0000-000000000000}"
            ? SelectAsioDriverByName(EnumerateAsioDrivers(), route.asioDriverName) : route.asioDriver;
        driver.Open(driverId);
        long inputs = 0, outputs = 0;
        Check(driver.value->getChannels(&inputs, &outputs), "getChannels");
        const auto mapping = asio::MapChannels(route.speakerIndices.size(), route.asioChannels, outputs);
        Check(driver.value->canSampleRate(48'000.0), "ASIO requires 48 kHz PCM");
        ASIOSampleRate rate = 0;
        Check(driver.value->getSampleRate(&rate), "getSampleRate");
        if (rate != 48'000.0) Check(driver.value->setSampleRate(48'000.0), "setSampleRate(48000)");
        Check(driver.value->getSampleRate(&rate), "getSampleRate");
        if (rate != 48'000.0) throw std::runtime_error("ASIO driver did not accept 48 kHz");
        long minimum = 0, maximum = 0, preferred = 0, granularity = 0;
        Check(driver.value->getBufferSize(&minimum, &maximum, &preferred, &granularity), "getBufferSize");
        bufferFrames = asio::SelectBufferSize(minimum, maximum, preferred, granularity, route.asioBufferFrames);
        if (static_cast<std::uint64_t>(bufferFrames) * 4 > std::numeric_limits<std::uint32_t>::max())
            throw std::runtime_error("ASIO buffer size overflows renderer frame accounting");
        ring = std::make_unique<asio::FrameRing>(mapping.size(), static_cast<std::size_t>(bufferFrames) * 4);
        producerFrame.resize(mapping.size());
        callbackFrame.resize(mapping.size());
        buffers.resize(mapping.size());
        for (std::size_t channel = 0; channel < mapping.size(); ++channel) {
            if (route.speakerIndices[channel] >= layout.speakers.size())
                throw std::invalid_argument("ASIO route references a missing speaker");
            const double trim = layout.speakers[route.speakerIndices[channel]].trimDb;
            if (!std::isfinite(trim) || trim < -60.0 || trim > 12.0)
                throw std::invalid_argument("ASIO speaker trim must be between -60 and 12 dB");
            gains.push_back(gain * std::pow(10.0, trim / 20.0));
            buffers[channel].isInput = ASIOFalse;
            buffers[channel].channelNum = mapping[channel];
            ASIOChannelInfo info{};
            info.channel = mapping[channel];
            info.isInput = ASIOFalse;
            Check(driver.value->getChannelInfo(&info), "getChannelInfo");
            formats.push_back(asio::Format(info.type));
        }
        callbacks = {&BufferSwitch, &SampleRateChanged, &Message, &TimeSwitch};
        Check(driver.value->createBuffers(buffers.data(), static_cast<long>(buffers.size()),
                                          bufferFrames, &callbacks), "createBuffers");
        buffersCreated = true;
        for (std::size_t channel = 0; channel < buffers.size(); ++channel) {
            for (void* buffer : buffers[channel].buffers) {
                if (!buffer) throw std::runtime_error("ASIO returned a null output buffer");
                std::memset(buffer, 0, static_cast<std::size_t>(bufferFrames) * formats[channel].bytes);
            }
        }
        long inputLatency = 0;
        Check(driver.value->getLatencies(&inputLatency, &outputLatency), "getLatencies");
        if (outputLatency < 0) throw std::runtime_error("ASIO returned a negative output latency");
        outputReady = driver.value->outputReady() == ASE_OK;
        if (!std::isfinite(route.delayMilliseconds) || route.delayMilliseconds < 0 || route.delayMilliseconds > 500)
            throw std::invalid_argument("ASIO output delay must be between 0 and 500 ms");
        sourcePosition = -std::round(route.delayMilliseconds * 48.0);
    }
    void Fill(const InterleavedPcmQueue& queue) {
        if (queue.Channels() != layout.speakers.size())
            throw std::invalid_argument("ASIO PCM queue does not match the speaker layout");
        if (reconfigure.load(std::memory_order_acquire))
            throw std::runtime_error("ASIO driver configuration or sample rate changed; restart the bridge");
        if (latenciesChanged.exchange(false, std::memory_order_acq_rel)) {
            long inputLatency = 0, latency = 0;
            Check(driver.value->getLatencies(&inputLatency, &latency), "getLatencies after ASIO notification");
            if (latency < 0) throw std::runtime_error("ASIO returned a negative output latency");
            outputLatency = latency;
        }
        const auto& speakers = layout.outputs.front().speakerIndices;
        const auto available = ring->Writable();
        for (std::size_t frame = 0; frame < available; ++frame) {
            if (sourcePosition >= static_cast<double>(queue.EndFrame())) break;
            for (std::size_t channel = 0; channel < speakers.size(); ++channel) {
                const double sample = sourcePosition < 0 ? 0 :
                    queue.Sample(static_cast<std::uint64_t>(sourcePosition), speakers[channel]);
                producerFrame[channel] = static_cast<float>(std::clamp(sample * gains[channel], -1.0, 1.0));
            }
            ring->Push(producerFrame.data());
            sourcePosition += 1.0;
        }
    }
#endif
};

#ifdef SAL_ENABLE_ASIO
std::atomic<AsioRenderer::Impl*> AsioRenderer::Impl::active{};
#endif

AsioRenderer::AsioRenderer(const SpeakerLayout& layout, double gain) : impl_(std::make_unique<Impl>()) {
    impl_->layout = layout;
    impl_->gain = gain;
#ifdef SAL_ENABLE_ASIO
    impl_->Initialize();
#else
    AsioUnavailable();
#endif
}
AsioRenderer::~AsioRenderer() { try { Stop(); } catch (...) {} }
void AsioRenderer::Prime(const InterleavedPcmQueue& queue) {
    if (impl_->started || impl_->stopped) throw std::runtime_error("Cannot prime a running or stopped ASIO renderer");
#ifdef SAL_ENABLE_ASIO
    impl_->Fill(queue);
#else
    (void)queue;
#endif
}
void AsioRenderer::Start() {
    if (impl_->started) return;
    if (impl_->stopped) throw std::runtime_error("Cannot restart a stopped ASIO renderer");
#ifdef SAL_ENABLE_ASIO
    if (impl_->reconfigure.load()) throw std::runtime_error("ASIO configuration changed during startup; restart the bridge");
    impl_->running.store(true, std::memory_order_release);
    const auto result = impl_->driver.value->start();
    if (result != ASE_OK && result != ASE_SUCCESS) {
        impl_->running.store(false, std::memory_order_release);
        impl_->driver.value->stop();
        Check(result, "ASIO start");
    }
    impl_->started = true;
    impl_->lastProgress = impl_->rendered.load(std::memory_order_acquire);
    impl_->lastProgressTick = GetTickCount64();
#endif
}
void AsioRenderer::Service(const InterleavedPcmQueue& queue, bool countStarvation, DWORD timeout) {
    if (!impl_->started) throw std::runtime_error("ASIO renderer must be started before servicing");
#ifdef SAL_ENABLE_ASIO
    impl_->countStarvation.store(countStarvation, std::memory_order_relaxed);
    impl_->Fill(queue);
    const auto result = WaitForSingleObject(impl_->event, std::min<DWORD>(timeout, 1000));
    if (result != WAIT_OBJECT_0 && result != WAIT_TIMEOUT) throw std::runtime_error("ASIO event wait failed");
    impl_->Fill(queue);
    const auto progress = impl_->rendered.load(std::memory_order_acquire);
    const auto now = GetTickCount64();
    if (progress != impl_->lastProgress) {
        impl_->lastProgress = progress;
        impl_->lastProgressTick = now;
    } else if (now - impl_->lastProgressTick > std::max<std::uint64_t>(
                   5000, static_cast<std::uint64_t>(impl_->bufferFrames) / 12)) {
        throw std::runtime_error("ASIO driver stopped delivering audio callbacks; reconnect the device and restart the bridge");
    }
#else
    (void)queue; (void)countStarvation; (void)timeout;
#endif
}
void AsioRenderer::DiscardConsumed(InterleavedPcmQueue& queue) const { queue.DiscardBefore(impl_->sourcePosition); }
std::uint64_t AsioRenderer::MinimumFramesAvailable(const InterleavedPcmQueue& queue) const {
    // Source already copied into the callback ring still counts as buffered audio.
    auto frames = queue.FramesAvailable(impl_->sourcePosition);
#ifdef SAL_ENABLE_ASIO
    frames += impl_->ring->Readable();
#endif
    return frames;
}
std::uint32_t AsioRenderer::MaximumBufferFrames() const {
#ifdef SAL_ENABLE_ASIO
    return static_cast<std::uint32_t>(impl_->ring->Capacity());
#else
    return 0;
#endif
}
bool AsioRenderer::IsDrained(const InterleavedPcmQueue& queue) const {
    return MinimumFramesAvailable(queue) == 0;
}
bool AsioRenderer::IsStarted() const { return impl_->started; }
void AsioRenderer::Stop() {
    if (!impl_ || impl_->stopped) return;
#ifdef SAL_ENABLE_ASIO
    if (impl_->started) {
        impl_->countStarvation.store(false, std::memory_order_relaxed);
        // IsDrained covers the software ring. Allow the last submitted hardware
        // block and the driver-reported output latency to reach the DAC too.
        const auto milliseconds = static_cast<DWORD>(std::ceil(
            (static_cast<double>(impl_->outputLatency) + impl_->bufferFrames * 2.0) / 48.0));
        Sleep(milliseconds);
        impl_->running.store(false, std::memory_order_release);
        const auto result = impl_->driver.value->stop();
        impl_->started = false;
        impl_->stopped = true;
        Check(result, "ASIO stop");
    }
#endif
    impl_->started = false;
    impl_->stopped = true;
}
std::vector<EndpointRenderStats> AsioRenderer::Stats() const {
    EndpointRenderStats stats;
    stats.routeName = impl_->layout.outputs.front().name;
    stats.endpointName = L"ASIO " + (impl_->layout.outputs.front().asioDriverName.empty() ? impl_->layout.outputs.front().asioDriver : impl_->layout.outputs.front().asioDriverName);
    stats.isMaster = true;
#ifdef SAL_ENABLE_ASIO
    stats.starvationFrames = impl_->starvation.load();
    stats.clockSeconds = static_cast<double>(impl_->rendered.load()) / 48'000.0;
    stats.bufferFrames = static_cast<std::uint32_t>(impl_->bufferFrames);
    stats.bufferMilliseconds = impl_->bufferFrames / 48.0;
    stats.streamLatencyMilliseconds = impl_->outputLatency / 48.0;
    stats.defaultPeriodFrames = stats.minimumPeriodFrames = stats.selectedPeriodFrames = stats.bufferFrames;
#endif
    return {stats};
}
} // namespace dolby
