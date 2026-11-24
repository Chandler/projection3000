import Foundation

public struct ChromaFrame: Sendable {
    public let id: UInt16
    public let format: ChromaFormat
    public let colors: [SIMD2<Float>] // Signed, full-range Cb/Cr, each scaled by two.
    public init(id: UInt16, format: ChromaFormat, colors: [SIMD2<Float>]) {
        self.id=id;self.format=format;self.colors=colors
    }
}

private enum ChromaSignal {
    static let pilot: [Float] = {
        var state: UInt32=0x1f
        return (0..<32).map { _ in
            let v: Float = state & 1 == 1 ? 0.7 : -0.7
            let bit=((state >> 4) ^ (state >> 1)) & 1
            state=((state << 1) | bit) & 31
            return v
        }
    }()
    static func checksum(_ id: UInt16) -> UInt8 {
        var crc: UInt8=0
        for byte in [UInt8(id >> 8),UInt8(id & 255)] {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 128 != 0 ? (crc &<< 1) ^ 7 : crc &<< 1 }
        }
        return crc
    }
    // Eight-symbol, beta=.35 root-raised-cosine pulse.
    static func pulse(_ sps: Int) -> [Float] { (0...8*sps).map { i in
        let t=Double(i)/Double(sps)-4,b=0.35
        if abs(t)<1e-9 { return Float(1+b*(4/Double.pi-1)) }
        if abs(abs(t)-1/(4*b))<1e-9 {
            return Float(b/sqrt(2)*((1+2/Double.pi)*sin(Double.pi/(4*b))+(1-2/Double.pi)*cos(Double.pi/(4*b))))
        }
        return Float((sin(Double.pi*t*(1-b))+4*b*t*cos(Double.pi*t*(1+b)))/(Double.pi*t*(1-pow(4*b*t,2))))
    } }
    static func carrier(_ hz: Int) -> [SIMD2<Float>] { (0..<480).map { i in
        let angle=2*Double.pi*Double(hz)*Double(i)/48000
        return SIMD2(Float(cos(angle)),Float(sin(angle)))
    } }
}

/// Queue-owned streaming transmitter. Rendering supplies immutable, bounded frames.
public final class ChromaTransmitter {
    public let format: ChromaFormat
    private let pulse: [Float]
    private let carrier: [SIMD2<Float>]
    private var latest: ChromaFrame?
    private var frame: ChromaFrame?
    private var history=[SIMD2<Float>](repeating:.zero,count:9)
    private var symbol=0,phase=0,clock=0
    public private(set) var framesSent=0
    public init(format: ChromaFormat) {
        self.format=format;pulse=ChromaSignal.pulse(format.samplesPerSymbol);carrier=ChromaSignal.carrier(format.carrierHz)
    }
    public func submit(_ frame: ChromaFrame) {
        if frame.format == format && frame.colors.count == format.pixels { latest=frame }
    }
    private func nextSymbol() -> SIMD2<Float> {
        if symbol == 0 { frame=latest;framesSent += 1 }
        defer { symbol=(symbol+1)%format.symbols }
        if symbol<32 { return SIMD2(ChromaSignal.pilot[symbol],0) }
        if symbol<56 {
            let id=frame?.id ?? 0
            let header=(UInt32(id) << 8) | UInt32(ChromaSignal.checksum(id))
            return SIMD2(header & (1 << (55-symbol)) != 0 ? 0.7 : -0.7,0)
        }
        if symbol<56+format.pixels { return frame?.colors[symbol-56] ?? .zero }
        return .zero
    }
    /// Interleaved PCM at 48 kHz. Only the selected logical channel carries the signal.
    public func render(frames: Int,level: Float,channel: Int = 0) -> [Float] {
        var result=[Float](repeating:0,count:frames*2)
        for i in 0..<frames {
            if phase == 0 {
                for j in stride(from:8,through:1,by:-1) { history[j]=history[j-1] }
                history[0]=nextSymbol()
            }
            var iq=SIMD2<Float>.zero
            for j in 0..<9 {
                let tap=phase+j*format.samplesPerSymbol
                if tap<pulse.count { iq += history[j]*pulse[tap] }
            }
            let oscillator=carrier[clock]
            result[i*2+max(0,min(1,channel))]=max(-1,min(1,level*(iq.x*oscillator.x-iq.y*oscillator.y)))
            phase=(phase+1)%format.samplesPerSymbol;clock=(clock+1)%carrier.count
        }
        return result
    }
}

