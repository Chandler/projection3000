import Foundation

public struct MIDIMapping: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var node: UUID
    public var key: String
    public var device: String
    public var channel: Int
    public var cc: Int
    public var minimum: Double
    public var maximum: Double
    public var inverted: Bool
    public var pickup: Bool
    public var enabled: Bool
    public init(node: UUID,key: String,device: String,channel: Int,cc: Int,minimum: Double,maximum: Double,inverted: Bool = false,pickup: Bool = true) {
        id = UUID(); self.node = node; self.key = key; self.device = device; self.channel = channel; self.cc = cc
        self.minimum = minimum; self.maximum = maximum; self.inverted = inverted; self.pickup = pickup; enabled = true
    }
    public func value(_ raw: Int,spec: ParameterSpec) -> Double {
        let fraction = Double(Swift.max(0,Swift.min(127,raw)))/127
        let value = minimum+(maximum-minimum)*(inverted ? 1-fraction : fraction)
        let quantized = spec.step.map { $0 > 0 ? (value/$0).rounded()*$0 : value } ?? value
        return Swift.min(spec.max,Swift.max(spec.min,quantized))
    }
}

extension Node {
    /// MIDI uses the same stored keys as UI/API. Blinds' legacy p1 stores count/10.
    public var midiParameters: [ParameterSpec] {
        if hasBlindsControls {
            return [ParameterSpec("p1","Bar Count",0.1,10,3.8,step:0.1),
                    ParameterSpec("p3","Gap Size",0,0.95,0.15),ParameterSpec("p4","Vertical Offset",-0.5,0.5,0)]
                + parameterDefinitions.filter { !["p1","p2","p3","p4"].contains($0.key) && $0.supportsMIDI }
        }
        return parameterDefinitions.filter(\.supportsMIDI)
    }
}
extension Graph {
    public func validateMIDIMappings() throws {
        var ids = Set<UUID>(), hardware = Set<String>(), targets = Set<String>()
        for binding in midiMappings ?? [] {
            guard ids.insert(binding.id).inserted,
                  hardware.insert("\(binding.device):\(binding.channel):\(binding.cc)").inserted,
                  targets.insert("\(binding.node):\(binding.key)").inserted,
                  !binding.device.isEmpty, binding.device.count < 256, !binding.key.isEmpty, binding.key.count < 128,
                  (0...15).contains(binding.channel), (0...127).contains(binding.cc),
                  !(binding.device == "apc40mkII" && binding.channel == 0 && binding.cc == 15),
                  binding.minimum.isFinite, binding.maximum.isFinite, binding.minimum <= binding.maximum else { throw GraphError("Invalid MIDI mapping") }
            if let spec = node(binding.node)?.midiParameters.first(where:{ $0.key == binding.key }) {
                guard binding.minimum >= spec.min, binding.maximum <= spec.max else { throw GraphError("MIDI range outside parameter bounds") }
            }
        }
    }
    public mutating func bindMIDI(_ binding: MIDIMapping) throws {
        guard let node = node(binding.node),node.midiParameters.contains(where:{ $0.key == binding.key }) else { throw GraphError("Parameter is not MIDI assignable") }
        var next = self
        next.midiMappings = (midiMappings ?? []).filter {
            $0.id != binding.id && !($0.node == binding.node && $0.key == binding.key) &&
            !($0.device == binding.device && $0.channel == binding.channel && $0.cc == binding.cc)
        } + [binding]
        try next.validateMIDIMappings()
        if let index = next.nodes.firstIndex(where:{ $0.id == binding.node }) { next.nodes[index].modulations?.removeValue(forKey:binding.key) }
        self = next
    }
}
