// Liquid Chrome — poster liquid metal. A seeded 2D liquid network (pools,
// threads, holes, gravity drips) is fused by viscosity, inflated with a
// surface-tension meniscus profile, and lit by a dark hard-light studio.
// External user-node source; packed controls defined by LiquidChromeStyle.swift.
#if PATCH_LIQUID_CHROME_CONTROLS_VERSION >= 2
// texture(2) carries the pressurized-membrane height solved in LiquidChromeMembrane.swift.
#define PATCH_EFFECT_RGBA_AUX(uv,t,input,aux,c) liquidChrome(uv,t,input,aux,c)
#endif
// Legacy installation preflight entry point (the full renderer uses RGBA above).
float3 effect(float2 uv,float time,texture2d<float,access::sample> input,float4 controls) { return float3(0); }

// Trailing vector after segments and circles: method, tilt°, turn°, warmth.
float4 lcExtras(constant float4 *c) { return c[5+int(c[4].x)*3+int(c[4].y)]; }
float lcHash(float n) { return fract(sin(n)*43758.5453123); }
float lcHash2(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453123); }

// Exact distance to a quadratic Bézier (Quílez), plus the curve parameter.
float2 lcBezier(float2 pos,float2 A,float2 B,float2 C) {
    float2 a=B-A,b=A-2.0*B+C,c=a*2.0,d=A-pos;
    float kk=1.0/max(dot(b,b),1e-8);
    float kx=kk*dot(a,b),ky=kk*(2.0*dot(a,a)+dot(d,b))/3.0,kz=kk*dot(d,a);
    float p=ky-kx*kx,q=kx*(2.0*kx*kx-3.0*ky)+kz,h=q*q+4.0*p*p*p;
    if(h>=0.0) {
        h=sqrt(h);
        float2 x=(float2(h,-h)-q)*0.5;
        float2 uv=sign(x)*pow(abs(x),float2(1.0/3.0));
        float t=clamp(uv.x+uv.y-kx,0.0,1.0);
        float2 r=d+(c+b*t)*t;
        return float2(length(r),t);
    }
    float z=sqrt(-p),v=acos(clamp(q/(p*z*2.0),-1.0,1.0))/3.0;
    float m=cos(v),n=sin(v)*1.732050808;
    float2 t=clamp(float2(m+m,-n-m)*z-kx,0.0,1.0);
    float2 rx=d+(c+b*t.x)*t.x,ry=d+(c+b*t.y)*t.y;
    float dx=dot(rx,rx),dy=dot(ry,ry);
    return dx<dy ? float2(sqrt(dx),t.x) : float2(sqrt(dy),t.y);
}

// Viscous union: distance in x, the blended local radius in y.
float2 lcUnion(float2 a,float2 b,float k) {
    float h=clamp(0.5+0.5*(b.x-a.x)/k,0.0,1.0);
    // The radius blend must be C1 too, or the inflated surface shows creases.
    return float2(mix(b.x,a.x,h)-k*h*(1.0-h),mix(b.y,a.y,h*h*(3.0-2.0*h)));
}

float2 lcField(float2 p,constant float4 *c) {
    int segments=int(c[4].x),circles=int(c[4].y);
    // Viscosity is the fillet width: thick liquid bridges and rounds every join.
    float k=0.015+c[0].z*0.17;
    float2 d=float2(10.0,0.0);
    for(int i=0;i<segments;i++) {
        int index=5+i*3;
        float4 s0=c[index],s1=c[index+1],s2=c[index+2];
        if(length(p-s2.xy)-s2.z>d.x+k) continue;
        float2 hit=lcBezier(p,s0.xy,s0.zw,s1.xy);
        float radius=mix(s1.z,s1.w,hit.y);
        if(s2.w>=0.0) {
            // Necks drain toward the middle and flare smoothly into the pools.
            radius*=1.0-s2.w*pow(4.0*hit.y*(1.0-hit.y),0.55);
        } else {
            // Drips bead along their length, more strongly as they thin.
            float beads=floor(-s2.w);
            radius*=1.0+0.42*hit.y*max(0.0,sin(hit.y*beads*6.2831853-1.2));
        }
        // Drips and whips (neck ≤ 0) keep a tight fillet so they stay threads.
        d=lcUnion(d,float2(hit.x-radius,radius),s2.w>0.0 ? k : k*0.4);
    }
    int start=5+segments*3;
    for(int i=0;i<circles;i++) {
        float4 b=c[start+i];
        if(length(p-b.xy)-b.z>d.x+k) continue;
        d=lcUnion(d,float2(length(p-b.xy)-b.z,b.z),k*0.8);
    }
    return d;
}

