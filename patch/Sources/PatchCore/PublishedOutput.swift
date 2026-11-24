import Foundation

public struct OutputPublication: Codable, Equatable, Sendable {
    public var mode: String
    public var name: String?
    public init(mode: String = "auto", name: String? = nil) { self.mode = mode; self.name = name }
}
public struct PublishedPort: Equatable, Sendable {
    public let nodeID: UUID
    public let portID: String
    let hostKey: String
    public let type: PortType
    public let name: String
    public let listed: Bool
    /// Published by hand (⌘S or Published in the inspector), as opposed to an output node publishing itself.
    public let explicit: Bool
    public var id: String { "patch:\(nodeID.uuidString):\(hostKey)" }
    /// Hand-published outputs carry their node's name so they can be picked from a Syphon source list.
    public var streamName: String { explicit ? "\(name) · \(nodeID.uuidString)" : "Patch · \(nodeID.uuidString) · \(hostKey)" }
}
extension Node {
    public var publishablePortIDs: [String] {
        switch kind {
        case .apc40: return []
        case .syphon, .ndi, .window, .projector: return ["Video"]
        case .publishPalette: return ["Palette"]
        default: return kind.ports(output:true).map(\.id)
        }
    }

    /// These IDs already occur in VJ shows and Syphon stream names. Freeze each
    /// binding by socket ID. New outputs use the socket ID as their host identity.
    private static let hostPublicationKeys: [NodeKind:[String:String]] = {
        var keys: [NodeKind:[String:String]] = [:]
        let video: [NodeKind] = [
            .fieldRender, .profileDecoder, .rasterSynth, .chromaDecoder, .voltageVisualizer, .voltageFluid,
            .oscilloscope, .posterText, .posterComposer, .powerGlitch, .liveStream, .mux, .projectionDots,
            .shaderEffect, .ledMatrix, .pictureInPicture, .channelSplit, .channelColors, .crop, .poseRender,
            .faceReplace, .faceBoxes, .scene, .pattern, .image, .text, .webcam, .waveform, .audioVisualizer,
            .render, .shader, .dither, .halftone, .diffusion, .modulation, .crt, .blend, .color, .ndiIn,
            .video, .syphon, .ndi, .window, .projector
        ]
        for kind in video { keys[kind] = ["Video":"0"] }
        for kind: NodeKind in [.palette,.videoPalette,.paletteAdjust,.publishPalette] { keys[kind] = ["Palette":"0"] }
        for kind: NodeKind in [.videoCollection,.glowFaces,.graphInkFlow,.graphParticles,.graphPulse,.graphClouds,.graphCloudParticles,.flashFaces,.surfaceGate] { keys[kind] = ["Collection":"0"] }
        for kind: NodeKind in [.audioEnvelope,.lfo,.noise] { keys[kind] = ["Control":"0"] }
        keys[.lightningPulses] = ["Trace":"0"]
        keys[.meshGradient] = ["Video":"0","Palette":"1"]
        keys[.ab] = ["Video":"0","Collection":"1"]
        keys[.layerMux] = ["Layers":"0","Video":"1"]
        return keys
    }()

