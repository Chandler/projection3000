#pragma once
#include <nlohmann/json.hpp>
#include <array>
#include <vector>
#include "PatchTrace.h"
namespace vj::patch_trace {
using J=nlohmann::json;
template<class Color=PatchTraceColor> inline Color color(const J& p,const char* key,const char* fallback){
 auto s=p.value(key,std::string(fallback));unsigned rgb=0;try{rgb=std::stoul(s.substr(1),nullptr,16);}catch(...){return {0,0,0};}
 using Scalar=decltype(Color{}.r);return {Scalar((rgb>>16)&255)/Scalar(255),Scalar((rgb>>8)&255)/Scalar(255),Scalar(rgb&255)/Scalar(255)};
}
template<class Config=PatchTraceConfig,class Color=PatchTraceColor> inline Config config(const J& p){
 Config c{};c.rate=p.value("rate",.25);c.burst=p.value("burst",.45);c.speed=p.value("speed",.2);c.jitter=p.value("jitter",.35);
 c.length=p.value("length",.08);c.tail=p.value("tail",.62);c.crackle=p.value("crackle",.38);c.forks=p.value("forks",.32);c.spray=p.value("top_spray",.45);
 c.brightness=p.value("brightness",1.);c.rainbow=p.value("rainbow",0.);c.start=p.value("start",0.);c.end=p.value("end",1.);
 c.reverse=p.value("origin",std::string("start"))=="end";c.reflect=p.value("reflect",false);c.singleColor=p.value("single_color",false);c.seed=uint32_t(p.value("seed",0.));
 c.motionTime=p.value("_motion_time",0.);c.motionDistance=p.value("_motion_distance",0.);c.motionJitterDistance=p.value("_motion_jitter_distance",0.);
 c.core=color<Color>(p,"core","#f8fbff");c.glow=color<Color>(p,"glow","#43a9ff");return c;
}
inline int lineKind(const std::string& kind) {
 if(kind=="traceSnake")return 0;if(kind=="traceRainbow")return 1;
 if(kind=="tracePulse")return 2;if(kind=="traceSolid")return 3;return -1;
}
template<class Line=PatchLineTrace,class Color=PatchTraceColor> inline Line lineConfig(int kind,const J& p) {
 Line c{};c.kind=kind;c.beatSync=p.value("beat_sync",false);
 c.speed=p.value("speed",0.);c.beatSpeed=p.value("beat_speed",.25);c.tail=p.value("tail",.25);c.drag=p.value("drag",.5);
 c.rainbow=p.value("rainbow",0.);c.spread=p.value("spread",1.);c.brightness=p.value("brightness",1.);c.pulse=p.value("pulse",0.);
 c.breathe=p.value("breathe",0.);c.rate=p.value("rate",.5);c.perBeat=p.value("per_beat",1.);c.onTime=p.value("on_time",.5);
 c.attack=p.value("attack",.05);c.release=p.value("release",.1);c.floor=p.value("floor",0.);c.curve=p.value("curve",1.);
 c.motionTime=p.value("_motion_time",0.);c.ratePhase=p.value("_motion_rate_phase",0.);c.tint=color<Color>(p,"tint","#ffffff");return c;
}
struct Recipe {
 PatchLineTrace line{};int lineType=-1;
 PatchTraceConfig config{};std::vector<PatchTraceColor> colors;double time=0;bool available=false;
 explicit Recipe(const J& recipe){
  auto kind=recipe.value("kind",std::string{});lineType=lineKind(kind);time=recipe.value("time",0.);
  if(lineType>=0){line=lineConfig(lineType,recipe.value("params",J::object()));available=true;return;}
  if(kind!="lightningPulses")return;
  config=patch_trace::config(recipe.value("params",J::object()));time=recipe.value("time",0.);
  for(const auto& c:recipe.value("colors",J::array())){if(colors.size()==256)break;colors.push_back({c.value("r",0.),c.value("g",0.),c.value("b",0.)});}
  available=!recipe.value("paletteConnected",false)||!colors.empty();
 }
 std::array<float,3> sample(double x,uint32_t instance,double beat)const{
  if(!available)return {};auto c=lineType>=0?patch_line_sample(line,x,time,beat):patch_trace_sample(config,colors.data(),int(colors.size()),x,time,instance);return {float(c.r),float(c.g),float(c.b)};
 }
};
}
