import AppKit
import Metal
import PatchCore

let voltageShaders = """
#include <metal_stdlib>
using namespace metal;
struct Uniforms {float4 geometry;float4 colorWidth;float4 options;float4 offset;};
struct VertexOut {
    float4 position [[position]];
    float2 local [[sample_no_perspective]];
    float length;float radius;float mode;float4 color;
};
vertex VertexOut scopeVertex(uint vid [[vertex_id]],uint segment [[instance_id]],
                            const device float2 *points [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    const float2 corners[6]={float2(0,-1),float2(1,-1),float2(0,1),
                            float2(0,1),float2(1,-1),float2(1,1)};
    uint a=u.options.y>0.5?segment*2:segment;
    float mode=u.options.z;
    float2 p=points[a]*u.geometry.xy*0.92;
    float2 q=p;
    if(mode<1.5)q=points[a+1]*u.geometry.xy*0.92;
    float2 direction=(q-p)*u.geometry.zw*0.5;
    float segmentLength=length(direction);
    float2 tangent=segmentLength>0.00001?direction/segmentLength:float2(1,0);
    float2 normal=float2(-tangent.y,tangent.x);
    float radius=u.colorWidth.x*0.5;
    float support=mode>0.5?radius+1.0:radius;
    float extension=mode>0.5?support:0;
    float2 corner=corners[vid];
    float along=mix(-extension,segmentLength+extension,corner.x);
    float across=corner.y*support;
    VertexOut out;
    out.position=float4(p+u.offset.xy+(tangent*along+normal*across)*2.0/u.geometry.zw,0,1);
    out.local=float2(along,across);
    out.length=segmentLength;out.radius=radius;out.mode=mode;
    out.color=float4(u.colorWidth.yzw,u.options.x);
    return out;
}
fragment float4 scopeFragment(VertexOut in [[stage_in]]) {
    float coverage;
    if(in.mode<0.5) {
        coverage=1.0-smoothstep(0.55,1.0,abs(in.local.y/max(in.radius,0.0001)));
    } else {
        float2 nearest=float2(clamp(in.local.x,0.0,in.length),0);
        coverage=clamp(in.radius+0.5-length(in.local-nearest),0.0,1.0);
    }
    float alpha=in.color.a*coverage;
    return float4(in.color.rgb*alpha,alpha);
}
"""

