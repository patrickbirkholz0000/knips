import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import Vision

/// `Knips --selftest <test> <ausgabeordner>` — prüft Renderer, Erkennung, UI und Video ohne
/// den Bildschirm zu übernehmen. Läuft isoliert in `<ausgabeordner>/sandbox`.
@MainActor enum SelfTest {
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 2 else {
            print("Aufruf: --selftest render|detect|ui|selection|video|capture|record <ordner>")
            return 2
        }
        let out = URL(fileURLWithPath: args[1], isDirectory: true)
        Paths.ensure(out)
        setenv("KNIPS_TEST_DIR", out.appendingPathComponent("sandbox").path, 1)
        do {
            switch args[0] {
            case "render": try render(out)
            case "detect": detect(out)
            case "ui": try runAsync { try await ui(out) }
            case "selection": try selection(out)
            case "live":
                NSApp.setActivationPolicy(.accessory)
                try runAsync { try await live(out) }
            case "menu":
                NSApp.setActivationPolicy(.accessory)
                try runAsync { try await menu(out) }
            case "settings":
                NSApp.setActivationPolicy(.accessory)
                try runAsync { try await settings(out, panes: args.count > 2 ? args[2].split(separator: ",").compactMap { SettingsPane(rawValue: String($0)) } : SettingsPane.allCases) }
            case "video": try runAsync { try await video(out) }
            case "capture": try runAsync { try await capture() }
            case "output": try runAsync { try await output(out) }
            case "shortcut-roundtrip":
                // Schaltet ⌃⌘⇧3 (ID 29) kurz ab und wieder ein — prüft den Übernahme-Mechanismus.
                func state() -> String {
                    let d = (CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any])?["29"] as? [String: Any]
                    return "\(d?["enabled"] ?? "fehlt")"
                }
                print("vorher: \(state())")
                SystemShortcuts.takeOver([29])
                CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
                print("abgeschaltet: \(state()) · übernommen=\(SystemShortcuts.hasTakenOver)")
                SystemShortcuts.restore()
                print("wiederhergestellt: \(state()) · übernommen=\(SystemShortcuts.hasTakenOver)")
            case "perf":
                NSApp.setActivationPolicy(.accessory)
                try runAsync { try await perf(out) }
            case "record": try runAsync { try await record(out, seconds: Double(args.count > 2 ? args[2] : "3") ?? 3) }
            case "record-bench": try runAsync { try await recordBench(out) }
            default:
                print("Unbekannter Test \(args[0])")
                return 2
            }
            print("OK")
            return 0
        } catch {
            print("FEHLER: \(error.localizedDescription)")
            return 1
        }
    }

    private static func runAsync(_ body: @escaping @MainActor () async throws -> Void) throws {
        var result: Result<Void, Error>?
        Task { @MainActor in
            do { try await body(); result = .success(()) } catch { result = .failure(error) }
        }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        try result!.get()
    }

    // MARK: Testbild

    /// Nachgebautes App-Fenster mit typischen sensiblen Daten (alle fiktiv).
    static func sampleImage(width: Int = 1400, height: Int = 880, scale: CGFloat = 2) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let W = CGFloat(width), H = CGFloat(height)
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(CGColor(srgbRed: 0.84, green: 0.85, blue: 0.88, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: 34 * scale))
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: CGRect(x: (14 + CGFloat(i) * 20) * scale, y: 11 * scale, width: 12 * scale, height: 12 * scale))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.22, blue: 0.27, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 34 * scale, width: 170 * scale, height: H - 34 * scale))
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 14, weight: NSFont.Weight = .regular, color: NSColor = .black) {
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size * scale, weight: weight), .foregroundColor: color])
                .draw(at: CGPoint(x: x * scale, y: y * scale))
        }
        for (i, s) in ["Übersicht", "Kunden", "Rechnungen", "Einstellungen"].enumerated() {
            text(s, 18, 56 + CGFloat(i) * 30, size: 13, weight: .medium, color: .white)
        }
        text("Kundendaten", 196, 52, size: 22, weight: .bold)
        text("Name: Erika Mustermann", 196, 96)
        text("E-Mail: erika.mustermann@example.com", 196, 124)
        text("Telefon: +49 170 1234567", 196, 152)
        text("IBAN: DE89 3704 0044 0532 0130 00", 196, 180)
        text("Stripe-Key: sk_live_KnipsBeispiel42", 196, 208, size: 13, color: .darkGray)
        text("Bestellung #48213 wurde am 03.10. versendet und ist unterwegs.", 196, 252)
        text("Hinweis: Lieferzeit 2–3 Werktage, Sendungsverfolgung folgt per Mail.", 196, 280, color: .darkGray)
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 196 * scale, y: 318 * scale, width: 140 * scale, height: 30 * scale),
                           cornerWidth: 7 * scale, cornerHeight: 7 * scale, transform: nil))
        ctx.fillPath()
        text("Speichern", 232, 324, size: 13, weight: .semibold, color: .white)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private static func write(_ image: CGImage, _ url: URL) throws {
        guard let data = image.pngData() else { throw CaptureStore.StoreError.encode }
        try data.write(to: url)
        print("→ \(url.path) (\(image.width)×\(image.height))")
    }

    // MARK: Renderer

    static func render(_ out: URL) throws {
        let base = sampleImage()
        let scale: CGFloat = 2
        var doc = ImageDocument()
        func a(_ kind: AnnotationKind, _ s: CGPoint, _ e: CGPoint, color: RGBA = .red, size: StrokeSize = .medium) -> Annotation {
            Annotation(kind: kind, start: s, end: e, color: color, size: size)
        }
        doc.annotations.append(a(.arrow, CGPoint(x: 1260, y: 120), CGPoint(x: 1040, y: 230)))
        doc.annotations.append(a(.rectangle, CGPoint(x: 380, y: 490), CGPoint(x: 1300, y: 580), color: .blue))
        doc.annotations.append(a(.ellipse, CGPoint(x: 380, y: 620), CGPoint(x: 700, y: 720), color: .green, size: .small))
        doc.annotations.append(a(.line, CGPoint(x: 760, y: 680), CGPoint(x: 1200, y: 760), color: .purple, size: .large))
        doc.annotations.append(a(.highlight, CGPoint(x: 386, y: 500), CGPoint(x: 900, y: 532), color: .yellow))
        var counter = a(.counter, CGPoint(x: 360, y: 200), .zero); counter.number = 1
        var counter2 = a(.counter, CGPoint(x: 360, y: 256), .zero, color: .orange); counter2.number = 2
        doc.annotations += [counter, counter2]
        var t = a(.text, CGPoint(x: 820, y: 640), .zero, color: .red, size: .large); t.text = "Hier klicken!"
        doc.annotations.append(t)
        var r1 = a(.redact, CGPoint(x: 520, y: 236), CGPoint(x: 1130, y: 272)); r1.redactStyle = .pixelate
        var r2 = a(.redact, CGPoint(x: 498, y: 348), CGPoint(x: 1010, y: 384)); r2.redactStyle = .blur
        var r3 = a(.redact, CGPoint(x: 600, y: 404), CGPoint(x: 1300, y: 440)); r3.redactStyle = .solid
        doc.annotations += [r1, r2, r3]
        let effects = EffectsCache(base: base, scale: scale)
        try write(base, out.appendingPathComponent("render-original.png"))
        guard let full = Renderer.render(base: base, document: doc, scale: scale, effects: effects) else { throw CaptureStore.StoreError.encode }
        try write(full, out.appendingPathComponent("render-annotiert.png"))
        doc.crop = CGRect(x: 340, y: 60, width: 1000, height: 420)
        guard let cropped = Renderer.render(base: base, document: doc, scale: scale, effects: effects) else { throw CaptureStore.StoreError.encode }
        try write(cropped, out.appendingPathComponent("render-zugeschnitten.png"))
        guard cropped.width == 1000, cropped.height == 420 else { throw CaptureError.noDisplay }
    }

    static func detect(_ out: URL) {
        let base = sampleImage()
        let findings = SensitiveDetector.detectSync(in: base)
        for f in findings { print("  \(f.kind.title): \(f.text) @ \(Int(f.rect.minX)),\(Int(f.rect.minY)) \(Int(f.rect.width))×\(Int(f.rect.height))") }
        var doc = ImageDocument()
        for f in findings {
            var a = Annotation(kind: .redact, start: f.rect.origin, end: CGPoint(x: f.rect.maxX, y: f.rect.maxY))
            a.redactStyle = .pixelate
            doc.annotations.append(a)
        }
        if let img = Renderer.render(base: base, document: doc, scale: 2, effects: EffectsCache(base: base, scale: 2)) {
            try? write(img, out.appendingPathComponent("auto-zensur.png"))
        }
        // Großes Bild (wird für die Erkennung verkleinert): Fundstellen müssen genau doppelt so groß sein.
        let big = sampleImage(width: 2800, height: 1760, scale: 4)
        let bigFindings = SensitiveDetector.detectSync(in: big)
        for f in bigFindings { print("  2×: \(f.kind.title) @ \(Int(f.rect.minX)),\(Int(f.rect.minY)) \(Int(f.rect.width))×\(Int(f.rect.height))") }
        if let big = Renderer.render(base: big, document: ImageDocument(annotations: bigFindings.map {
            var a = Annotation(kind: .redact, start: $0.rect.origin, end: CGPoint(x: $0.rect.maxX, y: $0.rect.maxY))
            a.redactStyle = .solid
            return a
        }), scale: 4, effects: EffectsCache(base: big, scale: 4)) {
            try? write(ImageIOHelper.downscale(big, maxPixel: 1400), out.appendingPathComponent("auto-zensur-gross.png"))
        }
        let kinds = Set(findings.map(\.kind))
        print("Gefunden: \(findings.count) — Arten: \(kinds.map(\.title).sorted().joined(separator: ", "))")
        // Muster ohne OCR
        let samples = ["kontakt@example.com", "DE89 3704 0044 0532 0130 00", "4111 1111 1111 1111", "ghp_abcdefghijklmnopqrstuvwxyz123456",
                       "Bestellung 48213 versendet", "0170 1234567", "192.168.178.1", "Passwort: hunter22"]
        for s in samples { print("  „\(s)“ → \(SensitiveDetector.matches(in: s).map(\.0.title))") }
    }

    // MARK: UI

    private static func snapshot(_ view: NSView, _ url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureStore.StoreError.encode }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { throw CaptureStore.StoreError.encode }
        try write(cg, url)
    }

    static func ui(_ out: URL) async throws {
        let store = CaptureStore.shared
        let image = sampleImage()
        let item = try store.addImage(image, scale: 2)
        var doc = ImageDocument()
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 1200, y: 100), end: CGPoint(x: 1000, y: 220))
        arrow.size = .medium
        var red = Annotation(kind: .redact, start: CGPoint(x: 520, y: 236), end: CGPoint(x: 1130, y: 272))
        red.redactStyle = .pixelate
        doc.annotations = [arrow, red]

        // Editor
        let editor = EditorWindowController(item: item, base: image, document: doc, tool: .redact)
        editor.model.selectedID = red.id
        let window = editor.window!
        window.setContentSize(NSSize(width: 1120, height: 620))
        window.contentView?.layoutSubtreeIfNeeded()
        try snapshot(window.contentView!, out.appendingPathComponent("ui-editor.png"))
        editor.model.startCrop()
        window.contentView?.layoutSubtreeIfNeeded()
        try snapshot(window.contentView!, out.appendingPathComponent("ui-editor-zuschneiden.png"))

        // Quick-Access-Karten
        let rendered = Renderer.render(base: image, document: doc, scale: 2, effects: EffectsCache(base: image, scale: 2))!
        let saved = store.saveImage(rendered, document: doc, for: item)
        await store.waitUntilWritten(item.id)
        let second = try store.addImage(sampleImage(width: 900, height: 1200), scale: 2)
        var video = second
        video.kind = .video
        video.duration = 14
        let model = QuickAccessModel()
        model.cards = [video, saved]
        model.hovered = saved.id
        let root = QuickAccessRoot(model: model, actions: QuickAccessController.shared.actions)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: QuickAccessController.panelSize(cards: 2))
        host.appearance = NSAppearance(named: .darkAqua)
        let backdrop = NSView(frame: host.frame)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(srgbRed: 0.35, green: 0.42, blue: 0.55, alpha: 1).cgColor
        backdrop.addSubview(host)
        let panelWindow = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panelWindow.contentView = backdrop
        try snapshot(backdrop, out.appendingPathComponent("ui-karten.png"))

    }

    static func selection(_ out: URL) throws {
        guard let screen = NSScreen.main else { throw CaptureError.noDisplay }
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let img = sampleImage(width: Int(size.width * scale), height: Int(size.height * scale), scale: scale)
        let frozen = FrozenScreen(screen: screen, display: nil, image: img)
        let windows = [WindowInfo(windowID: 1, frame: CGRect(x: screen.frame.minX + 420, y: screen.frame.minY + 300, width: 700, height: 420),
                                  owner: "Test", title: "Fenster")]
        for (name, windowMode) in [("bereich", false), ("fenster", true)] {
            let overlay = SelectionOverlay(screens: [screen], windows: windows, purpose: .screenshot, windowMode: windowMode) { _ in }
            let view = SelectionView(screen: screen, overlay: overlay, image: frozen.image)
            view.frame = NSRect(origin: .zero, size: size)
            overlay.mouseMoved(to: CGPoint(x: screen.frame.minX + 700, y: screen.frame.minY + 520))
            if !windowMode { view.debugSelect(CGRect(x: 300, y: 380, width: 640, height: 300)) }
            view.layout()
            view.refresh()
            try renderLayer(view.layer!, size: size, scale: scale, url: out.appendingPathComponent("ui-auswahl-\(name).png"))
        }
    }

    private static func renderLayer(_ layer: CALayer, size: CGSize, scale: CGFloat, url: URL) throws {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        try write(ctx.makeImage()!, url)
    }

    // MARK: Video

    static func makeSampleVideo(_ url: URL, seconds: Int = 3, fps: Int = 30, hevc: Bool = false) async throws -> CGRect {
        try? FileManager.default.removeItem(at: url)
        let w = 1280, h = 720
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let emailRect = CGRect(x: 120, y: 300, width: 640, height: 50)
        for i in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(NSColor.systemBlue.cgColor)
            ctx.fill(CGRect(x: 100 + i * 8, y: 520, width: 120, height: 80))
            NSAttributedString(string: "Frame \(i)", attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .bold)]).draw(at: CGPoint(x: 120, y: 120))
            NSAttributedString(string: "Mail: max.muster@example.org", attributes: [.font: NSFont.systemFont(ofSize: 34)]).draw(at: CGPoint(x: 124, y: 304))
            NSGraphicsContext.restoreGraphicsState()
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return emailRect
    }

    static func video(_ out: URL) async throws {
        let src = out.appendingPathComponent("video-original.mp4")
        let emailRect = try await makeSampleVideo(src)
        let asset = AVURLAsset(url: src)
        let state = RedactionState(scale: 1)
        state.set([VideoRedaction(rect: emailRect, start: 0.5, end: 2.5, style: .pixelate)])
        let range = CMTimeRange(start: CMTime(seconds: 0.2, preferredTimescale: 600), end: CMTime(seconds: 2.8, preferredTimescale: 600))
        let exported = out.appendingPathComponent("video-zensiert.mp4")
        try await VideoRedactor.exportMP4(asset: asset, state: state, range: range, to: exported) { _ in }
        let exportedAsset = AVURLAsset(url: exported)
        let duration = try await exportedAsset.load(.duration).seconds
        print("Export-Dauer: \(String(format: "%.2f", duration)) s (erwartet ≈ 2,6 s)")
        let gen = AVAssetImageGenerator(asset: exportedAsset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        // Exportzeit 1,3 s = Quellzeit 1,5 s (zensiert), Exportzeit 0,1 s = Quelle 0,3 s (noch nicht zensiert)
        try write(try await gen.image(at: CMTime(seconds: 1.3, preferredTimescale: 600)).image, out.appendingPathComponent("video-frame-zensiert.png"))
        try write(try await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image, out.appendingPathComponent("video-frame-vorher.png"))

        let gif = out.appendingPathComponent("video.gif")
        let size = try await VideoRedactor.exportGIF(asset: asset, state: state, range: range, fps: 10, width: 640, to: gif) { _ in }
        let frames = CGImageSourceGetCount(CGImageSourceCreateWithURL(gif as CFURL, nil)!)
        print("GIF: \(Int(size.width))×\(Int(size.height)), \(frames) Bilder")

        let found = try await VideoRedactor.detect(asset: asset, range: CMTimeRange(start: .zero, duration: try await asset.load(.duration)),
                                                   step: 0.5, style: .pixelate) { _ in }
        for r in found {
            print("Auto: \(Int(r.rect.minX)),\(Int(r.rect.minY)) \(Int(r.rect.width))×\(Int(r.rect.height)) von \(String(format: "%.1f", r.start)) bis \(String(format: "%.1f", r.end)) s")
        }
        guard !found.isEmpty else { throw CaptureError.noDisplay }

        // HEVC-Quelle bleibt beim Zensur-Export HEVC
        let hevcSource = out.appendingPathComponent("video-hevc.mp4")
        _ = try await makeSampleVideo(hevcSource, hevc: true)
        let hevcOut = out.appendingPathComponent("video-hevc-zensiert.mp4")
        try await VideoRedactor.exportMP4(asset: AVURLAsset(url: hevcSource), state: state, range: range, to: hevcOut) { _ in }
        func codec(_ url: URL) async -> String {
            guard let fd = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.formatDescriptions).first else { return "?" }
            let c = CMFormatDescriptionGetMediaSubType(fd)
            return String(bytes: [UInt8(c >> 24 & 255), UInt8(c >> 16 & 255), UInt8(c >> 8 & 255), UInt8(c & 255)], encoding: .ascii) ?? "?"
        }
        print("Codec: H.264-Export \(await codec(exported)) · HEVC-Export \(await codec(hevcOut))")
    }

    // MARK: Live-Fenster (nur eigene Fenster, abseits des sichtbaren Bereichs)

    private static func windowShot(_ window: NSWindow, _ url: URL) async throws {
        let size = window.frame.size
        // ScreenCaptureKit nimmt nur Fenster, die einen Bildschirm berühren — 1 pt Überlappung
        // in der äußersten Ecke reicht, der Rest liegt unsichtbar daneben.
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        let origin = NSPoint(x: minX - size.width + 1, y: minY - size.height + 1)
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        window.setFrameOrigin(origin)
        try await Task.sleep(nanoseconds: 900_000_000)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scw = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw CaptureError.windowGone }
        let config = SCStreamConfiguration()
        config.width = Int(size.width * 2)
        config.height = Int(size.height * 2)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: config)
        try write(image, url)
        print("   Fensterposition: \(window.frame.origin)")
    }

    static func menu(_ out: URL) async throws {
        let store = CaptureStore.shared
        for (w, h) in [(1400, 880), (900, 1200), (1600, 700)] {
            let item = try store.addImage(sampleImage(width: w, height: h), scale: 2)
            await store.waitUntilWritten(item.id)
        }
        let model = MenuPanelModel()
        model.recent = Array(store.recent.prefix(4))
        let view = MenuHostingView(rootView: MenuPanelView(model: model, actions: MenuActions(
            capture: { _ in }, openImage: {}, openFolder: {}, openRecent: { _ in }, settings: {}, quit: {})))
        view.model = model
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        try await windowShot(window, out.appendingPathComponent("menu.png"))
        model.hovered = "full"
        try await windowShot(window, out.appendingPathComponent("menu-hover.png"))
        print("   Panelgröße \(Int(size.width))×\(Int(size.height)), Hover-Flächen: \(model.frames.keys.sorted().joined(separator: ", "))")
        window.orderOut(nil)
    }

    static func settings(_ out: URL, panes: [SettingsPane]) async throws {
        let controller = SettingsWindowController()
        let window = controller.window!
        for pane in panes {
            SettingsNavigation.shared.pane = pane
            try await windowShot(window, out.appendingPathComponent("einstellungen-\(pane.rawValue).png"))
            if pane == .shortcuts {
                HotkeyRecorderState.shared.recording = .captureArea
                try await windowShot(window, out.appendingPathComponent("einstellungen-shortcuts-eingabe.png"))
                HotkeyRecorderState.shared.recording = nil
            }
        }
        window.orderOut(nil)
    }

    static func live(_ out: URL) async throws {
        let store = CaptureStore.shared
        let image = sampleImage()
        let item = try store.addImage(image, scale: 2)
        var doc = ImageDocument()
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 1200, y: 100), end: CGPoint(x: 1000, y: 220))
        var red = Annotation(kind: .redact, start: CGPoint(x: 470, y: 250), end: CGPoint(x: 890, y: 286))
        red.redactStyle = .pixelate
        doc.annotations = [arrow, red]
        let editor = EditorWindowController(item: item, base: image, document: doc, tool: .redact)
        editor.model.selectedID = red.id
        editor.window?.setContentSize(NSSize(width: 1180, height: 640))
        try await windowShot(editor.window!, out.appendingPathComponent("live-editor.png"))
        // Zoom: 100 % und 250 % um die E-Mail-Zeile
        editor.canvas.zoomActualSize()
        try await windowShot(editor.window!, out.appendingPathComponent("live-editor-zoom100.png"))
        editor.canvas.zoomIn(); editor.canvas.zoomIn(); editor.canvas.zoomIn(); editor.canvas.zoomIn()
        print("   Zoom jetzt \(editor.model.zoomPercent) %")
        try await windowShot(editor.window!, out.appendingPathComponent("live-editor-zoom250.png"))
        editor.canvas.zoomToFit()

        // Schlaue Balken: Klick auf Zeile, ⌥-Klick auf Wort, angeschnittenes Ziehen
        await editor.model.waitForText()
        print("   Textzeilen erkannt: \(editor.model.textLines.count)")
        var smart: [Annotation] = []
        for (point, word) in [(CGPoint(x: 600, y: 320), false), (CGPoint(x: 560, y: 375), true)] {
            if let r = editor.model.textTarget(at: point, word: word) {
                var a = Annotation(kind: .redact, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY))
                a.redactStyle = .solid
                smart.append(a)
                print("   \(word ? "Wort" : "Zeile") bei \(Int(point.x)),\(Int(point.y)) → \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))")
            }
        }
        let drawn = CGRect(x: 640, y: 425, width: 180, height: 14)   // schneidet den Stripe-Key nur an
        let snapped = editor.model.snappedRedaction(drawn)
        print("   Gezogen \(Int(drawn.width))×\(Int(drawn.height)) → angepasst \(Int(snapped.minX)),\(Int(snapped.minY)) \(Int(snapped.width))×\(Int(snapped.height))")
        var cut = Annotation(kind: .redact, start: snapped.origin, end: CGPoint(x: snapped.maxX, y: snapped.maxY))
        cut.redactStyle = .solid
        smart.append(cut)
        editor.model.annotations = smart
        try await windowShot(editor.window!, out.appendingPathComponent("live-editor-schlaue-balken.png"))
        print("   Sichtbarer Text ohne Zensur:\n" + editor.model.visibleText().split(separator: "\n").map { "     | " + $0 }.joined(separator: "\n"))
        editor.model.selectedID = nil
        editor.model.tool = .arrow
        try await windowShot(editor.window!, out.appendingPathComponent("live-editor-pfeil.png"))
        editor.model.startCrop()
        try await windowShot(editor.window!, out.appendingPathComponent("live-editor-zuschneiden.png"))
        editor.window?.orderOut(nil)

        let src = out.appendingPathComponent("live-video.mp4")
        let emailRect = try await makeSampleVideo(src)
        let videoItem = try await store.addVideo(from: src, scale: 1)
        let model = try await VideoEditorModel.load(videoItem)
        model.addRedaction(rect: emailRect)
        model.setTrim(start: 0.4, end: 2.6)
        model.seek(to: 1.5)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let videoEditor = VideoEditorWindowController(model: model)
        videoEditor.window?.setContentSize(NSSize(width: 1180, height: 760))
        try await windowShot(videoEditor.window!, out.appendingPathComponent("live-video-editor.png"))
        videoEditor.window?.orderOut(nil)
        model.shutdown()
    }

    // MARK: Zeitmessung (echtes Bildschirmfoto nur im Speicher, Ausgabe nur Zeiten)

    private static func ms(_ start: CFAbsoluteTime) -> String { String(format: "%6.0f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000) }

    static func perf(_ out: URL) async throws {
        var t = CFAbsoluteTimeGetCurrent()
        let content = try await ScreenCapture.content()
        print("SCShareableContent           \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        let frozen = try await ScreenCapture.freeze(NSScreen.screens, content: content)
        print("Einfrieren (\(frozen.count) Bildschirme)   \(ms(t))")
        if #available(macOS 15.2, *) {
            t = CFAbsoluteTimeGetCurrent()
            _ = try await SCScreenshotManager.captureImage(in: NSScreen.screens[0].frame.cocoaToQuartz)
            print("captureImage(in:) 1 Bildschirm \(ms(t))")
        }
        guard let image = frozen.first?.image else { return }
        t = CFAbsoluteTimeGetCurrent()
        let crop = ScreenCapture.crop(frozen[0], localRect: CGRect(x: 200, y: 200, width: 1200, height: 700))!
        print("Zuschneiden                  \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        let png = image.pngData()!
        print("PNG 4K kodieren              \(ms(t))  (\(png.count / 1024) KB)")
        t = CFAbsoluteTimeGetCurrent()
        _ = crop.pngData()
        print("PNG Ausschnitt 2400×1400     \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        _ = ImageIOHelper.downscale(image, maxPixel: 640)
        print("Vorschaubild 640             \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        _ = NSBitmapImageRep(cgImage: image).tiffRepresentation
        print("TIFF 4K                      \(ms(t))")

        var doc = ImageDocument()
        var a = Annotation(kind: .redact, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 900, y: 300))
        a.redactStyle = .pixelate
        doc.annotations = [a]
        t = CFAbsoluteTimeGetCurrent()
        let effects = EffectsCache(base: image, scale: 2)
        _ = Renderer.render(base: image, document: doc, scale: 2, effects: effects)
        print("Rendern 4K mit Verpixeln     \(ms(t))")
        a.redactStyle = .solid
        doc.annotations = [a]
        t = CFAbsoluteTimeGetCurrent()
        _ = Renderer.render(base: image, document: doc, scale: 2, effects: EffectsCache(base: image, scale: 2))
        print("Rendern 4K mit Balken        \(ms(t))")

        for run in ["kalt", "warm"] {
            t = CFAbsoluteTimeGetCurrent()
            let found = SensitiveDetector.detectSync(in: image)
            print("Auto-Zensur 4K (\(run))        \(ms(t))  (\(found.count) Funde)")
        }
        t = CFAbsoluteTimeGetCurrent()
        NSApp.setActivationPolicy(.regular)
        print("Aktivierung → regular        \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        NSApp.setActivationPolicy(.accessory)
        print("Aktivierung → accessory      \(ms(t))")

        let item = try CaptureStore.shared.addImage(crop, scale: 2)
        t = CFAbsoluteTimeGetCurrent()
        let editor = EditorWindowController(item: item, base: crop, document: ImageDocument(), tool: .redact)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        print("Editor-Fenster 1. Mal        \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        let editor2 = EditorWindowController(item: item, base: crop, document: ImageDocument(), tool: .redact)
        editor2.window?.contentView?.layoutSubtreeIfNeeded()
        print("Editor-Fenster 2. Mal        \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        let promise = AppSettings.shared.outputPromise(sourceScale: 2) { image }
        let item2 = try CaptureStore.shared.addImage(image, scale: 2, output: promise)
        print("Aufnahme anlegen             \(ms(t))  (Hauptthread, 4K)")
        t = CFAbsoluteTimeGetCurrent()
        await CaptureStore.shared.waitUntilWritten(item2.id)
        print("  … Hintergrund fertig nach  \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        let settings = SettingsWindowController()
        settings.window?.contentView?.layoutSubtreeIfNeeded()
        print("Einstellungen erzeugen       \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        _ = SystemShortcuts.conflict(for: KeyCombo(keyCode: 21, modifiers: 768))
        print("Konfliktprüfung 1 Kürzel     \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        for style in RedactStyle.allCases { _ = RedactPreview.image(for: style) }
        print("Zensur-Vorschaubilder        \(ms(t))")
    }

    // MARK: Ausgabegröße

    static func output(_ out: URL) async throws {
        let store = CaptureStore.shared
        let image = sampleImage(width: 2800, height: 1760, scale: 4)   // „Retina“-Screenshot, 2 px pro Punkt
        func describe(_ url: URL) -> String {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let dims = ImageIOHelper.load(url).map { "\($0.width)×\($0.height)" } ?? "?"
            return "\(url.pathExtension.uppercased()) \(dims), \(size / 1024) KB"
        }
        for format in ImageFormat.allCases {
            let promise = AppSettings.shared.outputPromise(sourceScale: 2, format: format) { image }
            let item = try store.addImage(image, scale: 2, output: promise)
            await store.waitUntilWritten(item.id)
            print("\(format.rawValue): Ablage \(describe(item.fileURL)) · Original \(describe(store.originalURL(for: item))) · Anzeige-Faktor \(item.displayScale)")
        }
        // Editor: Zensur + Speichern über den normalen Weg
        let item = try store.addImage(image, scale: 2)
        await store.waitUntilWritten(item.id)
        let editor = EditorWindowController(item: item, base: image, document: ImageDocument(), tool: .redact)
        var bar = Annotation(kind: .redact, start: CGPoint(x: 900, y: 480), end: CGPoint(x: 1800, y: 560))
        bar.redactStyle = .solid
        editor.model.checkpoint()
        editor.model.annotations = [bar]
        editor.save(close: false)
        await store.waitUntilWritten(item.id)
        let saved = store.item(with: item.id)!
        print("Editor gespeichert: \(describe(saved.fileURL)) · Original \(describe(store.originalURL(for: saved))) · Dokument \(store.loadImageDocument(for: saved).annotations.count) Balken")
        if let img = ImageIOHelper.load(saved.fileURL) { try write(img, out.appendingPathComponent("ausgabe-editor.png")) }
    }

    // MARK: Echte Aufnahme (nur Metadaten, keine Bildinhalte)

    static func capture() async throws {
        let content = try await ScreenCapture.content()
        let frozen = try await ScreenCapture.freeze(NSScreen.screens, content: content)
        for f in frozen { print("Bildschirm \(f.screen.localizedName): \(f.image.width)×\(f.image.height) px, Faktor \(f.scale)") }
        print("Fenster erkannt: \(ScreenCapture.windows().count)")
    }

    /// Vollbild-Aufnahmen in vier Varianten: nur Größe, Dauer und Rechenzeit, Dateien werden gelöscht.
    static func recordBench(_ out: URL) async throws {
        let content = try await ScreenCapture.content()
        guard let screen = NSScreen.main, let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.noDisplay }
        func cpu() -> Double {
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        let rect = CGRect(origin: .zero, size: screen.frame.size)
        for (name, factor, hevc) in [("Retina 2×, H.264", 2.0, false), ("Bildschirm 1×, H.264", 1.0, false),
                                     ("Bildschirm 1×, HEVC", 1.0, true), ("Retina 2×, HEVC", 2.0, true)] {
            let url = out.appendingPathComponent("bench.mp4")
            let recorder = ScreenRecorder(url: url)
            let size = CGSize(width: (rect.width * factor / 2).rounded(.down) * 2, height: (rect.height * factor / 2).rounded(.down) * 2)
            let c0 = cpu()
            try await recorder.start(.init(display: display, sourceRect: rect, pixelSize: size, excludedApps: [], fps: 30,
                                           showsCursor: true, microphone: false, hevc: hevc))
            try await Task.sleep(nanoseconds: 4_000_000_000)
            _ = try await recorder.stop()
            let used = cpu() - c0
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("\(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(Int(size.width))×\(Int(size.height))  \(bytes / 1024) KB / 4 s  · CPU \(String(format: "%.2f", used)) s")
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func record(_ out: URL, seconds: Double) async throws {
        let content = try await ScreenCapture.content()
        guard let screen = NSScreen.main, let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.noDisplay }
        let url = out.appendingPathComponent("aufnahme-test.mp4")
        let recorder = ScreenRecorder(url: url)
        let rect = CGRect(x: 100, y: 100, width: 320, height: 200)
        try await recorder.start(.init(display: display, sourceRect: rect, pixelSize: CGSize(width: 640, height: 400),
                                       excludedApps: [], fps: 30, showsCursor: true, microphone: false))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let duration = try await recorder.stop()
        let asset = AVURLAsset(url: url)
        let size = try await VideoInfo.pixelSize(of: asset)
        let fileDuration = try await asset.load(.duration).seconds
        print("Aufnahme: \(Int(size.width))×\(Int(size.height)), \(String(format: "%.2f", fileDuration)) s (Recorder: \(String(format: "%.2f", duration)) s)")
        try? FileManager.default.removeItem(at: url)
    }
}
