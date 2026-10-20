import CoreGraphics
import Foundation
import Vision

/// Lokale Texterkennung (Vision) + Muster für typische Geheimnisse. Bilder und erkannter Text verlassen den Mac nie.
enum SensitiveDetector {
    enum Kind: String, CaseIterable {
        case email, iban, phone, card, secret, ip

        var title: String {
            switch self {
            case .email: "E-Mail"
            case .iban: "IBAN"
            case .phone: "Telefon"
            case .card: "Karte"
            case .secret: "Schlüssel"
            case .ip: "IP"
            }
        }
    }

    struct Finding: Equatable {
        /// Pixel, Ursprung oben links.
        let rect: CGRect
        let kind: Kind
        let text: String
    }

    private static let patterns: [(Kind, NSRegularExpression)] = {
        func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: p, options: opts)
        }
        let list: [(Kind, NSRegularExpression?)] = [
            (.email, re(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, .caseInsensitive)),
            (.iban, re(#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#)),
            // Unterstriche gehen bei kleiner Schrift in der Texterkennung oft verloren („sk_live Knips…“).
            (.secret, re(#"\b(?:sk|pk|rk)[_ ](?:live|test)[_ ][A-Za-z0-9]{10,}\b"#)),
            (.secret, re(#"\bsk-(?:proj-|ant-)?[A-Za-z0-9_\-]{16,}"#)),
            (.secret, re(#"\bgh[pousr][_ ][A-Za-z0-9]{20,}\b"#)),
            (.secret, re(#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#)),
            (.secret, re(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#)),
            (.secret, re(#"\bAKIA[0-9A-Z]{16}\b"#)),
            (.secret, re(#"\bAIza[0-9A-Za-z_\-]{30,}"#)),
            (.secret, re(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}"#)),
            (.secret, re(#"(?i)(?:passwor[dt]|password|pwd|secret|token|api[_ -]?key)\s*[:=]\s*\S{4,}"#)),
            (.card, re(#"\b(?:\d[ \-]?){12,18}\d\b"#)),
            (.phone, re(#"(?:\+|00)[1-9][0-9 ()/.\-]{7,}[0-9]"#)),
            (.phone, re(#"\b0[1-9][0-9]{1,4}[ /\-]?[0-9]{3,}(?:[ \-]?[0-9]{2,})*\b"#)),
            (.ip, re(#"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#)),
        ]
        return list.compactMap { kind, regex in regex.map { (kind, $0) } }
    }()

    /// Lange Zeichenketten aus Buchstaben UND Ziffern ohne Leerzeichen: typisch für Tokens/Hashes.
    private static let generic = try? NSRegularExpression(pattern: #"\b[A-Za-z0-9_\-]{28,}\b"#)

    static func detect(in image: CGImage, kinds: Set<Kind> = Set(Kind.allCases)) async -> [Finding] {
        await Task.detached(priority: .userInitiated) { detectSync(in: image, kinds: kinds) }.value
    }

    /// Längste Kante einer Kachel für die Texterkennung. Vision „genau“ braucht auf 4K-Screenshots im Ganzen
    /// über 30 s, auf 2048 px ~0,15 s — und erkennt Retina-Schrift dort genauso gut (gemessen 08.10.2026).
    static let ocrMaxPixel = 2048

    static func detectSync(in image: CGImage, kinds: Set<Kind> = Set(Kind.allCases)) -> [Finding] {
        guard !kinds.isEmpty else { return [] }
        var findings: [Finding] = []
        for tile in TextRecognizer.recognize(image) {
            for observation in tile.observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                for (kind, range) in matches(in: text, kinds: kinds) {
                    guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                    let rect = tile.pixels(box)
                    let snippet = String(text[range])
                    // Dieselbe Stelle aus einer überlappenden Nachbarkachel (oft abgeschnitten): zusammenlegen,
                    // die vollständigere Fassung behalten. Lieber zu viel verdecken als zu wenig.
                    if let i = findings.firstIndex(where: { same($0, rect: rect, kind: kind, text: snippet) }) {
                        let longer = snippet.count > findings[i].text.count ? snippet : findings[i].text
                        findings[i] = Finding(rect: findings[i].rect.union(rect), kind: findings[i].kind, text: longer)
                        continue
                    }
                    findings.append(Finding(rect: rect, kind: kind, text: snippet))
                }
            }
        }
        return findings
    }

    private static func same(_ f: Finding, rect: CGRect, kind: Kind, text: String) -> Bool {
        let i = f.rect.intersection(rect)
        guard !i.isNull, i.width > 0, i.height > 0 else { return false }
        if f.text.contains(text) || text.contains(f.text) { return true }
        return f.kind == kind && i.area > min(f.rect.area, rect.area) * 0.5
    }

    static func matches(in text: String, kinds: Set<Kind> = Set(Kind.allCases)) -> [(Kind, Range<String.Index>)] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var taken: [NSRange] = []
        var out: [(Kind, Range<String.Index>)] = []
        func add(_ kind: Kind, _ r: NSRange) {
            guard !taken.contains(where: { NSIntersectionRange($0, r).length > 0 }),
                  let range = Range(r, in: text) else { return }
            taken.append(r)
            out.append((kind, range))
        }
        for (kind, regex) in patterns where kinds.contains(kind) {
            for m in regex.matches(in: text, range: full) {
                let s = ns.substring(with: m.range)
                switch kind {
                case .card: if !luhn(s) { continue }
                case .phone: if s.filter(\.isNumber).count < 8 { continue }
                case .iban: if !ibanValid(s) { continue }
                default: break
                }
                add(kind, m.range)
            }
        }
        for m in generic?.matches(in: text, range: full) ?? [] where kinds.contains(.secret) {
            let s = ns.substring(with: m.range)
            let digits = s.filter(\.isNumber).count, letters = s.filter(\.isLetter).count
            if digits >= 4 && letters >= 8 { add(.secret, m.range) }
        }
        return out
    }

    static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    static func ibanValid(_ s: String) -> Bool {
        let iban = s.replacingOccurrences(of: " ", with: "").uppercased()
        guard iban.count >= 15, iban.count <= 34 else { return false }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let value: Int
            if let d = ch.wholeNumberValue { value = d } else if let a = ch.asciiValue, a >= 65, a <= 90 { value = Int(a) - 55 } else { return false }
            for digit in String(value) { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }
}

/// Texterkennung (Vision „genau“) in überlappenden Kacheln von höchstens 2048 px. Im Ganzen auf 2048 px
/// verkleinert wird Schrift auf hohen oder breiten Bildern (Scroll-Screenshots, Ultrawide, 4K in 1×) unlesbar:
/// gemessen 1400×7040 → 2 von 8 E-Mails, 1400×14080 → 0 von 16 (20.10.2026).
enum TextRecognizer {
    struct Tile {
        /// Kachel im Original (Pixel, Ursprung oben links).
        let rect: CGRect
        /// Zuständigkeitsbereich (Original-Pixel): Die Kerne aller Kacheln teilen das Bild lückenlos auf,
        /// die Nähte liegen mitten in den Überlappungen.
        let core: CGRect
        /// Spalte im Kachelraster (0 = links).
        let column: Int
        let observations: [VNRecognizedTextObservation]

        /// Normierte Vision-Box (Ursprung unten links) → Pixel im Original.
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: rect.minX + box.minX * rect.width, y: rect.minY + (1 - box.maxY) * rect.height,
                   width: box.width * rect.width, height: box.height * rect.height)
        }

        func owns(x: CGFloat, y: CGFloat) -> Bool {
            x >= core.minX && x < core.maxX && y >= core.minY && y < core.maxY
        }
    }

    /// Nie stärker verkleinern: Retina-Schrift ist bei 0,5 so groß wie 1×-Schrift und wird noch sicher gelesen.
    static let minFactor: CGFloat = 0.5
    /// Überlappung in Pixeln des Erkennungsbildes: senkrecht mehrere Textzeilen, waagerecht ~90 Zeichen —
    /// so liegt jedes Wort, auch ein langer Schlüssel, in mindestens einer Kachel ganz.
    static let overlapY = 200
    static let overlapX = 640
    /// Zeilen, die im Erkennungsbild niedriger sind (Pixel), gelten als zu klein gelesen: Dann wird in voller
    /// Größe wiederholt. Retina-Schrift liegt bei 0,5 um 15–23 px, 1×-Schrift um 6–9 px.
    static let smallLine: CGFloat = 12

    static func recognize(_ source: CGImage) -> [Tile] {
        let longest = CGFloat(max(source.width, source.height))
        let factor = max(minFactor, min(1, CGFloat(SensitiveDetector.ocrMaxPixel) / longest))
        let tiles = run(source, factor: factor)
        // Bildschirme in 1× (oder sehr kleine Schrift): verkleinert unlesbar → in voller Größe wiederholen.
        guard factor < 0.95, isSmall(tiles, factor: factor) else { return tiles }
        return run(source, factor: 1)
    }

    private static func isSmall(_ tiles: [Tile], factor: CGFloat) -> Bool {
        let heights = tiles.flatMap { t in t.observations.map { $0.boundingBox.height * t.rect.height * factor } }.sorted()
        guard !heights.isEmpty else { return true }
        return heights[heights.count / 4] < smallLine
    }

    private static func run(_ source: CGImage, factor: CGFloat) -> [Tile] {
        let image = factor < 0.999
            ? ImageIOHelper.downscale(source, maxPixel: Int((CGFloat(max(source.width, source.height)) * factor).rounded()))
            : source
        let bx = CGFloat(source.width) / CGFloat(image.width), by = CGFloat(source.height) / CGFloat(image.height)
        func original(_ r: CGRect) -> CGRect { CGRect(x: r.minX * bx, y: r.minY * by, width: r.width * bx, height: r.height * by) }
        let columns = spans(image.width, overlap: overlapX), rows = spans(image.height, overlap: overlapY)
        var tiles: [Tile] = []
        for row in rows {
            for (c, column) in columns.enumerated() {
                let part = CGRect(x: column.tile.lowerBound, y: row.tile.lowerBound, width: column.tile.count, height: row.tile.count)
                guard let crop = image.cropping(to: part) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["de-DE", "en-US"]
                do { try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request]) } catch {
                    Log.error("Texterkennung fehlgeschlagen: \(error.localizedDescription)")
                    continue
                }
                let core = CGRect(x: column.core.lowerBound, y: row.core.lowerBound, width: column.core.count, height: row.core.count)
                tiles.append(Tile(rect: original(part), core: original(core), column: c, observations: request.results ?? []))
            }
        }
        return tiles
    }

    /// Gleich große, überlappende Abschnitte einer Kante (je ≤ 2048 px); `core` teilt die Kante lückenlos auf.
    static func spans(_ length: Int, overlap: Int) -> [(tile: Range<Int>, core: Range<Int>)] {
        let maxTile = SensitiveDetector.ocrMaxPixel
        guard length > maxTile else { return [(0..<length, 0..<length)] }
        let count = Int((Double(length - overlap) / Double(maxTile - overlap)).rounded(.up))
        let size = min(maxTile, Int((Double(length + (count - 1) * overlap) / Double(count)).rounded(.up)))
        let step = Double(length - size) / Double(count - 1)
        let tiles = (0..<count).map { i -> Range<Int> in
            let start = Int((Double(i) * step).rounded())
            return start..<min(length, start + size)
        }
        return tiles.indices.map { i in
            let lo = i == 0 ? 0 : (tiles[i - 1].upperBound + tiles[i].lowerBound) / 2
            let hi = i == tiles.count - 1 ? length : (tiles[i].upperBound + tiles[i + 1].lowerBound) / 2
            return (tiles[i], lo..<hi)
        }
    }
}

/// Textzeilen und Wörter eines Bildes (Pixel, Ursprung oben links) — Grundlage für die schlauen
/// Zensurbalken und „Text kopieren“.
struct TextLine: Sendable {
    struct Word: Sendable { let text: String; let rect: CGRect }
    let text: String
    let rect: CGRect
    let words: [Word]
}

enum TextLayout {
    /// Zeile aus einer Kachel; an einer senkrechten Naht abgeschnittene Teile werden wieder verbunden.
    private struct Piece {
        var line: TextLine
        let column: Int
        /// Wörter links bzw. rechts der eigenen Zuständigkeit weggelassen: Die Zeile geht in der Nachbarkachel weiter.
        var continuesLeft: Bool
        var continuesRight: Bool
    }

    static func lines(in source: CGImage) -> [TextLine] {
        var pieces: [Piece] = []
        for tile in TextRecognizer.recognize(source) {
            for observation in tile.observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                // Zeilen gehören der Kachel, die für ihre Mitte (senkrecht) zuständig ist, Wörter der für ihre
                // Mitte (waagerecht) — im Überlappungsbereich kämen sie sonst doppelt oder abgeschnitten.
                let midY = tile.pixels(observation.boundingBox).midY
                var words: [TextLine.Word] = []
                var boxed = 0
                var left = false, right = false
                var index = text.startIndex
                while index < text.endIndex {
                    guard let start = text[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                    let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                    if let box = try? candidate.boundingBox(for: start..<end)?.boundingBox {
                        boxed += 1
                        let rect = tile.pixels(box)
                        if tile.owns(x: rect.midX, y: midY) {
                            words.append(TextLine.Word(text: String(text[start..<end]), rect: rect))
                        } else if rect.midX < tile.core.minX {
                            left = true
                        } else if rect.midX >= tile.core.maxX {
                            right = true
                        }
                    }
                    index = end
                }
                if boxed == 0 {
                    let rect = tile.pixels(observation.boundingBox)
                    guard tile.owns(x: rect.midX, y: rect.midY) else { continue }
                    pieces.append(Piece(line: TextLine(text: text, rect: rect, words: []), column: tile.column, continuesLeft: false, continuesRight: false))
                    continue
                }
                guard !words.isEmpty else { continue }
                let lineRect = words.dropFirst().reduce(words[0].rect) { $0.union($1.rect) }
                let lineText = words.count == boxed ? text : words.map(\.text).joined(separator: " ")
                pieces.append(Piece(line: TextLine(text: lineText, rect: lineRect, words: words), column: tile.column,
                                    continuesLeft: left, continuesRight: right))
            }
        }
        let result = joinAcrossSeams(pieces).map(\.line)
        // Lesereihenfolge: oben nach unten, innerhalb einer Zeile links nach rechts.
        return result.sorted { a, b in
            abs(a.rect.midY - b.rect.midY) < min(a.rect.height, b.rect.height) * 0.5 ? a.rect.minX < b.rect.minX : a.rect.midY < b.rect.midY
        }
    }

    /// Eine Zeile über eine senkrechte Kachelnaht kommt in zwei Teilen: links mit `continuesRight`,
    /// rechts mit `continuesLeft`, auf gleicher Höhe. Die Teile wieder zu einer Zeile zusammensetzen.
    private static func joinAcrossSeams(_ input: [Piece]) -> [Piece] {
        var pieces = input
        var i = 0
        while i < pieces.count {
            let a = pieces[i].line
            guard pieces[i].continuesRight, let j = pieces.indices.first(where: { j in
                let b = pieces[j].line
                return pieces[j].column == pieces[i].column + 1 && pieces[j].continuesLeft
                    && abs(a.rect.midY - b.rect.midY) < min(a.rect.height, b.rect.height) * 0.5
                    && b.rect.minX >= a.rect.minX && b.rect.minX - a.rect.maxX < max(a.rect.height, b.rect.height) * 3
            }) else {
                i += 1
                continue
            }
            let b = pieces[j].line
            pieces[i].line = TextLine(text: a.text + " " + b.text, rect: a.rect.union(b.rect), words: a.words + b.words)
            pieces[i].continuesRight = pieces[j].continuesRight
            pieces.remove(at: j)
            if j < i { i -= 1 }
            // Gleiche Zeile erneut prüfen: Über drei Spalten hat sie zwei Nähte.
        }
        return pieces
    }

    /// Flächen, unter denen Text nicht mehr zu sehen ist: Zensur sowie gefüllte, deckende Formen.
    static func hidingRects(_ annotations: [Annotation], scale: CGFloat) -> [CGRect] {
        annotations.compactMap { a in
            switch a.kind {
            case .redact:
                return a.rect
            case .rectangle, .ellipse:
                return a.filled && a.color.a >= 0.99 ? a.rect : nil
            case .counter:
                let r = a.counterRadius(scale: scale)
                return a.color.a >= 0.99 ? CGRect(x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r) : nil
            default:
                return nil
            }
        }
    }

    /// Text in Lesereihenfolge. Wörter unter einer Zensur werden durch █ ersetzt — sie dürfen nie
    /// über „Text kopieren“ wieder auftauchen. Jede Überschneidung zählt: Ein Wort, das ein Balken
    /// auch nur streift, gilt als verdeckt; Zeilen ohne Wortboxen fallen dann ganz weg.
    static func plainText(_ lines: [TextLine], excluding hidden: [CGRect] = []) -> String {
        let isHidden: (CGRect) -> Bool = { r in
            hidden.contains { let i = $0.intersection(r); return !i.isNull && i.width > 0 && i.height > 0 }
        }
        var out: [String] = []
        var lastMidY: CGFloat?
        var current = ""
        for line in lines {
            if line.words.isEmpty, isHidden(line.rect) { continue }
            let words = line.words.map { isHidden($0.rect) ? "████" : $0.text }
            if !words.isEmpty, words.allSatisfy({ $0 == "████" }) { continue }
            let text = line.words.isEmpty ? line.text : words.joined(separator: " ")
            if let y = lastMidY, abs(line.rect.midY - y) < line.rect.height * 0.5 {
                current += "  " + text
            } else {
                if !current.isEmpty { out.append(current) }
                current = text
            }
            lastMidY = line.rect.midY
        }
        if !current.isEmpty { out.append(current) }
        return out.joined(separator: "\n")
    }
}
