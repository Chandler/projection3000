import AppKit
import Combine
import Darwin
import PatchCore

/// A small C boundary keeps JUCE and VST3 SDK types outside the Swift graph.
private final class PluginHostLibrary {
    typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Command = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    typealias Free = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias ErrorText = @convention(c) () -> UnsafePointer<CChar>?
    typealias Dirty = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias Process = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<Float>, UnsafeMutablePointer<Float>, Int32, Double, UnsafePointer<Int32>?, UnsafePointer<Float>?, Int32) -> Int32
    let handle: UnsafeMutableRawPointer
    let create: Create; let destroy: Destroy; let command: Command; let free: Free
    let errorText: ErrorText; let dirty: Dirty; let process: Process
    init() throws {
        let url=Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libPatchAudioPluginHost.dylib")
        guard let handle=dlopen(url.path,RTLD_NOW | RTLD_LOCAL) else { throw GraphError("VST3 host unavailable. Build with scripts/build-app.sh. \(dlerror().map { String(cString:$0) } ?? "")") }
        self.handle=handle
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let p=dlsym(handle,name) else { throw GraphError("Missing plugin host function: \(name)") }
            return unsafeBitCast(p,to:T.self)
        }
        create=try symbol("pp_create",Create.self); destroy=try symbol("pp_destroy",Destroy.self)
        command=try symbol("pp_command",Command.self); free=try symbol("pp_free",Free.self)
        errorText=try symbol("pp_error",ErrorText.self); dirty=try symbol("pp_dirty",Dirty.self); process=try symbol("pp_process",Process.self)
        // Keep the library loaded for process lifetime: JUCE owns message-thread singletons.
    }
}
final class HostedAudioPlugin: @unchecked Sendable {
    private let library: PluginHostLibrary
    private let handle: UnsafeMutableRawPointer
    let path: String
    var configuration: AudioPluginConfiguration?
    var appliedParameters: [String:Double]=[:]
    var appliedState: String?
    private var activeModulations=Set<String>()
    var texts: [String:String]=[:]
    var latency=0
    fileprivate init(path: String, configuration: AudioPluginConfiguration?, library: PluginHostLibrary) throws {
        self.path=path; self.library=library
        guard let handle=library.create(path,configuration?.identifier ?? "") else { throw GraphError(library.errorText().map { String(cString:$0) } ?? "Could not open VST3") }
        self.handle=handle
        if let state=configuration?.state,!state.isEmpty { _ = try command(["op":"restore","state":state]); appliedState=state }
    }
    deinit {
        let library=library,handle=handle
        if Thread.isMainThread { library.destroy(handle) }
        else { DispatchQueue.main.async { library.destroy(handle) } }
    }
    fileprivate func command(_ request: [String:Any]) throws -> [String:Any] {
        let data=try JSONSerialization.data(withJSONObject:request)
        guard let pointer=library.command(handle,String(decoding:data,as:UTF8.self)) else { throw GraphError("Plugin host returned no response") }
        defer { library.free(UnsafeMutableRawPointer(pointer)) }
        let result=(try JSONSerialization.jsonObject(with:Data(String(cString:pointer).utf8))) as? [String:Any] ?? [:]
        if let error=result["error"] as? String { throw GraphError(error) }
        return result
    }
    var changed: Bool { library.dirty(handle) != 0 }
    func value(forText text: String, parameter: AudioPluginParameter) throws -> Double {
        let result=try command(["op":"parse","index":parameter.index,"text":text])
        guard let value=result["value"] as? Double,value.isFinite else { throw GraphError("Cannot parse parameter value") }
        return min(1,max(0,value))*(parameter.steps>1 ? Double(parameter.steps-1):1)
    }
    func openEditor() throws { _ = try command(["op":"editor"]) }
    func apply(_ node: Node) throws {
        let nextModulations=Set((node.modulations ?? [:]).filter { $0.value.enabled }.keys)
        for key in activeModulations.subtracting(nextModulations) { appliedParameters[key]=nil }
        activeModulations=nextModulations
        if let saved=node.plugin?.state,saved != appliedState {
            _ = try command(["op":"restore","state":saved]); appliedState=saved; appliedParameters=[:]
        }
        let values=(node.plugin?.parameters ?? []).compactMap { p -> [String:Any]? in
            let value=node.value(p.key)
            guard appliedParameters[p.key] != value else { return nil }
            return ["index":p.index,"value":p.normalized(value)]
        }
        if !values.isEmpty { _ = try command(["op":"set","values":values]) }
        appliedParameters=node.parameters
    }
    func snapshot() throws -> (AudioPluginConfiguration,[String:Double]) {
        let result=try command(["op":"snapshot"])
        let raw=result["parameters"] as? [[String:Any]] ?? []
        let definitions=try JSONDecoder().decode([AudioPluginParameter].self,from:JSONSerialization.data(withJSONObject:raw))
        let configuration=AudioPluginConfiguration(identifier:result["identifier"] as? String ?? "",name:result["name"] as? String ?? "VST3 Effect",manufacturer:result["manufacturer"] as? String ?? "",state:result["state"] as? String ?? "",parameters:definitions)
        var values: [String:Double]=[:]
        for (p,item) in zip(definitions,raw) {
            let value=(item["value"] as? Double ?? p.initial)*(p.steps>1 ? Double(p.steps-1):1)
            values[p.key]=p.steps>1 ? value.rounded():value
            texts[p.key]=[item["text"] as? String ?? "",p.unit].filter { !$0.isEmpty }.joined(separator:" ")
        }
        latency=result["latency"] as? Int ?? 0
        self.configuration=configuration; appliedState=configuration.state; appliedParameters=values
        return (configuration,values)
    }
    /// Called exclusively on Patch's serial audio queue. Only modulation overrides are sent here.
    func process(_ samples: [Float], rate: Double, node: Node) -> ([Float],String) {
        guard samples.count>0,samples.count%2==0 else { return (samples,"Invalid audio block") }
        let modulated=(node.plugin?.parameters ?? []).filter { node.modulations?[$0.key]?.enabled == true }
        let indices=modulated.map { Int32($0.index) },values=modulated.map { Float($0.normalized(node.value($0.key))) }
        var output=samples
        let code=samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                indices.withUnsafeBufferPointer { ids in values.withUnsafeBufferPointer { vals in
                    library.process(handle,input.baseAddress!,out.baseAddress!,Int32(samples.count/2),rate,ids.baseAddress,vals.baseAddress,Int32(ids.count))
                } }
            }
        }
        return (code == 0 ? output:samples,code == 0 ? "VST3 · \(Int(rate)) Hz · stereo":code == 1 ? "VST3 · updating settings (dry)":code == 2 ? "VST3 · preparing sample rate (dry)":"VST3 processing failed · bypassed")
    }
}

