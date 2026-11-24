import AppKit
import Combine
import CoreMIDI
import Darwin
import PatchCore

private final class MIDILease {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vibe MIDI")
    var fd: Int32 = -1
    var seen = ""
    var requestValue: String { (try? String(contentsOf:folder.appendingPathComponent("APC40-mkII.request"))) ?? "" }
    init() { seen = requestValue }
    func request() {
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        seen = "Patch:"+UUID().uuidString
        try? seen.write(to:folder.appendingPathComponent("APC40-mkII.request"),atomically:true,encoding:.utf8)
    }
    func shouldYield() -> Bool {
        let value = requestValue; defer { seen = value }
        return value != seen && !value.isEmpty && !value.hasPrefix("Patch:")
    }
    func acquire() -> Bool {
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let handle = Darwin.open(folder.appendingPathComponent("APC40-mkII.lock").path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        guard handle >= 0 else { return false }
        guard flock(handle,LOCK_EX|LOCK_NB) == 0 else { Darwin.close(handle); return false }
        fd = handle
        try? "Patch".write(to:folder.appendingPathComponent("APC40-mkII.owner"),atomically:true,encoding:.utf8)
        return true
    }
    func release() { if fd >= 0 { flock(fd,LOCK_UN); Darwin.close(fd); fd = -1 } }
    deinit { release() }
}

struct MIDIDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: MIDIEndpointRef
    var isAPC: Bool { name.lowercased().contains("apc40") && (name.lowercased().contains("mkii") || name.lowercased().contains("mk2")) }
    var mappingID: String { isAPC ? "apc40mkII" : id }
}
struct MIDITarget: Equatable { let node: UUID; let key: String }

final class MIDIController: ObservableObject {
    unowned let workspace: Workspace
    let apcState: APC40State
    private var apcNodeID: UUID?
    var ownsAPC: Bool { workspace.graph.nodes.contains { $0.kind == .apc40 } }
    func setAPCControl(output: Int,value: Double?) throws {
        guard ownsAPC else { throw GraphError("Add an APC40 node first") }
        guard APC40.outputs.indices.contains(output),value?.isFinite != false,
              value.map({ (0...1).contains($0) }) ?? true else { throw GraphError("Expected an APC output and a value from 0 to 1, or null") }
        syncAPCNode()
        apcState.set(output:output,value:value)
        if output == 25,let value { receiveCrossfader(value) }
        lastMessage = "GUI/API · \(APC40.outputs[output]) · \(value.map { String(format:"%.3f",$0) } ?? "Base")"
    }
    func receiveAPC(status: Int,number: Int,value: Int) {
        syncAPCNode()
        if status == 0xb0 && number == 15 { receiveCrossfader(Double(value)/127) }
        guard ownsAPC else { return }
        apcState.receive(status:status,number:number,value:value)
        lastMessage = "APC · \(APC40.output(status:status,number:number).map { APC40.outputs[$0] } ?? "MIDI") · \(value)"
    }
    private func syncAPCNode() {
        let id = workspace.graph.nodes.first { $0.kind == .apc40 }?.id
        if id != apcNodeID { apcState.reset(); pending.removeAll(); apcNodeID = id }
    }
    @Published var devices: [MIDIDevice] = []
    @Published private(set) var selection: String
    @Published private(set) var connected: MIDIDevice?
    @Published private(set) var status = "Starting"
    @Published private(set) var learning = false
    @Published private(set) var target: MIDITarget?
    @Published private(set) var lastMessage = ""
    @Published private(set) var faderPosition: Double?
    @Published private(set) var followNode: UUID?
    @Published private(set) var channelFaders = [Double?](repeating:nil,count:8)
    var followsChannelFaders: Bool { !ownsAPC && workspace.graph.nodes.contains { ($0.kind == .mux || $0.kind == .layerMux) && $0.enabled && $0.value("followAPC") == 1 } }
    var followsCrossfader: Bool { followNode.map { workspace.graph.node($0)?.kind == .ab } ?? false }
    private let hostAPC: Bool
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var destination: MIDIEndpointRef = 0
    private var generation = UUID()
    private let lease = MIDILease()
    private var scanTimer: Timer?
    private var controlTimer: Timer?
    private var pending: [Int:Int] = [:]
    private var rawValues: [Int:Int] = [:]
    private var latched = Set<UUID>()
    private var previous: [UUID:Double] = [:]
    private var applied: [UUID:Double] = [:]
    private var mappingSnapshot: [MIDIMapping] = []
    private var accepting = false
    private var legacyCheckInFlight = false
    private var legacyCheckedAt: Date?
    private var legacyVJOwnsAPC = false

