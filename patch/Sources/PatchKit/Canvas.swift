import AppKit
import Combine
import CoreText
import PatchCore

extension NSColor {
    static let patchBG = NSColor(calibratedRed: 0.082, green: 0.091, blue: 0.101, alpha: 1)
    static let patchPanel = NSColor(calibratedRed: 0.115, green: 0.126, blue: 0.14, alpha: 1)
    static let patchMuted = NSColor(calibratedRed: 0.49, green: 0.53, blue: 0.57, alpha: 1)
    static let patchAccent = NSColor(calibratedRed: 0.57, green: 0.83, blue: 0.66, alpha: 1)
    static let patchPublished = NSColor(calibratedRed: 0.98, green: 0.36, blue: 0.32, alpha: 1)
    static let patchPaused = NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.20, alpha: 1)
    static func node(_ kind: NodeKind) -> NSColor {
        if kind.isMIDINode { return NSColor(calibratedRed:0.65,green:0.72,blue:0.96,alpha:1) }
        if kind == .cellularField || kind == .streakField || kind == .waterfallField || kind == .streakGlow || kind == .blockerField || kind == .dataStream || kind == .lfo || kind == .noise { return NSColor(calibratedRed:0.76,green:0.58,blue:0.96,alpha:1) }
        if kind.isAudioNode || kind == .waveform || kind == .audioVisualizer || kind == .audioEnvelope { return NSColor(calibratedRed:0.90,green:0.78,blue:0.32,alpha:1) }
        if kind == .faceDetect || kind == .yoloPose { return NSColor(calibratedRed:0.95,green:0.55,blue:0.65,alpha:1) }
        if kind == .lorenz || kind == .vectorShape { return NSColor(calibratedRed: 0.69, green: 0.56, blue: 0.90, alpha: 1) }
        if kind == .render || kind == .voltageVisualizer || kind == .voltageFluid || kind == .oscilloscope || kind == .poseRender { return NSColor(calibratedRed: 0.89, green: 0.53, blue: 0.70, alpha: 1) }
        return kind.isOutput ? NSColor(calibratedRed: 0.88, green: 0.63, blue: 0.40, alpha: 1) : (kind.inputs.isEmpty ? NSColor(calibratedRed: 0.39, green: 0.68, blue: 0.83, alpha: 1) : .patchAccent)
    }
}
func drawText(_ text: String, _ rect: NSRect, size: CGFloat = 12, color: NSColor = .labelColor, weight: NSFont.Weight = .regular, mono: Bool = false) {
    guard rect.width > 0, rect.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
    let font = mono ? NSFont.monospacedSystemFont(ofSize:size,weight:weight) : NSFont.systemFont(ofSize:size,weight:weight)
    let ctFont = CTFontCreateWithName(font.fontName as CFString,size,nil)
    // Construct native Core Foundation attributes explicitly. Avoid a lazily
    // bridged Swift dictionary in NSString's CoreText drawing/copying path.
    let value = CFAttributedStringCreateMutable(nil,0)!
    CFAttributedStringReplaceString(value,CFRange(location:0,length:0),text as CFString)
    let range = CFRange(location:0,length:CFAttributedStringGetLength(value))
    CFAttributedStringSetAttribute(value,range,kCTFontAttributeName,ctFont)
    CFAttributedStringSetAttribute(value,range,kCTForegroundColorAttributeName,color.cgColor)
    let line = CTLineCreateWithAttributedString(value)
    context.saveGState()
    context.clip(to:rect)
    context.textMatrix = .identity
    context.translateBy(x:rect.minX,y:rect.minY+CTFontGetAscent(ctFont))
    context.scaleBy(x:1,y:-1)
    context.textPosition = .zero
    CTLineDraw(line,context)
    context.restoreGState()
}

