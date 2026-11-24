#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

struct DecodedVideoFrame {
    int width = 0;
    int height = 0;
    int stride = 0;
    double seconds = 0.0;
    std::uint64_t sequence = 0;
    std::shared_ptr<const std::vector<std::uint8_t>> rgb;
};

class MediaDecoder {
public:
    MediaDecoder(std::string path, int output_width, int output_height,
                 std::string subtitle_asset = {},
                 bool cache_frames = false);
    ~MediaDecoder();

    MediaDecoder(const MediaDecoder &) = delete;
    MediaDecoder &operator=(const MediaDecoder &) = delete;

    void request(double seconds);
    std::optional<DecodedVideoFrame> latest() const;
    double duration() const;
    double frame_rate() const;
    std::string backend() const;
    std::string error() const;

private:
    void run();

    std::string path_;
    std::string subtitle_asset_;
    bool cache_frames_;
    int output_width_;
    int output_height_;
    std::atomic<double> requested_seconds_{0.0};
    std::atomic<double> duration_{0.0};
    std::atomic<double> frame_rate_{0.0};
    std::atomic<bool> stop_{false};
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    std::optional<DecodedVideoFrame> latest_;
    std::string backend_ = "opening";
    std::string error_;
    std::thread thread_;
};
