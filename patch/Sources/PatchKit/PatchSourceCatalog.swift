import Foundation
import Combine
import PatchCore
import OutputBridge

struct PatchSourceEntry: Identifiable, Equatable {
    enum Binding: Equatable {
        case camera(String), ndi(String), syphon(String), local(UUID), unavailable
    }

    let id: String
    let name: String
    let group: String
    let type: String
    let binding: Binding
    var location: String? = nil
    var available = true
    var isOutput: Bool { id.hasPrefix("patch:") }
    var favorite: LibraryFavorite { LibraryFavorite(kind:isOutput ? "patchOutput" : "source",id:id,name:name) }
    var action: String? {
        switch binding {
        case .local: return "select"
        case .unavailable: return nil
        default: return "source_add"
        }
    }
    var descriptor: [String:Any] {
        var result: [String:Any] = ["id":id,"name":name,"group":group,"type":type,"available":available]
        result["location"] = location
        result["action"] = action
        if case .local(let nodeID) = binding { result["nodeID"] = nodeID.uuidString }
        return result
    }

    static func saved(_ pin: LibraryFavorite) -> Self? {
        guard pin.kind == "source", let split = pin.id.firstIndex(of:":") else { return nil }
        let key = String(pin.id[pin.id.index(after:split)...])
        guard !key.isEmpty else { return nil }
        switch pin.id[..<split] {
        case "ndi": return Self(id:pin.id,name:pin.name,group:"NDI",type:"video",binding:.ndi(key),available:false)
        case "usb_webcam": return Self(id:pin.id,name:pin.name,group:"Cameras",type:"video",binding:.camera(key),available:false)
        case "syphon":
            guard let info = try? JSONDecoder().decode([String:String].self,from:Data(key.utf8)), info["app"] != nil, info["name"] != nil else { return nil }
            return Self(id:pin.id,name:pin.name,group:"Syphon",type:"video",binding:.syphon(key),available:false)
        default: return nil
        }
    }

    func insert(in graph: inout Graph, at position: Position, id: UUID = UUID()) throws -> UUID {
        guard graph.node(id) == nil, graph.component(id) == nil else { throw GraphError("Duplicate node ID") }
        var node: Node
        switch binding {
        case .camera(let key): node = Node(kind:.webcam,position:position,id:id); node.deviceID = key
        case .ndi(let key): node = Node(kind:.ndiIn,position:position,id:id); node.text = key
        case .syphon(let key): node = Node(kind:.syphonIn,position:position,id:id); node.deviceID = key
        case .local: throw GraphError("This output is already in the graph. Select its node.")
        case .unavailable: throw GraphError("No video receiver is available for this output")
        }
        node.name = graph.availableName(name)
        graph.nodes.append(node)
        return node.id
    }
}

// Refuse redirects on loopback discovery requests carrying the local API token.
private final class PatchPeerDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class PatchSourceCatalog: ObservableObject {
    static let shared = PatchSourceCatalog()
    @Published private(set) var external: [PatchSourceEntry] = []
    @Published private(set) var peer: [PatchSourceEntry] = []
    private var scanning = false
    private var timer: Timer?
    private var peerRequest: URLRequest?
    private var peerName = ""
    private var fetching = false
    private let session = URLSession(configuration:.ephemeral,delegate:PatchPeerDelegate(),delegateQueue:nil)

