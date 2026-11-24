import Foundation
import simd
import Accelerate

/// Physical liquid generation for Liquid Chrome, solved once per shape on the CPU:
///  1. the seeded composition (pools, threads, drips) gives an initial liquid mask;
///  2. Cahn–Hilliard phase separation lets surface tension decide the final form —
///     interfaces round off, wide pools break into lace with holes, thin drips bead
///     and pinch off (semi-implicit spectral solve, Accelerate FFT);
///  3. a pressurized membrane, after Paper Shaders' Liquid Metal
///     (github.com/paper-design/shaders, Apache-2.0): ∇²u = −1 inside, u = 0 on the
///     edge. √(2u) is exactly round across any thread and domed over any pool.
extension LiquidChromeStyle {
    /// Only these keys move the liquid; lighting edits reuse the cached solve.
    public static let shapeKeys = ["method","seed","nodes","holes","pool","spread","viscosity","threads","drips","dripLength"]
    public static func shapeKey(_ node: Node, aspect: Double) -> [Double] { shapeKeys.map { node.value($0) } + [aspect] }

    struct FieldPrimitive { var segment: Segment?; var circle: Circle?; var center: SIMD2<Double>; var reach: Double }

    /// Quadratic Bézier distance (Quílez), matching `lcBezier` in LiquidChrome.metal.
    static func bezier(_ pos: SIMD2<Double>,_ A: SIMD2<Double>,_ B: SIMD2<Double>,_ C: SIMD2<Double>) -> (Double,Double) {
        let a=B-A, b=A-2*B+C, c=a*2, d=A-pos
        let kk=1/max(simd_dot(b,b),1e-12)
        let kx=kk*simd_dot(a,b), ky=kk*(2*simd_dot(a,a)+simd_dot(d,b))/3, kz=kk*simd_dot(d,a)
        let p=ky-kx*kx, q=kx*(2*kx*kx-3*ky)+kz
        var h=q*q+4*p*p*p
        func point(_ t: Double) -> Double { simd_length(d+(c+b*t)*t) }
        if h >= 0 {
            h=sqrt(h)
            let x=SIMD2((h-q)/2,(-h-q)/2)
            let t=min(max(cbrt(x.x)+cbrt(x.y)-kx,0),1)
            return (point(t),t)
        }
        let z=sqrt(-p), v=acos(min(max(q/(p*z*2),-1),1))/3
        let m=cos(v), n=sin(v)*1.732050808
        let t0=min(max((m+m)*z-kx,0),1), t1=min(max((-n-m)*z-kx,0),1)
        let d0=point(t0), d1=point(t1)
        return d0 < d1 ? (d0,t0) : (d1,t1)
    }

    /// Mirror of `lcField`: viscous union of threads, drips and pools.
    static func fieldDistance(_ p: SIMD2<Double>,_ primitives: [FieldPrimitive],k: Double) -> Double {
        var d=10.0
        func union(_ b: Double,_ k: Double) {
            let h=min(max(0.5+0.5*(b-d)/k,0),1)
            d=b+(d-b)*h-k*h*(1-h)
        }
        for primitive in primitives {
            if simd_length(p-primitive.center)-primitive.reach > d+k { continue }
            if let s=primitive.segment {
                let (distance,t)=bezier(p,s.a,s.control,s.b)
                var radius=s.ra+(s.rb-s.ra)*t
                if s.neck >= 0 { radius *= 1-s.neck*pow(4*t*(1-t),0.55) }
                else { radius *= 1+0.42*t*max(0,sin(t*floor(-s.neck)*2*Double.pi-1.2)) }
                union(distance-radius,s.neck > 0 ? k : k*0.4)
            } else if let circle=primitive.circle {
                union(simd_length(p-circle.center)-circle.radius,k*0.8)
            }
        }
        return d
    }

