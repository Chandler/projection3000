import Foundation

/// APC40 mkII, in Akai's generic (absolute knob) mode. Port indices are stable.
public enum APC40 {
    public static let outputs = (1...8).map { "Fader \($0)" }
        + (1...8).map { "Track knob \($0)" }
        + (1...8).map { "Device knob \($0)" }
        + ["Master", "Crossfader"]
        + (1...8).map { "Activator \($0)" }
    public static func output(status: Int, number: Int) -> Int? {
        let channel = status & 15, kind = status & 0xf0
        if kind == 0xb0 {
            if channel < 8 && number == 7 { return channel }
            if channel == 0 {
                if (48...55).contains(number) { return 8 + number - 48 }
                if (16...23).contains(number) { return 16 + number - 16 }
                if number == 14 { return 24 }
                if number == 15 { return 25 }
            }
        }
        if (kind == 0x90 || kind == 0x80) && channel < 8 && number == 50 { return 26 + channel }
        return nil
    }
}
