import Foundation

/// A continuous normalized XY traversal, independent of raster resolution or audio clock.
/// Outline strokes use equal-distance samples; optional travel edges run faster.
public struct VectorPath: Sendable {
    public var points: [SIMD2<Float>]
    private var circleRadius: Float?
    private var cubeRadius: Float?
    private static let cubeWalk=[0,1,3,2,0,4,5,1,5,7,3,7,6,2,6,4,0]
    public private(set) var contours: [[SIMD2<Float>]] = []
    public struct Signature: Equatable, Sendable {
        var kind: NodeKind
        var parameters: [String:Double]
        var text: String?
        public init(_ node: Node) {
            kind=node.kind
            parameters=node.parameters.filter { (["shape","size","inner","fill","hatch","cells","font","lineSpacing","travel"]+VoltageFluidStyle.shapeKeys).contains($0.key) }
            text=node.kind == .vectorText ? String((node.text ?? "PATCH").prefix(128)):nil
        }
    }
    public init(contours: [[SIMD2<Float>]],travelSpeed: Double = 16) {
        var vertices=[SIMD2<Float>](),travel=Set<Int>()
        let valid=contours.filter { $0.count>1 }
        for contour in valid {
            var line=contour
            if line.first == line.last { line.removeLast() }
            guard line.count>1 else { continue }
            if let previous=vertices.last,let entry=line.indices.min(by:{
                let a=line[$0]-previous,b=line[$1]-previous
                return a.x*a.x+a.y*a.y<b.x*b.x+b.y*b.y
            }) { line=Array(line[entry...])+Array(line[..<entry]);travel.insert(vertices.count-1) }
            vertices += line+[line[0]]
        }
        if !vertices.isEmpty { travel.insert(vertices.count-1) }
        self.init(vertices:vertices,samples:max(8192,min(65536,vertices.count*4)),travelEdges:travel,travelSpeed:travelSpeed)
        self.contours=valid
    }
    public init(vertices: [SIMD2<Float>], samples: Int = 4096,travelEdges: Set<Int> = [],travelSpeed: Double = 1) {
        guard vertices.count > 1, samples > 1 else { points = []; return }
        var lengths = [Double](repeating:0,count:vertices.count+1)
        for i in vertices.indices {
            let d = vertices[(i+1)%vertices.count]-vertices[i]
            lengths[i+1] = lengths[i]+Double((d.x*d.x+d.y*d.y).squareRoot())/(travelEdges.contains(i) ? max(1,travelSpeed):1)
        }
        guard lengths.last! > 0 else { points = []; return }
        var edge = 0
        points = (0..<samples).map { i in
            let distance = Double(i)/Double(samples)*lengths.last!
            while edge+1 < vertices.count && lengths[edge+1] < distance { edge += 1 }
            let t = Float((distance-lengths[edge])/max(1e-12,lengths[edge+1]-lengths[edge]))
            return vertices[edge]+(vertices[(edge+1)%vertices.count]-vertices[edge])*t
        }
    }
    public func point(_ phase: Double,rotation: Double = 0) -> SIMD2<Float> {
        let phase=phase-floor(phase)
        if let radius=cubeRadius {
            let t=phase*16,edge=min(15,Int(t)),f=Float(t-Double(edge))
            let yaw=Float(rotation)+0.55,tilt=Float(rotation*0.61)+0.35
            let cy=cos(yaw),sy=sin(yaw),ct=cos(tilt),st=sin(tilt)
            func vertex(_ i: Int) -> SIMD2<Float> {
                let x=i&1 != 0 ? radius:-radius,y=i&2 != 0 ? radius:-radius,z=i&4 != 0 ? radius:-radius
                let u=x*cy+z*sy,v = -x*sy+z*cy
                return SIMD2(u,y*ct-v*st)
            }
            let a=vertex(Self.cubeWalk[edge]),b=vertex(Self.cubeWalk[edge+1])
            return a+(b-a)*f
        }
        let point: SIMD2<Float>
        if let radius=circleRadius { point=SIMD2(cos(Float(phase*2*Double.pi))*radius,sin(Float(phase*2*Double.pi))*radius) }
        else {
            guard !points.isEmpty else { return .zero }
            let p=phase*Double(points.count),i=min(points.count-1,Int(p))
            point=points[i]+(points[(i+1)%points.count]-points[i])*Float(p-Double(i))
        }
        let c=cos(Float(rotation)),s=sin(Float(rotation))
        return SIMD2(point.x*c-point.y*s,point.x*s+point.y*c)
    }
    public func preview(rotation: Double) -> [SIMD2<Float>] {
        if contours.isEmpty { return points.isEmpty ? []:(0...1024).map { point(Double($0)/1024,rotation:rotation) } }
        let c=cos(Float(rotation)),s=sin(Float(rotation))
        func rotated(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(p.x*c-p.y*s,p.x*s+p.y*c) }
        return contours.flatMap { line in
            (0..<line.count).flatMap { i in [rotated(line[i]),rotated(line[(i+1)%line.count])] }
        }
    }
    /// The outline followed by evenly spaced interior lines, drawn back and forth.
    /// Connectors between neighboring line ends hug the outline, so they are drawn
    /// at full speed; only the return to the start is a fast travel move.
    private static func hatched(_ outline: [SIMD2<Float>],lines: Int) -> VectorPath {
        // The last line runs toward the start side to keep that return short.
        var vertices=outline+[outline[0]],forward=lines%2 == 0
        let low=outline.map(\.y).min()!,high=outline.map(\.y).max()!
        for line in 1...lines {
            let y=low+(high-low)*Float(line)/Float(lines+1)
            var crossings=[Float]()
            for i in outline.indices {
                let a=outline[i],b=outline[(i+1)%outline.count]
                if (a.y<=y) != (b.y<=y) { crossings.append(a.x+(b.x-a.x)*(y-a.y)/(b.y-a.y)) }
            }
            crossings.sort()
            if !forward { crossings.reverse() }
            for i in stride(from:0,to:crossings.count-1,by:2) { vertices += [SIMD2(crossings[i],y),SIMD2(crossings[i+1],y)] }
            forward.toggle()
        }
        return VectorPath(vertices:vertices,samples:8192,travelEdges:[vertices.count-1],travelSpeed:16)
    }
    /// Dark squares of a cells×cells board. Outline traces each square; hatched
    /// scans across each cell row, skipping light squares with travel moves.
    private static func checkerboard(radius: Float,cells: Int,hatch: Int?) -> VectorPath {
        let cell=2*radius/Float(cells)
        func dark(_ row: Int,_ column: Int) -> Bool { (row+column)%2 == 0 }
        guard let hatch else {
            var contours=[[SIMD2<Float>]]()
            for row in 0..<cells {
                let columns=Array(0..<cells)
                for column in row%2 == 0 ? columns:columns.reversed() where dark(row,column) {
                    let x = -radius+Float(column)*cell,y = -radius+Float(row)*cell
                    contours.append([SIMD2(x,y),SIMD2(x+cell,y),SIMD2(x+cell,y+cell),SIMD2(x,y+cell)])
                }
            }
            return VectorPath(contours:contours)
        }
        let perRow=max(1,Int((Double(hatch)/Double(cells)).rounded()))
        var vertices=[SIMD2<Float>](),travel=Set<Int>(),forward=true
        for row in 0..<cells {
            for line in 1...perRow {
                let y = -radius+(Float(row)+Float(line)/Float(perRow+1))*cell
                var segments=(0..<cells).filter { dark(row,$0) }.map { (-radius+Float($0)*cell,-radius+Float($0+1)*cell) }
                if !forward { segments=segments.reversed().map { ($0.1,$0.0) } }
                for (a,b) in segments {
                    if !vertices.isEmpty { travel.insert(vertices.count-1) }
                    vertices += [SIMD2(a,y),SIMD2(b,y)]
                }
                forward.toggle()
            }
        }
        travel.insert(vertices.count-1)
        return VectorPath(vertices:vertices,samples:8192,travelEdges:travel,travelSpeed:16)
    }
    public static func shape(_ node: Node) -> VectorPath {
        if node.kind == .vectorText { return VectorTextGeometry.make(node) }
        if node.kind == .fluidShape { return FluidShapeGeometry.make(node) }
        let shape = Int(node.value("shape")), radius = Float(node.value("size"))
        if shape == 4 { return checkerboard(radius:radius,cells:max(2,Int(node.value("cells"))),hatch:node.value("fill") >= 0.5 ? max(1,Int(node.value("hatch"))):nil) }
        if node.value("fill") >= 0.5 && shape != 3 {
            let n = shape == 1 ? 128 : 10
            let outline: [SIMD2<Float>] = shape == 0 ? [SIMD2(-radius,-radius),SIMD2(radius,-radius),SIMD2(radius,radius),SIMD2(-radius,radius)] : (0..<n).map { i in
                let angle = Float(i)*2*Float.pi/Float(n)-Float.pi/2
                let r = shape == 2 && i%2 == 1 ? radius*Float(node.value("inner")) : radius
                return SIMD2(cos(angle)*r,sin(angle)*r)
            }
            return hatched(outline,lines:max(1,Int(node.value("hatch"))))
        }
        if shape == 0 { return VectorPath(vertices:[SIMD2(-radius,-radius),SIMD2(radius,-radius),SIMD2(radius,radius),SIMD2(-radius,radius)]) }
        if shape == 1 { var path=VectorPath(vertices:[SIMD2(radius,0),SIMD2(0,radius)]);path.circleRadius=radius;return path }
        if shape == 3 { var path=VectorPath(vertices:[SIMD2(radius,0),SIMD2(0,radius)]);path.cubeRadius=radius*0.5;return path }
        let n = 10
        return VectorPath(vertices:(0..<n).map { i in
            let angle = Float(i)*2*Float.pi/Float(n)-Float.pi/2
            let r = shape == 2 && i%2 == 1 ? radius*Float(node.value("inner")) : radius
            return SIMD2(cos(angle)*r,sin(angle)*r)
        })
    }
}
public enum AnalogVectorStyle {
    public static func trailSeconds(_ node: Node,rate: Double) -> Double {
        min(1,max(0,node.value("historyMS")>0 ? node.value("historyMS")/1000:node.value("cycles")/max(5,rate)))
    }
    public static let outputRateParameters: [ParameterSpec] = [
        .init("sampleRate","Hardware sample rate",0,3,0,choices:["Device current","48 kHz","96 kHz","192 kHz"],midi:false,step:1)
    ]
    public static func requestedRate(_ node: Node) -> Double {
        [0.0,48000,96000,192000][min(3,max(0,Int(node.value("sampleRate"))))]
    }
    public static let channelParameters: [ParameterSpec] = [
        .init("channelX","Left / X channel",1,64,1,midi:false,step:1),
        .init("channelY","Right / Y channel",1,64,2,midi:false,step:1)
    ]
    public static let shapeParameters: [ParameterSpec] = [
        .init("shape","Shape",0,4,2,choices:["Square","Circle","Star","Cube","Checkerboard"],midi:true,step:1),
        .init("size","Size",0.05,1,0.78), .init("inner","Star inner radius",0.05,0.95,0.41),
        .init("fill","Fill",0,1,0,choices:["Outline","Hatched"],midi:true,step:1),
        .init("hatch","Hatch lines",1,64,12,step:1),
        .init("cells","Checker cells",2,16,4,step:1),
        .init("rotation","Rotation (°)",-180,180,0), .init("spin","Rotation (turns/s)",-2,2,0.1)
    ]
    public static let textParameters: [ParameterSpec] = [
        .init("font","Font",0,2,0,choices:["Sans","Monospace","Serif"],midi:false,step:1),
        .init("size","Size",0.05,1,0.85), .init("lineSpacing","Line spacing",0.8,2,1.3),
        .init("travel","Travel speed",1,32,16),
        .init("rotation","Rotation (°)",-180,180,0), .init("spin","Rotation (turns/s)",-2,2,0)
    ]
    public static let encoderParameters: [ParameterSpec] = [
        .init("rate","Draw rate (Hz)",5,1000,80), .init("level","Output level",0,1,0.5),
        .init("levelX","X output level",0,1,1), .init("levelY","Y output level",0,1,1)
    ]
    public static let visualizerParameters: [ParameterSpec] = [
        .init("rate","Unlinked draw rate (Hz)",5,1000,80),
        .init("cycles","Trail length (draw cycles)",0.1,8,2),
        .init("historyMS","Trail duration (ms; 0 follows cycles)",0,300,0),
        .init("antialias","Antialiasing",0,1,0,choices:["1×","4× MSAA"],midi:false,step:1),
        .init("drawing","Drawing",0,2,1,choices:["Straight connectors","Rounded connectors","Dots"],midi:true,step:1),
        .init("blend","Blend",0,1,1,choices:["Add","Maximum"],midi:true,step:1),
        .init("width","Line / dot width (px)",0.5,12,1.5), .init("glow","Glow",0,1,0.2),
        .init("gainX","X scale",0.01,200,2), .init("gainY","Y scale",0.01,200,2),
        .init("zoom","Zoom",0.01,8,1), .init("x","X offset",-1,1,0), .init("y","Y offset",-1,1,0),
        .init("flipX","Flip X",0,1,0,choices:["Off","On"]), .init("flipY","Flip Y",0,1,0,choices:["Off","On"]),
        .init("hue","Hue",0,1,0.39), .init("saturation","Saturation",0,1,0.85), .init("brightness","Brightness",0,1,0.8)
    ]
    public static let oscilloscopeParameters: [ParameterSpec] = [
        .init("channels","Channels",0,2,0,choices:["Both","Left / X","Right / Y"],midi:true,step:1),
        .init("timeMS","Time window (ms)",0.1,250,50),
        .init("gainX","Left / X gain",0.01,200,1), .init("gainY","Right / Y gain",0.01,200,1),
        .init("offsetX","Left / X vertical offset",-1,1,0), .init("offsetY","Right / Y vertical offset",-1,1,0),
        .init("trigger","Trigger",0,2,1,choices:["Free running","Rising edge","Falling edge"],midi:true,step:1),
        .init("triggerChannel","Trigger channel",0,1,0,choices:["Left / X","Right / Y"],midi:true,step:1),
        .init("triggerLevel","Trigger level",-1,1,0),
        .init("grid","Grid",0,1,1,choices:["Off","On"],midi:true,step:1),
        .init("width","Trace width (px)",0.5,6,1.5), .init("brightness","Brightness",0,1,0.9),
        .init("antialias","Antialiasing",0,1,0,choices:["1×","4× MSAA"],midi:false,step:1)
    ]
    public static let projectorParameters: [ParameterSpec] = [
        .init("tlX","Top left X",0,1,0,midi:false), .init("tlY","Top left Y",0,1,0,midi:false),
        .init("trX","Top right X",0,1,1,midi:false), .init("trY","Top right Y",0,1,0,midi:false),
        .init("brX","Bottom right X",0,1,1,midi:false), .init("brY","Bottom right Y",0,1,1,midi:false),
        .init("blX","Bottom left X",0,1,0,midi:false), .init("blY","Bottom left Y",0,1,1,midi:false)
    ]
}
