import Foundation
import Metal
import Vision
import QuartzCore
import PatchCore

/// One GPU readback/inference at a time per detector. All cross-queue state is locked.
final class FaceDetectionResource: @unchecked Sendable {
    private let lock = NSLock()
    private let worker = DispatchQueue(label:"patch.faces",qos:.userInitiated)
    private var busy = false
    private var lastSubmission = -Double.infinity
    private var sequence = 0
    private var generation = 0
    private var result: FaceFrame?
    private var error: String?
    private var sample: MTLTexture?
    private var readback: MTLBuffer?

    func invalidate() {
        lock.withLock { generation += 1; result = nil; error = nil; lastSubmission = -Double.infinity }
    }
    func snapshot(now: Double, captureScale: Double) -> (FaceFrame?, String) {
        lock.withLock {
            if let error { return (nil,error) }
            guard let result else { return (nil,"Detecting…") }
            guard now-result.timestamp < 2 else { return (nil,"Waiting for fresh detection") }
            // Expand the capture bounds without moving the observed landmarks.
            // Derive from the raw result each frame so adjustments never accumulate
            // or wait for another Vision inference.
            var frame = result
            frame.faces = result.faces.map { face in
                var face = face
                let bounds = face.bounds
                let width = bounds.width * captureScale, height = bounds.height * captureScale
                face.bounds = FaceBounds(x:bounds.x + (bounds.width-width)/2,
                                         y:bounds.y + (bounds.height-height)/2,
                                         width:width,height:height)
                return face
            }
            return (frame,"\(frame.faces.count) face\(frame.faces.count == 1 ? "" : "s") · \(Int(frame.inferenceMS)) ms")
        }
    }
    func encode(source: MTLTexture, device: MTLDevice, command: MTLCommandBuffer,
                pipeline: MTLComputePipelineState, rate: Double, now: Double) {
        guard let generation = lock.withLock({ () -> Int? in
            if busy || now-lastSubmission < 1/rate { return nil }
            busy = true; lastSubmission = now; return self.generation
        }) else { return }
        let scale = min(1,640.0/Double(max(source.width,source.height)))
        let width = max(1,Int(Double(source.width)*scale)), height = max(1,Int(Double(source.height)*scale))
        let stride = ((width*4+255)/256)*256
        if sample?.width != width || sample?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
            desc.usage = [.shaderRead,.shaderWrite]; desc.storageMode = .private
            sample = device.makeTexture(descriptor:desc)
            readback = device.makeBuffer(length:stride*height,options:.storageModeShared)
        }
        guard let sample, let readback, let encoder = command.makeComputeCommandEncoder() else {
            finish(nil,generation:generation,error:"Cannot allocate face analysis buffer"); return
        }
        encoder.setComputePipelineState(pipeline); encoder.setTexture(source,index:0); encoder.setTexture(sample,index:1)
        encoder.dispatchThreads(.init(width:width,height:height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); encoder.endEncoding()
        guard let blit = command.makeBlitCommandEncoder() else { finish(nil,generation:generation,error:"Cannot read face analysis frame"); return }
        blit.copy(from:sample,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:width,height:height,depth:1),to:readback,destinationOffset:0,destinationBytesPerRow:stride,destinationBytesPerImage:stride*height)
        blit.endEncoding()
        let sourceWidth = source.width, sourceHeight = source.height
        command.addCompletedHandler { [self] completed in
            guard completed.status == .completed else { finish(nil,generation:generation,error:"Face analysis GPU failure"); return }
            worker.async { [self] in
                autoreleasepool {
                    do {
                        let start = CACurrentMediaTime()
                        let data = Data(bytes:readback.contents(),count:stride*height)
                        guard let provider = CGDataProvider(data:data as CFData), let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw GraphError("Cannot create face analysis image") }
                        let request = VNDetectFaceLandmarksRequest()
                        try VNImageRequestHandler(cgImage:image,orientation:.up,options:[:]).perform([request])
                        let faces = (request.results ?? []).prefix(32).map { observation -> DetectedFace in
                            let r = observation.boundingBox
                            let bounds = FaceBounds.fromVision(x:r.minX,y:r.minY,width:r.width,height:r.height)
                            var points: [String:[FacePoint]] = [:]
                            if let l = observation.landmarks {
                                let regions: [(String,VNFaceLandmarkRegion2D?)] = [("contour",l.faceContour),("leftEye",l.leftEye),("rightEye",l.rightEye),("leftEyebrow",l.leftEyebrow),("rightEyebrow",l.rightEyebrow),("nose",l.nose),("noseCrest",l.noseCrest),("outerLips",l.outerLips),("innerLips",l.innerLips),("leftPupil",l.leftPupil),("rightPupil",l.rightPupil)]
                                for (name,region) in regions {
                                    if let region { points[name] = region.normalizedPoints.map { bounds.landmark(x:Double($0.x),y:Double($0.y)) } }
                                }
                            }
                            return DetectedFace(bounds:bounds,confidence:Double(observation.confidence),landmarks:points)
                        }
                        let number = lock.withLock { sequence += 1; return sequence }
                        finish(FaceFrame(sequence:number,timestamp:now,width:sourceWidth,height:sourceHeight,inferenceMS:(CACurrentMediaTime()-start)*1000,faces:faces),generation:generation,error:nil)
                    } catch { finish(nil,generation:generation,error:"Face detection: \(error.localizedDescription)") }
                }
            }
        }
    }
    private func finish(_ frame: FaceFrame?, generation: Int, error: String?) {
        lock.withLock {
            if generation == self.generation { result = frame; self.error = error }
            busy = false
        }
    }
}

final class FaceBoxRenderer {
    let downsample: MTLComputePipelineState
    let boxes: MTLComputePipelineState
    init(device: MTLDevice, library: MTLLibrary) throws {
        downsample = try device.makeComputePipelineState(function:library.makeFunction(name:"faceDownsample")!)
        boxes = try device.makeComputePipelineState(function:library.makeFunction(name:"faceBoxes")!)
    }
    func encode(source: MTLTexture,target: MTLTexture,frame: FaceFrame?,thickness: Double,command: MTLCommandBuffer) {
        guard let encoder = command.makeComputeCommandEncoder() else { return }
        var rects = (frame?.faces ?? []).prefix(32).map { f in SIMD4<Float>(Float(f.bounds.x),Float(f.bounds.y),Float(f.bounds.width),Float(f.bounds.height)) }
        var count = UInt32(rects.count), line = Float(thickness)
        if rects.isEmpty { rects = [.zero] }
        encoder.setComputePipelineState(boxes); encoder.setTexture(source,index:0); encoder.setTexture(target,index:1)
        rects.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
        encoder.setBytes(&count,length:4,index:1); encoder.setBytes(&line,length:4,index:2)
        encoder.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); encoder.endEncoding()
    }
}
