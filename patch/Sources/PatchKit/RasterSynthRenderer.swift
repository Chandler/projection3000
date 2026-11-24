import Foundation
import Metal
import PatchCore

final class RasterSynthRenderer {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    init(device: MTLDevice) throws {
        self.device=device
        let external=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Patch/User Nodes/Analog Raster.metal")
        let bundled=Bundle.main.resourceURL!.appendingPathComponent("User Nodes/Analog Raster.metal")
        let url=FileManager.default.fileExists(atPath:external.path) ? external:bundled
        let library=try device.makeLibrary(source:String(contentsOf:url,encoding:.utf8),options:nil)
        guard let function=library.makeFunction(name:"analogRaster") else { throw NSError(domain:"RasterSynth",code:1) }
        pipeline=try device.makeComputePipelineState(function:function)
    }
    func encode(_ history:[SIMD2<Float>],rate:Double,node:Node,time:Double,target:MTLTexture,command:MTLCommandBuffer) {
        let count=min(history.count,max(2,Int(rate*node.value("windowMS")/1000)))
        var start=max(0,history.count-count)
        // Both channels share one trigger and retain their relative phase.
        if node.value("trigger")>0.5,start>1 {
            for i in stride(from:start,through:1,by:-1) {
                if history[i-1].x<0 && history[i].x>=0 { start=i;break }
            }
        }
        let samples=count>0 ? Array(history[start..<start+count]):[SIMD2<Float>(0,0)]
        guard let buffer=samples.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }),let encoder=command.makeComputeCommandEncoder() else { return }
        var u=[SIMD4<Float>(Float(node.value("repeatX")),Float(node.value("repeatY")),Float(time*node.value("drift")),Float(count)),
               SIMD4<Float>(Float(node.value("gainX")),Float(node.value("gainY")),Float(node.value("warp")),Float(node.value("contrast"))),
               SIMD4<Float>(Float(node.value("mode")),Float(node.value("contours")),Float(node.value("rotation") * .pi/180),0),
               SIMD4<Float>(Float(node.value("hue")),Float(node.value("saturation")),Float(node.value("brightness")),Float(node.value("hueY")))]
        encoder.setComputePipelineState(pipeline);encoder.setTexture(target,index:0);encoder.setBuffer(buffer,offset:0,index:0)
        u.withUnsafeMutableBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
        encoder.dispatchThreads(MTLSize(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        encoder.endEncoding()
    }
}
