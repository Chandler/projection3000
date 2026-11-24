import Foundation
import PatchCore

extension Graph {
    fileprivate func migratingLayout() throws -> Graph {
        // Removed visualizer options must not prevent existing projects from opening.
        let removedVisualizerKeys = ["appearance", "previewMode", "autoFit", "fitScale"]
        if nodes.contains(where:{ node in node.kind == .voltageVisualizer && removedVisualizerKeys.contains(where: { node.parameters[$0] != nil }) }) {
            var migrated=self
            for i in migrated.nodes.indices where migrated.nodes[i].kind == .voltageVisualizer {
                for key in removedVisualizerKeys { migrated.nodes[i].parameters.removeValue(forKey:key) }
            }
            return try migrated.migratingLayout()
        }
        // Move old encoder rate choices to their hardware sinks, once per document.
        if nodes.contains(where:{ $0.kind == .voltageEncoder && $0.parameters["sampleRate"] != nil }) {
            var migrated=self, requested: [UUID:Double]=[:]
            for encoder in nodes where encoder.kind == .voltageEncoder {
                guard let old=encoder.parameters["sampleRate"],old.isFinite,old>=0,old<=2,old.rounded()==old else { continue }
                var pending=[encoder.id],seen=Set<UUID>()
                while let id=pending.popLast() {
                    guard seen.insert(id).inserted else { continue }
                    if let sink=node(id),sink.kind == .audioOutput,sink.parameters["sampleRate"] == nil { requested[id]=max(requested[id] ?? 0,old+1) }
                    pending += edges.filter { $0.source == id && node(id)?.kind.outputType(at:$0.outputIndex) == .audio }.map(\.target).filter { !seen.contains($0) }
                }
            }
            for i in migrated.nodes.indices {
                if migrated.nodes[i].kind == .voltageEncoder { migrated.nodes[i].parameters.removeValue(forKey:"sampleRate") }
                if let rate=requested[migrated.nodes[i].id] { migrated.nodes[i].parameters["sampleRate"]=rate }
            }
            return try migrated.migratingLayout()
        }
        if PosterStyle.needsMigration(self) { return try PosterStyle.migrate(self).migratingLayout() }
        // Old Projection Dots documents retain their paper size and color settings.
        // Remove redundant geometry controls before normal schema validation.
        if nodes.contains(where: { $0.kind == .projectionDots && !ProjectionDotsStyle.legacyKeys.isDisjoint(with: $0.parameters.keys) }) {
            var migrated = self
            migrated.nodes = nodes.map { $0.kind == .projectionDots ? ProjectionDotsStyle.migrate($0) : $0 }
            return try migrated.migratingLayout()
        }
        let colorKeys = Set(DotColorsStyle.parameters.map(\.key))
        let legacyDots = nodes.filter { $0.kind == .projectionDots && !colorKeys.isDisjoint(with:$0.parameters.keys) }
        if !legacyDots.isEmpty {
            var migrated = self
            for old in legacyDots {
                guard let index = migrated.nodes.firstIndex(where: { $0.id == old.id }) else { continue }
                if !migrated.edges.contains(where: { $0.target == old.id && $0.input == 0 }) {
                    var colors = Node(kind:.dotColors,position:.init(old.position.x-290,old.position.y))
                    for key in colorKeys { if let value = old.parameters[key] { colors.parameters[key] = value } }
                    colors.modulations = old.modulations?.filter { colorKeys.contains($0.key) }
                    migrated.nodes.append(colors)
                    migrated.edges.append(Edge(source:colors.id,target:old.id))
                }
                migrated.nodes[index].parameters = old.parameters.filter { !colorKeys.contains($0.key) }
                migrated.nodes[index].modulations = old.modulations?.filter { !colorKeys.contains($0.key) }
                // The old source contains the combined color/geometry shader. Its file is preserved on disk.
                migrated.nodes[index].file = nil
            }
            return try migrated.migratingLayout()
        }
        return self
    }
}