    fileprivate func publicationHostKey(_ portID: String) -> String {
        Self.hostPublicationKeys[kind]?[portID] ?? "socket."+portID
    }
    public var publishableTypes: [PortType] {
        if kind == .apc40 { return [] }
        if kind == .syphon || kind == .ndi || kind == .window || kind == .projector { return [.video] }
        if kind == .publishPalette { return [.palette] }
        return kind.outputTypes
    }
    /// Only dedicated output nodes and A/B publish without being asked; every other
    /// node is published explicitly (⌘S on the canvas, or Published in its inspector).
    public var publishesAutomatically: Bool { [.syphon,.ndi,.window,.projector,.publishPalette,.ab].contains(kind) }
}
extension Graph {
    /// Includes unlisted ports so a saved consumer survives graph extensions or hiding.
    public var publishablePorts: [PublishedPort] {
        nodes.flatMap { node -> [PublishedPort] in
            let ids = node.publishablePortIDs, types = node.publishableTypes
            return zip(ids,types).compactMap { id,type in
                guard [.video,.collection,.trace,.palette,.control].contains(type) else { return nil }
                let publication = node.publications?[id] ?? OutputPublication()
                let name = publication.name.flatMap { $0.isEmpty ? nil : $0 } ?? (node.name + (types.count > 1 ? " · " + type.rawValue.capitalized : ""))
                return PublishedPort(nodeID:node.id,portID:id,hostKey:node.publicationHostKey(id),type:type,name:name,
                    listed:publication.mode == "on" || (publication.mode == "auto" && node.publishesAutomatically),
                    explicit:publication.mode == "on" && !node.publishesAutomatically)
            }
        }
    }
    public mutating func publish(_ id: UUID, portID: String, mode: String, name: String?) throws {
        guard ["auto","on","off"].contains(mode), let index = nodes.firstIndex(where: { $0.id == id }),
              publishablePorts.contains(where: { $0.nodeID == id && $0.portID == portID }) else { throw GraphError("Invalid published output or mode") }
        var publications = nodes[index].publications ?? [:]
        publications[portID] = OutputPublication(mode:mode,name:name)
        nodes[index].publications = publications
    }
}
public enum CollectionStyle {
    public static let themeNames = ["Neon", "Ice", "Fire", "Candy", "RGB", "Custom"]
    public static let themes: [[UInt32]] = [
        [0xff00aa,0x00ffff,0xaaff00,0x7733ff,0xff6600,0xffff00],
        [0x00bbff,0xcceeff,0x2255ff,0x44ffdd,0x8877ff,0xffffff],
        [0xff2200,0xff8800,0xffcc00,0xff0055,0xff5500,0xfff0aa],
        [0xff44aa,0x55eeff,0xaa66ff,0xffee55,0xff99cc,0x66ffbb],
        [0xff0000,0x00ff00,0x0000ff,0xffff00,0x00ffff,0xff00ff]
    ]
    public static let colorParameters: [ParameterSpec] = [
        .init("theme","Color theme",0,5,0,choices:themeNames,midi:false,step:1),
        .init("colors","Colors",2,6,4,midi:false,step:1)
    ] + (0..<6).map { .init("color\($0)","Color \( $0+1)",0,16777215,Double(themes[0][$0]),midi:false,step:1) }
    public static func palette(_ node: Node) -> ColorPalette {
        if node.kind == .glowFaces { return .init([PaletteColor(hex:UInt32(node.value("color")))]) }
        let theme=max(0,min(5,Int(node.value("theme")))), count=max(2,min(6,Int(node.value("colors"))))
        return .init((0..<count).map { PaletteColor(hex:theme==5 ? UInt32(node.value("color\($0)")) : themes[theme][$0]) })
    }
    public static let glowParameters: [ParameterSpec] = [
        .init("brightness","Brightness",0,1,0.7),
        .init("center_glow","Center glow",0,1,1),
        .init("falloff","Glow falloff",0.25,6,1.5),
        .init("color","Color",0,16777215,16777215,midi:false,step:1,unit:"sRGB24"),
        .init("previewFaces","Preview surfaces",1,64,12,midi:false,step:1)
    ]
    public static let inkParameters: [ParameterSpec] = [
        .init("particles","Particles",8,192,128,step:1),
        .init("dwell","Residence (s)",0.1,10,2.4), .init("travel","Transfer (s)",0.08,5,0.8),
        .init("speed","Speed",0,4,1), .init("spin","Current speed",-4,4,0.65),
        .init("exploration","Surface exploration",0,1,1),
        .init("markStyle","Mark style",0,2,0,choices:["Grain","Circles","Glass"],midi:true,step:1),
        .init("glassFrost","Glass defocus",0,1,0.55), .init("glassRefraction","Glass refraction",0,1,0.5),
        .init("orbit","Spread",0.05,0.4,0.32), .init("depth","Depth",0,1,0),
        .init("size","Grain size",0.003,0.08,0.014), .init("stagger","Stream spread",0,0.8,0.65),
        .init("trail","Persistence (s)",0,0.5,0.12), .init("brightness","Opacity",0,1,0.95),
        .init("turbulence","Turbulence",0,2,1), .init("pulse","Breathing",0,1,0.45),
        .init("glow","Edge light",0,1,0.09), .init("seed","Seed",0,65535,7,step:1),
        .init("previewFaces","Preview surfaces",1,64,10,midi:false,step:1)
    ] + colorParameters
    public static let particleParameters: [ParameterSpec] = [
        .init("particles","Particles",1,64,24,step:1),
        .init("dwell","Swirl duration (s)",0.1,10,1), .init("travel","Transfer duration (s)",0.08,5,0.45),
        .init("speed","Speed",0,4,1), .init("spin","Orbit turns / second",-4,4,1.2),
        .init("orbit","Orbit radius",0.05,0.4,0.28), .init("depth","3D depth",0,1,0.75),
        .init("size","Particle size",0.003,0.08,0.023), .init("stagger","Arrival spread",0,0.8,0.12),
        .init("trail","Trail (s)",0,0.5,0.12), .init("brightness","Brightness",0,1,1),
        .init("seed","Seed",0,65535,1,step:1),
        .init("previewFaces","Preview surfaces",1,64,10,midi:false,step:1)
    ] + colorParameters
    public static let graphParameters: [ParameterSpec] = [
        .init("speed","Hops / second",0,16,2), .init("trail","Trail (hops)",0.1,8,1.5),
        .init("brightness","Brightness",0,1,1), .init("seed","Seed",0,65535,1,step:1),
        .init("previewFaces","Preview surfaces",1,64,12,midi:false,step:1)
    ] + colorParameters
    /// Clear sky: colors paint the clouds. Color sky: color 1 fills the sky and the rest paint the clouds.
    public static let cloudColors: [UInt32] = [0xF6E3A1,0xF4B3CF,0xADE1E8,0xBBA8E2,0xB7DCCC,0xF8C6A1]
    public static let cloudParameters: [ParameterSpec] = [
        .init("sky","Sky",0,1,0,choices:["Clear","Color"],midi:true,step:1),
        .init("clouds","Cloud strips",1,Double(cloudLimit),7,step:1),
        .init("speed","Drift (hops / second)",0,2,0.12), .init("length","Strip length (hops)",0.1,6,1.6),
        .init("width","Strip width",0.01,0.5,0.11), .init("wander","Wander",0,1,0.45),
        .init("softness","Defocus",0,1,0.7), .init("density","Density",0,1,0.55),
        .init("texture","Cloud texture",0,1,0.6), .init("haze","Sky wisps",0,1,0.3),
        .init("wind","Wind angle",-180,180,-8), .init("grain","Grain",0,1,0.18),
        .init("colorMode","Cloud colors",0,1,0,choices:["Single","Palette"],midi:true,step:1),
        .init("brightness","Opacity",0,1,1), .init("seed","Seed",0,65535,3,step:1),
        .init("previewFaces","Preview surfaces",1,64,12,midi:false,step:1)
    ] + colorParameters.map { p in
        if p.key == "theme" { return .init(p.key,p.title,p.min,p.max,5,choices:p.choices,midi:false,step:1) }
        if p.key == "colors" { return .init(p.key,p.title,p.min,p.max,4,midi:false,step:1) }
        guard p.key.hasPrefix("color"),let i=Int(p.key.dropFirst(5)) else { return p }
        return .init(p.key,p.title,p.min,p.max,Double(cloudColors[i]),midi:false,step:1)
    }
    public static let cloudParticleParameters: [ParameterSpec] = cloudParameters.map { p in
        switch p.key {
        case "clouds": return .init(p.key,"Cloud groups",1,8,4,step:1)
        case "length": return .init(p.key,"Spread along route",0.1,6,1.6)
        case "width": return .init(p.key,"Particle size",0.01,0.5,0.11)
        case "wander": return .init(p.key,"Turbulence",0,1,0.55)
        default: return p
        }
    } + [.init("detail","Particles per group",8,24,16,step:1)]

    public static let cloudLimit = 24

    public static let parameters: [ParameterSpec] = [
        .init("pattern","Pattern",0,5,0,choices:["Alternate","Strobe","Chase","Scatter","Wave","Shuffle"]),
        .init("speed","Speed",0,16,2), .init("onTime","On time",0.05,1,0.8),
        .init("fade","Fade",0,1,0), .init("brightness","Brightness",0,1,1),
        .init("seed","Seed",0,65535,1,step:1),
        .init("previewFaces","Preview surfaces",1,64,12,midi:false,step:1)
    ]
}
