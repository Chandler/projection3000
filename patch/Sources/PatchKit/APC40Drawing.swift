import AppKit
import CoreText
import PatchCore

/// Canvas artwork for the APC40 mkII node: a top-down drawing of the hardware
/// whose mapped controls double as output ports. Coordinates are node-local.
enum APC40Layout {
    static let size = NSSize(width:780,height:500)
    static let divider: CGFloat = 446
    static func column(_ i: Int) -> CGFloat { 44+CGFloat(i)*46 }
    static let knobRadius: CGFloat = 15, deviceKnobRadius: CGFloat = 17
    static func deviceKnob(_ k: Int) -> NSPoint { .init(x:500+CGFloat(k%4)*58,y:132+CGFloat(k/4)*60) }
    static func trackKnob(_ k: Int) -> NSPoint { .init(x:column(k),y:72) }
    /// The control's hit area, which is also its port slot.
    static func control(_ output: Int) -> NSRect {
        switch output {
        case 0..<8: return .init(x:column(output)-13,y:340,width:26,height:116)
        case 8..<16: let c = trackKnob(output-8),r = knobRadius+5; return .init(x:c.x-r,y:c.y-r,width:r*2,height:r*2)
        case 16..<24: let c = deviceKnob(output-16),r = deviceKnobRadius+5; return .init(x:c.x-r,y:c.y-r,width:r*2,height:r*2)
        case 24: return .init(x:column(8)-13,y:340,width:26,height:116)
        case 25: return .init(x:520,y:428,width:200,height:24)
        default: return .init(x:column(output-26)-16,y:258,width:32,height:16)
        }
    }
    /// Runs of neighbouring controls that may share one highlight.
    static let sections: [[Int]] = [Array(0..<8),[24],Array(8..<16),Array(16..<20),Array(20..<24),[25],Array(26..<34)]
}

private let led = NSColor(calibratedRed:1,green:0.36,blue:0.16,alpha:1)
private let amber = NSColor(calibratedRed:1,green:0.66,blue:0.18,alpha:1)
private let silk = NSColor(white:0.56,alpha:1)

