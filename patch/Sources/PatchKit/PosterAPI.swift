import AppKit
import PatchCore

/// The Poster Editor's operations for agents, at `/v1/apps/{posterID}`. Each
/// command runs the editor's own model on the request's draft, so layers,
/// groups, snapping-free geometry and undo behave exactly as in the window.
enum PosterAPI {
    static let api = NodeAppAPI(commands:[
        "add":"{element:{shape,text,font,size,x,y,…}, above?:layerID} → {id}. Omitted fields take defaults; shape defaults to text.",
        "patch":"{ids:[layerID] | id, set:{field:value}} merges fields into each layer; null clears an optional field (color null follows the ink).",
        "delete":"{ids}",
        "reorder":"{ids, to:front|back|forward|backward} or {order:[every layerID, front to back]}",
        "group":"{ids, name?} → {group}",
        "ungroup":"{ids} removes the groups those layers belong to",
        "group_update":"{group, set:{name?,collapsed?,hidden?,locked?}}",
        "align":"{ids, edge:left|centerX|right|top|centerY|bottom}; one layer aligns to the poster",
        "distribute":"{ids (3+), axis:horizontal|vertical}",
        "fit_margins":"{id} scales type so its widest line spans the margins",
        "fill_poster":"{id} image fills the poster",
        "fit_video_width":"{id} video layer poster-wide at its source's proportions",
        "add_image":"{file:absolutePath, above?:layerID} → {id}, filling the poster",
        "connect_video":"{node:nodeID, video?:1–6} wires a node into that video input (default: next free); it appears as a layer",
        "format":"{format:index|title}",
        "materialize":"{} keeps the current automatic layout as a free layout, so its layer IDs are stable",
        "revert":"{} discards the free layout and returns to the tagged text",
        "fonts":"{query?} → installed families and faces (PostScript names for `font`)"
    ],state:state,run:run)

