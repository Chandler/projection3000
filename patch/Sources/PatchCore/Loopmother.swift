import Foundation

public enum LoopmotherStyle {
    public static let parameters: [ParameterSpec] = [
        .init("osc1Wave","Oscillator 1 waveform",0,4,1,choices:["Sine", "Saw", "Square", "Triangle", "Pulse"],midi:true,step:1),
        .init("osc2Wave","Oscillator 2 waveform",0,4,2,choices:["Sine", "Saw", "Square", "Triangle", "Pulse"],midi:true,step:1),
        .init("osc1Octave","Oscillator 1 range",0,4,2,choices:["32 ft", "16 ft", "8 ft", "4 ft", "2 ft"],midi:true,step:1),
        .init("osc2Octave","Oscillator 2 range",0,4,2,choices:["32 ft", "16 ft", "8 ft", "4 ft", "2 ft"],midi:true,step:1),
        .init("detune","Oscillator 2 detune (cents)",-100,100,-7),
        .init("osc1Level","Oscillator 1 level",0,1,0.82),
        .init("osc2Level","Oscillator 2 level",0,1,0.58),
        .init("noise","Noise level",0,1,0.02),
        .init("cutoff","Filter cutoff (Hz)",20,18000,3500),
        .init("resonance","Resonance",0,1,0.22),
        .init("envAmount","Filter envelope amount",0,1,0.36),
        .init("tracking","Keyboard tracking",0,1,0.35),
        .init("lfoRate","LFO rate (Hz)",0.01,30,4.2),
        .init("lfoWave","LFO waveform",0,4,0,choices:["Sine", "Saw", "Square", "Triangle", "Pulse"],midi:true,step:1),
        .init("lfoPitch","LFO pitch (semitones)",0,12,0.02),
        .init("lfoCutoff","LFO filter amount",0,1,0.1),
        .init("attack","Attack (s)",0.001,5,0.01),
        .init("decay","Decay (s)",0.001,5,0.12),
        .init("sustain","Sustain",0,1,0.75),
        .init("release","Release (s)",0.001,8,0.18),
        .init("glide","Glide (s)",0,2,0),
        .init("vca","VCA",0,1,0,choices:["Envelope", "Drone"],midi:true,step:1),
        .init("poly","Voice mode",0,1,0,choices:["Mono", "Poly (8 voices)"],midi:true,step:1),
        .init("reverb","Spring reverb mix",0,1,0.12),
        .init("volume","Volume",0,1,0.25),
        .init("instrument","Instrument in level",0,2,1)
    ]
}
