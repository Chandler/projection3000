#pragma once
#include "native_render_graph.hpp"
#include <filesystem>
#include <memory>
namespace vj {
// Register bounded upload validation. Does not require an OpenGL context.
void installWasmtimeModuleValidator();
// Construct, render and destroy on the owning OpenGL context thread.
class VectorHost {
public:
    explicit VectorHost(std::filesystem::path uploadedModules);
    ~VectorHost();
    void install(NativeRenderGraph& graph);
    void beginFrame(std::uint64_t revision);
    void endFrame();
    nlohmann::json diagnostics() const;
private:
    struct Impl;
    std::shared_ptr<Impl> impl_;
};
}
