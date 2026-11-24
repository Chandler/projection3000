#pragma once
#include "native_scene.hpp"
#include "frame_transport.hpp"
namespace vj {
struct RenderViewDemand {
    std::string bus,mappingId;
    int width=960,height=540;
    SceneJson mappingOverride; // Optional native editor geometry snapshot.
};
// Pure demand calculation. No discovery, allocation, outputs or readback.
// Regular source buses keep canvas aspect; collection buses keep projector space.
std::map<std::string,std::array<int,2>> renderDemand(const SceneJson& snapshot,
    const NativeScene& scene,int canvasWidth,int canvasHeight,
    const std::vector<RenderViewDemand>& views,
    const std::map<std::string,FrameDemand>& streams,bool ndiPermitted);
// Published Patch types are retained by actual raster/LED consumers, not saved clips.
SceneJson patchDemand(const SceneJson& snapshot,const NativeScene& scene,
    const std::map<std::string,std::array<int,2>>& sizes);
}
