#pragma once
#include "PatchClouds.h"
#include "PatchCloudParticles.h"
#include <nlohmann/json.hpp>
#include <algorithm>
namespace patch_clouds {
// Defaults mirror CollectionStyle.cloudParameters: recipes carry only edited values.
inline PatchCloudConfig config(const nlohmann::json& p){return {std::clamp(int(p.value("clouds",7.)),1,PATCH_CLOUD_MAX),p.value("speed",.12),p.value("length",1.6),p.value("width",.11),p.value("wander",.45),p.value("colorMode",0.)>=.5?1:0,p.value("sky",0.)>=.5?1:0,uint32_t(p.value("seed",3.))};}
}
