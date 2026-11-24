// Analytic intersections keep this small scene inexpensive: two spheres and a
// rotating rectangular solid. The result is a regular video texture.
struct SceneHit { float distance; float3 normal; float3 color; };
float3x3 sceneRotation(float a, float b) {
    float c = cos(a), s = sin(a), d = cos(b), t = sin(b);
    return float3x3(float3(c,0,-s),float3(0,1,0),float3(s,0,c)) *
           float3x3(float3(d,t,0),float3(-t,d,0),float3(0,0,1));
}
SceneHit sceneIntersect(float3 origin, float3 ray, float time, float spread) {
    SceneHit hit = {1e5, float3(0), float3(0)};
    float3 centers[2] = {float3(-1.13*spread,0.28+0.14*sin(time*0.7),0.1),
                         float3(0.95*spread,0.75+0.17*cos(time*0.6),-0.38)};
    float radii[2] = {0.78,0.60};
    float3 colors[2] = {float3(0.94,0.62,0.66),float3(0.59,0.83,0.75)};
    for (int i=0;i<2;i++) {
        float3 q = origin-centers[i];
        float b = dot(q,ray), c = dot(q,q)-radii[i]*radii[i], d = b*b-c;
        if (d >= 0) {
            float near = -b-sqrt(d), far = -b+sqrt(d);
            float distance = near > 0.001 ? near : far;
            if (distance > 0.001 && distance < hit.distance)
                hit = {distance,normalize(origin+ray*distance-centers[i]),colors[i]};
        }
    }
    float3 center = float3(0.38*spread,-0.75+0.12*sin(time*0.85+1),0.30);
    float3 halfSize = float3(0.98,0.29,0.39);
    float3x3 rotation = sceneRotation(0.35+time*0.22,-0.24+0.12*sin(time*0.4));
    float3 localOrigin = transpose(rotation)*(origin-center), localRay = transpose(rotation)*ray;
    // Avoid infinities at axis-aligned rays when testing box slabs.
    float3 inverse = select(float3(-1),float3(1),localRay >= 0.0)/max(abs(localRay),float3(1e-7));
    float3 a = (-halfSize-localOrigin)*inverse, b = (halfSize-localOrigin)*inverse;
    float3 lo = min(a,b), hi = max(a,b);
    float near = max(lo.x,max(lo.y,lo.z)), far = min(hi.x,min(hi.y,hi.z));
    float distance = near > 0.001 ? near : far;
    if (far >= near && distance > 0.001 && distance < hit.distance) {
        float3 p = localOrigin+localRay*distance;
        float3 face = abs(p)/halfSize;
        float3 normal = face.x > face.y && face.x > face.z ? float3(sign(p.x),0,0) :
                        (face.y > face.z ? float3(0,sign(p.y),0) : float3(0,0,sign(p.z)));
        hit = {distance,rotation*normal,float3(0.96,0.82,0.57)};
    }
    return hit;
}
float3 pastelScene(float2 uv, float aspect, float clock, float4 controls, float shadowStrength) {
    float time = clock*controls.x, yaw = time*controls.y;
    float3 camera = float3(sin(yaw)*6.8,1.25,cos(yaw)*6.8);
    float3 forward = normalize(-camera), right = normalize(cross(forward,float3(0,1,0))), up = cross(right,forward);
    float2 p = (uv*2-1)*float2(aspect,-1)/controls.z;
    float3 ray = normalize(forward*2.5 + right*p.x + up*p.y);
    SceneHit hit = sceneIntersect(camera,ray,time,controls.w);
    float3 background = float3(0.61,0.65,0.80);
    if (hit.distance > 1e4) return background;
    float3 light = normalize(float3(-3,5,4));
    float3 point = camera+ray*hit.distance;
    float diffuse = max(0.0,dot(hit.normal,light));
    SceneHit shadow = sceneIntersect(point+hit.normal*0.004,light,time,controls.w);
    float visibility = shadow.distance < 1e4 ? 1-shadowStrength : 1;
    // Broad ambient fill and diffuse lighting, without glossy highlights.
    float illumination = 0.55+0.45*diffuse*visibility;
    float3 color = hit.color*illumination;
    return mix(color,background,clamp((hit.distance-5)*0.018,0.0,0.10));
}


// External scene entry point. Controls: motion, orbit, zoom, spacing; extra.x: shadows.
float3 animation(float2 uv, float time, float4 controls, float4 extra, float aspect) {
    return pastelScene(uv,aspect,time,controls,extra.x);
}
