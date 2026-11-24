import Foundation

public enum MetroStyle {
    public static let sets=[[0,3,7,10],[0,3,7],[0,4,7],[0,4,7,11],[0,2,3,5,7,8,10],[0,2,3,5,7,9,10],[0,2,4,5,7,9,11],[0,3,5,7,10],Array(0...11)]
    public static let setNames=["Minor 7 chord","Minor chord","Major chord","Major 7 chord","Minor scale","Dorian","Major scale","Minor pentatonic","Chromatic"]
    public static let orders=["Linear","Pendulum","Ping Pong","Odd / Even","Shuffle","Random"]
    public static let gates=["Hold","Multi","Single","Rest"]
    public static let parameters: [ParameterSpec] = {
        var p: [ParameterSpec]=[
            .init("bpm","Tempo",20,300,120), .init("root","Root",0,11,9,choices:ArpeggiatorStyle.roots,midi:true,step:1),
            .init("set","Pitch set",0,Double(sets.count-1),0,choices:setNames,midi:true,step:1)]
        let pitches=[0,1,2,3,4,2,1,3],pulses=[3,1,2,2,1,3,2,2],gates=[1,2,1,3,1,1,0,2]
        for s in 0..<8 {
            p += [.init("pitch\(s)","Stage \(s+1) pitch degree",0,16,Double(pitches[s]),step:1),
                  .init("pulses\(s)","Stage \(s+1) pulses",1,8,Double(pulses[s]),step:1),
                  .init("gate\(s)","Stage \(s+1) gate",0,3,Double(gates[s]),choices:MetroStyle.gates,midi:true,step:1)]
        }
        for t in 0..<2 {
            let k="t\(t)_"
            p += [.init(k+"mute","Track \(t+1) mute",0,1,Double(t),choices:["Play","Mute"],midi:true,step:1),
                  .init(k+"channel","MIDI channel",1,16,Double(t+1),step:1),
                  .init(k+"octave","Base octave",0,6,t==0 ? 2:1,step:1),
                  .init(k+"order","Order",0,5,0,choices:orders,midi:true,step:1),
                  .init(k+"reverse","Direction",0,1,0,choices:["Forward","Reverse"],midi:true,step:1),
                  .init(k+"length","Stages",1,8,t==0 ? 8:4,step:1),
                  .init(k+"offset","Stage offset",0,7,0,step:1),
                  .init(k+"division","Clock divide",1,64,t==0 ? 1:2,step:1),
                  .init(k+"pulseDiv","Pulse divide",1,8,1,step:1),
                  .init(k+"cycle","Cycle pulses (0 = Auto)",0,64,0,step:1),
                  .init(k+"swing","Swing (%)",50,78,50),
                  .init(k+"gateLength","Gate (%)",5,95,55),
                  .init(k+"velocity","Velocity",1,127,90,step:1),
                  .init(k+"limit","Accumulation limit",1,28,4,step:1),
                  .init(k+"boundary","Accumulation boundary",0,1,0,choices:["Wrap","Pendulum"],midi:true,step:1),
                  .init(k+"freeze","Accumulator",0,1,0,choices:["Move","Freeze"],midi:true,step:1),
                  .init(k+"chanceMode","Chance evaluated per",0,1,0,choices:["Stage","Pulse"],midi:true,step:1)]
            for s in 0..<8 {
                p += [.init(k+"skip\(s)","Skip \(s+1)",0,1,0,choices:["Play","Skip"],midi:true,step:1),
                      .init(k+"ratchet\(s)","Ratchets \(s+1)",1,8,1,step:1),
                      .init(k+"chance\(s)","Chance \(s+1) (%)",0,100,100),
                      .init(k+"accum\(s)","Accumulate \(s+1) degrees",-7,7,0,step:1)]
            }
        };return p
    }()
    public static func note(_ node: Node,track: Int,stage: Int,offset: Int = 0) -> Int {
        let set=sets[min(sets.count-1,max(0,Int(node.value("set"))))]
        let degree=Int(node.value("pitch\(stage)"))+offset
        let octave=Int(floor(Double(degree)/Double(set.count)))
        let index=((degree % set.count)+set.count)%set.count
        let n=12*(Int(node.value("t\(track)_octave"))+1)+Int(node.value("root"))+octave*12+set[index]
        // Fold by octaves rather than clamp to a different pitch class.
        return n<0 ? ((n%12)+12)%12 : n>127 ? n-12*Int(ceil(Double(n-127)/12)):n
    }
}

