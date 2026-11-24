import AppKit
import SwiftUI
import PatchCore

enum PosterItem: Hashable { case element(UUID) }

enum PosterTool: String, CaseIterable {
    case select, text, rule, rectangle, ellipse
    var symbol: String { ["cursorarrow","textformat","line.diagonal","rectangle","circle"][Self.allCases.firstIndex(of:self)!] }
    var key: String { ["v","t","l","m","e"][Self.allCases.firstIndex(of:self)!] }
    var title: String { ["Select","Type","Rule","Rectangle","Ellipse"][Self.allCases.firstIndex(of:self)!] }
}

/// A box in poster pixels (top-left origin), rotated clockwise about its center.
struct PosterBox {
    var center: CGPoint
    var size: CGSize
    var rotation: Double
    private var radians: Double { rotation*Double.pi/180 }
    func toWorld(_ local: CGPoint) -> CGPoint {
        let c = cos(radians), s = sin(radians)
        return CGPoint(x:center.x+local.x*c-local.y*s,y:center.y+local.x*s+local.y*c)
    }
    func toLocal(_ point: CGPoint) -> CGPoint {
        let dx = point.x-center.x, dy = point.y-center.y, c = cos(radians), s = sin(radians)
        return CGPoint(x:dx*c+dy*s,y:-dx*s+dy*c)
    }
    func contains(_ point: CGPoint,slop: Double) -> Bool {
        let local = toLocal(point)
        return abs(local.x) <= size.width/2+slop && abs(local.y) <= size.height/2+slop
    }
    /// Handles clockwise from top-left: tl, t, tr, r, br, b, bl, l.
    static let handleUnits = [CGPoint(x:-1,y:-1),CGPoint(x:0,y:-1),CGPoint(x:1,y:-1),CGPoint(x:1,y:0),CGPoint(x:1,y:1),CGPoint(x:0,y:1),CGPoint(x:-1,y:1),CGPoint(x:-1,y:0)]
    func handle(_ index: Int) -> CGPoint {
        let unit = Self.handleUnits[index]
        return toWorld(CGPoint(x:unit.x*size.width/2,y:unit.y*size.height/2))
    }
    var corners: [CGPoint] { [0,2,4,6].map(handle) }
    var bounds: CGRect {
        let points = corners
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
    }
}

/// Editing state shared by the poster canvas and its panels. The graph stays
/// the only document: every change is a workspace edit on the Poster Text
/// node's layout (video layers draw the composer's inputs).
final class PosterEditorModel: ObservableObject {
    let workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @Published var selection: Set<PosterItem> = []
    @Published var tool: PosterTool = .select
    /// 1 fits the poster to the window.
    @Published var zoom: Double = 1 { didSet { if zoom <= 1 { pan = .zero } } }
    /// Offset of the zoomed poster from the view center.
    var pan = CGPoint.zero
    @Published var showGuides = true
    /// Asks the sidebar to focus this element's text.
    @Published var focusText: UUID?
    static let pasteboardType = NSPasteboard.PasteboardType("local.patch.poster-elements")

    /// Where edits go: the workspace for the window, a draft for the API.
    let document: GraphDocument
    init(workspace: Workspace,renderer: Renderer,id: UUID,document: GraphDocument? = nil) {
        self.workspace = workspace; self.renderer = renderer; self.id = id; self.document = document ?? workspace
    }