private func textWidth(_ text: String,size: CGFloat,weight: NSFont.Weight = .regular) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize:size,weight:weight)
    let value = CFAttributedStringCreateMutable(nil,0)!
    CFAttributedStringReplaceString(value,CFRange(location:0,length:0),text as CFString)
    CFAttributedStringSetAttribute(value,CFRange(location:0,length:CFAttributedStringGetLength(value)),kCTFontAttributeName,CTFontCreateWithName(font.fontName as CFString,size,nil))
    return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(value),nil,nil,nil))
}
private func label(_ text: String,centeredAt p: NSPoint,size: CGFloat = 6,color: NSColor = silk,weight: NSFont.Weight = .medium) {
    let w = textWidth(text,size:size,weight:weight)+2
    drawText(text,.init(x:p.x-w/2,y:p.y-size*0.62,width:w,height:size*1.5),size:size,color:color,weight:weight,mono:true)
}
private func button(_ r: NSRect,fill: NSColor = NSColor(white:0.16,alpha:1),text: String? = nil,textColor: NSColor = silk) {
    fill.setFill(); NSBezierPath(roundedRect:r,xRadius:2,yRadius:2).fill()
    NSColor(white:1,alpha:0.10).setStroke(); let edge = NSBezierPath(roundedRect:r.insetBy(dx:0.5,dy:0.5),xRadius:2,yRadius:2); edge.lineWidth = 0.6; edge.stroke()
    if let text { label(text,centeredAt:.init(x:r.midX,y:r.midY),size:min(6,r.height*0.55),color:textColor) }
}
private func knob(_ c: NSPoint,radius r: CGFloat,value: Double?,ring: Bool = true) {
    let start = CGFloat.pi*0.75,sweep = CGFloat.pi*1.5
    if ring {
        for step in 0..<15 {
            let t = Double(step)/14,a = start+sweep*CGFloat(t)
            let p = NSPoint(x:c.x+cos(a)*(r+5),y:c.y+sin(a)*(r+5))
            let lit = value.map { t <= $0+0.001 && $0 > 0 } ?? false
            (lit ? led : NSColor(calibratedRed:0.32,green:0.13,blue:0.09,alpha:1)).setFill()
            NSBezierPath(ovalIn:.init(x:p.x-1.3,y:p.y-1.3,width:2.6,height:2.6)).fill()
        }
    }
    NSColor(white:0.03,alpha:0.7).setFill(); NSBezierPath(ovalIn:.init(x:c.x-r+1,y:c.y-r+2,width:r*2,height:r*2)).fill()
    NSGradient(starting:NSColor(white:0.30,alpha:1),ending:NSColor(white:0.10,alpha:1))?.draw(in:NSBezierPath(ovalIn:.init(x:c.x-r,y:c.y-r,width:r*2,height:r*2)),angle:-70)
    NSGradient(starting:NSColor(white:0.20,alpha:1),ending:NSColor(white:0.12,alpha:1))?.draw(in:NSBezierPath(ovalIn:.init(x:c.x-r*0.72,y:c.y-r*0.72,width:r*1.44,height:r*1.44)),angle:110)
    let a = start+sweep*CGFloat(value ?? 0)
    let line = NSBezierPath(); line.move(to:.init(x:c.x+cos(a)*r*0.25,y:c.y+sin(a)*r*0.25)); line.line(to:.init(x:c.x+cos(a)*r*0.9,y:c.y+sin(a)*r*0.9))
    line.lineWidth = 2; line.lineCapStyle = .round; NSColor(white:value == nil ? 0.6 : 0.95,alpha:1).setStroke(); line.stroke()
}
private func fader(_ r: NSRect,value: Double?,horizontal: Bool = false) {
    let along = horizontal ? r.width : r.height
    NSColor(white:1,alpha:0.18).setFill()
    for step in 0...10 {
        let o = 6+(along-12)*CGFloat(step)/10,major = step%5 == 0 ? 3.5 : 2
        if horizontal { NSRect(x:r.minX+o-0.4,y:r.minY-major,width:0.8,height:major).fill(); NSRect(x:r.minX+o-0.4,y:r.maxY,width:0.8,height:major).fill() }
        else { NSRect(x:r.minX+2,y:r.minY+o-0.4,width:major,height:0.8).fill(); NSRect(x:r.maxX-2-major,y:r.minY+o-0.4,width:major,height:0.8).fill() }
    }
    let slot = horizontal ? NSRect(x:r.minX+4,y:r.midY-1.5,width:r.width-8,height:3) : NSRect(x:r.midX-1.5,y:r.minY+4,width:3,height:r.height-8)
    NSColor.black.setFill(); NSBezierPath(roundedRect:slot,xRadius:1.5,yRadius:1.5).fill()
    let v = CGFloat(value ?? 0)
    let cap = horizontal ? NSRect(x:r.minX+(r.width-14)*v,y:r.midY-10,width:14,height:20) : NSRect(x:r.midX-11,y:r.maxY-12-(r.height-12)*v,width:22,height:12)
    NSColor(white:0,alpha:0.5).setFill(); NSBezierPath(roundedRect:cap.offsetBy(dx:0,dy:2),xRadius:2,yRadius:2).fill()
    NSGradient(starting:NSColor(white:value == nil ? 0.36 : 0.50,alpha:1),ending:NSColor(white:value == nil ? 0.20 : 0.28,alpha:1))?.draw(in:NSBezierPath(roundedRect:cap,xRadius:2,yRadius:2),angle:-90)
    NSColor(white:0.95,alpha:value == nil ? 0.4 : 0.9).setFill()
    (horizontal ? NSRect(x:cap.midX-0.6,y:cap.minY+3,width:1.2,height:cap.height-6) : NSRect(x:cap.minX+3,y:cap.midY-0.6,width:cap.width-6,height:1.2)).fill()
}

