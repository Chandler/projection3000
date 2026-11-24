import AppKit
import Combine
import Darwin
import PatchCore

struct LibraryFavorite: Codable, Equatable, Hashable {
    let kind: String
    let id: String
    let name: String

    func matches(_ other: Self) -> Bool { kind == other.kind && id == other.id }
    func validate() throws {
        guard ["patchNode","subpatch","composeEffect","media","source","patchOutput"].contains(kind),
              !id.isEmpty,id.utf8.count <= 32_768,!name.isEmpty,name.count <= 1024 else {
            throw GraphError("Invalid favorite kind, ID or name")
        }
    }
}

struct LibrarySubpatch: Equatable, Identifiable {
    struct Port: Codable, Equatable {
        let id: String
        let name: String
        let type: PortType
        var composeType: String? {
            [.video,.collection,.trace,.palette,.control].contains(type) ? type.rawValue : nil
        }
        var object: [String:Any] {
            var value = ["id":id,"name":name,"type":type.rawValue]
            if let composeType { value["composeType"] = composeType }
            return value
        }
    }
    let id: String
    let name: String
    let url: URL
    let bundled: Bool
    let outputs: [Port]
    let inputs: [Port]
    let favorite: LibraryFavorite
    let vectorArt: Bool
    let processingInput: UUID?
    var object: [String:Any] {
        var result: [String:Any] = ["id":id,"name":name,"bundled":bundled,"outputs":outputs.map(\.object),"inputs":inputs.map(\.object),
                                   "favorite":["kind":favorite.kind,"id":favorite.id,"name":favorite.name]]
        if vectorArt { result["category"] = "Vector Art" }
        result["processingInput"] = processingInput?.uuidString
        return result
    }
}

private struct FavoriteFile: Codable {
    var version = 1
    var favorites: [LibraryFavorite] = []
}

private enum LibraryFiles {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projection3000",isDirectory:true)
    static let subpatches = root.appendingPathComponent("Patch/Subpatches",isDirectory:true)
    static let favorites = root.appendingPathComponent("Library/Favorites.json")
    private static let cacheLock = NSLock()
    private struct CachedFile {
        let date: Date?
        let size: Int?
        let number: AnyHashable?
        let result: Result<LibrarySubpatch,Error>
    }
    private static var cache: [URL:CachedFile] = [:]

    static func readFavorites() throws -> [LibraryFavorite] {
        let data: Data
        do { data = try Data(contentsOf:favorites) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        let file = try JSONDecoder().decode(FavoriteFile.self,from:data)
        guard file.version == 1,let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(object.keys) == ["version","favorites"], let items = object["favorites"] as? [[String:Any]],
              items.allSatisfy({ Set($0.keys) == ["kind","id","name"] }) else { throw GraphError("Unsupported favorites file") }
        var unique = Set<[String]>()
        for item in file.favorites {
            try item.validate()
            guard unique.insert([item.kind,item.id]).inserted else { throw GraphError("Duplicate favorite") }
        }
        return file.favorites
    }

    static func setFavorite(_ item: LibraryFavorite,pinned: Bool) throws -> [LibraryFavorite] {
        try item.validate()
        let directory = favorites.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let fd = open(directory.appendingPathComponent(".favorites.lock").path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue:errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd,LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(.init(rawValue:errno) ?? .EIO) }
        }
        var values = try readFavorites()
        if let i = values.firstIndex(where:{ $0.matches(item) }) {
            if pinned {
                if values[i] == item { return values }
                values[i] = item
            } else { values.remove(at:i) }
        } else if pinned { values.append(item) }
        else { return values }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(FavoriteFile(favorites:values)).write(to:favorites,options:.atomic)
        return values
    }

