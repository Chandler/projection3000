import Foundation
import PatchCore

struct ConnectionOption: Encodable {
    let name: String
    let portID: String?
    let index: Int?
    let parameter: String?
}

extension CatalogNode {
    func connectionOptions(for type: PortType, fromOutput: Bool) -> [ConnectionOption] {
        var instance = Node(kind:kind)
        instance.fieldParameters = fieldParameters
        instance.controlStyle = controlStyle
        instance.file = file?.path
        var options = instance.ports(output:!fromOutput).compactMap { port -> ConnectionOption? in
            guard fromOutput ? port.type.accepts(type) : type.accepts(port.type) else { return nil }
            return ConnectionOption(name:port.name,portID:port.id,index:port.index,parameter:nil)
        }
        if fromOutput && type == .control {
            options += instance.modulationSpecs.map {
                ConnectionOption(name:$0.title,portID:nil,index:nil,parameter:$0.key)
            }
        }
        return options
    }
}

extension ControlAPI {
    func portRoute(_ method: String, _ path: String, _ data: Data) throws -> [String:Any]? {
        if method == "GET", path.hasPrefix("/v1/nodes/"), path.hasSuffix("/ports") {
            let parts = path.split(separator:"/")
            guard parts.count == 4, let id = UUID(uuidString:String(parts[2])) else { throw GraphError("Unknown node") }
            if let group = workspace.graph.component(id), let interface = group.interface {
                let encoder = JSONEncoder()
                let members = Set(group.members)
                let edges = workspace.graph.edges.filter { members.contains($0.source) != members.contains($0.target) }
                return ["node":id.uuidString,
                        "inputs":try JSONSerialization.jsonObject(with:encoder.encode(interface.ports.filter { !$0.output })),
                        "outputs":try JSONSerialization.jsonObject(with:encoder.encode(interface.ports.filter(\.output))),
                        "parameters":try JSONSerialization.jsonObject(with:encoder.encode(interface.parameters)),
                        "edges":try JSONSerialization.jsonObject(with:encoder.encode(edges)), "graphRevision":revision()]
            }
            guard let node = workspace.graph.node(id) else { throw GraphError("Unknown node") }
            var observations: [String:[String:Any]] = [:]
            for port in node.ports(output:true) {
                observations[port.id] = renderer.observation(of:node,output:port.index,graph:workspace.graph)?.fields
            }
            let edges = workspace.graph.edges.filter { $0.source == id || $0.target == id }
            let encoder = JSONEncoder()
            return ["node":id.uuidString,"inputs":try JSONSerialization.jsonObject(with:encoder.encode(node.ports(output:false))),
                    "outputs":try JSONSerialization.jsonObject(with:encoder.encode(node.ports(output:true))),
                    "edges":try JSONSerialization.jsonObject(with:encoder.encode(edges)),
                    "observations":observations,"transportTime":renderer.time,
                    "modulationTargets":node.modulationSpecs.map(\.key),
                    "drivers":try JSONSerialization.jsonObject(with:encoder.encode(node.modulations ?? [:])),
                    "graphRevision":revision()]
        }
        guard method == "POST", path == "/v1/connections/options" else { return nil }
        guard let body = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let raw = body["node"] as? String, let id = UUID(uuidString:raw),
              let direction = body["direction"] as? String, ["input","output"].contains(direction),
              let key = body["portID"] as? String else { throw GraphError("Expected node, direction (input or output), and portID") }
        let output = direction == "output"
        let type: PortType
        if let port = workspace.graph.node(id)?.ports(output:output).first(where:{ $0.id == key }) {
            type = port.type
        } else if let port = workspace.graph.component(id)?.interface?.ports.first(where:{ $0.id == UUID(uuidString:key) && $0.output == output }) {
            type = port.type
        } else { throw GraphError("Unknown "+direction+" port "+key) }
        let encoder = JSONEncoder()
        let entries = try CatalogNode.all.compactMap { entry -> [String:Any]? in
            let options = entry.connectionOptions(for:type,fromOutput:output)
            guard !options.isEmpty else { return nil }
            return ["catalogID":entry.id,"name":entry.title,"options":try JSONSerialization.jsonObject(with:encoder.encode(options))]
        }
        return ["type":type.rawValue,"entries":entries,"graphRevision":revision()]
    }
}
