import Foundation
import AVFoundation
import QuartzCore

/// AVFoundation decodes the network source independently of the graph's render queue.
/// Mutable playback state belongs to callbackQueue; reconnects retain the last frame.
final class LiveStreamSource: @unchecked Sendable {
    let address: String
    let callbackQueue: DispatchQueue
    var player: AVPlayer?
    var output: AVPlayerItemVideoOutput?
    var loading=false
    var status="Connecting…"
    var lastFrame=0.0, started=0.0, retryAt=0.0
    var attempts=0
    var generation=UUID()
    private var targetBuffer=2.0
    private var filling=true
    private var buffered=0.0
    private var nextProbe=0.0
    private var playbackStarted=0.0
    private var seeking=false
    private var lastSeek=0.0
    private var lastProgress=0.0
    private var loadedEnd=0.0
    init(address: String,queue: DispatchQueue) { self.address=address;callbackQueue=queue }
    deinit { player?.pause();player?.replaceCurrentItem(with:nil) }
    func connect() {
        guard !loading else { return }
        guard let url=URL(string:address),["https","http"].contains(url.scheme?.lowercased() ?? ""),url.host != nil else { status="Enter an HTTP(S) stream URL";retryAt = .infinity;return }
        loading=true;started=CACurrentMediaTime();lastProgress=started;loadedEnd=0;buffered=0;nextProbe=0;filling=true;seeking=false
        status=attempts==0 ? "Connecting…":"Reconnecting…"
        let ticket=UUID();generation=ticket;let queue=callbackQueue
        let forward=max(1,targetBuffer+1)
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let item=AVPlayerItem(url:url)
            // This preference alone is advisory. Playback below also waits for a
            // contiguous reserve before starting or recovering from an underrun.
            item.preferredForwardBufferDuration=forward
            item.configuredTimeOffsetFromLive=CMTime(seconds:forward,preferredTimescale:600)
            item.automaticallyPreservesTimeOffsetFromLive=false
            item.canUseNetworkResourcesForLiveStreamingWhilePaused=true
            item.preferredMaximumResolution=CGSize(width:1920,height:1080)
            let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferMetalCompatibilityKey as String:true])
            item.add(output)
            let player=AVPlayer(playerItem:item);player.isMuted=true
            player.automaticallyWaitsToMinimizeStalling=true
            queue.async { [weak self] in
                guard let self,self.generation==ticket else { player.pause();return }
                self.player=player;self.output=output;self.loading=false
            }
        }
    }
    func pause() {
        player?.pause();player?.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused=false
        filling=true;nextProbe=0;lastProgress=CACurrentMediaTime()
    }
    /// Only count continuously loaded media from the playhead, not isolated later segments.
    private func bufferAhead(_ item: AVPlayerItem,at position: Double) -> Double {
        guard position.isFinite else { return 0 }
        var end=position
        let ranges=item.loadedTimeRanges.map(\.timeRangeValue).sorted { $0.start.seconds < $1.start.seconds }
        for range in ranges {
            let start=range.start.seconds,finish=CMTimeRangeGetEnd(range).seconds
            guard start.isFinite,finish.isFinite else { continue }
            if start>end+0.05 { break }
            if finish>end { end=finish }
        }
        if end>position+0.01 && end>loadedEnd+0.01 { loadedEnd=end;lastProgress=CACurrentMediaTime() }
        return max(0,end-position)
    }
    func frame(playing: Bool,bufferDuration: Double) -> CVPixelBuffer? {
        let now=CACurrentMediaTime(),requested=min(8,max(0,bufferDuration))
        if abs(requested-targetBuffer)>0.001 {
            let increased=requested>targetBuffer;targetBuffer=requested
            player?.currentItem?.preferredForwardBufferDuration=max(1,requested+1)
            player?.currentItem?.configuredTimeOffsetFromLive=CMTime(seconds:max(1,requested+1),preferredTimescale:600)
            if increased { filling=true;player?.pause() }
            nextProbe=0
        }
        guard playing else { pause();status="Paused";return nil }
        if player == nil && !loading && now>=retryAt { connect() }
        guard let player,let output,let item=player.currentItem else { return nil }
        item.canUseNetworkResourcesForLiveStreamingWhilePaused=true
        if now>=nextProbe {
            nextProbe=now+0.1
            buffered=bufferAhead(item,at:player.currentTime().seconds)
            // A sliding live window or timestamp discontinuity can leave the old
            // playhead outside every loaded range. Recover only after output has
            // really stopped, never merely because range metadata moved ahead.
            if !seeking && now-max(lastFrame,playbackStarted)>0.6 && now-lastSeek>1,
               let range=item.loadedTimeRanges.map(\.timeRangeValue).first(where:{ $0.start.seconds>player.currentTime().seconds+0.1 }) {
                seeking=true;lastSeek=now;filling=true;player.pause()
                let ticket=generation,queue=callbackQueue
                player.seek(to:range.start,toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] _ in
                    queue.async { [weak self] in
                        guard let self,self.generation==ticket else { return }
                        self.seeking=false;self.nextProbe=0;self.lastProgress=CACurrentMediaTime()
                    }
                }
            }
            // A finite HTTP movie can finish with less than a full buffer remaining.
            let remaining=item.duration.seconds-player.currentTime().seconds
            let window=item.seekableTimeRanges.map { $0.timeRangeValue.duration.seconds }.filter { $0.isFinite && $0>0 }.max()
            let availableReserve=window.map { min(targetBuffer,max(0.05,$0-0.25)) } ?? targetBuffer
            let reserve=remaining.isFinite && remaining>0 ? min(availableReserve,remaining):availableReserve
            if !filling && item.isPlaybackBufferEmpty && now-max(lastFrame,playbackStarted)>0.5 { filling=true;player.pause() }
            if filling && !seeking && item.status == .readyToPlay && buffered>=max(0.05,reserve-0.05) {
                filling=false;playbackStarted=now
                player.play()
                lastProgress=now
            }
            status=filling ? String(format:"Buffering %.1f / %.1f s",buffered,reserve) : String(format:"Live · %.1f s buffered",buffered)
        }
        // Never repeatedly call play() during an underrun: refill once, then let
        // AVPlayer's media clock pace frames at their original presentation times.
        if !filling && !seeking {
            let time=output.itemTime(forHostTime:now)
            if output.hasNewPixelBuffer(forItemTime:time),let pixel=output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:nil) {
                lastFrame=now;lastProgress=now;attempts=0;return pixel
            }
        }
        if item.status == .failed || now-max(started,lastProgress)>20 {
            status=item.error?.localizedDescription ?? "Reconnecting…"
            player.pause();player.replaceCurrentItem(with:nil);self.player=nil;self.output=nil
            attempts+=1;retryAt=now+min(30,Double(attempts)*3)
        }
        return nil
    }
}

import SwiftUI
import PatchCore

struct LiveStreamInspector: View {
    @ObservedObject var workspace: Workspace
    let renderer: Renderer
    let id: UUID
    @State private var address=""
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("STREAM URL").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)
            TextField("https://…/live.m3u8",text:$address).textFieldStyle(.squareBorder).onSubmit { connect() }
            HStack {
                Button("Connect") { connect() }.controlSize(.small)
                Spacer()
                TimelineView(.periodic(from:.now,by:0.5)) { _ in Text(renderer.status[id] ?? "Offline").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.onAppear { address=workspace.graph.node(id)?.text ?? "" }
         .onChange(of:workspace.graph.node(id)?.text) { _,value in address=value ?? "" }
    }
    func connect() { workspace.update(id) { $0.text=address.trimmingCharacters(in:.whitespacesAndNewlines);$0.enabled=true } }
}