    var graph: Graph { document.graph }
    /// The Poster node. It holds the layout too, so `textID` names the same node.
    var composerID: UUID? { graph.node(id)?.kind == .posterComposer ? id : nil }
    var textID: UUID? { composerID }
    var composer: Node? { composerID.flatMap(graph.node) }
    var textNode: Node? { composer }
    var previewID: UUID? { composerID }
    var dimensions: VideoDimensions { (composer ?? textNode).map(PosterStyle.dimensions) ?? VideoDimensions(1080,1440) }
    var poster: CGSize { CGSize(width:dimensions.width,height:dimensions.height) }
    var isFreeLayout: Bool { textNode?.poster != nil }
    /// Includes a default layer for each connected video input not yet placed.
    var layout: PosterLayout {
        guard let textNode else { return PosterLayout() }
        return PosterStyle.withVideos(textNode.poster ?? PosterTextRenderer.autoLayout(textNode,dimensions:PosterStyle.dimensions(textNode)),composer:composer,graph:graph)
    }
    /// Back to front.
    var layers: [PosterElement] { layout.elements }
    /// What draws on the poster: type, shapes and images.
    var elements: [PosterElement] { layers.filter { $0.shape != .chrome } }
    /// Front to back, as Layers lists it.
    var stack: [PosterItem] { elements.reversed().map { .element($0.id) } }
    /// Rewrites the layout in a new front-to-back order.
    func restack(_ action: String,_ order: [PosterItem],membership: [UUID:UUID?] = [:]) {
        change(action) { elements,_ in
            for index in elements.indices { if let group = membership[elements[index].id] { elements[index].group = group } }
            let byID = Dictionary(elements.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
            elements = order.reversed().compactMap { item -> PosterElement? in
                guard case .element(let id) = item else { return nil }
                return byID[id]
            }
        }
    }
    func moveLayers(from source: IndexSet,to destination: Int) {
        var order = stack; order.move(fromOffsets:source,toOffset:destination)
        restack("Reorder Layers",order)
    }
    func element(_ id: UUID) -> PosterElement? { elements.first { $0.id == id } }
    var ink: [Double] { textNode.map(PosterTextRenderer.ink) ?? [0.9,0.88,0.8] }
    var margin: Double { (textNode?.value("margin") ?? 0.055)*poster.width }
    /// The node a video layer draws.
    func source(_ element: PosterElement) -> Node? {
        guard let composerID,let input = element.input else { return nil }
        return graph.edges.first { $0.target == composerID && $0.input == PosterStyle.edgeInput(video:input) }.flatMap { graph.node($0.source) }
    }
    /// Video nodes that can feed the composer without a loop.
    var videoCandidates: [Node] {
        guard let composerID else { return [] }
        var downstream: Set<UUID> = [composerID], pending = [composerID]
        while let id = pending.popLast() { for edge in graph.edges where edge.source == id && downstream.insert(edge.target).inserted { pending.append(edge.target) } }
        return graph.nodes.filter { $0.kind.outputType == .video && !downstream.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Wires a node into a video input: the given one, else the first free one.
    func connectVideo(_ node: UUID,input: Int? = nil) {
        guard let composerID else { return }
        let used = Set(graph.edges.filter { $0.target == composerID }.map { $0.input+1 })
        guard let video = input ?? PosterStyle.videoInputs.first(where:{ !used.contains($0) }) else { NSSound.beep(); return }
        let edgeInput = PosterStyle.edgeInput(video:video)
        document.edit("Connect Video Layer") { graph in
            graph.edges.removeAll { $0.target == composerID && $0.input == edgeInput }
            try graph.connect(node,to:composerID,input:edgeInput)
        }
    }

    func box(_ element: PosterElement) -> PosterBox {
        PosterBox(center:CGPoint(x:element.x*poster.width,y:element.y*poster.height),size:PosterTextRenderer.boxSize(element,poster:poster),rotation:element.rotation)
    }
    func box(_ item: PosterItem) -> PosterBox? {
        guard case .element(let id) = item else { return nil }; return element(id).map(box)
    }
    var selectedElements: [PosterElement] { elements.filter { selection.contains(.element($0.id)) } }
    var single: PosterItem? { selection.count == 1 ? selection.first : nil }

    // MARK: Edits

    /// One undoable edit across the layout and the composer. The tagged
    /// text becomes a free layout only when an element actually changes.
    func change(_ action: String,_ fn: (inout [PosterElement],inout Node?) -> Void) {
        changeLayout(action) { layout,composer in fn(&layout.elements,&composer) }
    }
    func changeLayout(_ action: String,_ fn: (inout PosterLayout,inout Node?) -> Void) {
        let textID = textID, composerID = composerID
        document.edit(action) { graph in
            let textIndex = textID.flatMap { id in graph.nodes.firstIndex { $0.id == id } }
            var layout = textIndex.map { graph.nodes[$0].poster ?? PosterTextRenderer.autoLayout(graph.nodes[$0],dimensions:PosterStyle.dimensions(graph.nodes[$0])) } ?? PosterLayout()
            var composer = composerID.flatMap(graph.node)
            let before = layout
            fn(&layout,&composer)
            layout = layout.normalized()
            // The composer copy carries the old layout, so write it before the new one.
            if let composer,let index = graph.nodes.firstIndex(where:{ $0.id == composer.id }) { graph.nodes[index] = composer }
            if let textIndex,layout != before { graph.nodes[textIndex].poster = layout }
        }
    }
    /// Applies one change to every selected element.
    func updateSelection(_ action: String,_ fn: @escaping (inout PosterElement) -> Void) {
        let ids = Set(selectedElements.map(\.id))
        change(action) { elements,_ in for index in elements.indices where ids.contains(elements[index].id) { fn(&elements[index]) } }
    }

    // MARK: Groups

    func members(_ group: UUID) -> [PosterElement] { elements.filter { $0.group == group } }
    /// Clicking a grouped element on the poster takes its whole group.
    func expand(_ item: PosterItem) -> Set<PosterItem> {
        guard case .element(let id) = item,let group = element(id)?.group else { return [item] }
        return Set(members(group).map { .element($0.id) })
    }
    /// The group whose members are exactly the selection.
    var selectedGroup: PosterGroup? {
        guard let first = selectedElements.first?.group,let group = layout.group(first) else { return nil }
        return Set(members(first).map { PosterItem.element($0.id) }) == selection ? group : nil
    }
    @discardableResult func groupSelection(name: String? = nil) -> UUID? {
        let ids = Set(selectedElements.map(\.id))
        guard !ids.isEmpty else { NSSound.beep(); return nil }
        let group = PosterGroup(name:name ?? "Group \((layout.groups?.count ?? 0)+1)")
        changeLayout("Group") { layout,_ in
            layout.groups = (layout.groups ?? [])+[group]
            for index in layout.elements.indices where ids.contains(layout.elements[index].id) { layout.elements[index].group = group.id }
        }
        return group.id
    }
    /// Scales type so its widest line spans the margins, centered.
    func fitBetweenMargins(_ id: UUID) {
        guard let element = element(id),element.shape == .text else { return }
        let factor = (poster.width-2*margin)/max(1,box(element).size.width)
        update(id,action:"Fit Type") { $0.size *= factor; $0.x = 0.5 }
    }
    func fillPoster(_ id: UUID) {
        update(id,action:"Fill Poster") { $0.x = 0.5; $0.y = 0.5; $0.width = 1; $0.height = 1; $0.rotation = 0 }
    }
    /// Poster-wide at the source's proportions.
    func fitVideoWidth(_ id: UUID) {
        guard let element = element(id) else { return }
        let size = source(element).map { graph.videoDimensions($0.id) } ?? dimensions, poster = poster
        update(id,action:"Fit Video") { $0.x = 0.5; $0.width = 1; $0.height = poster.width*Double(size.height)/max(1,Double(size.width))/poster.height; $0.rotation = 0 }
    }
    func ungroupSelection() {
        let groups = Set(selectedElements.compactMap(\.group))
        guard !groups.isEmpty else { NSSound.beep(); return }
        changeLayout("Ungroup") { layout,_ in layout.groups?.removeAll { groups.contains($0.id) } }
    }
    func updateGroup(_ id: UUID,action: String,_ fn: @escaping (inout PosterGroup) -> Void) {
        changeLayout(action) { layout,_ in if let index = layout.groups?.firstIndex(where:{ $0.id == id }) { fn(&layout.groups![index]) } }
    }
    enum Row: Hashable { case group(UUID), item(PosterItem) }
    /// Layers' rows front to back: each group's folder above its members, hidden when collapsed.
    var rows: [Row] {
        var rows: [Row] = [], seen: Set<UUID> = []
        let layout = layout
        for item in stack {
            guard case .element(let id) = item,let group = layout.elements.first(where:{ $0.id == id })?.group,let folder = layout.group(group) else { rows.append(.item(item)); continue }
            if seen.insert(group).inserted { rows.append(.group(group)) }
            if !folder.collapsed { rows.append(.item(item)) }
        }
        return rows
    }
    /// Drag in Layers. A folder carries its members; a dropped element joins
    /// the folder it lands inside, or leaves it.
    func moveRows(from source: IndexSet,to destination: Int) {
        let layout = layout
        var rows = rows, moving = source
        for index in source { if case .group(let group) = rows[index] {
            for (offset,row) in rows.enumerated() where offset > index { if case .item(.element(let id)) = row,layout.elements.first(where:{ $0.id == id })?.group == group { moving.insert(offset) } }
        } }
        let moved = Set(moving.map { rows[$0] })
        rows.move(fromOffsets:moving,toOffset:destination)
        func groupOf(_ row: Row) -> UUID? {
            switch row {
            case .group(let id): return id
            case .item(.element(let id)): return layout.elements.first { $0.id == id }?.group
            }
        }
        var order: [PosterItem] = [], membership: [UUID:UUID?] = [:]
        for (index,row) in rows.enumerated() {
            switch row {
            case .group(let id):
                if layout.group(id)?.collapsed == true { order += members(id).reversed().map { .element($0.id) } }
            case .item(let item):
                order.append(item)
                guard case .element(let id) = item,moved.contains(row),!moved.contains(.group(groupOf(row) ?? UUID())) else { continue }
                let previous = index > 0 ? rows[index-1] : nil, next = index+1 < rows.count ? rows[index+1] : nil
                if case .group(let folder)? = previous { membership[id] = folder }
                else if let previous,let folder = groupOf(previous),next.flatMap(groupOf) == folder { membership[id] = folder }
                else { membership[id] = .some(nil) }
            }
        }
        restack("Reorder Layers",order,membership:membership)
    }
    func update(_ id: UUID,action: String,_ fn: @escaping (inout PosterElement) -> Void) {
        change(action) { elements,_ in if let index = elements.firstIndex(where:{ $0.id == id }) { fn(&elements[index]) } }
    }
    /// Moves an item so its center lands on `center` (poster pixels).
    static func place(_ item: PosterItem,center: CGPoint,poster: CGSize,elements: inout [PosterElement],composer: inout Node?) {
        guard case .element(let id) = item,let index = elements.firstIndex(where:{ $0.id == id }) else { return }
        elements[index].x = center.x/poster.width; elements[index].y = center.y/poster.height
    }
    func add(_ element: PosterElement) {
        guard textID != nil else { NSSound.beep(); return }
        change("Add \(element.shape.rawValue.capitalized)") { elements,_ in elements.append(element) }
        selection = [.element(element.id)]
    }
    func deleteSelection() {
        let ids = Set(selectedElements.map(\.id))
        guard !ids.isEmpty else { return }
        change("Delete") { elements,_ in elements.removeAll { ids.contains($0.id) } }
        selection.subtract(ids.map(PosterItem.element))
    }
    @discardableResult func duplicateSelection(offset: Double = 24) -> [UUID] {
        let copies = selectedElements.map { element -> PosterElement in
            var copy = element; copy.id = UUID(); copy.x += offset/poster.width; copy.y += offset/poster.height; return copy
        }
        guard !copies.isEmpty else { return [] }
        change("Duplicate") { elements,_ in elements.append(contentsOf:copies) }
        selection = Set(copies.map { .element($0.id) })
        return copies.map(\.id)
    }
    enum Arrange { case front, forward, backward, back }
    func arrange(_ arrange: Arrange) {
        let selected = selection
        var order = stack
        guard order.contains(where:{ selected.contains($0) }) else { return }
        // `order` is front to back, so forward means toward index 0.
        switch arrange {
        case .front: order = order.filter { selected.contains($0) }+order.filter { !selected.contains($0) }
        case .back: order = order.filter { !selected.contains($0) }+order.filter { selected.contains($0) }
        case .forward:
            for index in order.indices.dropFirst() where selected.contains(order[index]) && !selected.contains(order[index-1]) { order.swapAt(index,index-1) }
        case .backward:
            for index in order.indices.reversed().dropFirst() where selected.contains(order[index]) && !selected.contains(order[index+1]) { order.swapAt(index,index+1) }
        }
        restack("Arrange",order)
    }
    func nudge(_ dx: Double,_ dy: Double) {
        let items = selection, poster = poster
        let boxes = items.compactMap { item in box(item).map { (item,$0) } }
        change("Nudge") { elements,composer in
            for (item,box) in boxes { Self.place(item,center:CGPoint(x:box.center.x+dx,y:box.center.y+dy),poster:poster,elements:&elements,composer:&composer) }
        }
    }
    enum Edge { case left, centerX, right, top, centerY, bottom }
    /// Aligns to the selection's bounds, or to the poster for one item.
    func align(_ edge: Edge) {
        let boxes = selection.compactMap { item in box(item).map { (item,$0) } }
        guard !boxes.isEmpty else { return }
        let target = boxes.count > 1 ? boxes.map(\.1.bounds).reduce(boxes[0].1.bounds) { $0.union($1) } : CGRect(origin:.zero,size:poster)
        let poster = poster
        change("Align") { elements,composer in
            for (item,box) in boxes {
                let b = box.bounds
                var center = box.center
                switch edge {
                case .left: center.x += target.minX-b.minX
                case .centerX: center.x += target.midX-b.midX
                case .right: center.x += target.maxX-b.maxX
                case .top: center.y += target.minY-b.minY
                case .centerY: center.y += target.midY-b.midY
                case .bottom: center.y += target.maxY-b.maxY
                }
                Self.place(item,center:center,poster:poster,elements:&elements,composer:&composer)
            }
        }
    }
    /// Even spacing between centers, keeping the outermost two in place.
    func distribute(vertical: Bool) {
        var boxes = selection.compactMap { item in box(item).map { (item,$0) } }
        guard boxes.count > 2 else { return }
        boxes.sort { vertical ? $0.1.center.y < $1.1.center.y : $0.1.center.x < $1.1.center.x }
        let first = boxes.first!.1.center, last = boxes.last!.1.center, poster = poster
        change("Distribute") { elements,composer in
            for (index,(item,box)) in boxes.enumerated() {
                let t = Double(index)/Double(boxes.count-1)
                var center = box.center
                if vertical { center.y = first.y+(last.y-first.y)*t } else { center.x = first.x+(last.x-first.x)*t }
                Self.place(item,center:center,poster:poster,elements:&elements,composer:&composer)
            }
        }
    }
    func selectAll() { let layout = layout; selection = Set(elements.filter { !layout.isHidden($0) && !layout.isLocked($0) }.map { .element($0.id) }) }
    func copy() -> Bool {
        let selected = selectedElements
        guard !selected.isEmpty,let data = try? JSONEncoder().encode(selected) else { return false }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data,forType:Self.pasteboardType)
        return true
    }
    func paste() {
        guard let data = NSPasteboard.general.data(forType:Self.pasteboardType),let pasted = try? JSONDecoder().decode([PosterElement].self,from:data),!pasted.isEmpty,textID != nil else { NSSound.beep(); return }
        let copies = pasted.map { element -> PosterElement in var copy = element; copy.id = UUID(); copy.x += 0.02; copy.y += 0.015; return copy }
        change("Paste") { elements,_ in elements.append(contentsOf:copies) }
        selection = Set(copies.map { .element($0.id) })
    }
    /// Keeps both nodes at one size so type and paper line up.
    func setFormat(_ index: Int) {
        let ids = [composerID,textID].compactMap { $0 }
        document.edit("Change Poster Format") { graph in
            for id in ids { if let i = graph.nodes.firstIndex(where:{ $0.id == id }) { graph.nodes[i].parameters["format"] = Double(index) } }
        }
    }
    /// A full-poster image layer on top of the stack (or of the selection).
    func addImage(_ url: URL) {
        guard textID != nil else { NSSound.beep(); return }
        var element = PosterElement(shape:.image); element.file = url.path
        let above = selectedElements.compactMap { selected in layers.firstIndex { $0.id == selected.id } }.max()
        change("Add Image") { elements,_ in
            if let above,above < elements.count { elements.insert(element,at:above+1) } else { elements.append(element) }
        }
        selection = [.element(element.id)]
    }
}

struct PosterCanvas: NSViewRepresentable {
    @ObservedObject var model: PosterEditorModel
    @ObservedObject var workspace: Workspace
    func makeNSView(context: Context) -> PosterCanvasView { PosterCanvasView(model:model) }
    func updateNSView(_ view: PosterCanvasView,context: Context) { view.refresh() }
}

/// The live render with an editing overlay sized exactly to it.
final class PosterCanvasView: NSView {
    let model: PosterEditorModel
    let video: VideoView
    private(set) var overlay: PosterOverlay!
    var pan: CGPoint { get { model.pan } set { model.pan = newValue } }
    override var isFlipped: Bool { true }
    init(model: PosterEditorModel) {
        self.model = model
        video = VideoView(renderer:model.renderer)
        super.init(frame:.zero)
        wantsLayer = true; layer?.backgroundColor = NSColor(white:0.11,alpha:1).cgColor
        video.nodeID = model.previewID
        addSubview(video)
        overlay = PosterOverlay(canvas:self)
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Where the poster sits in this view.
    var posterRect: CGRect {
        let poster = model.poster, area = bounds.insetBy(dx:36,dy:36)
        guard area.width > 0,area.height > 0 else { return .zero }
        let fit = min(area.width/poster.width,area.height/poster.height)*model.zoom
        let size = CGSize(width:poster.width*fit,height:poster.height*fit)
        return CGRect(x:bounds.midX-size.width/2+pan.x,y:bounds.midY-size.height/2+pan.y,width:size.width,height:size.height).integral
    }
    override func layout() {
        super.layout()
        video.frame = posterRect; overlay.frame = bounds
    }
    func refresh() {
        if video.nodeID != model.previewID { video.nodeID = model.previewID }
        needsLayout = true; overlay.needsDisplay = true
    }
    func setZoom(_ zoom: Double,around point: CGPoint? = nil) {
        let focus = point ?? CGPoint(x:bounds.midX,y:bounds.midY)
        let next = max(0.25,min(3,zoom))
        // Keep the poster point under the focus fixed.
        let ratio = next/model.zoom
        pan.x = (pan.x-(focus.x-bounds.midX))*ratio+(focus.x-bounds.midX)
        pan.y = (pan.y-(focus.y-bounds.midY))*ratio+(focus.y-bounds.midY)
        model.zoom = next; refresh()
    }
}

/// Selection, handles, snapping and tools, drawn over the live render.
final class PosterOverlay: NSView {
    unowned let canvas: PosterCanvasView
    private var model: PosterEditorModel { canvas.model }
    private enum Drag {
        case move(start: CGPoint,boxes: [(PosterItem,PosterBox)])
        case resize(PosterItem,handle: Int,box: PosterBox,element: PosterElement?)
        case rotate(PosterItem,box: PosterBox,element: PosterElement?,start: Double)
        case marquee(start: CGPoint,base: Set<PosterItem>)
        case create(PosterTool,start: CGPoint)
    }
    private var drag: Drag?
    private var current = CGPoint.zero
    private var hover: PosterItem?
    private var guides: [(vertical: Bool,at: Double)] = []
    private var dragged = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(canvas: PosterCanvasView) {
        self.canvas = canvas
        super.init(frame:.zero)
        wantsLayer = true; layer?.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect,.cursorUpdate],owner:self))
    }

