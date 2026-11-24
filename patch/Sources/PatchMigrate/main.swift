import CryptoKit
import Foundation
import PatchCore

typealias Object = [String:Any]

struct Options {
    var apply = false
    var backupDirectory: URL?
    var roots = [URL]()

    init(_ arguments: [String]) throws {
        var args = arguments.makeIterator()
        while let argument = args.next() {
            switch argument {
            case "--apply": apply = true
            case "--dry-run": apply = false
            case "--backup-dir":
                guard let path = args.next() else { throw GraphError("--backup-dir requires a directory") }
                backupDirectory = URL(fileURLWithPath:path,isDirectory:true)
            case "-h","--help":
                print("patch-migrate [--dry-run | --apply] [--backup-dir DIRECTORY] [FILE_OR_DIRECTORY ...]")
                exit(0)
            default:
                guard !argument.hasPrefix("-") else { throw GraphError("Unknown option "+argument) }
                roots.append(URL(fileURLWithPath:argument))
            }
        }
        if roots.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            roots = [home.appendingPathComponent("Projection3000"),home.appendingPathComponent("Library/Application Support/Patch")]
                .filter { FileManager.default.fileExists(atPath:$0.path) }
        }
    }
}

func object(_ value: Any) throws -> Object {
    guard let result = value as? Object else { throw GraphError("Expected a JSON object") }
    return result
}
func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
}
func digest(_ data: Data) -> String {
    SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
}

struct ConvertedGraph {
    let value: Object
    let revision: String
    let changed: Bool
}

struct Converter {
    var cache = [Data:ConvertedGraph]()
    var graphs = 0

    mutating func graph(_ input: Object) throws -> ConvertedGraph {
        let data = try json(input)
        let result: ConvertedGraph
        if let cached = cache[data] { result = cached }
        else {
            let current = input["version"] as? Int == Graph.currentVersion ? try? Graph.read(data) : nil
            let converted = try current ?? Graph.migrate(data)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(converted)
            // Accept the exact bytes that will be written with the production reader.
            _ = try Graph.read(encoded)
            result = ConvertedGraph(value:try object(JSONSerialization.jsonObject(with:encoded)),revision:digest(encoded),changed:current == nil)
            cache[data] = result
        }
        graphs += 1
        return result
    }

    mutating func session(_ original: Object) throws -> (Object,Bool) {
        var output = original, updated = false
        if let value = original["graph"] {
            let result = try graph(object(value))
            if result.changed {
                output["graph"] = result.value
                if output["graphRevision"] != nil { output["graphRevision"] = result.revision }
                updated = true
            }
        }
        if let value = original["tabs"] {
            guard let tabs = value as? [Object] else { throw GraphError("Invalid session tabs") }
            var result = [Object]()
            for (i,tab) in tabs.enumerated() {
                guard tab["graph"] != nil || tab["tabs"] != nil else { throw GraphError("Tab \(i+1) has no graph") }
                do {
                    let (snapshot,changed) = try session(tab)
                    result.append(snapshot); updated = updated || changed
                } catch { throw GraphError("Tab \(i+1): "+error.localizedDescription) }
            }
            output["tabs"] = result
        }
        return (output,updated)
    }

    mutating func subpatch(_ template: Object) throws -> (Object,Bool) {
        if template["version"] as? Int == SubpatchTemplate.currentVersion {
            _ = try SubpatchTemplate.read(json(template))
            return (template,false)
        }
        guard template["version"] as? Int == 1, let component = template["component"] else { throw GraphError("Unsupported subpatch version") }
        var synthetic: Object = ["version":1,"width":1280,"height":720,"fps":60,"components":[component]]
        for field in ["nodes","edges","midiMappings"] {
            guard let value = template[field] else { throw GraphError("Missing subpatch "+field) }
            synthetic[field] = value
        }
        let result = try graph(synthetic)
        guard let components = result.value["components"] as? [Object],components.count == 1 else { throw GraphError("Missing converted subpatch component") }
        var output = template
        output["version"] = SubpatchTemplate.currentVersion; output["component"] = components[0]
        for field in ["nodes","edges","midiMappings"] { output[field] = result.value[field] }
        _ = try SubpatchTemplate.read(json(output))
        return (output,true)
    }

