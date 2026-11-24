import Foundation
import PatchCore

/// Import the retired built-ins once. Their original parameter sets remain in the copied show.
private let templates = [
    "solid_color":"Solid Color", "plasma":"Plasma", "grid":"Grid", "starfield":"Starfield", "cube":"Cube",
    "gradient":"Gradient", "scan_lines":"Scan Lines", "color_adjust":"Color Adjust", "lens_adjust":"Lens Adjust",
    "triangulate_faces":"Triangulate Faces", "glow_faces":"Glow Faces", "flash_faces":"Flash Faces",
    "box_waterfall":"Box Waterfall", "sphere_gimbal":"Sphere Gimbal", "box_edges":"Box Edges",
    "trace_snake":"Snake", "trace_pulse":"Pulse", "trace_rainbow":"Rainbow Flow", "trace_solid":"Solid",
    "trace_lightning":"Lightning Pulses", "vector_cube":"Vector Cube", "laser_text":"Laser Text",
    "electric_strips":"Lightning Cell Grid", "vector_scan_lines":"Vector Scan Lines",
    "lorenz_attractor":"Lorenz Attractor", "slime_mold":"Slime Mold"
]

/// Resolve the selected palette to a real graph outlet, including the older palette API's sink ID.
private func paletteEndpoint(_ locator:String,in graph:Graph)->(UUID,Int)? {
    if let published=graph.publishablePorts.first(where:{ $0.id==locator && $0.type == .palette }),
       let node=graph.node(published.nodeID),let output=node.ports(output:true).firstIndex(where:{ $0.id==published.portID && $0.type == .palette }){
        return (node.id,output)
    }
    let pieces=locator.split(separator:":")
    guard pieces.count>=2,pieces[0]=="patch",let id=UUID(uuidString:String(pieces[1])),let node=graph.node(id) else{return nil}
    if let index=node.kind.outputTypes.firstIndex(of:.palette){return (id,index)}
    guard let input=node.inputTypes.firstIndex(of:.palette),
          let edge=graph.edges.first(where:{ $0.target==id && $0.input==input }) else{return nil}
    return (edge.source,edge.outputIndex)
}

private func migrateMappedSetting(_ effect:String,_ key:String,_ value:Any,
                                  instance:UUID,graph:inout Graph)throws->Bool {
    guard let group=graph.component(instance),let target=group.interface?.preview,
          let index=graph.nodes.firstIndex(where:{ $0.id==target }) else{return false}
    if effect=="triangulate_faces",["start_face","end_face"].contains(key),let selection=value as? String {
        var ids=graph.nodes[index].mappedFaceIDs ?? [:]
        ids[key]=selection.isEmpty ? nil:selection;graph.nodes[index].mappedFaceIDs=ids
        return true
    }
    guard effect=="flash_faces" else{return false}
    if key=="palette_source",let reference=value as? String {
        if reference.isEmpty{return true}
        guard let source=paletteEndpoint(reference,in:graph),let inlet=graph.nodes[index].inputTypes.firstIndex(of:.palette) else{return false}
        var next=graph
        // A source inside a collapsed group must explicitly expose its palette.
        if let owner=next.groups.first(where:{ $0.members.contains(source.0) && $0.interface != nil }),
           let port=next.node(source.0)?.ports(output:true)[source.1],
           owner.interface?.ports.contains(where:{ $0.output && $0.node==source.0 && $0.key==port.id }) == false {
            try next.exposePort(owner.id,node:source.0,key:port.id,output:true,name:port.name)
        }
        try next.connect(source.0,to:target,input:inlet,output:source.1)
        graph=try next.validated();return true
    }
    return false
}

private struct ComposeImport {
    let library: URL
    var graph: Graph
    var converted = 0
    var notes = [String]()