// Fast cubic B-spline sample (4 bilinear taps): C2-smooth, so normals derived
// from the 1024-px membrane never show texel facets at poster resolution.
float lcBicubic(texture2d<float,access::sample> t,float2 uv) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 size=float2(t.get_width(),t.get_height()),pixel=uv*size-0.5,f=fract(pixel),i=pixel-f;
    float2 w0=(1.0/6.0)*(-f*f*f+3.0*f*f-3.0*f+1.0),w1=(1.0/6.0)*(3.0*f*f*f-6.0*f*f+4.0);
    float2 w2=(1.0/6.0)*(-3.0*f*f*f+3.0*f*f+3.0*f+1.0),w3=(1.0/6.0)*f*f*f;
    float2 g0=w0+w1,g1=w2+w3,h0=(i-0.5+w1/g0)/size,h1=(i+1.5+w3/g1)/size;
    return g0.y*(g0.x*t.sample(linear,h0).r+g1.x*t.sample(linear,float2(h1.x,h0.y)).r)
          +g1.y*(g0.x*t.sample(linear,float2(h0.x,h1.y)).r+g1.x*t.sample(linear,h1).r);
}

float lcSmax(float a,float b,float k) {
    float h=clamp(0.5+0.5*(a-b)/k,0.0,1.0);
    return mix(b,a,h)+k*h*(1.0-h);
}

// Height = pressurized membrane (smooth, pools high, threads low), with a
// round-tube profile for threads finer than the solve and a crisp meniscus
// right at the exact silhouette.
float lcHeight(float2 p,constant float4 *c,float2 field,texture2d<float,access::sample> membrane) {
    float depth=-field.x;
    if(depth<=0.0) return 0.0;
    float puff=c[0].w,aspect=c[0].x;
    float solved=membrane.get_width()>1 ? lcBicubic(membrane,float2(p.x/(2.0*aspect)+0.5,0.5-p.y*0.5)) : 0.0;
    float pressure=(0.04+puff*0.16)*solved*sqrt(clamp(depth/0.012,0.0,1.0));
    float plateau=0.03+puff*0.05,radius=max(field.y,0.003);
    float capillary=-log(exp(-plateau*60.0)+exp(-radius*60.0))/60.0;
    float x=min(depth/capillary,1.0);
    float tube=capillary*sqrt(x*(2.0-x))*(0.8+puff*0.6);
    return lcSmax(pressure,tube,0.012);
}

// The physical pour (texture 2): R = membrane thickness √(2u), G = phase φ.
float2 lcBicubic2(texture2d<float,access::sample> t,float2 uv) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 size=float2(t.get_width(),t.get_height()),pixel=uv*size-0.5,f=fract(pixel),i=pixel-f;
    float2 w0=(1.0/6.0)*(-f*f*f+3.0*f*f-3.0*f+1.0),w1=(1.0/6.0)*(3.0*f*f*f-6.0*f*f+4.0);
    float2 w2=(1.0/6.0)*(-3.0*f*f*f+3.0*f*f+3.0*f+1.0),w3=(1.0/6.0)*f*f*f;
    float2 g0=w0+w1,g1=w2+w3,h0=(i-0.5+w1/g0)/size,h1=(i+1.5+w3/g1)/size;
    return g0.y*(g0.x*t.sample(linear,h0).rg+g1.x*t.sample(linear,float2(h1.x,h0.y)).rg)
          +g1.y*(g0.x*t.sample(linear,float2(h0.x,h1.y)).rg+g1.x*t.sample(linear,h1).rg);
}