    func start(embedded: Bool, token: String?, ownPort: UInt16) {
        if let token {
            peerName = embedded ? "Standalone Patch" : "VJ Patch"
            let variable = embedded ? "PATCH_API_PORT" : "VJ_PATCH_API_PORT"
            let port = ProcessInfo.processInfo.environment[variable].flatMap(UInt16.init) ?? (embedded ? 9417 : 9418)
            if ownPort != port, let url = URL(string:"http://127.0.0.1:\(port)/v1/outputs") {
                var request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:1.5)
                request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
                peerRequest = request
            }
        }
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval:3,repeats:true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer,forMode:.common)
        self.timer = timer
    }

    func refresh() {
        refreshPeer()
        guard !scanning else { return }
        scanning = true
        let servers = PatchSyphonInput.sources
        DispatchQueue.global(qos:.utility).async {
            var sources = CameraSource.devices.map {
                PatchSourceEntry(id:"usb_webcam:"+$0.uniqueID,name:$0.localizedName,group:"Cameras",type:"video",binding:.camera($0.uniqueID))
            } + PatchNDIReceiver.sources.map {
                PatchSourceEntry(id:"ndi:"+$0,name:$0,group:"NDI",type:"video",binding:.ndi($0))
            }
            let grouped = Dictionary(grouping:servers) { [$0["app"] ?? "",$0["name"] ?? ""] }
            for (parts,group) in grouped {
                for server in group {
                    let app = parts[0], name = parts[1], uuid = server["uuid"] ?? ""
                    guard !app.isEmpty || !name.isEmpty || !uuid.isEmpty else { continue }
                    var identity = ["app":app,"name":name]
                    if group.count > 1 || (app.isEmpty && name.isEmpty) { identity["uuid"] = uuid }
                    guard let bytes = try? JSONSerialization.data(withJSONObject:identity,options:[.sortedKeys,.withoutEscapingSlashes]), let key = String(data:bytes,encoding:.utf8) else { continue }
                    let label = [app,name].filter { !$0.isEmpty }.joined(separator:" · ")
                    let title = (label.isEmpty ? "Syphon" : label) + (group.count > 1 ? " · "+String(uuid.prefix(8)) : "")
                    sources.append(PatchSourceEntry(id:"syphon:"+key,name:title,group:"Syphon",type:"video",binding:.syphon(SyphonInputSource.key(app:app,name:name,uuid:uuid))))
                }
            }
            let ordered = Self.ordered(sources)
            DispatchQueue.main.async {
                if self.external != ordered { self.external = ordered }
                self.scanning = false
            }
        }
    }

    private func refreshPeer() {
        guard let request = peerRequest, !fetching else { return }
        fetching = true
        let location = peerName
        session.dataTask(with:request) { data,response,_ in
            var sources: [PatchSourceEntry] = []
            if (response as? HTTPURLResponse)?.statusCode == 200, let data,
               let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                for item in object["sources"] as? [[String:Any]] ?? [] {
                    guard item["listed"] as? Bool == true, let id = item["id"] as? String,
                          let name = item["name"] as? String, let type = item["type"] as? String else { continue }
                    var binding = PatchSourceEntry.Binding.unavailable
                    if type == "video", let selection = item["selection"] as? String,
                       let info = try? JSONDecoder().decode([String:String].self,from:Data(selection.utf8)),
                       let app = info["app"], let name = info["name"] {
                        binding = .syphon(SyphonInputSource.key(app:app,name:name,uuid:info["uuid"] ?? ""))
                    }
                    sources.append(PatchSourceEntry(id:id,name:name,group:"Patch Outputs",type:type,binding:binding,location:location,available:item["available"] as? Bool ?? false))
                }
            }
            let ordered = Self.ordered(sources)
            DispatchQueue.main.async {
                if self.peer != ordered { self.peer = ordered }
                self.fetching = false
            }
        }.resume()
    }

    static func ordered(_ entries: [PatchSourceEntry]) -> [PatchSourceEntry] {
        var seen = Set<String>()
        return entries.sorted { a,b in a.name == b.name ? a.id < b.id : a.name.localizedStandardCompare(b.name) == .orderedAscending }.filter { seen.insert($0.id).inserted }
    }

    func entries(in graph: Graph) -> [PatchSourceEntry] {
        let local = graph.publishablePorts.filter(\.listed).map {
            PatchSourceEntry(id:$0.id,name:$0.name,group:"Patch Outputs",type:$0.type.rawValue,binding:.local($0.nodeID),location:"This graph")
        }
        let localIDs = Set(local.map(\.id))
        return Self.ordered(local + peer.filter { !localIDs.contains($0.id) } + external)
    }
    func resolve(_ id: String, in graph: Graph) throws -> PatchSourceEntry {
        if let source = entries(in:graph).first(where:{ $0.id == id }) { return source }
        if let pin = PatchLibrary.shared.favorites.first(where:{ $0.kind == "source" && $0.id == id }), let source = PatchSourceEntry.saved(pin) { return source }
        throw GraphError("Source is unavailable")
    }
}

extension Workspace {
    @discardableResult func insertLibrarySource(_ id: String, at position: Position) throws -> UUID {
        let source = try PatchSourceCatalog.shared.resolve(id,in:graph)
        if case .local(let nodeID) = source.binding { selected = nodeID; return nodeID }
        var next = graph
        let nodeID = try source.insert(in:&next,at:position)
        try apply(next,action:"Add "+source.name)
        selected = nodeID
        return nodeID
    }
}