    static func catalog() throws -> (entries:[LibrarySubpatch],diagnostics:[String]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let manager = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Subpatches",isDirectory:true)
        var files: [String:(URL,Bool)] = [:], diagnostics: [String] = []
        for (root,isBundled) in [(bundled,true),(Optional(subpatches),false)] {
            guard let root,manager.fileExists(atPath:root.path) else { continue }
            let keys: [URLResourceKey] = [.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey]
            guard let enumerator = manager.enumerator(at:root,includingPropertiesForKeys:keys,options:[.skipsHiddenFiles],errorHandler:{ url,error in diagnostics.append(url.lastPathComponent+" · "+error.localizedDescription); return true }) else { throw GraphError("Cannot open subpatch library") }
            for case let file as URL in enumerator {
                let info = try file.resourceValues(forKeys:Set(keys))
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard info.isRegularFile == true,file.lastPathComponent.hasSuffix(".subpatch.json") else { continue }
                let relative = file.pathComponents.dropFirst(root.pathComponents.count).joined(separator:"/")
                files[relative] = (file,isBundled)
            }
        }
        let active = Set(files.values.map { $0.0 })
        cache = cache.filter { active.contains($0.key) }
        var entries: [LibrarySubpatch] = []
        for (id,(file,bundled)) in files {
            do {
                let attrs = try manager.attributesOfItem(atPath:file.path)
                let date = attrs[.modificationDate] as? Date, size = attrs[.size] as? Int, number = attrs[.systemFileNumber] as? AnyHashable
                if let cached = cache[file],cached.date == date,cached.size == size,cached.number == number { entries.append(try cached.result.get()); continue }
                let result = Result { () -> LibrarySubpatch in
                    let template = try SubpatchTemplate.read(Data(contentsOf:file))
                    guard let interface = template.component.interface else { throw GraphError("Missing subpatch interface") }
                    func ports(_ out: Bool) -> [LibrarySubpatch.Port] {
                        interface.ports.filter { $0.output == out }.map { .init(id:$0.id.uuidString,name:$0.name,type:$0.type) }
                    }
                    var favorite = LibraryFavorite(kind:"subpatch",id:id,name:template.component.name)
                    if bundled,template.nodes.count == 1,let member = template.nodes.first,interface.processingInput != nil || member.kind.vectorArtModule != nil {
                        let shader = member.file.flatMap { _ in ShaderCompiler.sourceURL(member) }.map { URL(fileURLWithPath:$0) }
                        favorite = CatalogNode(kind:member.kind,file:shader,name:template.component.name).favorite
                    }
                    return .init(id:id,name:template.component.name,url:file,bundled:bundled,outputs:ports(true),inputs:ports(false),favorite:favorite,vectorArt:template.nodes.contains { $0.kind.vectorArtModule != nil },processingInput:interface.processingInput)
                }
                cache[file] = CachedFile(date:date,size:size,number:number,result:result)
                entries.append(try result.get())
            } catch { diagnostics.append(id+" · "+error.localizedDescription) }
        }
        entries.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return (entries,diagnostics.sorted())
    }

    static func template(_ id: String) throws -> SubpatchTemplate {
        let catalog = try catalog()
        guard let entry = catalog.entries.first(where:{ $0.id == id }) else { throw GraphError("Unknown subpatch library ID: "+id) }
        return try SubpatchTemplate.read(Data(contentsOf:entry.url))
    }

    static func route(_ method: String,path: String,body: Data) throws -> [String:Any]? {
        if path == "/v1/library/subpatches" {
            guard method == "GET" else { throw GraphError("Use GET for the subpatch library") }
            let catalog = try catalog()
            return ["subpatches":catalog.entries.map(\.object),"diagnostics":catalog.diagnostics]
        }
        guard path == "/v1/library/favorites" else { return nil }
        let values: [LibraryFavorite]
        switch method {
        case "GET": values = try readFavorites()
        case "POST":
            let item = try JSONDecoder().decode(LibraryFavorite.self,from:body)
            struct Pin: Decodable { let pinned: Bool }
            let change = try JSONDecoder().decode(Pin.self,from:body)
            values = try setFavorite(item,pinned:change.pinned)
            DispatchQueue.main.async { PatchLibrary.shared.refresh() }
        default: throw GraphError("Use GET or POST for favorites")
        }
        return ["favorites":values.map { ["kind":$0.kind,"id":$0.id,"name":$0.name] }]
    }
}

extension CatalogNode {
    var favorite: LibraryFavorite {
        guard let file else { return .init(kind:"patchNode",id:kind.rawValue,name:title) }
        for base in [UserNodeLibrary.directory,UserNodeLibrary.bundledDirectory].compactMap({ $0 }) {
            let root = base.standardizedFileURL.pathComponents, path = file.standardizedFileURL.pathComponents
            if path.starts(with:root) { return .init(kind:"patchNode",id:"shader:"+path.dropFirst(root.count).joined(separator:"/"),name:title) }
        }
        return .init(kind:"patchNode",id:"shader:"+file.standardizedFileURL.path,name:title)
    }
}

