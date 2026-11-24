import Foundation

public struct VideoDimensions: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(_ width: Int,_ height: Int) { self.width=width; self.height=height }
    public var aspect: Double { Double(width)/Double(max(1,height)) }
}

extension Graph {
    /// Sources use the project canvas except Projection Dots, which follows paper proportions. Effects inherit input A.
    public func videoDimensions(_ id: UUID?) -> VideoDimensions {
        var visited = Set<UUID>()
        func resolve(_ id: UUID?) -> VideoDimensions {
            let canvas = VideoDimensions(width,height)
            guard let id, visited.insert(id).inserted, let node = node(id) else { return canvas }
            if node.kind == .rasterSynth || node.kind == .layerMux || node.kind == .voltageVisualizer || node.kind == .voltageFluid || node.kind == .oscilloscope || node.kind == .projector { return canvas }
            if node.kind.outputType == .collection || node.kind.outputType == .trace { return VideoDimensions(640,360) }
            if node.kind.previewKind == .palette { return VideoDimensions(640,160) }
            if node.kind == .posterText || node.kind == .posterComposer { return PosterStyle.dimensions(node) }
            if node.kind == .meshGradient || node.kind == .mux { return canvas }
            if node.kind == .chromaEncoder { return resolve(edges.first { $0.target == id && $0.input == 0 }?.source) }
            if node.kind.isAudioNode || node.kind.outputType == .control { return VideoDimensions(640,240) }
            if node.kind.outputType == .dots { return ProjectionDotsStyle.outputDimensions(dotPreviewGeometry(node.id),canvas:canvas) }
            if node.kind == .projectionDots { return ProjectionDotsStyle.outputDimensions(node,canvas:canvas) }
            if node.kind.inputs.isEmpty || node.kind == .render || node.kind == .waveform || node.kind == .audioVisualizer { return canvas }
            let source = edges.first { $0.target == id && $0.input == (node.kind == .chromaDecoder ? 1:0) }?.source
            let input = resolve(source)
            if node.enabled && node.hasLiquidSculptureControls && node.value("quality")<1.5 {
                let divisor=node.value("quality")<0.5 ? 4:2
                return VideoDimensions(max(1,input.width/divisor),max(1,input.height/divisor))
            }
            return node.enabled && node.kind == .crop ? CropStyle.outputDimensions(node,input:input) : input
        }
        return resolve(id)
    }
}
