import Foundation

public struct Component: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var members: [UUID]
    public var position: Position
    public var collapsed: Bool
    public init(members: [UUID],position: Position) { id = UUID(); name = "Component"; self.members = members; self.position = position; collapsed = true }
}
public struct ComponentPort: Equatable, Sendable {
    public let node: UUID
    public let input: Int
    public let type: PortType
    public let name: String
}
extension Graph {
    public var groups: [Component] { components ?? [] }
    public func component(_ id: UUID) -> Component? { groups.first { $0.id == id } }
    public func collapsedOwner(_ id: UUID) -> Component? { groups.first { $0.collapsed && $0.members.contains(id) } }
    public func ports(_ component: Component,output: Bool) -> [ComponentPort] {
        let members = Set(component.members)
        return component.members.compactMap(node).flatMap { node -> [ComponentPort] in
            if output {
                return node.kind.outputTypes.enumerated().compactMap { index,type in
                    let outgoing = edges.filter { $0.source == node.id && $0.outputIndex == index }
                    guard !outgoing.contains(where:{ members.contains($0.target) }) || outgoing.contains(where:{ !members.contains($0.target) }) else { return nil }
                    return ComponentPort(node:node.id,input:index,type:type,name:node.name+" · "+node.kind.outputs[index])
                }
            }
            return node.inputs.indices.compactMap { i in
                guard !edges.contains(where:{ $0.target == node.id && $0.input == i && members.contains($0.source) }) else { return nil }
                return ComponentPort(node:node.id,input:i,type:node.inputTypes[i],name:node.name+" · "+node.inputs[i])
            }
        }
    }
    public func previewNode(_ id: UUID?) -> Node? {
        guard let id else { return nil }
        if let node = node(id) { return node }
        guard let component = component(id) else { return nil }
        let ordered = (try? orderedNodes()) ?? nodes
        return ordered.last { component.members.contains($0.id) }
    }
    @discardableResult public mutating func makeComponent(_ ids: Set<UUID>) throws -> UUID {
        let members = nodes.filter { ids.contains($0.id) }
        guard members.count >= 2, members.count == ids.count else { throw GraphError("Shift-click at least two nodes to create a component") }
        guard !groups.contains(where:{ !Set($0.members).isDisjoint(with:ids) }) else { throw GraphError("Ungroup the existing component before regrouping its nodes") }
        let group = Component(members:members.map(\.id),position:.init(members.map(\.position.x).min()!,members.map(\.position.y).min()!))
        components = groups+[group]; return group.id
    }
    public mutating func autoLayout() throws {
        // The APC fans out to many targets; lay out the rest, then add it on the left.
        let apc = nodes.first { $0.kind == .apc40 && collapsedOwner($0.id) == nil }?.id
        let dependencies = self.dependencies.filter { $0.source != apc && $0.target != apc }
        let ordered = try orderedNodes().filter { $0.id != apc }
        var rank: [UUID:Int] = [:]
        for node in ordered { rank[node.id] = (dependencies.filter { $0.target == node.id }.compactMap { rank[$0.source].map { $0+1 } }.max() ?? 0) }
        let snapshot = self
        let unit: (UUID)->UUID = { snapshot.collapsedOwner($0)?.id ?? $0 }
        var unitRank: [UUID:Int] = [:]
        var units: [UUID] = []
        for node in ordered {
            let id = unit(node.id)
            if unitRank[id] == nil { units.append(id); unitRank[id] = rank[node.id] ?? 0 }
        }
        // Treat visible units joined by any dependency as one graph, including
        // control connections and connections through collapsed components.
        var neighbors: [UUID:[UUID]] = [:]
        for dependency in dependencies {
            let source = unit(dependency.source), target = unit(dependency.target)
            guard source != target else { continue }
            neighbors[source,default:[]].append(target)
            neighbors[target,default:[]].append(source)
        }
        var island: [UUID:Int] = [:]
        var islandCount = 0
        for id in units where island[id] == nil {
            island[id] = islandCount
            var pending = [id]
            while let current = pending.popLast() {
                for neighbor in neighbors[current] ?? [] where island[neighbor] == nil {
                    island[neighbor] = islandCount
                    pending.append(neighbor)
                }
            }
            islandCount += 1
        }
        var placements: [UUID:Position] = [:]
        var nextY = 120.0
        for index in 0..<islandCount {
            var layers = Dictionary(grouping:units.filter { island[$0] == index },by:{ unitRank[$0]! })
            // Barycenter ordering reduces crossings while preserving deterministic ties.
            for _ in 0..<4 {
                var row: [UUID:Double] = [:]
                for layer in layers.values { for (i,id) in layer.enumerated() { row[id] = Double(i) } }
                for level in layers.keys.sorted() {
                    let original = layers[level]!
                    func score(_ id: UUID) -> Double {
                        let adjacent = dependencies.filter { unit($0.target) == id && unit($0.source) != id }.compactMap { row[unit($0.source)] }
                        return adjacent.isEmpty ? (row[id] ?? 0) : adjacent.reduce(0,+)/Double(adjacent.count)
                    }
                    layers[level] = original.enumerated().sorted { let a = score($0.element), b = score($1.element); return a == b ? $0.offset < $1.offset : a < b }.map(\.element)
                }
            }
            // Every column shares this graph's row. Reserve its full height
            // before starting another graph, even when other columns are short.
            let startY = nextY
            for level in layers.keys.sorted() {
                var y = startY
                for id in layers[level]! {
                    placements[id] = .init(80+Double(level)*320,y)
                    let height = component(id).map { max(224,Double(max(ports($0,output:false).count,ports($0,output:true).count))*25+155) } ?? (node(id)?.canvasHeight ?? 224)
                    y += height+65
                }
                nextY = max(nextY,y)
            }
        }
        if let apc,let width = node(apc)?.canvasWidth {
            for id in placements.keys { placements[id]!.x += width+120 }
            placements[apc] = .init(80,120)
        }
        // Compute all unit mappings before mutation of the graph.
        let owners = Dictionary(uniqueKeysWithValues:nodes.map { ($0.id,unit($0.id)) })
        let oldGroups = groups
        for i in nodes.indices {
            if let owner = oldGroups.first(where:{ $0.id == owners[nodes[i].id] }), let to = placements[owner.id] {
                nodes[i].position.x += to.x-owner.position.x; nodes[i].position.y += to.y-owner.position.y
            } else if let to = placements[nodes[i].id] { nodes[i].position = to }
        }
        components = oldGroups.map { group in var g = group; if let p = placements[g.id] { g.position = p } else if !g.collapsed { let members = nodes.filter { g.members.contains($0.id) }; g.position = .init(members.map(\.position.x).min() ?? g.position.x,members.map(\.position.y).min() ?? g.position.y) }; return g }
    }
}
