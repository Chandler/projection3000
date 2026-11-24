import SwiftUI
import AppKit

struct MeshPointer {
    let startLocation: CGPoint
    let location: CGPoint
    var translation: CGSize { .init(width:location.x-startLocation.x,height:location.y-startLocation.y) }
}
struct MeshPreviewHandle {
    let position: CGPoint
    let color: NSColor
    let selected: Bool
    let radius: Double
    let arms: [CGPoint]
}
// Draw the preview and handles in the same AppKit surface. GPU readback is
// asynchronous and bounded to one pending frame per visible editor.
struct MeshGradientPreview: NSViewRepresentable {
    let renderer: Renderer
    let id: UUID
    let handles: [MeshPreviewHandle]
    let stroke: [CGPoint]
    let onMove: (MeshPointer,CGSize) -> Void
    let onEnd: (MeshPointer,CGSize) -> Void
    func makeNSView(context: Context) -> MeshGradientEditView { MeshGradientEditView(renderer:renderer) }
    func updateNSView(_ view: MeshGradientEditView,context: Context) {
        view.nodeID=id;view.overlay.handles=handles;view.overlay.stroke=stroke
        view.onMove=onMove;view.onEnd=onEnd;view.needsDisplay=true
        view.refreshPreview()
    }
}
final class MeshGradientEditView: NSView {
    let renderer: Renderer
    var nodeID: UUID?
    let overlay=MeshGradientHandleView()
    var onMove: ((MeshPointer,CGSize)->Void)?
    var onEnd: ((MeshPointer,CGSize)->Void)?
    private var start: CGPoint?
    private var image: NSImage?
    private var pending=false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(renderer: Renderer) {
        self.renderer=renderer
        super.init(frame:.zero)
        wantsLayer=true;layer?.masksToBounds=true
    }
    required init?(coder: NSCoder) { fatalError("Use init(renderer:)") }
    func refreshPreview() {
        guard !pending,let nodeID,window?.isVisible==true,!isHiddenOrHasHiddenAncestor,bounds.width>1,bounds.height>1 else {return}
        pending=true
        renderer.requestPreview(nodeID)
        renderer.meshPreviewImage(nodeID) { [weak self] image in
            guard let self else {return}
            self.pending=false
            if let image,self.nodeID==nodeID {self.image=NSImage(cgImage:image,size:.zero);self.needsDisplay=true}
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        image?.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        overlay.draw(dirtyRect)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p=convert(event.locationInWindow,from:nil);start=p
        onMove?(.init(startLocation:p,location:p),bounds.size)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else {return}
        onMove?(.init(startLocation:start,location:convert(event.locationInWindow,from:nil)),bounds.size)
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else {return}
        onEnd?(.init(startLocation:start,location:convert(event.locationInWindow,from:nil)),bounds.size);self.start=nil
    }
}
final class MeshGradientHandleView: NSView {
    var handles: [MeshPreviewHandle] = []
    var stroke: [CGPoint] = []
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (i,h) in handles.enumerated() {
            if h.selected {
                NSColor.white.withAlphaComponent(0.7).setStroke()
                for arm in h.arms {
                    let line=NSBezierPath();line.move(to:h.position);line.line(to:arm);line.lineWidth=1;line.stroke()
                    NSColor.white.setFill();NSBezierPath(ovalIn:.init(x:arm.x-5,y:arm.y-5,width:10,height:10)).fill()
                }
                if h.radius>0 {
                    let ring=NSBezierPath(ovalIn:.init(x:h.position.x-h.radius,y:h.position.y-h.radius,width:h.radius*2,height:h.radius*2));ring.lineWidth=1
                    ring.setLineDash([3,3],count:2,phase:0);ring.stroke()
                }
            }
            let circle=NSBezierPath(ovalIn:.init(x:h.position.x-11,y:h.position.y-11,width:22,height:22));h.color.setFill();circle.fill()
            (h.selected ? NSColor.white:NSColor.black).setStroke();circle.lineWidth=h.selected ? 3:1;circle.stroke()
            let text="\(i+1)" as NSString,attrs:[NSAttributedString.Key:Any]=[.font:NSFont.boldSystemFont(ofSize:9),.foregroundColor:NSColor.white]
            let size=text.size(withAttributes:attrs);text.draw(at:.init(x:h.position.x-size.width/2,y:h.position.y-size.height/2),withAttributes:attrs)
        }
        if stroke.count>1 {
            let path=NSBezierPath();path.move(to:stroke[0]);for p in stroke.dropFirst() {path.line(to:p)}
            NSColor.white.setStroke();path.lineWidth=2;path.stroke()
        }
    }
}
