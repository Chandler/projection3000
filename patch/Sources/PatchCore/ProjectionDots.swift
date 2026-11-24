import Foundation

public enum ProjectionDotsStyle {
    public static var parameters: [ParameterSpec] { [
        .init("sheetWidth", "Paper width · mm", 10, 2000, 594),
        .init("sheetHeight", "Paper height · mm", 10, 2000, 420),
        .init("diameter", "Dot diameter · mm", 0.1, 100, 25.4),
        .init("gap", "Gap · mm", 0, 100, 2.5),
        .init("softness", "Edge softness · pixels", 0, 8, 0.5)
    ] }

    // Compatibility is confined to file migration and the existing shader ABI.
    public static let legacyKeys: Set<String> = ["columns", "rows", "layout", "gapX", "gapY",
        "marginX", "marginY", "x", "y", "rotation", "scale", "stretchX", "stretchY", "flipX", "flipY"]

    public static func migrate(_ node: Node) -> Node {
        var result = node
        if result.parameters["gap"] == nil {
            let x = result.parameters["gapX"] ?? 2.5, y = result.parameters["gapY"] ?? x
            result.parameters["gap"] = (x+y)/2
        }
        result.parameters = result.parameters.filter { !legacyKeys.contains($0.key) }
        result.modulations = result.modulations?.filter { !legacyKeys.contains($0.key) }
        return result
    }

    public static func grid(_ node: Node) -> (columns: Int, rows: Int) {
        let diameter = node.value("diameter"), gap = node.value("gap")
        func count(_ length: Double) -> Int {
            max(0, Int(floor((length+gap)/max(0.1,diameter+gap)+1e-9)))
        }
        return (count(node.value("sheetWidth")),count(node.value("sheetHeight")))
    }

    public static func outputDimensions(_ node: Node, canvas: VideoDimensions) -> VideoDimensions {
        let width = node.value("sheetWidth"), height = node.value("sheetHeight")
        let scale = Double(max(canvas.width,canvas.height))/max(width,height)
        func even(_ length: Double) -> Int { max(2,Int((length*scale/2).rounded())*2) }
        return VideoDimensions(even(width),even(height))
    }

    public static func shaderValues(_ node: Node) -> [Float] {
        let count = grid(node)
        return [Float(count.columns),Float(count.rows),Float(node.value("diameter")),Float(node.value("gap")),
            Float(node.value("sheetWidth")),Float(node.value("sheetHeight")),Float(node.value("softness")),0]
    }
}

public enum DotColorsStyle {
    public static var parameters: [ParameterSpec] { [
        .init("pattern", "Color pattern", 0, 7, 0, choices:["Pole ribbons", "Slit ribbons", "Rainbow columns", "Rainbow rows", "White", "Solid color", "Checkerboard", "Alignment"]),
        .init("brightness", "Brightness", 0, 1, 1),
        .init("hue", "Hue", 0, 1, 0.6),
        .init("saturation", "Saturation", 0, 1, 1),
        .init("poleTop", "Top pole width · mm", 0.01, 54, 0.84375),
        .init("poleBottom", "Bottom pole width · mm", 0.01, 54, 27),
        .init("extent", "Spectrum spread", 0.1, 6.4, 3.2),
        .init("spectralShift", "Spectrum position", -3.2, 3.2, 0),
        .init("distribution", "Width progression", 0, 1, 0, choices:["Logarithmic", "Linear"]),
        .init("phase", "Color phase", 0, 1, 0),
        .init("speed", "Color motion · cycles/s", -2, 2, 0)
    ] }
}

public enum FlipDotsStyle {
    public static var parameters: [ParameterSpec] { [
        .init("hold", "Hold · seconds", 0.1, 20, 2),
        .init("flip", "Flip · seconds", 0.03, 2, 0.35),
        .init("sweep", "Sweep · seconds", 0, 4, 0.6),
        .init("jitter", "Timing scatter", 0, 1, 0.25),
        .init("hue", "Hue", 0, 1, 0.12),
        .init("saturation", "Saturation", 0, 1, 0),
        .init("brightness", "Brightness", 0, 1, 1),
        .init("offLevel", "Unlit dots", 0, 0.3, 0.025),
        .init("direction", "Sweep direction", 0, 3, 0, choices:["Left to right","Right to left","Top to bottom","Random"])
    ] }
    // Eight messages, 48 ASCII characters each. Buffer stays below Metal's 4 KiB inline limit.
    public static func textBuffer(_ node: Node) -> [UInt32] {
        let lines = (node.text ?? "HELLO\nWORLD\nPATCH").uppercased().split(separator:"\n",omittingEmptySubsequences:false).prefix(8)
        var values = [UInt32](repeating:0,count:393)
        values[0] = UInt32(lines.count)
        for (i,line) in lines.enumerated() {
            let codes = line.unicodeScalars.prefix(48).map { $0.value < 128 ? $0.value : 63 }
            values[1+i] = UInt32(codes.count)
            for (j,code) in codes.enumerated() { values[9+i*48+j] = code }
        }
        return values
    }
}

extension Graph {
    /// A source preview borrows its first connected paper. Each consumer still
    /// evaluates the pattern with its own grid, so sharing sources is supported.
    public func dotPreviewGeometry(_ source: UUID) -> Node {
        edges.filter { $0.source == source }.compactMap { node($0.target) }.first { $0.kind == .projectionDots }
            ?? Node(kind:.projectionDots)
    }
}
