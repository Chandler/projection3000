import Foundation
import Metal
import QuartzCore
import PatchCore

/// Shared by preflight and live reload so a successful preflight uses the exact runtime ABI.
enum ShaderCompiler {
    static func sourceURL(_ node: Node) -> String? {
        if node.kind == .flashCells { return FlashCellsField.path }
        if node.kind == .streakGlow { return GlowField.path }
        if let file = node.file {
            let prefix = "bundle:User Nodes/"
            if file.hasPrefix(prefix) {
                let relative = String(file.dropFirst(prefix.count))
                guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator:"/").contains("..") else { return nil }
                return UserNodeLibrary.bundledDirectory?.appendingPathComponent(relative).path
            }
            if FileManager.default.fileExists(atPath:file) { return file }
            // Saved projects can reference the other application's built-in library.
            // Rebase only that explicit bundle-relative namespace, never external
            // user shaders (whose identical effect.metal basenames are ambiguous).
            if let range = file.range(of:"/Contents/Resources/User Nodes/"),
               let bundled = UserNodeLibrary.bundledDirectory?.appendingPathComponent(String(file[range.upperBound...])),
               FileManager.default.fileExists(atPath:bundled.path) { return bundled.path }
            return file
        }
        switch node.kind {
        case .meshGradient: return UserNodeLibrary.meshGradientURL.path
        case .dotColors: return UserNodeLibrary.dotColorsURL.path
        case .flipDots: return UserNodeLibrary.flipDotsURL.path
        case .projectionDots: return UserNodeLibrary.projectionDotsURL.path
        case .scene: return UserNodeLibrary.pastelURL.path
        case .cellularField: return UserNodeLibrary.cellularFieldURL.path
        case .waterfallField: return UserNodeLibrary.waterfallFieldURL.path
        case .streakField: return UserNodeLibrary.streakFieldURL.path
        case .blockerField: return UserNodeLibrary.blockerFieldURL.path
        case .dataStream: return UserNodeLibrary.dataStreamURL.path
        default: return nil
        }
    }
    static func compile(_ code: String, kind: NodeKind, device: MTLDevice) throws -> MTLComputePipelineState {
        if kind == .projectionDots { return try dots(geometry:code,pattern:nil,device:device) }
        if kind.outputType == .dots { return try dots(geometry:String(contentsOf:UserNodeLibrary.projectionDotsURL),pattern:code,device:device) }
        if kind == .cellularField { return try pipeline(code,function:"cellularStep",device:device) }
        if kind.outputType == .field { return try matrix(primary:code,light:nil,device:device) }
        let call = kind == .meshGradient ? "meshGradient(uv,time,controls,float(output.get_width())/float(output.get_height()))" : kind == .projectionDots ? "animation(uv,time,controls,float2(output.get_width(),output.get_height()))" : kind == .scene ? "animation(uv,time,controls[0],controls[1],float(output.get_width())/float(output.get_height()))" : "animation(uv,time)"
        let signature = kind == .shaderEffect ? ", texture2d<float, access::sample> input [[texture(1)]], texture2d<float, access::sample> patchAux [[texture(2)]]" : ""
        let value = kind == .shaderEffect ? "(PATCH_EFFECT_MIX(controls) >= 1.0 ? PATCH_EFFECT(uv,time,input,controls) : mix(input.sample(patchSampler,uv).rgb,PATCH_EFFECT(uv,time,input,controls),PATCH_EFFECT_MIX(controls)))" : call
        let wrapper = """
        #include <metal_stdlib>
        using namespace metal;
        #define PATCH_BLINDS_CONTROLS_VERSION 2
        #define PATCH_MESH_CONTROLS_VERSION 2
        #define PATCH_LIQUID_METAL_CONTROLS_VERSION 5
        #define PATCH_LIQUID_CHROME_CONTROLS_VERSION 3
        #define PATCH_FERROFLUID_CONTROLS_VERSION 1
        \(code)
        #ifndef PATCH_EFFECT
        #define PATCH_EFFECT(uv,t,input,c) effect(uv,t,input,(c)[0])
        #endif
        #ifndef PATCH_EFFECT_MIX
        #define PATCH_EFFECT_MIX(c) ((c)[1].x)
        #endif
        kernel void customAnimation(texture2d<float, access::write> output [[texture(0)]]\(signature), constant float &time [[buffer(0)]], constant float4 *controls [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            constexpr sampler patchSampler(coord::normalized,address::clamp_to_edge,filter::linear);
            float2 uv = (float2(gid)+0.5)/float2(output.get_width(),output.get_height());
            #if defined(PATCH_EFFECT_RGBA_AUX)
            output.write(clamp(PATCH_EFFECT_RGBA_AUX(uv,time,input,patchAux,controls),0.0,1.0),gid);
            #elif defined(PATCH_EFFECT_RGBA)
            output.write(clamp(PATCH_EFFECT_RGBA(uv,time,input,controls),0.0,1.0),gid);
            #else
            output.write(float4(clamp(\(value),0.0,1.0),1),gid);
            #endif
        }
        """
        return try pipeline(wrapper,function:"customAnimation",device:device)
    }
    static func dotNodes(_ node: Node, graph: Graph) -> (geometry: Node, pattern: Node?) {
        if node.kind.outputType == .dots { return (graph.dotPreviewGeometry(node.id),node.enabled ? node : nil) }
        let pattern = graph.edges.first { $0.target == node.id && $0.input == 0 }.flatMap { graph.node($0.source) }
        return (node,pattern?.enabled == true ? pattern : nil)
    }
    static func dots(geometry: String, pattern: String?, device: MTLDevice) throws -> MTLComputePipelineState {
        let source = pattern ?? "float4 dotPattern(float2 cell,float2 grid,float time,constant float4 *c,constant uint *text) { return float4(1); }"
        let wrapper = """
        #include <metal_stdlib>
        using namespace metal;
        namespace dotSource {
        \(source)
        }
        \(geometry)
        kernel void customAnimation(texture2d<float, access::write> output [[texture(0)]],
            constant float &time [[buffer(0)]],constant float4 *geometry [[buffer(1)]],
            constant float4 *controls [[buffer(2)]],constant uint *messages [[buffer(3)]],
            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x>=output.get_width() || gid.y>=output.get_height()) return;
            float2 resolution=float2(output.get_width(),output.get_height());
            float2 uv=(float2(gid)+0.5f)/resolution;
            output.write(float4(projectionDots(uv,time,geometry,resolution,controls,messages),1),gid);
        }
        """
        return try pipeline(wrapper,function:"customAnimation",device:device)
    }
    static func matrix(primary: String?, light: String?, primaryCells: Bool = false, lightCells: Bool = false, lightTexture: Bool = false, device: MTLDevice) throws -> MTLComputePipelineState {
        let url = try PatchResources.shaderURL()
        var code = "#include <metal_stdlib>\nusing namespace metal;\n"
        if primary?.contains("PATCH_FLASH_CELLS") == true { code += "#define MATRIX_FLASH_PRIMARY 1\n" }
        if light?.contains("PATCH_FLASH_CELLS") == true { code += "#define MATRIX_FLASH_LIGHT 1\n" }
        if primaryCells { code += "#define MATRIX_CELL_FIELD 1\n" }
        else if let primary { code += "namespace matrixDriver {\n"+primary+"\n}\n#define MATRIX_FIELD 1\n" }
        if lightTexture { code += "#define MATRIX_TEXTURE_LIGHT 1\n" }
        if lightCells { code += "#define MATRIX_CELL_LIGHT 1\n" }
        else if let light { code += "namespace matrixLight {\n"+light+"\n}\n#define MATRIX_LIGHT 1\n" }
        code += try String(contentsOf:url)
        return try pipeline(code,function:"process",device:device)
    }
    static func lightPreview(light: String, device: MTLDevice) throws -> MTLComputePipelineState {
        let code = "#include <metal_stdlib>\nusing namespace metal;\nnamespace matrixLight {\n"+light+"\n}\n#define MATRIX_LIGHT 1\n"+(try String(contentsOf:PatchResources.shaderURL()))
        return try pipeline(code,function:"lightPreview",device:device)
    }
    static func pipeline(_ source: String, function: String, device: MTLDevice) throws -> MTLComputePipelineState {
        let library = try device.makeLibrary(source:source,options:nil)
        guard let function = library.makeFunction(name:function) else { throw GraphError("Missing shader entry point") }
        return try device.makeComputePipelineState(function:function)
    }
    static func matrixRevision(_ paths: [String?]) -> String {
        paths.map { path in
            guard let path else { return "none" }
            let date = (try? FileManager.default.attributesOfItem(atPath:path)[.modificationDate]) as? Date
            return date.map { String($0.timeIntervalSinceReferenceDate) } ?? "missing"
        }.joined(separator:"|")
    }
    /// Compile every custom shader and every combined signal/light matrix before graph attachment.
    static func prepare(_ graph: Graph, device: MTLDevice) throws -> [UUID:ShaderResource] {
        var result: [UUID:ShaderResource] = [:]
        for node in graph.nodes where [.meshGradient,.shader,.scene,.shaderEffect,.cellularField].contains(node.kind) {
            guard let path = sourceURL(node) else { throw GraphError("\(node.name): no shader selected") }
            let resource = ShaderResource(path); resource.kind = node.kind
            resource.pipeline = try compile(String(contentsOfFile:path),kind:node.kind,device:device)
            resource.modification = (try FileManager.default.attributesOfItem(atPath:path)[.modificationDate]) as? Date
            resource.checked = CACurrentMediaTime(); result[node.id] = resource
        }
        for node in graph.nodes where node.kind == .projectionDots || node.kind.outputType == .dots {
            let pair = dotNodes(node,graph:graph)
            let geometryPath = sourceURL(pair.geometry)!, patternPath = pair.pattern.flatMap(sourceURL)
            let resource = ShaderResource(geometryPath+"|"+(patternPath ?? "white")); resource.kind = node.kind
            resource.pipeline = try dots(geometry:String(contentsOfFile:geometryPath),pattern:patternPath.map { try String(contentsOfFile:$0) },device:device)
            resource.revisionKey = matrixRevision([geometryPath,patternPath]); resource.checked = CACurrentMediaTime()
            result[node.id] = resource
        }
        // Compile standalone custom producers even when a branch has no consumer yet.
        for node in graph.nodes where node.kind == .fieldShader {
            guard let input = FieldInput(producer:node) else { throw GraphError("\(node.name): choose a Metal field shader.") }
            let program = FieldProgram(primary:input,secondary:nil)
            let resource = ShaderResource("field")
            resource.fieldProgram = program
            resource.pipeline = try program.compile(device:device)
            resource.revisionKey = program.revision; resource.checked = CACurrentMediaTime()
            result[node.id] = resource
        }
        for node in graph.nodes where [.ledMatrix,.fieldRender,.fieldMix].contains(node.kind) {
            func field(_ index: Int) -> Node? {
                graph.edges.first { $0.target == node.id && $0.input == index }.flatMap { graph.node($0.source) }.flatMap { $0.enabled ? $0 : nil }
            }
            let a = field(node.kind == .ledMatrix ? 1 : 0), b = field(node.kind == .ledMatrix ? 2 : 1)
            guard a != nil || b != nil else { continue }
            let program = FieldProgram(primary:a.flatMap(FieldInput.init(producer:)),secondary:b.flatMap(FieldInput.init(producer:)))
            let resource = ShaderResource("field")
            resource.fieldProgram = program
            resource.pipeline = try program.compile(device:device)
            resource.revisionKey = program.revision; resource.checked = CACurrentMediaTime()
            result[node.id] = resource
        }
        return result
    }
}
