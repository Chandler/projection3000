import SwiftUI
import PatchCore

struct NodeBrowser: View {
    @State private var query = ""
    @State private var collapsed: Set<String> = []
    @State private var expandedCategories: Set<String> = []
    @ObservedObject private var shaders = UserNodeLibrary.shared
    @ObservedObject private var library = PatchLibrary.shared
    @ObservedObject private var sources = PatchSourceCatalog.shared
    @ObservedObject var workspace: Workspace
    var insertionPoint: () -> Position
    var frameSelection: () -> Void

    private func matches(_ values: String...) -> Bool {
        let text = values.joined(separator:" ")
        return query.split(whereSeparator:\.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }

    var body: some View {
        let catalog = CatalogNode.all
        let discovered = sources.entries(in:workspace.graph)
        let pins = library.favorites.filter { ["patchNode","source","patchOutput","subpatch"].contains($0.kind) }
        let issues = shaders.diagnostics + library.diagnostics
        VStack(alignment:.leading,spacing:0) {
            TextField("Search nodes and sources",text:$query).textFieldStyle(.roundedBorder).controlSize(.regular).padding(10)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:2) {
                    section("Favorites",icon:"star",count:pins.count) {
                        if pins.isEmpty { status("No favorites") }
                        ForEach(pins.indices,id:\.self) { index in
                            let pin = pins[index]
                            if matches(pin.name,pin.kind) {
                                if let node = catalog.first(where:{ $0.favorite.kind == pin.kind && $0.favorite.id == pin.id }) {
                                    nodeRow(node)
                                } else if let item = library.subpatches.first(where:{ $0.favorite.matches(pin) }) {
                                    subpatchRow(item)
                                } else if let source = discovered.first(where:{ $0.favorite.kind == pin.kind && $0.favorite.id == pin.id }) {
                                    sourceRow(source)
                                } else if let source = PatchSourceEntry.saved(pin) {
                                    sourceRow(source)
                                } else {
                                    browserRow(pin,icon:"star",detail:pin.kind == "patchOutput" ? "Offline" : "Unavailable",canActivate:false,activate:{})
                                }
                            }
                        }
                    }
                    section("Sources",icon:"antenna.radiowaves.left.and.right",count:discovered.count) {
                        if discovered.isEmpty { status("No sources found") }
                        ForEach(["Patch Outputs","Syphon","NDI","Cameras"],id:\.self) { group in
                            let results = discovered.filter { $0.group == group && matches($0.name,group,$0.type) }
                            if !results.isEmpty {
                                subgroupLabel(group)
                                ForEach(results) { source in sourceRow(source) }
                            }
                        }
                    }
                    section("Library",icon:"square.stack.3d.up",count:catalog.count+library.subpatches.count) {
                        let showUserNodes = shaders.root.matches(query) || matches("User Nodes")
                        let groups = Dictionary(grouping:catalog.filter { $0.matches(query) || ($0.file != nil && showUserNodes) },by:\.category)
                        let subpatches = library.subpatches.filter { matches($0.name,"Subpatches") }
                        if !subpatches.isEmpty {
                            category("Subpatches") { ForEach(subpatches,id:\.id) { subpatchRow($0) } }
                        }
                        ForEach(groups.keys.sorted(),id:\.self) { group in
                            category(group == "USER GENERATED" ? "User Nodes" : group.capitalized) {
                                if group == "USER GENERATED" {
                                    ForEach((groups[group] ?? []).filter { $0.file == nil }) { nodeRow($0) }
                                    folder(shaders.root,search:matches("User Nodes") ? "" : query)
                                } else {
                                    ForEach(groups[group] ?? []) { nodeRow($0) }
                                }
                            }
                        }
                    }
                }.padding(.bottom,12)
            }
            if !issues.isEmpty {
                DisclosureGroup("Library issues · "+String(issues.count)) {
                    ForEach(issues,id:\.self) { Text($0).font(.editorItem).textSelection(.enabled) }
                }.padding(.horizontal,10)
            }
            Divider()
            HStack {
                Menu("Folders") {
                    Button("User Nodes") { shaders.reveal() }
                    Button("Subpatches") {
                        do {
                            try FileManager.default.createDirectory(at:PatchLibrary.subpatchDirectory,withIntermediateDirectories:true)
                            NSWorkspace.shared.open(PatchLibrary.subpatchDirectory)
                        } catch { workspace.message = error.localizedDescription }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button { sources.refresh(); shaders.refresh(); library.refresh() } label: { Image(systemName:"arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh library and sources").accessibilityLabel("Refresh library and sources")
            }.font(.editorItem).padding(10)
        }.font(.editorBody).background(Color(nsColor:.patchPanel).opacity(0.65)).preferredColorScheme(.dark)
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.editorItem).foregroundStyle(.secondary).padding(.leading,28).padding(.vertical,4)
    }
    private func subgroupLabel(_ title: String) -> some View {
        Text(title).font(.editorItem.weight(.semibold)).foregroundStyle(.secondary).padding(.leading,17).padding(.top,4)
    }
    @ViewBuilder private func section<Content:View>(_ name: String, icon: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        let open = !query.isEmpty || !collapsed.contains(name)
        Button {
            if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        } label: {
            HStack(spacing:7) {
                Image(systemName:open ? "chevron.down" : "chevron.right").font(.editorCaption).frame(width:8)
                Image(systemName:icon)
                Text(name).fontWeight(.semibold)
                Spacer()
                Text(String(count)).font(.editorValue).foregroundStyle(.secondary)
            }.padding(.horizontal,10).padding(.vertical,7).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(open ? "Expanded" : "Collapsed")
        if open { content() }
    }
    @ViewBuilder private func category<Content:View>(_ title: String, key: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        let key = key ?? title, open = !query.isEmpty || expandedCategories.contains(key)
        Button {
            if expandedCategories.contains(key) { expandedCategories.remove(key) } else { expandedCategories.insert(key) }
        } label: {
            HStack(spacing:6) {
                Image(systemName:open ? "chevron.down" : "chevron.right").font(.editorCaption).frame(width:8)
                Image(systemName:"folder")
                Text(title).lineLimit(1)
                Spacer(minLength:0)
            }.padding(.leading,18).padding(.trailing,8).padding(.vertical,5).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityValue(open ? "Expanded" : "Collapsed")
        if open { content() }
    }

    private func folder(_ root: UserNodeFolder, search: String) -> AnyView {
        AnyView(Group {
            ForEach(root.folders.filter { $0.matches(search) }) { child in
                category(child.url.lastPathComponent,key:child.url.path) { folder(child,search:child.url.lastPathComponent.localizedCaseInsensitiveContains(search) ? "" : search).padding(.leading,8) }
            }
            ForEach(root.nodes.filter { $0.matches(search) }) { nodeRow($0) }
        })
    }
    private func placeNode(_ node: CatalogNode) {
        if node.file != nil { workspace.addUserNode(node,at:insertionPoint()) }
        else { _ = workspace.add(node.kind,at:insertionPoint()) }
    }
    private func nodeRow(_ node: CatalogNode) -> some View {
        browserRow(node.favorite,icon:node.file == nil ? "square" : "chevron.left.forwardslash.chevron.right",
                   detail:node.kind.ports(output:true).map { $0.type.rawValue.capitalized }.reduce(into:[String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator:" · "),tint:Color(nsColor:.node(node.kind)),activate:{ workspace.browse(node) },
                   add:{ placeNode(node) },file:node.file)
            .onDrag { NSItemProvider(object:(node.file.map { "patch-user:"+$0.path } ?? "patch-node:"+node.kind.rawValue) as NSString) }
    }
    private func subpatchRow(_ item: LibrarySubpatch) -> some View {
        browserRow(item.favorite,icon:"square.3.layers.3d",detail:"Subpatch",activate:{
            do { _ = try workspace.insertLibrarySubpatch(item.id,at:insertionPoint()) }
            catch { workspace.message = error.localizedDescription }
        },file:item.url)
        .onDrag { NSItemProvider(object:("patch-subpatch:"+item.id) as NSString) }
    }
    @ViewBuilder private func sourceRow(_ source: PatchSourceEntry) -> some View {
        let local = source.action == "select"
        let detail = [source.location ?? "",source.type.capitalized,source.available ? "" : "Offline"].filter { !$0.isEmpty }.joined(separator:" · ")
        let row = browserRow(source.favorite,icon:local ? "scope" : "video",detail:detail,canActivate:source.action != nil,activate:{
            do {
                _ = try workspace.insertLibrarySource(source.id,at:insertionPoint())
                if local { frameSelection() }
            } catch { workspace.message = error.localizedDescription }
        })
        if source.action == "source_add" { row.onDrag { NSItemProvider(object:("patch-source:"+source.id) as NSString) } }
        else { row }
    }
    private func browserRow(_ item: LibraryFavorite, icon: String, detail: String?, tint: Color = .secondary, canActivate: Bool = true,
                            activate: @escaping () -> Void, add: (() -> Void)? = nil, file: URL? = nil) -> some View {
        let pinned = library.favorites.contains { $0.kind == item.kind && $0.id == item.id }
        let toggle = {
            do { try library.setFavorite(item,pinned:!pinned) }
            catch { workspace.message = error.localizedDescription }
        }
        return HStack(spacing:5) {
            Button(action:activate) {
                HStack(spacing:7) {
                    Image(systemName:icon).foregroundStyle(tint).frame(width:14)
                    VStack(alignment:.leading,spacing:1) {
                        Text(item.name).font(.editorItem).lineLimit(2)
                        if let detail, !detail.isEmpty { Text(detail).font(.editorCaption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength:0)
                }.padding(.vertical,4).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canActivate)
            if let add {
                Button(action:add) { Image(systemName:"plus") }.buttonStyle(.plain).help("Add "+item.name).accessibilityLabel("Add "+item.name)
            }
            Button(action:toggle) { Image(systemName:pinned ? "star.fill" : "star").foregroundStyle(pinned ? Color.accentColor : .secondary) }
                .buttonStyle(.plain).help(pinned ? "Remove from Favorites" : "Add to Favorites").accessibilityLabel((pinned ? "Unpin " : "Pin ")+item.name)
        }.padding(.leading,22).padding(.trailing,8).contextMenu {
            if let add { Button("Add to Graph",action:add) }
            Button(pinned ? "Remove from Favorites" : "Add to Favorites",action:toggle)
            if let file { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
        }
    }
}
