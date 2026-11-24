import Foundation

/// Channel selection happens before gain/pan and preserves the selected level.
public enum AudioChannels {
    public static let parameters: [ParameterSpec] = [
        .init("channelMode", "Channel routing", 0, 6, 0, choices: [
            "Stereo", "Left → both", "Right → both", "Mute left", "Mute right", "Swap left/right", "Mono mix"
        ], midi: true, step: 1)
    ]

    public static func apply(_ samples: inout [Float], mode: Int) {
        guard mode > 0, mode <= 6, samples.count >= 2 else { return }
        for i in stride(from: 0, to: samples.count - 1, by: 2) {
            let left = samples[i], right = samples[i + 1]
            switch mode {
            case 1: samples[i + 1] = left
            case 2: samples[i] = right
            case 3: samples[i] = 0
            case 4: samples[i + 1] = 0
            case 5: samples[i] = right; samples[i + 1] = left
            case 6: samples[i] = (left + right) * 0.5; samples[i + 1] = samples[i]
            default: break
            }
        }
    }
}
