import Foundation
import simd

/// Audio-reactive ferrofluid: a puddle over a magnet, driven through the Rosensweig
/// (normal-field) instability. Unlike Liquid Chrome, nothing here is composed by hand:
/// fluid constants and the applied field decide spike spacing, count and response.
/// `FerrofluidSim` steps the spikes every frame; `Ferrofluid.metal` raymarches the
/// resulting heightfield. Drive Field (and optionally Rim field) with Audio Envelope.
public enum FerrofluidStyle {
    public static let fluid: [ParameterSpec] = [
        .init("sigma","Surface tension (mN/m)",15,60,28),
        .init("density","Density (kg/m³)",1000,1800,1250),
        .init("viscosity","Viscosity (mPa·s)",2,400,40),
        .init("chi","Susceptibility χ",0.3,4,1.6),
        .init("radius","Puddle radius (mm)",10,80,35)
    ]
    public static let field: [ParameterSpec] = [
        .init("field","Field H/Hc",0,3,1.15),
        .init("rim","Rim field H/Hc",0,2,0),
        .init("focus","Magnet focus",0,1,0.6),
        .init("magnet","Magnet width",0.2,1.5,0.6),
        .init("hysteresis","Hysteresis",0,0.4,0.12),
        .init("packing","Field packing",0,1,0.35),
        .init("onset","Onset threshold (H/s)",0.5,20,4)
    ]
    public static let spikes: [ParameterSpec] = [
        .init("width","Spike width ×λ",0.15,0.8,0.36),
        .init("flank","Flank exponent",0.6,2.5,1.05),
        .init("tip","Tip radius ×λ",0,0.2,0.03),
        .init("jump","Onset jump ×λ",0,0.8,0.25),
        .init("growth","Growth ×λ",0,2,0.7),
        .init("merge","Neighbour merge",1,10,4)
    ]
    public static let body: [ParameterSpec] = [
        .init("heap","Magnet heaping",0,1,0.5),
        .init("slosh","Onset slosh",0,1,0.4),
        .init("migrate","Spike migration",0,3,1),
        .init("timeScale","Time scale",0.05,1,0.35)
    ]
    public static let light: [ParameterSpec] = [
        .init("gloss","Reflectivity",0,1,0.45),
        .init("hardness","Light hardness",0,1,0.75),
        .init("edge","Blue edge",0,1,0.5),
        .init("glow","Glow",0,1,0.3),
        .init("exposure","Exposure",0.3,2,1),
        .init("warmth","Warm highlights",0,1,0.2),
        .init("reflection","Video reflection",0,1,0.3)
    ]
    public static let camera: [ParameterSpec] = [
        .init("tilt","Tilt °",0,75,42),
        .init("turn","Turn °",-180,180,0),
        .init("zoom","Zoom",0.5,2.5,1)
    ]
    public static let output: [ParameterSpec] = [
        .init("background","Background",0,2,1,choices:["Transparent","Black","Ivory"]),
        .init("quality","Detail",0,2,1,choices:["Draft","Balanced","Fine"])
    ]
    // Generic shader-effect keys (speed, mix, p1–p4) stay valid for the shared node runtime.
    public static let parameters: [ParameterSpec] = fluid + field + spikes + body + light + camera + output + NodeKind.shaderEffect.parameters
    /// Heightfield half-extent in puddle radii.
    public static let extent = 1.15

    public static func reset(_ node: inout Node) {
        node.parameters=Dictionary(uniqueKeysWithValues:parameters.map { ($0.key,$0.initial) })
        node.modulations=nil
    }

    /// Layout: 5 header vectors; texture(2) is the heightfield from `FerrofluidSim`.
    public static func shaderValues(_ node: Node, aspect: Float, hasInput: Bool, frame: FerrofluidSim.Frame) -> [SIMD4<Float>] {
        func f(_ key: String) -> Float { Float(node.value(key)) }
        let degrees = Float.pi/180
        return [
            SIMD4(aspect,Float(extent),Float(frame.maxHeight),f("quality")),
            SIMD4(f("tilt")*degrees,f("turn")*degrees,f("zoom"),f("background")),
            SIMD4(f("hardness"),f("edge"),f("glow"),f("exposure")),
            SIMD4(f("gloss"),f("warmth"),f("reflection"),hasInput ? 1:0),
            SIMD4(Float(frame.edge),Float(frame.texel),0,0)
        ]
    }
}

