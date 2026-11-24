import Foundation

/// Shared by the schema, inspector and renderer; defaults preserve existing patches.
public enum PoseStyle {
    public static var groups: [(String,[ParameterSpec])] { [
        ("LINES",[
            .init("confidence","Joint confidence",0.05,0.95,0.3),
            .init("thickness","Line width",0.5,30,4),
            .init("opacity","Opacity",0,1,1),
            .init("boneTrim","Joint gap",0,0.8,0),
            .init("dashLength","Dash length (0 = solid)",0,100,0),
            .init("dashGap","Dash gap",0,100,12),
            .init("dashSpeed","Dash motion (px/s)",-200,200,0)
        ]),
        ("BODY & JOINTS",[
            .init("headStyle","Head",0,2,0,choices:["Ring","Filled","Hidden"]),
            .init("headSize","Head size",0.1,4,1),
            .init("torso","Torso",0,3,0,choices:["Outline","Spine","Crossed","Hidden"]),
            .init("torsoWidth","Torso width",0.1,3,1),
            .init("armLength","Arm length",0,3,1),
            .init("legLength","Leg length",0,3,1),
            .init("arms","Arms",0,1,1,choices:["Hidden","Visible"]),
            .init("legs","Legs",0,1,1,choices:["Hidden","Visible"]),
            .init("joints","Joint dots",0,1,1,choices:["Off","On"]),
            .init("jointSize","Joint size",0.1,5,1),
            .init("jointShape","Joint shape",0,2,0,choices:["Disc","Ring","Diamond"])
        ]),
        ("COLOR",[
            .init("color","Palette",0,3,1,choices:["White","Limbs","Position","Rainbow"]),
            .init("hue","Hue",0,1,0.47),
            .init("hueSpread","Hue spread",0,1,0.3),
            .init("saturation","Saturation",0,1,0.82),
            .init("brightness","Brightness",0,1,1),
            .init("hueRate","Hue cycle (Hz)",-1,1,0),
            .init("background","Background",0,2,0,choices:["Black","White","Custom"]),
            .init("backgroundHue","Background hue",0,1,0.65),
            .init("backgroundSaturation","Background saturation",0,1,0.6),
            .init("backgroundBrightness","Background brightness",0,1,0.08)
        ]),
        ("GLOW & TRAILS",[
            .init("glow","Glow strength",0,3,0),
            .init("glowRadius","Glow radius",1,60,16),
            .init("trails","Trail duration (s)",0,1.5,0),
            .init("trailOpacity","Trail opacity",0,1,0.45),
            .init("trailDecay","Trail decay",0.25,4,1.5)
        ]),
        ("TRANSFORM",[
            .init("scale","Scale",0.1,4,1),
            .init("stretchX","Stretch X",0.1,3,1),
            .init("stretchY","Stretch Y",0.1,3,1),
            .init("x","Position X",-1,1,0),
            .init("y","Position Y",-1,1,0),
            .init("rotation","Rotation (degrees)",-180,180,0),
            .init("mirror","Mirror",0,1,0,choices:["Off","On"])
        ]),
        ("MOTION",[
            .init("spin","Spin (degrees/s)",-180,180,0),
            .init("pulse","Width pulse",0,0.95,0),
            .init("pulseRate","Pulse rate (Hz)",0,8,1),
            .init("wobble","Wobble (px)",0,60,0),
            .init("wobbleRate","Wobble rate (Hz)",0,8,1)
        ])
    ] }
    public static var parameters: [ParameterSpec] { groups.flatMap { $0.1 } }
    public static let presetNames = ["Classic","Neon","Wireframe","Dots","Ghosts","Ink","Electric"]
    public static func preset(_ name: String) -> [String:Double] {
        var values = Dictionary(uniqueKeysWithValues:parameters.map { ($0.key,$0.initial) })
        let overrides: [String:Double]
        switch name {
        case "Neon": overrides = ["color":3,"thickness":3,"joints":0,"glow":1.4,"glowRadius":22,"hueRate":0.08,"trails":0.3]
        case "Wireframe": overrides = ["headStyle":2,"torso":2,"joints":0,"thickness":1.5,"color":0]
        case "Dots": overrides = ["headStyle":1,"torso":3,"arms":0,"legs":0,"jointSize":2.5,"color":3,"glow":0.6]
        case "Ghosts": overrides = ["color":2,"opacity":0.65,"trails":1.2,"trailOpacity":0.5,"trailDecay":1,"headSize":1.3,"glow":0.5]
        case "Ink": overrides = ["color":0,"background":1,"thickness":7,"joints":0,"headStyle":1,"torso":1]
        case "Electric": overrides = ["color":3,"dashLength":12,"dashGap":8,"dashSpeed":45,"jointShape":2,"jointSize":1.4,"glow":1,"wobble":4,"wobbleRate":3,"pulse":0.3,"pulseRate":2]
        default: overrides = [:]
        }
        values.merge(overrides) { _,new in new }; return values
    }
}
