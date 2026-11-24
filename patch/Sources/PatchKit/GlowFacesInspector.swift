import AppKit
import SwiftUI
import PatchCore

struct GlowFacesInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    @State private var preview=false
    var node: Node? { workspace.graph.node(id) }
    var paletteConnected: Bool { workspace.graph.edges.contains { $0.target == id && $0.input == 0 } }
    @ViewBuilder func control(_ key: String) -> some View {
        if let p=CollectionStyle.glowParameters.first(where: { $0.key == key }) {
            VStack(spacing:5) {
                HStack { Text(p.title);Spacer();Text((node?.value(key) ?? p.initial).formatted(.number.precision(.fractionLength(key == "previewFaces" ? 0:2)))).font(.editorValue).foregroundStyle(.secondary) }
                ParameterControl(value:Binding(get:{ node?.value(key) ?? p.initial },set:{ workspace.parameter(id,key,p.step == 1 ? $0.rounded():$0) }),in:p.min...p.max,step:p.step,spec:p,onEditingChanged:{ editing in
                    if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(p.title)") }
                }).tint(Color(nsColor:.patchAccent)).controlSize(.small)
            }.midiParameter(workspace:workspace,id:id,key:key)
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            control("brightness");control("center_glow");control("falloff")
            HStack {
                Text("Color");Spacer()
                if paletteConnected { Text("Palette input").font(.caption).foregroundStyle(.secondary) }
                else {
                    PanelColorWell(selection:Binding(get:{ PaletteColor(hex:UInt32(node?.value("color") ?? 16777215)).displayColor },set:{ value in
                        if let c=NSColor(value).usingColorSpace(.sRGB) { workspace.parameter(id,"color",Double(PaletteColor(c.redComponent,c.greenComponent,c.blueComponent).hex)) }
                    }),title:"Color").frame(width:64,height:24)
                }
            }.midiParameter(workspace:workspace,id:id,key:"color")
            DisclosureGroup("Preview",isExpanded:$preview) { control("previewFaces").padding(.top,8) }
        }
    }
}
