#include "asio_audio.h"

#include <array>
#include <iostream>
#include <numeric>
#include <thread>

namespace {
void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
template<class Function> void Reject(Function fn) {
    bool rejected = false;
    try { fn(); } catch (const std::exception&) { rejected = true; }
    Require(rejected, "Invalid configuration was accepted");
}
void SampleFormats() {
    using namespace dolby::asio;
    struct Vector { long type; float value; std::vector<unsigned char> bytes; };
    const std::vector<Vector> vectors = {
        {16, -1.0f, {0x00,0x80}}, {0, 1.0f, {0x7f,0xff}},
        {17, -1.0f, {0x00,0x00,0x80}}, {1, 1.0f, {0x7f,0xff,0xff}},
        {18, -1.0f, {0x00,0x00,0x00,0x80}}, {2, 1.0f, {0x7f,0xff,0xff,0xff}},
        {19, 0.5f, {0,0,0,0x3f}}, {3, -0.5f, {0xbf,0,0,0}},
        {20, 0.5f, {0,0,0,0,0,0,0xe0,0x3f}}, {4, -0.5f, {0xbf,0xe0,0,0,0,0,0,0}},
        {24, -1.0f, {0,0x80,0xff,0xff}}, {8, 1.0f, {0,0,0x7f,0xff}},
        {25, -1.0f, {0,0,0xfe,0xff}}, {9, 1.0f, {0,1,0xff,0xff}},
        {26, -1.0f, {0,0,0xf8,0xff}}, {10, 1.0f, {0,7,0xff,0xff}},
        {27, -1.0f, {0,0,0x80,0xff}}, {11, 1.0f, {0,0x7f,0xff,0xff}},
        {16, 2.0f, {0xff,0x7f}}, {16, -2.0f, {0,0x80}},
    };
    for (const auto& test : vectors) {
        std::array<unsigned char, 10> buffer;
        buffer.fill(0xaa);
        WriteSample(buffer.data() + 1, Format(test.type), test.value);
        Require(buffer[0] == 0xaa && buffer[test.bytes.size()+1] == 0xaa,
                "Sample conversion overwrote its destination");
        Require(std::equal(test.bytes.begin(), test.bytes.end(), buffer.begin()+1),
                "Sample conversion produced incorrect bytes");
        for (float bad : {std::numeric_limits<float>::quiet_NaN(),
                          std::numeric_limits<float>::infinity()}) {
            WriteSample(buffer.data()+1, Format(test.type), bad);
            Require(std::all_of(buffer.begin()+1, buffer.begin()+1+test.bytes.size(),
                               [](auto byte) { return byte == 0; }), "Non-finite input was not silenced");
        }
    }
    for (long type : {5, 15, 21, 32, 33, 40, -1}) Reject([&] { Format(type); });
}
void MappingAndPeriods() {
    using namespace dolby::asio;
    const auto channels = MapChannels(128, {}, 128);
    Require(channels.size() == 128 && channels.back() == 127, "128-channel mapping was truncated");
    Require(MapChannels(4, {127,63,32,8}, 128) == std::vector<long>({127,63,32,8}),
            "Sparse channel mapping changed order");
    Reject([] { MapChannels(2, {1,1}, 128); });
    Reject([] { MapChannels(2, {0,128}, 128); });
    Reject([] { MapChannels(2, {-1,0}, 128); });
    Reject([] { MapChannels(3, {0,1}, 128); });
    Reject([] { MapChannels(129, {}, 128); });
    Reject([] { MapChannels(0, {}, 128); });
    Require(SelectBufferSize(32, 1024, 256, -1, 0) == 256, "Preferred ASIO period ignored");
    Require(SelectBufferSize(32, 1024, 256, -1, 512) == 512, "Power-of-two period rejected");
    Require(SelectBufferSize(64, 512, 128, 32, 160) == 160, "Stepped period rejected");
    Require(SelectBufferSize(64, 512, 128, 0, 117) == 117, "Continuous period rejected");
    Require(SelectBufferSize(128, 128, 128, 0, 0) == 128, "Fixed period rejected");
    Reject([] { SelectBufferSize(64, 512, 128, -1, 100); });
    Reject([] { SelectBufferSize(64, 512, 128, 32, 100); });
    Reject([] { SelectBufferSize(64, 512, 128, 0, 1024); });
    Reject([] { SelectBufferSize(128, 128, 128, 0, 64); });
    Reject([] { SelectBufferSize(0, 512, 128, 0, 0); });
    Reject([] { SelectBufferSize(64, 512, 128, -2, 0); });
}
void RingConcurrency() {
    using namespace dolby::asio;
    Reject([] { FrameRing ring(0, 1); });
    Reject([] { FrameRing ring(1, 0); });
    Reject([] { FrameRing ring(2, std::numeric_limits<std::size_t>::max()); });
    constexpr std::size_t channels = 65, frames = 100'000;
    FrameRing ring(channels, 37); // Non-power-of-two capacity, many wraps.
    std::atomic<bool> failed{};
    std::thread producer([&] {
        std::array<float, channels> frame{};
        for (std::size_t index = 0; index < frames; ++index) {
            for (std::size_t channel = 0; channel < channels; ++channel)
                frame[channel] = static_cast<float>(index * channels + channel);
            while (!ring.Writable()) std::this_thread::yield();
            ring.Push(frame.data());
        }
    });
    std::array<float, channels> frame{};
    for (std::size_t index = 0; index < frames; ++index) {
        while (!ring.Pop(frame.data())) std::this_thread::yield();
        for (std::size_t channel = 0; channel < channels; ++channel)
            if (frame[channel] != static_cast<float>(index * channels + channel)) failed = true;
    }
    producer.join();
    Require(!failed && !ring.Readable() && ring.Writable() == ring.Capacity(),
            "Concurrent ASIO frames were reordered, mixed, lost or duplicated");
    Require(!ring.Pop(frame.data()), "Empty ring returned audio");
}
} // namespace
int main() {
    try {
        SampleFormats(); MappingAndPeriods(); RingConcurrency();
        std::cout << "ASIO audio tests passed (18 formats, 128 channels, 100000 concurrent frames)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