private enum CanvasDrag {
    case nodes(UUID, NSPoint, Position)
    case cable(UUID, Bool, Int)
    case pan(NSPoint, NSPoint)
    case selection(NSPoint, Set<UUID>)
    case slice(NSPoint)
    case quickConnect(NSPoint)
}
private enum QuickEndpoint {
    case empty
    case body(UUID)
    case port(UUID, Bool, Int)
}
private struct QuickGesture { let start: NSPoint; let endpoint: QuickEndpoint }
private struct QuickConnection { let source: UUID; let target: UUID; let output: Int; let input: Int }
final class GraphCanvas: NSView {
    let workspace: Workspace
    let renderer: Renderer
    var zoom: CGFloat = 1
    var offset = NSPoint(x: 0, y: 70)
    var onViewportChange: (() -> Void)?
    private var observation: AnyCancellable?
    private var midiObservation: AnyCancellable?
    private var drag: CanvasDrag?
    private var quickGesture: QuickGesture?
    private var cursor = NSPoint.zero
    private var hoverEdge: UUID?
    private var hoverAPC: Int?
    private var selectedEdge: UUID?
    private var dragGraph: Graph?
    private var componentPreviews: [UUID:VideoView] = [:]
    var visibleNodes: [Node] { workspace.graph.nodes.filter { workspace.graph.collapsedOwner($0.id) == nil } }
    private var previews: [UUID: VideoView] = [:]
    private var outputButtons: [UUID:NSButton] = [:]
    private var pauseButtons: [UUID:NSButton] = [:]
    private var discardButtons: [UUID:NSButton] = [:]
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(workspace: Workspace, renderer: Renderer) {
        self.workspace = workspace; self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.patchBG.cgColor
        registerForDraggedTypes([.fileURL, .string])
        midiObservation = workspace.midi?.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.needsDisplay = true } }
        observation = workspace.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.sync(); self?.needsDisplay = true } }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    func world(_ p: NSPoint) -> NSPoint { .init(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom) }
    func screen(_ p: NSPoint) -> NSPoint { .init(x: p.x * zoom + offset.x, y: p.y * zoom + offset.y) }
    func rect(_ node: Node) -> NSRect { .init(x: node.position.x, y: node.position.y, width: node.canvasWidth, height: node.canvasHeight) }
    func componentRect(_ group: Component) -> NSRect {
        if !group.collapsed {
            let boxes = workspace.graph.nodes.filter { group.members.contains($0.id) }.map(rect)
            let bounds = boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
            return .init(x:bounds.minX-16,y:bounds.minY-36,width:bounds.width+32,height:bounds.height+52)
        }
        let count = max(workspace.graph.ports(group,output:false).count,workspace.graph.ports(group,output:true).count)
        return .init(x:group.position.x,y:group.position.y,width:250,height:max(224,Double(count)*25+155))
    }
    func componentPort(_ group: Component,output: Bool,index: Int) -> NSPoint {
        let r = componentRect(group)
        return .init(x:output ? r.maxX : r.minX,y:r.minY+51+Double(index)*25)
    }
    func modulationPort(_ node: Node,key: String) -> NSPoint {
        if let group = workspace.graph.collapsedOwner(node.id) { let r = componentRect(group); return .init(x:r.minX,y:r.maxY-14) }
        let index = (node.modulations ?? [:]).keys.sorted().firstIndex(of:key) ?? 0
        return .init(x:node.position.x,y:node.position.y+212+Double(max(0,node.portRows-2))*25+Double(index)*22)
    }
    func port(_ node: Node, output: Bool, input: Int = 0) -> NSPoint {
        if !output, input < 0 {
            let keys = (node.modulations ?? [:]).keys.sorted()
            if keys.indices.contains(-input-1) { return modulationPort(node,key:keys[-input-1]) }
        }
        if let group = workspace.graph.collapsedOwner(node.id), let i = workspace.graph.ports(group,output:output).firstIndex(where:{ $0.node == node.id && $0.input == input }) { return componentPort(group,output:output,index:i) }
        if node.kind == .apc40 && output { let r = apcControl(node,output:input); return .init(x:r.midX,y:r.midY) }
        return .init(x:node.position.x+(output ? node.canvasWidth : 0),y:node.position.y+51+Double(input)*25)
    }
    func slot(_ node: Node, output: Bool, input: Int = 0) -> NSRect {
        if node.kind == .apc40 && output { return apcControl(node,output:input) }
        let p = port(node,output:output,input:input)
        return .init(x:p.x-(output ? 70 : 0),y:p.y-10,width:70,height:20)
    }
    func hitPort(_ p: NSPoint) -> (UUID, Bool, Int)? {
        for group in workspace.graph.groups where group.collapsed {
            for out in [false,true] { for (i,port) in workspace.graph.ports(group,output:out).enumerated() {
                let anchor = componentPort(group,output:out,index:i)
                if NSRect(x:anchor.x-(out ? 112 : 0),y:anchor.y-12,width:112,height:24).contains(p) { return (port.node,out,port.input) }
            } }
        }
        for node in visibleNodes.reversed() {
            for i in node.kind.outputTypes.indices where slot(node,output:true,input:i).insetBy(dx:-4,dy:-4).contains(p) { return (node.id,true,i) }
            for i in node.inputs.indices where slot(node,output:false,input:i).insetBy(dx:-4,dy:-4).contains(p) { return (node.id,false,i) }
            for (i,key) in (node.modulations ?? [:]).keys.sorted().enumerated() {
                let anchor = modulationPort(node,key:key)
                if NSRect(x:anchor.x,y:anchor.y-9,width:180,height:18).contains(p) { return (node.id,false,-i-1) }
            }
        }
        return nil
    }
    private func quickEndpoint(_ p: NSPoint) -> QuickEndpoint {
        if let (id,output,index) = hitPort(p),index >= 0 { return .port(id,output,index) }
        if let node = visibleNodes.reversed().first(where:{ rect($0).contains(p) }) { return .body(node.id) }
        if let group = workspace.graph.groups.reversed().first(where:{ $0.collapsed && componentRect($0).contains(p) }) { return .body(group.id) }
        return .empty
    }
    private func quickPorts(_ endpoint: QuickEndpoint,output: Bool) -> [(UUID,Int)] {
        switch endpoint {
        case .empty: return []
        case let .port(id,isOutput,index): return output == isOutput ? [(id,index)] : []
        case let .body(id):
            if let node = workspace.graph.node(id) { return (output ? Array(node.kind.outputTypes.indices) : Array(node.inputs.indices)).map { (id,$0) } }
            if let group = workspace.graph.component(id) { return workspace.graph.ports(group,output:output).map { ($0.node,$0.input) } }
            return []
        }
    }
    private func quickConnections(_ start: QuickEndpoint,_ end: QuickEndpoint) -> [QuickConnection] {
        func matches(_ from: QuickEndpoint,_ into: QuickEndpoint) -> [QuickConnection] {
            var result: [QuickConnection] = []
            for (source,output) in quickPorts(from,output:true) {
                for (target,input) in quickPorts(into,output:false) {
                    guard source != target,let a = workspace.graph.node(source),let b = workspace.graph.node(target),
                          b.inputTypes[input].accepts(a.kind.outputType(at:output)) else { continue }
                    result.append(QuickConnection(source:source,target:target,output:output,input:input))
                }
            }
            return result
        }
        let forward = matches(start,end)
        return forward.isEmpty ? matches(end,start) : forward
    }
    private func beginQuickGesture() {
        guard drag == nil else { return }
        workspace.dismissLibraryPreview()
        let start = world(cursor),endpoint = quickEndpoint(start)
        quickGesture = QuickGesture(start:start,endpoint:endpoint)
        if case .empty = endpoint { drag = .slice(start) } else { drag = .quickConnect(start) }
        hoverEdge = nil; selectedEdge = nil; needsDisplay = true
    }
    func cancelQuickGesture() {
        guard quickGesture != nil else { return }
        quickGesture = nil; drag = nil; needsDisplay = true
    }
    private func cutConnections() {
        let edges = Set(workspace.graph.edges.filter { edge in cable(edge).map { sliceCrosses($0.0,$0.1) } ?? false }.map(\.id))
        let modulations = slicedModulations(),count = edges.count+modulations.count
        if count > 0 {
            workspace.edit("Slice Connections") { graph in
                graph.edges.removeAll { edges.contains($0.id) }
                for (id,key) in modulations {
                    if let i = graph.nodes.firstIndex(where:{ $0.id == id }) { graph.nodes[i].modulations?.removeValue(forKey:key) }
                }
            }
        }
        workspace.message = count > 0 ? "Cut \(count) connection\(count == 1 ? "" : "s") · ⌘Z to undo" : "No connections crossed"
    }
    private func finishQuickGesture(mouseReleased: Bool = false) {
        guard let gesture = quickGesture else { return }
        defer { cancelQuickGesture(); sync() }
        guard bounds.contains(cursor) else { return }
        let end = world(cursor),endpoint = quickEndpoint(end)
        if hypot(end.x-gesture.start.x,end.y-gesture.start.y)*zoom <= 3 {
            if mouseReleased,case let .body(id) = gesture.endpoint { workspace.select(id,extend:true) }
            return
        }
        if case .empty = gesture.endpoint,case .empty = endpoint { cutConnections(); return }
        let matches = quickConnections(gesture.endpoint,endpoint)
        guard matches.count == 1,let match = matches.first else {
            workspace.message = matches.isEmpty ? "No compatible connection" : "Multiple matching ports · start or end on a port"
            return
        }
        workspace.edit("Connect Nodes") { try $0.connect(match.source,to:match.target,input:match.input,output:match.output) }
    }
    /// Handles a Shift stroke even when a library button currently has keyboard focus.
    func handleQuickGesture(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        cursor = convert(window.mouseLocationOutsideOfEventStream,from:nil)
        let shiftOnly = event.modifierFlags.intersection([.shift,.command,.control,.option]) == [.shift]
        if event.type == .flagsChanged {
            if quickGesture != nil {
                if !event.modifierFlags.contains(.shift) { finishQuickGesture() }
                else if !shiftOnly { cancelQuickGesture() }
                return true
            }
            if shiftOnly,bounds.contains(cursor),drag == nil,!(window.firstResponder is NSTextView) { beginQuickGesture(); return true }
        } else if event.type == .leftMouseDown,shiftOnly,bounds.contains(cursor),quickGesture == nil {
            beginQuickGesture(); return true
        } else if quickGesture != nil {
            switch event.type {
            case .mouseMoved,.leftMouseDragged: needsDisplay = true; return true
            case .leftMouseDown: return true
            case .leftMouseUp: finishQuickGesture(mouseReleased:true); return true
            case .keyDown where event.keyCode == 53: cancelQuickGesture(); return true
            default: break
            }
        }
        return false
    }
    func cable(_ edge: Edge) -> (NSPoint, NSPoint)? {
        if let owner = workspace.graph.collapsedOwner(edge.source), owner.members.contains(edge.target) { return nil }
        guard let a = workspace.graph.node(edge.source), let b = workspace.graph.node(edge.target) else { return nil }
        return (port(a, output: true,input:edge.outputIndex), port(b, output: false, input: edge.input))
    }
    func controls(_ a: NSPoint, _ b: NSPoint) -> (NSPoint, NSPoint) {
        let span = max(65, abs(b.x - a.x) * 0.45)
        return (.init(x: a.x + span, y: a.y), .init(x: b.x - span, y: b.y))
    }
    private struct RouteKey: Hashable { let ax: CGFloat; let ay: CGFloat; let bx: CGFloat; let by: CGFloat }
    private var routeCache: [RouteKey:[NSPoint]] = [:]
    private var routeBoxes: [NSRect] = []
    func routePoints(_ a: NSPoint,_ b: NSPoint) -> [NSPoint] {
        let key = RouteKey(ax:a.x,ay:a.y,bx:b.x,by:b.y)
        if let cached = routeCache[key] { return cached }
        let corners = CableRouter.route(from:a,to:b,obstacles:routeBoxes)
        var points: [NSPoint] = [a]
        if corners.count > 2 {
            for i in 1..<(corners.count-1) {
                let before=corners[i-1],corner=corners[i],after=corners[i+1]
                let incoming=hypot(corner.x-before.x,corner.y-before.y),outgoing=hypot(after.x-corner.x,after.y-corner.y)
                let radius=min(8,min(incoming,outgoing)/2)
                let entry=NSPoint(x:corner.x+(before.x-corner.x)*radius/incoming,y:corner.y+(before.y-corner.y)*radius/incoming)
                let exit=NSPoint(x:corner.x+(after.x-corner.x)*radius/outgoing,y:corner.y+(after.y-corner.y)*radius/outgoing)
                points.append(entry)
                for step in 1...8 {
                    let t=CGFloat(step)/8,u=1-t
                    points.append(NSPoint(x:u*u*entry.x+2*u*t*corner.x+t*t*exit.x,y:u*u*entry.y+2*u*t*corner.y+t*t*exit.y))
                }
            }
        }
        points.append(b)
        if routeCache.count>2048 { routeCache.removeAll(keepingCapacity:true) }
        routeCache[key]=points; return points
    }
    func path(_ a: NSPoint, _ b: NSPoint) -> NSBezierPath {
        let p=NSBezierPath(); p.move(to:a)
        for point in routePoints(a,b).dropFirst() { p.line(to:point) }
        p.lineJoinStyle = .round; p.lineCapStyle = .round
        return p
    }
    // Intersect the cutter with a finely sampled version of the rendered Bézier.
    func sliceCrosses(_ a: NSPoint,_ b: NSPoint) -> Bool {
        guard case let .slice(start) = drag else { return false }
        let end = world(cursor)
        if quickGesture != nil { guard case .empty = quickEndpoint(end) else { return false } }
        guard hypot(end.x-start.x,end.y-start.y)*zoom > 3 else { return false }
        func cross(_ u: NSPoint,_ v: NSPoint) -> CGFloat { u.x*v.y-u.y*v.x }
        let r = NSPoint(x:end.x-start.x,y:end.y-start.y)
        var previous = a
        for next in routePoints(a,b).dropFirst() {
            let v = NSPoint(x:next.x-previous.x,y:next.y-previous.y), q = NSPoint(x:previous.x-start.x,y:previous.y-start.y)
            let denominator = cross(r,v)
            if abs(denominator)>0.000001 {
                let t = cross(q,v)/denominator, u = cross(q,r)/denominator
                if t>=0 && t<=1 && u>=0 && u<=1 { return true }
            }
            previous = next
        }
        return false
    }
    func slicedModulations() -> [(UUID,String)] {
        var result: [(UUID,String)] = []
        for node in workspace.graph.nodes {
            for (key,binding) in node.modulations ?? [:] {
                guard let source = workspace.graph.node(binding.source) else { continue }
                if let group = workspace.graph.collapsedOwner(source.id),group.members.contains(node.id) { continue }
                if sliceCrosses(port(source,output:true,input:binding.outputIndex),modulationPort(node,key:key)) { result.append((node.id,key)) }
            }
        }
        return result
    }
    func distance(_ point: NSPoint,to a: NSPoint,_ b: NSPoint) -> CGFloat {
        let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
        let t=length>0 ? max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/length)) : 0
        return hypot(point.x-a.x-t*dx,point.y-a.y-t*dy)
    }
    func hitCable(_ point: NSPoint, excluding node: UUID? = nil) -> UUID? {
        for e in workspace.graph.edges where e.source != node && e.target != node {
            guard let (a,b)=cable(e) else { continue }
            let points=routePoints(a,b)
            if zip(points,points.dropFirst()).contains(where:{ distance(point,to:$0.0,$0.1)<13/zoom }) { return e.id }
        }
        return nil
    }
    func insertionEdge(_ node: Node) -> UUID? {
        guard node.inputs.count == 1, node.kind.outputType == node.inputTypes.first,
              !workspace.graph.edges.contains(where:{ $0.source == node.id || $0.target == node.id }) else { return nil }
        let bounds = rect(node).insetBy(dx:-4,dy:-4)
        var best: (UUID,CGFloat)?
        for edge in workspace.graph.edges {
            guard workspace.graph.node(edge.source)?.kind.outputType(at:edge.outputIndex) == node.inputTypes.first, let (a,b) = cable(edge) else { continue }
            let points=routePoints(a,b)
            for (start,end) in zip(points,points.dropFirst()) {
                let length=hypot(end.x-start.x,end.y-start.y), steps=max(1,Int(length/8))
                for i in 0...steps {
                    let t=CGFloat(i)/CGFloat(steps),point=NSPoint(x:start.x+(end.x-start.x)*t,y:start.y+(end.y-start.y)*t)
                    if bounds.contains(point) {
                        let distance=hypot(point.x-bounds.midX,point.y-bounds.midY)
                        if best == nil || distance<best!.1 { best=(edge.id,distance) }
                    }
                }
            }
        }
        return best?.0
    }
    func sync() {
        // Only an unconnected effect being dragged is transparent to routing, so it can be inserted on a cable.
        var inserting: UUID?
        if case let .nodes(id,_,_) = drag, !workspace.graph.dependencies.contains(where:{ $0.source == id || $0.target == id }) { inserting=id }
        let boxes = visibleNodes.filter { $0.id != inserting }.map(rect)+workspace.graph.groups.filter(\.collapsed).map(componentRect)
        if boxes != routeBoxes { routeBoxes=boxes; routeCache.removeAll(keepingCapacity:true) }
        layer?.backgroundColor = (workspace.backdropEnabled ? NSColor.clear : NSColor.patchBG).cgColor
        let ids = Set(workspace.graph.nodes.map(\.id))
        for id in Array(previews.keys) where !ids.contains(id) { previews.removeValue(forKey: id)?.removeFromSuperview() }
        for id in Array(pauseButtons.keys) where !ids.contains(id) { pauseButtons.removeValue(forKey:id)?.removeFromSuperview() }
        for id in Array(outputButtons.keys) where ![NodeKind.window,.projector,.record,.recordAudio,.loopmother,.metroSequencer].contains(workspace.graph.node(id)?.kind ?? .pattern) { outputButtons.removeValue(forKey:id)?.removeFromSuperview() }
        for id in Array(discardButtons.keys) where ![.record,.recordAudio].contains(workspace.graph.node(id)?.kind) { discardButtons.removeValue(forKey:id)?.removeFromSuperview() }
        for node in workspace.graph.nodes {
            let pause = pauseButtons[node.id] ?? NSButton(title:"",target:self,action:#selector(toggleNodeEnabled(_:)))
            if pauseButtons[node.id] == nil {
                pause.identifier = NSUserInterfaceItemIdentifier(node.id.uuidString)
                pause.bezelStyle = .smallSquare; pause.imagePosition = .imageOnly
                pauseButtons[node.id] = pause; addSubview(pause)
            }
            let action = node.enabled ? "Pause" : "Resume"
            pause.image = NSImage(systemSymbolName:node.enabled ? "pause.fill" : "play.fill",accessibilityDescription:action)
            pause.contentTintColor = node.enabled ? .patchMuted : .patchPaused
            pause.toolTip = "\(action) \(node.name)" + (node.enabled && node.kind.bypassInput() != nil ? " · passes input through" : "")
            pause.setAccessibilityLabel("\(action) \(node.name)")
            pause.frame = NSRect(origin:screen(.init(x:node.position.x+node.canvasWidth-28,y:node.position.y+8)),size:.init(width:20*zoom,height:20*zoom))
            pause.isHidden = zoom < 0.4 || workspace.graph.collapsedOwner(node.id) != nil
            if node.kind == .record || node.kind == .recordAudio {
                let phase = renderer.recordingInfo(node.id)?.phase
                let button = discardButtons[node.id] ?? NSButton(title:"Discard",target:self,action:#selector(discardTake(_:)))
                if discardButtons[node.id] == nil {
                    button.identifier = NSUserInterfaceItemIdentifier(node.id.uuidString); button.bezelStyle = .smallSquare
                    button.toolTip = "Discard unsaved take"; button.setAccessibilityLabel("Discard take — \(node.name)")
                    discardButtons[node.id] = button; addSubview(button)
                }
                button.font = .systemFont(ofSize:max(8,10*zoom))
                button.frame = NSRect(origin:screen(.init(x:node.position.x+75,y:node.position.y+202)),size:.init(width:60*zoom,height:19*zoom))
                button.isHidden = !["ready","failed"].contains(phase ?? "") || zoom < 0.4 || workspace.graph.collapsedOwner(node.id) != nil
            }
            if node.kind == .window || node.kind == .projector || node.kind == .record || node.kind == .recordAudio || node.kind == .loopmother || node.kind == .metroSequencer {
                let button = outputButtons[node.id] ?? NSButton(title:"Open ↗",target:self,action:#selector(openNodeWindow(_:)))
                if outputButtons[node.id] == nil {
                    button.identifier = NSUserInterfaceItemIdentifier(node.id.uuidString); button.bezelStyle = .smallSquare
                    button.toolTip = [.loopmother,.metroSequencer].contains(node.kind) ? "Open instrument":"Open Video Window"; button.setAccessibilityLabel("Open — \(node.name)")
                    outputButtons[node.id] = button; addSubview(button)
                }
                if node.kind == .record || node.kind == .recordAudio {
                    let phase = renderer.recordingInfo(node.id)?.phase
                    button.title = phase == "recording" ? "■ Stop" : (phase == "finishing" ? "Wait…" : (phase == "ready" ? "Save…" : "● Rec"))
                    button.toolTip = node.kind.title; button.setAccessibilityLabel("\(button.title) — \(node.name)")
                    button.isEnabled = phase != "finishing"
                }
                button.font = .systemFont(ofSize:max(8,10*zoom))
                button.frame = NSRect(origin:screen(.init(x:node.position.x+140,y:node.position.y+202)),size:.init(width:62*zoom,height:19*zoom))
                button.isHidden = zoom < 0.4 || workspace.graph.collapsedOwner(node.id) != nil
            }
            if node.kind == .apc40 { previews.removeValue(forKey:node.id)?.removeFromSuperview(); continue }
            let view = previews[node.id] ?? VideoView(renderer: renderer)
            if previews[node.id] == nil { previews[node.id] = view; addSubview(view) }
            view.nodeID = node.id
            let origin = screen(.init(x: node.position.x + 12, y: node.position.y + 94 + Double(max(0,node.portRows-2))*25))
            view.frame = .init(origin: origin, size: .init(width: 186 * zoom, height: 105 * zoom))
            view.alphaValue = node.enabled ? 1 : 0.3
            // Keep on-screen previews visible at every zoom, including Frame All on large graphs.
            view.isHidden = workspace.graph.collapsedOwner(node.id) != nil || (node.kind.outputType == .geometry) || !bounds.intersects(view.frame)
        }
        for id in Array(componentPreviews.keys) where workspace.graph.component(id)?.collapsed != true { componentPreviews.removeValue(forKey:id)?.removeFromSuperview() }
        for group in workspace.graph.groups where group.collapsed {
            let view = componentPreviews[group.id] ?? VideoView(renderer:renderer)
            if componentPreviews[group.id] == nil { componentPreviews[group.id] = view; addSubview(view) }
            view.nodeID = workspace.graph.previewNode(group.id)?.id
            let r = componentRect(group)
            view.frame = .init(origin:screen(.init(x:r.minX+12,y:r.maxY-125)),size:.init(width:226*zoom,height:100*zoom))
            view.isHidden = !bounds.intersects(view.frame)
        }
        needsDisplay = true
    }
    override func layout() { super.layout(); sync() }
    func drawPreviews() { for preview in previews.values where !preview.isHidden { preview.draw() } }
    override func draw(_ dirtyRect: NSRect) {
        (workspace.backdropEnabled ? NSColor.black.withAlphaComponent(0.48) : NSColor.patchBG).setFill(); bounds.fill()
        let grid = 24 * zoom
        NSColor(white: 0.23, alpha: 0.6).setFill()
        if grid > 7 {
            for x in stride(from: offset.x.truncatingRemainder(dividingBy: grid), through: bounds.width, by: grid) {
                for y in stride(from: offset.y.truncatingRemainder(dividingBy: grid), through: bounds.height, by: grid) { NSRect(x: x, y: y, width: 1, height: 1).fill() }
            }
        }
        drawText("PATCH / GRAPH", .init(x: 24, y: 20, width: 240, height: 18), size: 10, color: .patchMuted, weight: .semibold, mono: true)
        if workspace.graph.nodes.isEmpty { drawText("⌘F to add a node  ·  Drop media here", .init(x: 24, y: 55, width: 500, height: 24), size: 16, color: .patchMuted) }
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: offset.x, byY: offset.y); (transform as NSAffineTransform).concat()
        let scale = NSAffineTransform(); scale.scale(by: zoom); scale.concat()
        for group in workspace.graph.groups { drawComponent(group) }
        for node in workspace.graph.nodes {
            for (key,binding) in node.modulations ?? [:] {
                guard let source = workspace.graph.node(binding.source) else { continue }
                if let group = workspace.graph.collapsedOwner(source.id),group.members.contains(node.id) { continue }
                let line = path(port(source,output:true,input:binding.outputIndex),modulationPort(node,key:key)); line.lineWidth = 1.5
                line.setLineDash([5,3],count:2,phase:0); (sliceCrosses(port(source,output:true,input:binding.outputIndex),modulationPort(node,key:key)) ? NSColor.systemRed : NSColor.node(.lfo).withAlphaComponent(binding.enabled ? 0.9 : 0.3)).setStroke(); line.stroke()
            }
        }
        for edge in workspace.graph.edges {
            guard let (a,b) = cable(edge) else { continue }
            let cutting = sliceCrosses(a,b)
            let highlight = cutting || hoverEdge == edge.id || selectedEdge == edge.id
            let p = path(a,b); p.lineWidth = highlight ? 3 : 2
            (cutting ? NSColor.systemRed : highlight ? NSColor.patchAccent : (workspace.graph.node(edge.source)?.kind.outputType(at:edge.outputIndex) == .midi ? NSColor.node(.arpeggiator) : workspace.graph.node(edge.source)?.kind.outputType(at:edge.outputIndex) == .palette ? NSColor.systemPink : workspace.graph.node(edge.source)?.kind.outputType(at:edge.outputIndex) == .field ? NSColor.node(.dataStream) : workspace.graph.node(edge.source)?.kind.outputType(at:edge.outputIndex) == .audio ? NSColor.node(.audio) : workspace.graph.node(edge.source)?.kind.outputType(at:edge.outputIndex) == .poses ? NSColor.node(.yoloPose) : workspace.graph.node(edge.source)?.kind.outputType(at:edge.outputIndex) == .faces ? NSColor.node(.faceDetect) : workspace.graph.node(edge.source)?.kind.outputType(at:edge.outputIndex) == .geometry ? NSColor.node(.lorenz) : NSColor(calibratedRed: 0.37, green: 0.57, blue: 0.60, alpha: 1))).setStroke(); p.stroke()
            if hoverEdge == edge.id { let points=routePoints(a,b); let c = points[points.count/2]; NSColor.patchAccent.setFill(); NSBezierPath(ovalIn: .init(x:c.x-4,y:c.y-4,width:8,height:8)).fill() }
        }
        if case let .cable(id, output, input) = drag, let node = workspace.graph.node(id) {
            let anchor = port(node, output: output, input: input), p = output ? path(anchor, world(cursor)) : path(world(cursor), anchor)
            NSColor.patchAccent.setStroke(); p.lineWidth = 2; p.setLineDash([5,4], count: 2, phase: 0); p.stroke()
        }
        let hover = hitPort(world(cursor))
        let publishedNodes = Set(workspace.graph.publishablePorts.filter { $0.listed && workspace.graph.node($0.nodeID)?.publishesAutomatically == false }.map(\.nodeID))
        for node in visibleNodes {
            if node.kind == .apc40 {
                drawAPC40(node,selected:workspace.selectedIDs.contains(node.id),hover:hover.flatMap { $0.0 == node.id && $0.1 ? $0.2 : nil })
                continue
            }
            // Nodes published by hand (⌘S) are tinted so they stand out from the rest of the graph.
            let published = publishedNodes.contains(node.id)
            // Paused nodes are amber with a dashed border and a pause mark; that outranks the published tint.
            let paused = !node.enabled, marked = published || paused
            let r = rect(node), selected = workspace.selectedIDs.contains(node.id), color = paused ? NSColor.patchPaused : published ? NSColor.patchPublished : NSColor.node(node.kind)
            (marked ? NSColor.patchPanel.blended(withFraction:0.2,of:color) ?? .patchPanel : NSColor.patchPanel).setFill(); NSBezierPath(roundedRect: r, xRadius: 0, yRadius: 0).fill()
            (selected || marked ? color : NSColor(white: 0.25, alpha: 1)).setStroke()
            let border = NSBezierPath(roundedRect: r.insetBy(dx:0.5,dy:0.5), xRadius:0,yRadius:0); border.lineWidth = selected ? (marked ? 3 : 1.8) : (marked ? 1.8 : 1)
            if paused { border.setLineDash([6,4],count:2,phase:0) }
            border.stroke()
            color.setFill()
            if paused { for x in [r.minX+10,r.minX+15] { NSRect(x:x,y:r.minY+13,width:3,height:10).fill() } }
            else { NSBezierPath(roundedRect: .init(x:r.minX+11,y:r.minY+13,width:5,height:10),xRadius:0,yRadius:0).fill() }
            drawText(node.name, .init(x:r.minX+24,y:r.minY+9,width:154,height:20), size:12, color: node.enabled ? .labelColor : .patchMuted, weight:.medium)
            drawText(node.enabled ? node.kind.category + " / " + node.kind.rawValue.uppercased() : node.kind.pausedStatus.uppercased(), .init(x:r.minX+12,y:r.maxY-19,width:[.record,.recordAudio].contains(node.kind) && ["ready","failed"].contains(renderer.recordingInfo(node.id)?.phase ?? "") ? 58 : ((node.kind == .window || node.kind == .projector || node.kind == .record || node.kind == .recordAudio) ? 122 : 180),height:16),size:8,color:.patchMuted,mono:true)
            if node.kind.outputType == .geometry {
                drawText("∿", .init(x:r.minX+70,y:r.minY+94,width:90,height:68),size:62,color:color,weight:.ultraLight)
                drawText(node.kind == .audio ? "AUDIO / PCM" : "\(Int(node.value("points"))) VERTICES", .init(x:r.minX+45,y:r.minY+177,width:140,height:16),size:9,color:.patchMuted,mono:true)
            }
            for key in (node.modulations ?? [:]).keys.sorted() {
                let p = modulationPort(node,key:key), color = NSColor.node(.lfo)
                let slot = NSRect(x:p.x,y:p.y-9,width:180,height:18)
                color.withAlphaComponent(0.12).setFill(); slot.fill(); color.setStroke(); NSBezierPath(rect:slot).stroke()
                let name = node.parameterSpecs.first(where:{ $0.key == key })?.title ?? key
                drawText("∿ "+name,.init(x:p.x+6,y:p.y-6,width:168,height:14),size:9,color:color)
            }
            let allPorts = node.inputs.indices.map { (false,$0) } + node.kind.outputTypes.indices.map { (true,$0) }
            for (out,i) in allPorts {
                let p = port(node,output:out,input:i)
                let slotRect = slot(node,output:out,input:i)
                let type = out ? node.kind.outputTypes[i] : node.inputTypes[i]
                let portColor = type == .midi ? NSColor.node(.arpeggiator) : type == .palette ? NSColor.systemPink : (type == .control || type == .drawRate) ? NSColor.node(.lfo) : type == .poses ? NSColor.node(.yoloPose) : type == .faces ? NSColor.node(.faceDetect) : type == .audio ? NSColor.node(.audio) : (type == .geometry || type == .vectorPath) ? NSColor.node(.lorenz) : NSColor(calibratedRed:0.39,green:0.68,blue:0.83,alpha:1)
                let connected = out ? (workspace.graph.edges.contains { $0.source == node.id && $0.outputIndex == i } || workspace.graph.nodes.contains { ($0.modulations ?? [:]).values.contains { $0.source == node.id && $0.outputIndex == i } }) : workspace.graph.edges.contains { $0.target == node.id && $0.input == i }
                portColor.withAlphaComponent(connected ? 0.20 : 0.06).setFill(); slotRect.fill()
                if node.kind == .apc40, let value = renderer.apcState.snapshot[i] {
                    portColor.withAlphaComponent(0.35).setFill()
                    NSRect(x:slotRect.minX,y:slotRect.maxY-2,width:slotRect.width*value,height:2).fill()
                }
                portColor.withAlphaComponent(0.7).setStroke(); let outline = NSBezierPath(rect:slotRect.insetBy(dx:0.5,dy:0.5)); outline.lineWidth = 0.7; outline.stroke()
                let label = node.kind == .apc40 ? node.kind.outputs[i].uppercased() : type == .midi ? (node.kind == .metroSequencer && out ? ["MIDI A","MIDI B","MIDI A+B"][i] : (out ? node.kind.outputs[i]:node.inputs[i]).uppercased()) : type == .rgbProfiles ? "RGB × XY" : type == .chromaReference ? "FRAME REF" : node.kind == .chromaEncoder && out && i == 0 ? (node.value("channel")<0.5 ? "COLOR AUDIO · L":"COLOR AUDIO · R") : type == .vectorPath ? "PATH" : type == .drawRate ? "DRAW Hz" : type == .visual ? "LAYER \(i+1)" : (node.kind == .faceReplace || node.kind == .audioMix) && !out ? node.inputs[i].uppercased() : type == .trace ? "TRACE" : type == .collection ? "COLLECTION" : type == .palette ? "PALETTE" : type == .dots ? "DOTS" : type == .control ? "CONTROL" : type == .poses ? "POSES" : type == .faces ? "FACES" : type == .audio ? (out ? node.kind.outputs[i]:node.inputs[i]).uppercased() : type == .geometry ? "GEOMETRY" : (node.kind == .mux && !out ? "VIDEO \(i+1)" : (node.kind == .blend && !out ? "\(node.inputs[i]) · VIDEO" : "VIDEO"))
                drawText(label,.init(x:slotRect.minX+8,y:slotRect.minY+4,width:slotRect.width-12,height:13),size:8,color:portColor,weight:.medium,mono:true)
                portColor.setFill(); NSRect(x:p.x-2,y:p.y-5,width:4,height:10).fill()
            }
        }
        if case let .slice(start) = drag {
            let line = NSBezierPath(); line.move(to:start); line.line(to:world(cursor))
            line.lineWidth = 2/zoom; line.setLineDash([6/zoom,4/zoom],count:2,phase:0)
            NSColor.systemRed.setStroke(); line.stroke()
        }
        if case let .quickConnect(start) = drag,let gesture = quickGesture {
            let end = world(cursor),matches = quickConnections(gesture.endpoint,quickEndpoint(end))
            let line = NSBezierPath(); line.move(to:start); line.line(to:end)
            line.lineWidth = 2/zoom; line.setLineDash([6/zoom,4/zoom],count:2,phase:0)
            (matches.count > 1 ? NSColor.systemOrange : NSColor.patchAccent).setStroke(); line.stroke()
        }
        if case let .selection(start,_) = drag {
            let box = selectionRect(from:start)
            NSColor.patchAccent.withAlphaComponent(0.12).setFill(); box.fill()
            NSColor.patchAccent.setStroke()
            let outline = NSBezierPath(rect:box); outline.lineWidth = 1/zoom; outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        if case .slice = drag {
            let count = workspace.graph.edges.filter { edge in cable(edge).map { sliceCrosses($0.0,$0.1) } ?? false }.count+slicedModulations().count
            drawText("Slice: \(count) connection\(count == 1 ? "" : "s") · Release Shift to cut · Esc cancels",.init(x:24,y:42,width:540,height:20),size:11,color:.systemRed)
        } else if let gesture = quickGesture {
            let matches = quickConnections(gesture.endpoint,quickEndpoint(world(cursor)))
            drawText(matches.count > 1 ? "Multiple matching ports · aim at a port to choose" : "Release Shift to connect · Esc cancels",.init(x:24,y:42,width:540,height:20),size:11,color:matches.count > 1 ? .systemOrange : .patchAccent)
        }
    }
    func drawComponent(_ group: Component) {
        let r = componentRect(group)
        NSColor.patchPanel.withAlphaComponent(group.collapsed ? 1 : 0.3).setFill(); r.fill()
        (workspace.selectedIDs.contains(group.id) ? NSColor.patchAccent : NSColor.patchMuted).setStroke(); NSBezierPath(rect:r).stroke()
        drawText((group.collapsed ? "▸ " : "▾ ")+group.name,.init(x:r.minX+12,y:r.minY+9,width:r.width-24,height:20),size:12,weight:.medium)
        guard group.collapsed else { return }
        drawText("COMPONENT · \(group.members.count) NODES",.init(x:r.minX+12,y:r.maxY-18,width:r.width-24,height:16),size:9,color:.patchMuted,mono:true)
        for out in [false,true] {
            for (i,port) in workspace.graph.ports(group,output:out).enumerated() {
                let p = componentPort(group,output:out,index:i)
                let slot = NSRect(x:p.x-(out ? 112 : 0),y:p.y-10,width:112,height:20)
                let color = NSColor.node(port.type == .control ? .lfo : port.type == .poses ? .yoloPose : port.type == .faces ? .faceDetect : port.type == .geometry ? .lorenz : (port.type == .audio ? .audio : .image))
                color.withAlphaComponent(0.16).setFill(); slot.fill(); color.setStroke(); NSBezierPath(rect:slot).stroke()
                drawText(port.name,.init(x:slot.minX+4,y:slot.minY+4,width:104,height:14),size:8,color:color)
            }
        }
    }
    @objc func toggleNodeEnabled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,let id = UUID(uuidString:raw),let node = workspace.graph.node(id) else { return }
        workspace.edit(node.enabled ? "Pause Node" : "Resume Node") { graph in
            if let i = graph.nodes.firstIndex(where:{ $0.id == id }) { graph.nodes[i].enabled.toggle() }
        }
        sync(); needsDisplay = true
    }
    @objc func discardTake(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,let id = UUID(uuidString:raw) else { return }
        workspace.onDiscardRecording?(id)
    }
    @objc func openNodeWindow(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString:raw) else { return }
        if [.record,.recordAudio].contains(workspace.graph.node(id)?.kind) { workspace.onRecord?(id) } else { workspace.onOpenOutput?(id) }
    }
    override func selectAll(_ sender: Any?) { contextSelectAll() }
    @objc func copy(_ sender: Any?) { workspace.copyNode() }
    @objc func paste(_ sender: Any?) { workspace.pasteNode(at:insertionPoint) }
    @objc func cut(_ sender: Any?) { if workspace.copyNode() { workspace.deleteSelection() } }
    override func mouseDown(with event: NSEvent) {
        workspace.dismissLibraryPreview()
        if event.modifierFlags.contains(.control) { rightMouseDown(with:event); return }
        window?.makeFirstResponder(self); cursor = convert(event.locationInWindow, from: nil); let p = world(cursor)
        if let (id,out,input) = hitPort(p) {
            if event.modifierFlags.contains(.option), !out {
                workspace.edit("Disconnect") { graph in
                    if input < 0,let i = graph.nodes.firstIndex(where:{ $0.id == id }) {
                        let keys = (graph.nodes[i].modulations ?? [:]).keys.sorted()
                        if keys.indices.contains(-input-1) { graph.nodes[i].modulations?.removeValue(forKey:keys[-input-1]) }
                    } else { graph.edges.removeAll { $0.target == id && $0.input == input } }
                }; return
            }
            drag = .cable(id,out,input); return
        }
        if let group = workspace.graph.groups.reversed().first(where:{ g in let r = componentRect(g); return (g.collapsed ? r : NSRect(x:r.minX,y:r.minY,width:r.width,height:30)).contains(p) }) {
            if event.modifierFlags.contains(.command) {
                workspace.select(group.id,extend:true); selectedEdge = nil; needsDisplay = true; return
            }
            if event.modifierFlags.contains(.shift) { workspace.select(group.id,extend:true) } else { workspace.focusSelection(group.id) }; selectedEdge = nil
            if event.clickCount == 2 { workspace.toggleComponent(group.id); return }
            dragGraph = workspace.graph; workspace.beginGesture(); drag = .nodes(group.id,p,group.position)
        } else if let node = visibleNodes.reversed().first(where:{ rect($0).contains(p) }) {
            if event.modifierFlags.contains(.command) {
                workspace.select(node.id,extend:true); selectedEdge = nil; needsDisplay = true; return
            }
            if event.modifierFlags.contains(.shift) { workspace.select(node.id,extend:true) }
            else { workspace.focusSelection(node.id) }
            selectedEdge = nil
            if event.clickCount == 2 {
                if let edge = insertionEdge(node) { workspace.edit("Insert Node") { try $0.insert(node.id,on:edge) } }
                else if NodeApp.for(node) != nil { workspace.onPinnedPreview?(node.id) }
                else if node.kind == .audioPlugin { workspace.onInspect?(node.id); workspace.plugins.openEditor(node.id) }
                else { workspace.onInspect?(node.id) }
                return
            }
            dragGraph = workspace.graph; workspace.beginGesture(); drag = .nodes(node.id,p,node.position)
        } else {
            if event.modifierFlags.contains(.command) {
                selectedEdge = nil; drag = .selection(p,workspace.selectedIDs)
            } else {
                selectedEdge = hitCable(p); workspace.selected = nil; drag = .pan(cursor,offset)
            }
        }
        needsDisplay = true
    }
    private func selectionRect(from start: NSPoint) -> NSRect {
        let end = world(cursor)
        return NSRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y))
    }
    private func updateBoxSelection(from start: NSPoint, initial: Set<UUID>) {
        let box = selectionRect(from:start)
        let nodes = visibleNodes.filter { box.intersects(rect($0)) }.map(\.id)
        let groups = workspace.graph.groups.filter { group in
            let r = componentRect(group)
            return box.intersects(group.collapsed ? r : NSRect(x:r.minX,y:r.minY,width:r.width,height:30))
        }.map(\.id)
        workspace.selectAll(initial.union(nodes).union(groups).sorted { $0.uuidString < $1.uuidString })
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from:nil)
        switch drag {
        case let .selection(start,initial): updateBoxSelection(from:start,initial:initial)
        case let .nodes(id,start,_):
            let p = world(cursor)
            if let original = dragGraph {
                let selected = workspace.selectedIDs
                let moving = selected.union(original.groups.filter { selected.contains($0.id) }.flatMap(\.members))
                workspace.edit("Move Selection") { g in
                    for i in g.nodes.indices where moving.contains(g.nodes[i].id) {
                        if let old = original.node(g.nodes[i].id) { g.nodes[i].position = .init(old.position.x+p.x-start.x,old.position.y+p.y-start.y) }
                    }
                    for i in (g.components ?? []).indices where selected.contains(g.components![i].id) {
                        if let old = original.component(g.components![i].id) { g.components![i].position = .init(old.position.x+p.x-start.x,old.position.y+p.y-start.y) }
                    }
                }
            }
            if workspace.selectedIDs.count == 1, let node = workspace.graph.node(id) { hoverEdge = insertionEdge(node) }
            sync()
        case let .pan(start,original): offset = .init(x: original.x+cursor.x-start.x,y:original.y+cursor.y-start.y); sync(); onViewportChange?()
        default: needsDisplay = true
        }
    }
    override func mouseUp(with event: NSEvent) {
        cursor = convert(event.locationInWindow,from:nil)
        let p = world(cursor)
        switch drag {
        case let .selection(start,initial): updateBoxSelection(from:start,initial:initial)
        case .slice:
            cutConnections()
        case let .cable(id,out,input):
            if out,case let (other,false,index)? = hitPort(p),index >= 0,workspace.graph.node(other)?.inputTypes[index] == .control {
                workspace.edit("Connect Control") { try $0.connect(id,to:other,input:index,output:input) }
            } else if out,workspace.graph.node(id)?.kind.outputType(at:input) == .control,let target = visibleNodes.reversed().first(where:{ rect($0).contains(p) }),target.id != id {
                if let (_,_,portIndex) = hitPort(p),portIndex < 0 {
                    let keys = (target.modulations ?? [:]).keys.sorted()
                    if keys.indices.contains(-portIndex-1) { connectModulation(source:id,target:target.id,key:keys[-portIndex-1],output:input) }
                } else { modulationMenu(source:id,target:target,event:event,output:input) }
            } else if !out,input < 0,case let (source,true,sourceOutput)? = hitPort(p),workspace.graph.node(source)?.kind.outputType == .control,let target = workspace.graph.node(id) {
                let keys = (target.modulations ?? [:]).keys.sorted()
                if keys.indices.contains(-input-1) { connectModulation(source:source,target:id,key:keys[-input-1],output:sourceOutput) }
            } else if let (other,otherOut,otherInput) = hitPort(p), otherOut != out {
                workspace.edit("Connect Nodes") { try $0.connect(out ? id : other, to:out ? other : id,input:out ? otherInput : input,output:out ? input : otherInput) }
            }
        case let .nodes(id,_,_):
            if let hoverEdge { workspace.edit("Insert Node") { try $0.insert(id,on:hoverEdge) } }
            workspace.endGesture("Move Node")
        default: break
        }
        drag = nil; hoverEdge = nil; sync(); needsDisplay = true
    }
    func connectModulation(source: UUID,target: UUID,key: String,output: Int = 0) {
        let old = workspace.graph.node(target)?.modulations?[key]
        workspace.edit("Connect Modulation") { try $0.modulate(target,key:key,source:source,minimum:old?.minimum,maximum:old?.maximum,output:output) }
    }
    func modulationMenu(source: UUID,target: Node,event: NSEvent,output: Int) {
        let menu = NSMenu(); menu.autoenablesItems = false
        for spec in target.modulationSpecs {
            let item = NSMenuItem(title:spec.title,action:#selector(chooseModulation(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = ["source":source.uuidString,"target":target.id.uuidString,"key":spec.key,"output":String(output)]; menu.addItem(item)
        }
        if menu.items.isEmpty { let item = NSMenuItem(title:"No continuous parameters",action:nil,keyEquivalent:""); item.isEnabled = false; menu.addItem(item) }
        drag = nil; needsDisplay = true
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc func chooseModulation(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String:String],let source = data["source"].flatMap(UUID.init(uuidString:)),let target = data["target"].flatMap(UUID.init(uuidString:)),let key = data["key"] else { return }
        connectModulation(source:source,target:target,key:key,output:Int(data["output"] ?? "0") ?? 0)
    }
    override func rightMouseDown(with event: NSEvent) {
        workspace.dismissLibraryPreview()
        window?.makeFirstResponder(self)
        cursor = convert(event.locationInWindow,from:nil); let p = world(cursor)
        if let node = visibleNodes.reversed().first(where:{ rect($0).contains(p) }) { workspace.focusSelection(node.id) }
        else if let group = workspace.graph.groups.reversed().first(where:{ componentRect($0).contains(p) }) { workspace.focusSelection(group.id) }
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String,_ action: Selector,_ enabled: Bool = true) {
            let i = NSMenuItem(title:title,action:action,keyEquivalent:""); i.target = self; i.isEnabled = enabled; menu.addItem(i)
        }
        let hasSelection = !workspace.selectedIDs.isEmpty
        item(workspace.previewVisible ? "Close Preview" : "Preview",#selector(contextPreview),hasSelection)
        if workspace.selected.flatMap({ workspace.graph.node($0)?.kind }) == .apc40 { item("Pop out APC40",#selector(contextAPCWindow)) }
        if let app = workspace.selected.flatMap({ workspace.graph.node($0) }).flatMap(NodeApp.for) { item("Open \(app.title)",#selector(contextPinPreview)) }
        item("Keep Preview Open",#selector(contextPinPreview),hasSelection)
        item("Copy",#selector(copy(_:)),workspace.graph.node(workspace.selected ?? UUID()) != nil)
        item("Duplicate",#selector(contextDuplicate),workspace.graph.node(workspace.selected ?? UUID()) != nil)
        item("Delete",#selector(contextDelete),hasSelection)
        menu.addItem(.separator())
        item("Add Node…",#selector(contextAdd))
        item("Paste",#selector(paste(_:)),NSPasteboard.general.data(forType:Workspace.nodePasteboardType) != nil)
        item("Select All",#selector(contextSelectAll))
        item("Frame Whole Graph",#selector(contextFrame))
        item("Auto Layout",#selector(contextLayout))
        menu.addItem(.separator())
        item("Create Component",#selector(contextComponent),workspace.selectedIDs.count > 1)
        let group = workspace.selected.flatMap { workspace.graph.component($0) }
        item(group?.collapsed == true ? "Expand Component" : "Collapse Component",#selector(contextToggle),group != nil)
        item("Ungroup Component",#selector(contextUngroup),group != nil)
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc private func contextDelete() { workspace.deleteSelection() }
    @objc private func contextDuplicate() { workspace.duplicate() }
    @objc private func contextAPCWindow() { if let id = workspace.selected { workspace.onAPCWindow?(id) } }
    @objc private func contextPinPreview() { if let id=workspace.graph.previewNode(workspace.selected)?.id { workspace.onPinnedPreview?(id) } }
    @objc private func contextPreview() { workspace.onPreview?() }
    @objc private func contextAdd() { workspace.onPalette?(insertionPoint) }
    @objc private func contextSelectAll() { workspace.selectAll(visibleNodes.map(\.id)+workspace.graph.groups.filter(\.collapsed).map(\.id)) }
    @objc private func contextFrame() { fit() }
    @objc private func contextLayout() { workspace.autoLayout(); fit() }
    @objc private func contextComponent() { workspace.collapseSelection() }
    @objc private func contextToggle() { if let id = workspace.selected { workspace.toggleComponent(id) } }
    @objc private func contextUngroup() { if let id = workspace.selected { workspace.ungroup(id) } }
    override func otherMouseDown(with event: NSEvent) { cursor = convert(event.locationInWindow,from:nil); drag = .pan(cursor,offset) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with:event) }
    override func otherMouseUp(with event: NSEvent) { drag = nil }
    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow,from:nil)
        let hover = hitPort(world(cursor)).flatMap { workspace.graph.node($0.0)?.kind == .apc40 && $0.1 ? $0.2 : nil }
        if hover != hoverAPC { hoverAPC = hover; needsDisplay = true }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { changeZoom(zoom * exp(event.scrollingDeltaY * 0.01), at: convert(event.locationInWindow,from:nil)) }
        else { offset.x += event.scrollingDeltaX; offset.y += event.scrollingDeltaY; sync(); onViewportChange?() }
    }
    override func magnify(with event: NSEvent) { changeZoom(zoom * (1+event.magnification), at:convert(event.locationInWindow,from:nil)) }
    func changeZoom(_ value: CGFloat, at anchor: NSPoint) {
        let p = world(anchor); zoom = min(2,max(0.25,value)); offset = .init(x:anchor.x-p.x*zoom,y:anchor.y-p.y*zoom); sync(); onViewportChange?()
    }
    func fit() {
        let boxes = visibleNodes.map(rect)+workspace.graph.groups.map(componentRect)
        guard let first = boxes.first else { zoom = 1; offset = .init(x:0,y:70); sync(); return }
        let all = boxes.dropFirst().reduce(first) { $0.union($1) }
        zoom = min(1.25, max(0.0001, min((bounds.width-130)/all.width,(bounds.height-min(180,max(48,bounds.height*0.22)))/all.height)))
        offset = .init(x:bounds.midX-all.midX*zoom,y:bounds.midY-all.midY*zoom); sync(); onViewportChange?()
    }
    var insertionPoint: Position {
        let safe = bounds.insetBy(dx:120*zoom,dy:125*zoom)
        let anchor = safe.contains(cursor) ? cursor : NSPoint(x:bounds.midX,y:bounds.midY)
        let p = world(anchor); return .init(p.x-105,p.y-112)
    }
    /// ⌘S publishes the selected nodes' first output (unpublishes when all already are),
    /// ⌘P plays or pauses the selected nodes, and ⌘A then P (Command held), or ⌥⌘P,
    /// also plays or pauses everything they feed.
    private var treeChordDeadline: TimeInterval = 0
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock,.numericPad,.function])
        // Clicking a thumbnail or node button can move focus into the canvas; text fields keep their own shortcuts.
        let focused = (window?.firstResponder as? NSView).map { $0 === self || ($0.isDescendant(of:self) && !($0 is NSText)) } ?? false
        guard event.type == .keyDown,focused else { return super.performKeyEquivalent(with:event) }
        if event.keyCode == 0,flags == .command {
            treeChordDeadline = event.timestamp+1.5
            workspace.message = "⌘A · press P to play or pause the selected node and everything it feeds"
            return true
        }
        guard !workspace.selectedIDs.isEmpty else { return super.performKeyEquivalent(with:event) }
        if event.keyCode == 1,flags == .command {
            let ports = workspace.selectedIDs.compactMap { id in workspace.graph.publishablePorts.first { $0.nodeID == id && workspace.graph.node(id)?.publishesAutomatically == false } }
            // With nothing publishable selected, ⌘S stays Save.
            guard !ports.isEmpty else { return super.performKeyEquivalent(with:event) }
            let mode = ports.allSatisfy(\.listed) ? "off" : "on"
            workspace.edit(mode == "on" ? "Publish Output" : "Unpublish Output") { graph in
                for port in ports { try graph.publish(port.nodeID,port:port.port,mode:mode,name:graph.node(port.nodeID)?.publications?[String(port.port)]?.name) }
            }
            workspace.message = (mode == "on" ? "Published " : "Unpublished ") + ports.map(\.name).sorted().joined(separator:", ")
            needsDisplay = true
            return true
        }
        if event.keyCode == 35,flags == .command || flags == [.command,.option] {
            var targets = workspace.selectedIDs
            let tree = flags.contains(.option) || event.timestamp <= treeChordDeadline
            treeChordDeadline = 0
            if tree {
                var frontier = Array(targets)
                while let id = frontier.popLast() {
                    for edge in workspace.graph.edges where edge.source == id && targets.insert(edge.target).inserted { frontier.append(edge.target) }
                }
            }
            // Pause if anything selected is playing; otherwise play.
            let enable = !workspace.selectedIDs.contains { workspace.graph.node($0)?.enabled == true }
            workspace.edit(enable ? "Play Nodes" : "Pause Nodes") { graph in
                for i in graph.nodes.indices where targets.contains(graph.nodes[i].id) { graph.nodes[i].enabled = enable }
            }
            workspace.message = "\(enable ? "Playing" : "Paused") \(targets.count) node\(targets.count == 1 ? "" : "s")"
            needsDisplay = true
            return true
        }
        return super.performKeyEquivalent(with:event)
    }
    override func keyDown(with event: NSEvent) {
        if case let .selection(_,initial) = drag {
            if event.keyCode == 53 {
                workspace.selectAll(initial.sorted { $0.uuidString < $1.uuidString }); drag = nil; needsDisplay = true
            }
            return
        }
        if case .slice = drag {
            if event.keyCode == 53 { drag = nil; needsDisplay = true; workspace.message = "Slice cancelled" }
            return
        }
        switch event.keyCode {
        case 49: if !event.isARepeat { workspace.onPreview?() }
        case 51,117:
            if let selectedEdge { workspace.edit("Delete Cable") { $0.edges.removeAll { $0.id == selectedEdge } }; self.selectedEdge = nil }
            else { workspace.deleteSelection() }
        case 53: drag = nil; selectedEdge = nil; workspace.selected = nil; needsDisplay = true
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" { fit() }
            else { super.keyDown(with:event) }
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let value = sender.draggingPasteboard.string(forType:.string), value.hasPrefix("patch-user:"), let entry = UserNodeLibrary.shared.entries.first(where:{ $0.file?.path == String(value.dropFirst(11)) }) {
            let p = world(convert(sender.draggingLocation,from:nil)); workspace.addUserNode(entry,at:.init(p.x-105,p.y-40)); return true
        }
        if let value = sender.draggingPasteboard.string(forType:.string), value.hasPrefix("patch-node:"), let kind = NodeKind(rawValue:String(value.dropFirst(11))) {
            let p = world(convert(sender.draggingLocation,from:nil)); workspace.add(kind,at:.init(p.x-105,p.y-40)); return true
        }
        guard let urls = sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] else { return false }
        let p = world(convert(sender.draggingLocation,from:nil)); workspace.importFiles(urls,at:.init(p.x,p.y)); return true
    }
}
