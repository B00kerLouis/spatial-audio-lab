#pragma once

// Portable audio primitives shared by the ASIO host and its tests.
#include <algorithm>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

namespace dolby::asio {

static_assert(std::atomic<std::uint64_t>::is_always_lock_free,
              "ASIO callbacks require lock-free frame counters (build x64)");

// Single producer (render service), single consumer (ASIO callback). All storage
// is allocated before start. Positions count frames, never individual samples.
class FrameRing {
public:
    FrameRing(std::size_t channels, std::size_t frames)
        : channels_(channels), capacity_(frames) {
        if (!channels || !frames || frames > std::numeric_limits<std::size_t>::max() / channels)
            throw std::invalid_argument("Invalid ASIO ring dimensions");
        samples_.resize(channels * frames);
    }
    std::size_t Writable() const noexcept {
        return capacity_ - static_cast<std::size_t>(
            write_.load(std::memory_order_relaxed) - read_.load(std::memory_order_acquire));
    }
    std::size_t Readable() const noexcept {
        return static_cast<std::size_t>(
            write_.load(std::memory_order_acquire) - read_.load(std::memory_order_relaxed));
    }
    // Write one complete frame, publish only after all channels are populated.
    void Push(const float* frame) noexcept {
        const auto position = write_.load(std::memory_order_relaxed);
        std::copy_n(frame, channels_, samples_.data() + (position % capacity_) * channels_);
        write_.store(position + 1, std::memory_order_release);
    }
    bool Pop(float* frame) noexcept {
        const auto position = read_.load(std::memory_order_relaxed);
        if (position == write_.load(std::memory_order_acquire)) return false;
        std::copy_n(samples_.data() + (position % capacity_) * channels_, channels_, frame);
        read_.store(position + 1, std::memory_order_release);
        return true;
    }
    std::size_t Capacity() const noexcept { return capacity_; }

private:
    std::size_t channels_, capacity_;
    std::vector<float> samples_;
    alignas(64) std::atomic<std::uint64_t> write_{};
    alignas(64) std::atomic<std::uint64_t> read_{};
};

struct SampleFormat {
    unsigned bytes;
    unsigned validBits; // zero for IEEE float
    bool bigEndian;
};

// ASIOSampleType numeric values are defined by the ASIO interface. DSD is
// deliberately rejected: this pipeline produces PCM, not a DSD bitstream.
inline SampleFormat Format(long type) {
    switch (type) {
    case 0: return {2, 16, true};
    case 1: return {3, 24, true};
    case 2: return {4, 32, true};
    case 3: return {4, 0, true};
    case 4: return {8, 0, true};
    case 8: return {4, 16, true};
    case 9: return {4, 18, true};
    case 10: return {4, 20, true};
    case 11: return {4, 24, true};
    case 16: return {2, 16, false};
    case 17: return {3, 24, false};
    case 18: return {4, 32, false};
    case 19: return {4, 0, false};
    case 20: return {8, 0, false};
    case 24: return {4, 16, false};
    case 25: return {4, 18, false};
    case 26: return {4, 20, false};
    case 27: return {4, 24, false};
    default: throw std::invalid_argument("ASIO channel has an unsupported PCM/DSD sample type");
    }
}

inline void WriteSample(void* destination, SampleFormat format, float input) noexcept {
    const double value = std::isfinite(input) ? std::clamp<double>(input, -1.0, 1.0) : 0.0;
    std::uint64_t bits;
    if (!format.validBits) {
        bits = format.bytes == 4
            ? std::bit_cast<std::uint32_t>(static_cast<float>(value))
            : std::bit_cast<std::uint64_t>(value);
    } else {
        const auto scale = std::uint64_t{1} << (format.validBits - 1);
        const auto sample = static_cast<std::int64_t>(std::clamp(
            std::round(value * static_cast<double>(scale)),
            -static_cast<double>(scale), static_cast<double>(scale - 1)));
        // ASIO Int32{MSB,LSB}{16,18,20,24} is a sign-extended, right-aligned
        // integer in a 32-bit container (not a left-justified WAVE valid-bits field).
        bits = static_cast<std::uint64_t>(sample);
    }
    auto* bytes = static_cast<unsigned char*>(destination);
    for (unsigned byte = 0; byte < format.bytes; ++byte) {
        const unsigned target = format.bigEndian ? format.bytes - byte - 1 : byte;
        bytes[target] = static_cast<unsigned char>(bits >> (byte * 8));
    }
}

inline long SelectBufferSize(long minimum, long maximum, long preferred,
                             long granularity, long requested) {
    const long size = requested ? requested : preferred;
    if (minimum <= 0 || maximum < minimum || size < minimum || size > maximum)
        throw std::invalid_argument("ASIO buffer size is outside the driver range");
    if ((granularity == -1 && (static_cast<unsigned long>(size) &
                              (static_cast<unsigned long>(size) - 1))) ||
        (granularity > 0 && (size - minimum) % granularity) || granularity < -1)
        throw std::invalid_argument("ASIO buffer size does not match driver granularity");
    return size;
}

inline std::vector<long> MapChannels(std::size_t speakers,
                                     const std::vector<long>& configured,
                                     long available) {
    if (!speakers || available <= 0 || speakers > static_cast<std::size_t>(available))
        throw std::invalid_argument("ASIO driver has too few output channels");
    std::vector<long> result = configured;
    if (result.empty()) {
        result.resize(speakers);
        for (std::size_t channel = 0; channel < speakers; ++channel)
            result[channel] = static_cast<long>(channel);
    }
    if (result.size() != speakers)
        throw std::invalid_argument("ASIO channel mapping must match the route speaker count");
    auto sorted = result;
    std::sort(sorted.begin(), sorted.end());
    if (sorted.front() < 0 || sorted.back() >= available ||
        std::adjacent_find(sorted.begin(), sorted.end()) != sorted.end())
        throw std::invalid_argument("ASIO channel mapping contains a duplicate or unavailable output");
    return result;
}

} // namespace dolby::asio
