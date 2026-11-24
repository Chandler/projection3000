import AppKit
import SwiftUI
import PatchCore

/// Native slider interaction/keyboard/accessibility, with a color-aware track.
private final class ColorTrackCell: NSSliderCell {
    var colors: [NSColor] = []
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x:rect.minX,y:rect.midY-4,width:rect.width,height:8)
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect:track,xRadius:4,yRadius:4)
        path.addClip()
        NSGradient(colors:colors)?.draw(in:track,angle:0)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.16).setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}
private final class ColorTrackSlider: NSSlider {
    var editing: (Bool)->Void = { _ in }
    override func mouseDown(with event: NSEvent) {
        editing(true); super.mouseDown(with:event); editing(false)
    }
    override func keyDown(with event: NSEvent) {
        editing(true); super.keyDown(with:event); editing(false)
    }
}
private struct ColorTrack: NSViewRepresentable {
    @Binding var value: Double
    let colors: [NSColor]
    let label: String
    let editing: (Bool)->Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ColorTrackSlider {
        let slider = ColorTrackSlider()
        slider.cell = ColorTrackCell(); slider.minValue = 0; slider.maxValue = 1
        slider.isContinuous = true; slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(label)
        slider.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return slider
    }
    func updateNSView(_ slider: ColorTrackSlider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = value; slider.editing = editing
        (slider.cell as? ColorTrackCell)?.colors = colors
        slider.needsDisplay = true
    }
    final class Coordinator: NSObject {
        var parent: ColorTrack
        init(_ parent: ColorTrack) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
}

/// Keep one native well alive while SwiftUI refreshes inspector values. Both
/// portions of the expanded well open the full panel, without a popover step.
struct PanelColorWell: NSViewRepresentable {
    @Binding var selection: Color
    let title: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.colorWellStyle = .expanded
        well.supportsAlpha = false
        well.isContinuous = true
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        well.pulldownTarget = context.coordinator
        well.pulldownAction = #selector(Coordinator.openPanel(_:))
        well.setAccessibilityLabel(title)
        return well
    }
    func updateNSView(_ well: NSColorWell,context: Context) {
        context.coordinator.parent = self
        well.setAccessibilityLabel(title)
        let next = NSColor(selection).usingColorSpace(.sRGB) ?? NSColor(selection)
        // Setting color on an active well also updates the shared panel. Avoid
        // feeding equivalent HSB-to-RGB round trips back into a panel drag.
        if let current = well.color.usingColorSpace(.sRGB), let rgb = next.usingColorSpace(.sRGB),
           abs(current.redComponent-rgb.redComponent) < 0.000001,
           abs(current.greenComponent-rgb.greenComponent) < 0.000001,
           abs(current.blueComponent-rgb.blueComponent) < 0.000001 { return }
        well.color = next
    }
    static func dismantleNSView(_ well: NSColorWell,coordinator: Coordinator) {
        well.deactivate(); well.target = nil; well.pulldownTarget = nil
    }
    final class Coordinator: NSObject {
        var parent: PanelColorWell
        init(_ parent: PanelColorWell) { self.parent = parent }
        @objc func changed(_ well: NSColorWell) { parent.selection = Color(nsColor:well.color) }
        @objc func openPanel(_ well: NSColorWell) {
            well.activate(true)
            NSColorPanel.shared.makeKeyAndOrderFront(nil)
        }
    }
}

