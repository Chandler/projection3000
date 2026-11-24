import Foundation

public struct CropRegion: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
}
public enum CropStyle {
    public static let aspects = ["Input", "Free", "16:9", "9:16", "1:1", "4:3", "3:4", "4:5", "21:9", "Custom"]
    public static var parameters: [ParameterSpec] { [
        .init("aspect","Aspect ratio",0,9,0,choices:aspects),
        .init("ratioWidth","Ratio width",1,32,16), .init("ratioHeight","Ratio height",1,32,9),
         .init("resolution","Output resolution",0,4,0,choices:["Match input long edge","HD · 720 short edge","Full HD · 1080 short edge","4K · 2160 short edge","Custom pixels"]),
        .init("outputWidth","Output width",2,8192,1080), .init("outputHeight","Output height",2,8192,1920),
        .init("zoom","Zoom",1,8,1),
        .init("width","Crop width",0.05,1,1), .init("height","Crop height",0.05,1,1),
        .init("x","Horizontal position",0,1,0.5), .init("y","Vertical position",0,1,0.5),
        .init("fit","Output framing",0,2,0,choices:["Fit","Fill","Stretch"]),
        .init("background","Bars",0,1,0,choices:["Black","White"]),
        .init("flipX","Flip horizontal",0,1,0,choices:["Off","On"]), .init("flipY","Flip vertical",0,1,0,choices:["Off","On"])
    ] }
    public static func outputDimensions(_ node: Node,input: VideoDimensions) -> VideoDimensions {
        func even(_ value: Double) -> Int { max(2,min(8192,Int((value/2).rounded())*2)) }
        if Int(node.value("resolution")) == 4 { return VideoDimensions(even(node.value("outputWidth")),even(node.value("outputHeight"))) }
        let r = region(node,width:input.width,height:input.height)
        let ratio = input.aspect*r.width/max(0.000001,r.height)
        let w: Double, h: Double
        switch Int(node.value("resolution")) {
        case 1,2,3:
            let short = [720.0,1080.0,2160.0][Int(node.value("resolution"))-1]
            w = ratio>=1 ? short*ratio : short; h = ratio>=1 ? short : short/ratio
        default:
            // Retain the input's long-edge resolution; zoom changes framing, not stream size.
            let long = Double(max(input.width,input.height))
            w = ratio>=1 ? long : long*ratio; h = ratio>=1 ? long/ratio : long
        }
        let scale = min(1,8192/max(w,h))
        return VideoDimensions(even(w*scale),even(h*scale))
    }
    public static func region(_ node: Node,width: Int,height: Int) -> CropRegion {
        let sourceAspect = Double(max(1,width))/Double(max(1,height))
        let ratio: Double
        switch Int(node.value("aspect")) {
        case 2: ratio = 16.0/9
        case 3: ratio = 9.0/16
        case 4: ratio = 1
        case 5: ratio = 4.0/3
        case 6: ratio = 3.0/4
        case 7: ratio = 4.0/5
        case 8: ratio = 21.0/9
        case 9: ratio = node.value("ratioWidth")/max(1,node.value("ratioHeight"))
        default: ratio = sourceAspect
        }
        let free = Int(node.value("aspect")) == 1, zoom = max(1,node.value("zoom"))
        let w = (free ? node.value("width") : min(1,ratio/sourceAspect))/zoom
        let h = (free ? node.value("height") : min(1,sourceAspect/ratio))/zoom
        return CropRegion(x:(1-w)*node.value("x"),y:(1-h)*node.value("y"),width:w,height:h)
    }
}
