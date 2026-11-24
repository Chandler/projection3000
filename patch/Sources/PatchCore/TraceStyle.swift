import Foundation

public enum TraceStyle {
    public static let parameters: [ParameterSpec] = [
        .init("rate","Pulses / second",0,2,0.25),
        .init("burst","Burstiness",0,1,0.45),
        .init("speed","Lengths / second",0.05,10,0.2),
        .init("jitter","Speed jitter",0,1,0.35),
        .init("length","Pulse length",0.01,0.35,0.08),
        .init("tail","Afterglow",0,1,0.62),
        .init("crackle","Crackle",0,1,0.38),
        .init("forks","Forks",0,1,0.32),
        .init("top_spray","Top spray",0,1,0.45),
        .init("brightness","Brightness",0,1.5,1),
        .init("single_color","Single color",0,1,0,choices:["Off","On"],midi:true,step:1),
        .init("core","Core",0,16777215,Double(0xf8fbff),midi:false,step:1),
        .init("glow","Glow",0,16777215,Double(0x43a9ff),midi:false,step:1),
        .init("rainbow","Ion color",0,1,0),
        .init("origin","From",0,1,0,choices:["Start","End"],midi:true,step:1),
        .init("start","Start",0,1,0),
        .init("end","End",0,1,1),
        .init("reflect","Reflect",0,1,0,choices:["Off","On"],midi:true,step:1),
        .init("cycle","Phase cycle (s)",0.1,60,4),
        .init("seed","Seed",0,65520,0,midi:false,step:1)
    ]
    public static func recipeParameters(_ node: Node) -> [String:Any] {
        var p: [String:Any] = node.parameters
        for key in ["core","glow"] { p[key]=String(format:"#%06X",UInt32(node.value(key).rounded())) }
        for key in ["single_color","reflect"] { p[key]=node.value(key)>=0.5 }
        p["origin"]=node.value("origin")>=0.5 ? "end":"start"
        return p
    }
}
