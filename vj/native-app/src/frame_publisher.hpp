#pragma once
#include "frame_transport.hpp"
#include "led_sampler.hpp"
#include "native_render_graph.hpp"
#include <memory>
namespace vj {
// GL-thread owner; readback follows demand and never starts an output destination.
class FramePublisher {
public:
    FramePublisher(); ~FramePublisher();
    NativeBusTexture mappingTexture(const nlohmann::json& snapshot,NativeRenderGraph& graph,const LedSampler::Frames& traces,const std::string& mappingId,int width,int height);
    void publish(FrameTransport& transport,const nlohmann::json& snapshot,NativeRenderGraph& graph,const LedSampler::Frames& traces);
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
}
