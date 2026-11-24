import SwiftUI
import PatchCore

/// Performance controls follow quantity semantics; exact entry remains available.
struct ParameterControl: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let hasNeutralZero: Bool
    private let showsValueField: Bool
    private let centeredBalance: Bool
    private let colorHue: Double
    private let spec: ParameterSpec?
    private let onEditingChanged: (Bool) -> Void

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
         hasNeutralZero: Bool = true, showsValueField: Bool = true, centeredBalance: Bool = false,
         spec: ParameterSpec? = nil, colorHue: Double = 0, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.colorHue = colorHue
        self.spec = spec
        _value = value
        self.range = range
        self.step = step.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.hasNeutralZero = hasNeutralZero
        self.showsValueField = showsValueField
        self.centeredBalance = centeredBalance
        self.onEditingChanged = onEditingChanged
    }

    private var bipolar: Bool { hasNeutralZero && range.lowerBound < 0 && range.upperBound > 0 }
    private var increment: Double { step ?? pow(10, floor(log10(max(0.000001, range.upperBound-range.lowerBound)))) / 100 }
    private func set(_ next: Double) {
        guard next.isFinite else { return }
        let quantized = step.map { (next / $0).rounded() * $0 } ?? next
        onEditingChanged(true)
        value = min(range.upperBound, max(range.lowerBound, quantized))
        onEditingChanged(false)
    }

    private var neutral: Double? {
        if centeredBalance || bipolar { return 0 }
        if let spec, ["scale", "saturation", "brightness", "contrast", "gamma", "speed"].contains(spec.key), range.contains(1) { return 1 }
        return nil
    }
    private var colors: [Color] {
        guard let spec else { return [] }
        let key = spec.key.lowercased()
        if key.contains("hue") && !key.contains("rate") && !key.contains("speed") {
            return (0...12).map {
                let hue = (Double($0)/12 + (range.lowerBound < 0 ? 0.5 : 0)).truncatingRemainder(dividingBy:1)
                return Color(hue:hue,saturation:1,brightness:1)
            }
        }
        if key.contains("temperature") { return [.blue, .gray, .orange] }
        if key.contains("saturation") { return [.gray, Color(hue:colorHue,saturation:1,brightness:1)] }
        if key.contains("brightness") { return [.black, Color(hue:colorHue,saturation:1,brightness:1), .white] }
        return []
    }
    private var logarithmic: Bool {
        guard range.lowerBound > 0, let spec else { return false }
        return spec.title.contains("Hz") || spec.title.contains("(ms)") || ["scale", "zoom", "cutoff"].contains(spec.key)
    }
    var body: some View {
        VStack(spacing:4) {
            HStack(spacing:6) {
                if spec?.key.lowercased().contains("seed") == true {
                    Button("New variation") { set(Double.random(in:range).rounded()) }
                        .buttonStyle(.bordered).controlSize(.small)
                    TextField("Seed",value:Binding(get:{ value },set:set),format:.number.precision(.fractionLength(0)))
                        .textFieldStyle(.squareBorder).frame(width:80)
                } else if step != nil {
                    if showsValueField {
                        TextField("Value",value:Binding(get:{ value },set:set),format:.number.precision(.fractionLength(0...4)))
                            .textFieldStyle(.squareBorder).frame(width:80)
                    }
                    Stepper("Adjust value", onIncrement:{ set(value + increment) }, onDecrement:{ set(value - increment) }).labelsHidden()
                } else if centeredBalance {
                    BalanceSlider(value:$value,onEditingChanged:onEditingChanged)
                } else {
                    SemanticSlider(value:$value,range:range,neutral:neutral,colors:colors,logarithmic:logarithmic,onEditingChanged:onEditingChanged)
                }
                if let neutral {
                    Button(neutral == 0 ? "0" : "1×") { set(neutral) }
                        .buttonStyle(.bordered).controlSize(.mini).help("Return to neutral")
                } else if range.lowerBound == 0 {
                    Button("0") { set(0) }.buttonStyle(.bordered).controlSize(.mini).help("Set exactly zero")
                }
                if let spec {
                    Button { set(spec.initial) } label: { Image(systemName:"arrow.counterclockwise") }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .help("Reset to default: \(spec.initial.formatted())")
                        .accessibilityLabel("Reset \(spec.title) to default")
                }
            }
            if bipolar && showsValueField && !centeredBalance {
                TextField("Exact value",value:Binding(get:{ value },set:set),format:.number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.squareBorder).frame(width:80).frame(maxWidth:.infinity,alignment:.trailing)
            }
            if let spec, spec.key.lowercased().contains("temperature") {
                HStack { Text("Cool"); Spacer(); Text("Unchanged"); Spacer(); Text("Warm") }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

}

/// Balance is a direction from neutral, not an amount filled from the left.
private struct BalanceSlider: View {
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @State private var dragging = false
    @FocusState private var focused: Bool

    private func adjust(_ delta: Double) {
        onEditingChanged(true)
        value = min(1,max(-1,value + delta))
        if abs(value) < 0.000001 { value = 0 }
        onEditingChanged(false)
    }

    var body: some View {
        HStack(spacing:8) {
            Text("L").font(.caption.monospaced()).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let width = max(1,geometry.size.width - 16)
                let center = geometry.size.width / 2
                let position = 8 + CGFloat((min(1,max(-1,value)) + 1) / 2) * width
                ZStack(alignment:.leading) {
                    Capsule().fill(Color.secondary.opacity(0.22)).frame(height:4)
                        .padding(.horizontal,8)
                    Capsule().fill(Color.accentColor)
                        .frame(width:abs(position-center),height:4)
                        .offset(x:min(center,position))
                    Rectangle().fill(Color.secondary).frame(width:1,height:12).offset(x:center-0.5)
                    Circle().fill(Color(nsColor:.controlBackgroundColor))
                        .overlay(Circle().stroke(focused ? Color.accentColor : Color.secondary,lineWidth:focused ? 2:1))
                        .frame(width:14,height:14).offset(x:position-7)
                }
                .frame(height:24)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { event in
                    focused = true
                    if !dragging { dragging = true; onEditingChanged(true) }
                    let x = min(width,max(0,event.location.x-8))
                    value = abs(x-width/2) <= 3 ? 0 : Double(x/width)*2-1
                }.onEnded { _ in dragging = false; onEditingChanged(false) })
            }.frame(height:24)
            Text("R").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .focusable().focused($focused)
        .onMoveCommand { direction in
            if direction == .left { adjust(-0.01) }
            if direction == .right { adjust(0.01) }
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Left right balance")
        .accessibilityValue(value == 0 ? "Center" : "\(Int((abs(value)*100).rounded())) percent \(value < 0 ? "left" : "right")")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(0.01)
            case .decrement: adjust(-0.01)
            @unknown default: break
            }
        }
        .help("Center is neutral. Drag toward L or R; arrow keys adjust balance.")
    }
}

