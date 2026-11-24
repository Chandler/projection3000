import Metal
import MetalPerformanceShaders
import PatchCore
import simd

let voltageFluidShaders = """
#include <metal_stdlib>
using namespace metal;
// u: grid width, grid height, splat sigma (cells), weight per sample.
struct Splat {float4 position [[position]];float2 local;float2 direction;float sigma;float weight;};
vertex Splat fluidSplatVertex(uint vid [[vertex_id]],uint sample [[instance_id]],
                              const device float4 *points [[buffer(0)]],constant float4 &u [[buffer(1)]]) {
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    float4 p=points[sample];
    float2 offset=corners[vid]*3.0*u.z,cell=p.xy+offset;
    Splat out;
    out.position=float4(cell.x/u.x*2.0-1.0,1.0-cell.y/u.y*2.0,0,1);
    out.local=offset;out.direction=p.zw;out.sigma=u.z;out.weight=u.w;
    return out;
}
// Normalized gaussian: total deposited mass is independent of beam width.
fragment float4 fluidSplatFragment(Splat in [[stage_in]]) {
    float s2=in.sigma*in.sigma;
    float g=in.weight*exp(-dot(in.local,in.local)/(2.0*s2))/(6.2831853*s2);
    return float4(g,g*in.direction,0);
}

// c0: dt, push, gravity, tension · c1: viscosity, evaporate, swirl, level
struct FluidStep {float4 c0;float4 c1;};
constexpr sampler fluidLinear(coord::normalized,address::clamp_to_edge,filter::linear);

kernel void fluidAdvect(texture2d<float,access::sample> state [[texture(0)]],
                        texture2d<float,access::read> deposit [[texture(1)]],
                        texture2d<float,access::write> next [[texture(2)]],
                        constant FluidStep &u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    uint w=next.get_width(),h=next.get_height();
    if(gid.x>=w||gid.y>=h) return;
    float2 size=float2(w,h),uv=(float2(gid)+0.5)/size,texel=1.0/size;
    float dt=u.c0.x;
    float4 here=state.sample(fluidLinear,uv);
    // Semi-Lagrangian: carry mass and momentum back along the flow.
    float4 carried=state.sample(fluidLinear,uv-here.gb*dt*texel);
    float mass=carried.r;float2 velocity=carried.gb;
    float4 d=deposit.read(gid);
    mass+=d.r;
    // The beam drags what it lays down in its direction of travel.
    velocity+=u.c0.y*120.0*d.gb/(mass+0.15);
    float level=u.c1.w,wet=clamp(mass/level,0.0,1.5);
    velocity.y+=u.c0.z*220.0*dt*wet;
    // Cohesion: liquid climbs its own thickness gradient, so threads bead and
    // nearby strokes merge (a cheap stand-in for surface tension).
    float2 e=texel*2.0;
    float2 gradient=float2(state.sample(fluidLinear,uv+float2(e.x,0)).r-state.sample(fluidLinear,uv-float2(e.x,0)).r,
                           state.sample(fluidLinear,uv+float2(0,e.y)).r-state.sample(fluidLinear,uv-float2(0,e.y)).r)*0.25;
    velocity+=u.c0.w*900.0*dt*gradient/(1.0+mass);
    float4 l=state.sample(fluidLinear,uv-float2(texel.x,0)),r=state.sample(fluidLinear,uv+float2(texel.x,0));
    float4 t=state.sample(fluidLinear,uv-float2(0,texel.y)),b=state.sample(fluidLinear,uv+float2(0,texel.y));
    float viscosity=u.c1.x;
    velocity=mix(velocity,(l.gb+r.gb+t.gb+b.gb)*0.25,viscosity*0.6);
    // Air carries little momentum; liquid keeps more.
    velocity*=exp(-dt*(mix(3.0,0.6,clamp(wet,0.0,1.0))+viscosity*3.0));
    mass*=exp(-u.c1.y*dt);
    if(gid.x==0||gid.y==0||gid.x==w-1||gid.y==h-1) velocity=float2(0);
    next.write(float4(max(mass,0.0),velocity,0),gid);
}
kernel void fluidDivergence(texture2d<float,access::read> state [[texture(0)]],
                            texture2d<float,access::write> divergence [[texture(1)]],uint2 gid [[thread_position_in_grid]]) {
    uint w=state.get_width(),h=state.get_height();
    if(gid.x>=w||gid.y>=h) return;
    uint2 l=uint2(max(int(gid.x)-1,0),gid.y),r=uint2(min(gid.x+1,w-1),gid.y);
    uint2 t=uint2(gid.x,max(int(gid.y)-1,0)),b=uint2(gid.x,min(gid.y+1,h-1));
    divergence.write(float4(0.5*(state.read(r).g-state.read(l).g+state.read(b).b-state.read(t).b)),gid);
}
kernel void fluidJacobi(texture2d<float,access::read> pressure [[texture(0)]],
                        texture2d<float,access::read> divergence [[texture(1)]],
                        texture2d<float,access::write> next [[texture(2)]],uint2 gid [[thread_position_in_grid]]) {
    uint w=pressure.get_width(),h=pressure.get_height();
    if(gid.x>=w||gid.y>=h) return;
    uint2 l=uint2(max(int(gid.x)-1,0),gid.y),r=uint2(min(gid.x+1,w-1),gid.y);
    uint2 t=uint2(gid.x,max(int(gid.y)-1,0)),b=uint2(gid.x,min(gid.y+1,h-1));
    float p=(pressure.read(l).r+pressure.read(r).r+pressure.read(t).r+pressure.read(b).r-divergence.read(gid).r)*0.25;
    next.write(float4(p),gid);
}
// Swirl blends the incompressible flow (rolls, plumes) with the raw one (beading).
kernel void fluidProject(texture2d<float,access::read> state [[texture(0)]],
                         texture2d<float,access::read> pressure [[texture(1)]],
                         texture2d<float,access::write> next [[texture(2)]],
                         constant FluidStep &u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    uint w=state.get_width(),h=state.get_height();
    if(gid.x>=w||gid.y>=h) return;
    uint2 l=uint2(max(int(gid.x)-1,0),gid.y),r=uint2(min(gid.x+1,w-1),gid.y);
    uint2 t=uint2(gid.x,max(int(gid.y)-1,0)),b=uint2(gid.x,min(gid.y+1,h-1));
    float4 s=state.read(gid);
    float2 gradient=0.5*float2(pressure.read(r).r-pressure.read(l).r,pressure.read(b).r-pressure.read(t).r);
    s.gb-=gradient*u.c1.z;
    next.write(s,gid);
}

float fvHash(float n) { return fract(sin(n)*43758.5453123); }
float3 fvHue(float h) { return clamp(abs(fmod(h*6.0+float3(0,4,2),6.0)-3.0)-1.0,0.0,1.0); }
// s0: grid w, grid h, level, puff · s1: hardness, edge, glow, reflection
// s2: exposure, hue, saturation, background · s3: aspect, has reflection
struct FluidShade {float4 s0;float4 s1;float4 s2;float4 s3;};
float3 fvEnvironment(float3 r,constant FluidShade &u) {
    float hard=u.s1.x,edge=u.s1.y;
    float3 cool=mix(float3(1.0),float3(0.36,0.58,1.0),edge),blue=mix(float3(1.0),float3(0.06,0.26,1.0),edge);
    float3 color=float3(0.006,0.008,0.012)+float3(0.01,0.014,0.022)*max(r.y,0.0);
    color+=smoothstep(-0.55,-0.84,r.z)*blue*mix(0.9,0.75,edge);
    color+=smoothstep(-0.9,-0.985,r.z)*float3(1.8,1.9,2.1);
    float soft=mix(0.35,0.04,hard);
    color+=smoothstep(0.62-soft,0.62+soft,r.y)*step(0.0,r.z)*float3(1.3,1.32,1.4);
    for(int i=0;i<7;i++) {
        float fi=float(i);
        float around=fvHash(fi*7.13)*6.2831853,off=mix(0.3,0.95,fvHash(fi*3.71));
        float3 dir=normalize(float3(cos(around)*off,sin(around)*off*0.8+0.15,sqrt(max(0.05,1.0-off*off))));
        if(dot(r,dir)<0.0) continue;
        float angle=fvHash(fi*9.31)*3.14159265;
        float2 o=(r-dir).xy;
        o=float2(cos(angle)*o.x+sin(angle)*o.y,-sin(angle)*o.x+cos(angle)*o.y);
        o.x/=1.0+3.0*fvHash(fi*2.53);
        float size=mix(0.2,0.045,hard)*(0.6+fvHash(fi*4.41)),feather=size*mix(0.7,0.08,hard);
        color+=(1.0-smoothstep(size-feather,size+feather,length(o)))*mix(1.4,4.0,fvHash(fi*6.07))*mix(float3(1.0),cool,0.35*fvHash(fi*8.8));
    }
    return color;
}
// Wet surface: a sessile-drop profile, steep at the contact line, domed inside.
float fvHeight(texture2d<float,access::sample> field,float2 p,float level,float puff) { return puff*6.0*sqrt(max(field.sample(fluidLinear,p).r-level,0.0)); }
kernel void fluidShade(texture2d<float,access::sample> field [[texture(0)]],
                       texture2d<float,access::sample> media [[texture(1)]],
                       texture2d<float,access::write> target [[texture(2)]],
                       constant FluidShade &u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    uint w=target.get_width(),h=target.get_height();
    if(gid.x>=w||gid.y>=h) return;
    float2 uv=(float2(gid)+0.5)/float2(w,h),texel=1.0/u.s0.xy;
    float level=u.s0.z,puff=u.s0.w,edge=u.s1.y,glow=u.s1.z;
    float m=field.sample(fluidLinear,uv).r,excess=m-level;
    float coverage=smoothstep(-0.04*level,0.04*level,excess);
    float3 blue=mix(float3(1.0),float3(0.08,0.3,1.0),edge);
    float3 color=float3(0);
    if(coverage>0.0) {
        float hx=fvHeight(field,uv+float2(texel.x,0),level,puff)-fvHeight(field,uv-float2(texel.x,0),level,puff);
        float hy=fvHeight(field,uv+float2(0,texel.y),level,puff)-fvHeight(field,uv-float2(0,texel.y),level,puff);
        float3 n=normalize(float3(-hx*0.5,hy*0.5,1.0));
        float3 r=reflect(float3(0,0,-1),n);
        color=fvEnvironment(r,u);
        if(u.s3.y>0.5 && u.s1.w>0.0) {
            float2 bent=uv-n.xy*float2(0.22/max(u.s3.x,0.1),-0.22);
            float3 video=pow(max(media.sample(fluidLinear,bent).rgb,float3(0)),float3(2.2));
            color+=video*1.6*u.s1.w*(1.0-smoothstep(0.15,1.2,dot(color,float3(0.3,0.5,0.2))));
        }
        float fresnel=pow(1.0-clamp(n.z,0.0,1.0),5.0);
        color*=mix(float3(0.78,0.82,0.9),float3(1.0),fresnel);
        color+=blue*exp(-max(excess,0.0)/max(level,0.01)*6.0)*glow*0.45;
        color*=mix(float3(1.0),fvHue(u.s2.y)*1.4,u.s2.z);
    }
    color*=u.s2.x;
    color=clamp((color*(2.51*color+0.03))/(color*(2.43*color+0.59)+0.14),0.0,1.0);
    color=pow(max(color,float3(0)),float3(1.0/2.2));
    float3 halo=blue*smoothstep(0.0,level,m)*glow*0.35*(1.0-coverage);
    float3 lit=color*coverage+halo;
    if(u.s2.w<0.5) { target.write(float4(lit,clamp(max(coverage,dot(halo,float3(0.4))),0.0,1.0)),gid); return; }
    target.write(float4(float3(0.004,0.007,0.018)*(1.3-uv.y)*(1.0-coverage)+lit,1.0),gid);
}
"""

