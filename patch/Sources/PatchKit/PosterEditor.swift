import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PatchCore

enum PosterFonts {
    /// Faces that suit club and techno posters, as (PostScript name, title); missing ones are skipped.
    static let featured: [(String,String)] = [
        ("Helvetica Neue","Condensed Black"),("Helvetica Neue","Condensed Bold"),("Helvetica Neue","Bold"),("Helvetica Neue","Medium"),
        ("Futura","Condensed ExtraBold"),("DIN Condensed","Bold"),("DIN Alternate","Bold"),("Avenir Next Condensed","Heavy"),
        ("Skia","Black Extended"),("Skia","Extended"),("Krungthep","Regular"),("Impact","Regular"),("Arial Black","Regular"),
        ("Andale Mono","Regular"),("PT Mono","Bold"),("Menlo","Bold")
    ].compactMap { family,style in
        members(family).first { $0.1 == style }.map { ($0.0,"\(family) \(style == "Regular" ? "" : style)".trimmingCharacters(in:.whitespaces)) }
    }
    static let families = NSFontManager.shared.availableFontFamilies
    static func members(_ family: String) -> [(String,String)] {
        (NSFontManager.shared.availableMembers(ofFontFamily:family) ?? []).compactMap { member in
            guard let name = member.first as? String,let style = member.dropFirst().first as? String else { return nil }
            return (name,style)
        }
    }
    static func name(_ postScript: String) -> String { NSFont(name:postScript,size:12)?.displayName ?? postScript }
}