    mutating func document(_ input: Data, url: URL, explicit: Bool) throws -> (String,Data?)? {
        let name = url.lastPathComponent.lowercased()
        let expected = explicit || name.hasSuffix(".patch.json") || name.hasSuffix(".subpatch.json") || name.hasSuffix(".session.json") || name == "patch-session.json"
        let original: Object
        do { original = try object(JSONSerialization.jsonObject(with:input)) }
        catch { if expected { throw error }; return nil }
        let kind: String, value: Object, updated: Bool
        if original["kind"] as? String == "lightField", let file = original["file"] as? String, let name = original["name"] as? String {
            let node: Object = ["id":UUID().uuidString,"kind":"lightField","name":name,"file":file,"position":["x":0,"y":0],"parameters":Object(),"enabled":true]
            let graph: Object = ["version":1,"width":1280,"height":720,"fps":60,"nodes":[node],"edges":[]]
            guard let fields = try Graph.migrate(json(graph)).nodes.first?.fieldParameters else { throw GraphError("Cannot recover light field parameters") }
            var manifest = original
            let parameters = try JSONSerialization.jsonObject(with:JSONEncoder().encode(fields))
            if let declared = manifest["parameters"],try json(declared) != json(parameters) { throw GraphError("Legacy field already declares a different parameter layout") }
            manifest["parameters"] = parameters
            manifest["kind"] = NodeKind.fieldShader.rawValue
            return ("shader manifest",try json(manifest))
        }
        if original["component"] != nil && original["nodes"] != nil || name.hasSuffix(".subpatch.json") {
            kind = "subpatch"; (value,updated) = try subpatch(original)
        } else if original["nodes"] != nil && original["edges"] != nil && original["fps"] != nil {
            let result = try graph(original)
            kind = "project"; value = result.value; updated = result.changed
        } else if (original["graph"] as? Object)?["nodes"] != nil || original["tabs"] is [Object] && (expected || (original["tabs"] as? [Object])?.first?["graph"] != nil) {
            kind = "session"; (value,updated) = try session(original)
        } else {
            if expected { throw GraphError("Unrecognized Patch document") }
            return nil
        }
        return (kind, updated ? try json(value) : nil)
    }
}

struct Change {
    let url: URL
    let before: Data
    let after: Data
}

func inputs(_ roots: [URL]) throws -> [URL:Bool] {
    let fm = FileManager.default
    var result = [URL:Bool]()
    for raw in roots {
        let root = raw.standardizedFileURL.resolvingSymlinksInPath()
        let info = try root.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey])
        if info.isRegularFile == true { result[root] = true; continue }
        guard info.isDirectory == true else { throw GraphError("Expected file or directory: "+root.path) }
        var failure: Error?
        guard let files = fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[],errorHandler:{ _,error in failure = error; return false }) else { throw GraphError("Cannot read "+root.path) }
        for case let file as URL in files where file.pathExtension.lowercased() == "json" {
            let info = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            if info.isRegularFile == true && info.isSymbolicLink != true { result[file.standardizedFileURL] = result[file.standardizedFileURL] ?? false }
        }
        if let failure { throw failure }
    }
    return result
}

/// Refresh integrity records only for files that belong to this migration.
func packageUpdates(_ manifests: [URL], changes: [Change]) throws -> [Change] {
    let byURL = Dictionary(uniqueKeysWithValues:changes.map { ($0.url,$0) })
    var result = [Change]()
    for url in manifests {
        let before = try Data(contentsOf:url), value = try JSONSerialization.jsonObject(with:before)
        let directory = url.deletingLastPathComponent()
        func change(_ relative: String, recorded: String) -> Change? {
            let target = directory.appendingPathComponent(relative).standardizedFileURL
            guard let changed = byURL[target] else { return nil }
            if digest(changed.before) != recorded { print("Previously stale checksum  "+url.path+"  "+relative) }
            return changed
        }
        var after: Data?
        if var mapping = value as? Object,mapping["format"] as? String == "vj-portable-show/1",var hashes = mapping["sha256"] as? [String:String] {
            var updated = false
            for (path,hash) in hashes {
                if let file = change(path,recorded:hash) { hashes[path] = digest(file.after); updated = true }
            }
            if updated { mapping["sha256"] = hashes; after = try json(mapping) }
        } else if var entries = value as? [Object] {
            var updated = false
            for i in entries.indices {
                guard let path = entries[i]["path"] as? String,let sha = entries[i]["sha256"] as? String,
                      let file = change(path,recorded:sha) else { continue }
                entries[i]["sha256"] = digest(file.after); entries[i]["bytes"] = file.after.count; updated = true
            }
            if updated { after = try json(entries) }
        }
        if let after { result.append(.init(url:url,before:before,after:after)); print("Pending package manifest  "+url.path) }
    }
    return result
}

