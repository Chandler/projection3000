import Foundation
public enum RasterSynthStyle {
    public static let parameters: [ParameterSpec] = [
        .init("mode","Pattern",0,4,4,choices:["Crossfade bars","Weave","Contours","Warped bands","Two-color layers"],step:1),
        .init("windowMS","Waveform window (ms)",1,100,12.84),
        .init("trigger","Phase lock",0,1,1,choices:["Free","Left rising edge"],step:1),
        .init("repeatX","Horizontal repeats",1,32,6,step:1),
        .init("repeatY","Vertical repeats",1,32,4,step:1),
        .init("gainX","Left signal gain",0,40,8),
        .init("gainY","Right signal gain",0,40,8),
        .init("warp","Cross modulation",0,2,0.2),
        .init("contours","Contour bands",1,16,4,step:1),
        .init("contrast","Contrast",0.1,8,1.5),
        .init("rotation","Rotation (degrees)",-180,180,0),
        .init("drift","Drift speed",0,1,0),
        .init("hue","Hue",0,1,0.55),
        .init("hueY","Right layer hue",0,1,0.04),
        .init("saturation","Saturation",0,1,0.85),
        .init("brightness","Brightness",0,2,1)
    ]
}
