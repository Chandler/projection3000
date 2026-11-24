import Foundation

/// A Poster Text node's free layout: placed type and shapes, drawn in order
/// (first is backmost). Without one, the node lays out its tagged text.
public struct PosterLayout: Codable, Equatable, Sendable {
    public var elements: [PosterElement]
    /// Folders in Layers. Members (elements naming the group) stay contiguous.
    public var groups: [PosterGroup]?
    public init(elements: [PosterElement] = [], groups: [PosterGroup]? = nil) { self.elements = elements; self.groups = groups }

    public func group(_ id: UUID?) -> PosterGroup? { id.flatMap { id in groups?.first { $0.id == id } } }
    /// Hidden or locked itself or through its group.
    public func isHidden(_ element: PosterElement) -> Bool { element.hidden || group(element.group)?.hidden == true }
    public func isLocked(_ element: PosterElement) -> Bool { element.locked || group(element.group)?.locked == true }
    /// What draws: visible elements in stack order.
    public var visible: [PosterElement] { elements.filter { !isHidden($0) } }
    /// Drops empty groups and memberships of missing groups, and pulls each
    /// group's members together at its frontmost member.
    public func normalized() -> PosterLayout {
        let known = Set(groups?.map(\.id) ?? [])
        var cleaned = elements.map { element -> PosterElement in
            var element = element
            if element.shape == .chrome || element.group.map({ !known.contains($0) }) == true { element.group = nil }
            return element
        }
        var placed: Set<UUID> = [], frontToBack: [PosterElement] = []
        for element in cleaned.reversed() {
            guard let group = element.group else { frontToBack.append(element); continue }
            guard placed.insert(group).inserted else { continue }
            frontToBack += cleaned.reversed().filter { $0.group == group }
        }
        cleaned = frontToBack.reversed()
        let used = Set(cleaned.compactMap(\.group))
        let kept = groups?.filter { used.contains($0.id) }
        return PosterLayout(elements: cleaned, groups: kept?.isEmpty == false ? kept : nil)
    }
}

public struct PosterGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var collapsed: Bool
    public var hidden: Bool
    public var locked: Bool
    public init(name: String, id: UUID = UUID()) { self.id = id; self.name = name; collapsed = false; hidden = false; locked = false }
    private enum CodingKeys: String, CodingKey { case id, name, collapsed, hidden, locked }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
}

/// Positions are normalized to the poster (x of width, y of height, y down)
/// so a layout survives format changes. Sizes and weights are fractions of
/// the poster width, so type keeps its proportions.
public struct PosterElement: Codable, Equatable, Identifiable, Sendable {
    /// `video` draws one of the composer's video inputs. `chrome` is the
    /// pre-video marker for the composer's chrome, converted on load.
    public enum Shape: String, Codable, Sendable, CaseIterable { case text, rule, rectangle, ellipse, image, video, chrome }
    public enum Align: Int, Codable, Sendable { case left, center, right }
    /// How a layer combines with everything below it. `relief` adds only an
    /// image's local detail (creases, wrinkles), so it never shifts overall brightness.
    public enum Blend: String, Codable, Sendable, CaseIterable {
        case normal, multiply, screen, overlay, softLight, add, lighten, darken, difference, relief
        public var title: String { self == .softLight ? "Soft light" : rawValue.prefix(1).uppercased()+rawValue.dropFirst() }
    }
    public var id: UUID
    public var shape: Shape
    public var name: String?
    public var text: String
    /// PostScript font name.
    public var font: String
    public var size: Double
    /// In ems.
    public var tracking: Double
    /// Horizontal shear of the glyphs.
    public var slant: Double
    /// Baseline advance as a multiple of the line height.
    public var leading: Double
    public var align: Align
    /// Center.
    public var x: Double
    public var y: Double
    /// Shapes only; text measures itself.
    public var width: Double
    public var height: Double
    /// Degrees, clockwise.
    public var rotation: Double
    /// sRGB; nil follows the node's ink.
    public var color: [Double]?
    public var opacity: Double
    /// Outline weight for rectangles and ellipses (0 fills), thickness for rules.
    public var stroke: Double
    public var hidden: Bool
    public var locked: Bool
    /// Images only: the file, filled into the box and cropped to it.
    public var file: String?
    public var blend: Blend
    /// Images only: negative of the file, e.g. dark marks from a white-on-black scan.
    public var invert: Bool
    /// The Layers folder this element belongs to.
    public var group: UUID?
    /// Video only: the composer input it draws (1 is Video 1).
    public var input: Int?

    public init(shape: Shape, x: Double = 0.5, y: Double = 0.5, id: UUID = UUID()) {
        self.id = id; self.shape = shape; name = nil; self.x = x; self.y = y
        text = shape == .text ? "TEXT" : ""
        font = "HelveticaNeue-Bold"; size = 0.06; tracking = 0; slant = 0; leading = 1; align = .center
        width = shape == .rule ? 0.8 : shape == .image || shape == .video ? 1 : 0.3; height = shape == .rule ? 0 : shape == .image || shape == .video ? 1 : 0.2
        rotation = 0; color = nil; opacity = 1
        stroke = shape == .rule ? 0.0018 : 0; hidden = false; locked = false
        file = nil; blend = .normal; invert = false
    }

    // Every field is optional on disk so layouts written by agents or older
    // builds load with defaults.
    private enum CodingKeys: String, CodingKey { case id, shape, name, text, font, size, tracking, slant, leading, align, x, y, width, height, rotation, color, opacity, stroke, hidden, locked, file, blend, invert, group, input }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(shape: try c.decodeIfPresent(Shape.self, forKey: .shape) ?? .text, id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID())
        name = try c.decodeIfPresent(String.self, forKey: .name)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? text
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? font
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        tracking = try c.decodeIfPresent(Double.self, forKey: .tracking) ?? tracking
        slant = try c.decodeIfPresent(Double.self, forKey: .slant) ?? slant
        leading = try c.decodeIfPresent(Double.self, forKey: .leading) ?? leading
        align = try c.decodeIfPresent(Align.self, forKey: .align) ?? align
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? x
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? y
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? height
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? rotation
        color = try c.decodeIfPresent([Double].self, forKey: .color)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        stroke = try c.decodeIfPresent(Double.self, forKey: .stroke) ?? stroke
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        file = try c.decodeIfPresent(String.self, forKey: .file)
        blend = try c.decodeIfPresent(Blend.self, forKey: .blend) ?? .normal
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        group = try c.decodeIfPresent(UUID.self, forKey: .group)
        input = try c.decodeIfPresent(Int.self, forKey: .input)
    }

    public var title: String {
        if let name, !name.isEmpty { return name }
        switch shape {
        case .text: let line = text.split(separator: "\n").first.map(String.init) ?? ""; return line.isEmpty ? "Text" : line
        case .rule: return "Rule"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .image: return file.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Image"
        case .video: return "Video \(input ?? 1)"
        case .chrome: return "Chrome"
        }
    }
    public var isValid: Bool {
        [size, tracking, slant, leading, x, y, width, height, rotation, opacity, stroke].allSatisfy(\.isFinite)
            && (color?.count ?? 3) >= 3 && (color?.allSatisfy(\.isFinite) ?? true) && text.count <= 4096 && (file?.count ?? 0) <= 4096 && (input.map { PosterStyle.videoInputs.contains($0) } ?? true)
    }
}
