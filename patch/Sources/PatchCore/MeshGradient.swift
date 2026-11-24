import Foundation

public enum MeshGradientStyle {
    public struct Palette: Sendable {
        public let name: String
        public let colors: [UInt32]
    }
    public static let palettes: [Palette] = [
        .init(name:"Molten",colors:[0x260E38,0xEB384D,0xFFAD48,0x6D1952,0xFF713D,0xFEE4A0,0xB22A69,0xFFCE73]),
        .init(name:"Aurora",colors:[0x101A44,0x7152DA,0x35E4BB,0x183C79,0xE0B4FA,0x40A9BD,0xAC63DB,0xBEF3CF]),
        .init(name:"Tidal",colors:[0x071E37,0x127990,0x80E5D0,0x254B85,0x38B7D0,0xE7F3CF,0x25635C,0x94C9F0]),
        .init(name:"Afterglow",colors:[0x382C81,0xEA6C9B,0xFFCE8C,0xA34691,0xFC9677,0xFBE4B8,0x6B5DB4,0xEBB3C9]),
        .init(name:"Sorbet",colors:[0xF4B3CF,0xF6E3A1,0xB7DCCC,0xBBA8E2,0xF8C6A1,0xEAE1F7,0xADE1E8,0xE6EDBE]),
        .init(name:"Iris",colors:[0x18122C,0x522F87,0xBA8FD9,0x312255,0x8557B4,0xE8CDED,0x6E587F,0xB7B3E4]),
        .init(name:"Moss",colors:[0x142C2B,0x46734A,0xCAD486,0x314B40,0x92AC65,0xEDE5B5,0x5C8E81,0xB6CAA1]),
        .init(name:"Ember",colors:[0x170E1A,0x692339,0xE75A36,0x38192B,0xB03B33,0xF7B45B,0x963D5A,0xF5D08E]),
        .init(name:"Chrome",colors:[0x101216,0xE8EDF2,0x737B85,0x24282F,0xFAFCFF,0xAAB2BC,0x414851,0xD4DAE1])
    ]
    public static let positions: [Position] = [.init(0.12,0.16),.init(0.5,0.12),.init(0.88,0.2),.init(0.16,0.82),.init(0.52,0.72),.init(0.9,0.86),.init(0.32,0.45),.init(0.75,0.46)]

