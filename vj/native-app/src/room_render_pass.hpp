#pragma once
#include "native_render_graph.hpp"
#include <functional>
#include <memory>
namespace vj {
// Orbit camera: {eye:[3],target:[3],up:[3],verticalFovDegrees:48,near:.035,far:150}.
// Through camera: {projectorId:"1"}; uses exact descriptor lens/shift and fits
// its aspect inside the target. Matrix is column-major, viewport is GL pixels.
nlohmann::json roomCameraProjection(const nlohmann::json& roomDescriptor,
    const nlohmann::json& camera,int width,int height);
// Own/destroy with the shared OpenGL context current. The caller owns its color
// framebuffer and depth attachment. Feed textures are already-mapped projector
// images, in sRGB encoding and standard GL bottom-left texture orientation.
// No render graph, frame source, display, transport, or output activation lives
// here. Use MappingRenderPass feeds from the shared runtime. Feed alpha is ignored,
// matching original opaque /mapping/frame?room=1 PNG images.
class RoomRenderPass {
public:
    using ProjectorTextureLookup=std::function<NativeBusTexture(const std::string& mappingId)>;
    RoomRenderPass();
    ~RoomRenderPass();
    RoomRenderPass(const RoomRenderPass&)=delete;
    RoomRenderPass& operator=(const RoomRenderPass&)=delete;
    void render(const nlohmann::json& roomDescriptor,const nlohmann::json& camera,
        int width,int height,const ProjectorTextureLookup& lookup);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
