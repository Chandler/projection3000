import AppKit
import SwiftUI
import PatchCore

struct TraceInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    @State private var detail=false
    @State private var colors=true
    @State private var range=false
    @State private var sync=false
    var node: Node? { workspace.graph.node(id) }
    var paletteConnected: Bool { workspace.graph.edges.contains { $0.target == id && $0.input == 0 } }
    var phaseConnected: Bool { workspace.graph.edges.contains { $0.target == id && $0.input == 1 } }
    func value(_ key: String) -> Double { node?.value(key) ?? 0 }
    @ViewBuilder func control(_ key: String) -> some View {
        if let p=TraceStyle.parameters.first(where:{$0.key==key}) {
            if key == "core" || key == "glow" {
                HStack {
                    Text(p.title);Spacer()
                    PanelColorWell(selection:Binding(get:{ PaletteColor(hex:UInt32(value(key).rounded())).displayColor },set:{ color in
                        if let c=NSColor(color).usingColorSpace(.sRGB) { workspace.parameter(id,key,Double(PaletteColor(c.redComponent,c.greenComponent,c.blueComponent).hex)) }
                    }),title:p.title).frame(width:64,height:24)
                }.disabled(key == "glow" ? paletteConnected : value("single_color")>=0.5)
            } else if let choices=p.choices {
                Picker(p.title,selection:Binding(get:{ Int(value(key).rounded()) },set:{ workspace.parameter(id,key,Double($0)) })) {
                    ForEach(Array(choices.enumerated()),id:\.offset) { index,title in Text(title).tag(index) }
                }.midiParameter(workspace:workspace,id:id,key:key)
            } else {
                VStack(spacing:5) {
                    HStack { Text(p.title);Spacer();Text(value(key).formatted(.number.precision(.fractionLength(key == "seed" ? 0:2)))).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary) }
                    // The original trace speed control is logarithmic across 0.05–10.
                    let logarithmic=key == "speed"
                    ParameterControl(value:Binding(get:{ logarithmic ? log(max(p.min,value(key))):value(key) },set:{ raw in
                        let v=logarithmic ? exp(raw):raw
                        workspace.parameter(id,key,p.step == 1 ? v.rounded():v)
                    }),in:logarithmic ? log(p.min)...log(p.max):p.min...p.max,step:logarithmic ? nil:p.step,hasNeutralZero:!logarithmic,onEditingChanged:{ editing in
                        if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(p.title)") }
                    }).tint(Color(nsColor:.patchAccent)).controlSize(.small)
                }.midiParameter(workspace:workspace,id:id,key:key)
            }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("LIGHTNING PULSES").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
            control("rate");control("speed");control("brightness")
            DisclosureGroup("Pulse shape",isExpanded:$detail) {
                VStack(spacing:12) { ForEach(["burst","jitter","length","tail","crackle","forks","top_spray"],id:\.self) { control($0) } }.padding(.top,8)
            }
            DisclosureGroup("Color",isExpanded:$colors) {
                VStack(spacing:12) {
                    if paletteConnected { Text("Palette input").font(.caption).foregroundStyle(.secondary) }
                    control("single_color");control("core");control("glow");control("rainbow")
                }.padding(.top,8)
            }
            DisclosureGroup("Path range",isExpanded:$range) {
                VStack(spacing:12) { control("origin");control("start");control("end");control("reflect") }.padding(.top,8)
            }
            DisclosureGroup("Sync",isExpanded:$sync) {
                VStack(spacing:12) {
                    HStack { Text("Clock");Spacer();Text(phaseConnected ? "Phase input":"Free running").foregroundStyle(.secondary) }
                    control("cycle").disabled(!phaseConnected);control("seed")
                }.padding(.top,8)
            }
        }
    }
}
