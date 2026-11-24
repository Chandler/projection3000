import AppKit
import Metal
import SwiftUI
import PatchCore

/// One independent editor/runtime per host. Video leaves through the graph's
/// regular Syphon/NDI nodes, never through an application-specific frame API.
@objc(PatchEditorController)
public final class PatchEditorController: NSViewController {
    private let editor: AppController
    private var hostMenu: NSMenu?
    private var patchMenu: NSMenu?
    private var stopped = false
    private var fitted = false
    @objc public private(set) var active = false

    @objc(initWithWindow:sessionURL:apiPort:error:)
    public init(window: NSWindow, sessionURL: URL, apiPort: UInt16) throws {
        editor = AppController(hostWindow:window,sessionURL:sessionURL,apiPort:apiPort)
        super.init(nibName:nil,bundle:nil)
        do { try editor.start() } catch { editor.stop(); throw error }
        editor.renderer.setHostManagedOutputs()
        view = editor.editorRoot
        editor.editorVisible = false; editor.editorFocused = false
    }
    required init?(coder: NSCoder) { fatalError("Use init(window:sessionURL:apiPort:)") }

    @objc public func setEditorActive(_ value: Bool) {
        guard !stopped else { return }
        setEditorVisible(value)
        setEditorFocused(value)
        if value { editor.window.makeFirstResponder(editor.canvas) }
    }

    @objc public func setEditorVisible(_ value: Bool) {
        guard !stopped, value != editor.editorVisible else { return }
        editor.editorVisible = value
        if value {
            view.layoutSubtreeIfNeeded()
            if !fitted { fitted = true; if !editor.restoredEditor { editor.canvas.fit() } }
            editor.updateTitle(); editor.canvas.sync()
        } else {
            setEditorFocused(false)
            editor.palette?.panel.close(); editor.nodePreview?.panel.close()
            editor.persistSession()
        }
        for video in editor.renderer.views.allObjects where video.isDescendant(of:view) { video.isPaused = !value }
    }

    // Split hosts can keep presentation alive while moving keyboard/menu focus.
    // Do not replace the clicked first responder or write the session on clicks.
    @objc public func setEditorFocused(_ value: Bool) {
        guard !stopped, value != active else { return }
        active = value; editor.editorFocused = value
        if value {
            hostMenu = NSApp.mainMenu
            if let patchMenu { NSApp.mainMenu = patchMenu }
            else { editor.makeMenus(hostMenu:hostMenu); patchMenu = NSApp.mainMenu }
        } else {
            editor.canvas.cancelQuickGesture(); editor.midi.setLearning(false)
            editor.palette?.panel.close(); editor.nodePreview?.panel.close()
            if NSApp.mainMenu === patchMenu { NSApp.mainMenu = hostMenu }
        }
    }

    @objc public func shouldTerminateApplication(_ application: NSApplication) -> NSApplication.TerminateReply {
        editor.applicationShouldTerminate(application)
    }
    @objc public func receiveHostFader(_ value: NSNumber?) {
        guard !stopped else { return }
        editor.midi.receiveHostFader(value?.doubleValue)
    }
    @objc public var followsHostCrossfader: Bool { !stopped && editor.midi.followsCrossfader }
    @objc public var ownsHostAPC: Bool { !stopped && editor.midi.ownsAPC }
    @objc public func receiveHostAPC(_ messages: [[NSNumber]]) {
        guard !stopped else { return }
        for message in messages where message.count == 3 { editor.midi.receiveAPC(status:message[0].intValue,number:message[1].intValue,value:message[2].intValue) }
    }
    @objc public var followsHostChannelFaders: Bool { !stopped && editor.midi.followsChannelFaders }
    @objc public func receiveHostChannelFaders(_ values: [NSNumber]) {
        guard !stopped else { return }
        editor.midi.receiveHostChannelFaders(values.map(\.doubleValue))
    }
    @objc(instantiateLibrarySubpatch:outputID:error:)
    public func instantiateLibrarySubpatch(_ id: String, outputID: String) throws -> NSDictionary {
        guard !stopped,let output = UUID(uuidString:outputID) else { throw GraphError("Invalid subpatch output or inactive editor") }
        return try stageOutput(PatchLibrary.template(id),output:output)
    }

    @objc(instantiateLibrarySubpatch:outputID:inputSource:error:)
    public func instantiateLibrarySubpatch(_ id: String, outputID: String, inputSource: String) throws -> NSDictionary {
        guard !stopped,let output = UUID(uuidString:outputID) else { throw GraphError("Invalid subpatch output or inactive editor") }
        return try stageOutput(PatchLibrary.template(id),output:output,inputSource:inputSource)
    }

