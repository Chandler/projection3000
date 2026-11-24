import AVFoundation
import QuartzCore
import PatchCore

final class MicrophoneSource: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static var devices: [AVCaptureDevice] { AVCaptureDevice.DiscoverySession(deviceTypes:[.microphone,.external],mediaType:.audio,position:.unspecified).devices }
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label:"patch.microphone.capture",qos:.userInitiated)
    private let lock = NSLock()
    private var samples = [Float](repeating:0,count:19_200) // At most 200 ms; discard old audio under load.
    private var readIndex = 0, available = 0
    private var lastCapture = 0.0
    private var message = "Starting microphone…"
    private var observers: [NSObjectProtocol] = []
    init(deviceID: String?) {
        super.init()
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized: start(deviceID)
        case .notDetermined:
            setMessage("Allow microphone access in the macOS prompt")
            AVCaptureDevice.requestAccess(for:.audio) { [weak self] allowed in
                if allowed { self?.start(deviceID) } else { self?.setMessage("Microphone access denied — enable Patch in System Settings → Privacy & Security → Microphone") }
            }
        default: setMessage("Microphone access denied — enable Patch in System Settings → Privacy & Security → Microphone")
        }
    }
    private func setMessage(_ value: String) { lock.withLock { message = value; available = 0 } }
    private func start(_ deviceID: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let device = deviceID.flatMap({ id in Self.devices.first { $0.uniqueID == id } }) ?? (deviceID == nil ? AVCaptureDevice.default(for:.audio) : nil) else { throw GraphError("Microphone unavailable — choose an input device") }
                let input = try AVCaptureDeviceInput(device:device), output = AVCaptureAudioDataOutput()
                output.audioSettings = [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false,AVLinearPCMIsBigEndianKey:false]
                output.setSampleBufferDelegate(self,queue:self.queue)
                self.session.beginConfiguration()
                guard self.session.canAddInput(input),self.session.canAddOutput(output) else { self.session.commitConfiguration(); throw GraphError("Cannot configure microphone") }
                self.session.addInput(input); self.session.addOutput(output); self.session.commitConfiguration()
                self.observers.append(NotificationCenter.default.addObserver(forName:.AVCaptureSessionRuntimeError,object:self.session,queue:nil) { [weak self] note in
                    self?.setMessage((note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Microphone capture stopped")
                })
                self.observers.append(NotificationCenter.default.addObserver(forName:.AVCaptureDeviceWasDisconnected,object:device,queue:nil) { [weak self] _ in self?.setMessage("Microphone disconnected — choose an input device") })
                self.session.startRunning()
            } catch { self.setMessage(error.localizedDescription) }
        }
    }
    func captureOutput(_ output: AVCaptureOutput,didOutput buffer: CMSampleBuffer,from connection: AVCaptureConnection) {
        guard let format = CMSampleBufferGetFormatDescription(buffer),let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,asbd.mSampleRate == 48000,asbd.mChannelsPerFrame == 2,asbd.mBitsPerChannel == 32,asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              let data = CMSampleBufferGetDataBuffer(buffer) else { setMessage("Microphone did not provide stereo PCM"); return }
        let count = min(CMSampleBufferGetNumSamples(buffer)*2,samples.count)
        var incoming = [Float](repeating:0,count:count)
        let result = incoming.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data,atOffset:max(0,CMBlockBufferGetDataLength(data)-count*4),dataLength:count*4,destination:$0.baseAddress!) }
        guard result == kCMBlockBufferNoErr else { return }
        lock.withLock {
            if available+count > samples.count { let dropped = available+count-samples.count; readIndex = (readIndex+dropped)%samples.count; available -= dropped }
            for value in incoming { samples[(readIndex+available)%samples.count] = value.isFinite ? value : 0; available += 1 }
            lastCapture = CACurrentMediaTime(); message = "Live · 48 kHz stereo"
        }
    }
    func read(frames: Int) -> ([Float],String) {
        lock.withLock {
            var result = [Float](repeating:0,count:frames*2)
            if lastCapture > 0 && CACurrentMediaTime()-lastCapture > 0.5 { available = 0; if message.hasPrefix("Live") { message = "Waiting for microphone" } }
            // Stay close to live time after a delayed capture callback.
            if available > frames*8 { let discard = available-frames*4; readIndex = (readIndex+discard)%samples.count; available -= discard }
            let count = min(result.count,available)
            for i in 0..<count { result[i] = samples[(readIndex+i)%samples.count] }
            readIndex = (readIndex+count)%samples.count; available -= count
            return (result,message)
        }
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        let session = session; queue.async { session.stopRunning() }
    }
}
