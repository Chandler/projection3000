#include "live_capture.hpp"

#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

using namespace std::chrono_literals;
using Clock = std::chrono::steady_clock;

static DecodedVideoFrame await_frame(LiveCapture &capture, std::uint64_t after = 0) {
    const auto deadline = Clock::now() + 5s;
    while (Clock::now() < deadline) {
        if (auto frame = capture.latest(); frame && frame->sequence > after)
            return *frame;
        std::this_thread::sleep_for(10ms);
    }
    throw std::runtime_error("No live frame: " + capture.error());
}

int main(int argc, char **argv) {
    try {
        // Explicit manual smoke test; CTest never opens a physical camera.
        if (argc == 3 && std::string(argv[1]) == "--device") {
            LiveCapture camera(argv[2]);
            const auto first = await_frame(camera);
            const auto next = await_frame(camera, first.sequence + 10);
            std::cout << LiveCapture::platform_format << " captured "
                      << next.width << 'x' << next.height << " frame "
                      << next.sequence << '\n';
            return 0;
        }
        LiveCapture capture("testsrc2=size=160x90:rate=30,realtime", "lavfi");
        const auto first = await_frame(capture);
        const auto next = await_frame(capture, first.sequence + 3);
        if (!next.rgb || next.rgb->size() != 160 * 90 * 3
            || next.width != 160 || next.height != 90
            || next.seconds <= first.seconds || *next.rgb == *first.rgb)
            throw std::runtime_error("Live RGB frames did not advance");
        if (!capture.error().empty()) throw std::runtime_error(capture.error());

        // A library thumbnail and a launched layer share one capture and frame.
        {LiveCapture preview("testsrc2=size=160x90:rate=30,realtime", "lavfi");
         const auto shared=preview.latest();
         if(!shared || shared->sequence<next.sequence || shared->rgb!=capture.latest()->rgb)
             throw std::runtime_error("Preview opened a duplicate camera capture");}
        await_frame(capture,next.sequence+2); // Closing the preview keeps the layer alive.

        // Missing/disconnected inputs cannot block construction or teardown.
        const auto before = Clock::now();
        {
            LiveCapture missing("ignored", "no-such-camera-backend");
            const auto deadline = Clock::now() + 1s;
            while (missing.error() == "Opening camera" && Clock::now() < deadline)
                std::this_thread::sleep_for(5ms);
            if (missing.latest() || missing.error().empty())
                throw std::runtime_error("Missing input did not report failure");
        }
        if (Clock::now() - before > 1500ms)
            throw std::runtime_error("Missing camera blocked teardown");

        // EOF/reconnect must clear the previous picture and keep sequences
        // monotonic so a recovered stream gets uploaded to the existing GL texture.
        LiveCapture finite("testsrc2=size=64x48:rate=30:duration=0.4,realtime", "lavfi");
        const auto start = await_frame(finite);
        const auto deadline = Clock::now() + 3s;
        bool cleared = false;
        while (Clock::now() < deadline) {
            if (!finite.latest() && !finite.error().empty()) { cleared = true; break; }
            std::this_thread::sleep_for(10ms);
        }
        if (!cleared) throw std::runtime_error("Ended camera retained a stale frame");
        await_frame(finite, start.sequence);
        std::cout << "Live capture frames, disconnect, reconnect and teardown passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
