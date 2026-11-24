import SwiftUI
import PatchCore

/// Apply this once to any custom parameter row. Numeric eligibility, range and
/// stepping come from ParameterSpec; learning never invokes the row's normal action.
struct MIDIParameterModifier: ViewModifier {
    @ObservedObject var workspace: Workspace
    let id: UUID
    let key: String
    @ViewBuilder func body(content: Content) -> some View {
        if let midi = workspace.midi,workspace.graph.node(id)?.midiParameters.contains(where:{ $0.key == key }) == true {
            MIDITargetView(midi:midi,workspace:workspace,id:id,key:key,content:content)
        } else { content }
    }
}
private struct MIDITargetView<Content: View>: View {
    @ObservedObject var midi: MIDIController
    @ObservedObject var workspace: Workspace
    let id: UUID
    let key: String
    let content: Content
    var binding: MIDIMapping? { midi.mapping(id,key) }
    var armed: Bool { midi.target == MIDITarget(node:id,key:key) }
    var color: Color { armed ? .orange : binding == nil ? .cyan : .green }
    var body: some View {
        content.disabled(midi.learning)
            .overlay {
                if midi.learning {
                    Button { midi.arm(id,key) } label: {
                        RoundedRectangle(cornerRadius:4).fill(color.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius:4).stroke(color,lineWidth:armed ? 2 : 1))
                    }.buttonStyle(.plain).accessibilityLabel("Learn MIDI: \(key)")
                }
            }
            .overlay(alignment:.topTrailing) {
                if let binding,!midi.learning {
                    Text("CC \(binding.cc)").font(.system(size:8,design:.monospaced)).padding(2)
                        .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:3)).offset(y:-10).allowsHitTesting(false)
                }
            }
    }
}
extension View {
    func midiParameter(workspace: Workspace,id: UUID,key: String) -> some View {
        modifier(MIDIParameterModifier(workspace:workspace,id:id,key:key))
    }
}

struct MIDIInspector: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var midi: MIDIController
    let id: UUID?
    @State private var allControls = false
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Toggle("MIDI Learn",isOn:Binding(get:{ midi.learning },set:{ midi.setLearning($0) })).toggleStyle(.button)
                Spacer()
                Text(midi.connected?.name ?? midi.status).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if midi.learning {
                Text(midi.target == nil ? "Select a parameter · ⌘M / Esc" : "Move a knob or fader · Esc")
                    .font(.system(size:10,design:.monospaced)).foregroundStyle(midi.target == nil ? Color.secondary : .orange)
                if let id,let node = workspace.graph.node(id) {
                    DisclosureGroup("All assignable parameters",isExpanded:$allControls) {
                        // This metadata-driven list also covers collapsed sections and
                        // custom controls; new ParameterSpecs are available immediately.
                        ForEach(node.midiParameters,id:\.key) { spec in
                            HStack { Text(spec.title); Spacer(); Text((node.value(spec.key) * (node.hasBlindsControls && spec.key == "p1" ? 10 : 1)).formatted(.number.precision(.fractionLength(0...2)))) }
                                .font(.system(size:11)).padding(6)
                                .midiParameter(workspace:workspace,id:id,key:spec.key)
                        }
                    }
                }
                if !midi.lastMessage.isEmpty { Text(midi.lastMessage).font(.system(size:10)).foregroundStyle(.secondary) }
            }
        }
    }
}

struct ABInspector: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var midi: MIDIController
    let id: UUID
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Button("A") { manual(0) }
                ParameterControl(value:Binding(get:{ workspace.graph.node(id)?.value("mix") ?? 0 },set:manual),in:0...1)
                Button("B") { manual(1) }
            }.midiParameter(workspace:workspace,id:id,key:"mix")
            Picker("Transition",selection:Binding(get:{ Int(workspace.graph.node(id)?.value("mode") ?? 0) },set:{ workspace.parameter(id,"mode",Double($0)) })) {
                Text("Crossfade").tag(0); Text("Cut").tag(1)
            }.pickerStyle(.menu)
            Toggle("Follow APC",isOn:Binding(get:{ midi.followNode == id },set:{ enabled in
                do { try midi.setFollow(id,enabled:enabled) } catch { workspace.message = error.localizedDescription }
            })).toggleStyle(.switch)
            .help("Assign the APC crossfader exclusively to this A/B node, in every VJ tab.")
            Text(midi.followNode == id ? (midi.faderPosition == nil ? "Move fader once" : "Following globally · CC 15") : "Manual")
                .font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
        }
    }
    func manual(_ value: Double) { workspace.parameter(id,"mix",value) }
}

