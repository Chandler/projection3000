import Foundation
import AppKit
import CoreText
import Metal
import PatchCore

/// CoreText layout for Poster Text. Each line's prefix sets its role:
/// `#` headline (fit to width), `##` lineup, `###` venue, `==` date between
/// rules, `-` detail, `~` credits, `---` rule, `>` flexible space.
enum PosterTextRenderer {
    enum Role { case headline, lineup, venue, date, detail, credits, rule, flex, gap, body }
    static func parse(_ text: String) -> [(Role,String)] {
        text.components(separatedBy:"\n").map { raw in
            let line = raw.trimmingCharacters(in:.whitespaces)
            func strip(_ prefix: String) -> String { String(line.dropFirst(prefix.count)).trimmingCharacters(in:.whitespaces) }
            if line == ">" { return (.flex,"") }
            if line.isEmpty { return (.gap,"") }
            if line.hasPrefix("---") { return (.rule,"") }
            if line.hasPrefix("###") { return (.venue,strip("###")) }
            if line.hasPrefix("##") { return (.lineup,strip("##")) }
            if line.hasPrefix("#") { return (.headline,strip("#")) }
            if line.hasPrefix("==") { return (.date,strip("==")) }
            if line.hasPrefix("-") { return (.detail,strip("-")) }
            if line.hasPrefix("~") { return (.credits,strip("~")) }
            return (.body,line)
        }
    }
    static let headlineFaces = ["HelveticaNeue-CondensedBlack","Futura-CondensedExtraBold","DINCondensed-Bold","AvenirNext-Heavy"]

