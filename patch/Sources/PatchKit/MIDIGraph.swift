import Foundation
import CoreMIDI
import QuartzCore
import PatchCore

struct MIDIOutputDevice: Identifiable {
    var id: String
    var name: String
    var endpoint: MIDIEndpointRef
    static var devices: [Self] { endpoints(input:false) }
    static var inputs: [Self] { endpoints(input:true) }
    private static func endpoints(input: Bool) -> [Self] {
        (0..<(input ? MIDIGetNumberOfSources():MIDIGetNumberOfDestinations())).compactMap { index in
            let endpoint=input ? MIDIGetSource(index):MIDIGetDestination(index)
            var uid: Int32=0,offline: Int32=0,name: Unmanaged<CFString>?
            guard endpoint != 0,MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&uid)==noErr else { return nil }
            _ = MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyOffline,&offline)
            guard offline==0 else { return nil }
            _ = MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&name)
            return Self(id:String(uid),name:name?.takeRetainedValue() as String? ?? "MIDI",endpoint:endpoint)
        }
    }
}

/// Hardware MIDI and generated arps share one serial scheduler, independent of rendering.
final class MIDIGraphEngine {
    private let instruments: InstrumentMIDIInbox
    private final class Source {
        var node: Node
        var index=0
        var next: Double
        var off: Double?
        var note: Int?
        var steps: UInt64=0
        init(_ node: Node,now: Double) { self.node=node;next=now+0.003 }
    }
    private final class Route {
        let node: Node
        let device: MIDIOutputDevice
        let path: [UUID]
        // Wire channel*128+note. Counts preserve overlapping notes in merged streams.
        var active: [Int:Int]=[:]
        var sustain=Set<Int>()
        var messages: UInt64=0,notes: UInt64=0
        var lastNote: Int?
        var error: String?
        init(node: Node,device: MIDIOutputDevice,path: [UUID]) { self.node=node;self.device=device;self.path=path }
    }
    private let queue=DispatchQueue(label:"patch.midi.graph",qos:.userInteractive)
    private let lock=NSLock()
    private var timer: DispatchSourceTimer?
    private var client: MIDIClientRef=0,port: MIDIPortRef=0,inputPort: MIDIPortRef=0
    private var graph=Graph(),playing=true,stopped=false
    private var metros: [UUID:MetroSequencer]=[:]
    private var sources: [UUID:Source]=[:],routes: [String:Route]=[:]
    private var devices=[MIDIOutputDevice](),inputs=[MIDIOutputDevice]()
    private var connected=Set<MIDIEndpointRef>()
    private var decoders: [MIDIEndpointRef:MIDIStreamDecoder]=[:]
    private var nextScan=0.0,nextPublish=0.0
    private var messages: [UUID:String]=[:],published: [String:Any]=[:]
    private var recent: [UUID:[[String:Any]]]=[:],counts: [UUID:UInt64]=[:]
    private var signature="",failure: String?
    private var inputErrors: [MIDIEndpointRef:String]=[:]
    var status: [UUID:String] { lock.withLock { messages } }
    var state: [String:Any] { lock.withLock { published } }
    init(instruments: InstrumentMIDIInbox) {
        self.instruments=instruments
        let result=MIDIClientCreateWithBlock("Patch MIDI Graph" as CFString,&client) { [weak self] _ in
            self?.queue.async { [weak self] in self?.refresh() }
        }
        if result != noErr { failure="Core MIDI unavailable (\(result))" }
        else {
            let out=MIDIOutputPortCreate(client,"Patch MIDI Out" as CFString,&port)
            if out != noErr { failure="MIDI output unavailable (\(out))" }
            let input=MIDIInputPortCreateWithBlock(client,"Patch MIDI In" as CFString,&inputPort) { [weak self] packets,context in
                guard let self,let context else { return }
                let endpoint=MIDIEndpointRef(UInt(bitPattern:context))
                // Copy packet bytes inside CoreMIDI's callback; never retain its pointers.
                var bytes=[UInt8]()
                var packet=UnsafeRawPointer(packets).advanced(by:MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to:MIDIPacket.self)
                for _ in 0..<packets.pointee.numPackets {
                    let data=UnsafeRawPointer(packet).advanced(by:MemoryLayout<MIDIPacket>.offset(of: \.data)!).assumingMemoryBound(to:UInt8.self)
                    bytes.append(contentsOf:UnsafeBufferPointer(start:data,count:Int(packet.pointee.length)))
                    packet=UnsafePointer(MIDIPacketNext(packet))
                }
                let copy=bytes
                self.queue.async { [weak self] in self?.receive(copy,endpoint:endpoint) }
            }
            if input != noErr { failure="MIDI input unavailable (\(input))" }
        }
        resume()
    }
    func resume() {
        guard timer == nil else { return }
        queue.sync { stopped=false; graph=Graph(); signature="" }
        let timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:.milliseconds(1),leeway:.microseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer=timer;timer.resume()
    }
    func update(_ graph: Graph,playing: Bool) {
        queue.async { [weak self] in
            guard let self,!self.stopped,self.graph != graph || self.playing != playing else { return }
            if self.graph.edges != graph.edges || self.playing != playing {
                for (id,metro) in self.metros { self.emitMetro(metro.silence(now:CACurrentMediaTime()),id:id) }
            } else {
                for (id,metro) in self.metros where graph.node(id)?.enabled != true {
                    self.emitMetro(metro.silence(now:CACurrentMediaTime()),id:id)
                }
            }
            self.graph=graph;self.playing=playing;self.refresh()
        }
    }
    private func emitMetro(_ events: [MetroEvent],id: UUID) {
        for event in events { emit(event.bytes,at:id,path:[],outputs:[event.track,2]) }
    }
    func metroAction(_ id: UUID,action: String,track: Int = 0,start: Int = 0,end: Int = 0) {
        queue.async { [weak self] in
            guard let self,let metro=self.metros[id] else { return }
            self.emitMetro(metro.action(action,track:track,start:start,end:end,now:CACurrentMediaTime()),id:id)
            self.publish()
        }
    }
    func panic(_ id: UUID? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            for route in self.routes.values where id==nil || route.path.contains(id!) { self.silence(route) }
            self.instruments.panic()
            self.publish()
        }
    }
    func stop() {
        timer?.cancel();timer=nil
        queue.sync {
            stopped=true
            instruments.configure([])
            metros=[:]
            for route in routes.values { silence(route) }
            for endpoint in connected { MIDIPortDisconnectSource(inputPort,endpoint) }
            connected=[];routes=[:];sources=[:];publish()
        }
    }
    deinit {
        timer?.cancel()
        for route in routes.values { silence(route) }
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }
    private func pathKey(_ path: [UUID]) -> String { path.map(\.uuidString).joined(separator:"/") }
    private func refresh() {
        guard !stopped else { return }
        guard !stopped else { return }
        let now=CACurrentMediaTime()
        devices=MIDIOutputDevice.devices;inputs=MIDIOutputDevice.inputs;nextScan=now+0.5
        // Layout and inspector selection do not interrupt held notes. Musical edits do:
        // release with the old mapping before installing a new filter/transpose/channel.
        let midi=graph.nodes.filter { $0.kind.isMIDINode || $0.kind == .loopmother }
        let ids=Set(midi.map(\.id))
        let parts=midi.map { n in if n.kind == .loopmother || n.kind == .metroSequencer { return "\(n.id):loopmother:\(n.enabled)" }; return "\(n.id):\(n.kind.rawValue):\(n.enabled):\(n.deviceID ?? ""):\(n.parameters.sorted { $0.key<$1.key }.map { "\($0.key)=\($0.value)" }.joined(separator:","))" }
        let edges=graph.edges.filter { ids.contains($0.source) && ids.contains($0.target) }.map { "\($0.id):\($0.source):\($0.outputIndex):\($0.target):\($0.input)" }.sorted()
        let endpoints=(devices+inputs).map { "\($0.id):\($0.endpoint)" }.joined(separator:",")
        let next=([String(playing),endpoints]+parts+edges).joined(separator:";")
        if next != signature {
            for (id,metro) in metros { emitMetro(metro.silence(now:now),id:id) }
            instruments.configure(Set(midi.filter { $0.kind == .loopmother && $0.enabled && playing }.map(\.id)))
            for route in routes.values { silence(route) }
            routes=[:];signature=next
            if playing && failure==nil {
                for node in midi where node.kind == .midiOut && node.enabled {
                    guard let device=devices.first(where:{ $0.id==node.deviceID }) else { continue }
                    for path in paths(to:node.id,visited:[]) {
                        routes[pathKey(path)]=Route(node:node,device:device,path:path)
                    }
                }
            }
        }
        let wanted=Set(midi.filter { $0.kind == .midiIn && $0.enabled && playing }.compactMap { n in inputs.first { $0.id==n.deviceID }?.endpoint })
        for endpoint in connected.subtracting(wanted) { MIDIPortDisconnectSource(inputPort,endpoint);decoders.removeValue(forKey:endpoint);inputErrors.removeValue(forKey:endpoint) }
        connected.formIntersection(wanted)
        if inputPort != 0 {
            for endpoint in wanted.subtracting(connected) {
                let result=MIDIPortConnectSource(inputPort,endpoint,UnsafeMutableRawPointer(bitPattern:UInt(endpoint)))
                if result==noErr { connected.insert(endpoint);decoders[endpoint]=MIDIStreamDecoder();inputErrors.removeValue(forKey:endpoint) }
                else { inputErrors[endpoint]="MIDI connection failed (\(result))" }
            }
        }
        let activeMetro=Set(midi.filter { $0.kind == .metroSequencer && $0.enabled && playing }.map(\.id))
        metros=metros.filter { activeMetro.contains($0.key) }
        for id in activeMetro {
            if let node=graph.node(id) {
                if let metro=metros[id] { metro.node=node } else { metros[id]=MetroSequencer(node,now:now+0.003) }
            }
        }
        let active=Set(midi.filter { $0.kind == .arpeggiator && $0.enabled && playing }.map(\.id))
        sources=sources.filter { active.contains($0.key) }
        for id in active {
            guard let node=graph.node(id) else { continue }
            if let source=sources[id] {
                if source.node.parameters != node.parameters {
                    let ratio=ArpeggiatorStyle.duration(node)/ArpeggiatorStyle.duration(source.node)
                    source.next=now+max(0,source.next-now)*ratio
                    if let off=source.off { source.off=now+max(0,off-now)*ratio }
                    source.node=node
                }
            } else { sources[id]=Source(node,now:now) }
        }
        recent=recent.filter { ids.contains($0.key) };counts=counts.filter { ids.contains($0.key) }
        publish()
    }
    private func paths(to id: UUID,visited: Set<UUID>) -> [[UUID]] {
        guard !visited.contains(id),visited.count<64,let node=graph.node(id),node.kind.isMIDINode,node.enabled else { return [] }
        if node.kind == .midiIn {
            guard inputs.contains(where:{ $0.id==node.deviceID }) else { return [] };return [[id]]
        }
        if node.kind == .arpeggiator || node.kind == .metroSequencer { return [[id]] }
        var result=[[UUID]](),seen=visited;seen.insert(id)
        let incoming=graph.edges.filter { $0.target==id }
        for edge in incoming {
            for path in paths(to:edge.source,visited:seen) {
                if result.count>=256 { return result }
                result.append(path+[edge.id,id])
            }
        }
        return result
    }
    private func receive(_ bytes: [UInt8],endpoint: MIDIEndpointRef) {
        guard playing,!stopped,connected.contains(endpoint),let device=inputs.first(where:{ $0.endpoint==endpoint }) else { return }
        var decoder=decoders[endpoint] ?? MIDIStreamDecoder()
        let events=decoder.feed(bytes);decoders[endpoint]=decoder
        for node in graph.nodes where node.kind == .midiIn && node.enabled && node.deviceID==device.id {
            for event in events { emit(event,at:node.id,path:[]) }
        }
    }
    private func tick() {
        guard !stopped else { return }
        let now=CACurrentMediaTime()
        if now>=nextScan { refresh() }
        for (id,metro) in metros { emitMetro(metro.advance(now:now),id:id) }
        for (id,source) in sources {
            if let off=source.off,now>=off,let note=source.note {
                emit([0x80,UInt8(note),0],at:id,path:[]);source.note=nil;source.off=nil
            }
            guard now>=source.next else { continue }
            let duration=ArpeggiatorStyle.duration(source.node)
            if now-source.next>duration { source.index += Int((now-source.next)/duration);source.next=now }
            if let note=source.note { emit([0x80,UInt8(note),0],at:id,path:[]) }
            let sequence=ArpeggiatorStyle.sequence(source.node)
            guard !sequence.isEmpty else { continue }
            let note=Int(source.node.value("pattern"))==4 ? sequence.randomElement()!:sequence[source.index%sequence.count]
            emit([0x90,UInt8(note),UInt8(source.node.value("velocity").rounded())],at:id,path:[])
            source.note=note;source.off=source.next+duration*source.node.value("gate")
            source.next += duration;source.index=(source.index+1)%sequence.count;source.steps += 1
        }
        if now>=nextPublish { publish();nextPublish=now+0.05 }
    }
    private func emit(_ bytes: [UInt8],at id: UUID,path: [UUID],outputs: Set<Int>? = nil) {
        if let node=graph.node(id),node.kind == .loopmother {
            if node.enabled && playing { instruments.send(bytes,to:id) };return
        }
        guard path.count<64,!path.contains(id),let node=graph.node(id),node.kind.isMIDINode else { return }
        guard let processed=MIDIRoutingStyle.process(bytes,node:node) else { return }
        let next=path+[id]
        counts[id,default:0] += 1
        if node.kind == .midiMonitor || node.kind == .midiIn {
            let text=describe(processed)
            recent[id,default:[]].append(["time":CACurrentMediaTime(),"message":text,"bytes":processed.map(Int.init)])
            if recent[id,default:[]].count>32 { recent[id]?.removeFirst() }
        }
        if node.kind == .midiOut {
            guard let route=routes[pathKey(next)] else { return }
            send(processed,to:route);return
        }
        for edge in graph.edges where edge.source==id && (outputs?.contains(edge.outputIndex) ?? (edge.outputIndex==0)) {
            emit(processed,at:edge.target,path:next+[edge.id])
        }
    }
    private func transmit(_ bytes: [UInt8],device: MIDIOutputDevice) -> OSStatus {
        guard port != 0,!bytes.isEmpty,bytes.count<=3 else { return -1 }
        var list=MIDIPacketList()
        return withUnsafeMutablePointer(to:&list) { pointer in
            let packet=MIDIPacketListInit(pointer)
            _ = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(pointer,MemoryLayout<MIDIPacketList>.size,packet,0,$0.count,$0.baseAddress!) }
            return MIDISend(port,device.endpoint,pointer)
        }
    }
    private func otherOwner(_ route: Route,key: Int) -> Bool {
        routes.values.contains { $0 !== route && $0.device.endpoint==route.device.endpoint && ($0.active[key] ?? 0)>0 }
    }
    private func send(_ input: [UInt8],to route: Route) {
        guard let status=input.first else { return }
        var bytes=input
        let channel=Int(route.node.value("channel"))
        if status<0xf0 && channel>0 { bytes[0]=(status&0xf0)|UInt8(channel-1) }
        let kind=bytes[0]&0xf0,ch=Int(bytes[0]&15)
        let noteKey=bytes.count>=3 ? ch*128+Int(bytes[1]):-1
        let on=kind==0x90 && bytes.count==3 && bytes[2]>0
        let off=(kind==0x80 || kind==0x90 && bytes.count==3 && bytes[2]==0) && bytes.count==3
        if off {
            guard let count=route.active[noteKey],count>0 else { return }
            if count>1 { route.active[noteKey]=count-1;return }
            route.active.removeValue(forKey:noteKey)
            if otherOwner(route,key:noteKey) { return }
        }
        // Treat channel panic messages as releasing this branch's ownership.
        if kind==0xb0 && bytes.count==3 && [120,123].contains(bytes[1]) { silence(route,channel:ch);return }
        if bytes[0]==0xff { silence(route);return }
        let result=transmit(bytes,device:route.device)
        guard result==noErr else { route.error="MIDI send failed (\(result))";return }
        route.error=nil;route.messages += 1
        if on { route.active[noteKey,default:0] += 1;route.lastNote=Int(bytes[1]);route.notes += 1 }
        if kind==0xb0 && bytes.count==3 && bytes[1]==64 {
            if bytes[2]>=64 { route.sustain.insert(ch) } else { route.sustain.remove(ch) }
        }
    }
    private func silence(_ route: Route,channel: Int? = nil) {
        for key in Array(route.active.keys) where channel==nil || key/128==channel {
            route.active.removeValue(forKey:key)
            if !otherOwner(route,key:key) { _ = transmit([0x80|UInt8(key/128),UInt8(key%128),0],device:route.device) }
        }
        for ch in Array(route.sustain) where channel==nil || channel==ch {
            route.sustain.remove(ch)
            let owned=routes.values.contains { $0 !== route && $0.device.endpoint==route.device.endpoint && $0.sustain.contains(ch) }
            if !owned { _ = transmit([0xb0|UInt8(ch),64,0],device:route.device) }
        }
    }
    private func describe(_ bytes: [UInt8]) -> String {
        guard let s=bytes.first else { return "" }
        let channel="ch \(Int(s&15)+1)"
        if bytes.count==3 {
            switch s&0xf0 {
            case 0x90: return "\(channel) \(bytes[2]==0 ? "Off":"On") \(ArpeggiatorStyle.noteName(Int(bytes[1]))) · \(bytes[2])"
            case 0x80: return "\(channel) Off \(ArpeggiatorStyle.noteName(Int(bytes[1])))"
            case 0xb0: return "\(channel) CC \(bytes[1]) = \(bytes[2])"
            case 0xe0: return "\(channel) Bend \(Int(bytes[1])+Int(bytes[2])*128-8192)"
            default: break
            }
        }
        if s==0xf8 { return "Clock" };if s==0xfa { return "Start" };if s==0xfb { return "Continue" };if s==0xfc { return "Stop" }
        return bytes.map { String(format:"%02X",$0) }.joined(separator:" ")
    }
    private func publish() {
        var status: [UUID:String]=[:],outputs: [String:Any]=[:],arps: [String:Any]=[:],nodes: [String:Any]=[:]
        for node in graph.nodes where node.kind.isMIDINode {
            let owned=routes.values.filter { $0.node.id==node.id }
            if !node.enabled { status[node.id]=node.kind.pausedStatus }
            else if !playing { status[node.id]="Transport paused" }
            else if node.kind == .midiIn {
                if let device=inputs.first(where:{ $0.id==node.deviceID }) { status[node.id]=inputErrors[device.endpoint] ?? "\(device.name) · \(counts[node.id] ?? 0) messages" }
                else { status[node.id]=node.deviceID==nil ? "Choose MIDI input":"MIDI input disconnected" }
            } else if node.kind == .metroSequencer {
                status[node.id]=String(format:"%.1f BPM · 8 stages · A / B",node.value("bpm"))
            } else if node.kind == .arpeggiator {
                status[node.id]=String(format:"%.1f BPM · %@",node.value("bpm"),sources[node.id]?.note.map(ArpeggiatorStyle.noteName) ?? "rest")
            } else if node.kind == .midiOut {
                if let first=owned.first {
                    status[node.id]=owned.compactMap(\.error).first ?? "\(first.device.name) · \(owned.reduce(0) { $0+$1.notes }) notes sent"
                    outputs[node.id.uuidString]=["device":first.device.name,"deviceID":first.device.id,"channel":Int(node.value("channel")),"notesSent":owned.reduce(0) { $0+$1.notes },"messagesSent":owned.reduce(0) { $0+$1.messages },"activeNotes":owned.flatMap { $0.active.keys.sorted().map { ["channel":$0/128+1,"note":$0%128] } },"error":owned.compactMap(\.error).first as Any? ?? NSNull()]
                } else { status[node.id]=failure ?? (node.deviceID==nil ? "Choose MIDI output":!devices.contains { $0.id==node.deviceID } ? "MIDI output disconnected":"Connect an active MIDI source") }
            } else { status[node.id]="\(counts[node.id] ?? 0) messages · \(recent[node.id]?.last?["message"] as? String ?? "Waiting for MIDI")" }
            nodes[node.id.uuidString]=["messages":(counts[node.id] ?? 0) as UInt64,"recent":(recent[node.id] ?? []) as [[String:Any]],"status":(status[node.id] ?? "") as String]
            if node.kind == .arpeggiator { arps[node.id.uuidString]=["notes":ArpeggiatorStyle.notes(node),"steps":sources[node.id]?.steps ?? 0,"activeNote":sources[node.id]?.note as Any? ?? NSNull()] }
        }
        lock.withLock { self.messages=status;published=["metro":Dictionary(uniqueKeysWithValues:metros.map { ($0.key.uuidString,$0.value.state) }),"outputs":outputs,"arpeggiators":arps,"nodes":nodes,"devices":devices.map { ["id":$0.id,"name":$0.name] },"inputs":inputs.map { ["id":$0.id,"name":$0.name] },"sysex":"blocked"] }
    }
}
