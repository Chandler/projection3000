import Foundation

public enum LEDMatrixStyle {
    public static var parameters: [ParameterSpec] { [
        .init("columns","Columns",8,320,112,step:1), .init("rows","Rows",4,160,28,step:1),
        .init("grid","Grid spacing",0,1,0,choices:["Even spacing","Manual rows"]),
        .init("shape","Pixel shape",0,3,0,choices:["Circle","Square","Diamond","Rounded square"]),
        .init("size","Dot size",0.08,0.95,0.42),
        .init("sample","Sample",0,1,1,choices:["Center","Cell average"]),
        .init("color","Color",0,1,0,choices:["Tinted luminance","Source color"]),
        .init("hue","Hue",0,1,0.61), .init("saturation","Saturation",0,1,1), .init("brightness","Brightness",0,1,1),
        .init("gain","Signal gain",0,6,1.8), .init("gamma","Signal gamma",0.2,3,1.3),
        .init("black","Black cutoff",0,0.95,0.035), .init("idle","Idle brightness",0,0.2,0.004),
        .init("glow","Local glow",0,1,0.25), .init("whiteHot","White-hot peaks",0,1,0),
        .init("invert","Invert signal",0,1,0,choices:["Off","On"])
    ] }
}
public enum DataStreamStyle {
    public static var parameters: [ParameterSpec] { [
        .init("pattern","Algorithm",0,3,0,choices:["Data packets","Travelling waves","Drifting mask","Staggered pulses"]),
        .init("speed","Speed",-4,4,1), .init("rows","Signal rows",4,160,28,step:1),
        .init("rate","Flow rate",0,12,3.8), .init("packets","Packets across",1,24,6),
        .init("length","Pulse length",0.03,1,0.42), .init("density","Density",0,1,0.8),
        .init("variance","Row speed variation",0,1,0.75),
        .init("mask","Mask depth",0,1,0.9), .init("maskScale","Mask scale",1,16,4),
        .init("maskSpeed","Mask motion",0,5,0.8), .init("bands","Rising dark bands",0,8,2),
        .init("jitter","Flicker",0,1,0.4), .init("refresh","Flicker rate (Hz)",1,60,24),
        .init("seed","Seed",0,65535,17,step:1)
    ] }
}

public enum BlockerFieldStyle {
    public static var parameters: [ParameterSpec] { [
        .init("speed","Playback speed",0,3,1), .init("rows","Stream rows",4,160,36,step:1),
        .init("rate","Flow speed · widths/s",0.1,5,1.5), .init("segments","Launches per second",0.2,12,3),
        .init("tail","Stream duty",0.1,1,0.95), .init("density","Launch probability",0,1,0.95),
        .init("variance","Row speed variation",0,1,0.35),
        .init("depth","Block strength",0,1,1), .init("blockers","Blocker count",1,12,5),
        .init("motion","Blocker movement",0,4,0.8), .init("height","Blocker height · rows",0.5,16,4),
        .init("jitter","Brightness jitter",0,1,0.1), .init("refresh","Jitter rate",1,60,20),
        .init("seed","Seed",0,65535,37,step:1)
    ] }
}


