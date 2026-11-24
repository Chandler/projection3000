import Foundation

public enum AudioEQStyle {
    public static let parameters: [ParameterSpec] = AudioChannels.parameters + [
        .init("bass", "Bass (dB)", -18, 18, 0),
        .init("mid", "Mid (dB)", -18, 18, 0),
        .init("treble", "Treble (dB)", -18, 18, 0),
        .init("balance", "Balance (−1 left, +1 right)", -1, 1, 0),
        .init("leftGain", "Left trim (dB)", -60, 12, 0),
        .init("rightGain", "Right trim (dB)", -60, 12, 0),
        .init("gain", "Output gain (dB)", -60, 12, 0),
        .init("muteLeft", "Mute left output", 0, 1, 0, choices: ["Off", "On"], midi: true, step: 1),
        .init("muteRight", "Mute right output", 0, 1, 0, choices: ["Off", "On"], midi: true, step: 1)
    ]
}

/// Complementary, gentle three-band tone controls. The bands sum to the
/// original signal at zero dB. Each channel has independent filter memory.
public struct AudioEQProcessor {
    private var low = SIMD2<Double>.zero
    private var highLow = SIMD2<Double>.zero
    private var levels: [Double]?
    public init() {}

    public mutating func process(_ input: [Float], node: Node, sampleRate: Double) -> [Float] {
        guard sampleRate > 0 else { return input }
        var output = input
        AudioChannels.apply(&output, mode: Int(node.value("channelMode")))
        let balance = node.value("balance")
        let target = ["bass", "mid", "treble"].map { pow(10, node.value($0) / 20) } + [
            node.value("muteLeft") > 0.5 ? 0 : pow(10, (node.value("gain") + node.value("leftGain")) / 20) * (1 - max(0, balance)),
            node.value("muteRight") > 0.5 ? 0 : pow(10, (node.value("gain") + node.value("rightGain")) / 20) * (1 + min(0, balance))
        ]
        var gains = levels ?? target
        let bassAlpha = 1 - exp(-2 * Double.pi * 200 / sampleRate)
        let trebleAlpha = 1 - exp(-2 * Double.pi * 4000 / sampleRate)
        let smoothing = 1 - exp(-1 / (0.01 * sampleRate))
        guard output.count >= 2 else { return output }
        for i in stride(from: 0, to: output.count - 1, by: 2) {
            for j in gains.indices { gains[j] += (target[j] - gains[j]) * smoothing }
            for channel in 0..<2 {
                let x = Double(output[i + channel])
                low[channel] += bassAlpha * (x - low[channel])
                highLow[channel] += trebleAlpha * (x - highLow[channel])
                let value = low[channel] * gains[0] + (highLow[channel] - low[channel]) * gains[1] + (x - highLow[channel]) * gains[2]
                output[i + channel] = Float(value * gains[channel + 3])
            }
        }
        levels = gains
        return output
    }
}
