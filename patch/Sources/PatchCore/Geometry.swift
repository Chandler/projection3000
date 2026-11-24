import Foundation

public enum GeometryGenerator {
    /// A contiguous line strip. The fourth component is normalized arc progression.
    /// Geometry stays independent of camera, raster size, shading and transport time.
    public static func lorenz(sigma: Double, rho: Double, beta: Double, count: Int) throws -> [SIMD4<Float>] {
        guard (1...30).contains(sigma), (1...60).contains(rho), (0.1...8).contains(beta), (1000...50000).contains(count) else { throw GraphError("Invalid Lorenz parameters") }
        var p = SIMD3<Double>(0.1, 0, 0)
        let dt = 0.005
        func derivative(_ v: SIMD3<Double>) -> SIMD3<Double> { .init(sigma*(v.y-v.x),v.x*(rho-v.z)-v.y,v.x*v.y-beta*v.z) }
        var vertices: [SIMD4<Float>] = []; vertices.reserveCapacity(count)
        for i in 0..<(count+1000) {
            let k1 = derivative(p), k2 = derivative(p+k1*(dt/2)), k3 = derivative(p+k2*(dt/2)), k4 = derivative(p+k3*dt)
            p += (k1+2*k2+2*k3+k4)*(dt/6)
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, abs(p.x)<10000, abs(p.y)<10000, abs(p.z)<10000 else { throw GraphError("Geometry diverged; reduce Lorenz parameters") }
            if i >= 1000 { vertices.append(.init(Float(p.x)*0.032,Float(p.z-25)*0.032,Float(p.y)*0.032,Float(i-1000)/Float(count-1))) }
        }
        return vertices
    }
}
