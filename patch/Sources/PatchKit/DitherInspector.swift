import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PatchCore

private struct DitherPalette: Identifiable {
    let name: String
    let shadow: Int
    let midtone: Int
    let highlight: Int
    var id: String { name }
    var colors: [Int] { [shadow, midtone, highlight] }
    static let all: [DitherPalette] = [
        .init(name:"Blue Print", shadow:0x142129, midtone:0x3B84B0, highlight:0xE8EDFF),
        .init(name:"Cyanotype", shadow:0x081B44, midtone:0x357FA3, highlight:0xF2F1DB),
        .init(name:"Teal & Coral", shadow:0x123B40, midtone:0xE78170, highlight:0xFFF0CF),
        .init(name:"Indigo & Gold", shadow:0x251B4B, midtone:0xC89137, highlight:0xFFF0C2),
        .init(name:"Plum & Peach", shadow:0x381B3F, midtone:0xB96786, highlight:0xFFD9AE),
        .init(name:"Forest", shadow:0x142D28, midtone:0x6E9667, highlight:0xF0EBC6),
        .init(name:"Copper", shadow:0x30201C, midtone:0xBE7950, highlight:0xFFE9C4),
        .init(name:"Rose", shadow:0x381C2D, midtone:0xC3718A, highlight:0xFFE3DD),
        .init(name:"Ultraviolet", shadow:0x1C103C, midtone:0x9663D9, highlight:0xEFE0FF),
        .init(name:"Mint", shadow:0x142C3B, midtone:0x50A998, highlight:0xE0FFD1),
        .init(name:"Red & Cream", shadow:0x241A20, midtone:0xD9534F, highlight:0xFFF1D6),
        .init(name:"Amber", shadow:0x291A08, midtone:0xBC851F, highlight:0xFFE8A0),
        .init(name:"Olive", shadow:0x252B19, midtone:0x8F9854, highlight:0xF3E8B9),
        .init(name:"Ice", shadow:0x182C46, midtone:0x658FAE, highlight:0xEAF9FF),
        .init(name:"Sepia", shadow:0x30251F, midtone:0xA18B70, highlight:0xF5EAD2),
        .init(name:"Graphite", shadow:0x191B21, midtone:0x858891, highlight:0xF4F3EF),
    ]
}