    static func ink(_ node: Node) -> [Double] {
        let ink = node.value("ink"), warmth = node.value("inkWarmth")
        return [ink,ink*(1-0.04*warmth),ink*(1-0.12*warmth)]
    }
    /// Lines take their color from the context, so one measurement serves every color.
    static func line(_ text: String,_ face: String,_ size: Double,tracking: Double = 0) -> CTLine {
        let font = CTFontCreateWithName(face as CFString,max(1,size),nil)
        let value = NSAttributedString(string:text,attributes:[.init(kCTFontAttributeName as String):font,.init(kCTForegroundColorFromContextAttributeName as String):true,.init(kCTKernAttributeName as String):tracking*size])
        return CTLineCreateWithAttributedString(value)
    }
    static func measure(_ line: CTLine) -> (width: Double,ascent: Double,descent: Double) {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line,&ascent,&descent,nil)
        return (width,Double(ascent),Double(descent))
    }
    struct TypeMetrics { var lines: [(line: CTLine,width: Double)]; var ascent, descent, advance: Double; var size: CGSize }
    /// Lines and their unrotated box, in poster pixels.
    static func metrics(_ element: PosterElement,posterWidth w: Double) -> TypeMetrics {
        let size = element.size*w
        let lines = element.text.components(separatedBy:"\n").map { text -> (line: CTLine,width: Double) in
            let built = line(text,element.font,size,tracking:element.tracking)
            return (built,measure(built).width)
        }
        let font = CTFontCreateWithName(element.font as CFString,max(1,size),nil)
        let ascent = Double(CTFontGetAscent(font)), descent = Double(CTFontGetDescent(font))
        let advance = (ascent+descent)*element.leading
        let width = lines.map(\.width).max() ?? 0
        return TypeMetrics(lines:lines,ascent:ascent,descent:descent,advance:advance,size:CGSize(width:max(width,size*0.3),height:ascent+descent+advance*Double(max(0,lines.count-1))))
    }
    /// Unrotated box of any element, in poster pixels.
    static func boxSize(_ element: PosterElement,poster: CGSize) -> CGSize {
        switch element.shape {
        case .text: return metrics(element,posterWidth:poster.width).size
        case .rule: return CGSize(width:element.width*poster.width,height:max(1,element.stroke*poster.width))
        case .rectangle, .ellipse, .image, .video: return CGSize(width:element.width*poster.width,height:element.height*poster.height)
        case .chrome: return .zero
        }
    }

    /// The tagged-text layout as placed elements: what the editor starts from.
    static func autoLayout(_ node: Node,dimensions: VideoDimensions) -> PosterLayout {
        let width = dimensions.width, height = dimensions.height, w = Double(width), h = Double(height)
        let margin = node.value("margin")*w, content = w-2*margin, body = node.value("bodySize"), spacing = node.value("spacing")
        let headlineFace = headlineFaces[max(0,min(headlineFaces.count-1,Int(node.value("headlineFont").rounded())))]
        let ruleWeight = max(1.5,w*0.0018)/w
        // Build each element at its size first, so flexible space can be distributed.
        struct Item { var role: Role; var text: String; var face: String; var size, tracking, width, ascent, descent, before: Double }
        var items: [Item] = []
        for (role,text) in parse(node.text ?? PosterStyle.defaultText) {
            var face = "", size = 0.0, tracking = 0.0
            switch role {
            case .headline:
                face = headlineFace; tracking = node.value("tracking")
                let probe = measure(line(text,face,100,tracking:tracking))
                size = min(w*0.5,100*content/max(probe.width,1)*node.value("headlineSize"))
            case .lineup:
                face = "HelveticaNeue-CondensedBold"; size = w*0.068*body
                let probe = measure(line(text,face,size))
                if probe.width > content { size *= content/probe.width }
            case .venue: face = "HelveticaNeue-Bold"; size = w*0.05*body
            case .date: face = "HelveticaNeue-Bold"; size = w*0.052*body
            case .detail: face = "HelveticaNeue-Medium"; size = w*0.026*body
            case .credits: face = "HelveticaNeue-Medium"; size = w*0.022*body
            case .body: face = "HelveticaNeue"; size = w*0.026*body
            case .rule, .flex, .gap: break
            }
            let metrics = face.isEmpty ? (width:0,ascent:0,descent:0) : measure(line(text,face,size,tracking:tracking))
            let before = (role == .gap ? w*0.02 : role == .rule ? w*0.03 : w*0.012)*spacing
            items.append(Item(role:role,text:text,face:face,size:size,tracking:tracking,width:metrics.width,ascent:metrics.ascent,descent:metrics.descent,before:before))
        }
        let used = items.reduce(0.0) { $0+$1.before+$1.ascent+$1.descent+($1.role == .rule ? w*0.006 : 0) }
        let flexCount = items.filter { $0.role == .flex }.count
        let flex = flexCount > 0 ? max(0,h-2*margin-used)/Double(flexCount) : 0
        var y = margin*0.8   // distance from the top
        var elements: [PosterElement] = []
        func rule(_ x0: Double,_ x1: Double,_ y: Double) {
            var element = PosterElement(shape:.rule,x:(x0+x1)/2/w,y:y/h); element.width = (x1-x0)/w; element.stroke = ruleWeight
            elements.append(element)
        }
        for item in items {
            if item.role == .flex { y += flex; continue }
            y += item.before
            if item.role == .rule { rule(margin,w-margin,y); y += w*0.006; continue }
            guard !item.face.isEmpty else { continue }
            var element = PosterElement(shape:.text,x:0.5,y:(y+(item.ascent+item.descent)/2)/h)
            element.text = item.text; element.font = item.face; element.size = item.size/w; element.tracking = item.tracking
            if item.role == .headline { element.slant = node.value("slant") }
            elements.append(element)
            if item.role == .date {
                // Thin rules either side of the date.
                let gap = w*0.04, middle = y+item.ascent*0.62, left = (w-item.width)/2
                rule(margin+w*0.03,left-gap,middle); rule(left+item.width+gap,w-margin-w*0.03,middle)
            }
            y += item.ascent+item.descent
        }
        // Stable IDs, so a selection survives until the first edit makes the layout free.
        for index in elements.indices { elements[index].id = UUID(uuidString:String(format:"504F5354-0000-4000-8000-%012X",index))! }
        return PosterLayout(elements:elements)
    }

    /// Draws into a top-left-origin context sized to the poster.
    static func draw(_ layout: PosterLayout,ink: [Double],in context: CGContext,poster: CGSize) {
        let w = Double(poster.width)
        for element in layout.visible where ![.chrome,.image,.video].contains(element.shape) {
            let rgb = element.color ?? ink
            let color = CGColor(srgbRed:rgb[0],green:rgb[1],blue:rgb[2],alpha:1)
            context.saveGState()
            context.setAlpha(max(0,min(1,element.opacity)))
            context.setFillColor(color); context.setStrokeColor(color)
            context.translateBy(x:element.x*poster.width,y:element.y*poster.height)
            context.rotate(by:element.rotation*Double.pi/180)
            let box = boxSize(element,poster:poster), rect = CGRect(x:-box.width/2,y:-box.height/2,width:box.width,height:box.height)
            switch element.shape {
            case .text:
                let metrics = metrics(element,posterWidth:w)
                context.scaleBy(x:1,y:-1)   // glyphs draw upright in y-up space
                for (index,line) in metrics.lines.enumerated() {
                    let top = Double(index)*metrics.advance
                    let x = element.align == .left ? -box.width/2 : element.align == .right ? box.width/2-line.width : -line.width/2
                    context.textMatrix = CGAffineTransform(a:1,b:0,c:element.slant,d:1,tx:0,ty:0)
                    context.textPosition = CGPoint(x:x,y:box.height/2-top-metrics.ascent)
                    CTLineDraw(line.line,context)
                }
            case .rule:
                context.setLineWidth(box.height)
                context.move(to:CGPoint(x:-box.width/2,y:0)); context.addLine(to:CGPoint(x:box.width/2,y:0)); context.strokePath()
            case .rectangle, .ellipse:
                let weight = element.stroke*w
                if weight > 0 {
                    context.setLineWidth(weight)
                    let inset = rect.insetBy(dx:weight/2,dy:weight/2)
                    if element.shape == .rectangle { context.stroke(inset) } else { context.strokeEllipse(in:inset) }
                } else if element.shape == .rectangle { context.fill(rect) } else { context.fillEllipse(in:rect) }
            case .chrome, .image, .video: break
            }
            context.restoreGState()
        }
    }

    /// One step of the composer's stack, back to front.
    enum Pass { case type(MTLTexture,PosterElement.Blend), image(PosterElement), video(PosterElement) }
    /// The stack as passes: runs of vector layers sharing a blend are set
    /// together; images and video are composited on the GPU.
    static func renderPasses(_ node: Node,dimensions: VideoDimensions,device: MTLDevice) throws -> [Pass] {
        let layout = node.poster ?? autoLayout(node,dimensions:dimensions), ink = ink(node)
        var passes: [Pass] = [], run: [PosterElement] = []
        func flush() throws {
            guard let blend = run.first?.blend else { return }
            passes.append(.type(try render(PosterLayout(elements:run),ink:ink,dimensions:dimensions,device:device),blend))
            run = []
        }
        for element in layout.visible {
            switch element.shape {
            case .chrome: break
            case .video: try flush(); passes.append(.video(element))
            case .image: try flush(); if element.file != nil { passes.append(.image(element)) }
            default: if let blend = run.first?.blend,blend != element.blend { try flush() }; run.append(element)
            }
        }
        try flush()
        return passes
    }
    static func render(_ layout: PosterLayout,ink: [Double],dimensions: VideoDimensions,device: MTLDevice) throws -> MTLTexture {
        let width = dimensions.width, height = dimensions.height
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw GraphError("Cannot create poster text image") }
        context.translateBy(x:0,y:Double(height)); context.scaleBy(x:1,y:-1)
        draw(layout,ink:ink,in:context,poster:CGSize(width:width,height:height))
        guard let image = context.makeImage() else { throw GraphError("Cannot create poster text image") }
        return try ImageUpload.texture(image,device:device)
    }
}

