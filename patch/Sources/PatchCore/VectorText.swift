import Foundation
import CoreText
import CoreGraphics

/// Outline generation happens only when text or geometry settings change.
/// Core Text provides shaping and fallback fonts; the encoder samples a cached path.
enum VectorTextGeometry {
    static func make(_ node: Node) -> VectorPath {
        let text=String((node.text ?? "PATCH").prefix(128))
        let fonts=["HelveticaNeue","Menlo-Regular","TimesNewRomanPSMT"]
        let font=CTFontCreateWithName(fonts[min(2,max(0,Int(node.value("font"))))] as CFString,100,nil)
        let attributes=[NSAttributedString.Key(kCTFontAttributeName as String):font]
        let path=CGMutablePath()
        for (row,text) in text.components(separatedBy:.newlines).prefix(8).enumerated() {
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attributes))
            let width=CTLineGetTypographicBounds(line,nil,nil,nil)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count=CTRunGetGlyphCount(run)
                guard count>0 else { continue }
                var glyphs=[CGGlyph](repeating:0,count:count),positions=[CGPoint](repeating:.zero,count:count)
                CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs)
                CTRunGetPositions(run,CFRange(location:0,length:0),&positions)
                let actualFont=(CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                for i in 0..<count {
                    guard let outline=CTFontCreatePathForGlyph(actualFont,glyphs[i],nil) else { continue }
                    let transform=CGAffineTransform(translationX:positions[i].x-width/2,y:positions[i].y-Double(row)*100*node.value("lineSpacing"))
                    path.addPath(outline,transform:transform)
                }
            }
        }
        let bounds=path.boundingBoxOfPath
        guard !bounds.isNull,max(bounds.width,bounds.height)>0 else { return VectorPath(vertices:[]) }
        let scale=Float(node.value("size")*2/max(bounds.width,bounds.height))
        let center=SIMD2(Float(bounds.midX),Float(bounds.midY))
        var contours=[[SIMD2<Float>]](),line=[SIMD2<Float>](),current=SIMD2<Float>.zero
        func point(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(p.x),Float(p.y)) }
        func finish() {
            if line.count>1 { contours.append(line.map { ($0-center)*scale }) }
            line.removeAll(keepingCapacity:true)
        }
        func flatten(_ a: SIMD2<Float>,_ b: SIMD2<Float>,_ c: SIMD2<Float>,_ d: SIMD2<Float>,_ depth: Int = 0) {
            let chord=d-a,length=max(0.0001,(chord.x*chord.x+chord.y*chord.y).squareRoot())
            let ab=b-a,ac=c-a
            let deviation: Float
            if length<=0.0001 { deviation=max((ab.x*ab.x+ab.y*ab.y).squareRoot(),(ac.x*ac.x+ac.y*ac.y).squareRoot()) }
            else { deviation=max(abs(chord.x*ab.y-chord.y*ab.x),abs(chord.x*ac.y-chord.y*ac.x))/length }
            if depth>=10 || deviation<0.25 { line.append(d);return }
            let abm=(a+b)*0.5,bcm=(b+c)*0.5,cdm=(c+d)*0.5
            let abc=(abm+bcm)*0.5,bcd=(bcm+cdm)*0.5,middle=(abc+bcd)*0.5
            flatten(a,abm,abc,middle,depth+1);flatten(middle,bcd,cdm,d,depth+1)
        }
        path.applyWithBlock { element in
            let e=element.pointee
            switch e.type {
            case .moveToPoint:
                finish();current=point(e.points[0]);line.append(current)
            case .addLineToPoint:
                current=point(e.points[0]);line.append(current)
            case .addQuadCurveToPoint:
                let control=point(e.points[0]),end=point(e.points[1])
                flatten(current,current+(control-current)*(2/3),end+(control-end)*(2/3),end);current=end
            case .addCurveToPoint:
                let end=point(e.points[2]);flatten(current,point(e.points[0]),point(e.points[1]),end);current=end
            case .closeSubpath:
                if let first=line.first { current=first;line.append(first) };finish()
            @unknown default: break
            }
        }
        finish()
        return VectorPath(contours:contours,travelSpeed:node.value("travel"))
    }
}