/// Reconstructs a returned XY beam as liquid. Render-queue confined; every
/// pass shares the graph command buffer.
final class VoltageFluidRenderer {
    private let device: MTLDevice
    private let splat: MTLRenderPipelineState
    private let advect: MTLComputePipelineState, divergence: MTLComputePipelineState
    private let jacobi: MTLComputePipelineState, project: MTLComputePipelineState, shade: MTLComputePipelineState
    private final class Resources {
        let width: Int, height: Int
        var state: [MTLTexture], pressure: [MTLTexture]
        let deposit: MTLTexture, divergence: MTLTexture, smooth: MTLTexture
        let blur: MPSImageGaussianBlur
        var slots=[MTLBuffer?](repeating:nil,count:3), slot=0, cleared=false
        init?(device: MTLDevice,width: Int,height: Int) {
            func texture(_ format: MTLPixelFormat) -> MTLTexture? {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
                d.usage=[.shaderRead,.shaderWrite,.renderTarget];d.storageMode = .private
                return device.makeTexture(descriptor:d)
            }
            guard let a=texture(.rgba16Float),let b=texture(.rgba16Float),let p=texture(.r16Float),let q=texture(.r16Float),
                  let deposit=texture(.rgba16Float),let divergence=texture(.r16Float),let smooth=texture(.rgba16Float) else { return nil }
            self.width=width;self.height=height;state=[a,b];pressure=[p,q]
            self.deposit=deposit;self.divergence=divergence;self.smooth=smooth
            blur=MPSImageGaussianBlur(device:device,sigma:1.0);blur.edgeMode = .clamp
        }
    }
    private var resources: [UUID:Resources] = [:]
    init(device: MTLDevice) throws {
        self.device=device
        let library=try device.makeLibrary(source:voltageFluidShaders,options:nil)
        func kernel(_ name: String) throws -> MTLComputePipelineState { try device.makeComputePipelineState(function:library.makeFunction(name:name)!) }
        advect=try kernel("fluidAdvect");divergence=try kernel("fluidDivergence");jacobi=try kernel("fluidJacobi")
        project=try kernel("fluidProject");shade=try kernel("fluidShade")
        let d=MTLRenderPipelineDescriptor()
        d.vertexFunction=library.makeFunction(name:"fluidSplatVertex");d.fragmentFunction=library.makeFunction(name:"fluidSplatFragment")
        let a=d.colorAttachments[0]!
        a.pixelFormat = .rgba16Float;a.isBlendingEnabled=true
        a.sourceRGBBlendFactor = .one;a.destinationRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .one;a.destinationAlphaBlendFactor = .one
        splat=try device.makeRenderPipelineState(descriptor:d)
    }
    func prune(_ ids: Set<UUID>) { resources=resources.filter { ids.contains($0.key) } }
    private func clear(_ textures: [MTLTexture],command: MTLCommandBuffer) {
        for texture in textures {
            let pass=MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);pass.colorAttachments[0].storeAction = .store
            command.makeRenderCommandEncoder(descriptor:pass)?.endEncoding()
        }
    }
    private func dispatch(_ encoder: MTLComputeCommandEncoder,_ width: Int,_ height: Int) {
        encoder.dispatchThreads(.init(width:width,height:height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1))
    }
    func encode(_ points: [SIMD2<Float>],sampleRate: Double,dt: Double,node: Node,reflection: MTLTexture?,target: MTLTexture,command: MTLCommandBuffer) {
        let aspect=Float(target.width)/Float(max(1,target.height)),side=VoltageFluidStyle.gridSide(node)
        let width=aspect >= 1 ? side:max(16,Int((Float(side)*aspect).rounded()))
        let height=aspect >= 1 ? max(16,Int((Float(side)/aspect).rounded())):side
        if resources[node.id]?.width != width || resources[node.id]?.height != height { resources[node.id]=Resources(device:device,width:width,height:height) }
        guard let r=resources[node.id] else { return }
        if !r.cleared { clear(r.state+r.pressure+[r.smooth],command:command);r.cleared=true }
        if dt > 0 {
            clear([r.deposit],command:command)
            if points.count > 1 {
                // Same framing as the Voltage Visualizer, then into grid cells.
                let w=Float(target.width),h=Float(target.height),screen=min(w,h),zoom=Float(node.value("zoom"))
                let gx=Float(node.value("gainX"))*(node.value("flipX")>0.5 ? -1:1)*zoom*screen/w*0.92
                let gy=Float(node.value("gainY"))*(node.value("flipY")>0.5 ? -1:1)*zoom*screen/h*0.92
                let ox=Float(node.value("x")),oy=Float(node.value("y")),gw=Float(width),gh=Float(height)
                func cell(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2((p.x*gx+ox)*0.5+0.5,0.5-(p.y*gy+oy)*0.5)*SIMD2(gw,gh) }
                var splats=[SIMD4<Float>](repeating:.zero,count:points.count-1)
                var previous=cell(points[0])
                for i in 1..<points.count {
                    let next=cell(points[i]),motion=(next-previous)*Float(sampleRate),speed=simd_length(motion)
                    let direction=speed > 1e-3 ? motion/speed*min(1,speed/20000):.zero
                    splats[i-1]=SIMD4(previous.x,previous.y,direction.x,direction.y);previous=next
                }
                let bytes=splats.count*MemoryLayout<SIMD4<Float>>.stride,index=r.slot%3
                if (r.slots[index]?.length ?? 0) < bytes { r.slots[index]=device.makeBuffer(length:max(bytes,65536),options:.storageModeShared) }
                if let buffer=r.slots[index] {
                    r.slot += 1
                    splats.withUnsafeBytes { buffer.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
                    let pass=MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture=r.deposit;pass.colorAttachments[0].loadAction = .load;pass.colorAttachments[0].storeAction = .store
                    if let encoder=command.makeRenderCommandEncoder(descriptor:pass) {
                        // Mass per second scales with the grid, so the look holds across Detail.
                        var u=SIMD4<Float>(gw,gh,Float(node.value("splat"))*gw/384,Float(node.value("flow"))*0.25*gw*gh/Float(max(1,sampleRate)))
                        encoder.setRenderPipelineState(splat);encoder.setVertexBuffer(buffer,offset:0,index:0)
                        encoder.setVertexBytes(&u,length:16,index:1)
                        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:splats.count)
                        encoder.endEncoding()
                    }
                }
            }
            var step=[SIMD4<Float>(Float(dt),Float(node.value("push")),Float(node.value("gravity")),Float(node.value("tension"))),
                      SIMD4<Float>(Float(node.value("viscosity")),Float(node.value("evaporate")),Float(node.value("swirl")),Float(node.value("level")))]
            if let encoder=command.makeComputeCommandEncoder() {
                step.withUnsafeMutableBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
                encoder.setComputePipelineState(advect)
                encoder.setTexture(r.state[0],index:0);encoder.setTexture(r.deposit,index:1);encoder.setTexture(r.state[1],index:2)
                dispatch(encoder,width,height)
                encoder.setComputePipelineState(divergence)
                encoder.setTexture(r.state[1],index:0);encoder.setTexture(r.divergence,index:1)
                dispatch(encoder,width,height)
                encoder.setComputePipelineState(jacobi)
                for _ in 0..<20 {
                    encoder.setTexture(r.pressure[0],index:0);encoder.setTexture(r.divergence,index:1);encoder.setTexture(r.pressure[1],index:2)
                    dispatch(encoder,width,height);r.pressure.swapAt(0,1)
                }
                encoder.setComputePipelineState(project)
                encoder.setTexture(r.state[1],index:0);encoder.setTexture(r.pressure[0],index:1);encoder.setTexture(r.state[0],index:2)
                dispatch(encoder,width,height)
                encoder.endEncoding()
            }
        }
        r.blur.encode(commandBuffer:command,sourceTexture:r.state[0],destinationTexture:r.smooth)
        guard let encoder=command.makeComputeCommandEncoder() else { return }
        var u=[SIMD4<Float>(Float(width),Float(height),Float(node.value("level")),Float(node.value("puff"))),
               SIMD4<Float>(Float(node.value("hardness")),Float(node.value("edge")),Float(node.value("glow")),Float(node.value("reflection"))),
               SIMD4<Float>(Float(node.value("exposure")),Float(node.value("hue")),Float(node.value("saturation")),Float(node.value("background"))),
               SIMD4<Float>(aspect,reflection == nil ? 0:1,0,0)]
        encoder.setComputePipelineState(shade)
        encoder.setTexture(r.smooth,index:0);encoder.setTexture(reflection ?? r.smooth,index:1);encoder.setTexture(target,index:2)
        u.withUnsafeMutableBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
        dispatch(encoder,target.width,target.height)
        encoder.endEncoding()
    }
}
