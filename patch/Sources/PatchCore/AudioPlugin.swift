import Foundation

/// Saved plugin identity, opaque processor state, and its native parameter schema.
public struct AudioPluginConfiguration: Codable, Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var manufacturer: String
    public var state: String
    public var parameters: [AudioPluginParameter]
    public init(identifier: String, name: String, manufacturer: String, state: String, parameters: [AudioPluginParameter]) {
        self.identifier=identifier; self.name=name; self.manufacturer=manufacturer; self.state=state; self.parameters=parameters
    }
}
public struct AudioPluginParameter: Codable, Equatable, Sendable {
    public var index: Int
    public var key: String
    public var name: String
    public var initial: Double
    public var steps: Int
    public var choices: [String]
    public var automatable: Bool
    public var unit: String
    public var bipolar: Bool
    public var spec: ParameterSpec {
        let maximum=steps>1 ? Double(steps-1):1
        return .init(key,name,0,maximum,(choices.isEmpty ? initial*maximum:(initial*maximum).rounded()),choices:choices.isEmpty ? nil:choices,midi:automatable,step:steps>1 ? 1:nil)
    }
    public func normalized(_ value: Double) -> Double { min(1,max(0,value/(steps>1 ? Double(steps-1):1))) }
}
