import AppKit
import AVFoundation
import CoreText
import Metal
import PatchCore

// Normalize every decoded image to the same color space and byte layout before
// upload. This handles indexed, grayscale, CMYK, wide-gamut and high-bit-depth files.
enum ImageUpload {
    static func texture(_ image: CGImage, device: MTLDevice) throws -> MTLTexture {
        guard let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue), let bytes = context.data else { throw GraphError("Cannot convert image to sRGB") }
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:image.width,height:image.height,mipmapped:false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor:descriptor) else { throw GraphError("Cannot allocate image texture") }
        texture.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0,withBytes:bytes,bytesPerRow:image.width*4)
        return texture
    }
    static func text(_ node: Node, width: Int, height: Int, device: MTLDevice) throws -> MTLTexture {
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw GraphError("Cannot render text") }
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        let font = CTFontCreateWithName("Helvetica" as CFString,node.value("size"),nil)
        let color = NSColor(hue:node.value("hue"),saturation:node.value("saturation"),brightness:1,alpha:1).cgColor
        let lines = (node.text ?? "Text").components(separatedBy:"\n")
        let leading = CTFontGetAscent(font)+CTFontGetDescent(font)+CTFontGetLeading(font)+4
        for (index,line) in lines.enumerated() {
            let value = CFAttributedStringCreateMutable(nil,0)!
            CFAttributedStringReplaceString(value,CFRange(location:0,length:0),line as CFString)
            let range = CFRange(location:0,length:CFAttributedStringGetLength(value))
            CFAttributedStringSetAttribute(value,range,kCTFontAttributeName,font)
            CFAttributedStringSetAttribute(value,range,kCTForegroundColorAttributeName,color)
            let ctLine = CTLineCreateWithAttributedString(value)
            let lineWidth = CTLineGetTypographicBounds(ctLine,nil,nil,nil)
            let x = (Double(width) - lineWidth) * node.value("x")
            let anchorY = Double(height) * (1 - node.value("y"))
            let blockOffset = Double(lines.count - 1) * Double(leading) / 2
            let lineOffset = Double(index) * Double(leading)
            let y = anchorY + blockOffset - lineOffset - Double(CTFontGetAscent(font)) / 2
            context.textPosition = CGPoint(x:x,y:y)
            CTLineDraw(ctLine,context)
        }
        guard let image = context.makeImage() else { throw GraphError("Cannot create text image") }
        return try texture(image,device:device)
    }
}
final class TextSource {
    let node: Node; let width: Int; let height: Int
    var texture: MTLTexture?; var error: String?
    init(_ node: Node, _ width: Int, _ height: Int) { self.node = node; self.width = width; self.height = height }
}

final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static var devices: [AVCaptureDevice] { AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.external],mediaType:.video,position:.unspecified).devices }
    let deviceID: String?
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label:"patch.camera",qos:.userInitiated)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var message = "Starting camera…"
    var frame: (CVPixelBuffer?,String) { lock.withLock { (latest,message) } }
    init(deviceID: String?) {
        self.deviceID = deviceID; super.init()
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in
                if allowed { self?.start() } else { self?.setError("Camera permission denied — enable Patch in System Settings") }
            }
        default: setError("Camera permission denied — enable Patch in System Settings")
        }
    }
    private func setError(_ value: String) { lock.withLock { message = value } }
    private func start() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let device = self.deviceID.flatMap({ id in Self.devices.first { $0.uniqueID == id } }) ?? (self.deviceID == nil ? AVCaptureDevice.default(for:.video) : nil) else { throw GraphError("Camera unavailable") }
                let input = try AVCaptureDeviceInput(device:device)
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self,queue:self.captureQueue)
                self.session.beginConfiguration(); self.session.sessionPreset = .hd1280x720
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else { self.session.commitConfiguration(); throw GraphError("Cannot configure camera") }
                self.session.addInput(input); self.session.addOutput(output); self.session.commitConfiguration()
                self.session.startRunning()
            } catch { self.setError(error.localizedDescription) }
        }
    }
    func captureOutput(_ output: AVCaptureOutput,didOutput sampleBuffer: CMSampleBuffer,from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock { latest = pixel; message = "Ready" }
    }
    deinit { let session = session; captureQueue.async { session.stopRunning() } }
}
