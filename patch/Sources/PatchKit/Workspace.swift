import AppKit
import Combine
import UniformTypeIdentifiers
import PatchCore

final class Workspace: ObservableObject {
    /// Default folder for project files; personal data stays out of the source tree.
    static var projectsDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projection3000/Patch/Projects",isDirectory:true)
        try? FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    let plugins = AudioPlugins()
    weak var midi: MIDIController?
    @Published private(set) var graph: Graph = .demo
    private var extendingSelection = false
    @Published var selectedIDs: Set<UUID> = []
    @Published var selected: UUID? {
        willSet { if mutationDepth == 0 && newValue != selected { finishPendingGesture() } }
        didSet { dismissLibraryPreview(); if !extendingSelection { selectedIDs = selected.map { [$0] } ?? [] } }
    }
    @Published private(set) var libraryPreview: Workspace?
    private(set) var libraryCatalogID: String?
    private var libraryPreviewObservation: AnyCancellable?
    var libraryPreviewNode: Node? { libraryPreview.flatMap { preview in preview.selected.flatMap { preview.graph.node($0) } } }
    /// Temporary library nodes evaluate beside the real graph, without entering the saved document.
    var renderGraph: Graph {
        guard let preview = libraryPreview else { return graph }
        var result = graph
        let realIDs = Set(graph.nodes.map(\.id))
        result.nodes += preview.graph.nodes.filter { !realIDs.contains($0.id) }
        result.edges += preview.graph.edges.filter { !realIDs.contains($0.target) }
        return result
    }
    func dismissLibraryPreview() {
        guard libraryPreview != nil else { return }
        libraryPreviewObservation = nil; libraryCatalogID = nil; libraryPreview = nil
    }
    func browse(_ entry: CatalogNode) {
        if entry.kind == .apc40, let existing = graph.nodes.first(where:{ $0.kind == .apc40 }) { selected = existing.id; return }
        if libraryCatalogID == entry.id { return }
        finishPendingGesture()
        dismissLibraryPreview()
        var temporary = graph
        var node = Node(kind:entry.kind); node.configureShaderParameters(entry.fieldParameters); node.file = entry.file?.path; node.controlStyle = entry.controlStyle; node.name = entry.title
        // Browsing an output must not open windows, publish streams, or start recording.
        if node.kind.isOutput || node.kind == .webcam || node.kind == .microphone || node.kind == .audioInput { node.enabled = false }
        let selectedNode = graph.previewNode(selected)
        let preferredIDs = [selectedNode?.id,backdropID] + graph.nodes.filter { $0.kind.isOutput && $0.enabled }.map { Optional($0.id) }
        var candidates: [Node] = []
        for id in preferredIDs.compactMap({ $0 }) {
            if let source = graph.node(id),!source.kind.isOutput { candidates.append(source) }
            candidates += graph.edges.filter { $0.target == id }.compactMap { graph.node($0.source) }
        }
        candidates += graph.nodes.reversed().filter { !$0.kind.isOutput && $0.enabled }
        temporary.nodes.append(node)
        var samples: [PortType:Node] = [:]
        for (index,type) in node.kind.inputTypes.enumerated() {
            let source = candidates.first { $0.kind.outputTypes.contains(where:{ type.accepts($0) }) && $0.enabled } ?? samples[type]
            var sample = source
            if sample == nil && (type == .video || type == .geometry || type == .vectorPath) {
                let generated = Node(kind:type == .video ? .pattern : type == .vectorPath ? .vectorShape : .lorenz)
                temporary.nodes.append(generated); samples[type] = generated; sample = generated
            }
            if let sample,let output = sample.kind.outputTypes.firstIndex(where:{ type.accepts($0) }) {
                try? temporary.connect(sample.id,to:node.id,input:index,output:output)
            }
        }
        let preview = Workspace(); preview.graph = temporary; preview.selected = node.id
        preview.playing = playing; preview.dirty = false
        libraryCatalogID = entry.id; libraryPreview = preview
        libraryPreviewObservation = preview.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }
    func select(_ id: UUID,extend: Bool) {
        if !extend { selected = id; return }
        extendingSelection = true
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        selected = selectedIDs.contains(id) ? id : selectedIDs.sorted(by:{ $0.uuidString < $1.uuidString }).first
        extendingSelection = false
    }
    func focusSelection(_ id: UUID) {
        if !selectedIDs.contains(id) { selected = id; return }
        extendingSelection = true; selected = id; extendingSelection = false
    }
    func selectAll(_ ids: [UUID]) {
        extendingSelection = true; selectedIDs = Set(ids); selected = ids.first; extendingSelection = false
    }
    func collapseSelection() {
        edit("Create Component") { selected = try $0.makeComponent(selectedIDs) }
    }
    func extractSubpatch() {
        edit("Extract Subpatch") { graph in selected = try graph.extractSubpatch(selectedIDs) }
    }
    func instantiateSubpatch(_ template: SubpatchTemplate, at position: Position, includeMIDI: Bool, enableOutputs: Bool = false) {
        edit("Insert Subpatch") { graph in selected = try graph.instantiate(template,at:position,includeMIDI:includeMIDI,enableOutputs:enableOutputs) }
    }
    @discardableResult func insertLibrarySubpatch(_ id: String, at position: Position) throws -> UUID {
        var next = graph
        let group = try next.instantiate(PatchLibrary.template(id),at:position,includeMIDI:false)
        try apply(next,action:"Insert Subpatch")
        selected = group
        return group
    }

