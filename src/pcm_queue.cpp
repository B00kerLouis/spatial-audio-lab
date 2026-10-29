#include "multi_endpoint_renderer.h"
#include <algorithm>
#include <cmath>
#include <iterator>
#include <stdexcept>

namespace dolby {
InterleavedPcmQueue::InterleavedPcmQueue(const std::size_t channels) : channels_(channels) {
    if (channels == 0) throw std::invalid_argument("Invalid PCM channel count");
}
void InterleavedPcmQueue::Append(std::vector<std::int16_t>&& samples) {
    if (samples.size() % channels_ != 0) {
        throw std::runtime_error("PCM producer returned an incomplete interleaved frame");
    }
    samples_.insert(samples_.end(),
                    std::make_move_iterator(samples.begin()),
                    std::make_move_iterator(samples.end()));
}

std::uint64_t InterleavedPcmQueue::EndFrame() const {
    return baseFrame_ + samples_.size() / channels_;
}
std::uint64_t InterleavedPcmQueue::FramesAvailable(const double sourcePosition) const {
    const double clamped = std::max(0.0, sourcePosition);
    const std::uint64_t first = static_cast<std::uint64_t>(std::floor(clamped));
    return first < EndFrame() ? EndFrame() - first : 0;
}
double InterleavedPcmQueue::Sample(const std::uint64_t frame, const std::size_t channel) const {
    if (frame < baseFrame_ || frame >= EndFrame() || channel >= channels_) return 0.0;
    return static_cast<double>(samples_[(frame - baseFrame_) * channels_ + channel]) / 32768.0;
}
void InterleavedPcmQueue::DiscardBefore(const double sourcePosition) {
    if (sourcePosition <= static_cast<double>(baseFrame_)) return;
    std::uint64_t frame = static_cast<std::uint64_t>(std::floor(sourcePosition));
    if (frame > 1) --frame;
    frame = std::min(frame, EndFrame());
    const std::uint64_t discardFrames = frame > baseFrame_ ? frame - baseFrame_ : 0;
    if (discardFrames < 4'800 && discardFrames != samples_.size() / channels_) return;
    const std::size_t discardSamples = static_cast<std::size_t>(discardFrames * channels_);
    samples_.erase(samples_.begin(), samples_.begin() + discardSamples);
    baseFrame_ += discardFrames;
}
} // namespace dolby
