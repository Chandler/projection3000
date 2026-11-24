float3 rampColor(float packed) {
    uint n = uint(round(packed));
    return float3((n >> 16) & 255u, (n >> 8) & 255u, n & 255u) / 255.0;
}

float3 animation(float2 uv, float time, float4 a, float4 b, float4 c, float4 d) {
    float angle = (a.z * 0.01745329252);
    float phase = dot(uv - 0.5, float2(cos(angle), sin(angle))) / max(a.w, 0.01) + 0.5 + b.x;
    return mix(rampColor(a.x), rampColor(a.y), b.y * smoothstep(0.0, 1.0, phase));
}
