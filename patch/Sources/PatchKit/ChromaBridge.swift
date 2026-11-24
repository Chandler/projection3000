import Foundation
import PatchCore

/// Small immutable snapshots cross queues. Audio never waits for a video frame.
final class ChromaBridge {
    struct Return {
        var frame: ChromaFrame
        var time: Double
        var frames: Int
        var rejected: Int
        var correlation: Float
        var signalRMS: Float
        var freeRunning: Bool
    }
    private let lock=NSLock()
    private var inputs: [UUID:ChromaFrame]=[:]
    private var outputs: [UUID:Return]=[:]
    func submit(_ frame: ChromaFrame,id: UUID) { lock.withLock { inputs[id]=frame } }
    func input(_ id: UUID) -> ChromaFrame? { lock.withLock { inputs[id] } }
    func output(_ id: UUID) -> Return? { lock.withLock { outputs[id] } }
    func publish(_ receiver: ChromaReceiver,id: UUID,time: Double,freeRunning: Bool = false) {
        guard let frame=receiver.latest else { return }
        lock.withLock { outputs[id]=Return(frame:frame,time:time,frames:receiver.framesReceived,rejected:receiver.rejectedFrames,correlation:receiver.correlation,signalRMS:receiver.signalRMS,freeRunning:freeRunning) }
    }
    func retain(_ ids: Set<UUID>) { lock.withLock { inputs=inputs.filter { ids.contains($0.key) };outputs=outputs.filter { ids.contains($0.key) } } }
    var state: [String:Any] {
        lock.withLock { Dictionary(uniqueKeysWithValues:outputs.map { id,value in
            (id.uuidString,["carrierHz":value.frame.format.carrierHz,"symbolRate":value.frame.format.symbolRate,"colorSignalRMS":value.signalRMS,"mode":value.freeRunning ? "live":"locked","frameID":Int(value.frame.id),"width":value.frame.format.width,"height":value.frame.format.height,"colorFPS":value.frame.format.fps,"framesReceived":value.frames,"rejectedFrames":value.rejected,"pilotCorrelation":value.correlation,"lastFrameHostTime":value.time] as [String:Any])
        }) }
    }
}