    // MARK: Coordinates

    private var scale: Double { let rect = canvas.posterRect; return rect.width/max(1,model.poster.width) }
    private func view(_ p: CGPoint) -> CGPoint { let rect = canvas.posterRect; return CGPoint(x:rect.minX+p.x*scale,y:rect.minY+p.y*scale) }
    private func poster(_ v: CGPoint) -> CGPoint { let rect = canvas.posterRect; return CGPoint(x:(v.x-rect.minX)/scale,y:(v.y-rect.minY)/scale) }
    private func point(_ event: NSEvent) -> CGPoint { poster(convert(event.locationInWindow,from:nil)) }

    // MARK: Hit testing

    /// Front to back: type and shapes first so they stay reachable under
    /// video, then video, then images, which often fill the poster.
    private func item(at p: CGPoint) -> PosterItem? {
        let slop = 4/scale, layout = model.layout, pickable = model.elements.reversed().filter { !layout.isHidden($0) && !layout.isLocked($0) }
        for element in pickable where element.shape != .image && element.shape != .video {
            if model.box(element).contains(p,slop:slop+(element.shape == .rule ? 4/scale : 0)) { return .element(element.id) }
        }
        if let video = pickable.first(where:{ $0.shape == .video && model.box($0).contains(p,slop:slop) }) { return .element(video.id) }
        return pickable.first { $0.shape == .image && model.box($0).contains(p,slop:0) }.map { .element($0.id) }
    }
    private func handles(_ item: PosterItem) -> [Int] {
        if case .element(let id) = item,let element = model.element(id) {
            switch element.shape { case .text: return [0,2,4,6]; case .rule: return [3,7]; default: return Array(0..<8) }
        }
        return [0,2,4,6]
    }
    private func rotationHandle(_ box: PosterBox) -> CGPoint { box.toWorld(CGPoint(x:0,y:-box.size.height/2-26/scale)) }
    private enum HandleHit { case resize(Int), rotate }
    private func handle(at p: CGPoint) -> (PosterItem,HandleHit)? {
        guard let item = model.single,let box = model.box(item) else { return nil }
        let reach = 7/scale
        if hypot(rotationHandle(box).x-p.x,rotationHandle(box).y-p.y) <= reach { return (item,.rotate) }
        for index in handles(item) {
            let h = box.handle(index)
            if abs(h.x-p.x) <= reach && abs(h.y-p.y) <= reach { return (item,.resize(index)) }
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event); current = p; dragged = false; guides = []
        if model.tool != .select {
            if model.tool == .text {
                var element = PosterElement(shape:.text,x:p.x/model.poster.width,y:p.y/model.poster.height)
                element.text = "Type"
                model.add(element); model.tool = .select; model.focusText = element.id
            } else { model.workspace.beginGesture(); drag = .create(model.tool,start:p) }
            needsDisplay = true; return
        }
        if let (item,hit) = handle(at:p),let box = model.box(item) {
            let element: PosterElement? = { if case .element(let id) = item { return model.element(id) }; return nil }()
            model.workspace.beginGesture()
            switch hit {
            case .resize(let index): drag = .resize(item,handle:index,box:box,element:element)
            case .rotate: drag = .rotate(item,box:box,element:element,start:atan2(p.y-box.center.y,p.x-box.center.x))
            }
            return
        }
        guard let hit = item(at:p) else {
            if !event.modifierFlags.contains(.shift) { model.selection = [] }
            drag = .marquee(start:p,base:model.selection); needsDisplay = true; return
        }
        // Double-click reaches inside a group (and into type's text).
        if event.clickCount == 2,case .element(let id) = hit {
            model.selection = [hit]
            if model.element(id)?.shape == .text { model.focusText = id }
            needsDisplay = true; return
        }
        let picked = model.expand(hit)
        if event.modifierFlags.contains(.shift) {
            if model.selection.contains(hit) { model.selection.subtract(picked); needsDisplay = true; return }
            model.selection.formUnion(picked)
        } else if !model.selection.contains(hit) { model.selection = picked }
        model.workspace.beginGesture()
        // Option-drag moves copies, leaving the originals behind.
        if event.modifierFlags.contains(.option) {
            model.duplicateSelection(offset:0)
        }
        drag = .move(start:p,boxes:model.selection.compactMap { item in model.box(item).map { (item,$0) } })
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let p = point(event); current = p; dragged = true
        let flags = event.modifierFlags, poster = model.poster
        switch drag {
        case .move(let start,let boxes):
            var dx = p.x-start.x, dy = p.y-start.y
            if flags.contains(.shift) { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            guides = []
            if !flags.contains(.command),let union = boxes.map(\.1.bounds).reduce(nil as CGRect?,{ $0?.union($1) ?? $1 }) {
                let moving = Set(boxes.map(\.0))
                let snapped = snap(union.offsetBy(dx:dx,dy:dy),excluding:moving)
                dx += snapped.dx; dy += snapped.dy
            }
            model.change("Move") { elements,composer in
                for (item,box) in boxes { PosterEditorModel.place(item,center:CGPoint(x:box.center.x+dx,y:box.center.y+dy),poster:poster,elements:&elements,composer:&composer) }
            }
        case .resize(let item,let handle,let box,let element):
            resize(item,handle:handle,box:box,element:element,to:p,flags:flags)
        case .rotate(let item,let box,let element,let start):
            var degrees = (element?.rotation ?? box.rotation)+(atan2(p.y-box.center.y,p.x-box.center.x)-start)*180/Double.pi
            if flags.contains(.shift) { degrees = (degrees/15).rounded()*15 }
            degrees = remainder(degrees,360)
            model.change("Rotate") { elements,_ in
                if case .element(let id) = item,let index = elements.firstIndex(where:{ $0.id == id }) { elements[index].rotation = degrees }
            }
        case .marquee(let start,let base):
            let rect = CGRect(x:min(start.x,p.x),y:min(start.y,p.y),width:abs(p.x-start.x),height:abs(p.y-start.y))
            // Images and video only when enclosed, so a full-bleed layer does not join every marquee.
            let layout = model.layout
            var hits = Set(model.elements.filter { !layout.isHidden($0) && !layout.isLocked($0) && ([.image,.video].contains($0.shape) ? rect.contains(model.box($0).bounds) : model.box($0).bounds.intersects(rect)) }.flatMap { model.expand(.element($0.id)) })
            model.selection = base.union(hits)
        case .create, nil: break
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .create(let tool,let start):
            if let element = created(tool,from:start,to:p,flags:event.modifierFlags,dragged:dragged) { model.add(element) }
            model.workspace.endGesture("Add \(tool.title)"); model.tool = .select
        case .move: model.workspace.endGesture(dragged ? "Move" : "Select")
        case .resize: model.workspace.endGesture("Resize")
        case .rotate: model.workspace.endGesture("Rotate")
        case .marquee, nil: break
        }
        drag = nil; guides = []; needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        let p = point(event), next = model.tool == .select && handle(at:p) == nil ? item(at:p) : nil
        if next != hover { hover = next; needsDisplay = true }
        cursor(at:p).set()
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func cursorUpdate(with event: NSEvent) { cursor(at:point(event)).set() }
    private func cursor(at p: CGPoint) -> NSCursor {
        switch model.tool {
        case .text: return .iBeam
        case .rule, .rectangle, .ellipse: return .crosshair
        case .select: return handle(at:p) != nil ? .crosshair : .arrow
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            canvas.setZoom(model.zoom*exp(-event.scrollingDeltaY*0.01),around:convert(event.locationInWindow,from:nil)); return
        }
        guard model.zoom > 1 else { return }
        canvas.pan.x += event.scrollingDeltaX; canvas.pan.y += event.scrollingDeltaY; canvas.refresh()
    }
    override func magnify(with event: NSEvent) {
        canvas.setZoom(model.zoom*(1+event.magnification),around:convert(event.locationInWindow,from:nil))
    }

    /// Scales about the opposite handle (or the center with Option). Type and
    /// video scale uniformly; shapes and images stretch unless Shift is held.
    private func resize(_ item: PosterItem,handle: Int,box: PosterBox,element: PosterElement?,to p: CGPoint,flags: NSEvent.ModifierFlags) {
        let unit = PosterBox.handleUnits[handle], half = CGSize(width:box.size.width/2,height:box.size.height/2)
        let fromCenter = flags.contains(.option)
        let anchor = fromCenter ? CGPoint.zero : CGPoint(x:-unit.x*half.width,y:-unit.y*half.height)
        let mouse = box.toLocal(p)
        let uniform = element.map { $0.shape == .text || ($0.shape == .video) != flags.contains(.shift) && $0.shape != .rule } ?? true
        let poster = model.poster
        var size = box.size, centerLocal = CGPoint.zero, factor = 1.0
        if uniform {
            let reference = CGPoint(x:unit.x*half.width-anchor.x,y:unit.y*half.height-anchor.y)
            let moved = CGPoint(x:mouse.x-anchor.x,y:mouse.y-anchor.y)
            factor = max(0.02,(moved.x*reference.x+moved.y*reference.y)/max(0.0001,reference.x*reference.x+reference.y*reference.y))
            size = CGSize(width:box.size.width*factor,height:box.size.height*factor)
            centerLocal = CGPoint(x:anchor.x*(1-factor),y:anchor.y*(1-factor))
        } else {
            if unit.x != 0 { size.width = max(2,fromCenter ? 2*abs(mouse.x) : abs(mouse.x-anchor.x)); centerLocal.x = fromCenter ? 0 : (anchor.x+mouse.x)/2 }
            if unit.y != 0 { size.height = max(2,fromCenter ? 2*abs(mouse.y) : abs(mouse.y-anchor.y)); centerLocal.y = fromCenter ? 0 : (anchor.y+mouse.y)/2 }
        }
        let center = box.toWorld(centerLocal)
        model.change("Resize") { elements,composer in
            guard case .element(let id) = item,let index = elements.firstIndex(where:{ $0.id == id }),let original = element else { return }
            switch original.shape {
            case .text: elements[index].size = max(0.002,original.size*factor)
            case .rule: elements[index].width = size.width/poster.width
            case .rectangle, .ellipse, .image, .video: elements[index].width = size.width/poster.width; elements[index].height = size.height/poster.height
            case .chrome: break
            }
            PosterEditorModel.place(item,center:center,poster:poster,elements:&elements,composer:&composer)
        }
    }
    private func created(_ tool: PosterTool,from start: CGPoint,to end: CGPoint,flags: NSEvent.ModifierFlags,dragged: Bool) -> PosterElement? {
        let poster = model.poster
        switch tool {
        case .rule:
            var dx = end.x-start.x, dy = end.y-start.y
            var angle = atan2(dy,dx)
            if flags.contains(.shift) { angle = (angle/(Double.pi/4)).rounded()*Double.pi/4 }
            let length = dragged ? hypot(dx,dy) : poster.width*0.4
            dx = cos(angle)*length; dy = sin(angle)*length
            let origin = dragged ? start : CGPoint(x:start.x-length/2,y:start.y)
            var element = PosterElement(shape:.rule,x:(origin.x+dx/2)/poster.width,y:(origin.y+dy/2)/poster.height)
            element.width = length/poster.width; element.rotation = dragged ? angle*180/Double.pi : 0
            return length > 2 ? element : nil
        case .rectangle, .ellipse:
            var w = abs(end.x-start.x), h = abs(end.y-start.y)
            if flags.contains(.shift) { w = max(w,h); h = w }
            if !dragged || w < 3 || h < 3 { w = poster.width*0.25; h = w }
            let center = flags.contains(.option) || !dragged ? start : CGPoint(x:start.x+(end.x >= start.x ? w : -w)/2,y:start.y+(end.y >= start.y ? h : -h)/2)
            var element = PosterElement(shape:tool == .rectangle ? .rectangle : .ellipse,x:center.x/poster.width,y:center.y/poster.height)
            element.width = (flags.contains(.option) && dragged ? 2*w : w)/poster.width; element.height = (flags.contains(.option) && dragged ? 2*h : h)/poster.height
            return element
        default: return nil
        }
    }

    /// Snaps a moving box's edges and center to the poster, its margins and the
    /// other items, and records the guides to draw.
    private func snap(_ rect: CGRect,excluding moving: Set<PosterItem>) -> (dx: Double,dy: Double) {
        let poster = model.poster, margin = model.margin, reach = 6/scale
        var xs = [0,margin,poster.width/2,poster.width-margin,poster.width], ys = [0,margin,poster.height/2,poster.height-margin,poster.height]
        var others = model.elements.filter { !$0.hidden && !moving.contains(.element($0.id)) }.map { model.box($0).bounds }
        for b in others { xs += [b.minX,b.midX,b.maxX]; ys += [b.minY,b.midY,b.maxY] }
        func best(_ edges: [Double],_ targets: [Double]) -> (offset: Double,at: Double)? {
            var found: (offset: Double,at: Double)?
            for edge in edges { for target in targets where abs(target-edge) <= reach && abs(target-edge) < abs(found?.offset ?? .infinity) { found = (target-edge,target) } }
            return found
        }
        let x = best([rect.minX,rect.midX,rect.maxX],xs), y = best([rect.minY,rect.midY,rect.maxY],ys)
        if let x { guides.append((true,x.at)) }
        if let y { guides.append((false,y.at)) }
        return (x?.offset ?? 0,y?.offset ?? 0)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command,.control,.option])
        let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch event.keyCode {
        case 51, 117: model.deleteSelection(); return
        case 123: model.nudge(-step,0); return
        case 124: model.nudge(step,0); return
        case 125: model.nudge(0,step); return
        case 126: model.nudge(0,-step); return
        case 53: if model.tool != .select { model.tool = .select } else { model.selection = [] }; needsDisplay = true; return
        case 36, 76:
            if case .element(let id) = model.single,model.element(id)?.shape == .text { model.focusText = id }
            return
        default: break
        }
        if flags.isEmpty,let key = event.charactersIgnoringModifiers?.lowercased(),let tool = PosterTool.allCases.first(where:{ $0.key == key }) { model.tool = tool; return }
        super.keyDown(with:event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with:event) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers {
        case "d": model.duplicateSelection(); return true
        case "g", "G": if shift { model.ungroupSelection() } else { model.groupSelection() }; return true
        case "]", "}": model.arrange(shift ? .front : .forward); return true
        case "[", "{": model.arrange(shift ? .back : .backward); return true
        case "=", "+": canvas.setZoom(model.zoom*1.25); return true
        case "-": canvas.setZoom(model.zoom/1.25); return true
        case "0": canvas.pan = .zero; canvas.setZoom(1); return true
        default: return super.performKeyEquivalent(with:event)
        }
    }
    @objc func copy(_ sender: Any?) { if !model.copy() { NSSound.beep() } }
    @objc func cut(_ sender: Any?) { if model.copy() { model.deleteSelection() } }
    @objc func paste(_ sender: Any?) { model.paste() }
    @objc override func selectAll(_ sender: Any?) { model.selectAll(); needsDisplay = true }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = canvas.posterRect, accent = NSColor.patchAccent.cgColor
        context.setStrokeColor(NSColor(white:1,alpha:0.12).cgColor); context.setLineWidth(1); context.stroke(rect.insetBy(dx:-0.5,dy:-0.5))
        if model.showGuides {
            let m = model.margin*scale
            context.setStrokeColor(NSColor.systemTeal.withAlphaComponent(0.28).cgColor)
            context.setLineDash(phase:0,lengths:[4,4]); context.stroke(rect.insetBy(dx:m,dy:m)); context.setLineDash(phase:0,lengths:[])
        }
        func outline(_ box: PosterBox,color: CGColor,width: Double = 1) {
            let points = box.corners.map(view)
            context.setStrokeColor(color); context.setLineWidth(width)
            context.addLines(between:points+[points[0]]); context.strokePath()
        }
        if let hover,!model.selection.contains(hover),let box = model.box(hover) { outline(box,color:NSColor.patchAccent.withAlphaComponent(0.55).cgColor) }
        for item in model.selection { if let box = model.box(item) { outline(box,color:accent,width:1.5) } }
        let moving: Bool = { if case .move = drag,dragged { return true }; return false }()
        if let item = model.single,let box = model.box(item),!moving {
            let top = view(box.toWorld(CGPoint(x:0,y:-box.size.height/2))), knob = view(rotationHandle(box))
            context.setStrokeColor(accent); context.setLineWidth(1)
            context.move(to:top); context.addLine(to:knob); context.strokePath()
            context.setFillColor(NSColor.white.cgColor); context.fillEllipse(in:CGRect(x:knob.x-4.5,y:knob.y-4.5,width:9,height:9))
            context.strokeEllipse(in:CGRect(x:knob.x-4.5,y:knob.y-4.5,width:9,height:9))
            for index in handles(item) {
                let h = view(box.handle(index)), square = CGRect(x:h.x-3.5,y:h.y-3.5,width:7,height:7)
                context.fill(square); context.stroke(square)
            }
        }
        if model.selection.count > 1 {
            let union = model.selection.compactMap { model.box($0)?.bounds }.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
            if let union {
                context.setStrokeColor(NSColor.patchAccent.withAlphaComponent(0.6).cgColor); context.setLineDash(phase:0,lengths:[3,3])
                context.stroke(CGRect(origin:view(union.origin),size:CGSize(width:union.width*scale,height:union.height*scale)))
                context.setLineDash(phase:0,lengths:[])
            }
        }
        context.setStrokeColor(NSColor.systemPink.cgColor); context.setLineWidth(1)
        for guide in guides {
            if guide.vertical { let x = view(CGPoint(x:guide.at,y:0)).x; context.move(to:CGPoint(x:x,y:rect.minY-12)); context.addLine(to:CGPoint(x:x,y:rect.maxY+12)) }
            else { let y = view(CGPoint(x:0,y:guide.at)).y; context.move(to:CGPoint(x:rect.minX-12,y:y)); context.addLine(to:CGPoint(x:rect.maxX+12,y:y)) }
        }
        context.strokePath()
        switch drag {
        case .marquee(let start,_), .create(_,let start):
            let a = view(start), b = view(current)
            let box = CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y))
            context.setFillColor(NSColor.patchAccent.withAlphaComponent(0.08).cgColor); context.fill(box)
            context.setStrokeColor(accent); context.setLineDash(phase:0,lengths:[4,3])
            if case .create(.rule,_) = drag { context.move(to:a); context.addLine(to:b); context.strokePath() }
            else if case .create(.ellipse,_) = drag { context.strokeEllipse(in:box) }
            else { context.stroke(box) }
            context.setLineDash(phase:0,lengths:[])
        default: break
        }
    }
}
