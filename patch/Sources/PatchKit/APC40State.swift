import Foundation
import PatchCore

/// Shared by the controller and the render/audio queues of one editor.
final class APC40State: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [Double?](repeating:nil,count:APC40.outputs.count)
    var snapshot: [Double?] { lock.withLock { values } }
    func reset() { lock.withLock { values = Array(repeating:nil,count:APC40.outputs.count) } }
    func set(output: Int,value: Double?) {
        guard APC40.outputs.indices.contains(output),value?.isFinite != false else { return }
        lock.withLock { values[output] = value.map { max(0,min(1,$0)) } }
    }
    func receive(status: Int,number: Int,value: Int) {
        guard let output = APC40.output(status:status,number:number) else { return }
        let normalized = status & 0xf0 == 0x80 ? 0 : Double(max(0,min(127,value)))/127
        set(output:output,value:normalized)
    }
}
