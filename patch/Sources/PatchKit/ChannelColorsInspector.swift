import SwiftUI
import PatchCore

struct ChannelColorsInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    var node: Node? { workspace.graph.node(id) }
    func binding(_ key: String) -> Binding<Double> {
        Binding(get:{ node?.value(key) ?? 0 },set:{ workspace.parameter(id,key,$0) })
    }
    func rgb(_ packed: Double) -> Color {
        let v = Int(packed); return Color(.sRGB,red:Double((v>>16)&255)/255,green:Double((v>>8)&255)/255,blue:Double(v&255)/255,opacity:1)
    }
    func slider(_ key: String,_ title: String,tint: Color = .accentColor) -> some View {
        let spec = ChannelColorsStyle.parameters.first { $0.key == key }!
        return VStack(spacing:4) {
            HStack {
                Text(title); Spacer()
                TextField(title,value:binding(key),format:.number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.squareBorder).frame(width:65)
            }
            ParameterControl(value:binding(key),in:spec.min...spec.max,step:spec.step,showsValueField:false,spec:spec,onEditingChanged:{ editing in
                if editing { workspace.beginGesture() } else { workspace.endGesture("Adjust Channel Colors") }
            }).tint(tint).controlSize(.small)
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
    func color(_ key: String,_ title: String) -> some View {
        ColorPicker(title,selection:Binding(get:{ rgb(node?.value(key) ?? 0) },set:{ color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            let r = Int((c.redComponent*255).rounded()),g = Int((c.greenComponent*255).rounded()),b = Int((c.blueComponent*255).rounded())
            workspace.parameter(id,key,Double((r<<16)|(g<<8)|b))
        }),supportsOpacity:false)
    }
    func preset(_ colors: [Double]) {
        workspace.edit("Channel Colors Preset") { graph in
            for (i,value) in colors.enumerated() { try graph.setParameter(id,key:"color\(i)",value:value) }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("CHANNEL COLORS").font(.editorHeading).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    workspace.edit("Reset Channel Colors") { graph in
                        for p in ChannelColorsStyle.parameters { try graph.setParameter(id,key:p.key,value:p.initial) }
                    }
                }.buttonStyle(.plain)
            }
            Picker("Channels",selection:binding("channels")) {
                Text("All").tag(0.0); Text("R").tag(1.0); Text("G").tag(2.0); Text("B").tag(3.0)
            }.pickerStyle(.segmented)
            HStack {
                Button("RGB") { preset(ChannelColorsStyle.primaries) }
                Button("CMY") { preset([0x00FFFF,0xFF00FF,0xFFFF00]) }
                Button("Swap") { preset([0x0000FF,0xFF0000,0x00FF00]) }
                Button("Risograph") { preset([0xFF48B0,0x00A95C,0x0078BF]) }
            }.controlSize(.small)
            Text("Redraws the red, green and blue channels of the input in the three colors below. Choose one channel to isolate it as its own stream.")
                .font(.system(size:11)).foregroundStyle(.secondary)
            ForEach(0..<3,id:\.self) { i in
                VStack(spacing:8) {
                    color("color\(i)","\(ChannelColorsStyle.names[i]) becomes")
                    slider("level\(i)","Level",tint:rgb(node?.value("color\(i)") ?? 0))
                }
            }
            Picker("Blend",selection:binding("blend")) {
                Text("Add").tag(0.0); Text("Screen").tag(1.0)
            }
            slider("mix","Mix")
            Text("Add sums the three colored channels and clips at white. Screen keeps overlapping bright colors from clipping.")
                .font(.system(size:10)).foregroundStyle(.secondary)
        }
    }
}
