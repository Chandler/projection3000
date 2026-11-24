import SwiftUI
import PatchCore

struct NodeBrowser: View {
    @State private var query = ""
    private static let categories = ["USER GENERATED","CONTROL","SOURCE","GEOMETRY","RENDER","AUDIO","ANALYSIS","EFFECT","COLLECTION","TRACE","OUTPUT"]
    @State private var collapsed = Set(Self.categories)
    @ObservedObject private var library = UserNodeLibrary.shared
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Text("NODES").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary).padding(.horizontal,14).padding(.top,18)
            TextField("Filter nodes",text:$query).textFieldStyle(.squareBorder).controlSize(.small).padding(12)
            ScrollView {
                VStack(alignment:.leading,spacing:6) {
                    ForEach(Self.categories,id:\.self) { category in
                        let nodes = CatalogNode.all.filter { $0.category == category && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
                        if !nodes.isEmpty || (category == "USER GENERATED" && library.root.matches(query)) {
                            VStack(alignment:.leading,spacing:4) {
                                Button { workspace.dismissLibraryPreview(); if collapsed.contains(category) { collapsed.remove(category) } else { collapsed.insert(category) } } label: {
                                    HStack(spacing:6) { Image(systemName:collapsed.contains(category) && query.isEmpty ? "chevron.right" : "chevron.down").frame(width:8); Image(systemName:"folder"); Text(category); Spacer() }
                                        .font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(.secondary).padding(.horizontal,12).padding(.vertical,7).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("\(category) folder")
                                    .contextMenu {
                                        if category == "USER GENERATED" {
                                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([UserNodeLibrary.directory]) }
                                        }
                                    }
                                if !collapsed.contains(category) || !query.isEmpty {
                                    if category == "USER GENERATED" {
                                        UserNodeFolderContents(folder:library.root,query:query,workspace:workspace)
                                    } else {
                                        ForEach(nodes) { NodeBrowserRow(node:$0,workspace:workspace) }
                                    }
                                }
                            }
                        }
                    }
                }.padding(.top,8).padding(.bottom,18)
            }
            Button("Open User Folder…") { library.reveal() }.buttonStyle(.plain).font(.system(size:10)).padding(.horizontal,14).padding(.vertical,8)
            Spacer(minLength:0)
            Text("Click to preview · Drag to add\n⌘F Add · Space Preview\n⌘-click: select · ⌘-drag: box select\nHold ⇧: cut or connect").font(.system(size:9,design:.monospaced)).foregroundStyle(.tertiary).padding(14)
        }.background(Color(nsColor:.patchPanel).opacity(0.65)).preferredColorScheme(.dark)
    }
}

private struct NodeBrowserRow: View {
    let node: CatalogNode
    @ObservedObject var workspace: Workspace
    var body: some View {
        Button { workspace.browse(node) } label: {
            HStack(spacing:8) {
                Rectangle().fill(Color(nsColor:.node(node.kind))).frame(width:3,height:12)
                Text(node.title).font(.system(size:11)).lineLimit(1)
                Spacer(minLength:0)
            }.padding(.horizontal,14).padding(.vertical,7).background(workspace.libraryCatalogID == node.id ? Color(nsColor:.patchAccent).opacity(0.12) : .clear).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Preview \(node.title); drag to add to the graph")
            .onDrag { NSItemProvider(object:(node.file.map { "patch-user:"+$0.path } ?? "patch-node:\(node.kind.rawValue)") as NSString) }
            .contextMenu {
                if let file = node.file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }
    }
}

private struct UserNodeFolderContents: View {
    let folder: UserNodeFolder
    let query: String
    let workspace: Workspace
    var body: some View {
        ForEach(folder.folders.filter { $0.matches(query) }) { child in
            UserNodeFolderRow(folder:child,query:query,workspace:workspace)
        }
        ForEach(folder.nodes.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { node in
            NodeBrowserRow(node:node,workspace:workspace)
        }
    }
}

private struct UserNodeFolderRow: View {
    let folder: UserNodeFolder
    let query: String
    let workspace: Workspace
    @State private var expanded = false
    var body: some View {
        let folderQuery = !query.isEmpty && folder.url.lastPathComponent.localizedCaseInsensitiveContains(query) ? "" : query
        VStack(alignment:.leading,spacing:4) {
            Button { workspace.dismissLibraryPreview(); expanded.toggle() } label: {
                HStack(spacing:6) {
                    Image(systemName:expanded || !query.isEmpty ? "chevron.down" : "chevron.right").frame(width:8)
                    Image(systemName:"folder")
                    Text(folder.url.lastPathComponent).lineLimit(1)
                    Spacer(minLength:0)
                }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,12).padding(.vertical,7).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(folder.url.lastPathComponent) folder")
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                }
            if expanded || !query.isEmpty {
                UserNodeFolderContents(folder:folder,query:folderQuery,workspace:workspace).padding(.leading,12)
            }
        }.padding(.leading,12)
    }
}