    mutating func grid(_ input: Object, show: String) throws -> Object {
        guard var rows = input["rows"] as? [Object] else { throw GraphError("Missing rows in "+show) }
        for row in rows.indices {
            guard var clips = rows[row]["clips"] as? [String:Object] else { throw GraphError("Invalid clips in "+show) }
            for column in clips.keys.sorted() {
                guard var clip = clips[column], let effect = clip["gen"] as? String, let title = templates[effect] else { continue }
                let template = try SubpatchTemplate.read(Data(contentsOf:library.appendingPathComponent(title+".subpatch.json")))
                let origin = Position((graph.nodes.map { $0.position.x + $0.canvasWidth }.max() ?? 0) + 60, 0)
                let id = try graph.instantiate(template,at:origin,includeMIDI:false)
                guard let surface = graph.component(id)?.interface,
                      let port = surface.ports.first(where:{ $0.output && [.video,.collection,.trace].contains($0.type) }),
                      let published = graph.publishablePorts.first(where:{ $0.nodeID == port.node && $0.portID == port.key })
                else { throw GraphError("Missing Compose output in "+title) }
                let parameters = clip["params"] as? Object ?? [:]
                var unmapped = Set(parameters.keys)
                let aliases = ["solid_color":["color":"start"],"gradient":["color_a":"start","color_b":"end"],
                               "plasma":["hue_range":"spread"],"cube":["size":"scale","glow":"tint"],
                               "grid":["color":"tint"],"color_adjust":["black":"blackPoint","white":"whitePoint"]]
                for (old,raw) in parameters {
                    if effect == "laser_text", old == "content", let value = raw as? String,
                       let index = graph.nodes.firstIndex(where:{ $0.id == surface.preview }) {
                        graph.nodes[index].text = value
                        unmapped.remove(old)
                        continue
                    }
                    if (try? migrateMappedSetting(effect,old,raw,instance:id,graph:&graph)) == true {
                        unmapped.remove(old);continue
                    }
                    let faceAliases=["color_a":"color0","color_b":"color1","color_c":"color2","color_d":"color3","color_e":"color4","color_f":"color5","on_time":"onTime"]
                    let key = (effect=="flash_faces" ? faceAliases[old]:nil) ?? aliases[effect]?[old] ?? old
                    let members = graph.component(id)?.members ?? []
                    let nodeID = surface.parameters.first(where:{ $0.key == key })?.node ??
                        members.first(where:{ graph.node($0)?.parameterDefinitions.contains(where:{ $0.key == key }) == true })
                    guard let nodeID, let spec = graph.node(nodeID)?.parameterDefinitions.first(where:{ $0.key == key }) else { continue }
                    let value: Double?
                    if let n = raw as? NSNumber { value = n.doubleValue }
                    else if let s = raw as? String, s.count == 7, s.first == "#", let rgb = UInt32(s.dropFirst(),radix:16) { value = Double(rgb) }
                    else if let s = raw as? String, let index = spec.choices?.firstIndex(where:{ $0.caseInsensitiveCompare(s) == .orderedSame }) { value = Double(index) }
                    else { value = nil }
                    if let value, (try? graph.setParameter(nodeID,key:key,value:value)) != nil { unmapped.remove(old) }
                }
                var review = [String]()
                if !unmapped.isEmpty { review.append("Archived controls: "+unmapped.sorted().joined(separator:", ")) }
                var original: Object = ["effect":effect,"params":parameters]
                if let controls = clip.removeValue(forKey:"patchControls") {
                    original["patchControls"] = controls
                    review.append("Reconnect control bindings in Patch")
                }
                clip["importedEffect"] = original
                if !review.isEmpty {
                    clip["conversionNotes"] = review
                    notes.append(show+" / "+(clip["name"] as? String ?? title)+" — "+review.joined(separator:". "))
                }
                clip["gen"] = surface.processingInput == nil ? "patch_"+port.type.rawValue : "patch_adjustment"
                clip["params"] = ["source":published.id]
                clip.removeValue(forKey:"nativeImportUnsupported")
                clips[column] = clip
                converted += 1
            }
            rows[row]["clips"] = clips
        }
        var result = input
        result["rows"] = rows
        return result
    }
}

