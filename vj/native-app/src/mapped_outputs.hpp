#pragma once
#include "model.hpp"
#include "native_render_graph.hpp"
#include "led_sampler.hpp"
#include <memory>
namespace vj {
// GL-thread owner. Saved routing is inert until the host explicitly permits
// publication; checks and import review never create network senders.
class MappedOutputs {
public:
    MappedOutputs();
    ~MappedOutputs();
    void configure(const Json& snapshot,bool permitted);
    void render(const Json& snapshot,NativeRenderGraph& graph,const LedSampler::Frames& traces={},const std::function<void(const std::string&,uint64_t)>& presented={});
    Json runtime() const;
    std::array<int,2> size() const;
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
}
