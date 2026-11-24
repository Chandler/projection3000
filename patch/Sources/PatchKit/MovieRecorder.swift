import Foundation
import AVFoundation
import Metal
import QuartzCore
import PatchCore

struct RecordingInfo {
    var phase = "recording"
    var frames = 0
    var dropped = 0
    var seconds = 0.0
    var error: String?
    let url: URL
    var noun = "movie"
    /// Audio takes describe their file format instead of video frame counts.
    var detail: String?
    var label: String {
        switch phase {
        case "recording": return detail.map { String(format:"Recording %.1fs · %@ · %d dropped",seconds,$0,dropped) } ?? String(format:"Recording %.1fs · %d frames · %d dropped",seconds,frames,dropped)
        case "finishing": return "Finishing \(noun)…"
        case "ready": return String(format:"Ready to save · %.1fs",seconds)
        case "saved": return String(format:"Saved · %.1fs",seconds)
        default: return error ?? "Recording failed"
        }
    }
    var object: [String:Any] { ["state":phase,"frames":frames,"droppedFrames":dropped,"seconds":seconds,"path":url.path,"format":detail as Any? ?? NSNull(),"error":error as Any? ?? NSNull()] }
}

/// A take owned by a Record Movie or Record Audio node.
protocol TakeRecorder: AnyObject {
    var info: RecordingInfo { get }
    func finish(_ completion: ((Result<URL,Error>)->Void)?)
    func discard() throws
    func save(to destination: URL,replace: Bool) throws
    func appendAudio(_ block: AudioBlock)
}
extension TakeRecorder { func finish() { finish(nil) } }
extension MovieRecorder: TakeRecorder {}

