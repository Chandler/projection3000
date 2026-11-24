import Foundation
import simd

/// Poster liquid chrome: a seeded liquid network (pools, threads, holes, drips)
/// built here in poster space, then inflated and lit by `LiquidChrome.metal`.
public enum LiquidChromeStyle {
    /// Each method generates the liquid by a different process (see LiquidChromeMembrane.swift).
    public static let methods = ["Pour","Balloon","Sheet","Coral","Swarm","Ferrofluid"]
    public enum Method: Int { case pour, balloon, sheet, coral, swarm, ferrofluid
        /// Raymarched as a 3D object with a perspective camera.
        public var isVolumetric: Bool { self != .pour && self != .coral }
    }
    public static func method(_ node: Node) -> Method { Method(rawValue:Int(node.value("method").rounded())) ?? .pour }
    public static let form: [ParameterSpec] = [
        .init("method","Method",0,Double(methods.count-1),0,choices:methods),
        .init("seed","Seed",0,999999,7,step:1),
        .init("nodes","Network",4,16,9,step:1),
        .init("holes","Holes",0,8,4,step:1),
        .init("pool","Pool weight",0,1,0.6),
        .init("spread","Size",0.4,1.6,1)
    ]
    public static let liquid: [ParameterSpec] = [
        .init("viscosity","Viscosity",0,1,0.6),
        .init("threads","Thread thinness",0,1,0.55),
        .init("drips","Drips",0,14,7,step:1),
        .init("dripLength","Drip length",0,1,0.55),
        .init("puff","Puffiness",0,1,0.6),
        .init("motion","Liquid motion",0,1,0.15)
    ]
    public static let light: [ParameterSpec] = [
        .init("hardness","Light hardness",0,1,0.75),
        .init("edge","Blue edge",0,1,0.6),
        .init("glow","Glow",0,1,0.4),
        .init("sparkle","Sparkle",0,1,0.35),
        .init("exposure","Exposure",0.3,2,1),
        .init("warmth","Warm highlights",0,1,0.2),
        .init("reflection","Video reflection",0,1,0.55)
    ]
    public static let camera: [ParameterSpec] = [
        .init("tilt","Tilt °",-60,60,16),
        .init("turn","Turn °",-60,60,-10)
    ]
    public static let output: [ParameterSpec] = [
        .init("background","Background",0,2,1,choices:["Transparent","Black","Ivory"]),
        .init("quality","Detail",0,2,1,choices:["Draft","Balanced","Fine"])
    ]
    // Generic shader-effect keys (speed, mix, p1–p4) stay valid for the shared node runtime.
    public static let parameters: [ParameterSpec] = form + liquid + light + camera + output + NodeKind.shaderEffect.parameters
    public static let maxSegments = 48, maxCircles = 40

    public static func reset(_ node: inout Node) {
        node.parameters=Dictionary(uniqueKeysWithValues:parameters.map { ($0.key,$0.initial) })
        node.modulations=nil
    }

    /// Tuned starting points per method; switching keeps the seed and lighting choices.
    public static let methodDefaults: [Method:[String:Double]] = [
        .pour:["nodes":9,"holes":4,"pool":0.6,"spread":1,"viscosity":0.6,"threads":0.55,"drips":7,"dripLength":0.55,"puff":0.6,"edge":0.6,"warmth":0.15],
        .balloon:["nodes":7,"holes":2,"pool":0.5,"spread":1.05,"viscosity":0.85,"threads":0.2,"drips":2,"dripLength":0.3,"puff":0.75,"edge":0.55,"warmth":0.1,"tilt":12,"turn":-8,"hardness":0.65],
        .sheet:["nodes":10,"holes":5,"spread":1.1,"viscosity":0.45,"threads":0.5,"puff":0.6,"edge":0.85,"warmth":0.6,"tilt":24,"turn":-18,"hardness":0.7,"glow":0.5],
        .coral:["nodes":8,"holes":5,"pool":0.8,"spread":1.1,"viscosity":0.4,"threads":0.4,"drips":3,"puff":0.55,"edge":0.7,"warmth":0.1],
        .swarm:["nodes":10,"holes":3,"spread":1,"viscosity":0.7,"threads":0.5,"drips":8,"dripLength":0.6,"puff":0.7,"edge":0.6,"warmth":0.2,"tilt":10,"turn":-6],
        .ferrofluid:["nodes":6,"holes":5,"pool":0.9,"spread":1.1,"viscosity":0.9,"threads":0.3,"drips":0,"dripLength":0.6,"puff":0.6,"edge":0.5,"warmth":0.25,"tilt":30,"turn":-12,"hardness":0.8]
    ]
    public static func applyMethod(_ node: inout Node,_ method: Method) {
        node.parameters["method"]=Double(method.rawValue)
        node.parameters.merge(methodDefaults[method] ?? [:]) { _,new in new }
    }

