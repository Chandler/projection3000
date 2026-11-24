import Foundation
import Metal
import PatchCore

/// Two small textures, one texel per LED. No CPU readback or full-size simulation.
final class CellularGrid {
    private var textures: [MTLTexture] = []
    private var active = 0
    private var resetValues: [Double] = []
    private var lastTime: Double?
    private var accumulated = 0.0
    private var generation: UInt32 = 0
    private var ready = false
    var status = ""
    func encode(_ command: MTLCommandBuffer,device: MTLDevice,pipeline: MTLComputePipelineState,node: Node,columns: Int,rows: Int,time: Double) -> MTLTexture? {
        guard columns>0,rows>0,columns<=320,rows<=4096 else { status="Automata grid exceeds 320 × 4096"; return nil }
        if textures.first?.width != columns || textures.first?.height != rows {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:columns,height:rows,mipmapped:false)
            descriptor.usage=[.shaderRead,.shaderWrite]; descriptor.storageMode = .private
            textures=(0..<2).compactMap { _ in device.makeTexture(descriptor:descriptor) }; ready=false
        }
        guard textures.count==2 else { status="Cannot allocate automata grid"; return nil }
        let resets=[node.value("rule").rounded(),node.value("density"),node.value("seed").rounded(),node.value("states").rounded()]
        let reset = !ready || resetValues != resets
        let elapsed=max(0,min(0.25,time-(lastTime ?? time))); lastTime=time
        if reset { generation=0; accumulated=0; resetValues=resets }
        else { accumulated += elapsed*node.value("rate") }
        // Bound catch-up after a hidden view or a slow frame; never queue a burst.
        let steps=reset ? 1 : min(4,Int(accumulated))
        if !reset { accumulated -= floor(accumulated) }
        for _ in 0..<steps {
            guard let encoder=command.makeComputeCommandEncoder() else { return ready ? textures[active] : nil }
            let next=1-active
            var controls=[SIMD4<Float>(Float(node.value("rule").rounded()),Float(node.value("density")/100),Float(node.value("seed").rounded()),reset ? 1:0),
                          SIMD4<Float>(Float(node.value("inject")/100),Float(node.value("trail")),Float(node.value("wrap")),Float(node.value("neighbors"))),
                          SIMD4<Float>(Float(node.value("states").rounded()),Float(node.value("threshold").rounded()),Float(generation),0)]
            encoder.setComputePipelineState(pipeline); encoder.setTexture(textures[active],index:0); encoder.setTexture(textures[next],index:1)
            controls.withUnsafeMutableBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
            encoder.dispatchThreads(.init(width:columns,height:rows,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1)); encoder.endEncoding()
            active=next; ready=true; generation=(generation+1)%16000000
        }
        status="\(columns) × \(rows) cells · Generation \(generation)"
        return textures[active]
    }
}

extension Renderer {
    func cellularDomain(_ node: Node,display: Node?,displaySize: VideoDimensions?,project: VideoDimensions) -> VideoDimensions {
        let explicitWidth = Int(node.value("gridColumns").rounded())
        let explicitHeight = Int(node.value("gridRows").rounded())
        let columns = explicitWidth > 0 ? explicitWidth : display.map { Int($0.value("columns").rounded()) } ?? min(320,project.width)
        let rows: Int
        if explicitHeight > 0 { rows = explicitHeight }
        else if explicitWidth == 0, let display, display.value("grid") >= 0.5 { rows = Int(display.value("rows").rounded()) }
        else {
            let aspect = (explicitWidth == 0 ? displaySize : nil)?.aspect ?? project.aspect
            rows = max(1,min(4096,Int((Double(columns)/aspect).rounded())))
        }
        return VideoDimensions(columns,rows)
    }
    func cellularTexture(_ field: Node,columns: Int,rows: Int,command: MTLCommandBuffer) -> (MTLTexture?,String) {
        let resource=shader(field)
        guard let pipeline=resource?.pipeline else { return (nil,resource?.error ?? "Compiling cellular automata…") }
        let grid: CellularGrid
        if let existing = cellularGrids[field.id] { grid = existing }
        else { grid = CellularGrid(); cellularGrids[field.id] = grid }
        let texture=grid.encode(command,device:device,pipeline:pipeline,node:field,columns:columns,rows:rows,time:renderTime)
        return (texture,resource?.error ?? grid.status)
    }
}
