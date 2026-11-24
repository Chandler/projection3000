import AVFoundation
import AudioToolbox
import CoreAudio
import OutputBridge
import PatchCore

struct HardwareAudioDevice: Identifiable {
    var id: String
    var object: AudioDeviceID
    var name: String
    var inputs: Int
    var outputs: Int
    static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var a = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreamConfiguration,mScope:input ? kAudioDevicePropertyScopeInput:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id,&a,0,nil,&size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount:Int(size),alignment:16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id,&a,0,nil,&size,raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to:AudioBufferList.self)).reduce(0) { $0+Int($1.mNumberChannels) }
    }
    static func string(_ id: AudioDeviceID,_ selector: AudioObjectPropertySelector) -> String {
        var a = AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id,&a,0,nil,&size,&value) == noErr else { return "" }
        return value?.takeRetainedValue() as String? ?? ""
    }
    static var devices: [Self] {
        var a = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain),size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating:0,count:Int(size)/4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&ids) == noErr else { return [] }
        return ids.map { .init(id:string($0,kAudioDevicePropertyDeviceUID),object:$0,name:string($0,kAudioObjectPropertyName),inputs:channels($0,input:true),outputs:channels($0,input:false)) }
    }
    static func resolve(_ uid: String?,input: Bool) -> Self? {
        let all = devices
        if let uid { return all.first { $0.id == uid } }
        var a = AudioObjectPropertyAddress(mSelector:input ? kAudioHardwarePropertyDefaultInputDevice:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0,size: UInt32 = 4
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&id) == noErr else { return nil }
        return all.first { $0.object == id }
    }
}

