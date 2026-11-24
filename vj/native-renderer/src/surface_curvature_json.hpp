#pragma once
#include "surface_curvature.hpp"
#include <nlohmann/json.hpp>
#include <string>

namespace surface_curvature {
// Decode the same normalized surface settings for mapping and collection meshes.
inline Settings from_json(const nlohmann::json& raw) {
    Settings c;
    if(!raw.is_object())return c;
    c.top=raw.value("top",0.);c.right=raw.value("right",0.);
    c.bottom=raw.value("bottom",0.);c.left=raw.value("left",0.);
    c.wrap_x=raw.value("wrapX",0.);c.wrap_y=raw.value("wrapY",0.);
    c.spacing_x=raw.value("spacingX",0.);c.spacing_y=raw.value("spacingY",0.);
    const std::array<std::string,4> sides={"top","right","bottom","left"};
    for(int i=0;i<4;++i){c.skew[i]=raw.value(sides[i]+"Skew",0.);c.shape[i]=raw.value(sides[i]+"Shape",0.);}
    if(const auto p=raw.find("pins");p!=raw.end()&&p->is_object()){
        c.pins_enabled=p->value("enabled",true);c.local_pins=p->value("method",std::string("fit"))=="local";
        for(const auto& pin:p->value("points",nlohmann::json::array())){
            auto side=std::find(sides.begin(),sides.end(),pin.value("side",std::string{}));
            if(side==sides.end()||!pin.contains("target")||pin["target"].size()!=2)continue;
            c.pins.push_back({int(side-sides.begin()),pin.value("t",.5),{pin["target"][0],pin["target"][1]},pin.value("enabled",true)});
        }
    }
    prepare_pins(c);return c;
}
}
