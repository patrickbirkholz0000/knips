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

    // MARK: Hilfen

    /// Wie `runAsync` in SelfTest.swift: Hauptthread-Runloop drehen, bis der Block fertig ist.
    static func wait(_ body: @escaping @MainActor () async throws -> Void) throws {
        var result: Result<Void, Error>?
        Task { @MainActor in
            do { try await body(); result = .success(()) } catch { result = .failure(error) }
        }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try result?.get()
    }

    /// Wartet höchstens `seconds`, bis `condition` gilt.
    static func until(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Pixel als BGRA-Bytes — für exakte Vergleiche.
    static func pixels(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }

    // MARK: Scroll-Screenshot (Teil von `stitch`)

    /// Lange Testseite und überlappende „Bildschirm“-Ausschnitte wie beim Scrollen.
    static func scrollPage() -> (page: CGImage, frames: [CGImage], offsets: [Int], view: Int) {
        let w = 1200, h = 4200, view = 900
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<120 {
            let y = CGFloat(20 + i * 34)
            NSAttributedString(string: "Zeile \(i + 1) · Rechnung #\(73000 + i * 11) · \(["offen", "bezahlt", "storniert"][i % 3])",
                               attributes: [.font: NSFont.systemFont(ofSize: 20)]).draw(at: CGPoint(x: 40 + CGFloat(i % 7) * 10, y: y))
            if i % 8 == 0 { ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.3).cgColor); ctx.fill(CGRect(x: 650, y: y, width: 320, height: 26)) }
        }
        NSGraphicsContext.restoreGraphicsState()
        let page = ctx.makeImage()!
        let offsets = [0, 140, 410, 760, 1180, 1500, 1990, 2400, 2760, 3100, 3300]
        return (page, offsets.map { page.cropping(to: CGRect(x: 0, y: $0, width: w, height: view))! }, offsets, view)
    }

    static func stitchRobust(_ out: URL) throws {
        let (page, frames, offsets, view) = scrollPage()
        let w = page.width
        func reference(_ height: Int) -> [UInt8] { pixels(page.cropping(to: CGRect(x: 0, y: 0, width: w, height: height))!) }
        var problems: [String] = []

        // 1) Nur neue Zeilen werden behalten, nicht ganze Bilder.
        let stitcher = ScrollStitcher(first: frames[0])
        for f in frames.dropFirst() { stitcher.add(f) }
        let expected = offsets.last! + view
        let framesBytes = frames.count * view * w * 4
        if stitcher.height != expected { problems.append("Höhe \(stitcher.height) statt \(expected)") }
        if stitcher.storedBytes > expected * w * 4 + 64 * frames.count { problems.append("Speicher \(stitcher.storedBytes) B für \(expected) Zeilen") }
        print("  Speicher: \(stitcher.storedBytes / 1024) KB statt \(framesBytes / 1024) KB für \(frames.count) ganze Bilder")

        // 2) Obergrenze: genau bis zur Grenze, danach nichts mehr; Bild stimmt pixelgenau.
        let capped = ScrollStitcher(first: frames[0], maxHeight: 2000)
        for f in frames.dropFirst() { capped.add(f) }
        let more = capped.add(frames.last!)
        if capped.height != 2000 || !capped.limitReached || more { problems.append("Obergrenze: Höhe \(capped.height), erreicht \(capped.limitReached)") }
        if let image = capped.assemble(), image.height == 2000 {
            if pixels(image) != reference(2000) { problems.append("Obergrenze: Bild weicht ab") }
        } else {
            problems.append("Obergrenze: kein Bild")
        }
        print("  Obergrenze \(capped.maxHeight) px: Höhe \(capped.height), weitere Bilder ignoriert: \(!more)")

        // 3) Anhängen im Hintergrund, gleichzeitig Zusammensetzen im Hauptthread — nacheinander, nie gleichzeitig.
        let racing = ScrollStitcher(first: frames[0])
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            for f in frames.dropFirst() { racing.add(f) }
            done.signal()
        }
        var assembled = 0
        while done.wait(timeout: .now()) == .timedOut {
            if let image = racing.assemble(), image.height == racing.height || image.height <= expected { assembled += 1 }
        }
        if let image = racing.assemble(), image.height == expected, pixels(image) == reference(expected) {
            print("  Gleichzeitig: \(assembled)× zusammengesetzt während des Anhängens, Ergebnis pixelgenau")
        } else {
            problems.append("Gleichzeitiges Anhängen/Zusammensetzen: Ergebnis falsch")
        }

        // 4) Sitzungen: Ein Bild, das erst nach „Fertig“ zurückkommt, landet nie in der nächsten Aufnahme;
        //    „Fertig“ wartet auf das laufende Anhängen.
        try wait {
            let ctl = ScrollCaptureController.shared
            let first = ctl.debugBeginSession()
            await ctl.ingest(frames[0], session: first)
            await ctl.ingest(frames[2], session: first)
            let firstImage = await ctl.debugFinish()
            if firstImage?.height != offsets[2] + view { problems.append("Sitzung 1: Höhe \(firstImage?.height ?? 0)") }
            let second = ctl.debugBeginSession()
            await ctl.ingest(frames[5], session: first)   // Nachzügler der alten Sitzung
            if ctl.debugStitcher != nil { problems.append("Bild der alten Sitzung in der neuen gelandet") }
            await ctl.ingest(frames[0], session: second)
            if ctl.debugStitcher?.height != view { problems.append("Sitzung 2 beginnt nicht mit ihrem eigenen Bild") }
            let running = Task { await ctl.ingest(frames[2], session: second) }
            for _ in 0..<500 where !ctl.debugIsIngesting { await Task.yield() }
            let secondImage = await ctl.debugFinish()
            await running.value
            if let secondImage, secondImage.height == offsets[2] + view, pixels(secondImage) == reference(offsets[2] + view) {
                print("  Sitzungen: Nachzügler verworfen, „Fertig“ wartet auf das laufende Anhängen")
            } else {
                problems.append("Sitzung 2: „Fertig“ ohne das zuletzt angehängte Bild (Höhe \(secondImage?.height ?? 0))")
            }
            await ctl.ingest(frames[3], session: second)   // nach „Fertig“
            if ctl.debugStitcher != nil || ctl.active { problems.append("Nach „Fertig“ noch aktiv") }
        }

        if !problems.isEmpty { throw CheckFailed(message: "Scroll-Screenshot: \(problems.joined(separator: ", "))") }
        print("   ✓ Scroll-Screenshot: nur neue Zeilen im Speicher, Obergrenze, nacheinander, Sitzungen getrennt")
    }

    // MARK: Ablage, Beenden, Aufnahme-Zustände (`--selftest robust`)

    static func robust(_ out: URL) throws {
        var problems: [String] = []
        let fm = FileManager.default
        let store = CaptureStore.shared

        // JPEG nur bis 65 535 px je Kante.
        let tall = CGContext(data: nil, width: 8, height: 65_536, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!.makeImage()!
        let jpegFails = tall.encoded(as: .jpeg) == nil, pngWorks = tall.encoded(as: .png) != nil
        if !jpegFails || !pngWorks { problems.append("Annahme JPEG-Grenze stimmt nicht (JPEG scheitert: \(jpegFails), PNG geht: \(pngWorks))") }
        if CaptureStore.format(.jpeg, width: 1400, height: 65_536) != .png || CaptureStore.format(.jpeg, width: 1400, height: 65_535) != .jpeg
            || CaptureStore.format(.png, width: 1400, height: 90_000) != .png {
            problems.append("JPEG über der Grenze wird nicht zu PNG")
        }
        print("  JPEG 8×65 536 scheitert: \(jpegFails), PNG geht: \(pngWorks) → lange Bilder als PNG")

        // Ablageordner nicht erreichbar → Ausweichordner.
        let fallback = out.appendingPathComponent("ausweich", isDirectory: true)
        let missing = URL(fileURLWithPath: "/Volumes/KnipsNichtEingehaengt-\(UUID().uuidString)/Ablage", isDirectory: true)
        let locked = out.appendingPathComponent("gesperrt", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let a = try? CaptureStore.usableFolder(missing, fallback: fallback)
        let b = try? CaptureStore.usableFolder(locked, fallback: fallback)
        let c = try? CaptureStore.usableFolder(fallback, fallback: nil)
        let d = try? CaptureStore.usableFolder(missing, fallback: nil)
        if a?.0 != fallback || a?.1 != true { problems.append("Nicht eingehängt: kein Ausweichordner") }
        if b?.0 != fallback || b?.1 != true { problems.append("Schreibgeschützt: kein Ausweichordner") }
        if c?.0 != fallback || c?.1 != false { problems.append("Erreichbarer Ordner nicht genommen") }
        if d != nil { problems.append("Ohne Ausweichordner kein Fehler") }
        print("  Ablage: nicht eingehängt → Ausweichordner, schreibgeschützt → Ausweichordner, ohne Ausweichordner → Fehler")

        try wait {
            // Schreibfehler werden gemeldet, nicht verschluckt.
            let item = try store.addImage(sampleImage(), scale: 2)
            await store.waitUntilWritten(item.id)
            let dir = store.directory(for: item)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            store.debugWriteFailures.removeAll()
            store.saveImage(sampleImage(), document: ImageDocument(), for: item)
            await store.waitUntilWritten(item.id)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            if store.debugWriteFailures != ["Änderungen konnten nicht gespeichert werden"] {
                problems.append("Schreibfehler nicht gemeldet: \(store.debugWriteFailures)")
            }
            print("  Schreibfehler gemeldet: \(store.debugWriteFailures)")

            // Abgelaufene Originale verschwinden auch ohne Neustart.
            store.purgeExpired(now: Date().addingTimeInterval(31 * 24 * 3600), days: 30)
            let gone = await until(2) { !fm.fileExists(atPath: dir.path) }
            if store.item(with: item.id) != nil || !gone { problems.append("Abgelaufene Aufnahme nicht entfernt") }

            // Reste im Temp-Ordner: alt → weg, frisch (laufende Aufnahme) → bleibt.
            let temp = out.appendingPathComponent("tmp", isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            let old = temp.appendingPathComponent("aufnahme-alt.mp4"), fresh = temp.appendingPathComponent("aufnahme-laeuft.mp4")
            try Data([1, 2, 3]).write(to: old)
            try Data([1, 2, 3]).write(to: fresh)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
            CaptureStore.cleanTemp(in: temp)
            if fm.fileExists(atPath: old.path) || !fm.fileExists(atPath: fresh.path) { problems.append("Temp-Ordner falsch aufgeräumt") }
            print("  Aufräumen: abgelaufene Aufnahme entfernt: \(gone), alter Temp-Rest weg, laufende Aufnahme bleibt")

            // Beenden wartet auf laufende Schreibvorgänge.
            let big = sampleImage(width: 3840, height: 2160, scale: 2)
            let pending = try store.addImage(big, scale: 2)
            let wasPending = store.hasPendingWrites
            await QuitGuard.finish()
            let written = fm.fileExists(atPath: pending.fileURL.path) && fm.fileExists(atPath: store.originalURL(for: pending).path)
            if !wasPending || store.hasPendingWrites || !written { problems.append("Beenden wartet nicht auf Schreibvorgänge") }
            var calls = 0
            QuitGuard.finish(timeout: 0.3) { calls += 1 }
            try await Task.sleep(nanoseconds: 600_000_000)
            if calls != 1 { problems.append("Beenden meldet \(calls)× statt einmal") }
            print("  Beenden: Schreibvorgang lief: \(wasPending), danach geschrieben: \(written), Rückmeldung genau einmal: \(calls == 1)")

            try await recordingStates(&problems)
        }

        if !problems.isEmpty { throw CheckFailed(message: problems.joined(separator: "; ")) }
        print("   ✓ Ablage, Beenden und Aufnahme-Zustände")
    }

    /// Aufnahme-Ablauf mit einer Attrappe — nimmt nie den Bildschirm auf und zeigt keine Fenster.
    private static func recordingStates(_ problems: inout [String]) async throws {
        let rc = RecordingController.shared
        var errors: [String] = []
        let previous = rc.onError
        rc.onError = { title, _, _ in errors.append(title) }
        defer { rc.onError = previous }
        func run(_ session: FakeRecordingSession, countdown: Bool = false) {
            rc.run(session, screen: nil, global: CGRect(x: 0, y: 0, width: 400, height: 300), isFull: true, countdown: countdown, showsWindows: false)
        }

        // Start dauert: gilt schon als belegt, ein zweiter Start wird abgewiesen.
        let slow = FakeRecordingSession(startDelay: 0.4), second = FakeRecordingSession()
        run(slow)
        let busyWhileStarting = rc.phase == .starting && rc.isBusy
        run(second)
        // Abbruch, während der Recorder startet: Er wird nach dem Start sofort wieder beendet.
        _ = await until(2) { slow.starting }
        rc.stop(save: true)
        _ = await until(2) { slow.started }
        try await Task.sleep(nanoseconds: 100_000_000)
        if !busyWhileStarting || second.started || !slow.cancelled || rc.phase != .idle {
            problems.append("Start: belegt \(busyWhileStarting), zweiter gestartet \(second.started), abgebrochen \(slow.cancelled), Phase \(rc.phase)")
        }
        print("  Start: belegt während des Starts, zweiter Start abgewiesen, Abbruch beendet den Recorder")

        // Abbruch im Countdown: Recorder startet gar nicht.
        let counted = FakeRecordingSession()
        run(counted, countdown: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let inCountdown = rc.phase == .countdown(3)
        rc.stop(save: false)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        if !inCountdown || counted.started || rc.phase != .idle { problems.append("Countdown-Abbruch: gestartet \(counted.started), Phase \(rc.phase)") }

        // Writer-Fehler (Platte voll): sofort beenden, Datei verwerfen, Meldung.
        let failing = FakeRecordingSession()
        run(failing)
        _ = await until(2) { rc.phase == .recording }
        rc.debugWriterFailed(CocoaError(.fileWriteOutOfSpace))
        _ = await until(2) { rc.phase == .idle }
        if !failing.cancelled || rc.phase != .idle || errors.last != "Aufnahme abgebrochen" {
            problems.append("Writer-Fehler: verworfen \(failing.cancelled), Phase \(rc.phase), Meldung \(errors)")
        }
        print("  Writer-Fehler: Aufnahme beendet, Datei verworfen, Meldung „\(errors.last ?? "–")“")

        // Beenden während der Aufnahme: Stoppen und Speichern wird abgewartet.
        let quitting = FakeRecordingSession()
        run(quitting)
        _ = await until(2) { rc.phase == .recording }
        await QuitGuard.finish()
        if !quitting.stopped || rc.phase != .idle { problems.append("Beenden: gestoppt \(quitting.stopped), Phase \(rc.phase)") }
        print("  Beenden während der Aufnahme: gestoppt \(quitting.stopped), danach frei: \(rc.phase == .idle)")
    }
}

/// Aufnahme-Attrappe für Selbsttests: kein Bildschirm, keine Datei. Der Start lässt sich nicht abbrechen,
/// genau wie bei ScreenCaptureKit.
final class FakeRecordingSession: RecordingSession, @unchecked Sendable {
    let url = Paths.temp.appendingPathComponent("attrappe-\(UUID().uuidString).mp4")
    let startDelay: Double
    private(set) var starting = false
    private(set) var started = false
    private(set) var stopped = false
    private(set) var cancelled = false

    init(startDelay: Double = 0) { self.startDelay = startDelay }

    func start() async throws {
        starting = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) { done.resume() }
        }
        started = true
    }

    func stop() async throws -> Double {
        stopped = true
        throw ScreenRecorder.RecorderError.noFrames
    }

    func cancel() async { cancelled = true }
}
#endif
