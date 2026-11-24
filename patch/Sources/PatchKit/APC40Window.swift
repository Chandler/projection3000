import AppKit
import Combine
import PatchCore

/// Transparent controls sit over the same artwork used by the graph node.
private final class APC40Control: NSControl {
    let output: Int
    var change: ((Double) -> Void)?
    private var dragStart = NSPoint.zero
    private var startValue = 0.0
    private var controlValue = 0.0
    override var doubleValue: Double { get { controlValue } set { controlValue = newValue } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(output: Int) {
        self.output = output
        super.init(frame:.zero)
        setAccessibilityElement(true)
        setAccessibilityRole(output >= 26 ? .checkBox : .slider)
        setAccessibilityLabel(APC40.outputs[output])
        toolTip = APC40.outputs[output]
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self {
            NSColor.patchAccent.setStroke()
            let ring = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:5,yRadius:5)
            ring.lineWidth = 1; ring.stroke()
        }
    }
    private func commit(_ value: Double) {
        guard isEnabled else { return }
        doubleValue = max(0,min(1,value)); change?(doubleValue)
        superview?.needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow,from:nil); startValue = doubleValue
        if output >= 26 { commit(doubleValue > 0.5 ? 0 : 1) }
        else if output < 8 || output == 24 || output == 25 { drag(event) }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { if output < 26 { drag(event) } }
    private func drag(_ event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if output < 8 || output == 24 {
            let inset = bounds.height * 6 / 116
            commit(1-(point.y-inset)/max(1,bounds.height-2*inset))
        } else if output == 25 {
            let inset = bounds.width * 7 / 200
            commit((point.x-inset)/max(1,bounds.width-2*inset))
        } else {
            let precision = event.modifierFlags.contains(.shift) ? 0.1 : 1.0
            commit(startValue+Double(dragStart.y-point.y)/150*precision)
        }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123,125: commit(doubleValue-(event.modifierFlags.contains(.shift) ? 0.001 : 0.01))
        case 124,126: commit(doubleValue+(event.modifierFlags.contains(.shift) ? 0.001 : 0.01))
        case 49 where output >= 26: commit(doubleValue > 0.5 ? 0 : 1)
        default: super.keyDown(with:event)
        }
    }
    override func accessibilityValue() -> Any? { doubleValue }
    override func setAccessibilityValue(_ value: Any?) { if let value = value as? NSNumber { commit(value.doubleValue) } }
    override func accessibilityPerformIncrement() -> Bool { commit(doubleValue+0.01); return isEnabled }
    override func accessibilityPerformDecrement() -> Bool { commit(doubleValue-0.01); return isEnabled }
    override func accessibilityPerformPress() -> Bool { guard output >= 26 else { return false }; commit(doubleValue > 0.5 ? 0 : 1); return isEnabled }
}

private final class APC40Panel: NSView {
    let workspace: Workspace
    let midi: MIDIController
    let nodeID: UUID
    var controls: [APC40Control] = []
    private var lastValues: [Double?] = []
    private var observation: AnyCancellable?
    override var isFlipped: Bool { true }
    var drawingScale: CGFloat { min(bounds.width/APC40Layout.size.width,bounds.height/APC40Layout.size.height) }
    var drawingOrigin: NSPoint { .init(x:(bounds.width-APC40Layout.size.width*drawingScale)/2,y:(bounds.height-APC40Layout.size.height*drawingScale)/2) }
    init(workspace: Workspace,midi: MIDIController,nodeID: UUID) {
        self.workspace = workspace; self.midi = midi; self.nodeID = nodeID
        super.init(frame:NSRect(origin:.zero,size:APC40Layout.size))
        for output in APC40.outputs.indices {
            let control = APC40Control(output:output)
            control.change = { [weak self] value in
                guard let self,self.workspace.graph.node(self.nodeID)?.enabled == true else { return }
                do { try self.midi.setAPCControl(output:output,value:value) }
                catch { self.workspace.message = error.localizedDescription }
            }
            controls.append(control); addSubview(control)
        }
        observation = workspace.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true; self?.sync() }
        }
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }
    func sync() {
        guard let node = workspace.graph.node(nodeID),node.kind == .apc40 else { window?.close(); return }
        let values = midi.apcState.snapshot
        if values != lastValues { lastValues = values; needsDisplay = true }
        for control in controls { control.doubleValue = values[control.output] ?? 0; control.isEnabled = node.enabled }
        window?.title = node.name
    }
    override func layout() {
        super.layout()
        let scale = drawingScale, origin = drawingOrigin
        for control in controls {
            let rect = APC40Layout.control(control.output)
            control.frame = NSRect(x:origin.x+rect.minX*scale,y:origin.y+rect.minY*scale,width:rect.width*scale,height:rect.height*scale)
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.patchBG.setFill(); bounds.fill()
        guard var node = workspace.graph.node(nodeID) else { return }
        node.position = Position(0,0)
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX:drawingOrigin.x,byY:drawingOrigin.y)
        let matrix = NSAffineTransform(transform:transform); matrix.scale(by:drawingScale); matrix.concat()
        APC40Artwork.draw(node,graph:workspace.graph,values:midi.apcState.snapshot,selected:false,hover:nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class APC40WindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var timer: Timer?
    init(workspace: Workspace,midi: MIDIController,nodeID: UUID) {
        let panel = APC40Panel(workspace:workspace,midi:midi,nodeID:nodeID)
        let window = NSWindow(contentRect:panel.frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = workspace.graph.node(nodeID)?.name ?? "APC40"
        window.contentView = panel; window.contentMinSize = NSSize(width:624,height:400)
        window.contentAspectRatio = APC40Layout.size; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PatchAPC40Controller"); window.center()
        super.init(window:window); window.delegate = self
        timer = Timer(timeInterval:1.0/30,repeats:true) { [weak panel] _ in
            guard let panel,panel.window?.isVisible == true,panel.window?.isMiniaturized == false else { return }
            panel.sync()
        }
        if let timer { RunLoop.main.add(timer,forMode:.common) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; onClose?() }
    deinit { timer?.invalidate() }
}
