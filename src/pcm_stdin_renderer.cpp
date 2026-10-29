#include "commands.h"
#include "layout_mix.h"
#include "multi_endpoint_renderer.h"
#include <Windows.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

namespace dolby {
void RenderPcmStdin(const std::filesystem::path& layoutPath, double gain, bool validateOnly) {
    if (!std::isfinite(gain) || gain < 0 || gain > 1) throw std::invalid_argument("输出增益必须为 0 到 1");
    const auto layout = LoadSpeakerLayout(layoutPath);
    const auto mix = BuildCanonical714Mix(layout);
    const auto input = GetStdHandle(STD_INPUT_HANDLE);
    const auto type = GetFileType(input);
    if (type != FILE_TYPE_PIPE && type != FILE_TYPE_DISK)
        throw std::runtime_error("PCM 输入必须为管道或文件：48 kHz，12 声道，Float32 小端");
    std::unique_ptr<MultiEndpointRenderer> renderer;
    if (!validateOnly) renderer = std::make_unique<MultiEndpointRenderer>(layout, gain, RendererLatencyMode::Balanced);
    InterleavedPcmQueue queue(layout.speakers.size());
    std::vector<unsigned char> carry;
    std::array<unsigned char, 24 * 1024> bytes{};
    std::vector<double> peaks(layout.speakers.size());
    std::uint64_t submitted = 0;
    bool eof = false;
    constexpr std::size_t frameBytes = 12 * sizeof(float);
    auto nextReport = std::chrono::steady_clock::now();
    std::cout << "{\"event\":\"ready\",\"sampleRate\":48000,\"sourceChannels\":12,\"sampleFormat\":\"f32le\",\"prebufferFrames\":" << (renderer ? std::max<std::uint32_t>(960, renderer->MaximumBufferFrames()) : 0) << "}\n" << std::flush;
    const auto report = [&](std::uint64_t played, const char* event) {
        std::cout << "{\"event\":\"" << event << "\",\"playedFrames\":" << played
                  << ",\"submittedFrames\":" << submitted << ",\"channels\":" << layout.speakers.size()
                  << ",\"clockKind\":\"rendered_pcm_estimate\",\"peaks\":[";
        for (std::size_t channel = 0; channel < peaks.size(); ++channel) {
            if (channel) std::cout << ',';
            std::cout << peaks[channel];
        }
        std::cout << "]}\n" << std::flush;
    };
    for (;;) {
        if (!eof && (!renderer || renderer->MinimumFramesAvailable(queue) < 96'000)) {
            DWORD available = static_cast<DWORD>(bytes.size());
            if (type == FILE_TYPE_PIPE && !PeekNamedPipe(input, nullptr, 0, nullptr, &available, nullptr)) {
                const auto error = GetLastError();
                if (error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED) eof = true;
                else throw std::runtime_error("无法读取 Cinema PCM 管道");
            }
            if (!eof && available) {
                DWORD count = 0;
                if (!ReadFile(input, bytes.data(), std::min<DWORD>(available, static_cast<DWORD>(bytes.size())), &count, nullptr)) {
                    if (GetLastError() == ERROR_BROKEN_PIPE) eof = true;
                    else throw std::runtime_error("读取 PCM 数据失败");
                } else if (!count) eof = true;
                if (count) carry.insert(carry.end(), bytes.begin(), bytes.begin() + count);
            }
            const auto frames = carry.size() / frameBytes;
            if (frames) {
                std::vector<float> mapped(frames * layout.speakers.size());
                for (std::size_t frame = 0; frame < frames; ++frame) {
                    std::array<float, 12> source{};
                    std::memcpy(source.data(), carry.data() + frame * frameBytes, frameBytes);
                    auto target = std::span<float>(mapped.data() + frame * layout.speakers.size(), layout.speakers.size());
                    MixCanonical714Frame(source, mix, target);
                    for (std::size_t channel = 0; channel < target.size(); ++channel)
                        peaks[channel] = std::max(peaks[channel], std::abs(static_cast<double>(target[channel]) * gain));
                }
                submitted += frames;
                carry.erase(carry.begin(), carry.begin() + static_cast<std::ptrdiff_t>(frames * frameBytes));
                if (renderer) queue.AppendFloat(std::move(mapped));
            }
        }
        if (eof && !carry.empty()) throw std::runtime_error("PCM 管道结尾存在不完整的声道帧");
        if (renderer) {
            const auto buffered = renderer->MinimumFramesAvailable(queue);
            if (!renderer->IsStarted() && buffered && (eof || buffered >= std::max<std::uint64_t>(960, renderer->MaximumBufferFrames())))
                renderer->PrimeAndStart(queue);
            if (renderer->IsStarted()) {
                renderer->Service(queue, !eof, 2);
                renderer->DiscardConsumed(queue);
            } else Sleep(2);
            const auto now = std::chrono::steady_clock::now();
            if (now >= nextReport) {
                const auto remaining = renderer->MinimumFramesAvailable(queue);
                const auto stats = renderer->Stats();
                double latency = 0;
                for (const auto& item : stats) latency = std::max(latency, item.streamLatencyMilliseconds + item.bufferMilliseconds);
                const auto consumed = submitted > remaining ? submitted - remaining : 0;
                const auto delay = static_cast<std::uint64_t>(std::ceil(latency * 48.0));
                report(consumed > delay ? consumed - delay : 0, "clock");
                nextReport = now + std::chrono::milliseconds(20);
            }
            if (eof && (!renderer->IsStarted() || renderer->IsDrained(queue))) break;
        } else if (eof) break;
        else if (type == FILE_TYPE_PIPE) Sleep(2);
    }
    if (!submitted) throw std::runtime_error("没有收到可播放的 PCM 帧");
    if (renderer) renderer->Stop();
    report(submitted, "done");
}
} // namespace dolby
