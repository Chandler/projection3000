import SwiftUI
import PatchCore

struct MediaTransportInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    var node: Node? { workspace.graph.node(id) }
    func stamp(_ time: Double) -> String { let t = max(0,time); return String(format:"%02d:%05.2f",Int(t)/60,t.truncatingRemainder(dividingBy:60)) }
    var body: some View {
        if let node {
            TimelineView(.periodic(from:.now,by:0.1)) { _ in
                let state = renderer.mediaStates[id]
                let duration = max(0,state?.duration ?? 0)
                let position = scrubbing ? scrubTime : min(duration,max(0,state?.position ?? node.value("seek")))
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Button(node.value("playing") > 0.5 ? "Pause" : "Play") { workspace.parameter(id,"playing",node.value("playing") > 0.5 ? 0 : 1) }
                        Button("Stop") {
                            workspace.edit("Stop Media") { graph in try graph.setParameter(id,key:"playing",value:0); try graph.setParameter(id,key:"seek",value:node.value("start")) }
                        }
                        Button("↺") { workspace.parameter(id,"seek",node.value("start")) }.help("Return to loop start")
                        Spacer()
                    }
                    ParameterControl(value:Binding(get:{ position },set:{ value in scrubTime = value; workspace.parameter(id,"seek",value) }),in:0...max(0.001,duration),onEditingChanged:{ editing in
                        if editing { scrubTime = position; scrubbing = true; workspace.beginGesture() }
                        else { scrubbing = false; workspace.endGesture("Scrub Media") }
                    }).disabled(duration <= 0).help("Scrub playback")
                    HStack { Text(stamp(position)); Spacer(); Text(stamp(duration)) }.font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                    if !workspace.playing { Text("Global transport is paused").font(.system(size:10)).foregroundStyle(.secondary) }
                    HStack {
                        Button("Set In") { workspace.parameter(id,"start",position) }.help("Set loop start to the current playhead")
                        Button("Set Out") { workspace.parameter(id,"end",position) }.help("Set loop end to the current playhead")
                        Button("Reset Loop") { workspace.edit("Reset Loop") { graph in try graph.setParameter(id,key:"start",value:0); try graph.setParameter(id,key:"end",value:0) } }
                    }.font(.system(size:10))
                }
            }
        }
    }
}
