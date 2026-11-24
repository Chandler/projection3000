import Foundation

public enum ChannelColorsStyle {
    public static let names = ["Red","Green","Blue"]
    public static let primaries: [Double] = [0xFF0000,0x00FF00,0x0000FF]
    public static var parameters: [ParameterSpec] {
        var result: [ParameterSpec] = [
            .init("channels","Channels",0,3,0,choices:["All","Red","Green","Blue"]),
            .init("blend","Blend",0,1,0,choices:["Add","Screen"]),
            .init("mix","Mix",0,1,1)
        ]
        for (i,name) in names.enumerated() {
            result += [.init("color\(i)","\(name) color",0,16777215,primaries[i],midi:false),
                       .init("level\(i)","\(name) level",0,2,1)]
        }
        return result
    }
}
