import Foundation
import Darwin
import PatchCore

/// Bounded MIDI handoff from the MIDI scheduler to the audio graph queue.
final class InstrumentMIDIInbox {
    private let lock=NSLock()
    private var messages: [UUID:[[UInt8]]]=[:]
    private var resets=Set<UUID>()
    private var targets=Set<UUID>()
    func configure(_ ids: Set<UUID>) {
        lock.withLock { targets=ids;messages=[:];resets=ids }
    }
    func send(_ bytes: [UInt8],to id: UUID) {
        lock.withLock {
            guard targets.contains(id) else { return }
            if messages[id,default:[]].count>=512 { messages[id]=[];resets.insert(id) }
            messages[id,default:[]].append(bytes)
        }
    }
    func drain(_ id: UUID) -> (Bool,[[UInt8]]) {
        lock.withLock { (resets.remove(id) != nil,messages.removeValue(forKey:id) ?? []) }
    }
    func panic() { lock.withLock { messages=[:];resets=targets } }
}

private final class LoopmotherLibrary {
    typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
    typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias SetValue = @convention(c) (UnsafeMutableRawPointer,Int32,Float) -> Void
    typealias Note = @convention(c) (UnsafeMutableRawPointer,Int32,Float) -> Void
    typealias Render = @convention(c) (UnsafeMutableRawPointer,UnsafePointer<Float>?,UnsafeMutablePointer<Float>,Int32,Double) -> Int32
    let create: Create, destroy: Destroy, reset: Destroy, set: SetValue, note: Note, render: Render
    init() throws {
        let path=Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libPatchAudioPluginHost.dylib").path
        guard let handle=dlopen(path,RTLD_NOW | RTLD_LOCAL) else { throw GraphError("Loopmother engine unavailable; rebuild Patch") }
        func symbol<T>(_ name: String,_ type: T.Type) throws -> T {
            guard let p=dlsym(handle,name) else { throw GraphError("Missing Loopmother function: \(name)") }
            return unsafeBitCast(p,to:T.self)
        }
        create=try symbol("lm_create",Create.self);destroy=try symbol("lm_destroy",Destroy.self)
        reset=try symbol("lm_reset",Destroy.self);set=try symbol("lm_set",SetValue.self)
        note=try symbol("lm_note",Note.self);render=try symbol("lm_render_input",Render.self)
    }
}

/// Instance lifetime and DSP calls are owned exclusively by AudioGraphEngine's queue.
final class LoopmotherInstrument {
    private let library: LoopmotherLibrary
    private let handle: UnsafeMutableRawPointer
    private var rate=0.0
    private var parameters=[String:Double]()
    private var held=Set<Int>(),sustained=Set<Int>(),sustain=false
    private(set) var notesReceived=0
    init() throws {
        library=try LoopmotherLibrary()
        guard let h=library.create() else { throw GraphError("Could not create Loopmother") };handle=h
    }
    deinit { library.destroy(handle) }
    func reset() { library.reset(handle);held=[];sustained=[];sustain=false }
    /// `instrument` is an interleaved stereo block mixed in ahead of the filter.
    func render(node: Node,frames: Int,rate: Double,events: (Bool,[[UInt8]]),instrument: [Float]? = nil) -> [Float] {
        var samples=[Float](repeating:0,count:frames*2)
        // Prepare before delivering notes; rate changes reset the native engine.
        if self.rate != rate {
            _ = library.render(handle,nil,&samples,Int32(frames),rate);self.rate=rate;reset()
        }
        for (i,spec) in LoopmotherStyle.parameters.enumerated() {
            let value=node.value(spec.key)
            if parameters[spec.key] != value { library.set(handle,Int32(i),Float(value));parameters[spec.key]=value }
        }
        if events.0 { reset() }
        for bytes in events.1 {
            guard let status=bytes.first else { continue }
            let kind=status & 0xf0
            if status == 0xfc || status == 0xff { reset();continue }
            guard bytes.count==3 else { continue }
            let note=Int(bytes[1])
            if kind==0x90 && bytes[2]>0 {
                held.insert(note);sustained.remove(note)
                library.note(handle,Int32(note),Float(bytes[2])/127);notesReceived += 1
            } else if kind==0x80 || (kind==0x90 && bytes[2]==0) {
                held.remove(note)
                if sustain { sustained.insert(note) } else { library.note(handle,Int32(note),0) }
            } else if kind==0xb0 {
                if note==120 || note==123 { reset() }
                if note==64 {
                    sustain=bytes[2]>=64
                    if !sustain {
                        for n in sustained.subtracting(held) { library.note(handle,Int32(n),0) };sustained=[]
                    }
                }
            }
        }
        let rendered: Int32
        if let instrument,instrument.count>=frames*2 { rendered=instrument.withUnsafeBufferPointer { library.render(handle,$0.baseAddress,&samples,Int32(frames),rate) } }
        else { rendered=library.render(handle,nil,&samples,Int32(frames),rate) }
        if rendered==0 { reset() }
        return samples
    }
}