/// Hardware callbacks only move samples through a preallocated, lock-free SPSC ring.
/// Graph processing remains on the audio queue; neither direction waits for Metal.
final class HardwareAudioIO {
    private var unit: AudioUnit?
    private let ring: OpaquePointer
    private let outputResampling=AudioResamplingContext()
    private let nativeRing: OpaquePointer?
    let clientRate: Double
    private let buffer: AVAudioPCMBuffer?
    private let x: UInt32, y: UInt32
    let rate: Double
    let device: HardwareAudioDevice
    let input: Bool
    var conversionError: String? { outputResampling.error }
    var drops: UInt64 { PatchStereoDrops(ring) }
    var metrics: [String:Any] { ["device":device.name,"input":input,"nativeRate":rate,"clientRate":clientRate,"writtenFrames":PatchStereoWritten(ring),"requestedFrames":PatchStereoRequested(ring),"underruns":PatchStereoUnderruns(ring),"latencyResets":PatchStereoTrims(ring),"xruns":drops] }
    init(uid: String?,input: Bool,x: Int,y: Int,clientRate: Double = 48000,requestedRate: Double = 0) throws {
        if input {
            let authorization=AVCaptureDevice.authorizationStatus(for:.audio)
            if authorization == .notDetermined {
                AVCaptureDevice.requestAccess(for:.audio) { _ in }
                throw GraphError("Allow microphone access in macOS")
            }
            guard authorization == .authorized else { throw GraphError("Microphone access denied — enable Patch in System Settings") }
        }
        guard let device = HardwareAudioDevice.resolve(uid,input:input) else { throw GraphError("Audio device unavailable — choose a connected device") }
        let count = input ? device.inputs:device.outputs
        // Mono devices (the built-in mic) feed their one channel to both sides;
        // equal selectors also duplicate a mono instrument input, as documented.
        let x = count == 1 ? 1 : x, y = count == 1 ? 1 : y
        guard x >= 1,y >= 1,max(x,y) <= count else { throw GraphError("Choose channels 1–\(count) on \(device.name)") }
        self.device=device;self.input=input;self.x=UInt32(x-1);self.y=UInt32(y-1)
        var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyNominalSampleRate,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var nativeRate=0.0,size=UInt32(MemoryLayout<Double>.size)
        if !input,requestedRate>0 {
            guard AudioObjectGetPropertyData(device.object,&address,0,nil,&size,&nativeRate) == noErr else { throw GraphError("Cannot read hardware sample rate") }
            if abs(nativeRate-requestedRate)>1 {
                var requested=requestedRate
                guard AudioObjectSetPropertyData(device.object,&address,0,nil,size,&requested) == noErr else { throw GraphError("\(device.name) cannot use \(Int(requestedRate)) Hz") }
                // Device reconfiguration can complete asynchronously. This is the device queue.
                for _ in 0..<100 {
                    _ = AudioObjectGetPropertyData(device.object,&address,0,nil,&size,&nativeRate)
                    if abs(nativeRate-requestedRate)<1 { break }
                    Thread.sleep(forTimeInterval:0.01)
                }
                guard abs(nativeRate-requestedRate)<1 else { throw GraphError("Hardware sample rate change did not complete") }
            }
        }
        guard AudioObjectGetPropertyData(device.object,&address,0,nil,&size,&nativeRate) == noErr,
              nativeRate.isFinite,nativeRate > 0 else { throw GraphError("Cannot read a valid sample rate from \(device.name)") }
        // Interface channels are discrete ports, not a standard speaker layout.
        // The channel-count-only AVAudioFormat initializer rejects many multichannel
        // devices. Keep every hardware channel available for the X/Y selectors.
        guard count > 0,count <= Int(UInt16.max),
              let layout=AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_DiscreteInOrder | UInt32(count)) else {
            throw GraphError("Unsupported audio channel layout: \(device.name) has \(count) channels")
        }
        let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:nativeRate,interleaved:false,channelLayout:layout)
        let captureBuffer=input ? AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16384):nil
        guard !input || captureBuffer != nil else { throw GraphError("Cannot allocate audio input buffer for \(device.name)") }
        guard let ring=PatchStereoCreate() else { throw GraphError("Cannot allocate audio transfer buffer") }
        self.rate=nativeRate;self.ring=ring;self.clientRate=clientRate;self.nativeRing=input ? PatchStereoCreate():nil
        PatchStereoPlaybackRate(ring,nativeRate)
        buffer=captureBuffer
        var description=AudioComponentDescription(componentType:kAudioUnitType_Output,componentSubType:kAudioUnitSubType_HALOutput,componentManufacturer:kAudioUnitManufacturer_Apple,componentFlags:0,componentFlagsMask:0)
        func check(_ status: OSStatus) throws { if status != noErr { throw GraphError("Core Audio error \(status)") } }
        do {
            guard let component=AudioComponentFindNext(nil,&description) else { throw GraphError("Core Audio unavailable") }
            try check(AudioComponentInstanceNew(component,&unit))
            guard let unit else { throw GraphError("Core Audio unit unavailable") }
            var on: UInt32=input ? 1:0,off: UInt32=input ? 0:1,id=device.object
            try check(AudioUnitSetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&on,4))
            try check(AudioUnitSetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&off,4))
            try check(AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,4))
            var stream=format.streamDescription.pointee
            try check(AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,input ? kAudioUnitScope_Output:kAudioUnitScope_Input,input ? 1:0,&stream,UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var callback=AURenderCallbackStruct(inputProc:{ ref,flags,time,_,frames,list in
                let io=Unmanaged<HardwareAudioIO>.fromOpaque(ref).takeUnretainedValue()
                if io.input {
                    guard let unit=io.unit,let buffer=io.buffer,frames <= buffer.frameCapacity else { return kAudio_ParamError }
                    buffer.frameLength=frames
                    let status=AudioUnitRender(unit,flags,time,1,frames,buffer.mutableAudioBufferList)
                    if status == noErr { PatchStereoCapture(io.ring,buffer.audioBufferList,frames,io.x,io.y);if let native=io.nativeRing { PatchStereoCapture(native,buffer.audioBufferList,frames,io.x,io.y) } }
                    return status
                }
                if let list { PatchStereoRender(io.ring,list,frames,io.x,io.y) }
                return noErr
            },inputProcRefCon:Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit,input ? kAudioOutputUnitProperty_SetInputCallback:kAudioUnitProperty_SetRenderCallback,input ? kAudioUnitScope_Global:kAudioUnitScope_Input,0,&callback,UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check(AudioUnitInitialize(unit));try check(AudioOutputUnitStart(unit))
        } catch { stop(); throw error }
    }
    func formatIsCurrent() -> Bool {
        var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceIsAlive,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var alive: UInt32=0,size: UInt32=4
        guard AudioObjectGetPropertyData(device.object,&address,0,nil,&size,&alive) == noErr,alive != 0 else { return false }
        address.mSelector=kAudioDevicePropertyNominalSampleRate
        var current=0.0;size=8
        return AudioObjectGetPropertyData(device.object,&address,0,nil,&size,&current) == noErr && abs(current-rate)<1
    }
    func write(_ samples: [Float],hostTime: Double) {
        let converted=outputResampling.render(samples,source:clientRate,target:rate,time:hostTime)
        converted.withUnsafeBufferPointer { PatchStereoWrite(ring,$0.baseAddress,UInt32($0.count/2)) }
    }
    func drainNative() -> [Float] {
        guard let nativeRing else { return [] }
        var result=[Float](repeating:0,count:32768*2)
        let n=result.withUnsafeMutableBufferPointer { PatchStereoDrain(nativeRing,$0.baseAddress,32768) }
        result.removeLast(result.count-Int(n)*2);return result
    }
    func read(frames: Int) -> [Float] {
        var result=[Float](repeating:0,count:frames*2)
        result.withUnsafeMutableBufferPointer { PatchStereoRead(ring,$0.baseAddress,UInt32(frames)) }
        return result
    }
    func stop() { if let unit { AudioOutputUnitStop(unit);AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit);self.unit=nil } }
    deinit { stop();PatchStereoDestroy(ring);if let nativeRing { PatchStereoDestroy(nativeRing) } }
}
