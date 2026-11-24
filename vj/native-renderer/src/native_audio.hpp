#pragma once

#include "native_scene.hpp"

#include <SDL2/SDL.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

class NativeAudioEngine {
public:
    NativeAudioEngine();
    ~NativeAudioEngine();

    NativeAudioEngine(const NativeAudioEngine &) = delete;
    NativeAudioEngine &operator=(const NativeAudioEngine &) = delete;

    void apply_scene(const NativeScene &scene);
    void suspend_output();
    void resume_output();
    bool owns_source(const std::string &source_id) const;
    std::optional<double> playhead_for(
        const std::string &source_id) const;
    std::string stats() const;

private:
    struct Request {
        std::string source_id;
        std::string path;
        bool playing = true;
        double speed = 1.0;
        double loop_start = 0.0;
        double loop_end = 1.0;
        double position = 0.0;
        double seek_nonce = 0.0;
        double gain = 1.0;
        std::optional<double> start_seconds;
    };

    bool open_output();
    void close_output();
    bool audio_initialized_ = false;

    static std::optional<Request> select_request(const NativeScene &scene);
    static bool same_timeline(const Request &left, const Request &right);
    void start(Request request);
    void stop();
    void run(Request request);
    void set_error(std::string message);

    SDL_AudioDeviceID device_ = 0;
    SDL_AudioSpec device_spec_{};
    std::uint64_t bytes_per_second_ = 0;
    mutable std::mutex mutex_;
    std::optional<Request> request_;
    std::string error_;
    std::string backend_ = "disabled";
    std::thread thread_;
    std::atomic<bool> stop_requested_{false};
    std::atomic<bool> ready_{false};
    std::atomic<bool> playing_{false};
    std::atomic<bool> suspended_{false};
    std::atomic<double> speed_{1.0};
    std::atomic<double> gain_{1.0};
    std::atomic<double> initial_position_{0.0};
    std::atomic<double> loop_start_seconds_{0.0};
    std::atomic<double> loop_end_seconds_{0.0};
    std::atomic<double> queued_media_seconds_{0.0};
};
