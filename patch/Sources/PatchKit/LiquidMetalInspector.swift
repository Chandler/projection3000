import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PatchCore

/// The sidebar is a launcher, not a second copy of the sculpture editor.
struct LiquidMetalInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    let renderer: Renderer
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Button("Reset Blob") { workspace.update(id,action:"Reset Blob") { LiquidMetalStyle.reset(&$0) } }
        }
    }
}

struct LiquidMetalEditor: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @State private var exportError: String?
    private var node: Node? { workspace.graph.node(id) }
    // Exactly ten parameters; no hidden advanced panel or per-ball control dump.
    private let keys=["family","seed","viscosity","complexity","holeSize","height","zoom","yaw","roughness","reflection"]
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text(node?.name ?? "Blob removed").font(.title2.weight(.semibold))
                Spacer()
                Button("New Variation") { vary() }
                Button("Reset Blob") { workspace.update(id,action:"Reset Blob") { LiquidMetalStyle.reset(&$0) } }
                Button("Export PNG…") { export() }
            }.padding(16)
            Divider()
            HStack(spacing:0) {
                MetalPreview(renderer:renderer,id:id).frame(minWidth:380,maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        ForEach(keys,id:\.self) { key in
                            if let spec=LiquidMetalStyle.parameters.first(where:{$0.key==key}) { control(spec) }
                        }
                    }.padding(18)
                }.frame(width:320)
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.orange).padding(8) }
        }.background(Color(nsColor:.patchPanel)).preferredColorScheme(.dark)
    }
    private func control(_ spec: ParameterSpec) -> some View {
        VStack(alignment:.leading,spacing:5) {
            if spec.key == "family" {
                Picker("Shape",selection:Binding(get:{Int(node?.value("family") ?? 3)},set:{ value in
                    workspace.beginGesture()
                    workspace.parameter(id,"construction",1)
                    workspace.parameter(id,"family",Double(value))
                    workspace.endGesture("Change Blob Shape")
                })) {
                    if let current=node, current.value("family")<3 { Text("Existing shape").tag(Int(current.value("family"))) }
                    Text("Liquid sculpture").tag(3)
                    Text("Splash").tag(4)
                }
            } else {
                Text(title(spec)).font(.system(size:12,weight:.medium))
                ParameterControl(value:Binding(get:{node?.value(spec.key) ?? spec.initial},set:{workspace.parameter(id,spec.key,$0)}),in:spec.min...spec.max,step:spec.step,spec:spec,onEditingChanged:{ editing in
                    if editing { workspace.beginGesture() } else { workspace.endGesture("Change \(spec.title)") }
                })
            }
        }.midiParameter(workspace:workspace,id:id,key:spec.key)
    }
    private func title(_ spec: ParameterSpec) -> String {
        ["viscosity":"Fullness","flow":"Flow","holeSize":"Tension","height":"Stretch","zoom":"Size","yaw":"Rotation °","reflection":"Photo / video reflection"][spec.key] ?? spec.title
    }
    private func vary() {
        workspace.update(id,action:"New Blob Variation") { node in
            if node.value("construction")<0.5 || node.value("family")<3 { LiquidMetalStyle.reset(&node) }
            node.parameters["seed"]=Double(Int.random(in:0...999999))
        }
    }
    private func export() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.png];panel.nameFieldStringValue="Liquid Metal.png"
        panel.begin { response in
            guard response == .OK,let url=panel.url else { return }
            do { try renderer.snapshot(id,to:url,fullResolution:true);exportError=nil } catch { exportError=error.localizedDescription }
        }
    }
}
