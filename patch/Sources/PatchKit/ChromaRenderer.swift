import Metal
import QuartzCore
import PatchCore

/// Render-queue owned. Only the tiny color grid is read back; full-size references
/// stay on the GPU in a bounded history and are selected by the audio frame ID.
final class ChromaRenderer {
    private let device: MTLDevice
    private let downsample: MTLComputePipelineState
    private let combine: MTLComputePipelineState
    private struct Reference {
        var format: ChromaFormat
        var nextID: UInt16=1
        var lastCapture: Double = -Double.infinity
        var frames: [UInt16:MTLTexture]=[:]
        var order: [UInt16]=[]
        var pending=0
    }
    private var references: [UUID:Reference]=[:]
    private var colorTextures: [UUID:(UInt16,ChromaFormat,MTLTexture)]=[:]
    private let neutral: MTLTexture
    init(device: MTLDevice) throws {
        self.device=device
        let library=try device.makeLibrary(source:Self.shader,options:nil)
        downsample=try device.makeComputePipelineState(function:library.makeFunction(name:"chromaSample")!)
        combine=try device.makeComputePipelineState(function:library.makeFunction(name:"chromaCombine")!)
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rg32Float,width:1,height:1,mipmapped:false)
        desc.storageMode = .shared;desc.usage = .shaderRead
        neutral=device.makeTexture(descriptor:desc)!
        var zero=SIMD2<Float>.zero
        neutral.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&zero,bytesPerRow:8)
    }
    func retain(_ ids: Set<UUID>) {
        references=references.filter { ids.contains($0.key) };colorTextures=colorTextures.filter { ids.contains($0.key) }
    }
    func capture(_ source: MTLTexture,node: Node,now: Double,command: MTLCommandBuffer,queue: DispatchQueue,bridge: ChromaBridge) {
        let format=ChromaFormat(format:Int(node.value("format")),fps:node.value("fps"),carrierProfile:Int(node.value("carrierProfile")))
        if references[node.id]?.format != format { references[node.id]=Reference(format:format) }
        guard var ref=references[node.id],now-ref.lastCapture>=1/format.fps-0.001,ref.pending<2 else { return }
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:source.pixelFormat,width:source.width,height:source.height,mipmapped:false)
        desc.storageMode = .private;desc.usage = [.shaderRead]
        guard let texture=device.makeTexture(descriptor:desc),
              let buffer=device.makeBuffer(length:format.pixels*8,options:.storageModeShared),
              let encoder=command.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(downsample);encoder.setTexture(source,index:0);encoder.setBuffer(buffer,offset:0,index:0)
        var size=SIMD2<UInt32>(UInt32(format.width),UInt32(format.height))
        encoder.setBytes(&size,length:8,index:1)
        encoder.dispatchThreads(.init(width:format.width,height:format.height,depth:1),threadsPerThreadgroup:.init(width:8,height:8,depth:1));encoder.endEncoding()
        guard let blit=command.makeBlitCommandEncoder() else { return }
        blit.copy(from:source,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:source.width,height:source.height,depth:1),to:texture,destinationSlice:0,destinationLevel:0,destinationOrigin:.init(x:0,y:0,z:0));blit.endEncoding()
        let id=ref.nextID;ref.nextID = id == UInt16.max ? 1:id+1
        ref.lastCapture=ref.lastCapture.isFinite ? max(ref.lastCapture+1/format.fps,now-1/format.fps):now
        ref.pending += 1;references[node.id]=ref
        command.addCompletedHandler { [weak self] completed in
            guard completed.status == .completed else {
                queue.async { if self?.references[node.id]?.format == format { self?.references[node.id]?.pending -= 1 } }
                return
            }
            let values=Array(UnsafeBufferPointer(start:buffer.contents().assumingMemoryBound(to:SIMD2<Float>.self),count:format.pixels))
            queue.async {
                guard let self,var current=self.references[node.id],current.format == format else { return }
                current.pending -= 1;current.frames[id]=texture;current.order.append(id)
                while current.order.count>12 { current.frames.removeValue(forKey:current.order.removeFirst()) }
                self.references[node.id]=current
                bridge.submit(ChromaFrame(id:id,format:format,colors:values),id:node.id)
            }
        }
    }
    func encode(_ node: Node,reference: UUID?,fallback: MTLTexture,returned: ChromaBridge.Return?,target: MTLTexture,now: Double,command: MTLCommandBuffer) -> String {
        let ref=reference.flatMap { references[$0] }
        let live=node.value("decodeMode")>0.5
        let fresh=returned.map { now-$0.time<0.5 && $0.frame.format == ref?.format && $0.freeRunning == live } ?? false
        let paired=fresh && !live ? returned.flatMap { ref?.frames[$0.frame.id] }:nil
        let hasColor=fresh && (live || paired != nil)
        let source=paired ?? ref?.order.last.flatMap { ref?.frames[$0] } ?? fallback
        var color=neutral
        if let returned,hasColor {
            let frame=returned.frame
            if colorTextures[node.id]?.0 != frame.id || colorTextures[node.id]?.1 != frame.format {
                let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rg32Float,width:frame.format.width,height:frame.format.height,mipmapped:false)
                desc.storageMode = .shared;desc.usage = .shaderRead
                if let texture=device.makeTexture(descriptor:desc) {
                    frame.colors.withUnsafeBytes { data in
                        texture.replace(region:MTLRegionMake2D(0,0,frame.format.width,frame.format.height),mipmapLevel:0,withBytes:data.baseAddress!,bytesPerRow:frame.format.width*8)
                    }
                    colorTextures[node.id]=(frame.id,frame.format,texture)
                }
            }
            color=colorTextures[node.id]?.2 ?? neutral
        }
        if let encoder=command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(combine);encoder.setTexture(source,index:0);encoder.setTexture(color,index:1);encoder.setTexture(target,index:2)
            var params=SIMD4<Float>(Float(node.value("saturation")),Float(node.value("hue")*Double.pi/180),Float(node.value("view")),Float(node.value("interpolation")))
            encoder.setBytes(&params,length:16,index:0)
            encoder.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));encoder.endEncoding()
        }
        guard reference != nil else { return "Connect encoder Frame Reference and returned audio" }
        guard let returned,hasColor else { return live ? "Waiting for live audio · no lock required":"No color lock · showing original luma" }
        if live { return String(format:"Live color · %d × %d · %.2f fps · no lock required",returned.frame.format.width,returned.frame.format.height,returned.frame.format.fps) }
        return String(format:"%d × %d color · %.2f fps · locked %.0f%% · frame %d",returned.frame.format.width,returned.frame.format.height,returned.frame.format.fps,returned.correlation*100,Int(returned.frame.id))
    }
    private static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    kernel void chromaSample(texture2d<float,access::sample> source [[texture(0)]],device float2 *colors [[buffer(0)]],constant uint2 &size [[buffer(1)]],uint2 p [[thread_position_in_grid]]) {
        if(any(p>=size)) return;
        constexpr sampler linear(coord::normalized,filter::linear,address::clamp_to_edge);
        float3 rgb=0;
        for(uint y=0;y<8;y++) for(uint x=0;x<8;x++) {
            float2 uv=(float2(p)+(float2(x,y)+0.5)/8.0)/float2(size);
            rgb+=source.sample(linear,uv).rgb;
        }
        rgb/=64.0;
        float luma=dot(rgb,float3(0.2126,0.7152,0.0722));
        colors[p.y*size.x+p.x]=float2((rgb.b-luma)/0.9278,(rgb.r-luma)/0.7874);
    }
    kernel void chromaCombine(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::sample> colors [[texture(1)]],texture2d<float,access::write> out [[texture(2)]],constant float4 &params [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
        if(p.x>=out.get_width() || p.y>=out.get_height()) return;
        constexpr sampler linear(coord::normalized,filter::linear,address::clamp_to_edge);
        constexpr sampler nearest(coord::normalized,filter::nearest,address::clamp_to_edge);
        float2 uv=(float2(p)+0.5)/float2(out.get_width(),out.get_height());
        float3 original=source.sample(linear,uv).rgb;
        if(params.z>0.5 && params.z<1.5) { out.write(float4(original,1),p);return; }
        float y=dot(original,float3(0.2126,0.7152,0.0722));
        float2 c=(params.w>0.5 ? colors.sample(linear,uv):colors.sample(nearest,uv)).rg*0.5*params.x;
        c=float2(c.x*cos(params.y)-c.y*sin(params.y),c.x*sin(params.y)+c.y*cos(params.y));
        if(params.z>1.5 && params.z<2.5) y=0.5;
        if(params.z>2.5) c=0;
        float r=y+1.5748*c.y,b=y+1.8556*c.x;
        float g=(y-0.2126*r-0.0722*b)/0.7152;
        out.write(float4(clamp(float3(r,g,b),0.0,1.0),1),p);
    }
    """
}
