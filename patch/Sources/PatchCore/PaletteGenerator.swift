import Foundation
public enum PaletteGenerator {
    public static var schemes: [String] { ["Custom"] + MeshGradientStyle.palettes.map(\.name) + ["Analogous","Complementary","Triad","Spectrum"] }
    public static var parameters: [ParameterSpec] { [
        .init("scheme","Scheme",0,Double(schemes.count-1),0,choices:schemes,step:1),
        .init("count","Color Count · 0 = original",0,32,0,step:1),
        .init("hueShift","Hue Shift (°)",-180,180,0),
        .init("saturation","Saturation",0,2,1),
        .init("seed","Variation",0,65535,0,step:1)
    ] }
    public static func hsv(_ h: Double,_ s: Double,_ v: Double) -> PaletteColor {
        let h=(h-floor(h))*6, i=Int(h), f=h-Double(i), p=v*(1-s), q=v*(1-s*f), t=v*(1-s*(1-f))
        switch i % 6 { case 0:return .init(v,t,p);case 1:return .init(q,v,p);case 2:return .init(p,v,t);case 3:return .init(p,q,v);case 4:return .init(t,p,v);default:return .init(v,p,q) }
    }
    public static func colors(_ node: Node) -> ColorPalette {
        let scheme=Int(node.value("scheme")), seed=node.value("seed")
        let variation=seed == 0 ? 0 : (sin(seed*127.1)*43758.5453).truncatingRemainder(dividingBy:1)
        let original=node.palette ?? PaletteStyle.defaultPalette
        let base=scheme>0 && scheme<=MeshGradientStyle.palettes.count ? ColorPalette(MeshGradientStyle.palettes[scheme-1].colors.map(PaletteColor.init(hex:))) : original
        let count=node.value("count")>0 ? Int(node.value("count")) : base.colors.count
        let harmonic=scheme-MeshGradientStyle.palettes.count
        let result=(0..<max(1,count)).map { i -> PaletteColor in
            let x=count>1 ? Double(i)/Double(count-1) : 0
            let color: PaletteColor
            if harmonic>0 {
                let offsets=[x*0.18,Double(i%2)*0.5+Double(i/2)*0.025,Double(i%3)/3,Double(i)/Double(max(1,count))]
                color=hsv(0.58+offsets[min(3,harmonic-1)]+variation,0.82,1)
            } else { color=base.sampled(at:x) }
            let hi=max(color.r,max(color.g,color.b)),lo=min(color.r,min(color.g,color.b))
            let saturation=hi>0 ? (hi-lo)/hi : 0
            return hsv(color.hue+node.value("hueShift")/360+(harmonic>0 ? 0 : variation*0.12),min(1,max(0,saturation*node.value("saturation"))),hi)
        }
        return ColorPalette(result)
    }
}