extension Graph {
    /// Used by the offline project converter. The editor reads only the current format.
    public static func migrate(_ data: Data) throws -> Graph {
        guard var document = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let version = document["version"] as? Int, version == 1 || version == currentVersion,
              var originals = document["nodes"] as? [[String:Any]],
              var cables = document["edges"] as? [[String:Any]] else { throw GraphError("Unsupported migration input") }
        if version == currentVersion, let graph = try? read(data) { return graph }
        struct Slots: Decodable { let input: Int?; let output: Int? }
        func slots(_ object: [String:Any]) throws -> Slots {
            try JSONDecoder().decode(Slots.self,from:JSONSerialization.data(withJSONObject:object))
        }
        let edgeSlots = try cables.map(slots)
        for i in cables.indices {
            cables[i].removeValue(forKey:"input")
            cables[i].removeValue(forKey:"output")
        }
        var modulationSlots: [Int:[String:Int]] = [:]
        for i in originals.indices {
            if originals[i]["kind"] as? String == "graphInkFlow2" { originals[i]["kind"] = "graphInkFlow" }
            if originals[i]["kind"] as? String == "lightField" {
                if originals[i]["file"] is String {
                    let specs: [ParameterSpec] = [
                        .init("scale","Cloud count",1,12,4), .init("radius","Cloud radius",0.05,0.7,0.24),
                        .init("drift","Drift distance",0,1,0.14), .init("breathing","Breathing",0,1,0.7),
                        .init("contrast","Contrast",0.25,4,1.5), .init("floor","Dark region level",0,1,0.04),
                        .init("gain","Bright region gain",0,6,3.5), .init("seed","Seed",0,65535,93),
                        .init("speed","Evolution speed",0,2,0.25,scalesFieldTime:true)
                    ]
                    originals[i]["kind"] = "fieldShader"
                    originals[i]["fieldParameters"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(specs))
                } else { originals[i]["kind"] = "streakGlow" }
            }
            if var bindings = originals[i]["modulations"] as? [String:[String:Any]] {
                for (key,binding) in bindings {
                    modulationSlots[i,default:[:]][key] = try slots(binding).output ?? 0
                    bindings[key]?.removeValue(forKey:"output")
                }
                originals[i]["modulations"] = bindings
            }
        }
        document["nodes"] = originals
        document["edges"] = cables
        let normalized = try JSONSerialization.data(withJSONObject:document)
        var graph = try ProjectCoding.decode(Graph.self,from:normalized)
        for i in graph.edges.indices {
            graph.edges[i].input = edgeSlots[i].input ?? 0
            graph.edges[i].output = edgeSlots[i].output
        }
        for (i,bindings) in modulationSlots {
            for (key,slot) in bindings {
                let id = graph.nodes[i].modulations?[key]?.outputID
                graph.nodes[i].modulations?[key]?.output = slot
                graph.nodes[i].modulations?[key]?.outputID = id
            }
        }
        if version == 1 { graph = try graph.migratingLayout() }
        let nodesByID = Dictionary(grouping:graph.nodes,by: \.id)
        func portID(node: UUID, output: Bool, index: Int, named: String?) throws -> String {
            guard let matches = nodesByID[node], matches.count == 1, let ports = matches.first?.ports(output:output) else { throw GraphError("Missing migration endpoint") }
            if let named, ports.contains(where:{ $0.id == named }) { return named }
            guard named == nil, let port = ports.first(where:{ $0.legacyIndex == index }) else { throw GraphError("Unknown migration port on \(node)") }
            return port.id
        }
        for i in graph.edges.indices {
            let edge = graph.edges[i]
            graph.edges[i].inputID = try portID(node:edge.target,output:false,index:edge.input,named:edge.inputID)
            graph.edges[i].outputID = try portID(node:edge.source,output:true,index:edge.outputIndex,named:edge.outputID)
        }
        for i in graph.nodes.indices {
            let node = graph.nodes[i]
            for (key,binding) in node.modulations ?? [:] {
                let id = try portID(node:binding.source,output:true,index:binding.outputIndex,named:binding.outputID)
                graph.nodes[i].modulations?[key]?.outputID = id
            }
            if let old = node.publications {
                var updated: [String:OutputPublication] = [:]
                for (key,value) in old {
                    let names = node.publishablePortIDs
                    let name: String
                    if let slot = Int(key), names.indices.contains(slot) { name = names[slot] }
                    else if names.contains(key) { name = key }
                    else { throw GraphError("Unknown publication on \(node.name)") }
                    guard updated.updateValue(value,forKey:name) == nil else { throw GraphError("Duplicate publication on \(node.name)") }
                }
                graph.nodes[i].publications = updated
            }
        }
        graph.version = currentVersion
        return try graph.validated()
    }
}