// Signed distance (x) and surface height (y) of the settled liquid.
float2 lcPoured(float2 p,constant float4 *c,texture2d<float,access::sample> pour) {
    float2 s=lcBicubic2(pour,float2(p.x/(2.0*c[0].x)+0.5,0.5-p.y*0.5));
    // φ ≈ tanh(−d/(√2ε)) across the interface.
    float d=-1.41421356*c[4].w*atanh(clamp(s.y,-0.995,0.995));
    // φ saturates away from the liquid; treat fully dry texels as far, so the
    // glow fades out instead of tinting the whole frame.
    if(s.y<-0.985) d=max(d,0.25);
    float puff=c[0].w,cap=0.09+puff*0.22;
    // √(2u) is a round cross-section; tanh lets wide pools settle into puddles.
    float h=cap*tanh(max(s.x,0.0)*(0.8+puff*0.8)/cap)*sqrt(clamp(-d/0.004,0.0,1.0));
    return float2(d,h);
}

float2 lcWarp(float2 p,float time,constant float4 *c) {
    float motion=c[3].x,phase=c[3].y;
    return p+motion*0.018*float2(sin(p.y*6.0+time*1.3+phase),sin(p.x*5.0-time*1.1+phase*0.7));
}

float3 lcEnvironment(float3 r,constant float4 *c,texture2d<float,access::sample> input,float2 uv,float3 n) {
    float hard=c[1].x,edge=c[1].y,phase=c[3].y;
    float3 cool=mix(float3(1.0),float3(0.36,0.58,1.0),edge);
    // A near-black room: wet metal reads through contrast, not grey fill.
    float3 color=float3(0.006,0.008,0.012)+float3(0.01,0.014,0.022)*max(r.y,0.0);
    // Grazing reflections see the bright backdrop behind the form: thin cool rims.
    float3 blue=mix(float3(1.0),float3(0.06,0.26,1.0),edge);
    // Kept below the tone curve's shoulder so the band stays cobalt, not white.
    color+=smoothstep(-0.55,-0.84,r.z)*blue*mix(0.9,0.75,edge);
    color+=smoothstep(-0.9,-0.985,r.z)*float3(1.8,1.9,2.1);       // white-hot core
    // Broad overhead panel: the long white sheen across upper surfaces.
    float soft=mix(0.35,0.04,hard);
    color+=smoothstep(0.62-soft,0.62+soft,r.y)*step(0.0,r.z)*float3(1.3,1.32,1.4);
    // Many small hard lights: each curve picks up its own crisp highlight.
    int lights=int(c[3].z);
    for(int i=0;i<lights;i++) {
        float fi=float(i)+phase;
        // Keep lights off the view axis: flat liquid should mirror the dark room.
        float around=lcHash(fi*7.13)*6.2831853,off=mix(0.3,0.95,lcHash(fi*3.71));
        float3 dir=normalize(float3(cos(around)*off,sin(around)*off*0.8+0.15,sqrt(max(0.05,1.0-off*off))));
        if(dot(r,dir)<0.0) continue;
        float angle=lcHash(fi*9.31)*3.14159265;
        float2 offset=(r-dir).xy;
        offset=float2(cos(angle)*offset.x+sin(angle)*offset.y,-sin(angle)*offset.x+cos(angle)*offset.y);
        offset.x/=1.0+3.0*lcHash(fi*2.53); // strip lights give streaks
        float size=mix(0.2,0.045,hard)*(0.6+lcHash(fi*4.41));
        float feather=size*mix(0.7,0.08,hard);
        float intensity=mix(1.4,4.0,lcHash(fi*6.07));
        // Warm highlights: some lights turn peach, against the cool chrome body.
        float3 tint=mix(mix(float3(1.0),cool,0.35*lcHash(fi*8.8)),float3(1.0,0.62,0.46),lcExtras(c).w*step(0.45,lcHash(fi*1.91)));
        color+=(1.0-smoothstep(size-feather,size+feather,length(offset)))*intensity*tint;
    }
    if(c[2].w>0.5 && c[2].x>0.0) {
        constexpr sampler mirror(coord::normalized,address::clamp_to_edge,filter::linear);
        // The connected video is seen bent through the liquid, strongest where it
        // curves, so the picture flows around every pool and thread.
        float2 bent=uv-n.xy*float2(0.22/max(c[0].x,0.1),-0.22);
        float3 media=pow(max(input.sample(mirror,bent).rgb,float3(0)),float3(2.2));
        // Video fills the dark reflections; highlights and rims stay on top.
        float lum=dot(color,float3(0.3,0.5,0.2));
        color+=media*1.6*c[2].x*(1.0-smoothstep(0.15,1.2,lum));
    }
    return color;
}

