import Foundation
import AVFoundation
import PatchCore

// Writes one audio branch continuously on its own serial queue. The audio graph
// hands over native-rate blocks; with Source rate and a lossless format a
// hardware input reaches the file without resampling, quantized only by the
// chosen bit depth. Neither a slow disk nor a Save dialog blocks the graph.
final class AudioRecorder: TakeRecorder {
    let options: AudioRecording.Options
    private let queue = DispatchQueue(label:"patch.audio.record",qos:.userInitiated)
    private let pending = DispatchGroup()
    private let lock = NSLock()
    private let fileLock = NSLock()
    private var state: RecordingInfo
    private var finishCallbacks: [(Result<URL,Error>)->Void] = []
    private var queued = 0
    private var openedRate: Double?
    // Encoder state; touched only on `queue`.
    private var file: AVAudioFile?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var written: Int64 = 0
    private var silenceRemainder = 0.0
    var info: RecordingInfo { lock.withLock { state } }
    /// Native rate of the first block; later blocks are converted to it by the graph.
    var sourceRate: Double? { lock.withLock { openedRate } }
    init(_ options: AudioRecording.Options) throws {
        self.options = options
        let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Patch/Recordings")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        state = RecordingInfo(url:directory.appendingPathComponent("Take-\(UUID().uuidString).\(options.format.fileExtension(options.depth))"))
        state.noun = "audio"; state.detail = options.summary(rate:nil)
    }
    /// Called from the audio graph queue with interleaved stereo samples.
    func appendAudio(_ block: AudioBlock) {
        guard !block.samples.isEmpty else { return }
        if openedRate == nil { lock.withLock { openedRate = block.sampleRate } }
        enqueue { try self.write(block.samples,rate:block.sampleRate) }
    }
    /// Paused transport records silence, keeping the take on real elapsed time.
    func appendSilence(seconds: Double) {
        guard sourceRate != nil else { return }
        enqueue {
            guard let rate = self.sourceFormat?.sampleRate else { return }
            let exact = seconds*rate+self.silenceRemainder
            let frames = Int(exact.rounded(.down)); self.silenceRemainder = exact-Double(frames)
            if frames > 0 { try self.write([Float](repeating:0,count:frames*2),rate:rate) }
        }
    }
    private func enqueue(_ work: @escaping () throws -> Void) {
        let accepted = lock.withLock { () -> Bool in
            guard state.phase == "recording" else { return false }
            // About four seconds of 10 ms blocks; beyond that the disk is not keeping up.
            guard queued < 400 else { state.dropped += 1; return false }
            queued += 1; pending.enter(); return true
        }
        guard accepted else { return }
        queue.async { [self] in
            defer { lock.withLock { queued -= 1 }; pending.leave() }
            do { try work() } catch { lock.withLock { state.error = error.localizedDescription }; finish() }
        }
    }
    private func open(rate: Double) throws {
        let channels = AVAudioChannelCount(options.channels.count), fileRate = options.fileRate(source:rate)
        guard let source = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:channels,interleaved:false) else { throw GraphError("Unsupported source rate \(rate)") }
        var settings: [String:Any] = [AVSampleRateKey:fileRate,AVNumberOfChannelsKey:Int(channels)]
        switch options.format {
        case .wav,.aiff,.caf:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = options.depth.bits
            settings[AVLinearPCMIsFloatKey] = options.depth == .float32
            settings[AVLinearPCMIsBigEndianKey] = options.format == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC; settings[AVEncoderBitDepthHintKey] = options.depth.bits
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless; settings[AVEncoderBitDepthHintKey] = options.depth.bits
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC; settings[AVEncoderBitRateKey] = options.bitRate
        }
        let file = try AVAudioFile(forWriting:info.url,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        if fileRate != rate {
            guard let converter = AVAudioConverter(from:source,to:file.processingFormat) else { throw GraphError("Cannot convert \(rate) Hz to \(fileRate) Hz") }
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = .max
            self.converter = converter
        }
        self.file = file; sourceFormat = source
        lock.withLock { state.detail = options.summary(rate:fileRate) }
    }
    private func write(_ samples: [Float],rate: Double) throws {
        if file == nil { try open(rate:rate) }
        guard let file,let sourceFormat else { return }
        guard rate == sourceFormat.sampleRate else { throw GraphError(String(format:"Source rate changed to %g kHz; take stopped",rate/1000)) }
        let frames = samples.count/2, gain = options.gain
        guard frames > 0,let input = AVAudioPCMBuffer(pcmFormat:sourceFormat,frameCapacity:AVAudioFrameCount(frames)),let out = input.floatChannelData else { return }
        input.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let left = samples[i*2]*gain, right = samples[i*2+1]*gain
            switch options.channels {
            case .stereo: out[0][i] = left; out[1][i] = right
            case .mono: out[0][i] = (left+right)*0.5
            case .left: out[0][i] = left
            case .right: out[0][i] = right
            }
        }
        if converter != nil { try convert(input,end:false) } else { try file.write(from:input) }
        written += Int64(frames)
        lock.withLock { state.frames = Int(written); state.seconds = Double(written)/rate }
    }
    /// Streams through the converter; `end` drains its filter tail at the end of the take.
    private func convert(_ input: AVAudioPCMBuffer?,end: Bool) throws {
        guard let converter,let file else { return }
        let ratio = converter.outputFormat.sampleRate/converter.inputFormat.sampleRate
        var supplied = false
        repeat {
            let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0)*ratio)+4096
            guard let output = AVAudioPCMBuffer(pcmFormat:converter.outputFormat,frameCapacity:capacity) else { return }
            var error: NSError?
            let status = converter.convert(to:output,error:&error) { _,outStatus in
                if supplied || input == nil { outStatus.pointee = end ? .endOfStream : .noDataNow; return nil }
                supplied = true; outStatus.pointee = .haveData; return input
            }
            if status == .error { throw error ?? GraphError("Sample-rate conversion failed") }
            if output.frameLength > 0 { try file.write(from:output) }
            if status != .haveData || output.frameLength < capacity { return }
        } while true
    }
    func finish(_ completion: ((Result<URL,Error>)->Void)? = nil) {
        let shouldFinish: Bool = lock.withLock {
            if state.phase == "ready" || state.phase == "saved" || state.phase == "failed" {
                let result: Result<URL,Error> = state.phase == "failed" ? .failure(GraphError(state.error ?? "Recording failed")) : .success(state.url)
                if let completion { DispatchQueue.main.async { completion(result) } }
                return false
            }
            if let completion { finishCallbacks.append(completion) }
            guard state.phase == "recording" else { return false }
            state.phase = "finishing"; return true
        }
        guard shouldFinish else { return }
        pending.notify(queue:queue) { [self] in
            var failure: Error? = info.error.map { GraphError($0) }
            if failure == nil { do { try convert(nil,end:true) } catch { failure = error } }
            file = nil // Closing the AVAudioFile finalizes its header.
            if failure == nil && written == 0 { failure = GraphError("No audio was recorded") }
            complete(failure.map { .failure($0) } ?? .success(info.url))
        }
    }
    private func complete(_ result: Result<URL,Error>) {
        let callbacks = lock.withLock { () -> [(Result<URL,Error>)->Void] in
            switch result { case .success: state.phase = "ready"; case .failure(let error): state.phase = "failed"; state.error = error.localizedDescription }
            let callbacks = finishCallbacks; finishCallbacks.removeAll(); return callbacks
        }
        DispatchQueue.main.async { callbacks.forEach { $0(result) } }
    }
    /// Only the unsaved, app-generated take is removed; exported files are untouched.
    func discard() throws {
        fileLock.lock(); defer { fileLock.unlock() }
        let take = info
        guard ["ready","failed"].contains(take.phase) else { throw GraphError("Only a finished, unsaved take can be discarded") }
        if FileManager.default.fileExists(atPath:take.url.path) { try FileManager.default.removeItem(at:take.url) }
        lock.withLock { state.phase = "discarded" }
    }
    func save(to destination: URL,replace: Bool = false) throws {
        fileLock.lock(); defer { fileLock.unlock() }
        guard ["ready","saved"].contains(info.phase) else { throw GraphError("Stop recording and wait for the file to finish first") }
        try exportTake(info.url,to:destination,replace:replace)
        lock.withLock { state.phase = "saved" }
    }
}
