import Foundation
import Combine
import AppKit
import PatchCore

struct CatalogNode: Identifiable, Equatable {
    var kind: NodeKind
    var file: URL?
    var name: String?
    var controlStyle: String?
    var parameterTitles: [String:String] = [:]
    var fieldParameters: [ParameterSpec]?
    var parameterSpecs: [ParameterSpec] {
        (fieldParameters ?? (kind == .fieldShader ? [] : kind == .scene && controlStyle == "metallicPool" ? MetallicPoolStyle.parameters : kind == .shaderEffect && controlStyle == "liquidMetal" ? LiquidMetalStyle.parameters : kind == .shaderEffect && controlStyle == "liquidChrome" ? LiquidChromeStyle.parameters : kind == .shaderEffect && controlStyle == "ferrofluid" ? FerrofluidStyle.parameters : kind == .shaderEffect && controlStyle == "blinds" ? BlindsStyle.parameters : kind.parameters)).map { spec in
            spec.withTitle(parameterTitles[spec.key] ?? spec.title)
        }
    }
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator:\.isWhitespace)
        return words.allSatisfy { word in
            if word.hasPrefix("in:") || word.hasPrefix("out:") {
                let output = word.hasPrefix("out:")
                let value = String(word.dropFirst(output ? 4 : 3))
                let requested = PortType.allCases.first { $0.rawValue.lowercased() == value }
                return kind.ports(output:output).contains { port in
                    if let requested { return output ? port.type == requested : port.type.accepts(requested) }
                    return value.isEmpty || port.type.rawValue.lowercased().contains(value) || port.name.localizedCaseInsensitiveContains(value)
                }
            }
            return title.localizedCaseInsensitiveContains(String(word)) || category.localizedCaseInsensitiveContains(String(word))
        }
    }
    var id: String { file?.path ?? kind.rawValue }
    var title: String { name ?? kind.title }
    var category: String { file == nil ? kind.category : "USER GENERATED" }
    static var all: [CatalogNode] { NodeKind.allCases.filter { $0 != .fieldShader && $0 != .posterText && $0 != .meshGradient && $0 != .dotColors && $0 != .flipDots && $0 != .projectionDots && $0 != .scene && $0 != .dataStream && $0 != .blockerField && $0 != .streakField && $0 != .waterfallField && $0 != .cellularField }.map { CatalogNode(kind:$0) } + UserNodeLibrary.shared.entries }
}
struct UserNodeFolder: Identifiable, Equatable {
    var url: URL
    var nodes: [CatalogNode] = []
    var folders: [UserNodeFolder] = []
    var id: String { url.path }
    var entries: [CatalogNode] { nodes + folders.flatMap(\.entries) }
    func matches(_ query: String) -> Bool {
        query.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(query) || nodes.contains { $0.matches(query) } || folders.contains { $0.matches(query) }
    }
}
final class UserNodeLibrary: ObservableObject {
    static let shared = UserNodeLibrary()
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Patch/User Nodes",isDirectory:true) }
    static var bundledDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("User Nodes",isDirectory:true) }
    private static func sourceURL(_ name: String) -> URL {
        let external = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath:external.path) { return external }
        if let bundled = bundledDirectory?.appendingPathComponent(name), FileManager.default.fileExists(atPath:bundled.path) { return bundled }
        return external
    }
    static var meshGradientURL: URL { sourceURL("Mesh Gradient.metal") }
    static var dotColorsURL: URL { sourceURL("Dot Colors.metal") }
    static var flipDotsURL: URL { sourceURL("Flip Dots.metal") }
    static var projectionDotsURL: URL { sourceURL("Projection Dots.metal") }
    static var pastelURL: URL { sourceURL("Pastel Scene.metal") }
    static var dataStreamURL: URL { sourceURL("Data Stream.metal") }
    static var cellularFieldURL: URL { sourceURL("Cellular Automata.metal") }
    static var waterfallFieldURL: URL { sourceURL("Waterfall Ribbon.metal") }
    static var streakFieldURL: URL { sourceURL("Moving Streaks.metal") }
    static var blockerFieldURL: URL { sourceURL("Flow Blockers.metal") }
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var entries: [CatalogNode] = []
    @Published private(set) var root = UserNodeFolder(url:UserNodeLibrary.directory)
    private var timer: Timer?
    private var scanning = false
    private var rescanRequested = false
    private var refreshCallbacks: [() -> Void] = []
    private struct Metadata: Decodable {
        let name: String
        let file: String
        let kind: NodeKind?
        let parameterTitles: [String:String]?
        let controlStyle: String?
        let parameters: [ParameterSpec]?
        var fieldParameters: [ParameterSpec]? {
            guard kind == .fieldShader || kind == .shaderEffect && parameters != nil else { return nil }
            return (parameters ?? []).map { $0.withTitle(parameterTitles?[$0.key] ?? $0.title) }
        }
    }
    private static let fileKinds: Set<NodeKind> = [
        .profileEncoder, .rasterSynth, .meshGradient, .dotColors, .flipDots, .projectionDots,
        .shader, .shaderEffect, .fieldShader, .scene, .dataStream, .blockerField, .streakField,
        .waterfallField, .cellularField
    ]
    init() {
        try? FileManager.default.createDirectory(at:Self.directory,withIntermediateDirectories:true)
        refresh()
        let timer = Timer(timeInterval:2,repeats:true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer,forMode:.common); self.timer = timer
    }
    func refresh(completion: (() -> Void)? = nil) {
        if let completion { refreshCallbacks.append(completion) }
        guard !scanning else { rescanRequested = true; return }; scanning = true
        DispatchQueue.global(qos:.utility).async {
            var diagnostics: [String] = []
            func scan(_ directory: URL, bundled: URL?) -> UserNodeFolder {
                func contents(_ url: URL?) -> [URL] {
                    guard let url else { return [] }
                    return (try? FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:.skipsHiddenFiles)) ?? []
                }
                // External files override bundled defaults at the same relative path.
                var byName: [String:URL] = [:]
                for url in contents(bundled) + contents(directory) { byName[url.lastPathComponent] = url }
                let files = Array(byName.values)
                var metadata: [String:Metadata] = [:]
                var retired: Set<String> = []
                for url in files where url.pathExtension.lowercased() == "json" {
                    let sibling = url.deletingPathExtension().lastPathComponent+".metal"
                    var referencedFile = byName[sibling] == nil ? nil : sibling
                    do {
                        let data = try Data(contentsOf:url)
                        // Presets and other JSON data can live beside shader manifests.
                        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                              let file = object["file"] as? String else {
                            if referencedFile != nil { throw GraphError("Missing shader file") }
                            continue
                        }
                        referencedFile = file
                        let item = try JSONDecoder().decode(Metadata.self,from:data)
                        if item.kind == .streakGlow { retired.insert(file); continue }
                        if let kind = item.kind, !Self.fileKinds.contains(kind) { throw GraphError("Unsupported shader kind "+kind.rawValue) }
                        if let specs = item.fieldParameters {
                            guard item.controlStyle == nil else { throw GraphError("Choose a built-in control style or declare shader parameters") }
                            try ParameterSpec.validateShaderParameters(specs)
                        }
                        if metadata[file] != nil { throw GraphError("Multiple manifests name "+file) }
                        metadata[file] = item
                    } catch {
                        if let file = referencedFile {
                            retired.insert(file)
                            diagnostics.append(url.lastPathComponent+" · "+error.localizedDescription)
                        }
                    }
                }
                var folder = UserNodeFolder(url:directory)
                for url in files {
                    let values = try? url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                    if values?.isDirectory == true {
                        if values?.isSymbolicLink != true { folder.folders.append(scan(directory.appendingPathComponent(url.lastPathComponent,isDirectory:true),bundled:bundled?.appendingPathComponent(url.lastPathComponent,isDirectory:true))) }
                    } else if url.pathExtension.lowercased() == "metal", !retired.contains(url.lastPathComponent) {
                        let info = metadata[url.lastPathComponent]
                        folder.nodes.append(CatalogNode(kind:info?.kind ?? .shader,file:url,name:info?.name ?? url.deletingPathExtension().lastPathComponent,controlStyle:info?.controlStyle,parameterTitles:info?.parameterTitles ?? [:],fieldParameters:info?.fieldParameters))
                    }
                }
                folder.nodes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                folder.folders.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
                return folder
            }
            let root = scan(Self.directory,bundled:Self.bundledDirectory)
            let entries = root.entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let issues = diagnostics.sorted()
            DispatchQueue.main.async {
                if self.diagnostics != issues { self.diagnostics = issues }
                if self.root != root { self.root = root }
                if self.entries != entries { self.entries = entries }
                self.scanning = false
                if self.rescanRequested { self.rescanRequested = false; self.refresh(); return }
                let callbacks = self.refreshCallbacks; self.refreshCallbacks.removeAll()
                callbacks.forEach { $0() }
            }
        }
    }
    func reveal() { NSWorkspace.shared.open(Self.directory) }
}

