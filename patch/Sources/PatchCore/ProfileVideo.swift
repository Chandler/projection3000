import Foundation

public enum ProfileVideoStyle {
    public static let names = ["X Red", "X Green", "X Blue", "Y Red", "Y Green", "Y Blue"]
    public static let processorParameters: [ParameterSpec] = [
        .init("amount","Processing amount",0,1,0.7),
        .init("slotA","Signal A",0,5,0,choices:names,midi:true,step:1),
        .init("slotB","Signal B",0,6,5,choices:names+["Off"],midi:true,step:1),
        .init("gain","Signal gain",0,4,1.4),
        .init("smooth","Smoothing radius (samples)",0,64,8,step:1),
        .init("drive","Soft clipping",0,8,1.5),
        .init("bias","Signal offset",-0.5,0.5,0),
        .init("shift","Phase shift (cycles)",-0.5,0.5,0),
        .init("oscMix","Oscillator replacement",0,1,0.25),
        .init("oscCycles","Oscillator cycles",1,32,4,step:1),
        .init("oscLevel","Oscillator amplitude",0,0.5,0.15),
        .init("speed","Oscillator motion",0,2,0.15)
    ]
    public static let decoderParameters: [ParameterSpec] = [
        .init("view","View",0,4,2,choices:["Reconstructed","Original","Split comparison","Residual detail","Six profiles"],midi:false,step:1),
        .init("mix","Replacement amount",0,1,1)
    ]
}
