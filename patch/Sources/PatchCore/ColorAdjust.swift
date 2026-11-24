import Foundation

public enum ColorAdjustStyle {
    /// Applied in this order: input levels, exposure, white balance, brightness,
    /// contrast, saturation, hue, output levels, invert.
    public static let parameters: [ParameterSpec] = [
        .init("brightness","Brightness",-1,1,0),
        .init("contrast","Contrast",0,2,1),
        .init("saturation","Saturation",0,2,1),
        .init("exposure","Exposure (stops)",-3,3,0),
        .init("gamma","Gamma",0.1,4,1),
        .init("blackPoint","Input black",0,1,0),
        .init("whitePoint","Input white",0,1,1),
        .init("outBlack","Output black",0,1,0),
        .init("outWhite","Output white",0,1,1),
        .init("hue","Hue shift (°)",-180,180,0),
        .init("temperature","Temperature",-1,1,0),
        .init("tint","Tint",-1,1,0),
        .init("invert","Invert",0,1,0,choices:["Off","On"],midi:true,step:1),
        .init("mix","Mix",0,1,1)
    ]
}