/// Per-node state, stepped on the render queue with the transport clock.
public final class FerrofluidSim {
    public struct Frame { public var width: Int; public var heights: [Float]; public var maxHeight: Double; public var edge: Double; public var texel: Double; public var spikes: Int }
    struct Site { var p: SIMD2<Double>; var h = 0.0, v = 0.0, on = false, dying = false, field = 0.0 }
    struct Ripple { var age: Double; var amplitude: Double }

    private var sites: [Site] = []
    private var ripples: [Ripple] = []
    private var lastTime: Double?
    private var lastField: Double?
    private var slowField = 1.0
    private var heapHeight = 0.0, heapVelocity = 0.0
    private var random = SystemRandomNumberGenerator()
    public private(set) var spikeCount = 0
    public init() {}

    static let gravity = 9.81
    struct Constants { var sigma, rho, nu, radius, lambdaC: Double }
    static func constants(_ node: Node) -> Constants {
        let sigma = node.value("sigma")*1e-3, rho = node.value("density"), nu = node.value("viscosity")*1e-3/rho
        // Capillary length ℓc = √(σ/Δρg); the critical wavelength is 2πℓc.
        return Constants(sigma:sigma,rho:rho,nu:nu,radius:node.value("radius")*1e-3,lambdaC:2*Double.pi*sqrt(sigma/(rho*gravity)))
    }

    /// Applied field at radius r (puddle units): a magnet under the centre plus an optional rim coil.
    private func field(_ node: Node,_ r: Double,drive: Double,rim: Double) -> Double {
        let focus = node.value("focus"), width = node.value("magnet")
        let profile = (1-focus) + focus*exp(-(r*r)/(width*width))
        return drive*profile + rim*smoothstep(0.55,0.95,r)
    }

