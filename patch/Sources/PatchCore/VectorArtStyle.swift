import Foundation

public enum VectorArtStyle {
  public static func parameters(_ kind: NodeKind) -> [ParameterSpec] {
    switch kind {
    case .vectorCube:
      return [
        .init("speed", "Master speed", 0.0, 4.0, 1.0),
        .init("rotate_x", "X rotation", -4.0, 4.0, 0.0),
        .init("rotate_y", "Y rotation", -4.0, 4.0, 1.0),
        .init("rotate_z", "Z rotation", -4.0, 4.0, 0.0),
        .init("pose_x", "X angle", -180.0, 180.0, 0.0),
        .init("pose_y", "Y angle", -180.0, 180.0, 0.0),
        .init("pose_z", "Z angle", -180.0, 180.0, 0.0),
        .init("projection", "View", 0, 1, 0, choices: ["orthographic", "perspective"], step: 1),
        .init("size", "Size", 0.2, 2.0, 1.0),
        .init("glow", "Glow color", 0, 16_777_215, 7_913_215, midi: false, step: 1, unit: "sRGB24"),
        .init("line_width", "Core width", 0.5, 16.0, 4.0),
        .init("glow_width", "Glow radius", 0.0, 60.0, 18.0, step: 1),
      ]
    case .laserLettering:
      return [
        .init(
          "font", "Font", 0, 9, 1,
          choices: [
            "Archivo Black", "Bebas Neue", "Bungee", "DM Serif Display", "Lobster", "Pacifico",
            "Permanent Marker", "Special Elite", "Monoton", "Press Start 2P",
          ], step: 1),
        .init(
          "color", "Laser color", 0, 16_777_215, 2_162_560, midi: false, step: 1, unit: "sRGB24"),
        .init("line_width", "Core width", 0.5, 8.0, 1.5),
        .init("glow_width", "Glow radius", 0.0, 60.0, 14.0, step: 1),
        .init("brightness", "Brightness", 0.0, 2.0, 1.0),
        .init("size", "Size", 0.02, 0.9, 0.3),
        .init("x", "X", 0.0, 1.0, 0.5),
        .init("y", "Y", 0.0, 1.0, 0.5),
        .init("pulse", "Pulse", 0.0, 1.0, 0.0),
        .init("speed", "Pulse speed", 0.0, 8.0, 1.0),
      ]
    case .lightningCellGrid:
      return [
        .init("rate", "Pulse rate", 0.0, 8.0, 0.8),
        .init("burst", "Burstiness", 0.0, 1.0, 0.45),
        .init("speed", "Speed", 0.05, 3.0, 0.55),
        .init("jitter", "Speed jitter", 0.0, 1.0, 0.35),
        .init("length", "Pulse length", 0.01, 0.35, 0.08),
        .init("tail", "Afterglow", 0.0, 1.0, 0.62),
        .init("crackle", "Crackle", 0.0, 1.0, 0.38),
        .init("forks", "Forks", 0.0, 1.0, 0.32),
        .init("top_spray", "Top spray", 0.0, 1.0, 0.45),
        .init("brightness", "Brightness", 0.0, 1.5, 1.0),
        .init("core", "Core", 0, 16_777_215, 16_317_439, midi: false, step: 1, unit: "sRGB24"),
        .init("glow", "Glow", 0, 16_777_215, 4_434_431, midi: false, step: 1, unit: "sRGB24"),
        .init("rainbow", "Ion color", 0.0, 1.0, 0.0),
        .init("origin", "From", 0, 1, 0, choices: ["start", "end"], step: 1),
      ]
    case .vectorScanLines:
      return [
        .init(
          "tint", "Core color", 0, 16_777_215, 14_219_519, midi: false, step: 1, unit: "sRGB24"),
        .init("glow", "Glow color", 0, 16_777_215, 3_528_959, midi: false, step: 1, unit: "sRGB24"),
        .init("rate", "Rate", -800.0, 800.0, 110.0, step: 1),
        .init("angle", "Angle", -180.0, 180.0, 0.0, step: 1),
        .init("spacing", "Spacing", 8.0, 600.0, 110.0, step: 1),
        .init("width", "Core width", 0.5, 80.0, 4.0),
        .init("blur", "Glow radius", 0.0, 160.0, 14.0, step: 1),
        .init("amount", "Brightness", 0.0, 2.0, 0.85),
        .init("wave", "Wave amount", 0.0, 120.0, 0.0, step: 1),
        .init("wave_frequency", "Wave frequency", 0.1, 8.0, 1.5),
        .init("pulse", "Beat pulse", 0.0, 1.0, 0.0),
        .init("tempo", "Pulse tempo", 20, 300, 120, unit: "BPM"),
      ]
    case .vectorLorenz:
      return [
        .init("speed", "Speed", -2.0, 2.0, 0.5),
        .init("length", "Length", 0.02, 1.0, 0.22),
        .init("zoom", "Zoom", 0.3, 1.6, 0.9),
        .init("rotation", "Rotation speed", 0.0, 0.8, 0.08),
        .init("tilt", "Camera tilt", -70.0, 70.0, 18.0, step: 1),
        .init("line_width", "Line width", 0.5, 8.0, 2.0),
        .init("brightness", "Brightness", 0.0, 1.5, 1.0),
        .init("color", "Color", 0, 16_777_215, 5_630_719, midi: false, step: 1, unit: "sRGB24"),
        .init("seed", "Orbit seed", 0.0, 999.0, 7.0, step: 1),
        .init(
          "rotation_direction", "Rotation direction", 0, 1, 0, choices: ["forward", "reverse"],
          step: 1),
      ]
    case .slimeMold:
      return [
        .init("density", "Density", 80, 580, 320, step: 1),
        .init("branching", "Radial growth", 0, 1, 0.25),
        .init("x", "Origin X", 0, 1, 0.5),
        .init("y", "Origin Y", 0, 1, 0.5),
        .init("line_width", "Line width", 0.5, 5, 1),
        .init("pulse", "Pulse amount", 0, 1, 0),
        .init("speed", "Pulse speed", 0, 1, 0.2),
        .init("pulse_length", "Pulse length", 0.01, 0.3, 0.08),
        .init("color", "Color", 0, 16_777_215, 12_058_564, midi: false, step: 1, unit: "sRGB24"),
        .init("seed", "Seed", 0, 999999, 1, step: 1),
      ]
    default: return []
    }
  }
}

extension NodeKind {
  public var vectorArtModule: String? {
    switch self {
    case .vectorCube: return "vector-cube"
    case .laserLettering: return "laser-text"
    case .lightningCellGrid: return "electric-strips"
    case .vectorScanLines: return "vector-scan-lines"
    case .vectorLorenz: return "lorenz-attractor"
    case .slimeMold: return "slime-mold"
    default: return nil
    }
  }
}
