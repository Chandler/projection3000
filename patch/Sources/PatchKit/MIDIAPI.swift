import Foundation
import CoreFoundation
import PatchCore

extension ControlAPI {
    func midiRuntimeCommand(_ command: [String:Any]) throws -> [String:Any]? {
        guard let op = command["op"] as? String,["apc_control","midi_device","midi_learn","midi_follow"].contains(op) else { return nil }
        guard let midi = workspace.midi else { throw GraphError("MIDI unavailable") }
        try checkRevision(command)
        switch op {
        case "apc_control":
            try protectTransport(command)
            let output = try midiInteger(command,"output")
            let value: Double?
            if command["value"] is NSNull { value = nil }
            else {
                guard let number = command["value"] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID() else { throw GraphError("value must be a number from 0 to 1, or null") }
                value = number.doubleValue
            }
            try midi.setAPCControl(output:output,value:value)
        case "midi_device":
            try protectTransport(command)
            guard let id = command["device"] as? String,id == "auto" || id == "off" || midi.devices.contains(where:{ $0.id == id }) else { throw GraphError("Choose auto, off or an input ID from state.midi.inputs") }
            midi.select(id)
        case "midi_learn":
            try protectTransport(command)
            guard let enabled = command["enabled"] as? Bool else { throw GraphError("Expected enabled") }
            if enabled,let key = command["key"] as? String {
                let id = try midiUUID(command,"node")
                guard workspace.graph.node(id)?.midiParameters.contains(where:{ $0.key == key }) == true else { throw GraphError("Parameter is not MIDI assignable") }
                midi.setLearning(true); midi.arm(id,key)
            } else { midi.setLearning(enabled) }
        default:
            try protectTransport(command)
            guard let enabled = command["enabled"] as? Bool else { throw GraphError("Expected enabled") }
            try midi.setFollow(command["node"] != nil ? midiUUID(command,"node") : nil,enabled:enabled)
        }
        return ["ok":true,"midi":midi.stateObject,"graphRevision":revision()]
    }
    func midiGraphCommand(_ command: [String:Any],graph: inout Graph) throws -> [String:Any]? {
        guard let op = command["op"] as? String,["midi_bind","midi_update","midi_unbind","midi_clear"].contains(op) else { return nil }
        switch op {
        case "midi_bind":
            let node = try midiUUID(command,"node")
            guard let key = command["key"] as? String,let spec = graph.node(node)?.midiParameters.first(where:{ $0.key == key }),
                  let device = command["device"] as? String ?? workspace.midi?.connected?.mappingID else { throw GraphError("Expected node, assignable key and device") }
            var binding = MIDIMapping(node:node,key:key,device:device,channel:try midiInteger(command,"channel"),cc:try midiInteger(command,"cc"),minimum:spec.min,maximum:spec.max)
            try updateMIDIFields(command,binding:&binding)
            try graph.bindMIDI(binding)
            return ["id":binding.id.uuidString]
        case "midi_update":
            let id = try midiUUID(command,"id")
            guard let index = graph.midiMappings?.firstIndex(where:{ $0.id == id }) else { throw GraphError("Unknown MIDI mapping") }
            try updateMIDIFields(command,binding:&graph.midiMappings![index])
            if command["node"] != nil { graph.midiMappings![index].node = try midiUUID(command,"node") }
            if command["key"] != nil { guard let key = command["key"] as? String else { throw GraphError("key must be text") }; graph.midiMappings![index].key = key }
            let binding = graph.midiMappings![index]
            guard graph.node(binding.node)?.midiParameters.contains(where:{ $0.key == binding.key }) == true else { throw GraphError("Parameter is not MIDI assignable") }
            try graph.validateMIDIMappings()
        case "midi_unbind":
            let id = try midiUUID(command,"id")
            guard graph.midiMappings?.contains(where:{ $0.id == id }) == true else { throw GraphError("Unknown MIDI mapping") }
            graph.midiMappings?.removeAll { $0.id == id }
        default: graph.midiMappings = nil
        }
        return ["ok":true]
    }
    private func midiUUID(_ command: [String:Any],_ key: String) throws -> UUID {
        guard let string = command[key] as? String,let id = UUID(uuidString:string) else { throw GraphError("\(key) must be a UUID") }; return id
    }
    private func midiInteger(_ command: [String:Any],_ key: String) throws -> Int {
        guard let number = command[key] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,number.doubleValue.rounded() == number.doubleValue,(0...127).contains(number.doubleValue) else { throw GraphError("\(key) must be an integer from 0 to 127") }
        return number.intValue
    }
    private func updateMIDIFields(_ command: [String:Any],binding: inout MIDIMapping) throws {
        for key in ["minimum","maximum"] where command[key] != nil {
            guard let number = command[key] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite else { throw GraphError("\(key) must be numeric") }
            if key == "minimum" { binding.minimum = number.doubleValue } else { binding.maximum = number.doubleValue }
        }
        for key in ["inverted","pickup","enabled"] where command[key] != nil {
            guard let number = command[key] as? NSNumber,CFGetTypeID(number) == CFBooleanGetTypeID() else { throw GraphError("\(key) must be boolean") }
            switch key { case "inverted": binding.inverted = number.boolValue; case "pickup": binding.pickup = number.boolValue; default: binding.enabled = number.boolValue }
        }
        if command["channel"] != nil { binding.channel = try midiInteger(command,"channel") }
        if command["cc"] != nil { binding.cc = try midiInteger(command,"cc") }
        if command["device"] != nil {
            guard let device = command["device"] as? String else { throw GraphError("device must be a string") }; binding.device = device
        }
    }
}
