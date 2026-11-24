import SwiftUI
import AppKit

/// Font chooser that previews the layer's own text in each face. Choosing
/// applies at once and keeps the popover open, so the canvas previews too;
/// ↑/↓ step through families. Starred faces are listed first, in the order
/// they were starred.
struct PosterFontBrowser: View {
    let current: String
    let sample: String
    let choose: (String) -> Void
    @State private var query = ""
    @State private var family: String?
    @State private var favorites = PosterFonts.favorites
    @FocusState private var searching: Bool

    private var favoriteFaces: [(String,String)] {
        favorites.filter { NSFont(name:$0,size:12) != nil }.map { ($0,PosterFonts.name($0)) }
            .filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) }
    }
    private var featured: [(String,String)] {
        PosterFonts.featured.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) }
    }
    private var families: [String] {
        query.isEmpty ? PosterFonts.families : PosterFonts.families.filter { $0.localizedCaseInsensitiveContains(query) }
    }
    private var text: String {
        let line = sample.split(separator:"\n").first.map { String($0.prefix(32)) } ?? ""
        return line.trimmingCharacters(in:.whitespaces).isEmpty ? "Poster" : line
    }
    private var currentStyle: String? {
        NSFont(name:current,size:12)?.familyName.flatMap { family in PosterFonts.members(family).first { $0.0 == current }?.1 }
    }

    var body: some View {
        VStack(spacing:0) {
            TextField("Search",text:$query).textFieldStyle(.roundedBorder).focused($searching).padding(10)
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onKeyPress(.return) { if let first = families.first, family == nil || !families.contains(family!) { pick(first) }; return .handled }
            Divider()
            HStack(spacing:0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:0) {
                            if !favoriteFaces.isEmpty {
                                header("Favorites")
                                ForEach(favoriteFaces,id:\.0) { face in
                                    row(face.1,font:face.0,selected:face.0 == current,star:face.0) { family = NSFont(name:face.0,size:12)?.familyName; choose(face.0) }
                                }
                            }
                            if !featured.isEmpty {
                                header("Featured")
                                ForEach(featured,id:\.0) { face in
                                    row(face.1,font:face.0,selected:face.0 == current,star:face.0) { family = NSFont(name:face.0,size:12)?.familyName; choose(face.0) }
                                }
                            }
                            if !favoriteFaces.isEmpty || !featured.isEmpty { header("All Fonts") }
                            ForEach(families,id:\.self) { name in
                                let face = PosterFonts.face(name,style:nil)
                                row(name,font:face,selected:name == family,star:face) { pick(name) }.id(name)
                            }
                        }
                    }
                    .onChange(of:family) { _,name in if let name { withAnimation(.easeOut(duration:0.12)) { proxy.scrollTo(name) } } }
                    .onAppear { if let family { proxy.scrollTo(family,anchor:.center) } }
                }
                .frame(width:330)
                Divider()
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:0) {
                        if let family {
                            header(family)
                            ForEach(PosterFonts.members(family),id:\.0) { member in
                                row(member.1,font:member.0,selected:member.0 == current,size:15,star:member.0) { choose(member.0) }
                            }
                        }
                    }
                }
                .frame(width:220)
            }
        }
        .frame(height:500)
        .onAppear {
            family = NSFont(name:current,size:12)?.familyName
            searching = true
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal,12).padding(.top,10).padding(.bottom,4)
    }
    /// `star` is the face the row's star toggles.
    private func row(_ title: String,font: String?,selected: Bool,size: CGFloat = 19,star: String? = nil,action: @escaping () -> Void) -> some View {
        HStack(spacing:0) {
            Button(action:action) {
                VStack(alignment:.leading,spacing:1) {
                    Text(text).font(font.flatMap { NSFont(name:$0,size:size) }.map { Font($0 as CTFont) } ?? .system(size:size)).lineLimit(1)
                    Text(title).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth:.infinity,alignment:.leading).padding(.leading,12).padding(.vertical,5)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let star {
                let on = favorites.contains(star)
                Button { toggleFavorite(star) } label: {
                    Image(systemName:on ? "star.fill" : "star").font(.system(size:11))
                        .foregroundStyle(on ? Color.yellow : Color.secondary.opacity(0.5))
                        .frame(width:28).frame(maxHeight:.infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).help(on ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        .padding(.trailing,star == nil ? 12 : 4)
        .background(selected ? Color(nsColor:.patchAccent).opacity(0.28) : Color.clear)
    }
    private func toggleFavorite(_ face: String) {
        if let index = favorites.firstIndex(of:face) { favorites.remove(at:index) } else { favorites.append(face) }
        PosterFonts.favorites = favorites
    }
    /// Keeps the current style when the new family has it.
    private func pick(_ name: String) {
        family = name
        if let face = PosterFonts.face(name,style:currentStyle) { choose(face) }
    }
    private func step(_ delta: Int) {
        let list = families
        guard !list.isEmpty else { return }
        let index = family.flatMap { list.firstIndex(of:$0) }.map { min(max($0+delta,0),list.count-1) } ?? 0
        pick(list[index])
    }
}

extension PosterFonts {
    /// Starred PostScript names, shared by every poster.
    static var favorites: [String] {
        get { UserDefaults.standard.stringArray(forKey:"posterFontFavorites") ?? [] }
        set { UserDefaults.standard.set(newValue,forKey:"posterFontFavorites") }
    }
    /// A family's face with the given style, else its regular face, else its first.
    static func face(_ family: String,style: String?) -> String? {
        let members = members(family)
        return (members.first { $0.1 == style } ?? members.first { $0.1 == "Regular" } ?? members.first)?.0
    }
}
