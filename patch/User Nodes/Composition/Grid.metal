float3 animation(float2 uv, float time, float4 a, float4 b, float4 c, float4 d) {
    float2 spacing = max(a.xy, 1.0);
    float2 cell = abs(fract(uv * spacing + float2(time * 0.25, 0) + 0.5) - 0.5);
    float line = 1.0 - smoothstep(a.z * 0.5, a.z * 0.5 + 0.012, min(cell.x, cell.y));
    uint rgb = uint(round(a.w));
    float3 tint = float3((rgb >> 16) & 255u, (rgb >> 8) & 255u, rgb & 255u) / 255.0;
    return mix(float3(b.x), tint, line);
}
