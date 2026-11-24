import Foundation

extension Node {
    /// Node identity keeps duplicate display names distinct, including imported projects.
    public var streamName: String { "\(name) · \(id.uuidString)" }
}
extension Graph {
    public func availableName(_ base: String) -> String {
        let names = Set(nodes.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var suffix = 2
        while names.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
    public var liveDependencies: Set<UUID> {
        var protected = Set(nodes.filter { $0.enabled && $0.kind.isOutput }.map(\.id))
        protected.formUnion(publishablePorts.filter { $0.listed && node($0.nodeID)?.enabled == true }.map(\.nodeID))
        var pending = Array(protected)
        while let id = pending.popLast() {
            for dependency in dependencies where dependency.target == id {
                if protected.insert(dependency.source).inserted { pending.append(dependency.source) }
            }
        }
        return protected
    }
    /// Layout/name edits on processing nodes do not affect the signal. Output names do.
    public func liveImpact(of next: Graph) -> [UUID] {
        let protected = liveDependencies
        if protected.isEmpty { return [] }
        if width != next.width || height != next.height || fps != next.fps { return Array(protected) }
        return protected.filter { id in
            guard var before = node(id), var after = next.node(id) else { return true }
            before.position = .init(0,0); after.position = .init(0,0)
            if !before.kind.isOutput { before.name = ""; after.name = "" }
            if before != after { return true }
            let incoming = edges.filter { $0.target == id }.sorted { $0.input < $1.input }
            let revised = next.edges.filter { $0.target == id }.sorted { $0.input < $1.input }
            return incoming.map { "\($0.source):\($0.outputIndex):\($0.input)" } != revised.map { "\($0.source):\($0.outputIndex):\($0.input)" }
        }.sorted { $0.uuidString < $1.uuidString }
    }
}
