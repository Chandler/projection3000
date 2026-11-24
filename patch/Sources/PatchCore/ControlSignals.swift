import Foundation

public struct ParameterModulation: Codable, Equatable, Sendable {
    public var source: UUID
    public var output: Int?
    public var outputIndex: Int { output ?? 0 }
    public var minimum: Double
    public var maximum: Double
    public var enabled: Bool
    public init(source: UUID,minimum: Double,maximum: Double,enabled: Bool = true,output: Int = 0) {
        self.output = output == 0 ? nil : output
        self.source = source; self.minimum = minimum; self.maximum = maximum; self.enabled = enabled
    }
}
public enum ControlSignal {
    private static func random(_ index: Int64,_ seed: UInt64) -> Double {
        var x = UInt64(bitPattern:index) &+ seed &* 0x9e3779b97f4a7c15
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        x ^= x >> 31
        return Double(x >> 11) / 9007199254740992.0
    }
    public static func value(_ node: Node,time: Double) -> Double {
        let phase = time*node.value("rate") + node.value("phase")
        var value: Double
        if node.kind == .lfo {
            let p = phase-floor(phase)
            switch Int(node.value("shape")) {
            case 1: value = 1-abs(p*2-1)
            case 2: value = p
            case 3: value = p < node.value("width") ? 1 : 0
            default: value = 0.5+0.5*sin(phase*2*Double.pi)
            }
        } else {
            let count = max(1,min(6,Int(node.value("octaves").rounded())))
            var sum = 0.0, weightSum = 0.0, weight = 1.0
            for octave in 0..<count {
                let p = phase*pow(2,Double(octave)), index = Int64(floor(p)), f = p-floor(p)
                let seed = UInt64(node.value("seed").rounded()) &+ UInt64(octave)*7919
                let a = random(index,seed), b = random(index+1,seed)
                let t = node.value("style") > 0.5 ? 0 : f*f*f*(f*(f*6-15)+10)
                sum += (a+(b-a)*t)*weight; weightSum += weight; weight *= node.value("roughness")
            }
            value = sum/max(1e-9,weightSum)
        }
        return min(1,max(0,node.value("offset")+(value-0.5)*node.value("amplitude")))
    }
}
extension NodeKind {
    public var modulatableParameters: [ParameterSpec] {
        if self == .arpeggiator || self == .midiOut { return [] }
        if self == .lightningPulses { return parameters.filter { $0.supportsMIDI && $0.choices == nil } }
        if self == .vectorText { return parameters.filter { ["rotation","spin"].contains($0.key) } }
        if self == .text || self == .lorenz || self == .projector { return [] }
        if self == .videoPalette { return parameters.filter { $0.supportsMIDI && $0.choices == nil } }
        if self == .meshGradient { return parameters.filter { $0.supportsMIDI && $0.choices == nil } }
        let structural: Set<String> = ["channels","channelX","channelY","previewFaces","start","end","seek","seed","columns","rows","octaves","dpi","cell","highlightColor","midtoneColor","shadowColor","backgroundColor"]
        let dimensions: Set<String> = self == .crop ? ["width","height","ratioWidth","ratioHeight","outputWidth","outputHeight"] : []
        return parameters.filter { $0.choices == nil && !structural.contains($0.key) && !dimensions.contains($0.key) }
    }
}
extension Graph {
    public var dependencies: [(source: UUID,target: UUID)] {
        edges.map { ($0.source,$0.target) } + nodes.flatMap { node in (node.modulations ?? [:]).values.map { ($0.source,node.id) } }
    }
    public mutating func modulate(_ target: UUID,key: String,source: UUID,minimum: Double? = nil,maximum: Double? = nil,enabled: Bool = true,output: Int = 0) throws {
        guard let index = nodes.firstIndex(where:{ $0.id == target }),node(source)?.kind.outputType(at:output) == .control,
              let spec = nodes[index].modulationDefinitions.first(where:{ $0.key == key }) else { throw GraphError("Choose a control source and a continuous parameter") }
        var next = self
        if next.nodes[index].modulations == nil { next.nodes[index].modulations = [:] }
        next.nodes[index].modulations![key] = .init(source:source,minimum:minimum ?? spec.min,maximum:maximum ?? spec.max,enabled:enabled,output:output)
        self = try next.validated()
    }
}