func convertComposeState(_ args: [String]) throws {
    guard args.count == 4 else { throw GraphError("patch-migrate compose NATIVE-STATE.json PATCH-SESSION.json SUBPATCH-DIRECTORY NEW-OUTPUT-DIRECTORY") }
    let urls = args.map { URL(fileURLWithPath:$0) }
    let fm = FileManager.default
    guard !fm.fileExists(atPath:urls[3].path) else { throw GraphError("Choose a new output directory") }
    let stateData = try Data(contentsOf:urls[0])
    var state = try object(JSONSerialization.jsonObject(with:stateData))
    let sessionData = fm.fileExists(atPath:urls[1].path) ? try Data(contentsOf:urls[1]) : nil
    let emptyGraph = try object(JSONSerialization.jsonObject(with:JSONEncoder().encode(Graph())))
    var session = try sessionData.map { try object(JSONSerialization.jsonObject(with:$0)) } ?? ["graph":emptyGraph,"playing":true]
    guard state["format"] as? String == "vj-native-development/1",
          let grid = state["grid"] as? Object, let active = grid["active_show"] as? String,
          var shows = state["showContents"] as? [String:Object], let activeShow = shows[active],
          let rawGraph = session["graph"] as? Object else { throw GraphError("Invalid VJ state or Patch session") }
    let source = urls[0].deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    let parent = urls[3].deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    guard parent.path != source.path && !parent.path.hasPrefix(source.path+"/") else { throw GraphError("Choose an output outside the source show") }
    let data = try json(rawGraph)
    let graph = try (try? Graph.read(data)) ?? Graph.migrate(data)
    var importer = ComposeImport(library:urls[2],graph:graph)
    let current = try importer.grid(grid,show:active)
    var activeSnapshot = activeShow
    activeSnapshot["rows"] = current["rows"]
    shows[active] = activeSnapshot
    for id in shows.keys.sorted() where id != active {
        if let show = shows[id] { shows[id] = try importer.grid(show,show:id) }
    }
    state["grid"] = current
    state["showContents"] = shows
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(importer.graph)
    _ = try Graph.read(encoded)
    func update(_ snapshot: inout Object) throws {
        snapshot["graph"] = try object(JSONSerialization.jsonObject(with:encoded))
        snapshot["graphRevision"] = digest(encoded)
        snapshot["file"] = NSNull()
        snapshot["dirty"] = true
    }
    try update(&session)
    if var tabs = session["tabs"] as? [Object] {
        guard let activeID = session["activeTab"] as? String,
              let i = tabs.firstIndex(where:{ $0["tabID"] as? String == activeID }) else { throw GraphError("Invalid active Patch tab") }
        try update(&tabs[i])
        session["tabs"] = tabs
    }
    let stage = urls[3].deletingLastPathComponent().appendingPathComponent(".compose-import-"+UUID().uuidString)
    try fm.createDirectory(at:stage,withIntermediateDirectories:false)
    defer { try? fm.removeItem(at:stage) }
    let excluded: Set<String> = ["native-state.json","native-state.json.bak","native.lock","Patch","thumbnail-cache","text-cache","media-cache","media-processing","ndi-clients.json"]
    for entry in try fm.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) where !excluded.contains(entry.lastPathComponent) {
        try fm.copyItem(at:entry,to:stage.appendingPathComponent(entry.lastPathComponent))
    }
    try json(state).write(to:stage.appendingPathComponent("native-state.json"))
    let patch = stage.appendingPathComponent("Patch")
    try fm.createDirectory(at:patch,withIntermediateDirectories:false)
    let sourcePatch = source.appendingPathComponent("Patch")
    if fm.fileExists(atPath:sourcePatch.path) {
        for entry in try fm.contentsOfDirectory(at:sourcePatch,includingPropertiesForKeys:nil) where entry.lastPathComponent != "session.json" {
            try fm.copyItem(at:entry,to:patch.appendingPathComponent(entry.lastPathComponent))
        }
    }
    try json(session).write(to:patch.appendingPathComponent("session.json"),options:.atomic)
    guard try Data(contentsOf:urls[0]) == stateData else { throw GraphError("Show changed during conversion. Retry the export.") }
    try fm.moveItem(at:stage,to:urls[3])
    print("Converted \(importer.converted) clips into \(urls[3].path)")
    for note in importer.notes { print(note) }
}
