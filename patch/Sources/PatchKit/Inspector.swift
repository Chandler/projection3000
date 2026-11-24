import SwiftUI
import AppKit
import AVFoundation
import PatchCore

struct MetalPreview: NSViewRepresentable {
    let renderer: Renderer
    let id: UUID?
    func makeNSView(context: Context) -> VideoView { let v = VideoView(renderer:renderer); v.nodeID = id; return v }
    func updateNSView(_ view: VideoView, context: Context) { view.nodeID = id }
}
struct Inspector: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var userLibrary = UserNodeLibrary.shared
    let renderer: Renderer
    var fixedID: UUID? = nil
    var isLibraryPreview = false
    var node: Node? { (fixedID ?? workspace.selected).flatMap { workspace.graph.node($0) } }
    var viewerID: UUID? {
        guard let node else { return nil }
        return isLibraryPreview && node.kind.isOutput ? workspace.graph.edges.first { $0.target == node.id && $0.input == 0 }?.source : node.id
    }
    var body: some View {
        if fixedID == nil,let preview = workspace.libraryPreview {
            Inspector(workspace:preview,renderer:renderer,isLibraryPreview:true)
        } else { content }
    }
    var content: some View {
        VStack(spacing:0) {
            HStack {
                Text(isLibraryPreview ? "LIBRARY PREVIEW" : "VIEWER").font(.editorHeading).foregroundStyle(.secondary)
                Spacer()
                if let node,!isLibraryPreview { Button { let showing = workspace.backdropEnabled && workspace.backdropID == node.id; workspace.backdropID = node.id; workspace.backdropEnabled = !showing } label: { Image(systemName:"rectangle.on.rectangle") }.buttonStyle(.plain).help("Use as graph backdrop")
                    Button { workspace.onPinnedPreview?(node.id) } label: { Image(systemName:"pin") }.buttonStyle(.plain).help("Keep this node open in its own window")
                    Button { workspace.selected = node.id; workspace.onPreview?() } label: { Image(systemName:"arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help("Preview selected node (Space)") }
            }.padding(.horizontal,16).padding(.vertical,12)
            if let node,node.kind.isMIDINode {
                TimelineView(.periodic(from:.now,by:0.1)) { _ in
                    VStack(spacing:12) {
                        Image(systemName:"pianokeys").font(.system(size:28))
                        Text("MIDI · NOTES & CONTROL").font(.editorValue)
                        Text(renderer.midiGraph.status[node.id] ?? "Waiting for MIDI").font(.editorItem).multilineTextAlignment(.center)
                    }.padding().frame(maxWidth:.infinity).frame(height:180).background(.black)
                }
            } else {
                MetalPreview(renderer:renderer,id:viewerID).id(viewerID).frame(height:180).background(.black)
            }
            HStack {
                Text(node?.name ?? "No selection").lineLimit(1)
                Spacer()
                if let node {
                    if node.kind.previewKind == .video {
                        let size = workspace.graph.videoDimensions(node.id)
                        Text("\(size.width) × \(size.height)").monospacedDigit()
                    } else {
                        Text(node.kind.outputType?.rawValue.capitalized ?? node.kind.category)
                    }
                }

            }.font(.editorItem).padding(12)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if let node {
                        HStack {
                            Text(node.catalogTitle).font(.editorTitle).foregroundStyle(Color(nsColor:.node(node.kind)))
                            Spacer()
                            Toggle(node.kind.isOutput ? "Active" : "Enabled",isOn:Binding(get:{ self.node?.enabled ?? true },set:{ value in workspace.update(node.id,action:value ? "Resume Node" : "Pause Node") { $0.enabled = value } })).toggleStyle(.checkbox).controlSize(.mini).disabled(isLibraryPreview && node.kind.isOutput)
                        }
                        TextField("Name",text:Binding(get:{ self.node?.name ?? "" },set:{ name in workspace.update(node.id,action:"Rename Node") { $0.name = name } })).textFieldStyle(.squareBorder)
                        DisclosureGroup("Ports") {
                            ForEach([false,true],id:\.self) { output in
                                ForEach(node.kind.ports(output:output).filter { output || node.inputs.indices.contains($0.index) },id:\.id) { port in
                                    HStack {
                                        Image(systemName:output ? "arrow.up.right" : "arrow.down.right")
                                        Text(port.name)
                                        Spacer()
                                        Text(port.type.rawValue).foregroundStyle(Color(nsColor:.signal(port.type)))
                                    }.font(.callout)
                                }
                            }
                        }
                        if !isLibraryPreview,let app = NodeApp.for(node) { NodeAppButton(workspace:workspace,id:node.id,app:app) }
                        if !isLibraryPreview { PublicationInspector(workspace:workspace,node:node) }
                        if let status = renderer.status[node.id], status != "Ready", !node.kind.isOutput {
                            Text(status).font(.editorCaption.monospacedDigit()).foregroundStyle(status.contains("vertices") ? Color.secondary : Color.orange).textSelection(.enabled)
                        }
                        if node.kind == .meshGradient || node.kind == .dotColors || node.kind == .flipDots || node.kind == .projectionDots || node.kind == .scene || node.kind == .shader || node.kind == .shaderEffect || node.kind == .dataStream || node.kind == .blockerField || node.kind == .streakField || node.kind == .waterfallField || node.kind == .cellularField {
                            let source = node.file.map { URL(fileURLWithPath:$0) } ?? (node.kind == .dotColors ? UserNodeLibrary.dotColorsURL : node.kind == .flipDots ? UserNodeLibrary.flipDotsURL : node.kind == .projectionDots ? UserNodeLibrary.projectionDotsURL : node.kind == .cellularField ? UserNodeLibrary.cellularFieldURL : node.kind == .waterfallField ? UserNodeLibrary.waterfallFieldURL : node.kind == .scene ? UserNodeLibrary.pastelURL : node.kind == .dataStream ? UserNodeLibrary.dataStreamURL : node.kind == .blockerField ? UserNodeLibrary.blockerFieldURL : node.kind == .streakField ? UserNodeLibrary.streakFieldURL : nil)
                            if let source { Button("Reveal Source File") { NSWorkspace.shared.activateFileViewerSelecting([source]) } }
                        }
                        if [.meshGradient,.dotColors,.flipDots,.projectionDots,.image,.video,.audio,.shader,.shaderEffect,.scene,.dataStream,.blockerField,.streakField,.waterfallField,.cellularField].contains(node.kind) {
                            VStack(alignment:.leading,spacing:8) {
                                Text(node.file.map { URL(fileURLWithPath:$0).lastPathComponent } ?? "No file selected").foregroundStyle(.secondary).lineLimit(2)
                                Button("Choose \(node.kind == .image ? "Image" : (node.kind == .audio ? "Audio" : (node.kind == .video ? "Video" : "Shader")))…") { workspace.chooseMedia(node.id) }
                            }
                        }
                        if node.kind == .image || node.kind == .video {
                            HStack {
                                Button("↶ 90°") { rotate(node,-90) }.help("Rotate counterclockwise")
                                Button("↷ 90°") { rotate(node,90) }.help("Rotate clockwise")
                            }
                        }
                        if node.kind == .posterComposer,let layout = node.poster {
                            sectionLabel("LAYOUT")
                            Text("Free layout · \(layout.elements.count) elements. Edit it in the Poster Editor.").font(.editorItem).foregroundStyle(.secondary)
                            Button("Revert to Tagged Text") { workspace.update(node.id,action:"Revert Poster Layout") { $0.poster = nil } }
                        } else if node.kind == .text || node.kind == .vectorText || node.kind == .laserLettering || node.kind == .posterComposer {
                            sectionLabel("TEXT")
                            TextEditor(text:Binding(get:{ self.node?.text ?? (self.node?.kind == .posterComposer ? PosterStyle.defaultText : "") },set:{ value in workspace.update(node.id) { $0.text = value } })).font(.system(size:13,design:.monospaced)).frame(height:100).border(Color.gray.opacity(0.4))
                        }
                        if node.kind == .webcam {
                            Picker("Camera",selection:Binding(get:{ self.node?.deviceID ?? "" },set:{ value in workspace.update(node.id) { $0.deviceID = value.isEmpty ? nil : value } })) {
                                Text("Default camera").tag("")
                                ForEach(CameraSource.devices,id:\.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                            }
                        }
                        if node.kind == .audioInput || node.kind == .audioOutput { HardwareAudioInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .audioPlugin { AudioPluginInspector(workspace:workspace,id:node.id) }
                        if node.kind == .midiIn { MIDIInputInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if [.midiMonitor,.midiFilter,.midiTransform,.midiMerge].contains(node.kind) { MIDIMonitorInspector(renderer:renderer,id:node.id) }
                        if node.kind == .midiOut { MIDIOutputInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .metroSequencer { Text("Eight shared stages, two MIDI voices. Open the instrument to edit pitches, pulses, gates and accumulation.").font(.editorItem) }
                        if node.kind == .arpeggiator { ArpeggiatorInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .projector { ProjectorInspector(workspace:workspace,id:node.id) }
                        if node.kind == .oscilloscope {
                            Text("Time runs left to right. Left / X is green; Right / Y is orange. The time window spans ten grid divisions. Gains show normalized audio amplitude; physical voltage depends on the interface.").font(.editorItem).foregroundStyle(.secondary)
                            Text("Edge triggering steadies repeating signals. With one channel displayed, that channel also supplies the trigger.").font(.editorItem).foregroundStyle(.secondary)
                            Text(String(format:"%.3g ms / horizontal division",node.value("timeMS")/10)).font(.editorValue).foregroundStyle(.secondary)
                            Button("Fit channels to input") {
                                let points=renderer.audioGraph.oscilloscopeSamples(node.id,seconds:0.1).points
                                let peak=points.reduce(SIMD2<Float>.zero) { SIMD2(max($0.x,abs($1.x)),max($0.y,abs($1.y))) }
                                workspace.update(node.id) {
                                    if peak.x>0.0001 { $0.parameters["gainX"]=min(200,max(0.01,0.85/Double(peak.x))) }
                                    if peak.y>0.0001 { $0.parameters["gainY"]=min(200,max(0.01,0.85/Double(peak.y))) }
                                    $0.parameters["offsetX"]=0;$0.parameters["offsetY"]=0
                                }
                            }
                        }
                        if node.kind == .voltageVisualizer {
                            VoltageTrailInspector(workspace:workspace,renderer:renderer,id:node.id)
                            Button("Fit XY to input") {
                                let points=renderer.audioGraph.voltageSamples(node.id,count:4800)
                                let peak=points.reduce(SIMD2<Float>.zero) { SIMD2(max($0.x,abs($1.x)),max($0.y,abs($1.y))) }
                                if peak.x>0.0001,peak.y>0.0001 {
                                    workspace.update(node.id) { $0.parameters["gainX"]=min(200,max(0.01,0.78/Double(peak.x)));$0.parameters["gainY"]=min(200,max(0.01,0.78/Double(peak.y)));$0.parameters["zoom"]=1;$0.parameters["x"]=0;$0.parameters["y"]=0 }
                                }
                            }
                        }
                        if node.kind == .microphone {
                            TimelineView(.periodic(from:.now,by:2)) { _ in
                                let devices = MicrophoneSource.devices
                                Picker("Input",selection:Binding(get:{ self.node?.deviceID ?? "" },set:{ value in workspace.update(node.id) { $0.deviceID = value.isEmpty ? nil : value } })) {
                                    Text("Default microphone").tag("")
                                    ForEach(devices,id:\.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                                    if let id = self.node?.deviceID,!devices.contains(where:{ $0.uniqueID == id }) { Text("Disconnected input").tag(id) }
                                }
                            }
                            TimelineView(.periodic(from:.now,by:0.2)) { _ in Text(renderer.status[node.id] ?? "Starting microphone…").font(.editorCaption.monospacedDigit()).foregroundStyle(.secondary) }
                            Text("Connect to Audio Envelope to drive parameters.").font(.editorCaption).foregroundStyle(.secondary)
                        }
                        if node.kind == .audioVisualizer {
                            let mode=Int(node.value("mode"))
                            Text(["X · Time (ms)    Y · Amplitude (−1…1)","X · Frequency (Hz)    Y · Level (dBFS)","X · Time (s)    Y · Frequency (Hz)","Angle · Frequency (Hz)    Radius · Level (dBFS)","X · Frequency (Hz)    Height · Level (dBFS)","X · Frequency, lows centered    Depth · Time (s)"][max(0,min(5,mode))])
                                .font(.editorCaption.monospacedDigit()).foregroundStyle(.secondary)
                            if mode == 2 { Text("Brightness · Level (dBFS)").font(.editorCaption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        if node.kind == .yoloPose {
                            TimelineView(.periodic(from:.now,by:0.2)) { _ in
                                Text(renderer.status[node.id] ?? "Loading YOLO…").font(.editorCaption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text("17 joints per person · normalized 0–1 · top-left origin").font(.editorCaption).foregroundStyle(.secondary)
                            Button("Reveal Model Folder") { NSWorkspace.shared.open(PoseDetectionResource.defaultModelURL.deletingLastPathComponent()) }
                        }
                        if node.kind == .faceDetect { FaceCoordinateReadout(renderer:renderer,id:node.id) }
                        if node.kind.vectorArtModule != nil, let seed = node.parameterSpecs.first(where: { $0.key == "seed" }) {
                            Button("Reseed") { workspace.parameter(node.id,seed.key,Double(Int.random(in:Int(seed.min)...Int(seed.max)))) }
                        }
                        if node.kind == .cellularField { Button("Reseed") { workspace.parameter(node.id,"seed",Double(Int(node.value("seed")+1)%65536)) } }
                        if node.kind == .apc40 && !isLibraryPreview { Button("Pop out APC40") { workspace.onAPCWindow?(node.id) } }
                        if node.kind == .liveStream { LiveStreamInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .syphonIn { SyphonInputInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .ndiIn { NDIInputInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .video || node.kind == .audio { MediaTransportInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if !node.inputs.isEmpty && node.kind != .mux {
                            VStack(alignment:.leading,spacing:8) {
                                sectionLabel("INPUTS")
                                ForEach(Array(node.inputs.enumerated()),id:\.offset) { index,name in
                                    HStack {
                                        Rectangle().fill(Color(nsColor:.node(node.kind))).frame(width:5,height:5)
                                        Text(name).frame(width:36,alignment:.leading).foregroundStyle(.secondary)
                                        let edge = workspace.graph.edges.first { $0.target == node.id && $0.input == index }
                                        Text(edge.flatMap { workspace.graph.node($0.source)?.name } ?? "Not connected").lineLimit(1)
                                        Spacer(minLength:0)
                                        if edge != nil && !isLibraryPreview { Button { workspace.edit("Disconnect") { $0.edges.removeAll { $0.target == node.id && $0.input == index } } } label: { Image(systemName:"xmark").font(.system(size:8)) }.buttonStyle(.plain).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                        if let midi = workspace.midi,!isLibraryPreview {
                            MIDIInspector(workspace:workspace,midi:midi,id:node.id)
                            if node.kind == .mux || node.kind == .layerMux { MUXInspector(workspace:workspace,midi:midi,id:node.id) }
                            if node.kind == .ab { ABInspector(workspace:workspace,midi:midi,id:node.id) }
                        }
                        ModulationInspector(workspace:workspace,renderer:renderer,id:node.id)
                        if node.kind == .chromaEncoder {
                            Text("Sends both color components on the selected left or right audio channel. Scarlett Send maps that channel to a physical output. Frame Reference preserves full-resolution detail and frame timing. Higher color resolutions reduce the achievable frame rate; the node status shows the actual rate.").font(.editorItem).foregroundStyle(.secondary)
                        }
                        if node.kind == .chromaDecoder {
                            Text("Connect returned audio and the encoder’s Frame Reference. Frame lock pairs returned color with its original frame. Live color always draws the received signal over the latest picture; adjust live gain, scan phase and hue to explore the result. Use View to compare with the original.").font(.editorItem).foregroundStyle(.secondary)
                        }
                        if node.kind == .dither { DitherInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .projectionDots || node.kind.outputType == .dots { ProjectionDotsInspector(workspace:workspace,id:node.id) }
                        if node.kind == .flashFaces || node.kind == .graphInkFlow || node.kind == .graphParticles || node.kind == .graphPulse || node.kind == .graphCloudParticles || node.kind == .graphClouds { CollectionPaletteInspector(workspace:workspace,id:node.id) }
                        if node.kind == .palette { ColorPaletteInspector(workspace:workspace,id:node.id) }
                        if node.kind == .powerGlitch { PowerGlitchInspector(workspace:workspace,id:node.id) }
                        if node.kind == .triangulateFaces {
                            ForEach(["start_face","end_face"],id:\.self) { key in
                                TextField(key == "start_face" ? "Start face ID":"End face ID",text:Binding(get:{ node.mappedFaceIDs?[key] ?? "" },set:{ value in
                                    workspace.edit("Set Face ID") { graph in
                                        guard let index=graph.nodes.firstIndex(where:{ $0.id == node.id }) else {return}
                                        var ids=graph.nodes[index].mappedFaceIDs ?? [:]
                                        ids[key]=value.isEmpty ? nil:value;graph.nodes[index].mappedFaceIDs=ids
                                    }
                                }))
                            }
                        }
                        if node.kind == .glowFaces { GlowFacesInspector(workspace:workspace,id:node.id) }
                        if node.kind == .lightningPulses { TraceInspector(workspace:workspace,id:node.id) }
                        if node.kind == .paletteAdjust { PaletteAdjustInspector(workspace:workspace,id:node.id) }
                        if (node.kind.outputTypes.contains(.palette) || node.kind == .publishPalette || node.kind == .syphon) { PaletteOutputInspector(renderer:renderer,id:node.id) }
                        if node.kind == .meshGradient { MeshGradientInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .ledMatrix { LEDMatrixInspector(workspace:workspace,id:node.id) }
                        if node.kind == .pictureInPicture { PictureInPictureInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .channelSplit { ChannelSplitInspector(workspace:workspace,id:node.id) }
                        if node.kind == .channelColors { ChannelColorsInspector(workspace:workspace,id:node.id) }
                        if node.kind == .crop { CropInspector(workspace:workspace,renderer:renderer,id:node.id) }
                        if node.kind == .poseRender { PoseInspector(workspace:workspace,id:node.id) }
                        if node.hasLiquidMetalControls { LiquidMetalInspector(workspace:workspace,id:node.id,renderer:renderer) }
                        if node.hasLiquidChromeControls { LiquidChromeInspector(workspace:workspace,id:node.id) }
                        if node.isBlinds { BlindsInspector(workspace:workspace,id:node.id) }
                        if node.kind != .audioPlugin && node.kind != .projector && node.kind != .powerGlitch && node.kind != .glowFaces && node.kind != .lightningPulses && node.kind != .paletteAdjust && node.kind != .meshGradient && node.kind != .ab && node.kind != .mux && node.kind != .layerMux && !node.isBlinds && !node.hasLiquidSculptureControls && node.kind.outputType != .dots && node.kind != .projectionDots && node.kind != .dither && node.kind != .poseRender && node.kind != .crop && node.kind != .channelSplit && node.kind != .channelColors && node.kind != .pictureInPicture && node.kind != .ledMatrix && !node.parameterSpecs.isEmpty {
                            VStack(alignment:.leading,spacing:16) {
                                HStack { sectionLabel("PARAMETERS"); Spacer(); Button("Reset") { workspace.beginGesture(); for p in node.parameterSpecs { workspace.parameter(node.id,p.key,p.initial) }; workspace.endGesture("Reset Parameters") }.buttonStyle(.plain).font(.editorCaption).foregroundStyle(.secondary) }
                                ForEach(node.parameterSpecs.filter { p in if node.kind == .fieldShader || node.fieldParameters != nil { return true }; return !(node.kind == .palette && ["seed","scheme"].contains(p.key)) && !(node.hasMetallicPoolControls && p.key == "blend" && node.value("function") < 4) && node.kind != .metroSequencer && !["playing","seek","channelX","channelY"].contains(p.key) && !(node.kind == .voltageVisualizer && ["historyMS","cycles","rate"].contains(p.key)) && !(node.kind == .midiOut && p.key == "channel") && !(node.kind == .cellularField && node.value("rule").rounded() != 4 && ["states","threshold"].contains(p.key)) && !(node.kind == .streakGlow && !StreakGlowStyle.shows(p.key,function:Int(node.value("function")))) && !(node.kind == .audioVisualizer && ((p.key == "bars" && Int(node.value("mode")) != 4) || (p.key == "ridges" && Int(node.value("mode")) != 5))) && !(node.kind == .graphInkFlow && ((node.value("markStyle")>=0.5 && ["glow","trail"].contains(p.key)) || (node.value("markStyle")<1.5 && ["glassFrost","glassRefraction"].contains(p.key)))) && !((node.kind == .flashFaces || node.kind == .graphInkFlow || node.kind == .graphParticles || node.kind == .graphPulse || node.kind == .graphCloudParticles || node.kind == .graphClouds) && CollectionStyle.colorParameters.contains { $0.key == p.key }) },id:\.key) { p in
                                    if node.kind == .video && (p.key == "start" || p.key == "end") {
                                        HStack { Text(p.title); Spacer(); TextField("Seconds",value:Binding(get:{ self.node?.value(p.key) ?? 0 },set:{ workspace.parameter(node.id,p.key,$0) }),format:.number.precision(.fractionLength(3))).textFieldStyle(.squareBorder).frame(width:85) }.midiParameter(workspace:workspace,id:node.id,key:p.key)
                                    } else if let choices = p.choices {
                                        Picker(p.title,selection:Binding(get:{ Int(self.node?.value(p.key) ?? p.initial) },set:{ workspace.parameter(node.id,p.key,Double($0)) })) {
                                            ForEach(Array(choices.enumerated()),id:\.offset) { i,title in Text(title).tag(i) }
                                        }.midiParameter(workspace:workspace,id:node.id,key:p.key)
                                    } else if node.kind.isAudioNode && ["balance","pan"].contains(p.key) {
                                        VStack(spacing:5) {
                                            HStack {
                                                Text(p.key == "balance" ? "Balance" : "Pan")
                                                Spacer()
                                                let amount = self.node?.value(p.key) ?? 0
                                                Text(amount == 0 ? "Center" : String(format:"%.0f%% %@",abs(amount)*100,amount < 0 ? "Left" : "Right"))
                                                    .font(.editorValue).foregroundStyle(.secondary)
                                                Button("Center") { workspace.parameter(node.id,p.key,0) }
                                                    .buttonStyle(.bordered).controlSize(.mini)
                                            }
                                            ParameterControl(value:Binding(get:{ self.node?.value(p.key) ?? 0 },set:{ workspace.parameter(node.id,p.key,$0) }),in:-1...1,centeredBalance:true,spec:p,colorHue:self.node?.value("hue") ?? 0,onEditingChanged:{ editing in
                                                if editing { workspace.beginGesture() } else { workspace.endGesture("Change balance") }
                                            }).tint(Color(nsColor:.patchAccent))
                                        }.midiParameter(workspace:workspace,id:node.id,key:p.key)
                                    } else if p.step != nil {
                                        HStack {
                                            Text(p.title)
                                            ParameterControl(value:Binding(get:{ self.node?.value(p.key) ?? p.initial },set:{ workspace.parameter(node.id,p.key,$0) }),in:p.min...p.max,step:p.step,spec:p,colorHue:self.node?.value("hue") ?? 0,onEditingChanged:{ editing in
                                                if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(p.title)") }
                                            }).controlSize(.small)
                                        }.midiParameter(workspace:workspace,id:node.id,key:p.key)
                                    } else {
                                        VStack(spacing:5) {
                                            HStack {
                                                Text(p.title); Spacer()
                                                TextField(p.title,value:Binding(get:{ self.node?.value(p.key) ?? p.initial },set:{ value in
                                                    if value.isFinite { workspace.parameter(node.id,p.key,min(p.max,max(p.min,p.step.map { $0>0 ? (value/$0).rounded()*$0:value } ?? value))) }
                                                }),format:.number.precision(.fractionLength(0...3)))
                                                    .textFieldStyle(.squareBorder).frame(width:72).font(.editorValue)
                                                    .help("Enter an exact value")
                                                if node.kind.isAudioNode && p.min <= 0 && p.max >= 0 {
                                                    Button(["balance","pan"].contains(p.key) ? "Center" : "0") { workspace.parameter(node.id,p.key,0) }
                                                        .buttonStyle(.bordered).controlSize(.mini)
                                                        .help("Reset to zero")
                                                }
                                            }
                                            ParameterControl(value:Binding(get:{ self.node?.value(p.key) ?? p.initial },set:{ value in workspace.parameter(node.id,p.key,min(p.max,max(p.min,p.step.map { $0>0 ? (value/$0).rounded()*$0:value } ?? value))) }),in:p.min...p.max,step:p.step,hasNeutralZero:true,showsValueField:false,centeredBalance:node.kind.isAudioNode && ["balance","pan"].contains(p.key),spec:p,colorHue:self.node?.value("hue") ?? 0,onEditingChanged:{ editing in if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(p.title)") } }).tint(Color(nsColor:.patchAccent)).controlSize(.small)
                                        }.midiParameter(workspace:workspace,id:node.id,key:p.key)
                                    }
                                }
                            }
                        }
                        if node.kind.isOutput && !isLibraryPreview {
                            VStack(alignment:.leading,spacing:8) {
                                sectionLabel("OUTPUT")
                                Text(renderer.status[node.id] ?? "Waiting for frame").foregroundStyle(.secondary)
                                if node.kind == .window || node.kind == .projector { Button("Open Output") { workspace.update(node.id) { $0.enabled = true }; workspace.onOpenOutput?(node.id) } }
                                else if node.kind == .record || node.kind == .recordAudio {
                                    let info = renderer.recordingInfo(node.id)
                                    let noun = node.kind == .record ? "Movie" : "Audio"
                                    Button(info?.phase == "recording" ? "Stop Recording" : (info?.phase == "ready" ? "Save \(noun)…" : "Record")) { workspace.onRecord?(node.id) }.disabled(info?.phase == "finishing")
                                    if info?.phase == "ready" || info?.phase == "saved" {
                                        Button("Save \(noun) As…") { workspace.onSaveRecording?(node.id) }
                                    }
                                    if info?.phase == "ready" || info?.phase == "failed" {
                                        Button("Discard Take",role:.destructive) { workspace.onDiscardRecording?(node.id) }
                                            .help("Delete this unsaved take and return to Ready to record.")
                                    }
                                    Text(node.kind == .record ? "H.264 + AAC · MOV · connect audio before recording" : AudioRecording.Options(node).summary(rate:nil) + (AudioRecording.Options(node).format.lossless ? " · lossless" : "") + " · settings apply to the next take").font(.editorCaption).foregroundStyle(.secondary)
                                }
                                else if node.kind == .audioOutput { Text("Stereo audio · selected device channels").foregroundStyle(.secondary) }
                                else { Text("Stream name: \(node.name)").foregroundStyle(.secondary) }
                            }
                        }
                        Divider()
                        HStack {
                            Text(node.kind.outputTypes.map(\.rawValue).joined(separator:" · ")).font(.editorItem).foregroundStyle(.secondary)

                            Spacer()
                            if !isLibraryPreview { Button { workspace.selected = node.id; workspace.deleteSelection() } label: { Image(systemName:"trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete node") }
                        }
                    } else if let id = workspace.selected, let group = workspace.graph.component(id) {
                        sectionLabel(group.interface == nil ? "COMPONENT" : "SUBPATCH")
                        TextField("Name",text:Binding(get:{ workspace.graph.component(id)?.name ?? "" },set:{ value in workspace.edit("Rename Component") { g in if let i = g.components?.firstIndex(where:{ $0.id == id }) { g.components![i].name = value } } })).textFieldStyle(.squareBorder)
                        Text("\(group.members.count) nodes")
                        Button(group.collapsed ? "Expand Component" : "Collapse Component") { workspace.toggleComponent(id) }
                        if group.interface != nil { SubpatchInspector(workspace:workspace,group:group) }
                        else { Button("Extract Subpatch") { workspace.extractSubpatch() } }
                        Button("Ungroup") { workspace.ungroup(id) }
                    } else {
                        sectionLabel("PATCH")
                        Text("\(workspace.graph.nodes.count) nodes · \(workspace.graph.edges.count) connections").foregroundStyle(.secondary)
                        Divider()
                        shortcut("Add node", "⌘F")
                        shortcut("Preview node", "Space")
                        shortcut("Frame graph", "F")
                        shortcut("Import media", "⌘I")
                        shortcut("Duplicate", "⌘D")
                        shortcut("Parameters", "Double-click")
                        shortcut("Disconnect input", "⌥Click port")
                        shortcut("Pan", "Scroll / drag")
                        shortcut("Zoom", "Pinch / ⌘Scroll")
                    }
                }.font(.editorBody).padding(16).frame(maxWidth:.infinity,alignment:.leading)
            }
            Spacer(minLength:0)
        }.background(Color(nsColor:.patchPanel)).preferredColorScheme(.dark)
    }
    func rotate(_ node: Node, _ amount: Double) {
        var angle = node.value("rotation") + amount
        if angle > 180 { angle -= 360 }; if angle < -180 { angle += 360 }
        workspace.parameter(node.id,"rotation",angle)
    }
    func sectionLabel(_ title: String) -> some View { Text(title).font(.editorHeading).foregroundStyle(.secondary) }
    func shortcut(_ label: String,_ key: String) -> some View { HStack { Text(label); Spacer(); Text(key).foregroundStyle(.secondary) } }
}

struct FaceCoordinateReadout: View {
    let renderer: Renderer
    let id: UUID
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.1)) { _ in
            VStack(alignment:.leading,spacing:6) {
                Text("FACE COORDINATES").fontWeight(.semibold)
                Text("Normalized 0–1 · origin top-left").foregroundStyle(.secondary)
                if let frame = renderer.faceFrame(id) {
                    ForEach(Array(frame.faces.enumerated()),id:\.offset) { index,face in
                        let b = face.bounds
                        Text(String(format:"Face %d  x %.3f  y %.3f\nw %.3f  h %.3f",index+1,b.x,b.y,b.width,b.height))
                    }
                    if frame.faces.isEmpty { Text("No faces").foregroundStyle(.secondary) }
                } else { Text("Waiting for coordinates").foregroundStyle(.secondary) }
            }.font(.editorCaption.monospacedDigit()).textSelection(.enabled)
        }
    }
}
