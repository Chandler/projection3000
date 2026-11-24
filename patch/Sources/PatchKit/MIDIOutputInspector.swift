import SwiftUI
import PatchCore

struct MIDIOutputInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    var body: some View {
        if let node=workspace.graph.node(id) {
            TimelineView(.periodic(from:.now,by:1)) { _ in
                let devices=MIDIOutputDevice.devices
                Picker("MIDI destination",selection:Binding(get:{ workspace.graph.node(id)?.deviceID ?? "" },set:{ value in workspace.update(id) { $0.deviceID=value.isEmpty ? nil:value } })) {
                    Text("Choose output…").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                    if let selected=node.deviceID,!devices.contains(where:{ $0.id == selected }) { Text("Disconnected output").tag(selected) }
                }
            }
            Picker("MIDI channel",selection:Binding(get:{ Int(workspace.graph.node(id)?.value("channel") ?? 1) },set:{ workspace.parameter(id,"channel",Double($0)) })) {
                Text("Keep incoming channels").tag(0)
                ForEach(1...16,id:\.self) { Text(String($0)).tag($0) }
            }.midiParameter(workspace:workspace,id:id,key:"channel")
            Text("Choose a USB instrument or interface output. Channel 0 preserves each incoming channel. Match the instrument’s receive channel to the routed notes.").font(.caption).foregroundStyle(.secondary)
            Button("All Notes Off") { renderer.midiGraph.panic(id) }
                .help("Release notes and sustain now. Pause Arpeggiator or MIDI Out to stop the repeating pattern.")
            TimelineView(.periodic(from:.now,by:0.1)) { _ in
                Text(renderer.midiGraph.status[id] ?? "Waiting for MIDI").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}
struct ArpeggiatorInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    var body: some View {
        if let node=workspace.graph.node(id) {
            Text("Patch tempo · one note at a time · MIDI note events").font(.caption).foregroundStyle(.secondary)
            Text(ArpeggiatorStyle.notes(node).map(ArpeggiatorStyle.noteName).joined(separator:"  ")).font(.caption.monospaced()).foregroundStyle(.secondary)
            Button(node.enabled ? "Stop arpeggiator":"Start arpeggiator") { workspace.update(id) { $0.enabled.toggle() } }
            TimelineView(.periodic(from:.now,by:0.1)) { _ in
                Text(renderer.midiGraph.status[id] ?? "Connect MIDI Out").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

struct MIDIInputInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { _ in
            let devices=MIDIOutputDevice.inputs
            Picker("MIDI source",selection:Binding(get:{ workspace.graph.node(id)?.deviceID ?? "" },set:{ value in workspace.update(id) { $0.deviceID=value.isEmpty ? nil:value } })) {
                Text("Choose input…").tag("")
                ForEach(devices) { Text($0.name).tag($0.id) }
                if let selected=workspace.graph.node(id)?.deviceID,!devices.contains(where:{ $0.id==selected }) { Text("Disconnected input").tag(selected) }
            }
        }
        Text("Hardware notes, controllers and timing. Use MIDI Filter to choose channels and message types. SysEx is blocked.").font(.caption).foregroundStyle(.secondary)
        MIDIMonitorInspector(renderer:renderer,id:id)
    }
}
struct MIDIMonitorInspector: View {
    let renderer: Renderer
    let id: UUID
    var body: some View {
        Button("Release routed notes") { renderer.midiGraph.panic(id) }
        TimelineView(.periodic(from:.now,by:0.1)) { _ in
            let nodes=renderer.midiGraph.state["nodes"] as? [String:[String:Any]] ?? [:]
            let events=nodes[id.uuidString]?["recent"] as? [[String:Any]] ?? []
            VStack(alignment:.leading,spacing:3) {
                Text(renderer.midiGraph.status[id] ?? "Waiting for MIDI").foregroundStyle(.secondary)
                ForEach(Array(events.suffix(8).enumerated()),id:\.offset) { _,event in
                    Text(event["message"] as? String ?? "").textSelection(.enabled)
                }
            }.font(.caption.monospaced())
        }
    }
}
