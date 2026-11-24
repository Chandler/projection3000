import Foundation
import Metal
import PatchCore

/// Frame-local GPU data: original RGB frame is the lossless residual reference.
/// The decoder uses original + (processed X - base X) + (processed Y - base Y).
struct ProfileVideoFrame {
    let source: MTLTexture
    let base: MTLBuffer
    let current: MTLBuffer
    let mean: MTLBuffer
}
final class ProfileVideoRenderer {
    private let device: MTLDevice
    private let extract, mean, process, decode: MTLComputePipelineState
    init(device: MTLDevice) throws {
        self.device=device
        let external=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Patch/User Nodes/RGB Profiles.metal")
        let bundled=Bundle.main.resourceURL!.appendingPathComponent("User Nodes/RGB Profiles.metal")
        let url=FileManager.default.fileExists(atPath:external.path) ? external:bundled
        let lib=try device.makeLibrary(source:String(contentsOf:url,encoding:.utf8),options:nil)
        func pipeline(_ name:String) throws -> MTLComputePipelineState { try device.makeComputePipelineState(function:lib.makeFunction(name:name)!) }
        extract=try pipeline("profileExtract");mean=try pipeline("profileMean");process=try pipeline("profileProcess");decode=try pipeline("profileDecode")
    }
    func capture(_ source:MTLTexture,command:MTLCommandBuffer) -> ProfileVideoFrame? {
        guard let p=device.makeBuffer(length:(source.width+source.height)*16,options:.storageModePrivate),let m=device.makeBuffer(length:16,options:.storageModePrivate),let e=command.makeComputeCommandEncoder() else{return nil}
        e.setComputePipelineState(extract);e.setTexture(source,index:0);e.setBuffer(p,offset:0,index:0)
        e.dispatchThreads(.init(width:source.width+source.height,height:1,depth:1),threadsPerThreadgroup:.init(width:64,height:1,depth:1));e.endEncoding()
        guard let a=command.makeComputeCommandEncoder() else{return nil}
        var w=UInt32(source.width);a.setComputePipelineState(mean);a.setBuffer(p,offset:0,index:0);a.setBuffer(m,offset:0,index:1);a.setBytes(&w,length:4,index:2)
        a.dispatchThreads(.init(width:1,height:1,depth:1),threadsPerThreadgroup:.init(width:1,height:1,depth:1));a.endEncoding()
        return ProfileVideoFrame(source:source,base:p,current:p,mean:m)
    }
    func manipulate(_ f:ProfileVideoFrame,node:Node,time:Double,command:MTLCommandBuffer) -> ProfileVideoFrame {
        guard node.value("amount")>0,let p=device.makeBuffer(length:f.current.length,options:.storageModePrivate),let e=command.makeComputeCommandEncoder() else{return f}
        var size=SIMD2<UInt32>(UInt32(f.source.width),UInt32(f.source.height))
        var u=[SIMD4<Float>(Float(node.value("gain")),Float(node.value("drive")),Float(node.value("bias")),Float(node.value("shift"))),
               SIMD4<Float>(Float(node.value("oscCycles")),Float(node.value("oscLevel")),Float(node.value("oscMix")),Float(node.value("smooth"))),
               SIMD4<Float>(Float(node.value("slotA")),Float(node.value("slotB")),Float(node.value("amount")),Float(time*node.value("speed")))]
        e.setComputePipelineState(process);e.setBuffer(f.current,offset:0,index:0);e.setBuffer(p,offset:0,index:1);e.setBuffer(f.mean,offset:0,index:2);e.setBytes(&size,length:8,index:3)
        u.withUnsafeMutableBytes{e.setBytes($0.baseAddress!,length:$0.count,index:4)}
        e.dispatchThreads(.init(width:f.source.width+f.source.height,height:1,depth:1),threadsPerThreadgroup:.init(width:64,height:1,depth:1));e.endEncoding()
        return ProfileVideoFrame(source:f.source,base:f.base,current:p,mean:f.mean)
    }
    func render(_ f:ProfileVideoFrame,target:MTLTexture,view:Double,mix:Double,command:MTLCommandBuffer) {
        guard let e=command.makeComputeCommandEncoder() else{return}
        var size=SIMD2<UInt32>(UInt32(f.source.width),UInt32(f.source.height)),controls=SIMD2<Float>(Float(view),Float(mix))
        e.setComputePipelineState(decode);e.setTexture(f.source,index:0);e.setTexture(target,index:1)
        e.setBuffer(f.base,offset:0,index:0);e.setBuffer(f.current,offset:0,index:1);e.setBuffer(f.mean,offset:0,index:2)
        e.setBytes(&size,length:8,index:3);e.setBytes(&controls,length:8,index:4)
        e.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));e.endEncoding()
    }
}
