import Foundation

public struct SubpatchPort: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var node: UUID
    public let output: Bool
    public var key: String
    public let type: PortType
}

public struct SubpatchParameter: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var node: UUID
    public var key: String
}

public struct SubpatchInterface: Codable, Equatable, Sendable {
    public var ports: [SubpatchPort]
    public var parameters: [SubpatchParameter]
    public var preview: UUID?
}

public struct SubpatchTemplate: Codable, Sendable {
    public static let currentVersion = 2
    public let version: Int
    public let component: Component
    public let nodes: [Node]
    public let edges: [Edge]
    public let midiMappings: [MIDIMapping]
    /// Reject unsupported fields before an import can discard user data.
    public static func read(_ data: Data) throws -> Self {
        let value = try ProjectCoding.decode(Self.self,from:data)
        guard value.version == currentVersion else { throw GraphError("Unsupported subpatch version \(value.version). Run patch-migrate on older files.") }
        return value
    }

}

extension Graph {
    @discardableResult public mutating func extractSubpatch(_ ids: Set<UUID>, name: String? = nil) throws -> UUID {
        var next = self
        let id: UUID
        if ids.count == 1, let groupID = ids.first, next.component(groupID) != nil { id = groupID }
        else { id = try next.makeComponent(ids) }
        guard let index = next.components?.firstIndex(where:{ $0.id == id }), let group = next.component(id) else { throw GraphError("Missing component") }
        if group.interface == nil {
            var ports: [SubpatchPort] = []
            let members = Set(group.members)
            for output in [false,true] {
                for port in next.ports(group,output:output) {
                    guard let node = next.node(port.node) else { continue }
                    let key = node.ports(output:output)[port.input].id
                    ports.append(.init(id:UUID(),name:port.name,node:port.node,output:output,key:key,type:port.type))
                }
            }
            // A control output may feed both an internal cable and an external modulation.
            for target in nodes where !members.contains(target.id) {
                for binding in (target.modulations ?? [:]).values where members.contains(binding.source) {
                    guard let source = next.node(binding.source) else { continue }
                    let key = source.ports(output:true)[binding.outputIndex].id
                    if !ports.contains(where:{ $0.output && $0.node == source.id && $0.key == key }) {
                        ports.append(.init(id:UUID(),name:source.name+" · "+key,node:source.id,output:true,key:key,type:.control))
                    }
                }
            }
            let parameters = group.members.compactMap(next.node).flatMap { node in
                (node.modulations ?? [:]).keys.sorted().compactMap { key -> SubpatchParameter? in
                    guard let binding = node.modulations?[key], !members.contains(binding.source), let spec = node.modulationDefinitions.first(where:{ $0.key == key }) else { return nil }
                    return .init(id:UUID(),name:spec.title,node:node.id,key:key)
                }
            }
            let preview = next.previewNode(id)?.id
            next.components![index].interface = .init(ports:ports,parameters:parameters,preview:preview)
            if group.name == "Component" { next.components![index].name = "Subpatch" }
        }
        if let name { next.components![index].name = name }
        self = try next.validated()
        return id
    }

    public func resolveSubpatchPort(_ group: Component, id: UUID, output: Bool) throws -> (node: UUID, index: Int) {
        guard let port = group.interface?.ports.first(where:{ $0.id == id && $0.output == output }),
              group.members.contains(port.node), let member = node(port.node),
              let spec = member.ports(output:output).first(where:{ $0.id == port.key && $0.type == port.type }),
              output || member.inputs.indices.contains(spec.index) else { throw GraphError("Unresolved subpatch port") }
        return (member.id,spec.index)
    }

