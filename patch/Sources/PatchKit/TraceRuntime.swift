import Foundation
import Metal
import PatchCore
import OutputBridge

/// Render-queue owned. A trace publishes a recipe, never a destination-sized movie.
final class TraceRuntime {
    struct Motion {
        var anchor=0.0, last=0.0, distance=0.0, jitterDistance=0.0
        var speed=0.0, jitter=0.0
        var rate=0.0,ratePhase=0.0
        var external=false
    }
    let device: MTLDevice
    let pipeline: MTLComputePipelineState
    let samplePipeline: MTLComputePipelineState
    var samples: [UUID:MTLBuffer]=[:]
    var textures: [UUID:MTLTexture]=[:]
    var motions: [UUID:Motion]=[:]
    var heldPalettes: [UUID:ColorPalette]=[:]
    init(device: MTLDevice,library: MTLLibrary) throws {
        self.device=device
        guard let function=library.makeFunction(name:"tracePreview") else { throw GraphError("Missing trace preview shader") }
        pipeline=try device.makeComputePipelineState(function:function)
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        using PatchTraceReal=float;
        using PatchTraceSeed=uint;
        #define PATCH_TRACE_ADDRESS constant
        \(String(cString:patch_trace_metal_math()))
        kernel void sampleTrace(device float4* samples [[buffer(0)]],
              constant PatchTraceConfig& lightning [[buffer(1)]],constant PatchLineTrace& line [[buffer(2)]],
              constant PatchTraceColor* colors [[buffer(3)]],constant float4& state [[buffer(4)]],uint i [[thread_position_in_grid]]) {
            if(i>=1024)return;
            float x=float(i)/1023;
            if(state.w<0){samples[i]=float4(0);return;}
            PatchTraceColor c=state.z>0 ? patch_trace_sample(lightning,colors,int(state.w),x,state.x,0)
                                        : patch_line_sample(line,x,state.x,state.y);
            samples[i]=float4(c.r,c.g,c.b,1);
        }
        """
        guard let sample=try device.makeLibrary(source:source,options:nil).makeFunction(name:"sampleTrace") else { throw GraphError("Missing trace sampler") }
        samplePipeline=try device.makeComputePipelineState(function:sample)
    }
    func retain(_ ids: Set<UUID>) {
        samples=samples.filter { ids.contains($0.key) }
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
        var config=PatchGPUTraceConfig()
        config.rate=Float(node.value("rate"));config.burst=Float(node.value("burst"));config.speed=Float(node.value("speed"));config.jitter=Float(node.value("jitter"))
        config.length=Float(node.value("length"));config.tail=Float(node.value("tail"));config.crackle=Float(node.value("crackle"));config.forks=Float(node.value("forks"))
        config.spray=Float(node.value("top_spray"));config.brightness=Float(node.value("brightness"));config.rainbow=Float(node.value("rainbow"))
        config.start=Float(node.value("start"));config.end=Float(node.value("end"));config.reverse=node.value("origin")>=0.5 ? 1:0
        config.reflect=node.value("reflect")>=0.5 ? 1:0;config.singleColor=node.value("single_color")>=0.5 ? 1:0;config.seed=UInt32(node.value("seed").rounded())
        config.motionTime=Float(motion.anchor);config.motionDistance=Float(motion.distance);config.motionJitterDistance=Float(motion.jitterDistance)
        let core=PaletteColor(hex:UInt32(node.value("core").rounded())),glow=PaletteColor(hex:UInt32(node.value("glow").rounded()))
        config.core=PatchGPUTraceColor(r:Float(core.r),g:Float(core.g),b:Float(core.b));config.glow=PatchGPUTraceColor(r:Float(glow.r),g:Float(glow.g),b:Float(glow.b))
        let input=colors.map { PatchGPUTraceColor(r:Float($0.r),g:Float($0.g),b:Float($0.b)) }
        let count = palette != nil && input.isEmpty ? -1 : input.count
        let state = SIMD4<Float>(Float(t),0,1,Float(count))
        return (previewTexture(node.id,lightning:config,colors:input,state:state,command:command),recipe)
    }
    func mapped(_ node:Node,time:Double,command:MTLCommandBuffer,preview:Bool)->(MTLTexture?,[String:Any]) {
        var p=node.mappedRecipeParameters
        let rate=node.value("rate")
        var motion=motions[node.id] ?? Motion(rate:rate)
        if time<motion.last { motion=Motion(rate:rate) }
        if rate != motion.rate {
            motion.ratePhase += (time-motion.anchor)*motion.rate
            motion.anchor=time;motion.rate=rate
        }
        motion.last=time;motions[node.id]=motion
        p["_motion_time"]=motion.anchor;p["_motion_rate_phase"]=motion.ratePhase
        let recipe:[String:Any]=["version":1,"kind":node.kind.rawValue,"params":p,"time":time]
        guard preview else {return (nil,recipe)}
        var c=PatchGPULineTrace()
        c.kind=node.kind == .traceRainbow ? 1:node.kind == .tracePulse ? 2:node.kind == .traceSolid ? 3:0
        c.beatSync=node.value("beat_sync") != 0 ? 1:0
        c.speed=Float(node.value("speed"));c.beatSpeed=Float(node.value("beat_speed"));c.tail=Float(node.value("tail"));c.drag=Float(node.value("drag"));c.rainbow=Float(node.value("rainbow"))
        c.spread=Float(node.value("spread"));c.brightness=Float(node.value("brightness"));c.pulse=Float(node.value("pulse"));c.breathe=Float(node.value("breathe"));c.rate=Float(rate)
        c.perBeat=Float(node.value("per_beat"));c.onTime=Float(node.value("on_time"));c.attack=Float(node.value("attack"));c.release=Float(node.value("release"))
        c.floor=Float(node.value("floor"));c.curve=Float(node.value("curve"));c.ratePhase=Float(motion.ratePhase);c.motionTime=Float(motion.anchor)
        let tint=PaletteColor(hex:UInt32(node.value("tint")));c.tint=PatchGPUTraceColor(r:Float(tint.r),g:Float(tint.g),b:Float(tint.b))
        let state = SIMD4<Float>(Float(time),Float(time*2),0,0)
        return (previewTexture(node.id,line:c,state:state,command:command),recipe)
    }
    private func previewTexture(_ id:UUID,lightning:PatchGPUTraceConfig = .init(),line:PatchGPULineTrace = .init(),
                                colors:[PatchGPUTraceColor] = [],state:SIMD4<Float>,command:MTLCommandBuffer)->MTLTexture? {
        if textures[id] == nil {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:360,mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite];d.storageMode = .private;textures[id]=device.makeTexture(descriptor:d)
        }
        if samples[id] == nil { samples[id]=device.makeBuffer(length:1024*MemoryLayout<SIMD4<Float>>.stride,options:.storageModePrivate) }
        guard let texture=textures[id],let buffer=samples[id],let evaluate=command.makeComputeCommandEncoder() else { return nil }
        var lightning=lightning,line=line,state=state,empty=PatchGPUTraceColor()
        evaluate.setComputePipelineState(samplePipeline);evaluate.setBuffer(buffer,offset:0,index:0)
        evaluate.setBytes(&lightning,length:MemoryLayout<PatchGPUTraceConfig>.stride,index:1)
        evaluate.setBytes(&line,length:MemoryLayout<PatchGPULineTrace>.stride,index:2)
        if colors.isEmpty { evaluate.setBytes(&empty,length:MemoryLayout<PatchGPUTraceColor>.stride,index:3) }
        else { colors.withUnsafeBytes { evaluate.setBytes($0.baseAddress!,length:$0.count,index:3) } }
        evaluate.setBytes(&state,length:MemoryLayout<SIMD4<Float>>.stride,index:4)
        evaluate.dispatchThreads(.init(width:1024,height:1,depth:1),threadsPerThreadgroup:.init(width:64,height:1,depth:1));evaluate.endEncoding()
        guard let e=command.makeComputeCommandEncoder() else { return nil }
        e.setComputePipelineState(pipeline);e.setTexture(texture,index:0);e.setBuffer(buffer,offset:0,index:0)
        e.dispatchThreads(.init(width:640,height:360,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));e.endEncoding()
        return texture
    }
}