func write(_ changes: [Change], backups base: URL?) throws {
    let fm = FileManager.default
    let root = base ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Projection3000 Migration Backups")
    let directory = root.appendingPathComponent(ISO8601DateFormatter().string(from:Date())+"-"+UUID().uuidString)
    try fm.createDirectory(at:directory,withIntermediateDirectories:true)
    print("Backups: "+directory.path)
    var manifest = [Object]()
    for (i,change) in changes.enumerated() {
        guard try Data(contentsOf:change.url) == change.before else { throw GraphError("File changed during preflight: "+change.url.path) }
        let name = String(format:"%04d-",i+1)+change.url.lastPathComponent+".bak"
        let backup = directory.appendingPathComponent(name)
        try fm.copyItem(at:change.url,to:backup)
        guard try Data(contentsOf:backup) == change.before else { throw GraphError("File changed during backup: "+change.url.path) }
        manifest.append(["path":change.url.path,"backup":name,"beforeSHA256":digest(change.before),"afterSHA256":digest(change.after)])
    }
    try json(["files":manifest]).write(to:directory.appendingPathComponent("manifest.json"),options:.atomic)
    var installed = [Change]()
    do {
        for change in changes {
            guard try Data(contentsOf:change.url) == change.before else { throw GraphError("File changed before writing: "+change.url.path) }
            try change.after.write(to:change.url,options:.atomic)
            installed.append(change)
            guard try Data(contentsOf:change.url) == change.after else { throw GraphError("File changed after writing: "+change.url.path) }
            print("Migrated "+change.url.path)
        }
    } catch {
        for change in installed.reversed() {
            do {
                guard try Data(contentsOf:change.url) == change.after else { throw GraphError("Concurrent edit") }
                try change.before.write(to:change.url,options:.atomic)
            } catch { FileHandle.standardError.write(Data(("Restore from backup if needed: "+change.url.path+"\n").utf8)) }
        }
        throw error
    }
}

do {
    if CommandLine.arguments.dropFirst().first == "compose" {
        try convertComposeState(Array(CommandLine.arguments.dropFirst(2)))
        exit(0)
    }
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    var converter = Converter(), changes = [Change](), failures = 0, files = 0
    let candidates = try inputs(options.roots)
    for url in candidates.keys.sorted(by:{ $0.path < $1.path }) {
        do {
            let data = try Data(contentsOf:url)
            guard let (kind,after) = try converter.document(data,url:url,explicit:candidates[url] == true) else { continue }
            files += 1
            if let after {
                changes.append(Change(url:url,before:data,after:after))
                print("Pending \(kind)  "+url.path)
            }
        } catch {
            failures += 1; FileHandle.standardError.write(Data(("Failed "+url.path+": "+error.localizedDescription+"\n").utf8))
        }
    }
    var manifests = Set<URL>()
    for change in changes {
        var parent = change.url.deletingLastPathComponent()
        while parent.path != "/" && !parent.path.isEmpty {
            let manifest = parent.appendingPathComponent("manifest.json").standardizedFileURL
            if FileManager.default.fileExists(atPath:manifest.path) { manifests.insert(manifest) }
            parent.deleteLastPathComponent()
        }
    }
    let packages = try packageUpdates(manifests.sorted { $0.path < $1.path },changes:changes)
    changes += packages
    files += packages.count
    print("\(files) documents inspected, \(converter.graphs) graphs, \(changes.count) documents pending, \(failures) failures.")
    guard failures == 0 else { throw GraphError("Migration preflight failed") }
    if options.apply && !changes.isEmpty { try write(changes,backups:options.backupDirectory) }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); exit(1)
}
