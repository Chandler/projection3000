import Foundation

public enum MetallicPoolStyle {
    public static var parameters: [ParameterSpec] { [
        .init("function","Function",0,5,0,choices:["Liquid folds","Gaussian swells","Interference ripples","Cellular pools","Swells + folds","Ripples + swells"],midi:true,step:1),
        .init("blend","Blend",0,1,0.5),
        .init("speed","Speed",0,2,0.6),
        .init("orbit","Wave Depth",-1,1,0.1),
        .init("zoom","Wave Size",0.5,2,1.65),
        .init("spread","Flow Complexity",0.7,1.5,1),
        .init("shadows","Polish",0,1,0.8),
        .init("tintHue","Tint Hue",0,1,0.08),
        .init("tintStrength","Tint Strength",0,1,0)
    ] }
}
extension Node {
    public var hasMetallicPoolControls: Bool { kind == .scene && controlStyle == "metallicPool" }
}
