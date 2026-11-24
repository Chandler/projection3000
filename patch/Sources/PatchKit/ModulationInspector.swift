import SwiftUI
import PatchCore

struct ModulationInspector: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var userLibrary = UserNodeLibrary.shared
    let renderer: Renderer
    let id: UUID
    var node: Node? { workspace.graph.node(id) }
    var controls: [Node] { workspace.graph.nodes.filter { $0.kind.outputType == .control && $0.id != id } }
    func update(_ key: String,_ change: (inout ParameterModulation)->Void) {
        workspace.edit("Edit Modulation") { graph in
            guard let i = graph.nodes.firstIndex(where:{ $0.id == id }),var binding = graph.nodes[i].modulations?[key] else { return }
            change(&binding); graph.nodes[i].modulations?[key] = binding
        }
    }
    var body: some View {
        if let node {
            VStack(alignment:.leading,spacing:10) {
                if node.kind == .apc40 {
                    Text("FADERS").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
                    TimelineView(.periodic(from:.now,by:0.1)) { _ in
                        let values = renderer.apcState.snapshot
                        ForEach(Array(0..<8) + [24,25],id:\.self) { output in
                            VStack(spacing:5) {
                                HStack {
                                    Text(APC40.outputs[output])
                                    Spacer()
                                    Text(values[output].map { String(format:"%.0f%%",$0*100) } ?? "Base").monospacedDigit().foregroundStyle(.secondary)
                                    Button { try? workspace.midi?.setAPCControl(output:output,value:nil) } label: {
                                        Image(systemName:"arrow.counterclockwise")
                                    }.buttonStyle(.plain).disabled(values[output] == nil).help("Release control to target base values")
                                }
                                Slider(value:Binding(get:{ renderer.apcState.snapshot[output] ?? 0 },set:{ try? workspace.midi?.setAPCControl(output:output,value:$0) }),in:0...1)
                                    .controlSize(.small).accessibilityLabel(APC40.outputs[output])
                            }.disabled(workspace.midi == nil)
                        }
                    }
                    DisclosureGroup("Control values") {
                    TimelineView(.periodic(from:.now,by:0.1)) { _ in
                        ForEach(APC40.outputs.indices,id:\.self) { output in
                            HStack { Text(APC40.outputs[output]); Spacer(); Text(renderer.apcState.snapshot[output].map { String(format:"%.3f",$0) } ?? "Waiting") }.font(.system(size:10,design:.monospaced))
                        }
                    }
                    }
                } else if node.kind.outputType == .control {
                    TimelineView(.periodic(from:.now,by:0.1)) { _ in
                    HStack { Text("CONTROL OUTPUT"); Spacer(); Text((renderer.controlValues[id] ?? 0).formatted(.number.precision(.fractionLength(3)))) }.font(.system(size:10,design:.monospaced))
                    }
                    Text("Drag the CONTROL output onto a node, then choose a parameter.").font(.system(size:10)).foregroundStyle(.secondary)
                }
                if !node.modulationSpecs.isEmpty {
                    HStack {
                        Text("MODULATION").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Menu("Add…") {
                            ForEach(node.modulationSpecs,id:\.key) { spec in
                                Menu(spec.title) {
                                    ForEach(controls) { source in
                                        Menu(source.name) { ForEach(source.kind.outputs.indices,id:\.self) { output in
                                            Button(source.kind.outputs[output]) { workspace.edit("Connect Modulation") { try $0.modulate(id,key:spec.key,source:source.id,output:output) } }
                                        } }
                                    }
                                }
                            }
                        }.disabled(controls.isEmpty)
                    }
                    if controls.isEmpty { Text("Add LFO, Noise or Audio Envelope to drive parameters.").font(.system(size:10)).foregroundStyle(.secondary) }
                    ForEach((node.modulations ?? [:]).keys.sorted(),id:\.self) { key in
                        if let binding = node.modulations?[key],let spec = node.modulationSpecs.first(where:{ $0.key == key }) {
                            VStack(alignment:.leading,spacing:8) {
                                HStack {
                                    Toggle(spec.title,isOn:Binding(get:{ self.node?.modulations?[key]?.enabled ?? false },set:{ active in update(key) { $0.enabled = active } })).toggleStyle(.checkbox)
                                    Spacer()
                                    Button("×") { workspace.edit("Remove Modulation") { g in if let i = g.nodes.firstIndex(where:{ $0.id == id }) { g.nodes[i].modulations?.removeValue(forKey:key) } } }.buttonStyle(.plain).help("Disconnect modulation")
                                }
                                Picker("Source",selection:Binding(get:{ self.node?.modulations?[key]?.source ?? binding.source },set:{ source in update(key) { $0.source = source; $0.output = nil } })) {
                                    ForEach(controls) { source in Text(source.name).tag(source.id) }
                                }
                                if let source = workspace.graph.node(binding.source), source.kind.outputs.count > 1 {
                                    Picker("Output",selection:Binding(get:{ self.node?.modulations?[key]?.outputIndex ?? 0 },set:{ output in update(key) { $0.output = output } })) {
                                        ForEach(source.kind.outputs.indices,id:\.self) { output in Text(source.kind.outputs[output]).tag(output) }
                                    }
                                }
                                HStack {
                                    Text("From")
                                    TextField("Min",value:Binding(get:{ self.node?.modulations?[key]?.minimum ?? spec.min },set:{ value in update(key) { $0.minimum = value } }),format:.number.precision(.fractionLength(0...3))).textFieldStyle(.squareBorder)
                                    Text("To")
                                    TextField("Max",value:Binding(get:{ self.node?.modulations?[key]?.maximum ?? spec.max },set:{ value in update(key) { $0.maximum = value } }),format:.number.precision(.fractionLength(0...3))).textFieldStyle(.squareBorder)
                                }
                                TimelineView(.periodic(from:.now,by:0.1)) { _ in
                                Text("Live: \((renderer.modulationValues[id]?[key] ?? node.value(key)).formatted(.number.precision(.fractionLength(3))))  ·  Base: \(node.value(key).formatted(.number.precision(.fractionLength(3))))").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical,6)
                        }
                    }
                }
            }
        }
    }
}
