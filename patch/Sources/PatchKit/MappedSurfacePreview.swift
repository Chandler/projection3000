import Metal
import PatchCore
import OutputBridge

/// Uses the projector's fragment functions on a small reference mesh while editing without a destination.
final class MappedSurfacePreview {
    let device: MTLDevice
    private var library: MTLLibrary?
    private var pipelines: [String:MTLRenderPipelineState] = [:]
    private var textures: [UUID:MTLTexture] = [:]
    init(device:MTLDevice) {self.device=device}
    func retain(_ ids:Set<UUID>){textures=textures.filter {ids.contains($0.key)}}

    private func pipeline(_ name:String)throws->MTLRenderPipelineState {
        if let state=pipelines[name]{return state}
        if library == nil {
            let prefix="""
            #include <metal_stdlib>
            using namespace metal;
            struct MappedVertexOut { float4 position [[position]]; float3 uv; float3 graph; };
            struct MappedBlend { float opacity; };
            float4 mappedColor(float4 rgba,constant MappedBlend& blend){ return rgba; }
            vertex MappedVertexOut mappedPreviewVertex(uint i [[vertex_id]],device const float* v [[buffer(0)]]){
                uint k=i*8; return {float4(v[k],v[k+1],0,1),float3(v[k+2],v[k+3],v[k+4]),float3(v[k+5],v[k+6],v[k+7])};
            }
            """
            library=try device.makeLibrary(source:prefix+"\n"+String(cString:PatchMappedSurfaceSource()),options:nil)
        }
        let d=MTLRenderPipelineDescriptor();d.vertexFunction=library?.makeFunction(name:"mappedPreviewVertex")
        d.fragmentFunction=library?.makeFunction(name:name)
        let color=d.colorAttachments[0]!;color.pixelFormat = .bgra8Unorm;color.isBlendingEnabled=true
        color.sourceRGBBlendFactor = .sourceAlpha;color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one;color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state=try device.makeRenderPipelineState(descriptor:d);pipelines[name]=state;return state
    }

    private static let cube:[SIMD3<Float>]=[
        .init(-1,-1,-1),.init(1,-1,-1),.init(1,1,-1),.init(-1,1,-1),
        .init(-1,-1,1),.init(1,-1,1),.init(1,1,1),.init(-1,1,1)]
    private static func project(_ p:SIMD3<Float>)->SIMD2<Float> {
        .init((p.x-p.z)*84+320,p.y*93+(p.x+p.z)*32+180)
    }
    private func geometry(_ node:Node)->[Float] {
        var v=[Float]()
        func vertex(_ p:SIMD2<Float>,_ uv:SIMD3<Float>,_ data:SIMD3<Float>){v += [p.x/320-1,p.y/180-1,uv.x,uv.y,uv.z,data.x,data.y,data.z]}
        let thickness=Float(node.value("thickness"))/3,glow=Float(node.value("glow_radius"))/3
        func line(_ a:SIMD2<Float>,_ b:SIMD2<Float>,_ start:Float,_ end:Float,_ gap:Float=0){
            let length=hypot(b.x-a.x,b.y-a.y);guard length>2*gap else{return}
            let d=(b-a)/length,n=SIMD2<Float>(-d.y,d.x),extent=max(thickness/2+1,glow*1.75)
            let span=length-2*gap,source=a+d*gap
            for (x,y) in [(-extent,extent),(-extent,-extent),(span+extent,-extent),(-extent,extent),(span+extent,-extent),(span+extent,extent)]{
                vertex(source+d*x+n*y,.init(x,y,span),.init(start,end,1))
            }
        }
        let cube=Self.cube
        if node.kind == .boxEdges {
            for (a,b) in [(0,1),(1,2),(2,3),(3,0),(4,5),(5,6),(6,7),(7,4),(0,4),(1,5),(2,6),(3,7)] {line(Self.project(cube[a]),Self.project(cube[b]),0,1)}
        } else if node.kind == .triangulateFaces {
            let pts:[SIMD2<Float>]=[.init(88,104),.init(312,74),.init(552,117),.init(120,256),.init(332,280),.init(534,250)]
            let gap:Float=node.value("line_ends")==0 ? Float(node.value("edge_margin"))/3+22:0
            for (a,b) in [(0,1),(1,2),(0,3),(1,3),(1,4),(2,4),(2,5),(3,4),(4,5)] {line(pts[a],pts[b],Float(a),Float(b),gap)}
        } else {
            for (face,indices) in [[4,5,6,7],[1,2,6,5],[3,7,6,2]].enumerated() {
                for i in [0,1,2,0,2,3] {
                    let p=cube[indices[i]]
                    if node.kind == .boxWaterfall {vertex(Self.project(p),.init(p.x,p.z,1),.init(p.y,face==2 ? 1:0,1))}
                    else {vertex(Self.project(p),.init(p.x,p.y,1),.init(p.z,0,0))}
                }
            }
        }
        return v
    }
    func render(_ node:Node,time:Double,command:MTLCommandBuffer)throws->MTLTexture? {
        let name=node.kind == .boxEdges ? "mappedBoxEdges":node.kind == .sphereGimbal ? "mappedSphere":node.kind == .boxWaterfall ? "mappedWaterfall":"mappedTriangulate"
        let state=try pipeline(name)
        if textures[node.id]==nil {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:360,mipmapped:false)
            d.usage=[.renderTarget,.shaderRead];d.storageMode = .private;textures[node.id]=device.makeTexture(descriptor:d)
        }
        guard let target=textures[node.id] else{return nil}
        let pass=MTLRenderPassDescriptor();let attachment=pass.colorAttachments[0]!
        attachment.texture=target;attachment.loadAction = .clear;attachment.storeAction = .store
        attachment.clearColor=MTLClearColorMake(0,0,0,1)
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else{return nil}
        defer{encoder.endEncoding()}
        if node.kind == .triangulateFaces && node.value("lines")==0{return target}
        let vertices=geometry(node)
        guard let buffer=vertices.withUnsafeBytes({ p in p.baseAddress.flatMap {device.makeBuffer(bytes:$0,length:p.count)} }) else{return target}
        func f(_ key:String)->Float {Float(node.value(key))}
        let color=PaletteColor(hex:UInt32(node.value("color"))),rad=Float.pi/180
        let uniforms:[SIMD4<Float>]=[
            .init(Float(color.r),Float(color.g),Float(color.b),f("brightness")),.init(f("thickness")/3,f("glow_radius")/3,f("glow"),f("pulses")),
            .init(f("pulse_speed"),f("pulse_rate"),f("pulse_width"),f("pulse_amount")),.init(Float(time),5,f("pulse_direction"),f("sparkle")),
            .init(f("density"),f("width"),f("foam"),f("turbulence")),.init(f("speed"),f("trails"),f("tail"),f("spread")),
            .init(f("pose_x")*rad,f("pose_y")*rad,f("pose_z")*rad,f("fade_start")),.init(f("rotate_x")*rad,f("rotate_y")*rad,f("rotate_z")*rad,f("tail_fade"))]
        var opacity:Float=1
        encoder.setRenderPipelineState(state);encoder.setVertexBuffer(buffer,offset:0,index:0)
        uniforms.withUnsafeBytes{encoder.setFragmentBytes($0.baseAddress!,length:$0.count,index:0)}
        encoder.setFragmentBytes(&opacity,length:4,index:2);encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:vertices.count/8)
        return target
    }
}
