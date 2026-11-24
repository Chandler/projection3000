#pragma once
#include "native_render_graph.hpp"
#include <chrono>
#include <map>
#include <memory>
namespace vj {
// The source evaluator is shared by projected virtual fixtures and future LED
// transports. This class never sends packets and owns no audio/capture device.
class LedSampler {
public:
    using Frames=std::map<std::string,std::vector<std::uint8_t>>;
    LedSampler();
    ~LedSampler();
    // Add raw media-only 64x64 banks before graph.apply_scene/set_bus_sizes.
    // Source identities stay unchanged so graph decoders are shared.
    static void prepareScene(const SceneJson& snapshot,NativeScene& scene,
                             std::map<std::string,std::array<int,2>>& sizes);
    // Call whenever the same scene is applied to the render graph.
    void configure(const NativeScene& scene);
    // Populate projected trace motion anchors, then retain the same scene for LEDs.
    void configure(NativeScene& scene);
    // Call once per frame after graph.render, before binding destination FBOs.
    Frames render(const SceneJson& snapshot,NativeRenderGraph& graph,double flash=0);
    SceneJson diagnostics()const;
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
// Pure evaluator, useful for comparing against original trace_effects.evaluate.
std::array<float,3> evaluateTrace(const std::string& name,double x,double seconds,
    double beat,const SceneJson& params,unsigned instance=0);
}
