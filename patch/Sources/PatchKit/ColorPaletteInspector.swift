import AppKit
import SwiftUI
import PatchCore

extension PaletteColor {
    var displayColor: Color { Color(.sRGB,red:r,green:g,blue:b,opacity:1) }
}
struct PaletteOutputInspector: View {
    let renderer: Renderer
    let id: UUID
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.2)) { _ in
            let colors=renderer.colorPalette(id)?.colors ?? []
            VStack(alignment:.leading,spacing:6) {
                Text("PALETTE · \(colors.count) COLORS").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
                if !colors.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing:2) {
                            ForEach(colors.indices,id:\.self) { i in
                                colors[i].displayColor.frame(width:24,height:25)
                                    .help("\(i+1): #"+String(format:"%06X",colors[i].hex))
                            }
                        }
                    }
                }
            }
        }
    }
}
struct ColorPaletteInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    var colors: [PaletteColor] { workspace.graph.node(id).map { PaletteGenerator.colors($0).colors } ?? PaletteStyle.defaultPalette.colors }
    func edit(_ name: String,_ change: (inout [PaletteColor])->Void) {
        var result=colors; change(&result)
        workspace.edit(name) { graph in
            try graph.setPalette(id,colors:result)
            for (key,value) in [("scheme",0.0),("count",0),("hueShift",0),("saturation",1),("seed",0)] { try graph.setParameter(id,key:key,value:value) }
        }
    }
    func binding(_ i: Int) -> Binding<Color> {
        Binding(get:{ colors.indices.contains(i) ? colors[i].displayColor : .black },set:{ selected in
            guard let c=NSColor(selected).usingColorSpace(.sRGB) else { return }
            edit("Change Palette Color") { values in
                if values.indices.contains(i) { values[i] = .init(c.redComponent,c.greenComponent,c.blueComponent) }
            }
        })
    }
    private var schemeGrid: some View {
        LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
            ForEach(PaletteGenerator.schemes.indices,id:\.self) { index in
                if var candidate=workspace.graph.node(id) {
                    let _ = candidate.parameters["scheme"]=Double(index)
                    PaletteSchemeButton(name:PaletteGenerator.schemes[index],colors:PaletteGenerator.colors(candidate).colors,selected:Int(workspace.graph.node(id)?.value("scheme") ?? 0)==index) {
                        workspace.parameter(id,"scheme",Double(index))
                    }
                }
            }
        }.midiParameter(workspace:workspace,id:id,key:"scheme")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            schemeGrid
            HStack {
                Text("ORDERED COLORS · \(colors.count)").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("New Variation") {
                    let seed=workspace.graph.node(id)?.value("seed") ?? 0
                    workspace.parameter(id,"seed",Double((Int(seed)+1)%65536))
                }

            }
            ForEach(colors.indices,id:\.self) { i in
                HStack(spacing:8) {
                    Text("\(i+1)").monospacedDigit().foregroundStyle(.secondary).frame(width:22)
                    PanelColorWell(selection:binding(i),title:"Palette color \(i+1)").frame(width:64,height:24)
                    Text(String(format:"#%06X",colors[i].hex)).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                    Spacer(minLength:0)
                    Button { edit("Reorder Palette") { $0.swapAt(i,i-1) } } label: { Image(systemName:"arrow.up") }.disabled(i==0).help("Move color earlier")
                    Button { edit("Reorder Palette") { $0.swapAt(i,i+1) } } label: { Image(systemName:"arrow.down") }.disabled(i==colors.count-1).help("Move color later")
                    Button { edit("Remove Palette Color") { $0.remove(at:i) } } label: { Image(systemName:"minus") }.disabled(colors.count==1).help("Remove color")
                }.buttonStyle(.plain)
            }
            HStack {
                Button("Add color") { edit("Add Palette Color") { $0.append($0.last ?? .init(1,1,1)) } }.disabled(colors.count>=256)
                Spacer()
                Button("Reverse") { edit("Reverse Palette") { $0.reverse() } }
            }.controlSize(.small)
        }
    }
}

