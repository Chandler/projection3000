import AVFoundation

/// Queue-owned streaming PCM conversion. AVAudioConverter supplies the anti-alias
/// and reconstruction filters; hardware callbacks continue to move native PCM only.
final class AudioResamplingContext {
    private struct Format: Hashable { var source: Double;var target: Double }
    private final class Stream {
        let source: Double,target: Double
        private let converter: AVAudioConverter
        private var input: AVAudioPCMBuffer
        private var output: AVAudioPCMBuffer
        private var pending=[Float]()
        private var readOffset=0
        private var lastTime: Double?
        private var cached=[Float]()
        private var duration=0.01
        var error: String?

        init(source: Double,target: Double) throws {
            guard source>0,target>0,source.isFinite,target.isFinite,
                  let from=AVAudioFormat(standardFormatWithSampleRate:source,channels:2),
                  let to=AVAudioFormat(standardFormatWithSampleRate:target,channels:2),
                  let converter=AVAudioConverter(from:from,to:to),
                  let input=AVAudioPCMBuffer(pcmFormat:from,frameCapacity:4096),
                  let output=AVAudioPCMBuffer(pcmFormat:to,frameCapacity:AVAudioFrameCount(ceil(4096*target/source))+1024) else {
                throw NSError(domain:"Patch.Audio",code:1,userInfo:[NSLocalizedDescriptionKey:"Cannot create audio sample-rate converter"])
            }
            self.source=source;self.target=target;self.converter=converter;self.input=input;self.output=output
            converter.sampleRateConverterAlgorithm=AVSampleRateConverterAlgorithm_Normal
            converter.sampleRateConverterQuality=AVAudioQuality.max.rawValue
            // Apple's live-input mode keeps filter history and expresses its small
            // startup delay in the output, without waiting for future capture blocks.
            converter.primeMethod = .none
        }
        func render(_ samples: [Float],time: Double) -> [Float] {
            if lastTime == time { return cached }
            let frames=samples.count/2,count=Int((Double(frames)*target/source).rounded())
            if let previous=lastTime,time<previous || time-previous>max(0.05,duration*3) {
                converter.reset();pending.removeAll(keepingCapacity:true);readOffset=0
            }
            lastTime=time;duration=Double(frames)/source;error=nil
            guard frames>0 else { cached=[];return cached }
            if input.frameCapacity<frames {
                guard let buffer=AVAudioPCMBuffer(pcmFormat:input.format,frameCapacity:AVAudioFrameCount(frames)) else {
                    error="Cannot allocate audio conversion input";cached=[Float](repeating:0,count:count*2);return cached
                }
                input=buffer
            }
            let capacity=AVAudioFrameCount(ceil(Double(frames)*target/source))+1024
            if output.frameCapacity<capacity {
                guard let buffer=AVAudioPCMBuffer(pcmFormat:output.format,frameCapacity:capacity) else {
                    error="Cannot allocate audio conversion output";cached=[Float](repeating:0,count:count*2);return cached
                }
                output=buffer
            }
            input.frameLength=AVAudioFrameCount(frames)
            let channels=input.floatChannelData!
            for i in 0..<frames { channels[0][i]=samples[i*2];channels[1][i]=samples[i*2+1] }
            var supplied=false
            while true {
                output.frameLength=0
                var failure: NSError?
                let status=converter.convert(to:output,error:&failure) { [input] _,state in
                    guard !supplied else { state.pointee = .noDataNow;return nil }
                    supplied=true;state.pointee = .haveData;return input
                }
                if status == .error {
                    error=failure?.localizedDescription ?? "Audio sample-rate conversion failed"
                    converter.reset();pending.removeAll(keepingCapacity:true);readOffset=0
                    cached=[Float](repeating:0,count:count*2);return cached
                }
                let converted=Int(output.frameLength),data=output.floatChannelData!
                for i in 0..<converted { pending.append(data[0][i]);pending.append(data[1][i]) }
                if status != .haveData || converted == 0 { break }
            }
            // A live converter can buffer a few samples. Keep its output in order
            // across blocks rather than padding every block boundary or repeating data.
            if pending.count-readOffset>=count*2 {
                cached=Array(pending[readOffset..<readOffset+count*2]);readOffset += count*2
                if readOffset>=pending.count { pending.removeAll(keepingCapacity:true);readOffset=0 }
                else if readOffset>16384 { pending.removeFirst(readOffset);readOffset=0 }
            } else { cached=[Float](repeating:0,count:count*2) }
            return cached
        }
    }
    private var streams: [Format:Stream]=[:]
    private(set) var error: String?
    func render(_ samples: [Float],source: Double,target: Double,time: Double) -> [Float] {
        guard source != target else { return samples }
        let format=Format(source:source,target:target)
        do {
            if streams[format] == nil { streams[format]=try Stream(source:source,target:target) }
            let stream=streams[format]!,result=stream.render(samples,time:time)
            error=stream.error;return result
        } catch {
            self.error=error.localizedDescription
            return [Float](repeating:0,count:max(0,Int((Double(samples.count/2)*target/source).rounded()))*2)
        }
    }
}
