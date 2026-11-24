import SwiftUI
import PatchCore
import OutputBridge

struct NDIInputInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @State private var source=""
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("NDI SOURCE").font(.editorHeading).foregroundStyle(.secondary)
            HStack {
                TextField("MACHINE (Stream)",text:$source).textFieldStyle(.squareBorder).onSubmit { connect(source) }
                // Discovery keeps running in the background; the menu lists whatever is visible now.
                TimelineView(.periodic(from:.now,by:1)) { _ in
                    Menu("Sources") {
                        let sources=PatchNDIReceiver.sources
                        if sources.isEmpty { Text(PatchNDIReceiver.available ? "No sources found" : "NDI runtime unavailable") }
                        ForEach(sources,id:\.self) { name in Button(name) { source=name;connect(name) } }
                    }.fixedSize()
                }
            }
            HStack {
                Button("Connect") { connect(source) }.controlSize(.small)
                Spacer()
                TimelineView(.periodic(from:.now,by:0.5)) { _ in Text(renderer.status[id] ?? "Offline").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.onAppear { source=workspace.graph.node(id)?.text ?? "" }
         .onChange(of:workspace.graph.node(id)?.text) { _,value in source=value ?? "" }
    }
    func connect(_ name: String) { workspace.update(id) { $0.text=name.trimmingCharacters(in:.whitespacesAndNewlines) } }
}
