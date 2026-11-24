import AppKit
import SwiftUI
import Combine
import PatchCore
import UniformTypeIdentifiers

final class PatchWindow: NSWindow {
    var patchUndo: UndoManager?
    override var undoManager: UndoManager? { patchUndo }
}
final class ProjectorWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect,to screen: NSScreen?) -> NSRect {
        styleMask == .borderless ? frameRect:super.constrainFrameRect(frameRect,to:screen)
    }
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with:event) }
    }
}
final class OutputWindowDelegate: NSObject, NSWindowDelegate {
    let close: () -> Void
    init(_ close: @escaping () -> Void) { self.close = close }
    func windowWillClose(_ notification: Notification) { close() }
}
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    weak var tabOwner: AppController?
    var tabChildren: [AppController] = []
    weak var activeTab: AppController?
    var tabID = UUID()
    var tabClosed = false
    var tabRunning = true
    var changingRunState = false
    var initialTabSession: [String:Any]?
    var pendingTabSession: [String:Any]?
    var pendingOpenFiles: [String] = []
    var tabStrip: NSStackView?
    var tabStripSignature = ""
    var headerRunButton: NSButton?
    var tabRoot: AppController { tabOwner ?? self }
    var openTabs: [AppController] { let root=tabRoot; return (root.tabClosed ? [] : [root]) + root.tabChildren }
    let embedded: Bool
    let headless: Bool
    let sessionURL: URL?
    let apiPort: UInt16
    var editorVisible = true
    var editorFocused = true
    var restoredEditor = false
    var started = false
    var editorRoot: NSView!
    init(hostWindow: NSWindow? = nil, sessionURL: URL? = nil, apiPort: UInt16 = 9417, tabOwner: AppController? = nil, tabSession: [String:Any]? = nil) {
        self.tabOwner=tabOwner; self.initialTabSession=tabSession
        embedded = hostWindow != nil
        headless = hostWindow == nil && CommandLine.arguments.contains("--headless")
        self.sessionURL = sessionURL ?? (tabOwner == nil ? ProcessInfo.processInfo.environment["PATCH_SESSION_PATH"].map(URL.init(fileURLWithPath:)) : nil) ?? (hostWindow == nil && tabOwner == nil && !CommandLine.arguments.contains("--headless")
            ? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Patch/Session.json") : nil)
        self.apiPort = apiPort
        window = hostWindow
        super.init()
    }
    let workspace = Workspace()
    var renderer: Renderer!
    var midi: MIDIController!
    var midiSettings: NSWindow?
    var apcWindows: [UUID:APC40WindowController] = [:]
    var midiLearnButton: NSButton?
    var api: ControlAPI?
    var restarting = false
    var restoredSession: [String:Any]?
    var window: NSWindow!
    var canvas: GraphCanvas!
    var timer: Timer?
    var palette: PaletteController?
    var nodePreview: NodePreviewController?
    var pinnedPreviews: [UUID:NodePreviewController] = [:]
    var previewKeyMonitor: Any?
    var canvasGestureMonitor: Any?
    var observation: AnyCancellable?
    var outputWindows: [UUID:NSWindow] = [:]
    var outputDelegates: [UUID:OutputWindowDelegate] = [:]
    var inspectorWindows: [UUID:NSWindow] = [:]
    var titleLabel = NSButton(title:"Untitled ▾",target:nil,action:nil)
    var footer = NSTextField(labelWithString:"")
    var apiLabel = NSTextField(labelWithString:"")
    var playButton: NSButton!
    var backdropButton: NSButton!
    var resolutionButton: NSPopUpButton!
    var backdropView: VideoView!
    var browserPane: NSView!
    var inspectorPane: NSView!
    var browserWidth: NSLayoutConstraint!
    var inspectorWidth: NSLayoutConstraint!
    var nextFrameTime = 0.0
    var lastMetrics = CACurrentMediaTime()
    var lastFrames = 0
    var measuredFPS = 0.0
    var lastAutosave = CACurrentMediaTime()
    var recoveryURL: URL { if ProcessInfo.processInfo.environment["PATCH_SESSION_PATH"] != nil, let sessionURL { return sessionURL.deletingLastPathComponent().appendingPathComponent("Recovery.patch.json") }; return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Patch/Recovery.patch.json") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try start() }
        catch { if headless { fputs("Patch startup: \(error.localizedDescription)\n",stderr); exit(1) }; NSAlert(error:error).runModal(); NSApp.terminate(nil) }
    }
    func start() throws {
        workspace.remembersRecentProjects = !headless
        if !embedded { NSApp.setActivationPolicy(headless ? .prohibited : .regular); NSApp.appearance = NSAppearance(named:.darkAqua) }
        renderer = try Renderer()
        workspace.plugins.bind(workspace)
        renderer.audioGraph.plugins = workspace.plugins
        midi = MIDIController(workspace:workspace,apcState:renderer.apcState,enabled:!headless && ProcessInfo.processInfo.environment["PATCH_DISABLE_MIDI"] != "1",hostAPC:embedded)
        if !headless && !embedded && tabOwner == nil { makeMenus() }; makeWindow()
        workspace.onInspect = { [weak self] in self?.inspect($0) }
        workspace.onRecord = { [weak self] in self?.toggleRecording($0) }
        workspace.onSaveRecording = { [weak self] in self?.saveRecording($0) }
        workspace.onDiscardRecording = { [weak self] id in
            guard let self else { return }
            DispatchQueue.global(qos:.userInitiated).async {
                do { try self.renderer.discardRecording(id); DispatchQueue.main.async { self.workspace.message = "Take discarded · ready to record"; self.workspace.objectWillChange.send() } }
                catch { DispatchQueue.main.async { self.workspace.message = error.localizedDescription } }
            }
        }
        workspace.onOpenOutput = { [weak self] in self?.showOutput($0) }
        workspace.onPreview = { [weak self] in self?.toggleNodePreview() }
        workspace.onAPCWindow = { [weak self] id in
            guard let self,!self.headless,self.workspace.graph.node(id)?.kind == .apc40 else { return }
            if let controller = self.apcWindows[id] { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
            let controller = APC40WindowController(workspace:self.workspace,midi:self.midi,nodeID:id)
            controller.onClose = { [weak self] in self?.apcWindows.removeValue(forKey:id) }
            self.apcWindows[id] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        }
        workspace.onPinnedPreview = { [weak self] in self?.openPinnedPreview($0) }
        workspace.onClosePinnedPreview = { [weak self] id in self?.pinnedPreviews[id]?.panel.close() }
        if !headless { installPreviewKeys(); installCanvasGestures() }
        workspace.onPalette = { [weak self] in self?.showPalette($0) }
        workspace.onDocumentChange = { [weak self] in self?.updateTitle() }
        observation = workspace.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.syncOutputs(); self?.updateTitle(); if let self { self.renderer.update(graph:self.workspace.renderGraph,playing:self.workspace.playing,publicationGraph:self.workspace.graph); self.nodePreview?.sync() } } }
        do { api = try ControlAPI(workspace:workspace,renderer:renderer,port:apiPort,listen:tabOwner == nil) }
        catch { workspace.message = "API unavailable: \(error.localizedDescription)" }
        api?.onFrame = { [weak self] in self?.canvas.fit() }
        api?.pinnedPreviewState = { [weak self] in self?.pinnedPreviewState ?? [] }
        api?.pinnedPreviewSnapshot = { [weak self] id,url in
            guard let view=self?.pinnedPreviews[id]?.panel.contentView,let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw GraphError("Pinned window is not open") }
            view.cacheDisplay(in:view.bounds,to:rep)
            guard let data=rep.representation(using:.png,properties:[:]) else { throw GraphError("Cannot encode window") }
            try data.write(to:url,options:.atomic)
        }
        api?.editorState = { [weak self] in
            guard let self else { return [:] }
            return ["zoom":Double(self.canvas.zoom),"x":Double(self.canvas.offset.x),"y":Double(self.canvas.offset.y)]
        }
        if !embedded { api?.onRestart = { [weak self] app,session in
            guard let self else { throw GraphError("Patch is shutting down") }
            return try self.tabRoot.restart(app:app,session:session)
        } }
        configureTabAPI()
        var args = embedded || tabOwner != nil ? [String]() : CommandLine.arguments
        if let sessionURL, !args.contains("--project"), !args.contains("--session"), !args.contains("--restore"), FileManager.default.fileExists(atPath:sessionURL.path) { args = ["--session",sessionURL.path] }
        if embedded && args.isEmpty {
            // Seed from the standalone app once; the embedded session then has its own recovery file.
            let recent = UserDefaults(suiteName:"local.patch.editor")?.stringArray(forKey:"recentProjects") ?? []
            for path in recent { if (try? workspace.load(URL(fileURLWithPath:path))) != nil { break } }
        }
        if !embedded && !headless && tabOwner == nil && !args.contains("--project") && !args.contains("--session") && !args.contains("--restore") {
            workspace.reopenRecentProject(excluding:recoveryURL)
        }
        if args.contains("--restore"), FileManager.default.fileExists(atPath:recoveryURL.path) { try? workspace.load(recoveryURL) }
        var incomingSession = initialTabSession
        if let index = args.firstIndex(of:"--session"), args.indices.contains(index+1) {
            incomingSession = (try? JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[index+1])))) as? [String:Any]
        }
        if !embedded, tabOwner == nil, let tabs = incomingSession?["tabs"] as? [[String:Any]] {
            pendingTabSession = incomingSession
            incomingSession = try tabs.first ?? ["graph":try JSONSerialization.jsonObject(with:JSONEncoder().encode(Graph())),"running":false,"dirty":false]
        }
        if let object = incomingSession {
            do {
                guard let graphObject = object["graph"] else { throw GraphError("Invalid session file") }
                tabID = (object["tabID"] as? String).flatMap(UUID.init(uuidString:)) ?? tabID
                tabRunning = object["running"] as? Bool ?? true
                let graph = try JSONDecoder().decode(Graph.self,from:JSONSerialization.data(withJSONObject:graphObject))
                try workspace.apply(graph,action:"Restore Session")
                workspace.undo.removeAllActions()
                workspace.selected = (object["selection"] as? String).flatMap(UUID.init(uuidString:))
                if let selected = object["selectedNodes"] as? [String] {
                    workspace.selectedIDs = Set(selected.compactMap(UUID.init(uuidString:)).filter { workspace.graph.node($0) != nil || workspace.graph.component($0) != nil })
                }
                restoredSession = object
                workspace.playing = object["playing"] as? Bool ?? true
                workspace.backdropEnabled = object["backdropEnabled"] as? Bool ?? false
                workspace.backdropID = (object["backdropID"] as? String).flatMap(UUID.init(uuidString:))
                workspace.unsavedName = object["projectName"] as? String ?? "Untitled"
                workspace.fileURL = (object["file"] as? String).map(URL.init(fileURLWithPath:))
                workspace.dirty = object["dirty"] as? Bool ?? true
                if let midiState = object["midi"] as? [String:Any],let node = (midiState["followNode"] as? String).flatMap(UUID.init(uuidString:)),workspace.graph.node(node)?.kind == .ab {
                    try midi.setFollow(node,enabled:true)
                }
            } catch { if embedded { throw error }; workspace.message = "Session restore: \(error.localizedDescription)" }
        }
        if let index = args.firstIndex(of:"--project"), args.indices.contains(index+1) { do { try workspace.load(URL(fileURLWithPath:args[index+1])) } catch { workspace.message = error.localizedDescription } }
        if tabRunning { renderer.start(graph:workspace.graph,playing:workspace.playing) }
        else { renderer.stop(); workspace.plugins.setSuspended(true); suspendTabMIDI() }
        started = true
        if !embedded && tabOwner == nil { activeTab=self }
        if headless && CommandLine.arguments.contains("--verify-render-thread") {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                let before = self.renderer.renderedFrames
                Thread.sleep(forTimeInterval:1.0)
                let advanced = self.renderer.renderedFrames-before
                if advanced < 25 { fputs("FAIL render thread stalled with UI: \(advanced) frames\n",stderr); exit(1) }
                print("PASS render thread: \(advanced) frames while main thread was blocked for 1 second")
                exit(0)
            }
        }
        let frameTimer = Timer(timeInterval:0.5,repeats:true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(frameTimer,forMode:.common); timer = frameTimer
        syncOutputs(); canvas.sync(); if !headless && !embedded && tabOwner == nil { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas); NSApp.activate(ignoringOtherApps:true) }
        DispatchQueue.main.async {
            if let editor = self.restoredSession?["editor"] as? [String:Double],
               let zoom = editor["zoom"], let x = editor["x"], let y = editor["y"],
               zoom.isFinite, x.isFinite, y.isFinite, (0.0001...2).contains(zoom) {
                self.restoredEditor = true; self.canvas.zoom = CGFloat(zoom); self.canvas.offset = NSPoint(x:x,y:y); self.canvas.sync()
            } else if !self.embedded { self.canvas.fit() }
            if !self.embedded, self.restoredSession?["previewVisible"] as? Bool == true { self.toggleNodePreview() }
            if !self.headless,let previews=self.restoredSession?["pinnedPreviews"] as? [[String:Any]] {
                for preview in previews {
                    guard let text=preview["id"] as? String,let id=UUID(uuidString:text),self.workspace.graph.node(id) != nil else { continue }
                    self.openPinnedPreview(id)
                    if let frame=preview["frame"] as? [Double],frame.count==4,frame.allSatisfy(\.isFinite) {
                        self.pinnedPreviews[id]?.panel.setFrame(.init(x:frame[0],y:frame[1],width:max(320,frame[2]),height:max(220,frame[3])),display:true)
                    }
                }
            }
            self.restoredSession = nil
            if let session = self.pendingTabSession {
                self.pendingTabSession = nil
                for snapshot in (session["tabs"] as? [[String:Any]] ?? []).dropFirst() {
                    do { _ = try self.createTab(snapshot: snapshot, select:false) }
                    catch { self.workspace.message = "Tab restore: \(error.localizedDescription)" }
                }
                let selected = session["activeTab"] as? String
                let tab = self.openTabs.first { $0.tabID.uuidString == selected } ?? self
                self.selectProjectTab(tab)
            }
            self.updateTitle()
            let files=self.pendingOpenFiles; self.pendingOpenFiles=[]
            for file in files { self.openInTab(URL(fileURLWithPath:file)) }
        }
    }
    func makeWindow() {
        if !embedded {
        window = PatchWindow(contentRect:.init(x:80,y:100,width:1380,height:850),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "Patch — Untitled"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.minSize = .init(width:980,height:650); window.delegate = self; (window as? PatchWindow)?.patchUndo = workspace.undo; window.isReleasedWhenClosed = false
        window.backgroundColor = .patchBG; window.setFrameAutosaveName("Patch.Main")
        }
        if !embedded { window.tabbingMode = .disallowed }
        window.acceptsMouseMovedEvents = true
        let root = PatchEditorRoot(); root.patchUndo = workspace.undo
        root.identifier = NSUserInterfaceItemIdentifier("patch-editor-root")
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.patchBG.cgColor
        root.appearance = NSAppearance(named:.darkAqua); editorRoot = root
        if !embedded { window.contentView = root }
        if !embedded && !headless { makeTabStrip(in:root) }
        let header = NSView(); header.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(header)
        let brand = NSTextField(labelWithString:"PATCH"); brand.font = .monospacedSystemFont(ofSize:12,weight:.bold); brand.textColor = .patchAccent
        titleLabel.font = .systemFont(ofSize:12,weight:.medium); titleLabel.bezelStyle = .smallSquare; titleLabel.isBordered = false; titleLabel.target = self; titleLabel.action = #selector(projectMenu); titleLabel.toolTip = "Project: rename, save, or switch"; titleLabel.setAccessibilityLabel("Project menu")
        let add = button("Add Node",symbol:"plus",action:#selector(addNode)); let importButton = button("Import",symbol:"square.and.arrow.down",action:#selector(importMedia))
        playButton = button("Pause",symbol:"pause.fill",action:#selector(togglePlay))
        backdropButton = button("Backdrop",symbol:"rectangle.on.rectangle",action:#selector(toggleBackdrop)); backdropButton.setButtonType(.toggle)
        let midiToggle = button("MIDI",symbol:"slider.horizontal.3",action:#selector(toggleMIDILearn)); midiToggle.setButtonType(.toggle); midiToggle.toolTip = "MIDI Learn · ⌘M"; midiLearnButton = midiToggle
        let fit = button("Frame",symbol:"arrow.up.left.and.arrow.down.right",action:#selector(frameGraph))
        let resolution = NSPopUpButton(); resolutionButton = resolution; resolution.addItems(withTitles:["1280 × 720","1920 × 1080","960 × 540","Custom…"]); resolution.target = self; resolution.action = #selector(changeResolution(_:)); resolution.controlSize = .small
        let libraryToggle = button("",symbol:"sidebar.left",action:#selector(toggleLibrary)); libraryToggle.toolTip = "Toggle Node Library"; libraryToggle.setAccessibilityLabel("Toggle Node Library")
        let detailsToggle = button("",symbol:"sidebar.right",action:#selector(toggleInspector)); detailsToggle.toolTip = "Toggle Inspector"; detailsToggle.setAccessibilityLabel("Toggle Inspector")
        let left = NSStackView(views:[libraryToggle,brand,titleLabel]); left.spacing = 18; left.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(left)
        let tabControl=button("Stop Tab",symbol:"stop.fill",action:#selector(toggleTabRunning)); headerRunButton=tabControl
        let runtimeControls: [NSView] = embedded || headless ? [] : [tabControl]
        let right = NSStackView(views:[importButton,add,fit,backdropButton,resolution,playButton] + runtimeControls + [midiToggle,detailsToggle]); right.spacing = 10; right.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(right)
        let browser = NSHostingView(rootView:NodeBrowser(workspace:workspace).disclosureGroupStyle(PatchDisclosureStyle()))
        browserPane = browser; browser.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(browser)
        let split = NSStackView(); split.orientation = .horizontal; split.spacing = 1; split.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(split)
        canvas = GraphCanvas(workspace:workspace,renderer:renderer)
        let inspector = NSHostingView(rootView:Inspector(workspace:workspace,renderer:renderer).disclosureGroupStyle(PatchDisclosureStyle())); inspectorPane = inspector; inspector.frame = .init(x:0,y:0,width:310,height:700)
        let graphContainer = NSView()
        backdropView = VideoView(renderer:renderer); backdropView.translatesAutoresizingMaskIntoConstraints = false; backdropView.isHidden = true
        canvas.translatesAutoresizingMaskIntoConstraints = false
        graphContainer.addSubview(backdropView); graphContainer.addSubview(canvas)
        for child in [backdropView as NSView,canvas as NSView] {
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:graphContainer.leadingAnchor),child.trailingAnchor.constraint(equalTo:graphContainer.trailingAnchor),child.topAnchor.constraint(equalTo:graphContainer.topAnchor),child.bottomAnchor.constraint(equalTo:graphContainer.bottomAnchor)])
        }
        split.addArrangedSubview(graphContainer); split.addArrangedSubview(inspector)
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant:310); inspectorWidth.isActive = true
        browserWidth = browser.widthAnchor.constraint(equalToConstant:172); browserWidth.isActive = true
        let foot = NSView(); foot.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(foot)
        footer.font = .monospacedSystemFont(ofSize:10,weight:.regular); footer.textColor = .patchMuted; footer.translatesAutoresizingMaskIntoConstraints = false; foot.addSubview(footer)
        apiLabel.font = .monospacedSystemFont(ofSize:10,weight:.regular); apiLabel.textColor = .patchMuted; apiLabel.translatesAutoresizingMaskIntoConstraints = false; foot.addSubview(apiLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo:root.topAnchor,constant:embedded ? 0 : headless ? 28 : 66),header.leadingAnchor.constraint(equalTo:root.leadingAnchor),header.trailingAnchor.constraint(equalTo:root.trailingAnchor),header.heightAnchor.constraint(equalToConstant:48),
            left.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:22),left.centerYAnchor.constraint(equalTo:header.centerYAnchor),
            right.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-16),right.centerYAnchor.constraint(equalTo:header.centerYAnchor),left.trailingAnchor.constraint(lessThanOrEqualTo:right.leadingAnchor,constant:-20),
            browser.leadingAnchor.constraint(equalTo:root.leadingAnchor),browser.topAnchor.constraint(equalTo:header.bottomAnchor),browser.bottomAnchor.constraint(equalTo:foot.topAnchor),
            split.topAnchor.constraint(equalTo:header.bottomAnchor),split.leadingAnchor.constraint(equalTo:browser.trailingAnchor),split.trailingAnchor.constraint(equalTo:root.trailingAnchor),split.bottomAnchor.constraint(equalTo:foot.topAnchor),
            foot.heightAnchor.constraint(equalToConstant:30),foot.bottomAnchor.constraint(equalTo:root.bottomAnchor),foot.leadingAnchor.constraint(equalTo:root.leadingAnchor),foot.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo:foot.leadingAnchor,constant:16),footer.centerYAnchor.constraint(equalTo:foot.centerYAnchor),footer.trailingAnchor.constraint(lessThanOrEqualTo:apiLabel.leadingAnchor,constant:-12),
            apiLabel.trailingAnchor.constraint(equalTo:foot.trailingAnchor,constant:-16),apiLabel.centerYAnchor.constraint(equalTo:foot.centerYAnchor)
        ])
        if !embedded { window.center() }; root.layoutSubtreeIfNeeded(); restorePanes()
    }
    func button(_ title: String,symbol: String,action: Selector) -> NSButton {
        let b = NSButton(title:title,target:self,action:action); b.image = NSImage(systemSymbolName:symbol,accessibilityDescription:title); b.imagePosition = .imageLeading; b.bezelStyle = .smallSquare; b.controlSize = .small; b.font = .systemFont(ofSize:11); return b
    }
    func tick() {
        // MTKView owns display scheduling; graph evaluation stays on renderQueue.
        let now = CACurrentMediaTime()
        if (embedded ? editorVisible : !tabClosed && tabRoot.activeTab === self), now-lastMetrics > 0.5 {
            measuredFPS = Double(renderer.renderedFrames-lastFrames)/(now-lastMetrics); lastFrames = renderer.renderedFrames; lastMetrics = now
            footer.stringValue = !embedded && !tabRunning ? "■  STOPPED · No nodes processing" : workspace.message.isEmpty ? String(format:"●  %.0f FPS    GPU %.2f ms    %d NODES    %d%%",measuredFPS,renderer.gpuMS,workspace.graph.nodes.count,Int(canvas.zoom*100)) : workspace.message
            footer.textColor = workspace.message.isEmpty ? .patchMuted : .systemOrange
            apiLabel.stringValue = "API  " + (api?.state ?? "Unavailable")
            midiLearnButton?.state = midi.learning ? .on : .off
            workspace.objectWillChange.send()
        }
        if !headless, tabOwner == nil, now-lastAutosave > 15 {
            lastAutosave = now; persistSession()
        }
    }
    func updateTitle() {
        backdropView?.isHidden = !workspace.backdropEnabled
        backdropView?.nodeID = workspace.backdropID.flatMap { workspace.graph.node($0) == nil ? nil : $0 } ?? workspace.graph.nodes.first(where:{ $0.kind.isOutput && $0.kind.previewKind == .video && $0.enabled })?.id ?? workspace.selected
        backdropButton?.state = workspace.backdropEnabled ? .on : .off
        let resolutionTitle = "\(workspace.graph.width) × \(workspace.graph.height)"
        if let resolutionButton, !resolutionButton.itemTitles.contains(resolutionTitle) {
            resolutionButton.insertItem(withTitle:resolutionTitle,at:max(0,resolutionButton.numberOfItems-1))
        }
        resolutionButton?.selectItem(withTitle:resolutionTitle)
        let name = workspace.projectName
        if !embedded {
            refreshTabStrips()
            headerRunButton?.title = changingRunState ? "Stopping…" : tabRunning ? "Stop Tab" : "Start Tab"
            headerRunButton?.image = NSImage(systemSymbolName:tabRunning ? "stop.fill" : "play.fill",accessibilityDescription:nil)
            headerRunButton?.isEnabled = !changingRunState
            playButton?.isEnabled = tabRunning
        }
        titleLabel.title = name + (workspace.dirty ? " • ▾" : " ▾"); if !embedded { window.title = "Patch — \(name)"; window.isDocumentEdited = workspace.dirty }
        playButton.title = workspace.playing ? "Pause" : "Play"; playButton.image = NSImage(systemSymbolName:workspace.playing ? "pause.fill" : "play.fill",accessibilityDescription:nil)
    }
    func syncOutputs() {
        guard !headless, !tabClosed, embedded || tabRunning else { return }
        for node in workspace.graph.nodes where (node.kind == .window || node.kind == .projector) && node.enabled { if outputWindows[node.id] == nil { showOutput(node.id,front:false) } }
        for id in Array(outputWindows.keys) {
            if let node = workspace.graph.node(id), (node.kind != .window && node.kind != .projector) || node.enabled { outputWindows[id]?.title = "Patch · \(node.name)"; let size = workspace.graph.videoDimensions(id); outputWindows[id]?.aspectRatio = .init(width:size.width,height:size.height) }
            else { outputWindows[id]?.delegate = nil; outputWindows.removeValue(forKey:id)?.close(); outputDelegates[id] = nil }
        }
        for node in workspace.graph.nodes where node.kind == .projector {
            if let win=outputWindows[node.id] { configureProjector(win,node:node) }
        }
        for id in Array(pinnedPreviews.keys) {
            if workspace.graph.node(id) == nil { pinnedPreviews[id]?.panel.close() }
            else { pinnedPreviews[id]?.sync() }
        }
        for id in Array(inspectorWindows.keys) where workspace.graph.node(id) == nil { inspectorWindows.removeValue(forKey:id)?.close() }
    }
    func toggleRecording(_ id: UUID) {
        switch renderer.recordingInfo(id)?.phase {
        case "recording": renderer.stopRecording(id) { [weak self] result in
            switch result { case .success: self?.saveRecording(id); case .failure(let error): self?.workspace.message = error.localizedDescription }
        }
        case "finishing": break
        case "ready": saveRecording(id)
        default:
            do { try renderer.startRecording(id); workspace.message = "" }
            catch { workspace.message = error.localizedDescription }
        }
        workspace.objectWillChange.send()
    }
    func saveRecording(_ id: UUID) {
        guard let info = renderer.recordingInfo(id), ["ready","saved"].contains(info.phase) else { return }
        let fileExtension = info.url.pathExtension
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:fileExtension) ?? .quickTimeMovie]
        panel.nameFieldStringValue = "\(workspace.projectName).\(fileExtension)"
        window.makeKeyAndOrderFront(nil)
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.workspace.message = "Saving \(info.noun)…"
            DispatchQueue.global(qos:.userInitiated).async {
                do { try self.renderer.saveRecording(id,to:url,replace:true); DispatchQueue.main.async { self.workspace.message = "Saved \(url.lastPathComponent)"; self.workspace.objectWillChange.send() } }
                catch { DispatchQueue.main.async { self.workspace.message = error.localizedDescription } }
            }
        }
    }
    func showOutput(_ id: UUID,front: Bool = true) {
        if let existing = outputWindows[id] { if front { existing.makeKeyAndOrderFront(nil) }; return }
        guard let node = workspace.graph.node(id) else { return }
        if NodeApp.for(node) != nil { openPinnedPreview(id);return }
        if node.kind.isMIDINode { inspect(id);return }
        if front && (node.kind == .window || node.kind == .projector) && !node.enabled { workspace.update(id) { $0.enabled = true } }
        let view = VideoView(renderer:renderer); view.nodeID = id
        let win = ProjectorWindow(contentRect:.init(x:150,y:140,width:960,height:540),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        win.title = "Patch · \(node.name)"; win.backgroundColor = .black; win.contentView = view; win.isReleasedWhenClosed = false; win.collectionBehavior = [.fullScreenPrimary]; win.aspectRatio = .init(width:workspace.graph.videoDimensions(id).width,height:workspace.graph.videoDimensions(id).height)
        let delegate = OutputWindowDelegate { [weak self] in
            guard let self else { return }; self.outputWindows[id] = nil; self.outputDelegates[id] = nil
            if let kind=self.workspace.graph.node(id)?.kind,kind == .window || kind == .projector { self.workspace.update(id) { $0.enabled = false } }
        }
        outputDelegates[id] = delegate; outputWindows[id] = win; win.delegate = delegate
        if node.kind == .projector { configureProjector(win,node:node) }
        if front { win.makeKeyAndOrderFront(nil) } else if node.kind == .projector { win.orderFront(nil) } else { win.orderBack(nil) }
    }
    private func configureProjector(_ win: NSWindow,node: Node) {
        if let id=node.deviceID,let screen=NSScreen.screens.first(where:{ $0.patchDisplayID == id }) {
            if win.styleMask != .borderless { win.styleMask = .borderless }
            win.level = NSWindow.Level(rawValue:NSWindow.Level.mainMenu.rawValue+1)
            win.collectionBehavior=[.canJoinAllSpaces,.stationary,.ignoresCycle,.fullScreenAuxiliary]
            win.hidesOnDeactivate=false;win.hasShadow=false;win.aspectRatio = .zero
            if win.frame != screen.frame { win.setFrame(screen.frame,display:true) }
        } else if win.styleMask == .borderless {
            win.level = .normal;win.collectionBehavior=[.fullScreenPrimary];win.hasShadow=true
            win.styleMask=[.titled,.closable,.miniaturizable,.resizable]
            win.setFrame(NSRect(x:150,y:140,width:960,height:540),display:true)
        }
    }
    func inspect(_ id: UUID) {
        workspace.selected = id
        if inspectorPane.isHidden { toggleInspector() }
        window.makeKeyAndOrderFront(nil)
    }
    func restorePanes() {
        if UserDefaults.standard.bool(forKey:"libraryHidden") { toggleLibrary() }
        if UserDefaults.standard.bool(forKey:"inspectorHidden") { toggleInspector() }
    }
    @objc func toggleLibrary() {
        browserPane.isHidden.toggle(); browserWidth.constant = browserPane.isHidden ? 0 : 172
        UserDefaults.standard.set(browserPane.isHidden,forKey:"libraryHidden")
        editorRoot.layoutSubtreeIfNeeded()
    }
    @objc func toggleInspector() {
        inspectorPane.isHidden.toggle()
        UserDefaults.standard.set(inspectorPane.isHidden,forKey:"inspectorHidden")
        editorRoot.layoutSubtreeIfNeeded()
    }
    func addCatalogNode(_ entry: CatalogNode, at position: Position) {
        guard entry.file != nil else { addKind(entry.kind,at:position); return }
        workspace.addUserNode(entry,at:position)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas)
    }
    func addKind(_ kind: NodeKind, at position: Position) {
        let selected = workspace.selected
        workspace.beginGesture()
        let id = workspace.add(kind,at:position)
        if let selected, !kind.inputs.isEmpty, kind.inputTypes.first?.accepts(workspace.graph.node(selected)?.kind.outputType) == true {
            workspace.edit("Add and Connect") { try $0.connect(selected,to:id) }
        }
        workspace.endGesture("Add \(kind.title)")
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas)
        if kind == .image || kind == .video || kind == .audio || kind == .shader || kind == .shaderEffect { workspace.chooseMedia(id) }
    }
    var pinnedPreviewState: [[String:Any]] {
        pinnedPreviews.sorted { $0.key.uuidString < $1.key.uuidString }.map { id,preview in
            let f=preview.panel.frame
            return ["id":id.uuidString,"name":workspace.graph.node(id)?.name ?? "", "kind":workspace.graph.node(id)?.kind.rawValue ?? "", "visible":preview.panel.isVisible,"windowLevel":preview.panel.level.rawValue,"frame":[Double(f.minX),Double(f.minY),Double(f.width),Double(f.height)]]
        }
    }
    func openPinnedPreview(_ id: UUID) {
        guard !headless,workspace.graph.node(id) != nil else { return }
        if let existing=pinnedPreviews[id] { existing.panel.makeKeyAndOrderFront(nil);return }
        let preview=NodePreviewController(workspace:workspace,renderer:renderer,fixedID:id)
        preview.onClose = { [weak self] in self?.pinnedPreviews[id]=nil }
        pinnedPreviews[id]=preview
        if nodePreview?.panel.isVisible == true,workspace.graph.previewNode(workspace.selected)?.id == id { nodePreview?.panel.close() }
        preview.show(over:window)
    }
    func toggleNodePreview() {
        if nodePreview?.panel.isVisible == true {
            nodePreview?.panel.close(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas)
        } else {
            if nodePreview == nil { nodePreview = NodePreviewController(workspace:workspace,renderer:renderer) }
            nodePreview?.show(over:window)
        }
    }
    func installPreviewKeys() {
        previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self, self.editorFocused, self.window.attachedSheet == nil else { return event }
            if event.keyCode == 53, self.midi.learning { self.midi.setLearning(false); return nil }
            guard event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
                  NSApp.keyWindow === self.window || NSApp.keyWindow === self.nodePreview?.panel else { return event }
            // Keep spaces available in node names, text content, and search fields.
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if self.embedded, NSApp.keyWindow === self.window,
               let responder = self.window.firstResponder as? NSView,
               !responder.isDescendant(of:self.editorRoot) { return event }
            if event.keyCode == 49 {
                if !event.isARepeat { self.toggleNodePreview() }; return nil
            }
            if event.keyCode == 53, NSApp.keyWindow === self.nodePreview?.panel {
                self.toggleNodePreview(); return nil
            }
            return event
        }
    }
    func installCanvasGestures() {
        canvasGestureMonitor = NSEvent.addLocalMonitorForEvents(matching:[.flagsChanged,.mouseMoved,.leftMouseDragged,.leftMouseDown,.leftMouseUp,.keyDown]) { [weak self] event in
            guard let self,self.editorFocused,self.window.attachedSheet == nil,NSApp.keyWindow === self.window,
                  event.window === self.window || event.type == .flagsChanged else { return event }
            return self.canvas.handleQuickGesture(event) ? nil : event
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard !embedded, started, notification.object as? NSWindow === window else { return }
        tabRoot.activeTab = self; makeMenus(); refreshTabStrips()
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === window { canvas?.cancelQuickGesture() }
    }
    func showPalette(_ position: Position) {
        if palette?.panel.isVisible == true { palette?.panel.close(); window.makeFirstResponder(canvas); return }
        palette = PaletteController { [weak self] kind in self?.addCatalogNode(kind,at:position) }
        palette?.show(over:window)
    }
    func makeMenus(hostMenu: NSMenu? = nil) {
        let menu = NSMenu(); NSApp.mainMenu = menu
        func submenu(_ title: String) -> NSMenu { let item = NSMenuItem(); item.title = title; let sub = NSMenu(title:title); item.submenu = sub; menu.addItem(item); return sub }
        func item(_ menu: NSMenu,_ title: String,_ action: Selector,_ key: String, modifiers: NSEvent.ModifierFlags = .command) { let i = menu.addItem(withTitle:title,action:action,keyEquivalent:key); i.target = self; i.keyEquivalentModifierMask = modifiers }
        if let hostItem = hostMenu?.items.first?.copy() as? NSMenuItem { menu.addItem(hostItem) }
        else { let app = submenu("Patch"); item(app,"About Patch",#selector(about),""); item(app,"Settings…",#selector(showMIDISettings),","); app.addItem(.separator()); item(app,"Quit Patch",#selector(quit),"q") }
        let file = submenu("File"); item(file,"New",#selector(newProject),"n"); item(file,"Open…",#selector(openProject),"o"); item(file,"Save",#selector(saveProject),"s"); item(file,"Save As…",#selector(saveAs),"s",modifiers:[.command,.shift]); file.addItem(.separator()); item(file,"Import Media…",#selector(importMedia),"i")
        if !embedded { item(file,"Close Tab",#selector(closeProjectTab),"w") }
        let edit = submenu("Edit"); item(edit,"Undo",#selector(undoAction),"z"); item(edit,"Redo",#selector(redoAction),"z",modifiers:[.command,.shift]); edit.addItem(.separator())
        for (title,action,key) in [("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"")] { edit.addItem(withTitle:title,action:action,keyEquivalent:key) }
        item(edit,"Duplicate Node",#selector(duplicate),"d"); item(edit,"Delete Node",#selector(deleteNode),"\u{8}")
        let graph = submenu("Graph"); item(graph,"Add Node…",#selector(addNode),"f"); item(graph,"Frame All",#selector(frameGraph),"0"); item(graph,"Auto Layout",#selector(autoLayout),"a",modifiers:[.command,.shift]); item(graph,"Create Component",#selector(createComponent),"g"); item(graph,"Expand / Collapse Component",#selector(toggleComponent),"g",modifiers:[.command,.shift]); item(graph,"Play / Pause",#selector(togglePlay)," "); item(graph,"Preview Selected Node",#selector(openViewer),"\r"); item(graph,"Video Backdrop",#selector(toggleBackdrop),"b"); item(graph,"Use Selection as Backdrop",#selector(pinBackdrop),"b",modifiers:[.command,.shift])
        item(graph,"MIDI Learn",#selector(toggleMIDILearn),"m")
        let view = submenu("View"); item(view,"Toggle Node Library",#selector(toggleLibrary),"1"); item(view,"Toggle Inspector",#selector(toggleInspector),"2")
        if embedded { item(graph,"Patch Settings…",#selector(showMIDISettings),",") }
        if let windowMenu = hostMenu?.item(withTitle:"Window")?.copy() as? NSMenuItem { menu.addItem(windowMenu) }
        let help = submenu("Help"); item(help,"Control API",#selector(apiHelp),"")
    }
    @objc func toggleMIDILearn() {
        midi.toggleLearn()
        midiLearnButton?.state = midi.learning ? .on : .off
        if midi.learning && inspectorPane.isHidden { toggleInspector() }
    }
    @objc func showMIDISettings() {
        if midiSettings == nil {
            let panel = NSWindow(contentRect:.init(x:160,y:160,width:820,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            panel.title = "Patch Settings"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView:MIDISettings(workspace:workspace,midi:midi).disclosureGroupStyle(PatchDisclosureStyle()))
            midiSettings = panel
        }
        midiSettings?.makeKeyAndOrderFront(nil)
    }
    @objc func projectMenu() {
        let menu = NSMenu()
        for (title,action) in [("Rename…",#selector(renameProject)),("Save",#selector(saveProject)),("Save As…",#selector(saveAs))] {
            let item = menu.addItem(withTitle:title,action:action,keyEquivalent:""); item.target = self
        }
        menu.addItem(.separator())
        for (title,action) in [("New Project",#selector(newProject)),("Open Project…",#selector(openProject))] {
            let item = menu.addItem(withTitle:title,action:action,keyEquivalent:""); item.target = self
        }
        let recent = NSMenu(title:"Recent Projects")
        for url in workspace.recentProjects {
            let item = recent.addItem(withTitle:url.lastPathComponent,action:#selector(openRecent(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = url; item.toolTip = url.path
            item.state = workspace.fileURL == url ? .on : .off
        }
        if recent.items.isEmpty { let empty = recent.addItem(withTitle:"No recent projects",action:nil,keyEquivalent:""); empty.isEnabled = false }
        let item = menu.addItem(withTitle:"Recent Projects",action:nil,keyEquivalent:""); item.submenu = recent
        menu.popUp(positioning:nil,at:.init(x:0,y:titleLabel.bounds.minY-5),in:titleLabel)
    }
    @objc func renameProject() { workspace.renameProject(); updateTitle() }
    @objc func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { if embedded { workspace.openRecent(url); canvas.fit() } else { openInTab(url) } } }
    @objc func addNode() { showPalette(canvas.insertionPoint) }
    @objc func importMedia() { workspace.chooseMedia() }
    @objc func frameGraph() { window.makeKeyAndOrderFront(nil); canvas.fit() }
    @objc func autoLayout() {
        if let text = (NSApp.keyWindow ?? window)?.firstResponder as? NSTextView { text.selectAll(nil); return }
        workspace.autoLayout(); canvas.fit()
    }
    @objc func createComponent() { workspace.collapseSelection() }
    @objc func toggleComponent() { if let id = workspace.selected { workspace.toggleComponent(id) } }
    @objc func toggleBackdrop() { workspace.backdropEnabled.toggle(); updateTitle() }
    @objc func pinBackdrop() { workspace.backdropID = workspace.selected; workspace.backdropEnabled = true; updateTitle() }
    @objc func togglePlay() { workspace.playing.toggle(); updateTitle() }
    @objc func newProject() {
        if embedded { workspace.new(); canvas.fit(); return }
        do { _ = try tabRoot.createTab(snapshot:["graph":try JSONSerialization.jsonObject(with:JSONEncoder().encode(Graph())),"running":false,"dirty":false]) }
        catch { workspace.message=error.localizedDescription }
    }
    @objc func openProject() {
        if embedded { workspace.open(); canvas.fit(); return }
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.json]; panel.allowsMultipleSelection=true; panel.directoryURL=Workspace.projectsDirectory
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openInTab(url) }
    }
    @objc func saveProject() { workspace.save() }
    @objc func saveAs() { workspace.save(as:true) }
    private var activeHistoryWorkspace: Workspace { workspace.libraryPreview ?? workspace }
    @objc func undoAction() {
        canvas.cancelQuickGesture()
        if let text = (NSApp.keyWindow ?? window)?.firstResponder as? NSTextView { text.undoManager?.undo() }
        else { activeHistoryWorkspace.performUndo() }
    }
    @objc func redoAction() {
        canvas.cancelQuickGesture()
        if let text = (NSApp.keyWindow ?? window)?.firstResponder as? NSTextView { text.undoManager?.redo() }
        else { activeHistoryWorkspace.performRedo() }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(undoAction) || item.action == #selector(redoAction) else { return true }
        let isUndo = item.action == #selector(undoAction)
        if let text = (NSApp.keyWindow ?? window)?.firstResponder as? NSTextView,let manager = text.undoManager {
            item.title = isUndo ? manager.undoMenuItemTitle : manager.redoMenuItemTitle
            return isUndo ? manager.canUndo : manager.canRedo
        }
        let active = activeHistoryWorkspace
        item.title = isUndo ? active.undo.undoMenuItemTitle : active.undo.redoMenuItemTitle
        return isUndo ? active.canUndo : active.undo.canRedo
    }
    @objc func duplicate() { workspace.duplicate() }
    @objc func deleteNode() { workspace.deleteSelection() }
    @objc func openViewer() { toggleNodePreview() }
    @objc func changeResolution(_ sender: NSPopUpButton) {
        if sender.titleOfSelectedItem == "Custom…" {
            // Restore the actual size in the toolbar even if the dialog is canceled.
            updateTitle()
            let alert = NSAlert(); alert.messageText = "Custom Project Dimensions"
            let guidance = "Enter pixel dimensions. Width: 64–3840. Height: 64–2160."
            alert.informativeText = guidance
            let width = NSTextField(string:String(workspace.graph.width))
            let height = NSTextField(string:String(workspace.graph.height))
            width.setAccessibilityLabel("Project width in pixels")
            height.setAccessibilityLabel("Project height in pixels")
            let fields = NSGridView(views:[[NSTextField(labelWithString:"Width"),width,NSTextField(labelWithString:"px")],
                                          [NSTextField(labelWithString:"Height"),height,NSTextField(labelWithString:"px")]])
            fields.rowSpacing = 12; fields.columnSpacing = 10
            fields.frame = .init(x:0,y:0,width:300,height:64)
            fields.column(at:1).width = 180
            alert.accessoryView = fields
            alert.addButton(withTitle:"Apply"); alert.addButton(withTitle:"Cancel")
            alert.window.initialFirstResponder = width
            while alert.runModal() == .alertFirstButtonReturn {
                guard let w = Int(width.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)),
                      let h = Int(height.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)),
                      (64...3840).contains(w), (64...2160).contains(h) else {
                    alert.informativeText = "Enter whole numbers within the supported ranges.\n"+guidance
                    continue
                }
                workspace.edit("Render Resolution") { $0.width = w; $0.height = h }
                updateTitle(); return
            }
            return
        }
        let parts = (sender.titleOfSelectedItem ?? "").components(separatedBy:" × ")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return }
        workspace.edit("Render Resolution") { $0.width = width; $0.height = height }
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Patch",.applicationVersion:"0.1.0",.credits:NSAttributedString(string:"Swift · Metal")]) }
    @objc func apiHelp() {
        let alert = NSAlert(); alert.messageText = "Local Control API"
        alert.informativeText = "http://127.0.0.1:\(api?.port ?? 9417)\n\nGET /v1/state\nGET /v1/schema\nPOST /v1/commands\n\nBearer token:\n~/Library/Application Support/Patch/api-token\n\nThe schema lists node types, ports, and parameter ranges."
        alert.addButton(withTitle:"OK"); alert.runModal()
    }
    func restart(app: URL,session: [String:Any]) throws -> URL {
        guard !embedded, !headless, !restarting else { throw GraphError("Restart is unavailable") }
        guard app.pathExtension == "app", let bundle = Bundle(url:app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath:executable.path) else { throw GraphError("Choose a built Patch application") }
        let folder = recoveryURL.deletingLastPathComponent().appendingPathComponent("Restart Sessions",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let snapshot = folder.appendingPathComponent("restart-"+UUID().uuidString+".json")
        let fullSession = try sessionWithTabs(base:session)
        try JSONSerialization.data(withJSONObject:fullSession,options:[.prettyPrinted,.sortedKeys]).write(to:snapshot,options:.atomic)
        let log = snapshot.deletingPathExtension().appendingPathExtension("log")
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let logHandle = try FileHandle(forWritingTo:log)
        defer { try? logHandle.close() }
        // Launch from Patch's desktop session. The child waits for this process
        // to exit so the replacement can bind the same API port.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath:"/bin/sh")
        helper.arguments = ["-c", """
        attempts=0
        while /bin/kill -0 "$1" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 3000 ]; then echo 'Patch did not exit'; exit 1; fi
            /bin/sleep 0.1
        done
        exec /usr/bin/open -n "$2" --args --session "$3"
        """, "patch-restart", String(ProcessInfo.processInfo.processIdentifier), app.path, snapshot.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = logHandle; helper.standardError = logHandle
        try helper.run()
        restarting = true
        for window in NSApp.windows { window.ignoresMouseEvents = true }
        // Leave time for the authenticated API reply to be delivered.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { NSApp.terminate(nil) }
        return snapshot
    }
    @objc func quit() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if sender === window && !embedded { closeProjectTab(); return false }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !restarting, started {
            window.makeFirstResponder(nil)
            for tab in openTabs { tab.workspace.finishPendingGesture(); tab.workspace.plugins.synchronize() }
            for tab in openTabs where tab !== self && tab.workspace.dirty {
                if let file=tab.workspace.fileURL { try? tab.workspace.write(to:file) }
            }
            workspace.finishPendingGesture()
            // A project write can fail (for example, an unplugged drive). Keep
            // the full dirty session recoverable before allowing the app to exit.
            if !tabClosed, workspace.dirty, let file = workspace.fileURL {
                do { try workspace.write(to:file) }
                catch { workspace.message = "Project save: \(error.localizedDescription)" }
            }
            do { try writeSession() }
            catch {
                workspace.message = "Session save: \(error.localizedDescription)"
                NSAlert(error:error).runModal()
                return .terminateCancel
            }
        }
        let recordingTabs = openTabs.filter { $0.renderer?.hasActiveRecordings == true }
        if !recordingTabs.isEmpty {
            let group=DispatchGroup()
            for tab in recordingTabs { group.enter(); tab.renderer.finishRecordings { group.leave() } }
            group.notify(queue:.main) { sender.reply(toApplicationShouldTerminate:true) }
            return .terminateLater
        }
        return .terminateNow
    }
    func writeSession() throws {
        if let tabOwner { try tabOwner.writeSession(); return }
        guard started, let sessionURL else { return }
        try FileManager.default.createDirectory(at:sessionURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        let session: [String:Any] = ["pinnedPreviews":pinnedPreviewState,"midi":["followNode":midi?.followNode?.uuidString as Any? ?? NSNull()],"graph":try JSONSerialization.jsonObject(with:JSONEncoder().encode(workspace.graph)),
            "selection":workspace.selected?.uuidString as Any? ?? NSNull(),"selectedNodes":workspace.selectedIDs.map(\.uuidString),
            "playing":workspace.playing,"backdropEnabled":workspace.backdropEnabled,"backdropID":workspace.backdropID?.uuidString as Any? ?? NSNull(),
            "projectName":workspace.projectName,"file":workspace.fileURL?.path as Any? ?? NSNull(),"dirty":workspace.dirty,
            "editor":["zoom":Double(canvas.zoom),"x":Double(canvas.offset.x),"y":Double(canvas.offset.y)]]
        try JSONSerialization.data(withJSONObject:embedded ? session : sessionWithTabs(base:session),options:[.sortedKeys]).write(to:sessionURL,options:.atomic)
        // Preserve the explicit --restore graph format as well as the richer
        // session used for ordinary launches. The embedded host has its own file.
        if !embedded { try? JSONEncoder().encode(workspace.graph).write(to:recoveryURL,options:.atomic) }
    }
    func persistSession() {
        do { try writeSession() }
        catch { workspace.message = "Session save: \(error.localizedDescription)" }
    }
    func applicationWillTerminate(_ notification: Notification) {
        persistSession()
        for tab in tabChildren { tab.stop(saveSession:false) }; stop(saveSession:false)
    }
    func stop(keepAPI: Bool = false, saveSession: Bool = true) {
        if saveSession { persistSession() }

        if !headless, let url = workspace.fileURL { workspace.remember(url) }
        if !keepAPI { timer?.invalidate() }
        if let previewKeyMonitor { NSEvent.removeMonitor(previewKeyMonitor) }
        if let canvasGestureMonitor { NSEvent.removeMonitor(canvasGestureMonitor) }
        previewKeyMonitor = nil; canvasGestureMonitor = nil; observation = nil
        if !keepAPI { api?.stop(); api = nil }; midi = nil; renderer?.stop(); workspace.plugins.setSuspended(true)
        palette?.panel.close(); nodePreview?.panel.close(); midiSettings?.close()
        for preview in Array(pinnedPreviews.values) { preview.panel.close() }; pinnedPreviews.removeAll()
        for window in outputWindows.values { window.delegate = nil; window.close() }
        for window in inspectorWindows.values { window.close() }
        outputWindows.removeAll(); outputDelegates.removeAll(); inspectorWindows.removeAll()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { openTabs.isEmpty }
}


/// The standalone shell uses exactly the same editor/runtime as embedded hosts.
public enum PatchApplication {
    public static func run() {
        let app = NSApplication.shared
        let port = UInt16(ProcessInfo.processInfo.environment["PATCH_API_PORT"] ?? "9417") ?? 9417
        let controller = AppController(apiPort:port)
        app.delegate = controller
        app.run()
        withExtendedLifetime(controller) {}
    }
}

final class PatchEditorRoot: NSView {
    var patchUndo: UndoManager?
    override var undoManager: UndoManager? { patchUndo }
}
