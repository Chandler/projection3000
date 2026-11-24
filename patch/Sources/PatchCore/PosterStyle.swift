import Foundation

/// The Poster node: a tagged text block or a free layout of type, shapes,
/// images and video layers over a fill. Video layers draw its video inputs.
/// (`posterText` is the old separate type node, merged into it on load.)
public enum PosterStyle {
    public static let formats: [(String,VideoDimensions)] = [
        // 11×17 in tabloid at 150 dpi: exact print proportions, light enough to render live.
        ("11×17 tabloid",VideoDimensions(1650,2550)),
        ("3:4 poster",VideoDimensions(1080,1440)),("4:5 feed",VideoDimensions(1080,1350)),
        ("9:16 story",VideoDimensions(1080,1920)),("1:1 square",VideoDimensions(1080,1080)),("16:9 screen",VideoDimensions(1920,1080))
    ]
    static let formatSpec = ParameterSpec("format","Format",0,Double(formats.count-1),0,choices:formats.map(\.0))
    public static func dimensions(_ node: Node) -> VideoDimensions {
        formats[max(0,min(formats.count-1,Int(node.value("format").rounded())))].1
    }

    public static let headlineFonts = ["Helvetica Condensed","Futura Condensed","DIN Condensed","Avenir Next Heavy"]
    public static let textParameters: [ParameterSpec] = [
        formatSpec,
        .init("headlineFont","Headline font",0,Double(headlineFonts.count-1),0,choices:headlineFonts),
        .init("headlineSize","Headline size",0.5,1.3,1),
        .init("slant","Headline slant",0,0.35,0.12),
        .init("tracking","Headline tracking",-0.08,0.1,-0.03),
        .init("bodySize","Body size",0.6,1.5,1),
        .init("margin","Margins",0.02,0.15,0.055),
        .init("spacing","Line spacing",0.6,1.6,1),
        .init("ink","Ink brightness",0.5,1,0.9),
        .init("inkWarmth","Ink warmth",0,1,0.55)
    ]
    /// One line per element; the prefix sets its role. `>` is flexible space.
    public static let defaultText = """
    # NASA
    >
    ## MyKA · Ying · Nitro_Jen · Youngmin
    == NOV. 14TH
    - 8:00 PM – 2:00 AM
    ### NOC NOC
    - 557 Haight St, San Francisco, CA 94117
    ---
    ~ LIGHTING: cb.a__   |   MEDIA: tkohs (Terry)
    """

    public static let composerParameters: [ParameterSpec] = [formatSpec] + [
        .init("backgroundLevel","Fill",0,1,0.035),
        .init("backgroundWarmth","Fill warmth",0,1,0.35),
        .init("textOpacity","Type opacity",0,1,1)
    ] + textParameters.dropFirst()
    public static let typeKeys = Set(textParameters.map(\.key))
    /// Video layer numbers; Video n is input n-1.
    public static let videoInputs = 1...6
    public static let composerInputs = videoInputs.map { "Video \($0)" }
    public static func edgeInput(video: Int) -> Int { video-1 }

    /// A connected input with no layer yet: on top, centered, poster-wide.
    /// Its ID is stable, so the editor can select it before the layout keeps it.
    public static func defaultVideo(input: Int,source: VideoDimensions,poster: VideoDimensions) -> PosterElement {
        var element = PosterElement(shape:.video,id:UUID(uuidString:String(format:"504F5354-0000-4000-8001-%012X",input))!)
        element.input = input
        element.height = Double(poster.width)*Double(source.height)/max(1,Double(source.width))/Double(poster.height)
        return element
    }
    /// The layout plus a default layer for each connected video input it doesn't place.
    public static func withVideos(_ layout: PosterLayout,composer: Node?,graph: Graph) -> PosterLayout {
        guard let composer else { return layout }
        let placed = Set(layout.elements.compactMap { $0.shape == .video ? $0.input : nil })
        var layout = layout
        for edge in graph.edges.sorted(by:{ $0.input < $1.input }) where edge.target == composer.id && videoInputs.contains(edge.input+1) && !placed.contains(edge.input+1) {
            layout.elements.append(defaultVideo(input:edge.input+1,source:graph.videoDimensions(edge.source),poster:dimensions(composer)))
        }
        return layout
    }