struct CollectionPaletteInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    var node: Node? { workspace.graph.node(id) }
    var connected: Bool { workspace.graph.edges.contains { $0.target == id && $0.input == 0 } }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("FALLBACK COLORS").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
            Text(connected ? "Palette input supplies the colors. Disconnect it to use this theme." : "Used when no palette is connected.").font(.caption).foregroundStyle(.secondary)
            if node?.kind == .graphClouds { Text(node?.value("sky") ?? 0 >= 0.5 ? "Color 1 fills the sky; the others paint the clouds." : "Clear sky: clouds layer over whatever is beneath.").font(.caption).foregroundStyle(.secondary) }
            Picker("Theme",selection:Binding(get:{ Int(node?.value("theme") ?? 0) },set:{ workspace.parameter(id,"theme",Double($0)) })) {
                ForEach(Array(CollectionStyle.themeNames.enumerated()),id:\.offset) { i,name in Text(name).tag(i) }
            }.midiParameter(workspace:workspace,id:id,key:"theme")
            Stepper("Colors: \(Int(node?.value("colors") ?? 4))",value:Binding(get:{ Int(node?.value("colors") ?? 4) },set:{ workspace.parameter(id,"colors",Double($0)) }),in:2...6).midiParameter(workspace:workspace,id:id,key:"colors")
            if let node {
                HStack(spacing:3) { ForEach(Array(CollectionStyle.palette(node).colors.enumerated()),id:\.offset) { _,c in c.displayColor.frame(height:22) } }
                if Int(node.value("theme")) == 5 {
                    ForEach(0..<Int(node.value("colors")),id:\.self) { i in
                        ColorPicker((node.kind == .graphClouds || node.kind == .graphCloudParticles) && node.value("sky")>=0.5 && i<2 ? ["Sky","Clouds"][i] : "Color \(i+1)",selection:Binding(get:{ PaletteColor(hex:UInt32(self.node?.value("color\(i)") ?? 0)).displayColor },set:{ color in
                            guard let c=NSColor(color).usingColorSpace(.sRGB) else { return }
                            let rgb=(Int((c.redComponent*255).rounded())<<16)|(Int((c.greenComponent*255).rounded())<<8)|Int((c.blueComponent*255).rounded())
                            workspace.parameter(id,"color\(i)",Double(rgb))
                        }),supportsOpacity:false).midiParameter(workspace:workspace,id:id,key:"color\(i)")
                    }
                }
            }
        }
    }
}

struct PaletteAdjustInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    var node: Node? { workspace.graph.node(id) }
    var mode: Int { Int((node?.value("mode") ?? 0).rounded()) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("COLOR ADJUSTMENT").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    workspace.beginGesture()
                    for p in PaletteAdjustmentStyle.parameters { workspace.parameter(id,p.key,p.initial) }
                    workspace.endGesture("Reset Palette Adjustment")
                }.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(.secondary)
            }
            Picker("Mode",selection:Binding(get:{ mode },set:{ workspace.parameter(id,"mode",Double($0)) })) {
                ForEach(Array((PaletteAdjustmentStyle.parameters[0].choices ?? []).enumerated()),id:\.offset) { index,title in
                    Text(title).tag(index)
                }
            }.midiParameter(workspace:workspace,id:id,key:"mode")
            ForEach(PaletteAdjustmentStyle.parameters.filter { $0.key != "mode" },id:\.key) { p in
                VStack(spacing:5) {
                    HStack {
                        Text(p.title)
                        Spacer()
                        Text((node?.value(p.key) ?? p.initial).formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                    }
                    ParameterControl(value:Binding(get:{ node?.value(p.key) ?? p.initial },set:{ workspace.parameter(id,p.key,$0) }),in:p.min...p.max,step:p.step,spec:p,onEditingChanged:{ editing in
                        if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(p.title)") }
                    }).tint(Color(nsColor:.patchAccent)).controlSize(.small)
                }.disabled(mode == 0 || (p.key == "saturation" && mode != 2))
                    .midiParameter(workspace:workspace,id:id,key:p.key)
            }
        }
    }
}

struct PaletteSchemeButton: View {
    let name: String
    let colors: [PaletteColor]
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action:action) {
            VStack(alignment:.leading,spacing:5) {
                HStack(spacing:0) {
                    ForEach(Array(colors.enumerated()),id:\.offset) { _,color in
                        color.displayColor.frame(maxWidth:.infinity)
                    }
                }.frame(height:24).clipShape(RoundedRectangle(cornerRadius:3))
                HStack(spacing:4) {
                    Text(name).font(.system(size:10,weight:.medium)).lineLimit(1)
                    Spacer(minLength:0)
                    if selected { Image(systemName:"checkmark").font(.system(size:10,weight:.bold)) }
                }
            }.padding(6).frame(maxWidth:.infinity).contentShape(Rectangle())
                .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius:5).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2),lineWidth:selected ? 2 : 1))
        }.buttonStyle(.plain).accessibilityLabel(name)
            .accessibilityValue(selected ? "Selected" : "")
    }
}
