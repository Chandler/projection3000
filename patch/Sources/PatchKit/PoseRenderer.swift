import Foundation
import Metal
import simd
import PatchCore

private struct PoseStroke {
    var endpoints: SIMD4<Float>
    var color: SIMD4<Float>
    var style: SIMD4<Float> // radius, ring thickness, glow radius, glow strength
    var detail: SIMD4<Float> // dash length, gap, phase, shape
}
final class PoseRenderer {
    let downsample: MTLComputePipelineState
    private let pipeline: MTLRenderPipelineState
    private let device: MTLDevice
    private struct TrailSample { var time: Double; var strokes: [PoseStroke] }
    private var history: [UUID:[TrailSample]] = [:]
    func invalidateHistory(_ id: UUID) { history.removeValue(forKey:id) }
    func retainHistory(_ ids: Set<UUID>) { history = history.filter { ids.contains($0.key) } }
    private func hsv(_ hue: Float, _ saturation: Float, _ brightness: Float, _ opacity: Float) -> SIMD4<Float> {
        let h = (hue-floor(hue))*6, i = Int(h), f = h-Float(i)
        let p = brightness*(1-saturation), q = brightness*(1-saturation*f), t = brightness*(1-saturation*(1-f))
        switch i {
        case 0: return .init(brightness,t,p,opacity)
        case 1: return .init(q,brightness,p,opacity)
        case 2: return .init(p,brightness,t,opacity)
        case 3: return .init(p,q,brightness,opacity)
        case 4: return .init(t,p,brightness,opacity)
        default: return .init(brightness,p,q,opacity)
        }
    }
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        downsample = try device.makeComputePipelineState(function:library.makeFunction(name:"poseLetterbox")!)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name:"poseVertex")
        desc.fragmentFunction = library.makeFunction(name:"poseFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor:desc)
    }
    func encode(target: MTLTexture, frame: PoseFrame?, node: Node?, time: Double = 0, command: MTLCommandBuffer) {
        let style = node ?? Node(kind:.poseRender)
        func v(_ key: String) -> Float { Float(style.value(key)) }
        let background = Int(v("background")), palette = Int(v("color"))
        let light = background == 1
        let threshold = style.value("confidence")
        let pulse = 1+v("pulse")*sin(Float(time)*v("pulseRate")*2*Float.pi)
        let thickness = max(0.25,v("thickness")*pulse), opacity = v("opacity")
        let hue = v("hue")+Float(time)*v("hueRate")
        let brightness = v("brightness"), saturation = v("saturation")
        let neutral = (light ? SIMD4<Float>(0.06,0.08,0.12,1) : SIMD4<Float>(0.94,0.97,1,1))*SIMD4<Float>(brightness,brightness,brightness,opacity)
        let left = palette == 0 ? neutral : hsv(hue,saturation,brightness,opacity)
        let right = palette == 0 ? neutral : hsv(hue+v("hueSpread"),saturation*0.8,brightness,opacity)
        let size = SIMD2<Float>(Float(target.width),Float(target.height))
        let angle = (v("rotation")+Float(time)*v("spin"))*Float.pi/180
        let cosA = cos(angle), sinA = sin(angle)
        var strokes: [PoseStroke] = []
        func stroke(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ color: SIMD4<Float>, _ radius: Float, ring: Float = 0, dashed: Bool = true, shape: Float = 0) {
            strokes.append(PoseStroke(endpoints:.init(a.x,a.y,b.x,b.y),color:color,
                style:.init(radius,ring,v("glowRadius"),v("glow")),
                detail:.init(dashed ? v("dashLength") : 0,v("dashGap"),Float(time)*v("dashSpeed"),shape)))
        }
        for pose in (frame?.poses ?? []).prefix(32) where pose.keypoints.count == 17 {
            let raw = pose.keypoints.map { SIMD2<Float>(Float($0.x),Float($0.y))*size }
            var points = raw
            func valid(_ i: Int) -> Bool { pose.keypoints[i].confidence >= threshold }
            for (a,b) in [(5,6),(11,12)] where valid(a) && valid(b) {
                let center = (raw[a]+raw[b])/2
                points[a] = center+(raw[a]-center)*v("torsoWidth")
                points[b] = center+(raw[b]-center)*v("torsoWidth")
            }
            for (a,b,c,length) in [(5,7,9,v("armLength")),(6,8,10,v("armLength")),(11,13,15,v("legLength")),(12,14,16,v("legLength"))] {
                // An occluded anchor must not move an otherwise visible limb.
                if valid(a) && valid(b) {
                    points[b] = points[a]+(raw[b]-raw[a])*length
                    if valid(c) { points[c] = points[b]+(raw[c]-raw[b])*length }
                }
            }
            for i in points.indices {
                var p = points[i]-size/2
                p *= SIMD2<Float>(v("stretchX")*(v("mirror") > 0.5 ? -1 : 1),v("stretchY"))*v("scale")
                p = .init(p.x*cosA-p.y*sinA,p.x*sinA+p.y*cosA)
                let phase = Float(time)*v("wobbleRate")*2*Float.pi+Float(i)*1.73
                p += SIMD2<Float>(sin(phase),cos(phase*0.91))*v("wobble")
                points[i] = p+size/2+SIMD2<Float>(v("x"),v("y"))*size
            }
            func color(_ fallback: SIMD4<Float>, at p: SIMD2<Float>) -> SIMD4<Float> {
                if palette == 2 { return hsv(hue+Float(pose.bounds.x+pose.bounds.width/2)*v("hueSpread"),saturation,brightness,opacity) }
                if palette == 3 { return hsv(hue+(p.x/size.x+p.y/size.y)*v("hueSpread"),saturation,brightness,opacity) }
                return fallback
            }
            func bone(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ tint: SIMD4<Float>) {
                let trim = v("boneTrim")/2
                stroke(a+(b-a)*trim,b+(a-b)*trim,color(tint,at:(a+b)/2),thickness/2)
            }
            var bones: [(Int,Int,SIMD4<Float>)] = []
            let torso = Int(v("torso"))
            if torso != 3 {
                bones += [(5,6,neutral),(11,12,neutral)]
                if torso == 0 || torso == 2 { bones += [(5,11,left),(6,12,right)] }
                if torso == 2 { bones += [(5,12,left),(6,11,right)] }
                if torso == 1 && [5,6,11,12].allSatisfy(valid) { bone((points[5]+points[6])/2,(points[11]+points[12])/2,neutral) }
            }
            if v("arms") > 0.5 { bones += [(5,7,left),(7,9,left),(6,8,right),(8,10,right)] }
            if v("legs") > 0.5 { bones += [(11,13,left),(13,15,left),(12,14,right),(14,16,right)] }
            for (a,b,tint) in bones where valid(a) && valid(b) { bone(points[a],points[b],tint) }
            if Int(v("headStyle")) != 2 && valid(5) && valid(6) && valid(0) {
                let neck = (points[5]+points[6])/2, head = points[0]
                let shoulderWidth = simd_length(points[5]-points[6])
                let radius = max(thickness*1.5,min(shoulderWidth*0.3,Float(pose.bounds.height)*size.y*0.1*v("scale")))*v("headSize")
                let delta = neck-head, distance = simd_length(delta)
                if distance > radius && torso != 3 { bone(head+delta/distance*radius,neck,neutral) }
                stroke(head,head,color(neutral,at:head),radius,ring:Int(v("headStyle")) == 0 ? min(thickness,radius) : 0,dashed:false)
            }
            if v("joints") > 0.5 {
                for i in 5..<17 where valid(i) {
                    let radius = thickness*0.8*v("jointSize")
                    stroke(points[i],points[i],color(neutral,at:points[i]),radius,
                        ring:Int(v("jointShape")) == 1 ? max(0.5,radius*0.35) : 0,dashed:false,shape:Int(v("jointShape")) == 2 ? 1 : 0)
                }
            }
        }
        let current = strokes
        if let node, v("trails") > 0 {
            let duration = Double(v("trails"))
            var samples = (history[node.id] ?? []).filter { time >= $0.time && time-$0.time < duration }
            var ghosts: [PoseStroke] = []
            let weight = v("trailOpacity")/sqrt(Float(max(1,samples.count)))
            for sample in samples {
                let fade = pow(Float(max(0,1-(time-sample.time)/duration)),v("trailDecay"))*weight
                ghosts += sample.strokes.map { old in var s = old; s.color.w *= fade; return s }
            }
            if time-(samples.last?.time ?? -1) >= 1.0/20 {
                samples.append(TrailSample(time:time,strokes:current)); samples = Array(samples.suffix(30))
            }
            history[node.id] = samples
            strokes = ghosts+current
        } else if let node { history[node.id] = nil }
        let bg: SIMD4<Float> = background == 2 ? hsv(v("backgroundHue"),v("backgroundSaturation"),v("backgroundBrightness"),1) : SIMD4<Float>(repeating:light ? 1 : 0)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(Double(bg.x),Double(bg.y),Double(bg.z),1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { return }
        if !strokes.isEmpty, let buffer = strokes.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }) {
            var viewport = size
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer,offset:0,index:0)
            encoder.setVertexBytes(&viewport,length:MemoryLayout<SIMD2<Float>>.stride,index:1)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:strokes.count)
        }
        encoder.endEncoding()
    }
}