    public static let maxPoints = 40
    public static let maxStrokePoints = 192
    public static let pointStride = 217 // 9 field slots, 16 gradient-stop slots, 192 path slots
    public static let blendModes = ["Existing", "Normal", "Linear light", "OKLab", "Multiply", "Screen", "Overlay", "Soft light", "Lighten", "Darken"]
    public static let shapes = ["Ellipse", "Line", "Arc", "Brush"]
    public static let parameters: [ParameterSpec] = {
        var specs: [ParameterSpec] = [
            .init("count","Color regions",1,Double(maxPoints),6,midi:false,step:1),
            .init("fieldStyle","Field rendering",0,1,1,choices:["Existing","Shaped"],midi:false,step:1),
            .init("motion","Motion",0,4,0,choices:["Still","Drift","Lava","Orbit","Wander"],midi:true,step:1),
            .init("speed","Speed",0,3,0.35), .init("movement","Movement",0,1,0.55),
            .init("motionX","Horizontal travel",0,1,1), .init("motionY","Vertical travel",0,1,1),
            .init("motionPhase","Animation phase",0,1,0),
            .init("motionBoundary","Motion bounds",0,1,0,choices:["Free","Reflect"],midi:true,step:1),
            .init("softness","Blend softness",0,1,0.55), .init("warp","Flow distortion",0,1,0),
            .init("blendSpace","Blending",0,9,3,choices:blendModes,midi:true,step:1),
            .init("grain","Grain amount",0,1,0.12), .init("grainSize","Grain size",1,8,1),
            .init("grainDensity","Grain density",0,1,0.7),
            .init("grainType","Grain type",0,2,0,choices:["Mono","Duo","RGB"],midi:true,step:1),
            .init("grainColor","Grain color",0,16777215,16777215,midi:false,step:1),
            .init("grainColor2","Second grain color",0,16777215,255,midi:false,step:1),
            .init("seed","Seed",0,10000,427,midi:false,step:1),
            .init("hue","Hue",-180,180,0), .init("saturation","Saturation",0,2,1),
            .init("brightness","Brightness",0.2,1.8,1), .init("temperature","Temperature",-100,100,0)
        ]
        for i in 0..<maxPoints {
            let p = positions[i % positions.count], col = palettes[0].colors[i % 8]
            func add(_ key: String,_ title: String,_ lo: Double,_ hi: Double,_ initial: Double, choices: [String]? = nil, midi: Bool = true) {
                specs.append(.init("\(key)\(i)","Region \(i+1) \(title)",lo,hi,initial,choices:choices,midi:midi,step:choices == nil ? nil : 1))
            }
            add("x","X",-2,3,p.x); add("y","Y",-2,3,p.y)
            specs.append(.init("color\(i)","Region \(i+1) color",0,16777215,Double(col),midi:false,step:1))
            add("shape","Shape",0,3,0,choices:shapes,midi:false)
            for key in ["left","right","top","bottom"] { add(key,key.capitalized+" spread",0.01,5,0.5) }
            add("angle","Rotation",-180,180,0); add("axisAngle","Second axis",-180,180,90)
            add("brushBase","Brush base hardness",1,10000,2.5,midi:false)
            add("hardness","Hardness",1,5000,2.2); add("width","Band width",0.001,2,0.3)
            add("linked","Linked arms",0,1,1,choices:["Independent","Linked"],midi:false)
            add("bend","Bend",-175,175,20)
            add("opacity","Opacity",0,1,1); add("overlay","Composite",0,1,0,choices:["Blend","Over"],midi:false)
            add("feather","Edge feather",0,0.2,0.003); add("featherB","Second edge feather",0,0.2,0.003)
            add("featherAngle","Feather angle",-180,180,0)
            for (key,angle) in [("leftAngle",180.0),("rightAngle",0),("topAngle",-90),("bottomAngle",90)] { add(key,key, -180,180,angle) }
            add("travel","Animation amount",0,2,1); add("rate","Animation rate",0,3,1)
            add("phase","Animation phase",0,1,(Double(i)*0.381966).truncatingRemainder(dividingBy:1))
            add("gradient","Fill",0,1,0,choices:["Solid","Gradient"],midi:false)
            add("gradientAngle","Fill angle",-180,180,0)
            add("gradientEase","Fill easing",0,3,0,choices:["Linear","Ease in","Ease out","Ease in/out"],midi:false)
        }
        return specs
    }()
    private static let defaults = Dictionary(uniqueKeysWithValues:parameters.map { ($0.key,$0.initial) })
    public static func value(_ node: Node,_ key: String) -> Double {
        // Old patches opt into the original shader until a shape is edited or a preset is applied.
        if key == "fieldStyle", node.parameters[key] == nil { return 0 }
        return node.parameters[key] ?? defaults[key] ?? 0
    }
    public struct Detail: Codable, Equatable, Sendable {
        public var paths: [String:[[Double]]] = [:] // relative x/y in long-side units, hardness
        public var stops: [String:[[Double]]] = [:] // position, packed RGB, opacity
        public init() {}
        public init(text: String?) {
            self = text.flatMap { $0.data(using:.utf8) }.flatMap { try? JSONDecoder().decode(Self.self,from:$0) } ?? Self()
        }
        public var text: String? { (try? JSONEncoder().encode(self)).flatMap { String(data:$0,encoding:.utf8) } }
    }
    public static let regionPrefixes = ["x","y","color","shape","left","right","top","bottom","angle","axisAngle","hardness","brushBase","width","linked","bend","opacity","overlay","feather","featherB","featherAngle","leftAngle","rightAngle","topAngle","bottomAngle","travel","rate","phase","gradient","gradientAngle","gradientEase"]
    public static func color(_ packed: Double) -> SIMD4<Float> {
        let c = UInt32(max(0,min(16777215,packed)).rounded())
        return .init(Float((c>>16)&255)/255,Float((c>>8)&255)/255,Float(c&255)/255,0)
    }
    public static func animatedPosition(_ node: Node,index: Int,time: Double) -> Position {
        func v(_ key: String) -> Double { value(node,key) }
        let x=v("x\(index)"), y=v("y\(index)"), mode=Int(v("motion"))
        let amount=v("movement")*v("travel\(index)"), t=time*0.42*v("rate\(index)")
        let phase=(v("phase\(index)")+v("motionPhase"))*2*Double.pi
        var dx=0.0,dy=0.0
        if mode == 1 { dx=0.17*sin(t*0.7+phase); dy=0.17*cos(t*0.53+phase*1.3) }
        if mode == 2 { dx=0.16*sin(t*0.67+phase)+0.07*sin(t*1.13-phase); dy=0.29*sin(t*0.49+phase*1.7)+0.06*cos(t*0.83+phase) }
        if mode == 3 { let a=t*0.48+v("motionPhase")*2*Double.pi; dx=cos(a)*(x-0.5)-sin(a)*(y-0.5)-(x-0.5);dy=sin(a)*(x-0.5)+cos(a)*(y-0.5)-(y-0.5) }
        if mode == 4 { dx=0.22*sin(t*0.31+phase)+0.12*sin(t*0.79+phase*2.1);dy=0.22*cos(t*0.37+phase*1.3)+0.12*sin(t*0.61-phase) }
        func bound(_ n: Double) -> Double { let m=n.truncatingRemainder(dividingBy:2);return 1-abs((m < 0 ? m+2 : m)-1) }
        let px=x+dx*amount*v("motionX"), py=y+dy*amount*v("motionY")
        return .init(v("motionBoundary") > 0 ? bound(px) : px,v("motionBoundary") > 0 ? bound(py) : py)
    }
    public static func shaderValues(_ node: Node,palette: ColorPalette? = nil,time: Double = 0,detail: Detail? = nil) -> [SIMD4<Float>] {
        func v(_ key: String) -> Float { Float(value(node,key)) }
        let count=max(1,min(maxPoints,Int(value(node,"count"))))
        func rgb(_ i: Int) -> SIMD4<Float> {
            color(palette.flatMap { $0.colors.isEmpty ? nil : Double($0.sampled(at:Double(i)/Double(max(1,count-1))).hex) } ?? value(node,"color\(i)"))
        }
        // Preserve the complete original 18-slot ABI for user-authored shaders.
        var out: [SIMD4<Float>] = [.init(v("count"),v("motion"),v("movement"),v("softness")),.init(v("warp"),v("grain"),0,0)]
        for i in 0..<8 { out += [.init(v("x\(i)"),v("y\(i)"),0,0),rgb(i)] }
        out += [.init(2,v("fieldStyle"),v("blendSpace"),v("softness")),.init(v("grainSize"),v("grainDensity"),v("grainType"),v("seed")),.init(v("hue"),v("saturation"),v("brightness"),v("temperature")),color(value(node,"grainColor")),color(value(node,"grainColor2")),.zero]
        let detail=detail ?? Detail(text:node.text)
        for i in 0..<count {
            func f(_ prefix: String) -> Float { v("\(prefix)\(i)") }
            let p=animatedPosition(node,index:i,time:time)
            let raw=detail.paths[String(i)] ?? (Int(value(node,"shape\(i)")) == 3 ? [[-0.2,0,Double(f("hardness"))],[0.2,0,Double(f("hardness"))]]:[]), path=Array(raw.filter { $0.count >= 2 && $0.allSatisfy(\.isFinite) }.prefix(maxStrokePoints))
            let stops=Array((detail.stops[String(i)] ?? [[0,value(node,"color\(i)"),1],[1,value(node,"color\(i)"),1]]).filter { $0.count >= 3 && $0.allSatisfy(\.isFinite) }.sorted { $0[0] < $1[0] }.prefix(8))
            let deg=Float.pi/180
            out += [.init(Float(p.x),Float(p.y),f("shape"),f("opacity")),.init(f("left"),f("right"),f("top"),f("bottom")),.init(f("angle")*deg,f("axisAngle")*deg,f("hardness"),f("width")),.init(f("linked"),f("bend")*deg,f("overlay"),0),.init(f("leftAngle")*deg,f("rightAngle")*deg,f("topAngle")*deg,f("bottomAngle")*deg),.init(f("feather"),f("featherB"),f("featherAngle")*deg,0),.init(f("brushBase"),0,0,0),.init(rgb(i).x,rgb(i).y,rgb(i).z,Float(path.count)),.init(f("gradient"),f("gradientAngle")*deg,f("gradientEase"),Float(stops.count))]
            for j in 0..<8 {
                if j < stops.count { let c=palette.flatMap { $0.colors.isEmpty ? nil:color(Double($0.sampled(at:stops[j][0]).hex)) } ?? color(stops[j][1]);out += [.init(Float(max(0,min(1,stops[j][0]))),Float(max(0,min(1,stops[j][2]))),0,0),c] }
                else { out += [.zero,.zero] }
            }
            for j in 0..<maxStrokePoints { out.append(j < path.count ? .init(Float(path[j][0]),Float(path[j][1]),Float(path[j].count > 2 ? max(1,min(10000,path[j][2])) : value(node,"hardness\(i)")),0) : .zero) }
        }
        return out
    }
}
