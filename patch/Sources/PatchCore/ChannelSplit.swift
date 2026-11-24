import Foundation

public enum ChannelSplitStyle {
    public static var parameters: [ParameterSpec] {
        var result: [ParameterSpec] = [
            .init("mode","Color model",0,1,0,choices:["RGB","CMYK"]),
            .init("amount","Separation",0,4,1),
            .init("angle","Rotation",-180,180,0),
            .init("radial","Radial spread (px)",-100,100,0),
            .init("mix","Mix",0,1,1),
            .init("edges","Edges",0,3,0,choices:["Clamp","Wrap","Mirror","Neutral"])
        ]
        for (i,name) in ["Red / Cyan","Green / Magenta","Blue / Yellow","Black"].enumerated() {
            result += [.init("x\(i)","\(name) X (px)",-200,200,i == 0 ? -8 : (i == 2 ? 8 : 0)),
                       .init("y\(i)","\(name) Y (px)",-200,200,0)]
        }
        return result
    }
}
