import SwiftUI
import PatchCore

struct PoseInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    @State private var expanded: Set<String> = ["LINES","COLOR"]
    var node: Node? { workspace.graph.node(id) }
    func apply(_ name: String) {
        workspace.edit("Pose Style: \(name)") { graph in
            guard let index = graph.nodes.firstIndex(where:{ $0.id == id }) else { return }
            graph.nodes[index].parameters = PoseStyle.preset(name)
            // Presets set base values; modulation connections are preserved.
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("POSE STYLE").font(.editorHeading).foregroundStyle(.secondary)
                Spacer()
                Menu("Presets") { ForEach(PoseStyle.presetNames,id:\.self) { name in Button(name) { apply(name) } } }
                Button("Reset") { apply("Classic") }.buttonStyle(.plain).font(.system(size:10))
            }
            ForEach(PoseStyle.groups,id:\.0) { title,parameters in
                DisclosureGroup(isExpanded:Binding(get:{ expanded.contains(title) },set:{ open in if open { expanded.insert(title) } else { expanded.remove(title) } })) {
                    VStack(alignment:.leading,spacing:14) {
                        ForEach(parameters,id:\.key) { p in
                            if p.key == "hue" {
                                PoseColorControls(workspace:workspace,id:id)
                                if node?.value("color") == 0 { Text("Choose Limbs, Position or Rainbow to use color.").font(.system(size:10)).foregroundStyle(.secondary) }
                            } else if p.key == "backgroundHue" {
                                if node?.value("background") == 2 { PoseColorControls(workspace:workspace,id:id,background:true) }
                            } else if ["saturation","brightness","backgroundSaturation","backgroundBrightness"].contains(p.key) {
                                // Edited together in the visual color controls above.
                            } else if let choices = p.choices {
                                Picker(p.title,selection:Binding(get:{ Int(node?.value(p.key) ?? p.initial) },set:{ workspace.parameter(id,p.key,Double($0)) })) {
                                    ForEach(Array(choices.enumerated()),id:\.offset) { i,name in Text(name).tag(i) }
                                }
                            } else {
                                VStack(spacing:5) {
                                    HStack {
                                        Text(p.title)
                                        Spacer()
                                        TextField(p.title,value:Binding(get:{ node?.value(p.key) ?? p.initial },set:{ value in
                                            guard value.isFinite else { return }
                                            workspace.parameter(id,p.key,min(p.max,max(p.min,value)))
                                        }),format:.number.precision(.fractionLength(0...2))).textFieldStyle(.squareBorder).frame(width:62)
                                    }
                                    ParameterControl(value:Binding(get:{ node?.value(p.key) ?? p.initial },set:{ workspace.parameter(id,p.key,$0) }),in:p.min...p.max,step:p.step,showsValueField:false,spec:p,onEditingChanged:{ editing in
                                        if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(p.title)") }
                                    }).controlSize(.small).tint(Color(nsColor:.patchAccent))
                                }.midiParameter(workspace:workspace,id:id,key:p.key)
                            }
                        }
                    }.padding(.top,10)
                } label: { Text(title).font(.editorItem.weight(.medium)) }
                Divider()
            }
            Text("Continuous controls accept LFO, Noise and Audio Envelope modulation above. Presets keep modulation connections.").font(.system(size:10)).foregroundStyle(.secondary)
        }
    }
}
