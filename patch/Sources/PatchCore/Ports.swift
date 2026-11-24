import Foundation

/// A port ID belongs to the saved graph format. The display name and position may change.
public struct PortSpec: Encodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: PortType
    public let index: Int
    // Used only by the offline v1 converter.
    package let legacyIndex: Int
    private enum CodingKeys: String, CodingKey { case id, name, type, index }
}

private struct Socket {
    let id: String
    let title: String
    let type: PortType
    let legacyIndex: Int
    init(_ id: String, _ type: PortType, _ legacyIndex: Int, title: String? = nil) {
        self.id = id
        self.title = title ?? id
        self.type = type
        self.legacyIndex = legacyIndex
    }
    func port(at index: Int) -> PortSpec {
        PortSpec(id:id, name:title, type:type, index:index, legacyIndex:legacyIndex)
    }
}

extension NodeKind {
    private struct Sockets {
        let ports: [PortSpec]
        let names: [String]
        let types: [PortType]
        init(_ sockets: [Socket]) {
            ports = sockets.enumerated().map { $0.element.port(at:$0.offset) }
            names = sockets.map(\.title)
            types = sockets.map(\.type)
        }
    }
    private static let schemas = Dictionary(uniqueKeysWithValues:allCases.map { kind in
        (kind, (inputs:Sockets(kind.inputSockets), outputs:Sockets(kind.outputSockets)))
    })
    private func sockets(output: Bool) -> Sockets {
        guard let schema = Self.schemas[self] else { preconditionFailure("Missing node schema") }
        return output ? schema.outputs : schema.inputs
    }
    public func ports(output: Bool) -> [PortSpec] { sockets(output:output).ports }
    public var inputs: [String] { sockets(output:false).names }
    public var outputs: [String] { sockets(output:true).names }
    public var inputTypes: [PortType] { sockets(output:false).types }
    public var outputTypes: [PortType] { sockets(output:true).types }
    public var outputType: PortType? { outputTypes.first }