struct DitherInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    var node: Node? { workspace.graph.node(id) }
    func value(_ key: String) -> Double {
        guard let node else { return 0 }
        if key == "algorithm" { return node.parameters[key] ?? node.value("matrix") }
        if key == "tonal" { return node.parameters[key] ?? node.value("mono") }
        return node.value(key)
    }
    func binding(_ key: String) -> Binding<Double> { Binding(get:{ value(key) },set:{ workspace.parameter(id,key,$0) }) }
    @ViewBuilder func parameter(_ key: String) -> some View {
        if let spec = NodeKind.dither.parameters.first(where:{ $0.key == key }) {
            if let choices = spec.choices {
                Picker(spec.title,selection:Binding(get:{ Int(value(key)) },set:{ workspace.parameter(id,key,Double($0)) })) {
                    ForEach(Array(choices.enumerated()),id:\.offset) { index,title in Text(title).tag(index) }
                }.controlSize(.small)
            } else {
                VStack(spacing:5) {
                    HStack {
                        Text(spec.title); Spacer()
                        TextField("",value:binding(key),format:.number.precision(.fractionLength(0...2))).textFieldStyle(.squareBorder).frame(width:62)
                    }
                    ParameterControl(value:binding(key),in:spec.min...spec.max,step:spec.step,showsValueField:false,spec:spec,onEditingChanged:{ editing in
                        if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(spec.title)") }
                    }).controlSize(.small).tint(Color(nsColor:.patchAccent))
                }.midiParameter(workspace:workspace,id:id,key:key)
            }
        }
    }
    func color(_ key: String,_ title: String) -> some View {
        ColorPicker(title,selection:Binding(get:{
            let v=Int(value(key)); return Color(.sRGB,red:Double((v>>16)&255)/255,green:Double((v>>8)&255)/255,blue:Double(v&255)/255,opacity:1)
        },set:{ color in
            guard let rgb=NSColor(color).usingColorSpace(.sRGB) else { return }
            let r=Int((rgb.redComponent*255).rounded()),g=Int((rgb.greenComponent*255).rounded()),b=Int((rgb.blueComponent*255).rounded())
            workspace.parameter(id,key,Double((r<<16)|(g<<8)|b))
        }),supportsOpacity:false)
    }
    func inkColor(_ key: String,_ title: String,minimumMode: Int,requirement: String,modeName: String) -> some View {
        VStack(alignment:.leading,spacing:5) {
            color(key,title).disabled(value("tonal") < Double(minimumMode))
            if value("tonal") < Double(minimumMode) {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    Text(requirement).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:0)
                    Button("Use \(modeName)") { workspace.parameter(id,"tonal",Double(minimumMode)) }
                        .buttonStyle(.plain).foregroundStyle(Color(nsColor:.patchAccent))
                }.font(.system(size:10))
            }
        }
    }
    func heading(_ title: String) -> some View { Text(title).font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.top,8) }
    private func applyPalette(_ palette: DitherPalette) {
        workspace.edit("Dither Palette") { graph in
            for (key,value) in [("tonal",4),("shadowColor",palette.shadow),("midtoneColor",palette.midtone),("highlightColor",palette.highlight)] {
                try graph.setParameter(id,key:key,value:Double(value))
            }
        }
    }
    private var palettes: some View {
        DisclosureGroup("Color palettes") {
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
                ForEach(DitherPalette.all) { palette in
                    let selected = value("tonal") == 4 && Int(value("shadowColor")) == palette.shadow && Int(value("midtoneColor")) == palette.midtone && Int(value("highlightColor")) == palette.highlight
                    Button { applyPalette(palette) } label: {
                        VStack(alignment:.leading,spacing:4) {
                            HStack(spacing:0) {
                                ForEach(palette.colors,id:\.self) { hex in
                                    Rectangle().fill(Color(.sRGB,red:Double((hex>>16)&255)/255,green:Double((hex>>8)&255)/255,blue:Double(hex&255)/255,opacity:1))
                                }
                            }.frame(height:20)
                            Text(palette.name).font(.system(size:10)).lineLimit(1)
                        }.padding(4).frame(maxWidth:.infinity,alignment:.leading)
                            .overlay(Rectangle().stroke(selected ? Color(nsColor:.patchAccent) : Color.secondary.opacity(0.3),lineWidth:1))
                    }.buttonStyle(.plain).accessibilityLabel(palette.name)
                        .accessibilityValue(selected ? "Selected" : "")
                }
            }.padding(.top,6)
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Menu("Preset") {
                    Button("Blue Print") { preset(blue:true) }
                    Button("Black & White Print") { preset(blue:false) }
                    Button("Reset") { workspace.edit("Reset Dither") { graph in for p in NodeKind.dither.parameters { try graph.setParameter(id,key:p.key,value:p.initial) } } }
                }
                Spacer()
                Button("Render Frame…") { export() }.help("Save the current rendered frame as PNG. The node updates live.")
            }
            heading("RENDER SETTINGS")
            parameter("dpi").help("72 uses the graph's native resolution before pixel sizing. Lower values create a coarser processing grid; this is a relative print-resolution control for video.")
            parameter("resampling").help("Preserve Details uses an edge-aware filter when reducing resolution.")
            parameter("algorithm"); parameter("cell"); parameter("levels").disabled(value("tonal")>=3)
            heading("EFFECT CONTROLS")
            parameter("sharpen"); parameter("sharpenRadius"); parameter("noise"); parameter("denoise"); parameter("blur"); parameter("brightness"); parameter("contrast"); parameter("gamma")
            heading("TONAL CONTROLS")
            parameter("tonal")
            palettes
            inkColor("highlightColor","Highlights",minimumMode:2,requirement:"Requires a color mapping",modeName:"1 Color")
            parameter("highlightLevel").disabled(value("tonal")<1)
            inkColor("midtoneColor","Midtones",minimumMode:4,requirement:"Requires 3 Colors",modeName:"3 Colors")
            parameter("midtoneLevel").disabled(value("tonal")<4)
            inkColor("shadowColor","Shadows",minimumMode:3,requirement:"Requires 2 or 3 Colors",modeName:"2 Colors")
            parameter("shadowLevel").disabled(value("tonal")<1)
            parameter("background").disabled(value("tonal")<2)
            if value("background")==2 { color("backgroundColor","Background color") }
            heading("PATTERN")
            parameter("angle"); parameter("seed"); parameter("mix")
        }
    }
    func preset(blue: Bool) {
        workspace.edit("Dither Preset") { graph in
            for p in NodeKind.dither.parameters { try graph.setParameter(id,key:p.key,value:p.initial) }
            let values: [String:Double] = ["dpi":42,"cell":1,"algorithm":1,"sharpen":102,"sharpenRadius":11,"brightness":5,"contrast": -8,"tonal":blue ? 4 : 1,"highlightColor":15265023,"midtoneColor":3900592,"shadowColor":1319209,"mix":1]
            for (key,value) in values { try graph.setParameter(id,key:key,value:value) }
        }
    }
    func export() {
        let panel=NSSavePanel(); panel.allowedContentTypes=[.png]; panel.nameFieldStringValue="\(node?.name ?? "Dither").png"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { try renderer.snapshot(id,to:url); workspace.message="Saved \(url.lastPathComponent)" }
        catch { workspace.message=error.localizedDescription }
    }
}
