import Foundation
import AVFoundation
import CryptoKit
import PatchCore

/// Shared by video and audio loaders. Concurrent requests for one MKV await the
/// same conversion; projects always retain the original source path.
actor MediaCompatibility {
    static let shared = MediaCompatibility()
    private var pending: [String:Task<URL,Error>] = [:]
    static func needsPreparation(_ path: String) -> Bool {
        URL(fileURLWithPath:path).pathExtension.lowercased() == "mkv"
    }
    func playbackURL(for path: String) async throws -> URL {
        let source = URL(fileURLWithPath:path)
        guard Self.needsPreparation(path) else { return source }
        let values = try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        let identity = "patch-mkv-v1|\(source.standardizedFileURL.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let key = SHA256.hash(data:Data(identity.utf8)).map { String(format:"%02x",$0) }.joined()
        let folder = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("Patch/Media")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let target = folder.appendingPathComponent(key+".mov")
        if FileManager.default.fileExists(atPath:target.path) { return target }
        if let task = pending[key] { return try await task.value }
        let task = Task.detached(priority:.userInitiated) { try await Self.prepare(source:source,target:target) }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }
    private static func executable(_ name: String) -> URL? {
        let folders = ["/opt/homebrew/bin","/usr/local/bin","/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map(String.init)
        return folders.map { URL(fileURLWithPath:$0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath:$0.path) }
    }
    private static func run(_ executable: URL,_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        // Drain while the process runs, so diagnostic output cannot fill a pipe.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding:output,as:UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GraphError("MKV preparation failed: \(String(text.suffix(1600)))")
        }
        return text.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    private static func prepare(source: URL,target: URL) async throws -> URL {
        guard let ffmpeg = executable("ffmpeg") else { throw GraphError("MKV playback needs FFmpeg · install with brew install ffmpeg") }
        let temp = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".mov")
        defer { try? FileManager.default.removeItem(at:temp) }
        let common = ["-hide_banner","-loglevel","error","-nostdin","-y","-i",source.path,"-map","0:v:0","-map","0:a:0?","-sn","-dn"]
        let audio = ["-c:a","aac","-b:a","192k","-ac","2"]
        let codec = executable("ffprobe").flatMap { try? run($0,["-v","error","-select_streams","v:0","-show_entries","stream=codec_name","-of","default=noprint_wrappers=1:nokey=1",source.path]) }
        var remuxed = false
        if codec == "h264" || codec == "hevc" {
            do {
                _ = try run(ffmpeg,common+["-c:v","copy"]+(codec == "hevc" ? ["-tag:v","hvc1"] : [])+audio+["-movflags","+faststart",temp.path])
                let asset = AVURLAsset(url:temp)
                remuxed = try await asset.load(.isPlayable)
            } catch { remuxed = false }
        }
        if !remuxed {
            _ = try run(ffmpeg,common+["-c:v","libx264","-preset","fast","-crf","18","-pix_fmt","yuv420p","-vf","pad=ceil(iw/2)*2:ceil(ih/2)*2"]+audio+["-movflags","+faststart",temp.path])
        }
        let asset = AVURLAsset(url:temp)
        guard try await asset.load(.isPlayable), try await !asset.loadTracks(withMediaType:.video).isEmpty else {
            throw GraphError("MKV preparation produced no playable video")
        }
        // Publish only a complete file. Another Patch process may have won the race.
        if !FileManager.default.fileExists(atPath:target.path) {
            do { try FileManager.default.moveItem(at:temp,to:target) }
            catch { if !FileManager.default.fileExists(atPath:target.path) { throw error } }
        }
        return target
    }
}