public struct MetroEvent {
    public var time: Double
    public var track: Int
    public var bytes: [UInt8]
}
/// Runs on the MIDI queue. Views never own the transport or its note lifetimes.
public final class MetroSequencer {
    private struct Cursor {
        var index=0, pulse=0, total=0, stage=0
        var seed: UInt64=0xabc123
    }
    private final class Track {
        var cursor=Cursor(), shadow: Cursor?
        var loop: ClosedRange<Int>?
        var next: Double
        var ticks=0
        var offset=Array(repeating:0,count:8), directions=Array(repeating:1,count:8)
        var currentOffset=0
        var allowed=true, held=false
        var note: Int?, channel=0
        var active=Set<Int>()
        var lastPulse=0
        var pending=[MetroEvent]()
        var shuffled=Array(0..<8)
        var seed: UInt64
        init(now: Double,seed: UInt64) { next=now;self.seed=seed;shuffle() }
        func shuffle() {
            shuffled=Array(0..<8)
            for j in stride(from:7,through:1,by:-1) { shuffled.swapAt(j,min(j,Int(random()*Double(j+1)))) }
        }
        func random() -> Double { seed=seed &* 6364136223846793005 &+ 1442695040888963407;return Double(seed>>11)/9007199254740992 }
    }
    public var node: Node
    private var tracks: [Track]
    public init(_ node: Node,now: Double) {
        self.node=node;tracks=[Track(now:now,seed:0x12345),Track(now:now,seed:0x87654)]
    }
    private func val(_ t: Int,_ key: String) -> Double { node.value("t\(t)_"+key) }
    public func silence(now: Double) -> [MetroEvent] {
        var out=[MetroEvent]()
        for (i,t) in tracks.enumerated() {
            for key in t.active.sorted() { out.append(.init(time:now,track:i,bytes:[UInt8(0x80+key/128),UInt8(key%128),0])) }
            t.active=[];t.note=nil;t.held=false;t.pending=[]
        };return out
    }
    public func action(_ action: String,track: Int = 0,start: Int = 0,end: Int = 0,now: Double) -> [MetroEvent] {
        if action=="reset" { let out=silence(now:now);for t in tracks { t.cursor=Cursor();t.shadow=nil;t.loop=nil;t.next=now;t.ticks=0;t.offset=Array(repeating:0,count:8);t.directions=Array(repeating:1,count:8);t.shuffle() };return out }
        let t=tracks[max(0,min(1,track))]
        if action=="accumReset" { t.offset=Array(repeating:0,count:8);t.directions=Array(repeating:1,count:8);t.currentOffset=0 }
        if action=="loop" {
            if t.shadow==nil { t.shadow=t.cursor }
            t.loop=min(start,end)...max(start,end);t.cursor=Cursor()
        }
        if action=="release" { if let shadow=t.shadow { t.cursor=shadow };t.shadow=nil;t.loop=nil }
        return []
    }
    private func itinerary(_ i: Int,_ t: Track,loop: ClosedRange<Int>?) -> [Int] {
        var a: [Int]
        if let loop { a=Array(loop) }
        else { a=(0..<Int(val(i,"length"))).map { ($0+Int(val(i,"offset")))%8 }.filter { val(i,"skip\($0)")<0.5 } }
        if val(i,"reverse")>0.5 { a.reverse() }
        guard !a.isEmpty else { return [] }
        if loop != nil { return a }
        switch Int(val(i,"order")) {
        case 1: return a+Array(a.dropFirst().dropLast().reversed())
        case 2: return a+Array(a.reversed())
        case 3: return a.enumerated().filter { $0.offset%2==0 }.map(\.element)+a.enumerated().filter { $0.offset%2==1 }.map(\.element)
        case 4:
            let shuffled=t.shuffled.filter { a.contains($0) }
            return val(i,"reverse")>0.5 ? Array(shuffled.reversed()):shuffled
        default:return a
        }
    }
    private func pulse(_ c: inout Cursor,_ i: Int,_ t: Track,loop: ClosedRange<Int>?,random: Bool) -> (Int,Int,Bool)? {
        let a=itinerary(i,t,loop:loop)
        guard !a.isEmpty else { c=Cursor();return nil }
        let limit=Int(val(i,"cycle"))
        if loop==nil && limit>0 && c.total>=limit { c=Cursor() }
        if c.pulse==0 || !a.contains(c.stage) {
            c.index %= a.count
            if random && loop==nil && Int(val(i,"order"))==5 {
                c.seed=c.seed &* 6364136223846793005 &+ 1442695040888963407
                c.stage=a[Int((c.seed>>32)%UInt64(a.count))]
            } else { c.stage=a[c.index] }
            c.pulse=0
        }
        let result=(c.stage,c.pulse,c.pulse==0)
        c.pulse += 1;c.total += 1
        if c.pulse>=Int(node.value("pulses\(c.stage)")) { c.pulse=0;c.index=(c.index+1)%a.count }
        return result
    }
    public func advance(now: Double) -> [MetroEvent] {
        var output=[MetroEvent]()
        for (i,t) in tracks.enumerated() {
            let muted=val(i,"mute")>0.5
            if muted {
                for key in t.active.sorted() { output.append(.init(time:now,track:i,bytes:[UInt8(0x80+key/128),UInt8(key%128),0])) };t.active=[];t.note=nil;t.pending=[];t.held=false
            }
            if now>=t.next {
                let base=60/node.value("bpm")/4*val(i,"division")
                if now-t.next>base { // No late burst after a stalled scheduler.
                    for key in t.active.sorted() { output.append(.init(time:now,track:i,bytes:[UInt8(0x80+key/128),UInt8(key%128),0])) };t.active=[];t.note=nil;t.pending=[];t.held=false;t.next=now
                }
                let at=t.next
                let swing=val(i,"swing")/100
                let interval=2*base*(t.ticks%2==0 ? swing:1-swing)
                t.next += interval;t.ticks += 1
                if var shadow=t.shadow { _=pulse(&shadow,i,t,loop:nil,random:true);t.shadow=shadow }
                if let (stage,p,entry)=pulse(&t.cursor,i,t,loop:t.loop,random:true) {
                    t.lastPulse=p+1
                    let chance=val(i,"chance\(stage)")/100
                    if entry || val(i,"chanceMode")>0.5 { t.allowed=t.random()<chance }
                    let gate=Int(node.value("gate\(stage)"))
                    if entry {
                        t.currentOffset=t.offset[stage]
                        if !muted && t.allowed && gate != 3 && val(i,"freeze")<0.5 {
                            let amount=Int(val(i,"accum\(stage)")),bound=Int(val(i,"limit"))
                            if amount != 0 {
                                let sign=amount<0 ? -1:1
                                var x=t.offset[stage]*sign+abs(amount)*t.directions[stage]
                                if Int(val(i,"boundary"))==0 { if x>bound || x<0 { x=0 } }
                                else { while x>bound || x<0 { if x>bound { x=2*bound-x;t.directions[stage] = -1 };if x<0 { x = -x;t.directions[stage]=1 } } }
                                t.offset[stage]=x*sign
                            }
                        }
                    }
                    if !muted {
                        let eligible=t.allowed && (gate==0 ? entry:gate==1 ? p%Int(val(i,"pulseDiv"))==0:gate==2 ? entry:false)
                        if gate==3 || !t.allowed {
                            if let n=t.note { t.pending.append(.init(time:at,track:i,bytes:[UInt8(0x80+t.channel),UInt8(n),0])) };t.held=false
                        } else if eligible {
                            let n=MetroStyle.note(node,track:i,stage:stage,offset:t.currentOffset),ch=Int(val(i,"channel"))-1
                            let repeats=gate==0 ? 1:Int(val(i,"ratchet\(stage)"))
                            for r in 0..<repeats {
                                let on=at+interval*Double(r)/Double(repeats)
                                if r==0 && t.held,let old=t.note {
                                    if old != n || ch != t.channel {
                                        t.pending.append(.init(time:on,track:i,bytes:[UInt8(0x90+ch),UInt8(n),UInt8(val(i,"velocity"))]))
                                        t.pending.append(.init(time:on+0.0001,track:i,bytes:[UInt8(0x80+t.channel),UInt8(old),0]))
                                    }
                                } else {
                                    t.pending.append(.init(time:on,track:i,bytes:[UInt8(0x90+ch),UInt8(n),UInt8(val(i,"velocity"))]))
                                }
                                if gate != 0 { t.pending.append(.init(time:on+interval/Double(repeats)*val(i,"gateLength")/100,track:i,bytes:[UInt8(0x80+ch),UInt8(n),0])) }
                            }
                            t.held=gate==0
                        }
                    }
                } else if let n=t.note { t.pending.append(.init(time:at,track:i,bytes:[UInt8(0x80+t.channel),UInt8(n),0]));t.held=false }
            }
            t.pending.sort { $0.time<$1.time }
            while let e=t.pending.first,e.time<=now {
                t.pending.removeFirst();output.append(e)
                let key=Int(e.bytes[0]&15)*128+Int(e.bytes[1])
                if e.bytes[0]&0xf0==0x90 { t.active.insert(key);t.note=Int(e.bytes[1]);t.channel=Int(e.bytes[0]&15) }
                else { t.active.remove(key);if t.note==Int(e.bytes[1]) && t.channel==Int(e.bytes[0]&15) { t.note=nil } }
            }
        }
        return output.sorted { $0.time<$1.time }
    }
    public var state: [[String:Any]] {
        tracks.enumerated().map { i,t in ["stage":t.cursor.stage+1,"pulse":t.lastPulse,"ticks":t.ticks,"note":t.note as Any? ?? NSNull(),"accumulation":t.currentOffset,"loop":t.loop.map { [$0.lowerBound+1,$0.upperBound+1] } as Any? ?? NSNull(),"shadowStage":t.shadow.map { $0.stage+1 } as Any? ?? NSNull(),"muted":val(i,"mute")>0.5] }
    }
}