// Three bounded GPU readbacks feed a serial encoder. Neither a slow encoder nor
// a Save dialog can accumulate frames or block graph evaluation.
final class MovieRecorder {
    let width: Int, height: Int, fps: Int
    private let stride: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private var pendingAudio = 0
    private var lastAudioFrame: Int64 = -1
    let startTime: Double
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let encodeQueue = DispatchQueue(label:"patch.movie.encode",qos:.userInitiated)
    private let pending = DispatchGroup()
    private let lock = NSLock()
    private let fileLock = NSLock()
    private var state: RecordingInfo
    private var freeBuffers: [MTLBuffer] = []
    private var finishCallbacks: [(Result<URL,Error>)->Void] = []
    private var lastFrame: Int64 = -1
    var info: RecordingInfo { lock.withLock { state } }
    init(device: MTLDevice,width: Int,height: Int,fps: Int, audio: Bool = false) throws {
        guard width%2 == 0, height%2 == 0 else { throw GraphError("H.264 recording needs an even width and height") }
        self.width = width; self.height = height; self.fps = fps; stride = ((width*4+255)/256)*256
        let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Patch/Recordings")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url = directory.appendingPathComponent("Take-\(UUID().uuidString).mov")
        state = RecordingInfo(url:url)
        writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:max(2_000_000,width*height*8),AVVideoExpectedSourceFrameRateKey:fps,AVVideoMaxKeyFrameIntervalKey:fps*2]])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        guard writer.canAdd(input) else { throw GraphError("Movie encoder unavailable") }
        writer.add(input)
        if audio {
            var asbd = AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
            guard CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&audioFormat) == noErr else { throw GraphError("Cannot create recording audio format") }
            let audioInput = AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:192000],sourceFormatHint:audioFormat)
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else { throw GraphError("AAC encoder unavailable") }
            writer.add(audioInput); self.audioInput = audioInput
        } else { audioInput = nil }
        for _ in 0..<3 { guard let buffer = device.makeBuffer(length:stride*height,options:.storageModeShared) else { throw GraphError("Cannot allocate recording buffer") }; freeBuffers.append(buffer) }
        guard writer.startWriting() else { throw writer.error ?? GraphError("Cannot start movie writer") }
        writer.startSession(atSourceTime:.zero)
        startTime = CACurrentMediaTime()
    }
    // Called only from the graph render queue.
    func encode(_ texture: MTLTexture,command: MTLCommandBuffer) {
        guard info.phase == "recording" else { return }
        guard texture.width == width, texture.height == height else { finish(); return }
        let now = CACurrentMediaTime()
        let frame = Int64(((now-startTime)*60_000).rounded())
        guard frame > lastFrame else { return }; lastFrame = frame
        guard let buffer = lock.withLock({ () -> MTLBuffer? in
            guard state.phase == "recording", let buffer = freeBuffers.popLast() else { return nil }
            pending.enter(); return buffer
        }) else { lock.withLock { state.dropped += 1 }; return }
        guard let blit = command.makeBlitCommandEncoder() else { lock.withLock { freeBuffers.append(buffer); state.dropped += 1 }; pending.leave(); return }
        blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:width,height:height,depth:1),to:buffer,destinationOffset:0,destinationBytesPerRow:stride,destinationBytesPerImage:buffer.length)
        blit.endEncoding()
        command.addCompletedHandler { [self] completed in
            encodeQueue.async {
                defer { self.lock.withLock { self.freeBuffers.append(buffer) }; self.pending.leave() }
                guard self.writer.status == .writing else {
                    self.lock.withLock { self.state.error = self.writer.error?.localizedDescription ?? "Movie encoder stopped" }; self.finish(); return
                }
                guard completed.status == .completed, self.input.isReadyForMoreMediaData else { self.lock.withLock { self.state.dropped += 1 }; return }
                var pixel: CVPixelBuffer?
                guard let pool = self.adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel) == kCVReturnSuccess, let pixel else { self.lock.withLock { self.state.dropped += 1 }; return }
                CVPixelBufferLockBaseAddress(pixel,[])
                if let destination = CVPixelBufferGetBaseAddress(pixel) {
                    let row = CVPixelBufferGetBytesPerRow(pixel)
                    for y in 0..<self.height { memcpy(destination.advanced(by:y*row),buffer.contents().advanced(by:y*self.stride),self.width*4) }
                }
                CVPixelBufferUnlockBaseAddress(pixel,[])
                if self.adaptor.append(pixel,withPresentationTime:CMTime(value:frame,timescale:60_000)) {
                    self.lock.withLock { self.state.frames += 1; self.state.seconds = Double(frame)/60_000 + 1.0/Double(self.fps) }
                } else { self.lock.withLock { self.state.error = self.writer.error?.localizedDescription ?? "Movie encoder failed" }; self.finish() }
            }
        }
    }
    // Independent audio graph queue supplies timestamped stereo PCM.
    func appendAudio(_ block: AudioBlock) {
        guard audioInput != nil,block.hostTime >= startTime else { return }
        let accepted = lock.withLock { () -> Bool in
            guard state.phase == "recording",pendingAudio < 32 else { return false }
            pendingAudio += 1; pending.enter(); return true
        }
        guard accepted else { return }
        encodeQueue.async { [self] in
            defer { lock.withLock { pendingAudio -= 1 }; pending.leave() }
            guard writer.status == .writing,let audioInput,let audioFormat else { return }
            guard audioInput.isReadyForMoreMediaData else { lock.withLock { state.error = "Audio encoder could not keep up" }; finish(); return }
            let frame = Int64(((block.hostTime-startTime)*48000).rounded()),count = block.samples.count/2
            guard frame > lastAudioFrame else { return }; lastAudioFrame = frame
            var data: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:block.samples.count*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:block.samples.count*4,flags:0,blockBufferOut:&data) == kCMBlockBufferNoErr,let data else { return }
            _ = block.samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:data,offsetIntoDestination:0,dataLength:$0.count) }
            var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:48000),presentationTimeStamp:CMTime(value:frame,timescale:48000),decodeTimeStamp:.invalid)
            var size = 8, sample: CMSampleBuffer?
            let result = CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:data,formatDescription:audioFormat,sampleCount:count,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)
            if result != noErr || sample == nil || !audioInput.append(sample!) { lock.withLock { state.error = writer.error?.localizedDescription ?? "Audio encoding failed" }; finish() }
        }
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
        pending.notify(queue:encodeQueue) { [self] in
            guard info.frames > 0, writer.status == .writing else {
                writer.cancelWriting(); complete(.failure(writer.error ?? GraphError(info.error ?? "No frames were recorded"))); return
            }
            writer.endSession(atSourceTime:CMTime(seconds:info.seconds,preferredTimescale:60_000))
            input.markAsFinished(); audioInput?.markAsFinished()
            writer.finishWriting { [self] in
                if writer.status == .completed && info.error == nil { complete(.success(info.url)) }
                else { complete(.failure(writer.error ?? GraphError("Cannot finish movie"))) }
            }
        }
    }
    private func complete(_ result: Result<URL,Error>) {
        let callbacks = lock.withLock { () -> [(Result<URL,Error>)->Void] in
            switch result { case .success: state.phase = "ready"; case .failure(let error): state.phase = "failed"; state.error = error.localizedDescription }
            freeBuffers.removeAll()
            let callbacks = finishCallbacks; finishCallbacks.removeAll(); return callbacks
        }
        DispatchQueue.main.async { callbacks.forEach { $0(result) } }
    }
    /// Only the unsaved, app-generated take is removed; exported movies are untouched.
    func discard() throws {
        fileLock.lock(); defer { fileLock.unlock() }
        let take = info
        guard ["ready","failed"].contains(take.phase) else { throw GraphError("Only a finished, unsaved take can be discarded") }
        if FileManager.default.fileExists(atPath:take.url.path) { try FileManager.default.removeItem(at:take.url) }
        lock.withLock { state.phase = "discarded" }
    }
    // Call from a worker queue. Keep the original take as recovery after saving.
    func save(to destination: URL,replace: Bool = false) throws {
        fileLock.lock(); defer { fileLock.unlock() }
        guard ["ready","saved"].contains(info.phase) else { throw GraphError("Stop recording and wait for the movie to finish first") }
        try exportTake(info.url,to:destination,replace:replace)
        lock.withLock { state.phase = "saved" }
    }
}

/// Copies a finished take atomically; the recovery original stays in place.
func exportTake(_ original: URL,to destination: URL,replace: Bool) throws {
    if destination == original { return }
    let fm = FileManager.default
    if fm.fileExists(atPath:destination.path) && !replace { throw GraphError("Destination already exists") }
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Patch-\(UUID().uuidString).\(original.pathExtension)")
    defer { try? fm.removeItem(at:temporary) }
    try fm.copyItem(at:original,to:temporary)
    if fm.fileExists(atPath:destination.path) { _ = try fm.replaceItemAt(destination,withItemAt:temporary) }
    else { try fm.moveItem(at:temporary,to:destination) }
}
