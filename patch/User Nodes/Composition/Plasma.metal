float3 animation(float2 uv, float time, float4 a, float4 b, float4 c, float4 d) {
    float2 p = (uv - 0.5) * a.x * 6.283185;
    float2 center = float2(sin(time * 0.31), cos(time * 0.27));
    float wave = (sin(p.x + time) + cos(p.y - time * 0.81) + sin(length(p - center) * 1.4 - time)) / 3.0;
    float hue = a.y + a.z * wave + time * b.x;
    float3 rgb = 0.5 + 0.5 * cos(6.283185 * (hue + float3(0, 0.67, 0.33)));
    return saturate((rgb - 0.5) * (b.y > 0.0 ? b.y : 1.0) + 0.5);
}
