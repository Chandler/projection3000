#pragma once

#include "media_decoder.hpp"

// A latest-frame live input, independent of the file playback clock. Capture
// owns its resources on a worker; releasing a layer never waits on camera I/O.
class LiveCapture {
public:
#ifdef __APPLE__
    static constexpr const char *platform_format = "avfoundation";
#else
    static constexpr const char *platform_format = "v4l2";
#endif
    explicit LiveCapture(std::string device, std::string format = platform_format);
    ~LiveCapture();
    LiveCapture(const LiveCapture &) = delete;
    LiveCapture &operator=(const LiveCapture &) = delete;
    std::optional<DecodedVideoFrame> latest() const;
    std::string error() const;

private:
    struct State;
    std::shared_ptr<State> state_;
    static void run(const std::shared_ptr<State> &state);
};
