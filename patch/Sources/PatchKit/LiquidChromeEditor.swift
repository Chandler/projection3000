import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PatchCore

/// The sidebar only launches the editor; all shaping happens in one window.
struct LiquidChromeInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Button("Reset") { workspace.update(id,action:"Reset Liquid Chrome") { LiquidChromeStyle.reset(&$0) } }
        }
    }
}

struct LiquidChromeEditor: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @State private var exportError: String?
    @State private var showMore = false
    private var node: Node? { workspace.graph.node(id) }
    private var method: LiquidChromeStyle.Method { node.map(LiquidChromeStyle.method) ?? .pour }
    // One line on how each method generates the liquid.
    private let summaries: [LiquidChromeStyle.Method:String] = [
        .pour:"Poured along a network, then phase separation opens it into lace. Flat poster view.",
        .balloon:"The same pour, fully inflated into a closed chrome volume in 3D.",
        .sheet:"A torn liquid film, twisted through space with rims rolled thick.",
        .coral:"Reaction–diffusion grows tubes, worms or spots inside the shape.",
        .swarm:"Thousands of cohesive liquid particles settle under gravity.",
        .ferrofluid:"A magnetized pool rising into a lattice of rounded spikes."
    ]
    // Same keys, named for what they do in each method; nil hides a control.
    private func title(_ key: String) -> String? {
        switch (method,key) {
        case (.sheet,"nodes"),(.sheet,"pool"),(.sheet,"drips"),(.sheet,"dripLength"): return nil
        case (.sheet,"holes"): return "Tears"
        case (.sheet,"threads"): return "Rim thickness"
        case (.sheet,"puff"): return "Wave depth"
        case (.coral,"holes"): return "Pattern · spots → worms"
        case (.swarm,"nodes"): return "Particles"
        case (.swarm,"holes"),(.swarm,"pool"),(.swarm,"threads"): return nil
        case (.swarm,"viscosity"): return "Cohesion"
        case (.swarm,"drips"): return "Gravity"
        case (.swarm,"dripLength"): return "Fall"
        case (.ferrofluid,"holes"): return "Spike density"
        case (.ferrofluid,"dripLength"): return "Spike height"
        case (.ferrofluid,"threads"): return "Spike sharpness"
        case (.ferrofluid,"drips"): return nil
        case (.balloon,"puff"): return "Inflation"
        default: return spec(key)?.title
        }
    }
    private var sections: [(String,String,[String])] {
        var result: [(String,String,[String])] = [
            ("FORM","Where the liquid starts.",["nodes","holes","pool","spread"]),
            ("LIQUID","How it flows and settles.",["viscosity","threads","puff","drips","dripLength"]),
            ("LIGHT","Dark studio, hard lights, connected video.",["hardness","edge","warmth","glow","sparkle","exposure","reflection"])
        ]
        if method.isVolumetric { result.append(("CAMERA","Orbit the 3D form.",["tilt","turn"])) }
        return result
    }
    var body: some View {
        NodeAppLayout(sidebarWidth:340,footer:exportError) { toolbar } canvas: {
            MetalPreview(renderer:renderer,id:id).frame(minWidth:520).background(Color.black)
        } sidebar: {
            methodPicker
            ForEach(sections,id:\.0) { section in
                NodeAppSection(title:section.0,caption:section.1) {
                    ForEach(section.2.filter { title($0) != nil },id:\.self) { NodeAppParameter(workspace:workspace,id:id,key:$0,title:title($0)) }
                }
            }
            DisclosureGroup("More",isExpanded:$showMore) {
                VStack(alignment:.leading,spacing:12) { NodeAppParameter(workspace:workspace,id:id,key:"motion") }.padding(.top,8)
            }.font(.system(size:12,weight:.medium))
        }
    }
    private var toolbar: some View {
        Group {
            Text(node?.name ?? "Liquid Chrome removed").font(.title2.weight(.semibold))
            Spacer()
            HStack(spacing:4) {
                Button { step(-1) } label: { Image(systemName:"chevron.left") }
                Text("Seed \(Int(node?.value("seed") ?? 0))").monospacedDigit().frame(minWidth:90)
                Button { step(1) } label: { Image(systemName:"chevron.right") }
            }.midiParameter(workspace:workspace,id:id,key:"seed")
            Button("New Variation") { setSeed(Double(Int.random(in:0...999999)),action:"New Liquid Variation") }
                .buttonStyle(.borderedProminent)
            choice("background",width:230)
            choice("quality",width:200)
            Button("Reset") { workspace.update(id,action:"Reset Liquid Chrome") { LiquidChromeStyle.reset(&$0) } }
            Button("Export PNG…") { export() }
        }
    }
    private var methodPicker: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("METHOD").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
            Picker("Method",selection:Binding(get:{method.rawValue},set:{ value in
                // Each method loads its tuned starting point; the seed is kept.
                workspace.update(id,action:"Change Liquid Method") { LiquidChromeStyle.applyMethod(&$0,LiquidChromeStyle.Method(rawValue:value) ?? .pour) }
            })) {
                ForEach(LiquidChromeStyle.methods.indices,id:\.self) { Text(LiquidChromeStyle.methods[$0]).tag($0) }
            }.labelsHidden()
            Text(summaries[method] ?? "").font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func spec(_ key: String) -> ParameterSpec? { LiquidChromeStyle.parameters.first { $0.key == key } }
    @ViewBuilder private func choice(_ key: String,width: CGFloat) -> some View {
        if let spec=spec(key),let choices=spec.choices {
            Picker(spec.title,selection:Binding(get:{Int(node?.value(key) ?? spec.initial)},set:{ value in
                workspace.beginGesture(); workspace.parameter(id,key,Double(value)); workspace.endGesture("Change \(spec.title)")
            })) {
                ForEach(choices.indices,id:\.self) { Text(choices[$0]).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width:width).help(spec.title)
        }
    }
    private func step(_ delta: Double) {
        let seed=(node?.value("seed") ?? 0)+delta
        setSeed(seed<0 ? 999999 : seed>999999 ? 0 : seed,action:"Change Seed")
    }
    private func setSeed(_ seed: Double,action: String) {
        workspace.update(id,action:action) { $0.parameters["seed"]=seed }
    }
    private func export() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.png];panel.nameFieldStringValue="Liquid Chrome.png"
        panel.begin { response in
            guard response == .OK,let url=panel.url else { return }
            do { try renderer.snapshot(id,to:url,fullResolution:true);exportError=nil } catch { exportError=error.localizedDescription }
        }
    }
}
