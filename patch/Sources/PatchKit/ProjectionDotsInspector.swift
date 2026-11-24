import SwiftUI
import PatchCore

struct ProjectionDotsInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    var node: Node? { workspace.graph.node(id) }
    func control(_ key: String) -> some View {
        let spec = (node?.kind.parameters ?? ProjectionDotsStyle.parameters).first { $0.key == key }!
        let binding = Binding<Double>(get:{ node?.value(key) ?? spec.initial }, set:{ value in
            guard value.isFinite else { return }
            workspace.parameter(id,key,max(spec.min,min(spec.max,value)))
        })
        return Group {
            if let choices = spec.choices {
                Picker(spec.title,selection:binding) {
                    ForEach(Array(choices.enumerated()),id:\.offset) { index,title in Text(title).tag(Double(index)) }
                }
            } else {
                VStack(spacing:4) {
                    HStack {
                        Text(spec.title); Spacer()
                        ProjectionDotsNumberField(title:spec.title,value:binding)
                            .id("\(id)-\(key)")
                            .frame(width:76)
                    }
                    ParameterControl(value:binding,in:spec.min...spec.max,step:spec.step,showsValueField:false,spec:spec,onEditingChanged:{ editing in
                        if editing { workspace.beginGesture() } else { workspace.endGesture("Adjust Projection Dots") }
                    }).controlSize(.small)
                }
            }
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            if node?.kind == .projectionDots {
                Picker("Colors",selection:Binding<String>(get:{
                    workspace.graph.edges.first { $0.target == id && $0.input == 0 }?.source.uuidString ?? ""
                },set:{ value in
                    workspace.edit("Change Dot Colors") { graph in
                        if let source = UUID(uuidString:value) { try graph.connect(source,to:id) }
                        else { graph.edges.removeAll { $0.target == id && $0.input == 0 } }
                    }
                })) {
                    Text("White").tag("")
                    ForEach(workspace.graph.nodes.filter { $0.kind.outputType == .dots }) { source in
                        Text(source.name).tag(source.id.uuidString)
                    }
                }
                control("sheetWidth"); control("sheetHeight")
                control("diameter"); control("gap")
                if let node {
                    let count = ProjectionDotsStyle.grid(node)
                    let size = workspace.graph.videoDimensions(id)
                    HStack { Text("Grid"); Spacer(); Text("\(count.columns) × \(count.rows)").monospacedDigit() }.foregroundStyle(.secondary)
                    HStack { Text("Video"); Spacer(); Text("\(size.width) × \(size.height)").monospacedDigit() }.foregroundStyle(.secondary)
                }
                DisclosureGroup("Edges") { control("softness").padding(.top,8) }
            } else if node?.kind == .dotColors {
                control("pattern"); control("brightness")
                if (node?.value("pattern") ?? 0) < 2 {
                    control("poleTop"); control("poleBottom"); control("distribution")
                    control("extent"); control("spectralShift"); control("phase"); control("speed")
                } else if [2.0,3.0,5.0].contains(node?.value("pattern") ?? 0) {
                    control("hue"); control("saturation"); control("phase"); control("speed")
                }
            } else if node?.kind == .flipDots {
                Text("Messages").font(.headline)
                TextEditor(text:Binding(get:{ node?.text ?? "" },set:{ value in
                    workspace.update(id,action:"Edit Messages") { $0.text = String(value.prefix(1024)) }
                })).font(.system(size:13,design:.monospaced)).frame(height:100)
                    .help("One message per line · up to 8 messages · 5 × 7 dot letters")
                control("hold"); control("flip"); control("sweep"); control("jitter"); control("direction")
                DisclosureGroup("Color") {
                    VStack(spacing:12) { control("hue"); control("saturation"); control("brightness"); control("offLevel") }.padding(.top,8)
                }
            }
        }
    }

}

/// Keep incomplete typing separate from the validated graph value.
private struct ProjectionDotsNumberField: View {
    let title: String
    @Binding var value: Double
    @State private var draft = ""
    @State private var editingStart = ""
    @FocusState private var focused: Bool

    private func displayValue() -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...4)))
    }

    private func commit() {
        let text = draft.trimmingCharacters(in:.whitespacesAndNewlines)
        if draft != editingStart, !text.isEmpty, let number = try? Double(text,format:.number), number.isFinite {
            // The binding applies the parameter bounds once the edit is complete.
            value = number
        }
        draft = displayValue()
        editingStart = draft
    }

    var body: some View {
        TextField(title,text:$draft)
            .textFieldStyle(.squareBorder)
            .focused($focused)
            .onAppear { draft = displayValue(); editingStart = draft }
            .onChange(of:value) { _,_ in
                if !focused { draft = displayValue(); editingStart = draft }
            }
            .onChange(of:focused) { _,editing in
                if editing { editingStart = draft } else { commit() }
            }
            .onSubmit { commit(); focused = false }
            .onExitCommand { draft = displayValue(); editingStart = draft; focused = false }
    }
}
