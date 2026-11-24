import SwiftUI
import AppKit
import PatchCore

struct VoltageTrailInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    private func number(_ key: String,_ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get:{ workspace.graph.node(id)?.value(key) ?? range.lowerBound },set:{ value in
            if value.isFinite { workspace.parameter(id,key,min(range.upperBound,max(range.lowerBound,value))) }
        })
    }
    var body: some View {
        if let node=workspace.graph.node(id) {
            VStack(alignment:.leading,spacing:10) {
                Text("Connect XY together, or wire X and Y separately. Separate inputs take precedence for that axis; an unconnected axis is zero. Timing offset is retained.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("TRAIL DURATION").font(.editorHeading).foregroundStyle(.secondary)
                Picker("Timing",selection:Binding(get:{ node.value("historyMS")>0 ? 0:1 },set:{ mode in
                    let scope=renderer.voltageScope(id)
                    let rate=scope?.rate ?? node.value("rate")
                    let seconds=AnalogVectorStyle.trailSeconds(node,rate:rate)
                    workspace.update(id,action:"Change Trail Timing") {
                        if mode==0 { $0.parameters["historyMS"]=min(300,max(0.1,seconds*1000)) }
                        else { $0.parameters["cycles"]=min(8,max(0.1,seconds*rate));$0.parameters["historyMS"]=0 }
                    }
                })) {
                    Text("Milliseconds").tag(0)
                    Text("Draw cycles").tag(1)
                }
                if node.value("historyMS")>0 {
                    HStack {
                        Text("Trail duration (ms)");Spacer()
                        TextField("Trail duration (ms)",value:number("historyMS",0.1...300),format:.number.precision(.fractionLength(0...3)))
                            .textFieldStyle(.squareBorder).frame(width:85)
                    }.midiParameter(workspace:workspace,id:id,key:"historyMS")
                } else {
                    VStack(alignment:.leading,spacing:4) {
                        HStack {
                            Text("Draw cycles");Spacer()
                            TextField("Draw cycles",value:number("cycles",0.1...8),format:.number.precision(.fractionLength(0...3)))
                                .textFieldStyle(.squareBorder).frame(width:85)
                        }
                        ParameterControl(value:number("cycles",0.1...8),in:0.1...8,onEditingChanged:{ editing in
                            if editing { workspace.beginGesture() } else { workspace.endGesture("Change Draw cycles") }
                        })
                    }.midiParameter(workspace:workspace,id:id,key:"cycles")
                    if !workspace.graph.edges.contains(where:{ $0.target==id && $0.input==1 }) {
                        VStack(alignment:.leading,spacing:4) {
                            HStack {
                                Text("Unlinked draw rate (Hz)");Spacer()
                                TextField("Unlinked draw rate (Hz)",value:number("rate",5...1000),format:.number.precision(.fractionLength(0...3)))
                                    .textFieldStyle(.squareBorder).frame(width:85)
                            }
                            ParameterControl(value:number("rate",5...1000),in:5...1000,onEditingChanged:{ editing in
                                if editing { workspace.beginGesture() } else { workspace.endGesture("Change Unlinked draw rate (Hz)") }
                            })
                        }.midiParameter(workspace:workspace,id:id,key:"rate")
                    }
                }
                TimelineView(.periodic(from:.now,by:0.25)) { _ in
                    let scope=renderer.voltageScope(id)
                    let rate=scope?.rate ?? node.value("rate")
                    let seconds=scope?.seconds ?? AnalogVectorStyle.trailSeconds(node,rate:rate)
                    let history=renderer.audioGraph.oscilloscopeSamples(scope?.source,seconds:seconds)
                    Text(String(format:"%.2f ms · %d samples · %.0f kHz",seconds*1000,history.points.count,history.rate/1000))
                        .font(.editorValue).foregroundStyle(.secondary)
                    Text(String(format:"%.3f draw cycles at %.3f Hz%@",seconds*rate,rate,scope?.linked == true ? " · linked":" · unlinked"))
                        .font(.caption).foregroundStyle(.secondary)
                }

            }
        }
    }
}

