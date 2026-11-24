import AVFoundation
import QuartzCore
import PatchCore

private let audioRate = 48_000.0
private let audioFrames = 480
/// One stereo PCM stream with an explicit rate; hardware sinks negotiate processing upstream.
struct AudioBlock {
    var samples: [Float] // Interleaved X/left, Y/right.
    var hostTime: Double
    var sampleRate: Double = 48000
    var resampling=AudioResamplingContext()
    func resampled(to rate: Double) -> AudioBlock {
        guard rate != sampleRate else { return self }
        return AudioBlock(samples:resampling.render(samples,source:sampleRate,target:rate,time:hostTime),hostTime:hostTime,sampleRate:rate)
    }
    var mono: [Float] { stride(from:0,to:samples.count,by:2).map { (samples[$0]+samples[$0+1])*0.5 } }
    var peak: Float { samples.reduce(0) { max($0,abs($1)) } }
}
struct VideoAudioClock {
    var position: Double
    var hostTime: Double
    var speed: Double
    var playing: Bool
    var duration: Double
}

// Decode bounded, timestamped two-second pages away from both rendering queues.
// Four pages per source keep memory independent of the movie's duration.
private final class AudioFileStream: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label:"patch.audio.decode",qos:.userInitiated)
    private let lock = NSLock()
    private var asset: AVURLAsset?
    private var track: AVAssetTrack?
    private var pages: [Int:[Float]] = [:]
    private var order: [Int] = []
    private var pending: Set<Int> = []
    private var length = 0.0
    private var message = "Loading audio…"
    private var failure: String?
    var state: (Double,String) { lock.withLock { (length,message) } }
    init(_ path: String) {
        self.path = path
        if MediaCompatibility.needsPreparation(path) { message = "Preparing MKV audio…" }
        Task { [weak self] in
            do {
                let playableURL = try await MediaCompatibility.shared.playbackURL(for:path)
                let asset = AVURLAsset(url:playableURL)
                let tracks = try await asset.loadTracks(withMediaType:.audio)
                let duration = try await asset.load(.duration).seconds
                guard let self else { return }
                self.lock.withLock {
                    self.length = duration.isFinite ? duration : 0
                    self.asset = asset; self.track = tracks.first
                    self.message = tracks.isEmpty ? "No audio track" : "Loading audio…"
                }
            } catch { self?.lock.withLock { self?.message = error.localizedDescription } }
        }
    }
    private func request(_ page: Int) {
        let source: (AVURLAsset,AVAssetTrack)? = lock.withLock {
            guard failure == nil,page >= 0, Double(page)*2 < length, pages[page] == nil, !pending.contains(page),pending.count < 4,let asset,let track else { return nil }
            pending.insert(page); return (asset,track)
        }
        guard let (asset,track) = source else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let reader = try AVAssetReader(asset:asset)
                reader.timeRange = CMTimeRange(start:CMTime(seconds:Double(page)*2,preferredTimescale:48000),duration:CMTime(seconds:2,preferredTimescale:48000))
                let output = AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:audioRate,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false,AVLinearPCMIsBigEndianKey:false])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw GraphError("Cannot decode audio") }
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? GraphError("Cannot read audio") }
                var samples = [Float](repeating:0,count:192_000)
                while let buffer = output.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                    let count = CMSampleBufferGetNumSamples(buffer)
                    let offset = Int((CMSampleBufferGetPresentationTimeStamp(buffer).seconds*audioRate).rounded())-page*96_000
                    let first = max(0,offset),skip = max(0,-offset),frames = min(count-skip,96_000-first)
                    if frames > 0 {
                        _ = samples.withUnsafeMutableBytes { bytes in CMBlockBufferCopyDataBytes(block,atOffset:skip*8,dataLength:frames*8,destination:bytes.baseAddress!.advanced(by:first*8)) }
                    }
                }
                if reader.status == .failed { throw reader.error ?? GraphError("Audio decode failed") }
                self.lock.withLock {
                    self.pages[page] = samples; self.order.removeAll { $0 == page }; self.order.append(page)
                    while self.order.count > 4 { self.pages.removeValue(forKey:self.order.removeFirst()) }
                    self.pending.remove(page); self.message = "Ready"
                }
            } catch { self.lock.withLock { self.pending.remove(page); self.failure = error.localizedDescription; self.message = error.localizedDescription } }
        }
    }
    func read(position: Double,speed: Double,start: Double,end: Double) -> [Float] {
        let duration = state.0, end = end > 0 ? min(end,duration) : duration
        guard end > start else { return [Float](repeating:0,count:audioFrames*2) }
        let span = end-start
        func wrapped(_ time: Double) -> Double { start+((time-start).truncatingRemainder(dividingBy:span)+span).truncatingRemainder(dividingBy:span) }
        let positions = (0..<audioFrames).map { wrapped(position+Double($0)*speed/audioRate)*audioRate }
        let needed = Set(positions.flatMap { [Int($0)/96_000,Int(wrapped(($0+1)/audioRate)*audioRate)/96_000] })
        for page in needed { request(page) }
        request(Int(wrapped(position+2)*audioRate)/96_000)
        request(Int(start*audioRate)/96_000)
        let available = lock.withLock { () -> [Int:[Float]] in
            if track != nil && failure == nil { message = needed.allSatisfy { pages[$0] != nil } ? "Ready" : "Buffering audio…" }
            return pages
        }
        var result = [Float](repeating:0,count:audioFrames*2)
        for i in 0..<audioFrames {
            let index = Int(positions[i]),fraction = Float(positions[i]-Double(index))
            let next = Int(wrapped(Double(index+1)/audioRate)*audioRate)
            guard let a = available[index/96_000],let b = available[next/96_000] else { continue }
            for c in 0..<2 { let x = a[(index%96_000)*2+c]; result[i*2+c] = x+(b[(next%96_000)*2+c]-x)*fraction }
        }
        return result
    }
}

