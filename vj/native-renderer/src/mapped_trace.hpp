#pragma once
#include "mapped_metal.hpp"
#include "patch_trace.hpp"
#include "mapped_trace_source.hpp"

namespace vj::mapped_trace {
namespace gpu {
using PatchTraceReal=float;
using PatchTraceSeed=uint32_t;
#define PATCH_TRACE_ADDRESS
#define PATCH_TRACE_MATH(...) __VA_ARGS__
#include "PatchTraceMath.inc"
#undef PATCH_TRACE_MATH
#undef PATCH_TRACE_ADDRESS
}
struct Uniforms {
    gpu::PatchTraceConfig lightning{};
    gpu::PatchLineTrace line{};
    int kind=0,mode=0,reverse=0,sequence=0,colors=0;
    uint32_t seed=0;
    float width=0,offset=0,time=0,beat=0;
};
inline void draw(MappedMetalRenderer& renderer,const nlohmann::json& recipe,const nlohmann::json& collection,
                 const std::vector<float>& vertices,int width,int height,const std::string& blend,float opacity,double beat){
    const auto kind=recipe.value("kind",std::string{});
    Uniforms u;u.kind=patch_trace::lineKind(kind);const auto params=recipe.value("params",nlohmann::json::object());
    std::array<gpu::PatchTraceColor,256> palette{};
    if(u.kind>=0)u.line=patch_trace::lineConfig<gpu::PatchLineTrace,gpu::PatchTraceColor>(u.kind,params);
    else if(kind=="lightningPulses"){
        u.kind=4;u.lightning=patch_trace::config<gpu::PatchTraceConfig,gpu::PatchTraceColor>(params);
        for(const auto& c:recipe.value("colors",nlohmann::json::array())){
            if(u.colors==int(palette.size()))break;
            palette[u.colors++]={c.value("r",0.f),c.value("g",0.f),c.value("b",0.f)};
        }
        if(recipe.value("paletteConnected",false)&&!u.colors)return;
    }else return;
    const auto route=collection.value("trace",nlohmann::json::object());auto mode=route.value("mode",std::string("perimeter"));
    u.mode=mode=="horizontal"?1:mode=="vertical"?2:0;u.reverse=route.value("reverse",false);
    u.sequence=route.value("scope",std::string("face"))=="collection";u.seed=collection.value("traceSeed",0u);
    u.width=route.value("width",.04f);u.offset=route.value("offset",0.f);u.time=recipe.value("time",0.f);u.beat=float(beat);
    renderer.draw(mappedTraceSource,"mappedTrace",vertices.data(),vertices.size(),&u,sizeof(u),
                  palette.data(),std::max(1,u.colors)*sizeof(palette[0]),width,height,blend,opacity);
}
}
