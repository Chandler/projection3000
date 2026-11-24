import Foundation

extension NodeKind {
    public var isMIDINode: Bool { [.metroSequencer,.midiIn,.midiOut,.midiFilter,.midiTransform,.midiMonitor,.midiMerge,.arpeggiator].contains(self) }
}
public enum MIDIRoutingStyle {
    public static let channels=["All channels"]+(1...16).map { "Channel \($0)" }
    public static let filterParameters: [ParameterSpec] = [
        .init("channel","Accept channel",0,16,0,choices:channels,midi:false,step:1),
        .init("notes","Notes",0,1,1,choices:["Block","Pass"],midi:false,step:1),
        .init("lowNote","Lowest note",0,127,0,midi:false,step:1),
        .init("highNote","Highest note",0,127,127,midi:false,step:1),
        .init("cc","Controllers",0,1,1,choices:["Block","Pass"],midi:false,step:1),
        .init("bend","Pitch bend",0,1,1,choices:["Block","Pass"],midi:false,step:1),
        .init("pressure","Aftertouch",0,1,1,choices:["Block","Pass"],midi:false,step:1),
        .init("program","Program changes",0,1,0,choices:["Block","Pass"],midi:false,step:1),
        .init("clock","Clock ticks",0,1,0,choices:["Block","Pass"],midi:false,step:1),
        .init("transport","Start / Stop / Position",0,1,0,choices:["Block","Pass"],midi:false,step:1)
    ]
    public static let transformParameters: [ParameterSpec] = [
        .init("channel","Output channel",0,16,0,choices:["Keep incoming"]+(1...16).map { "Channel \($0)" },midi:false,step:1),
        .init("transpose","Transpose (semitones)",-48,48,0,midi:false,step:1),
        .init("velocity","Velocity multiplier",0.05,2,1,midi:false),
        .init("ccFrom","Remap CC (-1 disables)",-1,127,-1,midi:false,step:1),
        .init("ccTo","Destination CC",0,127,1,midi:false,step:1)
    ]
    public static func process(_ bytes: [UInt8],node: Node) -> [UInt8]? {
        guard let status=bytes.first else { return nil }
        // Pausing a MIDI node stops its branch, including filters and transforms.
        guard node.enabled else { return nil }
        let kind=status&0xf0
        if node.kind == .midiFilter {
            let ch=Int(node.value("channel"))
            if status<0xf0 && ch>0 && Int(status&15)+1 != ch { return nil }
            let key: String
            switch kind {
            case 0x80,0x90:
                guard bytes.count==3,Int(bytes[1])>=Int(node.value("lowNote")),Int(bytes[1])<=Int(node.value("highNote")) else { return nil }
                key="notes"
            case 0xa0,0xd0: key="pressure"
            case 0xb0: key="cc"
            case 0xc0: key="program"
            case 0xe0: key="bend"
            default:
                if status==0xf8 { key="clock" }
                else if [0xfa,0xfb,0xfc,0xf2].contains(status) { key="transport" }
                else { return nil }
            }
            return node.value(key)>0.5 ? bytes:nil
        }
        if node.kind == .midiTransform {
            var result=bytes
            let channel=Int(node.value("channel"))
            if status<0xf0 && channel>0 { result[0]=kind|UInt8(channel-1) }
            if [0x80,0x90,0xa0].contains(kind) && bytes.count==3 {
                let note=Int(bytes[1])+Int(node.value("transpose"))
                guard (0...127).contains(note) else { return nil }
                result[1]=UInt8(note)
                if kind==0x90 && bytes[2]>0 { result[2]=UInt8(max(1,min(127,Int((Double(bytes[2])*node.value("velocity")).rounded())))) }
            }
            if kind==0xb0 && bytes.count==3 && Int(bytes[1])==Int(node.value("ccFrom")) { result[1]=UInt8(node.value("ccTo")) }
            return result
        }
        return bytes
    }
}

/// MIDI 1.0 stream parser: packets may split messages; realtime can interrupt them.
/// SysEx is deliberately discarded, including split packets, rather than routing
/// firmware/configuration writes through a musical performance graph.
public struct MIDIStreamDecoder {
    private var running: UInt8=0
    private var pending: [UInt8]=[]
    private var sysex=false
    public init() {}
    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        var result=[[UInt8]]()
        for b in bytes {
            if b>=0xf8 { if [0xf8,0xfa,0xfb,0xfc,0xff].contains(b) { result.append([b]) };continue }
            if b==0xf0 { sysex=true;running=0;pending=[];continue }
            if b==0xf7 { sysex=false;pending=[];continue }
            if sysex { continue }
            if b>=0x80 {
                pending=[];running=b<0xf0 ? b:0
                if b==0xf6 { result.append([b]);continue }
                if b==0xf4 || b==0xf5 { continue }
                pending=[b]
            } else {
                if pending.isEmpty { if running==0 { continue };pending=[running] }
                pending.append(b)
            }
            guard let status=pending.first else { continue }
            let length: Int
            if status==0xf1 || status==0xf3 || status&0xf0==0xc0 || status&0xf0==0xd0 { length=2 }
            else { length=3 }
            if pending.count==length { result.append(pending);pending=[] }
        }
        return result
    }
}
