float4 lensSample(texture2d<float,access::sample> image,float2 uv,int edge) {
    constexpr sampler mirror(coord::normalized,address::mirrored_repeat,filter::linear);
    constexpr sampler wrap(coord::normalized,address::repeat,filter::linear);
    constexpr sampler border(coord::normalized,address::clamp_to_zero,filter::linear);
    if (edge == 0) return image.sample(mirror,uv);
    if (edge == 1) return image.sample(wrap,uv);
    return image.sample(border,uv);
}

float4 lensAdjust(float2 uv,texture2d<float,access::sample> image,constant float4* controls) {
    float2 p = uv * 2.0f - 1.0f;
    float2 center = 0.5f + 0.5f * p * (1.0f + controls[0].z * dot(p,p)) / max(0.05f,controls[0].w);
    float2 split = controls[0].xy / float2(image.get_width(),image.get_height());
    int edge = int(round(controls[1].x));
    float4 red = lensSample(image,center + split,edge);
    float4 green = lensSample(image,center,edge);
    float4 blue = lensSample(image,center - split,edge);
    return float4(red.r,green.g,blue.b,max(red.a,max(green.a,blue.a)));
}

#define PATCH_EFFECT_RGBA(uv,time,input,c) lensAdjust(uv,input,c)
