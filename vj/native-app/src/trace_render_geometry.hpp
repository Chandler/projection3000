#pragma once
#include <nlohmann/json.hpp>
#include <cstdint>
#include <vector>
namespace vj {
struct TraceGpuVertex {
    float position[2],local[3],core[4],glow[4],widths[4];
};
// Original normalized arc-length pixel topology, expanded to analytic line quads.
// RGB is one triplet per pixel. Missing cells are black. No graphics API calls.
std::vector<TraceGpuVertex> traceRenderGeometry(const nlohmann::json& trace,
    const std::vector<std::uint8_t>& rgb,int width,int height,int rotation);
}
