import SwiftUI
import AppKit
import PatchCore

/// A node that works like a small app: its own window with a canvas and
/// controls. Register the node here and it opens consistently from a
/// double-click, the canvas menu, the inspector, `view` and `preview_pin`.
/// The window stays with its node, keeps its frame per node, and closes when
/// the node is deleted.
///
/// Build the window body from `NodeAppLayout`, `NodeAppSection` and
/// `NodeAppParameter` so every app shares the same toolbar, sidebar and
/// MIDI-aware controls.
///
/// An app can also register an `api`, served at `/v1/apps/{nodeID}`, so
/// agents get the window's own operations, not only raw node fields.
struct NodeApp {
    /// Names the open action: "Open \(title)".
    let title: String
    let size: NSSize
    let minSize: NSSize
    let content: (Workspace,Renderer,UUID) -> AnyView
    var api: NodeAppAPI? = nil

    static func `for`(_ node: Node) -> NodeApp? {
        if node.kind == .posterComposer {
            return NodeApp(title:"Poster Editor",size:.init(width:1380,height:900),minSize:.init(width:1040,height:680),content:{ AnyView(PosterEditor(workspace:$0,renderer:$1,id:$2)) },api:PosterAPI.api)
        }
        if node.hasLiquidChromeControls {
            return NodeApp(title:"Liquid Chrome Editor",size:.init(width:1240,height:860),minSize:.init(width:920,height:680)) { AnyView(LiquidChromeEditor(workspace:$0,renderer:$1,id:$2)) }
        }
        if node.hasLiquidMetalControls {
            return NodeApp(title:"Blob Editor",size:.init(width:1040,height:760),minSize:.init(width:780,height:640)) { AnyView(LiquidMetalEditor(workspace:$0,renderer:$1,id:$2)) }
        }
        if node.kind == .metroSequencer {
            return NodeApp(title:"Metro Instrument",size:.init(width:1160,height:850),minSize:.init(width:1060,height:800)) { AnyView(MetroEditor(workspace:$0,renderer:$1,id:$2)) }
        }
        if node.kind == .loopmother {
            return NodeApp(title:"Loopmother",size:.init(width:1110,height:620),minSize:.init(width:760,height:480)) { AnyView(LoopmotherEditor(workspace:$0,renderer:$1,id:$2)) }
        }
        return nil
    }
}

/// What an app edits: the live workspace from its window, or a draft graph
/// for an API request, which is validated and protected before it applies.
protocol GraphDocument: AnyObject {
    var graph: Graph { get }
    func edit(_ action: String,_ update: (inout Graph) throws -> Void)
}
extension Workspace: GraphDocument {}
final class GraphDraft: GraphDocument {
    private(set) var graph: Graph
    private(set) var error: Error?
    init(_ graph: Graph) { self.graph = graph }
    func edit(_ action: String,_ update: (inout Graph) throws -> Void) {
        guard error == nil else { return }
        do { var next = graph; try update(&next); graph = next } catch { self.error = error }
    }
}
/// An app's API. `state` describes what the window shows; each command runs
/// the window's own operation on a draft and returns its result.
struct NodeAppAPI {
    struct Context { let document: GraphDraft; let workspace: Workspace; let renderer: Renderer; let id: UUID }
    /// Op name → one-line usage, listed by GET.
    let commands: [String:String]
    let state: (Context) throws -> [String:Any]
    let run: (Context,[String:Any]) throws -> [String:Any]
}

/// The sidebar button for a node with an app.
struct NodeAppButton: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    let app: NodeApp
    var body: some View {
        Button("Open \(app.title) ↗") { workspace.onPinnedPreview?(id) }.buttonStyle(.borderedProminent)
    }
}

