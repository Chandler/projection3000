import CoreText
import Foundation
import Metal
import OutputBridge
import PatchCore

private final class VectorArtProgram {
  private let handle: OpaquePointer
  private var outlineKey = ""
  private var outline: [Float] = []

  init(module: String) throws {
    guard let handle = module.withCString(patch_vector_create) else {
      throw GraphError("Unknown vector program " + module)
    }
    self.handle = handle
  }

  deinit { patch_vector_destroy(handle) }

  func frame(_ node: Node, width: Int, height: Int, time: Double) throws -> UnsafeBufferPointer<
    PatchStrokeSegment
  > {
    let size = Float(height)
    let aspect = Float(height) / Float(width)
    func p(_ key: String) -> Float { Float(node.value(key)) }
    func rgb(_ key: String) -> [Float] {
      let c = UInt32(node.value(key))
      return [Float((c >> 16) & 255) / 255, Float((c >> 8) & 255) / 255, Float(c & 255) / 255]
    }
    var args: [Float]
    switch node.kind {
    case .vectorCube:
      args = ["speed", "rotate_x", "rotate_y", "rotate_z", "projection", "size"].map(p)
      args += rgb("glow") + [p("line_width") / size, p("glow_width") / size, aspect]
      args += ["pose_x", "pose_y", "pose_z"].map { p($0) * .pi / 180 }
    case .laserLettering:
      let key = String(Int(p("font"))) + "\n" + (node.text ?? "YOUR NAME")
      if outlineKey != key {
        let fonts = [
          "ArchivoBlack", "BebasNeue", "Bungee", "DMSerifDisplay", "Lobster", "Pacifico",
          "PermanentMarker", "SpecialElite", "Monoton", "PressStart2P",
        ]
        let file = fonts[min(fonts.count - 1, max(0, Int(p("font"))))]
        let roots = [
          Bundle.main.resourceURL?.appendingPathComponent("fonts"),
          URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
              "vj/static/fonts"),
        ]
        guard
          let url = roots.compactMap({ $0?.appendingPathComponent(file + ".ttf") }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
          }),
          let provider = CGDataProvider(url: url as CFURL), let graphic = CGFont(provider)
        else { throw GraphError("Missing vector font " + file) }
        let font = CTFontCreateWithGraphicsFont(graphic, 96, nil, nil)
        let lines = VectorTextGeometry.make(node, font: font).contours
        var stream: [Float] = []
        for line in lines {
          guard stream.count / 3 + line.count <= 10000 else {
            throw GraphError("Text outline exceeds 10000 points")
          }
          for (i, point) in line.enumerated() { stream += [i == 0 ? 2 : 3, point.x, -point.y] }
        }
        outline = [Float(stream.count / 3)] + stream
        outlineKey = key
      }
      args = rgb("color") + [p("line_width") / size, p("glow_width") / size]
      args += ["brightness", "size", "x", "y", "pulse", "speed"].map(p) + [aspect] + outline
    case .lightningCellGrid:
      args = [
        "rate", "burst", "speed", "jitter", "length", "tail", "crackle", "forks", "top_spray",
        "brightness",
      ].map(p)
      args += rgb("core") + rgb("glow") + [p("rainbow"), p("origin")]
    case .vectorScanLines:
      args = [p("angle") * .pi / 180] + ["rate", "spacing", "width", "blur"].map { p($0) / size }
      args +=
        [p("amount"), p("wave") / size, p("wave_frequency"), p("pulse")] + rgb("tint") + rgb("glow")
        + [aspect]
    case .vectorLorenz:
      args = [
        p("speed"), p("length"), p("zoom"), p("rotation") * (p("rotation_direction") > 0 ? -1 : 1),
        p("tilt") * .pi / 180, p("line_width") / size, p("brightness"),
      ]
      args += rgb("color") + [p("seed"), aspect]
    case .slimeMold:
      args = ["seed", "density", "branching", "x", "y"].map(p)
      args +=
        [p("line_width") / size, p("pulse"), p("speed"), p("pulse_length")] + rgb("color") + [
          aspect
        ]
    default: throw GraphError("Unknown vector program")
    }
    let beat = node.kind == .vectorScanLines ? time * node.value("tempo") / 60 : 0
    return args.withUnsafeBufferPointer { values in
      var count = 0
      let result = patch_vector_frame(
        handle, values.baseAddress, values.count, time, beat, &count)
      return UnsafeBufferPointer(start: result, count: count)
    }
  }
}

