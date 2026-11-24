import Foundation

public enum LiquidMetalStyle {
    public static let scene: [ParameterSpec] = [
        .init("count","Manual parts",1,24,4,step:1),
        .init("fusion","Fusion",0,1.5,0.6),
        .init("zoom","Zoom",0.3,3,1),
        .init("yaw","Orbit horizontal °",-180,180,0),
        .init("pitch","Orbit vertical °",-80,80,0),
        .init("background","Background",0,2,0,choices:["Transparent","Charcoal","Ivory"]),
        .init("quality","Detail",0,2,1,choices:["Draft","Balanced","Fine"])
    ]
    public static let generation: [ParameterSpec] = [
        .init("construction","Shape source",0,1,0,choices:["Manual","Generated"]),
        .init("seed","Seed",0,999999,42,step:1),
        .init("family","Structure",0,4,0,choices:["Branching liquid","Open loops","Cluster","Liquid sculpture","Splash"]),
        .init("complexity","Complexity",1,6,1,step:1),
        .init("viscosity","Fullness",0,1,0.65),
        .init("flow","Flow deformation",0,1,0.55),
        .init("parts","Parts",3,24,12,step:1),
        .init("branching","Branching",0,1,0.5),
        .init("loops","Extra loops",0,6,2,step:1),
        .init("span","Spread",0.3,2.5,1),
        .init("height","Vertical stretch",0.4,2.5,1.45),
        .init("depth","Depth variation",0,1.5,0.35),
        .init("thickness","Body thickness",0.08,0.65,0.23),
        .init("neck","Bridge thickness",0.025,0.45,0.095),
        .init("curve","Bridge curvature",0,1,0.45),
        .init("variation","Size variation",0,1,0.65),
        .init("stretch","Part elongation",1,3,1.65),
        .init("holes","Carved holes",0,6,2,step:1),
        .init("holeSize","Hole size",0.08,0.65,0.25)
    ]
    public static let lighting: [ParameterSpec] = [
        .init("lightWidth","Studio light width",0.02,1,0.22),
        .init("lightContrast","Light contrast",0,1,0.75),
        .init("coolTint","Cool highlights",0,1,0.5),
        .init("selfReflection","Sculpture reflections",0,1,0),
    ]
    public static let material: [ParameterSpec] = [
        .init("metal","Metal",0,2,0,choices:["Chrome","Gold","Copper"]),
        .init("roughness","Roughness",0,1,0.12),
        .init("reflection","Image / video reflection",0,1,0.8),
        .init("environmentRotation","Reflection rotation °",-180,180,0),
        .init("mapping","Reflection mapping",0,1,0,choices:["Wrap panorama","Mirror image"]),
        .init("studio","Studio lighting",0,2,1),
        .init("exposure","Exposure",0.1,3,1),
        .init("texture","Surface ripple",0,1,0),
        .init("textureScale","Ripple scale",1,40,12),
        .init("motion","Liquid motion",0,1,0),
        .init("speed","Motion speed",0,3,1)
    ]
    public static func ball(_ i: Int) -> [ParameterSpec] {
        let poses: [[Double]] = [[-0.65,0.3,0,0.72],[0.55,0.15,0,0.64],[-0.1,-0.65,0.1,0.57],[0.15,0.95,-0.1,0.43],[-1.2,-0.65,0,0.4],[1.2,0.8,0,0.4],[0,-1.4,0,0.35],[1.2,-0.7,0,0.4]]
        let p=poses[(i-1)%poses.count]
        return [.init("ball\(i)X","X",-3,3,p[0]),.init("ball\(i)Y","Y",-3,3,p[1]),.init("ball\(i)Z","Depth",-3,3,p[2]),.init("ball\(i)Radius","Radius",0.05,1.5,p[3]),.init("ball\(i)StretchX","Stretch X",0.2,3,1),.init("ball\(i)StretchY","Stretch Y",0.2,3,1),.init("ball\(i)StretchZ","Stretch depth",0.2,3,1),.init("ball\(i)Angle","Rotation °",-180,180,0),.init("ball\(i)Cut","Operation",0,1,0,choices:["Add","Carve"]),.init("ball\(i)Parent","Connect to part (0 = none)",0,24,0,step:1)]
    }
    public static let parameters: [ParameterSpec] = scene + material + generation + lighting + (1...24).flatMap { ball($0) } + NodeKind.shaderEffect.parameters.filter { $0.key != "speed" }
    /// Reset appearance and geometry without changing source files, connections or identity.
    public static func reset(_ node: inout Node) {
        node.parameters=Dictionary(uniqueKeysWithValues:parameters.map { ($0.key,$0.initial) })
        let values: [String:Double] = ["construction":1,"family":3,"complexity":3,"seed":42,"span":1,"height":0.9,"depth":0.4,"thickness":0.4,"viscosity":0.7,"flow":0.55,"variation":0.5,"holes":1,"holeSize":0.32,"roughness":0.045,"studio":1.15,"lightWidth":0.65,"lightContrast":0.5,"coolTint":0.08,"reflection":0.25,"exposure":1.2,"texture":0,"selfReflection":0.4,"quality":1,"zoom":1,"yaw":-12,"pitch":15,"motion":0]
        node.parameters.merge(values) { _,new in new }
        node.modulations=nil
    }
    public static func shaderValues(_ node: Node, aspect: Float, hasInput: Bool) -> [SIMD4<Float>] {
        func v(_ keys: [String]) -> SIMD4<Float> { SIMD4(Float(node.value(keys[0])),Float(node.value(keys[1])),Float(node.value(keys[2])),Float(node.value(keys[3]))) }
        var values = [v(["count","fusion","zoom","roughness"]),v(["yaw","pitch","metal","reflection"]),v(["environmentRotation","studio","exposure","background"]),v(["texture","textureScale","motion","quality"]),SIMD4(aspect,hasInput ? 1:0,Float(node.value("mapping")),Float(node.value("seed")))] + (1...8).map { v(["ball\($0)X","ball\($0)Y","ball\($0)Z","ball\($0)Radius"]) }
        let molten = node.value("construction")>=0.5 && node.value("family")>=3
        let geometry = molten ? flowingCurves(node) : primitives(node)
        values += [SIMD4(Float(geometry.count / (molten ? 4:3)),molten ? Float(node.value("family")):0,Float(node.value("viscosity")),Float(node.value("flow"))),v(["lightWidth","lightContrast","coolTint","selfReflection"])]
        if molten { values += [v(["span","height","depth","thickness"]),v(["variation","holeSize","holes","complexity"])] }
        values += geometry
        return values
    }
}
extension Node {
    public var hasLiquidMetalControls: Bool { kind == .shaderEffect && controlStyle == "liquidMetal" }
}
