#if KNIPS_DEV
import AppKit

/// Selbsttests für große Bilder (Texterkennung in Kacheln) und Scroll-Screenshots ohne Obergrenze.
/// Alle Bilder entstehen im Speicher, nichts wird vom Bildschirm aufgenommen.
extension SelfTest {
    // MARK: Testbilder

    /// Mehrere Testfenster (`sampleImage`) nebeneinander/untereinander, jedes mit eigener E-Mail-Adresse.
    struct Composite {
        let name: String
        let image: CGImage
        /// Pixel pro Punkt der Testfenster (Lage der Zeilen im Fenster)
        let scale: CGFloat
        /// Fenster (Pixel, oben links) und die E-Mail-Adresse darin.
        let windows: [(rect: CGRect, email: String)]
    }

    static func composite(_ name: String, width: Int, height: Int, window: CGSize, scale: CGFloat, columns: Int, count: Int) -> Composite {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var windows: [(CGRect, String)] = []
        for i in 0..<count {
            let email = "erika\(i + 1).mustermann@example.com"
            let tile = sampleImage(width: Int(window.width), height: Int(window.height), scale: scale, email: email)
            let rect = CGRect(x: CGFloat(i % columns) * window.width, y: CGFloat(i / columns) * window.height, width: window.width, height: window.height)
            ctx.draw(tile, in: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
            windows.append((rect, email))
        }
        return Composite(name: name, image: ctx.makeImage()!, scale: scale, windows: windows)
    }

    /// Bildschirm voller Text (wie Editor oder Terminal) mit `emails` eingestreuten Adressen.
    static func denseText(width: Int, height: Int, fontSize: CGFloat, emails: Int) -> (image: CGImage, emails: [String]) {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.setFillColor(CGColor(gray: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let words = ["Bestellung", "versendet", "Kunde", "Rechnung", "Lieferung", "Artikel", "Status", "offen", "zugestellt",
                     "Betrag", "Datum", "Konto", "Nummer", "Adresse", "Hinweis"]
        let lineHeight = fontSize * 1.5
        let lines = Int(CGFloat(height) / lineHeight) - 1
        let every = max(1, lines / max(1, emails))
        var found: [String] = []
        for i in 0..<lines {
            var s = ""
            var j = i
            while CGFloat(s.count) < CGFloat(width) / (fontSize * 0.55) - 30 { s += words[j % words.count] + " "; j += 7 }
            if i % every == every / 2, found.count < emails {
                let mail = "nutzer\(found.count + 1).test\(i)@example.com"
                found.append(mail)
                s = "Kontakt " + mail + " " + s
            }
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black])
                .draw(at: CGPoint(x: 20, y: 10 + CGFloat(i) * lineHeight))
        }
        NSGraphicsContext.restoreGraphicsState()
        return (ctx.makeImage()!, found)
    }

    /// Hohe, breite und 1×-Bilder, auf denen die Erkennung früher versagte (eine Verkleinerung auf 2048 px).
    static func largeComposites() -> [Composite] {
        [
            composite("hoch 1400×7040", width: 1400, height: 7040, window: CGSize(width: 1400, height: 880), scale: 2, columns: 1, count: 8),
            composite("hoch 1400×14080", width: 1400, height: 14080, window: CGSize(width: 1400, height: 880), scale: 2, columns: 1, count: 16),
            composite("breit 7000×880", width: 7000, height: 880, window: CGSize(width: 1400, height: 880), scale: 2, columns: 5, count: 5),
            composite("4K 1× 3840×2160", width: 3840, height: 2160, window: CGSize(width: 1280, height: 720), scale: 1, columns: 3, count: 9),
            composite("Ultrawide 1× 5120×1440", width: 5120, height: 1440, window: CGSize(width: 1280, height: 720), scale: 1, columns: 4, count: 8),
            composite("4K 2× 3840×2160", width: 3840, height: 2160, window: CGSize(width: 1920, height: 1080), scale: 2, columns: 2, count: 4),
        ]
    }

    // MARK: Erkennung auf großen Bildern (Teil von `detect`)

    static func detectLarge(_ out: URL) throws {
        var missing: [String] = []
        for c in largeComposites() {
            let t = CFAbsoluteTimeGetCurrent()
            let findings = SensitiveDetector.detectSync(in: c.image)
            let detectTime = CFAbsoluteTimeGetCurrent() - t
            let t2 = CFAbsoluteTimeGetCurrent()
            let lines = TextLayout.lines(in: c.image)
            let linesTime = CFAbsoluteTimeGetCurrent() - t2
            let text = TextLayout.plainText(lines)
            var hits = 0, keys = 0, copied = 0
            for (i, w) in c.windows.enumerated() {
                // Pflicht: E-Mail und Stripe-Key jedes Fensters gefunden, und zwar auf ihrer Zeile (Text darf
                // Lesefehler enthalten, etwa „.con“ — verdeckt wird trotzdem die richtige Stelle).
                func found(_ kind: SensitiveDetector.Kind, lineY: CGFloat, prefix: String) -> Bool {
                    findings.contains { f in
                        let y = (f.rect.midY - w.rect.minY) / c.scale
                        return f.kind == kind && f.text.hasPrefix(prefix) && w.rect.contains(CGPoint(x: f.rect.midX, y: f.rect.midY))
                            && y > lineY && y < lineY + 22
                    }
                }
                if found(.email, lineY: 124, prefix: "erika") { hits += 1 } else { missing.append("\(c.name): E-Mail \(i + 1)") }
                if found(.secret, lineY: 208, prefix: "sk") { keys += 1 } else { missing.append("\(c.name): Stripe-Key \(i + 1)") }
                if text.contains(w.email) { copied += 1 } else { missing.append("\(c.name): Text kopieren \(i + 1)") }
            }
            // Überlappende Kacheln dürfen keine Zeile doppelt liefern.
            let headings = text.components(separatedBy: "Kundendaten").count - 1
            let sentences = text.components(separatedBy: "Bestellung #48213 wurde am 03.10. versendet und ist unterwegs.").count - 1
            if headings != c.windows.count { missing.append("\(c.name): „Kundendaten“ \(headings)× statt \(c.windows.count)×") }
            if sentences != c.windows.count { missing.append("\(c.name): Satz über Kachelgrenze \(sentences)× statt \(c.windows.count)×") }
            print(String(format: "  %@: E-Mail %d/%d · Key %d/%d · Text %d/%d · Überschriften %d · Erkennung %.0f ms · Zeilen %.0f ms",
                         c.name, hits, c.windows.count, keys, c.windows.count, copied, c.windows.count, headings, detectTime * 1000, linesTime * 1000))
        }
        if !missing.isEmpty { throw CheckFailed(message: "Große Bilder – nicht erkannt: \(missing.joined(separator: ", "))") }
        print("   ✓ Hohe, breite und 1×-Bilder: alle E-Mails und Schlüssel gefunden, Text ohne Doppelungen")
        try textHiding()
    }

    /// „Text kopieren“ im Editor: Jede Überschneidung mit einer Zensur oder einer gefüllten, deckenden Form
    /// verdeckt ein Wort; Zeilen ohne Wortboxen fallen dann ganz weg.
    static func textHiding() throws {
        let line = TextLine(text: "geheim offen", rect: CGRect(x: 100, y: 100, width: 120, height: 20), words: [
            TextLine.Word(text: "geheim", rect: CGRect(x: 100, y: 100, width: 60, height: 20)),
            TextLine.Word(text: "offen", rect: CGRect(x: 170, y: 100, width: 50, height: 20)),
        ])
        let bare = TextLine(text: "ohne Wortboxen", rect: CGRect(x: 100, y: 200, width: 150, height: 20), words: [])
        func a(_ kind: AnnotationKind, _ r: CGRect, filled: Bool = false) -> Annotation {
            var a = Annotation(kind: kind, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY))
            a.filled = filled
            return a
        }
        let cases: [(String, [Annotation], String)] = [
            ("ohne Zensur", [], "geheim offen\nohne Wortboxen"),
            ("Balken streift 1 px", [a(.redact, CGRect(x: 159, y: 110, width: 5, height: 5))], "████ offen\nohne Wortboxen"),
            ("gefülltes Rechteck", [a(.rectangle, CGRect(x: 200, y: 95, width: 40, height: 30), filled: true)], "geheim ████\nohne Wortboxen"),
            ("gefüllte Ellipse", [a(.ellipse, CGRect(x: 200, y: 95, width: 40, height: 30), filled: true)], "geheim ████\nohne Wortboxen"),
            ("Rechteck-Umriss", [a(.rectangle, CGRect(x: 200, y: 95, width: 40, height: 30))], "geheim offen\nohne Wortboxen"),
            ("Markieren", [a(.highlight, CGRect(x: 200, y: 95, width: 40, height: 30))], "geheim offen\nohne Wortboxen"),
            ("Zeile ohne Wortboxen gestreift", [a(.redact, CGRect(x: 249, y: 219, width: 10, height: 10))], "geheim offen"),
            ("nur Kante an Kante", [a(.redact, CGRect(x: 220, y: 100, width: 10, height: 20))], "geheim offen\nohne Wortboxen"),
        ]
        var wrong: [String] = []
        for (name, annotations, expected) in cases {
            let text = TextLayout.plainText([line, bare], excluding: TextLayout.hidingRects(annotations, scale: 2))
            if text != expected { wrong.append("\(name): „\(text.replacingOccurrences(of: "\n", with: " ⏎ "))“") }
        }
        if !wrong.isEmpty { throw CheckFailed(message: "Text kopieren gibt Verdecktes aus: \(wrong.joined(separator: "; "))") }
        print("   ✓ Text kopieren: jede Überschneidung mit Zensur oder gefüllter Form verdeckt (\(cases.count) Fälle)")
    }

