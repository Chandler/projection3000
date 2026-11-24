import AppKit
import Foundation
import AVFoundation
import Network
import PatchCore
import OutputBridge

final class ControlAPI {
    let workspace: Workspace
    let renderer: Renderer
    let token: String
    let port: UInt16
    let tokenURL: URL
    var jobs: [String:LiveJob] = [:]
    let compileQueue = DispatchQueue(label:"patch.api.compile",qos:.utility)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "patch.api")
    var state = "Starting"
    var onFrame: (() -> Void)?
    var pinnedPreviewState: (() -> [[String:Any]])?
    var pinnedPreviewSnapshot: ((UUID,URL) throws -> Void)?
    var editorState: (() -> [String:Any])?
    var onRestart: ((URL,[String:Any]) throws -> URL)?
    var activeEndpoint: (() -> ControlAPI?)?
    var forwardRoute: ((String,String,Data) throws -> [String:Any]?)?
    var tabState: (() -> [[String:Any]])?
    var tabCommand: (([String:Any]) throws -> [String:Any]?)?
    var onOpenProject: ((URL) throws -> Void)?
    var restarting = false
    init(workspace: Workspace, renderer: Renderer, port: UInt16 = 9417, listen: Bool = true) throws {
        self.workspace = workspace; self.renderer = renderer; self.port = port
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Patch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tokenURL = directory.appendingPathComponent("api-token")
        if let saved = try? String(contentsOf: tokenURL), saved.count >= 32 { token = saved.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { token = UUID().uuidString + UUID().uuidString; try token.write(to: tokenURL, atomically: true, encoding: .utf8) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        guard listen else { state = "Shared tab API"; return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] value in
            DispatchQueue.main.async {
                switch value { case .ready: self?.state = "127.0.0.1:\(port)"; case .failed(let error): self?.state = "API: \(error.localizedDescription)"; default: break }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let request = HTTPRequest(connection: connection, queue: self.queue) { [weak self] method, path, headers, data, reply in
                guard let self else { return }
                if headers["origin"] != nil { reply(403, ["error":"Browser origins are not accepted."]); return }
                if method == "GET" && path == "/health" { reply(200,["app":"Patch","version":1]); return }
                guard headers["authorization"] == "Bearer \(self.token)" else { reply(401,["error":"Bearer token required. Read ~/Library/Application Support/Patch/api-token."]); return }
                DispatchQueue.main.async {
                    let endpoint = self.activeEndpoint?() ?? self
                    if method == "POST", path == "/v1/commands", let command = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any], ["record_save","record_discard"].contains(command["op"] as? String ?? "") {
                        let renderer=endpoint.renderer
                        DispatchQueue.global(qos:.userInitiated).async {
                            do {
                                if command["op"] as? String == "record_discard" { try renderer.discardRecording(endpoint.uuid(command,"id")) }
                                else { try renderer.saveRecording(endpoint.uuid(command,"id"),to:endpoint.fileURL(command),replace:command["replace"] as? Bool ?? false) }
                                reply(200,["ok":true])
                            } catch { reply(400,["error":error.localizedDescription]) }
                        }
                        return
                    }
                    do { reply(200, try self.route(method, path, data)) }
                    catch { reply(400,["error":error.localizedDescription]) }
                }
            }
            request.start()
        }
        listener.start(queue: queue)
    }
    func stop() { listener?.cancel(); listener = nil }
    deinit { listener?.cancel() }
    var paletteSources: [[String:Any]] {
        workspace.graph.nodes.filter { $0.enabled && ($0.kind == .publishPalette || $0.kind == .syphon) }.map { node in
            let colors=renderer.colorPalette(node.id)?.colors ?? []
            return ["id":"patch:"+node.id.uuidString,"nodeID":node.id.uuidString,
                    "name":node.kind == .syphon ? node.streamName : node.name,
                    "kind":node.kind.rawValue,"colorSpace":"sRGB","available":!colors.isEmpty,
                    "colors":colors.map { ["r":$0.r,"g":$0.g,"b":$0.b] }]
        }
    }
    func stateObject() throws -> [String: Any] {
        workspace.plugins.synchronize()
        let graph = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.graph))
        let audio = renderer.audioGraph.snapshot
        return ["tabs":tabState?() ?? [],"running":renderer.running,"renderedFrames":renderer.renderedFrames,"pinnedPreviews":pinnedPreviewState?() ?? [],"audioPlugins":workspace.plugins.state,"voltageScopes":renderer.voltageScopeStates,"analogChroma":renderer.audioGraph.chroma.state,"midiOutput":renderer.midiGraph.state,"audioHardware":renderer.audioGraph.hardwareMetrics,"renderDemand":renderer.demandState,"publishedOutputs":renderer.publishedOutputs,"paletteSources":paletteSources,"palettes":renderer.paletteStates,"midi":workspace.midi?.stateObject ?? [:],"midiParameters":try Dictionary(uniqueKeysWithValues:workspace.graph.nodes.map { ($0.id.uuidString,try JSONSerialization.jsonObject(with:JSONEncoder().encode($0.midiParameters))) }),"processID":ProcessInfo.processInfo.processIdentifier,"editor":editorState?() ?? [:],"controls":try Dictionary(uniqueKeysWithValues:workspace.graph.nodes.filter(\.isBlinds).map { ($0.id.uuidString,try JSONSerialization.jsonObject(with:JSONEncoder().encode(BlindsControls.specs))) }),"parameterSpecs":try Dictionary(uniqueKeysWithValues:workspace.graph.nodes.map { ($0.id.uuidString,try JSONSerialization.jsonObject(with:JSONEncoder().encode($0.parameterSpecs))) }),"graphRevision":revision(),"liveProtectedNodes":workspace.graph.liveDependencies.map(\.uuidString),"streams":workspace.graph.nodes.filter { $0.kind == .syphon || $0.kind == .ndi }.map { ["id":$0.id.uuidString,"kind":$0.kind.rawValue,"name":$0.streamName,"enabled":$0.enabled] as [String:Any] },"audioPreview":renderer.audioGraph.previewState,"audio":Dictionary(uniqueKeysWithValues:audio.0.map { ($0.key.uuidString,["peak":$0.value.peak,"sampleRate":$0.value.sampleRate,"nativeSampleRate":$0.value.sampleRate,"channels":2,"status":audio.1[$0.key] ?? ""] as [String:Any]) }),"media":Dictionary(uniqueKeysWithValues:renderer.mediaStates.map { ($0.key.uuidString,["position":$0.value.position,"duration":$0.value.duration,"playing":$0.value.playing,"speed":$0.value.speed] as [String:Any]) }),"controlValues":Dictionary(uniqueKeysWithValues:renderer.controlValues.map { ($0.key.uuidString,$0.value) }),"modulationValues":Dictionary(uniqueKeysWithValues:renderer.modulationValues.map { ($0.key.uuidString,$0.value) }),"previewVisible":workspace.previewVisible,"selectedNodes":workspace.selectedIDs.map(\.uuidString),"recordings":renderer.recordingStates,"faceDetections":renderer.faceStates,"poseDetections":renderer.poseStates,"projectName":workspace.projectName,"graph":graph, "viewers":renderer.views.allObjects.map { view -> [String:Any] in
            let stats = view.presentationStats
            return ["previewRendering":view.previewRendering,"previewPoints":view.previewPoints,"targetFPS":view.preferredFramesPerSecond,"bounds":[Double(view.bounds.width),Double(view.bounds.height)],"visibleRect":[Double(view.visibleRect.width),Double(view.visibleRect.height)],"drawableSize":[Double(view.drawableSize.width),Double(view.drawableSize.height)],"paused":view.isPaused,"node":view.nodeID?.uuidString as Any? ?? NSNull(),"window":view.window?.title ?? "","windowLevel":view.window?.level.rawValue ?? 0,"windowFrame":view.window.map { [Double($0.frame.minX),Double($0.frame.minY),Double($0.frame.width),Double($0.frame.height)] } ?? [],"screenFrame":view.window?.screen.map { [Double($0.frame.minX),Double($0.frame.minY),Double($0.frame.width),Double($0.frame.height)] } ?? [],"visible":view.window?.isVisible == true && view.window?.occlusionState.contains(.visible) == true && !view.isHiddenOrHasHiddenAncestor,"presentedFrames":stats.frames,"lastPresentedTime":stats.time]
        }, "selection":workspace.selected?.uuidString as Any? ?? NSNull(), "playing":workspace.playing, "backdropEnabled":workspace.backdropEnabled, "backdropID":workspace.backdropID?.uuidString as Any? ?? NSNull(), "time":renderer.time, "gpuMS":renderer.gpuMS, "frames":renderer.renderedFrames, "droppedFrames":renderer.droppedFrames, "file":workspace.fileURL?.path as Any? ?? NSNull(), "dirty":workspace.dirty, "status":Dictionary(uniqueKeysWithValues:renderer.status.map { ($0.key.uuidString,$0.value) }), "outputs":["window":true,"syphon":PatchSyphon.available,"ndi":PatchNDI.available]]
    }
    func route(_ method: String, _ path: String, _ data: Data) throws -> [String: Any] {
        if let forwarded = try forwardRoute?(method,path,data) { return forwarded }
        if method == "POST", path == "/v1/commands", let c = try JSONSerialization.jsonObject(with:data) as? [String:Any], let result = try tabCommand?(c) { return result }
        if restarting && method != "GET" { throw GraphError("Patch is restarting") }
        if let result = try portRoute(method,path,data) { return result }
        if let result = try liveRoute(method,path,data) { return result }
        if method == "GET", path == "/v1/outputs" { return ["sources":renderer.publishedOutputs] }
        if method == "GET", path == "/v1/palettes" { return ["sources":paletteSources] }
        if method == "GET", path == "/v1/midi/hooks" { return ["hooks":workspace.midi?.controlHooks ?? [],"graphRevision":revision(),"channelNumbering":"zero-based","editEndpoint":"POST /v1/commands"] }
        if method == "GET",path.hasPrefix("/v1/subpatches/"),let id = UUID(uuidString:String(path.dropFirst("/v1/subpatches/".count))) {
            return ["template":try JSONSerialization.jsonObject(with:JSONEncoder().encode(workspace.graph.subpatchTemplate(id))),"graphRevision":revision()]
        }
        if method == "GET", path == "/v1/state" { return try stateObject() }
        if method == "GET",path.hasPrefix("/v1/voltage/"),path.hasSuffix("/samples") {
            let parts=path.split(separator:"/")
            guard parts.count==4,let id=UUID(uuidString:String(parts[2])),let scope=renderer.voltageScope(id) else { throw GraphError("Choose an active Voltage Visualizer") }
            let history=renderer.audioGraph.oscilloscopeSamples(scope.source,seconds:scope.seconds)
            return ["node":id.uuidString,"sampleRate":history.rate,"trailMS":scope.seconds*1000,"drawRate":scope.rate,"count":history.points.count,"sampleStride":1,"points":history.points.map { [$0.x,$0.y] }]
        }
        if method == "GET", path == "/v1/schema" {
            return ["instancePorts":"GET /v1/nodes/{id}/ports","connectionOptions":"POST /v1/connections/options","projectVersion":Graph.currentVersion,"midiOutputDevices":MIDIOutputDevice.devices.map { ["id":$0.id,"name":$0.name] },"meshPresets":MeshGradientStyle.presets.enumerated().map { ["index":$0.offset,"name":$0.element.name,"source":$0.element.source,"author":$0.element.author] as [String:Any] },"meshDetail":"update.text accepts JSON {paths:{region:[[x,y,hardness]]},stops:{region:[[position,packedRGB,opacity]]}}. Paths use canvas-long-side units relative to the region pivot.","midiHooks":"GET /v1/midi/hooks","liveAPI":["catalog":"GET /v1/catalog","install":"POST /v1/effects","stage":"POST /v1/branches","job":"GET /v1/jobs/{id}","commit":"POST /v1/branches/{id}/commit","protection":"Active output dependencies are protected. Intentional changes require allowLiveChanges:true and expectedRevision."],"microphoneAuthorization":([0:"notDetermined",1:"restricted",2:"denied",3:"authorized"][AVCaptureDevice.authorizationStatus(for:.audio).rawValue] ?? "unknown"),"hardwareAudioDevices":HardwareAudioDevice.devices.map { ["id":$0.id,"name":$0.name,"inputs":$0.inputs,"outputs":$0.outputs] as [String:Any] },"projectorDisplays":NSScreen.screens.map { ["id":$0.patchDisplayID,"name":$0.localizedName] },"audioInputDevices":MicrophoneSource.devices.map { ["id":$0.uniqueID,"name":$0.localizedName] },"userNodeFolder":UserNodeLibrary.directory.path,"userNodes":UserNodeLibrary.shared.entries.map { ["name":$0.title,"kind":$0.kind.rawValue,"file":$0.file!.path] },"poseKeypoints":PosePoint.names,"version":1,"publishedOutputs":"GET /v1/outputs","portTypes":PortType.allCases.map(\.rawValue),"nodes":try NodeKind.allCases.map { kind -> [String:Any] in
                ["midiParameters":kind.parameters.filter(\.supportsMIDI).map(\.key),"modulatableParameters":kind.modulatableParameters.map(\.key),"preview":kind.previewKind.rawValue,"kind":kind.rawValue,"title":kind.title,"category":kind.category,"inputs":try JSONSerialization.jsonObject(with:JSONEncoder().encode(kind.ports(output:false))),"outputs":try JSONSerialization.jsonObject(with:JSONEncoder().encode(kind.ports(output:true))),"output":kind.outputType?.rawValue as Any? ?? NSNull(),"parameters":try JSONSerialization.jsonObject(with:JSONEncoder().encode(kind.parameters))]
            }, "apps":"Node apps (Poster Editor…) expose their own operations: GET /v1/apps/{nodeID} lists ops and state; POST /v1/apps/{nodeID} takes {op,…} or {commands:[…]} with the same expectedRevision/allowLiveChanges rules, applied as one undo step.", "commands":(onRestart == nil ? [] : ["restart"]) + ["liquid_reset","tab_new","tab_select","tab_start","tab_stop","tab_close","metro_action","metro_snapshot","metro_revert","plugin_editor","plugin_retry","frame","publish","apc_window","apc_control","midi_panic","midi_device","midi_learn","midi_bind","midi_update","midi_unbind","midi_clear","midi_follow","library_refresh","mesh_preset","mesh_import","mesh_add","mesh_remove","mesh_duplicate","palette","modulate","unmodulate","add","remove","connect","disconnect","parameter","update","replace","select","play","pause","backdrop","view","preview","preview_pin","preview_close","preview_snapshot","component","subpatch_extract","subpatch_instance","subpatch_interface","component_toggle","ungroup","layout","record_start","record_stop","record_save","record_discard","save","open","snapshot"], "transaction":"Send an array of graph commands to apply atomically."]
        }
        if path.hasPrefix("/v1/apps/") { return try appRoute(method,String(path.dropFirst("/v1/apps/".count)),data) }
        guard method == "POST", path == "/v1/commands" else { throw GraphError("Unknown route. Use GET /v1/state, GET /v1/schema, POST /v1/commands or /v1/apps/{nodeID}.") }
        let body = try JSONSerialization.jsonObject(with:data)
        let envelope = body as? [String:Any] ?? [:]
        if let command=body as? [String:Any],let op=command["op"] as? String,["plugin_editor","plugin_retry"].contains(op) {
            let id=try uuid(command,"id")
            guard workspace.graph.node(id)?.kind == .audioPlugin else { throw GraphError("Expected a VST3 Effect node") }
            if op == "plugin_editor" { workspace.plugins.openEditor(id) } else { workspace.plugins.retry(id) }
            return ["ok":true]
        }
        if let commands = body as? [[String:Any]] ?? envelope["commands"] as? [[String:Any]] {
            guard !commands.isEmpty, commands.count <= 256 else { throw GraphError("Expected 1–256 graph commands") }
            var next = workspace.graph, results: [[String:Any]] = []
            try checkRevision(envelope)
            for command in commands { results.append(try graphCommand(command, graph:&next)) }
            next = try next.validated(); try protect(next,command:envelope)
            try workspace.apply(next,action:"API Transaction")
            return ["results":results,"graphRevision":revision()]
        }
        guard let command = body as? [String: Any], let op = command["op"] as? String else { throw GraphError("Expected a JSON command object with op.") }
        try checkRevision(command)
        if let result = try midiRuntimeCommand(command) { return result }
        switch op {
        case "restart":
            try protectTransport(command)
            guard let onRestart else { throw GraphError("Restart is unavailable") }
            guard let path = command["appPath"] as? String, path.hasPrefix("/") else { throw GraphError("appPath must be an absolute application path") }
            workspace.finishPendingGesture()
            let session = try onRestart(URL(fileURLWithPath:path),stateObject())
            restarting = true
            return ["ok":true,"session":session.path]
        case "library_refresh":
            let job = try newJob(); job.state = "refreshing"
            UserNodeLibrary.shared.refresh { job.state = "ready"; job.result = ["count":UserNodeLibrary.shared.entries.count] }
            return job.object
        case "frame": onFrame?()
        case "select": let id = try uuid(command,"id"); guard workspace.graph.node(id) != nil || workspace.graph.component(id) != nil else { throw GraphError("Unknown node") }; workspace.selected = id
        case "backdrop":
            if command["id"] != nil { let id = try uuid(command,"id"); guard workspace.graph.node(id) != nil else { throw GraphError("Unknown node") }; workspace.backdropID = id }
            workspace.backdropEnabled = command["enabled"] as? Bool ?? true
        case "apc_window":
            let id = try uuid(command,"id")
            guard workspace.graph.node(id)?.kind == .apc40,let open = workspace.onAPCWindow else { throw GraphError("APC40 window unavailable") }
            open(id)
        case "preview_pin", "preview_close":
            let id=try uuid(command,"id")
            guard workspace.graph.node(id) != nil else { throw GraphError("Unknown node") }
            if command["op"] as? String == "preview_pin" { workspace.onPinnedPreview?(id) }
            else { workspace.onClosePinnedPreview?(id) }
        case "preview_snapshot":
            // The window's controls and overlays; Metal views draw empty, so pair with `snapshot`.
            let id=try uuid(command,"id")
            guard let path=command["path"] as? String,path.hasPrefix("/") else { throw GraphError("Missing absolute path") }
            guard let capture=pinnedPreviewSnapshot else { throw GraphError("Pinned windows unavailable") }
            try capture(id,URL(fileURLWithPath:path))
        case "preview":
            if command["id"] != nil { let id = try uuid(command,"id"); guard workspace.graph.node(id) != nil || workspace.graph.component(id) != nil else { throw GraphError("Unknown node") }; workspace.selected = id }
            if let enabled = command["enabled"] as? Bool { if enabled != workspace.previewVisible { workspace.onPreview?() } } else { workspace.onPreview?() }
        case "metro_action":
            let id=try uuid(command,"id")
            guard workspace.graph.node(id)?.kind == .metroSequencer else { throw GraphError("Choose a Metro node") }
            let action=command["action"] as? String ?? ""
            guard ["reset","accumReset","loop","release"].contains(action) else { throw GraphError("Metro action: reset, accumReset, loop or release") }
            let track=command["track"] as? Int ?? 0,start=command["start"] as? Int ?? 0,end=command["end"] as? Int ?? 0
            guard (0...1).contains(track),(0...7).contains(start),(0...7).contains(end) else { throw GraphError("Track must be 0–1 and stage endpoints 0–7") }
            renderer.midiGraph.metroAction(id,action:action,track:track,start:start,end:end)
        case "midi_panic":
            let id=command["id"] == nil ? nil:try uuid(command,"id")
            if let id,workspace.graph.node(id)?.kind != .midiOut { throw GraphError("Choose a MIDI Out node") }
            renderer.midiGraph.panic(id)
        case "record_save": try renderer.saveRecording(try uuid(command,"id"),to:fileURL(command),replace:command["replace"] as? Bool ?? false)
        case "record_discard": try renderer.discardRecording(try uuid(command,"id"))
        case "record_start": try renderer.startRecording(try uuid(command,"id"))
        case "record_stop": renderer.stopRecording(try uuid(command,"id"))
        case "play": try protectTransport(command); workspace.playing = true
        case "pause": try protectTransport(command); workspace.playing = false
        case "view": let id = try uuid(command,"id"); guard workspace.graph.node(id) != nil else { throw GraphError("Unknown node") }; workspace.onOpenOutput?(id)
        case "save": try workspace.write(to: fileURL(command))
        case "open":
            if let onOpenProject { try onOpenProject(fileURL(command)); return ["ok":true] }
            try protectTransport(command)
            guard !workspace.dirty || command["discardChanges"] as? Bool == true else { throw GraphError("Save the current graph first or set discardChanges:true.") }
            try workspace.load(fileURL(command))
        case "snapshot": try renderer.snapshot(try uuid(command,"id"),to:fileURL(command))
        default:
            var next = workspace.graph
            let result = try graphCommand(command,graph:&next)
            next = try next.validated(); try protect(next,command:command)
            try workspace.apply(next,action:"API \(op)")
            return result.merging(["graphRevision":revision()]) { _,new in new }
        }
        return ["ok":true]
    }
    func graphCommand(_ c: [String:Any], graph: inout Graph) throws -> [String:Any] {
        guard let op = c["op"] as? String else { throw GraphError("Missing op") }
        if let result = try midiGraphCommand(c,graph:&graph) { return result }
        if ["connect","disconnect","modulate","publish"].contains(op), c["input"] != nil || c["output"] != nil {
            throw GraphError("Use inputID or outputID to select a port.")
        }
        func port(_ field: String, keys: [String]) throws -> Int {
            guard !keys.isEmpty else { throw GraphError("No "+field+" ports") }
            guard let value = c[field+"ID"] else { return 0 }
            guard let id = value as? String, let index = keys.firstIndex(of:id) else { throw GraphError("Unknown "+field+"ID") }
            return index
        }
        func endpoint(_ owner: UUID, output: Bool) throws -> (node: UUID,index: Int) {
            let field = output ? "output":"input"
            if let group = graph.component(owner),let interface = group.interface {
                let ports = interface.ports.filter { $0.output == output }
                let index = try port(field,keys:ports.map { $0.id.uuidString })
                return try graph.resolveSubpatchPort(group,id:ports[index].id,output:output)
            }
            guard let node = graph.node(owner) else { throw GraphError("Unknown node") }
            return (owner,try port(field,keys:node.ports(output:output).map(\.id)))
        }
        func parameter(_ owner: UUID,key: String) throws -> (node: UUID,key: String) {
            guard let group = graph.component(owner) else { return (owner,key) }
            guard let address = group.interface?.parameters.first(where:{ $0.id == UUID(uuidString:key) }) else { throw GraphError("Unknown subpatch parameter") }
            return (address.node,address.key)
        }
        switch op {
        case "publish":
            let id = try uuid(c,"id")
            guard let node = graph.node(id) else { throw GraphError("Unknown node") }
            let keys = node.publishablePortIDs
            let index = try port("output",keys:keys)
            try graph.publish(id,portID:keys[index],mode:c["mode"] as? String ?? "auto",name:c["name"] as? String)
        case "modulate":
            guard let key = c["key"] as? String else { throw GraphError("Missing parameter key") }
            let source = try endpoint(uuid(c,"source"),output:true), target = try parameter(uuid(c,"target"),key:key)
            try graph.modulate(target.node,key:target.key,source:source.node,minimum:c["minimum"] as? Double,maximum:c["maximum"] as? Double,enabled:c["enabled"] as? Bool ?? true,output:source.index)
        case "unmodulate":
            guard let key = c["key"] as? String else { throw GraphError("Missing parameter key") }
            let target = try parameter(uuid(c,"target"),key:key)
            guard let i = graph.nodes.firstIndex(where:{ $0.id == target.node }) else { throw GraphError("Unknown node") }
            graph.nodes[i].modulations?.removeValue(forKey:target.key)
        case "subpatch_extract":
            let ids: Set<UUID>
            if c["id"] != nil { ids = [try uuid(c,"id")] }
            else {
                guard let strings = c["nodes"] as? [String] else { throw GraphError("Expected member IDs") }
                ids = try Set(strings.map { value in
                    guard let id = UUID(uuidString:value) else { throw GraphError("Invalid member UUID") }
                    return id
                })
            }
            return ["id":try graph.extractSubpatch(ids,name:c["name"] as? String).uuidString]
        case "subpatch_instance":
            let template: SubpatchTemplate
            if let object = c["template"] as? [String:Any] { template = try SubpatchTemplate.read(JSONSerialization.data(withJSONObject:object)) }
            else { template = try graph.subpatchTemplate(uuid(c,"id")) }
            let at = Position(c["x"] as? Double ?? template.component.position.x+280,c["y"] as? Double ?? template.component.position.y)
            return ["id":try graph.instantiate(template,at:at,includeMIDI:c["includeMIDI"] as? Bool ?? false,enableOutputs:c["enableOutputs"] as? Bool ?? false).uuidString]
        case "subpatch_interface":
            guard let value = c["interface"] as? [String:Any] else { throw GraphError("Expected subpatch interface") }
            let interface = try JSONDecoder().decode(SubpatchInterface.self,from:JSONSerialization.data(withJSONObject:value))
            try graph.editInterface(uuid(c,"id")) { $0 = interface }
        case "component":
            guard let strings = c["nodes"] as? [String], strings.allSatisfy({ UUID(uuidString:$0) != nil }) else { throw GraphError("nodes must be an array of UUIDs") }
            let id = try graph.makeComponent(Set(strings.compactMap(UUID.init(uuidString:))))
            if let name = c["name"] as? String, let i = graph.components?.firstIndex(where:{ $0.id == id }) { graph.components![i].name = name }
            return ["id":id.uuidString]
        case "component_toggle":
            let id = try uuid(c,"id"); guard let i = graph.components?.firstIndex(where:{ $0.id == id }) else { throw GraphError("Unknown component") }; graph.components![i].collapsed.toggle()
        case "ungroup": let id = try uuid(c,"id"); graph.components?.removeAll { $0.id == id }
        case "layout": try graph.autoLayout()
        case "add":
            let catalog = (c["catalogID"] as? String).flatMap { id in CatalogNode.all.first { $0.id == id } }
            if c["catalogID"] != nil && catalog == nil { throw GraphError("Unknown catalogID. Refresh the library and read /v1/catalog.") }
            guard let kind = catalog?.kind ?? (c["kind"] as? String).flatMap(NodeKind.init(rawValue:)) else { throw GraphError("Unknown node kind") }
            let id = c["id"] == nil ? UUID() : try uuid(c,"id")
            guard graph.node(id) == nil else { throw GraphError("Duplicate node ID") }
            var node = Node(kind:kind, position:.init(c["x"] as? Double ?? 120,c["y"] as? Double ?? 160),id:id)
            node.fieldParameters = catalog?.fieldParameters
            if let declaration = c["fieldParameters"] {
                guard kind == .fieldShader, catalog == nil else { throw GraphError("Set fieldParameters on a standalone Field Shader or use its catalog definition") }
                node.fieldParameters = try JSONDecoder().decode([ParameterSpec].self,from:JSONSerialization.data(withJSONObject:declaration))
                try ParameterSpec.validateShaderParameters(node.fieldParameters ?? [])
            }
            node.file = catalog?.file?.path; node.controlStyle = catalog?.controlStyle; node.name = catalog?.title ?? kind.title
            if let enabled = c["enabled"] as? Bool { node.enabled = enabled }
            if let name = c["name"] as? String { node.name = name }
            if let path = c["file"] as? String { node.file = path }
            if let text = c["text"] as? String { node.text = text }
            if let device = c["deviceID"] as? String { node.deviceID = device }
            node.name = graph.availableName(node.name)
            if c["parameters"] != nil && !(c["parameters"] is [String:Double]) { throw GraphError("Parameters must be numeric values") }
            if let colors=c["colors"] {
                guard kind == .palette else { throw GraphError("colors is only supported on Palette source nodes") }
                node.palette=try JSONDecoder().decode(ColorPalette.self,from:JSONSerialization.data(withJSONObject:["colors":colors]))
            }
            graph.nodes.append(node)
            graph = graph.resolvingBlindsControls()
            if let values = c["parameters"] as? [String:Double] { for (key,value) in values { try setUserParameter(&graph,id:id,key:key,value:value) } }
            return ["id":id.uuidString,"name":node.name,"streamName":node.streamName]
        case "liquid_reset":
            let id=try uuid(c,"id")
            guard let i=graph.nodes.firstIndex(where:{$0.id==id}),graph.nodes[i].hasLiquidSculptureControls else { throw GraphError("Choose a Liquid Metal or Liquid Chrome node") }
            if graph.nodes[i].hasLiquidChromeControls { LiquidChromeStyle.reset(&graph.nodes[i]) } else { LiquidMetalStyle.reset(&graph.nodes[i]) }
        case "remove":
            let id = try uuid(c,"id")
            guard graph.node(id) != nil || graph.component(id) != nil else { throw GraphError("Unknown node or component") }
            graph.remove(id)
        case "connect":
            let source = try endpoint(uuid(c,"source"),output:true),target = try endpoint(uuid(c,"target"),output:false)
            try graph.connect(source.node,to:target.node,input:target.index,output:source.index)
        case "disconnect":
            let target = try endpoint(uuid(c,"target"),output:false)
            guard graph.node(target.node)?.inputs.indices.contains(target.index) == true else { throw GraphError("Unknown target or input") }
            graph.edges.removeAll { $0.target == target.node && $0.input == target.index }
        case "palette":
            let id=try uuid(c,"id")
            guard let colors=c["colors"] else { throw GraphError("Expected colors: an ordered array of sRGB {r,g,b} objects") }
            let data=try JSONSerialization.data(withJSONObject:["colors":colors])
            let palette=try JSONDecoder().decode(ColorPalette.self,from:data)
            try graph.setPalette(id,colors:palette.colors)
        case "mesh_preset", "mesh_import", "mesh_add", "mesh_remove", "mesh_duplicate":
            let id=try uuid(c,"id")
            guard let i=graph.nodes.firstIndex(where:{$0.id==id}),graph.nodes[i].kind == .meshGradient else { throw GraphError("Expected Mesh Gradient node") }
            switch op {
            case "mesh_preset":
                guard let preset=c["preset"] as? Int else { throw GraphError("Expected preset index") }
                try MeshGradientStyle.applyPreset(preset,to:&graph.nodes[i])
            case "mesh_import":
                guard let config=c["config"] as? [String:Any] else { throw GraphError("Expected mmeshy config") }
                try MeshGradientStyle.importConfig(config,to:&graph.nodes[i])
            case "mesh_add":
                let shape=c["shape"] as? Int ?? 0
                guard (0...3).contains(shape) else { throw GraphError("Unknown mesh shape") }
                let x=c["x"] as? Double ?? 0.5,y=c["y"] as? Double ?? 0.5
                guard x.isFinite,y.isFinite,(-2...3).contains(x),(-2...3).contains(y) else { throw GraphError("Invalid mesh position") }
                let region=try MeshGradientStyle.addRegion(to:&graph.nodes[i],shape:shape,position:.init(x,y))
                return ["ok":true,"region":region]
            case "mesh_remove":
                guard let regions=c["regions"] as? [Int] else { throw GraphError("Expected region indices") }
                try graph.removeMeshRegions(Set(regions),node:id)
            default:
                guard let region=c["region"] as? Int else { throw GraphError("Expected region index") }
                let target=try MeshGradientStyle.duplicateRegion(region,in:&graph.nodes[i]);return ["ok":true,"region":target]
            }
        case "metro_snapshot", "metro_revert":
            let id=try uuid(c,"id")
            guard let i=graph.nodes.firstIndex(where:{ $0.id==id && $0.kind == .metroSequencer }) else { throw GraphError("Choose a Metro node") }
            if c["op"] as? String == "metro_snapshot" { graph.nodes[i].metroSnapshot=graph.nodes[i].parameters }
            else if let saved=graph.nodes[i].metroSnapshot { graph.nodes[i].parameters=saved }
            else { throw GraphError("Take a Metro snapshot first") }
        case "parameter":
            guard let key = c["key"] as? String else { throw GraphError("Expected a parameter key") }
            let address = try parameter(uuid(c,"id"),key:key)
            guard let node = graph.node(address.node) else { throw GraphError("Unknown parameter target") }
            let value: Double
            if let number = c["value"] as? Double { value = number }
            else if let label = c["value"] as? String,
                    let spec = node.parameterSpecs.first(where:{ $0.key == address.key }),
                    let index = spec.choices?.firstIndex(of:label) { value = spec.min + Double(index) }
            else { throw GraphError("Expected a number or a declared choice for "+address.key) }
            try setUserParameter(&graph,id:address.node,key:address.key,value:value)
        case "update":
            let id = try uuid(c,"id")
            if let i = graph.components?.firstIndex(where:{ $0.id == id }) {
                guard let name = c["name"] as? String,
                      Set(c.keys).isSubset(of:["op","id","name","expectedRevision","allowLiveChanges"]) else { throw GraphError("Component update accepts a name") }
                graph.components![i].name = name
                return ["ok":true]
            }
            guard let i = graph.nodes.firstIndex(where:{$0.id==id}) else { throw GraphError("Unknown node") }
            if let name = c["name"] as? String { graph.nodes[i].name = name }
            if let text = c["text"] as? String { graph.nodes[i].text = text }
            if let poster = c["poster"] as? [String:Any] { graph.nodes[i].poster = try JSONDecoder().decode(PosterLayout.self,from:JSONSerialization.data(withJSONObject:poster)) }
            if c["poster"] is NSNull { graph.nodes[i].poster = nil }
            if let device = c["deviceID"] as? String { graph.nodes[i].deviceID = device }
            if c["deviceID"] is NSNull { graph.nodes[i].deviceID = nil }
            if let file = c["file"] as? String { graph.nodes[i].file = file; if !graph.nodes[i].hasBlindsControls && !graph.nodes[i].hasLiquidSculptureControls && !graph.nodes[i].hasFerrofluidControls { graph.nodes[i].controlStyle = nil }; graph = graph.resolvingBlindsControls() }
            if c["file"] is NSNull { graph.nodes[i].file = nil }
            if let enabled = c["enabled"] as? Bool { graph.nodes[i].enabled = enabled }
            if let x = c["x"] as? Double { graph.nodes[i].position.x = x }
            if let y = c["y"] as? Double { graph.nodes[i].position.y = y }
        case "replace":
            guard let object = c["graph"] else { throw GraphError("Missing graph") }
            graph = try Graph.read(JSONSerialization.data(withJSONObject:object))
        default: throw GraphError("Unknown graph command: \(op)")
        }
        return ["ok":true]
    }
    private func setUserParameter(_ graph: inout Graph,id: UUID,key: String,value: Double) throws {
        if graph.node(id)?.isBlinds == true, let spec = BlindsControls.specs.first(where:{ $0.key == key }) {
            guard value.isFinite, value >= spec.min, value <= spec.max, !(spec.choices != nil || ["count","seed","gradientStart","gradientEnd"].contains(key)) || value.rounded() == value else { throw GraphError("Invalid Blinds \(key)") }
            let stored = BlindsControls.storage(key,value)
            try graph.setParameter(id,key:stored.0,value:stored.1)
        } else { try graph.setParameter(id,key:key,value:value) }
    }
    private func uuid(_ c: [String:Any], _ key: String) throws -> UUID {
        guard let raw = c[key] as? String, let id = UUID(uuidString:raw) else { throw GraphError("\(key) must be a UUID") }; return id
    }
    /// A node app's API. POST takes one `{op,…}` or `{commands:[…]}`; the batch
    /// runs on a draft and applies as one undo step under live protection.
    private func appRoute(_ method: String,_ id: String,_ data: Data) throws -> [String:Any] {
        guard let id = UUID(uuidString:id),let node = workspace.graph.node(id) else { throw GraphError("Unknown node") }
        guard let app = NodeApp.for(node),let api = app.api else { throw GraphError("\(node.kind.title) has no app API") }
        let draft = GraphDraft(workspace.graph)
        let context = NodeAppAPI.Context(document:draft,workspace:workspace,renderer:renderer,id:id)
        if method == "GET" { return ["app":app.title,"commands":api.commands,"state":try api.state(context),"graphRevision":revision()] }
        guard method == "POST",let body = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw GraphError("Expected a JSON object: {op,…} or {commands:[…]}") }
        let commands = body["commands"] as? [[String:Any]] ?? [body]
        guard !commands.isEmpty,commands.count <= 256 else { throw GraphError("Expected 1–256 commands") }
        try checkRevision(body)
        var results: [[String:Any]] = []
        for (index,command) in commands.enumerated() {
            guard let op = command["op"] as? String,api.commands[op] != nil else { throw GraphError("Command \(index): unknown op. Ops: \(api.commands.keys.sorted().joined(separator:", "))") }
            do { results.append(try api.run(context,command)) } catch { throw GraphError("Command \(index) (\(op)): \(error.localizedDescription)") }
            if let error = draft.error { throw GraphError("Command \(index) (\(op)): \(error.localizedDescription)") }
        }
        let next = try draft.graph.validated()
        try protect(next,command:body)
        let ops = Set(commands.compactMap { $0["op"] as? String }).sorted().joined(separator:", ")
        try workspace.apply(next,action:"\(app.title): \(ops)")
        return ["results":results,"graphRevision":revision()]
    }
    private func fileURL(_ c: [String:Any]) throws -> URL {
        guard let path = c["path"] as? String, path.hasPrefix("/") else { throw GraphError("path must be an absolute file path") }; return URL(fileURLWithPath:path)
    }
}
private final class HTTPRequest {
    typealias Reply = (Int,[String:Any]) -> Void
    let connection: NWConnection
    let queue: DispatchQueue
    let handler: (String,String,[String:String],Data,@escaping Reply)->Void
    var bytes = Data()
    var finished = false
    var responded = false
    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping (String,String,[String:String],Data,@escaping Reply)->Void) { self.connection = connection; self.queue = queue; self.handler = handler }
    func start() {
        connection.start(queue:queue)
        queue.asyncAfter(deadline:.now()+8) { [weak self] in if self?.responded == false { self?.finish(408,["error":"Request timed out"]) } }
        read()
    }
    func read() {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [self] data,_,complete,error in
            if let data { bytes.append(data) }
            guard !finished else { return }
            if bytes.count > 2_097_152 { finish(413,["error":"Request too large"]); return }
            if let range = bytes.range(of:Data("\r\n\r\n".utf8)) {
                guard range.lowerBound < 16_384, let header = String(data:bytes[..<range.lowerBound],encoding:.utf8) else { finish(400,["error":"Invalid headers"]); return }
                let lines = header.components(separatedBy:"\r\n"), first = lines[0].split(separator:" ")
                guard first.count == 3 else { finish(400,["error":"Invalid HTTP request"]); return }
                var headers: [String:String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator:":",maxSplits:1)
                    guard parts.count == 2 else { finish(400,["error":"Invalid header"]); return }
                    let key = parts[0].lowercased()
                    guard headers[key] == nil else { finish(400,["error":"Duplicate header"]); return }
                    headers[key] = parts[1].trimmingCharacters(in:.whitespaces)
                }
                guard headers["transfer-encoding"] == nil, let size = Int(headers["content-length"] ?? "0"), size >= 0, size < 2_080_000 else { finish(400,["error":"Invalid content length or unsupported transfer encoding"]); return }
                let body = bytes[range.upperBound...]
                if body.count >= size {
                    finished = true
                    handler(String(first[0]),String(first[1]),headers,Data(body.prefix(size))) { [self] code,result in queue.async { self.finish(code,result) } }
                    return
                }
            } else if bytes.count > 16384 { finish(413,["error":"Headers too large"]); return }
            if complete || error != nil { finish(400,["error":"Incomplete request"]); return }
            read()
        }
    }
    func finish(_ code: Int, _ object: [String:Any]) {
        guard !responded else { return }; responded = true; finished = true
        let body = (try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])) ?? Data("{}".utf8)
        let reason = code == 200 ? "OK" : "Error"
        var response = Data("HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(body)
        connection.send(content:response,completion:.contentProcessed { [connection] _ in connection.cancel() })
    }
}