// Resolve labels by shader file, so renaming a node preserves its control names.
extension Node {
    var catalogTitle: String {
        guard let file else { return kind.title }
        return UserNodeLibrary.shared.entries.first { $0.kind == kind && $0.file?.path == file }?.title ?? kind.title
    }

    var isBlinds: Bool {
        hasBlindsControls || kind == .shaderEffect && UserNodeLibrary.shared.entries.contains { $0.file?.path == file && $0.controlStyle == "blinds" }
    }
    var parameterSpecs: [ParameterSpec] {
        if kind == .fieldShader || fieldParameters != nil { return parameterDefinitions }
        guard let file, let entry = UserNodeLibrary.shared.entries.first(where:{ $0.file?.path == file && $0.kind == kind }) else { return parameterDefinitions }
        return entry.parameterSpecs
    }
    var modulationSpecs: [ParameterSpec] {
        let keys = Set(modulationDefinitions.map(\.key))
        return parameterSpecs.filter { keys.contains($0.key) }
    }
}

extension Graph {
    func resolvingBlindsControls() -> Graph {
        var result = self
        for index in result.nodes.indices where result.nodes[index].kind == .shaderEffect && result.nodes[index].controlStyle == nil && result.nodes[index].fieldParameters == nil {
            guard let file = result.nodes[index].file else { continue }
            let catalogStyle = UserNodeLibrary.shared.entries.first(where:{ $0.file?.path == file })?.controlStyle
            var style = catalogStyle
            if style == nil {
                let metadata = URL(fileURLWithPath:file).deletingPathExtension().appendingPathExtension("json")
                if let data = try? Data(contentsOf:metadata), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any], object["file"] as? String == URL(fileURLWithPath:file).lastPathComponent {
                    style = object["controlStyle"] as? String
                }
            }
            if style == "blinds" || style == "liquidMetal" || style == "liquidChrome" || style == "ferrofluid" { result.nodes[index].controlStyle = style }
        }
        return result
    }
}
