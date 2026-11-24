import Foundation
public enum FlashCellsStyle {
    public static var parameters: [ParameterSpec] { [
        .init("rate","Flash Rate",0,12,2),
        .init("chance","Chance",0,1,0.7),
        .init("onTime","On Time",0.03,0.95,0.5),
        .init("fade","Fade",0,1,0.65),
        .init("colorMode","Color Selection",0,2,0,choices:["Random per flash","Cycle","Fixed per cell"],step:1),
        .init("seed","Seed",0,65535,17,step:1)
    ] }
}