final class VectorArtRenderer {
  private let device: MTLDevice
  private let pipeline: MTLRenderPipelineState
  private var programs: [UUID: VectorArtProgram] = [:]
  private var moduleNames: [UUID: String] = [:]
  init(device: MTLDevice, library: MTLLibrary) throws {
    self.device = device
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "vectorArtVertex")
    d.fragmentFunction = library.makeFunction(name: "vectorArtFragment")
    let a = d.colorAttachments[0]!
    a.pixelFormat = .bgra8Unorm
    a.isBlendingEnabled = true
    a.sourceRGBBlendFactor = .one
    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
    a.sourceAlphaBlendFactor = .one
    a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    pipeline = try device.makeRenderPipelineState(descriptor: d)
  }
  func prune(_ ids: Set<UUID>) {
    programs = programs.filter { ids.contains($0.key) }
    moduleNames = moduleNames.filter { ids.contains($0.key) }
  }
  func render(
    _ node: Node, target: MTLTexture, command: MTLCommandBuffer, time: Double, wantRaster: Bool,
    wantPath: Bool
  ) throws -> VectorPath? {
    guard let module = node.kind.vectorArtModule else { throw GraphError("Unknown vector program") }
    if moduleNames[node.id] != module {
      programs[node.id] = try VectorArtProgram(module: module)
      moduleNames[node.id] = module
    }
    let lines = try programs[node.id]!.frame(
      node, width: target.width, height: target.height, time: time)
    if wantRaster {
      let pass = MTLRenderPassDescriptor()
      let a = pass.colorAttachments[0]!
      a.texture = target
      a.loadAction = .clear
      a.storeAction = .store
      a.clearColor = MTLClearColorMake(0, 0, 0, 0)
      if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
        defer { encoder.endEncoding() }
        if !lines.isEmpty,
          let buffer = device.makeBuffer(
            bytes: lines.baseAddress!,
            length: lines.count * MemoryLayout<PatchStrokeSegment>.stride,
            options: .storageModeShared)
        {
          var size = SIMD4<Float>(
            Float(target.width), Float(target.height),
            module == "electric-strips" || module == "vector-scan-lines" ? 1 : 0, Float(lines.count)
          )
          encoder.setRenderPipelineState(pipeline)
          encoder.setVertexBuffer(buffer, offset: 0, index: 0)
          encoder.setVertexBytes(&size, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
          for layer in [0, 1] {
            var index = Int32(layer)
            encoder.setFragmentBytes(&index, length: 4, index: 0)
            encoder.drawPrimitives(
              type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lines.count)
          }
        }
      }
    }
    guard wantPath else { return nil }
    var points: [SIMD2<Float>] = []
    var travel = Set<Int>()
    func xy(_ v: PatchStrokeVertex) -> SIMD2<Float> {
      .init(max(-1, min(1, 2 * v.pointWidth.x - 1)), max(-1, min(1, 1 - 2 * v.pointWidth.y)))
    }
    for line in lines {
      let a = xy(line.a)
      let b = xy(line.b)
      if points.last != a {
        if !points.isEmpty { travel.insert(points.count - 1) }
        points.append(a)
      }
      points.append(b)
    }
    if !points.isEmpty { travel.insert(points.count - 1) }
    return VectorPath(vertices: points, samples: 4096, travelEdges: travel, travelSpeed: 16)
  }
}
