import Metal
import PatchCore

private let projectorShader="""
#include <metal_stdlib>
using namespace metal;
kernel void projector(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::write> target [[texture(1)]],constant float4 *h [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=target.get_width() || p.y>=target.get_height())return;
    float3 xy=float3((float2(p)+0.5)/float2(target.get_width(),target.get_height()),1);
    float denominator=dot(h[2].xyz,xy);
    float2 uv=float2(dot(h[0].xyz,xy),dot(h[1].xyz,xy))/denominator;
    constexpr sampler s(coord::normalized,address::clamp_to_zero,filter::linear);
    bool inside=h[2].w>0 && abs(denominator)>0.00001 && all(uv>=0) && all(uv<=1);
    target.write(inside?float4(source.sample(s,uv).rgb,1):float4(0,0,0,1),p);
}
"""
final class ProjectorRenderer {
    private let pipeline: MTLComputePipelineState
    init(device: MTLDevice) throws {
        let library=try device.makeLibrary(source:projectorShader,options:nil)
        pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"projector")!)
    }
    static func corners(_ node: Node) -> [SIMD2<Double>] { ["tl","tr","br","bl"].map { SIMD2(node.value($0+"X"),node.value($0+"Y")) } }
    static func valid(_ p: [SIMD2<Double>]) -> Bool {
        (0..<4).allSatisfy { i in
            let a=p[(i+1)%4]-p[i],b=p[(i+2)%4]-p[(i+1)%4]
            return a.x*b.y-a.y*b.x>0.00001
        }
    }
    private var cache: [UUID:([SIMD2<Double>],[SIMD4<Float>])] = [:]
    func prune(_ ids: Set<UUID>) { cache=cache.filter { ids.contains($0.key) } }
    func encode(_ source: MTLTexture,target: MTLTexture,node: Node,command: MTLCommandBuffer) -> Bool {
        let p=Self.corners(node),valid=Self.valid(p)
        if cache[node.id]?.0 != p {
            // Solve the inverse homography once per edit: screen coordinates → texture UV.
            let uv: [SIMD2<Double>]=[SIMD2(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,1)]
            var rows=[[Double]]()
            for i in 0..<4 {
                let x=p[i].x,y=p[i].y,u=uv[i].x,v=uv[i].y
                rows.append([x,y,1,0,0,0,-u*x,-u*y,u])
                rows.append([0,0,0,x,y,1,-v*x,-v*y,v])
            }
            var solved=valid
            if valid {
                for i in 0..<8 {
                    let pivot=(i..<8).max { abs(rows[$0][i])<abs(rows[$1][i]) }!
                    if abs(rows[pivot][i])<1e-10 { solved=false;break }
                    rows.swapAt(i,pivot)
                    let divisor=rows[i][i]
                    for j in i...8 { rows[i][j]/=divisor }
                    for k in 0..<8 where k != i {
                        let factor=rows[k][i]
                        for j in i...8 { rows[k][j]-=factor*rows[i][j] }
                    }
                }
            }
            let h=rows.map { Float($0[8]) }
            cache[node.id]=(p,[SIMD4(h[0],h[1],h[2],0),SIMD4(h[3],h[4],h[5],0),SIMD4(h[6],h[7],1,solved ? 1:0)])
        }
        if let encoder=command.makeComputeCommandEncoder() {
            let h=cache[node.id]!.1
            encoder.setComputePipelineState(pipeline);encoder.setTexture(source,index:0);encoder.setTexture(target,index:1)
            h.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:0) }
            encoder.dispatchThreads(.init(width:target.width,height:target.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));encoder.endEncoding()
        }
        return valid
    }
}