float lcStar(float2 q,float width,float arm) {
    float2 a=abs(q);
    return exp(-a.x/width)*exp(-a.y/arm)+exp(-a.y/width)*exp(-a.x/arm);
}

float3 lcOrbit(float3 p,float yaw,float pitch) {
    p=float3(p.x,cos(pitch)*p.y-sin(pitch)*p.z,sin(pitch)*p.y+cos(pitch)*p.z);
    return float3(cos(yaw)*p.x+sin(yaw)*p.z,p.y,-sin(yaw)*p.x+cos(yaw)*p.z);
}

float2 lcPourAt(texture2d<float,access::sample> pour,float2 xy,float aspect,bool fine) {
    float2 uv=float2(xy.x/(2.0*aspect)+0.5,0.5-xy.y*0.5);
    if(fine) return lcBicubic2(pour,uv);
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    return pour.sample(linear,uv).rg;
}

// Object-space distance bound for the 3D methods.
float lcSolid(float3 q,float time,constant float4 *c,texture2d<float,access::sample> pour,int method,bool fine) {
    float aspect=c[0].x,puff=c[0].w,epsilon=c[4].w;
    q.xy=lcWarp(q.xy,time,c);
    if(method==2) {
        // Sheet: the lace is a thin film twisted through space, flared into
        // wings, with rims rolled thick where it tore (sheet retraction).
        float phase=c[3].y;
        float angle=1.1*q.x*sin(phase+0.7)+0.45*sin(q.x*1.7+phase);
        float co=cos(angle),si=sin(angle);
        float3 w=float3(q.x,co*q.y+si*q.z,-si*q.y+co*q.z);
        w.y/=1.0+0.35*abs(w.x);
        w.z-=(0.15+puff*0.45)*(sin(w.x*1.3+phase)*cos(w.y*1.6-phase*0.5)+0.5*sin(w.x*2.7-w.y*1.9+phase*1.7));
        float2 s=lcPourAt(pour,w.xy,aspect,fine);
        float edge=-1.41421356*epsilon*atanh(clamp(s.y,-0.995,0.995));
        float film=(0.004+0.018*c[4].z)*(0.45+1.7*exp(-max(s.x,0.0)/0.016));
        return max(edge,abs(w.z)-film)*0.5;
    }
    // Closed volume: the membrane thickness mirrored front and back.
    float2 s=lcPourAt(pour,q.xy,aspect,fine);
    float edge=-1.41421356*epsilon*atanh(clamp(s.y,-0.995,0.995));
    float height=max(s.x,0.0)*(0.7+puff*1.2);
    return max(edge,abs(q.z)-height)*0.6;
}