    public func step(_ node: Node, time: Double) -> Frame {
        let dtReal = lastTime.map { time-$0 }.flatMap { $0 >= 0 && $0 < 0.5 ? $0 : nil } ?? 1/60
        let firstFrame = lastTime == nil
        lastTime = time
        let k = Self.constants(node)
        let drive = node.value("field"), rim = node.value("rim")
        let dt = dtReal*node.value("timeScale")

        // Slow field follows fast rises and decays over a second: it sets the lattice size.
        slowField += (drive-slowField)*(1-exp(-dtReal/(drive > slowField ? 0.25 : 1.2)))
        if firstFrame { slowField = drive }
        let lambda = k.lambdaC/(1 + node.value("packing")*max(0,slowField-1))
        let lambdaA = lambda/k.radius

        // Volume conservation: heaping toward the magnet pulls the edge in.
        let heapTarget = node.value("heap")*node.value("focus")*0.22*min(1,slowField*slowField/4)
        let edge = 1-0.6*heapHeight
        let rimBand = 0.97*edge

        // Onset: a fast rise in the applied field kicks the slosh mode and launches a ripple.
        if let lastField, dtReal > 0, (drive-lastField)/dtReal > node.value("onset") {
            heapVelocity += node.value("slosh")*0.9
            if ripples.count < 6 { ripples.append(Ripple(age:0,amplitude:0.012*node.value("slosh"))) }
        }
        lastField = drive

        // Lattice sizing: hexagonal cells of side λ over the region where H > Hc.
        var active = 0.0
        let rings = 64
        for i in 0..<rings {
            let r = (Double(i)+0.5)/Double(rings)*rimBand
            if field(node,r,drive:slowField,rim:rim) > 1 { active += 2*Double.pi*r*rimBand/Double(rings) }
        }
        let target = min(420,Int((active/(0.866*lambdaA*lambdaA)).rounded()))
        let alive = sites.reduce(0) { $0 + ($1.dying ? 0:1) }
        if alive < target {
            for _ in 0..<(firstFrame ? target : min(4,target-alive)) { spawn(node,lambdaA:lambdaA,radius:rimBand,drive:slowField,rim:rim) }
        } else if alive > target {
            let weakest = sites.indices.filter { !sites[$0].dying }.sorted { sites[$0].field < sites[$1].field }
            for index in weakest.prefix(min(4,alive-target)) { sites[index].dying = true }
        }
        for _ in 0..<(firstFrame ? 160 : 1) { relax(node,lambdaA:lambdaA,radius:rimBand,dt:firstFrame ? 0.05 : dt,strength:firstFrame ? 6 : 10*node.value("migrate")) }

        // Heights: hysteretic bifurcation, then a capillary–gravity spring.
        let wave = 2*Double.pi/lambda
        let omega = sqrt(Self.gravity*wave + k.sigma*wave*wave*wave/k.rho)
        let zeta = min(3,2*k.nu*wave*wave/omega)
        let substeps = max(1,min(40,Int(ceil(omega*dt*max(1,zeta)/0.25)))), h = dt/Double(substeps)
        let hysteresis = node.value("hysteresis"), jump = node.value("jump"), growth = node.value("growth")
        for index in sites.indices.reversed() {
            var s = sites[index]
            s.field = field(node,simd_length(s.p),drive:drive,rim:rim)
            if s.field > 1 { s.on = true } else if s.field < 1-hysteresis { s.on = false }
            let goal = s.dying || !s.on ? 0 : lambdaA*(jump + growth*sqrt(max(0,s.field-1+hysteresis)))
            if firstFrame { s.h = goal } else {
                for _ in 0..<substeps {
                    s.v += (omega*omega*(goal-s.h) - 2*zeta*omega*s.v)*h
                    s.h += s.v*h
                    if s.h < 0 { s.h = 0; s.v = max(0,s.v) }
                }
            }
            if s.dying && s.h < 1e-4 { sites.remove(at:index) } else { sites[index] = s }
        }

        // Slosh: the puddle's lowest gravity mode, ω² = gk with k = π/R.
        let slosh = sqrt(Self.gravity*Double.pi/k.radius)
        let sloshDamping = 0.06 + min(1,2*k.nu*pow(Double.pi/k.radius,2)/slosh)
        let sloshSteps = max(1,Int(ceil(slosh*dt/0.2))), sh = dt/Double(sloshSteps)
        for _ in 0..<sloshSteps {
            heapVelocity += (slosh*slosh*(heapTarget-heapHeight) - 2*sloshDamping*slosh*heapVelocity)*sh
            heapHeight += heapVelocity*sh
        }
        heapHeight = max(-0.05,min(0.4,heapHeight))
        let rippleSpeed = omega/wave/k.radius
        for i in ripples.indices { ripples[i].age += dt }
        ripples.removeAll { $0.age*rippleSpeed > 1.3 }

        spikeCount = sites.filter { !$0.dying && $0.h > lambdaA*0.05 }.count
        return heightfield(node,lambdaA:lambdaA,edge:edge,rippleSpeed:rippleSpeed,ripple:lambdaA)
    }

    private func spawn(_ node: Node,lambdaA: Double,radius: Double,drive: Double,rim: Double) {
        guard sites.count < 480 else { return }
        var best: SIMD2<Double>?, bestDistance = -1.0
        for attempt in 0..<24 {
            let angle = Double.random(in:0..<2*Double.pi,using:&random), r = sqrt(Double.random(in:0..<1,using:&random))*radius
            let p = SIMD2(cos(angle),sin(angle))*r
            if field(node,r,drive:drive,rim:rim) <= 1 && attempt < 20 { continue }
            let nearest = sites.lazy.filter { !$0.dying }.map { simd_length_squared($0.p-p) }.min() ?? 9
            if nearest > bestDistance { bestDistance = nearest; best = p }
        }
        if let best { sites.append(Site(p:best)) }
    }

    /// Short-range repulsion packs the spikes hexagonally; sub-critical spikes drift toward the magnet.
    private func relax(_ node: Node,lambdaA: Double,radius: Double,dt: Double,strength: Double) {
        let cut = 2*lambdaA, cut2 = cut*cut, focus = node.value("focus")
        var forces = [SIMD2<Double>](repeating:.zero,count:sites.count)
        for i in sites.indices where !sites[i].dying {
            for j in (i+1)..<sites.count where !sites[j].dying {
                let d = sites[i].p-sites[j].p, d2 = simd_length_squared(d)
                guard d2 < cut2, d2 > 1e-12 else { continue }
                let distance = sqrt(d2), s = 1-distance/cut, f = d*(s*s/distance)
                forces[i] += f; forces[j] -= f
            }
        }
        for i in sites.indices where !sites[i].dying {
            var f = forces[i]
            let r = simd_length(sites[i].p)
            f -= sites[i].p*(focus*(sites[i].field < 1 ? 0.25 : 0.03))
            if r > radius { f -= sites[i].p/r*(r-radius)*40 }
            sites[i].p += f*strength*lambdaA*dt
        }
    }

