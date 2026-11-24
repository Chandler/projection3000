#pragma once
#include <nlohmann/json.hpp>
#include <array>
#include <vector>
#include "PatchTrace.h"
namespace vj::patch_trace {
using J=nlohmann::json;
inline PatchTraceColor color(const J& p,const char* key,const char* fallback){
 auto s=p.value(key,std::string(fallback));unsigned rgb=0;try{rgb=std::stoul(s.substr(1),nullptr,16);}catch(...){return {0,0,0};}
 return {double((rgb>>16)&255)/255,double((rgb>>8)&255)/255,double(rgb&255)/255};
}
inline PatchTraceConfig config(const J& p){
 PatchTraceConfig c{};c.rate=p.value("rate",.25);c.burst=p.value("burst",.45);c.speed=p.value("speed",.2);c.jitter=p.value("jitter",.35);
 c.length=p.value("length",.08);c.tail=p.value("tail",.62);c.crackle=p.value("crackle",.38);c.forks=p.value("forks",.32);c.spray=p.value("top_spray",.45);
 c.brightness=p.value("brightness",1.);c.rainbow=p.value("rainbow",0.);c.start=p.value("start",0.);c.end=p.value("end",1.);
 c.reverse=p.value("origin",std::string("start"))=="end";c.reflect=p.value("reflect",false);c.singleColor=p.value("single_color",false);c.seed=uint32_t(p.value("seed",0.));
 c.motionTime=p.value("_motion_time",0.);c.motionDistance=p.value("_motion_distance",0.);c.motionJitterDistance=p.value("_motion_jitter_distance",0.);
 c.core=color(p,"core","#f8fbff");c.glow=color(p,"glow","#43a9ff");return c;
}
struct Recipe {
 PatchTraceConfig config{};std::vector<PatchTraceColor> colors;double time=0;bool available=false;
 explicit Recipe(const J& recipe){
  if(recipe.value("kind",std::string{})!="lightningPulses")return;
  config=patch_trace::config(recipe.value("params",J::object()));time=recipe.value("time",0.);
  for(const auto& c:recipe.value("colors",J::array())){if(colors.size()==256)break;colors.push_back({c.value("r",0.),c.value("g",0.),c.value("b",0.)});}
  available=!recipe.value("paletteConnected",false)||!colors.empty();
 }
 std::array<float,3> sample(double x,uint32_t instance)const{
  if(!available)return {};auto c=patch_trace_sample(config,colors.data(),int(colors.size()),x,time,instance);return {float(c.r),float(c.g),float(c.b)};
 }
};
}