    // MARK: Tempo der Texterkennung (`--selftest ocr-bench`)

    static func ocrBench(_ out: URL) throws {
        let dense4K = denseText(width: 3840, height: 2160, fontSize: 26, emails: 10)
        let dense5K = denseText(width: 5120, height: 2880, fontSize: 26, emails: 10)
        let dense4K1 = denseText(width: 3840, height: 2160, fontSize: 13, emails: 10)
        var cases: [(String, CGImage, Int)] = [
            ("4K 2× textreich 3840×2160", dense4K.image, dense4K.emails.count),
            ("5K 2× textreich 5120×2880", dense5K.image, dense5K.emails.count),
            ("4K 1× textreich 3840×2160", dense4K1.image, dense4K1.emails.count),
        ]
        cases += largeComposites().map { ($0.name, $0.image, $0.windows.count) }
        // Ohne Text (Foto, Verlauf): löst den zweiten Durchgang in voller Größe aus — was kostet er?
        let photo = CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        photo.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [NSColor.systemTeal.cgColor, NSColor.systemIndigo.cgColor] as CFArray, locations: nil)!,
                                 start: .zero, end: CGPoint(x: 3840, y: 2160), options: [])
        cases.append(("4K ohne Text (Verlauf)", photo.makeImage()!, 0))
        cases.append(("Testfenster 1400×880", sampleImage(), 1))
        _ = SensitiveDetector.detectSync(in: sampleImage())   // Vision laden
        for (name, image, expected) in cases {
            var times: [Double] = []
            var emails = 0
            for _ in 0..<3 {
                let t = CFAbsoluteTimeGetCurrent()
                emails = SensitiveDetector.detectSync(in: image, kinds: [.email]).count
                times.append(CFAbsoluteTimeGetCurrent() - t)
            }
            times.sort()
            print(String(format: "  %-28@ Median %5.0f ms (min %5.0f) · E-Mail-Funde %2d von %2d", name as NSString, times[1] * 1000, times[0] * 1000, emails, expected))
        }
    }
}
#endif