    public mutating func editInterface(_ id: UUID, _ edit: (inout SubpatchInterface) throws -> Void) throws {
        guard let i = components?.firstIndex(where:{ $0.id == id }), var interface = components?[i].interface else { throw GraphError("Unknown subpatch") }
        try edit(&interface)
        var next = self
        let old = groups[i]
        next.components![i].interface = interface
        let updated = next.groups[i], members = Set(old.members)
        for prior in old.interface!.ports {
            guard let replacement = interface.ports.first(where:{ $0.id == prior.id }),
                  replacement.node != prior.node || replacement.key != prior.key else { continue }
            guard prior.output == replacement.output, prior.type == replacement.type else { throw GraphError("Reassigned ports must keep direction and type") }
            let from = try resolveSubpatchPort(old,id:prior.id,output:prior.output)
            let to = try next.resolveSubpatchPort(updated,id:prior.id,output:prior.output)
            for (index,edge) in edges.enumerated() {
                if prior.output && edge.source == from.node && edge.outputIndex == from.index && !members.contains(edge.target) {
                    next.edges[index].source = to.node; next.edges[index].output = to.index; next.edges[index].outputID = replacement.key
                } else if !prior.output && edge.target == from.node && edge.input == from.index && !members.contains(edge.source) {
                    next.edges[index].target = to.node; next.edges[index].input = to.index; next.edges[index].inputID = replacement.key
                }
            }
            for (index,target) in nodes.enumerated() where prior.output && !members.contains(target.id) {
                for (key,binding) in target.modulations ?? [:] where binding.source == from.node && binding.outputIndex == from.index {
                    next.nodes[index].modulations?[key]?.source = to.node
                    next.nodes[index].modulations?[key]?.output = to.index
                    next.nodes[index].modulations?[key]?.outputID = replacement.key
                }
            }
        }
        for prior in old.interface!.parameters {
            guard let replacement = interface.parameters.first(where:{ $0.id == prior.id }),
                  replacement.node != prior.node || replacement.key != prior.key,
                  let original = node(prior.node)?.modulations?[prior.key], !members.contains(original.source) else { continue }
            guard let before = next.nodes.firstIndex(where:{ $0.id == prior.node }),
                  let after = next.nodes.firstIndex(where:{ $0.id == replacement.node }),
                  next.nodes[after].modulations?[replacement.key] == nil else { throw GraphError("The new control already has a driver") }
            next.nodes[before].modulations?.removeValue(forKey:prior.key)
            var bindings = next.nodes[after].modulations ?? [:]
            bindings[replacement.key] = original
            next.nodes[after].modulations = bindings
        }
        self = try next.validated()
    }

    public mutating func exposePort(_ id: UUID,node member: UUID,key: String,output: Bool,name: String) throws {
        guard let node = node(member),let spec = node.ports(output:output).first(where:{ $0.id == key }),
              output || node.inputs.indices.contains(spec.index) else { throw GraphError("Unknown member port") }
        try editInterface(id) { $0.ports.append(.init(id:UUID(),name:name,node:member,output:output,key:key,type:spec.type)) }
    }

    public mutating func exposeParameter(_ id: UUID,node member: UUID,key: String,name: String) throws {
        try editInterface(id) { $0.parameters.append(.init(id:UUID(),name:name,node:member,key:key)) }
    }

    public func validateInterface(_ group: Component) throws {
        guard let interface = group.interface else { return }
        let members = Set(group.members)
        guard interface.preview.map(members.contains) ?? true else { throw GraphError("Subpatch preview must be a member") }
        var ids = Set<UUID>(), addresses = Set<String>()
        for port in interface.ports {
            guard ids.insert(port.id).inserted, addresses.insert("\(port.node):\(port.output):\(port.key)").inserted,
                  !port.name.isEmpty,port.name.count <= 128 else { throw GraphError("Duplicate or unnamed subpatch port") }
            _ = try resolveSubpatchPort(group,id:port.id,output:port.output)
        }
        for parameter in interface.parameters {
            guard ids.insert(parameter.id).inserted, addresses.insert("\(parameter.node):parameter:\(parameter.key)").inserted,
                  !parameter.name.isEmpty,parameter.name.count <= 128,members.contains(parameter.node),
                  node(parameter.node)?.parameterDefinitions.contains(where:{ $0.key == parameter.key }) == true else { throw GraphError("Invalid subpatch parameter") }
        }
        for edge in edges where members.contains(edge.source) != members.contains(edge.target) {
            let output = members.contains(edge.source), member = output ? edge.source : edge.target
            guard let endpoint = node(member) else { throw GraphError("Missing subpatch member") }
            let keys = endpoint.ports(output:output).map(\.id), index = output ? edge.outputIndex : edge.input
            guard keys.indices.contains(index), addresses.contains("\(member):\(output):\(keys[index])") else { throw GraphError("Expose the member port before connecting outside the subpatch") }
        }
        for target in nodes {
            for (key,binding) in target.modulations ?? [:] where members.contains(binding.source) != members.contains(target.id) {
                if members.contains(target.id) {
                    guard addresses.contains("\(target.id):parameter:\(key)") else { throw GraphError("Expose the driven control before connecting outside the subpatch") }
                } else {
                    guard let source = node(binding.source), let output = source.ports(output:true).first(where:{ $0.index == binding.outputIndex }),
                          addresses.contains("\(source.id):true:\(output.id)") else { throw GraphError("Expose the control output before connecting outside the subpatch") }
                }
            }
        }
    }

