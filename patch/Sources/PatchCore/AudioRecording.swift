import Foundation

/// Record Audio file options. Settings are captured when a take starts;
/// changing them mid-take applies to the next take.
public enum AudioRecording {
    public enum Format: Int, CaseIterable, Sendable {
        case wav, aiff, caf, flac, alac, aac
        public var title: String { ["WAV","AIFF","CAF","FLAC","Apple Lossless (ALAC)","AAC"][rawValue] }
        public var short: String { ["WAV","AIFF","CAF","FLAC","ALAC","AAC"][rawValue] }
        public var lossless: Bool { self != .aac }
        public var pcm: Bool { [.wav,.aiff,.caf].contains(self) }
        /// Integer-only encoders store at most 24 bits; AAC has no bit depth.
        public var depths: [Depth] { pcm ? Depth.allCases : (self == .aac ? [] : [.int16,.int24]) }
        /// AAC is limited to 48 kHz here; lossless formats keep the source rate.
        public var maximumRate: Double { self == .aac ? 48000 : 384000 }
        public func fileExtension(_ depth: Depth) -> String {
            switch self {
            case .wav: return "wav"
            case .aiff: return depth == .float32 ? "aifc" : "aif"
            case .caf: return "caf"
            case .flac: return "flac"
            case .alac, .aac: return "m4a"
            }
        }
    }
    public enum Depth: Int, CaseIterable, Sendable {
        case int16, int24, float32
        public var bits: Int { [16,24,32][rawValue] }
        public var title: String { ["16-bit","24-bit","32-bit float"][rawValue] }
    }
    public enum Channels: Int, CaseIterable, Sendable {
        case stereo, mono, left, right
        public var count: Int { self == .stereo ? 2 : 1 }
        public var title: String { ["Stereo","Mono mix","Left only","Right only"][rawValue] }
    }
    /// 0 keeps the source's native rate, so a hardware input is written bit-exact.
    public static let rates: [Double] = [0,44100,48000,88200,96000,192000]
    public static let bitRates: [Int] = [128_000,192_000,256_000,320_000]
    public static let parameters: [ParameterSpec] = [
        .init("format","Format",0,5,0,choices:Format.allCases.map(\.title),midi:false,step:1),
        .init("bitDepth","Bit depth",0,2,1,choices:Depth.allCases.map(\.title),midi:false,step:1),
        .init("sampleRate","Sample rate",0,5,0,choices:["Source (no resampling)","44.1 kHz","48 kHz","88.2 kHz","96 kHz","192 kHz"],midi:false,step:1),
        .init("channels","Channels",0,3,0,choices:Channels.allCases.map(\.title),midi:false,step:1),
        .init("aacBitRate","AAC bit rate",0,3,2,choices:["128 kbps","192 kbps","256 kbps","320 kbps"],midi:false,step:1),
        .init("gain","Gain (dB)",-24,24,0)
    ]
    /// Resolved options for one take.
    public struct Options: Equatable, Sendable {
        public var format: Format, depth: Depth, rate: Double, channels: Channels, bitRate: Int, gain: Float
        public init(_ node: Node) {
            format = Format(rawValue:Int(node.value("format"))) ?? .wav
            let requested = Depth(rawValue:Int(node.value("bitDepth"))) ?? .int24
            depth = format.depths.contains(requested) ? requested : (format.depths.last ?? .int24)
            rate = AudioRecording.rates[max(0,min(AudioRecording.rates.count-1,Int(node.value("sampleRate"))))]
            channels = Channels(rawValue:Int(node.value("channels"))) ?? .stereo
            bitRate = AudioRecording.bitRates[max(0,min(AudioRecording.bitRates.count-1,Int(node.value("aacBitRate"))))]
            gain = Float(pow(10,node.value("gain")/20))
        }
        /// File rate for a given source rate.
        public func fileRate(source: Double) -> Double { min(format.maximumRate,rate > 0 ? rate : source) }
        public func summary(rate: Double?) -> String {
            let hz = rate.map { String(format:"%g kHz",$0/1000) } ?? (self.rate > 0 ? String(format:"%g kHz",self.rate/1000) : "source rate")
            let quality = format == .aac ? "\(bitRate/1000) kbps" : depth.title
            return "\(format.short) · \(quality) · \(hz) · \(channels.title.lowercased())"
        }
    }
}