    /// Interleaved (thickness √(2u) in poster units, phase φ ∈ [−1,1]) per texel,
    /// rows top to bottom, spanning x ∈ [−aspect, aspect], y ∈ [1, −1].
    public static func pour(_ node: Node, aspect: Double) -> (width: Int, height: Int, values: [Float]) {
        // Power-of-two grid for the 2D FFT, long side 1024, matched to the frame.
        let landscape = aspect >= 1
        let ratio = landscape ? aspect : 1/aspect
        let short = 1 << max(6,min(10,Int((log2(1024/ratio)).rounded())))
        let width = landscape ? 1024 : short, height = landscape ? short : 1024
        let lx = 2*aspect, ly = 2.0
        let dx = lx/Double(width), dy = ly/Double(height)

        let shape = geometry(node,aspect:aspect)
        var primitives = shape.segments.map { s -> FieldPrimitive in
            let center=(s.a+s.control+s.b)/3
            let reach=max(simd_length(s.a-center),simd_length(s.b-center),simd_length(s.control-center))+max(s.ra,s.rb)*1.5
            return FieldPrimitive(segment:s,circle:nil,center:center,reach:reach)
        }
        primitives += shape.circles.map { FieldPrimitive(segment:nil,circle:$0,center:$0.center,reach:$0.radius) }
        let k = 0.015+node.value("viscosity")*0.17

        // 1. Initial condition: sharp liquid where the composition is thin, a noisy
        //    mixture deep inside wide pools so they can separate into lace.
        // A thin interface keeps threads alive; hole size comes from smooth seeded
        // noise instead of ε, so the two scales are independent.
        let spread = max(0.6,node.value("spread"))
        let epsilon = 0.0032*spread
        let lace = max(0,min(8,node.value("holes")))/8
        let mean = 0.6-0.5*lace
        var random = Random(state:UInt64(max(0,node.value("seed")))&*0x2545F4914F6CDD1D &+ 99)
        let cell = 0.1*spread
        let columns = Int(lx/cell)+3, rows = Int(ly/cell)+3
        let lattice = (0..<(columns*rows)).map { _ in random.next()*2-1 }
        func smoothNoise(_ p: SIMD2<Double>) -> Double {
            let q = SIMD2((p.x+aspect)/cell,(1-p.y)/cell)
            let i = Int(floor(q.x)), j = Int(floor(q.y)), f = q-SIMD2(Double(i),Double(j))
            let s = f*f*(3-2*f)
            func at(_ x: Int,_ y: Int) -> Double { lattice[max(0,min(rows-1,y))*columns+max(0,min(columns-1,x))] }
            let top = at(i,j)+(at(i+1,j)-at(i,j))*s.x, bottom = at(i,j+1)+(at(i+1,j+1)-at(i,j+1))*s.x
            return top+(bottom-top)*s.y
        }
        let method = LiquidChromeStyle.method(node)
        func point(_ x: Int,_ y: Int) -> SIMD2<Double> { SIMD2((Double(x)+0.5)*dx-aspect,1-(Double(y)+0.5)*dy) }
        // Composition distance per texel, shared by the composition-based methods.
        var composition = [Double](repeating:10,count:width*height)
        if method != .sheet {
            composition.withUnsafeMutableBufferPointer { buffer in
                let out = buffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations:height) { y in
                    for x in 0..<width { out[y*width+x] = fieldDistance(point(x,y),primitives,k:k) }
                }
            }
        }
        var phi = [Float](repeating:-1,count:width*height)
        switch method {
        case .pour, .balloon, .ferrofluid:
            // Sharp liquid where the composition is thin, a noisy mixture deep
            // inside wide pools so phase separation can open them into lace.
            for y in 0..<height { for x in 0..<width {
                let d = composition[y*width+x]
                let sharp = tanh(-d/(sqrt(2)*epsilon))
                let mixing = (method == .ferrofluid ? lace*0.4 : lace)*smoothstep(0.03,0.09,max(-d,0))
                phi[y*width+x] = Float(sharp+(mean+0.75*smoothNoise(point(x,y))-sharp)*mixing)
            } }
        case .sheet:
            // One continuous sheet across the frame, torn by noise into lace.
            for y in 0..<height { for x in 0..<width {
                let p = point(x,y)
                let extent = SIMD2(p.x/(aspect*0.98),p.y/0.62*(1+0.25*abs(p.x)/aspect))
                let inside = 1-smoothstep(0.85,1.0,simd_length(extent*SIMD2(0.75,1)))
                // Broad, few tears: the noise is sampled at roughly half the pool scale.
                let torn = mean-0.3+1.05*smoothNoise(p*0.42)
                phi[y*width+x] = Float(-1+(torn+1)*inside)
            } }
        case .coral:
            phi = coral(node,composition:composition,width:width,height:height,random:&random)
        case .swarm:
            phi = swarm(node,composition:composition,width:width,height:height,aspect:aspect,random:&random)
        }

