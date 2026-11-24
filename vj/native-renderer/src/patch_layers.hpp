#pragma once
#include <nlohmann/json.hpp>
#include <vector>
#include <algorithm>
#include <cmath>
namespace patch_layers {
using J=nlohmann::json;
struct Leaf { J recipe; double opacity; bool additive=false; };
// A mux carries recipes, never pre-rasterized collection effects. Bounded expansion
// is shared by projector and LED evaluation; silent channels cost no evaluation.
inline void append(const J& recipe,double opacity,std::vector<Leaf>& out,int depth=0,bool additive=false){
 if(!recipe.is_object()||!std::isfinite(opacity)||opacity<=0||depth>16||out.size()>=128)return;
 if(recipe.value("kind",std::string{})=="layerMux"){
  if(!recipe.contains("layers")||!recipe["layers"].is_array())return;
  for(const auto& layer:recipe["layers"])if(layer.is_object()&&layer.contains("recipe"))append(layer["recipe"],opacity*std::clamp(layer.value("opacity",0.),0.,1.),out,depth+1,additive||recipe.value("composite",std::string{})=="crossfade");
 }else out.push_back({recipe,opacity,additive});
}
inline std::vector<Leaf> flatten(const J& recipe,double opacity=1){std::vector<Leaf> out;append(recipe,opacity,out);return out;}
}
