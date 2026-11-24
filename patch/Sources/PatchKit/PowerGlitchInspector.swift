import SwiftUI
import PatchCore

struct PowerGlitchInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    @State private var timing=false
    @State private var spatial=false
    @State private var corruption=false
    var node: Node? { workspace.graph.node(id) }
    @ViewBuilder func control(_ key: String) -> some View {
        if let p=PowerGlitchStyle.parameters.first(where: { $0.key == key }) {
            if let choices=p.choices {
                Picker(p.title,selection:Binding(get:{ Int(node?.value(key) ?? p.initial) },set:{ workspace.parameter(id,key,Double($0)) })) {
                    ForEach(Array(choices.enumerated()),id:\.offset) { index,title in Text(title).tag(index) }
                }.midiParameter(workspace:workspace,id:id,key:key)
            } else {
                VStack(spacing:5) {
                    HStack { Text(p.title);Spacer();Text((node?.value(key) ?? p.initial).formatted(.number.precision(.fractionLength(p.step == 1 || key == "flashMs" ? 0:2)))).font(.editorValue).foregroundStyle(.secondary) }
                    ParameterControl(value:Binding(get:{ node?.value(key) ?? p.initial },set:{ workspace.parameter(id,key,p.step == 1 ? $0.rounded():$0) }),in:p.min...p.max,step:p.step,spec:p,onEditingChanged:{ editing in
                        if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(p.title)") }
                    }).tint(Color(nsColor:.patchAccent)).controlSize(.small)
                }.midiParameter(workspace:workspace,id:id,key:key)
            }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            control("recipe");control("shape");control("burstRate");control("flashes");control("rate")
            DisclosureGroup("Flash timing",isExpanded:$timing) {
                VStack(spacing:12) { control("flashMs");control("variation") }.padding(.top,8)
            }
            DisclosureGroup("Spatial cluster",isExpanded:$spatial) {
                VStack(spacing:12) { control("spread");control("jitter");control("blocks");control("dropout") }.padding(.top,8)
            }
            DisclosureGroup("Corruption",isExpanded:$corruption) {
                VStack(spacing:12) { control("blackout");control("bands");control("static");control("seed") }.padding(.top,8)
            }
        }
    }
}
