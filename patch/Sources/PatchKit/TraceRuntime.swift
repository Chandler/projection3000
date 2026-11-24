import Foundation
import Metal
import PatchCore
import OutputBridge

/// Render-queue owned. A trace publishes a recipe, never a destination-sized movie.
final class TraceRuntime {
    struct Motion {
        var anchor=0.0, last=0.0, distance=0.0, jitterDistance=0.0
        var speed=0.0, jitter=0.0
        var external=false
    }
    let device: MTLDevice
    let pipeline: MTLComputePipelineState
    var textures: [UUID:MTLTexture]=[:]
    var motions: [UUID:Motion]=[:]
    var heldPalettes: [UUID:ColorPalette]=[:]
    init(device: MTLDevice,library: MTLLibrary) throws {
        self.device=device
        guard let function=library.makeFunction(name:"tracePreview") else { throw GraphError("Missing trace preview shader") }
        pipeline=try device.makeComputePipelineState(function:function)
    }
    func retain(_ ids: Set<UUID>) {
        textures=textures.filter { ids.contains($0.key) };motions=motions.filter { ids.contains($0.key) };heldPalettes=heldPalettes.filter { ids.contains($0.key) }
    }
    func render(_ node: Node,palette: ColorPalette?,phase: Double?,time: Double,command: MTLCommandBuffer,preview: Bool = true) -> (MTLTexture?,[String:Any]) {
        let t=phase.map { min(1,max(0,$0))*node.value("cycle") } ?? time
        var motion=motions[node.id] ?? Motion(speed:node.value("speed"),jitter:node.value("jitter"),external:phase != nil)
        if phase != nil || motion.external || t<motion.last {
            motion=Motion(speed:node.value("speed"),jitter:node.value("jitter"),external:phase != nil)
        } else if motion.speed != node.value("speed") || motion.jitter != node.value("jitter") {
            motion.distance += (t-motion.anchor)*motion.speed
            motion.jitterDistance += (t-motion.anchor)*motion.speed*motion.jitter
            motion.anchor=t;motion.speed=node.value("speed");motion.jitter=node.value("jitter")
        }
        motion.last=t;motions[node.id]=motion
        if let palette,!palette.colors.isEmpty { heldPalettes[node.id]=palette }
        if palette == nil { heldPalettes.removeValue(forKey:node.id) }
        let colors=(palette == nil ? [] : heldPalettes[node.id]?.colors ?? []).prefix(256)
        var p=TraceStyle.recipeParameters(node)
        p["_motion_time"]=motion.anchor;p["_motion_distance"]=motion.distance;p["_motion_jitter_distance"]=motion.jitterDistance
        let recipe: [String:Any] = ["version":1,"kind":"lightningPulses","params":p,"time":t,"phaseDriven":phase != nil,"paletteConnected":palette != nil,"colors":colors.map { ["r":$0.r,"g":$0.g,"b":$0.b] }]
        guard preview else { return (nil,recipe) }
        var config=PatchTraceConfig()
        config.rate=node.value("rate");config.burst=node.value("burst");config.speed=node.value("speed");config.jitter=node.value("jitter")
        config.length=node.value("length");config.tail=node.value("tail");config.crackle=node.value("crackle");config.forks=node.value("forks")
        config.spray=node.value("top_spray");config.brightness=node.value("brightness");config.rainbow=node.value("rainbow")
        config.start=node.value("start");config.end=node.value("end");config.reverse=node.value("origin")>=0.5 ? 1:0
        config.reflect=node.value("reflect")>=0.5 ? 1:0;config.singleColor=node.value("single_color")>=0.5 ? 1:0;config.seed=UInt32(node.value("seed").rounded())
        config.motionTime=motion.anchor;config.motionDistance=motion.distance;config.motionJitterDistance=motion.jitterDistance
        let core=PaletteColor(hex:UInt32(node.value("core").rounded())),glow=PaletteColor(hex:UInt32(node.value("glow").rounded()))
        config.core=PatchTraceColor(r:core.r,g:core.g,b:core.b);config.glow=PatchTraceColor(r:glow.r,g:glow.g,b:glow.b)
        let input=colors.map { PatchTraceColor(r:$0.r,g:$0.g,b:$0.b) }
        let samples: [SIMD4<Float>] = input.withUnsafeBufferPointer { buffer in
            (0..<1024).map { i in
                if palette != nil && input.isEmpty { return .zero }
                let c=patch_trace_sample(config,buffer.baseAddress,Int32(buffer.count),Double(i)/1023,t,0)
                return .init(Float(c.r),Float(c.g),Float(c.b),1)
            }
        }
        if textures[node.id] == nil {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:360,mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite];d.storageMode = .private;textures[node.id]=device.makeTexture(descriptor:d)
        }
        guard let texture=textures[node.id],let buffer=samples.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }),let e=command.makeComputeCommandEncoder() else { return (nil,recipe) }
        e.setComputePipelineState(pipeline);e.setTexture(texture,index:0);e.setBuffer(buffer,offset:0,index:0)
        e.dispatchThreads(.init(width:640,height:360,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));e.endEncoding()
        return (texture,recipe)
    }
}