extension GraphCanvas {
    func apcControl(_ node: Node,output: Int) -> NSRect { APC40Layout.control(output).offsetBy(dx:node.position.x,dy:node.position.y) }
    func drawAPC40(_ node: Node,selected: Bool,hover: Int?) {
        APC40Artwork.draw(node,graph:workspace.graph,values:renderer.apcState.snapshot,selected:selected,hover:hover)
    }
}

enum APC40Artwork {
    /// Where each APC output goes: target node plus a short description.
    private static func apcTargets(_ node: Node,graph: Graph) -> [[(UUID,String)]] {
        var targets = Array(repeating:[(UUID,String)](),count:APC40.outputs.count)
        for edge in graph.edges where edge.source == node.id && targets.indices.contains(edge.outputIndex) {
            guard let target = graph.node(edge.target) else { continue }
            targets[edge.outputIndex].append((target.id,target.inputs.indices.contains(edge.input) ? target.inputs[edge.input] : "Input"))
        }
        for target in graph.nodes {
            for (key,binding) in (target.modulations ?? [:]).sorted(by:{ $0.key < $1.key }) where binding.source == node.id && targets.indices.contains(binding.outputIndex) {
                targets[binding.outputIndex].append((target.id,target.parameterSpecs.first { $0.key == key }?.title ?? key))
            }
        }
        return targets
    }
    static func draw(_ node: Node,graph: Graph,values: [Double?],selected: Bool,hover: Int?) {
        let origin = node.position, r = NSRect(x:node.position.x,y:node.position.y,width:APC40Layout.size.width,height:APC40Layout.size.height)
        func apcControl(_ node: Node,output: Int) -> NSRect { APC40Layout.control(output).offsetBy(dx:node.position.x,dy:node.position.y) }
        func at(_ x: CGFloat,_ y: CGFloat) -> NSPoint { .init(x:origin.x+x,y:origin.y+y) }
        func box(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat) -> NSRect { .init(x:origin.x+x,y:origin.y+y,width:w,height:h) }
        NSColor.patchPanel.setFill(); r.fill()
        (selected ? NSColor.node(node.kind) : NSColor(white:0.25,alpha:1)).setStroke()
        let border = NSBezierPath(rect:r.insetBy(dx:0.5,dy:0.5)); border.lineWidth = selected ? 1.8 : 1; border.stroke()
        NSColor.node(node.kind).setFill(); NSRect(x:r.minX+11,y:r.minY+13,width:5,height:10).fill()
        drawText(node.name,.init(x:r.minX+24,y:r.minY+9,width:400,height:20),size:12,color:node.enabled ? .labelColor : .patchMuted,weight:.medium)
        drawText(node.enabled ? "CONTROL / APC40 MKII · \(values.compactMap { $0 }.count) OF \(values.count) CONTROLS LIVE" : node.kind.pausedStatus.uppercased(),.init(x:r.minX+12,y:r.maxY-19,width:500,height:16),size:8,color:.patchMuted,mono:true)

        // Chassis
        let chassis = box(8,34,764,440)
        NSColor(white:0,alpha:0.45).setFill(); NSBezierPath(roundedRect:chassis.offsetBy(dx:0,dy:3),xRadius:10,yRadius:10).fill()
        NSGradient(starting:NSColor(white:0.115,alpha:1),ending:NSColor(white:0.065,alpha:1))?.draw(in:NSBezierPath(roundedRect:chassis,xRadius:10,yRadius:10),angle:-90)
        NSColor(white:1,alpha:0.13).setStroke(); let rim = NSBezierPath(roundedRect:chassis.insetBy(dx:0.5,dy:0.5),xRadius:10,yRadius:10); rim.lineWidth = 1; rim.stroke()
        NSColor(white:1,alpha:0.06).setFill(); box(APC40Layout.divider,46,1,418).fill()
        let col = APC40Layout.column

        // Track control knobs
        for k in 0..<8 { knob(at(col(k),72),radius:APC40Layout.knobRadius,value:values[8+k]) }
        label("TRACK CONTROL",centeredAt:at(col(8),52));
        for (i,name) in ["PAN","SENDS","USER"].enumerated() { button(box(col(8)-16,59+CGFloat(i)*10,32,8),text:name) }
        // Clip launch grid and scene launch
        for row in 0..<5 {
            for k in 0..<8 {
                let pad = box(col(k)-17,102+CGFloat(row)*22,34,18)
                NSColor(white:0.17,alpha:1).setFill(); NSBezierPath(roundedRect:pad,xRadius:2.5,yRadius:2.5).fill()
                NSColor(white:1,alpha:0.05).setFill(); NSBezierPath(roundedRect:pad.insetBy(dx:3,dy:3),xRadius:1.5,yRadius:1.5).fill()
            }
            button(box(col(8)-15,104+CGFloat(row)*22,30,14),text:"▶")
        }
        label("SCENE LAUNCH",centeredAt:at(col(8),96))
        for k in 0..<8 {
            button(box(col(k)-15,216,30,8))
            button(box(col(k)-15,233,30,8))
            label("\(k+1)",centeredAt:at(col(k),249),size:5.5)
            let lit = (values[26+k] ?? 0) > 0.5
            button(box(col(k)-15,258,30,16),fill:lit ? amber : amber.withAlphaComponent(0.22),text:"\(k+1)",textColor:lit ? .black : amber)
            button(box(col(k)-15,280,30,11),fill:NSColor.systemBlue.withAlphaComponent(0.20),text:"S")
            button(box(col(k)-15,297,30,11),fill:NSColor.systemRed.withAlphaComponent(0.22),text:"●")
            button(box(col(k)-15,314,30,9),text:"A | B")
        }
        label("CLIP STOP",centeredAt:at(col(8),210)); button(box(col(8)-15,216,30,8))
        label("MASTER",centeredAt:at(col(8),228)); button(box(col(8)-15,233,30,8))
        for (i,name) in ["ACTIVATOR","SOLO","REC ARM","X-FADE"].enumerated() { label(name,centeredAt:at(col(8),266+CGFloat(i)*17-CGFloat(i == 0 ? 0 : 1))) }
        // Channel faders and master
        for k in 0..<9 { fader(box(col(k)-13,340,26,116),value:values[k < 8 ? k : 24]) }
        label("MASTER",centeredAt:at(col(8),334))

        // Right half: tempo, device control, transport, crossfader
        let rx = APC40Layout.divider
        knob(at(rx+40,72),radius:12,value:nil,ring:false); label("TEMPO",centeredAt:at(rx+40,92))
        for (i,name) in ["METRO","TAP","NUDGE−","NUDGE+"].enumerated() { button(box(rx+70+CGFloat(i)*44,66,38,10),text:name) }
        knob(at(rx+282,72),radius:12,value:nil,ring:false); label("CUE LEVEL",centeredAt:at(rx+282,92))
        label("DEVICE CONTROL",centeredAt:at(587,222))
        for k in 0..<8 { knob(at(APC40Layout.deviceKnob(k).x,APC40Layout.deviceKnob(k).y),radius:APC40Layout.deviceKnobRadius,value:values[16+k]) }
        for (i,name) in ["◀ DEVICE","DEVICE ▶","◀ BANK","BANK ▶","DEV ON","DEV LOCK","CLIP/DEV","DETAIL"].enumerated() {
            button(box(rx+30+CGFloat(i%4)*58,232+CGFloat(i/4)*16,50,11),text:name)
        }
        for (i,name) in ["PLAY","RECORD","SESSION"].enumerated() { button(box(rx+30+CGFloat(i)*58,276,50,14),text:name) }
        button(box(rx+30,304,50,14),text:"SHIFT"); button(box(rx+88,304,50,14),text:"BANK")
        let arrows = NSPoint(x:rx+214,y:318)
        for (dx,dy,glyph) in [(0.0,-13.0,"▲"),(0.0,13.0,"▼"),(-21.0,0.0,"◀"),(21.0,0.0,"▶")] { button(box(arrows.x+dx-9,arrows.y+dy-6,18,12),text:glyph) }
        label("BANK SELECT",centeredAt:at(arrows.x,arrows.y+28))
        label("AKAI",centeredAt:at(rx+40,372),size:11,color:NSColor(white:0.75,alpha:1),weight:.heavy)
        label("PROFESSIONAL",centeredAt:at(rx+40,384),size:5)
        label("APC40 mkII",centeredAt:at(rx+260,377),size:12,color:NSColor(white:0.78,alpha:1),weight:.bold)
        fader(box(520,428,200,24),value:values[25],horizontal:true)
        label("A",centeredAt:at(508,440),size:8); label("B",centeredAt:at(732,440),size:8); label("CROSSFADER",centeredAt:at(620,464))

        // Highlight every control that drives something, circling runs that share a target.
        let targets = apcTargets(node,graph:graph)
        for section in APC40Layout.sections {
            var runs: [[Int]] = []
            for output in section where !targets[output].isEmpty {
                if let last = runs.last?.last,last == output-1,Set(targets[last].map(\.0)) == Set(targets[output].map(\.0)) { runs[runs.count-1].append(output) }
                else { runs.append([output]) }
            }
            for run in runs {
                guard let first = run.first,let target = graph.node(targets[first][0].0) else { continue }
                let color = NSColor.node(target.kind)
                let area = run.map { apcControl(node,output:$0) }.reduce(apcControl(node,output:first)) { $0.union($1) }.insetBy(dx:-5,dy:-5)
                let outline = NSBezierPath(roundedRect:area,xRadius:min(12,area.height/2),yRadius:min(12,area.height/2))
                color.withAlphaComponent(0.10).setFill(); outline.fill()
                color.withAlphaComponent(0.22).setStroke(); outline.lineWidth = 6; outline.stroke()
                color.setStroke(); outline.lineWidth = 1.5; outline.stroke()
                let others = Set(targets[first].map(\.0)).count-1
                var text = "→ " + target.name
                if run.count == 1 { text += " · " + targets[first][0].1 }
                if others > 0 { text += " +\(others)" }
                let w = textWidth(text,size:7.5,weight:.semibold)+12
                let pill = NSRect(x:max(chassis.minX+4,min(chassis.maxX-w-4,area.midX-w/2)),y:area.minY-7,width:w,height:13)
                NSColor.patchBG.setFill(); NSBezierPath(roundedRect:pill,xRadius:6.5,yRadius:6.5).fill()
                color.setStroke(); let edge = NSBezierPath(roundedRect:pill.insetBy(dx:0.5,dy:0.5),xRadius:6,yRadius:6); edge.lineWidth = 1; edge.stroke()
                drawText(text,.init(x:pill.minX+6,y:pill.minY+2,width:w-10,height:11),size:7.5,color:color,weight:.semibold,mono:true)
            }
        }
        if let hover {
            let area = apcControl(node,output:hover).insetBy(dx:-3,dy:-3)
            NSColor.patchAccent.setStroke(); let ring = NSBezierPath(roundedRect:area,xRadius:6,yRadius:6); ring.lineWidth = 1.2; ring.setLineDash([3,2],count:2,phase:0); ring.stroke()
            let text = APC40.outputs[hover].uppercased() + (values[hover].map { String(format:" · %.2f",$0) } ?? " · WAITING")
            let w = textWidth(text,size:8,weight:.semibold)+12
            let tip = NSRect(x:area.midX-w/2,y:area.maxY+4,width:w,height:14)
            NSColor.patchBG.withAlphaComponent(0.95).setFill(); NSBezierPath(roundedRect:tip,xRadius:3,yRadius:3).fill()
            drawText(text,.init(x:tip.minX+6,y:tip.minY+2,width:w-8,height:12),size:8,color:.patchAccent,weight:.semibold,mono:true)
        }
    }
}
