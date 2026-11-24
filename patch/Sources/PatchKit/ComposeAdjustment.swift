import Metal
import PatchCore

extension Graph {
    /// A Compose adjustment has one host-provided video inlet and a video outlet.
    /// Walk the typed cable chain so Patch and Compose agree on effect order.
    func adjustmentChain(source: String) throws -> [Node] {
        guard let port = publishablePorts.first(where: { $0.id == source && $0.type == .video }),
              let group = groups.first(where: { group in
                  group.interface?.processingInput != nil && group.interface?.ports.contains {
                      $0.output && $0.node == port.nodeID && $0.key == port.portID
                  } == true
              }),
              let inletID = group.interface?.processingInput else { throw GraphError("Unknown adjustment output") }
        let inlet = try resolveSubpatchPort(group, id: inletID, output: false)
        var chain = [Node]()
        var current = port.nodeID
        var visited = Set<UUID>()
        while visited.insert(current).inserted, let node = node(current), group.members.contains(current) {
            guard node.kind.ports(output: false).map(\.type) == [.video], node.kind.outputTypes == [.video],
                  [.dither, .diffusion, .color, .halftone, .shaderEffect].contains(node.kind) else {
                throw GraphError("Unsupported Compose adjustment: " + node.name)
            }
            chain.append(node)
            let incoming = edges.first { $0.target == current && $0.input == 0 }
            if current == inlet.node && inlet.index == 0 && incoming == nil { return chain.reversed() }
            guard let incoming else { break }
            current = incoming.source
        }
        throw GraphError("Connect the adjustment inlet to its output within the subpatch")
    }
}

extension Uniforms {
    mutating func videoAdjustment(_ node: Node) {
        switch node.kind {
        case .halftone:
            mode.x = 9
            a = .init(Float(node.value("cell")), Float(node.value("angle") * .pi/180), Float(node.value("shape")), Float(node.value("mono")))
            b = .init(Float(node.value("contrast")), Float(node.value("mix")), 0, 0)
        case .color:
            mode.x = 4
            mode.y = UInt32(node.value("invert"))
            a = .init(Float(node.value("exposure")), Float(node.value("saturation")), Float(node.value("contrast")), Float(node.value("brightness")))
            b = .init(Float(node.value("blackPoint")), Float(node.value("whitePoint")), Float(node.value("gamma")), Float(node.value("hue") * .pi/180))
            c = .init(Float(node.value("outBlack")), Float(node.value("outWhite")), Float(node.value("temperature")), Float(node.value("tint")))
            d.x = Float(node.value("mix"))
        default: break
        }
    }
}
