import SwiftUI
import OutputBridge

enum SyphonInputSource {
    static func key(app: String, name: String, uuid: String = "") -> String {
        let fields = ["app":app,"name":name,"uuid":uuid]
        guard let data = try? JSONEncoder.sorted.encode(fields) else { return "" }
        return String(decoding:data,as:UTF8.self)
    }
    static func decode(_ key: String) -> [String:String]? {
        guard let value = try? JSONDecoder().decode([String:String].self,from:Data(key.utf8)),
              value["app"] != nil, value["name"] != nil else { return nil }
        return value
    }
    static func label(_ fields: [String:String]) -> String {
        [fields["app"],fields["name"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator:" · ")
    }
}
private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}

struct SyphonInputInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { _ in
            let selection = workspace.graph.node(id)?.deviceID.flatMap(SyphonInputSource.decode)
            HStack {
                Menu(selection.map(SyphonInputSource.label) ?? "Choose Syphon Source") {
                    Button("None") { workspace.update(id) { $0.deviceID = nil } }
                    ForEach(PatchSyphonInput.sources,id:\.self) { source in
                        Button(SyphonInputSource.label(source)) {
                            workspace.update(id) { $0.deviceID = SyphonInputSource.key(app:source["app"] ?? "",name:source["name"] ?? "",uuid:source["uuid"] ?? "") }
                        }
                    }
                }
                Text(renderer.status[id] ?? "Offline").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