    /// Composers from before image layers had Background, Texture and Dust
    /// inputs and a generated paper finish. Their wired images become image
    /// layers in the type's free layout; the paper settings are dropped.
    static let legacyComposerKeys: Set<String> = ["textureMode","textureOpacity","textureOrder","dustMode","dustOpacity","dustInvert","paper","grain","folds","wear","corner","seed"]
    static func needsMigration(_ graph: Graph) -> Bool {
        graph.nodes.contains { $0.kind == .posterText || $0.kind == .posterComposer && ($0.parameters["margin"] == nil || !legacyComposerKeys.union(chromeKeys).isDisjoint(with:$0.parameters.keys)) }
    }
    static func migrate(_ graph: Graph) -> Graph {
        var migrated = graph
        for composer in graph.nodes where composer.kind == .posterComposer && !legacyComposerKeys.isDisjoint(with:composer.parameters.keys) {
            let incoming = graph.edges.filter { $0.target == composer.id }
            func image(_ input: Int) -> Node? { incoming.first { $0.input == input }.flatMap { graph.node($0.source) }.flatMap { $0.kind == .image && $0.file != nil ? $0 : nil } }
            var absorbed: Set<UUID> = []
            if let typeID = incoming.first(where:{ $0.input == 1 })?.source,let index = migrated.nodes.firstIndex(where:{ $0.id == typeID && $0.kind == .posterText }),var elements = migrated.nodes[index].poster?.elements {
                func layer(_ node: Node,_ blend: PosterElement.Blend,opacity: Double = 1,invert: Bool = false) -> PosterElement {
                    var element = PosterElement(shape:.image); element.file = node.file; element.blend = blend; element.opacity = opacity; element.invert = invert
                    absorbed.insert(node.id); return element
                }
                func overChrome(_ element: PosterElement) {
                    if !elements.contains(where:{ $0.shape == .chrome }) { elements.append(PosterElement(shape:.chrome)) }
                    elements.append(element)
                }
                if let node = image(0) { elements.insert(layer(node,.normal),at:0) }
                if let node = image(2) {
                    let modes: [PosterElement.Blend] = [.normal,.multiply,.screen,.overlay,.softLight,.relief]
                    let element = layer(node,modes[max(0,min(5,Int(composer.value("textureMode").rounded())))],opacity:composer.value("textureOpacity"))
                    if composer.value("textureOrder") >= 0.5 { overChrome(element) }
                    else if let marker = elements.firstIndex(where:{ $0.shape == .chrome }) { elements.insert(element,at:marker) } else { elements.append(element) }
                }
                if let node = image(4) {
                    let modes: [PosterElement.Blend] = [.screen,.add,.lighten,.multiply]
                    overChrome(layer(node,modes[max(0,min(3,Int(composer.value("dustMode").rounded())))],opacity:composer.value("dustOpacity"),invert:composer.value("dustInvert") >= 0.5))
                }
                migrated.nodes[index].poster = PosterLayout(elements:elements)
            }
            migrated.edges = migrated.edges.compactMap { edge in
                guard edge.target == composer.id else { return edge }
                guard edge.input == 1 || edge.input == 3 else { return nil }
                var moved = edge; moved.input = edge.input == 1 ? 0 : 1; return moved
            }
            // Image nodes now carried by layers go too, unless something else uses them.
            for id in absorbed where !migrated.edges.contains(where:{ $0.source == id }) { migrated.nodes.removeAll { $0.id == id } }
            if let index = migrated.nodes.firstIndex(where:{ $0.id == composer.id }) {
                for key in legacyComposerKeys { migrated.nodes[index].parameters.removeValue(forKey:key) }
                migrated.nodes[index].modulations = migrated.nodes[index].modulations?.filter { !legacyComposerKeys.contains($0.key) }
            }
        }
        return merge(migrateChrome(migrated))
    }
    /// The composer's chrome placement parameters become a Video 1 layer.
    static let chromeKeys: Set<String> = ["chromeMode","chromeOpacity","chromeScale","chromeX","chromeY","chromeRotation"]
    static func migrateChrome(_ graph: Graph) -> Graph {
        var migrated = graph
        for composer in graph.nodes where composer.kind == .posterComposer && !chromeKeys.isDisjoint(with:composer.parameters.keys) {
            let poster = dimensions(composer)
            if let typeID = graph.edges.first(where:{ $0.target == composer.id && $0.input == 0 })?.source,
               let index = migrated.nodes.firstIndex(where:{ $0.id == typeID && $0.kind == .posterText }),var elements = migrated.nodes[index].poster?.elements {
                let marker = elements.firstIndex { $0.shape == .chrome }
                elements.removeAll { $0.shape == .chrome }
                if let source = graph.edges.first(where:{ $0.target == composer.id && $0.input == 1 })?.source {
                    let size = graph.videoDimensions(source), scale = composer.value("chromeScale")
                    var video = defaultVideo(input:1,source:size,poster:poster)
                    video.id = UUID()
                    video.name = graph.node(source)?.name
                    video.x = 0.5+composer.value("chromeX")*0.5; video.y = 0.5-composer.value("chromeY")*0.5
                    video.width = scale; video.height *= scale; video.rotation = composer.value("chromeRotation")
                    video.opacity = composer.value("chromeOpacity")
                    video.blend = [.normal,.screen,.add,.lighten][max(0,min(3,Int(composer.value("chromeMode").rounded())))]
                    elements.insert(video,at:min(marker ?? elements.count,elements.count))
                }
                migrated.nodes[index].poster = PosterLayout(elements:elements,groups:migrated.nodes[index].poster?.groups)
            }
            if let index = migrated.nodes.firstIndex(where:{ $0.id == composer.id }) {
                for key in chromeKeys { migrated.nodes[index].parameters.removeValue(forKey:key) }
                migrated.nodes[index].modulations = migrated.nodes[index].modulations?.filter { !chromeKeys.contains($0.key) }
            }
        }
        return migrated
    }
    /// Before the merge a Poster Text fed the composer's input 0 (Video n was
    /// input n). The text, layout and type settings move into the composer,
    /// which takes over the type node's other cables; a type node with no
    /// composer becomes a Poster itself.
    static func merge(_ graph: Graph) -> Graph {
        var migrated = graph
        for composer in graph.nodes where composer.kind == .posterComposer && composer.parameters["margin"] == nil {
            guard let index = migrated.nodes.firstIndex(where:{ $0.id == composer.id }) else { continue }
            let typeEdge = migrated.edges.first { $0.target == composer.id && $0.input == 0 }
            if let typeID = typeEdge?.source,let type = migrated.nodes.first(where:{ $0.id == typeID && $0.kind == .posterText }) {
                migrated.nodes[index].text = type.text
                migrated.nodes[index].poster = type.poster
                for key in typeKeys where key != "format" { migrated.nodes[index].parameters[key] = type.parameters[key] ?? type.value(key) }
                let carried = (type.modulations ?? [:]).filter { typeKeys.contains($0.key) && $0.key != "format" }
                if !carried.isEmpty { migrated.nodes[index].modulations = (migrated.nodes[index].modulations ?? [:]).merging(carried) { a,_ in a } }
                // Anything else watching the type now watches the poster.
                migrated.edges = migrated.edges.compactMap { edge in
                    guard edge.source == typeID else { return edge }
                    if edge.target == composer.id { return nil }
                    var moved = edge; moved.source = composer.id; moved.output = nil; return moved
                }
                migrated.nodes.removeAll { $0.id == typeID }
            } else {
                for key in typeKeys where migrated.nodes[index].parameters[key] == nil { migrated.nodes[index].parameters[key] = composer.value(key) }
            }
            migrated.edges = migrated.edges.compactMap { edge in
                guard edge.target == composer.id else { return edge }
                guard edge.input >= 1 else { return nil }
                var moved = edge; moved.input -= 1; return moved
            }
            if let index = migrated.nodes.firstIndex(where:{ $0.id == composer.id }),migrated.nodes[index].name == "Poster Composer" { migrated.nodes[index].name = "Poster" }
        }
        for index in migrated.nodes.indices where migrated.nodes[index].kind == .posterText {
            migrated.nodes[index].kind = .posterComposer
            for spec in composerParameters where migrated.nodes[index].parameters[spec.key] == nil { migrated.nodes[index].parameters[spec.key] = spec.initial }
            if migrated.nodes[index].name == "Poster Text" { migrated.nodes[index].name = "Poster" }
        }
        return migrated
    }
}
