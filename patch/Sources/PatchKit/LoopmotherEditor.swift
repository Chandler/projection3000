import SwiftUI
import PatchCore

/// A fixed node editor: selection elsewhere never changes the instrument it controls.
/// Laid out like the Grandmother's panel: one colored module per stage of the signal path.
struct LoopmotherEditor: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    private var node: Node? { workspace.graph.node(id) }
    private struct Control: Identifiable { let id: String; let label: String; init(_ key: String,_ label: String) { id=key;self.label=label } }
    private struct Module: Identifiable { let id: String; let color: Color; let ink: Color; let controls: [Control] }
    private static let panelBlack=Color(red:0.09,green:0.09,blue:0.10)
    private static let modules: [Module] = [
        .init(id:"MODULATION",color:Color(red:0.93,green:0.77,blue:0.24),ink:.black,controls:[
            .init("lfoRate","RATE"),.init("lfoWave","WAVEFORM"),.init("lfoPitch","PITCH AMT"),.init("lfoCutoff","CUTOFF AMT")]),
        .init(id:"OSCILLATORS",color:Color(red:0.19,green:0.45,blue:0.72),ink:.white,controls:[
            .init("osc1Wave","OSC 1 WAVE"),.init("osc1Octave","OSC 1 OCTAVE"),.init("osc2Wave","OSC 2 WAVE"),.init("osc2Octave","OSC 2 OCTAVE"),.init("detune","OSC 2 FREQ")]),
        .init(id:"MIXER",color:panelBlack,ink:.white,controls:[
            .init("osc1Level","OSC 1"),.init("osc2Level","OSC 2"),.init("noise","NOISE"),.init("instrument","INSTRUMENT IN")]),
        .init(id:"FILTER",color:Color(red:0.22,green:0.55,blue:0.38),ink:.white,controls:[
            .init("cutoff","CUTOFF"),.init("resonance","RESONANCE"),.init("envAmount","ENVELOPE AMT"),.init("tracking","KB TRACK")]),
        .init(id:"ENVELOPE",color:Color(red:0.80,green:0.28,blue:0.20),ink:.white,controls:[
            .init("attack","ATTACK"),.init("decay","DECAY"),.init("sustain","SUSTAIN"),.init("release","RELEASE")]),
        .init(id:"OUTPUT",color:panelBlack,ink:.white,controls:[
            .init("volume","VOLUME"),.init("reverb","SPRING REVERB"),.init("glide","GLIDE"),.init("vca","VCA MODE"),.init("poly","VOICES")])
    ]
    var body: some View {
        VStack(spacing:0) {
            HStack(alignment:.center) {
                VStack(alignment:.leading,spacing:4) {
                    Text("LOOPMOTHER").font(.system(size:23,weight:.semibold,design:.rounded))
                    Text(node?.name ?? "Instrument removed").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("MIDI + INSTRUMENT IN → SYNTH → AUDIO OUT").font(.caption.monospaced()).foregroundStyle(.secondary)
            }.padding(20)
            ScrollView([.horizontal,.vertical]) {
                HStack(alignment:.top,spacing:3) {
                    ForEach(Self.modules) { module($0) }
                }.padding(3).background(Color.black).frame(maxWidth:.infinity)
            }
            HStack {
                Image(systemName:"macwindow")
                Text("Drag a knob to turn it · double-click to reset · stays open while you select other nodes")
                Spacer()
                TimelineView(.periodic(from:.now,by:0.2)) { _ in
                    Text(renderer.audioGraph.snapshot.1[id] ?? "Connect MIDI In and Audio Output")
                        .lineLimit(1)
                }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .background(Color(nsColor:.patchPanel)).preferredColorScheme(.dark)
    }
    private func module(_ module: Module) -> some View {
        VStack(spacing:18) {
            Text(module.id).font(.system(size:12,weight:.heavy)).tracking(1.6).foregroundStyle(module.ink)
            LazyVGrid(columns:[GridItem(.fixed(80)),GridItem(.fixed(80))],spacing:20) {
                ForEach(module.controls) { control in
                    if let spec=LoopmotherStyle.parameters.first(where:{ $0.key==control.id }) { parameter(spec,label:control.label,ink:module.ink) }
                }
            }
            Spacer(minLength:0)
        }
        .padding(.horizontal,8).padding(.vertical,16).frame(width:180).frame(minHeight:440,alignment:.top)
        .background(module.color)
    }
    private func binding(_ spec: ParameterSpec) -> Binding<Double> {
        Binding(get:{ node?.value(spec.key) ?? spec.initial },set:{ value in
            guard value.isFinite else { return }
            workspace.parameter(id,spec.key,min(spec.max,max(spec.min,value)))
        })
    }
    @ViewBuilder private func parameter(_ spec: ParameterSpec,label: String,ink: Color) -> some View {
        if spec.choices?.count == 2 {
            LoopmotherSwitch(label:label,spec:spec,ink:ink,value:binding(spec)).midiParameter(workspace:workspace,id:id,key:spec.key)
        } else {
            LoopmotherKnob(label:label,spec:spec,ink:ink,value:binding(spec),onEditingChanged:{ editing in
                if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(spec.title)") }
            }).midiParameter(workspace:workspace,id:id,key:spec.key)
        }
    }
}

/// Rotary control with a 270° sweep. Wide positive ranges (cutoff, rates, times) turn logarithmically;
/// choice parameters click between positions.
private struct LoopmotherKnob: View {
    let label: String
    let spec: ParameterSpec
    let ink: Color
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @State private var dragStart: Double?
    private var positions: Int? { spec.choices?.count }
    private var logarithmic: Bool { spec.choices == nil && spec.min>0 && spec.max/spec.min>=100 }
    private var normalized: Double {
        let n=logarithmic ? log(max(spec.min,value)/spec.min)/log(spec.max/spec.min) : (value-spec.min)/(spec.max-spec.min)
        return min(1,max(0,n))
    }
    private func turn(to position: Double) {
        var n=min(1,max(0,position))
        if let positions,positions>1 { n=(n*Double(positions-1)).rounded()/Double(positions-1) }
        value=logarithmic ? spec.min*pow(spec.max/spec.min,n) : spec.min+n*(spec.max-spec.min)
    }
    var body: some View {
        VStack(spacing:5) {
            ZStack {
                Canvas { context,size in
                    let center=CGPoint(x:size.width/2,y:size.height/2),count=positions ?? 11
                    for i in 0..<count {
                        let angle=(-225+270*Double(i)/Double(max(1,count-1))) * .pi/180
                        var tick=Path()
                        tick.move(to:CGPoint(x:center.x+cos(angle)*28,y:center.y+sin(angle)*28))
                        tick.addLine(to:CGPoint(x:center.x+cos(angle)*32,y:center.y+sin(angle)*32))
                        context.stroke(tick,with:.color(ink.opacity(0.75)),lineWidth:1.5)
                    }
                }
                Circle().fill(LinearGradient(colors:[Color(white:0.24),Color(white:0.03)],startPoint:.top,endPoint:.bottom))
                    .frame(width:46,height:46).shadow(color:.black.opacity(0.55),radius:3,y:2)
                Circle().fill(LinearGradient(colors:[Color(white:0.32),Color(white:0.12)],startPoint:.top,endPoint:.bottom))
                    .frame(width:30,height:30)
                Capsule().fill(Color.white).frame(width:3,height:13).offset(y:-15)
                    .rotationEffect(.degrees(-135+270*normalized))
            }
            .frame(width:68,height:68).contentShape(Circle())
            .gesture(DragGesture(minimumDistance:2).onChanged { drag in
                if dragStart == nil { dragStart=normalized;onEditingChanged(true) }
                turn(to:(dragStart ?? 0)+Double(drag.translation.width-drag.translation.height)/160)
            }.onEnded { _ in dragStart=nil;onEditingChanged(false) })
            .simultaneousGesture(TapGesture(count:2).onEnded { value=spec.initial })
            Text(label).font(.system(size:9,weight:.bold)).tracking(0.8).foregroundStyle(ink)
                .multilineTextAlignment(.center).lineLimit(2).frame(height:24,alignment:.top)
            if let choices=spec.choices {
                Text(choices[min(choices.count-1,max(0,Int(value.rounded())))])
                    .font(.system(size:10,design:.monospaced)).foregroundStyle(ink.opacity(0.8))
            } else {
                TextField(spec.title,value:$value,format:.number.precision(.fractionLength(0...(spec.max>=100 ? 0 : 3))))
                    .textFieldStyle(.plain).multilineTextAlignment(.center)
                    .font(.system(size:10,design:.monospaced)).foregroundStyle(ink.opacity(0.8)).frame(width:64)
                    .help("Enter an exact value")
            }
        }
        .frame(width:80).help(spec.title).accessibilityLabel(spec.title)
    }
}

/// Two-position rocker for the two-choice parameters.
private struct LoopmotherSwitch: View {
    let label: String
    let spec: ParameterSpec
    let ink: Color
    @Binding var value: Double
    private var on: Bool { value>=0.5 }
    private func caption(_ index: Int) -> some View {
        Text(spec.choices?[index] ?? "").font(.system(size:9,design:.monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(ink.opacity((index == 1) == on ? 0.95 : 0.5))
    }
    var body: some View {
        VStack(spacing:5) {
            caption(1)
            ZStack {
                RoundedRectangle(cornerRadius:4).fill(Color(white:0.04)).frame(width:24,height:42)
                    .overlay(RoundedRectangle(cornerRadius:4).stroke(Color(white:0.35),lineWidth:1))
                RoundedRectangle(cornerRadius:3).fill(LinearGradient(colors:[Color(white:0.9),Color(white:0.6)],startPoint:.top,endPoint:.bottom))
                    .frame(width:18,height:18).offset(y:on ? -10 : 10)
            }
            .contentShape(Rectangle()).onTapGesture { value=on ? 0 : 1 }
            caption(0)
            Text(label).font(.system(size:9,weight:.bold)).tracking(0.8).foregroundStyle(ink)
        }
        .frame(width:80,height:122).help(spec.title).accessibilityLabel(spec.title)
    }
}
