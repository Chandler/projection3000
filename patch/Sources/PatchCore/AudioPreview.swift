import Foundation

extension Graph {
    /// Audio audition follows the selected signal, without adding graph cables.
    public func audioPreviewSource(_ id: UUID?) -> UUID? {
        var visited: Set<UUID> = []
        func analogBranch(_ id: UUID,seen: Set<UUID> = []) -> Bool {
            guard !seen.contains(id),let n=node(id) else { return false }
            if [.rasterSynth,.chromaEncoder,.chromaDecoder,.voltageEncoder,.voltageVisualizer,.voltageFluid,.oscilloscope,.audioInput].contains(n.kind) { return true }
            return edges.filter { $0.target == id }.contains { analogBranch($0.source,seen:seen.union([id])) }
        }
        func resolve(_ id: UUID?) -> UUID? {
            guard let id,visited.insert(id).inserted,let node = node(id) else { return nil }
            // XY hardware paths must never be auditioned through the system speakers.
            if [.rasterSynth,.chromaEncoder,.chromaDecoder,.voltageEncoder,.voltageVisualizer,.voltageFluid,.oscilloscope,.audioInput].contains(node.kind) || (node.kind == .audioOutput && node.deviceID != nil) { return nil }
            if node.kind.isAudioNode || node.kind == .video { return analogBranch(id) ? nil:id }
            // A recorder previews exactly its explicit audio input. Analysis and
            // visualization nodes audition the audio they are analyzing.
            if let index = node.kind.inputTypes.firstIndex(of:.audio) {
                return edges.first { $0.target == id && $0.input == index }?.source
            }
            // Video-only effects/window previews follow their primary picture
            // source's audio; they do not invent an audio mix for a visual blend.
            if let index = node.kind.inputTypes.firstIndex(of:.video) {
                return resolve(edges.first { $0.target == id && $0.input == index }?.source)
            }
            return nil
        }
        return resolve(id)
    }
}