final class AudioPlugins: ObservableObject {
    private var suspended = false
    func setSuspended(_ value: Bool) {
        if value { synchronize() }
        suspended=value
        timer?.invalidate(); timer=nil
        if value { lock.withLock { instances.removeAll() } }
        else if let workspace { bind(workspace); synchronize() }
    }
    @Published private(set) var errors: [UUID:String]=[:]
    @Published private(set) var revision=0
    private var library: PluginHostLibrary?
    private var instances: [UUID:HostedAudioPlugin]=[:]
    private let lock=NSLock()
    private weak var workspace: Workspace?
    private var timer: Timer?
    private var failedPaths: [UUID:String]=[:]
    private var synchronizing=false
    func bind(_ workspace: Workspace) {
        self.workspace=workspace
        timer?.invalidate()
        let timer=Timer(timeInterval:0.2,repeats:true) { [weak self] _ in self?.synchronize() }
        RunLoop.main.add(timer,forMode:.common); self.timer=timer
        workspace.beforeSave = { [weak self] in self?.synchronize() }
    }
    func instance(_ id: UUID) -> HostedAudioPlugin? { lock.withLock { instances[id] } }
    func synchronize() {
        guard !suspended,!synchronizing,let workspace else { return }
        synchronizing=true
        defer { synchronizing=false }
        let nodes=workspace.graph.nodes.filter { $0.kind == .audioPlugin }
        let ids=Set(nodes.map(\.id))
        let removed=lock.withLock { () -> [HostedAudioPlugin] in
            let removed=instances.filter { !ids.contains($0.key) }.map(\.value)
            instances=instances.filter { ids.contains($0.key) }; return removed
        }
        withExtendedLifetime(removed) {}
        var graph=workspace.graph
        for node in nodes {
            guard let path=node.file else { lock.withLock { instances[node.id]=nil }; errors[node.id]=nil; continue }
            do {
                var host=instance(node.id)
                if host?.path != path || (node.plugin != nil && host?.configuration?.identifier != node.plugin?.identifier) {
                    if failedPaths[node.id] == path { continue }
                    lock.withLock { instances[node.id]=nil }
                    if library == nil { library=try PluginHostLibrary() }
                    host=try HostedAudioPlugin(path:path,configuration:node.plugin,library:library!)
                    lock.withLock { instances[node.id]=host }
                }
                guard let host else { continue }
                try host.apply(node)
                if host.changed || node.plugin == nil {
                    let (configuration,values)=try host.snapshot()
                    if let index=graph.nodes.firstIndex(where:{ $0.id == node.id }) {
                        graph.nodes[index].plugin=configuration
                        graph.nodes[index].parameters=values
                        for (key,binding) in node.modulations ?? [:] where binding.enabled { graph.nodes[index].parameters[key]=node.value(key) }
                        if node.name == NodeKind.audioPlugin.title { graph.nodes[index].name=configuration.name }
                    }
                    revision += 1
                }
                if errors[node.id] != nil { errors[node.id]=nil }
            } catch { failedPaths[node.id]=path; errors[node.id]=error.localizedDescription }
        }
        if graph != workspace.graph { try? workspace.apply(graph,action:"Plugin Settings",registerUndo:false) }
    }
    func choose(_ id: UUID, path: String) {
        guard let workspace else { return }
        failedPaths[id]=nil
        workspace.update(id,action:"Choose VST3") { $0.file=path; $0.plugin=nil; $0.parameters=[:];$0.modulations=nil }
        synchronize()
    }
    func setText(_ id: UUID, parameter: AudioPluginParameter, text: String) {
        do {
            guard let host=instance(id) else { return }
            let value=try host.value(forText:text,parameter:parameter)
            workspace?.parameter(id,parameter.key,value); synchronize()
        } catch { errors[id]=error.localizedDescription }
    }
    func retry(_ id: UUID) { failedPaths[id]=nil; lock.withLock { instances[id]=nil }; synchronize() }
    func openEditor(_ id: UUID) {
        synchronize()
        do {
            guard let host=instance(id) else { throw GraphError(errors[id] ?? "Choose a VST3 plugin first") }
            try host.openEditor()
        } catch { errors[id]=error.localizedDescription }
    }
    var state: [String:Any] {
        var result: [String:Any]=[:]
        if let workspace { for node in workspace.graph.nodes where node.kind == .audioPlugin {
            let host=instance(node.id)
            result[node.id.uuidString]=["loaded":host != nil,"error":errors[node.id] as Any? ?? NSNull(),"latencySamples":host?.latency ?? 0,"parameterText":host?.texts ?? [:]]
        } }
        return result
    }
    static var installed: [URL] {
        let roots=[URL(fileURLWithPath:"/Library/Audio/Plug-Ins/VST3"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3")]
        var result: [URL]=[]
        for root in roots {
            guard let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased()=="vst3" { result.append(url) }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
