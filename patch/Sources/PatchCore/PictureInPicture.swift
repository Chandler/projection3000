import Foundation

public enum PictureInPictureStyle {
    public static var parameters: [ParameterSpec] { [
        .init("x","Horizontal position",0,1,0.96), .init("y","Vertical position",0,1,0.96),
        .init("width","Width",0.05,1,0.3), .init("height","Height",0.05,1,0.3),
        .init("lock","Lock proportions",0,1,1,choices:["Off","On"]),
        .init("fit","Framing",0,2,1,choices:["Fit","Fill","Stretch"]),
        .init("opacity","Opacity",0,1,1), .init("radius","Corner radius (px)",0,120,16),
        .init("border","White border (px)",0,30,0), .init("shadow","Shadow",0,1,0.4)
    ] }
}
