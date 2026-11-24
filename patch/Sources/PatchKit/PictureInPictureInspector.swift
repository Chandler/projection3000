import SwiftUI
import PatchCore

struct PictureInPictureInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @State private var original: Node?
    var node: Node? { workspace.graph.node(id) }
    func set(_ values: [String:Double],_ title: String = "Adjust Picture in Picture") {
        workspace.edit(title) { graph in for (key,value) in values { try graph.setParameter(id,key:key,value:value) } }
    }
    func drag(_ translation: CGSize,_ size: CGSize,corner: Int? = nil) {
        guard let node else { return }
        if original == nil { original=node; workspace.beginGesture() }
        guard let n=original else { return }
        let dx=translation.width/max(1,size.width), dy=translation.height/max(1,size.height)
        let ow=n.value("width"), oh=n.value("height")
        let ox=(1-ow)*n.value("x"), oy=(1-oh)*n.value("y")
        var w=ow,h=oh,x=ox,y=oy
        if let corner {
            let left=corner%2 == 0, top=corner<2
            let anchorX=left ? ox+ow : ox, anchorY=top ? oy+oh : oy
            let maxW=left ? anchorX : 1-anchorX, maxH=top ? anchorY : 1-anchorY
            w=max(0.05,min(maxW,ow+dx*(left ? -1 : 1)))
            h=max(0.05,min(maxH,oh+dy*(top ? -1 : 1)))
            if n.value("lock")==1 {
                let factor=abs(dx/ow)>abs(dy/oh) ? w/ow : h/oh
                let scale=max(max(0.05/ow,0.05/oh),min(factor,min(maxW/ow,maxH/oh)))
                w=ow*scale; h=oh*scale
            }
            x=left ? anchorX-w : anchorX; y=top ? anchorY-h : anchorY
        } else { x=ox+dx; y=oy+dy }
        set(["width":w,"height":h,"x":w<1 ? max(0,min(1,x/(1-w))) : 0.5,"y":h<1 ? max(0,min(1,y/(1-h))) : 0.5])
    }
    func finish() { if original != nil { original=nil; workspace.endGesture("Place Picture in Picture") } }
    func parameter(_ key: String,_ title: String) -> some View {
        let spec=PictureInPictureStyle.parameters.first { $0.key == key }!
        let binding=Binding<Double>(get:{ node?.value(key) ?? spec.initial },set:{ value in
            guard value.isFinite else { return }
            let value=max(spec.min,min(spec.max,value))
            if (key == "width" || key == "height"), let n=node, n.value("lock")==1 {
                let other=key == "width" ? "height" : "width"
                let ratio=n.value(other)/max(0.05,n.value(key))
                let clamped=max(max(0.05,0.05/ratio),min(value,min(1,1/ratio)))
                set([key:clamped,other:clamped*ratio])
            } else { workspace.parameter(id,key,value) }
        })
        return VStack(spacing:4) {
            HStack { Text(title); Spacer(); TextField(title,value:binding,format:.number.precision(.fractionLength(0...3))).textFieldStyle(.squareBorder).frame(width:62) }
            ParameterControl(value:binding,in:spec.min...spec.max,step:spec.step,showsValueField:false,spec:spec,onEditingChanged:{ editing in if editing { workspace.beginGesture() } else { workspace.endGesture("Adjust Inset") } }).controlSize(.small)
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("PICTURE IN PICTURE").font(.editorHeading).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { set(Dictionary(uniqueKeysWithValues:PictureInPictureStyle.parameters.map { ($0.key,$0.initial) })) }.buttonStyle(.plain)
            }
            Text("A fills the canvas. Drag B to place it; drag a corner to resize.").font(.system(size:11)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let w=node?.value("width") ?? 0.3,h=node?.value("height") ?? 0.3
                let rect=CGRect(x:(1-w)*(node?.value("x") ?? 0.96)*geometry.size.width,y:(1-h)*(node?.value("y") ?? 0.96)*geometry.size.height,width:w*geometry.size.width,height:h*geometry.size.height)
                ZStack(alignment:.topLeading) {
                    MetalPreview(renderer:renderer,id:id).allowsHitTesting(false)
                    Rectangle().fill(.clear).contentShape(Rectangle()).frame(width:rect.width,height:rect.height).position(x:rect.midX,y:rect.midY)
                        .gesture(DragGesture(minimumDistance:0).onChanged { drag($0.translation,geometry.size) }.onEnded { _ in finish() })
                    Rectangle().stroke(Color.accentColor,lineWidth:1).frame(width:rect.width,height:rect.height).position(x:rect.midX,y:rect.midY).allowsHitTesting(false)
                    ForEach(0..<4,id:\.self) { corner in
                        RoundedRectangle(cornerRadius:2).fill(.white).frame(width:8,height:8).shadow(color:.black,radius:1)
                            .frame(width:22,height:22).contentShape(Rectangle())
                            .position(x:corner%2 == 0 ? rect.minX : rect.maxX,y:corner<2 ? rect.minY : rect.maxY)
                            .gesture(DragGesture(minimumDistance:0).onChanged { drag($0.translation,geometry.size,corner:corner) }.onEnded { _ in finish() })
                            .accessibilityLabel("Resize inset corner \(corner+1)")
                    }
                }.background(.black).clipped()
            }.aspectRatio(workspace.graph.videoDimensions(id).aspect,contentMode:.fit)
            HStack {
                ForEach(0..<4,id:\.self) { corner in
                    Button { set(["x":corner%2 == 0 ? 0.04 : 0.96,"y":corner<2 ? 0.04 : 0.96]) } label: {
                        Image(systemName:["arrow.up.left","arrow.up.right","arrow.down.left","arrow.down.right"][corner]).frame(maxWidth:.infinity)
                    }.help(["Top left","Top right","Bottom left","Bottom right"][corner])
                }
                Button("Center") { set(["x":0.5,"y":0.5]) }
            }.controlSize(.small)
            Toggle("Lock proportions",isOn:Binding(get:{ node?.value("lock")==1 },set:{ set(["lock":$0 ? 1 : 0]) })).toggleStyle(.checkbox)
            parameter("width","Width · fraction of canvas")
            DisclosureGroup("Position & Size") { VStack(spacing:10) { parameter("height","Height · fraction of canvas"); parameter("x","Horizontal"); parameter("y","Vertical") }.padding(.top,8) }
            Picker("Framing",selection:Binding(get:{ Int(node?.value("fit") ?? 1) },set:{ set(["fit":Double($0)]) })) {
                Text("Fit").tag(0); Text("Fill").tag(1); Text("Stretch").tag(2)
            }.pickerStyle(.segmented)
            parameter("opacity","Opacity")
            DisclosureGroup("Border & Shadow") { VStack(spacing:10) { parameter("radius","Corner radius · px"); parameter("border","White border · px"); parameter("shadow","Shadow") }.padding(.top,8) }
        }.onDisappear { finish() }
    }
}
