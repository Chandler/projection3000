import SwiftUI
import PatchCore

struct MetroEditor: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @State private var track=0
    @State private var lane="ratchet"
    @State private var latched=false
    @State private var loopStart: Int?
    @State private var loopEnd: Int?
    private var node: Node { workspace.graph.node(id) ?? Node(kind:.metroSequencer) }
    private var prefix: String { "t\(track)_" }
    private var accent: Color { track==0 ? .orange:.blue }
    private let ink=Color(white:0.12)
    private func bind(_ key: String) -> Binding<Double> {
        Binding(get:{ node.value(key) },set:{ value in
            guard let spec=MetroStyle.parameters.first(where:{ $0.key==key }),value.isFinite else { return }
            workspace.parameter(id,key,min(spec.max,max(spec.min,spec.step==1 ? value.rounded():value)))
        })
    }
    private func action(_ name: String,start: Int = 0,end: Int = 0) {
        renderer.midiGraph.metroAction(id,action:name,track:track,start:start,end:end)
    }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading) {
                    Text("METRO").font(.system(size:27,weight:.black,design:.rounded))
                    Text("EIGHT STAGES · TWO VOICES").font(.system(size:10,weight:.semibold,design:.monospaced))
                }
                Spacer()
                parameter("root",label:"Root").frame(width:110)
                parameter("set",label:"Pitch set").frame(width:195)
                parameter("bpm",label:"BPM").frame(width:140)
                Button(node.enabled ? "■ Pause":"▶ Run") { workspace.update(id) { $0.enabled.toggle() } }
                Button("Reset") { action("reset") }.help("Restart both tracks and clear accumulation")
            }.padding(18)
            Divider()
            HStack(alignment:.top,spacing:16) {
                performance.frame(width:205)
                VStack(spacing:12) {
                    HStack {
                        Text("SHARED PITCH / RHYTHM").font(.caption.bold())
                        Spacer()
                        Text("Pitch snaps to your selected set").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment:.top,spacing:8) {
                        ForEach(0..<8,id:\.self) { s in stage(s).frame(maxWidth:.infinity) }
                    }
                    HStack {
                        Text("TRACK \(track==0 ? "A":"B") LANE").font(.caption.bold())
                        Picker("Lane",selection:$lane) {
                            Text("Ratchet").tag("ratchet");Text("Chance %").tag("chance");Text("Accumulate °").tag("accum")
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    HStack(spacing:8) { ForEach(0..<8,id:\.self) { s in
                        parameter(prefix+lane+"\(s)",label:"\(s+1)").frame(maxWidth:.infinity)
                    } }
                    loopPads
                }
            }.padding(18)
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment:.top,spacing:15) {
                    parameter(prefix+"order",label:"Order").frame(width:150)
                    parameter(prefix+"reverse",label:"Direction").frame(width:115)
                    parameter(prefix+"length",label:"Stages").frame(width:85)
                    parameter(prefix+"offset",label:"Offset").frame(width:85)
                    parameter(prefix+"division",label:"Clock ÷").frame(width:85)
                    parameter(prefix+"pulseDiv",label:"Pulse ÷").frame(width:85)
                    parameter(prefix+"cycle",label:"Cycle · 0 Auto").frame(width:100)
                    parameter(prefix+"octave",label:"Octave").frame(width:85)
                    parameter(prefix+"channel",label:"MIDI channel").frame(width:100)
                }.padding(16)
            }
            HStack {
                Image(systemName:"macwindow")
                Text("Stays open · A/B/Both MIDI outputs · Hold uses MIDI legato")
                Spacer()
                Text("Internal clock · pulse ratchets · stage accumulation")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .foregroundStyle(ink).background(Color(red:0.93,green:0.92,blue:0.89))
        .preferredColorScheme(.light)
        .onDisappear { if !latched { action("release") } }
    }
    private var performance: some View {
        VStack(alignment:.leading,spacing:13) {
            TimelineView(.periodic(from:.now,by:0.05)) { _ in
                let all=renderer.midiGraph.state["metro"] as? [String:[[String:Any]]]
                let states=all?[id.uuidString] ?? []
                VStack(alignment:.leading,spacing:12) {
                    ForEach(0..<2,id:\.self) { t in
                        let state=states.indices.contains(t) ? states[t]:[:]
                        let note=(state["note"] as? Int).map(ArpeggiatorStyle.noteName) ?? "—"
                        HStack { Text(t==0 ? "▲ A":"● B").foregroundStyle(t==0 ? Color.orange:Color.cyan);Spacer();Text(note).font(.title2.monospaced()) }
                        Text("Stage \(state["stage"] as? Int ?? 1) · Δ \(state["accumulation"] as? Int ?? 0)°").font(.caption.monospaced()).foregroundStyle(.white.opacity(0.7))
                    }
                }.padding(12).foregroundStyle(.white).background(Color(white:0.12),in:RoundedRectangle(cornerRadius:6))
            }
            Picker("Edit track",selection:$track) { Text("▲ A").tag(0);Text("● B").tag(1) }.pickerStyle(.segmented)
                .onChange(of:track) { old,_ in if !latched { renderer.midiGraph.metroAction(id,action:"release",track:old) } }
            parameter(prefix+"mute",label:"Track")
            parameter(prefix+"gateLength",label:"Gate %")
            parameter(prefix+"velocity",label:"Velocity")
            parameter(prefix+"swing",label:"Swing %")
            parameter(prefix+"chanceMode",label:"Chance per")
            parameter(prefix+"limit",label:"Accum. limit °")
            parameter(prefix+"boundary",label:"Boundary")
            parameter(prefix+"freeze",label:"Accumulator")
            Button("Reset accumulation") { action("accumReset") }
            HStack {
                Button("Snapshot") { workspace.update(id) { $0.metroSnapshot=$0.parameters } }
                Button("Revert") { workspace.update(id) { n in if let saved=n.metroSnapshot { n.parameters=saved } } }.disabled(node.metroSnapshot==nil)
            }
        }.controlSize(.small)
    }
    private func stage(_ s: Int) -> some View {
        VStack(spacing:8) {
            TimelineView(.periodic(from:.now,by:0.05)) { _ in
                let all=renderer.midiGraph.state["metro"] as? [String:[[String:Any]]]
                let states=all?[id.uuidString] ?? []
                HStack {
                    ForEach(0..<2,id:\.self) { t in
                        let active=states.indices.contains(t) && (states[t]["stage"] as? Int)==s+1 && (states[t]["muted"] as? Bool)==false
                        Text(t==0 ? "▲":"●").foregroundStyle(active ? (t==0 ? Color.orange:.blue):Color.gray.opacity(0.22))
                    }
                    Text("\(s+1)").font(.headline.monospaced())
                }
            }
            MetroPitchFader(value:bind("pitch\(s)"),label:ArpeggiatorStyle.noteName(MetroStyle.note(node,track:track,stage:s)),
                            begin:{ workspace.beginGesture() },end:{ workspace.endGesture("Move Metro pitch") })
                .midiParameter(workspace:workspace,id:id,key:"pitch\(s)")
            parameter("pitch\(s)",label:"Degree")
            parameter("pulses\(s)",label:"Pulses")
            VStack(spacing:2) {
                ForEach(0..<4,id:\.self) { g in
                    Button(MetroStyle.gates[g]) { bind("gate\(s)").wrappedValue=Double(g) }
                        .buttonStyle(.plain).font(.system(size:11,weight:.medium))
                        .frame(maxWidth:.infinity).padding(.vertical,4)
                        .background(Int(node.value("gate\(s)"))==g ? ink:Color.black.opacity(0.05),in:RoundedRectangle(cornerRadius:3))
                        .foregroundStyle(Int(node.value("gate\(s)"))==g ? Color.white:ink)
                }
            }.midiParameter(workspace:workspace,id:id,key:"gate\(s)")
            Toggle("Skip",isOn:Binding(get:{ node.value(prefix+"skip\(s)")>0.5 },set:{ bind(prefix+"skip\(s)").wrappedValue=$0 ? 1:0 })).toggleStyle(.checkbox).font(.caption)
                .midiParameter(workspace:workspace,id:id,key:prefix+"skip\(s)")
        }
    }
    private var loopPads: some View {
        VStack(spacing:6) {
            HStack {
                Text("LOOP · hold or drag across stages").font(.caption.bold())
                Spacer()
                Toggle("Latch",isOn:$latched).toggleStyle(.checkbox).font(.caption)
                Button("Release") { action("release");latched=false;loopStart=nil;loopEnd=nil }
            }
            GeometryReader { geo in
                HStack(spacing:6) { ForEach(0..<8,id:\.self) { s in
                    Text("\(s+1)").font(.headline.monospaced()).frame(maxWidth:.infinity,maxHeight:.infinity)
                        .background(loopStart.map { s>=min($0,loopEnd ?? $0) && s<=max($0,loopEnd ?? $0) }==true ? accent.opacity(0.5):Color.black.opacity(0.08),in:RoundedRectangle(cornerRadius:5))
                } }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { g in
                    let end=max(0,min(7,Int(g.location.x/geo.size.width*8)))
                    let start=max(0,min(7,Int(g.startLocation.x/geo.size.width*8)))
                    if loopStart != start || loopEnd != end { loopStart=start;loopEnd=end;action("loop",start:start,end:end) }
                }.onEnded { _ in if !latched { action("release");loopStart=nil;loopEnd=nil } })
            }.frame(height:36)
        }
    }
    private func parameter(_ key: String,label: String) -> some View {
        let spec=MetroStyle.parameters.first { $0.key==key }!
        let value=bind(key)
        return VStack(alignment:.leading,spacing:3) {
            Text(label).font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
            if let choices=spec.choices {
                Picker(label,selection:value) { ForEach(Array(choices.enumerated()),id:\.offset) { i,name in Text(name).tag(Double(i)) } }.labelsHidden()
            } else {
                HStack(spacing:2) {
                    TextField(label,value:value,format:.number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder).font(.caption.monospaced()).frame(minWidth:25)
                    Stepper(label,value:value,in:spec.min...spec.max,step:spec.step ?? 1).labelsHidden().fixedSize()
                }
                if spec.min<0 { Button("Zero") { value.wrappedValue=0 }.font(.caption2) }
            }
        }.controlSize(.mini).midiParameter(workspace:workspace,id:id,key:key)
    }
}
private struct MetroPitchFader: View {
    @Binding var value: Double
    var label: String
    var begin: ()->Void
    var end: ()->Void
    var body: some View {
        VStack(spacing:5) {
            GeometryReader { geo in
                ZStack(alignment:.top) {
                    RoundedRectangle(cornerRadius:3).fill(Color(white:0.15)).frame(width:12)
                    ForEach(0...16,id:\.self) { tick in
                        Rectangle().fill(Color.gray.opacity(tick%4==0 ? 0.8:0.35)).frame(width:tick%4==0 ? 38:26,height:1).offset(y:(geo.size.height-12)*(1-Double(tick)/16)+6)
                    }
                    RoundedRectangle(cornerRadius:3).fill(Color(red:0.78,green:0.16,blue:0.16)).frame(width:28,height:12).shadow(radius:1)
                        .offset(y:(geo.size.height-12)*(1-value/16))
                }.frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:0).onChanged { g in begin();value=(max(0,min(1,1-(g.location.y-6)/(geo.size.height-12)))*16).rounded() }.onEnded { _ in end() })
            }.frame(height:190)
            Text(label).font(.system(size:16,weight:.semibold,design:.monospaced))
        }.accessibilityElement(children:.ignore).accessibilityLabel("Pitch \(label)").accessibilityValue("Degree \(Int(value))")
            .accessibilityAdjustableAction { direction in value=max(0,min(16,value+(direction == .increment ? 1:-1))) }
    }
}
