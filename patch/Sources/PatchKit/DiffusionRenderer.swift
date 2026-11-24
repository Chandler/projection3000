import Metal
import MetalPerformanceShaders
import PatchCore
import Foundation

// Render-queue confined; all passes share the graph command buffer. Half-float
// intermediates avoid clipping the linear-light highlight and halo passes.
final class DiffusionRenderer {
    let device: MTLDevice
    let extract: MTLComputePipelineState
    let combine: MTLComputePipelineState
    struct Resources {
        let textures: [MTLTexture]
        let radius: Double
        let narrow: MPSImageGaussianBlur
        let broad: MPSImageGaussianBlur
    }
    var resources: [UUID:Resources] = [:]
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        extract = try device.makeComputePipelineState(function:library.makeFunction(name:"glowExtract")!)
        combine = try device.makeComputePipelineState(function:library.makeFunction(name:"glowCombine")!)
    }
    func retain(_ ids: Set<UUID>) { resources = resources.filter { ids.contains($0.key) } }
    func encode(_ command: MTLCommandBuffer,node: Node,source: MTLTexture,target: MTLTexture) {
        let width = max(1,target.width/2), height = max(1,target.height/2), radius = node.value("radius")
        if resources[node.id]?.textures.first?.width != width || resources[node.id]?.textures.first?.height != height || resources[node.id]?.radius != radius {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
            desc.storageMode = .private; desc.usage = [.shaderRead,.shaderWrite]
            let previous = resources[node.id]?.textures
            let textures = previous?.first?.width == width && previous?.first?.height == height ? previous! : (0..<3).compactMap { _ in device.makeTexture(descriptor:desc) }
            guard textures.count == 3 else { return }
            let narrow = MPSImageGaussianBlur(device:device,sigma:Float(radius*0.15))
            let broad = MPSImageGaussianBlur(device:device,sigma:Float(radius*0.5))
            narrow.edgeMode = .clamp; broad.edgeMode = .clamp
            resources[node.id] = Resources(textures:textures,radius:radius,narrow:narrow,broad:broad)
        }
        guard let r = resources[node.id], let enc = command.makeComputeCommandEncoder() else { return }
        var controls = SIMD4<Float>(Float(node.value("threshold")),Float(node.value("knee")),Float(node.value("strength")),Float(node.value("saturation")))
        enc.setComputePipelineState(extract); enc.setTexture(source,index:0); enc.setTexture(r.textures[0],index:1)
        enc.setBytes(&controls,length:16,index:0)
        enc.dispatchThreads(.init(width:width,height:height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); enc.endEncoding()
        r.narrow.encode(commandBuffer:command,sourceTexture:r.textures[0],destinationTexture:r.textures[1])
        r.broad.encode(commandBuffer:command,sourceTexture:r.textures[0],destinationTexture:r.textures[2])
        guard let final = command.makeComputeCommandEncoder() else { return }
        final.setComputePipelineState(combine); final.setTexture(source,index:0); final.setTexture(r.textures[1],index:1); final.setTexture(r.textures[2],index:2); final.setTexture(target,index:3)
        final.setBytes(&controls,length:16,index:0)
        final.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); final.endEncoding()
    }
}
