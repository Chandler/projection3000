#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>
#include <nlohmann/json.hpp>

namespace flash_faces {
using Color = std::array<float,3>;
inline Color color(const std::string &hex) {
    if(hex.size()!=7 || hex[0]!='#')return {1,1,1};
    try {
        const auto value=std::stoul(hex.substr(1),nullptr,16);
        return {float((value>>16)&255)/255,float((value>>8)&255)/255,float(value&255)/255};
    } catch(...) {return {1,1,1};}
}
inline std::uint32_t hash(std::uint32_t value) {
    value^=value>>16;value*=0x7feb352dU;value^=value>>15;value*=0x846ca68bU;return value^(value>>16);
}
inline std::vector<Color> palette(const nlohmann::json &p,const nlohmann::json &sources=nlohmann::json::array()) {
    const auto selected=p.value("palette_source",std::string{});
    if(!selected.empty())for(const auto& source:sources)if(source.value("id",std::string{})==selected&&(source.value("available",false)||source.value("held",false))){
        std::vector<Color> result;
        for(const auto& c:source.value("colors",nlohmann::json::array()))result.push_back({c.at("r").get<float>(),c.at("g").get<float>(),c.at("b").get<float>()});
        if(!result.empty())return result;
    }
    // An external route must never flash an unrelated local theme. Before its
    // first valid palette, remain dark; thereafter the model supplies held colors.
    if(!selected.empty())return {{0,0,0}};
    const auto theme=p.value("theme",std::string("neon"));
    std::vector<std::string> colors;
    if(theme=="ice")colors={"#00bbff","#cceeff","#2255ff","#44ffdd","#8877ff","#ffffff"};
    else if(theme=="fire")colors={"#ff2200","#ff8800","#ffcc00","#ff0055","#ff5500","#fff0aa"};
    else if(theme=="candy")colors={"#ff44aa","#55eeff","#aa66ff","#ffee55","#ff99cc","#66ffbb"};
    else if(theme=="rgb")colors={"#ff0000","#00ff00","#0000ff","#ffff00","#00ffff","#ff00ff"};
    else colors={"#ff00aa","#00ffff","#aaff00","#7733ff","#ff6600","#ffff00"};
    const int count=std::clamp(int(std::round(p.value("colors",4.0))),2,6);
    std::vector<Color> result;
    for(int i=0;i<count;++i){
        const std::string key="color_"+std::string(1,char('a'+i));
        result.push_back(color(theme=="custom"?p.value(key,colors[i]):colors[i]));
    }
    return result;
}
inline float smooth(float value){value=std::clamp(value,0.f,1.f);return value*value*(3-2*value);}
// One sample per face, independent of frame rate, using the destination clock.
inline Color sample(const nlohmann::json &p,const std::vector<Color> &colors,
                    int face,int faces,double seconds) {
    const auto pattern=p.value("pattern",std::string("alternate"));
    const auto seed=std::uint32_t(p.value("seed",1.0));
    const double speed=std::clamp(p.value("speed",2.0),0.0,16.0);
    double phase=std::max(0.0,seconds)*speed;
    if(pattern=="scatter")phase+=double(hash(std::uint32_t(face)+seed*101U)%65536)/65536;
    if(pattern=="wave")phase-=double(face)/std::max(1,faces);
    const double step=std::floor(phase);
    const float fraction=float(phase-step);
    const auto cycle=static_cast<std::int64_t>(step);
    const auto mod=[](std::int64_t a,int b){return int((a%b+b)%b);};
    const auto index=[&](std::int64_t tick){
        if(pattern=="shuffle"||pattern=="scatter")return int(hash(std::uint32_t(tick)*131U+std::uint32_t(face)*977U+seed*101U)%colors.size());
        if(pattern=="strobe")return mod(tick,int(colors.size()));
        if(pattern=="chase")return mod(tick/std::max(1,faces)+face,int(colors.size()));
        return mod(tick+face,int(colors.size()));
    };
    const float fade=std::clamp(p.value("fade",0.f),0.f,1.f);
    const float on=std::clamp(p.value("on_time",.8f),.05f,1.f);
    float level=fraction<on?1.f:0.f;
    if(fade>0 && on<1){
        const float edge=on*.5f*fade;
        level=smooth(fraction/edge)*smooth((on-fraction)/edge);
    }
    if(pattern=="chase" && mod(cycle,std::max(1,faces))!=face)level=0;
    if(pattern=="wave")level*=float(.5-.5*std::cos(fraction*6.283185307179586));
    level*=std::clamp(p.value("brightness",1.f),0.f,1.f);
    const auto &current=colors[index(cycle)],&previous=colors[index(cycle-1)];
    const float blend=fade>0?smooth(fraction/(fade*.5f)):1.f;
    Color result;
    for(int c=0;c<3;c++)result[c]=(previous[c]+(current[c]-previous[c])*blend)*level;
    return result;
}
}
