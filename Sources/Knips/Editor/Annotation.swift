import AppKit

struct RGBA: Codable, Equatable, Hashable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    static let red = RGBA(r: 1, g: 0.23, b: 0.19)
    static let orange = RGBA(r: 1, g: 0.58, b: 0)
    static let yellow = RGBA(r: 1, g: 0.8, b: 0)
    static let green = RGBA(r: 0.2, g: 0.78, b: 0.35)
    static let blue = RGBA(r: 0, g: 0.48, b: 1)
    static let purple = RGBA(r: 0.69, g: 0.32, b: 0.87)
    static let black = RGBA(r: 0.08, g: 0.08, b: 0.09)
    static let white = RGBA(r: 1, g: 1, b: 1)

    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

enum AnnotationKind: String, Codable {
    case arrow, line, rectangle, ellipse, text, counter, highlight, redact
}

enum StrokeSize: Int, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: Int { rawValue }
    var lineWidth: CGFloat { [3, 5, 8][rawValue] }
    var fontSize: CGFloat { [16, 24, 36][rawValue] }
    var counterRadius: CGFloat { [11, 15, 21][rawValue] }
    var title: String { ["S", "M", "L"][rawValue] }
}

/// Alle Koordinaten in Pixeln des Originalbildes, Ursprung oben links.
struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var color: RGBA = .red
    var size: StrokeSize = .medium
    var filled = false
    var text = ""
    var number = 1
    var redactStyle: RedactStyle = .pixelate
    /// Von der Auto-Zensur vorgeschlagen.
    var auto = false

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var isLineLike: Bool { kind == .arrow || kind == .line }
    var isRectLike: Bool { kind == .rectangle || kind == .ellipse || kind == .highlight || kind == .redact }

    func lineWidth(scale: CGFloat) -> CGFloat { size.lineWidth * scale }
    func fontSize(scale: CGFloat) -> CGFloat { size.fontSize * scale }
    func counterRadius(scale: CGFloat) -> CGFloat { size.counterRadius * scale }

    mutating func offset(by d: CGVector) {
        start.x += d.dx; start.y += d.dy
        end.x += d.dx; end.y += d.dy
    }
}
