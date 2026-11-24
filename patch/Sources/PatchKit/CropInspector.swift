import SwiftUI
import PatchCore

struct CropInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @State private var gestureNode: Node?
    var node: Node? { workspace.graph.node(id) }
    var source: UUID? { workspace.graph.edges.first { $0.target == id && $0.input == 0 }?.source }
    var inputDimensions: VideoDimensions { workspace.graph.videoDimensions(source) }
    var outputDimensions: VideoDimensions { workspace.graph.videoDimensions(id) }
    var region: CropRegion { CropStyle.region(node ?? Node(kind:.crop),width:inputDimensions.width,height:inputDimensions.height) }
    func parameter(_ key: String,_ title: String,percent: Bool = false) -> some View {
        let spec = CropStyle.parameters.first { $0.key == key }!
        let factor = percent ? 100.0 : 1
        return VStack(spacing:4) {
            HStack {
                Text(title); Spacer()
                TextField(title,value:Binding<Double>(get:{ (node?.value(key) ?? spec.initial)*factor },set:{ value in
                    guard value.isFinite else { return }; workspace.parameter(id,key,min(spec.max,max(spec.min,value/factor)))
                }),format:.number.precision(.fractionLength(0...2))).textFieldStyle(.squareBorder).frame(width:62)
                if percent { Text("%").foregroundStyle(.secondary) }
            }
            ParameterControl(value:Binding(get:{ node?.value(key) ?? spec.initial },set:{ workspace.parameter(id,key,$0) }),in:spec.min...spec.max,step:spec.step,showsValueField:false,spec:spec,onEditingChanged:{ editing in
                if editing { workspace.beginGesture() } else { workspace.endGesture("Adjust Crop") }
            }).controlSize(.small).tint(Color(nsColor:.patchAccent))
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
    func gesture(_ translation: CGSize,size: CGSize,corner: Int? = nil) {
        guard let node else { return }
        if gestureNode == nil { gestureNode = node; workspace.beginGesture() }
        guard let original = gestureNode else { return }
        let r = CropStyle.region(original,width:inputDimensions.width,height:inputDimensions.height)
        let dx = translation.width/max(1,size.width), dy = translation.height/max(1,size.height)
        var w = r.width, h = r.height, cx = r.x+w/2, cy = r.y+h/2
        var changes: [String:Double] = [:]
        if let corner {
            let sx = corner%2 == 0 ? -1.0 : 1.0, sy = corner < 2 ? -1.0 : 1.0
            if Int(original.value("aspect")) == 1 {
                w = max(0.05,min(1,w+2*dx*sx)); h = max(0.05,min(1,h+2*dy*sy))
                changes = ["zoom":1,"width":w,"height":h]
            } else {
                let factor = max(0.05,max(1+2*dx*sx/w,1+2*dy*sy/h))
                let zoom = max(1,min(8,original.value("zoom")/factor))
                changes["zoom"] = zoom
                w *= original.value("zoom")/zoom; h *= original.value("zoom")/zoom
            }
        } else { cx += dx; cy += dy }
        changes["x"] = w < 0.999999 ? max(0,min(1,(cx-w/2)/(1-w))) : 0.5
        changes["y"] = h < 0.999999 ? max(0,min(1,(cy-h/2)/(1-h))) : 0.5
        workspace.edit("Adjust Crop") { graph in for (key,value) in changes { try graph.setParameter(id,key:key,value:value) } }
    }
    func finishGesture() { if gestureNode != nil { gestureNode = nil; workspace.endGesture("Adjust Crop") } }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("CROP / ASPECT").font(.editorHeading).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { workspace.edit("Reset Crop") { graph in for p in CropStyle.parameters { try graph.setParameter(id,key:p.key,value:p.initial) } } }.buttonStyle(.plain)
            }
            Picker("Aspect",selection:Binding(get:{ Int(node?.value("aspect") ?? 0) },set:{ workspace.parameter(id,"aspect",Double($0)) })) {
                ForEach(Array(CropStyle.aspects.enumerated()),id:\.offset) { index,title in Text(title).tag(index) }
            }
            HStack(spacing:6) {
                ForEach([4,2,3,7],id:\.self) { index in
                    Button { workspace.parameter(id,"aspect",Double(index)) } label: {
                        Text(CropStyle.aspects[index]).font(.editorItem.weight(.medium)).frame(maxWidth:.infinity).padding(.vertical,7)
                            .background((Int(node?.value("aspect") ?? 0) == index ? Color(nsColor:.patchAccent).opacity(0.25) : Color.white.opacity(0.04)),in:RoundedRectangle(cornerRadius:4))
                    }.buttonStyle(.plain)
                }
            }
            if Int(node?.value("aspect") ?? 0) == 9 {
                HStack { parameter("ratioWidth","W"); Text(":"); parameter("ratioHeight","H") }
            }
            GeometryReader { geometry in
                let r = region
                let crop = CGRect(x:r.x*geometry.size.width,y:r.y*geometry.size.height,width:r.width*geometry.size.width,height:r.height*geometry.size.height)
                ZStack(alignment:.topLeading) {
                    MetalPreview(renderer:renderer,id:source)
                    Path { path in path.addRect(CGRect(origin:.zero,size:geometry.size)); path.addRect(crop) }.fill(.black.opacity(0.6),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                    Rectangle().fill(.clear).contentShape(Rectangle()).frame(width:crop.width,height:crop.height).position(x:crop.midX,y:crop.midY)
                        .gesture(DragGesture(minimumDistance:0).onChanged { gesture($0.translation,size:geometry.size) }.onEnded { _ in finishGesture() })
                    Path { path in
                        path.addRect(crop)
                        for n in 1...2 {
                            let x = crop.minX+crop.width*Double(n)/3, y = crop.minY+crop.height*Double(n)/3
                            path.move(to:CGPoint(x:x,y:crop.minY)); path.addLine(to:CGPoint(x:x,y:crop.maxY))
                            path.move(to:CGPoint(x:crop.minX,y:y)); path.addLine(to:CGPoint(x:crop.maxX,y:y))
                        }
                    }.stroke(.white.opacity(gestureNode == nil ? 0.5 : 0.85),lineWidth:0.75).allowsHitTesting(false)
                    ForEach(0..<4,id:\.self) { corner in
                        RoundedRectangle(cornerRadius:2).fill(.white).frame(width:9,height:9)
                            .shadow(color:.black.opacity(0.8),radius:1)
                            .frame(width:24,height:24).contentShape(Rectangle())
                            .position(x:corner%2 == 0 ? crop.minX : crop.maxX,y:corner < 2 ? crop.minY : crop.maxY)
                            .gesture(DragGesture(minimumDistance:0).onChanged { gesture($0.translation,size:geometry.size,corner:corner) }.onEnded { _ in finishGesture() })
                            .accessibilityLabel("Resize crop corner \(corner+1)")
                    }
                    if source == nil { Text("Connect video to frame your crop").font(.system(size:10)).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
                }.background(.black).clipped()
            }.aspectRatio(inputDimensions.aspect,contentMode:.fit)
            HStack {
                Text("Drag to reframe · corners to resize").font(.system(size:9)).foregroundStyle(.secondary)
                Spacer(minLength:0)
                Button("Center") { workspace.edit("Center Crop") { graph in try graph.setParameter(id,key:"x",value:0.5); try graph.setParameter(id,key:"y",value:0.5) } }.buttonStyle(.plain).font(.system(size:10))
            }
            parameter("zoom","Zoom")
            DisclosureGroup("Position & Size") {
                VStack(spacing:12) {
                    parameter("x","Horizontal",percent:true); parameter("y","Vertical",percent:true)
                    if Int(node?.value("aspect") ?? 0) == 1 { parameter("width","Width",percent:true); parameter("height","Height",percent:true) }
                }.padding(.top,10)
            }
            Divider()
            Text("OUTPUT STREAM").font(.editorItem.weight(.medium)).foregroundStyle(.secondary)
            Picker("Resolution",selection:Binding(get:{ Int(node?.value("resolution") ?? 0) },set:{ workspace.parameter(id,"resolution",Double($0)) })) {
                Text("Match input long edge").tag(0)
                Text("HD · 720 short edge").tag(1)
                Text("Full HD · 1080 short edge").tag(2)
                Text("4K · 2160 short edge").tag(3)
                Text("Custom pixels").tag(4)
            }
            if node?.value("resolution") == 4 {
                parameter("outputWidth","Width · px"); parameter("outputHeight","Height · px")
            }
            Button("Portrait · 1080 × 1920") {
                workspace.edit("Portrait Output") { graph in
                    try graph.setParameter(id,key:"aspect",value:3)
                    try graph.setParameter(id,key:"resolution",value:2)
                }
            }
            Text("Output: \(outputDimensions.width) × \(outputDimensions.height)").font(.editorHeading.monospacedDigit())
            Text("Downstream effects and recording use this size. Changing dimensions ends an active recording.").font(.system(size:10)).foregroundStyle(.secondary)
            Text("OUTPUT FRAMING").font(.editorItem.weight(.medium)).foregroundStyle(.secondary)
            Picker("Output framing",selection:Binding(get:{ Int(node?.value("fit") ?? 0) },set:{ workspace.parameter(id,"fit",Double($0)) })) {
                Text("Fit").tag(0); Text("Fill").tag(1); Text("Stretch").tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            Text(["Keep the selected aspect with bars around it.","Fill the canvas by cropping further inside the selection.","Stretch the selection to the canvas."][Int(node?.value("fit") ?? 0)]).font(.system(size:10)).foregroundStyle(.secondary)
            if node?.value("fit") == 0 {
                Picker("Bars",selection:Binding(get:{ Int(node?.value("background") ?? 0) },set:{ workspace.parameter(id,"background",Double($0)) })) { Text("Black").tag(0); Text("White").tag(1) }
            }
            HStack {
                Toggle("Flip H",isOn:Binding(get:{ node?.value("flipX") == 1 },set:{ workspace.parameter(id,"flipX",$0 ? 1 : 0) }))
                Toggle("Flip V",isOn:Binding(get:{ node?.value("flipY") == 1 },set:{ workspace.parameter(id,"flipY",$0 ? 1 : 0) }))
            }.toggleStyle(.checkbox)

        }.onDisappear { finishGesture() }
    }
}
