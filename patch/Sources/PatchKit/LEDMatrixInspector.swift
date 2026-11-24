import SwiftUI
import PatchCore

struct LEDMatrixInspector: View {
    @ObservedObject var workspace: Workspace
    let id: UUID
    @State private var colorExpanded = true
    @State private var finishExpanded = false
    var node: Node? { workspace.graph.node(id) }
    func control(_ key: String) -> some View {
        let spec=LEDMatrixStyle.parameters.first { $0.key==key }!
        let binding=Binding<Double>(get:{ node?.value(key) ?? spec.initial },set:{ value in
            guard value.isFinite else { return }
            workspace.parameter(id,key,max(spec.min,min(spec.max,["columns","rows"].contains(key) ? value.rounded() : value)))
        })
        return Group {
            if let choices=spec.choices {
                Picker(spec.title,selection:binding) { ForEach(Array(choices.enumerated()),id:\.offset) { index,title in Text(title).tag(Double(index)) } }.pickerStyle(.menu)
            } else {
                VStack(spacing:4) {
                    HStack { Text(spec.title); Spacer(); TextField(spec.title,value:binding,format:.number.precision(.fractionLength(0...2))).textFieldStyle(.squareBorder).frame(width:64) }
                    if ["columns","rows"].contains(key) {
                        Slider(value:binding,in:spec.min...spec.max,step:1,onEditingChanged:{ editing in
                            if editing { workspace.beginGesture() } else { workspace.endGesture("Adjust LED Matrix") }
                        }).controlSize(.small).accessibilityLabel(spec.title)
                        GeometryReader { geometry in
                            ZStack {
                                ForEach(0..<5) { index in
                                    VStack(spacing:2) {
                                        Rectangle().fill(.secondary).frame(width:1,height:4)
                                        Text(Int(spec.min+(spec.max-spec.min)*Double(index)/4).description)
                                            .font(.editorCaption.monospacedDigit()).foregroundStyle(.secondary)
                                    }.position(x:8+max(0,geometry.size.width-16)*Double(index)/4,y:8)
                                }
                            }
                        }.frame(height:18).accessibilityHidden(true)
                    } else {
                        ParameterControl(value:binding,in:spec.min...spec.max,step:spec.step,showsValueField:false,spec:spec,onEditingChanged:{ editing in if editing { workspace.beginGesture() } else { workspace.endGesture("Adjust LED Matrix") } }).controlSize(.small)
                    }
                }
            }
        }.midiParameter(workspace:workspace,id:id,key:key)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("LED MATRIX").font(.editorHeading).foregroundStyle(.secondary)
            control("columns"); control("grid")
            if node?.value("grid")==1 { control("rows") }
            control("shape"); control("size")
            Divider()
            control("gain"); control("black"); control("gamma")
            section("Color",expanded:$colorExpanded) {
                VStack(spacing:12) {
                    control("color")
                    if node?.value("color")==0 { PoseColorControls(workspace:workspace,id:id) }
                    control("whiteHot")
                }.padding(.top,8)
            }
            section("Finish & Sampling",expanded:$finishExpanded) {
                VStack(spacing:12) { control("glow"); control("idle"); control("sample"); control("invert") }.padding(.top,8)
            }
        }
    }
    private func section<Content: View>(_ title: String,expanded: Binding<Bool>,@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment:.leading,spacing:0) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing:6) {
                    Image(systemName:expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size:10))
                    Text(title)
                    Spacer(minLength:0)
                }.frame(maxWidth:.infinity,minHeight:24,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            if expanded.wrappedValue { content() }
        }
    }
}
