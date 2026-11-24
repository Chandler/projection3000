import Foundation

public extension NodeKind {
    var isMappedSurface: Bool { [.triangulateFaces,.boxWaterfall,.sphereGimbal,.boxEdges].contains(self) }
    var isMappedTrace: Bool { [.traceSnake,.tracePulse,.traceRainbow,.traceSolid].contains(self) }
    var mappedParameters: [ParameterSpec] {
        switch self {
        case .triangulateFaces: return [
            .init("color","Color",0,16777215,16777215,midi:false,step:1,unit:"sRGB24"),
            .init("lines","Lines",0,1,1,choices:["Off","On"],midi:true),
            .init("line_ends","Line ends",0,1,0,choices:["edges", "centers"],midi:true),
            .init("edge_margin","Edge margin",0.0,80.0,0.0),
            .init("thickness","Line thickness",0.5,20.0,2.0),
            .init("glow","Line glow",0.0,1.0,0.6),
            .init("glow_radius","Glow radius",0.0,80.0,16.0,step:1),
            .init("pulses","Graph pulses",0,1,0,choices:["Off","On"],midi:true),
            .init("pulse_mode","Pulse mode",0,1,0,choices:["wave", "route"],midi:true),
            .init("pulse_start","Start",0,4,0,choices:["center", "first", "last", "random", "face"],midi:true),
            .init("pulse_end","End",0,4,0,choices:["farthest", "first", "last", "random", "face"],midi:true),
            .init("pulse_direction","Direction",0,2,0,choices:["forward", "reverse", "bounce"],midi:true),
            .init("pulse_speed","Pulse speed",0.05,4.0,0.6),
            .init("pulse_rate","Pulse rate",0.1,8.0,1.0),
            .init("pulse_width","Pulse width",0.02,0.5,0.15),
            .init("pulse_amount","Pulse amount",0.0,1.0,1.0),
            .init("sparkle","Crackle",0.0,1.0,0.0)
        ]
        case .boxWaterfall: return [
            .init("speed","Speed",0.0,3.0,0.65),
            .init("density","Streams",1.0,32.0,8.0),
            .init("width","Width",0.05,1.0,0.35),
            .init("foam","Foam",0.0,1.0,0.6),
            .init("brightness","Brightness",0.0,1.0,0.85),
            .init("turbulence","Turbulence",0.0,1.0,0.35),
            .init("color","Color",0,16777215,5618687,midi:false,step:1,unit:"sRGB24")
        ]
        case .sphereGimbal: return [
            .init("trails","Trail count",1.0,32.0,24.0,step:1),
            .init("speed","Orbit speed (rev/s)",0.0,60.0,2.0),
            .init("tail","Tail length",0.005,0.25,0.025),
            .init("fade_start","Fade start",0.0,0.95,0.0),
            .init("tail_fade","Tail fade",0.0,1.0,1.0),
            .init("spread","Lateral spread",0.0,0.25,0.035),
            .init("width","Line width",0.002,0.05,0.012),
            .init("pose_x","X orientation",-180.0,180.0,0.0),
            .init("pose_y","Y orientation",-180.0,180.0,0.0),
            .init("pose_z","Z orientation",-180.0,180.0,0.0),
            .init("rotate_x","X rotation rate",-360.0,360.0,0.0,step:1),
            .init("rotate_y","Y rotation rate",-360.0,360.0,0.0,step:1),
            .init("rotate_z","Z rotation rate",-360.0,360.0,0.0,step:1),
            .init("brightness","Brightness",0.0,1.5,1.0),
            .init("color","Color",0,16777215,5630719,midi:false,step:1,unit:"sRGB24")
        ]
        case .boxEdges: return [
            .init("color","Color",0,16777215,16777215,midi:false,step:1,unit:"sRGB24"),
            .init("thickness","Width",0.5,20.0,3.0),
            .init("brightness","Brightness",0.0,1.0,1.0)
        ]
        case .traceSnake: return [
            .init("speed","Speed",0.0,2.0,0.5),
            .init("beat_sync","Beat sync",0,1,0,choices:["Off","On"],midi:true),
            .init("beat_speed","Laps/beat",0.0,1.0,0.25),
            .init("tail","Tail length",0.02,1.0,0.25),
            .init("drag","Drag trail",0.0,1.0,0.5),
            .init("tint","Color",0,16777215,16723592,midi:false,step:1,unit:"sRGB24"),
            .init("rainbow","Rainbow",0.0,1.0,0.0)
        ]
        case .tracePulse: return [
            .init("tint","Color",0,16777215,16777215,midi:false,step:1,unit:"sRGB24"),
            .init("beat_sync","Beat sync",0,1,0,choices:["Off","On"],midi:true),
            .init("rate","Pulses / s",0.02,10.0,0.5),
            .init("per_beat","Pulses/beat",0.25,4.0,1.0),
            .init("on_time","On time",0.1,0.9,0.5),
            .init("attack","Attack",0.0,1.0,0.05),
            .init("release","Release",0.0,1.0,0.1),
            .init("floor","Floor glow",0.0,0.5,0.0),
            .init("curve","Softness",0.25,4.0,1.0)
        ]
        case .traceRainbow: return [
            .init("speed","Speed",-2.0,2.0,0.25),
            .init("spread","Hue spread",0.1,4.0,1.0),
            .init("brightness","Brightness",0.0,1.0,1.0),
            .init("pulse","Beat pulse",0.0,1.0,0.0)
        ]
        case .traceSolid: return [
            .init("tint","Color",0,16777215,4202592,midi:false,step:1,unit:"sRGB24"),
            .init("breathe","Beat breathe",0.0,1.0,0.0)
        ]
        default: return []
        }
    }
}

public extension Node {
    var mappedRecipeParameters: [String:Any] {
        var result: [String:Any] = [:]
        for spec in kind.mappedParameters {
            let n = spec.quantized(value(spec.key))
            switch spec.valueKind {
            case .color: result[spec.key] = String(format:"#%06x",Int(n))
            case .toggle: result[spec.key] = n != 0
            case .choice: result[spec.key] = spec.choices?[Int(n)]
            default: result[spec.key] = n
            }
        }
        for (key,identifier) in mappedFaceIDs ?? [:] { result[key] = identifier }
        return result
    }
}