    private var pendingLibraryInsertion: (id: UUID, before: HistoryState, after: Graph)?
    func stageLibraryOutput(_ template: SubpatchTemplate, outputID: UUID, inputSource: String?, copyInputs: Bool) throws -> [String:Any] {
        guard pendingLibraryInsertion == nil else { throw GraphError("Another subpatch insertion is pending") }
        finishPendingGesture()
        let before = historyState
        var next = graph
        let origin = Position((next.nodes.map { $0.position.x + $0.canvasWidth }.max() ?? 0) + 64,next.nodes.map { $0.position.y }.min() ?? 0)
        let instance = try next.instantiate(template,at:origin,includeMIDI:false)
        if copyInputs { try next.restoreIncomingBindings(from:template.component.id,to:instance) }
        let output = try next.libraryOutput(instance,outputID:outputID,inputSource:inputSource)
        try apply(next,action:"Insert Subpatch",registerUndo:false)
        pendingLibraryInsertion = (instance,before,graph)
        return output
    }
    func commitLibraryInsertion(_ id: UUID) {
        guard let pending = pendingLibraryInsertion,pending.id == id else { return }
        pendingLibraryInsertion = nil
        registerHistory(pending.before,action:"Insert Subpatch")
    }
    func discardLibraryInsertion(_ id: UUID) throws {
        guard let pending = pendingLibraryInsertion,pending.id == id else { throw GraphError("Unknown pending subpatch insertion") }
        guard graph == pending.after else {
            commitLibraryInsertion(id)
            throw GraphError("The graph changed after insertion")
        }
        try apply(pending.before.graph,registerUndo:false)
        pendingLibraryInsertion = nil
    }

