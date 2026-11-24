float2 cubeRotate(float2 p, float angle) {
    return float2(cos(angle)*p.x - sin(angle)*p.y, sin(angle)*p.x + cos(angle)*p.y);
}

float3 animation(float2 uv, float time, float4 a, float4 b, float4 c, float4 d) {
    float3 origin = float3(0, 0, -3.2);
    float3 ray = normalize(float3((uv - 0.5) * 2.0 / a.x, 1.3));
    origin.xz = cubeRotate(origin.xz, time); ray.xz = cubeRotate(ray.xz, time);
    origin.yz = cubeRotate(origin.yz, (a.y * 0.01745329252)); ray.yz = cubeRotate(ray.yz, (a.y * 0.01745329252));
    float3 inv = select(float3(-1), float3(1), ray >= 0.0) / max(abs(ray), 0.00001);
    float3 lo = (-0.65 - origin) * inv, hi = (0.65 - origin) * inv;
    float3 nearFace = min(lo,hi), farFace = max(lo,hi);
    float t = max(nearFace.x,max(nearFace.y,nearFace.z));
    if (t < 0.0 || t > min(farFace.x,min(farFace.y,farFace.z))) return float3(0);
    float3 face = abs(origin + t * ray);
    float second = min(max(face.x,face.y),min(max(face.x,face.z),max(face.y,face.z)));
    float edge = smoothstep(0.65 - a.z,0.65,second);
    uint rgb = uint(round(a.w));
    float3 tint = float3((rgb >> 16) & 255u,(rgb >> 8) & 255u,rgb & 255u)/255.0;
    float shade = nearFace.x == t ? 0.45 : (nearFace.y == t ? 0.8 : 0.6);
    return mix(tint * shade, float3(1), edge);
}