final class AudioGraphEngine {
    let instrumentMIDI=InstrumentMIDIInbox()
    private var instruments: [UUID:LoopmotherInstrument]=[:]
    let chroma=ChromaBridge()
    private var chromaTransmitters: [UUID:ChromaTransmitter]=[:]
    private var chromaReceivers: [UUID:ChromaReceiver]=[:]
    private var chromaReceiverKeys: [UUID:String]=[:]

    private let queue = DispatchQueue(label:"patch.audio.graph",qos:.userInteractive)
    private let lock = NSLock()
    var plugins: AudioPlugins?
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var graph = Graph()
    private var plan: [Node] = []
    private var demanded = Set<UUID>()
    func setDemand(_ ids: Set<UUID>) {
        queue.async {
            guard self.demanded != ids else { return }
            self.instruments=self.instruments.filter { ids.contains($0.key) }
            self.demanded=ids
            self.hardware=self.hardware.filter { ids.contains($0.key) }
            self.lock.withLock { self.vectorHistories=self.vectorHistories.filter { ids.contains($0.key) } }
            let devices=Set(self.graph.nodes.filter { ids.contains($0.id) && $0.enabled && $0.kind == .microphone }.map { $0.deviceID ?? "default" })
            self.microphones=self.microphones.filter { devices.contains($0.key) }
            if ids.isEmpty {
                self.flushMonitor()
                self.lock.withLock { self.published=[:];self.messages=[:];self.mediaStates=[:];self.publishedEnvelopes=[:];self.publishedHistory=[:];self.publishedWindows=[:];self.publishedHardware=[:] }
            }
        }
    }
    private let hardwareQueue=DispatchQueue(label:"patch.audio.devices",qos:.userInitiated)
    private var hardwarePending=Set<UUID>()
    private var hardware: [UUID:HardwareAudioIO] = [:]
    private var publishedHardware: [String:[String:Any]] = [:]
    var hardwareMetrics: [String:[String:Any]] { lock.withLock { publishedHardware } }
    private var hardwareKeys: [UUID:String] = [:]
    private var hardwareRetry: [UUID:Double] = [:]
    private var deviceRates: [UUID:Double] = [:]
    private var blockResampling: [UUID:AudioResamplingContext]=[:]
    private var sourceResampling: [UUID:AudioResamplingContext]=[:]
    private func resamplingContext(_ id: UUID,source: Bool = false) -> AudioResamplingContext {
        if source {
            if sourceResampling[id] == nil { sourceResampling[id]=AudioResamplingContext() }
            return sourceResampling[id]!
        }
        if blockResampling[id] == nil { blockResampling[id]=AudioResamplingContext() }
        return blockResampling[id]!
    }
    private var processingRates: [UUID:Double] = [:]
    private var outputRequests: [UUID:Double] = [:]
    private var vectorPaths: [UUID:(VectorPath.Signature,VectorPath)] = [:]
    private var vectorPhases: [UUID:Double] = [:]
    private var vectorSources = Set<UUID>()
    private var vectorHistories: [UUID:StereoHistory] = [:]
    // Ordinary stereo scopes read the original source history. Only channel
    // selection/assembly needs a scope-owned history.
    private var vectorHistorySources: [UUID:UUID] = [:]
    private var vectorRates: [UUID:Double] = [:]
    func voltageSamples(_ id: UUID?,count: Int) -> [SIMD2<Float>] {
        guard let id else { return [] }
        let history = lock.withLock { vectorHistories[vectorHistorySources[id] ?? id] }
        return history.map { $0.latest(min(60000,Int(Double(count)*$0.sampleRate/48000))) } ?? []
    }
    func oscilloscopeSamples(_ id: UUID?,seconds: Double) -> (points:[SIMD2<Float>],rate:Double) {
        guard let id,let history=lock.withLock({ vectorHistories[vectorHistorySources[id] ?? id] }) else { return ([],48000) }
        return (history.latest(Int(ceil(min(1,max(0,seconds))*history.sampleRate))),history.sampleRate)
    }
    var drawRates: [UUID:Double] { lock.withLock { vectorRates } }
    func scopeSamplePath(_ id: UUID) -> String {
        lock.withLock { vectorHistorySources[id] == id ? "separateChannels":"stereoSource" }
    }
    private var inputs: [UUID:[Int:UUID]] = [:]
    private var inputChannels: [UUID:[Int:Int]] = [:]
    private var channelResampling: [UUID:[Int:AudioResamplingContext]] = [:]
    private var audioConsumers: Set<UUID> = []
    private var previewNode: UUID?
    private var previewSource: UUID?
    private var publishedPreview: [String:Any] = [:]
    var previewState: [String:Any] { lock.withLock { publishedPreview } }
    private var playing = true
    private var transportTime = 0.0
    private var transportHost = CACurrentMediaTime()
    private var nextTime = CACurrentMediaTime()
    private var microphones: [String:MicrophoneSource] = [:]
    private var envelopes: [UUID:Double] = [:]
    private var envelopeHistory: [UUID:[Float]] = [:]
    private var publishedEnvelopes: [UUID:Double] = [:]
    private var sources: [UUID:AudioFileStream] = [:]
    private var positions: [UUID:Double] = [:]
    private var seeks: [UUID:Double] = [:]
    private var seekRevisions: [UUID:UUID] = [:]
    private var monitorGeneration = 0
    private var videoClocks: [UUID:VideoAudioClock] = [:]
    private var gains: [UUID:SIMD2<Float>] = [:]
    private var equalizers: [UUID:AudioEQProcessor] = [:]
    private var filters: [UUID:SIMD2<Float>] = [:]
    private var recorders: [UUID:MovieRecorder] = [:]
    private var audioRecorders: [UUID:AudioRecorder] = [:]
    private var published: [UUID:AudioBlock] = [:]
    private var messages: [UUID:String] = [:]
    private var mediaStates: [UUID:VideoAudioClock] = [:]
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var queuedBuffers = 0
    private var monitorError: String?
    private var format = AVAudioFormat(standardFormatWithSampleRate:audioRate,channels:2)!
    var snapshot: ([UUID:AudioBlock],[UUID:String],[UUID:VideoAudioClock],[UUID:Double],[UUID:[Float]],[UUID:[Float]]) { lock.withLock { (published,messages,mediaStates,publishedEnvelopes,publishedHistory,publishedWindows) } }
    private var analysisWindows: [UUID:[Float]] = [:]
    private var publishedWindows: [UUID:[Float]] = [:]
    private var analysisSources: Set<UUID> = []
    private var publishedHistory: [UUID:[Float]] = [:]
    init() { resume() }
    func resume() {
        guard timer == nil else { return }
        queue.sync { stopped = false }
        let timer = DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:.milliseconds(5),leeway:.microseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
    }
    func stop() {
        timer?.cancel(); timer = nil
        queue.sync {
            self.stopped = true; self.playing = false
            self.instruments.removeAll()
            self.engine?.stop(); self.player?.stop()
            self.microphones.removeAll(); self.sources.removeAll(); self.hardware.removeAll();self.blockResampling.removeAll();self.sourceResampling.removeAll()
        }
    }
    deinit { timer?.cancel(); engine?.stop() }
    func update(_ graph: Graph,playing: Bool,time: Double) {
        queue.async {
            guard !self.stopped else { return }
            if self.graph != graph {
                if graph.nodes.contains(where:{ node in
                    guard let previous = self.graph.node(node.id) else { return false }
                    return node.seekRevision != previous.seekRevision || node.value("playing") != previous.value("playing")
                }) {
                    self.player?.stop(); self.queuedBuffers = 0; self.monitorGeneration += 1; self.filters.removeAll(); self.equalizers.removeAll();self.blockResampling.removeAll();self.sourceResampling.removeAll()
                }
                let source = graph.audioPreviewSource(self.previewNode)
                let newFile = source.flatMap { graph.node($0)?.file }
                let oldFile = self.previewSource.flatMap { self.graph.node($0)?.file }
                if source != self.previewSource || newFile != oldFile {
                    self.flushMonitor()
                }
                self.previewSource = source
                self.analysisWindows = self.analysisWindows.filter { self.graph.node($0.key) == graph.node($0.key) }
                self.chroma.retain(Set(graph.nodes.map(\.id)))
                self.chromaTransmitters=self.chromaTransmitters.filter { graph.node($0.key)?.kind == .chromaEncoder }
                self.chromaReceivers=self.chromaReceivers.filter { graph.node($0.key)?.kind == .chromaDecoder }
                self.instruments=self.instruments.filter { graph.node($0.key)?.kind == .loopmother && graph.node($0.key)?.enabled == true }
                self.graph = graph; self.plan = (try? graph.orderedNodes()) ?? []; self.inputs = [:]; self.inputChannels = [:]; self.audioConsumers = []; self.channelResampling.removeAll()
                for edge in graph.edges where graph.node(edge.source)?.kind.outputType(at:edge.outputIndex) == .audio { self.inputs[edge.target,default:[:]][edge.input] = edge.source; self.audioConsumers.insert(edge.source); if let channel=graph.node(edge.source)?.kind.audioChannel(at:edge.outputIndex) { self.inputChannels[edge.target,default:[:]][edge.input]=channel } }
                var historySources: [UUID:UUID]=[:]
                for scope in graph.nodes where [.rasterSynth,.voltageVisualizer,.voltageFluid,.oscilloscope].contains(scope.kind) {
                    let incoming=self.inputs[scope.id] ?? [:]
                    let separate=[.voltageVisualizer,.voltageFluid].contains(scope.kind) && (incoming[2] != nil || incoming[3] != nil)
                    if separate || self.inputChannels[scope.id]?[0] != nil { historySources[scope.id]=scope.id }
                    else if let source=incoming[0] { historySources[scope.id]=source }
                }
                self.vectorSources=Set(historySources.values)
                self.lock.withLock {
                    self.vectorHistorySources=historySources
                    self.vectorHistories=self.vectorHistories.filter { self.vectorSources.contains($0.key) && self.demanded.contains($0.key) }
                }
                self.hardware=self.hardware.filter { id,_ in graph.node(id)?.enabled == true }
                self.analysisSources = Set(graph.edges.filter { graph.node($0.target)?.kind == .audioVisualizer }.map(\.target))
                self.analysisWindows = self.analysisWindows.filter { self.analysisSources.contains($0.key) }
                let wanted = Set(graph.nodes.filter { $0.kind == .microphone && $0.enabled }.map { $0.deviceID ?? "default" })
                self.microphones = self.microphones.filter { wanted.contains($0.key) }
                let ids = Set(graph.nodes.map(\.id))
                self.vectorPaths=self.vectorPaths.filter { ids.contains($0.key) }; self.vectorPhases=self.vectorPhases.filter { ids.contains($0.key) }
                self.deviceRates=self.deviceRates.filter { ids.contains($0.key) && self.graph.node($0.key)?.deviceID == graph.node($0.key)?.deviceID };self.hardwareKeys=self.hardwareKeys.filter { ids.contains($0.key) };self.hardwareRetry=self.hardwareRetry.filter { ids.contains($0.key) };self.hardwareErrors=self.hardwareErrors.filter { ids.contains($0.key) }
                self.envelopes = self.envelopes.filter { ids.contains($0.key) }; self.envelopeHistory = self.envelopeHistory.filter { ids.contains($0.key) }
                self.equalizers = self.equalizers.filter { ids.contains($0.key) }
                self.sources = self.sources.filter { ids.contains($0.key) }; self.filters = self.filters.filter { ids.contains($0.key) }; self.gains = self.gains.filter { ids.contains($0.key) }
                self.blockResampling=self.blockResampling.filter { ids.contains($0.key) };self.sourceResampling=self.sourceResampling.filter { ids.contains($0.key) }
                self.positions = self.positions.filter { ids.contains($0.key) }; self.seeks = self.seeks.filter { ids.contains($0.key) }
            }
            if self.playing != playing { self.blockResampling.removeAll();self.sourceResampling.removeAll();self.hardware.removeAll(); self.hardwareRetry.removeAll(); self.player?.stop(); self.queuedBuffers = 0; self.monitorGeneration += 1 }
            self.playing = playing; self.transportTime = time; self.transportHost = CACurrentMediaTime()
        }
    }
    private func flushMonitor() {
        player?.stop(); queuedBuffers = 0; monitorGeneration += 1
    }
    func preview(_ id: UUID?) {
        queue.async {
            guard self.previewNode != id else { return }
            self.flushMonitor()
            self.previewNode = id; self.previewSource = self.graph.audioPreviewSource(id)
        }
    }
    func clocks(_ values: [UUID:VideoAudioClock]) { queue.async { self.videoClocks = values } }
    func record(_ id: UUID,recorder: MovieRecorder) { queue.async { self.recorders[id] = recorder } }
    func record(_ id: UUID,recorder: AudioRecorder) { queue.async { self.audioRecorders[id] = recorder } }
    private func tick() {
        let now = CACurrentMediaTime()
        if nextTime < now-0.05 { nextTime = now }
        var count = 0
        while nextTime <= now && count < 6 {
            process(at:nextTime); nextTime += Double(audioFrames)/audioRate; count += 1
        }
    }
    let apcState = APC40State()
    private func negotiateRates() {
        let outputs=plan.filter { $0.kind == .audioOutput && $0.enabled && demanded.contains($0.id) }
        var devices: [String:Double]=[:]
        for node in outputs {
            let key=hardware[node.id]?.device.id ?? node.deviceID ?? "default"
            devices[key]=max(devices[key] ?? 0,AnalogVectorStyle.requestedRate(node))
        }
        var rates: [UUID:Double]=[:]
        outputRequests=[:]
        for node in outputs {
            let key=hardware[node.id]?.device.id ?? node.deviceID ?? "default"
            let request=devices[key] ?? 0
            outputRequests[node.id]=request
            rates[node.id]=request>0 ? request:(deviceRates[node.id] ?? audioRate)
        }
        for node in plan.reversed() {
            guard let rate=rates[node.id] else { continue }
            for source in (inputs[node.id] ?? [:]).values { rates[source]=max(rates[source] ?? 0,rate) }
        }
        for node in plan {
            if node.kind == .audioInput {
                // Capture stays native. Convert only branches that need another rate.
                rates[node.id]=deviceRates[node.id] ?? rates[node.id] ?? audioRate
            } else if [.microphone,.audio,.video,.chromaEncoder].contains(node.kind) {
                rates[node.id]=audioRate
            } else if node.kind != .audioOutput,
                      let upstream=(inputs[node.id] ?? [:]).values.compactMap({ rates[$0] }).max() {
                // Process shared branches at their source rate, including bypassed
                // effects. A sink's conversion must not change sibling consumers.
                rates[node.id]=upstream
            } else if rates[node.id] == nil {
                rates[node.id]=(inputs[node.id] ?? [:]).values.compactMap { rates[$0] }.max() ?? audioRate
            }
        }
        if rates != processingRates {
            // Starting a sink must not reset an unchanged branch's filter history.
            equalizers=equalizers.filter { rates[$0.key] == processingRates[$0.key] }
            filters=filters.filter { rates[$0.key] == processingRates[$0.key] }
            blockResampling=blockResampling.filter { rates[$0.key] == processingRates[$0.key] }
            sourceResampling=sourceResampling.filter { rates[$0.key] == processingRates[$0.key] }
            processingRates=rates
        }
    }
    private func process(at host: Double) {
        guard !demanded.isEmpty else { return }
        if !playing { instruments.removeAll() }
        negotiateRates()
        let silence = [Float](repeating:0,count:audioFrames*2)
        var captureSamples: [UUID:([Float],Double)]=[:]
        var blocks: [UUID:AudioBlock] = [:], status: [UUID:String] = [:], states: [UUID:VideoAudioClock] = [:], controls: [UUID:Double] = [:]
        var channelBlocks: [UUID:[Int:AudioBlock]] = [:]
        func inputBlock(_ target: UUID,_ port: Int) -> AudioBlock? {
            guard let source=inputs[target]?[port],let block=blocks[source] else { return nil }
            guard let channel=inputChannels[target]?[port] else { return block }
            if let cached=channelBlocks[source]?[channel] { return cached }
            var samples=block.samples
            for i in stride(from:0,to:samples.count,by:2) { let value=samples[i+channel];samples[i]=value;samples[i+1]=value }
            if channelResampling[source]?[channel] == nil { channelResampling[source,default:[:]][channel]=AudioResamplingContext() }
            let selected=AudioBlock(samples:samples,hostTime:block.hostTime,sampleRate:block.sampleRate,resampling:channelResampling[source]![channel]!)
            channelBlocks[source,default:[:]][channel]=selected
            return selected
        }
        var monitor = silence, wantsMonitor = false
        var rates: [UUID:Double] = [:]
        var captured: [String:([Float],String)] = [:]
        let time = transportTime+(playing ? max(0,host-transportHost) : 0)
        let apcValues = apcState.snapshot
        let apcIDs = Set(plan.filter { $0.kind == .apc40 && $0.enabled }.map(\.id))
        for original in plan where demanded.contains(original.id) {
            var node = original
            for (key,binding) in node.modulations ?? [:] where binding.enabled {
                if let value = apcIDs.contains(binding.source) ? apcValues[binding.outputIndex] : controls[binding.source] { node.parameters[key] = binding.minimum+(binding.maximum-binding.minimum)*value }
            }
            let incoming = inputs[node.id] ?? [:]
            let audioRate=processingRates[node.id] ?? 48000
            let audioFrames=Int((audioRate*0.01).rounded())
            let silence=[Float](repeating:0,count:audioFrames*2)
            var a = inputBlock(node.id,0)?.resampled(to:audioRate).samples ?? silence
            if node.enabled && [.audioGain,.audioOutput].contains(node.kind) { AudioChannels.apply(&a,mode:Int(node.value("channelMode"))) }
            if node.kind == .audioEnvelope {
                guard node.enabled else { envelopes[node.id] = nil; envelopeHistory[node.id] = nil; status[node.id] = node.kind.pausedStatus; continue }
                let level = node.value("mode") > 0.5 ? Double(a.reduce(0) { max($0,abs($1)) }) : sqrt(a.reduce(0.0) { $0+Double($1)*Double($1) }/Double(max(1,a.count)))
                let db = 20*log10(max(1e-9,level))+node.value("gain")
                let target = min(1,max(0,(db-node.value("floor"))/max(0.001,node.value("ceiling")-node.value("floor"))))
                let previous = envelopes[node.id] ?? 0
                let ms = target > previous ? node.value("attack") : node.value("release")
                let value = playing ? target+(previous-target)*exp(-10/max(1,ms)) : previous
                envelopes[node.id] = value; controls[node.id] = value
                if playing || envelopeHistory[node.id] == nil {
                    var history = envelopeHistory[node.id] ?? [Float](repeating:0,count:512)
                    history.removeFirst(); history.append(Float(value)); envelopeHistory[node.id] = history
                }
                status[node.id] = incoming.isEmpty ? "No input" : String(format:"%.3f · CONTROL",value)
                continue
            }
            if node.kind == .apc40 { continue }
            if node.kind.outputType == .control { if node.enabled { controls[node.id] = ControlSignal.value(node,time:time) }; continue }
            if node.kind == .record {
                if let recorder = recorders[node.id],recorder.info.phase == "recording" {
                    recorder.appendAudio(AudioBlock(samples:playing && node.enabled ? (inputBlock(node.id,1)?.resampled(to:48000).samples ?? [Float](repeating:0,count:960)) : [Float](repeating:0,count:960),hostTime:host))
                }
                continue
            }
            if node.kind == .recordAudio {
                if let recorder = audioRecorders[node.id],recorder.info.phase == "recording" {
                    if playing && node.enabled,let source = inputs[node.id]?[0] {
                        // Hardware inputs record every native sample, not the graph-rate copy.
                        if let native = captureSamples[source] {
                            var samples = native.0
                            if let channel = inputChannels[node.id]?[0] { for i in stride(from:0,to:samples.count,by:2) { let value = samples[i+channel];samples[i] = value;samples[i+1] = value } }
                            recorder.appendAudio(AudioBlock(samples:samples,hostTime:host,sampleRate:native.1))
                        } else if graph.node(source)?.kind != .audioInput,var block = inputBlock(node.id,0) {
                            if let rate = recorder.sourceRate,block.sampleRate != rate { block = block.resampled(to:rate) }
                            recorder.appendAudio(block)
                        }
                    } else { recorder.appendSilence(seconds:Double(audioFrames)/audioRate) }
                }
                continue
            }
            if node.kind == .chromaDecoder {
                guard playing,node.enabled,let source=incoming[0],let block=inputBlock(node.id,0),
                      let reference=graph.edges.first(where:{ $0.target == node.id && $0.input == 1 }),
                      let encoder=graph.node(reference.source),encoder.enabled,encoder.kind == .chromaEncoder else { continue }
                let format=ChromaFormat(format:Int(encoder.value("format")),fps:encoder.value("fps"),carrierProfile:Int(encoder.value("carrierProfile")))
                let key="\(source)|\(reference.source)|\(Int(node.value("channel")))|\(Int(node.value("decodeMode")))"
                if chromaReceivers[node.id]?.format != format || chromaReceiverKeys[node.id] != key {
                    chromaReceivers[node.id]=ChromaReceiver(format:format);chromaReceiverKeys[node.id]=key
                }
                let receiver=chromaReceivers[node.id]!
                let live=node.value("decodeMode")>0.5
                let gain=Float(pow(10,node.value("returnGain")/20)/max(0.0001,encoder.value("level")))
                let returned=receiver.append(block.resampled(to:48000).samples,channel:Int(node.value("channel")),freeRunning:live,gain:gain,scanPhase:node.value("scanPhase"))
                if !returned.isEmpty { chroma.publish(receiver,id:node.id,time:host,freeRunning:live) }
                continue
            }
            if [.rasterSynth,.voltageVisualizer,.voltageFluid,.oscilloscope].contains(node.kind) {
                let separate=[.voltageVisualizer,.voltageFluid].contains(node.kind) && (incoming[2] != nil || incoming[3] != nil)
                // Keep ordinary XY input on the pre-channel-routing path: retain
                // the source's samples once, without a synthetic scope block.
                if !separate && inputChannels[node.id]?[0] == nil { continue }
                let base=inputBlock(node.id,0)
                let x=incoming[2] != nil ? inputBlock(node.id,2):base
                let y=incoming[3] != nil ? inputBlock(node.id,3):base
                let rate=(y ?? x)?.sampleRate ?? audioRate
                var xy=[Float](repeating:0,count:Int((rate*0.01).rounded())*2)
                if playing,node.enabled {
                    if separate {
                        let xs=x?.resampled(to:rate).samples ?? []
                        let ys=y?.resampled(to:rate).samples ?? []
                        for i in stride(from:0,to:xy.count,by:2) { xy[i]=i<xs.count ? xs[i]:0;xy[i+1]=i+1<ys.count ? ys[i+1]:0 }
                    } else if let base { xy=base.samples }
                    // An ordinary capture scope still retains every native sample.
                    if !separate,let source=incoming[0],let native=captureSamples[source] {
                        var samples=native.0
                        if let channel=inputChannels[node.id]?[0] {
                            for i in stride(from:0,to:samples.count,by:2) { let value=samples[i+channel];samples[i]=value;samples[i+1]=value }
                        }
                        captureSamples[node.id]=(samples,native.1)
                    }
                }
                blocks[node.id]=AudioBlock(samples:xy,hostTime:host,sampleRate:rate)
                continue
            }
            if [.waveform,.audioVisualizer].contains(node.kind) {
                blocks[node.id]=inputBlock(node.id,0)
                continue
            }
            guard node.kind.isAudioNode || (node.kind == .video && (audioConsumers.contains(node.id) || previewSource == node.id)) else { continue }
            var samples = silence
            if !node.enabled {
                equalizers[node.id] = nil
                let source = node.kind.bypassInput().flatMap { inputBlock(node.id,$0) }
                samples = source?.resampled(to:audioRate).samples ?? silence
                status[node.id] = node.kind.pausedStatus
            }
            else {
                switch node.kind {
                case .loopmother:
                    if playing {
                        do {
                            if instruments[node.id] == nil { instruments[node.id]=try LoopmotherInstrument() }
                            let synth=instruments[node.id]!
                            let instrument=inputBlock(node.id,1)?.resampled(to:audioRate).samples
                            samples=synth.render(node:node,frames:audioFrames,rate:audioRate,events:instrumentMIDI.drain(node.id),instrument:instrument)
                            status[node.id]="Loopmother · \(synth.notesReceived) notes · \(instrument == nil ? "MIDI → audio":"MIDI + instrument → audio")"
                        } catch { status[node.id]=error.localizedDescription }
                    } else { _ = instrumentMIDI.drain(node.id);status[node.id]="Transport paused" }
                case .chromaEncoder:
                    let format=ChromaFormat(format:Int(node.value("format")),fps:node.value("fps"),carrierProfile:Int(node.value("carrierProfile")))
                    if chromaTransmitters[node.id]?.format != format { chromaTransmitters[node.id]=ChromaTransmitter(format:format) }
                    let transmitter=chromaTransmitters[node.id]!
                    if let frame=chroma.input(node.id) { transmitter.submit(frame) }
                    let pcm=transmitter.render(frames:480,level:Float(node.value("level")),channel:Int(node.value("channel")))
                    samples=AudioBlock(samples:pcm,hostTime:host,sampleRate:48000,resampling:resamplingContext(node.id,source:true)).resampled(to:audioRate).samples
                    status[node.id]=String(format:"%d × %d color · %.2f fps · %.1f kHz carrier · %@",format.width,format.height,format.fps,Double(format.carrierHz)/1000,node.value("channel")<0.5 ? "left":"right")
                case .voltageEncoder:
                    rates[node.id] = node.value("rate")
                    if let edge=graph.edges.first(where:{ $0.target == node.id && $0.input == 0 }),
                       var shape=graph.node(edge.source),shape.enabled {
                        for (key,binding) in shape.modulations ?? [:] where binding.enabled {
                            if let value=controls[binding.source] { shape.parameters[key]=binding.minimum+(binding.maximum-binding.minimum)*value }
                        }
                        let key=VectorPath.Signature(shape)
                        if vectorPaths[shape.id]?.0 != key { vectorPaths[shape.id]=(key,VectorPath.shape(shape)) }
                        let path=vectorPaths[shape.id]!.1,rate=node.value("rate"),level=Float(node.value("level"))
                        let sampleRate=audioRate,frames=audioFrames
                        let levelX=Float(node.value("levelX")),levelY=Float(node.value("levelY"))
                        let rotation=shape.value("rotation")*Double.pi/180,spin=shape.value("spin")*2*Double.pi
                        var phase=vectorPhases[node.id] ?? 0
                        for i in 0..<frames {
                            let angle=rotation+(time+Double(i)/sampleRate)*spin
                            let point=path.point(phase,rotation:angle)*level
                            samples[i*2]=point.x*levelX;samples[i*2+1]=point.y*levelY
                            if playing { phase += rate/sampleRate; phase -= floor(phase) }
                        }
                        vectorPhases[node.id]=phase
                        status[node.id]=String(format:"X / Y · %.1f Hz · %.0f kHz",rate,sampleRate/1000)
                    } else { status[node.id]="Connect a vector path" }
                case .audioInput:
                    if playing,let io=hardwareIO(node,host:host,status:&status,clientRate:audioRate) {
                        let gain=Float(pow(10,node.value("gain")/20))
                        samples=io.read(frames:audioFrames).map { $0*gain }
                        captureSamples[node.id]=(io.drainNative().map { $0*gain },io.rate)
                    }
                case .microphone:
                    let key = node.deviceID ?? "default"
                    if microphones[key] == nil { microphones[key] = MicrophoneSource(deviceID:node.deviceID) }
                    if captured[key] == nil { captured[key] = microphones[key]!.read(frames:480) }
                    let capture = captured[key]!,gain = Float(pow(10,node.value("gain")/20))
                    samples = AudioBlock(samples:capture.0,hostTime:host,resampling:resamplingContext(node.id,source:true)).resampled(to:audioRate).samples.map { $0*gain }; status[node.id] = capture.1
                case .video,.audio:
                    if let path = node.file {
                        if sources[node.id]?.path != path { sources[node.id] = AudioFileStream(path); positions[node.id] = node.value("start"); seeks[node.id] = nil }
                        let source = sources[node.id]!, duration = source.state.0
                        let active = playing && node.value("playing") > 0.5
                        let speed = node.value("speed"), start = node.value("start"), end = node.value("end") > 0 ? min(node.value("end"),duration) : duration
                        var position: Double
                        if node.kind == .video {
                            let clock = videoClocks[node.id]
                            position = clock.map { $0.position+($0.playing ? max(-0.05,host-$0.hostTime)*$0.speed : 0) } ?? start
                        } else {
                            if seeks[node.id] != node.value("seek") || seekRevisions[node.id] != node.seekRevision { positions[node.id] = max(start,min(node.value("seek"),max(start,end-1/audioRate))); seeks[node.id] = node.value("seek"); seekRevisions[node.id] = node.seekRevision; filters.removeAll();equalizers.removeAll();sourceResampling[node.id]=nil;blockResampling[node.id]=nil }
                            position = positions[node.id] ?? start
                        }
                        if end > start { position = start+((position-start).truncatingRemainder(dividingBy:end-start)+(end-start)).truncatingRemainder(dividingBy:end-start) }
                        let decoded = source.read(position:position,speed:speed,start:start,end:end)
                        let running = active && (node.kind != .video || videoClocks[node.id]?.playing == true)
                        samples = running ? AudioBlock(samples:decoded,hostTime:host,resampling:resamplingContext(node.id,source:true)).resampled(to:audioRate).samples : silence
                        if node.kind == .audio { positions[node.id] = position+(running ? Double(audioFrames)/audioRate*speed : 0) }
                        states[node.id] = .init(position:position,hostTime:host,speed:speed,playing:running,duration:duration)
                        status[node.id] = source.state.1
                    } else { status[node.id] = "Choose a file" }
                case .audioGain,.audioOutput:
                    let gain = Float(pow(10,node.value("gain")/20)),pan = Float(node.value("pan"))
                    let left = gain*(pan > 0 ? 1-pan : 1),right = gain*(pan < 0 ? 1+pan : 1)
                    let target = SIMD2<Float>(left,right), previous = gains[node.id] ?? target
                    for i in 0..<audioFrames { let gain = previous+(target-previous)*Float(i+1)/Float(audioFrames); samples[i*2] = a[i*2]*gain.x; samples[i*2+1] = a[i*2+1]*gain.y }
                    gains[node.id] = target
                case .audioMono:
                    // Average preserves headroom for correlated stereo and duplicates to both ears.
                    for i in 0..<audioFrames {
                        let mono = (a[i*2]+a[i*2+1])*0.5
                        samples[i*2] = mono; samples[i*2+1] = mono
                    }
                    status[node.id] = "Left + right → both channels"
                case .audioMix:
                    let b = inputBlock(node.id,1)?.resampled(to:audioRate).samples ?? silence
                    let ga = Float(pow(10,(node.value("gainA")+node.value("master"))/20)),gb = Float(pow(10,(node.value("gainB")+node.value("master"))/20))
                    let target = SIMD2<Float>(ga,gb),previous = gains[node.id] ?? target
                    for i in samples.indices { let gain = previous+(target-previous)*Float(i/2+1)/Float(audioFrames); samples[i] = a[i]*gain.x+b[i]*gain.y }
                    gains[node.id] = target
                case .audioPlugin:
                    if let plugin=plugins?.instance(node.id) {
                        let result=plugin.process(a,rate:audioRate,node:node)
                        samples=result.0; status[node.id]=result.1
                    } else {
                        samples=a; status[node.id]=node.file == nil ? "Choose a VST3 effect · bypassed":"Plugin unavailable · bypassed (see inspector)"
                    }
                case .audioEQ:
                    var eq = equalizers[node.id] ?? AudioEQProcessor()
                    samples = eq.process(a,node:node,sampleRate:audioRate)
                    equalizers[node.id] = eq
                case .audioFilter:
                    var z = filters[node.id] ?? .zero
                    let alpha = Float(1-exp(-2*Double.pi*node.value("cutoff")/audioRate)),mix = Float(node.value("mix"))
                    for i in 0..<audioFrames { for c in 0..<2 { let x = a[i*2+c]; z[c] += alpha*(x-z[c]); let wet = node.value("mode") > 0.5 ? x-z[c] : z[c]; samples[i*2+c] = x+(wet-x)*mix } }
                    filters[node.id] = z
                default: break
                }
            }
            if node.enabled && [.audioInput,.audio].contains(node.kind) {
                let mode=Int(node.value("channelMode"))
                AudioChannels.apply(&samples,mode:mode)
                if var native=captureSamples[node.id] {
                    AudioChannels.apply(&native.0,mode:mode)
                    captureSamples[node.id]=native
                }
            }
            if !playing { samples = silence }
            let block = AudioBlock(samples:samples,hostTime:host,sampleRate:audioRate,resampling:resamplingContext(node.id)); blocks[node.id] = block
            if let error=inputBlock(node.id,0)?.resampling.error ?? sourceResampling[node.id]?.error { status[node.id]="Audio conversion: \(error)" }
            if status[node.id] == nil { status[node.id] = incoming.isEmpty ? "No input" : String(format:"%.1f kHz · stereo · %.1f dB",audioRate/1000,20*log10(max(0.000001,block.peak))) }
            if node.kind == .audioOutput && node.enabled && playing && !incoming.isEmpty {
                if let io=hardwareIO(node,host:host,status:&status,clientRate:audioRate,requestedRate:outputRequests[node.id] ?? 0) { io.write(samples,hostTime:host);if let error=io.conversionError { status[node.id]="Audio conversion: \(error)" } }
            } else if node.kind == .audioOutput { hardware[node.id]=nil }
        }
        // Audition converts only its monitor copy to the system preview format.
        var audition = previewSource.flatMap { blocks[$0] }
        if let id=previewNode,let kind=graph.node(id)?.kind,[.waveform,.audioVisualizer,.record,.recordAudio].contains(kind) {
            audition=inputBlock(id,kind == .record ? 1:0)
        }
        if previewSource != nil {
            monitor = audition?.resampled(to:48000).samples ?? silence
            wantsMonitor = playing && audition != nil
        }
        recorders = recorders.filter { $0.value.info.phase == "recording" }
        audioRecorders = audioRecorders.filter { $0.value.info.phase == "recording" }
        if wantsMonitor { play(monitor) }
        else if queuedBuffers > 0 || player?.isPlaying == true { flushMonitor() }
        for id in analysisSources {
            guard let block=blocks[id] else { analysisWindows.removeValue(forKey:id); continue }
            var window=analysisWindows[id] ?? []
            if playing { window.append(contentsOf:block.resampled(to:48000).mono); if window.count > 8192 { window.removeFirst(window.count-8192) } }
            analysisWindows[id]=window
        }
        for id in vectorSources where demanded.contains(id) {
            guard let block=blocks[id],playing else { continue }
            let history=lock.withLock { () -> StereoHistory in
                let rate=captureSamples[id]?.1 ?? block.sampleRate
                if vectorHistories[id]?.sampleRate != rate { vectorHistories[id]=StereoHistory(sampleRate:rate) }
                return vectorHistories[id]!
            }
            history.append(captureSamples[id]?.0 ?? block.samples)
        }
        lock.withLock {
            vectorRates=rates
            publishedHardware=Dictionary(uniqueKeysWithValues:hardware.map { ($0.key.uuidString,$0.value.metrics) })
            publishedWindows=analysisWindows
            publishedPreview = ["node":previewNode?.uuidString as Any? ?? NSNull(),"source":previewSource?.uuidString as Any? ?? NSNull(),"active":previewSource != nil && wantsMonitor,"peak":audition?.peak ?? 0,"queuedBuffers":queuedBuffers,"error":monitorError as Any? ?? NSNull()]
            published = blocks; messages = status; mediaStates = states; publishedEnvelopes = envelopes; publishedHistory = envelopeHistory }
    }
    private func hardwareIO(_ node: Node,host: Double,status: inout [UUID:String],clientRate: Double = 48000,requestedRate: Double = 0) -> HardwareAudioIO? {
        let key="\(requestedRate)|\(clientRate)|\(node.deviceID ?? "default")|\(Int(node.value("channelX")))|\(Int(node.value("channelY")))"
        if hardwareKeys[node.id] != key { hardware[node.id]=nil;hardwareRetry[node.id]=nil;hardwareKeys[node.id]=key }
        if let io=hardware[node.id],host >= (hardwareRetry[node.id] ?? 0) {
            hardwareRetry[node.id]=host+1
            hardwareQueue.async { [weak self,weak io] in
                guard let io,!io.formatIsCurrent() else { return }
                self?.queue.async { [weak self] in
                    guard let self,self.hardware[node.id] === io else { return }
                    self.hardware[node.id]=nil;self.hardwareRetry[node.id]=nil
                }
            }
        }
        if hardware[node.id] == nil,!hardwarePending.contains(node.id),host >= (hardwareRetry[node.id] ?? 0) {
            hardwarePending.insert(node.id);hardwareRetry[node.id]=host+2
            hardwareQueue.async { [weak self] in
                let result=Result { try HardwareAudioIO(uid:node.deviceID,input:node.kind == .audioInput,x:Int(node.value("channelX")),y:Int(node.value("channelY")),clientRate:clientRate,requestedRate:requestedRate) }
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.hardwarePending.remove(node.id)
                    guard !self.stopped,self.hardwareKeys[node.id] == key,self.demanded.contains(node.id),self.graph.node(node.id)?.enabled == true,self.playing else { return }
                    switch result {
                    case .success(let io): self.hardware[node.id]=io;self.deviceRates[node.id]=io.rate;self.hardwareErrors[node.id]=nil
                    case .failure(let error): self.hardwareErrors[node.id]=error.localizedDescription
                    }
                }
            }
        }
        guard let io=hardware[node.id] else { status[node.id]=hardwareErrors[node.id] ?? "Waiting for audio device";return nil }
        status[node.id]="\(io.device.name) · \(Int(io.rate)) Hz · channels \(Int(node.value("channelX")))/\(Int(node.value("channelY"))) · \(io.drops) xruns"
        return io
    }
    private var hardwareErrors: [UUID:String] = [:]
    private func play(_ samples: [Float]) {
        do {
            if engine == nil {
                let engine = AVAudioEngine(), player = AVAudioPlayerNode()
                engine.attach(player); engine.connect(player,to:engine.mainMixerNode,format:format)
                try engine.start(); self.engine = engine; self.player = player
            }
            guard let player,queuedBuffers < 8,let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(audioFrames)),let channels = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(audioFrames)
            for i in 0..<audioFrames { for c in 0..<2 { channels[c][i] = min(1,max(-1,samples[i*2+c])) } }
            queuedBuffers += 1
            let generation = monitorGeneration
            player.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack) { [weak self] _ in
                self?.queue.async { [weak self] in if let self,self.monitorGeneration == generation { self.queuedBuffers = max(0,self.queuedBuffers-1) } }
            }
            if !player.isPlaying && queuedBuffers >= 3 { player.play() }
            monitorError = nil
        } catch { monitorError = error.localizedDescription }
    }
}
