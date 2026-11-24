import Foundation

extension MeshGradientStyle {
    public struct Preset: Sendable {
        public let name: String
        public let source: String
        public let author: String
        public let config: String
        public init(name: String,source: String,author: String,config: String) { self.name=name;self.source=source;self.author=author;self.config=config }
    }
    public static func applyPreset(_ index: Int,to node: inout Node) throws {
        guard presets.indices.contains(index),let data=presets[index].config.data(using:.utf8),let config=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw GraphError("Unknown mesh preset") }
        try importConfig(config,to:&node)
    }
    public static func importConfig(_ config: [String:Any],to node: inout Node) throws {
        guard node.kind == .meshGradient,let regions=config["nodes"] as? [[String:Any]],!regions.isEmpty,regions.count <= maxPoints else { throw GraphError("Expected 1–40 mesh regions") }
        func num(_ n: [String:Any],_ key: String,_ fallback: Double) throws -> Double {
            guard let raw=n[key] else { return fallback };guard let v=raw as? Double,v.isFinite else { throw GraphError("Invalid mesh value: \(key)") };return v
        }
        func packed(_ raw: Any?,_ fallback: Double) throws -> Double {
            guard let raw else { return fallback };guard let hex=raw as? String,hex.count==7,hex.first=="#",let c=UInt32(hex.dropFirst(),radix:16) else { throw GraphError("Expected #RRGGBB mesh color") };return Double(c)
        }
        func degrees(_ n: Double) -> Double { let a=n*180/Double.pi;let m=(a+180).truncatingRemainder(dividingBy:360);return (m<0 ? m+360:m)-180 }
        var next=Node(kind:.meshGradient),detail=Detail()
        // Motion belongs to the performance, so switching a visual preset retains it.
        for key in ["motion","speed","movement","motionX","motionY","motionPhase","motionBoundary"] { next.parameters[key]=value(node,key) }
        next.parameters["count"]=Double(regions.count);next.parameters["fieldStyle"]=1
        next.parameters["softness"]=try num(config,"soft",0.1)/0.2
        next.parameters["grain"]=try num(config,"grain",0.02)/0.15
        next.parameters["grainSize"]=try num(config,"grainSize",1)
        next.parameters["grainDensity"]=try num(config,"density",1.4)/2
        next.parameters["seed"]=try num(config,"seed",427)
        let mode=config["blendMode"] as? String ?? "normal"
        let modes=["normal":1,"linear":2,"oklab":3,"multiply":4,"screen":5,"overlay":6,"softlight":7,"lighten":8,"darken":9]
        guard let blending=modes[mode] else { throw GraphError("Unsupported mesh blend mode: \(mode)") };next.parameters["blendSpace"]=Double(blending)
        next.parameters["grainType"]=Double(["mono":0,"duo":1,"multi":2][config["grainType"] as? String ?? "mono"] ?? 0)
        if let colors=config["grainColors"] as? [String:Any] {
            next.parameters["grainColor"]=try packed(colors[(next.parameters["grainType"] == 1) ? "duoA":"mono"],16777215)
            next.parameters["grainColor2"]=try packed(colors["duoB"],255)
        } else if next.parameters["grainType"] == 1 { next.parameters["grainColor"]=16776960 }
        if let adj=config["adj"] as? [String:Any] {
            for (key,source,fallback) in [("hue","hue",0.0),("saturation","sat",1),("brightness","bri",1),("temperature","temp",0)] { next.parameters[key]=try num(adj,source,fallback) }
        }
        let longSide=max(try num(config,"w",1600),try num(config,"h",1000))
        for (i,r) in regions.enumerated() {
            let type=r["type"] as? String ?? "circle"
            guard let shape=["circle":0,"line":1,"arc":2,"stroke":3][type] else { throw GraphError("Unsupported mesh shape: \(type)") }
            next.parameters["shape\(i)"]=Double(shape)
            let angle=try num(r,"th",0),axis=try num(r,"th2",angle+Double.pi/2),bend=try num(r,"phi",0.35)
            let raw:[String:Double] = ["x":try num(r,"x",0.5),"y":try num(r,"y",0.5),"color":try packed(r["color"],0),"left":try num(r,"sl",0.5),"right":try num(r,"sr",0.5),"top":try num(r,"st",0.5),"bottom":try num(r,"sb",0.5),"angle":degrees(angle),"axisAngle":degrees(axis),"hardness":try num(r,"k",2.2),"width":try num(r,"sw",0.3),"bend":degrees(bend),"opacity":try num(r,"a",1),"linked":r["linked"] as? Bool == false ? 0:1,"overlay":r["occ"] as? Bool == true ? 1:0,"feather":try num(r,"os1",3)/longSide,"featherB":try num(r,"os2",3)/longSide,"featherAngle":try num(r,"oa",0),"leftAngle":degrees(try num(r,"al",angle+Double.pi-bend)),"rightAngle":degrees(try num(r,"ar",angle+bend)),"topAngle":degrees(try num(r,"at",axis+Double.pi)),"bottomAngle":degrees(try num(r,"ab",axis)),"gradient":r["grad"] as? Bool == true ? 1:0,"gradientAngle":try num(r,"gradAngle",0),"gradientEase":Double(["linear":0,"in":1,"out":2,"inout":3][r["gradEase"] as? String ?? "linear"] ?? 0)]
            for (key,v) in raw { next.parameters["\(key)\(i)"]=v }
            if shape==3 {
                next.parameters["brushBase\(i)"]=raw["hardness"]
                guard let pts=r["pts"] as? [[Double]],pts.count>=2,pts.count<=maxStrokePoints,pts.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else { throw GraphError("Brush paths require 2–192 XY points") }
                let stops=(r["stops"] as? [[String:Double]] ?? [["t":0,"m":1],["t":1,"m":1]]).sorted { ($0["t"] ?? 0)<($1["t"] ?? 0) }
                var lengths=[0.0];for j in 1..<pts.count { lengths.append(lengths.last!+hypot(pts[j][0]-pts[j-1][0],pts[j][1]-pts[j-1][1])) }
                detail.paths[String(i)]=pts.enumerated().map { j,p in
                    let t=lengths[j]/max(lengths.last!,1e-9);var multiplier=stops.first?["m"] ?? 1
                    for k in 1..<stops.count { let a=stops[k-1],b=stops[k];if t >= (a["t"] ?? 0) { let u=max(0,min(1,(t-(a["t"] ?? 0))/max((b["t"] ?? 1)-(a["t"] ?? 0),1e-9)));multiplier=(a["m"] ?? 1)*(1-u)+(b["m"] ?? 1)*u } }
                    return [p[0],p[1],max(1,min(10000,(raw["hardness"] ?? 2.2)*multiplier))]
                }
            }
            if let stops=r["gradStops"] as? [[String:Any]],stops.count>=2 {
                guard stops.count<=8 else { throw GraphError("Mesh fills support up to eight stops") }
                detail.stops[String(i)]=try stops.map { [try num($0,"t",0),try packed($0["color"],raw["color"] ?? 0),try num($0,"a",1)] }
            }
        }
        for spec in parameters {
            let v=value(next,spec.key)
            guard v.isFinite,v>=spec.min,v<=spec.max else { throw GraphError("Imported mesh \(spec.key) is outside supported range") }
        }
        node.parameters=next.parameters;node.text=detail.text
    }
    public static func addRegion(to node: inout Node,shape: Int = 0,position: Position = .init(0.5,0.5)) throws -> Int {
        guard node.kind == .meshGradient else { throw GraphError("Expected Mesh Gradient node") }
        let count=Int(value(node,"count"));guard count<maxPoints else { throw GraphError("Mesh region limit is 40") }
        let initial=Node(kind:.meshGradient)
        for key in regionPrefixes { node.parameters["\(key)\(count)"]=value(initial,"\(key)\(count)") }
        node.parameters["count"]=Double(count+1);node.parameters["fieldStyle"]=1
        node.parameters["shape\(count)"]=Double(shape);node.parameters["x\(count)"]=position.x;node.parameters["y\(count)"]=position.y
        return count
    }
    public static func removeRegions(_ indices: Set<Int>,from node: inout Node) throws {
        let count=Int(value(node,"count"));guard !indices.isEmpty,indices.allSatisfy({$0>=0 && $0<count}),indices.count<count else { throw GraphError("Keep at least one mesh region") }
        let source=node,detail=Detail(text:node.text);var nextDetail=Detail(),target=0
        for i in 0..<count where !indices.contains(i) {
            for key in regionPrefixes { node.parameters["\(key)\(target)"]=value(source,"\(key)\(i)") }
            nextDetail.paths[String(target)]=detail.paths[String(i)];nextDetail.stops[String(target)]=detail.stops[String(i)];target+=1
        }
        for i in target..<maxPoints { for key in regionPrefixes { node.parameters.removeValue(forKey:"\(key)\(i)") } }
        node.parameters["count"]=Double(target);node.text=nextDetail.text
        // Remap modulation targets with their region; removed targets are dropped.
        let survivors=(0..<count).filter { !indices.contains($0) }
        if let mods=source.modulations {
            var remapped=mods.filter { entry in !regionPrefixes.contains { prefix in (0..<maxPoints).contains { entry.key == "\(prefix)\($0)" } } }
            for (new,old) in survivors.enumerated() { for prefix in regionPrefixes { if let m=mods["\(prefix)\(old)"] { remapped["\(prefix)\(new)"]=m } } }
            node.modulations=remapped
        }
    }
    public static func duplicateRegion(_ index: Int,in node: inout Node) throws -> Int {
        guard (0..<Int(value(node,"count"))).contains(index) else { throw GraphError("Unknown mesh region") }
        let source=node,target=try addRegion(to:&node)
        for key in regionPrefixes { node.parameters["\(key)\(target)"]=value(source,"\(key)\(index)") }
        node.parameters["x\(target)"]=min(3,value(source,"x\(index)")+0.04);node.parameters["y\(target)"]=min(3,value(source,"y\(index)")+0.04)
        var detail=Detail(text:node.text);detail.paths[String(target)]=detail.paths[String(index)];detail.stops[String(target)]=detail.stops[String(index)];node.text=detail.text
        for prefix in regionPrefixes { if let m=source.modulations?["\(prefix)\(index)"] { if node.modulations == nil { node.modulations=[:] };node.modulations?["\(prefix)\(target)"]=m } }
        return target
    }
}

