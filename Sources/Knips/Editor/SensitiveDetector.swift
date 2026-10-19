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
            (.secret, re(#"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b"#)),
            (.secret, re(#"\bsk-(?:proj-|ant-)?[A-Za-z0-9_\-]{16,}"#)),
            (.secret, re(#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#)),
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

    /// Längste Kante für die Texterkennung. Vision „genau“ braucht auf 4K-Screenshots über 30 s,
    /// auf 2048 px ~0,15 s — und erkennt Retina-Schrift dort genauso gut (gemessen 08.10.2026).
    static let ocrMaxPixel = 2048

    static func detectSync(in image: CGImage, kinds: Set<Kind> = Set(Kind.allCases)) -> [Finding] {
        guard !kinds.isEmpty else { return [] }
        let source = image
        let image = ImageIOHelper.downscale(source, maxPixel: ocrMaxPixel)
        let back = CGFloat(source.width) / CGFloat(image.width)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch {
            Log.error("Texterkennung fehlgeschlagen: \(error.localizedDescription)")
            return []
        }
        // Normierte Koordinaten → Pixel des Originals
        let w = CGFloat(image.width) * back, h = CGFloat(image.height) * back
        var findings: [Finding] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            for (kind, range) in matches(in: text, kinds: kinds) {
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                let rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
                let snippet = String(text[range])
                if findings.contains(where: { $0.rect.intersects(rect) && $0.text.contains(snippet) }) { continue }
                findings.append(Finding(rect: rect, kind: kind, text: snippet))
            }
        }
        return findings
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

/// Textzeilen und Wörter eines Bildes (Pixel, Ursprung oben links) — Grundlage für die schlauen
/// Zensurbalken und „Text kopieren“.
struct TextLine: Sendable {
    struct Word: Sendable { let text: String; let rect: CGRect }
    let text: String
    let rect: CGRect
    let words: [Word]
}

enum TextLayout {
    static func lines(in source: CGImage) -> [TextLine] {
        let image = ImageIOHelper.downscale(source, maxPixel: SensitiveDetector.ocrMaxPixel)
        let back = CGFloat(source.width) / CGFloat(image.width)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return [] }
        let w = CGFloat(image.width) * back, h = CGFloat(image.height) * back
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        }
        var result: [TextLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            var words: [TextLine.Word] = []
            var index = text.startIndex
            while index < text.endIndex {
                guard let start = text[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                if let box = try? candidate.boundingBox(for: start..<end)?.boundingBox {
                    words.append(TextLine.Word(text: String(text[start..<end]), rect: pixels(box)))
                }
                index = end
            }
            let lineRect = words.isEmpty ? pixels(observation.boundingBox) : words.dropFirst().reduce(words[0].rect) { $0.union($1.rect) }
            result.append(TextLine(text: text, rect: lineRect, words: words))
        }
        // Lesereihenfolge: oben nach unten, innerhalb einer Zeile links nach rechts.
        return result.sorted { a, b in
            abs(a.rect.midY - b.rect.midY) < min(a.rect.height, b.rect.height) * 0.5 ? a.rect.minX < b.rect.minX : a.rect.midY < b.rect.midY
        }
    }

    /// Text in Lesereihenfolge. Wörter unter einer Zensur werden durch █ ersetzt — sie dürfen nie
    /// über „Text kopieren“ wieder auftauchen.
    static func plainText(_ lines: [TextLine], excluding hidden: [CGRect] = []) -> String {
        var out: [String] = []
        var lastMidY: CGFloat?
        var current = ""
        for line in lines {
            let isHidden: (CGRect) -> Bool = { r in hidden.contains { $0.intersection(r).area > r.area * 0.15 } }
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
