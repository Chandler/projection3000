import Foundation

/// Timestamped MIDI 1.0 messages. MIDI Out supplies the destination channel.
public struct MIDIEvent: Sendable {
    public var time: Double
    public var bytes: [UInt8]
    public init(time: Double,bytes: [UInt8]) { self.time=time;self.bytes=bytes }
}
public enum ArpeggiatorStyle {
    public static let roots=["C","C♯","D","E♭","E","F","F♯","G","A♭","A","B♭","B"]
    public static let chordNames=["Major","Minor","Dominant 7","Major 7","Minor 7","Sus 2","Sus 4","Diminished","Augmented","Power fifth"]
    public static let chords=[[0,4,7],[0,3,7],[0,4,7,10],[0,4,7,11],[0,3,7,10],[0,2,7],[0,5,7],[0,3,6],[0,4,8],[0,7]]
    public static let patterns=["Up","Down","Up / Down","Down / Up","Random"]
    public static let parameters: [ParameterSpec] = [
        .init("root","Root note",0,11,0,choices:roots,midi:true,step:1),
        .init("octave","Root octave",0,6,3,step:1),
        .init("chord","Chord",0,9,1,choices:chordNames,midi:true,step:1),
        .init("inversion","Inversion",0,3,0,step:1),
        .init("octaves","Octave range",1,4,2,step:1),
        .init("pattern","Pattern",0,4,2,choices:patterns,midi:true,step:1),
        .init("bpm","Tempo (BPM)",20,300,110),
        .init("division","Note division",0,4,1,choices:["1/4","1/8","1/16","1/8 triplet","1/16 triplet"],midi:true,step:1),
        .init("gate","Gate length",0.05,0.95,0.6),
        .init("velocity","Velocity",1,127,90,step:1)
    ]
    public static let outputParameters: [ParameterSpec] = [.init("channel","MIDI channel",0,16,1,choices:["Keep incoming"]+(1...16).map { "Channel \($0)" },midi:false,step:1)]
    public static func duration(_ node: Node) -> Double {
        60/node.value("bpm")*[1.0,0.5,0.25,1.0/3,1.0/6][Int(node.value("division"))]
    }
    public static func notes(_ node: Node) -> [Int] {
        let root=12*(Int(node.value("octave"))+1)+Int(node.value("root"))
        var chord=chords[Int(node.value("chord"))]
        for _ in 0..<Int(node.value("inversion")) { chord.append(chord.removeFirst()+12) }
        return (0..<Int(node.value("octaves"))).flatMap { octave in chord.map { root+$0+12*octave } }.filter { (0...127).contains($0) }.sorted()
    }
    public static func sequence(_ node: Node) -> [Int] {
        let notes=notes(node)
        switch Int(node.value("pattern")) {
        case 1: return Array(notes.reversed())
        case 2: return notes+Array(notes.dropFirst().dropLast().reversed())
        case 3: return Array(notes.reversed())+Array(notes.dropFirst().dropLast())
        default: return notes
        }
    }
    public static func noteName(_ note: Int) -> String { roots[max(0,min(127,note))%12]+String(note/12-1) }
}
