import Foundation

/// Controls specific to the Horizontal Bars shader; mapping remains in p1–p4.
public enum BlindsStyle {
    public static let animations = ["Static", "Sequential Flash", "Chase", "Multi-speed Chase", "Scatter Flash", "Pulse Wave"]
    public static let directions = ["Top to Bottom", "Bottom to Top", "Bounce"]
    public static let colorMotions = ["Per Bar", "Per Flash", "Cycle Palette"]
    public static let animationParameters: [ParameterSpec] = [
        .init("animation","Animation",0,5,0,choices:animations),
        .init("variation","Speed Variation",0,1,0.65),
        .init("pulseWidth","Flash Width",0.05,1,0.55),
        .init("trail","Trail (bars)",1,16,4),
        .init("direction","Direction",0,2,0,choices:directions),
        .init("colorMotion","Color Motion",0,2,1,choices:colorMotions),
        .init("colorRate","Color Rate",0,2,0.2),
        .init("background","Background",0,1,0.04),
        .init("brightness","Brightness",0,2,1),
        .init("seed","Seed",0,9999,0,step:1)
    ]
    public static let colorModes = ["Palette", "Two-Color Gradient", "Spectral"]
    public static let spectralTypes = ["Pole", "Slit"]
    public static let widthProgressions = ["Logarithmic", "Linear"]
    public static let appearanceParameters: [ParameterSpec] = [
        .init("colorMode","Color Mode",0,2,0,choices:colorModes),
        .init("gradientStart","Top Color",0,16777215,16770457,midi:false),
        .init("gradientEnd","Bottom Color",0,16777215,12525320,midi:false),
        .init("gradientCurve","Gradient Curve",0.2,5,1),
        .init("spectralType","Filter",0,1,0,choices:spectralTypes),
        .init("spectralTop","Top Width · nm",0.1,1880,30),
        .init("spectralBottom","Bottom Width · nm",0.1,1880,940),
        .init("spectralDistribution","Width Progression",0,1,0,choices:widthProgressions),
        .init("spectralSpread","Spectrum Spread",0.1,6.4,3.2),
        .init("spectralShift","Spectrum Position",-3.2,3.2,0)
    ]
    public static var parameters: [ParameterSpec] { NodeKind.shaderEffect.parameters + animationParameters + appearanceParameters }
}

extension Node {
    public var hasBlindsControls: Bool { kind == .shaderEffect && controlStyle == "blinds" }
    public var parameterDefinitions: [ParameterSpec] { if kind == .fieldShader { return fieldParameters ?? [] }; return hasMetallicPoolControls ? MetallicPoolStyle.parameters : kind == .audioPlugin ? (plugin?.parameters.map(\.spec) ?? []) : hasLiquidMetalControls ? LiquidMetalStyle.parameters : hasLiquidChromeControls ? LiquidChromeStyle.parameters : hasFerrofluidControls ? FerrofluidStyle.parameters : hasBlindsControls ? BlindsStyle.parameters : kind.parameters }
    public var modulationDefinitions: [ParameterSpec] {
        if kind == .fieldShader || kind == .audioPlugin || hasLiquidSculptureControls || hasFerrofluidControls || hasMetallicPoolControls { return parameterDefinitions.filter { $0.supportsMIDI && $0.choices == nil } }
        let standard = kind.modulatableParameters.filter { spec in
            guard kind == .mux || kind == .layerMux, spec.key.hasPrefix("level"), let channel = Int(spec.key.dropFirst(5)) else { return true }
            return channel <= channelCount
        }
        return hasBlindsControls ? standard + (BlindsStyle.animationParameters + BlindsStyle.appearanceParameters).filter { $0.choices == nil && !["seed","gradientStart","gradientEnd"].contains($0.key) } : standard
    }
}
