float starRandom(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float3 animation(float2 uv, float time, float4 a, float4 b, float4 c, float4 d) {
    float3 result = 0;
    for (int i = 0; i < 4; ++i) {
        float age = fract(time * 0.1 + float(i) * 0.25);
        float2 p = (uv - 0.5) * mix(a.x, a.x * 0.2, age);
        float2 index = floor(p);
        float2 seed = index + float2(a.z + i * 79, i * 113);
        float2 offset = 0.12 + 0.76 * float2(starRandom(seed), starRandom(seed + 27.3));
        float distance = length(fract(p) - offset);
        float star = 1.0 - smoothstep(0.0, a.y, distance);
        float fade = smoothstep(0.0, 0.2, age) * (1.0 - smoothstep(0.8, 1.0, age));
        result += mix(float3(0.52,0.7,1.0),float3(1.0,0.83,0.58),starRandom(seed+60.8)) * star * fade;
    }
    return min(result, 1.0);
}