float4 lcVolume(float2 uv,float time,texture2d<float,access::sample> input,texture2d<float,access::sample> pour,constant float4 *c,int method) {
    float aspect=c[0].x;
    float4 extra=lcExtras(c);
    float yaw=extra.z*0.0174532925,pitch=extra.y*0.0174532925;
    float2 screen=float2((uv.x-0.5)*2.0*aspect,(0.5-uv.y)*2.0);
    // Perspective camera 4.2 units out; the ±1 frame height fills the view.
    float3 ro=lcOrbit(float3(0,0,4.2),yaw,pitch),rd=lcOrbit(normalize(float3(screen*0.238,-1.0)),yaw,pitch);
    float3 box=float3(aspect+0.15,1.15,0.75);
    float3 inverse=1.0/rd,t0=(-box-ro)*inverse,t1=(box-ro)*inverse;
    float near=max(max(min(t0.x,t1.x),min(t0.y,t1.y)),min(t0.z,t1.z));
    float far=min(min(max(t0.x,t1.x),max(t0.y,t1.y)),max(t0.z,t1.z));
    float glow=c[1].z,edge=c[1].y,background=c[2].z;
    float3 blue=mix(float3(1.0),float3(0.08,0.3,1.0),edge);
    float t=max(near,0.0),closest=1e3;
    bool hit=false;
    int steps=c[3].w<0.5 ? 110 : (c[3].w<1.5 ? 160 : 220);
    if(far>near) for(int i=0;i<steps;i++) {
        float d=lcSolid(ro+rd*t,time,c,pour,method,false);
        closest=min(closest,d);
        if(d<0.0007) { hit=true; break; }
        t+=max(d,0.0025);
        if(t>far) break;
    }
    float3 color=float3(0);
    if(hit) {
        float3 p=ro+rd*t;
        float e=0.002;
        float3 n=normalize(float3(
            lcSolid(p+float3(e,0,0),time,c,pour,method,true)-lcSolid(p-float3(e,0,0),time,c,pour,method,true),
            lcSolid(p+float3(0,e,0),time,c,pour,method,true)-lcSolid(p-float3(0,e,0),time,c,pour,method,true),
            lcSolid(p+float3(0,0,e),time,c,pour,method,true)-lcSolid(p-float3(0,0,e),time,c,pour,method,true)));
        float3 r=reflect(rd,n);
        float3 env=lcEnvironment(r,c,input,uv,n);
        // One bounce between surfaces: hole walls and folds mirror each other.
        float travel=0.02;
        for(int j=0;j<40;j++) {
            float d=lcSolid(p+n*0.006+r*travel,time,c,pour,method,false);
            if(d<0.0012) {
                float3 q=p+n*0.006+r*travel,m=float3(0,0,1);
                float f=0.004;
                m=normalize(float3(lcSolid(q+float3(f,0,0),time,c,pour,method,false)-d,lcSolid(q+float3(0,f,0),time,c,pour,method,false)-d,lcSolid(q+float3(0,0,f),time,c,pour,method,false)-d));
                env=mix(env,lcEnvironment(reflect(r,m),c,input,uv,m)*0.8,0.85);
                break;
            }
            travel+=max(d,0.004);
            if(travel>2.5) break;
        }
        float fresnel=pow(1.0-clamp(dot(-rd,n),0.0,1.0),5.0);
        color=env*mix(float3(0.74,0.8,0.92),float3(1.0),fresnel);
        color+=blue*pow(1.0-clamp(dot(-rd,n),0.0,1.0),3.0)*edge*0.5;
        float sparkle=c[1].w;
        if(sparkle>0.0) {
            float cell=0.007;
            float2 grid=floor(screen/cell);
            float lum=dot(color,float3(0.3,0.5,0.2));
            for(int j=-1;j<=1;j++) for(int i=-1;i<=1;i++) {
                float2 id=grid+float2(i,j);
                if(lcHash2(id)<1.0-0.035*sparkle) continue;
                float2 center=(id+float2(lcHash2(id+3.1),lcHash2(id+7.7)))*cell;
                color+=lcStar(screen-center,0.0006,0.003)*smoothstep(0.25,1.4,lum)*2.2*sparkle;
            }
        }
    }
    color*=c[2].y;
    color=clamp((color*(2.51*color+0.03))/(color*(2.43*color+0.59)+0.14),0.0,1.0);
    color=pow(max(color,float3(0)),float3(1.0/2.2));
    // Only rays grazing a silhouette glow; a big sheet would otherwise fog the frame.
    float3 halo=hit ? float3(0) : blue*exp(-max(closest,0.0)*mix(420.0,140.0,glow))*glow*0.45;
    float coverage=hit ? 1.0 : 0.0;
    float3 lit=color*coverage+halo;
    if(background<0.5) return float4(lit,clamp(max(coverage,dot(halo,float3(0.4))),0.0,1.0));
    // A faint navy falloff behind 3D forms gives them a space to sit in.
    float3 paper=background<1.5 ? float3(0.004,0.007,0.018)*(1.3-uv.y) : float3(0.94,0.925,0.89);
    return float4(paper*(1.0-coverage)+lit,1.0);
}

