import Foundation
import Metal
import PatchCore

// One bounded analysis/history state per visualizer, confined to the render queue.
final class AudioVisualizer {
    private var smoothed = [Float](repeating:0,count:512)
    private var history = [UInt8](repeating:0,count:512*256)
    private var previousTime: Double?
    private var columnTime = 0.0
    private var source: UUID?
    private var settings: [Double] = []

    func update(window: [Float], time: Double?, source: UUID?, node: Node, playing: Bool) -> [Float] {
        let config = [node.value("mode"),node.value("logFrequency"),node.value("floor"),node.value("history")]
        if self.source != source || settings != config {
            self.source=source; settings=config; previousTime=nil; columnTime=0
            smoothed=Array(repeating:0,count:512); history=Array(repeating:0,count:512*256)
        }
        let gain = Float(pow(10,node.value("gain")/20))
        if node.value("mode") < 0.5 {
            let count = min(window.count,max(2,Int(node.value("window")*48)))
            let samples = Array(window.suffix(count))
            guard samples.count > 1 else { return Array(repeating:0,count:512) }
            return (0..<512).map { i in
                let x=Double(i)*Double(samples.count-1)/511, lo=Int(x), hi=min(samples.count-1,lo+1)
                return max(-1,min(1,(samples[lo]+(samples[hi]-samples[lo])*Float(x-Double(lo)))*gain))
            }
        }
        guard let time else { smoothed=Array(repeating:0,count:512); history=Array(repeating:0,count:512*256); previousTime=nil; return smoothed }
        let dt = min(0.1,max(0,time-(previousTime ?? time-0.02)))
        if previousTime == time || (!playing && previousTime != nil) { return smoothed }
        previousTime=time
        let magnitudes = spectrum(window)
        let floor = Float(node.value("floor")), smoothing = Float(node.value("smoothing"))
        let retain = exp(-Float(dt)/max(0.001,smoothing))
        for i in 0..<512 {
            let low=frequency(Double(i)/512,node), high=frequency(Double(i+1)/512,node)
            let lo=max(1,min(1023,Int(low*2048/48000))),hi=max(lo,min(1023,Int(ceil(high*2048/48000))))
            let amplitude=(magnitudes[lo...hi].max() ?? 0)*gain
            let level=max(0,min(1,(20*log10(max(1e-9,amplitude))-floor)/(-floor)))
            smoothed[i]=max(level,smoothed[i]*retain+level*(1-retain))
        }
        if playing {
            columnTime += dt
            let interval=node.value("history")/512
            let columns=min(512,Int(columnTime/interval))
            if columns > 0 {
                columnTime -= Double(columns)*interval
                for row in 0..<256 {
                    let start=row*512
                    if columns < 512 { for x in 0..<(512-columns) { history[start+x]=history[start+x+columns] } }
                    let value=UInt8(max(0,min(255,smoothed[(255-row)*2]*255)))
                    for x in (512-columns)..<512 { history[start+x]=value }
                }
            }
        }
        return smoothed
    }
    private func frequency(_ x: Double,_ node: Node) -> Double {
        node.value("logFrequency") > 0.5 ? 20*pow(1000,x) : x*20000
    }
    func historyTexture(_ device: MTLDevice) -> MTLTexture? {
        // A fresh small upload avoids CPU writes to a texture still in flight.
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Unorm,width:512,height:256,mipmapped:false)
        desc.storageMode = .shared; desc.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:desc) else { return nil }
        history.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,512,256),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:512) }
        return texture
    }
    private func spectrum(_ samples: [Float]) -> [Float] {
        // 2048-point Hann-windowed radix-2 FFT; amplitude normalized to full scale.
        let n=2048
        var real=Array(repeating:Float(0),count:n),imag=real
        let input=Array(samples.suffix(n)), offset=n-input.count
        for i in input.indices { let j=i+offset; real[j]=input[i]*Float(0.5-0.5*cos(2*Double.pi*Double(j)/Double(n-1))) }
        var j=0
        for i in 1..<n {
            var bit=n>>1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { real.swapAt(i,j); imag.swapAt(i,j) }
        }
        var length=2
        while length <= n {
            let angle = -2*Double.pi/Double(length),wr=Float(cos(angle)),wi=Float(sin(angle))
            for start in stride(from:0,to:n,by:length) {
                var ur:Float=1,ui:Float=0
                for k in 0..<(length/2) {
                    let a=start+k,b=a+length/2,vr=real[b]*ur-imag[b]*ui,vi=real[b]*ui+imag[b]*ur
                    real[b]=real[a]-vr; imag[b]=imag[a]-vi; real[a]+=vr; imag[a]+=vi
                    let next=ur*wr-ui*wi; ui=ur*wi+ui*wr; ur=next
                }
            }
            length *= 2
        }
        return (0..<(n/2)).map { sqrt(real[$0]*real[$0]+imag[$0]*imag[$0])*4/Float(n) }
    }
}
