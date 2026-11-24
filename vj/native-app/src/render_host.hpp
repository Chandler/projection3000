#pragma once
#include "model.hpp"
#include <memory>

namespace vj {
struct RenderHostOptions {
    int width=960, height=540, fps=60;
    bool publishOutputs=true;
    std::vector<std::string> outputs; // Empty renders all current Outputs.
};

// The owning thread must construct, tick and destroy the host. SDL video events
// and its OpenGL context stay on that thread; the API owns a separate thread.
// Rendering is offscreen; configured NDI projectors publish when permitted.
// There is no physical display takeover in this host. Audio opens only
// when a selected video explicitly enables audio playback.
class RenderHost {
public:
    RenderHost(Model& model, RenderHostOptions options={});
    ~RenderHost();
    RenderHost(const RenderHost&)=delete;
    RenderHost& operator=(const RenderHost&)=delete;
    bool tick(); // false when SDL requests shutdown
    Json diagnostics() const;
    Json checkRendering();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
