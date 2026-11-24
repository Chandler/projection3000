#include "media_decoder.hpp"

extern "C" {
#include <libavfilter/avfilter.h>
}

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <string>
#include <thread>
#include <unistd.h>

namespace {

std::optional<DecodedVideoFrame> frame_at(MediaDecoder &decoder,
                                           double seconds) {
    decoder.request(seconds);
    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::seconds(8);
    while (std::chrono::steady_clock::now() < deadline) {
        if (const auto frame = decoder.latest();
            frame && frame->rgb
                && std::abs(frame->seconds - seconds) <= 0.1) {
            return frame;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return std::nullopt;
}

std::uint64_t brightness(const DecodedVideoFrame &frame) {
    std::uint64_t total = 0;
    for (const auto value : *frame.rgb) total += value;
    return total;
}

}  // namespace

int main() {
    // Some FFmpeg distributions ship libavfilter without compiling libass.
    // That is a supported production fallback, not a video-playback failure.
    if (!avfilter_get_by_name("ass")) return 77;
    namespace fs = std::filesystem;
    const fs::path root = fs::temp_directory_path()
        / ("vibe-subtitle-test-" + std::to_string(getpid()));
    const fs::path media = root / "black.mp4";
    const fs::path captions = root / "captions.ass";
    std::error_code ignored;
    fs::create_directories(root, ignored);
    if (ignored) return 1;
    {
        std::ofstream output(captions);
        output << "[Script Info]\n"
               << "ScriptType: v4.00+\nPlayResX: 320\nPlayResY: 180\n"
               << "[V4+ Styles]\n"
               << "Format: Name, Fontname, Fontsize, PrimaryColour, "
                  "SecondaryColour, OutlineColour, BackColour, Bold, "
                  "Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, "
                  "Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, "
                  "MarginR, MarginV, Encoding\n"
               << "Style: Default,Arial,32,&H00FFFFFF,&H000000FF,"
                  "&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,"
                  "10,10,20,1\n"
               << "[Events]\n"
               << "Format: Layer, Start, End, Style, Name, MarginL, MarginR, "
                  "MarginV, Effect, Text\n"
               << "Dialogue: 0,0:00:00.50,0:00:01.50,Default,,0,0,0,,SYNC\n";
    }
    const std::string command =
        "ffmpeg -nostdin -hide_banner -loglevel error -y "
        "-f lavfi -i color=c=black:s=320x180:r=24:d=2 "
        "-c:v libx264 -pix_fmt yuv420p " + media.string();
    if (std::system(command.c_str()) != 0) {
        fs::remove_all(root, ignored);
        std::cerr << "failed to create video fixture\n";
        return 1;
    }

    MediaDecoder plain(media.string(), 320, 180);
    MediaDecoder captioned(media.string(), 320, 180, captions.string());
    const auto captioned_before = frame_at(captioned, 0.25);
    const auto plain_frame = frame_at(plain, 1.0);
    const auto captioned_frame = frame_at(captioned, 1.0);
    const auto captioned_after_seek = frame_at(captioned, 0.25);
    if (!captioned_before || !plain_frame || !captioned_frame
        || !captioned_after_seek) {
        fs::remove_all(root, ignored);
        std::cerr << "decoder did not produce the requested media PTS\n";
        return 1;
    }
    if (std::abs(captioned.frame_rate() - 24.0) > 0.02) {
        fs::remove_all(root, ignored);
        std::cerr << "decoder reported wrong native frame rate: "
                  << captioned.frame_rate() << "\n";
        return 1;
    }
    const auto plain_brightness = brightness(*plain_frame);
    const auto before_brightness = brightness(*captioned_before);
    const auto captioned_brightness = brightness(*captioned_frame);
    const auto after_seek_brightness = brightness(*captioned_after_seek);
    fs::remove_all(root, ignored);
    if (before_brightness > plain_brightness + 10000) {
        std::cerr << "subtitle rendered before its media start PTS\n";
        return 1;
    }
    if (captioned_brightness <= plain_brightness + 100000) {
        std::cerr << "subtitle was not rendered at its active media PTS: plain="
                  << plain_brightness << " captioned=" << captioned_brightness
                  << " pts=" << captioned_frame->seconds
                  << " backend=" << captioned.backend() << "\n";
        return 1;
    }
    if (after_seek_brightness + 100000 >= captioned_brightness) {
        std::cerr << "subtitle remained visible after a backwards media seek: "
                  << "active=" << captioned_brightness
                  << " after=" << after_seek_brightness << "\n";
        return 1;
    }
    if (captioned.backend().find("+ass") == std::string::npos) {
        std::cerr << "subtitle filter did not become active\n";
        return 1;
    }
    return 0;
}