final class PatchLibrary: ObservableObject {
    static let shared = PatchLibrary()
    static var subpatchDirectory: URL { LibraryFiles.subpatches }
    @Published private(set) var favorites: [LibraryFavorite] = []
    @Published private(set) var subpatches: [LibrarySubpatch] = []
    @Published private(set) var diagnostics: [String] = []
    private let queue = DispatchQueue(label:"Patch.Library.Read",qos:.utility)
    private var timer: Timer?
    private var refreshing = false
    private var repeatRefresh = false
    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.refresh() }
    }
    func setFavorite(_ favorite: LibraryFavorite,pinned: Bool) throws {
        favorites = try LibraryFiles.setFavorite(favorite,pinned:pinned)
        refresh()
    }
    func refresh() {
        guard !refreshing else { repeatRefresh = true; return }
        refreshing = true
        queue.async {
            let pins = Result { try LibraryFiles.readFavorites() }, catalog = Result { try LibraryFiles.catalog() }
            DispatchQueue.main.async {
                var diagnostics: [String] = []
                switch pins {
                case .success(let values): if self.favorites != values && !self.repeatRefresh { self.favorites = values }
                case .failure(let error): diagnostics.append(error.localizedDescription)
                }
                switch catalog {
                case .success(let result):
                    diagnostics += result.diagnostics
                    if self.subpatches != result.entries { self.subpatches = result.entries }
                case .failure(let error): diagnostics.append(error.localizedDescription)
                }
                if self.diagnostics != diagnostics { self.diagnostics = diagnostics }
                self.refreshing = false
                if self.repeatRefresh { self.repeatRefresh = false; self.refresh() }
            }
        }
    }

    static func template(_ id: String) throws -> SubpatchTemplate { try LibraryFiles.template(id) }
    static func save(_ template: SubpatchTemplate,id: String,replace: Bool) throws {
        let parts = id.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && !$0.hasPrefix(".") && !$0.contains("\0") }),
              id.hasSuffix(".subpatch.json") else { throw GraphError("Expected a relative .subpatch.json library ID") }
        let manager = FileManager.default, root = subpatchDirectory
        try manager.createDirectory(at:root,withIntermediateDirectories:true)
        var folder = root
        for part in parts.dropLast() {
            folder = folder.appendingPathComponent(String(part),isDirectory:true)
            if manager.fileExists(atPath:folder.path) {
                guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]).isDirectory == true,
                      try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw GraphError("Expected a library directory") }
            } else { try manager.createDirectory(at:folder,withIntermediateDirectories:false) }
        }
        let url = root.appendingPathComponent(id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(template)
        if replace { try data.write(to:url,options:.atomic) }
        else {
            let staged = folder.appendingPathComponent(".save-" + UUID().uuidString)
            defer { try? manager.removeItem(at:staged) }
            try data.write(to:staged,options:.withoutOverwriting)
            try manager.linkItem(at:staged,to:url)
        }
        shared.refresh()
    }
    static func route(_ method: String,path: String,body: Data) throws -> [String:Any]? { try LibraryFiles.route(method,path:path,body:body) }
}

@_cdecl("PatchLibraryRequestJSON")
public func patchLibraryRequestJSON(_ method: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?, _ body: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    var status = 200, response: [String:Any]
    do {
        guard let method,let path else { throw GraphError("Missing method or path") }
        let data = Data((body.map { String(cString:$0) } ?? "{}").utf8)
        if let value = try LibraryFiles.route(String(cString:method),path:String(cString:path),body:data) { response = value }
        else { status = 404; response = ["error":"Unknown library route"] }
    } catch { status = 400; response = ["error":error.localizedDescription] }
    guard let data = try? JSONSerialization.data(withJSONObject:["status":status,"body":response]), let string = String(data:data,encoding:.utf8) else { return nil }
    return strdup(string)
}

@_cdecl("PatchLibraryFreeJSON")
public func patchLibraryFreeJSON(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }

extension Graph {
    func templateForPublishedOutput(_ source: String) throws -> (template: SubpatchTemplate, outputID: UUID, inputSource: String?) {
        guard let port = publishablePorts.first(where:{ $0.id == source }) else { throw GraphError("Unknown published output") }
        for group in groups {
            if let boundary = group.interface?.ports.first(where:{ $0.output && $0.node == port.nodeID && $0.key == port.portID }) {
                var inputSource: String?
                if let input = group.interface?.processingInput {
                    let inlet = try resolveSubpatchPort(group,id:input,output:false)
                    if let edge = edges.first(where:{ $0.target == inlet.node && $0.input == inlet.index }) {
                        guard let outlet = publishablePorts.first(where:{ $0.nodeID == edge.source && $0.portID == edge.outputID && $0.type == .video }) else {
                            throw GraphError("The processor input has no published video source to copy")
                        }
                        inputSource = outlet.id
                    }
                }
                return (try subpatchTemplate(group.id),boundary.id,inputSource)
            }
        }
        throw GraphError("This output does not belong to an exposed subpatch port")
    }

