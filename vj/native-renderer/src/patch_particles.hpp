#pragma once
#include "PatchParticles.h"
#include <nlohmann/json.hpp>
#include <vector>
#include <algorithm>
namespace patch_particles {
inline PatchParticleConfig config(const nlohmann::json& p,bool ink=false){return {std::clamp(int(p.value("particles",24.)),1,ink?192:64),p.value("dwell",1.),p.value("travel",.45),p.value("speed",1.),p.value("spin",1.2),p.value("orbit",.28),p.value("depth",.75),p.value("size",.023),p.value("stagger",.12),p.value("trail",.12),uint32_t(p.value("seed",1.))};}
inline int traversal(const std::string& value){return value=="once"?1:value=="wander"?2:0;}
inline std::vector<PatchParticle> cloud(PatchParticleConfig p,int faces,int colors,double seconds,int traversal,bool ink=false,double turbulence=1,double pulse=.45,int circles=0,double startingFaces=100,bool independent=false){
 if(ink&&(independent||startingFaces<100))p.count=std::max(p.count,int(std::ceil(faces*std::clamp(startingFaces,0.,100.)/100.)));
 std::vector<PatchParticle> result;int trails=p.trail>0&&!(ink&&circles)?4:1;result.reserve(p.count*trails);
 for(int trail=trails-1;trail>=0;--trail)for(int i=0;i<p.count;++i){double t=seconds-p.trail*trail/3.;if(t<0)continue;auto s=ink?patch_ink_population(p,i,faces,colors,t,traversal,turbulence,pulse,circles,startingFaces,independent):patch_particle_sample(p,i,faces,colors,t,traversal);s.level*=trail==0?1: .32*(1-trail/4.);if(s.face>=0)result.push_back(s);}
 std::stable_sort(result.begin(),result.end(),[](const auto& a,const auto& b){return a.z<b.z;});return result;
}
}
