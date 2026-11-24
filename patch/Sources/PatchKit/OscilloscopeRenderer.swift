import Metal
import PatchCore

/// Time-domain traces share the XY renderer's antialiased line shader.
/// Peak-preserving reduction bounds geometry by display width, not capture rate.
final class OscilloscopeRenderer {
    private let device: MTLDevice
    private var pipelines: [Int:MTLRenderPipelineState]=[:]
    private final class Buffers {
        var slots=[MTLBuffer?](repeating:nil,count:3)
        var index=0
        var multisample: MTLTexture?
    }
    private struct Stroke {
        var start: Int
        var count: Int
        var color: SIMD3<Float>
        var width: Float
        var alpha: Float
        var pairs: Bool
    }
    private var buffers: [UUID:Buffers]=[:]
    init(device: MTLDevice) throws {
        self.device=device
        let library=try device.makeLibrary(source:voltageShaders,options:nil)
        for samples in (device.supportsTextureSampleCount(4) ? [1,4]:[1]) {
            let d=MTLRenderPipelineDescriptor()
            d.rasterSampleCount=samples
            d.vertexFunction=library.makeFunction(name:"scopeVertex")
            d.fragmentFunction=library.makeFunction(name:"scopeFragment")
            let a=d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm;a.isBlendingEnabled=true
            a.sourceRGBBlendFactor = .one;a.destinationRGBBlendFactor = .one;a.rgbBlendOperation = .max
            a.sourceAlphaBlendFactor = .one;a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelines[samples]=try device.makeRenderPipelineState(descriptor:d)
        }
    }
    func prune(_ ids: Set<UUID>) { buffers=buffers.filter { ids.contains($0.key) } }

    @discardableResult
    func encode(_ history: [SIMD2<Float>],sampleRate: Double,node: Node,target: MTLTexture,command: MTLCommandBuffer) -> Bool {
        let window=max(2,Int((sampleRate*node.value("timeMS")/1000).rounded()))
        let channels=Int(node.value("channels")),trigger=Int(node.value("trigger"))
        let triggerChannel=channels == 1 ? 0:channels == 2 ? 1:Int(node.value("triggerChannel"))
        let level=Float(node.value("triggerLevel"))
        var start=max(0,history.count-window),triggered=false
        // Pick the newest crossing with a full sweep already captured after it.
        if trigger>0,history.count>window+1 {
            for i in stride(from:history.count-window,through:1,by:-1) {
                let a=history[i-1][triggerChannel],b=history[i][triggerChannel]
                if trigger == 1 ? a<level && b>=level:a>level && b<=level {
                    start=i;triggered=true;break
                }
            }
        }
        let count=min(window,history.count-start)
        var points=[SIMD2<Float>](),strokes=[Stroke]()
        let colors: [SIMD3<Float>]=[SIMD3(0.18,1,0.45),SIMD3(1,0.57,0.14)]
        if node.value("grid")>0.5 {
            let gridStart=points.count
            for i in 0...10 {
                let x=Float(i)/10*1.88-0.94
                points += [SIMD2(x,-0.9),SIMD2(x,0.9)]
            }
            for i in 0...8 {
                let y=Float(i)/8*1.8-0.9
                points += [SIMD2(-0.94,y),SIMD2(0.94,y)]
            }
            strokes.append(Stroke(start:gridStart,count:points.count-gridStart,color:SIMD3(0.17,0.23,0.25),width:0.75,alpha:0.65,pairs:true))
            let zeroStart=points.count
            points += [SIMD2(-0.94,0),SIMD2(0.94,0)]
            strokes.append(Stroke(start:zeroStart,count:2,color:SIMD3(0.28,0.37,0.39),width:1,alpha:0.8,pairs:true))
        }
        if count>1 {
            for channel in 0...1 where channels == 0 || channel == channels-1 {
                let traceStart=points.count
                let gain=Float(node.value(channel == 0 ? "gainX":"gainY"))
                let offset=Float(node.value(channel == 0 ? "offsetX":"offsetY"))
                func point(_ i: Int) -> SIMD2<Float> {
                    SIMD2(-0.94+Float(i)/Float(window-1)*1.88,history[start+i][channel]*gain*0.9+offset*0.9)
                }
                let bins=min(count,max(2,target.width))
                for bin in 0..<bins {
                    let lower=bin*count/bins,upper=(bin+1)*count/bins
                    var low=lower,high=lower
                    for i in lower..<upper {
                        if history[start+i][channel]<history[start+low][channel] { low=i }
                        if history[start+i][channel]>history[start+high][channel] { high=i }
                    }
                    // Keep extrema in chronological order so fast edges stay visible.
                    if low == high { points.append(point(low)) }
                    else { points.append(point(min(low,high)));points.append(point(max(low,high))) }
                }
                strokes.append(Stroke(start:traceStart,count:points.count-traceStart,color:colors[channel],width:Float(node.value("width")),alpha:Float(node.value("brightness")),pairs:false))
            }
        }
        let resource=buffers[node.id] ?? Buffers();buffers[node.id]=resource
        let samples=node.value("antialias")>0.5 && pipelines[4] != nil ? 4:1
        let pass=MTLRenderPassDescriptor(),attachment=pass.colorAttachments[0]!
        attachment.texture=target;attachment.loadAction = .clear;attachment.storeAction = .store
        attachment.clearColor=MTLClearColorMake(0,0,0,1)
        if samples>1 {
            if resource.multisample?.width != target.width || resource.multisample?.height != target.height {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:target.pixelFormat,width:target.width,height:target.height,mipmapped:false)
                d.textureType = .type2DMultisample;d.sampleCount=samples;d.usage = .renderTarget;d.storageMode = .private
                resource.multisample=device.makeTexture(descriptor:d)
            }
            guard let texture=resource.multisample else { return triggered }
            attachment.texture=texture;attachment.resolveTexture=target;attachment.storeAction = .multisampleResolve
        }
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { return triggered }
        defer { encoder.endEncoding() }
        guard !points.isEmpty else { return triggered }
        let slot=resource.index%3,bytes=points.count*MemoryLayout<SIMD2<Float>>.stride
        if (resource.slots[slot]?.length ?? 0)<bytes { resource.slots[slot]=device.makeBuffer(length:max(bytes,16384),options:.storageModeShared) }
        guard let buffer=resource.slots[slot] else { return triggered }
        points.withUnsafeBytes { buffer.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
        resource.index += 1
        encoder.setRenderPipelineState(pipelines[samples]!)
        for stroke in strokes where stroke.count>1 {
            encoder.setVertexBuffer(buffer,offset:stroke.start*MemoryLayout<SIMD2<Float>>.stride,index:0)
            var u=[SIMD4<Float>(1/0.92,1/0.92,Float(target.width),Float(target.height)),SIMD4(stroke.width,stroke.color.x,stroke.color.y,stroke.color.z),SIMD4<Float>(stroke.alpha,stroke.pairs ? 1:0,1,0),SIMD4<Float>.zero]
            u.withUnsafeMutableBytes { encoder.setVertexBytes($0.baseAddress!,length:$0.count,index:1) }
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:stroke.pairs ? stroke.count/2:stroke.count-1)
        }
        return triggered
    }
}
