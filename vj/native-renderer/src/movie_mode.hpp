#pragma once

#include "native_scene.hpp"

#include <cmath>
#include <optional>
#include <string>

inline bool cinema_frame_rate(double fps) {
    constexpr double ntsc_film = 24000.0 / 1001.0;
    return std::isfinite(fps)
        && (std::abs(fps - ntsc_film) <= 0.02
            || std::abs(fps - 24.0) <= 0.02);
}

inline std::optional<std::string> movie_mode_source(
    const NativeScene &scene) {
    if (!scene.mix.movie_mode || scene.outputs.size() != 1) {
        return std::nullopt;
    }
    const auto bus = scene.buses.find(scene.outputs.front());
    if (bus == scene.buses.end()) return std::nullopt;

    const NativeLayer *visible = nullptr;
    for (const auto &layer : bus->second.layers) {
        if (!layer.enabled || layer.opacity <= 0.001f) continue;
        if (visible) return std::nullopt;
        visible = &layer;
    }
    if (!visible || visible->generator != "video"
        || visible->source_id.empty() || visible->resolved_file.empty()
        || visible->blend != "normal") {
        return std::nullopt;
    }
    const auto audio = visible->params.find("audio_enabled");
    if (audio == visible->params.end() || !audio->is_boolean()
        || !audio->get<bool>()) {
        return std::nullopt;
    }
    const auto speed = visible->params.find("speed");
    const double playback_speed = speed != visible->params.end()
            && speed->is_number()
        ? speed->get<double>() : 1.0;
    if (std::abs(playback_speed - 1.0) > 0.0001) return std::nullopt;
    const auto loop_mode = visible->params.find("loop_mode");
    if (loop_mode != visible->params.end() && loop_mode->is_string()
        && loop_mode->get<std::string>() == "ping-pong") {
        return std::nullopt;
    }
    return visible->source_id;
}