/// Toolbar across the top, the node's canvas filling the middle, and a
/// scrolling control column on the right (and optionally a left column).
struct NodeAppLayout<Toolbar: View,Canvas: View,Sidebar: View,Leading: View>: View {
    var sidebarWidth: CGFloat = 320
    var leadingWidth: CGFloat = 220
    var footer: String? = nil
    @ViewBuilder var toolbar: () -> Toolbar
    @ViewBuilder var canvas: () -> Canvas
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var leading: () -> Leading
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) { toolbar() }.padding(.horizontal,16).padding(.vertical,10)
            Divider()
            HStack(spacing:0) {
                if Leading.self != EmptyView.self {
                    leading().frame(width:leadingWidth).frame(maxHeight:.infinity,alignment:.top)
                    Divider()
                }
                canvas().frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                ScrollView { VStack(alignment:.leading,spacing:22) { sidebar() }.padding(20).frame(maxWidth:.infinity,alignment:.leading) }
                    .frame(width:sidebarWidth)
            }
            if let footer { Text(footer).font(.caption).foregroundStyle(.orange).padding(8) }
        }.background(Color(nsColor:.patchPanel)).preferredColorScheme(.dark)
    }
}
extension NodeAppLayout where Leading == EmptyView {
    init(sidebarWidth: CGFloat = 320,footer: String? = nil,@ViewBuilder toolbar: @escaping () -> Toolbar,@ViewBuilder canvas: @escaping () -> Canvas,@ViewBuilder sidebar: @escaping () -> Sidebar) {
        self.init(sidebarWidth:sidebarWidth,footer:footer,toolbar:toolbar,canvas:canvas,sidebar:sidebar,leading:{ EmptyView() })
    }
}

/// A titled group of sidebar controls.
struct NodeAppSection<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            VStack(alignment:.leading,spacing:2) {
                Text(title.uppercased()).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                if let caption { Text(caption).font(.system(size:11)).foregroundStyle(.tertiary) }
            }
            content()
        }
    }
}

/// One node parameter, chosen by its spec: a picker for choices, otherwise a
/// `ParameterControl`. Each drag is one undo step and the row is MIDI-learnable.
struct NodeAppParameter: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    let key: String
    var title: String? = nil
    private var node: Node? { workspace.graph.node(id) }
    var body: some View {
        if let spec = node?.parameterSpecs.first(where:{ $0.key == key }) {
            if let choices = spec.choices {
                Picker(title ?? spec.title,selection:Binding(get:{ Int((node?.value(key) ?? spec.initial).rounded()) },set:{ workspace.parameter(id,key,Double($0)) })) {
                    ForEach(choices.indices,id:\.self) { Text(choices[$0]).tag($0) }
                }.font(.system(size:12))
            } else {
                VStack(alignment:.leading,spacing:5) {
                    NodeAppSliderTitle(title:title ?? spec.title,value:node?.value(key) ?? spec.initial,range:spec.min...spec.max,step:spec.step) { workspace.parameter(id,key,$0) }
                    ParameterControl(value:Binding(get:{ node?.value(key) ?? spec.initial },set:{ workspace.parameter(id,key,$0) }),in:spec.min...spec.max,step:spec.step,showsValueField:spec.step != nil,spec:spec,colorHue:node?.value("hue") ?? 0,onEditingChanged:{ editing in
                        if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(spec.title)") }
                    }).controlSize(.small)
                }.midiParameter(workspace:workspace,id:id,key:key)
            }
        }
    }
}

/// A slider's title with its current value, typed to set it exactly. Sliders
/// that already show a value field (stepped or bipolar) get only the title.
struct NodeAppSliderTitle: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let set: (Double) -> Void
    private var showsField: Bool { step == nil }
    private var decimals: Int { let span = range.upperBound-range.lowerBound; return span >= 100 ? 0 : span >= 10 ? 1 : 2 }
    var body: some View {
        HStack {
            Text(title).font(.system(size:12,weight:.medium))
            Spacer(minLength:4)
            if showsField {
                TextField(title,value:Binding(get:{ value },set:{ if $0.isFinite { set(min(range.upperBound,max(range.lowerBound,$0))) } }),format:.number.precision(.fractionLength(decimals)))
                    .textFieldStyle(.roundedBorder).font(.system(size:11,design:.monospaced)).multilineTextAlignment(.trailing).frame(width:72)
                    .labelsHidden().help("Type an exact value")
            }
        }
    }
}
