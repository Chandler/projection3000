#include "native_audio.hpp"

#include <SDL2/SDL.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

void write_u16(std::ofstream &stream, std::uint16_t value) {
    stream.put(static_cast<char>(value & 0xff));
    stream.put(static_cast<char>((value >> 8) & 0xff));
}

void write_u32(std::ofstream &stream, std::uint32_t value) {
    write_u16(stream, static_cast<std::uint16_t>(value & 0xffff));
    write_u16(stream, static_cast<std::uint16_t>(value >> 16));
}

void write_wav(const std::filesystem::path &path) {
    constexpr std::uint32_t rate = 48000;
    constexpr std::uint16_t channels = 2;
    constexpr std::uint16_t sample_bytes = 2;
    constexpr std::uint32_t seconds = 10;
    constexpr std::uint32_t samples = rate * seconds;
    constexpr std::uint32_t data_bytes =
        samples * channels * sample_bytes;
    std::ofstream stream(path, std::ios::binary);
    stream.write("RIFF", 4);
    write_u32(stream, 36 + data_bytes);
    stream.write("WAVEfmt ", 8);
    write_u32(stream, 16);
    write_u16(stream, 1);
    write_u16(stream, channels);
    write_u32(stream, rate);
    write_u32(stream, rate * channels * sample_bytes);
    write_u16(stream, channels * sample_bytes);
    write_u16(stream, sample_bytes * 8);
    stream.write("data", 4);
    write_u32(stream, data_bytes);
    for (std::uint32_t index = 0; index < samples; ++index) {
        const auto sample = static_cast<std::int16_t>(
            std::sin(index * 2.0 * 3.141592653589793 * 440.0 / rate)
            * 12000.0);
        for (int channel = 0; channel < channels; ++channel) {
            write_u16(stream, static_cast<std::uint16_t>(sample));
        }
    }
}

NativeScene scene_for(const std::filesystem::path &path) {
    NativeScene scene;
    scene.outputs = {"program"};
    NativeLayer layer;
    layer.id = 1;
    layer.source_id = "movie";
    layer.generator = "video";
    layer.resolved_file = path.string();
    layer.params = {
        {"audio_enabled", true}, {"audio_gain", 0.0},
        {"playing", true}, {"speed", 1.0},
        {"loop_start", 0.0}, {"loop_end", 1.0},
        {"position", 0.0}, {"seek_nonce", 0.0},
    };
    scene.buses["program"].layers.push_back(std::move(layer));
    return scene;
}

double wait_for_clock(NativeAudioEngine &audio, double timeout = 3.0) {
    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::duration<double>(timeout);
    while (std::chrono::steady_clock::now() < deadline) {
        if (const auto clock = audio.playhead_for("movie")) return *clock;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    throw std::runtime_error("audio clock did not become ready: "
                             + audio.stats());
}

void require_near(
    const std::string &label, double actual, double expected,
    double tolerance) {
    if (std::abs(actual - expected) <= tolerance) return;
    throw std::runtime_error(
        label + ": expected " + std::to_string(expected)
        + ", got " + std::to_string(actual));
}

}  // namespace

int main() {
    const auto path = std::filesystem::temp_directory_path()
        / "vibe-native-audio-clock-test.wav";
    try {
        write_wav(path);
        const auto parsed = parse_native_scene({
            {"type", "renderer_state"},
            {"mix", {{"sync", {{"clock", 100.0}, {"video", -25.0}}}}},
        });
        if (!parsed) throw std::runtime_error("native scene did not parse");
        require_near(
            "video sync parsing", parsed->mix.video_shift_seconds,
            0.075, 0.000001);
        {
        NativeAudioEngine audio;
        if(SDL_WasInit(SDL_INIT_AUDIO))throw std::runtime_error("Idle audio engine opened the audio subsystem");
        NativeScene scene = scene_for(path);
        audio.apply_scene(scene);
        const double start = wait_for_clock(audio);
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        const double after = wait_for_clock(audio);
        require_near("1x slope", after - start, 0.5, 0.06);

        audio.suspend_output();
        const double suspended = wait_for_clock(audio);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        require_near(
            "display transition suspend",
            wait_for_clock(audio) - suspended, 0.0, 0.02);
        audio.resume_output();
        const double after_suspend = wait_for_clock(audio);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        require_near(
            "display transition resume",
            wait_for_clock(audio) - after_suspend, 0.3, 0.05);

        scene.buses["program"].layers[0].params["playing"] = false;
        audio.apply_scene(scene);
        const double paused = wait_for_clock(audio);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        require_near("pause", wait_for_clock(audio) - paused, 0.0, 0.02);

        scene.buses["program"].layers[0].params["playing"] = true;
        audio.apply_scene(scene);
        const double resumed = wait_for_clock(audio);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        require_near(
            "resume", wait_for_clock(audio) - resumed, 0.3, 0.05);

        auto &params = scene.buses["program"].layers[0].params;
        params["position"] = 0.5;
        params["seek_nonce"] = 1.0;
        audio.apply_scene(scene);
        require_near("seek", wait_for_clock(audio), 5.0, 0.08);

        const double before_gain = wait_for_clock(audio);
        params["audio_gain"] = 0.5;
        audio.apply_scene(scene);
        require_near(
            "gain continuity", wait_for_clock(audio), before_gain, 0.03);

        const double before_speed = wait_for_clock(audio);
        params["speed"] = 2.0;
        audio.apply_scene(scene);
        const double fast = wait_for_clock(audio);
        require_near("speed continuity", fast, before_speed, 0.08);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        require_near(
            "2x slope", wait_for_clock(audio) - fast, 0.6, 0.09);

        params["speed"] = 1.0;
        params["loop_start"] = 0.2;
        params["loop_end"] = 0.3;
        params["position"] = 0.95;
        params["seek_nonce"] = 3.0;
        audio.apply_scene(scene);
        std::this_thread::sleep_for(std::chrono::milliseconds(700));
        const double looped = wait_for_clock(audio);
        if (looped < 2.0 || looped > 3.0) {
            throw std::runtime_error(
                "loop clock escaped bounds: " + std::to_string(looped));
        }
        params["loop_mode"] = "ping-pong";
        audio.apply_scene(scene);
        if(SDL_WasInit(SDL_INIT_AUDIO))throw std::runtime_error("Disabled audio retained the audio subsystem");
        if (audio.owns_source("movie")) {
            throw std::runtime_error(
                "ping-pong video incorrectly retained audio output");
        }
        }
        SDL_Quit();
        std::filesystem::remove(path);
        std::cout << "native audio master clock: PASS\n";
        return 0;
    } catch (const std::exception &error) {
        SDL_Quit();
        std::filesystem::remove(path);
        std::cerr << "native audio master clock: FAIL: "
                  << error.what() << "\n";
        return 1;
    }
}
