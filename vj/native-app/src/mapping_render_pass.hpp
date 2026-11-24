#pragma once
#include "native_render_graph.hpp"
#include <functional>
#include <memory>
namespace vj {
// Draw into the caller's framebuffer, which must have an 8-bit stencil attachment.
// Own and destroy the pass with its OpenGL context current. No display or sender.
class MappingRenderPass {
public:
    using TextureLookup=std::function<NativeBusTexture(const std::string&)>;
    using TraceLookup=std::function<std::vector<std::uint8_t>(const std::string& fixtureId)>;
    MappingRenderPass();
    ~MappingRenderPass();
    MappingRenderPass(const MappingRenderPass&)=delete;
    MappingRenderPass& operator=(const MappingRenderPass&)=delete;
    void render(const nlohmann::json& mapping, int width,int height,const TextureLookup& lookup,const TraceLookup& traces = {},const nlohmann::json& calibration = nullptr,bool ignoreOutputRotation = false,NativeRenderGraph* graph = nullptr);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
