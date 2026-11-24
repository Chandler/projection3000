import SwiftUI
import PatchCore
struct PublicationInspector: View {
    @ObservedObject var workspace: Workspace
    let node: Node
    var body: some View {
        let ports = workspace.graph.publishablePorts.filter { $0.nodeID == node.id }
        if !ports.isEmpty {
            DisclosureGroup("PUBLISHING") {
                VStack(alignment:.leading,spacing:8) {
                    if node.kind == .ab { Text("Automatic publishes this A/B output in VJ, including when connected to other nodes.").foregroundStyle(.secondary) }
                    ForEach(ports,id:\.id) { port in
                        let settings = node.publications?[port.portID] ?? OutputPublication()
                        Picker(port.type.rawValue.capitalized,selection:Binding(get:{ settings.mode },set:{ mode in set(port,mode:mode,name:settings.name) })) {
                            Text(node.publishesAutomatically ? "Automatic" : "Not published").tag("auto"); Text("Published").tag("on"); Text("Hidden").tag("off")
                        }
                        TextField("Output name",text:Binding(get:{ settings.name ?? "" },set:{ name in set(port,mode:settings.mode,name:name) })).textFieldStyle(.squareBorder)
                    }
                }.padding(.top,8)
            }.font(.system(size:11))
        }
    }
    func set(_ port: PublishedPort,mode: String,name: String?) {
        workspace.update(node.id,action:"Publish Output") { node in
            node.publications = node.publications ?? [:]
            node.publications?[port.portID] = OutputPublication(mode:mode,name:name)
        }
    }
}
