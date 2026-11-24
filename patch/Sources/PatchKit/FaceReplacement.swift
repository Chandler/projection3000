import Metal
import simd
import PatchCore

private struct FaceReplaceUniforms {
    var rowX = SIMD4<Float>(1,0,0,0)
    var rowY = SIMD4<Float>(0,1,0,0)
    var donorBounds = SIMD4<Float>(0,0,1,1)
    var controls = SIMD4<Float>(0,0.18,0,0)
}

/// Landmark-guided 2D compositing: eye centers and mouth center define an affine warp.
final class FaceReplacementRenderer {
    let pipeline: MTLComputePipelineState
    init(device: MTLDevice,library: MTLLibrary) throws {
        pipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"faceReplace")!)
    }
    private func selected(_ frame: FaceFrame?, index: Double) -> DetectedFace? {
        let faces = (frame?.faces ?? []).sorted {
            let a = $0.bounds, b = $1.bounds
            return a.width*a.height == b.width*b.height ? a.x < b.x : a.width*a.height > b.width*b.height
        }
        let i = Int(index.rounded())
        return faces.indices.contains(i) ? faces[i] : nil
    }
    private func anchors(_ face: DetectedFace) -> [SIMD2<Float>]? {
        func center(_ key: String) -> SIMD2<Float>? {
            guard let points = face.landmarks[key], !points.isEmpty else { return nil }
            return points.reduce(SIMD2<Float>.zero) { $0 + SIMD2(Float($1.x),Float($1.y)) } / Float(points.count)
        }
        guard let left = center("leftEye"), let right = center("rightEye"), let mouth = center("outerLips") else { return nil }
        // Screen order also works when either input is mirrored.
        return left.x < right.x ? [left,right,mouth] : [right,left,mouth]
    }
    func encode(a: MTLTexture,b: MTLTexture,target: MTLTexture,facesA: FaceFrame?,facesB: FaceFrame?,node: Node,command: MTLCommandBuffer) -> String {
        // A single donor broadcasts to every target, independent of saved face indices.
        let singleDonor = facesB?.faces.count == 1
        let targets = singleDonor ? (facesA?.faces ?? []) : selected(facesA,index:node.value("faceA")).map { [$0] } ?? []
        let donor = singleDonor ? facesB?.faces.first : selected(facesB,index:node.value("faceB"))
        var replacements: [FaceReplaceUniforms] = []
        var landmarkCount = 0
        if let faceB = donor {
            for faceA in targets {
                var uniforms = FaceReplaceUniforms()
                uniforms.controls.y = Float(node.value("feather"))
                let a = faceA.bounds, b = faceB.bounds
                if min(a.width,a.height,b.width,b.height) > 0.0001 {
                    // Bounds fallback for observations without usable landmarks.
                    uniforms.rowX = .init(Float(b.width/a.width),0,Float(b.x-a.x*b.width/a.width),0)
                    uniforms.rowY = .init(0,Float(b.height/a.height),Float(b.y-a.y*b.height/a.height),0)
                    if let aa = anchors(faceA), let bb = anchors(faceB) {
                        let source = simd_float3x3(columns:(SIMD3(aa[0].x,aa[0].y,1),SIMD3(aa[1].x,aa[1].y,1),SIMD3(aa[2].x,aa[2].y,1)))
                        let donor = simd_float3x3(columns:(SIMD3(bb[0].x,bb[0].y,1),SIMD3(bb[1].x,bb[1].y,1),SIMD3(bb[2].x,bb[2].y,1)))
                        if abs(simd_determinant(source)) > 0.00001 && abs(simd_determinant(donor)) > 0.00001 {
                            let map = donor * source.inverse
                            uniforms.rowX = .init(map[0][0],map[1][0],map[2][0],0)
                            uniforms.rowY = .init(map[0][1],map[1][1],map[2][1],0)
                            landmarkCount += 1
                        }
                    }
                    // Enlarge the destination about its own center before applying
                    // the inverse warp, preserving each target's pose/alignment.
                    let inverseScale = 1 / Float(node.value("scale"))
                    let center = SIMD2<Float>(Float(a.x+a.width/2),Float(a.y+a.height/2))
                    uniforms.rowX.z += (uniforms.rowX.x*center.x + uniforms.rowX.y*center.y) * (1-inverseScale)
                    uniforms.rowY.z += (uniforms.rowY.x*center.x + uniforms.rowY.y*center.y) * (1-inverseScale)
                    uniforms.rowX.x *= inverseScale; uniforms.rowX.y *= inverseScale
                    uniforms.rowY.x *= inverseScale; uniforms.rowY.y *= inverseScale
                    uniforms.donorBounds = .init(Float(b.x),Float(b.y),Float(b.width),Float(b.height))
                    uniforms.controls.x = Float(node.value("mix"))
                    replacements.append(uniforms)
                }
            }
        }
        var count = UInt32(replacements.count)
        let status = replacements.isEmpty ? "Waiting for faces A and B" :
            "Replacing \(replacements.count) face\(replacements.count == 1 ? "" : "s") · \(landmarkCount == replacements.count ? "landmark" : landmarkCount == 0 ? "bounds" : "mixed") alignment"
        // Bind a valid buffer even when there are no faces; the shader copies A unchanged.
        if replacements.isEmpty { replacements.append(FaceReplaceUniforms()) }
        guard let buffer = replacements.withUnsafeBytes({ bytes in
            pipeline.device.makeBuffer(bytes:bytes.baseAddress!,length:bytes.count,options:.storageModeShared)
        }) else { return "Cannot allocate face replacements" }
        guard let encoder = command.makeComputeCommandEncoder() else { return "Cannot encode face replacement" }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(a,index:0); encoder.setTexture(b,index:1); encoder.setTexture(target,index:2)
        encoder.setBuffer(buffer,offset:0,index:0)
        encoder.setBytes(&count,length:MemoryLayout<UInt32>.stride,index:1)
        encoder.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));encoder.endEncoding()
        return status
    }
}
