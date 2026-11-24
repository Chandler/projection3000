import Foundation

public enum PowerGlitchStyle {
    public static let parameters: [ParameterSpec] = [
        .init("recipe","Pattern",0,1,0,choices:["Power flicker","Signal breakup"],midi:true,step:1),
        .init("shape","Shape",0,3,0,choices:["Mixed","Rows","Columns","Chunks"],midi:true,step:1),
        .init("burstRate","Bursts / second",0,3,0.35),
        .init("flashes","Flashes / burst",1,8,3,step:1),
        .init("rate","Burst speed (Hz)",0.1,40,24),
        .init("flashMs","Flash length (ms)",8,120,25),
        .init("variation","Timing variation",0,1,0.55),
        .init("spread","Region size",0.05,1,0.35),
        .init("blocks","Region detail",1,64,10,step:1),
        .init("jitter","Spatial jitter",0,1,0.35),
        .init("dropout","Cutout density",0,1,0.7),
        .init("blackout","Full blackout chance",0,1,0.1),
        .init("static","Static",0,1,0.2),
        .init("bands","Scanline breaks",0,1,0.35),
        .init("seed","Seed",0,65535,1,midi:false,step:1)
    ]
    private static func random(_ event: UInt32,_ salt: UInt32) -> Double {
        var x=event &* 747796405 &+ salt &* 2891336453
        x ^= x >> 16;x = x &* 2246822519;x ^= x >> 13;x = x &* 3266489917;x ^= x >> 16
        return Double(x)/Double(UInt32.max)
    }
    /// Sparse events and quick flashes have separate clocks. The region seed is
    /// constant throughout a burst; only its small displacement changes per flash.
    public static func frame(_ node: Node,time: Double) -> [Float] {
        let frequency=node.value("burstRate"),seed=UInt32(node.value("seed").rounded())
        var values: [Float] = [0,0,Float(node.value("dropout")),Float(node.value("blocks")),Float(node.value("jitter")),Float(node.value("blackout")),Float(node.value("static")),Float(node.value("bands")),Float(seed),Float(node.value("recipe")),Float(node.value("spread")),Float(node.value("shape"))]
        guard frequency>0,time.isFinite else { return values }
        let period=1/frequency,epoch=floor(max(0,time)/period)
        let event=UInt32(truncatingIfNeeded:UInt64(epoch)) &+ seed &* 131
        let count=max(1,min(8,Int(node.value("flashes").rounded())))
        // Keep silence between bursts even at the densest timing settings.
        let interval=min(1/max(0.1,node.value("rate")),period*0.65/(Double(count)+0.5))
        let span=(Double(count)+0.5)*interval,variation=node.value("variation")
        let onset=(period-span)*(0.5+(random(event,1)-0.5)*variation)
        let local=max(0,time)-epoch*period-onset
        values[8]=Float(event%65521)
        for pulse in 0..<count {
            let salt=UInt32(pulse)+11
            let start=Double(pulse)*interval+(random(event,salt)-0.5)*interval*0.3*variation
            let width=min(interval*0.6,node.value("flashMs")/1000*(1+(random(event,salt+19)-0.5)*0.4*variation))
            if local>=start && local<start+width {
                values[0]=1;values[1]=Float(pulse);break
            }
        }
        return values
    }
}