struct MIDISettings: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var midi: MIDIController
    @State private var search = ""
    var mappings: [MIDIMapping] {
        (workspace.graph.midiMappings ?? []).filter { binding in
            search.isEmpty || (workspace.graph.node(binding.node)?.name ?? "Missing node").localizedCaseInsensitiveContains(search) || binding.key.localizedCaseInsensitiveContains(search) || String(binding.cc).contains(search)
        }
    }
    var body: some View {
        TabView {
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Picker("Input",selection:Binding(get:{ midi.selection },set:{ midi.select($0) })) {
                        Text("Auto · APC40 mkII").tag("auto"); Text("Off").tag("off")
                        ForEach(midi.devices) { device in Text(device.name).tag(device.id) }
                    }.frame(maxWidth:350)
                    Text(midi.status).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reconnect") { midi.select(midi.selection == "off" ? "auto" : midi.selection) }
                }
                HStack {
                    TextField("Filter mappings",text:$search).textFieldStyle(.roundedBorder)
                    Button(midi.learning ? "Done Learning" : "Learn · ⌘M") { midi.toggleLearn() }
                    Button("Clear All") { workspace.edit("Clear MIDI Mappings") { $0.midiMappings = nil } }.disabled((workspace.graph.midiMappings ?? []).isEmpty)
                }
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:12) {
                        ForEach(mappings) { binding in MIDISettingsRow(workspace:workspace,midi:midi,id:binding.id) }
                    }
                }
                if mappings.isEmpty { Text("No mappings").foregroundStyle(.secondary) }
                if !midi.lastMessage.isEmpty { Text(midi.lastMessage).font(.system(size:11)).foregroundStyle(.secondary) }
            }.padding(20).tabItem { Text("MIDI") }
        }.frame(minWidth:760,minHeight:400)
    }
}
private struct MIDISettingsRow: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var midi: MIDIController
    let id: UUID
    var mapping: MIDIMapping? { workspace.graph.midiMappings?.first { $0.id == id } }
    func change(_ edit: (inout MIDIMapping)->Void) {
        workspace.edit("Edit MIDI Mapping") { graph in
            if let index = graph.midiMappings?.firstIndex(where:{ $0.id == id }) { edit(&graph.midiMappings![index]) }
        }
    }
    var body: some View {
        if let binding = mapping {
            let node = workspace.graph.node(binding.node)
            let spec = node?.midiParameters.first { $0.key == binding.key }
            let displayScale = node?.hasBlindsControls == true && binding.key == "p1" ? 10.0 : 1.0
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Toggle("",isOn:Binding(get:{ mapping?.enabled ?? false },set:{ enabled in change { $0.enabled = enabled } })).labelsHidden()
                    Text(node?.name ?? "Missing node").fontWeight(.medium)
                    Text("→ \(spec?.title ?? binding.key)")
                    Spacer()
                    Text("Ch \(binding.channel+1) · CC \(binding.cc)").font(.system(size:11,design:.monospaced))
                    Text(midi.mappingStatus(binding)).font(.system(size:10)).foregroundStyle(.secondary)
                    Button("Relearn") { workspace.selected = binding.node; midi.arm(binding.node,binding.key) }.disabled(spec == nil)
                    Button("Remove") { workspace.edit("Remove MIDI Mapping") { $0.midiMappings?.removeAll { $0.id == id } } }
                }
                HStack {
                    Text("Range")
                    TextField("Minimum",value:Binding(get:{ (mapping?.minimum ?? 0)*displayScale },set:{ displayValue in
                        let value = displayValue/displayScale
                        guard value.isFinite,let spec else { return }
                        change { $0.minimum = min($0.maximum,max(spec.min,value)) }
                    }),format:.number.precision(.fractionLength(0...3))).frame(width:80)
                    Text("–")
                    TextField("Maximum",value:Binding(get:{ (mapping?.maximum ?? 1)*displayScale },set:{ displayValue in
                        let value = displayValue/displayScale
                        guard value.isFinite,let spec else { return }
                        change { $0.maximum = max($0.minimum,min(spec.max,value)) }
                    }),format:.number.precision(.fractionLength(0...3))).frame(width:80)
                    Toggle("Invert",isOn:Binding(get:{ mapping?.inverted ?? false },set:{ value in change { $0.inverted = value } }))
                    Picker("Response",selection:Binding(get:{ mapping?.pickup ?? true },set:{ value in change { $0.pickup = value } })) {
                        Text("Pickup").tag(true); Text("Jump").tag(false)
                    }.frame(width:170)
                    Spacer()
                }.textFieldStyle(.roundedBorder).controlSize(.small)
            }.padding(10).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:6))
        }
    }
}