final class VoltageRenderer {
    private let device: MTLDevice
    private var pipelines: [Int:MTLRenderPipelineState] = [:]
    private final class Buffers {
        var slots=[MTLBuffer?](repeating:nil,count:3)
        var index=0
        var multisample: MTLTexture?
    }
    private var buffers: [UUID:Buffers] = [:]
    private var shapes: [UUID:(VectorPath.Signature,VectorPath)] = [:]
    init(device: MTLDevice) throws {
        self.device=device
        let library=try device.makeLibrary(source:voltageShaders,options:nil)
        for samples in (device.supportsTextureSampleCount(4) ? [1,4]:[1]) { for maximum in [false,true] {
            let d=MTLRenderPipelineDescriptor()
            d.rasterSampleCount=samples
            d.vertexFunction=library.makeFunction(name:"scopeVertex");d.fragmentFunction=library.makeFunction(name:"scopeFragment")
            let a=d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm;a.isBlendingEnabled=true
            a.sourceRGBBlendFactor = .one;a.destinationRGBBlendFactor = .one;a.rgbBlendOperation=maximum ? .max:.add
            a.sourceAlphaBlendFactor = .one;a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelines[samples*10+(maximum ? 1:0)]=try device.makeRenderPipelineState(descriptor:d)
        }}
    }
    func prune(_ ids: Set<UUID>) { buffers=buffers.filter { ids.contains($0.key) };shapes=shapes.filter { ids.contains($0.key) } }
    func shape(_ node: Node,time: Double) -> [SIMD2<Float>] {
        let key=VectorPath.Signature(node)
        if shapes[node.id]?.0 != key { shapes[node.id]=(key,VectorPath.shape(node)) }
        let angle=node.value("rotation")*Double.pi/180+time*node.value("spin")*2*Double.pi
        // Fluid shapes are dense fills; the coarse preview would skip their spirals.
        if node.kind == .fluidShape { let path=shapes[node.id]!.1;return (0...8192).map { path.point(Double($0)/8192,rotation:angle) } }
        return shapes[node.id]!.1.preview(rotation:angle)
    }
    func encode(_ points: [SIMD2<Float>],node: Node,target: MTLTexture,command: MTLCommandBuffer) {
        let source=node.kind == .vectorShape || node.kind == .vectorText || node.kind == .fluidShape
        let pairs=node.kind == .vectorText
        let samples = !source && node.value("antialias")>0.5 && device.supportsTextureSampleCount(4) ? 4:1
        let resource=buffers[node.id] ?? Buffers();buffers[node.id]=resource
        let pass=MTLRenderPassDescriptor(),a=pass.colorAttachments[0]!
        a.texture=target;a.loadAction = .clear;a.storeAction = .store;a.clearColor=MTLClearColorMake(0,0,0,1)
        if samples>1 {
            if resource.multisample?.width != target.width || resource.multisample?.height != target.height {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:target.pixelFormat,width:target.width,height:target.height,mipmapped:false)
                d.textureType = .type2DMultisample;d.sampleCount=samples;d.usage = .renderTarget;d.storageMode = .private
                resource.multisample=device.makeTexture(descriptor:d)
            }
            guard let texture=resource.multisample else { return }
            a.texture=texture;a.resolveTexture=target;a.storeAction = .multisampleResolve
        }
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { return }
        defer { encoder.endEncoding() }
        guard !points.isEmpty else { return }
        let slot=resource.index%3,bytes=points.count*MemoryLayout<SIMD2<Float>>.stride
        if (resource.slots[slot]?.length ?? 0)<bytes { resource.slots[slot]=device.makeBuffer(length:max(bytes,16384),options:.storageModeShared) }
        guard let buffer=resource.slots[slot] else { return }
        points.withUnsafeBytes { buffer.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
        resource.index += 1
        let w=Float(target.width),h=Float(target.height),side=min(w,h)
        let zoom=source ? 1:Float(node.value("zoom"))
        let gx=source ? 1:Float(node.value("gainX"))*(node.value("flipX")>0.5 ? -1:1)
        let gy=source ? 1:Float(node.value("gainY"))*(node.value("flipY")>0.5 ? -1:1)
        let color=NSColor(calibratedHue:source ? 0.39:node.value("hue"),saturation:source ? 0.85:node.value("saturation"),brightness:1,alpha:1).usingColorSpace(.deviceRGB)!
        let mode=source ? 1:Int(node.value("drawing")),count=pairs ? points.count/2:mode == 2 ? points.count:points.count-1
        guard count>0 else { return }
        encoder.setRenderPipelineState(pipelines[samples*10+(source ? 1:Int(node.value("blend").rounded()))]!)
        encoder.setVertexBuffer(buffer,offset:0,index:0)
        func stroke(width: Float,alpha: Float) {
            let rgb=SIMD3(Float(color.redComponent),Float(color.greenComponent),Float(color.blueComponent))
            var u=[SIMD4(gx*zoom*side/w,gy*zoom*side/h,w,h),SIMD4(width,rgb.x,rgb.y,rgb.z),SIMD4<Float>(alpha,pairs ? 1:0,Float(mode),0),SIMD4<Float>(source ? 0:Float(node.value("x")),source ? 0:Float(node.value("y")),0,0)]
            u.withUnsafeMutableBytes { encoder.setVertexBytes($0.baseAddress!,length:$0.count,index:1) }
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:count)
        }
        let width=source ? 1.5:Float(node.value("width")),brightness=source ? 0.8:Float(node.value("brightness")),glow=source ? 0.2:Float(node.value("glow"))
        if glow>0 { stroke(width:width+5,alpha:glow*brightness*0.2) }
        stroke(width:width,alpha:brightness)
    }
}