/// Composites the poster stack one layer per pass over a fill.
final class PosterComposerPipeline {
    let fill: MTLComputePipelineState
    let layer: MTLComputePipelineState
    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source:Self.source,options:nil)
        guard let fill = library.makeFunction(name:"posterFill"),let layer = library.makeFunction(name:"posterLayer") else { throw GraphError("Poster composer kernel missing") }
        self.fill = try device.makeComputePipelineState(function:fill)
        self.layer = try device.makeComputePipelineState(function:layer)
    }
    static func fillColor(_ node: Node) -> SIMD4<Float> {
        let level = Float(node.value("backgroundLevel")), warmth = Float(node.value("backgroundWarmth"))
        return SIMD4(level*(1+0.08*warmth),level,level*(1-0.14*warmth),1)
    }
    static let blendCodes = Dictionary(uniqueKeysWithValues:PosterElement.Blend.allCases.enumerated().map { ($0.element,Float($0.offset)) })
    /// Full-frame layer: mode, opacity, invert, kind 0.
    static func frame(_ blend: PosterElement.Blend,opacity: Double) -> [SIMD4<Float>] {
        [SIMD4(blendCodes[blend]!,Float(opacity),0,0),.zero,.zero]
    }
    /// A layer filling a rotated box (centre and size in poster units); `cover` crops the image to the box.
    static func box(_ blend: PosterElement.Blend,opacity: Double,invert: Bool,center: SIMD2<Float>,size: SIMD2<Float>,degrees: Double,layerAspect: Float,posterAspect: Float,cover: Bool) -> [SIMD4<Float>] {
        [SIMD4(blendCodes[blend]!,Float(opacity),invert ? 1:0,1),SIMD4(center.x,center.y,size.x,size.y),SIMD4(Float(degrees*Double.pi/180),layerAspect,posterAspect,cover ? 1:0)]
    }
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    float2 pCover(float2 uv,float source,float target) {
        // Fill the box, cropping the source's longer side.
        return source>target ? float2((uv.x-0.5)*target/source+0.5,uv.y) : float2(uv.x,(uv.y-0.5)*source/target+0.5);
    }
    float3 pBlend(float3 base,float3 layer,int mode) {
        if(mode==1) return base*layer;
        if(mode==2) return 1.0-(1.0-base)*(1.0-layer);
        if(mode==3) return mix(2.0*base*layer,1.0-2.0*(1.0-base)*(1.0-layer),step(0.5,base));
        if(mode==4) return mix(base-(1.0-2.0*layer)*base*(1.0-base),base+(2.0*layer-1.0)*(sqrt(base)-base),step(0.5,layer));
        if(mode==5) return base+layer;
        if(mode==6) return max(base,layer);
        if(mode==7) return min(base,layer);
        if(mode==8) return abs(base-layer);
        if(mode==9) return base+2.0*layer;   // relief: layer is detail around zero
        return layer;
    }
    kernel void posterFill(texture2d<float,access::write> output [[texture(0)]],constant float4 &color [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
        if(gid.x>=output.get_width()||gid.y>=output.get_height()) return;
        output.write(color,gid);
    }
    kernel void posterLayer(texture2d<float,access::read> base [[texture(0)]],texture2d<float,access::sample> layer [[texture(1)]],texture2d<float,access::write> output [[texture(2)]],
                            constant float4 *c [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
        if(gid.x>=output.get_width()||gid.y>=output.get_height()) return;
        constexpr sampler linear(coord::normalized,address::clamp_to_zero,filter::linear);
        float3 color=base.read(gid).rgb;
        float2 uv=(float2(gid)+0.5)/float2(output.get_width(),output.get_height());
        int mode=int(c[0].x);
        float2 luv=uv;
        float coverage=1.0;
        if(c[0].w>0.5) {
            // Into the box's own space: centre, unrotate, normalize by its size.
            float aspect=c[2].z;
            float2 q=(uv-c[1].xy)*float2(aspect,1.0);
            float co=cos(-c[2].x),si=sin(-c[2].x);
            q=float2(co*q.x-si*q.y,si*q.x+co*q.y);
            luv=q/(max(c[1].zw,0.0001)*float2(aspect,1.0))+0.5;
            coverage=step(0.0,luv.x)*step(luv.x,1.0)*step(0.0,luv.y)*step(luv.y,1.0);
            if(c[2].w>0.5) luv=pCover(luv,c[2].y,c[1].z*aspect/max(c[1].w,0.0001));
        }
        float4 l=layer.sample(linear,luv);
        float3 rgb=l.a>0.0 ? l.rgb/l.a : float3(0);
        if(c[0].z>0.5) rgb=1.0-rgb;
        if(mode==9) {
            // Relief: the image minus its local average, so only creases and wrinkles remain.
            float3 mean=float3(0);
            for(int i=0;i<8;i++) { float a=float(i)*0.785398; float3 s=layer.sample(linear,luv+float2(cos(a),sin(a))*0.02).rgb; mean+=c[0].z>0.5 ? 1.0-s : s; }
            rgb-=mean/8.0;
        }
        float a=clamp(l.a*c[0].y*coverage,0.0,1.0);
        output.write(float4(clamp(mix(color,pBlend(color,rgb,mode),a),0.0,1.0),1.0),gid);
    }
    """
}
