import SwiftUI
import AppKit
import PatchCore

struct MeshGradientInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @State private var selected: Set<Int> = [0]
    @State private var tool = -1
    @State private var expanded = false
    @State private var drag: MeshDrag?
    @State private var stroke: [CGPoint] = []
    @State private var gestureActive = false
    @State private var editAnchors = false
    struct MeshDrag {
        var start: CGPoint
        var regions: [Int:Position]
        var handle: Int? = nil // 0..3 arms, 4 hardness
        var original: Node
    }
    var node: Node? { workspace.graph.node(id) }
    var count: Int { max(1,min(40,Int(value("count")))) }
    var point: Int { selected.sorted().first ?? 0 }
    var paletteSource: UUID? { workspace.graph.edges.first { $0.target == id && $0.input == 0 }?.source }
    var linkedPalette: ColorPalette? { paletteSource.flatMap { renderer.colorPalette($0) } }
    func value(_ key: String) -> Double { node.map { MeshGradientStyle.value($0,key) } ?? 0 }
    func binding(_ key: String,shape: Bool = false) -> Binding<Double> {
        Binding(get:{ value(key) },set:{ n in
            workspace.edit("Adjust Mesh Gradient") { graph in
                try graph.setParameter(id,key:key,value:n)
                if shape { try graph.setParameter(id,key:"fieldStyle",value:1) }
            }
        })
    }
    func editNode(_ action: String,_ fn: (inout Node) throws -> Void) {
        workspace.edit(action) { graph in
            guard let i=graph.nodes.firstIndex(where:{$0.id==id}) else { return }
            try fn(&graph.nodes[i])
        }
    }
    func color(_ i: Int) -> Color {
        if let p=linkedPalette,!p.colors.isEmpty { return p.sampled(at:Double(i)/Double(max(1,count-1))).displayColor }
        return displayColor(value("color\(i)"))
    }
    func displayColor(_ packed: Double) -> Color {
        let c=MeshGradientStyle.color(packed)
        return Color(.sRGB,red:Double(c.x),green:Double(c.y),blue:Double(c.z),opacity:1)
    }
    func pack(_ color: Color) -> Double {
        guard let c=NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        return Double((Int((c.redComponent*255).rounded())<<16)|(Int((c.greenComponent*255).rounded())<<8)|Int((c.blueComponent*255).rounded()))
    }
    func colorBinding(_ key: String) -> Binding<Color> { Binding(get:{displayColor(value(key))},set:{workspace.parameter(id,key,pack($0))}) }
    func slider(_ key: String,_ title: String,shape: Bool = false,range: ClosedRange<Double>? = nil) -> some View {
        let spec=MeshGradientStyle.parameters.first {$0.key==key}!
        return VStack(spacing:4) {
            HStack { Text(title);Spacer();TextField(title,value:binding(key,shape:shape),format:.number.precision(.fractionLength(0...3))).textFieldStyle(.squareBorder).frame(width:68) }
            ParameterControl(value:binding(key,shape:shape),in:range ?? spec.min...spec.max,step:spec.step,showsValueField:false,spec:spec,colorHue:Double(NSColor(color(selected.first ?? 0)).usingColorSpace(.sRGB)?.hueComponent ?? 0),onEditingChanged:{ active in
                if active { workspace.beginGesture() } else { workspace.endGesture("Adjust Mesh Gradient") }
            }).controlSize(.small)
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
    func picker(_ key: String,_ title: String,_ choices: [String],shape: Bool = false) -> some View {
        Picker(title,selection:binding(key,shape:shape)) { ForEach(choices.indices,id:\.self) { Text(choices[$0]).tag(Double($0)) } }
            .midiParameter(workspace:workspace,id:id,key:key)
    }
    func add(_ shape: Int,at p: Position = .init(0.5,0.5)) {
        var result=0
        editNode("Add Mesh Region") { result=try MeshGradientStyle.addRegion(to:&$0,shape:shape,position:p) }
        selected=[result]
    }
    func duplicate() {
        var indices=Set<Int>()
        editNode("Duplicate Mesh Regions") { n in for i in selected.sorted() { indices.insert(try MeshGradientStyle.duplicateRegion(i,in:&n)) } }
        if !indices.isEmpty { selected=indices }
    }
    func remove() {
        workspace.edit("Remove Mesh Regions") { try $0.removeMeshRegions(selected,node:id) };selected=[0]
    }
    func applyPreset(_ index: Int) {
        editNode("Apply Mesh Preset") { try MeshGradientStyle.applyPreset(index,to:&$0) };selected=[0];tool = -1
    }
    func importPreset() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.canChooseDirectories=false
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do {
            let data=try Data(contentsOf:url)
            guard let config=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw GraphError("Expected gradient JSON") }
            editNode("Import Mesh Gradient") { try MeshGradientStyle.importConfig(config,to:&$0) };selected=[0]
        } catch { workspace.message=error.localizedDescription }
    }
    func position(_ i: Int,size: CGSize) -> CGPoint {
        guard let n=node else { return .zero }
        let p=editAnchors || value("fieldStyle") == 0 ? Position(value("x\(i)"),value("y\(i)")) : renderer.meshPositions(id).flatMap { $0.indices.contains(i) ? $0[i]:nil } ?? MeshGradientStyle.animatedPosition(n,index:i,time:renderer.time*value("speed"))
        return CGPoint(x:p.x*size.width,y:p.y*size.height)
    }
    func arm(_ i: Int,_ side: Int,size: CGSize) -> CGPoint {
        let center=position(i,size:size),shape=Int(value("shape\(i)")),linked=value("linked\(i)")>0
        let names=["left","right","top","bottom"],a=value("angle\(i)")*Double.pi/180,b=value("axisAngle\(i)")*Double.pi/180,bend=value("bend\(i)")*Double.pi/180
        let angles=linked ? [a+Double.pi-(shape==2 ? bend:0),a+(shape==2 ? bend:0),b+Double.pi,b] : names.map {value("\($0)Angle\(i)")*Double.pi/180}
        let radius=value("\(names[side])\(i)")*max(size.width,size.height)*0.12
        return CGPoint(x:center.x+cos(angles[side])*radius,y:center.y+sin(angles[side])*radius)
    }
    func hardRadius(_ i: Int) -> Double { 20+14*log2(max(1,value("hardness\(i)"))) }
    var toolbar: some View {
        HStack(spacing:6) {
            Picker("Tool",selection:$tool) { Text("Select").tag(-1);ForEach(MeshGradientStyle.shapes.indices,id:\.self) { Text(MeshGradientStyle.shapes[$0]).tag($0) } }.labelsHidden()
            Button(action:duplicate) { Image(systemName:"plus.square.on.square") }.help("Duplicate regions").disabled(count+selected.count>40 || selected.isEmpty)
            Button(action:remove) { Image(systemName:"trash") }.help("Delete regions").disabled(selected.isEmpty || selected.count>=count)
            Button { expanded=true } label:{ Image(systemName:"arrow.up.left.and.arrow.down.right") }.help("Expand editor")
        }.controlSize(.small)
    }
    var pointEditor: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from:.now,by:1.0/30)) { _ in
                MeshGradientPreview(renderer:renderer,id:id,handles:(0..<count).map { i in
                    let shape=Int(value("shape\(i)")),active=selected.contains(i) && value("fieldStyle")>0
                    return MeshPreviewHandle(position:position(i,size:geo.size),color:NSColor(color(i)),selected:selected.contains(i),radius:active ? hardRadius(i):0,arms:active && shape<3 ? (0..<(shape==0 ? 4:2)).map {arm(i,$0,size:geo.size)}:[])
                },stroke:stroke,onMove:moved,onEnd:ended).frame(width:geo.size.width,height:geo.size.height)
            }.overlay(Rectangle().stroke(.white.opacity(0.2),lineWidth:1))
        }.aspectRatio(workspace.graph.videoDimensions(id).aspect,contentMode:.fit)
    }
    func moved(_ event: MeshPointer,size: CGSize) {
        guard let n=node else { return }
        if !gestureActive {
            gestureActive=true;workspace.beginGesture()
            if tool == 3 { stroke=[event.startLocation];return }
            if tool>=0 { add(tool,at:.init(event.startLocation.x/size.width,event.startLocation.y/size.height)) }
            else {
                var handle: Int?
                let p=position(point,size:size)
                if selected.count==1 && value("fieldStyle")>0 {
                    let sides=Int(value("shape\(point)"))==0 ? 4:2
                    if Int(value("shape\(point)"))<3 { for side in 0..<sides { let a=arm(point,side,size:size);if hypot(a.x-event.startLocation.x,a.y-event.startLocation.y)<12 { handle=side;break } } }
                    if handle==nil && abs(hypot(p.x-event.startLocation.x,p.y-event.startLocation.y)-hardRadius(point))<7 { handle=4 }
                }
                if let handle { drag=MeshDrag(start:event.startLocation,regions:[:],handle:handle,original:n);return }
                let hit=(0..<count).min { a,b in let pa=position(a,size:size),pb=position(b,size:size);return hypot(pa.x-event.startLocation.x,pa.y-event.startLocation.y)<hypot(pb.x-event.startLocation.x,pb.y-event.startLocation.y) }
                if let hit, hypot(position(hit,size:size).x-event.startLocation.x,position(hit,size:size).y-event.startLocation.y)<18 {
                    let flags=NSApp.currentEvent?.modifierFlags ?? []
                    if flags.contains(.shift) || flags.contains(.command) { if selected.contains(hit) { selected.remove(hit) } else { selected.insert(hit) } }
                    else if !selected.contains(hit) { selected=[hit] }
                    if flags.contains(.option) { duplicate() }
                } else { drag=MeshDrag(start:event.startLocation,regions:[:],original:n);return }
            }
            drag=MeshDrag(start:event.startLocation,regions:Dictionary(uniqueKeysWithValues:selected.map { ($0,Position(value("x\($0)"),value("y\($0)"))) }),original:node ?? n)
        }
        if tool==3 { if let last=stroke.last,hypot(last.x-event.location.x,last.y-event.location.y)>2 { stroke.append(event.location) };return }
        guard let drag else { return }
        if let handle=drag.handle {
            let p=position(point,size:size),dx=event.location.x-p.x,dy=event.location.y-p.y
            editNode("Shape Mesh Region") { n in
                n.parameters["fieldStyle"]=1
                if handle==4 {
                    let k=pow(2.0,max(0.0,(Double(hypot(dx,dy))-20)/14));n.parameters["hardness\(point)"]=max(1,min(5000,k))
                } else {
                    let side=["left","right","top","bottom"][handle]
                    let length=max(0.01,min(5,hypot(dx,dy)/(max(size.width,size.height)*0.12)))
                    n.parameters["\(side)\(point)"]=length
                    let angle=atan2(dy,dx)*180/Double.pi
                    if MeshGradientStyle.value(n,"linked\(point)")<0.5 { n.parameters["\(side)Angle\(point)"]=angle }
                    else {
                        let offset=handle==0 ? 180.0:0, target=handle<2 ? "angle":"axisAngle"
                        let bend=Int(MeshGradientStyle.value(n,"shape\(point)"))==2 ? MeshGradientStyle.value(n,"bend\(point)")*(handle==0 ? -1:1):0
                        let raw=angle-offset-bend;let wrapped=(raw+180).truncatingRemainder(dividingBy:360)
                        n.parameters["\(target)\(point)"]=(wrapped<0 ? wrapped+360:wrapped)-180
                    }
                }
            }
        } else if !drag.regions.isEmpty {
            editNode("Move Mesh Regions") { n in
                for (i,p) in drag.regions {
                    n.parameters["x\(i)"]=max(-2,min(3,p.x+event.translation.width/size.width));n.parameters["y\(i)"]=max(-2,min(3,p.y+event.translation.height/size.height))
                }
                if tool==1 || tool==2 {
                    let dx=event.translation.width/max(size.width,size.height),dy=event.translation.height/max(size.width,size.height)
                    n.parameters["left\(point)"]=max(0.01,min(5,hypot(dx,dy)));n.parameters["right\(point)"]=max(0.01,min(5,hypot(dx,dy)))
                    n.parameters["angle\(point)"]=atan2(dy,dx)*180/Double.pi
                }
                if tool==0 {
                    n.parameters["left\(point)"]=max(0.01,min(5,abs(event.translation.width)/(max(size.width,size.height)*0.12)))
                    n.parameters["right\(point)"]=n.parameters["left\(point)"]
                    n.parameters["top\(point)"]=max(0.01,min(5,abs(event.translation.height)/(max(size.width,size.height)*0.12)))
                    n.parameters["bottom\(point)"]=n.parameters["top\(point)"]
                }
                if tool>=0 {
                    n.parameters["x\(point)"]=(event.startLocation.x+(tool==0 ? 0:event.translation.width*0.5))/size.width
                    n.parameters["y\(point)"]=(event.startLocation.y+(tool==0 ? 0:event.translation.height*0.5))/size.height
                    if tool==1 || tool==2 {
                        n.parameters["left\(point)"]=max(0.01,min(5,hypot(event.translation.width,event.translation.height)/max(size.width,size.height)*0.5))
                        n.parameters["right\(point)"]=n.parameters["left\(point)"]
                    }
                }
            }
        }
    }
    func ended(_ event: MeshPointer,size: CGSize) {
        if tool==3 && stroke.count>=2 {
            var samples=stroke
            for _ in 0..<3 {
                let original=samples
                for i in 1..<(samples.count-1) {
                    let neighbors=original[max(0,i-2)...min(original.count-1,i+2)]
                    samples[i]=CGPoint(x:neighbors.reduce(0) {$0+$1.x}/Double(neighbors.count),y:neighbors.reduce(0) {$0+$1.y}/Double(neighbors.count))
                }
            }
            let center=samples[samples.count/2],long=max(size.width,size.height)
            var result=0
            editNode("Draw Mesh Brush") { n in
                result=try MeshGradientStyle.addRegion(to:&n,shape:3,position:.init(center.x/size.width,center.y/size.height))
                let count=min(192,samples.count)
                var detail=MeshGradientStyle.Detail(text:n.text)
                detail.paths[String(result)]=(0..<count).map { j in let p=samples[j*(samples.count-1)/max(1,count-1)];return [(p.x-center.x)/long,(p.y-center.y)/long,2.5] }
                n.parameters["hardness\(result)"]=2.5;n.parameters["width\(result)"]=0.15;n.text=detail.text
            };selected=[result]
        } else if let drag,drag.regions.isEmpty,drag.handle==nil,hypot(event.translation.width,event.translation.height)>8 {
            let rect=CGRect(x:min(drag.start.x,event.location.x),y:min(drag.start.y,event.location.y),width:abs(event.translation.width),height:abs(event.translation.height))
            selected=Set((0..<count).filter { rect.contains(position($0,size:size)) })
        }
        workspace.endGesture("Edit Mesh Regions");gestureActive=false;drag=nil;stroke=[]
    }
    var regionControls: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("Region \(point+1)");Spacer();PanelColorWell(selection:Binding(get:{color(point)},set:{workspace.parameter(id,"color\(point)",pack($0))}),title:"Region color").frame(width:64,height:24).disabled(paletteSource != nil) }
            picker("shape\(point)","Shape",MeshGradientStyle.shapes,shape:true)
            picker("linked\(point)","Arms",["Independent","Linked"],shape:true)
            slider("opacity\(point)","Influence",shape:true)
            DisclosureGroup("Shape") {
                VStack(spacing:10) {
                    slider("x\(point)","Horizontal");slider("y\(point)","Vertical")
                    slider("angle\(point)","Rotation",shape:true)
                    if Int(value("shape\(point)"))==0 {
                        slider("axisAngle\(point)","Second axis",shape:true)
                        slider("top\(point)","Top spread",shape:true);slider("bottom\(point)","Bottom spread",shape:true)
                    }
                    if Int(value("shape\(point)"))<3 {
                        slider("left\(point)","Left spread",shape:true);slider("right\(point)","Right spread",shape:true)
                        if value("linked\(point)")==0 {
                            ForEach(["left","right"]+(Int(value("shape\(point)"))==0 ? ["top","bottom"]:[]),id:\.self) { side in slider("\(side)Angle\(point)",side.capitalized+" angle",shape:true) }
                        }
                    }
                    if Int(value("shape\(point)"))==2 { slider("bend\(point)","Bend",shape:true) }
                    if Int(value("shape\(point)"))>0 { slider("width\(point)","Band width",shape:true) }
                    slider("hardness\(point)","Hardness",shape:true,range:1...40)
                }.padding(.top,8)
            }
            DisclosureGroup("Fill and compositing") { fillControls.padding(.top,8) }
            DisclosureGroup("Region animation") {
                VStack(spacing:10) { slider("travel\(point)","Travel amount");slider("rate\(point)","Rate");slider("phase\(point)","Phase") }.padding(.top,8)
            }
        }
    }
    var fillControls: some View {
        VStack(spacing:10) {
            picker("gradient\(point)","Fill",["Solid","Gradient"],shape:true)
            if value("gradient\(point)")>0 {
                gradientStops
                slider("gradientAngle\(point)","Fill angle",shape:true)
                picker("gradientEase\(point)","Easing",["Linear","Ease in","Ease out","Ease in/out"],shape:true)
            }
            picker("overlay\(point)","Composite",["Blend","Over"],shape:true)
            if value("overlay\(point)")>0 {
                slider("feather\(point)","Edge feather",shape:true);slider("featherB\(point)","Second edge feather",shape:true);slider("featherAngle\(point)","Feather direction",shape:true)
            }
        }
    }
    var stops: [[Double]] {
        MeshGradientStyle.Detail(text:node?.text).stops[String(point)] ?? [[0,value("color\(point)"),1],[1,value("color\(point)"),1]]
    }
    func stopBinding(_ index: Int,_ component: Int) -> Binding<Double> {
        Binding(get:{ stops.indices.contains(index) ? stops[index][component]:0 },set:{ v in
            editNode("Edit Mesh Fill") { n in var detail=MeshGradientStyle.Detail(text:n.text);var list=stops;guard list.indices.contains(index) else {return};list[index][component]=v;detail.stops[String(point)]=list;n.text=detail.text;n.parameters["fieldStyle"]=1 }
        })
    }
    var gradientStops: some View {
        VStack(spacing:6) {
            ForEach(stops.indices,id:\.self) { index in
                HStack {
                    PanelColorWell(selection:Binding(get:{displayColor(stops[index][1])},set:{stopBinding(index,1).wrappedValue=pack($0)}),title:"Fill stop").frame(width:36,height:22)
                    TextField("Position",value:stopBinding(index,0),format:.number.precision(.fractionLength(0...2))).frame(width:48)
                    ParameterControl(value:stopBinding(index,2),in:0...1,onEditingChanged:{ active in if active {workspace.beginGesture()} else {workspace.endGesture("Fill stop opacity")} }).help("Stop opacity")
                    Button { editNode("Remove Fill Stop") { n in var d=MeshGradientStyle.Detail(text:n.text);var list=stops;list.remove(at:index);d.stops[String(point)]=list;n.text=d.text } } label:{ Image(systemName:"minus.circle") }.disabled(stops.count<=2)
                }
            }
            Button("Add stop") { editNode("Add Fill Stop") { n in var d=MeshGradientStyle.Detail(text:n.text);var list=stops;list.append([0.5,value("color\(point)"),1]);list.sort {$0[0]<$1[0]};d.stops[String(point)]=list;n.text=d.text } }.disabled(stops.count>=8)
        }
    }
    var presets: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Text("Presets");Spacer();Button("Import JSON",action:importPreset).controlSize(.small) }
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
                ForEach(MeshGradientStyle.presets.indices,id:\.self) { i in
                    let preset=MeshGradientStyle.presets[i]
                    Button { applyPreset(i) } label:{
                        VStack(alignment:.leading,spacing:4) {
                            if let root=UserNodeLibrary.bundledDirectory,let image=NSImage(contentsOf:root.appendingPathComponent("Mesh Presets/\(i).png")) {
                                Image(nsImage:image).resizable().aspectRatio(contentMode:.fill).frame(height:64).clipped()
                            }
                            Text(preset.name).font(.system(size:10)).foregroundStyle(.primary)
                        }.padding(4).background(.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:4))
                    }.buttonStyle(.plain).accessibilityLabel(preset.name).help("\(preset.author) · \(preset.source)")
                }
            }
        }
    }
    var animation: some View {
        VStack(spacing:10) {
            picker("motion","Motion",["Still","Drift","Lava","Orbit","Wander"])
            slider("speed","Speed");slider("movement","Movement")
            slider("motionX","Horizontal travel");slider("motionY","Vertical travel")
            slider("motionPhase","Phase");picker("motionBoundary","Bounds",["Free","Reflect"])
        }
    }
    var content: some View {
        VStack(alignment:.leading,spacing:14) {
            toolbar
            pointEditor
            Toggle("Show saved anchors",isOn:$editAnchors).controlSize(.small)
            ScrollView(.horizontal) { HStack(spacing:6) { ForEach(0..<count,id:\.self) { i in
                Button { selected=[i] } label:{ RoundedRectangle(cornerRadius:3).fill(color(i)).frame(width:25,height:24).overlay(Text("\(i+1)").font(.system(size:9)).foregroundStyle(.white)).overlay(RoundedRectangle(cornerRadius:3).stroke(selected.contains(i) ? .white:.clear,lineWidth:2)) }.buttonStyle(.plain)
            } } }
            regionControls
            presets
            DisclosureGroup("Color schemes") {
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())]) { ForEach(MeshGradientStyle.palettes.indices,id:\.self) { i in
                    PaletteSchemeButton(name:MeshGradientStyle.palettes[i].name,colors:MeshGradientStyle.palettes[i].colors.map(PaletteColor.init(hex:))) { editNode("Mesh Color Scheme") { n in for j in 0..<count { n.parameters["color\(j)"]=Double(MeshGradientStyle.palettes[i].colors[j%8]) } } }.disabled(paletteSource != nil)
                } }
            }
            DisclosureGroup("Animation") { animation.padding(.top,8) }
            picker("fieldStyle","Rendering",["Existing","Shaped"])
            picker("blendSpace","Blending",MeshGradientStyle.blendModes,shape:true)
            slider("softness","Blend softness");slider("warp","Flow distortion")
            DisclosureGroup("Color adjustment") { VStack(spacing:10) { slider("hue","Hue");slider("saturation","Saturation");slider("brightness","Brightness");slider("temperature","Temperature") }.padding(.top,8) }
            DisclosureGroup("Grain") {
                VStack(spacing:10) {
                    slider("grain","Amount");slider("grainSize","Size");slider("grainDensity","Density")
                    picker("grainType","Type",["Mono","Duo","RGB"])
                    HStack { Text("Color");Spacer();PanelColorWell(selection:colorBinding("grainColor"),title:"Grain color").frame(width:64,height:24) }
                    if value("grainType")==1 { HStack { Text("Second color");Spacer();PanelColorWell(selection:colorBinding("grainColor2"),title:"Second grain color").frame(width:64,height:24) } }
                    slider("seed","Seed")
                }.padding(.top,8)
            }
            Text("\(count) / 40 regions").font(.system(size:10)).foregroundStyle(.secondary)
        }
    }
    var body: some View {
        content
            .sheet(isPresented:$expanded) {
                VStack(spacing:12) {
                    HStack { toolbar;Spacer();Button("Done") {expanded=false} }
                    pointEditor
                    HStack { Text("Region \(point+1)");Toggle("Saved anchors",isOn:$editAnchors);Spacer();picker("motion","Motion",["Still","Drift","Lava","Orbit","Wander"]) }
                }.padding(16).frame(width:820,height:680)
            }
            .onChange(of:count) { _,n in selected=selected.filter {$0<n};if selected.isEmpty {selected=[0]} }
            .onChange(of:id) { _,_ in selected=[0];drag=nil;stroke=[];tool = -1 }
            .onDisappear { if gestureActive {workspace.endGesture("Edit Mesh Regions");gestureActive=false} }
    }
}
