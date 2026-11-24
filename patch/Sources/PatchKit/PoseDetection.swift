import Foundation
import Metal
import CoreML
import CoreVideo
import QuartzCore
import PatchCore

/// GPU readback and inference are bounded to one frame per detector. Model loading,
/// inference and postprocessing run on the worker, never the UI or render queue.
final class PoseDetectionResource: @unchecked Sendable {
    static let defaultModelURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Patch/Models/yolo11n-pose.mlmodelc")
    let path: String
    private let lock = NSLock()
    private let worker = DispatchQueue(label:"patch.yolo-pose", qos:.userInitiated)
    private var busy = false
    private var ready = false
    private var lastSubmission = -Double.infinity
    private var generation = 0
    private var sequence = 0
    private var result: PoseFrame?
    private var error: String?
    // Confined to worker after initialization.
    private var model: MLModel?
    private var pixelBuffer: CVPixelBuffer?
    // Confined to render queue, retained by the completion handler until inference ends.
    private var sample: MTLTexture?
    private var readback: MTLBuffer?

    init(path: String) { self.path = path }
    func invalidate() {
        lock.withLock { generation += 1; result = nil; lastSubmission = -Double.infinity }
    }
    func snapshot(now: Double) -> (PoseFrame?, String) {
        lock.withLock {
            if let error { return (nil,error) }
            guard let result else { return (nil, ready ? "Detecting poses…" : "Loading YOLO model…") }
            guard now-result.timestamp < 2 else { return (nil,"Waiting for fresh poses") }
            return (result,"\(result.poses.count) people · \(Int(result.inferenceMS)) ms")
        }
    }
    func encode(source: MTLTexture, device: MTLDevice, command: MTLCommandBuffer,
                pipeline: MTLComputePipelineState, node: Node, now: Double) {
        guard let state = lock.withLock({ () -> (Int,Bool)? in
            let interval = error == nil ? 1/node.value("rate") : 5
            guard !busy, now-lastSubmission >= interval else { return nil }
            busy = true; lastSubmission = now
            return (self.generation,ready)
        }) else { return }
        let generation = state.0
        if !state.1 {
            worker.async { [self] in
                do {
                    guard FileManager.default.fileExists(atPath:path) else {
                        throw GraphError("YOLO model missing · run scripts/setup-pose.sh")
                    }
                    let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
                    let model = try MLModel(contentsOf:URL(fileURLWithPath:path),configuration:configuration)
                    guard let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
                          input.pixelsWide == 640, input.pixelsHigh == 640 else {
                        throw GraphError("Expected YOLO11 pose model with a 640 × 640 image input")
                    }
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferCreate(nil,640,640,kCVPixelFormatType_32BGRA,nil,&buffer) == kCVReturnSuccess else {
                        throw GraphError("Cannot allocate YOLO input")
                    }
                    self.model = model; pixelBuffer = buffer
                    lock.withLock { ready = true }
                    finish(nil,generation:generation,error:nil)
                } catch { finish(nil,generation:generation,error:error.localizedDescription) }
            }
            return
        }
        let size = 640, stride = 640*4
        if sample == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:size,height:size,mipmapped:false)
            desc.usage = [.shaderRead,.shaderWrite]; desc.storageMode = .private
            sample = device.makeTexture(descriptor:desc)
            readback = device.makeBuffer(length:stride*size,options:.storageModeShared)
        }
        guard let sample, let readback, let encoder = command.makeComputeCommandEncoder() else {
            finish(nil,generation:generation,error:"Cannot allocate pose analysis buffer"); return
        }
        encoder.setComputePipelineState(pipeline); encoder.setTexture(source,index:0); encoder.setTexture(sample,index:1)
        encoder.dispatchThreads(.init(width:size,height:size,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); encoder.endEncoding()
        guard let blit = command.makeBlitCommandEncoder() else { finish(nil,generation:generation,error:"Cannot read pose frame"); return }
        blit.copy(from:sample,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:size,height:size,depth:1),to:readback,destinationOffset:0,destinationBytesPerRow:stride,destinationBytesPerImage:stride*size)
        blit.endEncoding()
        let width = source.width, height = source.height
        command.addCompletedHandler { [self] completed in
            guard completed.status == .completed else { finish(nil,generation:generation,error:"Pose analysis GPU failure"); return }
            worker.async { [self] in
                autoreleasepool {
                    do {
                        guard let model, let pixelBuffer else { throw GraphError("YOLO model unavailable") }
                        let start = CACurrentMediaTime()
                        CVPixelBufferLockBaseAddress(pixelBuffer,[])
                        if let bytes = CVPixelBufferGetBaseAddress(pixelBuffer) {
                            let row = CVPixelBufferGetBytesPerRow(pixelBuffer)
                            for y in 0..<size { memcpy(bytes.advanced(by:y*row),readback.contents().advanced(by:y*stride),stride) }
                        }
                        CVPixelBufferUnlockBaseAddress(pixelBuffer,[])
                        let output = try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(pixelBuffer:pixelBuffer)]))
                        guard let array = output.featureNames.sorted().compactMap({ output.featureValue(for:$0)?.multiArrayValue }).first else {
                            throw GraphError("YOLO model has no pose tensor")
                        }
                        let poses = try Self.decode(array,width:width,height:height,confidence:node.value("confidence"),iou:node.value("iou"))
                        let number = lock.withLock { sequence += 1; return sequence }
                        finish(PoseFrame(sequence:number,timestamp:now,width:width,height:height,inferenceMS:(CACurrentMediaTime()-start)*1000,poses:poses),generation:generation,error:nil)
                    } catch { finish(nil,generation:generation,error:"YOLO: \(error.localizedDescription)") }
                }
            }
        }
    }
    private func finish(_ frame: PoseFrame?, generation: Int, error: String?) {
        lock.withLock {
            if generation == self.generation { result = frame; self.error = error }
            busy = false
        }
    }
    private static func decode(_ array: MLMultiArray, width: Int, height: Int, confidence: Double, iou: Double) throws -> [DetectedPose] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[1] == 56, shape[2] > 0 else {
            throw GraphError("Expected raw YOLO11 pose tensor [1,56,N]; got \(shape)")
        }
        func value(_ channel: Int, _ index: Int) -> Double {
            let offset = channel*strides[1]+index*strides[2]
            switch array.dataType {
            case .float32: return Double(array.dataPointer.assumingMemoryBound(to:Float.self)[offset])
            case .float16: return Double(array.dataPointer.assumingMemoryBound(to:Float16.self)[offset])
            case .double: return array.dataPointer.assumingMemoryBound(to:Double.self)[offset]
            default: return array[offset].doubleValue
            }
        }
        let scale = 640.0/Double(max(width,height))
        let w = Double(width)*scale, h = Double(height)*scale
        let padX = (640-w)/2, padY = (640-h)/2
        var candidates: [(Int,Double,FaceBounds)] = []
        for i in 0..<shape[2] {
            let score = value(4,i)
            guard score.isFinite, score >= confidence else { continue }
            let cx = value(0,i), cy = value(1,i), bw = value(2,i), bh = value(3,i)
            guard [cx,cy,bw,bh].allSatisfy(\.isFinite), bw > 0, bh > 0 else { continue }
            let x0 = max(0,min(1,(cx-bw/2-padX)/w)), x1 = max(0,min(1,(cx+bw/2-padX)/w))
            let y0 = max(0,min(1,(cy-bh/2-padY)/h)), y1 = max(0,min(1,(cy+bh/2-padY)/h))
            guard x1 > x0, y1 > y0 else { continue }
            candidates.append((i,score,FaceBounds(x:x0,y:y0,width:x1-x0,height:y1-y0)))
        }
        var poses: [DetectedPose] = []
        for (i,score,bounds) in candidates.sorted(by:{ $0.1 > $1.1 }).prefix(300) {
            if poses.contains(where:{ overlap(bounds,$0.bounds) > iou }) { continue }
            let points = (0..<17).map { joint -> PosePoint in
                let x = (value(5+joint*3,i)-padX)/w, y = (value(6+joint*3,i)-padY)/h, c = value(7+joint*3,i)
                guard x.isFinite, y.isFinite, c.isFinite else { return PosePoint(x:0,y:0,confidence:0) }
                return PosePoint(x:max(0,min(1,x)),y:max(0,min(1,y)),confidence:(0...1).contains(x) && (0...1).contains(y) ? max(0,min(1,c)) : 0)
            }
            poses.append(DetectedPose(bounds:bounds,confidence:score,keypoints:points))
            if poses.count == 32 { break }
        }
        return poses
    }
    private static func overlap(_ a: FaceBounds, _ b: FaceBounds) -> Double {
        let intersection = max(0,min(a.x+a.width,b.x+b.width)-max(a.x,b.x))*max(0,min(a.y+a.height,b.y+b.height)-max(a.y,b.y))
        return intersection/max(1e-9,a.width*a.height+b.width*b.height-intersection)
    }
}
