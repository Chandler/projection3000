import Foundation
import Metal
import MetalPerformanceShaders
import PatchCore

final class DitherRenderer {
    struct Parameters {
        var render = SIMD4<Float>.zero
        var preparation = SIMD4<Float>.zero
        var tone = SIMD4<Float>.zero
        var mapping = SIMD4<Float>.zero
        var high = SIMD4<Float>.zero
        var mid = SIMD4<Float>.zero
        var low = SIMD4<Float>.zero
        var background = SIMD4<Float>.zero
    }
    struct Resource { let textures: [MTLTexture]; var kernels: [String:(Double,MPSImageGaussianBlur)] = [:] }
    let device: MTLDevice
    let resample: MTLComputePipelineState
    let denoise: MTLComputePipelineState
    let prepare: MTLComputePipelineState
    let quantize: MTLComputePipelineState
    private var resources: [UUID:Resource] = [:]
    init(device: MTLDevice,library: MTLLibrary) throws {
        self.device = device
        resample = try device.makeComputePipelineState(function:library.makeFunction(name:"ditherResample")!)
        denoise = try device.makeComputePipelineState(function:library.makeFunction(name:"ditherDenoise")!)
        prepare = try device.makeComputePipelineState(function:library.makeFunction(name:"ditherPrepare")!)
        quantize = try device.makeComputePipelineState(function:library.makeFunction(name:"ditherQuantize")!)
    }
    func retain(_ ids: Set<UUID>) { resources = resources.filter { ids.contains($0.key) } }
    private func color(_ value: Double,_ level: Double) -> SIMD4<Float> {
        let c = Int(value.rounded()); return .init(Float((c>>16)&255)/255,Float((c>>8)&255)/255,Float(c&255)/255,Float(level))
    }
    func encode(_ command: MTLCommandBuffer,node: Node,source: MTLTexture,target: MTLTexture) -> Bool {
        let scale = min(node.value("dpi")/72/max(1,node.value("cell").rounded()),min(3840.0/Double(target.width),2160.0/Double(target.height)))
        let width = min(3840,max(1,Int((Double(target.width)*scale).rounded()))), height = min(2160,max(1,Int((Double(target.height)*scale).rounded())))
        if resources[node.id]?.textures.first?.width != width || resources[node.id]?.textures.first?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
            d.storageMode = .private; d.usage = [.shaderRead,.shaderWrite]
            let textures = (0..<5).compactMap { _ in device.makeTexture(descriptor:d) }
            guard textures.count == 5 else { return false }; resources[node.id] = Resource(textures:textures)
        }
        guard var resource = resources[node.id] else { return false }
        let t = resource.textures
        var p = Parameters()
        p.render = .init(Float(node.value("resampling")),Float(node.parameters["algorithm"] ?? node.value("matrix")),Float(node.value("levels").rounded()),Float(node.value("angle") * .pi/180))
        p.preparation = .init(Float(node.value("sharpen")/100),Float(node.value("noise")/100),Float(node.value("denoise")/100),Float(node.value("seed")))
        p.tone = .init(Float(node.value("brightness")/100),Float(pow(2,node.value("contrast")/50)),Float(node.value("gamma")),Float(node.value("mix")))
        p.mapping = .init(Float(node.parameters["tonal"] ?? node.value("mono")),Float(node.value("background")),0,0)
        p.high = color(node.value("highlightColor"),node.value("highlightLevel"))
        p.mid = color(node.value("midtoneColor"),node.value("midtoneLevel"))
        p.low = color(node.value("shadowColor"),node.value("shadowLevel"))
        p.background = color(node.value("backgroundColor"),0)
        func pass(_ pipeline: MTLComputePipelineState,_ textures: [MTLTexture],_ output: MTLTexture) -> Bool {
            guard let encoder = command.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(pipeline)
            for (index,texture) in textures.enumerated() { encoder.setTexture(texture,index:index) }
            encoder.setBytes(&p,length:MemoryLayout<Parameters>.stride,index:0)
            encoder.dispatchThreads(.init(width:output.width,height:output.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); encoder.endEncoding(); return true
        }
        func gaussian(_ key: String,_ radius: Double,_ source: MTLTexture,_ destination: MTLTexture) {
            let sigma = max(0.15,radius*scale)
            if resource.kernels[key]?.0 != sigma {
                let kernel = MPSImageGaussianBlur(device:device,sigma:Float(sigma)); kernel.edgeMode = .clamp; resource.kernels[key] = (sigma,kernel)
            }
            resource.kernels[key]!.1.encode(commandBuffer:command,sourceTexture:source,destinationTexture:destination)
        }
        guard pass(resample,[source,t[0]],t[0]) else { return false }
        var current = t[0]
        if node.value("denoise") > 0 {
            guard pass(denoise,[current,t[1]],t[1]) else { return false }; current = t[1]
        }
        if node.value("blur") > 0 { gaussian("blur",node.value("blur"),current,t[2]); current = t[2] }
        if node.value("sharpen") > 0 { gaussian("sharpen",node.value("sharpenRadius"),current,t[3]) }
        guard pass(prepare,[current,node.value("sharpen") > 0 ? t[3] : current,t[4]],t[4]) else { return false }
        resources[node.id] = resource
        return pass(quantize,[t[4],source,target],target)
    }
}
