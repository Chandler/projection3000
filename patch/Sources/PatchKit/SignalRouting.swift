import Foundation
import PatchCore

/// Runtime addresses include the output slot even for nodes that currently have one output.
struct SignalOutlet: Hashable {
    let node: UUID
    let port: Int
}

struct SignalRouting {
    var nodes: [UUID:Node] = [:]
    var incoming: [UUID:[Edge]] = [:]
    var sockets: [UUID:[Int:Edge]] = [:]

    init() {}
    init(_ graph: Graph) {
        nodes = Dictionary(uniqueKeysWithValues:graph.nodes.map { ($0.id,$0) })
        incoming = Dictionary(grouping:graph.edges,by: \.target)
        for edge in graph.edges {
            sockets[edge.target,default:[:]][edge.input] = edge
        }
    }
}

extension Edge {
    var outlet: SignalOutlet { SignalOutlet(node:source,port:outputIndex) }
}