    func exportSubpatch(_ id: UUID) {
        do {
            let template = try graph.subpatchTemplate(id)
            try FileManager.default.createDirectory(at:PatchLibrary.subpatchDirectory,withIntermediateDirectories:true)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.directoryURL = PatchLibrary.subpatchDirectory
            panel.nameFieldStringValue = template.component.name+".subpatch.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(template).write(to:url,options:.atomic)
            PatchLibrary.shared.refresh()
        } catch { message = error.localizedDescription }
    }
    func importSubpatch(at position: Position) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.directoryURL = PatchLibrary.subpatchDirectory
        let midi = NSButton(checkboxWithTitle:"Include MIDI mappings",target:nil,action:nil)
        let outputs = NSButton(checkboxWithTitle:"Activate devices and outputs",target:nil,action:nil)
        let options = NSStackView(views:[outputs,midi]); options.orientation = .vertical; options.alignment = .leading
        panel.accessoryView = options
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { instantiateSubpatch(try SubpatchTemplate.read(Data(contentsOf:url)),at:position,includeMIDI:midi.state == .on,enableOutputs:outputs.state == .on) }
        catch { message = error.localizedDescription }
    }
    func toggleComponent(_ id: UUID) { edit("Toggle Component") { g in if let i = g.components?.firstIndex(where:{ $0.id == id }) { g.components![i].collapsed.toggle() } } }
    func ungroup(_ id: UUID) { edit("Ungroup Component") { $0.components?.removeAll { $0.id == id } } }
    func autoLayout() { edit("Auto Layout") { try $0.autoLayout() } }
    @Published var message = ""
    @Published var playing = true
    @Published var previewVisible = false
    @Published var backdropEnabled = false
    @Published var backdropID: UUID?
    @Published var fileURL: URL?
    @Published var unsavedName = "Untitled"
    var projectName: String {
        guard let fileURL else { return unsavedName }
        let name = fileURL.lastPathComponent
        return name.hasSuffix(".patch.json") ? String(name.dropLast(11)) : fileURL.deletingPathExtension().lastPathComponent
    }
    var remembersRecentProjects = true
    var recentProjects: [URL] { (UserDefaults.standard.stringArray(forKey:"recentProjects") ?? []).map(URL.init(fileURLWithPath:)) }
    func remember(_ url: URL) {
        guard remembersRecentProjects else { return }
        var paths = recentProjects.map(\.path); paths.removeAll { $0 == url.path }; paths.insert(url.path,at:0)
        UserDefaults.standard.set(Array(paths.prefix(12)),forKey:"recentProjects")
    }
    func reopenRecentProject(excluding excludedURL: URL) {
        // load() validates before changing the workspace. Missing or invalid files
        // can therefore fall back to the next recent project without losing state.
        for url in recentProjects where url.standardizedFileURL != excludedURL.standardizedFileURL {
            do { try load(url); return }
            catch { continue }
        }
    }
    @Published var dirty = false { didSet { if !dirty { savedGraph = graph } } }
    let undo = UndoManager()
    var onRecord: ((UUID)->Void)?
    var onSaveRecording: ((UUID)->Void)?
    var onDiscardRecording: ((UUID)->Void)?
    var onOpenOutput: ((UUID) -> Void)?
    var onInspect: ((UUID) -> Void)?
    var onPreview: (() -> Void)?
    var onAPCWindow: ((UUID) -> Void)?
    var onPinnedPreview: ((UUID) -> Void)?
    var onClosePinnedPreview: ((UUID) -> Void)?
    var onPalette: ((Position) -> Void)?
    var onDocumentChange: (() -> Void)?
    var beforeSave: (() -> Void)?
    private struct HistoryState {
        var graph: Graph
        var selected: UUID?
        var selectedIDs: Set<UUID>
    }
    private var savedGraph: Graph?
    private var gestureState: HistoryState?
    private var gestureAction = "Edit Graph"
    private var mutationDepth = 0
    private var historyState: HistoryState { .init(graph:graph,selected:selected,selectedIDs:selectedIDs) }
    init() {
        savedGraph = graph
        selected = graph.nodes.first(where: { $0.kind == .crt })?.id
    }
    func apply(_ next: Graph, action: String = "Edit Graph", registerUndo: Bool = true) throws {
        try apply(next,action:action,registerUndo:registerUndo,previous:historyState)
    }
    private func apply(_ next: Graph, action: String, registerUndo: Bool, previous: HistoryState) throws {
        let valid = try next.resolvingBlindsControls().validated()
        guard valid != graph else { return }
        mutationDepth += 1; defer { mutationDepth -= 1 }
        dismissLibraryPreview()
        if registerUndo {
            if gestureState == nil { registerHistory(previous,action:action) }
            else { gestureAction = action }
        }
        graph = valid; dirty = valid != savedGraph
        selectedIDs.formIntersection(Set(graph.nodes.map(\.id)+graph.groups.map(\.id)))
        if let selected, graph.node(selected) == nil && graph.component(selected) == nil { self.selected = nil }
        onDocumentChange?()
    }
    func edit(_ action: String, _ update: (inout Graph) throws -> Void) {
        let previous = historyState
        mutationDepth += 1; defer { mutationDepth -= 1 }
        do { var next = graph; try update(&next); try apply(next,action:action,registerUndo:true,previous:previous); message = "" }
        catch { message = error.localizedDescription }
    }
    private func registerHistory(_ state: HistoryState, action: String) {
        undo.registerUndo(withTarget:self) { $0.restore(state,action:action) }
        undo.setActionName(action)
    }
    private func restore(_ state: HistoryState, action: String) {
        do {
            try apply(state.graph,action:action,registerUndo:true)
            mutationDepth += 1; defer { mutationDepth -= 1 }
            extendingSelection = true
            let available = Set(graph.nodes.map(\.id)+graph.groups.map(\.id))
            selectedIDs = state.selectedIDs.intersection(available)
            selected = state.selected.flatMap { available.contains($0) ? $0 : nil }
            extendingSelection = false
            message = ""
        } catch { message = error.localizedDescription }
    }
    func beginGesture() { if gestureState == nil { gestureState = historyState; gestureAction = "Edit Graph" } }
    func endGesture(_ action: String) {
        guard let old = gestureState else { return }; gestureState = nil
        if old.graph != graph { registerHistory(old,action:action) }
    }
    func finishPendingGesture() { endGesture(gestureAction) }
    var canUndo: Bool { undo.canUndo || gestureState.map { $0.graph != graph } == true }
    func performUndo() { finishPendingGesture(); undo.undo() }
    func performRedo() { finishPendingGesture(); undo.redo() }
    @discardableResult func add(_ kind: NodeKind, at position: Position) -> UUID {
        if kind == .apc40, let existing = graph.nodes.first(where:{ $0.kind == .apc40 }) { selected = existing.id; return existing.id }
        var node = libraryCatalogID == kind.rawValue ? (libraryPreviewNode ?? Node(kind:kind)) : Node(kind:kind)
        node.position = position
        if kind.isOutput || kind == .webcam || kind == .microphone { node.enabled = true }
        node.name = graph.availableName(node.name)
        edit("Add \(kind.title)") { $0.nodes.append(node); selected = node.id }
        return node.id
    }
    func addUserNode(_ entry: CatalogNode, at position: Position) {
        var node = libraryCatalogID == entry.id ? (libraryPreviewNode ?? Node(kind:entry.kind)) : Node(kind:entry.kind)
        node.configureShaderParameters(entry.fieldParameters); node.position = position; node.file = entry.file?.path; node.controlStyle = entry.controlStyle
        if libraryCatalogID != entry.id { node.name = entry.title }
        edit("Add \(entry.title)") { $0.nodes.append(node); selected = node.id }
    }
    func update(_ id: UUID, action: String = "Edit Node", _ fn: (inout Node) -> Void) {
        edit(action) { g in if let i = g.nodes.firstIndex(where: { $0.id == id }) { fn(&g.nodes[i]) } }
    }
    func parameter(_ id: UUID, _ key: String, _ value: Double) {
        let title = graph.node(id)?.parameterSpecs.first(where:{ $0.key == key })?.title ?? "Parameter"
        edit("Change \(title)") { try $0.setParameter(id,key:key,value:value) }
    }
    func deleteSelection() { let ids = selectedIDs; guard !ids.isEmpty else { return }; edit("Delete Selection") { g in g.remove(ids); selected = nil } }
    func duplicate() {
        guard let id = selected, var node = graph.node(id) else { return }
        node.id = UUID(); node.position.x += 40; node.position.y += 210; node.name = graph.availableName(node.name+" copy")
        edit("Duplicate Node") { $0.nodes.append(node); selected = node.id }
    }
    static let nodePasteboardType = NSPasteboard.PasteboardType("local.patch.node")
    @discardableResult func copyNode() -> Bool {
        guard let id = selected, let node = graph.node(id), let data = try? JSONEncoder().encode(node) else { return false }
        NSPasteboard.general.clearContents(); return NSPasteboard.general.setData(data,forType:Self.nodePasteboardType)
    }
    func pasteNode(at position: Position) {
        guard let data = NSPasteboard.general.data(forType:Self.nodePasteboardType), var node = try? JSONDecoder().decode(Node.self,from:data) else { return }
        node.id = UUID(); node.position = position; node.name = graph.availableName(node.name)
        node.modulations = node.modulations?.filter { graph.node($0.value.source)?.kind.outputType == .control }
        edit("Paste Node") { $0.nodes.append(node); selected = node.id }
    }
    func chooseMedia(_ id: UUID? = nil) {
        let kind = id.flatMap { graph.node($0)?.kind }
        let isShader = kind.map { [.dotColors,.flipDots,.projectionDots,.shader,.shaderEffect,.scene,.dataStream,.blockerField,.streakField,.waterfallField,.cellularField].contains($0) } ?? false
        let panel = NSOpenPanel()
        let movies: [UTType] = [.movie] + [UTType(filenameExtension:"mkv")].compactMap { $0 }
        if isShader { panel.allowedContentTypes = [.sourceCode,.plainText] }
        else if kind == .image { panel.allowedContentTypes = [.image,.webP] }
        else if kind == .video { panel.allowedContentTypes = movies }
        else if kind == .audio { panel.allowedContentTypes = [.audio] + movies }
        else { panel.allowedContentTypes = [.image,.webP,.audio] + movies }
        panel.allowsMultipleSelection = id == nil
        guard panel.runModal() == .OK else { return }
        if let id, let url = panel.url { update(id,action:"Choose Source File") { $0.file = url.path; $0.name = url.deletingPathExtension().lastPathComponent } }
        else { importFiles(panel.urls, at: .init(80, 400)) }
    }
    func importFiles(_ urls: [URL], at position: Position) {
        var offset = 0.0
        edit("Import Media") { g in
            for url in urls {
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                let isMKV = MediaCompatibility.needsPreparation(url.path)
                // Some downloaded WebP files have generic or missing content-type metadata.
                let isImage = url.pathExtension.lowercased() == "webp" || type?.conforms(to:.image) == true
                guard isMKV || isImage || type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true else { continue }
                var node = Node(kind: isMKV ? .video : (isImage ? .image : (type?.conforms(to: .audio) == true ? .audio : .video)), position: .init(position.x + offset, position.y))
                node.file = url.path; node.name = url.deletingPathExtension().lastPathComponent
                g.nodes.append(node); selected = node.id; offset += 240
            }
        }
    }
    func save(as saveAs: Bool = false) {
        var destination = fileURL
        if saveAs || destination == nil {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "\(unsavedName).patch.json"
            panel.directoryURL = fileURL?.deletingLastPathComponent() ?? Self.projectsDirectory
            guard panel.runModal() == .OK else { return }; destination = panel.url
        }
        guard let destination else { return }
        do { try write(to: destination); message = "Saved \(destination.lastPathComponent)" } catch { message = error.localizedDescription }
    }
    func write(to url: URL) throws {
        beforeSave?()
        finishPendingGesture()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(graph).write(to: url, options: .atomic)
        fileURL = url; dirty = false; remember(url); onDocumentChange?()
    }
    func renameProject() {
        let alert = NSAlert(); alert.messageText = "Rename Project"
        let field = NSTextField(string:projectName); field.frame = .init(x:0,y:0,width:300,height:24)
        alert.accessoryView = field; alert.addButton(withTitle:"Rename"); alert.addButton(withTitle:"Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), name.count <= 128 else { message = "Enter a name without slashes or colons (up to 128 characters)"; return }
        do {
            if let old = fileURL {
                let destination = old.deletingLastPathComponent().appendingPathComponent(name+".patch.json")
                if destination != old {
                    try FileManager.default.moveItem(at:old,to:destination)
                    let paths = recentProjects.filter { $0 != old }.map(\.path)
                    UserDefaults.standard.set(paths,forKey:"recentProjects")
                    fileURL = destination; remember(destination)
                }
            } else { unsavedName = name }
            message = ""; onDocumentChange?()
        } catch { message = error.localizedDescription }
    }
    func openRecent(_ url: URL) {
        guard confirmDiscard() else { return }
        do { try load(url) } catch { message = error.localizedDescription }
    }
    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to this patch?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() { case .alertFirstButtonReturn: save(); return !dirty; case .alertSecondButtonReturn: return true; default: return false }
    }
    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.directoryURL = Self.projectsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try load(url) } catch { message = error.localizedDescription }
    }
    func load(_ url: URL) throws {
        let next = try Graph.read(Data(contentsOf:url))
        finishPendingGesture()
        try apply(next, action: "Open Project"); undo.removeAllActions(); selected = next.nodes.first?.id; fileURL = url; dirty = false; remember(url); onDocumentChange?()
    }
    func new() {
        guard confirmDiscard() else { return }
        finishPendingGesture()
        try? apply(Graph(), action: "New Project"); undo.removeAllActions(); selected = nil; fileURL = nil; unsavedName = "Untitled"; dirty = false; onDocumentChange?()
    }
}