public enum StreakFieldStyle {
    public static var parameters: [ParameterSpec] { [
        .init("speed","Playback speed",0,3,1),
        .init("rows","Rows",10,42,28,step:1),
        .init("travel","Travel speed · widths/s",0.35,3.5,1.6),
        .init("length","Streak length",0.045,0.65,0.24),
        .init("activity","Activity · launches/s",1,17,8),
        .init("grouping","Row grouping",0,1,0.76),
        .init("stagger","Row stagger · seconds",0,0.07,0.018),
        .init("tail","Tail fade",0,1,0.64),
        .init("seed","Seed",0,65535,731,step:1)
    ] }
}
public enum StreakGlowStyle {
    public static let functions = ["Streaks","Gaussian noise","Lava lamp","Clouds","Ripples","Sweep","Plasma","Breathe"]
    public static var parameters: [ParameterSpec] { [
        .init("function","Function",0,7,0,choices:functions,midi:true,step:1),
        .init("speed","Evolution speed",0,3,1),
        .init("mode","Exposure mode",0,2,2,choices:["Darken only","Brighten only","Both"]),
        .init("invert","Invert regions",0,1,0,choices:["Off","On"]),
        .init("depth","Glow field depth",0,2,1.25),
        .init("scale","Field scale",0.25,3,1),
        .init("gain","Gain",0,3,1),
        .init("detail","Detail",1,6,2),
        .init("warp","Warp",0,2,0.6),
        .init("contrast","Contrast",0.25,4,1),
        .init("angle","Direction (°)",-180,180,90),
        .init("stretch","Stretch",0.25,4,1),
        .init("bias","Balance",-1,1,0),
        .init("pulse","Breathing",0,1,0),
        .init("seed","Seed",0,999,1,step:1)
    ] }
    /// Order of the light-field data block (a, b, c, d.xy); time follows at index 15.
    public static let keys = ["depth","scale","gain","mode","invert","function","detail","warp","contrast","angle","stretch","bias","seed","pulse"]
    /// Controls that have no effect for a function are hidden in the inspector.
    public static func shows(_ key: String, function: Int) -> Bool {
        let used: [String]
        switch function {
        case 0: used = ["scale"]
        case 1, 2, 5: used = ["scale","detail","warp","angle","stretch","seed"]
        case 3, 4: used = ["scale","detail","warp","stretch","seed"]
        case 6: used = ["scale","warp","stretch","seed"]
        default: used = ["warp","seed"]
        }
        return !["scale","detail","warp","angle","stretch","seed"].contains(key) || used.contains(key)
    }
}

public enum WaterfallFieldStyle {
    public static var parameters: [ParameterSpec] { [
        .init("rows","Flow rows",4,160,28,step:1),
        .init("rate","Flow speed · widths/s",0.05,20,2.5),
        .init("blockers","Blocker count",0,8,4),
        .init("pattern","Block behavior",0,3,0,choices:["Random","Alternating bands","Sweep","Smooth wander"]),
        .init("widthMin","Minimum width · rows",1,160,2),
        .init("widthMax","Maximum width · rows",1,160,7),
        .init("durationMin","Minimum duration · s",0.02,10,0.12),
        .init("durationMax","Maximum duration · s",0.02,10,0.65),
        .init("gap","Gap between blocks · s",0,5,0.2),
        .init("probability","Block probability",0,1,1),
        .init("motion","Movement range · rows",0,160,8),
        .init("motionRate","Movement rate · Hz",0,12,1.2),
        .init("tail","Soft tail · matrix widths",0,1,0),
        .init("seed","Random seed",0,65535,193,step:1)
    ] }
}


public enum CellularFieldStyle {
    public static var parameters: [ParameterSpec] { [
        .init("rule","Rule",0,4,3,choices:["Life","HighLife","Seeds","Brian’s Brain","Cyclic waves"],midi:true,step:1),
        .init("rate","Generations / s",0,60,12),
        .init("density","Starting density (%)",0,100,18),
        .init("inject","New cells / generation (%)",0,10,0.2),
        .init("trail","Trail persistence",0,0.98,0.45),
        .init("depth","Block strength",0,1,1),
        .init("output","Output",0,1,0,choices:["Dark blockers","Lit cells"],midi:true,step:1),
        .init("wrap","Edges",0,1,1,choices:["Closed","Wrap"],midi:true,step:1),
        .init("neighbors","Neighborhood",0,1,0,choices:["8 neighbors","4 neighbors"],midi:true,step:1),
        .init("states","Cyclic states",3,16,6,step:1),
        .init("threshold","Cyclic threshold",1,8,1,step:1),
        .init("seed","Seed",0,65535,137,step:1)
    ] }
}
