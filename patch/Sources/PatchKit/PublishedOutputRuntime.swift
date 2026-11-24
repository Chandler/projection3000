import Foundation
import Metal
import QuartzCore
import PatchCore
import OutputBridge

/// Confined to the render queue; snapshots cross to the UI under Renderer's state lock.
final class PublishedOutputRuntime {
    let device: MTLDevice
    let pipeline: MTLComputePipelineState
    let particlePipeline: MTLComputePipelineState
    let videoCollectionPipeline: MTLComputePipelineState
    let cloudParticlePipeline: MTLComputePipelineState
    let cloudPipeline: MTLComputePipelineState
    let traceRuntime: TraceRuntime
    var ports: [PublishedPort] = []
    var retained = Set<String>()
    var hostManaged = false
    private var publisherNames: [String:String] = [:]
    var publishers: [String:PatchSyphon] = [:]
    private var publisherUsed: [String:Double] = [:]
    private var publisherVersions: [String:UInt64] = [:]
    var previews: [UUID:MTLTexture] = [:]
    var recipes: [UUID:[String:Any]] = [:]
    init(device: MTLDevice,library: MTLLibrary) throws {
        self.device=device
        traceRuntime=try TraceRuntime(device:device,library:library)
        pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"collectionPreview")!)
        particlePipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"graphParticlePreview")!)
        videoCollectionPipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"videoCollectionPreview")!)
        cloudParticlePipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"graphCloudParticlePreview")!)
        cloudPipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"graphCloudPreview")!)
    }
    func videoCollection(_ node: Node,sources: [(String,MTLTexture)],black: MTLTexture,command: MTLCommandBuffer,preview: Bool) -> MTLTexture? {
        let fit=max(0,min(2,Int(node.value("fit"))))
        recipes[node.id]=["version":1,"kind":"videoCollection","videos":sources.map { $0.0 },"fit":["contain","cover","stretch"][fit],"brightness":node.value("brightness"),"graphCompatible":true]
        guard preview else { return nil }
        if previews[node.id] == nil {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:360,mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite];d.storageMode = .private
            previews[node.id]=device.makeTexture(descriptor:d)
        }
        guard let target=previews[node.id],let encoder=command.makeComputeCommandEncoder() else { return nil }
        var info=SIMD4<UInt32>(UInt32(sources.count),UInt32(node.value("previewFaces")),UInt32(fit),0)
        var brightness=Float(node.value("brightness"))
        encoder.setComputePipelineState(videoCollectionPipeline)
        for i in 0..<8 { encoder.setTexture(i<sources.count ? sources[i].1:black,index:i) }
        encoder.setTexture(target,index:8)
        encoder.setBytes(&info,length:MemoryLayout<SIMD4<UInt32>>.stride,index:0)
        encoder.setBytes(&brightness,length:MemoryLayout<Float>.stride,index:1)
        encoder.dispatchThreads(.init(width:640,height:360,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));encoder.endEncoding()
        return target
    }
    func plan(_ graph: Graph,publicationGraph: Graph) {
        ports=publicationGraph.publishablePorts
        let ids=Set(graph.nodes.map(\.id))
        traceRuntime.retain(ids)
        previews=previews.filter { ids.contains($0.key) }
        recipes=recipes.filter { ids.contains($0.key) }
    }
    func collection(_ node: Node,palette: ColorPalette,video: MTLTexture,source: UUID?,command: MTLCommandBuffer,time: Double,preview: Bool = true) -> MTLTexture? {
        let gate=node.kind == .surfaceGate, glow=node.kind == .glowFaces
        var colors=gate ? [["r":1.0,"g":1.0,"b":1.0]] : palette.colors.map { ["r":Double($0.r),"g":Double($0.g),"b":Double($0.b)] }
        if !gate && colors.isEmpty { colors=recipes[node.id]?["colors"] as? [[String:Double]] ?? [] }
        var recipe: [String:Any] = ["version":1,"kind":node.kind.rawValue,"params":node.parameters,"colors":colors,"graphCompatible":true]
        if let source { recipe["videoSource"]="patch:\(source.uuidString):0" }
        recipes[node.id]=recipe
        guard preview else { return nil }
        if node.kind == .graphCloudParticles { return cloudParticlePreview(node,colors:colors,command:command,time:time) }
        if node.kind == .graphClouds { return cloudPreview(node,colors:colors,command:command,time:time) }
        let config=PatchCollectionConfig(pattern:Int32(node.value("pattern")),speed:node.value("speed"),onTime:node.value("onTime"),fade:node.value("fade"),brightness:node.value("brightness"),seed:UInt32(node.value("seed")))
        let count=max(1,min(64,Int(node.value("previewFaces"))))
        var samples=[SIMD4<Float>]()
        for face in 0..<count {
            let s = glow ? patch_glow_sample(Int32(face),Int32(colors.count),node.value("brightness")) : node.kind == .graphPulse ? patch_graph_sample(Int32(face),Int32(count),Int32(colors.count),time,node.value("speed"),node.value("trail"),node.value("brightness"),0,UInt32(node.value("seed"))) : patch_collection_sample(config,Int32(face),Int32(count),Int32(colors.count),time)
            if colors.isEmpty { samples.append(.zero); continue }
            let a=colors[Int(s.previous)], b=colors[Int(s.color)]
            samples.append(SIMD4<Float>(Float(a["r"]!)+(Float(b["r"]!)-Float(a["r"]!))*s.blend,Float(a["g"]!)+(Float(b["g"]!)-Float(a["g"]!))*s.blend,Float(a["b"]!)+(Float(b["b"]!)-Float(a["b"]!))*s.blend,1)*s.level)
        }
        if previews[node.id] == nil {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:360,mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite]; d.storageMode = .private
            previews[node.id]=device.makeTexture(descriptor:d)
        }
        guard let target=previews[node.id] else { return nil }
        if node.kind == .graphParticles || node.kind == .graphInkFlow { return particlePreview(node,colors:colors,count:count,target:target,command:command,time:time) }
        guard let e=command.makeComputeCommandEncoder() else { return nil }
        var info=SIMD4<UInt32>(UInt32(count),gate ? 1:0,glow ? 1:0,0)
        var glowInfo=SIMD2<Float>(Float(node.value("center_glow")),Float(node.value("falloff")))
        e.setComputePipelineState(pipeline);e.setTexture(video,index:0);e.setTexture(target,index:1)
        samples.withUnsafeBytes { e.setBytes($0.baseAddress!,length:$0.count,index:0) }
        e.setBytes(&info,length:MemoryLayout<SIMD4<UInt32>>.stride,index:1)
        e.setBytes(&glowInfo,length:MemoryLayout<SIMD2<Float>>.stride,index:2)
        e.dispatchThreads(.init(width:640,height:360,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));e.endEncoding()
        return target
    }
    func cloudParticlePreview(_ node: Node,colors: [[String:Double]],command: MTLCommandBuffer,time: Double) -> MTLTexture? {
        if previews[node.id] == nil {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:360,mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite]; d.storageMode = .private
            previews[node.id]=device.makeTexture(descriptor:d)
        }
        guard let target=previews[node.id],!colors.isEmpty else { return previews[node.id] }
        let count=max(1,min(64,Int(node.value("previewFaces"))))
        let cols=Int(ceil(sqrt(Double(count)*16/9))),rows=(count+cols-1)/cols,aspect=Double(target.width)/Double(target.height)
        var centers=[Double]()
        for face in 0..<count { centers.append((Double(face%cols)+0.5)/Double(cols)*aspect); centers.append((Double(face/cols)+0.5)/Double(rows)) }
        let groups=max(1,min(8,Int(node.value("clouds").rounded()))),detail=max(8,min(24,Int(node.value("detail").rounded())))
        let config=PatchCloudConfig(count:Int32(groups),speed:node.value("speed"),length:node.value("length"),width:node.value("width"),wander:node.value("wander"),colorMode:Int32(node.value("colorMode")),sky:node.value("sky")>=0.5 ? 1:0,seed:UInt32(node.value("seed")))
        let wind=node.value("wind")*Double.pi/180
        func rgb(_ c: [String:Double]) -> SIMD4<Float> { .init(Float(c["r"] ?? 0),Float(c["g"] ?? 0),Float(c["b"] ?? 0),0) }
        var particles=[SIMD4<Float>](),bounds=[SIMD4<Float>]()
        for group in 0..<groups {
            var box=SIMD4<Float>(Float.greatestFiniteMagnitude,Float.greatestFiniteMagnitude,-Float.greatestFiniteMagnitude,-Float.greatestFiniteMagnitude)
            for i in 0..<detail {
                let p=centers.withUnsafeBufferPointer { patch_cloud_particle(config,Int32(group),Int32(i),Int32(detail),$0.baseAddress,Int32(count),Int32(colors.count),time,0,wind) }
                particles.append(.init(Float(p.x),Float(p.y),Float(p.rx),Float(p.ry)))
                particles.append(.init(Float(cos(p.angle)),Float(sin(p.angle)),Float(p.level),Float(p.noise)))
                particles.append(rgb(colors[Int(p.color)%colors.count]))
                let radius=Float(3*max(p.rx,p.ry));box.x=min(box.x,Float(p.x)-radius);box.y=min(box.y,Float(p.y)-radius);box.z=max(box.z,Float(p.x)+radius);box.w=max(box.w,Float(p.y)+radius)
            }
            bounds.append(box)
        }
        var uniforms=CloudPreviewUniforms(sky:rgb(colors[0]),shape:.init(Float(node.value("softness")),Float(node.value("density")),Float(node.value("texture")),Float(node.value("haze"))),motion:.init(Float(wind),Float(node.value("grain")),Float(node.value("speed")),Float(time)),info:.init(UInt32(count),UInt32(cols),UInt32(rows),UInt32(groups)),extra:.init(Float(node.value("brightness")),Float(detail),0,0))
        uniforms.sky.w=Float(node.value("sky"))
        let buffer=particles.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }
        guard let buffer,let e=command.makeComputeCommandEncoder() else { return nil }
        e.setComputePipelineState(cloudParticlePipeline);e.setTexture(target,index:0);e.setBuffer(buffer,offset:0,index:0)
        e.setBytes(&uniforms,length:MemoryLayout<CloudPreviewUniforms>.stride,index:1)
        bounds.withUnsafeBytes { e.setBytes($0.baseAddress!,length:$0.count,index:2) }
        e.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));e.endEncoding();return target
    }
    func cloudPreview(_ node: Node,colors: [[String:Double]],command: MTLCommandBuffer,time: Double) -> MTLTexture? {
        if previews[node.id] == nil {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:360,mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite]; d.storageMode = .private
            previews[node.id]=device.makeTexture(descriptor:d)
        }
        guard let target=previews[node.id],!colors.isEmpty else { return previews[node.id] }
        let count=max(1,min(64,Int(node.value("previewFaces"))))
        let cols=Int(ceil(sqrt(Double(count)*16/9))),rows=(count+cols-1)/cols,aspect=Double(target.width)/Double(target.height)
        // Card centers in canvas-height units, matching VJ projector metrics.
        var centers=[Double]()
        for face in 0..<count { centers.append((Double(face%cols)+0.5)/Double(cols)*aspect); centers.append((Double(face/cols)+0.5)/Double(rows)) }
        let config=PatchCloudConfig(count:Int32(node.value("clouds")),speed:node.value("speed"),length:node.value("length"),width:node.value("width"),wander:node.value("wander"),colorMode:Int32(node.value("colorMode")),sky:node.value("sky")>=0.5 ? 1:0,seed:UInt32(node.value("seed")))
        func rgb(_ c: [String:Double]) -> SIMD4<Float> { .init(Float(c["r"] ?? 0),Float(c["g"] ?? 0),Float(c["b"] ?? 0),0) }
        var streaks=[SIMD4<Float>]()
        for i in 0..<max(1,min(CollectionStyle.cloudLimit,Int(config.count))) {
            var s=centers.withUnsafeBufferPointer { patch_cloud_streak(config,Int32(i),$0.baseAddress,Int32(count),Int32(colors.count),time,0) }
            let x=withUnsafeBytes(of:&s.x) { Array($0.bindMemory(to:Double.self)) },y=withUnsafeBytes(of:&s.y) { Array($0.bindMemory(to:Double.self)) }
            for k in stride(from:0,to:6,by:2) { streaks.append(.init(Float(x[k]),Float(y[k]),Float(x[k+1]),Float(y[k+1]))) }
            streaks.append(.init(Float(s.width),Float(s.level),0,0)); streaks.append(rgb(colors[Int(s.color)%colors.count]))
        }
        var uniforms=CloudPreviewUniforms(sky:rgb(colors[0]),shape:.init(Float(node.value("softness")),Float(node.value("density")),Float(node.value("texture")),Float(node.value("haze"))),
            motion:.init(Float(node.value("wind")*Double.pi/180),Float(node.value("grain")),Float(node.value("speed")),Float(time)),info:.init(UInt32(count),UInt32(cols),UInt32(rows),UInt32(streaks.count/5)),extra:.init(Float(node.value("brightness")),0,0,0))
        uniforms.sky.w=Float(node.value("sky"))
        guard let e=command.makeComputeCommandEncoder() else { return nil }
        e.setComputePipelineState(cloudPipeline);e.setTexture(target,index:0)
        streaks.withUnsafeBytes { e.setBytes($0.baseAddress!,length:$0.count,index:0) }
        e.setBytes(&uniforms,length:MemoryLayout<CloudPreviewUniforms>.stride,index:1)
        e.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));e.endEncoding();return target
    }
    func particlePreview(_ node: Node,colors: [[String:Double]],count: Int,target: MTLTexture,command: MTLCommandBuffer,time: Double) -> MTLTexture? {
        let ink=node.kind == .graphInkFlow
        let circles=ink && node.value("markStyle")>=0.5
        var config=PatchParticleConfig(count:Int32(node.value("particles")),dwell:node.value("dwell"),travel:node.value("travel"),speed:node.value("speed"),spin:node.value("spin"),orbit:node.value("orbit"),depth:node.value("depth"),size:node.value("size"),stagger:node.value("stagger"),trail:node.value("trail"),seed:UInt32(node.value("seed")))
        if node.kind == .graphInkFlow && (node.value("independentTravel")>=0.5 || node.value("startingFaces")<100) { config.count=max(config.count,Int32(ceil(Double(count)*node.value("startingFaces")/100))) }
        let cols=Int(ceil(sqrt(Double(count)*16/9))),rows=(count+cols-1)/cols
        let aspect=Double(target.width)*Double(rows)/(Double(target.height)*Double(cols))
        var particles=[SIMD4<Float>]()
        if !colors.isEmpty { for trail in (0..<(config.trail>0 && !circles ? 4:1)).reversed() { for i in 0..<Int(config.count) {
            let t=time-config.trail*Double(trail)/3; if t<0 { continue }
            var sample=ink ? patch_ink_sample(config,Int32(i),Int32(count),Int32(colors.count),t,2,node.value("turbulence"),node.value("pulse"),circles ? 1:0) : patch_particle_sample(config,Int32(i),Int32(count),Int32(colors.count),t,0)
            if node.kind == .graphInkFlow {
                sample=patch_ink_population(config,Int32(i),Int32(count),Int32(colors.count),t,2,node.value("turbulence"),node.value("pulse"),circles ? 1:0,node.value("startingFaces"),node.value("independentTravel")>=0.5 ? 1:0)
            }
            if sample.face<0 { continue }
            let f=Int(sample.face),n=Int(sample.neighbor)
            let dx=n>=0 ? Double(n%cols-f%cols)*aspect : 1,dy=n>=0 ? Double(n/cols-f/cols) : 0
            sample=ink ? patch_ink_place(sample,aspect,dx,dy,node.value("exploration")) : patch_particle_place(sample,aspect,dx,dy)
            let w=max(1,aspect),h=max(1,1/aspect),rgb=colors[Int(sample.color)%colors.count]
            particles.append(.init(Float(sample.x),Float(sample.y),Float(sample.radius/w),Float(sample.radius/h)))
            particles.append(.init(Float(rgb["r"] ?? 0),Float(rgb["g"] ?? 0),Float(rgb["b"] ?? 0),Float(sample.level*node.value("brightness")*(trail==0 ? 1:0.32*(1-Double(trail)/4)))))
            particles.append(.init(Float(f),ink ? (node.value("markStyle")>=1.5 ? 3:circles ? 2:1):0,Float(node.value(node.value("markStyle")>=1.5 ? "glassFrost":"glow")),Float(t)))
        } } }
        var info=SIMD4<UInt32>(UInt32(count),UInt32(particles.count/3),UInt32(cols),UInt32(rows))
        if particles.isEmpty { particles=[.zero,.zero,.zero] }
        let buffer=particles.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }
        guard let buffer,let e=command.makeComputeCommandEncoder() else { return nil }
        e.setComputePipelineState(particlePipeline);e.setTexture(target,index:0);e.setBuffer(buffer,offset:0,index:0)
        e.setBytes(&info,length:MemoryLayout<SIMD4<UInt32>>.stride,index:1)
        e.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));e.endEncoding();return target
    }
    func publish(graph: Graph,nodes: [UUID:Node],textures: [UUID:MTLTexture],palettes: [UUID:ColorPalette],controls: [UUID:Double],existingSyphon: [UUID:PatchSyphon],staticVersions: [UUID:UInt64],command: MTLCommandBuffer) -> [[String:Any]] {
        var needed=retained
        // A host normally asks for what it uses, but hand-published video is always a Syphon source.
        for port in ports where (!hostManaged && port.listed) || (port.explicit && port.type == .video) { needed.insert(port.id) }
        func retainVideos(_ recipe: [String:Any],depth: Int = 0) {
            guard depth<16 else { return }
            if let source=recipe["videoSource"] as? String { needed.insert(source) }
            for source in recipe["videos"] as? [String] ?? [] { needed.insert(source) }
            for layer in recipe["layers"] as? [[String:Any]] ?? [] { if let child=layer["recipe"] as? [String:Any] { retainVideos(child,depth:depth+1) } }
        }
        for port in ports where port.type == .collection && needed.contains(port.id) { retainVideos(recipes[port.nodeID] ?? [:]) }
        // Keep a bounded set of dormant senders so A/B endpoints do not tear
        // down and recreate their IOSurface connections. Dormant nodes do no work.
        let now=CACurrentMediaTime()
        let valid=Set(ports.filter { graph.node($0.nodeID)?.enabled == true }.map(\.id))
        let dormant=publishers.keys.filter { valid.contains($0) && !needed.contains($0) }
            .sorted { publisherUsed[$0,default:0] > publisherUsed[$1,default:0] }
        let warm=Set(dormant.prefix(32))
        // A sender is named when created: drop it when publishing by hand changes that name.
        let names=Dictionary(ports.map { ($0.id,$0.streamName) },uniquingKeysWith:{ first,_ in first })
        publishers=publishers.filter { valid.contains($0.key) && (needed.contains($0.key) || warm.contains($0.key)) && publisherNames[$0.key] == names[$0.key] }
        publisherNames=publisherNames.filter { publishers[$0.key] != nil }
        publisherVersions=publisherVersions.filter { publishers[$0.key] != nil }
        publisherUsed=publisherUsed.filter { publishers[$0.key] != nil }
        var result=[[String:Any]]()
        for port in ports {
            guard let node=nodes[port.nodeID] ?? graph.node(port.nodeID) else { continue }
            let active=nodes[port.nodeID] != nil
            var item: [String:Any] = ["id":port.id,"nodeID":port.nodeID.uuidString,"outputID":port.portID,"name":port.name,"type":port.type.rawValue,"listed":port.listed,"available":node.enabled,"active":active]
            // Catalog entries survive dormancy, without evaluating their graph.
            if !active { result.append(item); continue }
            switch port.type {
            case .video:
                item["selection"]=""
                let hasInput = !node.kind.isOutput || graph.edges.contains { $0.target == node.id && $0.input == 0 }
                var publisher: PatchSyphon?
                if node.enabled,hasInput {
                    if node.kind == .syphon { publisher=existingSyphon[node.id] }
                    else if needed.contains(port.id),let texture=textures[port.nodeID] {
                        if publishers[port.id] == nil { publishers[port.id]=PatchSyphon(name:port.streamName,device:device);publisherNames[port.id]=port.streamName }
                        publisher=publishers[port.id];publisherUsed[port.id]=now
                        let version=staticVersions[port.nodeID]
                        if version == nil || publisherVersions[port.id] != version {
                            publisher?.publish(texture,commandBuffer:command)
                            publisherVersions[port.id]=version
                        }
                    }
                }
                if let selection=publisher?.selection,let data=try? JSONSerialization.data(withJSONObject:selection,options:.sortedKeys) { item["selection"]=String(data:data,encoding:.utf8) ?? "" }
                item["available"]=publisher != nil
            case .palette:
                let colors=palettes[port.nodeID]?.colors ?? []
                item["colors"]=colors.map { ["r":$0.r,"g":$0.g,"b":$0.b] };item["available"] = !colors.isEmpty
            case .control:
                item["value"]=controls[port.nodeID] ?? 0; item["available"]=node.enabled && controls[port.nodeID] != nil
            case .trace:
                let recipe=recipes[port.nodeID] ?? [:]
                item["recipe"]=recipe
                item["available"]=node.enabled && !recipe.isEmpty && ((recipe["paletteConnected"] as? Bool) != true || !(recipe["colors"] as? [[String:Double]] ?? []).isEmpty)
            case .collection:
                item["recipe"]=recipes[port.nodeID] ?? [:]
                item["available"]=node.enabled && (node.kind == .videoCollection ? !(recipes[port.nodeID]?["videos"] as? [String] ?? []).isEmpty : (node.kind == .layerMux || node.kind == .ab) ? recipes[port.nodeID] != nil : node.kind == .surfaceGate ? recipes[port.nodeID]?["videoSource"] != nil : !(recipes[port.nodeID]?["colors"] as? [[String:Double]] ?? []).isEmpty)
            default: break
            }
            result.append(item)
        }
        return result
    }
}

private struct CloudPreviewUniforms { var sky,shape,motion: SIMD4<Float>; var info: SIMD4<UInt32>; var extra: SIMD4<Float> }
