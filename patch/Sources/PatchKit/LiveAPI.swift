import Foundation
import CryptoKit
import Metal
import PatchCore

final class LiveJob {
    let id = UUID().uuidString
    var state = "queued"
    var result: [String:Any] = [:]
    var error: String?
    var graph: Graph?
    var baseRevision = ""
    var files: [String:String] = [:]
    var pipelines: [UUID:ShaderResource] = [:]
    var object: [String:Any] { ["id":id,"state":state,"result":result,"error":error as Any? ?? NSNull()] }
}

extension ControlAPI {
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    func revision(_ graph: Graph? = nil) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Self.digest((try? encoder.encode(graph ?? workspace.graph)) ?? Data())
    }
    func checkRevision(_ command: [String:Any], required: Bool = false) throws {
        if required || command["expectedRevision"] != nil {
            guard command["expectedRevision"] as? String == revision() else { throw GraphError("Revision conflict. Read /v1/state and retry with its graphRevision.") }
        }
    }
    func protect(_ next: Graph, command: [String:Any]) throws {
        try checkRevision(command)
        if workspace.graph.midiMappings != next.midiMappings { try protectTransport(command) }
        let affected = workspace.graph.liveImpact(of:next)
        guard !affected.isEmpty else { return }
        guard command["allowLiveChanges"] as? Bool == true else {
            throw GraphError("Live output protected. This changes upstream nodes or an active output: \(affected.map(\.uuidString).joined(separator:", ")). Use allowLiveChanges:true and expectedRevision for an intentional edit.")
        }
        try checkRevision(command,required:true)
    }
    func protectTransport(_ command: [String:Any]) throws {
        if !workspace.graph.liveDependencies.isEmpty {
            guard command["allowLiveChanges"] as? Bool == true else { throw GraphError("Live output protected. Transport/project changes require allowLiveChanges:true and expectedRevision.") }
            try checkRevision(command,required:true)
        }
    }
    func catalogObject() throws -> [String:Any] {
        let entries = CatalogNode.all
        return ["effects":try entries.map { entry -> [String:Any] in
            ["id":entry.id,"name":entry.title,"kind":entry.kind.rawValue,"category":entry.category,
             "file":entry.file?.path as Any? ?? NSNull(),
             "controlStyle":entry.controlStyle as Any? ?? NSNull(),
             "controls":try JSONSerialization.jsonObject(with:JSONEncoder().encode(entry.controlStyle == "blinds" ? BlindsControls.specs : [])),
             "inputs":try JSONSerialization.jsonObject(with:JSONEncoder().encode(entry.kind.ports(output:false))),
             "outputs":try JSONSerialization.jsonObject(with:JSONEncoder().encode(entry.kind.ports(output:true))),
             "parameters":try JSONSerialization.jsonObject(with:JSONEncoder().encode(entry.parameterSpecs))]
        },"libraryIssues":UserNodeLibrary.shared.diagnostics,"graphRevision":revision(),"refresh":"POST /v1/commands {op: library_refresh}"]
    }
    func newJob() throws -> LiveJob {
        guard jobs.values.filter({ ["queued","compiling","refreshing"].contains($0.state) }).count < 4 else { throw GraphError("Compile queue full; wait for a running job.") }
        guard jobs.count < 32 else { throw GraphError("Job limit reached. DELETE completed /v1/jobs/{id} records before submitting more.") }
        let job = LiveJob(); jobs[job.id] = job; return job
    }
    func installEffect(_ body: [String:Any]) throws -> [String:Any] {
        guard let source = body["source"] as? String, !source.isEmpty, source.utf8.count <= 131072,
              let name = body["name"] as? String, !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.count <= 100,
              let raw = body["kind"] as? String, let kind = NodeKind(rawValue:raw),
              [.meshGradient,.dotColors,.flipDots,.projectionDots,.shader,.shaderEffect,.scene,.fieldShader,.cellularField,.waterfallField,.streakField,.blockerField,.dataStream].contains(kind) else {
            throw GraphError("Expected name (1–100 characters), kind (meshGradient, dotColors, flipDots, projectionDots, shader, shaderEffect, scene or a field kind), and source (up to 128 KiB).")
        }
        var fieldParameters: [ParameterSpec]?
        if let declaration = body["parameters"] {
            guard [.fieldShader,.shaderEffect].contains(kind),body["controlStyle"] == nil else { throw GraphError("Declare parameters for a Field Shader or a Shader Effect without a built-in control style") }
            fieldParameters = try JSONDecoder().decode([ParameterSpec].self,from:JSONSerialization.data(withJSONObject:declaration))
            try ParameterSpec.validateShaderParameters(fieldParameters ?? [])
        }
        let declaredParameters = fieldParameters
        let controlStyle = body["controlStyle"] as? String
        if body["controlStyle"] != nil && !(controlStyle == "metallicPool" && kind == .scene) && (!["blinds","liquidMetal","liquidChrome","ferrofluid"].contains(controlStyle ?? "") || kind != .shaderEffect) { throw GraphError("Supported controlStyle: blinds, liquidMetal, liquidChrome or ferrofluid for shaderEffect") }
        let parameterTitles = body["parameterTitles"] as? [String:String] ?? [:]
        if body["parameterTitles"] != nil {
            let keys = Set((declaredParameters ?? (controlStyle == "metallicPool" ? MetallicPoolStyle.parameters : controlStyle == "liquidMetal" ? LiquidMetalStyle.parameters : controlStyle == "liquidChrome" ? LiquidChromeStyle.parameters : controlStyle == "ferrofluid" ? FerrofluidStyle.parameters : controlStyle == "blinds" ? BlindsStyle.parameters : kind.parameters)).map(\.key))
            guard body["parameterTitles"] is [String:String], parameterTitles.allSatisfy({ keys.contains($0.key) && !$0.value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.value.count <= 100 }) else {
                throw GraphError("parameterTitles must map parameter keys to nonempty names (up to 100 characters).")
            }
        }
        let job = try newJob(); job.state = "compiling"
        let device = renderer.device
        compileQueue.async {
            do {
                _ = try ShaderCompiler.compile(source,kind:kind,device:device)
                let parent = UserNodeLibrary.directory.appendingPathComponent("Live",isDirectory:true)
                try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
                let staging = parent.appendingPathComponent("."+job.id,isDirectory:true)
                let destination = parent.appendingPathComponent(job.id,isDirectory:true)
                try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
                do {
                    try source.write(to:staging.appendingPathComponent("effect.metal"),atomically:true,encoding:.utf8)
                    var metadata: [String:Any] = ["name":name,"kind":kind.rawValue,"file":"effect.metal","parameterTitles":parameterTitles]
                    if let declaredParameters { metadata["parameters"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(declaredParameters)) }
                    if let controlStyle { metadata["controlStyle"] = controlStyle }
                    try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]).write(to:staging.appendingPathComponent("effect.json"),options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:staging.appendingPathComponent("effect.metal").path)
                    try FileManager.default.moveItem(at:staging,to:destination)
                } catch { try? FileManager.default.removeItem(at:staging); throw error }
                DispatchQueue.main.async {
                    job.state = "refreshing"
                    UserNodeLibrary.shared.refresh {
                        job.state = "ready"
                        job.result = ["catalogID":destination.appendingPathComponent("effect.metal").path,"name":name,"kind":kind.rawValue,"sourceHash":Self.digest(Data(source.utf8)),"version":job.id]
                    }
                }
            } catch { DispatchQueue.main.async { job.state = "failed"; job.error = error.localizedDescription } }
        }
        return job.object
    }
    func stageBranch(_ body: [String:Any]) throws -> [String:Any] {
        try checkRevision(body)
        guard let commands = body["commands"] as? [[String:Any]], !commands.isEmpty, commands.count <= 128 else { throw GraphError("Expected 1–128 graph commands for the new branch.") }
        var branch = Graph(); branch.width = workspace.graph.width; branch.height = workspace.graph.height; branch.fps = workspace.graph.fps
        var reused: Set<UUID> = []
        if body["reuse"] != nil {
            guard let values = body["reuse"] as? [String], values.count <= 32 else { throw GraphError("reuse must list existing source node UUIDs") }
            var pending: [UUID] = []
            for value in values {
                guard let id = UUID(uuidString:value), let node = workspace.graph.node(id), node.kind.outputType != nil else { throw GraphError("Unknown reusable source: \(value)") }
                if reused.insert(id).inserted { pending.append(id) }
            }
            while let id = pending.popLast() {
                for edge in workspace.graph.dependencies where edge.target == id {
                    if reused.insert(edge.source).inserted { pending.append(edge.source) }
                }
            }
            branch.nodes = workspace.graph.nodes.filter { reused.contains($0.id) }
            branch.edges = workspace.graph.edges.filter { reused.contains($0.target) }
        }
        let borrowed = branch
        var results: [[String:Any]] = []
        for command in commands {
            guard let op = command["op"] as? String, ["publish","add","connect","parameter","palette","update","modulate","component","layout","mesh_preset","mesh_import","mesh_add","mesh_remove","mesh_duplicate"].contains(op) else { throw GraphError("Unsupported staged graph command. Use add, connect, parameter, palette, update, modulate, component, layout or mesh editing commands.") }
            results.append(try graphCommand(command,graph:&branch))
        }
        branch = try branch.validated()
        for original in borrowed.nodes {
            guard var current = branch.node(original.id) else { throw GraphError("Cannot remove a reused source") }
            current.position = original.position
            guard current == original, branch.edges.filter({ $0.target == original.id }) == borrowed.edges.filter({ $0.target == original.id }) else { throw GraphError("A staged branch cannot modify reused sources; add new processing nodes instead.") }
        }
        let newIDs = Set(branch.nodes.map(\.id)).subtracting(reused)
        guard !newIDs.isEmpty, newIDs.count <= 32, newIDs.isDisjoint(with:workspace.graph.nodes.map(\.id)) else { throw GraphError("A staged branch needs fresh node IDs and at most 32 new nodes.") }
        for node in branch.nodes where newIDs.contains(node.id) {
            for port in node.kind.inputs.indices where node.kind.inputTypes[port] == .video && node.kind != .ledMatrix && node.kind != .blend && node.kind != .pictureInPicture && !node.hasLiquidSculptureControls {
                guard branch.edges.contains(where:{ $0.target == node.id && $0.input == port }) else { throw GraphError("\(node.name): missing input \(port)") }
            }
        }
        var additions = branch
        additions.nodes = branch.nodes.filter { newIDs.contains($0.id) }
        additions.edges = branch.edges.filter { newIDs.contains($0.target) }
        guard additions.groups.allSatisfy({ Set($0.members).isSubset(of:newIDs) }) else { throw GraphError("Components may contain only new nodes") }
        if body["layout"] as? Bool ?? true {
            var layout = additions; layout.edges = layout.edges.filter { newIDs.contains($0.source) }
            try layout.autoLayout(); additions.nodes = layout.nodes; additions.components = layout.components
        }
        let right = workspace.graph.nodes.map { $0.position.x+300 }.max() ?? 0
        let minX = additions.nodes.map(\.position.x).min() ?? 0
        let dx = right+100-minX
        for i in additions.nodes.indices { additions.nodes[i].position.x += dx }
        for i in (additions.components ?? []).indices { additions.components![i].position.x += dx }
        let job = try newJob(); job.baseRevision = revision(); job.state = "compiling"
        let candidate = branch, attachment = additions, device = renderer.device
        compileQueue.async {
            do {
                var hashes: [String:String] = [:]
                for node in candidate.nodes {
                    if let path = ShaderCompiler.sourceURL(node), [.meshGradient,.dotColors,.flipDots,.projectionDots,.shader,.shaderEffect,.scene].contains(node.kind) || node.kind.outputType == .field {
                        let data = try Data(contentsOf:URL(fileURLWithPath:path))
                        guard data.count <= 131072 else { throw GraphError("Shader exceeds the 128 KiB live preflight limit") }
                        hashes[path] = Self.digest(data)
                        if node.kind.outputType == .field { _ = try ShaderCompiler.compile(String(decoding:data,as:UTF8.self),kind:node.kind,device:device) }
                    }
                }
                let pipelines = try ShaderCompiler.prepare(candidate,device:device).filter { newIDs.contains($0.key) }
                for (path,hash) in hashes where Self.digest(try Data(contentsOf:URL(fileURLWithPath:path))) != hash { throw GraphError("Shader changed during preflight; stage again.") }
                DispatchQueue.main.async {
                    job.graph = attachment; job.files = hashes; job.pipelines = pipelines; job.state = "ready"
                    job.result = ["baseRevision":job.baseRevision,"nodes":attachment.nodes.map { ["id":$0.id.uuidString,"name":$0.name,"kind":$0.kind.rawValue,"streamName":$0.streamName] },"results":results,"compiled":true,"rendered":false,"commit":"POST /v1/branches/\(job.id)/commit"]
                }
            } catch { DispatchQueue.main.async { job.state = "failed"; job.error = error.localizedDescription } }
        }
        return job.object
    }
    func commitBranch(_ id: String, body: [String:Any]) throws -> [String:Any] {
        guard let job = jobs[id] else { throw GraphError("Unknown branch") }
        if job.state == "committed" { return job.object }
        guard job.state == "ready", let branch = job.graph else { throw GraphError("Branch is not ready; inspect /v1/jobs/\(id)") }
        guard revision() == job.baseRevision else { throw GraphError("Graph changed since staging. Stage again against the latest session.") }
        try checkRevision(body)
        for (path,hash) in job.files where Self.digest(try Data(contentsOf:URL(fileURLWithPath:path))) != hash { throw GraphError("Shader changed after compilation. Stage again.") }
        var next = workspace.graph
        next.nodes += branch.nodes; next.edges += branch.edges; next.components = next.groups+branch.groups
        next = try next.validated(); try protect(next,command:body)
        // Queue resources and graph together, so no intermediate uncompiled frame is presented.
        let resources = job.pipelines, playing = workspace.playing
        try workspace.apply(next,action:"Add Live Branch")
        renderer.activatePrepared(next,playing:playing,resources:resources)
        job.pipelines.removeAll(); job.graph = nil; job.state = "committed"
        job.result["graphRevision"] = revision(); job.result["rendered"] = false
        job.result["status"] = "Attached. Poll /v1/state for renderer and publisher readiness before switching your compositor."
        return job.object
    }
    func liveRoute(_ method: String, _ path: String, _ data: Data) throws -> [String:Any]? {
        if method == "GET", path == "/v1/catalog" { return try catalogObject() }
        if path.hasPrefix("/v1/jobs/") {
            let id = String(path.dropFirst("/v1/jobs/".count))
            guard let job = jobs[id] else { throw GraphError("Unknown job") }
            if method == "GET" { return job.object }
            if method == "DELETE" {
                guard !["queued","compiling","refreshing"].contains(job.state) else { throw GraphError("Wait for the running job before discarding it") }
                jobs.removeValue(forKey:id); return ["ok":true,"note":"Job discarded; installed files and committed nodes are preserved."]
            }
        }
        if method == "POST", path == "/v1/effects" || path == "/v1/branches" || (path.hasPrefix("/v1/branches/") && path.hasSuffix("/commit")) {
            guard let body = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw GraphError("Expected a JSON object") }
            if path == "/v1/effects" { return try installEffect(body) }
            if path == "/v1/branches" { return try stageBranch(body) }
            return try commitBranch(String(path.dropFirst("/v1/branches/".count).dropLast("/commit".count)),body:body)
        }
        return nil
    }
}
