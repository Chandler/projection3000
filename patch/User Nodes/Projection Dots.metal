// Geometry only. dotSource::dotPattern supplies RGB and the horizontal face width.
float3 projectionDots(float2 uv,float time,constant float4 *g,float2 resolution,
                      constant float4 *controls,constant uint *messages) {
    float2 count = g[0].xy, sheet = g[1].xy;
    if (any(count<1.0f)) return float3(0);
    float diameter = g[0].z, pitch = diameter+g[0].w;
    float fit = min(resolution.x/sheet.x,resolution.y/sheet.y);
    float2 point = (uv-0.5f)*resolution/fit;
    if (any(abs(point)>sheet*0.5f)) return float3(0);
    float2 first = -(count-1.0f)*pitch*0.5f;
    float2 cell = floor((point-first)/pitch+0.5f);
    if (any(cell<0.0f) || any(cell>=count)) return float3(0);
    float4 sample = dotSource::dotPattern(cell,count,time,controls,messages);
    float width = clamp(sample.a,0.0f,1.0f);
    if (width<0.0001f) return float3(0);
    float2 local = point-(first+cell*pitch);
    local.x /= width;
    float radial = length(local)-diameter*0.5f;
    float aa = max(0.5f,g[1].z)/fit;
    float coverage = 1.0f-smoothstep(-aa*0.5f,aa*0.5f,radial);
    return clamp(sample.rgb,0.0f,1.0f)*coverage;
}