    public func subpatchTemplate(_ id: UUID) throws -> SubpatchTemplate {
        guard let group = component(id),group.interface != nil else { throw GraphError("Unknown subpatch") }
        let members = Set(group.members)
        let locals = nodes.filter { members.contains($0.id) }.map { original -> Node in
            var copy = original
            copy.modulations = original.modulations?.filter { members.contains($0.value.source) }
            return copy
        }
        return .init(version:SubpatchTemplate.currentVersion,component:group,nodes:locals,edges:edges.filter { members.contains($0.source) && members.contains($0.target) },midiMappings:(midiMappings ?? []).filter { members.contains($0.node) })
    }

    @discardableResult public mutating func instantiate(_ template: SubpatchTemplate, at origin: Position, includeMIDI: Bool, enableOutputs: Bool = false) throws -> UUID {
        let old = template.component
        let members = Set(old.members)
        guard template.version == SubpatchTemplate.currentVersion,old.interface != nil,!members.isEmpty,members.count == old.members.count,
              template.nodes.count == members.count, Set(template.nodes.map(\.id)) == members else { throw GraphError("Invalid subpatch template or unsupported version") }
        let mapping = Dictionary(uniqueKeysWithValues:members.map { ($0,UUID()) })
        func remap(_ id: UUID) throws -> UUID {
            guard let mapped = mapping[id] else { throw GraphError("Subpatch contains an unresolved external reference") }
            return mapped
        }
        var next = self
        for var member in template.nodes {
            member.id = try remap(member.id)
            member.position = .init(origin.x+member.position.x-old.position.x,origin.y+member.position.y-old.position.y)
            member.modulations = try member.modulations?.mapValues { original in
                var binding = original
                binding.source = try remap(original.source)
                binding.outputID = original.outputID
                return binding
            }
            if !enableOutputs {
                if member.kind == .apc40 { throw GraphError("Activate devices and outputs to reserve the APC40 controller") }
                if member.kind.isOutput || [.audioInput,.microphone,.webcam,.midiIn,.ndiIn,.liveStream].contains(member.kind) { member.enabled = false }
                if [.mux,.layerMux].contains(member.kind) { member.parameters["followAPC"] = 0 }
                for (key,type) in zip(member.publishablePortIDs,member.publishableTypes) where [.video,.collection,.trace,.palette,.control].contains(type) {
                    var publication = member.publications?[key] ?? OutputPublication()
                    guard publication.mode == "on" || publication.mode == "auto" && member.publishesAutomatically else { continue }
                    publication.mode = "off"
                    var publications = member.publications ?? [:]
                    publications[key] = publication
                    member.publications = publications
                }
            }
            next.nodes.append(member)
        }
        for var edge in template.edges {
            edge.id = UUID(); edge.source = try remap(edge.source); edge.target = try remap(edge.target)
            next.edges.append(edge)
        }
        var group = old
        group.id = UUID(); group.members = try old.members.map(remap); group.position = origin
        var interface = old.interface!
        interface.preview = try interface.preview.map(remap)
        for i in interface.ports.indices { interface.ports[i].node = try remap(interface.ports[i].node) }
        for i in interface.parameters.indices { interface.parameters[i].node = try remap(interface.parameters[i].node) }
        group.interface = interface
        next.components = next.groups + [group]
        for var binding in template.midiMappings {
            binding.node = try remap(binding.node)
            if includeMIDI {
                binding.id = UUID()
                next.midiMappings = (next.midiMappings ?? []) + [binding]
            }
        }
        self = try next.validated()
        return group.id
    }
}