float4 liquidChrome(float2 uv,float time,texture2d<float,access::sample> input,texture2d<float,access::sample> membrane,constant float4 *c) {
    int method=int(round(lcExtras(c).x));
    if(membrane.get_width()>1 && method!=0 && method!=3) return lcVolume(uv,time,input,membrane,c,method);
    float aspect=c[0].x;
    float2 p=lcWarp(float2((uv.x-0.5)*2.0*aspect,(0.5-uv.y)*2.0),time,c);
    bool poured=membrane.get_width()>1;
    float2 field=poured ? lcPoured(p,c,membrane) : lcField(p,c);
    float glow=c[1].z,edge=c[1].y,background=c[2].z;
    float3 cool=mix(float3(1.0),float3(0.42,0.64,1.0),edge);
    float pixel=0.0019;
    float coverage=clamp(0.5-field.x/pixel,0.0,1.0);
    float3 color=float3(0);
    if(field.x<pixel) {
        // Heightfield normal by finite differences of the inflated surface.
        float e=poured ? 0.0026 : 0.0022;
        float2 px=p+float2(e,0),py=p+float2(0,e);
        float h,hx,hy;
        if(poured) { h=field.y; hx=lcPoured(px,c,membrane).y; hy=lcPoured(py,c,membrane).y; }
        else { h=lcHeight(p,c,field,membrane); hx=lcHeight(px,c,lcField(px,c),membrane); hy=lcHeight(py,c,lcField(py,c),membrane); }
        float3 n=normalize(float3(-(hx-h)/e,-(hy-h)/e,1.0));
        float3 r=reflect(float3(0,0,-1),n);
        float3 env=lcEnvironment(r,c,input,uv,n);
        float fresnel=pow(1.0-clamp(n.z,0.0,1.0),5.0);
        color=env*mix(float3(0.78,0.82,0.9),float3(1.0),fresnel);
        // Inner bloom hugging the rim.
        color+=mix(float3(1.0),float3(0.1,0.32,1.0),edge)*exp(-max(-field.x,0.0)*240.0)*glow*0.45;
        // Glitter: tiny star specks scattered through the bright areas.
        float sparkle=c[1].w;
        if(sparkle>0.0) {
            float cell=0.007;
            float2 grid=floor(p/cell);
            float lum=dot(color,float3(0.3,0.5,0.2));
            for(int j=-1;j<=1;j++) for(int i=-1;i<=1;i++) {
                float2 id=grid+float2(i,j);
                if(lcHash2(id)<1.0-0.035*sparkle) continue;
                float2 center=(id+float2(lcHash2(id+3.1),lcHash2(id+7.7)))*cell;
                color+=lcStar(p-center,0.0006,0.003)*smoothstep(0.25,1.4,lum)*2.2*sparkle;
            }
        }
    }
    // Large star glints sit on the body and can spill past its edge.
    float sparkle=c[1].w;
    if(sparkle>0.0) {
        float cell=0.16;
        float2 grid=floor(p/cell);
        for(int j=-1;j<=1;j++) for(int i=-1;i<=1;i++) {
            float2 id=grid+float2(i,j);
            if(lcHash2(id+11.0)<0.72) continue;
            float2 center=(id+float2(lcHash2(id+5.3),lcHash2(id+9.1)))*cell;
            if((poured ? lcPoured(center,c,membrane).x : lcField(center,c).x)>-0.012) continue;
            color+=lcStar(p-center,0.0012,0.035)*cool*1.4*sparkle;
        }
    }
    color*=c[2].y;
    color=clamp((color*(2.51*color+0.03))/(color*(2.43*color+0.59)+0.14),0.0,1.0); // filmic highlight rolloff
    color=pow(max(color,float3(0)),float3(1.0/2.2));
    // Outer glow is light, so it composites additively over any background.
    float3 halo=mix(float3(1.0),float3(0.08,0.3,1.0),edge)*1.5*exp(-max(field.x,0.0)*mix(110.0,30.0,glow))*glow*0.35*(1.0-coverage);
    float3 lit=color*coverage+halo;
    if(background<0.5) return float4(lit,clamp(max(coverage,dot(halo,float3(0.4))),0.0,1.0));
    float3 paper=background<1.5 ? float3(0.0) : float3(0.94,0.925,0.89);
    return float4(paper*(1.0-coverage)+lit,1.0);
}
