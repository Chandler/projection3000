import Foundation

public struct ParameterSpec: Codable, Equatable, Sendable {
    public let key: String
    public private(set) var title: String
    public let min: Double
    public let max: Double
    public let initial: Double
    public let choices: [String]?
    public let midi: Bool?
    public let step: Double?
    public let unit: String?
    public let scalesFieldTime: Bool?
    public enum ValueKind: String, Codable, Sendable { case continuous, integer, stepped, choice, toggle, color }
    public var valueKind: ValueKind {
        if unit == "sRGB24" { return .color }
        if choices == ["Off","On"] { return .toggle }
        if choices != nil { return .choice }
        if step == 1 { return .integer }
        return step == nil ? .continuous : .stepped
    }
    public func quantized(_ value: Double) -> Double {
        let increment = choices == nil ? step : 1
        let adjusted = increment.flatMap { $0 > 0 ? (value/$0).rounded()*$0 : nil } ?? value
        return Swift.max(min,Swift.min(max,adjusted))
    }
    public func withTitle(_ title: String) -> Self {
        var copy = self
        copy.title = title
        return copy
    }

    /// The Metal animation ABI has fifteen user lanes and a final transport-time lane.
    public static func validateShaderParameters(_ parameters: [Self]) throws {
        guard parameters.filter({ $0.scalesFieldTime == true }).count <= 1 else { throw GraphError("Only one parameter can scale field time") }
        guard parameters.count <= 15, Set(parameters.map(\.key)).count == parameters.count else {
            throw GraphError("A Field Shader supports up to 15 parameters with unique keys")
        }
        for spec in parameters {
            guard !spec.key.isEmpty, spec.key.count <= 96, !spec.title.isEmpty, spec.title.count <= 128,
                  spec.min.isFinite, spec.max.isFinite, spec.min <= spec.max, spec.initial.isFinite,
                  (spec.min...spec.max).contains(spec.initial), spec.step.map({ $0.isFinite && $0 > 0 }) ?? true,
                  (spec.unit?.count ?? 0) <= 32 else { throw GraphError("Invalid field parameter: "+spec.key) }
            if let choices = spec.choices {
                guard !choices.isEmpty, choices.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
                      Set(choices).count == choices.count, spec.min == 0, spec.max == Double(choices.count-1),
                      spec.initial.rounded() == spec.initial else { throw GraphError("Invalid choices for "+spec.key) }
            }
        }
    }

    private enum Metadata: String, CodingKey { case valueKind, supportsMIDI }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy:CodingKeys.self)
        try fields.encode(key,forKey:.key)
        try fields.encode(title,forKey:.title)
        try fields.encode(min,forKey:.min)
        try fields.encode(max,forKey:.max)
        try fields.encode(initial,forKey:.initial)
        try fields.encodeIfPresent(choices,forKey:.choices)
        try fields.encodeIfPresent(midi,forKey:.midi)
        try fields.encodeIfPresent(step,forKey:.step)
        try fields.encodeIfPresent(unit,forKey:.unit)
        try fields.encodeIfPresent(scalesFieldTime,forKey:.scalesFieldTime)
        var metadata = encoder.container(keyedBy:Metadata.self)
        try metadata.encode(valueKind,forKey:.valueKind)
        try metadata.encode(supportsMIDI,forKey:.supportsMIDI)
    }
    public var supportsMIDI: Bool { midi ?? (choices == nil) }
    public init(_ key: String, _ title: String, _ min: Double, _ max: Double, _ initial: Double, choices: [String]? = nil, midi: Bool? = nil, step: Double? = nil, unit: String? = nil, scalesFieldTime: Bool? = nil) {
        self.key = key; self.title = title; self.min = min; self.max = max; self.initial = initial; self.choices = choices; self.midi = midi; self.step = step; self.unit = unit; self.scalesFieldTime = scalesFieldTime
    }
}
