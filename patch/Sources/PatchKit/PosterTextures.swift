import SwiftUI
import AppKit
import ImageIO
import PatchCore

/// The poster texture library: image folders under `~/Projection3000/Patch/Textures`
/// (projects reference these files in place), plus any in
/// `~/Library/Application Support/Patch/Textures`.
enum PosterTextures {
    static let extensions: Set<String> = ["jpg","jpeg","png","tif","tiff","heic","webp"]
    static var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Projection3000/Patch/Textures",isDirectory:true)
        let user = home.appendingPathComponent("Library/Application Support/Patch/Textures",isDirectory:true)
        return [library,user].filter { FileManager.default.fileExists(atPath:$0.path) }
    }
    /// Folders in name order, each with its images; nested folders are flattened into their top folder.
    static func library() -> [(name: String,files: [URL])] {
        var groups: [String:[URL]] = [:]
        for root in roots {
            guard let walker = FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where extensions.contains(url.pathExtension.lowercased()) {
                let relative = url.path.dropFirst(root.path.count+1).split(separator:"/")
                let folder = relative.count > 1 ? String(relative[0]) : "Loose"
                groups[folder,default:[]].append(url)
            }
        }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            (title(key),groups[key]!.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
    }
    static func title(_ folder: String) -> String {
        let words = folder.replacingOccurrences(of:"-",with:" ").replacingOccurrences(of:"_",with:" ")
        return words.prefix(1).uppercased()+words.dropFirst()
    }
}

/// Small, cached thumbnails so a large pack browses quickly.
final class TextureThumbnails: ObservableObject {
    static let shared = TextureThumbnails()
    @Published private(set) var images: [URL:NSImage] = [:]
    private var pending: Set<URL> = []
    private let queue = DispatchQueue(label:"patch.texture-thumbnails",qos:.userInitiated,attributes:.concurrent)
    func image(_ url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard pending.insert(url).inserted else { return nil }
        queue.async {
            let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:220,kCGImageSourceCreateThumbnailWithTransform:true]
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),let thumb = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { return }
            let image = NSImage(cgImage:thumb,size:NSSize(width:thumb.width,height:thumb.height))
            DispatchQueue.main.async { self.images[url] = image }
        }
        return nil
    }
}

struct PosterTextureBrowser: View {
    let current: String?
    /// Offers "Remove Layer", which chooses nil.
    var removable = false
    let choose: (URL?) -> Void
    @ObservedObject private var thumbnails = TextureThumbnails.shared
    @State private var library: [(name: String,files: [URL])] = []
    @State private var folder = ""
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Picker("Folder",selection:$folder) {
                    ForEach(library,id:\.name) { group in Text("\(group.name) · \(group.files.count)").tag(group.name) }
                }.labelsHidden().frame(width:240)
                Spacer()
                if removable { Button("Remove Layer") { choose(nil) } }
            }
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:104),spacing:8)],spacing:8) {
                    ForEach(library.first { $0.name == folder }?.files ?? [],id:\.self) { url in
                        Button { choose(url) } label: {
                            VStack(spacing:3) {
                                ZStack {
                                    Color.black.opacity(0.4)
                                    if let image = thumbnails.image(url) { Image(nsImage:image).resizable().aspectRatio(contentMode:.fill) } else { ProgressView().controlSize(.small) }
                                }
                                .frame(width:104,height:104).clipped()
                                .overlay(RoundedRectangle(cornerRadius:3).stroke(url.path == current ? Color(nsColor:.patchAccent) : Color.white.opacity(0.1),lineWidth:url.path == current ? 2 : 1))
                                Text(url.deletingPathExtension().lastPathComponent).font(.system(size:9)).lineLimit(1).foregroundStyle(.secondary).frame(width:104)
                            }
                        }.buttonStyle(.plain).help(url.lastPathComponent)
                    }
                }
            }
            if library.isEmpty { Text("No textures in assets/textures").foregroundStyle(.secondary) }
        }
        .padding(12).frame(width:500,height:460)
        .onAppear {
            library = PosterTextures.library()
            let currentFolder = library.first { $0.files.contains { $0.path == current } }?.name
            folder = currentFolder ?? library.first?.name ?? ""
        }
    }
}