    struct Segment { var a, control, b: SIMD2<Double>; var ra, rb, neck: Double }
    struct Circle { var center: SIMD2<Double>; var radius: Double }
    /// SplitMix64 keeps every seed reproducible across launches and machines.
    struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double,_ b: Double) -> Double { a + (b-a)*next() }
    }

    /// Network → holes (extra cycle edges) → pools → gravity drips → tendrils.
    static func geometry(_ node: Node, aspect: Double) -> (segments: [Segment], circles: [Circle]) {
        var random = Random(state:UInt64(max(0,node.value("seed")))&*2654435761 &+ 17)
        let spread = node.value("spread"), pool = node.value("pool"), thin = node.value("threads")
        let count = max(4,min(16,Int(node.value("nodes").rounded())))
        let rx = min(aspect,1.25)*0.62*spread, ry = 0.56*spread
        // Dart throwing gives even spacing without a grid look.
        let spacing = sqrt(Double.pi*rx*ry/Double(count))*0.78
        var points: [SIMD2<Double>] = []
        var attempts = 0
        while points.count < count && attempts < 4000 {
            attempts += 1
            let angle = random.range(0,2*Double.pi), radius = sqrt(random.next())
            // Mass settles downward: the lower half is slightly fuller.
            // The body sits high so gravity drips have room below it.
            let p = SIMD2(cos(angle)*radius*rx, sin(angle)*radius*ry + 0.1)
            let minimum = spacing*(attempts > 2000 ? 0.6:1)
            if points.allSatisfy({ simd_length($0-p) > minimum }) { points.append(p) }
        }
        let base = 0.105*sqrt(9/Double(count))*spread
        var radii = points.map { _ in base*random.range(0.55,1.15) }
        if let lowest = points.indices.min(by:{ points[$0].y < points[$1].y }) { radii[lowest] *= 1+1.9*pool }
        if points.count > 3 { radii[Int(random.next()*Double(points.count))%points.count] *= 1+0.9*pool }

        // Minimum spanning tree keeps one connected body; extra short edges become holes.
        var edges: [(Int,Int)] = []
        var inTree: Set<Int> = [0]
        while inTree.count < points.count {
            var best: (Int,Int,Double)?
            for i in inTree { for j in points.indices where !inTree.contains(j) {
                let d = simd_length(points[i]-points[j])
                if best == nil || d < best!.2 { best = (i,j,d) }
            } }
            guard let best else { break }
            edges.append((best.0,best.1)); inTree.insert(best.1)
        }
        func crosses(_ a: (Int,Int),_ b: (Int,Int)) -> Bool {
            if a.0 == b.0 || a.0 == b.1 || a.1 == b.0 || a.1 == b.1 { return false }
            func side(_ p: SIMD2<Double>,_ q: SIMD2<Double>,_ r: SIMD2<Double>) -> Double { (q.x-p.x)*(r.y-p.y)-(q.y-p.y)*(r.x-p.x) }
            let p1 = points[a.0], p2 = points[a.1], q1 = points[b.0], q2 = points[b.1]
            return side(p1,p2,q1)*side(p1,p2,q2) < 0 && side(q1,q2,p1)*side(q1,q2,p2) < 0
        }
        var candidates: [(Int,Int,Double)] = []
        for i in points.indices { for j in points.indices where j > i && !edges.contains(where:{ ($0 == (i,j)) || ($0 == (j,i)) }) {
            candidates.append((i,j,simd_length(points[i]-points[j])))
        } }
        var extra = max(0,min(8,Int(node.value("holes").rounded())))
        for candidate in candidates.sorted(by:{ $0.2 < $1.2 }) where extra > 0 {
            guard candidate.2 < spacing*2.4, !edges.contains(where:{ crosses($0,(candidate.0,candidate.1)) }) else { continue }
            edges.append((candidate.0,candidate.1)); extra -= 1
        }

        var segments: [Segment] = []
        var circles = zip(points,radii).map { Circle(center:$0,radius:$1) }
        func curved(_ a: SIMD2<Double>,_ b: SIMD2<Double>,bend: Double) -> SIMD2<Double> {
            let delta = b-a, length = max(simd_length(delta),0.0001)
            let normal = SIMD2(-delta.y,delta.x)/length
            // Never exactly straight: the quadratic distance solve needs curvature.
            let offset = bend*length
            return (a+b)*0.5 + normal*(abs(offset) < length*0.03 ? length*0.03*(offset < 0 ? -1:1) : offset)
        }
        for (i,j) in edges {
            let bend = random.range(-0.42,0.42)
            segments.append(Segment(a:points[i],control:curved(points[i],points[j],bend:bend),b:points[j],
                                    ra:radii[i]*0.8,rb:radii[j]*0.8,neck:0.2+thin*0.68*random.range(0.75,1.0)))
        }

        // Drips leave the underside of the body: thin threads that end in teardrop beads.
        let drips = max(0,min(14,Int(node.value("drips").rounded())))
        let dripLength = node.value("dripLength")
        var anchors: [(SIMD2<Double>,Double,Double)] = points.indices.map { (points[$0]-SIMD2(0,radii[$0]*0.7),radii[$0],0) }
        for (i,j) in edges {
            let mid = (points[i]+points[j])*0.5
            anchors.append((mid-SIMD2(0,(radii[i]+radii[j])*0.2),(radii[i]+radii[j])*0.3,0))
        }
        for index in anchors.indices { anchors[index].2 = -anchors[index].0.y + random.range(0,0.9)*spread }
        let chosen = anchors.sorted(by:{ $0.2 > $1.2 }).prefix(drips)
        // The heaviest pool releases one large anchoring teardrop.
        if pool > 0.25, let lowest = points.indices.min(by:{ points[$0].y < points[$1].y }) {
            let radius = radii[lowest], bulb = radius*(0.55+0.45*pool)
            let start = points[lowest]-SIMD2(0,radius*0.5)
            let length = min((0.22+0.3*dripLength)*spread,max(0.08,start.y+0.93-bulb))
            let sway = random.range(-0.08,0.08)*spread
            let end = start+SIMD2(sway,-length)
            segments.append(Segment(a:start,control:start+SIMD2(-sway*0.6,-length*0.5),b:end,ra:radius*0.5,rb:bulb*0.55,neck:0.35))
            circles.append(Circle(center:end,radius:bulb))
        }
        for (start,radius,_) in chosen {
            let length = min((0.12+0.75*dripLength*pow(random.next(),0.7))*spread,max(0.05,start.y+0.93))
            // Threads sway as they fall, rather than dropping as straight rods.
            let sway = random.range(-0.11,0.11)*spread*(0.4+length)
            let end = start + SIMD2(sway,-length)
            let thread = max(0.006,radius*(0.42-0.22*thin))
            // Plateau–Rayleigh: the fastest-growing bead wavelength is about nine radii.
            let beads = Double(max(0,min(5,Int(length/(thread*9*1.6)))))
            let control = start+SIMD2(-sway*random.range(0.4,1.1),-length*0.5)
            segments.append(Segment(a:start,control:control,b:end,ra:thread,rb:thread*0.4,neck:beads > 0 ? -(beads+0.5):0))
            let tip = thread*random.range(1.25,1.9)
            circles.append(Circle(center:end,radius:tip))
            // Some threads have already pinched off a satellite droplet below the tip.
            if random.next() < 0.35, end.y-tip*3.2 > -0.95 { circles.append(Circle(center:end-SIMD2(sway*0.05,tip*3.0),radius:tip*0.55)) }
        }

        // A few long whips flung off the outer edge, each ending in a small bead.
        let whips = min(3,drips/3)
        let outer = points.indices.sorted(by:{ simd_length(points[$0]*SIMD2(1/rx,1/ry)) > simd_length(points[$1]*SIMD2(1/rx,1/ry)) })
        for index in outer.prefix(whips) {
            let start = points[index], outward = simd_normalize(start + SIMD2(0.0001,0))
            let length = random.range(0.35,0.7)*spread
            var end = start + outward*length + SIMD2(0,random.range(-0.1,0.25))*spread
            end = SIMD2(max(-aspect*0.94,min(aspect*0.94,end.x)),max(-0.92,min(0.92,end.y)))
            let control = curved(start,end,bend:random.range(0.35,0.6)*(random.next() < 0.5 ? -1:1))
            let thread = max(0.005,radii[index]*(0.22-0.1*thin))
            segments.append(Segment(a:start,control:control,b:end,ra:thread,rb:thread*0.55,neck:0))
            circles.append(Circle(center:end,radius:thread*1.5))
        }
        return (Array(segments.prefix(maxSegments)),Array(circles.prefix(maxCircles)))
    }

    /// Layout: 5 header vectors, 3 per segment, then 1 per circle.
    public static func shaderValues(_ node: Node, aspect: Float, hasInput: Bool) -> [SIMD4<Float>] {
        func f(_ key: String) -> Float { Float(node.value(key)) }
        let shape = geometry(node,aspect:Double(aspect))
        var values: [SIMD4<Float>] = [
            SIMD4(aspect,f("spread"),f("viscosity"),f("puff")),
            SIMD4(f("hardness"),f("edge"),f("glow"),f("sparkle")),
            SIMD4(f("reflection"),f("exposure"),f("background"),hasInput ? 1:0),
            SIMD4(f("motion"),Float(fmod(node.value("seed")*0.61803398875,1))*6.2831853,7,f("quality")),
            // w: the pour's interface width ε, to turn its phase back into a distance.
            SIMD4(Float(shape.segments.count),Float(shape.circles.count),f("threads"),Float(0.0032*max(0.6,node.value("spread"))))
        ]
        for s in shape.segments {
            // A conservative bound lets the shader skip far-away segments.
            let center = (s.a+s.control+s.b)/3
            let reach = max(simd_length(s.a-center),simd_length(s.b-center),simd_length(s.control-center)) + max(s.ra,s.rb)
            values += [SIMD4(Float(s.a.x),Float(s.a.y),Float(s.control.x),Float(s.control.y)),
                       SIMD4(Float(s.b.x),Float(s.b.y),Float(s.ra),Float(s.rb)),
                       SIMD4(Float(center.x),Float(center.y),Float(reach),Float(s.neck))]
        }
        for c in shape.circles { values.append(SIMD4(Float(c.center.x),Float(c.center.y),Float(c.radius),0)) }
        // Trailing vector after the circles: method and camera.
        values.append(SIMD4(f("method"),f("tilt"),f("turn"),f("warmth")))
        return values
    }
}

extension Node {
    public var hasLiquidChromeControls: Bool { kind == .shaderEffect && controlStyle == "liquidChrome" }
    /// Either liquid sculpture renderer: shared editor window, export and detail scaling.
    public var hasLiquidSculptureControls: Bool { hasLiquidMetalControls || hasLiquidChromeControls }
}