/// Explicit neutral origin, color guidance, keyboard adjustment and a small neutral detent.
private struct SemanticSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double?
    let colors: [Color]
    let logarithmic: Bool
    let onEditingChanged: (Bool) -> Void
    @State private var dragging = false
    @FocusState private var focused: Bool
    private func fraction(_ value: Double) -> Double {
        let v = min(range.upperBound,max(range.lowerBound,value))
        if logarithmic { return log(v/range.lowerBound)/log(range.upperBound/range.lowerBound) }
        return (v-range.lowerBound)/max(0.000001,range.upperBound-range.lowerBound)
    }
    private func decoded(_ fraction: Double) -> Double {
        let f = min(1,max(0,fraction))
        if logarithmic { return range.lowerBound * pow(range.upperBound/range.lowerBound,f) }
        return range.lowerBound + f*(range.upperBound-range.lowerBound)
    }
    private func adjust(_ delta: Double) {
        onEditingChanged(true); value = decoded(fraction(value)+delta); onEditingChanged(false)
    }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1,geometry.size.width-16)
            let position = 8 + fraction(value)*width
            let origin = 8 + fraction(neutral ?? range.lowerBound)*width
            ZStack(alignment:.leading) {
                Capsule().fill(Color.secondary.opacity(0.22)).frame(height:5).padding(.horizontal,8)
                if !colors.isEmpty {
                    Capsule().fill(LinearGradient(colors:colors,startPoint:.leading,endPoint:.trailing)).frame(height:7).padding(.horizontal,8)
                } else {
                    Capsule().fill(Color.accentColor).frame(width:abs(position-origin),height:5).offset(x:min(position,origin))
                }
                if neutral != nil { Rectangle().fill(Color.primary).frame(width:1,height:13).offset(x:origin) }
                Circle().fill(Color(nsColor:.controlBackgroundColor))
                    .overlay(Circle().stroke(focused ? Color.accentColor : Color.secondary,lineWidth:2))
                    .frame(width:14,height:14).offset(x:position-7)
            }.frame(height:24).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { event in
                    focused = true
                    if !dragging { dragging = true; onEditingChanged(true) }
                    let x = min(width,max(0,event.location.x-8))
                    if let neutral, abs(x-fraction(neutral)*width) <= 3 { value = neutral }
                    else { value = decoded(x/width) }
                }.onEnded { _ in dragging = false; onEditingChanged(false) })
        }.frame(height:24).focusable().focused($focused)
            .onMoveCommand { direction in
                if direction == .left { adjust(-0.005) }
                if direction == .right { adjust(0.005) }
            }
            .accessibilityLabel("Adjust value")
            .accessibilityValue(value.formatted())
            .accessibilityAdjustableAction { direction in
                switch direction { case .increment: adjust(0.01); case .decrement: adjust(-0.01); @unknown default: break }
            }
    }
}
