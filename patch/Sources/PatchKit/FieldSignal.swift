import Foundation
import Metal
import QuartzCore
import PatchCore

enum FieldInput: Hashable {
    case procedural(String)
    case cells
    case sampled

    init?(producer node: Node) {
        if node.kind == .cellularField { self = .cells }
        else if node.kind == .fieldMix { self = .sampled }
        else if let file = ShaderCompiler.sourceURL(node) { self = .procedural(file) }
        else { return nil }
    }

    var file: String? {
        if case let .procedural(path) = self { return path }
        return nil
    }
}

struct FieldProgram: Hashable {
    let primary: FieldInput?
    let secondary: FieldInput?

    func compile(device: MTLDevice) throws -> MTLComputePipelineState {
        try ShaderCompiler.matrix(primary:primary?.file.map { try String(contentsOfFile:$0) },
                                  light:secondary?.file.map { try String(contentsOfFile:$0) },
                                  primaryCells:primary == .cells, lightCells:secondary == .cells,
                                  lightTexture:secondary == .sampled, device:device)
    }
    var revision: String { ShaderCompiler.matrixRevision([primary?.file,secondary?.file]) }
}

/// A field carries shader inputs or a sampled RGB surface in normalized coordinates.
struct FieldSignal {
    let input: FieldInput
    var texture: MTLTexture?
    var palette: ColorPalette?
    var time: Float = 0
    private var values = [Float](repeating:0,count:16)

    init(texture: MTLTexture) { input = .sampled; self.texture = texture }
    init?(node: Node, input: FieldInput, palette: ColorPalette, time: Double) {
        self.input = input
        let keys: [String]
        switch node.kind {
        case .fieldShader: keys = node.parameterDefinitions.map(\.key)
        case .flashCells:
            self.palette = palette
            keys = ["rate","chance","onTime","fade","colorMode","seed"]
        case .cellularField:
            keys = ["depth","output"]
        case .waterfallField: keys = ["rows","rate","blockers","gap","widthMin","widthMax","durationMin","durationMax","motion","motionRate","pattern","tail","seed","probability"]
        case .streakField: keys = ["rows","travel","length","activity","grouping","stagger","tail","seed"]
        case .streakGlow: keys = StreakGlowStyle.keys
        case .blockerField: keys = ["rows","rate","segments","tail","density","variance","depth","blockers","motion","height","jitter","refresh","seed"]
        case .dataStream: keys = ["rows","rate","packets","length","density","variance","mask","maskScale","maskSpeed","bands","jitter","refresh","seed","pattern"]
        default: return nil
        }
        guard keys.count <= 15 else { return nil }
        for (i,key) in keys.enumerated() { values[i] = Float(node.value(key)) }
        let timeScale: Double
        if node.kind == .fieldShader {
            timeScale = node.parameterDefinitions.first(where:{ $0.scalesFieldTime == true }).map { node.value($0.key) } ?? 1
        } else { timeScale = [.waterfallField,.flashCells].contains(node.kind) ? 1 : node.value("speed") }
        self.time = Float(time*timeScale)
        if input != .cells { values[15] = self.time }
    }
    func bind(to buffer: inout [Float], offset: Int, columns: Double, rows: Double) {
        buffer.replaceSubrange(offset..<offset+16,with:values)
        guard let palette else { return }
        let colors = palette.colors.prefix(64), start = offset == 0 ? 32 : 224
        buffer[offset+6] = Float(columns); buffer[offset+7] = Float(rows)
        buffer[offset+8] = Float(colors.count); buffer[offset+9] = Float(start-offset)
        for (i,color) in colors.enumerated() {
            let index = start+i*3
            buffer[index] = Float(color.r); buffer[index+1] = Float(color.g); buffer[index+2] = Float(color.b)
        }
    }
}
extension Renderer {
    func fieldPipeline(_ program: FieldProgram) -> ShaderResource {
        let resource: ShaderResource
        if let existing = fieldPipelines[program] { resource = existing }
        else {
            resource = ShaderResource("field")
            resource.fieldProgram = program
            fieldPipelines[program] = resource
        }
        let now = CACurrentMediaTime()
        guard now-resource.checked > 1, !resource.compiling else { return resource }
        resource.checked = now
        let revision = program.revision
        guard revision != resource.revisionKey || (resource.pipeline == nil && resource.error == nil) else { return resource }
        resource.compiling = true
        resource.revisionKey = revision
        let device = self.device
        DispatchQueue.global(qos:.userInitiated).async { [weak resource] in
            do {
                let pipeline = try program.compile(device:device)
                self.renderQueue.async { resource?.pipeline = pipeline; resource?.error = nil; resource?.compiling = false }
            } catch {
                self.renderQueue.async { resource?.error = error.localizedDescription; resource?.compiling = false }
            }
        }
        return resource
    }
}

extension Renderer {
    func fieldPreviewDimensions(_ size: VideoDimensions) -> VideoDimensions {
        let scale = min(1,320/Double(max(size.width,size.height)))
        return VideoDimensions(max(1,Int((Double(size.width)*scale).rounded())),
                               max(1,Int((Double(size.height)*scale).rounded())))
    }

    func preview(_ field: FieldSignal,grid: VideoDimensions,size: VideoDimensions,previous: MTLTexture?,command: MTLCommandBuffer) -> (texture:MTLTexture?,status:String?) {
        let resource = fieldPipeline(FieldProgram(primary:field.input,secondary:nil))
        guard let pipeline = resource.pipeline else { return (nil,resource.error ?? "Compiling field") }
        let texture: MTLTexture?
        if let previous, previous.width == size.width, previous.height == size.height, previous.pixelFormat == .bgra8Unorm { texture = previous }
        else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:size.width,height:size.height,mipmapped:false)
            descriptor.usage = [.shaderRead,.shaderWrite]; descriptor.storageMode = .private
            texture = device.makeTexture(descriptor:descriptor)
        }
        guard let texture, let encoder = command.makeComputeCommandEncoder() else { return (nil,"Field preview unavailable") }
        var params = Uniforms(); params.mode.x = 17; params.c.x = field.time
        var data = [Float](repeating:0,count:512)
        field.bind(to:&data,offset:0,columns:Double(grid.width),rows:Double(grid.height))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(field.texture ?? black,index:0); encoder.setTexture(black,index:1); encoder.setTexture(texture,index:2)
        encoder.setBytes(&params,length:MemoryLayout<Uniforms>.stride,index:0)
        data.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:1) }
        encoder.dispatchThreads(.init(width:size.width,height:size.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1))
        encoder.endEncoding()
        return (texture,resource.error)
    }
}
