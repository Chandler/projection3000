import AppKit
import MetalKit
import AVFoundation
import ImageIO
import PatchCore
import OutputBridge

struct Uniforms {
    var a = SIMD4<Float>(repeating: 0)
    var b = SIMD4<Float>(repeating: 0)
    var c = SIMD4<Float>(repeating: 0)
    var mode = SIMD4<UInt32>(repeating: 0)
    var d = SIMD4<Float>(repeating: 0)
    var e = SIMD4<Float>(repeating: 0)
}
// Mutable fields are confined to renderQueue; worker tasks deliver results there.
final class MediaSource: @unchecked Sendable {
    let path: String
    let start: Double
    let end: Double
    var texture: MTLTexture?
    var cvTexture: CVMetalTexture?
    var player: AVQueuePlayer?
    var looper: AVPlayerLooper?
    var output: AVPlayerItemVideoOutput?
    weak var outputItem: AVPlayerItem?
    var error: String?
    var loading = "Loading…"
    var duration = 0.0
    var requestedSeek: Double?
    var seekRevision: UUID?
    var seeking = false
    init(path: String,start: Double = 0,end: Double = 0) { self.path = path; self.start = start; self.end = end }
    deinit { player?.pause() }
}
final class NDIPublisher {
    let sender: PatchNDI
    let queue = DispatchQueue(label: "patch.ndi.send", qos: .userInitiated)
    let available = DispatchSemaphore(value: 2)
    var buffers: [MTLBuffer] = []
    var index = 0
    init?(_ name: String) { guard let sender = PatchNDI(name: name) else { return nil }; self.sender = sender }
    func encode(_ texture: MTLTexture, device: MTLDevice, command: MTLCommandBuffer, fps: Int) {
        guard available.wait(timeout: .now()) == .success else { return }
        let width = texture.width, height = texture.height, stride = ((width * 4 + 255) / 256) * 256
        let length = stride * height
        // Resolution changes only happen between frames; old buffers are retained by completion closures.
        if buffers.first?.length != length {
            buffers = (0..<2).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
            index = 0
        }
        guard buffers.count == 2, let blit = command.makeBlitCommandEncoder() else { available.signal(); return }
        let buffer = buffers[index]; index = (index + 1) % 2
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0,y: 0,z: 0), sourceSize: .init(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: length)
        blit.endEncoding()
        command.addCompletedHandler { [self] completed in
            queue.async {
                defer { self.available.signal() }
                if completed.status == .completed { self.sender.sendBytes(buffer.contents(), width: Int32(width), height: Int32(height), stride: Int32(stride), fps: Int32(fps)) }
            }
        }
    }
}
final class Renderer {
    private(set) var running = false
    let views = NSHashTable<VideoView>.weakObjects()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let faceReplacementRenderer: FaceReplacementRenderer
    let poseRenderer: PoseRenderer
    private var poseDetectors: [UUID:PoseDetectionResource] = [:]
    private var publishedPoses: [UUID:PoseFrame] = [:]
    func poseFrame(_ id: UUID) -> PoseFrame? { stateLock.withLock { publishedPoses[id] } }
    var poseStates: [String:Any] {
        let frames = stateLock.withLock { publishedPoses }
        return Dictionary(uniqueKeysWithValues:frames.compactMap { id, frame in
            guard let data = try? JSONEncoder().encode(frame), let value = try? JSONSerialization.jsonObject(with:data) else { return nil }
            return (id.uuidString,value)
        })
    }
    let faceBoxRenderer: FaceBoxRenderer
    private var faceDetectors: [UUID:FaceDetectionResource] = [:]
    private var publishedControls: [UUID:Double] = [:]
    private var publishedModulation: [UUID:[String:Double]] = [:]
    var controlValues: [UUID:Double] { stateLock.withLock { publishedControls } }
    var modulationValues: [UUID:[String:Double]] { stateLock.withLock { publishedModulation } }
    private var publishedFaces: [UUID:FaceFrame] = [:]
    func faceFrame(_ id: UUID) -> FaceFrame? { stateLock.withLock { publishedFaces[id] } }
    var faceStates: [String:Any] {
        let frames = stateLock.withLock { publishedFaces }
        return Dictionary(uniqueKeysWithValues:frames.compactMap { id, frame in
            guard let data = try? JSONEncoder().encode(frame), let value = try? JSONSerialization.jsonObject(with:data) else { return nil }
            return (id.uuidString,value)
        })
    }
    private let paletteRenderer: PaletteRenderer
    private let outputRuntime: PublishedOutputRuntime
    private var outputSnapshot: [[String:Any]] = []
    var publishedOutputs: [[String:Any]] { stateLock.withLock { outputSnapshot } }
    func retainPublishedOutputs(_ ids: Set<String>) { renderQueue.async { self.outputRuntime.retained=ids } }
    func setHostManagedOutputs() { renderQueue.async { self.outputRuntime.hostManaged=true } }
    // Visible views renew short leases. AppKit state is only read on its UI thread.
    private var previewDemand: [UUID:Double] = [:]
    private var demandedNodes = Set<UUID>()
    private struct StaticFrame {
        let parameters: [String:Double]
        let source: MTLTexture
        let target: MTLTexture
        let upstreamVersion: UInt64
        let version: UInt64
    }
    private var staticFrames: [UUID:StaticFrame] = [:]
    private var staticVersion: UInt64 = 0
    private var publishedDemand: [String:Any] = [:]
    var demandState: [String:Any] { stateLock.withLock { publishedDemand } }
    func requestPreview(_ id: UUID) {
        renderQueue.async { self.previewDemand[id]=CACurrentMediaTime()+0.3 }
    }
    private var publishedPalettes: [UUID:ColorPalette] = [:]
    func colorPalette(_ id: UUID) -> ColorPalette? { stateLock.withLock { publishedPalettes[id] } }
    var paletteStates: [String:Any] {
        let values=stateLock.withLock { publishedPalettes }
        return Dictionary(uniqueKeysWithValues:values.map { id,palette in
            (id.uuidString,["colorSpace":"sRGB","colors":palette.colors.map { ["r":$0.r,"g":$0.g,"b":$0.b] }] as [String:Any])
        })
    }
    let dither: DitherRenderer
    let glow: DiffusionRenderer
    let layerMuxPipeline: MTLComputePipelineState
    let muxPipeline: MTLComputePipelineState
    let powerGlitchPipeline: MTLComputePipelineState
    let pipeline: MTLComputePipelineState
    let geometryPipeline: MTLRenderPipelineState
    var geometries: [UUID:GeometryResource] = [:]
    var shaders: [UUID:ShaderResource] = [:]
    var glowPreviewResource: ShaderResource?
    var cellularGrids: [UUID:CellularGrid] = [:]
    var fieldPipelines: [FieldProgram:ShaderResource] = [:]
    private var fieldSources: [UUID:FieldInput] = [:]
    private var cellularGridReference: [UUID:UUID] = [:]
    private var meshDetails: [UUID:(String?,MeshGradientStyle.Detail)] = [:]
    private var membranes: [UUID:(key:[Double],texture:MTLTexture?)] = [:]
    /// One type job per node at a time; while dragging, the newest state is set
    /// as soon as the previous job lands instead of every result going stale.
    private struct PosterType { var rendered: PosterTypeKey?; var passes: [PosterTextRenderer.Pass] = []; var busy = false }
    private struct PosterTypeKey: Equatable { var text: String?; var parameters: [String:Double]; var poster: PosterLayout? }
    private var posterTexts: [UUID:PosterType] = [:]
    private var posterPipeline: PosterComposerPipeline?
    /// Second buffer for each composer's layer passes.
    private var posterScratch: [UUID:MTLTexture] = [:]
    /// Image layers' files, decoded off the render queue and kept while in use.
    private var posterImages: [String:(texture: MTLTexture?,used: Double)] = [:]
    private func posterImage(_ path: String) -> MTLTexture? {
        if let entry = posterImages[path] { posterImages[path]?.used = renderTime; return entry.texture }
        posterImages = posterImages.filter { renderTime-$0.value.used < 5 }
        posterImages[path] = (nil,renderTime)
        let device = device
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:4096,kCGImageSourceCreateThumbnailWithTransform:true]
            let image = CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0,0,options as CFDictionary) }
            let texture = image.flatMap { try? ImageUpload.texture($0,device:device) }
            self?.renderQueue.async { if self?.posterImages[path] != nil { self?.posterImages[path]?.texture = texture } }
        }
        return nil
    }
    /// Missing poster layers composite as nothing, not as black.
    private lazy var clearTexture: MTLTexture = {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1,height:1,mipmapped:false)
        descriptor.usage=[.shaderRead];descriptor.storageMode = .shared
        let texture=device.makeTexture(descriptor:descriptor)!
        var pixel: UInt32=0
        texture.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&pixel,bytesPerRow:4)
        return texture
    }()
    private var membraneJobs: Set<UUID> = []
    private let membraneQueue = DispatchQueue(label:"Patch.LiquidChromeMembrane",qos:.userInitiated)
    private var ferrofluids: [UUID:(sim:FerrofluidSim,textures:[MTLTexture],next:Int)] = [:]
    let previewPipeline: MTLRenderPipelineState
    let black: MTLTexture
    private var cache: CVMetalTextureCache!
    private var audioVisualizers: [UUID:AudioVisualizer] = [:]
    private var textSources: [UUID:TextSource] = [:]
    private var cameras: [UUID:CameraSource] = [:]
    let audioGraph = AudioGraphEngine()
    var apcState: APC40State { audioGraph.apcState }
    private let chromaRenderer: ChromaRenderer
    lazy var midiGraph = MIDIGraphEngine(instruments:audioGraph.instrumentMIDI)
    private let profileVideoRenderer: ProfileVideoRenderer
    private let rasterSynthRenderer: RasterSynthRenderer
    private let vectorArtRenderer: VectorArtRenderer
    private let voltageRenderer: VoltageRenderer
    private let oscilloscopeRenderer: OscilloscopeRenderer
    private let voltageFluidRenderer: VoltageFluidRenderer
    private let projectorRenderer: ProjectorRenderer
    private var publishedMedia: [UUID:VideoAudioClock] = [:]
    var mediaStates: [UUID:VideoAudioClock] { stateLock.withLock { publishedMedia } }
    private var media: [UUID: MediaSource] = [:]
    private var previewNode: UUID?
    func setPreviewNode(_ id: UUID?) { renderQueue.async { self.previewNode = id; self.audioGraph.preview(id) } }
    private var targets: [UUID: MTLTexture] = [:]
    private var layerPreviews: [UUID: MTLTexture] = [:]
    private(set) var textures: [UUID: MTLTexture] = [:]
    private var recordings: [UUID:any TakeRecorder] = [:]
    private var syphon: [UUID: PatchSyphon] = [:]
    private var ndi: [UUID: NDIPublisher] = [:]
    private var outputNames: [UUID: String] = [:]
    private var inFlight = DispatchSemaphore(value: 3)
    private var plan: [Node] = []
    private var inputs: [UUID: [Int: UUID]] = [:]
    private var routing = SignalRouting()
    private var plannedGraph: Graph?
    let renderQueue = DispatchQueue(label:"patch.render",qos:.userInteractive)
    private var frameTimer: DispatchSourceTimer?
    private var activeGraph = Graph()
    private var publicationGraph = Graph()
    private var nextFrameTime = 0.0
    private let stateLock = NSLock()
    private var publishedTextures: [UUID:MTLTexture] = [:]
    private var publishedStatus: [UUID:String] = [:]
    private var publishedGPU = 0.0
    private var publishedFrames = 0
    private var publishedDropped = 0
    private var publishedTime = 0.0
    struct VoltageScope {
        var node: Node
        var source: UUID?
        var rate: Double
        var linked: Bool
        var seconds: Double { AnalogVectorStyle.trailSeconds(node,rate:rate) }
    }
    private var publishedVoltageScopes: [UUID:VoltageScope] = [:]
    func voltageScope(_ id: UUID?) -> VoltageScope? {
        guard let id else { return nil }
        return stateLock.withLock { publishedVoltageScopes[id] }
    }
    var voltageScopeStates: [String:Any] {
        let scopes=stateLock.withLock { publishedVoltageScopes }
        return Dictionary(uniqueKeysWithValues:scopes.map { id,scope in
            let history=audioGraph.oscilloscopeSamples(scope.source,seconds:scope.seconds)
            return (id.uuidString,["samplePath":audioGraph.scopeSamplePath(id),"trailMS":scope.seconds*1000,"sampleRate":history.rate,"drawnPoints":history.points.count,"drawRate":scope.rate,"rateLinked":scope.linked,"previewMode":"videoTexture"] as [String:Any])
        })
    }
    private var publishedMeshPositions: [UUID:[Position]] = [:]
    func meshPositions(_ id: UUID) -> [Position]? { stateLock.withLock { publishedMeshPositions[id] } }
    private var renderStatus: [UUID:String] = [:]
    private var liveStreams: [UUID:LiveStreamSource] = [:]
    private var liveStreamFrames: [UUID:CVMetalTexture] = [:]
    private var syphonInputs: [String:PatchSyphonInput] = [:]
    private var ndiInputs: [String:PatchNDIReceiver] = [:]
    private var ndiInputFrames: [String:CVMetalTexture] = [:]
    var renderTime = 0.0
    private var playing = true
    var status: [UUID:String] { stateLock.withLock { publishedStatus } }
    var gpuMS: Double { stateLock.withLock { publishedGPU } }
    var renderedFrames: Int { stateLock.withLock { publishedFrames } }
    var droppedFrames: Int { stateLock.withLock { publishedDropped } }
    var time: Double { stateLock.withLock { publishedTime } }
    func start(graph: Graph, playing: Bool) {
        guard !running else { return }
        running = true
        audioGraph.resume(); midiGraph.resume()
        for view in views.allObjects { view.isPaused = false }
        update(graph:graph,playing:playing)
        let timer = DispatchSource.makeTimerSource(queue:renderQueue)
        timer.schedule(deadline:.now(),repeating:1.0/120.0,leeway:.microseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            guard now >= self.nextFrameTime - 0.001 else { return }
            self.nextFrameTime = max(self.nextFrameTime + 1.0/Double(self.activeGraph.fps),now)
            self.render(self.activeGraph,preview:nil)
        }
        frameTimer = timer; timer.resume()
    }
    func activatePrepared(_ graph: Graph, playing: Bool, resources: [UUID:ShaderResource]) {
        guard running else { return }
        midiGraph.update(graph,playing:playing)
        renderQueue.async {
            for (id,resource) in resources {
                if let program = resource.fieldProgram { self.fieldPipelines[program] = resource }
                else { self.shaders[id] = resource }
            }
            self.activeGraph = graph; self.publicationGraph = graph; self.playing = playing
            self.audioGraph.update(graph,playing:playing,time:self.renderTime)
        }
    }
    func update(graph: Graph, playing: Bool, publicationGraph: Graph? = nil) { guard running else { return }; midiGraph.update(graph,playing:playing);renderQueue.async { self.activeGraph = graph; self.publicationGraph = publicationGraph ?? graph; self.playing = playing; self.audioGraph.update(graph,playing:playing,time:self.renderTime) } }
    func stop() {
        running = false
        frameTimer?.cancel(); frameTimer = nil
        for view in views.allObjects { view.isPaused = true }
        renderQueue.sync {
            syphon.removeAll(); outputRuntime.publishers.removeAll(); ndi.removeAll(); cameras.removeAll(); media.removeAll(); liveStreams.removeAll(); liveStreamFrames.removeAll(); syphonInputs.removeAll(); ndiInputs.removeAll(); ndiInputFrames.removeAll()
            previewDemand.removeAll(); demandedNodes.removeAll()
            stateLock.withLock { publishedDemand = [:]; outputSnapshot = []; publishedGPU = 0 }
        }
        audioGraph.stop();midiGraph.stop()
    }
    deinit { frameTimer?.cancel() }
    private var lastTime = CACurrentMediaTime()
    private let adjustmentAlpha: MTLComputePipelineState
    private let adjustmentDither: DitherRenderer
    private let adjustmentDiffusion: DiffusionRenderer
    private var adjustmentNodes: [UUID:Node] = [:]

    func encodeAdjustment(_ source: String, input: MTLTexture, output: MTLTexture,
                          command: MTLCommandBuffer, time: Double) throws {
        try renderQueue.sync {
            guard let graph = plannedGraph else { throw GraphError("Patch graph is loading") }
            let nodes = try graph.adjustmentChain(source: source)
            adjustmentDither.retain(Set(graph.nodes.map(\.id)))
            adjustmentDiffusion.retain(Set(graph.nodes.map(\.id)))
            let size = MTLSize(width: input.width, height: input.height, depth: 1)
            let tile = MTLSize(width: 16, height: 16, depth: 1)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                      width: size.width, height: size.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            func scratch() throws -> MTLTexture {
                guard let texture = device.makeTexture(descriptor: descriptor) else { throw GraphError("Could not allocate adjustment texture") }
                return texture
            }
            func alpha(_ source: MTLTexture, _ target: MTLTexture, restore: Bool) throws {
                guard let encoder = command.makeComputeCommandEncoder() else { throw GraphError("Could not encode adjustment") }
                var mode: UInt32 = restore ? 1 : 0
                encoder.setComputePipelineState(adjustmentAlpha)
                encoder.setTexture(input, index: 0)
                encoder.setTexture(source, index: 1)
                encoder.setTexture(target, index: 2)
                encoder.setBytes(&mode, length: MemoryLayout<UInt32>.size, index: 0)
                encoder.dispatchThreads(size, threadsPerThreadgroup: tile)
                encoder.endEncoding()
            }
            let first = try scratch(), second = try scratch()
            try alpha(input, first, restore: false)
            var prior = first, target = second
            for original in nodes {
                let node = adjustmentNodes[original.id] ?? original
                guard node.enabled else { continue }
                switch node.kind {
                case .dither:
                    guard adjustmentDither.encode(command, node: node, source: prior, target: target) else {
                        throw GraphError("Could not encode Dither")
                    }
                case .diffusion:
                    adjustmentDiffusion.encode(command, node: node, source: prior, target: target)
                case .shaderEffect:
                    let resource = shader(node)
                    guard let pipeline = resource?.pipeline, let encoder = command.makeComputeCommandEncoder() else {
                        throw GraphError(resource?.error ?? "Compiling " + node.name)
                    }
                    let specs = node.fieldParameters
                    var t = Float(time * (specs?.first(where: { $0.scalesFieldTime == true }).map { node.value($0.key) } ?? (specs == nil ? node.value("speed") : 1)))
                    var controls = [SIMD4<Float>](repeating: .zero, count: 8)
                    if let specs {
                        for (i, spec) in specs.enumerated() { controls[i/4][i%4] = Float(node.value(spec.key)) }
                        controls[3].w = t
                    } else {
                        controls[0] = .init(Float(node.value("p1")), Float(node.value("p2")), Float(node.value("p3")), Float(node.value("p4")))
                        controls[1].x = Float(node.value("mix"))
                    }
                    encoder.setComputePipelineState(pipeline)
                    encoder.setTexture(target, index: 0)
                    encoder.setTexture(prior, index: 1)
                    encoder.setTexture(black, index: 2)
                    encoder.setBytes(&t, length: MemoryLayout<Float>.size, index: 0)
                    controls.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
                    encoder.dispatchThreads(size, threadsPerThreadgroup: tile)
                    encoder.endEncoding()
                default:
                    guard let encoder = command.makeComputeCommandEncoder() else { throw GraphError("Could not encode adjustment") }
                    var uniforms = Uniforms()
                    uniforms.videoAdjustment(node)
                    encoder.setComputePipelineState(pipeline)
                    encoder.setTexture(prior, index: 0)
                    encoder.setTexture(black, index: 1)
                    encoder.setTexture(target, index: 2)
                    encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                    var audio: Float = 0
                    encoder.setBytes(&audio, length: MemoryLayout<Float>.size, index: 1)
                    encoder.dispatchThreads(size, threadsPerThreadgroup: tile)
                    encoder.endEncoding()
                }
                swap(&prior, &target)
            }
            try alpha(prior, output, restore: true)
        }
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw GraphError("A Metal GPU is required.") }
        self.device = device; self.queue = queue
        chromaRenderer = try ChromaRenderer(device:device)
        let url = try PatchResources.shaderURL()
        voltageRenderer = try VoltageRenderer(device:device)
        profileVideoRenderer = try ProfileVideoRenderer(device:device)
        rasterSynthRenderer = try RasterSynthRenderer(device:device)
        oscilloscopeRenderer = try OscilloscopeRenderer(device:device)
        voltageFluidRenderer = try VoltageFluidRenderer(device:device)
        projectorRenderer = try ProjectorRenderer(device:device)
        let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
        adjustmentAlpha = try device.makeComputePipelineState(function: library.makeFunction(name: "adjustmentAlpha")!)
        adjustmentDither = try DitherRenderer(device: device, library: library)
        adjustmentDiffusion = try DiffusionRenderer(device: device, library: library)
        vectorArtRenderer = try VectorArtRenderer(device:device,library:library)
        faceReplacementRenderer = try FaceReplacementRenderer(device:device,library:library)
        poseRenderer = try PoseRenderer(device:device,library:library)
        faceBoxRenderer = try FaceBoxRenderer(device:device,library:library)
        paletteRenderer = try PaletteRenderer(device:device,library:library)
        outputRuntime = try PublishedOutputRuntime(device:device,library:library)
        dither = try DitherRenderer(device:device,library:library)
        glow = try DiffusionRenderer(device:device,library:library)
        layerMuxPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "layerMuxPreview")!)
        muxPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "muxVideos")!)
        powerGlitchPipeline = try device.makeComputePipelineState(function: library.makeFunction(name:"powerGlitch")!)
        pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "process")!)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreen"); desc.fragmentFunction = library.makeFunction(name: "preview")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        previewPipeline = try device.makeRenderPipelineState(descriptor: desc)
        let geo = MTLRenderPipelineDescriptor()
        geo.vertexFunction = library.makeFunction(name:"geometryVertex"); geo.fragmentFunction = library.makeFunction(name:"geometryFragment")
        geo.colorAttachments[0].pixelFormat = .bgra8Unorm
        geo.colorAttachments[0].isBlendingEnabled = true
        geo.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; geo.colorAttachments[0].destinationRGBBlendFactor = .one
        geometryPipeline = try device.makeRenderPipelineState(descriptor:geo)
        let b = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        b.storageMode = .shared
        black = device.makeTexture(descriptor: b)!
        var pixel: UInt32 = 0xff000000
        black.replace(region: .init(origin: .init(x: 0,y: 0,z: 0), size: .init(width: 1,height: 1,depth: 1)), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }
    // A regular AppKit drawing surface also works inside SwiftUI modal sheets,
    // where nested CAMetalLayer drawables may never become available.
    func meshPreviewImage(_ id: UUID,completion: @escaping (CGImage?)->Void) {
        renderQueue.async { [self] in
            let tex=texture(id),stride=((tex.width*4+255)/256)*256
            guard let bytes=device.makeBuffer(length:stride*tex.height,options:.storageModeShared),
                  let command=queue.makeCommandBuffer(),let blit=command.makeBlitCommandEncoder() else {
                DispatchQueue.main.async {completion(nil)};return
            }
            blit.copy(from:tex,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:tex.width,height:tex.height,depth:1),to:bytes,destinationOffset:0,destinationBytesPerRow:stride,destinationBytesPerImage:bytes.length)
            blit.endEncoding()
            command.addCompletedHandler { command in
                var image: CGImage?
                if command.status == .completed {
                    let data=Data(bytes:bytes.contents(),count:bytes.length)
                    if let provider=CGDataProvider(data:data as CFData) {
                        image=CGImage(width:tex.width,height:tex.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
                    }
                }
                let result=image
                DispatchQueue.main.async {completion(result)}
            }
            command.commit()
        }
    }
    func texture(_ id: UUID?) -> MTLTexture { stateLock.withLock { id.flatMap { publishedTextures[$0] } ?? black } }
    func source(_ node: Node) -> MediaSource? {
        guard let path = node.file, !path.isEmpty else { renderStatus[node.id] = "Choose a file"; return nil }
        if let found = media[node.id], found.path == path, found.start == node.value("start"), found.end == node.value("end") { return found }
        let item = MediaSource(path:path,start:node.value("start"),end:node.value("end")); media[node.id] = item
        guard FileManager.default.fileExists(atPath: path) else { item.error = "File not found"; return item }
        if node.kind == .image {
            let device = self.device
            DispatchQueue.global(qos: .userInitiated).async { [weak item] in
                do {
                    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { throw GraphError("Cannot decode image") }
                    let tex = try ImageUpload.texture(image,device:device)
                    self.renderQueue.async { item?.texture = tex }
                } catch { self.renderQueue.async { item?.error = error.localizedDescription } }
            }
        } else {
            if MediaCompatibility.needsPreparation(path) { item.loading = "Preparing MKV for playback…" }
            let queue = renderQueue
            Task { [weak item] in
                do {
                    let playableURL = try await MediaCompatibility.shared.playbackURL(for:path)
                    let asset = AVURLAsset(url:playableURL)
                    let duration = try await asset.load(.duration).seconds
                    let start = node.value("start"), end = node.value("end") > 0 ? min(duration,node.value("end")) : duration
                    guard duration.isFinite, end > start else { throw GraphError("Loop start is outside the video duration") }
                    let playerItem = AVPlayerItem(asset:asset)
                    let composition = AVVideoComposition(propertiesOf:asset)
                    await MainActor.run { playerItem.videoComposition = composition }
                    let player = AVQueuePlayer(); player.isMuted = true
                    let range = CMTimeRange(start:CMTime(seconds:start,preferredTimescale:60000),duration:CMTime(seconds:end-start,preferredTimescale:60000))
                    let looper = AVPlayerLooper(player:player,templateItem:playerItem,timeRange:range)
                    queue.async { item?.looper = looper; item?.player = player; item?.duration = duration }
                } catch { queue.async { item?.error = error.localizedDescription } }
            }
        }
        return item
    }
    /// Downstream styling and canvas layout must not interrupt pose inference.
    private func poseDependencies(_ graph: Graph, _ id: UUID) -> ([Node],[Edge]) {
        var ids: Set<UUID> = [id], pending = [id]
        while let next = pending.popLast() {
            for edge in graph.dependencies where edge.target == next {
                if ids.insert(edge.source).inserted { pending.append(edge.source) }
            }
        }
        let nodes = graph.nodes.filter { ids.contains($0.id) }.map { original -> Node in
            var n = original; n.position = .init(0,0); n.name = ""; return n
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let edges = graph.edges.filter { ids.contains($0.target) }.sorted { $0.id.uuidString < $1.id.uuidString }
        return (nodes,edges)
    }
    private var streamSizes: [UUID:VideoDimensions] = [:]
    func render(_ graph: Graph, preview: UUID?) {
        let now = CACurrentMediaTime(), dt = min(now - lastTime, 0.2); lastTime = now
        if playing { renderTime += dt }
        guard inFlight.wait(timeout: .now()) == .success else { stateLock.withLock { publishedDropped += 1 }; return }
        guard let command = queue.makeCommandBuffer() else { inFlight.signal(); return }
        if plannedGraph != graph {
            // Discard old detections after graph edits (including upstream transforms/reconnections).
            poseRenderer.retainHistory(Set(graph.nodes.map(\.id)))
            for node in graph.nodes where node.kind == .poseRender {
                if let old = plannedGraph, old.width == graph.width, old.height == graph.height {
                    let before = poseDependencies(old,node.id), after = poseDependencies(graph,node.id)
                    if before.0 != after.0 || before.1 != after.1 { poseRenderer.invalidateHistory(node.id) }
                } else { poseRenderer.invalidateHistory(node.id) }
            }
            for (id,detector) in poseDetectors {
                if let old = plannedGraph, old.width == graph.width, old.height == graph.height {
                    let before = poseDependencies(old,id), after = poseDependencies(graph,id)
                    if before.0 != after.0 || before.1 != after.1 { detector.invalidate() }
                } else { detector.invalidate() }
            }
            poseDetectors = poseDetectors.filter { graph.node($0.key)?.kind == .yoloPose }
            for (id,detector) in faceDetectors {
                if let old = plannedGraph, old.width == graph.width, old.height == graph.height {
                    let before = poseDependencies(old,id), after = poseDependencies(graph,id)
                    if before.0 != after.0 || before.1 != after.1 { detector.invalidate() }
                } else { detector.invalidate() }
            }
            faceDetectors = faceDetectors.filter { graph.node($0.key)?.kind == .faceDetect }
            for node in graph.nodes where node.kind == .videoPalette || node.kind == .syphon {
                if let old=plannedGraph, old.width==graph.width, old.height==graph.height {
                    let before=poseDependencies(old,node.id), after=poseDependencies(graph,node.id)
                    if before.0 != after.0 || before.1 != after.1 { paletteRenderer.invalidate(node.id) }
                } else { paletteRenderer.invalidate(node.id) }
            }
            plan = (try? graph.orderedNodes()) ?? []
            routing = SignalRouting(graph)
            inputs = [:]
            for e in graph.edges { inputs[e.target, default: [:]][e.input] = e.source }
            let ids = Set(graph.nodes.map(\.id))
            layerPreviews = layerPreviews.filter { ids.contains($0.key) }
            paletteRenderer.retain(ids)
            staticFrames=staticFrames.filter { ids.contains($0.key) }
            dither.retain(ids)
            glow.retain(ids)
            cellularGrids = cellularGrids.filter { routing.nodes[$0.key]?.kind == .cellularField }
            // Existing shows derive their simulation grid from their LED display. Use
            // document order to select one domain when several displays share a field.
            cellularGridReference.removeAll(keepingCapacity:true)
            fieldSources.removeAll(keepingCapacity:true)
            for node in graph.nodes where node.kind.outputType == .field {
                fieldSources[node.id] = FieldInput(producer:node)
            }
            var usedPrograms = Set<FieldProgram>()
            for node in graph.nodes {
                if node.kind.outputType == .field, node.kind != .fieldMix, let input = fieldSources[node.id] {
                    usedPrograms.insert(FieldProgram(primary:input,secondary:nil))
                }
                guard [.ledMatrix,.fieldMix,.fieldRender].contains(node.kind) else { continue }
                func fieldInput(_ slot: Int) -> FieldInput? {
                    guard let edge = routing.sockets[node.id]?[slot], let source = routing.nodes[edge.source], source.enabled else { return nil }
                    if node.kind == .ledMatrix, source.kind == .cellularField, cellularGridReference[source.id] == nil {
                        cellularGridReference[source.id] = node.id
                    }
                    return fieldSources[source.id]
                }
                usedPrograms.insert(FieldProgram(primary:fieldInput(node.kind == .ledMatrix ? 1 : 0),secondary:fieldInput(node.kind == .ledMatrix ? 2 : 1)))
            }
            fieldPipelines = fieldPipelines.filter { usedPrograms.contains($0.key) }
            geometries = geometries.filter { ids.contains($0.key) }; shaders = shaders.filter { ids.contains($0.key) }
            meshDetails = meshDetails.filter { ids.contains($0.key) }
            audioVisualizers = audioVisualizers.filter { ids.contains($0.key) }
            vectorArtRenderer.prune(ids);voltageRenderer.prune(ids);oscilloscopeRenderer.prune(ids);voltageFluidRenderer.prune(ids);projectorRenderer.prune(ids)
            textSources = textSources.filter { ids.contains($0.key) }
            cameras = cameras.filter { id, _ in graph.node(id)?.enabled == true && graph.node(id)?.kind == .webcam }
            liveStreams = liveStreams.filter { ids.contains($0.key) };liveStreamFrames = liveStreamFrames.filter { ids.contains($0.key) }
            let selectedSyphon = Set(graph.nodes.filter { $0.enabled && $0.kind == .syphonIn }.compactMap(\.deviceID))
            syphonInputs = syphonInputs.filter { selectedSyphon.contains($0.key) }
            let ndiNames = Set(graph.nodes.filter { $0.enabled && $0.kind == .ndiIn }.compactMap { $0.text?.trimmingCharacters(in:.whitespacesAndNewlines) })
            ndiInputs = ndiInputs.filter { ndiNames.contains($0.key) }
            ndiInputFrames = ndiInputFrames.filter { ndiNames.contains($0.key) }
            media = media.filter { ids.contains($0.key) }; targets = targets.filter { ids.contains($0.key) }
            syphon = syphon.filter { id, _ in graph.node(id)?.enabled == true && graph.node(id)?.kind == .syphon }
            ndi = ndi.filter { id, _ in graph.node(id)?.enabled == true && graph.node(id)?.kind == .ndi }
            streamSizes = Dictionary(uniqueKeysWithValues:graph.nodes.map { ($0.id,graph.videoDimensions($0.id)) })
            outputRuntime.plan(graph,publicationGraph:publicationGraph)
            plannedGraph = graph
        }
        for (id,recorder) in recordings where recorder.info.phase == "recording" {
            let connected = graph.node(id)?.enabled == true && graph.edges.contains(where:{ $0.target == id && $0.input == 0 })
            if let movie = recorder as? MovieRecorder {
                if !connected || graph.node(id)?.kind != .record || streamSizes[id]?.width != movie.width || streamSizes[id]?.height != movie.height || graph.fps != movie.fps { movie.finish() }
            } else if !connected || graph.node(id)?.kind != .recordAudio { recorder.finish() }
        }
        previewDemand = previewDemand.filter { $0.value > now && graph.node($0.key) != nil }
        var raster = Set(previewDemand.keys)
        if let preview { raster.insert(preview) }
        var previewLayers = raster
        var layerPreviewFrames: [UUID:MTLTexture] = [:]
        var vectorArtPathDemand = Set<UUID>()
        var required = Set<UUID>()
        let nodes = routing.nodes, dependencies = routing.incoming, sockets = routing.sockets
        // Resolve controls before walking image dependencies. A zero MUX input
        // can sleep while its fader/LFO/envelope keeps running to wake it again.
        let apcValues = apcState.snapshot
        let apcOwns = graph.nodes.contains { $0.kind == .apc40 }
        let audioSnapshot = audioGraph.snapshot
        var controlValues: [UUID:Double] = [:]
        var modulationValues: [UUID:[String:Double]] = [:]
        var resolvedNodes: [UUID:Node] = [:]
        func usesModulation(_ node: Node,_ key: String) -> Bool {
            !((node.kind == .mux || node.kind == .layerMux) && !apcOwns && node.value("followAPC") == 1 && key.hasPrefix("level"))
        }
        func resolvedNode(_ id: UUID) -> Node? {
            if let cached=resolvedNodes[id] { return cached }
            guard var node=nodes[id] else { return nil }
            if node.enabled {
                for (key,binding) in node.modulations ?? [:] where binding.enabled && usesModulation(node,key) {
                    if let value=controlValue(binding.source,binding.outputIndex), let spec=node.parameterDefinitions.first(where:{ $0.key == key }) {
                        node.parameters[key]=binding.value(at:value,spec:spec)
                        modulationValues[id,default:[:]][key]=node.parameters[key]
                    }
                }
                if node.kind.outputType == .control && node.kind != .apc40 {
                    controlValues[id]=node.kind == .audioEnvelope ? (audioSnapshot.3[id] ?? 0) : ControlSignal.value(node,time:renderTime)
                }
            }
            resolvedNodes[id]=node
            return node
        }
        func controlValue(_ source: UUID,_ output: Int = 0) -> Double? {
            guard let node=resolvedNode(source),node.enabled else { return nil }
            if node.kind == .apc40 { return apcValues.indices.contains(output) ? apcValues[output] : nil }
            return controlValues[source]
        }
        var visitedDemand: [UUID:Int] = [:]
        var gatedMuxInputs: [UUID:Set<Int>] = [:]
        func require(_ id: UUID) {
            guard let node=resolvedNode(id) else { return }
            // A recipe consumer may visit first; a later palette/video consumer
            // must still propagate its stronger raster demand upstream.
            let demand=1 | (raster.contains(id) ? 2:0) | (previewLayers.contains(id) ? 4:0)
            guard visitedDemand[id] != demand else { return }
            visitedDemand[id]=demand;required.insert(id)
            for edge in dependencies[id] ?? [] {
                if !node.enabled && node.kind.bypassInput() != edge.input { continue }
                if node.enabled && (node.kind == .mux || node.kind == .layerMux) {
                    if edge.input >= node.channelCount || node.value("level\(edge.input+1)")<=0 {
                        gatedMuxInputs[id,default:[]].insert(edge.input);continue
                    }
                    if nodes[edge.source]?.kind.outputType(at:edge.outputIndex) == .video && node.value("mode\(edge.input+1)")>=0.5 && nodes[edge.source]?.enabled != true { continue }
                }
                if node.enabled && node.kind == .ab {
                    let mix=node.value("mode") == 1 ? (node.value("mix")<0.5 ? 0.0:1.0) : node.value("mix")
                    if (edge.input == 0 && mix>=1) || (edge.input == 1 && mix<=0) { continue }
                }
                if (node.kind == .videoPalette || node.kind == .layerMux || node.kind == .ab) && (node.kind == .videoPalette || previewLayers.contains(id) || raster.contains(id)) { previewLayers.insert(edge.source); raster.insert(edge.source) }
                if nodes[edge.source]?.kind.outputType(at:edge.outputIndex) == .video { raster.insert(edge.source) }
                if edge.outputIndex == 0, nodes[edge.source]?.kind.vectorArtModule != nil { vectorArtPathDemand.insert(edge.source) }
                require(edge.source)
            }
            if node.enabled { for (key,binding) in node.modulations ?? [:] where binding.enabled && usesModulation(node,key) { require(binding.source) } }
        }
        for id in raster { require(id) }
        for port in outputRuntime.ports where outputRuntime.retained.contains(port.id) || (!outputRuntime.hostManaged && port.listed) || (port.explicit && port.type == .video) {
            if port.type == .video { raster.insert(port.nodeID) }
            require(port.nodeID)
        }
        // Explicit publishers and audible/recording sinks are consumers in their own right.
        for node in plan where node.enabled && ([.syphon,.ndi,.publishPalette,.audioOutput,.midiOut,.recordAudio].contains(node.kind) || recordings[node.id]?.info.phase == "recording") { require(node.id) }
        if let previewNode { require(previewNode) }
        for id in demandedNodes.subtracting(required) { media[id]?.player?.pause(); liveStreams[id]?.pause() }
        cameras = cameras.filter { required.contains($0.key) }
        if demandedNodes != required { audioGraph.setDemand(required) }
        demandedNodes = required
        textures.removeAll(keepingCapacity: true); renderStatus.removeAll(keepingCapacity: true)
        var retainedCV: [CVMetalTexture] = []
        var faceFrames: [UUID:FaceFrame] = [:]
        var poseFrames: [UUID:PoseFrame] = [:]
        let midiStatus = midiGraph.status
        chromaRenderer.retain(Set(plan.map(\.id)))
        let drawRates = audioGraph.drawRates
        var videoClocks: [UUID:VideoAudioClock] = [:]
        var paletteValues: [UUID:ColorPalette] = [:]
        var profileFrames: [UUID:ProfileVideoFrame] = [:]
        var frameReferences: [SignalOutlet:UUID] = [:]
        var fields: [SignalOutlet:FieldSignal] = [:]
        adjustmentNodes = resolvedNodes
        var effectiveNodes: [UUID:Node] = [:]
        var staticVersions: [UUID:UInt64] = [:]
        var staticCacheHits=0
        for originalNode in plan {
            guard required.contains(originalNode.id) else { renderStatus[originalNode.id]="Idle · No consumers"; continue }
            let node = resolvedNodes[originalNode.id] ?? originalNode
            effectiveNodes[node.id] = node
            let incoming = inputs[node.id] ?? [:]
            func inputTexture(_ input: Int) -> MTLTexture {
                guard let edge=sockets[node.id]?[input] else { return black }
                if nodes[edge.source]?.kind.outputType(at:edge.outputIndex) == .collection {
                    return layerPreviewFrames[edge.source] ?? textures[edge.source] ?? black
                }
                return textures[edge.source] ?? black
            }
            let a=inputTexture(0), b=inputTexture(1)
            if !node.enabled {
                let source = node.kind.bypassInput().flatMap { incoming[$0] }
                textures[node.id] = source.flatMap { textures[$0] } ?? black
                if node.kind.outputType == .rgbProfiles { profileFrames[node.id] = source.flatMap { profileFrames[$0] } }
                if node.kind.outputType == .palette { paletteValues[node.id] = source.flatMap { paletteValues[$0] } ?? .empty }
                staticVersions[node.id] = source.flatMap { staticVersions[$0] }
                outputRuntime.recipes.removeValue(forKey:node.id)
                renderStatus[node.id] = node.kind == .apc40 ? "Paused · Controller still reserved" : node.kind.pausedStatus
                media[node.id]?.player?.pause()
                liveStreams[node.id]?.pause()
                continue
            }
            if node.kind.isMIDINode { renderStatus[node.id]=midiStatus[node.id] ?? "Waiting for MIDI";continue }
            if node.kind.outputType == .field && node.kind != .fieldMix {
                let palette = incoming[0].map { paletteValues[$0] ?? .empty } ?? PaletteStyle.defaultPalette
                guard let input = fieldSources[node.id], var field = FieldSignal(node:node,input:input,palette:palette,time:renderTime) else {
                    renderStatus[node.id] = node.kind == .fieldShader ? "Choose a Metal field shader" : "Field evaluator unavailable"
                    continue
                }
                let projectSize = VideoDimensions(graph.width,graph.height)
                let grid: VideoDimensions
                if field.input == .cells {
                    let displayID = cellularGridReference[node.id]
                    grid = cellularDomain(node,display:displayID.flatMap(resolvedNode),displaySize:displayID.flatMap { streamSizes[$0] },project:projectSize)
                    let result = cellularTexture(node,columns:grid.width,rows:grid.height,command:command)
                    field.texture = result.0; renderStatus[node.id] = result.1
                    guard field.texture != nil else { continue }
                } else {
                    grid = fieldPreviewDimensions(projectSize)
                }
                fields[SignalOutlet(node:node.id,port:0)] = field
                if node.kind != .streakGlow {
                    if raster.contains(node.id) {
                        let size = fieldPreviewDimensions(projectSize)
                        let previous = targets[node.id]
                        let result = self.preview(field,grid:grid,size:size,previous:previous,command:command)
                        if let texture = result.texture { targets[node.id] = texture; textures[node.id] = texture }
                        if let status = result.status { renderStatus[node.id] = status }
                    }
                    if renderStatus[node.id] == nil { renderStatus[node.id] = "Ready" }
                    continue
                }
            }
            if node.kind == .streakGlow {
                let function=StreakGlowStyle.functions[max(0,min(StreakGlowStyle.functions.count-1,Int(node.value("function"))))]
                renderStatus[node.id] = node.enabled ? "Glow · \(function) · gray = neutral light" : node.kind.pausedStatus
                if node.enabled, raster.contains(node.id), let pipeline=glowPreviewPipeline() {
                    if targets[node.id]?.width != 320 || targets[node.id]?.height != 180 {
                        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:320,height:180,mipmapped:false)
                        desc.usage = [.shaderRead,.shaderWrite]; desc.storageMode = .private; targets[node.id] = device.makeTexture(descriptor:desc)
                    }
                    if let target=targets[node.id],let encoder=command.makeComputeCommandEncoder() {
                        var values=StreakGlowStyle.keys.map { Float(node.value($0)) }
                        values += [Float](repeating:0,count:16-values.count); values[15]=Float(renderTime*node.value("speed"))
                        encoder.setComputePipelineState(pipeline); encoder.setTexture(target,index:0)
                        values.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
                        encoder.dispatchThreads(.init(width:320,height:180,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); encoder.endEncoding()
                        textures[node.id]=target
                    }
                }
                continue
            }
            if node.kind == .chromaEncoder,node.enabled,incoming[0] != nil {
                frameReferences[SignalOutlet(node:node.id,port:1)] = node.id
                chromaRenderer.capture(a,node:node,now:now,command:command,queue:renderQueue,bridge:audioGraph.chroma)
            }
            if node.kind.isAudioNode {
                renderStatus[node.id] = audioSnapshot.1[node.id] ?? "Loading audio…"
                guard raster.contains(node.id) else { continue }
                if targets[node.id]?.width != 640 || targets[node.id]?.height != 240 {
                    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:240,mipmapped:false)
                    desc.usage = [.shaderRead,.shaderWrite]; desc.storageMode = .private; targets[node.id] = device.makeTexture(descriptor:desc)
                }
                if let target = targets[node.id],let encoder = command.makeComputeCommandEncoder() {
                    let mono = audioSnapshot.0[node.id]?.mono ?? []
                    let samples = (0..<512).map { mono.isEmpty ? Float(0) : mono[min(mono.count-1,$0*mono.count/512)] }
                    var params = Uniforms(); params.mode.x = 5; params.a = .init(1,0.12,2,0)
                    encoder.setComputePipelineState(pipeline); encoder.setTexture(black,index:0); encoder.setTexture(black,index:1); encoder.setTexture(target,index:2)
                    encoder.setBytes(&params,length:MemoryLayout<Uniforms>.stride,index:0)
                    samples.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
                    encoder.dispatchThreads(.init(width:640,height:240,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); encoder.endEncoding(); textures[node.id] = target
                }
                continue
            }
            if node.kind == .ab {
                let mix=node.value("mode") == 1 ? (node.value("mix")<0.5 ? 0.0:1.0) : max(0,min(1,node.value("mix")))
                var layers=[[String:Any]]()
                for channel in 0..<2 {
                    let level=channel == 0 ? 1-mix:mix
                    guard level>0,let edge=sockets[node.id]?[channel],let upstream=effectiveNodes[edge.source] else { continue }
                    var recipe: [String:Any]?
                    if upstream.kind.outputType(at:edge.outputIndex) == .collection {
                        recipe=outputRuntime.recipes[edge.source]
                    } else {
                        var source=edge.source,port=edge.outputIndex,visited=Set<UUID>()
                        while visited.insert(source).inserted,let n=effectiveNodes[source],!n.enabled,
                              let input=n.kind.bypassInput(forOutput:port),let bypass=sockets[source]?[input] {
                            source=bypass.source;port=bypass.outputIndex
                        }
                        recipe=["version":1,"kind":"surfaceGate","params":["speed":0.0,"onTime":1.0,"brightness":1.0],"colors":[["r":1.0,"g":1.0,"b":1.0]],"videoSource":"patch:\(source.uuidString):\(port)","graphCompatible":true]
                    }
                    if let recipe { layers.append(["channel":channel,"opacity":level,"recipe":recipe]) }
                }
                outputRuntime.recipes[node.id]=["version":1,"kind":"layerMux","composite":"crossfade","layers":layers,"graphCompatible":true]
                if !raster.contains(node.id) { textures[node.id]=black;renderStatus[node.id]="Collection crossfade";continue }
            }
            if node.kind == .videoCollection {
                let sources: [(String,MTLTexture)] = (0..<8).compactMap { channel in
                    guard let edge=sockets[node.id]?[channel] else { return nil }
                    // A bypassed effect still supplies video, but its own public
                    // port is disabled. Retain the upstream video port instead.
                    var source=edge.source,port=edge.outputIndex
                    var visited=Set<UUID>()
                    while visited.insert(source).inserted,let upstream=effectiveNodes[source],!upstream.enabled,
                          let input=upstream.kind.bypassInput(forOutput:port),
                          let bypass=sockets[source]?[input] {
                        source=bypass.source;port=bypass.outputIndex
                    }
                    return ("patch:\(source.uuidString):\(port)",textures[edge.source] ?? black)
                }
                textures[node.id]=outputRuntime.videoCollection(node,sources:sources,black:black,command:command,preview:raster.contains(node.id)) ?? black
                renderStatus[node.id]=sources.isEmpty ? "Connect Video" : "\(sources.count) videos · Repeat across faces"
                continue
            }
            if node.kind == .layerMux {
                // Video inputs retain the additive/mask semantics of Video Mux.
                // Collection inputs remain recipes and never enter this video texture.
                var videoLevels=Array(repeating:Float(0),count:8),modes=Array(repeating:UInt32(0),count:8)
                var layers=[[String:Any]](),previewSources=[MTLTexture](),previewLevels=[Float]()
                for channel in 0..<node.channelCount {
                    guard let edge=sockets[node.id]?[channel],let upstream=effectiveNodes[edge.source] else { continue }
                    let level=node.value("level\(channel+1)")
                    if upstream.kind.outputType(at:edge.outputIndex) == .video {
                        videoLevels[channel]=Float(level)
                        modes[channel]=node.value("mode\(channel+1)")>=0.5 ? (upstream.enabled ? 1:2):0
                    } else if upstream.enabled,level>0,let recipe=outputRuntime.recipes[edge.source] {
                        layers.append(["channel":channel,"opacity":level,"recipe":recipe])
                        previewSources.append(layerPreviewFrames[edge.source] ?? textures[edge.source] ?? black);previewLevels.append(Float(level))
                    }
                }
                let hasVideo=videoLevels.indices.contains { videoLevels[$0]>0 && modes[$0]==0 }
                if hasVideo || raster.contains(node.id) {
                    if targets[node.id]?.width != graph.width || targets[node.id]?.height != graph.height {
                        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:graph.width,height:graph.height,mipmapped:false);desc.usage=[.shaderRead,.shaderWrite];desc.storageMode = .private;targets[node.id]=device.makeTexture(descriptor:desc)
                    }
                    if let target=targets[node.id],let encoder=command.makeComputeCommandEncoder() {
                        encoder.setComputePipelineState(muxPipeline)
                        for i in 0..<8 { encoder.setTexture(videoLevels[i]>0 ? (incoming[i].flatMap { textures[$0] } ?? black):black,index:i) }
                        encoder.setTexture(target,index:8)
                        videoLevels.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
                        modes.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
                        encoder.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));encoder.endEncoding();textures[node.id]=target
                    }
                } else { textures[node.id]=black }
                if hasVideo {
                    let recipe: [String:Any]=["version":1,"kind":"surfaceGate","params":["speed":0.0,"onTime":1.0,"brightness":1.0],"colors":[["r":1.0,"g":1.0,"b":1.0]],"videoSource":"patch:\(node.id.uuidString):1","graphCompatible":true]
                    layers.insert(["channel":-1,"opacity":1.0,"recipe":recipe],at:0)
                    previewSources.insert(textures[node.id] ?? black,at:0);previewLevels.insert(1,at:0)
                }
                outputRuntime.recipes[node.id]=["version":1,"kind":"layerMux","layers":layers,"graphCompatible":true]
                if previewLayers.contains(node.id) {
                    if layerPreviews[node.id] == nil {
                        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:360,mipmapped:false);desc.usage=[.shaderRead,.shaderWrite];desc.storageMode = .private;layerPreviews[node.id]=device.makeTexture(descriptor:desc)
                    }
                    if let target=layerPreviews[node.id],let encoder=command.makeComputeCommandEncoder() {
                        encoder.setComputePipelineState(layerMuxPipeline)
                        while previewLevels.count<8 { previewLevels.append(0) }
                        for i in 0..<8 { encoder.setTexture(i<previewSources.count ? previewSources[i]:black,index:i) }
                        encoder.setTexture(target,index:8);previewLevels.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
                        encoder.dispatchThreads(.init(width:640,height:360,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));encoder.endEncoding();layerPreviewFrames[node.id]=target
                    }
                }
                renderStatus[node.id]="\(layers.count) active layers · Video + Collection";continue
            }
            if node.kind == .glowFaces || node.kind == .graphInkFlow || node.kind == .graphParticles || node.kind == .graphPulse || node.kind == .graphCloudParticles || node.kind == .graphClouds || node.kind == .flashFaces || node.kind == .surfaceGate {
                let palette = incoming[0].map { paletteValues[$0] ?? .empty } ?? CollectionStyle.palette(node)
                textures[node.id] = outputRuntime.collection(node,palette:palette,video:a,source:node.kind == .surfaceGate ? incoming[0] : nil,command:command,time:renderTime,preview:raster.contains(node.id)) ?? black
                renderStatus[node.id] = "Collection · \(Int(node.value("previewFaces"))) preview surfaces"
                continue
            }
            if node.kind.isMappedSurface {
                outputRuntime.recipes[node.id]=["version":1,"kind":node.kind.rawValue,"params":node.mappedRecipeParameters]
                do {
                    if raster.contains(node.id){textures[node.id]=try outputRuntime.surfacePreview.render(node,time:renderTime,command:command)}
                    renderStatus[node.id]="Mapped collection"
                } catch {renderStatus[node.id]=error.localizedDescription}
                continue
            }
            if node.kind.isMappedTrace {
                let (texture,recipe)=outputRuntime.traceRuntime.mapped(node,time:renderTime,command:command,preview:raster.contains(node.id))
                outputRuntime.recipes[node.id]=recipe;textures[node.id]=texture ?? black
                renderStatus[node.id]="Trace";continue
            }
            if node.kind == .lightningPulses {
                let palette=incoming[0].map { paletteValues[$0] ?? .empty }
                let phase=sockets[node.id]?[1].flatMap { controlValue($0.source,$0.outputIndex) }
                let (texture,recipe)=outputRuntime.traceRuntime.render(node,palette:palette,phase:phase,time:renderTime,command:command,preview:raster.contains(node.id))
                outputRuntime.recipes[node.id]=recipe;textures[node.id]=texture ?? black
                renderStatus[node.id]=phase == nil ? "Trace · Free running" : "Trace · Phase input"
                continue
            }
            if node.kind == .palette || node.kind == .videoPalette || node.kind == .paletteAdjust || node.kind == .publishPalette {
                let palette: ColorPalette
                if node.kind == .palette {
                    palette=PaletteGenerator.colors(node)
                } else if node.kind == .paletteAdjust {
                    palette=PaletteAdjustmentStyle.apply(incoming[0].flatMap { paletteValues[$0] } ?? .empty,node:node)
                } else if node.kind == .publishPalette {
                    palette=incoming[0].flatMap { paletteValues[$0] } ?? .empty
                } else if incoming[0] != nil {
                    palette=paletteRenderer.extract(node,source:a,command:command,renderQueue:renderQueue)
                } else { paletteRenderer.invalidate(node.id); palette = .empty }
                paletteValues[node.id]=palette
                if raster.contains(node.id) { textures[node.id]=paletteRenderer.preview(palette,id:node.id,command:command) ?? black }
                renderStatus[node.id]=node.kind == .publishPalette ? (palette.colors.isEmpty ? "Connect Palette" : "Publishing · \(palette.colors.count) colors") : node.kind == .videoPalette && incoming[0] == nil ? "Connect Video / Collection" : node.kind == .paletteAdjust && incoming[0] == nil ? "Connect Palette" : palette.colors.isEmpty ? "Waiting for colors" : "\(palette.colors.count) colors · PALETTE"
                continue
            }
            if node.kind == .meshGradient {
                let supplied=incoming[0].flatMap { paletteValues[$0] }
                paletteValues[node.id]=supplied.flatMap { $0.colors.isEmpty ? nil : $0 } ?? PaletteStyle.meshPalette(node)
                if !raster.contains(node.id) { renderStatus[node.id]="Palette only"; continue }
            }
            if node.kind == .apc40 {
                renderStatus[node.id] = node.enabled ? "APC40 · Controller owned by graph" : "Paused · Controller still reserved"
                continue
            }
            if node.kind.outputType == .control {
                let value = controlValues[node.id] ?? 0
                renderStatus[node.id]=String(format:"%.3f · CONTROL",value)
                guard raster.contains(node.id) else { continue }
                if targets[node.id]?.width != 640 || targets[node.id]?.height != 240 {
                    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:240,mipmapped:false)
                    desc.usage = [.shaderRead,.shaderWrite]; desc.storageMode = .private; targets[node.id] = device.makeTexture(descriptor:desc)
                }
                if let target = targets[node.id], let encoder = command.makeComputeCommandEncoder() {
                    let samples: [Float]
                    if node.kind == .audioEnvelope {
                        let history = audioSnapshot.4[node.id] ?? [Float](repeating:0,count:512)
                        samples = history.map { $0 * 2 - 1 }
                    } else {
                        samples = (0..<512).map { Float(ControlSignal.value(node,time:renderTime-5+Double($0)/511*5)*2-1) }
                    }
                    var params = Uniforms(); params.mode.x = 5; params.a = .init(1,0.77,2,0)
                    encoder.setComputePipelineState(pipeline); encoder.setTexture(black,index:0); encoder.setTexture(black,index:1); encoder.setTexture(target,index:2)
                    encoder.setBytes(&params,length:MemoryLayout<Uniforms>.stride,index:0)
                    samples.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
                    encoder.dispatchThreads(.init(width:640,height:240,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); encoder.endEncoding()
                    textures[node.id] = target
                }
                renderStatus[node.id] = node.kind == .audioEnvelope ? (audioSnapshot.1[node.id] ?? "No input") : String(format:"%.3f · CONTROL",value)
                continue
            }
            if node.kind == .posterComposer {
                let dimensions=PosterStyle.dimensions(node)
                if targets[node.id]?.width != dimensions.width || targets[node.id]?.height != dimensions.height {
                    let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:dimensions.width,height:dimensions.height,mipmapped:false)
                    desc.usage=[.shaderRead,.shaderWrite];desc.storageMode = .private;targets[node.id]=device.makeTexture(descriptor:desc)
                }
                if posterPipeline == nil { posterPipeline=try? PosterComposerPipeline(device:device) }
                if posterScratch[node.id]?.width != dimensions.width || posterScratch[node.id]?.height != dimensions.height,let target=targets[node.id] {
                    let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:target.width,height:target.height,mipmapped:false)
                    desc.usage=[.shaderRead,.shaderWrite];desc.storageMode = .private;posterScratch[node.id]=device.makeTexture(descriptor:desc)
                }
                // Type is set on the CPU only when the text, layout or type settings change.
                let key=PosterTypeKey(text:node.text,parameters:node.parameters.filter { PosterStyle.typeKeys.contains($0.key) },poster:node.poster)
                if posterTexts[node.id]?.rendered != key && posterTexts[node.id]?.busy != true {
                    posterTexts[node.id,default:PosterType()].busy=true
                    let device=self.device,snapshot=node
                    DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                        let passes=try? PosterTextRenderer.renderPasses(snapshot,dimensions:dimensions,device:device)
                        self?.renderQueue.async {
                            guard let self,self.posterTexts[snapshot.id] != nil else { return }
                            self.posterTexts[snapshot.id]?.busy=false; self.posterTexts[snapshot.id]?.rendered=key
                            if let passes { self.posterTexts[snapshot.id]?.passes=passes }
                        }
                    }
                }
                var passes=posterTexts[node.id]?.passes ?? []
                // Connected inputs the layout doesn't place yet draw on top.
                let placed=Set(passes.compactMap { pass -> Int? in if case .video(let element)=pass { return element.input }; return nil })
                for input in PosterStyle.videoInputs where !placed.contains(input) {
                    if let source=incoming[PosterStyle.edgeInput(video:input)] { passes.append(.video(PosterStyle.defaultVideo(input:input,source:graph.videoDimensions(source),poster:dimensions))) }
                }
                if var front=targets[node.id],var back=posterScratch[node.id],let posterPipeline,let encoder=command.makeComputeCommandEncoder() {
                    let grid=MTLSize(width:dimensions.width,height:dimensions.height,depth:1),group=MTLSize(width:16,height:16,depth:1)
                    let posterAspect=Float(dimensions.width)/Float(dimensions.height)
                    var fill=PosterComposerPipeline.fillColor(node)
                    encoder.setComputePipelineState(posterPipeline.fill); encoder.setTexture(front,index:0)
                    encoder.setBytes(&fill,length:MemoryLayout<SIMD4<Float>>.stride,index:0); encoder.dispatchThreads(grid,threadsPerThreadgroup:group)
                    var drawn: [String]=[]
                    encoder.setComputePipelineState(posterPipeline.layer)
                    for pass in passes {
                        var layer: MTLTexture, controls: [SIMD4<Float>]
                        switch pass {
                        case .type(let texture,let blend):
                            layer=texture; controls=PosterComposerPipeline.frame(blend,opacity:node.value("textOpacity")); drawn.append("type")
                        case .image(let element):
                            guard let file=element.file,let texture=posterImage(file) else { continue }
                            layer=texture; drawn.append("image")
                            controls=PosterComposerPipeline.box(element.blend,opacity:element.opacity,invert:element.invert,center:SIMD2(Float(element.x),Float(element.y)),size:SIMD2(Float(element.width),Float(element.height)),degrees:element.rotation,layerAspect:Float(texture.width)/Float(texture.height),posterAspect:posterAspect,cover:true)
                        case .video(let element):
                            guard let input=element.input,let texture=incoming[PosterStyle.edgeInput(video:input)].flatMap({ textures[$0] }) else { continue }
                            layer=texture; drawn.append("video")
                            controls=PosterComposerPipeline.box(element.blend,opacity:element.opacity,invert:element.invert,center:SIMD2(Float(element.x),Float(element.y)),size:SIMD2(Float(element.width),Float(element.height)),degrees:element.rotation,layerAspect:Float(texture.width)/Float(texture.height),posterAspect:posterAspect,cover:true)
                        }
                        encoder.setTexture(front,index:0); encoder.setTexture(layer,index:1); encoder.setTexture(back,index:2)
                        encoder.setBytes(&controls,length:MemoryLayout<SIMD4<Float>>.stride*controls.count,index:0)
                        encoder.dispatchThreads(grid,threadsPerThreadgroup:group)
                        swap(&front,&back)
                    }
                    encoder.endEncoding()
                    // The finished frame may be in either buffer; whichever it is becomes the output.
                    targets[node.id]=front; posterScratch[node.id]=back
                    textures[node.id]=front
                    renderStatus[node.id]="Poster \(dimensions.width)×\(dimensions.height) · "+(drawn.isEmpty ? "fill only" : "\(drawn.count) layers")
                } else { textures[node.id]=black; renderStatus[node.id]="Compiling poster…" }
                continue
            }
            if node.kind == .projector {
                let dimensions=VideoDimensions(graph.width,graph.height)
                if targets[node.id]?.width != dimensions.width || targets[node.id]?.height != dimensions.height {
                    let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:dimensions.width,height:dimensions.height,mipmapped:false)
                    desc.usage=[.shaderRead,.shaderWrite];desc.storageMode = .private;targets[node.id]=device.makeTexture(descriptor:desc)
                }
                if let target=targets[node.id] {
                    let valid=projectorRenderer.encode(a,target:target,node:node,command:command)
                    textures[node.id]=target
                    renderStatus[node.id]=incoming[0] == nil ? "Connect video" : valid ? "Projector · four-corner mapping" : "Invalid mapping — use a convex quadrilateral"
                }
                continue
            }
            if node.kind == .recordAudio {
                renderStatus[node.id] = incoming[0] == nil ? "Connect audio" : recordings[node.id]?.info.label ?? "Ready to record · \(AudioRecording.Options(node).summary(rate:nil))"
                continue
            }
            if node.kind.isOutput {
                textures[node.id] = a
                guard incoming[0] != nil else { renderStatus[node.id] = "No input"; continue }
                if outputNames[node.id] != node.streamName { syphon[node.id] = nil; ndi[node.id] = nil; outputNames[node.id] = node.streamName }
                if node.kind == .syphon {
                    var extractor=Node(kind:.videoPalette,id:node.id)
                    extractor.parameters["count"]=6; extractor.parameters["rate"]=5; extractor.parameters["smoothing"]=0.3
                    paletteValues[node.id]=paletteRenderer.extract(extractor,source:a,command:command,renderQueue:renderQueue)
                    if syphon[node.id] == nil { syphon[node.id] = PatchSyphon(name: node.streamName, device: device) }
                    syphon[node.id]?.publish(a, commandBuffer: command)
                    renderStatus[node.id] = syphon[node.id] == nil ? "Syphon runtime unavailable" : "Publishing"
                } else if node.kind == .ndi {
                    if ndi[node.id] == nil { ndi[node.id] = NDIPublisher(node.streamName) }
                    ndi[node.id]?.encode(a, device: device, command: command, fps: graph.fps)
                    renderStatus[node.id] = ndi[node.id] == nil ? "NDI runtime unavailable" : "Publishing"
                } else if node.kind == .record {
                    (recordings[node.id] as? MovieRecorder)?.encode(a,command:command)
                    renderStatus[node.id] = recordings[node.id]?.info.label ?? "Ready to record"
                } else { renderStatus[node.id] = "Ready" }
                continue
            }
            if (node.kind == .vectorShape || node.kind == .vectorText || node.kind == .fluidShape) && !raster.contains(node.id) { renderStatus[node.id]="Closed XY path";continue }
            let dimensions = streamSizes[node.id] ?? VideoDimensions(graph.width,graph.height)
            let format: MTLPixelFormat = node.kind == .fieldMix ? .rgba16Float : .bgra8Unorm
            if targets[node.id]?.width != dimensions.width || targets[node.id]?.height != dimensions.height || targets[node.id]?.pixelFormat != format {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format, width: dimensions.width, height: dimensions.height, mipmapped: false)
                desc.usage = [.shaderRead, .shaderWrite, .renderTarget]; desc.storageMode = .private
                targets[node.id] = device.makeTexture(descriptor: desc)
            }
            guard let target = targets[node.id] else { continue }
            if node.kind.vectorArtModule != nil {
                do {
                    let path = try vectorArtRenderer.render(node,target:target,command:command,time:renderTime,wantRaster:raster.contains(node.id),wantPath:vectorArtPathDemand.contains(node.id))
                    audioGraph.setVectorArtPath(path,id:node.id)
                    if raster.contains(node.id) { textures[node.id] = target }
                    renderStatus[node.id] = "Vector strokes"
                } catch {
                    audioGraph.setVectorArtPath(nil,id:node.id)
                    renderStatus[node.id] = error.localizedDescription
                }
                continue
            }
            var staticSource: MTLTexture?
            var upstreamVersion: UInt64 = 0
            if node.kind == .image { staticSource=source(node)?.texture }
            if node.kind == .crop,let source=incoming[0],let version=staticVersions[source] {
                staticSource=a;upstreamVersion=version
            }
            if let source=staticSource,let cached=staticFrames[node.id],
               cached.parameters==node.parameters,cached.source === source,cached.target === target,
               cached.upstreamVersion==upstreamVersion {
                textures[node.id]=target;staticVersions[node.id]=cached.version
                staticCacheHits += 1;renderStatus[node.id]="Ready · Cached";continue
            }
            staticFrames[node.id]=nil
            if node.kind == .yoloPose {
                guard incoming[0] != nil, a !== black else {
                    textures[node.id] = black; renderStatus[node.id] = "No input"; continue
                }
                let path = node.file ?? PoseDetectionResource.defaultModelURL.path
                if poseDetectors[node.id]?.path != path { poseDetectors[node.id] = PoseDetectionResource(path:path) }
                let detector = poseDetectors[node.id]!
                detector.encode(source:a,device:device,command:command,pipeline:poseRenderer.downsample,node:node,now:now)
                let (frame,message) = detector.snapshot(now:now)
                poseFrames[node.id] = frame; renderStatus[node.id] = message
                poseRenderer.encode(target:target,frame:frame,node:nil,command:command)
                textures[node.id] = target
                continue
            }
            if node.kind == .chromaDecoder {
                let reference=sockets[node.id]?[1].flatMap { frameReferences[$0.outlet] }
                renderStatus[node.id]=chromaRenderer.encode(node,reference:reference,fallback:black,returned:audioGraph.chroma.output(node.id),target:target,now:now,command:command)
                textures[node.id]=target
                continue
            }
            if [.profileEncoder,.profileAnalog,.profileDecoder].contains(node.kind) {
                var frame: ProfileVideoFrame?
                if node.kind == .profileEncoder {
                    frame=incoming[0] == nil ? nil:profileVideoRenderer.capture(a,command:command)
                } else {
                    frame=incoming[0].flatMap { profileFrames[$0] }
                    if node.kind == .profileAnalog,let current=frame { frame=profileVideoRenderer.manipulate(current,node:node,time:renderTime,command:command) }
                }
                if let frame {
                    profileFrames[node.id]=frame
                    profileVideoRenderer.render(frame,target:target,view:node.kind == .profileDecoder ? node.value("view"):4,mix:node.kind == .profileDecoder ? node.value("mix"):1,command:command)
                    renderStatus[node.id]="Six RGB profiles · \(frame.source.width) X + \(frame.source.height) Y · residual retained"
                    textures[node.id]=target
                } else { textures[node.id]=black;renderStatus[node.id]="Connect \(node.kind == .profileEncoder ? "Video":"RGB Profiles")" }
                continue
            }
            if node.kind == .rasterSynth {
                let history=audioGraph.oscilloscopeSamples(node.id,seconds:node.value("windowMS")/1000*2+0.002)
                rasterSynthRenderer.encode(history.points,rate:history.rate,node:node,time:renderTime,target:target,command:command)
                renderStatus[node.id]=history.points.isEmpty ? "Connect stereo audio" : String(format:"%d × %d · %.0f kHz · two waveform raster",target.width,target.height,history.rate/1000)
                textures[node.id]=target
                continue
            }
            if node.kind == .oscilloscope {
                let seconds=node.value("timeMS")/1000
                let history=audioGraph.oscilloscopeSamples(node.id,seconds:seconds*2+0.001)
                let triggered=oscilloscopeRenderer.encode(history.points,sampleRate:history.rate,node:node,target:target,command:command)
                renderStatus[node.id]=incoming[0] == nil ? "Connect stereo audio" : history.points.isEmpty ? "Waiting for audio" : String(format:"%.2f ms · %.0f kHz · %@",node.value("timeMS"),history.rate/1000,node.value("trigger")<0.5 ? "free running":triggered ? "triggered":"waiting for trigger · free running")
                textures[node.id]=target
                continue
            }
            if node.kind == .voltageFluid {
                // Deposit exactly the beam samples drawn since the previous frame.
                let history=audioGraph.oscilloscopeSamples(node.id,seconds:playing ? min(0.1,max(0.001,dt)):0)
                let connected=incoming[0] != nil || incoming[2] != nil || incoming[3] != nil
                voltageFluidRenderer.encode(history.points,sampleRate:history.rate,dt:playing ? min(1/30,dt):0,node:node,reflection:incoming[4] == nil ? nil:inputTexture(4),target:target,command:command)
                renderStatus[node.id]=connected ? String(format:"%d beam samples/frame · %.0f kHz · %d-cell grid",history.points.count,history.rate/1000,VoltageFluidStyle.gridSide(node)) : "Connect XY audio or separate X / Y"
                textures[node.id]=target
                continue
            }
            if node.kind == .vectorShape || node.kind == .vectorText || node.kind == .fluidShape || node.kind == .voltageVisualizer {
                let points: [SIMD2<Float>]
                if node.kind == .vectorShape || node.kind == .vectorText || node.kind == .fluidShape {
                    points=voltageRenderer.shape(node,time:renderTime)
                    renderStatus[node.id]=node.kind == .vectorText ? "Text outlines · fast inter-contour travel":node.kind == .fluidShape ? "Liquid body · spiral fill encodes mass":"Closed XY path · normalized coordinates"
                } else {
                    let rate=incoming[1].flatMap { drawRates[$0] } ?? node.value("rate")
                    let seconds=AnalogVectorStyle.trailSeconds(node,rate:rate)
                    let history=audioGraph.oscilloscopeSamples(node.id,seconds:seconds)
                    points=history.points
                    renderStatus[node.id]=incoming[0] == nil && incoming[2] == nil && incoming[3] == nil ? "Connect XY audio or separate X / Y" : String(format:"%.2f ms trail · %d XY samples · %.0f kHz · %.2f Hz%@",seconds*1000,points.count,history.rate/1000,rate,incoming[1] == nil ? "":" · linked") + (incoming[2] == nil && incoming[3] == nil ? "":" · separate X / Y")
                }
                voltageRenderer.encode(points,node:node,target:target,command:command)
                textures[node.id]=target
                continue
            }
            if node.kind == .poseRender {
                let frame = incoming[0].flatMap { poseFrames[$0] }
                poseRenderer.encode(target:target,frame:frame,node:node,time:renderTime,command:command)
                textures[node.id] = target
                renderStatus[node.id] = incoming[0] == nil ? "Connect poses" : frame.map { "\($0.poses.count) people" } ?? "Waiting for poses"
                continue
            }
            if node.kind == .faceDetect {
                guard incoming[0] != nil, a !== black else {
                    textures[node.id] = black; renderStatus[node.id] = "No input"; continue
                }
                let detector = faceDetectors[node.id] ?? FaceDetectionResource()
                faceDetectors[node.id] = detector
                detector.encode(source:a,device:device,command:command,pipeline:faceBoxRenderer.downsample,rate:node.value("rate"),now:now)
                let (frame,message) = detector.snapshot(now:now,captureScale:node.value("captureScale"))
                faceFrames[node.id] = frame; renderStatus[node.id] = message
                faceBoxRenderer.encode(source:a,target:target,frame:frame,thickness:2,command:command)
                textures[node.id] = target
                continue
            }
            if node.kind == .faceReplace {
                let message = faceReplacementRenderer.encode(a:a,b:b,target:target,
                    facesA:incoming.count == 4 ? incoming[2].flatMap { faceFrames[$0] } : nil,facesB:incoming.count == 4 ? incoming[3].flatMap { faceFrames[$0] } : nil,node:node,command:command)
                textures[node.id] = target
                renderStatus[node.id] = incoming.count < 4 ? "Missing input · connect Video A/B and Faces A/B" : message
                continue
            }
            if node.kind == .faceBoxes {
                let frame = incoming[1].flatMap { faceFrames[$0] }
                faceBoxRenderer.encode(source:a,target:target,frame:frame,thickness:node.value("thickness"),command:command)
                textures[node.id] = target
                renderStatus[node.id] = incoming.count < 2 ? "Missing input" : (frame == nil ? "Waiting for faces" : "\(frame!.faces.count) faces")
                continue
            }
            if node.kind == .lorenz || node.kind == .render {
                let resource = node.kind == .lorenz ? geometry(node) : incoming[0].flatMap { graph.node($0)?.enabled == true ? geometries[$0] : nil }
                rasterize(resource,target:target,command:command,node:node.kind == .render ? node : nil)
                textures[node.id] = target
                renderStatus[node.id] = resource?.error ?? (resource?.buffer == nil ? "Waiting for geometry" : "\(resource!.count) vertices")
                continue
            }
            if node.kind == .powerGlitch {
                if let e=command.makeComputeCommandEncoder() {
                    let data=PowerGlitchStyle.frame(node,time:renderTime)
                    e.setComputePipelineState(powerGlitchPipeline);e.setTexture(target,index:0)
                    data.withUnsafeBytes { e.setBytes($0.baseAddress!,length:$0.count,index:0) }
                    e.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));e.endEncoding()
                }
                textures[node.id]=target;renderStatus[node.id]="Burst dropout mask";continue
            }
            if node.kind == .mux {
                if let encoder = command.makeComputeCommandEncoder() {
                    encoder.setComputePipelineState(muxPipeline)
                    let levels = (1...8).map { $0 <= node.channelCount ? Float(node.value("level\($0)")) : 0 }
                    for i in 0..<8 { encoder.setTexture(incoming[i].flatMap { textures[$0] } ?? black,index:i) }
                    encoder.setTexture(target,index:8)
                    levels.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
                    let modes=(0..<8).map { i -> UInt32 in
                        guard node.value("mode\(i+1)")>=0.5 else { return 0 }
                        return incoming[i].flatMap { effectiveNodes[$0] }?.enabled == true ? 1:2
                    }
                    modes.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
                    encoder.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1))
                    encoder.endEncoding(); textures[node.id] = target
                }
                renderStatus[node.id] = "\(incoming.count) / \(node.channelCount) inputs"
                continue
            }
            if node.kind == .dither {
                let rendered = dither.encode(command,node:node,source:a,target:target)
                textures[node.id] = rendered ? target : a
                renderStatus[node.id] = !rendered ? "Cannot allocate dither buffers" : (incoming.isEmpty ? "Missing input" : "Ready")
                continue
            }
            if node.kind == .diffusion {
                glow.encode(command,node:node,source:a,target:target)
                textures[node.id] = target; renderStatus[node.id] = incoming.isEmpty ? "Missing input" : "Ready"
                continue
            }
            if node.kind == .projectionDots || node.kind.outputType == .dots {
                let pair = ShaderCompiler.dotNodes(node,graph:graph)
                let geometry = node.kind == .projectionDots ? node : pair.geometry
                let pattern = pair.pattern.map { effectiveNodes[$0.id] ?? $0 }
                let resource = dotShader(node,geometry:geometry,pattern:pattern)
                if let pipeline = resource.pipeline, let enc = command.makeComputeCommandEncoder() {
                    var time = Float(renderTime)
                    let values = ProjectionDotsStyle.shaderValues(geometry)
                    var controls = pattern.map { n in n.kind.parameters.map { Float(n.value($0.key)) } } ?? []
                    controls += [Float](repeating:0,count:max(0,16-controls.count))
                    let messages = pattern.map(FlipDotsStyle.textBuffer) ?? [UInt32](repeating:0,count:393)
                    enc.setComputePipelineState(pipeline); enc.setTexture(target,index:0)
                    enc.setBytes(&time,length:4,index:0)
                    values.withUnsafeBytes { enc.setBytes($0.baseAddress!,length:$0.count,index:1) }
                    controls.withUnsafeBytes { enc.setBytes($0.baseAddress!,length:$0.count,index:2) }
                    messages.withUnsafeBytes { enc.setBytes($0.baseAddress!,length:$0.count,index:3) }
                    enc.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); enc.endEncoding()
                    textures[node.id] = target
                } else { textures[node.id] = black }
                renderStatus[node.id] = resource.error ?? (resource.pipeline == nil ? "Compiling" : "Ready")
                continue
            }
            if node.kind == .meshGradient || node.kind == .shader || node.kind == .scene || node.kind == .shaderEffect {
                let resource = shader(node)
                if let pipeline = resource?.pipeline, let enc = command.makeComputeCommandEncoder() {
                    var time = Float(self.renderTime * ([.scene,.projectionDots].contains(node.kind) ? 1 : node.value("speed")))
                    var controls = node.kind == .shaderEffect ? [SIMD4<Float>(Float(node.value("p1")),Float(node.value("p2")),Float(node.value("p3")),Float(node.value("p4"))), SIMD4<Float>(Float(node.value("mix")),0,0,0)] : [SIMD4<Float>(Float(node.value("speed")),Float(node.value("orbit")),Float(node.value("zoom")),Float(node.value("spread"))),SIMD4<Float>(Float(node.value("shadows")),0,0,0)]
                    if node.kind == .shaderEffect,let specs = node.fieldParameters {
                        // Keep the supplied shader's declaration order, four scalar lanes per vector.
                        controls = Array(repeating:.zero,count:4)
                        for (i,spec) in specs.enumerated() { controls[i/4][i%4] = Float(node.value(spec.key)) }
                        let rate = specs.first(where:{ $0.scalesFieldTime == true }).map { node.value($0.key) } ?? 1
                        time = Float(self.renderTime * rate)
                        controls[3].w = time
                    } else if node.kind == .shaderEffect {
                        if node.hasBlindsControls && node.value("animation") > 0 { controls[1].x = 1 }
                        controls += [
                            SIMD4<Float>(Float(node.value("animation")),Float(node.value("variation")),Float(node.value("pulseWidth")),Float(node.value("trail"))),
                            SIMD4<Float>(Float(node.value("direction")),Float(node.value("colorMotion")),Float(node.value("colorRate")),Float(node.value("background"))),
                            SIMD4<Float>(Float(node.value("brightness")),Float(node.value("seed")),0,0)
                        ]
                        func barRGB(_ key: String) -> SIMD3<Float> {
                            let packed = Int(node.value(key).rounded())
                            return SIMD3<Float>(Float((packed >> 16) & 255),Float((packed >> 8) & 255),Float(packed & 255))/255
                        }
                        let start = barRGB("gradientStart"), end = barRGB("gradientEnd")
                        controls += [
                            SIMD4<Float>(Float(node.value("colorMode")),start.x,start.y,start.z),
                            SIMD4<Float>(end.x,end.y,end.z,Float(node.value("gradientCurve"))),
                            SIMD4<Float>(Float(node.value("spectralType")),Float(node.value("spectralTop")),Float(node.value("spectralBottom")),Float(node.value("spectralDistribution"))),
                            SIMD4<Float>(Float(node.value("spectralSpread")),Float(node.value("spectralShift")),0,0)
                        ]
                    }
                    if node.kind == .meshGradient {
                        if meshDetails[node.id]?.0 != node.text || meshDetails[node.id] == nil { meshDetails[node.id]=(node.text,MeshGradientStyle.Detail(text:node.text)) }
                        controls = MeshGradientStyle.shaderValues(node,palette:incoming[0].flatMap { paletteValues[$0] },time:Double(time),detail:meshDetails[node.id]?.1)
                    }
                    if node.hasMetallicPoolControls { controls[1].y = Float(node.value("function")); controls[1].z = Float(node.value("blend")); controls[1].w = Float((node.value("tintHue")*65535).rounded()*256+(node.value("tintStrength")*255).rounded()) }
                    if node.hasLiquidMetalControls { controls = LiquidMetalStyle.shaderValues(node, aspect:Float(target.width)/Float(target.height), hasInput:incoming[0] != nil) }
                    if node.hasLiquidChromeControls { controls = LiquidChromeStyle.shaderValues(node, aspect:Float(target.width)/Float(target.height), hasInput:incoming[0] != nil) }
                    var ferrofluidField: MTLTexture?
                    if node.hasFerrofluidControls {
                        let (frame,texture)=ferrofluidFrame(node)
                        ferrofluidField=texture
                        controls = FerrofluidStyle.shaderValues(node, aspect:Float(target.width)/Float(target.height), hasInput:incoming[0] != nil, frame:frame)
                    }
                    controls.withUnsafeBytes { bytes in
                        if bytes.count <= 4096 { enc.setBytes(bytes.baseAddress!,length:bytes.count,index:1) }
                        else {
                            // Each in-flight frame owns its upload until the command buffer completes.
                            let buffer=device.makeBuffer(bytes:bytes.baseAddress!,length:bytes.count,options:.storageModeShared)
                            enc.setBuffer(buffer,offset:0,index:1)
                        }
                    }
                    enc.setComputePipelineState(pipeline); enc.setTexture(target,index:0)
                    if node.kind == .shaderEffect { enc.setTexture(a,index:1); enc.setTexture((node.hasLiquidChromeControls ? membraneTexture(node,aspect:Double(target.width)/Double(target.height)) : ferrofluidField) ?? black,index:2) }
                    enc.setBytes(&time,length:4,index:0)
                    enc.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); enc.endEncoding()
                    textures[node.id] = target
                } else { textures[node.id] = node.kind == .shaderEffect ? a : black }
                renderStatus[node.id] = resource?.error ?? (resource?.pipeline == nil ? "Choose a Metal shader / compiling" : node.kind == .meshGradient && incoming[0] != nil && (paletteValues[incoming[0]!] == nil || paletteValues[incoming[0]!]!.colors.isEmpty) ? "Palette unavailable · local colors" : "Ready")
                if node.hasFerrofluidControls, resource?.error == nil, resource?.pipeline != nil { renderStatus[node.id] = "Ready · \(ferrofluids[node.id]?.sim.spikeCount ?? 0) spikes" }
                continue
            }
            var secondaryFieldTexture: MTLTexture?
            guard let encoder = command.makeComputeCommandEncoder() else { continue }
            var uniforms = Uniforms(); uniforms.c.x = Float(renderTime)
            var nodePipeline = pipeline
            var first = a
            // A bound zero sample also makes non-audio pipeline invocations valid.
            var audioSamples = [Float](repeating:0,count:512)
            switch node.kind {
            case .text:
                uniforms.mode.x = 1; first = black
                if textSources[node.id]?.node.text != node.text || textSources[node.id]?.node.parameters != node.parameters || textSources[node.id]?.width != graph.width || textSources[node.id]?.height != graph.height {
                    let resource = TextSource(node,graph.width,graph.height); textSources[node.id] = resource
                    DispatchQueue.global(qos:.userInitiated).async { [weak resource] in
                        do { let texture = try ImageUpload.text(node,width:graph.width,height:graph.height,device:self.device); self.renderQueue.async { resource?.texture = texture } }
                        catch { self.renderQueue.async { resource?.error = error.localizedDescription } }
                    }
                }
                if let resource = textSources[node.id] { first = resource.texture ?? black; renderStatus[node.id] = resource.error ?? (resource.texture == nil ? "Rendering text…" : "Ready") }
            case .liveStream:
                uniforms.mode.x = 7;first=black
                uniforms.a = .init(Float(node.value("rotation") * .pi / 180),Float(node.value("scale")),Float(node.value("x")),Float(node.value("y")))
                uniforms.b = .init(node.value("flipX") > 0 ? -1 : 1,node.value("flipY") > 0 ? -1 : 1,0,0)
                let address=(node.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                if liveStreams[node.id]?.address != address { liveStreams[node.id]=LiveStreamSource(address:address,queue:renderQueue);liveStreamFrames.removeValue(forKey:node.id) }
                if let resource=liveStreams[node.id] {
                    if let pixel=resource.frame(playing:playing,bufferDuration:node.value("buffer")) {
                        var cv: CVMetalTexture?
                        CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixel,nil,.bgra8Unorm,CVPixelBufferGetWidth(pixel),CVPixelBufferGetHeight(pixel),0,&cv)
                        if let cv { liveStreamFrames[node.id]=cv }
                    }
                    if let cv=liveStreamFrames[node.id] { retainedCV.append(cv);first=CVMetalTextureGetTexture(cv) ?? black }
                    renderStatus[node.id]=resource.status
                }
            case .syphonIn:
                uniforms.mode.x = 1; uniforms.b.x = 0; uniforms.b.y = 1; first = black
                if let key = node.deviceID, let selection = SyphonInputSource.decode(key) {
                    let input = syphonInputs[key] ?? PatchSyphonInput(selection:selection,device:device)
                    syphonInputs[key] = input
                    first = input.currentTexture() ?? black
                    renderStatus[node.id] = input.status
                } else { renderStatus[node.id] = "Choose a Syphon source" }
            case .ndiIn:
                uniforms.mode.x = 1; uniforms.b.x = 0; first = black
                let source=(node.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                if !source.isEmpty && ndiInputs[source] == nil { ndiInputs[source] = PatchNDIReceiver(source:source) }
                if let receiver=ndiInputs[source] {
                    if let pixel=receiver.copyNewFrame() {
                        var cv: CVMetalTexture?
                        CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixel,nil,.bgra8Unorm,CVPixelBufferGetWidth(pixel),CVPixelBufferGetHeight(pixel),0,&cv)
                        if let cv { ndiInputFrames[source]=cv }
                    }
                    if let cv=ndiInputFrames[source] { retainedCV.append(cv);first=CVMetalTextureGetTexture(cv) ?? black }
                    renderStatus[node.id]=receiver.status
                } else { renderStatus[node.id]=PatchNDIReceiver.available ? "Choose an NDI source" : "NDI runtime unavailable" }
            case .webcam:
                uniforms.mode.x = 1; uniforms.b.x = Float(node.value("mirror")); first = black
                if cameras[node.id] == nil || cameras[node.id]?.deviceID != node.deviceID { cameras[node.id] = CameraSource(deviceID:node.deviceID) }
                if let (pixel,status) = cameras[node.id]?.frame {
                    renderStatus[node.id] = status
                    if let pixel {
                        var cv: CVMetalTexture?
                        CVMetalTextureCacheCreateTextureFromImage(nil,cache,pixel,nil,.bgra8Unorm,CVPixelBufferGetWidth(pixel),CVPixelBufferGetHeight(pixel),0,&cv)
                        if let cv { retainedCV.append(cv); first = CVMetalTextureGetTexture(cv) ?? black }
                    }
                }
            case .audioVisualizer:
                let resource=audioVisualizers[node.id] ?? AudioVisualizer(); audioVisualizers[node.id]=resource
                let sourceID=incoming[0],block=audioSnapshot.0[node.id]
                let window=audioSnapshot.5[node.id] ?? []
                audioSamples=resource.update(window:window,time:block?.hostTime,source:sourceID,node:node,playing:playing)
                uniforms.mode.x=15; uniforms.mode.y=UInt32(node.value("mode"))
                uniforms.a = .init(Float(node.value("thickness")),Float(node.value("fill")),Float(node.value("axes")),Float(node.value("grid")))
                uniforms.b = .init(Float(node.value("bars")),Float(node.value("ridges")),0,0)
                let view=Int(node.value("mode"))
                if view == 2 || view == 5 { first=resource.historyTexture(device) ?? black }
                renderStatus[node.id]=sourceID == nil ? "No audio input" : (sourceID.flatMap { audioSnapshot.1[$0] } == "Choose a file" ? "Choose an audio file" : (window.isEmpty ? "Waiting for audio" : "48 kHz · 2048 FFT"))
            case .waveform:
                uniforms.mode.x = 5; uniforms.a = .init(Float(node.value("gain")),Float(node.value("hue")),Float(node.value("thickness")),0)
                if incoming[0] != nil,let block = audioSnapshot.0[node.id] {
                    let mono = block.mono
                    for i in audioSamples.indices { audioSamples[i] = mono.isEmpty ? 0 : mono[min(mono.count-1,i*mono.count/512)] }
                } else { renderStatus[node.id] = "Waiting for audio" }

            case .pattern: uniforms.mode.x = 0; uniforms.a = .init(Float(node.value("style")), Float(node.value("speed")), 0, 0)
            case .image, .video:
                uniforms.mode.x = 7; first = black
                uniforms.a = .init(Float(node.value("rotation") * .pi / 180),Float(node.value("scale")),Float(node.value("x")),Float(node.value("y")))
                uniforms.b = .init(node.value("flipX") > 0 ? -1 : 1,node.value("flipY") > 0 ? -1 : 1,0,0)
                if let resource = source(node) {
                    if let player = resource.player {
                        if let current = player.currentItem, resource.outputItem !== current {
                            let output = AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferMetalCompatibilityKey as String:true])
                            current.add(output); resource.output = output; resource.outputItem = current
                        }
                        if resource.requestedSeek != node.value("seek") || resource.seekRevision != node.seekRevision, !resource.seeking {
                            resource.requestedSeek = node.value("seek"); resource.seekRevision = node.seekRevision; resource.seeking = true
                            let end = resource.end > 0 ? min(resource.duration,resource.end) : resource.duration
                            let position = max(resource.start,min(node.value("seek"),max(resource.start,end-0.001)))
                            player.seek(to:CMTime(seconds:position,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero) { [weak resource] _ in
                                self.renderQueue.async { resource?.seeking = false }
                            }
                        }
                        let desired: Float = playing && node.value("playing") > 0.5 && !resource.seeking ? Float(node.value("speed")) : 0
                        let position = player.currentTime().seconds
                        videoClocks[node.id] = .init(position:position.isFinite ? position : resource.start,hostTime:now,speed:node.value("speed"),playing:desired > 0,duration:resource.duration)
                        if player.rate != desired { player.rate = desired }
                        // Looper clones outputs with items; read the current item's output.
                        let currentOutput = resource.output
                        let timestamp = currentOutput?.itemTime(forHostTime:CACurrentMediaTime()) ?? player.currentTime()
                        if let currentOutput, currentOutput.hasNewPixelBuffer(forItemTime: timestamp), let pixel = currentOutput.copyPixelBuffer(forItemTime: timestamp, itemTimeForDisplay: nil) {
                            var cv: CVMetalTexture?
                            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixel, nil, .bgra8Unorm, CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), 0, &cv)
                            if let cv { resource.cvTexture = cv; resource.texture = CVMetalTextureGetTexture(cv) }
                        }
                        if let error = player.currentItem?.error { resource.error = error.localizedDescription }
                    }
                    if let cv = resource.cvTexture { retainedCV.append(cv) }
                    first = resource.texture ?? black
                    renderStatus[node.id] = resource.error ?? (resource.texture == nil ? resource.loading : "Ready")
                }
            case .halftone: uniforms.videoAdjustment(node)
            case .modulation:
                uniforms.mode.x = 10
                uniforms.a = .init(Float(node.value("period")),Float(node.value("depth")),Float(node.value("width")),Float(node.value("angle") * .pi/180))
                uniforms.b = .init(Float(node.value("mono")),Float(node.value("mix")),0,0)
            case .crt:
                uniforms.mode.x = 2
                uniforms.a = .init(Float(node.value("scanlines")), Float(node.value("curvature")), Float(node.value("aberration")), Float(node.value("glow")))
                uniforms.b = .init(Float(node.value("vignette")), Float(node.value("noise")),0,0)
            case .ledMatrix, .fieldRender, .fieldMix:
                uniforms.mode.x = 14
                uniforms.mode.y = UInt32(node.value("shape"))
                uniforms.mode.z = UInt32(node.value("color"))
                uniforms.mode.w = UInt32(node.value("sample"))
                let columns = node.kind == .ledMatrix ? node.value("columns").rounded() : Double(min(320,target.width))
                let rows = node.value("grid") < 0.5 ? max(1,(columns*Double(target.height)/Double(target.width)).rounded()) : node.value("rows").rounded()
                uniforms.a = .init(Float(columns),Float(rows),Float(node.value("size")),Float(node.value("glow")))
                uniforms.b = .init(Float(node.value("gain")),Float(node.value("gamma")),Float(node.value("black")),Float(node.value("idle")))
                uniforms.d = .init(Float(node.value("hue")),Float(node.value("saturation")),Float(node.value("brightness")),Float(node.value("whiteHot")))
                uniforms.e.x = Float(node.value("invert"))
                let isMatrix = node.kind == .ledMatrix
                let primarySlot = isMatrix ? 1 : 0
                let lightSlot = isMatrix ? 2 : 1
                let primary = sockets[node.id]?[primarySlot].flatMap { fields[$0.outlet] }
                let light = sockets[node.id]?[lightSlot].flatMap { fields[$0.outlet] }
                if !isMatrix { uniforms.mode.x = node.kind == .fieldMix ? 18 : 17; uniforms.a.z = Float(node.value("mix")) }
                if let primary {
                    first = primary.texture ?? black
                    primary.bind(to:&audioSamples,offset:0,columns:columns,rows:rows)
                    uniforms.c.x = primary.time
                } else if !isMatrix { first = black }
                if let light {
                    light.bind(to:&audioSamples,offset:16,columns:columns,rows:rows)
                    secondaryFieldTexture = light.texture
                }
                if primary != nil || light != nil {
                    let resource = fieldPipeline(FieldProgram(primary:primary?.input,secondary:light?.input))
                    guard let compiled = resource.pipeline else {
                        encoder.endEncoding()
                        textures[node.id] = black
                        renderStatus[node.id] = resource.error ?? "Compiling fields…"
                        continue
                    }
                    nodePipeline = compiled
                    renderStatus[node.id] = resource.error ?? "Ready"
                } else { renderStatus[node.id]=isMatrix && incoming[0] != nil ? "Video" : "Connect Field" }
                if node.kind == .fieldMix { fields[SignalOutlet(node:node.id,port:0)] = FieldSignal(texture:target) }
            case .pictureInPicture:
                uniforms.mode.x = 13
                let w = node.value("width"), h = node.value("height")
                uniforms.a = .init(Float((1-w)*node.value("x")),Float((1-h)*node.value("y")),Float(w),Float(h))
                uniforms.b = .init(Float(node.value("opacity")),Float(node.value("radius")),Float(node.value("border")),Float(node.value("shadow")))
                uniforms.d.x = Float(node.value("fit"))
            case .channelSplit:
                uniforms.mode.x = 12
                uniforms.mode.y = UInt32(node.value("mode"))
                uniforms.mode.z = UInt32(node.value("edges"))
                uniforms.a = .init(Float(node.value("amount")),Float(node.value("angle") * .pi/180),Float(node.value("radial")),Float(node.value("mix")))
                uniforms.d = .init(Float(node.value("x0")),Float(node.value("y0")),Float(node.value("x1")),Float(node.value("y1")))
                uniforms.e = .init(Float(node.value("x2")),Float(node.value("y2")),Float(node.value("x3")),Float(node.value("y3")))
            case .channelColors:
                uniforms.mode.x = 16
                uniforms.mode.y = UInt32(node.value("channels"))
                uniforms.mode.z = UInt32(node.value("blend"))
                func rgb(_ key: String) -> SIMD3<Float> { let v = Int(node.value(key)); return .init(Float((v>>16)&255),Float((v>>8)&255),Float(v&255))/255 }
                uniforms.a = .init(rgb("color0"),Float(node.value("mix")))
                uniforms.b = .init(rgb("color1"),0)
                uniforms.c = .init(rgb("color2"),0)
                uniforms.d = .init(Float(node.value("level0")),Float(node.value("level1")),Float(node.value("level2")),0)
            case .crop:
                let r = CropStyle.region(node,width:a.width,height:a.height)
                uniforms.mode.x = 11
                uniforms.a = .init(Float(r.x),Float(r.y),Float(r.width),Float(r.height))
                uniforms.b = .init(Float(node.value("fit")),Float(node.value("background")),Float(node.value("flipX")),Float(node.value("flipY")))
            case .ab: uniforms.mode.x = 3; uniforms.a = .init(Float(node.value("mode") == 1 ? (node.value("mix") < 0.5 ? 0 : 1) : node.value("mix")),0,0,0)
            case .blend: uniforms.mode.x = 3; uniforms.a = .init(Float(node.value("mix")), Float(node.value("mode")),0,0); uniforms.b = .init(Float(node.value("x")),Float(node.value("y")),Float(node.value("scale")),0)
            case .color: uniforms.videoAdjustment(node)
            default: break
            }
            audioSamples.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
            encoder.setComputePipelineState(nodePipeline)
            encoder.setTexture(first, index: 0); encoder.setTexture(secondaryFieldTexture ?? b, index: 1); encoder.setTexture(target, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.dispatchThreads(.init(width: target.width, height: target.height, depth: 1), threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1))
            encoder.endEncoding(); textures[node.id] = target
            if let source=staticSource {
                staticVersion &+= 1
                staticFrames[node.id]=StaticFrame(parameters:node.parameters,source:source,target:target,upstreamVersion:upstreamVersion,version:staticVersion)
                staticVersions[node.id]=staticVersion
            }
            if renderStatus[node.id] == nil { renderStatus[node.id] = incoming.count < node.inputs.count ? "Missing input" : "Ready" }
        }
        let outputSnapshot = outputRuntime.publish(graph:publicationGraph,nodes:effectiveNodes,textures:textures,palettes:paletteValues,controls:controlValues,existingSyphon:syphon,staticVersions:staticVersions,command:command)
        stateLock.withLock { publishedDemand=["gatedMuxInputs":Dictionary(uniqueKeysWithValues:gatedMuxInputs.map { ($0.key.uuidString,$0.value.sorted()) }),"staticCacheHits":staticCacheHits,"cachedStaticNodes":staticFrames.count,"warmPublishers":outputRuntime.publishers.count,"activeNodes":required.map(\.uuidString).sorted(),"idleNodes":plan.filter { !required.contains($0.id) }.map { $0.id.uuidString },"previewNodes":previewDemand.keys.map(\.uuidString).sorted(),"rasterNodes":raster.map(\.uuidString).sorted(),"hostManaged":outputRuntime.hostManaged] }
        if required.isEmpty {
            inFlight.signal()
            stateLock.withLock { publishedGPU=0 }
        } else {
            command.addCompletedHandler { [weak self, retainedCV, inFlight] completed in
                _ = retainedCV
                inFlight.signal()
                let ms = (completed.gpuEndTime - completed.gpuStartTime) * 1000
                self?.stateLock.withLock { self?.publishedGPU = ms; self?.publishedFrames += 1 }
            }
            command.commit()
        }
        audioGraph.clocks(videoClocks)
        let mediaStates = audioSnapshot.2.merging(videoClocks) { _,video in video }
        let meshHandles=Dictionary(uniqueKeysWithValues:effectiveNodes.values.filter {$0.enabled && $0.kind == .meshGradient}.map { n in (n.id,(0..<max(1,min(40,Int(n.value("count"))))).map { MeshGradientStyle.animatedPosition(n,index:$0,time:renderTime*n.value("speed")) }) })
        let voltageScopes=Dictionary(uniqueKeysWithValues:effectiveNodes.values.filter { $0.kind == .voltageVisualizer && $0.enabled }.map { node in
            let input=inputs[node.id] ?? [:]
            return (node.id,VoltageScope(node:node,source:node.id,rate:input[1].flatMap { drawRates[$0] } ?? node.value("rate"),linked:input[1] != nil))
        })
        stateLock.withLock { publishedVoltageScopes=voltageScopes }
        stateLock.withLock { publishedMeshPositions=meshHandles; self.outputSnapshot = outputSnapshot; publishedPalettes = paletteValues; publishedMedia = mediaStates; publishedControls = controlValues; publishedModulation = modulationValues; publishedFaces = faceFrames; publishedPoses = poseFrames; publishedTextures = textures.merging(layerPreviewFrames) { _,preview in preview }; publishedStatus = renderStatus; publishedTime = renderTime }
    }
    func recordingInfo(_ id: UUID) -> RecordingInfo? { renderQueue.sync { recordings[id]?.info } }
    var recordingStates: [String:Any] { renderQueue.sync { Dictionary(uniqueKeysWithValues:recordings.map { ($0.key.uuidString,$0.value.info.object as Any) }) } }
    func startRecording(_ id: UUID) throws {
        try renderQueue.sync {
            guard running else { throw GraphError("Start the tab before recording") }
            guard let node = activeGraph.node(id), [.record,.recordAudio].contains(node.kind), node.enabled else { throw GraphError("Enable a Record Movie or Record Audio node first") }
            guard activeGraph.edges.contains(where:{ $0.target == id && $0.input == 0 }) else { throw GraphError(node.kind == .recordAudio ? "Connect an audio source before recording" : "Connect a video source before recording") }
            if let phase = recordings[id]?.info.phase, phase == "recording" || phase == "finishing" { throw GraphError("This node is already recording or finishing") }
            if node.kind == .recordAudio {
                let recorder = try AudioRecorder(AudioRecording.Options(node))
                recordings[id] = recorder; audioGraph.record(id,recorder:recorder)
                return
            }
            let dimensions = activeGraph.videoDimensions(id)
            let movie = try MovieRecorder(device:device,width:dimensions.width,height:dimensions.height,fps:activeGraph.fps,audio:activeGraph.edges.contains { $0.target == id && $0.input == 1 })
            recordings[id] = movie; audioGraph.record(id,recorder:movie)
        }
    }
    func stopRecording(_ id: UUID, completion: ((Result<URL,Error>)->Void)? = nil) {
        renderQueue.async {
            guard let recorder = self.recordings[id] else { if let completion { DispatchQueue.main.async { completion(.failure(GraphError("No recording for this node"))) } }; return }
            recorder.finish(completion)
        }
    }
    func discardRecording(_ id: UUID) throws {
        // File work stays off the render queue; retain the exact take while clearing.
        guard let recorder = renderQueue.sync(execute:{ recordings[id] }) else { return }
        try recorder.discard()
        renderQueue.sync { if recordings[id] === recorder { recordings[id] = nil } }
    }
    func saveRecording(_ id: UUID,to url: URL,replace: Bool = false) throws {
        guard let recorder = renderQueue.sync(execute:{ recordings[id] }) else { throw GraphError("No recording for this node") }
        try recorder.save(to:url,replace:replace)
    }
    var hasActiveRecordings: Bool { renderQueue.sync { recordings.values.contains { ["recording","finishing"].contains($0.info.phase) } } }
    func finishRecordings(_ completion: @escaping ()->Void) {
        renderQueue.async {
            let group = DispatchGroup()
            for recorder in self.recordings.values { group.enter(); recorder.finish { _ in group.leave() } }
            group.notify(queue:.main,execute:completion)
        }
    }
    /// Ferrofluid steps its spike lattice on the transport clock and uploads the
    /// heightfield into a ring of three textures, one per in-flight frame.
    private func ferrofluidFrame(_ node: Node) -> (FerrofluidSim.Frame,MTLTexture?) {
        var entry=ferrofluids[node.id] ?? (FerrofluidSim(),[],0)
        let frame=entry.sim.step(node,time:renderTime)
        if entry.textures.first?.width != frame.width {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r16Float,width:frame.width,height:frame.width,mipmapped:false)
            descriptor.usage=[.shaderRead];descriptor.storageMode = .shared
            entry.textures=(0..<3).compactMap { _ in device.makeTexture(descriptor:descriptor) }
        }
        var texture: MTLTexture?
        if !entry.textures.isEmpty {
            texture=entry.textures[entry.next%entry.textures.count]; entry.next+=1
            let half=frame.heights.map { Float16($0) }
            half.withUnsafeBytes { texture?.replace(region:MTLRegionMake2D(0,0,frame.width,frame.width),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:frame.width*2) }
        }
        ferrofluids[node.id]=entry
        return (frame,texture)
    }
    /// Liquid Chrome's poured liquid (thickness, phase), simulated off the render
    /// queue whenever the shape changes. The previous pour stays bound until the new one lands.
    private func membraneTexture(_ node: Node, aspect: Double) -> MTLTexture? {
        let key=LiquidChromeStyle.shapeKey(node,aspect:aspect)
        let cached=membranes[node.id]
        if cached?.key != key && !membraneJobs.contains(node.id) {
            membraneJobs.insert(node.id)
            let device=self.device
            membraneQueue.async { [weak self] in
                let solved=LiquidChromeStyle.pour(node,aspect:aspect)
                let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rg16Float,width:solved.width,height:solved.height,mipmapped:false)
                descriptor.usage=[.shaderRead];descriptor.storageMode = .shared
                let texture=device.makeTexture(descriptor:descriptor)
                let half=solved.values.map { Float16($0) }
                half.withUnsafeBytes { texture?.replace(region:MTLRegionMake2D(0,0,solved.width,solved.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:solved.width*4) }
                self?.renderQueue.async { self?.membraneJobs.remove(node.id);self?.membranes[node.id]=(key,texture) }
            }
        }
        return cached?.texture
    }
    func snapshot(_ id: UUID, to url: URL, fullResolution: Bool = false) throws {
        // An explicit API snapshot is a consumer, even with the editor hidden.
        let texture: MTLTexture? = renderQueue.sync {
            if fullResolution,var node=activeGraph.node(id),node.hasLiquidSculptureControls {
                // Export only this shader on an independent target; live publishers and recorders keep their sizes.
                guard let pipeline=shader(node)?.pipeline else { return nil }
                var exportGraph=activeGraph
                if let index=exportGraph.nodes.firstIndex(where:{$0.id==id}) { exportGraph.nodes[index].parameters["quality"]=2 }
                let dimensions=exportGraph.videoDimensions(id)
                let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:dimensions.width,height:dimensions.height,mipmapped:false)
                descriptor.usage=[.shaderRead,.shaderWrite];descriptor.storageMode = .private
                guard let target=device.makeTexture(descriptor:descriptor),let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { return nil }
                let sourceID=activeGraph.edges.first(where:{$0.target==id && $0.input==0})?.source
                let source=stateLock.withLock { sourceID.flatMap { publishedTextures[$0] } } ?? black
                let modulation=stateLock.withLock { publishedModulation[id] ?? [:] }
                node.parameters.merge(modulation) { _,new in new };node.parameters["quality"]=2
                let aspect=Float(dimensions.width)/Float(dimensions.height)
                let controls=node.hasLiquidChromeControls ? LiquidChromeStyle.shaderValues(node,aspect:aspect,hasInput:sourceID != nil) : LiquidMetalStyle.shaderValues(node,aspect:aspect,hasInput:sourceID != nil)
                var time=Float(renderTime*node.value("speed"))
                let buffer=controls.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }
                guard let buffer else { encoder.endEncoding();return nil }
                encoder.setComputePipelineState(pipeline);encoder.setTexture(target,index:0);encoder.setTexture(source,index:1)
                encoder.setTexture((node.hasLiquidChromeControls ? membraneTexture(node,aspect:Double(aspect)) : nil) ?? black,index:2)
                encoder.setBytes(&time,length:4,index:0);encoder.setBuffer(buffer,offset:0,index:1)
                encoder.dispatchThreads(.init(width:dimensions.width,height:dimensions.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));encoder.endEncoding();command.commit()
                return target
            }
            previewDemand[id]=CACurrentMediaTime()+0.3
            render(activeGraph,preview:id)
            return stateLock.withLock { publishedTextures[id] }
        }
        guard let source=texture, let buffer=queue.makeCommandBuffer() else { throw GraphError("No rendered frame.") }
        let tex: MTLTexture
        if source.pixelFormat == .rgba16Float {
            // PNG needs an SDR BGRA surface. The graph keeps the full field range.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:source.width,height:source.height,mipmapped:false)
            descriptor.usage = [.shaderWrite,.shaderRead]; descriptor.storageMode = .private
            guard let converted=device.makeTexture(descriptor:descriptor), let encoder=buffer.makeComputeCommandEncoder() else { throw GraphError("Cannot convert field snapshot.") }
            var params=Uniforms(); params.mode.x=17
            var zero=Float(0)
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source,index:0);encoder.setTexture(black,index:1);encoder.setTexture(converted,index:2)
            encoder.setBytes(&params,length:MemoryLayout<Uniforms>.stride,index:0)
            encoder.setBytes(&zero,length:MemoryLayout<Float>.stride,index:1)
            encoder.dispatchThreads(.init(width:converted.width,height:converted.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1))
            encoder.endEncoding(); tex=converted
        } else { tex=source }
        guard let blit=buffer.makeBlitCommandEncoder(), let copy=device.makeBuffer(length:((tex.width*4+255)/256)*256*tex.height,options:.storageModeShared) else { throw GraphError("No snapshot buffer.") }
        let stride = ((tex.width * 4 + 255) / 256) * 256
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x:0,y:0,z:0), sourceSize: .init(width:tex.width,height:tex.height,depth:1), to:copy,destinationOffset:0,destinationBytesPerRow:stride,destinationBytesPerImage:copy.length)
        blit.endEncoding(); buffer.commit(); buffer.waitUntilCompleted()
        if let error = buffer.error { throw error }
        let data = Data(bytes: copy.contents(), count: copy.length)
        guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: tex.width, height: tex.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw GraphError("Cannot encode snapshot.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GraphError("Cannot save snapshot.") }
    }
}
final class VideoView: MTKView, MTKViewDelegate {
    let renderer: Renderer
    var nodeID: UUID? { didSet { if nodeID != oldValue { nextDemandTime=0 } } }
    private var nextDemandTime=0.0
    private(set) var previewRendering = "videoTexture"
    private(set) var previewPoints = 0
    private let availableFrames = DispatchSemaphore(value:2)
    private let presentationLock = NSLock()
    private var presentationCount = 0
    private var presentationTime = 0.0
    var presentationStats: (frames:Int,time:Double) { presentationLock.withLock { (presentationCount,presentationTime) } }
    init(renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        renderer.views.add(self)
        delegate = self
        colorPixelFormat = .bgra8Unorm; framebufferOnly = true; isPaused = !renderer.running; enableSetNeedsDisplay = false; preferredFramesPerSecond = 60
        colorspace = CGColorSpace(name:CGColorSpace.sRGB)
        clearColor = MTLClearColorMake(0.025, 0.029, 0.035, 1)
    }
    required init(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    // Only acquire/present a drawable inside MTKView.draw(). MetalKit releases its
    // cached currentDrawable after this delegate callback, allowing the next frame.
    func draw(in view: MTKView) {
        guard !isPaused, window?.isVisible == true, window?.occlusionState.contains(.visible) == true, !isHiddenOrHasHiddenAncestor, visibleRect.width > 1, visibleRect.height > 1 else { return }
        let now=CACurrentMediaTime()
        if let nodeID,now>=nextDemandTime { renderer.requestPreview(nodeID); nextDemandTime=now+0.1 }
        guard bounds.width > 1, bounds.height > 1,
              availableFrames.wait(timeout:.now()) == .success else { return }
        guard let drawable = currentDrawable,
              let cmd = renderer.queue.makeCommandBuffer() else { availableFrames.signal(); return }
        guard let pass = currentRenderPassDescriptor,let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { availableFrames.signal(); return }
        enc.setRenderPipelineState(renderer.previewPipeline)
        enc.setFragmentTexture(renderer.texture(nodeID), index: 0)
        var aspect = Float(drawable.texture.width) / Float(max(1, drawable.texture.height))
        enc.setFragmentBytes(&aspect, length: 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        previewRendering="videoTexture";previewPoints=0
        drawable.addPresentedHandler { [weak self] shown in
            guard let self, shown.presentedTime > 0 else { return }
            self.presentationLock.withLock { self.presentationCount += 1; self.presentationTime = shown.presentedTime }
        }
        cmd.addCompletedHandler { [availableFrames] _ in availableFrames.signal() }
        cmd.present(drawable); cmd.commit()
    }
}
