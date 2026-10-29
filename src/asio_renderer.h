#pragma once
#include "multi_endpoint_renderer.h"

namespace dolby {

struct AsioDriverDescriptor {
    std::wstring name;
    std::wstring clsid;
};
std::vector<AsioDriverDescriptor> EnumerateAsioDrivers();
struct AsioDeviceDescriptor {
    std::vector<std::wstring> outputNames;
    long minimumBufferFrames{}, maximumBufferFrames{}, preferredBufferFrames{}, bufferGranularity{};
    bool supports48k{};
};
AsioDeviceDescriptor InspectAsioDevice(std::wstring_view clsid);
void PrintAsioChannels(std::wstring_view clsid);

// One ASIO driver owns the clock for the entire selected layout. Existing
// WASAPI profiles keep using MultiEndpointRenderer's multi-device engine.
class AsioRenderer {
public:
    AsioRenderer(const SpeakerLayout& layout, double gain);
    ~AsioRenderer();
    void Prime(const InterleavedPcmQueue& queue);
    void Start();
    void Service(const InterleavedPcmQueue& queue, bool countStarvation, DWORD timeout);
    void DiscardConsumed(InterleavedPcmQueue& queue) const;
    std::uint64_t MinimumFramesAvailable(const InterleavedPcmQueue& queue) const;
    std::uint32_t MaximumBufferFrames() const;
    bool IsDrained(const InterleavedPcmQueue& queue) const;
    bool IsStarted() const;
    void Stop();
    std::vector<EndpointRenderStats> Stats() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace dolby