/// Poster Composer's editor: the live poster with direct manipulation of its
/// type, shapes, images and video layers, plus the poster's fill and type settings.
struct PosterEditor: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @StateObject private var model: PosterEditorModel
    @FocusState private var textFocused: Bool
    @State private var exportError: String?
    @State private var addingImage = false
    @State private var replacingImage = false
    @State private var choosingFont = false
    init(workspace: Workspace,renderer: Renderer,id: UUID) {
        self.workspace = workspace; self.renderer = renderer; self.id = id
        _model = StateObject(wrappedValue:PosterEditorModel(workspace:workspace,renderer:renderer,id:id))
    }
    var body: some View {
        NodeAppLayout(sidebarWidth:300,footer:exportError) { toolbar } canvas: {
            PosterCanvas(model:model,workspace:workspace)
        } sidebar: { sidebar } leading: { layers }
        .onChange(of:model.focusText) { _,id in if id != nil { textFocused = true; model.focusText = nil } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        Group {
            Text(workspace.graph.node(id)?.name ?? "Poster removed").font(.headline)
            HStack(spacing:2) {
                ForEach(PosterTool.allCases,id:\.self) { tool in
                    Button { model.tool = tool } label: { Image(systemName:tool.symbol).frame(width:22,height:18) }
                        .buttonStyle(.bordered).tint(model.tool == tool ? Color(nsColor:.patchAccent) : nil)
                        .help("\(tool.title) (\(tool.key.uppercased()))")
                }
            }
            Divider().frame(height:18)
            HStack(spacing:2) {
                alignButton("align.horizontal.left",.left,"Align left"); alignButton("align.horizontal.center",.centerX,"Align horizontal centers"); alignButton("align.horizontal.right",.right,"Align right")
                alignButton("align.vertical.top",.top,"Align top"); alignButton("align.vertical.center",.centerY,"Align vertical centers"); alignButton("align.vertical.bottom",.bottom,"Align bottom")
                Button { model.distribute(vertical:false) } label: { Image(systemName:"distribute.horizontal.center") }.help("Distribute horizontally").disabled(model.selection.count < 3)
                Button { model.distribute(vertical:true) } label: { Image(systemName:"distribute.vertical.center") }.help("Distribute vertically").disabled(model.selection.count < 3)
            }.buttonStyle(.borderless)
            Spacer()
            HStack(spacing:4) {
                Button { model.zoom = max(0.25,model.zoom/1.25) } label: { Image(systemName:"minus.magnifyingglass") }.help("Zoom out (⌘−)")
                Text("\(Int((model.zoom*100).rounded()))%").monospacedDigit().frame(width:44)
                Button { model.zoom = min(3,model.zoom*1.25) } label: { Image(systemName:"plus.magnifyingglass") }.help("Zoom in (⌘=)")
                Button("Fit") { model.zoom = 1; model.pan = .zero }.help("Fit poster (⌘0)")
            }.buttonStyle(.borderless)
            Picker("Format",selection:Binding(get:{ Int((model.composer ?? model.textNode)?.value("format") ?? 0) },set:{ model.setFormat($0) })) {
                ForEach(PosterStyle.formats.indices,id:\.self) { Text(PosterStyle.formats[$0].0).tag($0) }
            }.labelsHidden().frame(width:150)
            Toggle("Guides",isOn:$model.showGuides).toggleStyle(.button)
            Button("Export PNG…") { export() }.disabled(model.previewID == nil)
        }
    }
    private func alignButton(_ symbol: String,_ edge: PosterEditorModel.Edge,_ help: String) -> some View {
        Button { model.align(edge) } label: { Image(systemName:symbol) }.help(model.selection.count > 1 ? help : help+" to poster").disabled(model.selection.isEmpty)
    }

    // MARK: Layers

    private var layers: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("LAYERS").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.textNode != nil && !model.isFreeLayout { Text("auto layout").font(.system(size:10)).foregroundStyle(.tertiary) }
            }.padding(.horizontal,12).padding(.vertical,10)
            List {
                // Drag to restack; the chrome moves like any other layer.
                ForEach(model.rows,id:\.self) { row in
                    switch row {
                    case .group(let id): if let group = model.layout.group(id) { groupRow(group) }
                    case .item(.element(let id)): if let element = model.element(id) { elementRow(element) }
                    }
                }.onMove { model.moveRows(from:$0,to:$1) }
            }.listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight,24)
            Divider()
            HStack(spacing:10) {
                Button { addingImage = true } label: { Image(systemName:"photo.badge.plus") }.help("Add image layer").disabled(model.textID == nil)
                    .popover(isPresented:$addingImage) { PosterTextureBrowser(current:nil) { url in if let url { model.addImage(url) }; addingImage = false } }
                Menu { videoMenu(nil) } label: { Image(systemName:"play.rectangle") }.menuIndicator(.hidden).fixedSize()
                    .help("Add video layer: wires a node into the next free video input").disabled(model.composerID == nil)
                Group {
                Button { model.groupSelection() } label: { Image(systemName:"folder.badge.plus") }.help("Group (⌘G)")
                Button { model.arrange(.forward) } label: { Image(systemName:"square.2.layers.3d.top.filled") }.help("Bring forward (⌘])")
                Button { model.arrange(.backward) } label: { Image(systemName:"square.2.layers.3d.bottom.filled") }.help("Send backward (⌘[)")
                Button { model.duplicateSelection() } label: { Image(systemName:"plus.square.on.square") }.help("Duplicate (⌘D)")
                Spacer()
                Button { model.deleteSelection() } label: { Image(systemName:"trash") }.help("Delete (⌫)")
                }.disabled(model.selection.isEmpty)
            }.buttonStyle(.borderless).padding(10)
        }
    }
    private func select(_ item: PosterItem) {
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if model.selection.contains(item) { model.selection.remove(item) } else { model.selection.insert(item) }
        } else { model.selection = [item] }
    }
    private func elementRow(_ element: PosterElement) -> some View {
        let selected = model.selection.contains(.element(element.id))
        let symbol = ["text":"character","rule":"minus","rectangle":"rectangle","ellipse":"circle","image":"photo","video":"play.rectangle"][element.shape.rawValue] ?? "square"
        let title = element.shape == .video && element.name == nil ? model.source(element)?.name ?? element.title : element.title
        return HStack(spacing:6) {
            Button { model.update(element.id,action:element.hidden ? "Show" : "Hide") { $0.hidden.toggle() } } label: { Image(systemName:element.hidden ? "eye.slash" : "eye").frame(width:16) }
                .buttonStyle(.plain).foregroundStyle(element.hidden ? .tertiary : .secondary)
            Image(systemName:symbol).frame(width:14).foregroundStyle(.secondary)
            Text(title).lineLimit(1).font(.system(size:12)).foregroundStyle(model.layout.isHidden(element) ? .secondary : .primary)
            Spacer(minLength:4)
            Button { model.update(element.id,action:element.locked ? "Unlock" : "Lock") { $0.locked.toggle() } } label: { Image(systemName:element.locked ? "lock.fill" : "lock.open").frame(width:14) }
                .buttonStyle(.plain).foregroundStyle(element.locked ? .secondary : .quaternary)
        }
        .padding(.vertical,2).padding(.leading,element.group == nil ? 0 : 16)
        .contentShape(Rectangle())
        .onTapGesture { select(.element(element.id)) }
        .listRowBackground(selected ? Color(nsColor:.patchAccent).opacity(0.28) : Color.clear)
    }
    private func groupRow(_ group: PosterGroup) -> some View {
        let members = Set(model.members(group.id).map { PosterItem.element($0.id) })
        let selected = !members.isEmpty && members.isSubset(of:model.selection)
        return HStack(spacing:6) {
            Button { model.updateGroup(group.id,action:group.hidden ? "Show Group" : "Hide Group") { $0.hidden.toggle() } } label: { Image(systemName:group.hidden ? "eye.slash" : "eye").frame(width:16) }
                .buttonStyle(.plain).foregroundStyle(group.hidden ? .tertiary : .secondary)
            Button {
                model.updateGroup(group.id,action:group.collapsed ? "Expand Group" : "Collapse Group") { $0.collapsed.toggle() }
                if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) { model.selection.formUnion(members) } else { model.selection = members }
            } label: {
                HStack(spacing:6) {
                    Image(systemName:group.collapsed ? "chevron.right" : "chevron.down").frame(width:10).foregroundStyle(.secondary)
                    Image(systemName:"folder").frame(width:14).foregroundStyle(.secondary)
                    Text(group.name).lineLimit(1).font(.system(size:12,weight:.medium))
                    Text("\(members.count)").font(.system(size:10)).foregroundStyle(.tertiary)
                    Spacer(minLength:4)
                }.frame(minHeight:24).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(group.collapsed ? "Collapsed" : "Expanded")
            Button { model.updateGroup(group.id,action:group.locked ? "Unlock Group" : "Lock Group") { $0.locked.toggle() } } label: { Image(systemName:group.locked ? "lock.fill" : "lock.open").frame(width:14) }
                .buttonStyle(.plain).foregroundStyle(group.locked ? .secondary : .quaternary)
        }
        .padding(.vertical,2)
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) { model.selection.formUnion(members) } else { model.selection = members }
        }
        .listRowBackground(selected ? Color(nsColor:.patchAccent).opacity(0.28) : Color.clear)
    }
    /// Video nodes to draw; `input` rewires that input, nil takes the next free one.
    @ViewBuilder private func videoMenu(_ input: Int?) -> some View {
        let candidates = model.videoCandidates
        if candidates.isEmpty { Text("No video nodes in this patch") }
        ForEach(candidates,id:\.id) { node in Button(node.name) { model.connectVideo(node.id,input:input) } }
    }

    // MARK: Properties

    @ViewBuilder private var sidebar: some View {
        let selected = model.selectedElements
        if selected.isEmpty { document } else { elementProperties(selected) }
    }
    /// Shows the frontmost selected layer's values; every change applies to the whole selection.
    private func elementProperties(_ elements: [PosterElement]) -> some View {
        let element = elements.last!, single = elements.count == 1, id = element.id, w = model.poster.width, h = model.poster.height
        let allText = elements.allSatisfy { $0.shape == .text }
        func edit(_ action: String,_ fn: @escaping (inout PosterElement) -> Void) { model.updateSelection(action,fn) }
        return Group {
            if !single {
                NodeAppSection(title:"\(elements.count) selected",caption:"Changes apply to every selected layer. Double-click on the poster selects inside a group.") {
                    if let group = model.selectedGroup {
                        TextField("Group name",text:Binding(get:{ model.layout.group(group.id)?.name ?? "" },set:{ name in model.updateGroup(group.id,action:"Rename Group") { $0.name = name } }))
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Button("Group") { model.groupSelection() }.help("⌘G")
                        Button("Ungroup") { model.ungroupSelection() }.help("⌘⇧G").disabled(!elements.contains { $0.group != nil })
                    }
                }
            }
            if allText {
                NodeAppSection(title:"Type") {
                    if single {
                        TextEditor(text:Binding(get:{ model.element(id)?.text ?? "" },set:{ text in model.update(id,action:"Edit Text") { $0.text = text } }))
                            .font(.system(size:13)).frame(height:76).scrollContentBackground(.hidden).padding(4)
                            .background(Color.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius:4)).focused($textFocused)
                    }
                    fontMenu(element)
                    slider("Size · px",element.size*w,4...max(8,w*0.6),action:"Change Size") { v in edit("Change Size") { $0.size = v/w } }
                    slider("Tracking · em",element.tracking,-0.1...0.4,action:"Change Tracking") { v in edit("Change Tracking") { $0.tracking = v } }
                    slider("Slant",element.slant,-0.4...0.4,action:"Change Slant") { v in edit("Change Slant") { $0.slant = v } }
                    if elements.contains(where:{ $0.text.contains("\n") }) { slider("Leading",element.leading,0.6...2,action:"Change Leading") { v in edit("Change Leading") { $0.leading = v } } }
                    Picker("Align",selection:Binding(get:{ element.align.rawValue },set:{ value in edit("Change Alignment") { $0.align = PosterElement.Align(rawValue:value) ?? .center } })) {
                        Image(systemName:"text.alignleft").tag(0); Image(systemName:"text.aligncenter").tag(1); Image(systemName:"text.alignright").tag(2)
                    }.pickerStyle(.segmented)
                    if single {
                        Button("Fit Between Margins") { model.fitBetweenMargins(id) }.help("Scale the type so its widest line spans the margins")
                    }
                }
            }
            if single && element.shape == .image {
                NodeAppSection(title:"Image") {
                    HStack(spacing:8) {
                        if let file = element.file { TextureThumbnail(url:URL(fileURLWithPath:file)) }
                        Text(element.title).font(.system(size:11)).lineLimit(2)
                        Spacer()
                        Button("Replace…") { replacingImage = true }
                            .popover(isPresented:$replacingImage) {
                                PosterTextureBrowser(current:element.file,removable:true) { url in
                                    if let url { model.update(id,action:"Replace Image") { $0.file = url.path } } else { model.deleteSelection() }
                                    replacingImage = false
                                }
                            }
                    }
                    Toggle("Invert",isOn:Binding(get:{ element.invert },set:{ value in model.update(id,action:"Invert Image") { $0.invert = value } })).toggleStyle(.checkbox)
                    Button("Fill Poster") { model.fillPoster(id) }
                }
            }
            if single && element.shape == .video {
                NodeAppSection(title:"Video \(element.input ?? 1)") {
                    Menu(model.source(element)?.name ?? "Not connected") { videoMenu(element.input) }
                    Toggle("Invert",isOn:Binding(get:{ element.invert },set:{ value in model.update(id,action:"Invert Video") { $0.invert = value } })).toggleStyle(.checkbox)
                    Button("Fit Poster Width") { model.fitVideoWidth(id) }
                }
            }
            if single && element.shape == .rule {
                NodeAppSection(title:"Rule") {
                    slider("Length · px",element.width*w,2...w*1.5,action:"Change Length") { v in edit("Change Length") { $0.width = v/w } }
                    slider("Weight · px",element.stroke*w,1...max(2,w*0.03),action:"Change Weight") { v in edit("Change Weight") { $0.stroke = v/w } }
                }
            }
            if single && [.rectangle,.ellipse,.image,.video].contains(element.shape) {
                NodeAppSection(title:"Size") {
                    slider("Width · px",element.width*w,2...w*2,action:"Change Width") { v in edit("Change Width") { $0.width = v/w } }
                    slider("Height · px",element.height*h,2...h*2,action:"Change Height") { v in edit("Change Height") { $0.height = v/h } }
                    if element.shape != .image && element.shape != .video {
                        slider("Outline · px (0 fills)",element.stroke*w,0...max(2,w*0.03),action:"Change Outline") { v in edit("Change Outline") { $0.stroke = v/w } }
                    }
                }
            }
            NodeAppSection(title:"Appearance") {
                Picker("Blend",selection:Binding(get:{ element.blend },set:{ value in edit("Change Blend") { $0.blend = value } })) {
                    ForEach(PosterElement.Blend.allCases,id:\.self) { Text($0.title).tag($0) }
                }
                if !elements.contains(where:{ $0.shape == .image || $0.shape == .video }) { HStack {
                    Toggle("Ink",isOn:Binding(get:{ element.color == nil },set:{ ink in edit("Change Color") { $0.color = ink ? nil : model.ink } })).toggleStyle(.checkbox)
                        .help("Follow the poster's ink color")
                    Spacer()
                    ColorPicker("Color",selection:Binding(get:{ let c = element.color ?? model.ink; return CGColor(srgbRed:c[0],green:c[1],blue:c[2],alpha:1) },set:{ color in
                        guard let rgb = color.converted(to:CGColorSpace(name:CGColorSpace.sRGB)!,intent:.defaultIntent,options:nil)?.components,rgb.count >= 3 else { return }
                        edit("Change Color") { $0.color = [Double(rgb[0]),Double(rgb[1]),Double(rgb[2])] }
                    }),supportsOpacity:false).labelsHidden()
                } }
                slider("Opacity",element.opacity,0...1,action:"Change Opacity") { v in edit("Change Opacity") { $0.opacity = v } }
            }
            NodeAppSection(title:"Transform") {
                if single {
                    HStack {
                        numberField("X",element.x*w) { v in model.update(id,action:"Move") { $0.x = v/w } }
                        numberField("Y",element.y*h) { v in model.update(id,action:"Move") { $0.y = v/h } }
                    }
                }
                slider("Rotation °",element.rotation,-180...180,action:"Rotate") { v in edit("Rotate") { $0.rotation = v } }
            }
            if single {
                NodeAppSection(title:"Layer") {
                    TextField("Name",text:Binding(get:{ element.name ?? "" },set:{ name in model.update(id,action:"Rename") { $0.name = name.isEmpty ? nil : name } }),prompt:Text(element.title))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Toggle("Hidden",isOn:Binding(get:{ element.hidden },set:{ value in model.update(id,action:"Hide") { $0.hidden = value } })).toggleStyle(.checkbox)
                        Toggle("Locked",isOn:Binding(get:{ element.locked },set:{ value in model.update(id,action:"Lock") { $0.locked = value } })).toggleStyle(.checkbox)
                    }
                }
            }
        }
    }
    private func fontMenu(_ element: PosterElement) -> some View {
        Button { choosingFont = true } label: {
            HStack {
                Text(PosterFonts.name(element.font)).font(NSFont(name:element.font,size:13).map { Font($0 as CTFont) } ?? .system(size:13)).lineLimit(1)
                Spacer()
                Image(systemName:"chevron.up.chevron.down").font(.system(size:10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal,8).padding(.vertical,5).background(Color.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius:4)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented:$choosingFont,arrowEdge:.leading) {
            PosterFontBrowser(current:element.font,sample:element.text) { font in model.updateSelection("Change Font") { $0.font = font } }
        }
    }
    @ViewBuilder private var document: some View {
        if let composerID = model.composerID {
            NodeAppSection(title:"Poster") {
                ForEach(["backgroundLevel","backgroundWarmth","textOpacity"],id:\.self) { NodeAppParameter(workspace:workspace,id:composerID,key:$0) }
            }
        }
        if let textID = model.textID {
            NodeAppSection(title:"Type",caption:model.isFreeLayout ? "Free layout. Reverting rebuilds the type from the tagged text." : "Laid out from tagged text. Editing on the poster switches to a free layout.") {
                NodeAppParameter(workspace:workspace,id:textID,key:"ink"); NodeAppParameter(workspace:workspace,id:textID,key:"inkWarmth")
                NodeAppParameter(workspace:workspace,id:textID,key:"margin",title:"Margins")
                if model.isFreeLayout {
                    Button("Revert to Tagged Text") { workspace.update(textID,action:"Revert Poster Layout") { $0.poster = nil }; model.selection = [] }
                } else {
                    TextEditor(text:Binding(get:{ model.textNode?.text ?? PosterStyle.defaultText },set:{ value in workspace.update(textID,action:"Edit Poster Text") { $0.text = value } }))
                        .font(.system(size:12,design:.monospaced)).frame(height:150).scrollContentBackground(.hidden).padding(4)
                        .background(Color.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius:4))
                    ForEach(["headlineFont","headlineSize","slant","tracking","bodySize","spacing"],id:\.self) { NodeAppParameter(workspace:workspace,id:textID,key:$0) }
                }
            }
        }
    }
    private func slider(_ title: String,_ value: Double,_ range: ClosedRange<Double>,action: String,set: @escaping (Double) -> Void) -> some View {
        VStack(alignment:.leading,spacing:5) {
            NodeAppSliderTitle(title:title,value:value,range:range) { typed in set(typed) }
            ParameterControl(value:Binding(get:{ value },set:set),in:range,onEditingChanged:{ editing in
                if editing { workspace.beginGesture() } else { workspace.endGesture(action) }
            }).controlSize(.small)
        }
    }
    private func numberField(_ title: String,_ value: Double,set: @escaping (Double) -> Void) -> some View {
        HStack(spacing:4) {
            Text(title).foregroundStyle(.secondary)
            TextField(title,value:Binding(get:{ value },set:{ if $0.isFinite { set($0) } }),format:.number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).font(.system(size:11,design:.monospaced))
        }
    }
    private func export() {
        guard let previewID = model.previewID else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "\(workspace.graph.node(id)?.name ?? "Poster").png"
        panel.begin { response in
            guard response == .OK,let url = panel.url else { return }
            do { try renderer.snapshot(previewID,to:url,fullResolution:true); exportError = nil } catch { exportError = error.localizedDescription }
        }
    }
}

struct TextureThumbnail: View {
    let url: URL
    @ObservedObject private var thumbnails = TextureThumbnails.shared
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            if let image = thumbnails.image(url) { Image(nsImage:image).resizable().aspectRatio(contentMode:.fill) }
        }.frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:3))
    }
}
