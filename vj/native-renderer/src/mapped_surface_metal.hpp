#pragma once
#include <array>
#include <cmath>
#include <string>
#include <nlohmann/json.hpp>

namespace vj::mapped_surface {
// Each vector is a Metal float4; keep the scalar layout identical on both sides.
struct Uniforms {
    std::array<float,4> tintBrightness,stroke,pulse,animation,flow,sphere,pose,rotation;
};
inline Uniforms uniforms(const nlohmann::json& p,const std::array<float,3>& tint,float thickness,
                         float glow,float seconds,float routeLength) {
    auto v=[&](const char* key,float fallback){return p.value(key,fallback);};
    constexpr float radians=.01745329252f;
    const auto direction=p.value("pulse_direction",std::string("forward"));
    return {{tint[0],tint[1],tint[2],v("brightness",.7f)},
            {thickness,glow,v("glow",.6f),p.value("pulses",false)?1.f:0.f},
            {v("pulse_speed",.6f),v("pulse_rate",1),v("pulse_width",.15f),v("pulse_amount",1)},
            {seconds,routeLength,direction=="reverse"?1.f:direction=="bounce"?2.f:0.f,v("sparkle",0)},
            {v("density",8),v("width",.35f),v("foam",.6f),v("turbulence",.35f)},
            {v("speed",.65f),v("trails",24),v("tail",.025f),v("spread",.035f)},
            {v("pose_x",0)*radians,v("pose_y",0)*radians,v("pose_z",0)*radians,v("fade_start",0)},
            {v("rotate_x",0)*radians,v("rotate_y",0)*radians,v("rotate_z",0)*radians,v("tail_fade",1)}};
}

}
