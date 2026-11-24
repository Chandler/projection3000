import Foundation
import Metal
import QuartzCore
import PatchCore

/// All mutable resources live on the render queue. Clustering runs on a separate queue.
final class PaletteRenderer {
    private final class Extraction {
        var palette = ColorPalette.empty
        var pending = false
        var sampled = -Double.infinity
        var completed = 0.0
    }
    private let device: MTLDevice
    private let samplePipeline: MTLComputePipelineState
    private let previewPipeline: MTLComputePipelineState
    private let worker = DispatchQueue(label:"patch.palette.extract",qos:.utility)
    private var extractions: [UUID:Extraction] = [:]
    private var previews: [UUID:(ColorPalette,MTLTexture)] = [:]
    init(device: MTLDevice,library: MTLLibrary) throws {
        self.device=device
        samplePipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"paletteSample")!)
        previewPipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"palettePreview")!)
    }
    func invalidate(_ id: UUID) { extractions[id]=nil }
    func retain(_ ids: Set<UUID>) { extractions=extractions.filter { ids.contains($0.key) }; previews=previews.filter { ids.contains($0.key) } }
    func extract(_ node: Node,source: MTLTexture,command: MTLCommandBuffer,renderQueue: DispatchQueue) -> ColorPalette {
        let resource=extractions[node.id] ?? Extraction(); extractions[node.id]=resource
        let now=CACurrentMediaTime()
        if !resource.pending, now-resource.sampled >= 1/max(1,node.value("rate")),
           let buffer=device.makeBuffer(length:32*32*MemoryLayout<SIMD4<Float>>.stride,options:.storageModeShared),
           let encoder=command.makeComputeCommandEncoder() {
            resource.pending=true; resource.sampled=now
            encoder.setComputePipelineState(samplePipeline); encoder.setTexture(source,index:0); encoder.setBuffer(buffer,offset:0,index:0)
            encoder.dispatchThreads(.init(width:32,height:32,depth:1),threadsPerThreadgroup:.init(width:8,height:8,depth:1)); encoder.endEncoding()
            let previous=resource.palette, last=resource.completed, smoothing=node.value("smoothing")
            let count=Int(node.value("count").rounded()), order=Int(node.value("order"))
            command.addCompletedHandler { [worker] completed in
                guard completed.status == .completed else { renderQueue.async { resource.pending=false }; return }
                worker.async {
                    let pixels=Array(UnsafeBufferPointer(start:buffer.contents().assumingMemoryBound(to:SIMD4<Float>.self),count:32*32))
                    var palette=PaletteStyle.extract(pixels,count:count,order:order,previous:previous)
                    if smoothing>0, previous.colors.count==palette.colors.count, last>0 {
                        let mix=1-exp(-max(0.001,now-last)/smoothing)
                        palette.colors=zip(previous.colors,palette.colors).map { $0.mixed(with:$1,amount:mix) }
                    }
                    let result=palette
                    renderQueue.async { resource.palette=result; resource.completed=now; resource.pending=false }
                }
            }
        }
        return resource.palette
    }
    func preview(_ palette: ColorPalette,id: UUID,command: MTLCommandBuffer) -> MTLTexture? {
        if let (old,texture)=previews[id], old==palette { return texture }
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:160,mipmapped:false)
        descriptor.usage=[.shaderRead,.shaderWrite]; descriptor.storageMode = .private
        guard let texture=previews[id]?.1 ?? device.makeTexture(descriptor:descriptor),let encoder=command.makeComputeCommandEncoder() else { return nil }
        var count=UInt32(palette.colors.count)
        let colors=palette.colors.isEmpty ? [SIMD4<Float>(0,0,0,1)] : palette.colors.map { SIMD4<Float>(Float($0.r),Float($0.g),Float($0.b),1) }
        encoder.setComputePipelineState(previewPipeline); encoder.setTexture(texture,index:0)
        colors.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
        encoder.setBytes(&count,length:4,index:1)
        encoder.dispatchThreads(.init(width:640,height:160,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); encoder.endEncoding()
        previews[id]=(palette,texture); return texture
    }
}
