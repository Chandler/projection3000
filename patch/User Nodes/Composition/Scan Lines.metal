// Distances use the 1280 × 720 composition reference frame.
float3 animation(float2 uv, float time, float4 a, float4 b, float4 c, float4 d) {
    float angle = radians(a.z);
    float axis = dot(uv * float2(1280,720),float2(-sin(angle),cos(angle)));
    float spacing = max(1.0f,a.w);
    float distance = abs(fract((axis - time * a.y) / spacing + 0.5f) - 0.5f) * spacing;
    float strength = 1.0f - smoothstep(b.x * 0.5f,b.x * 0.5f + max(0.5f,b.y),distance);
    uint rgb = uint(round(a.x));
    float3 tint = float3((rgb >> 16) & 255u,(rgb >> 8) & 255u,rgb & 255u) / 255.0f;
    return tint * strength * b.z;
}
