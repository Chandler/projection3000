import Foundation
import simd

/// A liquid body flattened into one closed XY path, and its reconstruction.
/// Position carries where the liquid is; beam dwell carries how much. Blobs are
/// spiral-filled, so their time on the path grows with area; threads are
/// zig-zags whose width sets their weight. Anything the analog path does to
/// timing or shape (slew, filtering, drift) redistributes the liquid itself.
public enum VoltageFluidStyle {
    public static let shapeParameters: [ParameterSpec] = [
        .init("seed","Seed",0,9999,7,midi:false,step:1),
        .init("blobs","Blobs",1,16,7,step:1),
        .init("size","Size",0.1,1,0.7),
        .init("body","Blob size",0.2,2,1),
        .init("fill","Fill density",0,1,0.5),
        .init("threads","Thread weight",0,1,0.35),
        .init("drips","Drips",0,8,3,step:1),
        .init("dripLength","Drip length",0,1,0.5),
        .init("rotation","Rotation (°)",-180,180,0),
        .init("spin","Rotation (turns/s)",-2,2,0)
    ]
    public static let shapeKeys = ["seed","blobs","size","body","fill","threads","drips","dripLength"]
    public static let fluidParameters: [ParameterSpec] = [
        .init("flow","Flow",0,4,1),
        .init("splat","Beam width",0.5,6,1.6),
        .init("push","Beam push",0,2,0.35),
        .init("gravity","Gravity",0,4,0.3),
        .init("tension","Surface tension",0,2,0.6),
        .init("viscosity","Viscosity",0,1,0.35),
        .init("swirl","Swirl",0,1,0.5),
        .init("evaporate","Evaporation",0,4,1.4),
        .init("level","Surface level",0.05,2,0.35),
        .init("puff","Puffiness",0,2,0.8),
        .init("hardness","Light hardness",0,1,0.75),
        .init("edge","Blue edge",0,1,0.6),
        .init("glow","Glow",0,1,0.35),
        .init("reflection","Video reflection",0,1,0.6),
        .init("exposure","Exposure",0.3,2,1),
        .init("hue","Tint hue",0,1,0),
        .init("saturation","Tint amount",0,1,0),
        .init("gainX","X scale",0.01,200,2), .init("gainY","Y scale",0.01,200,2),
        .init("zoom","Zoom",0.01,8,1), .init("x","X offset",-1,1,0), .init("y","Y offset",-1,1,0),
        .init("flipX","Flip X",0,1,0,choices:["Off","On"]), .init("flipY","Flip Y",0,1,0,choices:["Off","On"]),
        .init("quality","Detail",0,2,1,choices:["Draft","Balanced","Fine"],midi:false,step:1),
        .init("background","Background",0,1,1,choices:["Transparent","Black"],midi:false,step:1)
    ]
    /// Simulation grid long side for each Detail choice.
    public static func gridSide(_ node: Node) -> Int { [256,384,512][min(2,max(0,Int(node.value("quality").rounded())))] }
}