    private var inputSockets: [Socket] {
        switch self {
        case .traceSnake,.tracePulse,.traceRainbow,.traceSolid,.triangulateFaces,.boxWaterfall,.sphereGimbal,.boxEdges: return []
        case .fieldRender:
            return [.init("Field", .field, 0)]
        case .fieldMix:
            return [.init("A", .field, 0), .init("B", .field, 1)]
        case .flashCells, .glowFaces, .graphInkFlow, .graphParticles, .graphPulse, .graphClouds,
             .graphCloudParticles, .flashFaces, .publishPalette, .paletteAdjust, .meshGradient:
            return [.init("Palette", .palette, 0)]
        case .profileEncoder, .chromaEncoder, .projector, .surfaceGate, .shaderEffect, .channelSplit,
             .channelColors, .crop, .yoloPose, .faceDetect, .dither, .halftone, .diffusion, .modulation, .crt,
             .color, .window, .syphon, .ndi:
            return [.init("Video", .video, 0)]
        case .profileAnalog, .profileDecoder:
            return [.init("RGB Profiles", .rgbProfiles, 0)]
        case .rasterSynth, .audioPlugin, .oscilloscope, .audioEnvelope, .audioGain, .audioMono, .audioFilter,
             .audioEQ, .audioOutput, .waveform, .audioVisualizer, .recordAudio:
            return [.init("Audio", .audio, 0)]
        case .vectorCube, .laserLettering, .lightningCellGrid, .vectorScanLines, .vectorLorenz, .slimeMold, .fieldShader, .metroSequencer, .midiIn, .arpeggiator, .vectorShape, .vectorText, .fluidShape, .audioInput,
             .posterText, .apc40, .powerGlitch, .liveStream, .palette, .dotColors, .flipDots, .cellularField,
             .waterfallField, .streakField, .streakGlow, .blockerField, .dataStream, .microphone, .lfo, .noise,
             .scene, .pattern, .image, .video, .text, .webcam, .audio, .lorenz, .shader, .ndiIn, .syphonIn:
            return []
        case .loopmother:
            return [.init("MIDI", .midi, 0), .init("Instrument", .audio, 1)]
        case .midiFilter, .midiTransform, .midiMonitor, .midiOut:
            return [.init("MIDI", .midi, 0)]
        case .midiMerge:
            return [
                .init("MIDI A", .midi, 0),
                .init("MIDI B", .midi, 1),
                .init("MIDI C", .midi, 2),
                .init("MIDI D", .midi, 3)
            ]
        case .chromaDecoder:
            return [.init("Color Audio", .audio, 0), .init("Frame Reference", .chromaReference, 1)]
        case .voltageEncoder:
            return [.init("Path", .vectorPath, 0)]
        case .voltageVisualizer:
            return [
                .init("XY Audio", .audio, 0),
                .init("Draw Rate", .drawRate, 1),
                .init("X", .audio, 2),
                .init("Y", .audio, 3)
            ]
        case .voltageFluid:
            return [
                .init("XY Audio", .audio, 0),
                .init("Draw Rate", .drawRate, 1),
                .init("X", .audio, 2),
                .init("Y", .audio, 3),
                .init("Reflection", .video, 4)
            ]
        case .posterComposer:
            return [
                .init("Video 1", .video, 0),
                .init("Video 2", .video, 1),
                .init("Video 3", .video, 2),
                .init("Video 4", .video, 3),
                .init("Video 5", .video, 4),
                .init("Video 6", .video, 5)
            ]
        case .videoCollection, .mux:
            return [
                .init("Video 1", .video, 0),
                .init("Video 2", .video, 1),
                .init("Video 3", .video, 2),
                .init("Video 4", .video, 3),
                .init("Video 5", .video, 4),
                .init("Video 6", .video, 5),
                .init("Video 7", .video, 6),
                .init("Video 8", .video, 7)
            ]
        case .lightningPulses:
            return [.init("Palette", .palette, 0), .init("Phase", .control, 1)]
        case .videoPalette:
            return [.init("Video", .visual, 0)]
        case .ab:
            return [.init("A", .visual, 0), .init("B", .visual, 1)]
        case .layerMux:
            return [
                .init("Layer 1", .visual, 0),
                .init("Layer 2", .visual, 1),
                .init("Layer 3", .visual, 2),
                .init("Layer 4", .visual, 3),
                .init("Layer 5", .visual, 4),
                .init("Layer 6", .visual, 5),
                .init("Layer 7", .visual, 6),
                .init("Layer 8", .visual, 7)
            ]
        case .projectionDots:
            return [.init("Colors", .dots, 0)]
        case .ledMatrix:
            return [
                .init("Video", .video, 0),
                .init("Field", .field, 1),
                .init("Light", .field, 2)
            ]
        case .pictureInPicture, .blend:
            return [.init("A", .video, 0), .init("B", .video, 1)]
        case .poseRender:
            return [.init("Poses", .poses, 0)]
        case .audioMix:
            return [.init("Audio A", .audio, 0), .init("Audio B", .audio, 1)]
        case .faceReplace:
            return [
                .init("Video A", .video, 0),
                .init("Video B", .video, 1),
                .init("Faces A", .faces, 2),
                .init("Faces B", .faces, 3)
            ]
        case .faceBoxes:
            return [.init("Video", .video, 0), .init("Faces", .faces, 1)]
        case .render:
            return [.init("Geometry", .geometry, 0)]
        case .record:
            return [.init("Video", .video, 0), .init("Audio", .audio, 1)]
        }
    }