        // 2. Cahn–Hilliard, ∂φ/∂t = ∇²(φ³ − φ − ε²∇²φ), stabilized semi-implicit:
        //    φ̂ₙ₊₁ = [φ̂ₙ(1 + Δt·s·k²) − Δt·k²·N̂ₙ] / (1 + Δt·s·k² + Δt·ε²·k⁴), N = φ³ − φ.
        // Settling time in units of the interface time ε²: viscosity lets it relax longer.
        let total = (method == .coral || method == .swarm ? 30+node.value("viscosity")*300 : 60+node.value("viscosity")*900)*epsilon*epsilon
        let steps = 140
        let dt = total/Double(steps), stabilizer = 2.0
        let count = width*height
        var k2 = [Float](repeating:0,count:count)
        for y in 0..<height {
            let ny = y <= height/2 ? y : y-height
            let ky = 2*Double.pi*Double(ny)/ly
            for x in 0..<width {
                let nx = x <= width/2 ? x : x-width
                let kx = 2*Double.pi*Double(nx)/lx
                k2[y*width+x] = Float(kx*kx+ky*ky)
            }
        }
        let numerator = k2.map { Float(1+dt*stabilizer*Double($0)) }
        let denominator = k2.map { Float(1+dt*stabilizer*Double($0)+dt*epsilon*epsilon*Double($0)*Double($0)) }
        let log2w = vDSP_Length(log2(Double(width))), log2h = vDSP_Length(log2(Double(height)))
        if let setup = vDSP_create_fftsetup(max(log2w,log2h),FFTRadix(kFFTRadix2)) {
            var phiR = phi, phiI = [Float](repeating:0,count:count)
            var nR = [Float](repeating:0,count:count), nI = [Float](repeating:0,count:count)
            func transform(_ real: inout [Float],_ imag: inout [Float],_ direction: FFTDirection) {
                real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp:r.baseAddress!,imagp:i.baseAddress!)
                    vDSP_fft2d_zip(setup,&split,1,0,log2w,log2h,direction)
                } }
            }
            transform(&phiR,&phiI,FFTDirection(kFFTDirection_Forward))
            var field = phi
            let scale = 1/Float(count)
            for _ in 0..<steps {
                for i in 0..<count { let v = field[i]; nR[i] = v*v*v-v; nI[i] = 0 }
                transform(&nR,&nI,FFTDirection(kFFTDirection_Forward))
                let dtf = Float(dt)
                for i in 0..<count {
                    phiR[i] = (phiR[i]*numerator[i]-dtf*k2[i]*nR[i])/denominator[i]
                    phiI[i] = (phiI[i]*numerator[i]-dtf*k2[i]*nI[i])/denominator[i]
                }
                var backR = phiR, backI = phiI
                transform(&backR,&backI,FFTDirection(kFFTDirection_Inverse))
                for i in 0..<count { field[i] = backR[i]*scale }
            }
            vDSP_destroy_fftsetup(setup)
            phi = field
        }

        // 3. Membrane on the settled liquid, coarse to fine (red-black SOR, ω = 1.9).
        var u: [Double] = []
        var previous: (Int,Int)?
        for level in [4,2,1] {
            let w = width/level, h = height/level
            var mask = [UInt8](repeating:0,count:w*h)
            for y in 0..<h { for x in 0..<w {
                var sum: Float = 0
                for j in 0..<level { for i in 0..<level { sum += phi[(y*level+j)*width+x*level+i] } }
                mask[y*w+x] = sum > 0 ? 1:0
            } }
            var next = [Double](repeating:0,count:w*h)
            if let (pw,ph) = previous {
                for y in 0..<h { for x in 0..<w where mask[y*w+x] != 0 { next[y*w+x] = u[min(ph-1,y/2)*pw+min(pw-1,x/2)] } }
            }
            let hx = dx*Double(level), hy = dy*Double(level)
            let ax = 1/(hx*hx), ay = 1/(hy*hy), diagonal = 2*ax+2*ay, omega = 1.9
            let iterations = level == 4 ? 120 : level == 2 ? 80 : 60
            next.withUnsafeMutableBufferPointer { buffer in
                let value = buffer.baseAddress!
                mask.withUnsafeBufferPointer { maskBuffer in
                    let inside = maskBuffer.baseAddress!
                    for _ in 0..<iterations { for color in 0..<2 {
                        DispatchQueue.concurrentPerform(iterations:h) { y in
                            var x = (y+color)&1
                            while x < w {
                                let index = y*w+x
                                if inside[index] != 0 {
                                    let east = x < w-1 ? value[index+1]:0, west = x > 0 ? value[index-1]:0
                                    let north = y > 0 ? value[index-w]:0, south = y < h-1 ? value[index+w]:0
                                    value[index] = omega*((east+west)*ax+(north+south)*ay+1)/diagonal+(1-omega)*value[index]
                                }
                                x += 2
                            }
                        }
                    } }
                }
            }
            u = next; previous = (w,h)
        }
        var thickness = u.map { sqrt(2*max($0,0)) }
        if method == .ferrofluid { addSpikes(node,&thickness,width:width,height:height,aspect:aspect) }
        var values = [Float](repeating:0,count:count*2)
        for i in 0..<count {
            values[i*2] = Float(thickness[i])
            values[i*2+1] = max(-1,min(1,phi[i]))
        }
        return (width,height,values)
    }
}

