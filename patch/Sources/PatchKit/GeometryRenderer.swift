import Foundation
import QuartzCore
import Metal
import PatchCore

final class GeometryResource {
    let parameters: [String:Double]
    var buffer: MTLBuffer?
    var count = 0
    var error: String?
    init(_ parameters: [String:Double]) { self.parameters = parameters }
}
final class ShaderResource {
    let path: String
    var kind: NodeKind?
    var modification: Date?
    var checked: Double = 0
    var revisionKey = ""
    var fieldProgram: FieldProgram?
    var pipeline: MTLComputePipelineState?
    var error: String?
    var compiling = false
    init(_ path: String) { self.path = path }
}
struct GeometryUniforms {
    var camera: SIMD4<Float>
    var style: SIMD4<Float>
}
extension Renderer {
    func geometry(_ node: Node) -> GeometryResource {
        if let existing = geometries[node.id], existing.parameters == node.parameters { return existing }
        let resource = GeometryResource(node.parameters); geometries[node.id] = resource
        let device = self.device
        DispatchQueue.global(qos:.userInitiated).async { [weak resource] in
            do {
                let points = try GeometryGenerator.lorenz(sigma:node.value("sigma"),rho:node.value("rho"),beta:node.value("beta"),count:Int(node.value("points")))
                let buffer = points.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }
                self.renderQueue.async { resource?.buffer = buffer; resource?.count = points.count }
            } catch { self.renderQueue.async { resource?.error = error.localizedDescription } }
        }
        return resource
    }
    func rasterize(_ resource: GeometryResource?, target: MTLTexture, command: MTLCommandBuffer, node: Node?) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.006,0.009,0.013,1)
        guard let enc = command.makeRenderCommandEncoder(descriptor:pass) else { return }
        if let resource, let buffer = resource.buffer {
            var params = GeometryUniforms(camera:.init(Float(renderTime),Float(node?.value("rotation") ?? 0.18),Float(node?.value("scale") ?? 1.1),Float(target.width)/Float(target.height)), style:.init(Float(node?.value("hue") ?? 0.36),Float(node?.value("intensity") ?? 1.8),0,0))
            enc.setRenderPipelineState(geometryPipeline); enc.setVertexBuffer(buffer,offset:0,index:0); enc.setVertexBytes(&params,length:MemoryLayout<GeometryUniforms>.stride,index:1)
            enc.drawPrimitives(type:.lineStrip,vertexStart:0,vertexCount:resource.count)
        }
        enc.endEncoding()
    }
    func shader(_ node: Node) -> ShaderResource? {
        guard let path = ShaderCompiler.sourceURL(node) else { return nil }
        let resource: ShaderResource
        if let existing = shaders[node.id], existing.path == path, existing.kind == node.kind { resource = existing }
        else {
            resource = ShaderResource(path); resource.kind = node.kind; resource.modification = .distantPast
            if let previous = shaders[node.id], previous.kind == node.kind { resource.pipeline = previous.pipeline }
            shaders[node.id] = resource
        }
        let now = CACurrentMediaTime()
        guard now-resource.checked > 1, !resource.compiling else { return resource }
        resource.checked = now
        let date = (try? FileManager.default.attributesOfItem(atPath:path)[.modificationDate]) as? Date
        guard date != resource.modification || (resource.pipeline == nil && resource.error == nil) else { return resource }
        resource.modification = date; resource.compiling = true
        let device = self.device
        DispatchQueue.global(qos:.userInitiated).async { [weak resource] in
            do {
                let code = try String(contentsOfFile:path)
                let pipeline = try ShaderCompiler.compile(code,kind:node.kind,device:device)
                self.renderQueue.async { resource?.pipeline = pipeline; resource?.error = nil; resource?.compiling = false }
            } catch { self.renderQueue.async { resource?.error = error.localizedDescription; resource?.compiling = false } }
        }
        return resource
    }
}

extension Renderer {
    func dotShader(_ node: Node, geometry: Node, pattern: Node?) -> ShaderResource {
        let geometryPath = ShaderCompiler.sourceURL(geometry)!, patternPath = pattern.flatMap(ShaderCompiler.sourceURL)
        let path = geometryPath+"|"+(patternPath ?? "white")
        let resource: ShaderResource
        if let existing = shaders[node.id], existing.path == path, existing.kind == node.kind { resource = existing }
        else {
            resource = ShaderResource(path); resource.kind = node.kind
            if let previous = shaders[node.id], previous.kind == node.kind { resource.pipeline = previous.pipeline }
            shaders[node.id] = resource
        }
        let now = CACurrentMediaTime()
        guard now-resource.checked>1, !resource.compiling else { return resource }
        resource.checked = now
        let revision = ShaderCompiler.matrixRevision([geometryPath,patternPath])
        guard revision != resource.revisionKey || (resource.pipeline == nil && resource.error == nil) else { return resource }
        resource.revisionKey = revision; resource.compiling = true
        let device = self.device
        DispatchQueue.global(qos:.userInitiated).async { [weak resource] in
            do {
                let pipeline = try ShaderCompiler.dots(geometry:String(contentsOfFile:geometryPath),pattern:patternPath.map { try String(contentsOfFile:$0) },device:device)
                self.renderQueue.async { resource?.pipeline=pipeline; resource?.error=nil; resource?.compiling=false }
            } catch { self.renderQueue.async { resource?.error=error.localizedDescription; resource?.compiling=false } }
        }
        return resource
    }
}
