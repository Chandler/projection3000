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
            let videoInputs = interface.ports.filter { !$0.output && $0.type == .video }
            if !videoInputs.isEmpty {
                Picker("Clip input",selection:Binding(get:{ interface.processingInput },set:{ id in
                    edit("Change Clip Input") { $0.processingInput = id }
                })) {
                    Text("None").tag(nil as UUID?)
                    ForEach(videoInputs) { Text($0.name).tag(Optional($0.id)) }
                }
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
                            Button { edit("Hide Port") { if $0.processingInput == port.id { $0.processingInput = nil }; $0.ports.removeAll { $0.id == port.id } } } label: { Image(systemName:"minus") }
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
                        NodeAppParameter(workspace:workspace,id:node.id,key:spec.key,title:address.name)
                    }
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
            Button("Save to Library…") { workspace.saveSubpatchToLibrary(group.id) }
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

extension Workspace {
    func saveSubpatchToLibrary(_ id: UUID) {
        do {
            guard let component = graph.component(id) else { throw GraphError("Unknown subpatch") }
            let dialog = NSAlert()
            dialog.messageText = "Save Subpatch to Library"
            let name = NSTextField(frame:NSRect(x:0,y:0,width:300,height:24))
            name.stringValue = component.name.replacingOccurrences(of:"/",with:"–")
            name.setAccessibilityLabel("Library name")
            dialog.accessoryView = name
            dialog.addButton(withTitle:"Save")
            dialog.addButton(withTitle:"Cancel")
            dialog.window.initialFirstResponder = name
            guard dialog.runModal() == .alertFirstButtonReturn else { return }
            let value = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !value.isEmpty else { throw GraphError("Enter a library name") }
            let key = value.hasSuffix(".subpatch.json") ? value : value+".subpatch.json"
            let url = PatchLibrary.subpatchDirectory.appendingPathComponent(key)
            let replace = FileManager.default.fileExists(atPath:url.path)
            if replace {
                let confirm = NSAlert()
                confirm.messageText = "Replace "+url.lastPathComponent+"?"
                confirm.addButton(withTitle:"Cancel")
                confirm.addButton(withTitle:"Replace")
                guard confirm.runModal() == .alertSecondButtonReturn else { return }
            }
            var copy = graph
            guard let index = copy.components?.firstIndex(where:{ $0.id == id }) else { throw GraphError("Unknown subpatch") }
            let title = String(url.lastPathComponent.dropLast(".subpatch.json".count))
            guard !title.isEmpty else { throw GraphError("Enter a library name") }
            copy.components?[index].name = title
            try PatchLibrary.save(copy.subpatchTemplate(id),id:key,replace:replace)
            message = "Saved to Library · "+value
        } catch { message = error.localizedDescription }
    }
}
