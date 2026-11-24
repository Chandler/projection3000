#include "media_decoder.hpp"

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <vector>
#include <iostream>
#include <optional>
#include <string>
#include <thread>
#include <unistd.h>

namespace {

std::optional<DecodedVideoFrame> frame_at(
    MediaDecoder &decoder, double seconds) {
    decoder.request(seconds);
    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline) {
        if (const auto frame = decoder.latest();
            frame && frame->rgb
                && frame->seconds <= seconds + 0.01
                && seconds - frame->seconds <= 0.08) {
            return frame;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return std::nullopt;
}

}  // namespace

int main() {
    namespace fs = std::filesystem;
    const fs::path root = fs::temp_directory_path()
        / ("vibe-frame-cache-test-" + std::to_string(getpid()));
    const fs::path media = root / "motion.mp4";
    std::error_code ignored;
    fs::create_directories(root, ignored);
    if (ignored) return 1;
    const std::string command =
        "ffmpeg -nostdin -hide_banner -loglevel error -y "
        "-f lavfi -i testsrc2=s=160x90:r=30:d=2 "
        "-c:v libx264 -g 30 -pix_fmt yuv420p " + media.string();
    if (std::system(command.c_str()) != 0) {
        fs::remove_all(root, ignored);
        std::cerr << "failed to create video fixture\n";
        return 1;
    }

    bool passed = true;
    // VideoToolbox may enumerate MPEG-4 Part 2 but reject its actual decoder
    // session. get_format must accept FFmpeg's software retry rather than
    // returning AV_PIX_FMT_NONE and repeatedly decoding the file without frames.
    const auto legacy = root / "mpeg4.mp4";
    const auto legacy_command =
        "ffmpeg -nostdin -hide_banner -loglevel error -y "
        "-f lavfi -i testsrc2=s=96x64:r=12:d=2 "
        "-c:v mpeg4 -pix_fmt yuv420p " + legacy.string();
    if (std::system(legacy_command.c_str()) != 0) {
        passed = false;
    } else {
        MediaDecoder decoder(legacy.string(), 96, 64);
        if (!frame_at(decoder, 0) || !frame_at(decoder, 0.75)
            || !decoder.error().empty()) {
            std::cerr << "MPEG-4 hardware/software negotiation failed: "
                      << decoder.error() << "\n";
            passed = false;
        }
    }
    {
        MediaDecoder decoder(media.string(), 160, 90, {}, true);
        if (!frame_at(decoder, 0.0) || !frame_at(decoder, 1.9)) {
            std::cerr << "failed to fill ping-pong frame cache\n";
            passed = false;
        }
        if (passed) {
            for (const double seconds : {1.5, 1.0, 0.5, 0.1}) {
                if (!frame_at(decoder, seconds)) {
                    std::cerr << "reverse frame unavailable at "
                              << seconds << "\n";
                    passed = false;
                    break;
                }
            }
        }
    }
    // Compare the decoder to ffmpeg's autorotation for camera display tags.
    for (const int rotation : {0, 90, 180, 270}) {
        const auto rotated = root / ("rotated-" + std::to_string(rotation) + ".mp4");
        const auto reference = root / "reference.rgb";
        const auto prepare = "ffmpeg -nostdin -v error -y -display_rotation "
            + std::to_string(rotation) + " -i " + media.string()
            + " -c copy " + rotated.string();
        const auto export_frame = "ffmpeg -nostdin -v error -y -i " + rotated.string()
            + " -frames:v 1 -pix_fmt rgb24 -f rawvideo " + reference.string();
        if (std::system(prepare.c_str()) || std::system(export_frame.c_str())) {
            passed = false;
            break;
        }
        MediaDecoder decoder(rotated.string(), 160, 160);
        const auto frame = frame_at(decoder, 0);
        std::ifstream file(reference, std::ios::binary);
        const std::vector<unsigned char> expected{std::istreambuf_iterator<char>(file), {}};
        if (!frame || frame->width != (rotation % 180 ? 90 : 160)
            || frame->height != (rotation % 180 ? 160 : 90)
            || frame->rgb->size() != expected.size()) {
            std::cerr << "rotation dimensions failed: " << rotation << " actual " << (frame ? frame->width : 0) << "x" << (frame ? frame->height : 0) << " bytes " << expected.size() << "\n";
            passed = false;
            continue;
        }
        double error = 0;
        for (size_t i = 0; i < expected.size(); ++i)
            error += std::abs(int(expected[i]) - int((*frame->rgb)[i]));
        if (error / expected.size() > 5) {
            std::cerr << "rotation pixels differ from ffmpeg: " << rotation << "\n";
            passed = false;
        }
    }
    fs::remove_all(root, ignored);
    if (!passed) return 1;
    std::cout << "media decoder reverse cache: PASS\n";
    return 0;
}