    private static func model(_ context: NodeAppAPI.Context) -> PosterEditorModel {
        PosterEditorModel(workspace:context.workspace,renderer:context.renderer,id:context.id,document:context.document)
    }
    private static func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value),options:.fragmentsAllowed) }

    static func state(_ context: NodeAppAPI.Context) throws -> [String:Any] {
        let model = model(context)
        guard let node = model.composer else { throw GraphError("Not a Poster node") }
        let layout = model.layout
        let layers = try model.elements.map { element -> Any in
            var object = try json(element) as? [String:Any] ?? [:]
            let box = model.box(element)
            object["box"] = ["centerX":box.center.x,"centerY":box.center.y,"width":box.size.width,"height":box.size.height,"rotation":box.rotation]
            object["effectiveHidden"] = layout.isHidden(element)
            if element.shape == .video { object["source"] = model.source(element).map { ["id":$0.id.uuidString,"name":$0.name] } ?? NSNull() }
            return object
        }
        let inputs = PosterStyle.videoInputs.map { video -> [String:Any] in
            let source = context.document.graph.edges.first { $0.target == node.id && $0.input == PosterStyle.edgeInput(video:video) }.flatMap { context.document.graph.node($0.source) }
            return ["video":video,"source":source.map { ["id":$0.id.uuidString,"name":$0.name] } ?? NSNull()]
        }
        return [
            "poster":["width":model.poster.width,"height":model.poster.height,"format":PosterStyle.formats[max(0,min(PosterStyle.formats.count-1,Int(node.value("format"))))].0,"marginPx":model.margin],
            "formats":PosterStyle.formats.map(\.0),
            "freeLayout":model.isFreeLayout,
            "text":node.text ?? PosterStyle.defaultText,
            "parameters":node.parameters,
            "layers":layers,
            "groups":try json(layout.groups ?? []),
            "videoInputs":inputs,
            "videoCandidates":model.videoCandidates.map { ["id":$0.id.uuidString,"name":$0.name] },
            "notes":"layers are back to front; x/y are the center (0–1 of width/height, y down); size, width and stroke are fractions of poster width, height of poster height; box is in poster pixels. Edit tagged text with POST /v1/commands {op:update,id,text}; numeric settings with {op:parameter}."
        ]
    }

    static func run(_ context: NodeAppAPI.Context,_ command: [String:Any]) throws -> [String:Any] {
        let model = model(context), op = command["op"] as? String ?? ""
        guard model.composer != nil else { throw GraphError("Not a Poster node") }
        func layerIDs() throws -> [UUID] {
            let raw = command["ids"] as? [String] ?? (command["id"] as? String).map { [$0] } ?? []
            guard !raw.isEmpty else { throw GraphError("ids (or id) required") }
            let known = Set(model.elements.map(\.id))
            return try raw.map { value in
                guard let id = UUID(uuidString:value),known.contains(id) else { throw GraphError("Unknown layer \(value)") }
                return id
            }
        }
        func select() throws { model.selection = Set(try layerIDs().map(PosterItem.element)) }
        func anchor() throws -> Int? {
            guard let value = command["above"] as? String else { return nil }
            guard let id = UUID(uuidString:value),let index = model.layers.firstIndex(where:{ $0.id == id }) else { throw GraphError("Unknown layer \(value)") }
            return index
        }
        switch op {
        case "add":
            var element = try JSONDecoder().decode(PosterElement.self,from:JSONSerialization.data(withJSONObject:command["element"] as? [String:Any] ?? [:]))
            if model.layers.contains(where:{ $0.id == element.id }) { element.id = UUID() }
            guard element.isValid,element.shape != .chrome else { throw GraphError("Invalid element") }
            let above = try anchor()
            model.change("Add \(element.shape.rawValue.capitalized)") { elements,_ in
                if let above,above < elements.count { elements.insert(element,at:above+1) } else { elements.append(element) }
            }
            return ["id":element.id.uuidString]
        case "patch":
            let ids = Set(try layerIDs())
            guard let set = command["set"] as? [String:Any],!set.isEmpty else { throw GraphError("set:{field:value} required") }
            guard set["id"] == nil else { throw GraphError("A layer's id can't change") }
            var patched: [UUID:PosterElement] = [:]
            for element in model.elements where ids.contains(element.id) {
                var object = try json(element) as? [String:Any] ?? [:]
                for (key,value) in set { if value is NSNull { object.removeValue(forKey:key) } else { object[key] = value } }
                let next = try JSONDecoder().decode(PosterElement.self,from:JSONSerialization.data(withJSONObject:object))
                guard next.isValid else { throw GraphError("Invalid values for layer \(element.id.uuidString)") }
                patched[element.id] = next
            }
            model.change("Edit Layers") { elements,_ in for index in elements.indices { if let next = patched[elements[index].id] { elements[index] = next } } }
            return ["patched":patched.count]
        case "delete": try select(); model.deleteSelection()
        case "reorder":
            if let order = command["order"] as? [String] {
                let ids = order.compactMap(UUID.init(uuidString:))
                guard Set(ids) == Set(model.elements.map(\.id)),ids.count == model.elements.count else { throw GraphError("order must list every layer once") }
                model.restack("Reorder Layers",ids.map(PosterItem.element))
            } else {
                try select()
                let arrange: [String:PosterEditorModel.Arrange] = ["front":.front,"back":.back,"forward":.forward,"backward":.backward]
                guard let to = (command["to"] as? String).flatMap({ arrange[$0] }) else { throw GraphError("to must be front, back, forward or backward") }
                model.arrange(to)
            }
        case "group":
            try select()
            guard let group = model.groupSelection(name:command["name"] as? String) else { throw GraphError("Nothing to group") }
            return ["group":group.uuidString]
        case "ungroup": try select(); model.ungroupSelection()
        case "group_update":
            guard let value = command["group"] as? String,let id = UUID(uuidString:value),model.layout.group(id) != nil else { throw GraphError("Unknown group") }
            let set = command["set"] as? [String:Any] ?? [:]
            model.updateGroup(id,action:"Edit Group") { group in
                if let name = set["name"] as? String { group.name = name }
                if let value = set["collapsed"] as? Bool { group.collapsed = value }
                if let value = set["hidden"] as? Bool { group.hidden = value }
                if let value = set["locked"] as? Bool { group.locked = value }
            }
        case "align":
            try select()
            let edges: [String:PosterEditorModel.Edge] = ["left":.left,"centerX":.centerX,"right":.right,"top":.top,"centerY":.centerY,"bottom":.bottom]
            guard let edge = (command["edge"] as? String).flatMap({ edges[$0] }) else { throw GraphError("edge must be left, centerX, right, top, centerY or bottom") }
            model.align(edge)
        case "distribute":
            try select()
            guard model.selection.count > 2 else { throw GraphError("distribute needs 3 or more layers") }
            guard let axis = command["axis"] as? String,["horizontal","vertical"].contains(axis) else { throw GraphError("axis must be horizontal or vertical") }
            model.distribute(vertical:axis == "vertical")
        case "fit_margins", "fill_poster", "fit_video_width":
            let ids = try layerIDs()
            guard ids.count == 1,let element = model.element(ids[0]) else { throw GraphError("id required") }
            let shape: PosterElement.Shape = op == "fit_margins" ? .text : op == "fill_poster" ? .image : .video
            guard element.shape == shape else { throw GraphError("\(op) applies to \(shape.rawValue) layers") }
            if op == "fit_margins" { model.fitBetweenMargins(element.id) } else if op == "fill_poster" { model.fillPoster(element.id) } else { model.fitVideoWidth(element.id) }
        case "add_image":
            guard let file = command["file"] as? String,file.hasPrefix("/"),FileManager.default.fileExists(atPath:file) else { throw GraphError("file must be an existing absolute path") }
            if let above = try anchor() { model.selection = [.element(model.layers[above].id)] } else { model.selection = [] }
            model.addImage(URL(fileURLWithPath:file))
            guard case .element(let id)? = model.selection.first else { throw GraphError("Could not add the image") }
            return ["id":id.uuidString]
        case "connect_video":
            guard let value = command["node"] as? String,let node = UUID(uuidString:value),model.videoCandidates.contains(where:{ $0.id == node }) else { throw GraphError("node must be a video node that doesn't depend on this poster") }
            let video = command["video"] as? Int
            if let video,!PosterStyle.videoInputs.contains(video) { throw GraphError("video must be 1–6") }
            if video == nil,model.composer.map({ poster in PosterStyle.videoInputs.allSatisfy { video in model.graph.edges.contains { $0.target == poster.id && $0.input == PosterStyle.edgeInput(video:video) } } }) == true { throw GraphError("All six video inputs are in use") }
            model.connectVideo(node,input:video)
        case "format":
            let index = command["format"] as? Int ?? (command["format"] as? String).flatMap { title in PosterStyle.formats.firstIndex { $0.0 == title } }
            guard let index,PosterStyle.formats.indices.contains(index) else { throw GraphError("format must be an index or one of: \(PosterStyle.formats.map(\.0).joined(separator:", "))") }
            model.setFormat(index)
        case "materialize":
            let layout = model.layout, id = context.id
            context.document.edit("Keep Layout") { graph in if let index = graph.nodes.firstIndex(where:{ $0.id == id }) { graph.nodes[index].poster = layout } }
        case "revert":
            let id = context.id
            context.document.edit("Revert Poster Layout") { graph in if let index = graph.nodes.firstIndex(where:{ $0.id == id }) { graph.nodes[index].poster = nil } }
        case "fonts":
            let query = (command["query"] as? String ?? "").lowercased()
            let families = PosterFonts.families.filter { query.isEmpty || $0.lowercased().contains(query) }
            return ["families":families.prefix(query.isEmpty ? 400 : 100).map { family in ["family":family,"faces":PosterFonts.members(family).map { ["font":$0.0,"style":$0.1] }] },
                    "featured":PosterFonts.featured.map { ["font":$0.0,"title":$0.1] }]
        default: throw GraphError("Unknown op \(op)")
        }
        return ["ok":true]
    }
}
