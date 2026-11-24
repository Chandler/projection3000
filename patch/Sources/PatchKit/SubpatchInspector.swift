import SwiftUI
import PatchCore

struct SubpatchInspector: View {
    @ObservedObject var workspace: Workspace
    let group: Component
    @State private var enableOutputs = false

    private func edit(_ action: String, _ change: (inout SubpatchInterface) throws -> Void) {
        workspace.edit(action) { graph in try graph.editInterface(group.id,change) }
    }
    private var members: [Node] { group.members.compactMap(workspace.graph.node) }
    var body: some View {
        if let interface = group.interface {
            Picker("Preview",selection:Binding(get:{ interface.preview },set:{ value in edit("Choose Preview") { $0.preview = value } })) {
                Text("Automatic").tag(nil as UUID?)
                ForEach(members) { node in Text(node.name).tag(Optional(node.id)) }
            }
            ForEach([false,true],id:\.self) { output in
                DisclosureGroup(output ? "Outputs":"Inputs") {
                    ForEach(interface.ports.filter { $0.output == output }) { port in
                        HStack {
                            TextField("Port name",text:Binding(get:{ port.name },set:{ name in
                                edit("Rename Port") { value in
                                    if let i = value.ports.firstIndex(where:{ $0.id == port.id }) { value.ports[i].name = name }
                                }
                            }))
                            Menu {
                                ForEach(members) { node in
                                    ForEach(node.ports(output:output).filter { $0.type == port.type },id:\.id) { spec in
                                        Button(node.name+" · "+spec.name) {
                                            edit("Reassign Port") { value in
                                                if let i = value.ports.firstIndex(where:{ $0.id == port.id }) {
                                                    value.ports[i].node = node.id; value.ports[i].key = spec.id
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: { Image(systemName:"cable.connector") }
                            Button { edit("Hide Port") { $0.ports.removeAll { $0.id == port.id } } } label: { Image(systemName:"minus") }
                        }
                    }
                    Menu("Expose Port") {
                        ForEach(members) { node in
                            ForEach(node.ports(output:output).filter { spec in !interface.ports.contains { $0.output == output && $0.node == node.id && $0.key == spec.id } },id:\.id) { spec in
                                Button(node.name+" · "+spec.name) {
                                    workspace.edit("Expose Port") { graph in try graph.exposePort(group.id,node:node.id,key:spec.id,output:output,name:spec.name) }
                                }
                            }
                        }
                    }
                }
            }
            ForEach(interface.parameters) { address in
                if let node = workspace.graph.node(address.node),let spec = node.parameterDefinitions.first(where:{ $0.key == address.key }) {
                    VStack(alignment:.leading) {
                        HStack {
                            TextField("Control name",text:Binding(get:{ address.name },set:{ name in
                                edit("Rename Control") { value in
                                    if let i = value.parameters.firstIndex(where:{ $0.id == address.id }) { value.parameters[i].name = name }
                                }
                            }))
                            Button { edit("Hide Control") { $0.parameters.removeAll { $0.id == address.id } } } label: { Image(systemName:"minus") }
                        }
                        let value = Binding<Double>(get:{ node.value(spec.key) },set:{ workspace.parameter(node.id,spec.key,$0) })
                        if let choices = spec.choices {
                            Picker(address.name,selection:value) {
                                ForEach(choices.indices,id:\.self) { i in Text(choices[i]).tag(spec.min+Double(i)) }
                            }.labelsHidden()
                        } else {
                            ParameterControl(value:value,in:spec.min...spec.max,step:spec.step,centeredBalance:node.kind.isAudioNode && ["balance","pan"].contains(spec.key),spec:spec,onEditingChanged:{ active in
                                if active { workspace.beginGesture() } else { workspace.endGesture("Change "+address.name) }
                            })
                        }
                    }.midiParameter(workspace:workspace,id:node.id,key:spec.key)
                }
            }
            Menu("Expose Control") {
                ForEach(members) { node in
                    Menu(node.name) {
                        ForEach(node.parameterDefinitions.filter { spec in !interface.parameters.contains { $0.node == node.id && $0.key == spec.key } },id:\.key) { spec in
                            Button(spec.title) { workspace.edit("Expose Control") { try $0.exposeParameter(group.id,node:node.id,key:spec.key,name:spec.title) } }
                        }
                    }
                }
            }
            Toggle("Activate devices and outputs in new instance",isOn:$enableOutputs).toggleStyle(.checkbox)
            HStack {
                Button("New Instance") {
                    do { workspace.instantiateSubpatch(try workspace.graph.subpatchTemplate(group.id),at:.init(group.position.x+280,group.position.y),includeMIDI:false,enableOutputs:enableOutputs) }
                    catch { workspace.message = error.localizedDescription }
                }
                Button("Export…") { workspace.exportSubpatch(group.id) }
            }
        }
    }
}
