import Foundation

public enum NodePreviewKind: String, Codable, Sendable { case video, geometry, audio, control, palette, empty }
public enum PortType: String, Codable, Sendable { case rgbProfiles, chromaReference, midi, vectorPath, drawRate, video, geometry, audio, faces, poses, field, control, dots, palette, collection, trace, visual
    public func accepts(_ source: PortType?) -> Bool { guard let source else { return false }; return self == source || (self == .visual && (source == .video || source == .collection)) }
}
public struct ParameterSpec: Codable, Sendable {
    public let key: String
    public let title: String
    public let min: Double
    public let max: Double
    public let initial: Double
    public let choices: [String]?
    public let midi: Bool?
    public let step: Double?
    public var supportsMIDI: Bool { midi ?? (choices == nil && max <= 1_000_000 && key != "seek") }
    public init(_ key: String, _ title: String, _ min: Double, _ max: Double, _ initial: Double, choices: [String]? = nil, midi: Bool? = nil, step: Double? = nil) {
        self.key = key; self.title = title; self.min = min; self.max = max; self.initial = initial; self.choices = choices; self.midi = midi; self.step = step
    }
}
public enum NodeKind: String, Codable, CaseIterable, Sendable {
    case flashCells, profileEncoder, profileAnalog, profileDecoder, rasterSynth, metroSequencer, loopmother, midiIn, midiFilter, midiTransform, midiMonitor, midiMerge, audioPlugin, chromaEncoder, chromaDecoder, arpeggiator, midiOut, vectorShape, vectorText, fluidShape, voltageEncoder, voltageVisualizer, voltageFluid, oscilloscope, audioInput, projector, posterText, posterComposer, videoCollection, apc40, glowFaces, powerGlitch, liveStream, lightningPulses, graphInkFlow, graphParticles, graphPulse, graphClouds, graphCloudParticles, flashFaces, surfaceGate, publishPalette, palette, videoPalette, paletteAdjust, meshGradient, ab, mux, layerMux, dotColors, flipDots, projectionDots, shaderEffect, cellularField, waterfallField, streakField, streakGlow, blockerField, ledMatrix, dataStream, pictureInPicture, channelSplit, channelColors, crop, yoloPose, poseRender, microphone, audioEnvelope, audioGain, audioMono, audioMix, audioFilter, audioEQ, audioOutput, lfo, noise, faceReplace, faceDetect, faceBoxes, scene, pattern, image, video, text, webcam, audio, waveform, audioVisualizer, lorenz, render, shader, dither, halftone, diffusion, modulation, crt, blend, color, window, syphon, ndi, ndiIn, record, recordAudio
    public var title: String {
        switch self {
        case .profileEncoder: return "RGB Profile Encoder"
        case .profileAnalog: return "Profile Analog Lab"
        case .profileDecoder: return "RGB Profile Decoder"
        case .apc40: return "APC40 mkII"
        case .posterText: return "Poster Text (merged into Poster)"
        case .posterComposer: return "Poster"
        case .metroSequencer: return "Metro"
        case .loopmother: return "Loopmother"
        case .chromaEncoder: return "Chroma Encoder"
        case .chromaDecoder: return "Chroma Decoder"
        case .midiIn: return "MIDI In"
        case .midiFilter: return "MIDI Filter"
        case .midiTransform: return "MIDI Transform"
        case .midiMonitor: return "MIDI Monitor"
        case .midiMerge: return "MIDI Merge"
        case .arpeggiator: return "Arpeggiator"
        case .midiOut: return "MIDI Out"
        case .vectorShape: return "Vector Shape"
        case .vectorText: return "Vector Text"
        case .voltageEncoder: return "Voltage Encoder"
        case .voltageVisualizer: return "Voltage Visualizer"
        case .rasterSynth: return "Raster Synth"
        case .fluidShape: return "Fluid Shape"
        case .voltageFluid: return "Voltage Fluid"
        case .oscilloscope: return "Oscilloscope"
        case .audioInput: return "Audio Input"
        case .projector: return "Projector Out"
        case .powerGlitch: return "Power Glitch"
        case .liveStream: return "Live Stream"
        case .lightningPulses: return "Lightning Pulses"
        case .graphInkFlow: return "Graph Ink Flow"
        case .graphParticles: return "Graph Particles"
        case .graphPulse: return "Graph Pulse"
        case .graphClouds: return "Graph Clouds"
        case .graphCloudParticles: return "Graph Cloud Particles"
        case .glowFaces: return "Glow Faces"
        case .flashCells: return "Flash Cells"
        case .flashFaces: return "Flash Faces"
        case .surfaceGate: return "Surface Gate"
        case .videoCollection: return "Video Collection"
        case .publishPalette: return "Publish Palette"
        case .palette: return "Palette"
        case .videoPalette: return "Video to Palette"
        case .paletteAdjust: return "Palette Adjust"
        case .meshGradient: return "Mesh Gradient"
        case .yoloPose: return "YOLO Pose"
        case .poseRender: return "Render Poses"
        case .microphone: return "Microphone"
        case .audioEnvelope: return "Audio Envelope"
        case .audioGain: return "Audio Gain / Pan"
        case .audioMono: return "Audio Mono"
        case .audioMix: return "Audio Mix"
        case .audioPlugin: return "VST3 Effect"
        case .audioEQ: return "Audio EQ / Balance"
        case .audioFilter: return "Audio Filter"
        case .audioOutput: return "Audio Output"
        case .lfo: return "LFO"
        case .noise: return "Noise"
        case .faceReplace: return "Face Replace"
        case .faceDetect: return "Face Detection"
        case .faceBoxes: return "Draw Face Boxes"
        case .scene: return "Pastel Scene"
        case .text: return "Text"
        case .webcam: return "Camera"
        case .audio: return "Audio File"
        case .waveform: return "Waveform"
        case .audioVisualizer: return "Audio Visualizer"
        case .lorenz: return "Lorenz Attractor"
        case .render: return "Render Geometry"
        case .shaderEffect: return "Shader Effect"
        case .shader: return "Shader Animation"
        case .projectionDots: return "Projection Dots"
        case .dotColors: return "Dot Colors"
        case .flipDots: return "Flip Dots"
        case .pattern: return "Test Pattern"
        case .image: return "Image"
        case .video: return "Video"
        case .dither: return "Dither"
        case .halftone: return "Halftone"
        case .diffusion: return "Diffusion Glow"
        case .modulation: return "CRT Modulation"
        case .crt: return "CRT"
        case .layerMux: return "Layer Mux"
        case .mux: return "MUX"
        case .ab: return "A/B Crossfade"
        case .blend: return "Blend"
        case .ledMatrix: return "LED Matrix"
        case .cellularField: return "Cellular Automata"
        case .waterfallField: return "Waterfall Ribbon"
        case .streakField: return "Moving Streaks"
        case .streakGlow: return "Glow"
        case .blockerField: return "Flow Blockers"
        case .dataStream: return "Data Stream"
        case .pictureInPicture: return "Picture in Picture"
        case .channelSplit: return "Channel Split"
        case .channelColors: return "Channel Colors"
        case .crop: return "Crop / Aspect"
        case .color: return "Color Adjust"
        case .record: return "Record Movie"
        case .recordAudio: return "Record Audio"
        case .window: return "Video Window"
        case .syphon: return "Syphon Out"
        case .ndi: return "NDI Out"
        case .ndiIn: return "NDI In"
        }
    }
    public var previewKind: NodePreviewKind {
        switch self {
        case .flashCells, .metroSequencer, .midiIn, .midiFilter, .midiTransform, .midiMonitor, .midiMerge, .arpeggiator, .midiOut, .cellularField, .waterfallField, .streakField, .blockerField, .dataStream: return .empty
        case .apc40, .lfo, .noise, .audioEnvelope: return .control
        case .publishPalette, .palette, .videoPalette, .paletteAdjust: return .palette
        case .vectorShape, .vectorText, .fluidShape, .lorenz: return .geometry
        case .loopmother, .chromaEncoder, .audioInput, .voltageEncoder, .microphone, .audio, .audioGain, .audioMono, .audioMix, .audioPlugin, .audioFilter, .audioEQ, .audioOutput, .recordAudio: return .audio
        case .profileEncoder, .profileAnalog, .profileDecoder, .rasterSynth, .chromaDecoder, .oscilloscope, .voltageVisualizer, .voltageFluid, .projector, .posterText, .posterComposer, .videoCollection, .glowFaces, .powerGlitch, .liveStream, .lightningPulses, .graphInkFlow, .graphParticles, .graphPulse, .graphClouds, .graphCloudParticles, .flashFaces, .surfaceGate, .meshGradient, .ab, .mux, .layerMux, .dotColors, .flipDots, .projectionDots, .shaderEffect, .ledMatrix, .pictureInPicture, .channelSplit, .channelColors, .crop, .yoloPose, .poseRender, .faceReplace, .faceDetect, .faceBoxes, .scene, .pattern, .image, .video, .text, .webcam, .waveform, .audioVisualizer, .render, .shader, .dither, .halftone, .diffusion, .modulation, .crt, .blend, .color, .window, .syphon, .ndi, .ndiIn, .record, .streakGlow: return .video
        }
    }
    public var category: String { if isMIDINode { return "MIDI" }; if self == .posterText || self == .posterComposer { return "POSTER" }; if self == .vectorShape || self == .vectorText || self == .fluidShape { return "GEOMETRY" }; if self == .voltageVisualizer || self == .voltageFluid { return "RENDER" }; if self == .lightningPulses { return "TRACE" }; if self == .glowFaces || self == .graphInkFlow || self == .graphParticles || self == .graphPulse || self == .graphClouds || self == .graphCloudParticles || self == .flashFaces || self == .surfaceGate || self == .videoCollection || self == .layerMux { return "COLLECTION" }; if self == .apc40 || self == .lfo || self == .noise { return "CONTROL" }; if self == .meshGradient || self == .dotColors || self == .flipDots || self == .projectionDots || self == .scene || self == .dataStream || self == .blockerField || self == .streakField || self == .waterfallField || self == .cellularField || self == .streakGlow { return "USER GENERATED" }; if self == .videoPalette || self == .faceDetect || self == .yoloPose { return "ANALYSIS" }; return (isAudioNode || self == .recordAudio || self == .rasterSynth || self == .waveform || self == .audioVisualizer || self == .oscilloscope || self == .audioEnvelope) ? "AUDIO" : self == .lorenz ? "GEOMETRY" : (self == .render || self == .poseRender ? "RENDER" : (isOutput ? "OUTPUT" : (inputs.isEmpty ? "SOURCE" : "EFFECT"))) }
    public var inputs: [String] { switch self { case .flashCells: return ["Palette"]; case .profileAnalog, .profileDecoder: return ["RGB Profiles"]; case .loopmother: return ["MIDI","Instrument"]; case .chromaEncoder: return ["Video"]; case .chromaDecoder: return ["Color Audio", "Frame Reference"]; case .metroSequencer, .midiIn, .arpeggiator, .vectorShape, .vectorText, .fluidShape, .audioInput, .posterText: return []; case .posterComposer: return PosterStyle.composerInputs; case .midiMerge: return ["MIDI A","MIDI B","MIDI C","MIDI D"]; case .midiFilter, .midiTransform, .midiMonitor, .midiOut: return ["MIDI"]; case .voltageEncoder: return ["Path"]; case .voltageVisualizer: return ["XY Audio", "Draw Rate", "X", "Y"]; case .voltageFluid: return ["XY Audio", "Draw Rate", "X", "Y", "Reflection"]; case .lightningPulses: return ["Palette","Phase"]; case .layerMux: return (1...8).map { "Layer \($0)" }; case .mux, .videoCollection: return (1...8).map { "Video \($0)" }; case .glowFaces, .graphInkFlow, .graphParticles, .graphPulse, .graphClouds, .graphCloudParticles, .flashFaces, .publishPalette, .paletteAdjust, .meshGradient: return ["Palette"]; case .projectionDots: return ["Colors"]; case .apc40, .powerGlitch, .liveStream, .palette, .dotColors, .flipDots, .cellularField, .waterfallField, .streakField, .streakGlow, .blockerField, .dataStream, .microphone, .lfo, .noise, .scene, .pattern, .image, .video, .text, .webcam, .ndiIn, .audio, .lorenz, .shader: return []; case .ledMatrix: return ["Video","Field","Light"]; case .poseRender: return ["Poses"]; case .record: return ["Video","Audio"]; case .audioMix: return ["Audio A","Audio B"]; case .rasterSynth, .audioEnvelope, .audioGain, .audioMono, .audioPlugin, .audioFilter, .audioEQ, .audioOutput, .recordAudio, .waveform, .audioVisualizer, .oscilloscope: return ["Audio"]; case .render: return ["Geometry"]; case .faceReplace: return ["Video A", "Video B", "Faces A", "Faces B"]; case .faceBoxes: return ["Video", "Faces"]; case .ab, .blend, .pictureInPicture: return ["A", "B"]; default: return ["Video"] } }
    public var isOutput: Bool { [.midiOut, .projector, .publishPalette, .window, .syphon, .ndi, .record, .recordAudio, .audioOutput].contains(self) }
    public var outputType: PortType? { if self == .flashCells { return .field }; if self == .profileEncoder || self == .profileAnalog { return .rgbProfiles }; if isMIDINode && self != .midiOut { return .midi }; if self == .vectorShape || self == .vectorText || self == .fluidShape { return .vectorPath }; if self == .lightningPulses { return .trace }; if self == .glowFaces || self == .graphInkFlow || self == .graphParticles || self == .graphPulse || self == .graphClouds || self == .graphCloudParticles || self == .flashFaces || self == .surfaceGate || self == .videoCollection || self == .layerMux { return .collection }; if self == .palette || self == .videoPalette || self == .paletteAdjust { return .palette }; if self == .dotColors || self == .flipDots { return .dots }; if self == .dataStream || self == .blockerField || self == .streakField || self == .waterfallField || self == .cellularField || self == .streakGlow { return .field }; if self == .yoloPose { return .poses }; if self == .apc40 || self == .audioEnvelope || self == .lfo || self == .noise { return .control }; return self == .faceDetect ? .faces : isOutput ? nil : (isAudioNode ? .audio : (self == .lorenz ? .geometry : .video)) }
    public var isAudioNode: Bool { [.loopmother,.chromaEncoder,.audioInput,.voltageEncoder,.microphone,.audio,.audioGain,.audioMono,.audioMix,.audioPlugin,.audioFilter,.audioEQ,.audioOutput].contains(self) }
    public var outputTypes: [PortType] { if self == .apc40 { return Array(repeating:.control,count:APC40.outputs.count) }; if self == .metroSequencer { return [.midi,.midi,.midi] }; if self == .chromaEncoder { return [.audio,.chromaReference,.audio,.audio] }; if self == .voltageEncoder { return [.audio,.drawRate,.audio,.audio] }; if isAudioNode && !isOutput { return [.audio,.audio,.audio] }; return self == .ab ? [.video,.collection] : self == .layerMux ? [.collection,.video] : self == .meshGradient ? [.video,.palette] : self == .video ? [.video,.audio,.audio,.audio] : outputType.map { [$0] } ?? [] }
    public var outputs: [String] { if self == .apc40 { return APC40.outputs }; if self == .metroSequencer { return ["Track A","Track B","Both"] }; if self == .chromaEncoder { return ["Color Audio","Frame Reference","X / Left","Y / Right"] }; if isMIDINode && self != .midiOut { return ["MIDI"] }; if self == .vectorShape || self == .vectorText || self == .fluidShape { return ["Path"] }; if self == .voltageEncoder { return ["XY Audio", "Draw Rate", "X", "Y"] }; if self == .video { return ["Video","Stereo Audio","X / Left","Y / Right"] }; if isAudioNode && !isOutput { return ["Stereo / XY","X / Left","Y / Right"] }; if self == .layerMux { return ["Layers","Video"] }; return outputTypes.map { $0.rawValue.capitalized } }
    /// Separate audio outputs carry the chosen channel as mono in both slots.
    public func audioChannel(at output: Int) -> Int? {
        let first=(self == .voltageEncoder || self == .chromaEncoder || self == .video) ? 2:1
        guard (isAudioNode && !isOutput) || self == .video,output == first || output == first+1 else { return nil }
        return output-first
    }
    public var portRows: Int { max(inputs.count,outputTypes.count) }
    public func outputType(at index: Int) -> PortType? { outputTypes.indices.contains(index) ? outputTypes[index] : nil }
    /// Paused audio/video effects bypass; MIDI nodes stop their branch.
    public func bypassInput(forOutput index: Int = 0) -> Int? {
        guard !isMIDINode,let type = outputType(at:index) else { return nil }
        if self == .ab { return 0 }
        return inputTypes.firstIndex(of:type)
    }
    public var pausedStatus: String { isOutput ? "Disabled" : (bypassInput() == nil ? "Paused" : "Bypassed") }
    public var inputTypes: [PortType] { if self == .flashCells { return [.palette] }; if self == .profileAnalog || self == .profileDecoder { return [.rgbProfiles] }; if self == .loopmother { return [.midi,.audio] }; if self == .chromaEncoder { return [.video] }; if self == .chromaDecoder { return [.audio,.chromaReference] }; if isMIDINode { return inputs.map { _ in .midi } }; if self == .voltageEncoder { return [.vectorPath] }; if self == .voltageVisualizer { return [.audio,.drawRate,.audio,.audio] }; if self == .voltageFluid { return [.audio,.drawRate,.audio,.audio,.video] }; if self == .videoPalette { return [.visual] }; if self == .ab { return [.visual,.visual] }; if self == .layerMux { return Array(repeating:.visual,count:8) }; if self == .lightningPulses { return [.palette,.control] }; if self == .glowFaces || self == .graphInkFlow || self == .graphParticles || self == .graphPulse || self == .graphClouds || self == .graphCloudParticles || self == .flashFaces || self == .meshGradient || self == .publishPalette || self == .paletteAdjust { return [.palette] }; if self == .projectionDots { return [.dots] }; if self == .ledMatrix { return [.video,.field,.field] }; if self == .poseRender { return [.poses] }; if self == .record { return [.video,.audio] }; if self == .recordAudio { return [.audio] }; if isAudioNode || self == .audioEnvelope { return inputs.map { _ in .audio } }; if self == .faceReplace { return [.video, .video, .faces, .faces] }; if self == .faceBoxes { return [.video, .faces] }; return inputs.map { _ in (self == .rasterSynth || self == .waveform || self == .audioVisualizer || self == .oscilloscope) ? .audio : (self == .render ? .geometry : .video) } }
    public static var mediaPlaybackParameters: [ParameterSpec] { [.init("playing","Playing",0,1,1,choices:["Paused","Playing"]),.init("seek","Playhead (s)",0,86400,0)] }
    public static var mediaTransformParameters: [ParameterSpec] { [
        .init("rotation", "Rotation", -180, 180, 0),
        .init("flipX", "Flip horizontal", 0, 1, 0, choices:["Off","On"]),
        .init("flipY", "Flip vertical", 0, 1, 0, choices:["Off","On"]),
        .init("scale", "Scale", 0.1, 4, 1),
        .init("x", "Position X", -1, 1, 0), .init("y", "Position Y", -1, 1, 0)
    ] }
    public var parameters: [ParameterSpec] {
        switch self {
        case .apc40: return []
        case .graphInkFlow: return CollectionStyle.inkParameters + [
            .init("startingFaces","Starting faces (%)",0,100,100,step:1),
            .init("independentTravel","Travel timing",0,1,0,choices:["Together","Independent"],midi:true,step:1)
        ]
        case .graphParticles: return CollectionStyle.particleParameters
        case .graphPulse: return CollectionStyle.graphParameters
        case .graphClouds: return CollectionStyle.cloudParameters
        case .graphCloudParticles: return CollectionStyle.cloudParticleParameters
        case .glowFaces: return CollectionStyle.glowParameters
        case .flashFaces: return CollectionStyle.parameters + CollectionStyle.colorParameters
        case .surfaceGate: return CollectionStyle.parameters
        case .videoCollection: return [.init("fit","Fit",0,2,0,choices:["Contain","Cover","Stretch"],midi:false,step:1),.init("brightness","Brightness",0,2,1),.init("previewFaces","Preview surfaces",1,64,8,midi:false,step:1)]
        case .posterText: return PosterStyle.textParameters
        case .posterComposer: return PosterStyle.composerParameters
        case .chromaEncoder: return AnalogChromaStyle.encoderParameters
        case .chromaDecoder: return AnalogChromaStyle.decoderParameters
        case .loopmother: return LoopmotherStyle.parameters
        case .midiIn, .midiMonitor, .midiMerge: return []
        case .midiFilter: return MIDIRoutingStyle.filterParameters
        case .midiTransform: return MIDIRoutingStyle.transformParameters
        case .metroSequencer: return MetroStyle.parameters
        case .arpeggiator: return ArpeggiatorStyle.parameters
        case .midiOut: return ArpeggiatorStyle.outputParameters
        case .vectorShape: return AnalogVectorStyle.shapeParameters
        case .vectorText: return AnalogVectorStyle.textParameters
        case .voltageEncoder: return AnalogVectorStyle.encoderParameters
        case .voltageVisualizer: return AnalogVectorStyle.visualizerParameters
        case .profileAnalog: return ProfileVideoStyle.processorParameters
        case .profileDecoder: return ProfileVideoStyle.decoderParameters
        case .rasterSynth: return RasterSynthStyle.parameters
        case .fluidShape: return VoltageFluidStyle.shapeParameters
        case .voltageFluid: return VoltageFluidStyle.fluidParameters
        case .oscilloscope: return AnalogVectorStyle.oscilloscopeParameters
        case .projector: return AnalogVectorStyle.projectorParameters
        case .audioInput: return AudioChannels.parameters + AnalogVectorStyle.channelParameters + [.init("gain","Input gain (dB)",-24,36,0)]
        case .microphone: return [.init("gain","Input gain (dB)",-24,36,0)]
        case .audioEnvelope: return [.init("mode","Level",0,1,0,choices:["RMS","Peak"]),.init("gain","Sensitivity (dB)",-24,60,12),.init("floor","Floor (dB)",-90,-6,-60),.init("ceiling","Ceiling (dB)",-60,0,-6),.init("attack","Attack (ms)",1,1000,15),.init("release","Release (ms)",1,3000,200)]
        case .audioGain: return AudioChannels.parameters + [.init("gain","Gain (dB)",-60,12,0),.init("pan","Pan",-1,1,0)]
        case .audioMix: return [.init("gainA","A gain (dB)",-60,12,0),.init("gainB","B gain (dB)",-60,12,0),.init("master","Master (dB)",-60,6,-6)]
        case .audioEQ: return AudioEQStyle.parameters
        case .audioFilter: return [.init("cutoff","Cutoff (Hz)",20,20000,2000),.init("mode","Filter",0,1,0,choices:["Low-pass","High-pass"]),.init("mix","Mix",0,1,1)]
        case .audioOutput: return AudioChannels.parameters + AnalogVectorStyle.channelParameters + AnalogVectorStyle.outputRateParameters + [.init("gain","Volume (dB)",-60,6,0)]
        case .audio: return AudioChannels.parameters + Self.mediaPlaybackParameters + [.init("speed","Speed",0.1,3,1),.init("start","Loop start (s)",0,86400,0),.init("end","Loop end (s, 0 = end)",0,86400,0)]
        case .lfo: return [.init("rate","Rate (Hz)",0,20,0.2), .init("shape","Waveform",0,3,0,choices:["Sine","Triangle","Saw","Square"]), .init("phase","Phase",0,1,0), .init("width","Pulse width",0.01,0.99,0.5), .init("amplitude","Amplitude",0,1,1), .init("offset","Center",0,1,0.5)]
        case .noise: return [.init("rate","Rate (Hz)",0,20,0.5), .init("style","Style",0,1,0,choices:["Smooth","Stepped"]), .init("seed","Seed",0,65535,1,step:1), .init("octaves","Octaves",1,6,1,step:1), .init("roughness","Roughness",0,1,0.5), .init("phase","Phase",0,1,0), .init("amplitude","Amplitude",0,1,1), .init("offset","Center",0,1,0.5)]
        case .faceReplace: return [.init("mix", "Mix", 0, 1, 1), .init("scale", "Face scale", 0.25, 4, 1), .init("feather", "Edge softness", 0.01, 0.5, 0.18), .init("faceA", "Face A (largest = 0)", 0, 31, 0,step:1), .init("faceB", "Face B (largest = 0)", 0, 31, 0,step:1)]
        case .yoloPose: return [.init("rate", "Detection FPS", 1, 60, 30), .init("confidence", "Person confidence", 0.05, 0.95, 0.3), .init("iou", "Overlap threshold", 0.1, 0.9, 0.45)]
        case .poseRender: return PoseStyle.parameters
        case .faceDetect: return [.init("rate", "Detection FPS", 1, 60, 30), .init("captureScale", "Capture area scale", 0.5, 3, 1)]
        case .faceBoxes: return [.init("thickness", "Line width", 1, 12, 3)]
        case .webcam: return [.init("mirror", "Mirror", 0, 1, 0, choices:["Off","On"])]
        case .dither: return [
            .init("dpi", "Input DPI", 6, 144, 72),
            .init("resampling", "Resampling", 0, 3, 0, choices:["Preserve Details","Bicubic","Bilinear","Nearest"]),
            .init("algorithm", "Algorithm", 0, 5, 2, choices:["2×2 Bayer","4×4 Bayer","8×8 Bayer","Clustered Dots","Lines","Fixed Noise"]),
            .init("cell", "Pixel size", 1, 12, 2), .init("levels", "Levels", 2, 16, 2),
            .init("sharpen", "Sharpen strength", 0, 300, 0), .init("sharpenRadius", "Sharpen radius", 0.5, 30, 11),
            .init("noise", "Noise", 0, 100, 0), .init("denoise", "Denoise", 0, 100, 0), .init("blur", "Blur", 0, 30, 0),
            .init("brightness", "Brightness", -100, 100, 0), .init("contrast", "Contrast", -100, 100, 0), .init("gamma", "Gamma", 0.25, 3, 1),
            .init("tonal", "Tonal mapping", 0, 4, 0, choices:["RGB","Monochrome","1 Color","2 Colors","3 Colors"]),
            .init("highlightColor", "Highlights", 0, 16777215, 16777215), .init("midtoneColor", "Midtones", 0, 16777215, 3900592), .init("shadowColor", "Shadows", 0, 16777215, 0),
            .init("highlightLevel", "Highlight level", 0.51, 1, 1), .init("midtoneLevel", "Midtone position", 0.05, 0.95, 0.5), .init("shadowLevel", "Shadow level", 0, 0.49, 0),
            .init("background", "Background", 0, 3, 0, choices:["Black","White","Custom","Source"]), .init("backgroundColor", "Background color", 0, 16777215, 0),
            .init("angle", "Pattern angle", -180, 180, 0), .init("seed", "Noise seed", 0, 65535, 0,step:1), .init("mix", "Mix", 0, 1, 1),
            .init("matrix", "Legacy matrix", 0, 2, 2, choices:["2×2","4×4","8×8"]), .init("mono", "Legacy monochrome", 0, 1, 0, choices:["Off","On"])
        ]
        case .halftone: return [.init("cell", "Cell size", 3, 40, 8), .init("angle", "Angle", -180, 180, 15), .init("shape", "Screen", 0, 2, 0, choices:["Dots","Lines","Diamonds"]), .init("mono", "Color", 0, 1, 1, choices:["RGB","Monochrome"]), .init("contrast", "Contrast", 0.2, 3, 1), .init("mix", "Mix", 0, 1, 1)]
        case .diffusion: return [.init("strength", "Strength", 0, 3, 0.7), .init("radius", "Radius", 2, 100, 28), .init("threshold", "Highlight threshold", 0, 1, 0.45), .init("knee", "Soft knee", 0.01, 0.5, 0.2), .init("saturation", "Glow saturation", 0, 2, 1)]
        case .modulation: return [.init("period", "Line spacing", 2, 32, 6), .init("depth", "Phase modulation", 0, 16, 5), .init("width", "Beam width", 0.05, 0.9, 0.3), .init("angle", "Angle", -180, 180, 0), .init("mono", "Color", 0, 1, 0, choices:["RGB","Monochrome"]), .init("mix", "Mix", 0, 1, 1)]
        case .scene: return [.init("speed", "Motion", 0, 2, 0.6), .init("orbit", "Camera orbit", -1, 1, 0.15), .init("zoom", "Camera zoom", 0.5, 2, 1), .init("spread", "Spacing", 0.7, 1.5, 1), .init("shadows", "Shadows", 0, 1, 0.65)]
        case .text: return [.init("size", "Font size", 8, 300, 96), .init("x", "Horizontal", 0, 1, 0.5), .init("y", "Vertical", 0, 1, 0.5), .init("hue", "Hue", 0, 1, 0), .init("saturation", "Saturation", 0, 1, 0)]
        case .audioVisualizer: return [
            .init("mode","View",0,5,1,choices:["Waveform","Spectrum","Spectrogram","Radial","Bars","Ridgelines"]),
            .init("gain","Gain (dB)",-24,36,0), .init("floor","Floor (dBFS)",-100,-20,-72),
            .init("logFrequency","Frequency scale",0,1,1,choices:["Linear","Logarithmic"]),
            .init("window","Waveform window (ms)",10,170,80), .init("history","History (s)",1,20,6),
            .init("smoothing","Decay (s)",0,1,0.15), .init("thickness","Line width (px)",1,12,3),
            .init("fill","Spectrum style",0,1,1,choices:["Line","Filled"]),
            .init("axes","Axes",0,1,1,choices:["Off","On"]), .init("grid","Grid",0,1,0,choices:["Off","On"]),
            .init("bars","Bar count",8,128,48,step:1), .init("ridges","Ridge lines",8,64,28,step:1)
        ]
        case .waveform: return [.init("gain", "Gain", 0.1, 10, 1), .init("hue", "Hue", 0, 1, 0.12), .init("thickness", "Line width", 1, 10, 2)]
        case .lorenz: return [.init("sigma", "Sigma", 1, 30, 10), .init("rho", "Rho", 1, 60, 28), .init("beta", "Beta", 0.1, 8, 2.667), .init("points", "Points", 1000, 50000, 16000)]
        case .render: return [.init("rotation", "Orbit speed", -2, 2, 0.18), .init("scale", "Scale", 0.2, 2, 1.1), .init("hue", "Hue", 0, 1, 0.36), .init("intensity", "Intensity", 0.1, 3, 1.8)]
        case .shaderEffect: return [.init("speed","Speed",0,3,1), .init("mix","Mix",0,1,1), .init("p1","Control 1",-10,10,0), .init("p2","Control 2",-10,10,0), .init("p3","Control 3",-10,10,0), .init("p4","Control 4",-10,10,0)]
        case .shader: return [.init("speed", "Speed", 0, 3, 1)]
        case .powerGlitch: return PowerGlitchStyle.parameters
        case .liveStream: return [.init("buffer","Buffer (s)",0,8,2,midi:false,step:0.25)] + Self.mediaTransformParameters
        case .lightningPulses: return TraceStyle.parameters
        case .videoPalette: return PaletteStyle.extractionParameters
        case .paletteAdjust: return PaletteAdjustmentStyle.parameters
        case .meshGradient: return MeshGradientStyle.parameters
        case .pattern: return [.init("style", "Pattern", 0, 2, 0, choices: ["Gradient", "Color bars", "Grid"]), .init("speed", "Motion", 0, 2, 0.25)]
        case .image: return Self.mediaTransformParameters
        case .video: return Self.mediaPlaybackParameters + [.init("speed", "Speed", 0.1, 3, 1), .init("start", "Loop start (s)", 0, 86400, 0), .init("end", "Loop end (s, 0 = end)", 0, 86400, 0)] + Self.mediaTransformParameters
        case .crt: return [.init("scanlines", "Scanlines", 0, 1, 0.4), .init("curvature", "Curvature", 0, 1, 0.18), .init("aberration", "RGB offset", 0, 10, 2), .init("glow", "Glow", 0, 1, 0.3), .init("vignette", "Vignette", 0, 1, 0.35), .init("noise", "Noise", 0, 0.2, 0.025)]
        case .layerMux: return (1...8).map { ParameterSpec("level\($0)","Layer \($0)",0,1,$0 == 1 ? 1 : 0) } + (1...8).map { ParameterSpec("mode\($0)","Video \($0) mode",0,1,0,choices:["Mix","Mask"],midi:true,step:1) } + [.init("channels","Channels",1,8,8,midi:false,step:1),.init("followAPC","Follow APC",0,1,0,choices:["Off","On"],midi:false)]
        case .mux: return (1...8).map { ParameterSpec("level\($0)","Channel \($0)",0,1,$0 == 1 ? 1 : 0) } + (1...8).map { ParameterSpec("mode\($0)","Channel \($0) mode",0,1,0,choices:["Mix","Mask"],midi:true,step:1) } + [.init("channels","Channels",1,8,8,midi:false,step:1),.init("followAPC","Follow APC",0,1,0,choices:["Off","On"],midi:false)]
        case .ab: return [.init("mix","A / B",0,1,0),.init("mode","Transition",0,1,0,choices:["Crossfade","Cut"])]
        case .blend: return [.init("mix", "Mix / opacity", 0, 1, 0.5), .init("mode", "Blend mode", 0, 4, 0, choices: ["Crossfade", "Add", "Multiply", "Screen", "Alpha Over (B over A)"]), .init("x","Foreground X",-1,1,0), .init("y","Foreground Y",-1,1,0), .init("scale","Foreground size",0.1,3,1)]
        case .projectionDots: return ProjectionDotsStyle.parameters
        case .dotColors: return DotColorsStyle.parameters
        case .flipDots: return FlipDotsStyle.parameters
        case .flashCells: return FlashCellsStyle.parameters
        case .palette: return PaletteGenerator.parameters
        case .ledMatrix: return LEDMatrixStyle.parameters
        case .dataStream: return DataStreamStyle.parameters
        case .cellularField: return CellularFieldStyle.parameters
        case .waterfallField: return WaterfallFieldStyle.parameters
        case .streakField: return StreakFieldStyle.parameters
        case .streakGlow: return StreakGlowStyle.parameters
        case .blockerField: return BlockerFieldStyle.parameters
        case .pictureInPicture: return PictureInPictureStyle.parameters
        case .channelSplit: return ChannelSplitStyle.parameters
        case .channelColors: return ChannelColorsStyle.parameters
        case .crop: return CropStyle.parameters
        case .color: return ColorAdjustStyle.parameters
        case .recordAudio: return AudioRecording.parameters
        default: return []
        }
    }
}
extension NodeKind {
    // Retired kinds load as their surviving equivalent.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = NodeKind(rawValue: raw == "graphInkFlow2" ? "graphInkFlow" : raw == "lightField" ? "streakGlow" : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown node kind \(raw)"))
        }
        self = kind
    }
}
public struct Position: Codable, Equatable, Sendable { public var x: Double; public var y: Double; public init(_ x: Double, _ y: Double) { self.x = x; self.y = y } }
public struct Node: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: NodeKind
    public var name: String
    public var position: Position
    public var parameters: [String: Double]
    public var metroSnapshot: [String:Double]?
    public var plugin: AudioPluginConfiguration?
    public var file: String?
    public var controlStyle: String?
    public var palette: ColorPalette?
    public var text: String?
    /// Poster Text's free layout; nil lays out `text` by its tagged roles.
    public var poster: PosterLayout?
    public var deviceID: String?
    public var modulations: [String:ParameterModulation]?
    public var publications: [String:OutputPublication]?
    public var seekRevision: UUID?
    public var enabled: Bool
    public init(kind: NodeKind, position: Position = .init(0, 0), id: UUID = UUID()) {
        self.id = id; self.kind = kind; text = kind == .vectorText ? "PATCH" : kind == .text ? "Text" : kind == .flipDots ? "HELLO\nWORLD\nPATCH" : nil; name = kind.title; self.position = position
        palette = kind == .palette ? PaletteStyle.defaultPalette : nil
        parameters = Dictionary(uniqueKeysWithValues: kind.parameters.map { ($0.key, $0.initial) }); enabled = true
    }
    public var channelCount: Int { (kind == .mux || kind == .layerMux) ? max(1,min(8,Int(value("channels").rounded()))) : kind.inputs.count }
    public var inputs: [String] { Array(kind.inputs.prefix(channelCount)) }
    public var inputTypes: [PortType] { Array(kind.inputTypes.prefix(channelCount)) }
    public var portRows: Int { max(inputs.count,kind.outputTypes.count) }
    public var canvasWidth: Double { kind == .apc40 ? 780 : 210 }
    public var canvasHeight: Double { kind == .apc40 ? 500 : 224 + Double(max(0,portRows-2))*25 + Double(modulations?.count ?? 0)*22 }
    public func value(_ key: String) -> Double { parameters[key] ?? parameterDefinitions.first(where: { $0.key == key })?.initial ?? 0 }
}
public struct Edge: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var source: UUID
    public var target: UUID
    public var input: Int
    public var output: Int?
    public var outputIndex: Int { output ?? 0 }
    public init(source: UUID, target: UUID, input: Int = 0, output: Int = 0) { id = UUID(); self.source = source; self.target = target; self.input = input; self.output = output == 0 ? nil : output }
}
public struct GraphError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct Graph: Codable, Equatable, Sendable {
    public var version = 1
    public var nodes: [Node] = []
    public var edges: [Edge] = []
    public var components: [Component]?
    public var midiMappings: [MIDIMapping]?
    public var width = 1280
    public var height = 720
    public var fps = 60
    public init() {}
    public func node(_ id: UUID) -> Node? { nodes.first { $0.id == id } }
    public mutating func connect(_ source: UUID, to target: UUID, input: Int = 0, output: Int = 0) throws {
        var next = self
        guard let from = node(source), let into = node(target), into.inputs.indices.contains(input), let type = from.kind.outputType(at:output), into.inputTypes[input].accepts(type) else { throw GraphError("Connect compatible types. Layer inputs accept video or collection effects; other inputs require their declared type.") }
        guard source != target else { throw GraphError("A node cannot connect to itself.") }
        next.edges.removeAll { $0.target == target && $0.input == input }
        next.edges.append(Edge(source: source, target: target, input: input, output: output))
        _ = try next.orderedNodes()
        self = next
    }
    public mutating func remove(_ id: UUID) { remove(Set([id])) }
    public mutating func remove(_ ids: Set<UUID>) {
        let removing = Set(ids.flatMap { component($0)?.members ?? [$0] })
        struct Endpoint: Hashable { let node: UUID; let output: Int }
        let original = self
        // Follow a deleted chain only through inputs matching its outgoing type.
        // Multiple distinct upstream endpoints are ambiguous: never guess A versus B.
        func upstream(_ endpoint: Endpoint,_ visited: Set<UUID>) -> Set<Endpoint> {
            guard removing.contains(endpoint.node) else { return [endpoint] }
            guard !visited.contains(endpoint.node), let node = original.node(endpoint.node),
                  let type = node.kind.outputType(at:endpoint.output) else { return [] }
            var result = Set<Endpoint>()
            for edge in original.edges where edge.target == endpoint.node {
                guard node.inputTypes.indices.contains(edge.input),node.inputTypes[edge.input].accepts(type) else { continue }
                result.formUnion(upstream(Endpoint(node:edge.source,output:edge.outputIndex),visited.union([endpoint.node])))
            }
            return result
        }
        let boundary = edges.filter { removing.contains($0.source) && !removing.contains($0.target) }
        for i in nodes.indices { nodes[i].modulations = nodes[i].modulations?.filter { !removing.contains($0.value.source) } }
        nodes.removeAll { removing.contains($0.id) }; edges.removeAll { removing.contains($0.source) || removing.contains($0.target) }
        if components != nil { components = groups.compactMap { old in var g = old; g.members.removeAll { removing.contains($0) }; return g.members.isEmpty ? nil : g } }
        for edge in boundary {
            let candidates = upstream(Endpoint(node:edge.source,output:edge.outputIndex),[])
            if candidates.count == 1, let source = candidates.first {
                // connect also validates port types, occupied input replacement and cycles.
                try? connect(source.node,to:edge.target,input:edge.input,output:source.output)
            }
        }
    }
    public mutating func insert(_ nodeID: UUID, on edgeID: UUID) throws {
        guard let n = node(nodeID), n.inputs.count == 1, n.kind.outputType == n.inputTypes.first, !edges.contains(where: { $0.source == nodeID || $0.target == nodeID }), let edge = edges.first(where: { $0.id == edgeID }), edge.source != nodeID, edge.target != nodeID else { throw GraphError("Only an unconnected one-input effect can be inserted on a cable.") }
        var next = self
        next.edges.removeAll { $0.id == edgeID }
        try next.connect(edge.source, to: nodeID, output:edge.outputIndex)
        try next.connect(nodeID, to: edge.target, input: edge.input)
        self = next
    }
    public mutating func setParameter(_ id: UUID, key: String, value: Double) throws {
        guard let i = nodes.firstIndex(where: { $0.id == id }), let spec = nodes[i].parameterDefinitions.first(where: { $0.key == key }) else { throw GraphError("Unknown node or parameter: \(key)") }
        guard value.isFinite, value >= spec.min, value <= spec.max, spec.choices == nil || value.rounded() == value else { throw GraphError("\(key) must be between \(spec.min) and \(spec.max)\(spec.choices == nil ? "" : " and an integer").") }
        if key == "channels" {
            guard value.rounded() == value else { throw GraphError("Channel count must be a whole number") }
            guard !edges.contains(where:{ $0.target == id && $0.input >= Int(value) }),
                  !(nodes[i].modulations ?? [:]).keys.contains(where:{ $0.hasPrefix("level") && (Int($0.dropFirst(5)) ?? 0) > Int(value) }) else {
                throw GraphError("Disconnect inputs and level controls above channel \(Int(value)) before reducing the channel count.")
            }
        }
        nodes[i].parameters[key] = value
        if key == "seek" { nodes[i].seekRevision = UUID() }
    }
    public func orderedNodes() throws -> [Node] {
        var result: [Node] = [], visiting: Set<UUID> = [], visited: Set<UUID> = []
        let index = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let incoming = Dictionary(grouping: dependencies, by: \.target)
        func visit(_ id: UUID) throws {
            if visited.contains(id) { return }
            guard !visiting.contains(id) else { throw GraphError("That connection would create a feedback loop.") }
            guard let node = index[id] else { throw GraphError("Cable references a missing node.") }
            visiting.insert(id)
            for edge in incoming[id] ?? [] { try visit(edge.source) }
            visiting.remove(id); visited.insert(id); result.append(node)
        }
        for node in nodes { try visit(node.id) }
        return result
    }
    public func validated() throws -> Graph {
        // Removed visualizer options must not prevent existing projects from opening.
        let removedVisualizerKeys = ["appearance", "previewMode", "autoFit", "fitScale"]
        if nodes.contains(where:{ node in node.kind == .voltageVisualizer && removedVisualizerKeys.contains(where: { node.parameters[$0] != nil }) }) {
            var migrated=self
            for i in migrated.nodes.indices where migrated.nodes[i].kind == .voltageVisualizer {
                for key in removedVisualizerKeys { migrated.nodes[i].parameters.removeValue(forKey:key) }
            }
            return try migrated.validated()
        }
        // Move old encoder rate choices to their hardware sinks, once per document.
        if nodes.contains(where:{ $0.kind == .voltageEncoder && $0.parameters["sampleRate"] != nil }) {
            var migrated=self, requested: [UUID:Double]=[:]
            for encoder in nodes where encoder.kind == .voltageEncoder {
                guard let old=encoder.parameters["sampleRate"],old.isFinite,old>=0,old<=2,old.rounded()==old else { continue }
                var pending=[encoder.id],seen=Set<UUID>()
                while let id=pending.popLast() {
                    guard seen.insert(id).inserted else { continue }
                    if let sink=node(id),sink.kind == .audioOutput,sink.parameters["sampleRate"] == nil { requested[id]=max(requested[id] ?? 0,old+1) }
                    pending += edges.filter { $0.source == id && node(id)?.kind.outputType(at:$0.outputIndex) == .audio }.map(\.target).filter { !seen.contains($0) }
                }
            }
            for i in migrated.nodes.indices {
                if migrated.nodes[i].kind == .voltageEncoder { migrated.nodes[i].parameters.removeValue(forKey:"sampleRate") }
                if let rate=requested[migrated.nodes[i].id] { migrated.nodes[i].parameters["sampleRate"]=rate }
            }
            return try migrated.validated()
        }
        if PosterStyle.needsMigration(self) { return try PosterStyle.migrate(self).validated() }
        // Old Projection Dots documents retain their paper size and color settings.
        // Remove redundant geometry controls before normal schema validation.
        if nodes.contains(where: { $0.kind == .projectionDots && !ProjectionDotsStyle.legacyKeys.isDisjoint(with: $0.parameters.keys) }) {
            var migrated = self
            migrated.nodes = nodes.map { $0.kind == .projectionDots ? ProjectionDotsStyle.migrate($0) : $0 }
            return try migrated.validated()
        }
        let colorKeys = Set(DotColorsStyle.parameters.map(\.key))
        let legacyDots = nodes.filter { $0.kind == .projectionDots && !colorKeys.isDisjoint(with:$0.parameters.keys) }
        if !legacyDots.isEmpty {
            var migrated = self
            for old in legacyDots {
                guard let index = migrated.nodes.firstIndex(where: { $0.id == old.id }) else { continue }
                if !migrated.edges.contains(where: { $0.target == old.id && $0.input == 0 }) {
                    var colors = Node(kind:.dotColors,position:.init(old.position.x-290,old.position.y))
                    for key in colorKeys { if let value = old.parameters[key] { colors.parameters[key] = value } }
                    colors.modulations = old.modulations?.filter { colorKeys.contains($0.key) }
                    migrated.nodes.append(colors)
                    migrated.edges.append(Edge(source:colors.id,target:old.id))
                }
                migrated.nodes[index].parameters = old.parameters.filter { !colorKeys.contains($0.key) }
                migrated.nodes[index].modulations = old.modulations?.filter { !colorKeys.contains($0.key) }
                // The old source contains the combined color/geometry shader. Its file is preserved on disk.
                migrated.nodes[index].file = nil
            }
            return try migrated.validated()
        }
        guard nodes.filter({ $0.kind == .apc40 }).count <= 1 else { throw GraphError("Only one APC40 node is allowed in a patch.") }
        try validateMIDIMappings()
        guard version == 1 else { throw GraphError("Unsupported project version.") }
        guard (64...3840).contains(width), (64...2160).contains(height), (1...120).contains(fps) else { throw GraphError("Invalid render size or frame rate.") }
        guard nodes.count <= 200, Set(nodes.map(\.id)).count == nodes.count, Set(edges.map(\.id)).count == edges.count else { throw GraphError("Duplicate IDs or too many nodes (maximum 200).") }
        var grouped: Set<UUID> = [], groupIDs = Set<UUID>()
        for group in groups {
            guard groupIDs.insert(group.id).inserted, node(group.id) == nil, !group.members.isEmpty, group.name.count <= 128, group.position.x.isFinite, group.position.y.isFinite, abs(group.position.x)<1e6, abs(group.position.y)<1e6 else { throw GraphError("Invalid component") }
            for id in group.members { guard node(id) != nil, grouped.insert(id).inserted else { throw GraphError("Missing or duplicate component member") } }
        }
        var occupied: Set<String> = []
        for edge in edges {
            guard let from = node(edge.source), let to = node(edge.target), to.inputs.indices.contains(edge.input), to.inputTypes[edge.input].accepts(from.kind.outputType(at:edge.outputIndex)) else { throw GraphError("Invalid cable.") }
            guard occupied.insert("\(edge.target):\(edge.input)").inserted else { throw GraphError("An input can have only one cable.") }
        }
        for n in nodes {
            for (key, publication) in n.publications ?? [:] {
                guard let port=Int(key), n.publishableTypes.indices.contains(port), [.video,.palette,.control,.collection,.trace].contains(n.publishableTypes[port]), ["auto","on","off"].contains(publication.mode), (publication.name?.count ?? 0)<=128 else { throw GraphError("Invalid publication") }
            }
            if let palette = n.palette {
                guard n.kind == .palette, (1...256).contains(palette.colors.count), palette.colors.allSatisfy(\.isValid) else { throw GraphError("Invalid palette colors") }
            }
            if let poster = n.poster {
                guard n.kind == .posterComposer, poster.elements.count <= 512, poster.elements.allSatisfy(\.isValid), poster.elements.filter({ $0.shape == .chrome }).count <= 1, (poster.groups?.count ?? 0) <= 256, poster.groups?.allSatisfy({ $0.name.count <= 256 }) ?? true else { throw GraphError("Invalid poster layout") }
            }
            guard n.controlStyle == nil || n.hasMetallicPoolControls || n.hasBlindsControls || n.hasLiquidSculptureControls || n.hasFerrofluidControls else { throw GraphError("Invalid node control style") }
            if n.kind.isMIDINode {
                for spec in n.parameterDefinitions where spec.step == 1 {
                    if n.value(spec.key).rounded() != n.value(spec.key) { throw GraphError("MIDI values must use whole numbers for \(spec.title)") }
                }
                if n.kind == .midiFilter && n.value("lowNote") > n.value("highNote") { throw GraphError("MIDI note range is reversed") }
            }
            if n.kind == .arpeggiator,["octave","octaves","inversion","velocity"].contains(where:{ n.value($0).rounded() != n.value($0) }) { throw GraphError("Arpeggiator octave, range, inversion and velocity must be whole numbers") }
            if n.kind == .audioEnvelope, n.value("floor") >= n.value("ceiling") { throw GraphError("Envelope ceiling must be above its floor") }
            for (key,binding) in n.modulations ?? [:] {
                guard node(binding.source)?.kind.outputType(at:binding.outputIndex) == .control,
                      let spec = n.modulationDefinitions.first(where:{ $0.key == key }),
                      binding.minimum.isFinite, binding.maximum.isFinite,
                      binding.minimum >= spec.min, binding.minimum <= spec.max,
                      binding.maximum >= spec.min, binding.maximum <= spec.max else { throw GraphError("Invalid modulation for \(key)") }
            }
            if n.kind == .video || n.kind == .audio, n.value("end") > 0, n.value("end") <= n.value("start") { throw GraphError("Loop end must be after loop start (or zero for the end of the file)") }
            guard n.position.x.isFinite, n.position.y.isFinite, abs(n.position.x) < 1e6, abs(n.position.y) < 1e6, n.name.count <= 128, (n.text?.count ?? 0) <= (n.kind == .meshGradient ? 131072:16384) else { throw GraphError("Invalid node position or name.") }
            if n.kind == .meshGradient { try MeshGradientStyle.validate(n) }
            if n.kind == .mux || n.kind == .layerMux {
                guard n.value("channels").rounded() == n.value("channels") else { throw GraphError("Channel count must be a whole number") }
            }
            if n.kind == .audioInput || n.kind == .audioOutput {
                guard ["channelX","channelY"].allSatisfy({ n.value($0).rounded() == n.value($0) }) else { throw GraphError("Audio channels must be whole numbers") }
            }
            let specs=Dictionary(uniqueKeysWithValues:n.parameterDefinitions.map {($0.key,$0)})
            for (key, value) in n.parameters {
                guard let spec = specs[key], value.isFinite, value >= spec.min, value <= spec.max, spec.choices == nil || value.rounded() == value else { throw GraphError("Invalid parameter \(key).") }
            }
        }
        _ = try orderedNodes()
        return self
    }
    public static var demo: Graph {
        var g = Graph()
        let a = Node(kind: .lorenz, position: .init(65, 160))
        let b = Node(kind: .render, position: .init(345, 160))
        let c = Node(kind: .crt, position: .init(625, 160))
        let d = Node(kind: .window, position: .init(905, 160))
        g.nodes = [a, b, c, d]
        try! g.connect(a.id, to: b.id); try! g.connect(b.id, to: c.id); try! g.connect(c.id, to: d.id)
        return g
    }
}
