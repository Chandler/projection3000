import Foundation

public enum AnalogChromaStyle {
    public static let encoderParameters: [ParameterSpec] = [
        .init("channel","Output channel",0,1,0,choices:["Left","Right"],midi:false,step:1),
        .init("carrierProfile","Carrier / bandwidth",0,2,2,choices:["2.5 kHz · narrow","5 kHz · medium","10 kHz · wide"],midi:false,step:1),
        .init("format","Color resolution",0,5,1,choices:["16 × 9","24 × 14","32 × 18","48 × 27","8 × 4","16 × 8"],midi:false,step:1),
        .init("fps","Requested color FPS",1,30,15,midi:false,step:1),
        .init("level","Carrier level",0,0.5,0.25)
    ]
    public static let decoderParameters: [ParameterSpec] = [
        .init("decodeMode","Decoding",0,1,0,choices:["Frame lock","Live color (no lock)"],midi:false,step:1),
        .init("returnGain","Live color gain (dB)",-24,60,0),
        .init("scanPhase","Live scan phase (cycles)",0,1,0),
        .init("channel","Return channel",0,1,0,choices:["Left / 1","Right / 2"],midi:false,step:1),
        .init("view","View",0,3,0,choices:["Returned color","Original reference","Color only","Luma only"],midi:false,step:1),
        .init("saturation","Color amount",0,3,1),
        .init("hue","Hue rotation (°)",-180,180,0),
        .init("interpolation","Color upsampling",0,1,1,choices:["Nearest","Bilinear"],midi:false,step:1)
    ]
}

/// Quadrature color carrier with matched bandwidth presets. Both differences share one wire.
/// The frame reference travels digitally; only color and a protected frame ID use audio.
public struct ChromaFormat: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let symbols: Int
    public let carrierHz: Int
    public let symbolRate: Int
    public var samplesPerSymbol: Int { 48000/symbolRate }
    public var fps: Double { Double(symbolRate) / Double(symbols) }
    public var pixels: Int { width * height }
    public init(format: Int = 1, fps: Double = 15,carrierProfile: Int = 2) {
        let sizes = [(16,9),(24,14),(32,18),(48,27),(8,4),(16,8)]
        let profiles=[(2500,1500),(5000,3000),(10000,6000)]
        let profile=profiles[max(0,min(2,carrierProfile))]
        carrierHz=profile.0;symbolRate=profile.1
        let size = sizes[max(0,min(5,format))]
        width = size.0; height = size.1
        symbols = max(width*height+64,Int((Double(symbolRate)/max(1,min(30,fps))).rounded()))
    }
}
