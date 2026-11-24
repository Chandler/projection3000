import Foundation
import PatchCore

struct SignalObservation {
    let label: String
    let fields: [String:Any]
}

extension Renderer {
    /// Reads the last available value without making an idle branch a render consumer.
    func observation(of node: Node, output: Int, graph: Graph) -> SignalObservation? {
        guard let type = node.kind.outputType(at:output) else { return nil }
        if !node.enabled { return .init(label:node.kind.pausedStatus,fields:["enabled":false]) }
        switch type {
        case .control:
            let value: Double?
            if node.kind == .apc40 {
                let values = apcState.snapshot
                value = values.indices.contains(output) ? values[output] : nil
            } else { value = controlValues[node.id] }
            return value.map { .init(label:$0.formatted(.number.precision(.fractionLength(0...3))),fields:["value":$0]) }
        case .audio:
            guard let block = audioGraph.snapshot.0[node.id] else { return nil }
            let peak: Float
            if let channel = node.kind.audioChannel(at:output) {
                peak = stride(from:channel,to:block.samples.count,by:2).reduce(0) { max($0,abs(block.samples[$1])) }
            } else { peak = block.peak }
            let db = peak > 0 ? String(format:"%.1f dBFS",20*log10(peak)) : "−∞ dBFS"
            return .init(label:String(format:"%.1f kHz",block.sampleRate/1000)+" · "+db,
                         fields:["sampleRate":block.sampleRate,"peak":peak,"hostTime":block.hostTime])
        case .video:
            let size = graph.videoDimensions(node.id)
            return .init(label:"\(size.width) × \(size.height)",fields:["width":size.width,"height":size.height])
        case .drawRate:
            return audioGraph.drawRates[node.id].map { .init(label:String(format:"%.2f Hz",$0),fields:["hertz":$0]) }
        case .palette:
            return colorPalette(node.id).map { .init(label:"\($0.colors.count) colors",fields:["colors":$0.colors.count]) }
        case .poses:
            return poseFrame(node.id).map { .init(label:"\($0.poses.count) poses",fields:["poses":$0.poses.count,"hostTime":$0.timestamp]) }
        case .faces:
            return faceFrame(node.id).map { .init(label:"\($0.faces.count) faces",fields:["faces":$0.faces.count,"hostTime":$0.timestamp]) }
        default:
            let text = type == .midi ? midiGraph.status[node.id] : status[node.id]
            return text.map { .init(label:$0,fields:["status":$0]) }
        }
    }
}