/// Queue-owned matched receiver. Searches every sample phase, calibrates phase/gain
/// from a known pilot, validates the frame ID CRC, and publishes whole frames only.
public final class ChromaReceiver {
    public let format: ChromaFormat
    private let pulse: [Float]
    private let carrier: [SIMD2<Float>]
    private var ring: [SIMD2<Float>]
    private var ringIndex=0,clock=0,total=0
    private var filtered=[SIMD2<Float>]()
    private var base=0,scan=0
    private var freeStart=0
    private var freeID: UInt16=0
    private var candidate: (start:Int,gain:SIMD2<Float>,quality:Float)?
    public private(set) var framesReceived=0
    public private(set) var rejectedFrames=0
    public private(set) var correlation: Float=0
    public private(set) var signalRMS: Float=0
    public private(set) var latest: ChromaFrame?
    public init(format: ChromaFormat) {
        self.format=format;pulse=ChromaSignal.pulse(format.samplesPerSymbol);carrier=ChromaSignal.carrier(format.carrierHz)
        ring=[SIMD2<Float>](repeating:.zero,count:8*format.samplesPerSymbol+1)
    }
    private func sample(_ index: Int) -> SIMD2<Float> { filtered[index-base] }
    private func corrected(_ value: SIMD2<Float>,gain: SIMD2<Float>) -> SIMD2<Float> {
        let d=max(1e-12,gain.x*gain.x+gain.y*gain.y)
        return SIMD2((value.x*gain.x+value.y*gain.y)/d,(value.y*gain.x-value.x*gain.y)/d)
    }
    public func append(_ interleaved: [Float],channel: Int,freeRunning: Bool = false,gain: Float = 1,scanPhase: Double = 0) -> [ChromaFrame] {
        var completed=[ChromaFrame]()
        let sps=format.samplesPerSymbol
        for i in 0..<interleaved.count/2 {
            let x=interleaved[i*2+max(0,min(1,channel))],oscillator=carrier[clock]
            ring[ringIndex]=SIMD2(2*x*oscillator.x,-2*x*oscillator.y)
            var sum=SIMD2<Float>.zero
            for j in pulse.indices { sum += ring[(ringIndex-j+ring.count)%ring.count]*pulse[j] }
            filtered.append(sum/Float(sps))
            ringIndex=(ringIndex+1)%ring.count;clock=(clock+1)%carrier.count;total += 1
        }
        if freeRunning {
            let period=format.symbols*sps
            let offset=Int((max(0,min(1,scanPhase))*Double(period)).rounded())%period
            while freeStart+period<=total {
                var energy: Float=0
                let colors=(0..<format.pixels).map { j -> SIMD2<Float> in
                    // Ignore pilot/CRC validity. A local scan assigns every received
                    // color sample a position; phase rolls that scan through the frame.
                    let raw=sample(freeStart+((56+j)*sps+offset)%period)
                    energy += raw.x*raw.x+raw.y*raw.y
                    let value=raw*gain
                    return SIMD2(max(-2,min(2,value.x)),max(-2,min(2,value.y)))
                }
                signalRMS=sqrt(energy/Float(format.pixels))
                freeID = freeID == UInt16.max ? 1:freeID+1
                let frame=ChromaFrame(id:freeID,format:format,colors:colors)
                latest=frame;completed.append(frame);framesReceived += 1
                freeStart += period
            }
            if freeStart-base>4096 { filtered.removeFirst(freeStart-base);base=freeStart }
            return completed
        }
        // Look ahead one symbol so a local maximum chooses the timing center.
        while scan+32*sps+sps/2 < total {
            if let c=candidate {
                guard c.start+(56+format.pixels-1)*sps < total else { break }
                var header: UInt32=0
                for j in 32..<56 { header=(header << 1) | (corrected(sample(c.start+j*sps),gain:c.gain).x>0 ? 1:0) }
                let id=UInt16(header >> 8)
                if UInt8(header & 255) == ChromaSignal.checksum(id),id != 0 {
                    let colors=(0..<format.pixels).map { j -> SIMD2<Float> in
                        let color=corrected(sample(c.start+(56+j)*sps),gain:c.gain)
                        return SIMD2(max(-2,min(2,color.x)),max(-2,min(2,color.y)))
                    }
                    let frame=ChromaFrame(id:id,format:format,colors:colors)
                    latest=frame;completed.append(frame);framesReceived += 1;correlation=c.quality
                    // Leave room for small clock slips; every frame acquires a new pilot.
                    scan=c.start+(format.symbols-2)*sps
                } else { rejectedFrames += 1;scan=c.start+sps }
                candidate=nil
                continue
            }
            func measure(_ start: Int) -> (Float,SIMD2<Float>) {
                var gain=SIMD2<Float>.zero,energy: Float=0
                for j in 0..<32 {
                    let z=sample(start+j*sps);gain += z*ChromaSignal.pilot[j]
                    energy += z.x*z.x+z.y*z.y
                }
                let pilotEnergy: Float=32*0.49
                let power=gain.x*gain.x+gain.y*gain.y
                return (energy>1e-9 ? power/(pilotEnergy*energy):0,gain/pilotEnergy)
            }
            let score=measure(scan)
            if score.0>0.88 {
                var best=(scan,score)
                for offset in 1...sps/2 { let next=measure(scan+offset);if next.0>best.1.0 { best=(scan+offset,next) } }
                candidate=(best.0,best.1.1,best.1.0)
            } else { scan += 1 }
        }
        let keepFrom=max(base,min(total,min(scan,candidate?.start ?? scan)-16))
        if keepFrom-base>4096 { filtered.removeFirst(keepFrom-base);base=keepFrom }
        return completed
    }
}