    @objc(encodeProcessor:input:output:commandBuffer:time:context:error:)
    public func encodeProcessor(_ source: String, input: MTLTexture, output: MTLTexture,
                                commandBuffer: MTLCommandBuffer, time: Double, context: String) throws {
        try editor.renderer.encodeAdjustment(source, input: input, output: output, command: commandBuffer, time: time)
    }

    @objc(duplicatePublishedOutput:error:)
    public func duplicatePublishedOutput(_ source: String) throws -> NSDictionary {
        guard !stopped else { throw GraphError("Inactive editor") }
        let origin = try editor.workspace.graph.templateForPublishedOutput(source)
        return try stageOutput(origin.template,output:origin.outputID,inputSource:origin.inputSource,copyInputs:true)
    }

    private func stageOutput(_ template: SubpatchTemplate, output: UUID, inputSource: String? = nil, copyInputs: Bool = false) throws -> NSDictionary {
        let placed = try editor.workspace.stageLibraryOutput(template,outputID:output,inputSource:inputSource,copyInputs:copyInputs)
        do { try editor.writeSession() }
        catch {
            if let raw = placed["id"] as? String,let instance = UUID(uuidString:raw) { try editor.workspace.discardLibraryInsertion(instance) }
            throw error
        }
        return placed as NSDictionary
    }
    @objc(commitLibrarySubpatch:)
    public func commitLibrarySubpatch(_ id: String) {
        if let instance = UUID(uuidString:id) { editor.workspace.commitLibraryInsertion(instance) }
    }
    @objc(discardLibrarySubpatch:error:)
    public func discardLibrarySubpatch(_ id: String) throws {
        guard let instance = UUID(uuidString:id) else { throw GraphError("Invalid subpatch instance") }
        try editor.workspace.discardLibraryInsertion(instance)
        try editor.writeSession()
    }
    private func outputOwner(_ source: String) -> (node: UUID, component: Component?)? {
        let graph = editor.workspace.graph
        guard let port = graph.publishablePorts.first(where:{ $0.id == source }) else { return nil }
        let group = graph.groups.first { $0.interface?.ports.contains { $0.output && $0.node == port.nodeID && $0.key == port.portID } == true }
        return (port.nodeID,group)
    }

    @objc(controlsForPublishedOutput:)
    public func controlsForPublishedOutput(_ source: String) -> NSView? {
        guard !stopped, let group = outputOwner(source)?.component,
              group.interface?.parameters.isEmpty == false else { return nil }
        return NSHostingView(rootView:PublishedControls(workspace:editor.workspace,groupID:group.id))
    }
    @objc(focusPublishedOutput:)
    public func focusPublishedOutput(_ source: String) {
        guard let owner = outputOwner(source) else { return }
        editor.workspace.focusSelection(owner.component?.id ?? owner.node)
        editor.canvas.frameSelection()
    }
    @objc public func frameGraph() { view.layoutSubtreeIfNeeded(); editor.canvas.fit() }
    @objc public func saveSession() { editor.persistSession() }
    @objc public var publishedOutputs: NSArray { editor.renderer.publishedOutputs as NSArray }
    @objc public func retainPublishedOutputs(_ ids: [String]) { editor.renderer.retainPublishedOutputs(Set(ids)) }
    @objc public var paletteSources: NSArray { (editor.api?.paletteSources ?? []) as NSArray }
    @objc public var state: NSDictionary { ((try? editor.api?.stateObject()) ?? [:]) as NSDictionary }
    @objc public var renderedFrames: Int { editor.renderer.renderedFrames }
    @objc public func stop() {
        guard !stopped else { return }
        setEditorActive(false); stopped = true; editor.stop()
    }
}

// SwiftPM's generated Bundle.module falls back to its build directory. Packaged
// applications resolve the explicit nested resource bundle first, so relocation
// never depends on a developer checkout.
enum PatchResources {
    static func shaderURL() throws -> URL {
        if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("PatchResources.bundle"),
           let bundle = Bundle(url:bundleURL), let url = bundle.url(forResource:"Shaders",withExtension:"metal") { return url }
        if let url = Bundle.main.url(forResource:"Shaders",withExtension:"metal") { return url }
        if let url = Bundle.module.url(forResource:"Shaders",withExtension:"metal") { return url }
        throw GraphError("Missing Patch shaders")
    }
}

private struct PublishedControls: View {
    @ObservedObject var workspace: Workspace
    let groupID: UUID
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(workspace.graph.component(groupID)?.interface?.parameters ?? []) { control in
                NodeAppParameter(workspace:workspace,id:control.node,key:control.key,title:control.name)
            }
        }.padding(6)
    }
}
