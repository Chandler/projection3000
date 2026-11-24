#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <string_view>

// Mapping footprints specify pixel density, not the composition's aspect.
// Keep the full canvas until the mapping pass applies per-rect fit/crop.
inline std::array<int, 2> mapping_bus_size(
    std::array<int, 2> demand, int canvas_width, int canvas_height) {
    const double scale = std::max(
        static_cast<double>(demand[0]) / canvas_width,
        static_cast<double>(demand[1]) / canvas_height);
    return {
        std::max(1, static_cast<int>(std::ceil(canvas_width * scale))),
        std::max(1, static_cast<int>(std::ceil(canvas_height * scale))),
    };
}

inline std::array<float, 2> mapping_content_scale(
    std::string_view fit, float source_aspect, float box_width,
    float box_height) {
    const float ratio = source_aspect * box_height / box_width;
    if (fit == "fit") {
        return ratio >= 1 ? std::array<float, 2>{1, 1 / ratio}
                          : std::array<float, 2>{ratio, 1};
    }
    if (fit == "fill") {
        return ratio >= 1 ? std::array<float, 2>{ratio, 1}
                          : std::array<float, 2>{1, 1 / ratio};
    }
    return {1, 1};
}