extension MeshGradientStyle {
    public static func validate(_ node: Node) throws {
        let count=value(node,"count")
        guard count.rounded()==count else { throw GraphError("Mesh region count must be an integer") }
        guard let text=node.text,!text.isEmpty else { return }
        guard let data=text.data(using:.utf8),let detail=try? JSONDecoder().decode(Detail.self,from:data) else { throw GraphError("Invalid mesh path/fill JSON") }
        for (key,path) in detail.paths {
            guard let i=Int(key),(0..<maxPoints).contains(i),path.count>=2,path.count<=maxStrokePoints,path.allSatisfy({ p in p.count==3 && p.allSatisfy(\.isFinite) && abs(p[0])<=10 && abs(p[1])<=10 && (1...10000).contains(p[2]) }) else { throw GraphError("Invalid mesh brush path") }
        }
        for (key,stops) in detail.stops {
            guard let i=Int(key),(0..<maxPoints).contains(i),(2...8).contains(stops.count),stops.allSatisfy({ p in p.count==3 && p.allSatisfy(\.isFinite) && (0...1).contains(p[0]) && (0...16777215).contains(p[1]) && p[1].rounded()==p[1] && (0...1).contains(p[2]) }) else { throw GraphError("Invalid mesh fill stops") }
        }
    }
}

extension Graph {
    public mutating func removeMeshRegions(_ indices: Set<Int>,node id: UUID) throws {
        guard let index=nodes.firstIndex(where:{$0.id==id}),nodes[index].kind == .meshGradient else { throw GraphError("Expected Mesh Gradient node") }
        let count=Int(MeshGradientStyle.value(nodes[index],"count")),survivors=(0..<count).filter {!indices.contains($0)}
        try MeshGradientStyle.removeRegions(indices,from:&nodes[index])
        midiMappings=midiMappings?.compactMap { binding in
            guard binding.node==id else {return binding}
            for prefix in MeshGradientStyle.regionPrefixes {
                for old in 0..<MeshGradientStyle.maxPoints where binding.key=="\(prefix)\(old)" {
                    guard let new=survivors.firstIndex(of:old) else {return nil}
                    var next=binding;next.key="\(prefix)\(new)";return next
                }
            }
            return binding
        }
    }
}