extension LiquidChromeStyle {
    /// Gray–Scott reaction–diffusion inside the composition: Holes moves the
    /// pattern from isolated spots (low feed) to coral worms and mazes.
    static func coral(_ node: Node,composition: [Double],width: Int,height: Int,random: inout Random) -> [Float] {
        let w = width/2, h = height/2, count = w*h
        let pattern = max(0,min(8,node.value("holes")))/8
        let feed = 0.03+0.026*pattern, kill = 0.062+0.003*pattern
        var a = [Float](repeating:1,count:count), b = [Float](repeating:0,count:count)
        var region = [UInt8](repeating:0,count:count)
        for y in 0..<h { for x in 0..<w {
            let d = composition[(y*2)*width+x*2]
            region[y*w+x] = d < 0.01 ? 1:0
            if d < 0 && random.next() < 0.04 { b[y*w+x] = 1; a[y*w+x] = 0.5 }
        } }
        var na = a, nb = b
        for _ in 0..<5000 {
            a.withUnsafeBufferPointer { ap in b.withUnsafeBufferPointer { bp in na.withUnsafeMutableBufferPointer { nap in nb.withUnsafeMutableBufferPointer { nbp in
                let A = ap.baseAddress!, B = bp.baseAddress!, NA = nap.baseAddress!, NB = nbp.baseAddress!
                DispatchQueue.concurrentPerform(iterations:h) { y in
                    let up = max(0,y-1)*w, down = min(h-1,y+1)*w, row = y*w
                    for x in 0..<w {
                        let i = row+x
                        if region[i] == 0 { NA[i] = 1; NB[i] = 0; continue }
                        let left = row+max(0,x-1), right = row+min(w-1,x+1)
                        let la = A[left]+A[right]+A[up+x]+A[down+x]-4*A[i]
                        let lb = B[left]+B[right]+B[up+x]+B[down+x]-4*B[i]
                        let reaction = A[i]*B[i]*B[i]
                        NA[i] = A[i]+(0.2097*la-reaction+Float(feed)*(1-A[i]))
                        NB[i] = B[i]+(0.105*lb+reaction-Float(feed+kill)*B[i])
                    }
                }
            } } } }
            swap(&a,&na); swap(&b,&nb)
        }
        // Upsample; the inhibitor-rich phase becomes liquid.
        var phi = [Float](repeating:-1,count:width*height)
        for y in 0..<height { for x in 0..<width {
            let fx = min(Float(w-1),max(0,(Float(x)+0.5)/2-0.5)), fy = min(Float(h-1),max(0,(Float(y)+0.5)/2-0.5))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(x0+1,w-1), y1 = min(y0+1,h-1), tx = fx-Float(x0), ty = fy-Float(y0)
            let v = (b[y0*w+x0]*(1-tx)+b[y0*w+x1]*tx)*(1-ty)+(b[y1*w+x0]*(1-tx)+b[y1*w+x1]*tx)*ty
            phi[y*width+x] = tanh((v-0.2)*14)
        } }
        return phi
    }