struct HardwareAudioInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    var body: some View {
        if let node=workspace.graph.node(id) {
            TimelineView(.periodic(from:.now,by:2)) { _ in
                let input=node.kind == .audioInput
                let devices=HardwareAudioDevice.devices.filter { input ? $0.inputs>=2:$0.outputs>=2 }
                Picker(input ? "Input device":"Output device",selection:Binding(get:{ workspace.graph.node(id)?.deviceID ?? "" },set:{ value in workspace.update(id) { $0.deviceID=value.isEmpty ? nil:value } })) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                    if let selected=node.deviceID,!devices.contains(where:{ $0.id == selected }) { Text("Disconnected device").tag(selected) }
                }
            }
            ForEach(AnalogVectorStyle.channelParameters,id:\.key) { p in
                Picker(p.title,selection:Binding(get:{ Int(workspace.graph.node(id)?.value(p.key) ?? p.initial) },set:{ workspace.parameter(id,p.key,Double($0)) })) {
                    ForEach(1...64,id:\.self) { Text(String($0)).tag($0) }
                }.midiParameter(workspace:workspace,id:id,key:p.key)
            }
            TimelineView(.periodic(from:.now,by:0.5)) { _ in Text(renderer.status[id] ?? "Waiting for audio").font(.editorValue).foregroundStyle(.secondary) }
        }
    }
}

struct ProjectorInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    @State private var dragging=false
    var body: some View {
        if let node=workspace.graph.node(id) {
            Picker("Display",selection:Binding(get:{ workspace.graph.node(id)?.deviceID ?? "" },set:{ value in workspace.update(id) { $0.deviceID=value.isEmpty ? nil:value } })) {
                Text("Window").tag("")
                ForEach(NSScreen.screens,id:\.patchDisplayID) { screen in Text(screen.localizedName).tag(screen.patchDisplayID) }
                if let selected=node.deviceID,!NSScreen.screens.contains(where:{ $0.patchDisplayID == selected }) { Text("Disconnected display").tag(selected) }
            }
            GeometryReader { geo in
                let p=ProjectorRenderer.corners(node)
                let inset: CGFloat=12,w=max(1,geo.size.width-24),h=max(1,geo.size.height-24)
                let corners=p.map { CGPoint(x:inset+$0.x*w,y:inset+$0.y*h) }
                ZStack {
                    Color.black
                    Path { path in path.addLines(corners);path.closeSubpath() }.fill(Color.green.opacity(0.16))
                    Path { path in path.addLines(corners);path.closeSubpath() }.stroke(Color.green,lineWidth:1)
                    ForEach(0..<4,id:\.self) { i in
                        Circle().fill(Color.white).frame(width:14,height:14).position(corners[i])
                            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("projectorQuad")).onChanged { value in
                                if !dragging { workspace.beginGesture();dragging=true }
                                var next=ProjectorRenderer.corners(workspace.graph.node(id) ?? node)
                                next[i]=SIMD2(min(1,max(0,(value.location.x-inset)/w)),min(1,max(0,(value.location.y-inset)/h)))
                                guard ProjectorRenderer.valid(next) else { return }
                                let key=["tl","tr","br","bl"][i]
                                workspace.update(id) { $0.parameters[key+"X"]=next[i].x;$0.parameters[key+"Y"]=next[i].y }
                            }.onEnded { _ in dragging=false;workspace.endGesture("Map Projector") })
                    }
                }.coordinateSpace(name:"projectorQuad")
            }.frame(height:180)
            Button("Reset mapping") {
                workspace.update(id) { n in for p in AnalogVectorStyle.projectorParameters { n.parameters[p.key]=p.initial } }
            }
        }
    }
}
extension NSScreen {
    var patchDisplayID: String { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? localizedName }
}