    private func heightfield(_ node: Node,lambdaA: Double,edge: Double,rippleSpeed: Double,ripple: Double) -> Frame {
        let size = [192,320,448][max(0,min(2,Int(node.value("quality").rounded())))]
        let extent = FerrofluidStyle.extent, texel = 2*extent/Double(size)
        let width = node.value("width")*lambdaA, tip = node.value("tip")*lambdaA
        let flank = node.value("flank"), merge = node.value("merge")
        let cutoff = min(1.0,width*pow(6.2,1/flank)+tip)
        // One spike profile per frame: Σ hᵢᵖ·L(dᵢ), then a single p-th root per texel.
        let lutSize = 256
        let lut = (0..<lutSize).map { i -> Float in
            let d = Double(i)/Double(lutSize-1)*cutoff
            let x = (sqrt(d*d+tip*tip)-tip)/max(width,1e-6)
            return Float(pow(exp(-pow(x,flank)),merge))
        }
        // Bucket spikes on a grid of cutoff-sized cells.
        let cells = max(1,Int(2*extent/cutoff)), cellSize = 2*extent/Double(cells)
        var buckets = [[(SIMD2<Float>,Float)]](repeating:[],count:cells*cells)
        for s in sites where s.h > 1e-5 {
            let cx = max(0,min(cells-1,Int((s.p.x+extent)/cellSize))), cy = max(0,min(cells-1,Int((s.p.y+extent)/cellSize)))
            buckets[cy*cells+cx].append((SIMD2(Float(s.p.x),Float(s.p.y)),Float(pow(s.h,merge))))
        }
        let base = 0.045, heapWidth = node.value("magnet")
        let heap = heapHeight, ripples = self.ripples
        let invMerge = Float(1/merge), cut = Float(cutoff), lutScale = Float(lutSize-1)/cut
        var heights = [Float](repeating:0,count:size*size)
        heights.withUnsafeMutableBufferPointer { buffer in
            let out = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations:size) { row in
                let y = (Double(row)+0.5)*texel-extent
                for column in 0..<size {
                    let x = (Double(column)+0.5)*texel-extent
                    let r = sqrt(x*x+y*y)
                    guard r < edge else { out[row*size+column] = 0; continue }
                    // Meniscus: round at the rim, flat inside, heaped over the magnet.
                    let rim = sqrt(max(0,1-pow(r/edge,6)))
                    var height = (base + heap*exp(-(r*r)/(heapWidth*heapWidth)))*rim
                    for wave in ripples {
                        let front = wave.age*rippleSpeed, d = r-front
                        height += wave.amplitude*exp(-d*d/(ripple*ripple*0.8))*cos(d/ripple*2*Double.pi)*rim/(1+front*2)
                    }
                    let cx = Int((x+extent)/cellSize), cy = Int((y+extent)/cellSize)
                    var sum: Float = 0
                    let p = SIMD2(Float(x),Float(y))
                    for j in max(0,cy-1)...min(cells-1,cy+1) { for i in max(0,cx-1)...min(cells-1,cx+1) {
                        for (site,hp) in buckets[j*cells+i] {
                            let d = simd_length(p-site)
                            if d < cut { sum += hp*lut[Int(d*lutScale)] }
                        }
                    } }
                    if sum > 0 { height += Double(pow(sum,invMerge))*smoothstep(0,0.12,edge-r) }
                    out[row*size+column] = Float(height)
                }
            }
        }
        let maxHeight = Double(heights.max() ?? 0)
        return Frame(width:size,heights:heights,maxHeight:maxHeight,edge:edge,texel:texel,spikes:spikeCount)
    }
}

extension Node {
    public var hasFerrofluidControls: Bool { kind == .shaderEffect && controlStyle == "ferrofluid" }
}

private func smoothstep(_ a: Double,_ b: Double,_ x: Double) -> Double {
    let t = min(max((x-a)/(b-a),0),1)
    return t*t*(3-2*t)
}
