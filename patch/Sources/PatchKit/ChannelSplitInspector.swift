import SwiftUI
import PatchCore

struct ChannelSplitInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    var node: Node? { workspace.graph.node(id) }
    var cmyk: Bool { node?.value("mode") == 1 }
    func binding(_ key: String) -> Binding<Double> {
        Binding(get:{ node?.value(key) ?? 0 },set:{ workspace.parameter(id,key,$0) })
    }
    func slider(_ key: String,_ title: String,tint: Color = .accentColor) -> some View {
        let spec = ChannelSplitStyle.parameters.first { $0.key == key }!
        return VStack(spacing:4) {
            HStack {
                Text(title); Spacer()
                TextField(title,value:binding(key),format:.number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.squareBorder).frame(width:65)
            }
            ParameterControl(value:binding(key),in:spec.min...spec.max,step:spec.step,showsValueField:false,spec:spec,onEditingChanged:{ editing in
                if editing { workspace.beginGesture() } else { workspace.endGesture("Adjust Channel Split") }
            }).tint(tint).controlSize(.small)
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
    func preset(_ index: Int) {
        workspace.edit("Channel Split Preset") { graph in
            for p in ChannelSplitStyle.parameters { try graph.setParameter(id,key:p.key,value:p.initial) }
            let values: [String:Double]
            switch index {
            case 1: values = ["x0":0,"x2":0,"radial":24]
            case 2: values = ["mode":1,"x0":-12,"y0":-4,"x1":8,"y1":-6,"x2":3,"y2":10]
            default: values = [:]
            }
            for (key,value) in values { try graph.setParameter(id,key:key,value:value) }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("CHANNEL SPLIT").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { preset(0) }.buttonStyle(.plain)
            }
            Picker("Color model",selection:binding("mode")) {
                Text("RGB").tag(0.0); Text("CMYK").tag(1.0)
            }.pickerStyle(.segmented)
            HStack {
                Button("Classic") { preset(0) }
                Button("Prism") { preset(1) }
                Button("Print Slip") { preset(2) }
            }.controlSize(.small)
            Text(cmyk ? "Offset four ink plates, then recombine to RGB." : "Offset red, green and blue independently.")
                .font(.system(size:11)).foregroundStyle(.secondary)
            slider("amount","Separation")
            slider("angle","Rotation °")
            slider("radial","Radial spread · px")
            slider("mix","Mix")
            ForEach(0..<(cmyk ? 4 : 3),id:\.self) { i in
                let names = cmyk ? ["Cyan","Magenta","Yellow","Black"] : ["Red","Green","Blue"]
                let colors: [Color] = cmyk ? [.cyan,.pink,.yellow,.gray] : [.red,.green,.blue]
                DisclosureGroup {
                    VStack(spacing:10) {
                        slider("x\(i)","Horizontal · px",tint:colors[i])
                        slider("y\(i)","Vertical · px",tint:colors[i])
                    }.padding(.top,8)
                } label: {
                    HStack { Circle().fill(colors[i]).frame(width:8,height:8); Text(names[i]); Spacer()
                        Text("\(Int(node?.value("x\(i)") ?? 0)), \(Int(node?.value("y\(i)") ?? 0)) px")
                            .font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Edges",selection:binding("edges")) {
                Text("Clamp").tag(0.0); Text("Wrap").tag(1.0); Text("Mirror").tag(2.0); Text("Neutral").tag(3.0)
            }
            Text("Neutral uses black for RGB and unprinted white for CMYK. Offsets are in canvas pixels; positive X moves right, positive Y moves down.")
                .font(.system(size:10)).foregroundStyle(.secondary)
        }
    }
}