    /// A cohesive particle liquid: short-range repulsion, longer-range attraction
    /// (surface tension) and gravity, then splatted to a metaball field.
    static func swarm(_ node: Node,composition: [Double],width: Int,height: Int,aspect: Double,random: inout Random) -> [Float] {
        let spread = max(0.6,node.value("spread"))
        let count = 240+Int(node.value("nodes"))*70
        let radius = 0.05*spread, rest = radius*0.55
        var positions: [SIMD2<Double>] = []
        let dx = 2*aspect/Double(width), dy = 2/Double(height)
        var attempts = 0
        while positions.count < count && attempts < 200000 {
            attempts += 1
            let x = Int(random.next()*Double(width)), y = Int(random.next()*Double(height))
            if composition[y*width+x] < 0 { positions.append(SIMD2((Double(x)+0.5)*dx-aspect,1-(Double(y)+0.5)*dy)) }
        }
        var velocities = [SIMD2<Double>](repeating:.zero,count:positions.count)
        let gravity = 0.01+0.06*node.value("drips")/14*(0.4+node.value("dripLength"))
        let cohesion = 0.6+1.4*node.value("viscosity")
        let dt = 0.012
        for _ in 0..<260 {
            var forces = [SIMD2<Double>](repeating:.zero,count:positions.count)
            let snapshot = positions
            forces.withUnsafeMutableBufferPointer { buffer in
                let out = buffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations:snapshot.count) { i in
                    var f = SIMD2(0.0,-gravity)
                    for j in snapshot.indices where j != i {
                        let delta = snapshot[j]-snapshot[i], distance = simd_length(delta)
                        guard distance < radius, distance > 1e-6 else { continue }
                        let direction = delta/distance
                        let strength: Double
                        if distance < rest { strength = -(rest-distance)/rest*6 }
                        else { let band = (distance-rest)/(radius-rest); strength = cohesion*band*(1-band) }
                        f += direction*strength
                    }
                    out[i] = f
                }
            }
            for i in positions.indices {
                velocities[i] = (velocities[i]+forces[i]*dt)*0.96
                positions[i] += velocities[i]*dt
                positions[i].y = max(-0.97,positions[i].y)
            }
        }
        // Metaball splat, then a sharp tanh interface for the phase solver.
        var field = [Double](repeating:0,count:width*height)
        let blob = radius*0.75, reachX = Int(blob*2/dx)+1, reachY = Int(blob*2/dy)+1
        for p in positions {
            let cx = Int((p.x+aspect)/dx), cy = Int((1-p.y)/dy)
            for y in max(0,cy-reachY)...min(height-1,cy+reachY) { for x in max(0,cx-reachX)...min(width-1,cx+reachX) {
                let q = SIMD2((Double(x)+0.5)*dx-aspect,1-(Double(y)+0.5)*dy)
                let r2 = simd_length_squared(q-p)/(blob*blob*4)
                if r2 < 1 { field[y*width+x] += (1-r2)*(1-r2)*(1-r2) }
            } }
        }
        return field.map { Float(tanh(($0-0.35)*5)) }
    }

    /// Rosensweig instability: a hexagonal field of rounded spikes rises wherever
    /// the magnetic liquid is deep. Holes sets spike density, Drip length their height.
    static func addSpikes(_ node: Node,_ thickness: inout [Double],width: Int,height: Int,aspect: Double) {
        let spread = max(0.6,node.value("spread"))
        let spacing = (0.17-0.012*node.value("holes"))*spread
        let tall = 0.06+0.3*node.value("dripLength"), sharp = 1.1+1.6*node.value("threads")
        let dx = 2*aspect/Double(width), dy = 2/Double(height)
        let row = spacing*0.8660254
        for y in 0..<height { for x in 0..<width {
            let index = y*width+x, depth = thickness[index]
            guard depth > 0.004 else { continue }
            let p = SIMD2((Double(x)+0.5)*dx-aspect,1-(Double(y)+0.5)*dy)
            // Nearest site on a hexagonal lattice.
            let j = (p.y/row).rounded()
            let offset = Int(j).isMultiple(of:2) ? 0 : spacing*0.5
            let i = ((p.x-offset)/spacing).rounded()
            let site = SIMD2(i*spacing+offset,j*row)
            let r = simd_length(p-site)/(spacing*0.5)
            guard r < 1 else { continue }
            let cone = pow(1-r,sharp)
            thickness[index] += tall*cone*smoothstep(0.01,0.06,depth)
        } }
    }
}

private func smoothstep(_ a: Double,_ b: Double,_ x: Double) -> Double {
    let t = min(max((x-a)/(b-a),0),1)
    return t*t*(3-2*t)
}