    init(workspace: Workspace,apcState: APC40State,enabled: Bool = true,hostAPC: Bool = false) {
        self.workspace = workspace
        self.apcState = apcState
        self.hostAPC = hostAPC
        selection = UserDefaults.standard.string(forKey:"midiInput") ?? "auto"
        workspace.midi = self
        guard enabled else { status = "Off"; return }
        let result = MIDIClientCreateWithBlock("Patch MIDI" as CFString,&client) { [weak self] _ in
            DispatchQueue.main.async { self?.scan() }
        }
        guard result == noErr else { status = "MIDI unavailable (\(result))"; return }
        accepting = true
        scanTimer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in self?.scan() }
        controlTimer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in self?.flush() }
        RunLoop.main.add(controlTimer!,forMode:.common)
        scan()
    }
    func suspend() {
        accepting=false; scanTimer?.invalidate(); controlTimer?.invalidate()
        scanTimer=nil; controlTimer=nil
        let savedFollow=followNode; disconnect(); followNode=savedFollow; lease.release()
        if port != 0 { MIDIPortDispose(port); port=0 }
        if outputPort != 0 { MIDIPortDispose(outputPort); outputPort=0 }
        if client != 0 { MIDIClientDispose(client); client=0 }
        status="Stopped"
    }
    deinit {
        scanTimer?.invalidate(); controlTimer?.invalidate()
        if port != 0 { MIDIPortDispose(port) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }
    private func name(_ object: MIDIObjectRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object,kMIDIPropertyDisplayName,&value) == noErr else { return "MIDI" }
        return value?.takeRetainedValue() as String? ?? "MIDI"
    }
    func select(_ id: String) {
        disconnect(); selection = id; UserDefaults.standard.set(id,forKey:"midiInput")
        if !hostAPC && (id == "auto" || devices.first(where:{ $0.id == id })?.isAPC == true) { lease.request() }
        scan()
    }
    private func disconnect() {
        generation = UUID()
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if outputPort != 0 { MIDIPortDispose(outputPort); outputPort = 0 }
        destination = 0; connected = nil; faderPosition = nil
        channelFaders = [Double?](repeating:nil,count:8)
        pending.removeAll(); rawValues.removeAll(); latched.removeAll(); applied.removeAll(); previous.removeAll(); lease.release()
    }
    func scan() {
        guard accepting else { return }
        if !hostAPC && lease.shouldYield(), connected?.isAPC == true || selection == "auto" || devices.first(where:{ $0.id == selection })?.isAPC == true {
            disconnect(); selection = "off"; status = "In use by VJ"
            // A handoff is session-local; Patch may discover the APC on its next launch.
            return
        }
        var found: [MIDIDevice] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(i); var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&uid)
            found.append(.init(id:String(uid),name:name(endpoint),endpoint:endpoint))
        }
        if devices != found { devices = found }
        if let current = connected, !found.contains(current) { disconnect() }
        guard connected == nil else { return }
        guard selection != "off" else { if status != "In use by VJ" { status = "Off" }; return }
        let matches = selection == "auto" ? found.filter(\.isAPC) : found.filter { $0.id == selection }
        guard matches.count == 1, let device = matches.first else { status = matches.isEmpty ? "Disconnected" : "Select a device"; return }
        if device.isAPC && hostAPC { status = "APC via VJ Native"; return }
        if device.isAPC {
            checkLegacyVJ()
            guard legacyCheckedAt != nil else { status = "Checking VJ"; return }
            guard !legacyVJOwnsAPC else { status = "Restart VJ to release APC"; return }
        }
        if device.isAPC && !lease.acquire() { status = "In use by VJ"; return }
        connect(device)
    }
    // Older VJ releases did not participate in the shared controller lease.
    // Check that runtime before opening ports or sending APC mode messages.
    private func checkLegacyVJ() {
        guard !legacyCheckInFlight,legacyCheckedAt.map({ Date().timeIntervalSince($0) > 3 }) ?? true else { return }
        legacyCheckInFlight = true
        var request = URLRequest(url:URL(string:"http://127.0.0.1:9100/api/v1/state")!)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with:request) { [weak self] data,_,_ in
            let object = data.flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any]
            let state = object?["state"] as? [String:Any]
            let midi = state?["midi"] as? [String:Any]
            let selected = midi?["selected"] as? String ?? ""
            let legacy = selected.lowercased().contains("apc40") && midi?["cooperative"] as? Bool != true
            DispatchQueue.main.async {
                guard let self else { return }
                self.legacyVJOwnsAPC = legacy; self.legacyCheckedAt = Date(); self.legacyCheckInFlight = false
                self.scan()
            }
        }.resume()
    }
    private func connect(_ device: MIDIDevice) {
        let token = generation
        var running: UInt8 = 0, data: [UInt8] = []
        let result = MIDIInputPortCreateWithBlock(client,"Patch Controls" as CFString,&port) { [weak self] list,_ in
            var pointer = UnsafeRawPointer(list).advanced(by:MemoryLayout<MIDIPacketList>.offset(of:\.packet)!).assumingMemoryBound(to:MIDIPacket.self)
            var messages: [(Int,Int,Int)] = []
            for _ in 0..<list.pointee.numPackets {
                let length = Int(pointer.pointee.length)
                let bytes = UnsafeRawPointer(pointer).advanced(by:MemoryLayout<MIDIPacket>.offset(of:\.data)!).assumingMemoryBound(to:UInt8.self)
                for i in 0..<length {
                    let byte = bytes[i]
                    if byte >= 0xF8 { continue }
                    if byte & 0x80 != 0 { running = byte < 0xF0 ? byte : 0; data.removeAll(keepingCapacity:true); continue }
                    guard running != 0 else { continue }
                    data.append(byte)
                    let count = running & 0xE0 == 0xC0 ? 1 : 2
                    if data.count == count {
                        if [0x80,0x90,0xB0].contains(running & 0xF0) { messages.append((Int(running),Int(data[0]),Int(data[1]))) }
                        data.removeAll(keepingCapacity:true)
                    }
                }
                pointer = UnsafePointer(MIDIPacketNext(pointer))
            }
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                for (status,number,value) in messages {
                    if device.isAPC && self.ownsAPC { self.receiveAPC(status:status,number:number,value:value) }
                    else if status & 0xf0 == 0xb0 { self.receive(channel:status & 15,cc:number,value:value) }
                }
            }
        }
        guard result == noErr, MIDIPortConnectSource(port,device.endpoint,nil) == noErr else {
            disconnect(); status = "MIDI connection failed (\(result))"; return
        }
        connected = device; status = "Connected"
        if device.isAPC {
            let outputs = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }.filter { name($0).lowercased().contains("apc40") }
            if outputs.count == 1, MIDIOutputPortCreate(client,"Patch Feedback" as CFString,&outputPort) == noErr {
                destination = outputs[0]
                send([0xF0,0x47,0x7F,0x29,0x60,0,4,0x41,1,0,0,0xF7])
            }
        }
    }
    private func send(_ bytes: [UInt8]) {
        guard outputPort != 0, destination != 0 else { return }
        var list = MIDIPacketList()
        withUnsafeMutablePointer(to:&list) { pointer in
            let packet = MIDIPacketListInit(pointer)
            bytes.withUnsafeBufferPointer { data in
                _ = MIDIPacketListAdd(pointer,MemoryLayout<MIDIPacketList>.size,packet,0,data.count,data.baseAddress!)
            }
            MIDISend(outputPort,destination,pointer)
        }
    }
    // A/B routing is global and independent of the APC node and editor focus.
    private func receiveCrossfader(_ value: Double) {
        guard value.isFinite,(0...1).contains(value) else { return }
        if faderPosition != value { faderPosition = value }
        guard let id = followNode,workspace.graph.node(id)?.kind == .ab,
              workspace.graph.node(id)?.value("mix") != value else { return }
        applyValues([(id,"mix",value)])
    }
    func receiveHostFader(_ value: Double?) {
        // With Follow enabled, fresh CC messages arrive via receiveAPC instead.
        // Do not overwrite them with Composer's older cached fader position.
        guard hostAPC,!ownsAPC,!followsCrossfader else { return }
        if faderPosition != value { faderPosition = value }
    }
    func receiveHostChannelFaders(_ values: [Double]) {
        guard hostAPC,values.count == 8 else { return }
        let valid = values.map { $0.isFinite && (0...1).contains($0) ? Optional($0) : nil }
        if channelFaders != valid { channelFaders = valid }
        applyMuxFaders()
    }
    private func applyMuxFaders() {
        guard !ownsAPC else { return }
        var values: [(UUID,String,Double)] = []
        for node in workspace.graph.nodes where (node.kind == .mux || node.kind == .layerMux) && node.enabled && node.value("followAPC") == 1 {
            for channel in 0..<node.channelCount {
                let key = "level\(channel+1)"
                if let value = channelFaders[channel],node.value(key) != value { values.append((node.id,key,value)) }
            }
        }
        applyValues(values)
    }
    func toggleLearn() { setLearning(!learning) }
    func setLearning(_ enabled: Bool) { target = nil; learning = enabled }
    func arm(_ node: UUID,_ key: String) {
        guard workspace.graph.node(node)?.midiParameters.contains(where:{ $0.key == key }) == true else { return }
        let next = MIDITarget(node:node,key:key)
        if target == next { setLearning(false) } else { learning = true; target = next }
    }
    func mapping(_ node: UUID,_ key: String) -> MIDIMapping? { workspace.graph.midiMappings?.first { $0.node == node && $0.key == key } }
    func bind(node: UUID,key: String,channel: Int,cc: Int,device: String? = nil) throws {
        guard let spec = workspace.graph.node(node)?.midiParameters.first(where:{ $0.key == key }), let device = device ?? connected?.mappingID else { throw GraphError("Choose a MIDI device and parameter") }
        var binding = mapping(node,key) ?? MIDIMapping(node:node,key:key,device:device,channel:channel,cc:cc,minimum:spec.min,maximum:spec.max)
        binding.device = device; binding.channel = channel; binding.cc = cc
        var graph = workspace.graph; try graph.bindMIDI(binding); try workspace.apply(graph,action:"Learn MIDI")
        target = nil; latched.removeAll(); applied.removeAll(); previous.removeAll()
    }
    func setFollow(_ id: UUID?,enabled: Bool) throws {
        if let id,[NodeKind.mux,.layerMux].contains(workspace.graph.node(id)?.kind ?? .mux) {
            var graph = workspace.graph; try graph.setParameter(id,key:"followAPC",value:enabled ? 1 : 0)
            try workspace.apply(graph,action:"Follow APC"); applyMuxFaders(); return
        }
        if !enabled { if id == nil || followNode == id { followNode = nil }; return }
        guard let id,workspace.graph.node(id)?.kind == .ab else { throw GraphError("Choose an A/B or MUX node") }
        if workspace.graph.node(id)?.modulations?["mix"] != nil {
            var graph = workspace.graph
            if let index = graph.nodes.firstIndex(where:{ $0.id == id }) { graph.nodes[index].modulations?.removeValue(forKey:"mix") }
            try workspace.apply(graph,action:"Follow APC")
        }
        followNode = id
        if let value = faderPosition { receiveCrossfader(value) }
    }
    private func receive(channel: Int,cc: Int,value: Int) {
        let code = channel*128+cc
        let old = rawValues[code]; rawValues[code] = value
        if connected?.isAPC == true && channel == 0 && cc == 15 {
            if learning && target != nil { lastMessage = "CC 15 · A/B only" }
            faderPosition = Double(value)/127; pending[code] = value; return
        }
        if connected?.isAPC == true && channel < 8 && cc == 7 {
            channelFaders[channel] = Double(value)/127
            if followsChannelFaders { pending[code] = value; return }
        }
        if learning {
            if let target,old != value {
                do { try bind(node:target.node,key:target.key,channel:channel,cc:cc); lastMessage = "Mapped · Ch \(channel+1) CC \(cc)" }
                catch { lastMessage = error.localizedDescription }
            }
            return
        }
        pending[code] = value
    }
    private func flush() {
        syncAPCNode()
        if let id = followNode,workspace.graph.node(id)?.kind != .ab { followNode = nil }
        if ownsAPC && connected?.isAPC == true { pending.removeAll(); return }
        if !hostAPC { applyMuxFaders() }
        let bindings = workspace.graph.midiMappings ?? []
        if bindings != mappingSnapshot { mappingSnapshot = bindings; latched.removeAll(); applied.removeAll(); previous.removeAll() }
        guard let device = connected,!pending.isEmpty else { return }
        let events = pending; pending.removeAll(keepingCapacity:true)
        var values: [(UUID,String,Double)] = []
        if device.isAPC,let raw = events[15],let id = followNode { values.append((id,"mix",Double(raw)/127)) }
        for binding in bindings where binding.enabled && binding.device == device.mappingID {
            if device.isAPC && binding.channel == 0 && binding.cc == 15 { continue }
            if device.isAPC && followsChannelFaders && binding.cc == 7 && binding.channel < 8 { continue }
            guard let raw = events[binding.channel*128+binding.cc],let node = workspace.graph.node(binding.node),
                  let spec = node.midiParameters.first(where:{ $0.key == binding.key }),
                  node.modulations?[binding.key]?.enabled != true,
                  !(followNode == node.id && binding.key == "mix"),
                  !((node.kind == .mux || node.kind == .layerMux) && node.value("followAPC") == 1 && binding.key.hasPrefix("level")) else { continue }
            let current = node.value(binding.key),value = binding.value(raw,spec:spec)
            if let last = applied[binding.id], abs(last-current) > 0.000001 { latched.remove(binding.id); previous.removeValue(forKey:binding.id) }
            let crossed = previous[binding.id].map { (min($0,value)...max($0,value)).contains(current) } ?? false
            let tolerance = max((spec.step ?? 0)/2,abs(binding.maximum-binding.minimum)/254)
            previous[binding.id] = value
            if !binding.pickup || latched.contains(binding.id) || crossed || abs(value-current) <= tolerance {
                latched.insert(binding.id); applied[binding.id] = value; values.append((binding.node,binding.key,value))
            }
        }
        applyValues(values)
    }
    private func applyValues(_ values: [(UUID,String,Double)]) {
        guard !values.isEmpty else { return }
        var graph = workspace.graph
        for (id,key,value) in values { try? graph.setParameter(id,key:key,value:value) }
        do { try workspace.apply(graph,action:"MIDI",registerUndo:false) }
        catch { lastMessage = error.localizedDescription }
    }
    func mappingStatus(_ binding: MIDIMapping) -> String {
        guard let node = workspace.graph.node(binding.node),node.midiParameters.contains(where:{ $0.key == binding.key }) else { return "Missing parameter" }
        if !binding.enabled { return "Disabled" }
        if binding.device == "apc40mkII" && binding.channel == 0 && binding.cc == 15 { return "Reserved by A/B Follow APC" }
        if ownsAPC && binding.device == "apc40mkII" { return "Owned by APC40 node" }
        if binding.device == "apc40mkII" && binding.cc == 7 && binding.channel < 8 && followsChannelFaders { return "Reserved by MUX Follow APC" }
        if (node.kind == .mux || node.kind == .layerMux) && node.value("followAPC") == 1 && binding.key.hasPrefix("level") { return "Overridden by Follow APC" }
        if hostAPC && binding.device == "apc40mkII" { return "Host owns APC; use Follow APC" }
        if connected?.mappingID != binding.device { return "Disconnected" }
        if node.modulations?[binding.key]?.enabled == true { return "Modulated" }
        return binding.pickup && !latched.contains(binding.id) ? "Pickup" : "Active"
    }
    var controlHooks: [[String:Any]] {
        var hooks: [[String:Any]] = []
        for binding in workspace.graph.midiMappings ?? [] {
            let node = workspace.graph.node(binding.node)
            hooks.append(["id":binding.id.uuidString,"kind":"learned","device":binding.device,
                "input":["type":"cc","channel":binding.channel,"cc":binding.cc],
                "target":["node":binding.node.uuidString,"name":node?.name ?? "Missing node","parameter":binding.key],
                "enabled":binding.enabled,"status":mappingStatus(binding),"minimum":binding.minimum,"maximum":binding.maximum,"inverted":binding.inverted,"pickup":binding.pickup,
                "edit":["op":"midi_update","id":binding.id.uuidString],
                "disable":["op":"midi_update","id":binding.id.uuidString,"enabled":false],
                "remove":["op":"midi_unbind","id":binding.id.uuidString]])
        }
        for node in workspace.graph.nodes where node.kind == .ab || (node.kind == .mux || node.kind == .layerMux) {
            if node.kind == .ab {
                let enabled = followNode == node.id
                hooks.append(["id":"ab:\(node.id.uuidString)","kind":"builtin","device":"apc40mkII",
                    "input":["type":"cc","channel":0,"cc":15],"target":["node":node.id.uuidString,"name":node.name,"parameter":"mix"],
                    "enabled":enabled,"active":enabled && (hostAPC || connected?.isAPC == true) && faderPosition != nil,
                    "condition":"Global; exclusive A/B crossfader target","value":node.value("mix"),"physicalValue":faderPosition as Any? ?? NSNull(),"disable":["op":"midi_follow","node":node.id.uuidString,"enabled":false],
                    "enable":["op":"midi_follow","node":node.id.uuidString,"enabled":true]])
            } else {
                for channel in 0..<node.channelCount {
                    let enabled = node.value("followAPC") == 1
                    hooks.append(["id":"mux:\(node.id.uuidString):\(channel+1)","kind":"builtin","device":"apc40mkII",
                        "input":["type":"cc","channel":channel,"cc":7],"target":["node":node.id.uuidString,"name":node.name,"parameter":"level\(channel+1)"],
                        "enabled":enabled,"active":!ownsAPC && enabled && node.enabled && channelFaders[channel] != nil,
                        "value":node.value("level\(channel+1)"),"physicalValue":channelFaders[channel] as Any? ?? NSNull(),
                        "editScope":"MUX Follow APC","disable":["op":"midi_follow","node":node.id.uuidString,"enabled":false],
                        "enable":["op":"midi_follow","node":node.id.uuidString,"enabled":true]])
                }
            }
        }
        return hooks
    }

    var stateObject: [String:Any] {
        ["apcNodeOwnsController":ownsAPC,"apcOutputs":apcState.snapshot.enumerated().map { ["output":$0.offset,"name":APC40.outputs[$0.offset],"value":$0.element as Any? ?? NSNull()] },"controlHooks":controlHooks,"status":status,"selection":selection,"connected":connected?.name as Any? ?? NSNull(),"device":connected?.mappingID as Any? ?? NSNull(),
         "inputs":devices.map { ["id":$0.id,"name":$0.name,"device":$0.mappingID] },"learning":learning,
         "target":target.map { ["node":$0.node.uuidString,"key":$0.key] } as Any? ?? NSNull(),
         "channelFaders":channelFaders.map { $0 as Any? ?? NSNull() },"muxFollowNodes":workspace.graph.nodes.filter { ($0.kind == .mux || $0.kind == .layerMux) && $0.enabled && $0.value("followAPC") == 1 }.map { $0.id.uuidString },
         "followNode":followNode?.uuidString as Any? ?? NSNull(),"faderPosition":faderPosition as Any? ?? NSNull(),"lastMessage":lastMessage,
         "mappingStatus":Dictionary(uniqueKeysWithValues:(workspace.graph.midiMappings ?? []).map { ($0.id.uuidString,mappingStatus($0)) })]
    }
}
