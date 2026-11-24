import Foundation
import CryptoKit
import Metal

/// Built-in Glow light field. It is not a user-editable shader: saved nodes and stale
/// user-library copies of "Streak Glow.metal" always resolve to this source.
enum GlowField {
    /// The shader pipeline is path based, so the source is materialized once per content.
    static let path: String = {
        let digest = SHA256.hash(data:Data(source.utf8)).prefix(6).map { String(format:"%02x",$0) }.joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PatchGlow-\(digest).metal")
        if !FileManager.default.fileExists(atPath:url.path) { try? source.write(to:url,atomically:true,encoding:.utf8) }
        return url.path
    }()

    static let source = """
// Glow: one smooth, moving light field for LED Matrix's Light input.
// a: depth, scale, gain, exposure mode    b: invert, function, detail, warp
// c: contrast, direction (deg), stretch, balance    d: seed, breathing, -, time
// Functions: 0 Streaks, 1 Gaussian noise, 2 Lava lamp, 3 Clouds, 4 Ripples,
// 5 Sweep, 6 Plasma, 7 Breathe. Each yields n in 0..1 (Streaks keeps its
// original exposure curve), shaped into stops of exposure around Gain.
float glowHash(float3 p) { p=fract(p*float3(.1031,.1030,.0973)); p+=dot(p,p.yxz+33.33); return fract((p.x+p.y)*p.z); }
float3 glowGradient(float3 cell,float seed) {
    float angle=glowHash(cell+seed)*6.28318,z=glowHash(cell+seed+17.13)*2-1,r=sqrt(1-z*z);
    return float3(r*cos(angle),r*sin(angle),z);
}
// Smooth 3D gradient noise, roughly -1..1; z is time so the field evolves in place.
float glowNoise(float3 p,float seed) {
    float3 i=floor(p),f=fract(p),u=f*f*f*(f*(f*6-15)+10);
    float x00=mix(dot(glowGradient(i,seed),f),dot(glowGradient(i+float3(1,0,0),seed),f-float3(1,0,0)),u.x);
    float x10=mix(dot(glowGradient(i+float3(0,1,0),seed),f-float3(0,1,0)),dot(glowGradient(i+float3(1,1,0),seed),f-float3(1,1,0)),u.x);
    float x01=mix(dot(glowGradient(i+float3(0,0,1),seed),f-float3(0,0,1)),dot(glowGradient(i+float3(1,0,1),seed),f-float3(1,0,1)),u.x);
    float x11=mix(dot(glowGradient(i+float3(0,1,1),seed),f-float3(0,1,1)),dot(glowGradient(i+float3(1,1,1),seed),f-float3(1,1,1)),u.x);
    return mix(mix(x00,x10,u.y),mix(x01,x11,u.y),u.z)*1.45;
}
float glowFBM(float2 p,float z,int octaves,float seed) {
    float sum=0,amplitude=.5,total=0;
    for(int i=0;i<6;i++) {
        if(i>=octaves) break;
        sum+=amplitude*glowNoise(float3(p,z),seed+float(i)*7.7); total+=amplitude;
        p=float2(p.x*1.6-p.y*1.2,p.x*1.2+p.y*1.6)+3.1; z*=1.31; amplitude*=.5;
    }
    return sum/total;
}
float glowWarp(float2 p,float t,float seed) {
    return glowFBM(p*.8,t*.1,2,seed+41);
}
float3 animation(float2 uv,float time,float4 a,float4 b,float4 c,float4 d) {
    int function=int(round(b.y)),detail=int(round(b.z));
    float t=time,seed=d.x*1.618,warp=b.w,scale=a.y,pulse=d.y;
    float heading=c.y*0.0174533;
    float2 dir=float2(cos(heading),-sin(heading)),across=float2(-dir.y,dir.x);
    float2 p=(uv-.5)*float2(1.5*c.z,1)*scale;
    float n=.5,exposure=0;
    bool shaped=true;
    if(function==0) {
        // Original Streak Glow: unchanged so existing patches look the same.
        float s=t+7.3;
        float field=sin(uv.x*8.1*scale-s*.46)+.53*sin(uv.x*18.0*scale+s*.23+2.1)+.32*sin(uv.y*7.0*scale+s*.37);
        exposure=field*.61-.22; shaped=false;
    } else if(function==1) {
        // Slow Gaussian-smooth noise drifting along Direction, domain warped.
        float2 q=p*.9+dir*t*.06;
        if(warp>0) q+=warp*.8*float2(glowWarp(q,t,seed),glowWarp(q+5.2,t,seed+3));
        n=.5+.5*clamp(glowFBM(q,t*.1,detail,seed)*2.2,-1.0,1.0);
    } else if(function==2) {
        // Lava lamp: Gaussian blobs rising and sinking along Direction, softly merged.
        float2 q=p;
        if(warp>0) q+=warp*.12*float2(glowWarp(p*2,t,seed),glowWarp(p*2+9.1,t,seed+5));
        float sum=0;int count=3+detail*2;
        for(int i=0;i<15;i++) {
            if(i>=count) break;
            float h1=glowHash(float3(float(i),seed,1)),h2=glowHash(float3(float(i),seed,2)),h3=glowHash(float3(float(i),seed,3));
            float travel=sin(t*(.12+.18*h2)+h3*6.28318)*.62*scale;
            float lane=(h1-.5)*1.4*scale+.04*scale*sin(t*.3+h2*9);
            float radius=(.09+.08*h2)*scale;
            float2 delta=q-(across*lane+dir*travel);
            sum+=exp(-dot(delta,delta)/(2*radius*radius));
        }
        n=smoothstep(.25,.85,sum);
    } else if(function==3) {
        // Clouds: drifting, breathing Gaussian brightness clouds (former Light Field).
        float sum=0;int count=max(1,int(round(b.z*2)));
        for(int i=0;i<12;i++) {
            if(i>=count) break;
            float s=d.x+float(i)*19.73;
            float2 anchor=float2(glowHash(float3(s,1,0)),glowHash(float3(s,2,0)));
            float phase=glowHash(float3(s,3,0))*6.28318;
            float2 center=anchor+.14*warp*float2(sin(t*.7+phase),cos(t*.53+phase*1.7));
            float breath=mix(1.0,.5+.5*sin(t*1.3+phase),pulse);
            float radius=.24/scale*(.8+.35*sin(t*.4+phase));
            float2 delta=(uv-center)*float2(1.5*c.z,1);
            sum+=exp(-dot(delta,delta)/(2*radius*radius))*breath;
        }
        n=clamp(sum,0.0,1.0); pulse=0;
    } else if(function==4) {
        // Ripples: rings spreading from a wandering center.
        float2 center=.3*scale*float2(sin(t*.31+seed),cos(t*.23+seed*1.3));
        float r=length(p-center);
        if(warp>0) r+=warp*.12*glowWarp(p*2,t,seed);
        n=.5+.5*cos(r*(1.0+detail*.6)*6.28318/scale-t*1.4);
    } else if(function==5) {
        // Sweep: soft Gaussian bands travelling along Direction.
        float s=dot(p,dir)/scale;
        if(warp>0) s+=warp*.15*glowWarp(p*2,t,seed);
        float x=fract(s*float(detail)*.5-t*.15)-.5;
        n=exp(-x*x*28);
    } else if(function==6) {
        // Plasma: interfering sine fields.
        float2 q=p*3;
        if(warp>0) q+=warp*float2(glowWarp(p,t,seed),glowWarp(p+4.3,t,seed+2));
        float v=sin(q.x+t*.7)+sin(q.y*1.3-t*.5)+sin((q.x+q.y)*.7+t*.3)+sin(length(q+2*float2(sin(t*.27),cos(t*.31)))*1.5-t);
        n=clamp(.5+.2*v,0.0,1.0);
    } else {
        // Breathe: the whole field rises and falls, with a little spatial drift.
        n=.5+.5*sin(t*.9);
        if(warp>0) n=clamp(n+warp*.25*glowWarp(uv*3,t,seed),0.0,1.0);
    }
    if(shaped) {
        exposure=n*2-1;
        exposure=sign(exposure)*pow(abs(exposure),1/max(.05,c.x));
    } else if(c.x!=1) exposure=sign(exposure)*pow(abs(exposure),1/max(.05,c.x));
    exposure+=c.w;
    exposure*=mix(1.0,.5+.5*sin(t*.6),pulse);
    if(b.x>0.5) exposure=-exposure;
    if(a.w<0.5) exposure=min(0.0,exposure);
    else if(a.w<1.5) exposure=max(0.0,exposure);
    return float3(exp(a.x*exposure)*a.z);
}
"""
}

extension Renderer {
    /// Compiled once off the render queue; previews appear when it is ready.
    func glowPreviewPipeline() -> MTLComputePipelineState? {
        if let resource = glowPreviewResource { return resource.pipeline }
        let resource = ShaderResource(GlowField.path); resource.compiling = true; glowPreviewResource = resource
        let device = self.device
        DispatchQueue.global(qos:.userInitiated).async { [weak resource] in
            do {
                let pipeline = try ShaderCompiler.lightPreview(light:GlowField.source,device:device)
                self.renderQueue.async { resource?.pipeline = pipeline; resource?.compiling = false }
            } catch { self.renderQueue.async { resource?.error = error.localizedDescription; resource?.compiling = false } }
        }
        return nil
    }
}
