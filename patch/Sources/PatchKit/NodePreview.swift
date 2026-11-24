import AppKit
import SwiftUI
import PatchCore

struct NodePreviewContent: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    var fixedID: UUID? = nil
    var node: Node? { workspace.graph.previewNode(fixedID ?? workspace.selected) }
    var emptyMessage: String? {
        guard let node else { return "No node selected" }
        if node.kind.previewKind == .empty { return "No preview for this node" }
        if node.kind.isOutput { return workspace.graph.edges.contains(where:{ $0.target == node.id }) ? nil : "No input" }
        let status = renderer.status[node.id] ?? "Loading…"
        if ["No input","Missing input","Choose a file","Choose an audio file","Waiting for geometry","Waiting for audio","Disabled","Paused"].contains(status) { return status }
        if !node.enabled && node.kind.inputs.isEmpty { return "Node disabled" }
        return nil
    }
    var body: some View {
        VStack(spacing:0) {
            ZStack {
                Color.black
                if let node,node.kind.isMIDINode {
                    ScrollView {
                        VStack(alignment:.leading,spacing:12) {
                            Text(node.kind.title).font(.headline)
                            if node.kind == .midiOut { MIDIOutputInspector(workspace:workspace,renderer:renderer,id:node.id) }
                            else { MIDIMonitorInspector(renderer:renderer,id:node.id) }
                        }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                    }
                } else if let node, emptyMessage == nil {
                    MetalPreview(renderer:renderer,id:node.id).id(node.id)
                } else {
                    Text(emptyMessage ?? "No preview").font(.system(size:13)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack {
                Text(node.map { $0.kind.isMIDINode ? "MIDI · NOTES & CONTROL" : $0.kind.outputType == .trace ? "TRACE · PATH PREVIEW" : $0.kind.previewKind == .palette ? "PALETTE · ORDERED COLORS" : $0.kind.previewKind == .control ? "CONTROL · LAST 5 SECONDS" : $0.kind == .yoloPose ? "POSES · DETECTION PREVIEW" : $0.kind == .faceDetect ? "FACES · DETECTION PREVIEW" : $0.kind.previewKind == .audio ? "AUDIO · WAVEFORM" : ($0.kind.previewKind == .geometry ? "GEOMETRY · LINE STRIP" : "VIDEO") } ?? "EMPTY")
                Spacer()
                if let node { Text(renderer.status[node.id] ?? "Loading…").lineLimit(1) }
                if fixedID == nil {
                    if let node { Button("Keep Open") { workspace.onPinnedPreview?(node.id) }.help("Keep this node in its own window while selecting others") }
                    Text("Space / Esc Close").foregroundStyle(.tertiary)
                } else { Text("Stays with this node").foregroundStyle(.tertiary) }
            }.font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).padding(10).background(Color(nsColor:.patchPanel))
        }.preferredColorScheme(.dark)
    }
}
final class NodePreviewController: NSObject, NSWindowDelegate {
    private var positioned = false
    private var displayedNode: UUID?
    let panel: NSWindow
    let workspace: Workspace
    let renderer: Renderer
    let fixedID: UUID?
    var onClose: (() -> Void)?
    init(workspace: Workspace,renderer: Renderer,fixedID: UUID? = nil) {
        self.workspace = workspace; self.renderer = renderer; self.fixedID=fixedID
        panel = NSWindow(contentRect:.init(x:0,y:0,width:720,height:440),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        super.init()
        panel.isReleasedWhenClosed = false; panel.level = .normal; panel.hidesOnDeactivate = false
        panel.minSize = .init(width:320,height:220); panel.backgroundColor = .black; panel.delegate = self
        panel.contentView = contentView()
        if let id=fixedID,let node=workspace.graph.node(id),let app=NodeApp.for(node) {
            panel.setContentSize(app.size);panel.minSize = app.minSize
        } else if fixedID != nil {
            // Keep Open previews float: the editor and output windows never cover them.
            panel.level = .floating
        }
        panel.setFrameAutosaveName(fixedID.map { "Patch.PinnedPreview.\($0)" } ?? "Patch.NodePreview")
    }
    private func contentView() -> NSView {
        if let id=fixedID,let node=workspace.graph.node(id),let app=NodeApp.for(node) {
            return NSHostingView(rootView:app.content(workspace,renderer,id).disclosureGroupStyle(PatchDisclosureStyle()))
        }
        return NSHostingView(rootView:NodePreviewContent(workspace:workspace,renderer:renderer,fixedID:fixedID).disclosureGroupStyle(PatchDisclosureStyle()))
    }
    func show(over window: NSWindow) {
        if !positioned { positioned = true; panel.setFrameOrigin(.init(x:window.frame.midX-panel.frame.width/2,y:window.frame.midY-panel.frame.height/2)) }
        if fixedID == nil { workspace.previewVisible = true }; sync(force:true); panel.makeKeyAndOrderFront(nil)
    }
    func sync(force: Bool = false) {
        guard force || panel.isVisible else { return }
        let id = workspace.graph.previewNode(fixedID ?? workspace.selected)?.id
        if force || id != displayedNode {
            // Replace the hosting tree before showing a reused panel. A drawable
            // from the previous selection must never flash during SwiftUI layout.
            displayedNode = id
            panel.contentView = contentView()
        }
        panel.title = (fixedID ?? workspace.selected).flatMap { workspace.graph.node($0)?.name ?? workspace.graph.component($0)?.name }.map { fixedID == nil ? "Preview · \($0)" : $0 } ?? "Node Preview"
        if fixedID == nil { renderer.setPreviewNode(workspace.graph.previewNode(workspace.selected)?.id) }
    }
    func windowWillClose(_ notification: Notification) {
        if fixedID == nil { workspace.previewVisible = false; renderer.setPreviewNode(nil) }
        onClose?()
    }
}