    mutating func restoreIncomingBindings(from original: UUID,to instance: UUID) throws {
        guard let source = component(original),let originalInterface = source.interface,
              let copy = component(instance),let copyInterface = copy.interface else { throw GraphError("Unknown subpatch instance") }
        let members = Set(source.members)
        for port in originalInterface.ports where !port.output && port.id != originalInterface.processingInput {
            let prior = try resolveSubpatchPort(source,id:port.id,output:false)
            guard let edge = edges.first(where:{ $0.target == prior.node && $0.input == prior.index && !members.contains($0.source) }) else { continue }
            let next = try resolveSubpatchPort(copy,id:port.id,output:false)
            try connect(edge.source,to:next.node,input:next.index,output:edge.outputIndex)
        }
        for parameter in originalInterface.parameters {
            guard let binding = node(parameter.node)?.modulations?[parameter.key],!members.contains(binding.source),
                  let target = copyInterface.parameters.first(where:{ $0.id == parameter.id }),
                  let i = nodes.firstIndex(where:{ $0.id == target.node }) else { continue }
            var modulations = nodes[i].modulations ?? [:]
            modulations[target.key] = binding
            nodes[i].modulations = modulations
        }
    }

    /// The host retains this native port only while a show references it.
    mutating func libraryOutput(_ instance: UUID, outputID: UUID, inputSource: String? = nil) throws -> [String:Any] {
        guard let group = component(instance),let interface = group.interface,
              let boundary = interface.ports.first(where:{ $0.output && $0.id == outputID }) else {
            throw GraphError("Unknown subpatch output")
        }
        let endpoint = try resolveSubpatchPort(group,id:outputID,output:true)
        guard let published = publishablePorts.first(where:{ $0.nodeID == endpoint.node && $0.portID == boundary.key && $0.type == boundary.type }) else {
            throw GraphError("Unsupported Compose output type")
        }
        if let processingInput = interface.processingInput, let inputSource {
            guard boundary.type == .video,let source = publishablePorts.first(where:{ $0.id == inputSource && $0.type == .video }),
                  let member = node(source.nodeID) else { throw GraphError("Choose a Patch video source and a video output for this processor") }
            let inlet = try resolveSubpatchPort(group,id:processingInput,output:false)
            guard interface.ports.contains(where:{ $0.id == processingInput && !$0.output && $0.type == .video }),
                  !edges.contains(where:{ $0.target == inlet.node && $0.input == inlet.index }) else { throw GraphError("The processing input must be an unconnected video port") }
            if let outlet = member.ports(output:true).first(where:{ $0.id == source.portID && $0.type == .video }) {
                try connect(member.id,to:inlet.node,input:inlet.index,output:outlet.index)
            } else if member.kind.isOutput,let upstream = edges.first(where:{ $0.target == member.id && $0.input == 0 }),
                      node(upstream.source)?.kind.outputType(at:upstream.outputIndex) == .video {
                try connect(upstream.source,to:inlet.node,input:inlet.index,output:upstream.outputIndex)
            } else { throw GraphError("The selected output has no wireable video source") }
        } else if inputSource != nil { throw GraphError("This subpatch has no declared processing input") }
        let adjustment = interface.processingInput != nil && inputSource == nil
        if adjustment { _ = try adjustmentChain(source:published.id) }
        let name = group.name + " · " + boundary.name
        try publish(endpoint.node,portID:boundary.key,mode:"off",name:name)
        let controls = try interface.parameters.map { parameter -> [String:Any] in
            guard let member = node(parameter.node),let spec = member.parameterDefinitions.first(where:{ $0.key == parameter.key }) else { throw GraphError("Unknown subpatch parameter") }
            var info: [String:Any] = ["id":parameter.id.uuidString,"node":member.id.uuidString,"key":parameter.key,"name":parameter.name,
                                      "value":member.value(parameter.key),"min":spec.min,"max":spec.max,"valueKind":spec.valueKind.rawValue]
            info["step"] = spec.step
            info["choices"] = spec.choices
            info["unit"] = spec.unit
            return info
        }
        return ["id":instance.uuidString,"source":published.id,"name":name,"type":adjustment ? "adjustment" : published.type.rawValue,"controls":controls]
    }
}