public enum FluidShapeGeometry {
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11)/9007199254740992.0
        }
        mutating func range(_ a: Double,_ b: Double) -> Double { a+(b-a)*next() }
    }
    public static func make(_ node: Node) -> VectorPath {
        var random = Random(state:UInt64(max(0,node.value("seed")))&*2654435761 &+ 91)
        let size = node.value("size"), count = max(1,min(16,Int(node.value("blobs").rounded())))
        let rx = size*1.1, ry = size*0.72
        let spacing = sqrt(Double.pi*rx*ry/Double(count))*0.8
        var centers: [SIMD2<Double>] = []
        var attempts = 0
        while centers.count < count && attempts < 4000 {
            attempts += 1
            let angle = random.range(0,2*Double.pi), radius = sqrt(random.next())
            let p = SIMD2(cos(angle)*radius*rx, sin(angle)*radius*ry+0.12*size)
            let minimum = spacing*(attempts > 2000 ? 0.5:1)
            if centers.allSatisfy({ simd_length($0-p) > minimum }) { centers.append(p) }
        }
        let base = size*0.3/sqrt(Double(count))*node.value("body")
        let radii = centers.map { _ in base*random.range(0.55,1.2) }

        // Prim's tree: one connected body, walked depth-first so the path closes on itself.
        var children = [[Int]](repeating:[],count:centers.count)
        var inTree: Set<Int> = [0]
        while inTree.count < centers.count {
            var best: (Int,Int,Double)?
            for i in inTree { for j in centers.indices where !inTree.contains(j) {
                let d = simd_length(centers[i]-centers[j])
                if best == nil || d < best!.2 { best = (i,j,d) }
            }}
            children[best!.0].append(best!.1); inTree.insert(best!.1)
        }
        let drips = Set(centers.indices.sorted { centers[$0].y < centers[$1].y }.prefix(max(0,Int(node.value("drips").rounded()))))

        // Spiral pitch sets mass per area: dense fill is a heavy, slow beam.
        let pitch = max(0.004,(1.15-node.value("fill"))*0.028*size)
        let thread = node.value("threads")*0.045*size
        var vertices: [SIMD2<Double>] = []
        func spiral(_ center: SIMD2<Double>,_ radius: Double) {
            let turns = max(1,radius/pitch), steps = Int(turns*40)
            let phase = random.range(0,2*Double.pi)
            for i in 0...steps {
                let t = Double(i)/Double(steps), a = phase+t*turns*2*Double.pi
                vertices.append(center+SIMD2(cos(a),sin(a))*radius*sqrt(t))
            }
            // Wind back in between the outbound arms.
            for i in stride(from:steps,through:0,by:-1) {
                let t = Double(i)/Double(steps), a = phase+t*turns*2*Double.pi+Double.pi
                vertices.append(center+SIMD2(cos(a),sin(a))*radius*sqrt(t)*0.97)
            }
        }
        func strand(_ a: SIMD2<Double>,_ b: SIMD2<Double>,width: Double) {
            let d = b-a, length = simd_length(d)
            guard length > 1e-6 else { return }
            let normal = SIMD2(-d.y,d.x)/length
            let teeth = width > 0.0005 ? max(2,Int(length/max(0.004,width*0.6))) : 1
            for i in 1...teeth {
                let t = Double(i)/Double(teeth)
                // Threads neck in the middle, as a stretched liquid bridge does.
                let neck = 0.35+0.65*abs(t*2-1)
                vertices.append(a+d*t+normal*(i%2 == 0 ? 1:-1)*width*neck*(i == teeth ? 0:1))
            }
        }
        func visit(_ i: Int) {
            vertices.append(centers[i])
            spiral(centers[i],radii[i])
            if drips.contains(i) {
                let bottom = centers[i]-SIMD2(0,radii[i]*0.8)
                let tip = bottom-SIMD2(0,random.range(0.3,1)*node.value("dripLength")*size*0.6)
                strand(centers[i],bottom,width:0)
                strand(bottom,tip,width:thread*0.5)
                spiral(tip,radii[i]*0.28)
                strand(tip,bottom,width:thread*0.5)
                strand(bottom,centers[i],width:0)
            }
            for child in children[i] {
                strand(centers[i],centers[child],width:thread)
                visit(child)
                strand(centers[child],centers[i],width:thread)
            }
        }
        guard !centers.isEmpty else { return VectorPath(vertices:[]) }
        visit(0)
        var deduped: [SIMD2<Float>] = []
        for v in vertices {
            let p = SIMD2<Float>(Float(v.x),Float(v.y))
            if let last = deduped.last, simd_length(last-p) < 1e-5 { continue }
            deduped.append(p)
        }
        return VectorPath(vertices:deduped,samples:max(8192,min(65536,deduped.count*2)))
    }
}
