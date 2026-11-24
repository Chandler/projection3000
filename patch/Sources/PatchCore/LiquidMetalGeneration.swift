import Foundation

extension LiquidMetalStyle {
    // Stable integer RNG: a saved seed reproduces the same topology on every launch.
    private struct Random {
        var state: UInt64
        mutating func unit() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xffffff) / Float(0xffffff)
        }
        mutating func signed() -> Float { unit()*2-1 }
    }
    public static func primitives(_ node: Node) -> [SIMD4<Float>] {
        func f(_ key: String) -> Float { Float(node.value(key)) }
        var rng=Random(state:UInt64(max(0,node.value("seed").rounded())) &+ 1)
        var positions=[SIMD3<Float>](), scales=[SIMD3<Float>](), angles=[Float](), cuts=[Bool](), links=[(Int,Int)]()
        let generated=node.value("construction") >= 0.5
        let count=max(1,min(24,Int(node.value(generated ? "parts":"count").rounded())))
        let family=Int(node.value("family"))
        for i in 0..<count {
            if !generated {
                positions.append(SIMD3(f("ball\(i+1)X"),f("ball\(i+1)Y"),f("ball\(i+1)Z")))
                scales.append(SIMD3(f("ball\(i+1)StretchX"),f("ball\(i+1)StretchY"),f("ball\(i+1)StretchZ"))*f("ball\(i+1)Radius"))
                angles.append(f("ball\(i+1)Angle") * .pi/180);cuts.append(node.value("ball\(i+1)Cut")>0.5)
                let parent=Int(node.value("ball\(i+1)Parent").rounded())-1
                if parent>=0 && parent<count && parent != i { links.append((parent,i)) }
                continue
            }
            let u=Float(i)/Float(max(1,count-1))
            let jitter=SIMD3(rng.signed(),rng.signed(),rng.signed())
            var p=SIMD3<Float>.zero
            if family == 1 {
                let angle=Float(i)/Float(count)*2 * Float.pi
                p=SIMD3(cos(angle)*(0.95+0.18*jitter.x),sin(angle)*(1.0+0.12*jitter.y),jitter.z*f("depth"))
                if i>0 { links.append((i-1,i)) }
            } else if family == 2 {
                let angle=Float(i)*2.399963 + jitter.x*0.3
                let radius=0.25+0.9*sqrt(u)
                p=SIMD3(cos(angle)*radius,sin(angle)*radius,jitter.z*f("depth"))
                if i>0 { links.append((Int(rng.unit()*Float(i)).clamped(to:0...(i-1)),i)) }
            } else {
                // A continuous trunk with alternating lateral offshoots.
                p=SIMD3(sin(u*5.4)*0.35+jitter.x*0.2,(u-0.5)*2.6,jitter.z*f("depth"))
                if i>0 {
                    let branch=rng.unit()<f("branching") && i>1
                    let parent=branch ? max(0,i-2):i-1
                    if branch { p.x += (i%2 == 0 ? 1:-1)*(0.45+0.45*rng.unit()) }
                    links.append((parent,i))
                }
            }
            p *= SIMD3(f("span"),f("span")*f("height"),f("span"))
            positions.append(p)
            let radius=f("thickness")*(1+f("variation")*rng.signed()*0.75)
            scales.append(SIMD3(radius,radius*(1+(f("stretch")-1)*rng.unit()),radius*(0.75+rng.unit()*0.4)))
            angles.append(rng.signed() * .pi);cuts.append(false)
        }
        if generated {
            if family == 1 { links.append((count-1,0)) }
            for k in 0..<min(6,Int(node.value("loops").rounded())) {
                let a=(k*3+Int(rng.unit()*Float(count)))%count
                let b=(a+2+Int(rng.unit()*Float(max(1,count/2))))%count
                if a != b && !links.contains(where:{ ($0.0==a && $0.1==b) || ($0.0==b && $0.1==a) }) { links.append((a,b)) }
            }
        }
        var positive=[SIMD4<Float>](), negative=[SIMD4<Float>]()
        for i in 0..<count {
            let item=[SIMD4(positions[i],0),SIMD4(scales[i],0),SIMD4<Float>(0,0,angles[i],cuts[i] ? 2:0)]
            if cuts[i] { negative += item } else { positive += item }
        }
        for (a,b) in links where !cuts[a] && !cuts[b] {
            let start=positions[a],end=positions[b],delta=end-start
            let length=sqrt(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z)
            if length<0.001 { continue }
            let bend=SIMD3(-delta.y,delta.x,0)/max(0.001,sqrt(delta.x*delta.x+delta.y*delta.y))
            let control=(start+end)*0.5+bend*f("curve")*length*rng.signed()*0.6
            func point(_ t:Float)->SIMD3<Float> { (1-t)*(1-t)*start+2*(1-t)*t*control+t*t*end }
            func radius(_ t:Float)->Float { f("neck")*(0.72+0.8*abs(t-0.5)) }
            for j in 0..<3 {
                let t=Float(j)/3,u=Float(j+1)/3
                positive += [SIMD4(point(t),radius(t)),SIMD4(point(u),radius(u)),SIMD4<Float>(0,0,0,1)]
            }
        }
        if generated {
            for k in 0..<min(6,Int(node.value("holes").rounded())) {
                let i=(k*3+1)%count
                let center=positions[i]+SIMD3(rng.signed()*0.12,rng.signed()*0.12,0)
                let size=f("holeSize")*(0.75+rng.unit()*0.5)
                negative += [SIMD4(center,0),SIMD4<Float>(size,size*(0.7+rng.unit()*0.7),4,0),SIMD4<Float>(0,0,rng.signed() * .pi,2)]
            }
        }
        return positive+negative
    }
}
private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound,Swift.max(range.lowerBound,self)) }
}