struct MUXInspector: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var midi: MIDIController
    let id: UUID
    var follows: Bool { workspace.graph.node(id)?.value("followAPC") == 1 }
    func level(_ key: String) -> Double {
        guard let node = workspace.graph.node(id) else { return 0 }
        if let binding = node.modulations?[key], binding.enabled,
           let source = workspace.graph.node(binding.source), source.kind == .apc40, source.enabled,
           let value = midi.apcState.snapshot[binding.outputIndex] {
            return binding.minimum + (binding.maximum-binding.minimum)*value
        }
        return node.value(key)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Stepper("Channels: \(workspace.graph.node(id)?.channelCount ?? 8)",value:Binding(get:{ workspace.graph.node(id)?.channelCount ?? 8 },set:{ workspace.parameter(id,"channels",Double($0)) }),in:1...8)
            Toggle("Follow APC",isOn:Binding(get:{ follows },set:{ workspace.parameter(id,"followAPC",$0 ? 1 : 0) })).toggleStyle(.switch).disabled(midi.ownsAPC)
            Text(midi.ownsAPC ? "APC40 node · Connect controls in the graph" : follows ? (midi.channelFaders.contains(where:{ $0 != nil }) ? "APC · Channels 1–8" : "APC · Waiting for faders") : "Manual")
                .font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
            ForEach(0..<(workspace.graph.node(id)?.channelCount ?? 8),id:\.self) { channel in
                let key = "level\(channel+1)"
                let edge = workspace.graph.edges.first { $0.target == id && $0.input == channel }
                VStack(spacing:4) {
                    HStack {
                        Text("\(channel+1)").foregroundStyle(.secondary).frame(width:14)
                        Text(edge.flatMap { workspace.graph.node($0.source)?.name } ?? "Not connected").lineLimit(1)
                        Spacer()
                        Text("\(Int(level(key)*100))%").monospacedDigit().foregroundStyle(.secondary)
                        if edge != nil { Button { workspace.edit("Disconnect") { $0.edges.removeAll { $0.target == id && $0.input == channel } } } label: { Image(systemName:"xmark").font(.system(size:8)) }.buttonStyle(.plain).accessibilityLabel("Disconnect channel \(channel+1)") }
                    }.font(.system(size:11))
                    if workspace.graph.node(id)?.kind == .mux || edge.flatMap({ workspace.graph.node($0.source)?.kind.outputType(at:$0.outputIndex) }) == .video {
                    Picker("Mode",selection:Binding(get:{ Int(workspace.graph.node(id)?.value("mode\(channel+1)") ?? 0) },set:{ workspace.parameter(id,"mode\(channel+1)",Double($0)) })) {
                        Text("Mix").tag(0);Text("Mask").tag(1)
                    }.controlSize(.small).midiParameter(workspace:workspace,id:id,key:"mode\(channel+1)")
                    }
                    ParameterControl(value:Binding(get:{ level(key) },set:{ workspace.parameter(id,key,$0) }),in:0...1,onEditingChanged:{ editing in
                        if editing { workspace.beginGesture() } else { workspace.endGesture("MUX Level") }
                    }).disabled((follows && !midi.ownsAPC) || workspace.graph.node(id)?.modulations?[key]?.enabled == true).midiParameter(workspace:workspace,id:id,key:key)
                }
            }
        }
    }
}
