import Foundation

/// One second of stereo history, shared by XY and time-domain scopes.
final class StereoHistory {
    private let lock=NSLock()
    let sampleRate: Double
    private var points: [SIMD2<Float>]
    init(sampleRate: Double = 48000) { self.sampleRate=sampleRate;points=[SIMD2<Float>](repeating:.zero,count:Int(sampleRate)) }
    private var cursor=0,count=0
    func append(_ samples: [Float]) {
        guard samples.count >= 2 else { return }
        lock.withLock {
            for i in stride(from:0,to:samples.count-1,by:2) {
                let x=samples[i],y=samples[i+1]
                points[cursor]=SIMD2(x.isFinite ? x:0,y.isFinite ? y:0)
                cursor=(cursor+1)%points.count;count=min(points.count,count+1)
            }
        }
    }
    func latest(_ requested: Int) -> [SIMD2<Float>] {
        lock.withLock {
            let n=min(count,max(0,requested)),start=(cursor-n+points.count)%points.count
            return (0..<n).map { points[(start+$0)%points.count] }
        }
    }
}
