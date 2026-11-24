import SwiftUI
import UniformTypeIdentifiers
import PatchCore

struct AudioPluginInspector: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var plugins: AudioPlugins
    init(workspace: Workspace, id: UUID) { self.workspace=workspace; self.id=id; self.plugins=workspace.plugins }
    let id: UUID
    @State private var showAll=false
    @State private var available=AudioPlugins.installed
    private var node: Node? { workspace.graph.node(id) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("VST3 plugin",selection:Binding(get:{ node?.file ?? "" },set:{ if !$0.isEmpty { plugins.choose(id,path:$0) } })) {
                Text("Choose an effect…").tag("")
                ForEach(available,id:\.path) { url in Text(url.deletingPathExtension().lastPathComponent).tag(url.path) }
                if let path=node?.file,!available.contains(where:{ $0.path==path }) { Text(URL(fileURLWithPath:path).lastPathComponent).tag(path) }
            }
            HStack {
                Button("Browse…") {
                    let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.canChooseFiles=true
                    panel.allowedContentTypes=[UTType(filenameExtension:"vst3") ?? .bundle]
                    panel.treatsFilePackagesAsDirectories=false
                    if panel.runModal() == .OK,let url=panel.url { plugins.choose(id,path:url.path) }
                }
                Button("Refresh") { available=AudioPlugins.installed }
                Spacer()
                Button("Open Editor") { plugins.openEditor(id) }.disabled(node?.plugin == nil)
            }
            if let error=plugins.errors[id] {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Button("Retry Plugin") { plugins.retry(id) }
            }
            if let configuration=node?.plugin {
                Text("\(configuration.manufacturer) · Stereo VST3 effect").font(.caption).foregroundStyle(.secondary)
                let all=configuration.parameters
                let basic=all.filter { p in
                    let name=p.name.lowercased().replacingOccurrences(of:" ",with:"")
                    return ["mix","wet","dry/wet","decay","predelay","size","lowcut","highcut","mode","color","colormode","reverbmode"].contains(name)
                }
                let visible=showAll ? all:Array((basic.isEmpty ? all:basic).prefix(10))
                ForEach(visible,id:\.key) { parameter in parameterRow(parameter) }
                if all.count>visible.count || showAll {
                    Toggle("Show all \(all.count) parameters",isOn:$showAll).toggleStyle(.checkbox)
                }
                Text("Double-click the node to open the plugin’s own editor. Settings are included when you save the patch.")
                    .font(.caption).foregroundStyle(.secondary)
                if let latency=plugins.instance(id)?.latency,latency>0 {
                    Text("Plugin latency: \(latency) samples. Parallel audio branches are not delay-compensated.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Connect Audio Input → VST3 Effect → Audio Output. Missing or unavailable effects pass dry audio through.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private func parameterRow(_ parameter: AudioPluginParameter) -> some View {
        let spec=parameter.spec
        let binding=Binding<Double>(get:{ node?.value(parameter.key) ?? spec.initial },set:{ workspace.parameter(id,parameter.key,$0) })
        VStack(alignment:.leading,spacing:4) {
            if let choices=spec.choices {
                Picker(parameter.name,selection:Binding(get:{ Int(binding.wrappedValue.rounded()) },set:{ binding.wrappedValue=Double($0) })) {
                    ForEach(Array(choices.enumerated()),id:\.offset) { index,name in Text(name).tag(index) }
                }
            } else if parameter.bipolar {
                HStack {
                    Text(parameter.name)
                    Spacer()
                    TextField(parameter.name,text:Binding(get:{ plugins.instance(id)?.texts[parameter.key] ?? "0" },set:{ plugins.setText(id,parameter:parameter,text:$0) }))
                        .textFieldStyle(.squareBorder).frame(width:90)
                    Button("0") { plugins.setText(id,parameter:parameter,text:"0") }.help("Set exactly zero")
                }
            } else {
                HStack {
                    Text(parameter.name)
                    Spacer()
                    Text(plugins.instance(id)?.texts[parameter.key] ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                HStack {
                    ParameterControl(value:binding,in:spec.min...spec.max,step:spec.step,spec:spec,onEditingChanged:{ editing in
                        if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(parameter.name)") }
                    })
                    if spec.step == nil {
                        TextField("Normalized value",value:binding,format:.number.precision(.fractionLength(0...4)))
                            .frame(width:64).textFieldStyle(.squareBorder).help("Exact normalized value, 0–1")
                    }
                    Button("Reset") { binding.wrappedValue=spec.initial }.controlSize(.mini)
                }
            }
        }.midiParameter(workspace:workspace,id:id,key:parameter.key)
    }
}
