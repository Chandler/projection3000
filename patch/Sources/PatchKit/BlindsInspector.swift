import SwiftUI
import AppKit
import PatchCore

enum BlindsControls {
    static let patterns = ["Rainbow", "Pastel", "Sunset", "Ocean", "Forest", "Neon", "Amber", "White", "Mapping 36", "Color Cycle", "Cyan / Magenta"]
    static let specs: [ParameterSpec] = [
        .init("count","Bar Count",1,100,38,step:1),
        .init("pattern","Color Pattern",0,10,8,choices:patterns),
        .init("gap","Gap Size",0,0.95,0.15),
        .init("offset","Vertical Offset",-0.5,0.5,0)
    ] + [.init("speed","Speed",0,3,1)] + BlindsStyle.animationParameters + BlindsStyle.appearanceParameters
    static func storage(_ key: String,_ value: Double) -> (String,Double) {
        switch key {
        case "count": return ("p1",value/10)
        case "pattern": return ("p2",value)
        case "gap": return ("p3",value)
        case "offset": return ("p4",value)
        default: return (key,value)
        }
    }
}

struct BlindsInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    var node: Node? { workspace.graph.node(id) }
    func value(_ key: String) -> Double { node?.value(key) ?? 0 }
    func set(_ key: String,_ value: Double) { workspace.parameter(id,key,value) }
    var count: Binding<Int> {
        Binding(get:{ max(1,min(100,Int((value("p1")*10).rounded()))) },set:{ set("p1",Double(max(1,min(100,$0)))/10) })
    }
    func percent(_ key: String,_ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get:{ value(key)*100 },set:{ if $0.isFinite { set(key,min(range.upperBound,max(range.lowerBound,$0))/100) } })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            section("Mapping") { mappingControls }
            section("Appearance") { appearanceControls }
            section("Animation") { animationControls }
            section("Output") {
                percentControl("Brightness","brightness",0...200)
                if value("colorMode") == 0 && value("animation") == 0 && value("p2").rounded() < 8 {
                    percentControl("Mix","mix",0...100)
                }
            }
        }
    }
    var mappingControls: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Bar Count")
                Spacer()
                TextField("Bar Count",value:count,format:.number.grouping(.never)).textFieldStyle(.squareBorder).frame(width:70)
                Stepper("Bar Count",value:count,in:1...100).labelsHidden()
            }.midiParameter(workspace:workspace,id:id,key:"p1")
            percentControl("Gap Size","p3",0...95)
            percentControl("Vertical Offset","p4",-50...50)
        }
    }
    var appearanceControls: some View {
        VStack(alignment:.leading,spacing:12) {
            choice("Mode","colorMode",BlindsStyle.colorModes)
            if value("colorMode").rounded() == 0 {
                choice("Color Pattern","p2",BlindsControls.patterns)
            } else if value("colorMode").rounded() == 1 {
                colorControl("Top Color","gradientStart")
                colorControl("Bottom Color","gradientEnd")
                Button("Swap Colors") {
                    let start=value("gradientStart"),end=value("gradientEnd")
                    workspace.beginGesture()
                    set("gradientStart",end); set("gradientEnd",start)
                    workspace.endGesture("Swap Gradient Colors")
                }
                numberControl("Gradient Curve","gradientCurve",0.2...5)
            } else {
                choice("Filter","spectralType",BlindsStyle.spectralTypes)
                numberControl("Top Width · nm","spectralTop",0.1...1880)
                numberControl("Bottom Width · nm","spectralBottom",0.1...1880)
                choice("Width Progression","spectralDistribution",BlindsStyle.widthProgressions)
                numberControl("Spectrum Spread","spectralSpread",0.1...6.4)
                numberControl("Spectrum Position","spectralShift",-3.2...3.2)
            }
        }
    }
    var animationControls: some View {
        VStack(alignment:.leading,spacing:12) {
            choice("Animation","animation",BlindsStyle.animations)
            if value("animation") > 0 {
                numberControl("Speed","speed",0...3)
                choice("Direction","direction",BlindsStyle.directions)
                percentControl("Flash Width","pulseWidth",5...100)
                if [2,3].contains(Int(value("animation"))) { numberControl("Trail (bars)","trail",1...16) }
                if [3,4].contains(Int(value("animation"))) { percentControl("Speed Variation","variation",0...100) }
                percentControl("Background","background",0...100)
                if value("colorMode").rounded() != 2 {
                    choice("Color Motion","colorMotion",BlindsStyle.colorMotions)
                    if Int(value("colorMotion")) == 2 { numberControl("Color Rate","colorRate",0...2) }
                }
                HStack {
                    Text("Seed"); Spacer()
                    TextField("Seed",value:Binding(get:{ Int(value("seed").rounded()) },set:{ set("seed",Double(max(0,min(9999,$0)))) }),format:.number.grouping(.never)).textFieldStyle(.squareBorder).frame(width:70)
                }.midiParameter(workspace:workspace,id:id,key:"seed")
                Button("Reset Animation") {
                    workspace.beginGesture()
                    for spec in BlindsStyle.animationParameters where spec.key != "brightness" { set(spec.key,spec.initial) }
                    set("speed",1)
                    workspace.endGesture("Reset Bars Animation")
                }
            }
        }
    }
    func section<Content: View>(_ title: String,@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text(title.uppercased()).font(.editorHeading).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth:.infinity,alignment:.leading).padding(10)
            .background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:6))
    }
    func colorControl(_ title: String,_ key: String) -> some View {
        ColorPicker(title,selection:Binding(get:{
            let packed=Int(value(key).rounded())
            return Color(.sRGB,red:Double((packed>>16)&255)/255,green:Double((packed>>8)&255)/255,blue:Double(packed&255)/255,opacity:1)
        },set:{ color in
            guard let rgb=NSColor(color).usingColorSpace(.sRGB) else { return }
            let r=Int((min(1,max(0,rgb.redComponent))*255).rounded())
            let g=Int((min(1,max(0,rgb.greenComponent))*255).rounded())
            let b=Int((min(1,max(0,rgb.blueComponent))*255).rounded())
            set(key,Double((r<<16)|(g<<8)|b))
        }),supportsOpacity:false)
    }
    func choice(_ title: String,_ key: String,_ options: [String]) -> some View {
        Picker(title,selection:Binding(get:{ Int(value(key).rounded()) },set:{ set(key,Double($0)) })) {
            ForEach(Array(options.enumerated()),id:\.offset) { index,name in Text(name).tag(index) }
        }.pickerStyle(.menu)
    }
    func numberControl(_ title: String,_ key: String,_ range: ClosedRange<Double>) -> some View {
        let binding = Binding(get:{ value(key) },set:{ if $0.isFinite { set(key,min(range.upperBound,max(range.lowerBound,$0))) } })
        return VStack(spacing:5) {
            HStack {
                Text(title); Spacer()
                TextField(title,value:binding,format:.number.precision(.fractionLength(0...2))).textFieldStyle(.squareBorder).frame(width:65)
            }
            ParameterControl(value:binding,in:range,step:BlindsControls.specs.first(where:{ $0.key == key })?.step,showsValueField:false,onEditingChanged:{ editing in if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(title)") } }).controlSize(.small)
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
    func percentControl(_ title: String,_ key: String,_ range: ClosedRange<Double>) -> some View {
        VStack(spacing:5) {
            HStack {
                Text(title)
                Spacer()
                TextField(title,value:percent(key,range),format:.number.precision(.fractionLength(0...1))).textFieldStyle(.squareBorder).frame(width:65)
                Text("%").foregroundStyle(.secondary)
            }
            ParameterControl(value:percent(key,range),in:range,showsValueField:false,onEditingChanged:{ editing in if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(title)") } }).controlSize(.small)
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
}
