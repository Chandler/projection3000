import Foundation

extension LiquidMetalStyle {
    /// A gesture-driven network of quadratic sweeps, packed as three position/radius vectors and a conservative bound per curve.
    /// Curves have continuously varying thickness; branches share exact points on the spine.
    public static func flowingCurves(_ node: Node) -> [SIMD4<Float>] {
        var state=UInt64(max(0,node.value("seed").rounded())) &+ 1
        func random() -> Float {
            state=state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xffffff)/Float(0xffffff)
        }
        func signed() -> Float { random()*2-1 }
        let full=Float(node.value("viscosity")), tension=Float(node.value("holeSize"))/0.65
        let count=max(1,min(6,Int(node.value("complexity").rounded())))+2
        let splash=node.value("family")>=4
        let lean=signed()*0.28
        let bottom=SIMD3<Float>(-0.2+lean,-1.9,0.05)
        let middle=SIMD3<Float>(lean,0,0)
        let top=SIMD3<Float>(0.1-lean,1.9,-0.08)
        let tangent=SIMD3<Float>(0.6+random()*0.35,0.65,signed()*0.15)
        let lowerHandle=middle-tangent,upperHandle=middle+tangent
        var curves=[SIMD4<Float>]()
        func add(_ a: SIMD3<Float>,_ b: SIMD3<Float>,_ c: SIMD3<Float>,_ r0: Float,_ r1: Float,_ r2: Float) {
            let center=(a+b+c)/3
            func length(_ p: SIMD3<Float>)->Float { sqrt(p.x*p.x+p.y*p.y+p.z*p.z) }
            let bound=max(length(a-center),max(length(b-center),length(c-center)))+max(r0,max(r1,r2))
            curves += [SIMD4(a,r0),SIMD4(b,r1),SIMD4(c,r2),SIMD4(center,bound)]
        }
        func bezier(_ a: SIMD3<Float>,_ b: SIMD3<Float>,_ c: SIMD3<Float>,_ t: Float)->SIMD3<Float> { (1-t)*(1-t)*a+2*t*(1-t)*b+t*t*c }
        func spine(_ u: Float)->SIMD3<Float> {
            u<0.5 ? bezier(bottom,lowerHandle,middle,u*2):bezier(middle,upperHandle,top,(u-0.5)*2)
        }
        let core:Float=0.14+full*0.17
        add(bottom,lowerHandle,middle,0.045,core*0.8,core)
        add(middle,upperHandle,top,core,core*0.85,0.035)
        for i in 0..<count {
            let f=(Float(i)+0.5)/Float(count)
            let u=max(0.12,min(0.82,0.13+f*0.65+signed()*0.035))
            let root=spine(u)
            let side:Float=i%2 == 0 ? -1:1
            let reach:Float=0.65+random()*0.6+tension*0.15
            let rise:Float=0.18+random()*0.5
            let depth=signed()*0.3
            let shoulder=root+SIMD3(side*reach,rise,depth)
            let bend=root+SIMD3(side*reach*0.4,-0.35-random()*0.3,depth*0.5)
            let swelling:Float=(0.22+random()*0.25)*(0.65+full*0.65)
            // A narrow pulled neck expands into a heavy droplet at the shoulder.
            add(root,bend,shoulder,core*0.85,0.045+full*0.065,swelling)
            let closed = !splash && (i%3 != 1 || count<=3)
            if closed {
                let join=spine(min(0.96,u+0.19+random()*0.08))
                let rim=shoulder+SIMD3(-side*0.10,0.5+random()*0.28,-depth*0.25)
                add(shoulder,rim,join,swelling,0.055+tension*0.07,core*0.7)
            } else {
                // Free arms curl, then end in a genuinely thin filament rather than a capped tube.
                let tip=shoulder+SIMD3(side*(0.12+random()*0.20),0.6+random()*0.35,-depth*0.5)
                let curl=shoulder+SIMD3(-side*(0.35+random()*0.25),0.25+random()*0.25,depth*0.8)
                add(shoulder,curl,tip,swelling,0.025+full*0.03,0.012)
            }
            if i%3==0 {
                let start=spine(max(0.06,u-0.1))
                let tip=start+SIMD3(-side*(0.38+random()*0.28),-0.30-random()*0.25,0.15)
                add(start,start+SIMD3(-side*0.12,-0.32,0.04),tip,core*0.7,0.035,0.055)
            }
        }
        return curves
    }
}
