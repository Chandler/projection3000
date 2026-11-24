// Ferrofluid — a magnetic puddle in Rosensweig spikes. FerrofluidSim (Swift) steps
// the spike lattice each frame and uploads a heightfield; this shader raymarches it
// from a tilted camera and lights it as glossy black fluid in a dark studio.
// External user-node source; packed controls defined by FerrofluidStyle.swift.
#if PATCH_FERROFLUID_CONTROLS_VERSION >= 1
// texture(2) carries the heightfield (R, puddle radii) from FerrofluidStyle.swift.
#define PATCH_EFFECT_RGBA_AUX(uv,t,input,aux,c) ferrofluid(uv,t,input,aux,c)
#endif
// Legacy installation preflight entry point (the full renderer uses RGBA above).
float3 effect(float2 uv,float time,texture2d<float,access::sample> input,float4 controls) { return float3(0); }

float ffHeight(texture2d<float,access::sample> field,float2 p,float extent) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    return field.sample(linear,(p+extent)/(2.0*extent)).r;
}

// Dark studio, so flat fluid reads as a black mirror: a small overhead softbox,
// three narrow strips low around the horizon (one warm) and a cool horizon band
// that only steep spike flanks reflect.
float3 ffEnvironment(float3 r,constant float4 *c) {
    float hard=c[2].x,edge=c[2].y,warmth=c[3].y;
    float soft=mix(0.06,0.008,hard);
    float3 color=float3(0.002,0.0025,0.004)+float3(0.004,0.005,0.009)*max(r.z,0.0);
    color+=smoothstep(0.955-soft,0.955+soft,r.z)*float3(2.2,2.24,2.35);
    float azimuth=atan2(r.y,r.x);
    for(int i=0;i<3;i++) {
        float centre=float(i)*2.0943951+0.6;
        float d=abs(fmod(azimuth-centre+9.42477796,6.28318531)-3.14159265);
        float strip=(1.0-smoothstep(0.05-soft,0.05+soft*2.0,d))*smoothstep(0.12,0.2,r.z)*(1.0-smoothstep(0.42,0.5,r.z));
        float3 tint=i==2 ? mix(float3(1.0),float3(1.9,0.85,0.35),warmth) : float3(1.0);
        color+=strip*tint*(i==0 ? 3.0 : 2.0);
    }
    float3 blue=mix(float3(1.0),float3(0.08,0.3,1.0),edge);
    color+=(1.0-smoothstep(0.0,0.07,abs(r.z-0.03)))*blue*0.9;
    return color;
}

float4 ferrofluid(float2 uv,float time,texture2d<float,access::sample> input,texture2d<float,access::sample> field,constant float4 *c) {
    float aspect=c[0].x,extent=c[0].y,top=max(c[0].z,0.02)+0.01,quality=c[0].w;
    float tilt=c[1].x,turn=c[1].y,zoom=c[1].z,background=c[1].w;
    float edgeRadius=c[4].x,texel=c[4].y;
    bool solved=field.get_width()>1;

    // Orbit camera around the puddle centre; tilt 0 looks straight down.
    float tanHalf=0.25,orbit=1.3/(tanHalf*max(zoom,0.1));
    float3 target=float3(0,0,0.04);
    float3 eye=target+orbit*float3(sin(tilt)*sin(turn),-sin(tilt)*cos(turn),cos(tilt));
    float3 forward=normalize(target-eye),right=float3(cos(turn),sin(turn),0.0),up=cross(right,forward);
    float2 screen=float2((uv.x-0.5)*2.0*aspect,(0.5-uv.y)*2.0);
    float3 ray=normalize(forward+(screen.x*right+screen.y*up)*tanHalf);

    // Slab test against the heightfield's bounding box, then a fixed march with bisection.
    float3 lo=float3(-extent,-extent,0.0),hi=float3(extent,extent,top);
    float3 inv=1.0/ray,t0=(lo-eye)*inv,t1=(hi-eye)*inv;
    float3 tNear=min(t0,t1),tFar=max(t0,t1);
    float enter=max(max(tNear.x,tNear.y),max(tNear.z,0.0)),leave=min(min(tFar.x,tFar.y),tFar.z);
    bool hit=false;
    float3 p=eye;
    if(solved && enter<leave) {
        int steps=quality<0.5 ? 96 : quality<1.5 ? 160 : 260;
        float dt=(leave-enter)/float(steps),previous=enter;
        for(int i=1;i<=steps;i++) {
            float t=enter+dt*float(i);
            float3 q=eye+ray*t;
            if(q.z<=ffHeight(field,q.xy,extent)) {
                float a=previous,b=t;
                for(int j=0;j<7;j++) {
                    float m=(a+b)*0.5;
                    float3 s=eye+ray*m;
                    if(s.z<=ffHeight(field,s.xy,extent)) b=m; else a=m;
                }
                p=eye+ray*b; hit=ffHeight(field,p.xy,extent)>0.0005; break;
            }
            previous=t;
        }
    }

    float3 paper=background<1.5 ? float3(0.0) : float3(0.94,0.925,0.89);
    if(!hit) {
        if(background<0.5) return float4(0);
        // Contact shadow on the dish around the puddle.
        float floorT=-eye.z/min(ray.z,-1e-4);
        float r=length((eye+ray*floorT).xy);
        float shade=1.0-0.45*(1.0-smoothstep(edgeRadius*0.95,edgeRadius*1.35,r));
        return float4(paper*shade,1.0);
    }

    float e=texel;
    float hx=ffHeight(field,p.xy+float2(e,0),extent)-ffHeight(field,p.xy-float2(e,0),extent);
    float hy=ffHeight(field,p.xy+float2(0,e),extent)-ffHeight(field,p.xy-float2(0,e),extent);
    float3 n=normalize(float3(-hx/(2.0*e),-hy/(2.0*e),1.0));
    float3 view=-ray,r=reflect(ray,n);
    float gloss=c[3].x,f0=mix(0.04,0.8,gloss);
    float fresnel=f0+(1.0-f0)*pow(1.0-clamp(dot(n,view),0.0,1.0),5.0);
    float3 env=ffEnvironment(r,c);
    if(c[3].w>0.5 && c[3].z>0.0) {
        constexpr sampler mirror(coord::normalized,address::clamp_to_edge,filter::linear);
        // The connected video bends across every spike, filling the dark reflections.
        float2 bent=uv-n.xy*float2(0.18/max(aspect,0.1),-0.18);
        float3 media=pow(max(input.sample(mirror,bent).rgb,float3(0)),float3(2.2));
        float lum=dot(env,float3(0.3,0.5,0.2));
        env+=media*0.5*c[3].z*(1.0-smoothstep(0.15,1.2,lum));
    }
    float3 color=float3(0.005,0.005,0.006)*(1.0-fresnel)+env*fresnel;
    float3 blue=mix(float3(1.0),float3(0.1,0.32,1.0),c[2].y);
    color+=blue*pow(1.0-clamp(dot(n,view),0.0,1.0),3.0)*c[2].z*0.5;
    color*=c[2].w;
    color=clamp((color*(2.51*color+0.03))/(color*(2.43*color+0.59)+0.14),0.0,1.0);
    color=pow(max(color,float3(0)),float3(1.0/2.2));
    return float4(color,1.0);
}