    private var outputSockets: [Socket] {
        switch self {
        case .fieldRender, .profileDecoder, .rasterSynth, .chromaDecoder, .voltageVisualizer, .voltageFluid,
             .oscilloscope, .posterText, .posterComposer, .powerGlitch, .liveStream, .mux, .projectionDots,
             .shaderEffect, .ledMatrix, .pictureInPicture, .channelSplit, .channelColors, .crop, .poseRender,
             .faceReplace, .faceBoxes, .scene, .pattern, .image, .text, .webcam, .waveform, .audioVisualizer,
             .render, .shader, .dither, .halftone, .diffusion, .modulation, .crt, .blend, .color, .ndiIn, .syphonIn:
            return [.init("Video", .video, 0)]
        case .fieldShader, .fieldMix, .flashCells, .cellularField, .waterfallField, .streakField, .streakGlow, .blockerField,
             .dataStream:
            return [.init("Field", .field, 0)]
        case .profileEncoder, .profileAnalog:
            return [.init("Rgbprofiles", .rgbProfiles, 0, title:"RGB Profiles")]
        case .metroSequencer:
            return [
                .init("Track A", .midi, 0),
                .init("Track B", .midi, 1),
                .init("Both", .midi, 2)
            ]
        case .loopmother, .audioPlugin, .audioInput, .microphone, .audioGain, .audioMono, .audioMix,
             .audioFilter, .audioEQ, .audio:
            return [
                .init("Stereo / XY", .audio, 0),
                .init("X / Left", .audio, 1),
                .init("Y / Right", .audio, 2)
            ]
        case .midiIn, .midiFilter, .midiTransform, .midiMonitor, .midiMerge, .arpeggiator:
            return [.init("MIDI", .midi, 0)]
        case .chromaEncoder:
            return [
                .init("Color Audio", .audio, 0),
                .init("Frame Reference", .chromaReference, 1),
                .init("X / Left", .audio, 2),
                .init("Y / Right", .audio, 3)
            ]
        case .midiOut, .projector, .publishPalette, .audioOutput, .window, .syphon, .ndi, .record, .recordAudio:
            return []
        case .vectorCube, .laserLettering, .lightningCellGrid, .vectorScanLines, .vectorLorenz, .slimeMold:
            return [.init("Path", .vectorPath, 0), .init("Video", .video, 1)]
        case .vectorShape, .vectorText, .fluidShape:
            return [.init("Path", .vectorPath, 0)]
        case .voltageEncoder:
            return [
                .init("XY Audio", .audio, 0),
                .init("Draw Rate", .drawRate, 1),
                .init("X", .audio, 2),
                .init("Y", .audio, 3)
            ]
        case .triangulateFaces,.boxWaterfall,.sphereGimbal,.boxEdges,.videoCollection, .glowFaces, .graphInkFlow, .graphParticles, .graphPulse, .graphClouds,
             .graphCloudParticles, .flashFaces, .surfaceGate:
            return [.init("Collection", .collection, 0)]
        case .apc40:
            return [
                .init("Fader 1", .control, 0),
                .init("Fader 2", .control, 1),
                .init("Fader 3", .control, 2),
                .init("Fader 4", .control, 3),
                .init("Fader 5", .control, 4),
                .init("Fader 6", .control, 5),
                .init("Fader 7", .control, 6),
                .init("Fader 8", .control, 7),
                .init("Track knob 1", .control, 8),
                .init("Track knob 2", .control, 9),
                .init("Track knob 3", .control, 10),
                .init("Track knob 4", .control, 11),
                .init("Track knob 5", .control, 12),
                .init("Track knob 6", .control, 13),
                .init("Track knob 7", .control, 14),
                .init("Track knob 8", .control, 15),
                .init("Device knob 1", .control, 16),
                .init("Device knob 2", .control, 17),
                .init("Device knob 3", .control, 18),
                .init("Device knob 4", .control, 19),
                .init("Device knob 5", .control, 20),
                .init("Device knob 6", .control, 21),
                .init("Device knob 7", .control, 22),
                .init("Device knob 8", .control, 23),
                .init("Master", .control, 24),
                .init("Crossfader", .control, 25),
                .init("Activator 1", .control, 26),
                .init("Activator 2", .control, 27),
                .init("Activator 3", .control, 28),
                .init("Activator 4", .control, 29),
                .init("Activator 5", .control, 30),
                .init("Activator 6", .control, 31),
                .init("Activator 7", .control, 32),
                .init("Activator 8", .control, 33)
            ]
        case .traceSnake,.tracePulse,.traceRainbow,.traceSolid,.lightningPulses:
            return [.init("Trace", .trace, 0)]
        case .palette, .videoPalette, .paletteAdjust:
            return [.init("Palette", .palette, 0)]
        case .meshGradient:
            return [.init("Video", .video, 0), .init("Palette", .palette, 1)]
        case .ab:
            return [.init("Video", .video, 0), .init("Collection", .collection, 1)]
        case .layerMux:
            return [.init("Layers", .collection, 0), .init("Video", .video, 1)]
        case .dotColors, .flipDots:
            return [.init("Dots", .dots, 0)]
        case .yoloPose:
            return [.init("Poses", .poses, 0)]
        case .audioEnvelope, .lfo, .noise:
            return [.init("Control", .control, 0)]
        case .faceDetect:
            return [.init("Faces", .faces, 0)]
        case .video:
            return [
                .init("Video", .video, 0),
                .init("Stereo Audio", .audio, 1),
                .init("X / Left", .audio, 2),
                .init("Y / Right", .audio, 3)
            ]
        case .lorenz:
            return [.init("Geometry", .geometry, 0)]
        }
    }
}

extension Node {
    public func ports(output: Bool) -> [PortSpec] {
        let ports = kind.ports(output:output)
        return output ? ports : Array(ports.prefix(channelCount))
    }
}
