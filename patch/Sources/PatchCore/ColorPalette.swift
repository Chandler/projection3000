import Foundation

/// Ordered, normalized sRGB colors. A palette's length is independent of node port counts.
public struct PaletteColor: Codable, Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double,_ g: Double,_ b: Double) { self.r=r; self.g=g; self.b=b }
    public init(hex: UInt32) { self.init(Double((hex >> 16)&255)/255,Double((hex >> 8)&255)/255,Double(hex&255)/255) }
    public var hex: UInt32 { (UInt32((r*255).rounded()) << 16) | (UInt32((g*255).rounded()) << 8) | UInt32((b*255).rounded()) }
    public var isValid: Bool { [r,g,b].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    public func mixed(with other: PaletteColor,amount: Double) -> PaletteColor {
        .init(r+(other.r-r)*amount,g+(other.g-g)*amount,b+(other.b-b)*amount)
    }
    public var luminance: Double { r*0.2126+g*0.7152+b*0.0722 }
    public func distance(to c: PaletteColor) -> Double { pow(r-c.r,2)+pow(g-c.g,2)+pow(b-c.b,2) }
    public var hue: Double {
        let hi=max(r,g,b), lo=min(r,g,b), d=hi-lo
        guard d>0.00001 else { return 0 }
        let h = hi == r ? (g-b)/d : hi == g ? (b-r)/d+2 : (r-g)/d+4
        return (h/6+1).truncatingRemainder(dividingBy:1)
    }
}
public struct ColorPalette: Codable, Equatable, Sendable {
    public var colors: [PaletteColor]
    public init(_ colors: [PaletteColor]) { self.colors=colors }
    public static let empty = ColorPalette([])
    /// Resample the ordered list to a consumer's fixed number of anchors.
    public func sampled(at fraction: Double) -> PaletteColor {
        guard let first=colors.first else { return .init(0,0,0) }
        guard colors.count>1 else { return first }
        let p=min(1,max(0,fraction))*Double(colors.count-1), i=Int(p)
        return colors[i].mixed(with:colors[min(i+1,colors.count-1)],amount:p-Double(i))
    }
}
public enum PaletteStyle {
    public static let defaultPalette = ColorPalette(MeshGradientStyle.palettes[0].colors.map(PaletteColor.init(hex:)))
    public static let extractionParameters: [ParameterSpec] = [
        .init("count","Colors",1,32,6,midi:false,step:1),
        .init("rate","Updates / second",1,15,5),
        .init("smoothing","Smoothing (s)",0,2,0.3),
        .init("order","Color order",0,3,0,choices:["Stable","Dominance","Hue","Brightness"],midi:false,step:1)
    ]
    public static func meshPalette(_ node: Node) -> ColorPalette {
        .init((0..<max(3,min(8,Int(node.value("count"))))).map { PaletteColor(hex:UInt32(node.value("color\($0)").rounded())) })
    }
    /// Weighted clustering of a small frame sample, without full-frame CPU readback.
    public static func extract(_ pixels: [SIMD4<Float>],count: Int,order: Int,previous: ColorPalette) -> ColorPalette {
        var bins: [Int:(PaletteColor,Int)] = [:]
        for p in pixels where p.w>0.05 && p.x.isFinite && p.y.isFinite && p.z.isFinite {
            let c=PaletteColor(Double(max(0,min(1,p.x))),Double(max(0,min(1,p.y))),Double(max(0,min(1,p.z))))
            let key=(Int(c.r*31)<<10) | (Int(c.g*31)<<5) | Int(c.b*31)
            if let (old,n)=bins[key] { bins[key]=(old.mixed(with:c,amount:1/Double(n+1)),n+1) } else { bins[key]=(c,1) }
        }
        let samples=bins.sorted { $0.key<$1.key }.map(\.value)
        guard let first=samples.max(by: { $0.1<$1.1 }) else { return .empty }
        let k=min(max(1,count),samples.count)
        var centers=[first.0]
        while centers.count<k {
            let next=samples.max { a,b in
                let da=centers.map { $0.distance(to:a.0) }.min()! * Double(a.1)
                let db=centers.map { $0.distance(to:b.0) }.min()! * Double(b.1)
                return da<db
            }!.0
            centers.append(next)
        }
        var weights=[Int](repeating:0,count:k)
        for _ in 0..<5 {
            var sums=[SIMD3<Double>](repeating:.zero,count:k); weights=[Int](repeating:0,count:k)
            for (c,n) in samples {
                let i=centers.indices.min { centers[$0].distance(to:c)<centers[$1].distance(to:c) }!
                sums[i] += SIMD3(c.r,c.g,c.b)*Double(n); weights[i] += n
            }
            for i in centers.indices where weights[i]>0 {
                let c=sums[i]/Double(weights[i]); centers[i] = .init(c.x,c.y,c.z)
            }
        }
        var colors=centers.indices.filter { weights[$0]>0 }.sorted { weights[$0] == weights[$1] ? $0<$1 : weights[$0]>weights[$1] }.map { centers[$0] }
        if order==2 { colors.sort { $0.hue<$1.hue } }
        else if order==3 { colors.sort { $0.luminance<$1.luminance } }
        else if order==0 && !previous.colors.isEmpty {
            var ordered: [PaletteColor]=[]
            for old in previous.colors where !colors.isEmpty {
                let i=colors.indices.min { colors[$0].distance(to:old)<colors[$1].distance(to:old) }!
                ordered.append(colors.remove(at:i))
            }
            colors=ordered+colors
        }
        return .init(colors)
    }
}
extension Graph {
    public mutating func setPalette(_ id: UUID,colors: [PaletteColor]) throws {
        guard let i=nodes.firstIndex(where:{$0.id==id}),nodes[i].kind == .palette else { throw GraphError("Choose a Palette source node") }
        guard (1...256).contains(colors.count),colors.allSatisfy(\.isValid) else { throw GraphError("Use 1–256 valid sRGB colors") }
        nodes[i].palette = .init(colors)
    }
}

/// Palette-only adjustment: no video readback or changes to color order/count.
public enum PaletteAdjustmentStyle {
    public static let parameters: [ParameterSpec] = [
        .init("mode","Mode",0,2,0,choices:["Off","Normalize brightness","Hue only"],midi:true,step:1),
        .init("brightness","Brightness",0,1,1),
        .init("saturation","Saturation",0,1,1)
    ]
    public static func apply(_ palette: ColorPalette,node: Node) -> ColorPalette {
        let mode=Int(node.value("mode").rounded())
        guard mode != 0 else { return palette }
        let brightness=min(1,max(0,node.value("brightness")))
        let saturation=min(1,max(0,node.value("saturation")))
        return .init(palette.colors.map { color in
            let high=max(color.r,color.g,color.b), low=min(color.r,color.g,color.b)
            // Black carries no hue. Keep it black instead of inventing a color.
            guard high>0 else { return color }
            if mode == 1 {
                return .init(color.r/high*brightness,color.g/high*brightness,color.b/high*brightness)
            }
            let chroma=high-low
            // Neutral colors stay neutral, rather than inheriting an arbitrary red hue.
            guard chroma>high*1e-6 else { return .init(brightness,brightness,brightness) }
            func channel(_ value: Double) -> Double {
                brightness*((1-saturation)+saturation*(value-low)/chroma)
            }
            return .init(channel(color.r),channel(color.g),channel(color.b))
        })
    }
}