struct PoseColorControls: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    var background = false
    @State private var dragging = false
    var node: Node? { workspace.graph.node(id) }
    var hueKey: String { background ? "backgroundHue" : "hue" }
    var saturationKey: String { background ? "backgroundSaturation" : "saturation" }
    var brightnessKey: String { background ? "backgroundBrightness" : "brightness" }
    func value(_ key: String) -> Double { node?.value(key) ?? 0 }
    func binding(_ key: String) -> Binding<Double> {
        Binding(get:{ value(key) },set:{ workspace.parameter(id,key,min(1,max(0,$0))) })
    }
    func color(_ h: Double,_ s: Double,_ b: Double) -> NSColor { NSColor(hue:h,saturation:s,brightness:b,alpha:1) }
    var selected: Color { Color(nsColor:color(value(hueKey),value(saturationKey),value(brightnessKey))) }
    func editing(_ active: Bool) {
        if active { workspace.beginGesture() } else { workspace.endGesture("Change Color") }
    }
    func setColor(_ selected: Color) {
        guard let rgb = NSColor(selected).usingColorSpace(.sRGB) else { return }
        // Keep the last hue when choosing gray/black so raising saturation restores it.
        let hue = rgb.saturationComponent > 0.0001 && rgb.brightnessComponent > 0.0001 ? rgb.hueComponent : value(hueKey)
        let saturation = rgb.brightnessComponent > 0.0001 ? rgb.saturationComponent : value(saturationKey)
        workspace.edit("Change Color") { graph in
            try graph.setParameter(id,key:hueKey,value:hue)
            try graph.setParameter(id,key:saturationKey,value:saturation)
            try graph.setParameter(id,key:brightnessKey,value:rgb.brightnessComponent)
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if background || node?.kind != .poseRender || node?.value("color") != 0 {
            HStack {
                Text(background ? "Background color" : "Base color")
                Spacer()
                PanelColorWell(selection:Binding(get:{ selected },set:setColor),title:background ? "Background color" : "Base color")
                    .id("\(id)-\(background)")
                    .frame(width:64,height:24)
                    .help("Open Colors")
            }
            GeometryReader { geometry in
                ZStack(alignment:.topLeading) {
                    Rectangle().fill(Color(hue:value(hueKey),saturation:1,brightness:1))
                    Rectangle().fill(LinearGradient(colors:[.white,.white.opacity(0)],startPoint:.leading,endPoint:.trailing))
                    Rectangle().fill(LinearGradient(colors:[.black.opacity(0),.black],startPoint:.top,endPoint:.bottom))
                    Circle().fill(selected).frame(width:12,height:12)
                        .overlay(Circle().stroke(.black.opacity(0.65),lineWidth:4))
                        .overlay(Circle().stroke(.white,lineWidth:2))
                        .position(x:value(saturationKey)*geometry.size.width,y:(1-value(brightnessKey))*geometry.size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius:5))
                .overlay(RoundedRectangle(cornerRadius:5).stroke(.white.opacity(0.15),lineWidth:1))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { event in
                    if !dragging { dragging = true; editing(true) }
                    let s = max(0,min(1,event.location.x/max(1,geometry.size.width)))
                    let b = max(0,min(1,1-event.location.y/max(1,geometry.size.height)))
                    workspace.edit("Change Color") { graph in
                        try graph.setParameter(id,key:saturationKey,value:s)
                        try graph.setParameter(id,key:brightnessKey,value:b)
                    }
                }.onEnded { _ in dragging = false; editing(false) })
                .accessibilityElement(children:.ignore)
                .accessibilityLabel("Saturation and brightness")
                .accessibilityValue("Saturation \(Int(value(saturationKey)*100)) percent, brightness \(Int(value(brightnessKey)*100)) percent")
                .help("Drag left/right for saturation; up/down for brightness. The sliders below also support keyboard adjustment.")
            }.frame(height:105)
            ramp("Hue",key:hueKey,colors:(0...12).map { color(Double($0)/12,1,1) },maximum:360,suffix:"°")
            ramp("Saturation",key:saturationKey,colors:[color(value(hueKey),0,value(brightnessKey)),color(value(hueKey),1,value(brightnessKey))],maximum:100,suffix:"%")
            }
            ramp("Brightness",key:brightnessKey,colors:[.black,color(value(hueKey),!background && node?.kind == .poseRender && node?.value("color") == 0 ? 0 : value(saturationKey),1)],maximum:100,suffix:"%")
        }.onDisappear { if dragging { dragging = false; editing(false) } }
    }
    private func ramp(_ title: String,key: String,colors: [NSColor],maximum: Double,suffix: String) -> some View {
        VStack(spacing:3) {
            HStack {
                Text(title).font(.system(size:10)).foregroundStyle(.secondary)
                Spacer()
                TextField(title,value:Binding<Double>(get:{ value(key)*maximum },set:{ number in
                    guard number.isFinite else { return }; workspace.parameter(id,key,min(1,max(0,number/maximum)))
                }),format:.number.precision(.fractionLength(0...1))).textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width:45)
                Text(suffix).font(.system(size:10)).foregroundStyle(.secondary)
            }
            ColorTrack(value:binding(key),colors:colors,label:title,editing:editing).frame(height:18)
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
}
