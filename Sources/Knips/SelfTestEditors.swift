#if KNIPS_DEV
import AppKit
import ScreenCaptureKit
import SwiftUI

/// `--selftest live <ordner> [hell|dunkel|beide]` — Bild- und Video-Editor als echte Fenster, 1 pt in der
/// äußersten Bildschirmecke, per ScreenCaptureKit fotografiert (nur eigene Fenster). Jede Darstellung bekommt
/// ihre Bilder (`…-hell.png`, `…-dunkel.png`), dazu einmal Zoom, schlaue Balken und die Kürzel ⌘Z/⌘⏎.
extension SelfTest {
    static func live(_ out: URL, mode: String) async throws {
        let modes: [(name: String, appearance: NSAppearance.Name)] = switch mode {
        case "hell": [("hell", .aqua)]
        case "dunkel": [("dunkel", .darkAqua)]
        default: [("hell", .aqua), ("dunkel", .darkAqua)]
        }
        var failed: [String] = []
        func check(_ name: String, _ ok: Bool) {
            print("   \(ok ? "ok    " : "FALSCH") \(name)")
            if !ok { failed.append(name) }
        }

        let store = CaptureStore.shared
        let image = sampleImage()
        let item = try store.addImage(image, scale: 2)
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 1200, y: 100), end: CGPoint(x: 1000, y: 220))
        var red = Annotation(kind: .redact, start: CGPoint(x: 470, y: 250), end: CGPoint(x: 890, y: 286))
        red.redactStyle = .pixelate
        var doc = ImageDocument()
        doc.annotations = [arrow, red]

        let src = out.appendingPathComponent("live-video.mp4")
        let emailRect = try await makeSampleVideo(src)
        let videoItem = try await store.addVideo(from: src, scale: 1)

        for (index, (suffix, appearanceName)) in modes.enumerated() {
            print("Darstellung \(suffix):")
            let appearance = NSAppearance(named: appearanceName)

            // Bild-Editor mit Auto-Zensur-Knopf (Einstellung) — breit, schmal, Werkzeuge, Rahmen, Zuschneiden.
            AppSettings.shared.showAutoRedact = true
            let editor = EditorWindowController(item: item, base: image, document: doc, tool: .redact)
            let window = editor.window!
            window.appearance = appearance
            editor.model.selectedID = red.id
            window.setContentSize(NSSize(width: 1180, height: 680))
            try await shot(window, out, "live-editor-\(suffix).png")

            window.setContentSize(NSSize(width: EditorChrome.minWidth, height: 600))
            try await shot(window, out, "live-editor-schmal-\(suffix).png")
            check("Bild-Editor lässt sich auf \(Int(EditorChrome.minWidth)) pt verkleinern (ist \(Int(window.frame.width)))",
                  window.frame.width <= 900 && window.minSize.width <= 900)

            AppSettings.shared.showAutoRedact = false
            window.setContentSize(NSSize(width: 1180, height: 680))
            editor.model.tool = .arrow
            editor.model.selectedID = arrow.id
            try await shot(window, out, "live-editor-pfeil-\(suffix).png")

            editor.model.selectedID = nil
            editor.model.tool = .rectangle
            editor.model.setFrame(FrameStyle(gradient: 1, padding: 48, cornerRadius: 12, shadow: true))
            try await shot(window, out, "live-editor-rahmen-\(suffix).png")
            try await panelShot(FramePanel(model: editor.model), appearance: appearance, out, "live-rahmen-panel-\(suffix).png")
            editor.model.setFrame(nil)

            editor.model.startCrop()
            editor.model.cropDraft = CGRect(x: 120, y: 90, width: 1100, height: 640)
            try await shot(window, out, "live-editor-zuschneiden-\(suffix).png")
            editor.model.cancelCrop()

            if index == 0 {
                try await editorBehaviour(editor, out, check: check)
            }
            window.orderOut(nil)

            // Video-Editor: Zensur ausgewählt, gekürzt — breit und schmal.
            let model = try await VideoEditorModel.load(videoItem)
            model.addRedaction(rect: emailRect)
            model.setTrim(start: 0.4, end: 2.6)
            model.seek(to: 1.5)
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let videoEditor = VideoEditorWindowController(model: model)
            let videoWindow = videoEditor.window!
            videoWindow.appearance = appearance
            videoWindow.setContentSize(NSSize(width: 1180, height: 760))
            try await shot(videoWindow, out, "live-video-editor-\(suffix).png")
            videoWindow.setContentSize(NSSize(width: EditorChrome.minWidth, height: 600))
            try await shot(videoWindow, out, "live-video-editor-schmal-\(suffix).png")
            check("Video-Editor lässt sich auf \(Int(EditorChrome.minWidth)) pt verkleinern (ist \(Int(videoWindow.frame.width)))",
                  videoWindow.frame.width <= 900 && videoWindow.minSize.width <= 900)
            model.selectedID = nil
            videoWindow.setContentSize(NSSize(width: 1180, height: 760))
            try await shot(videoWindow, out, "live-video-editor-ohne-auswahl-\(suffix).png")

            if index == 0 {
                // ⌘Z gilt genau einmal, obwohl die Leiste mehrere Fassungen (ViewThatFits) hat.
                model.checkpoint()
                model.setTrim(start: 0.8)
                model.checkpoint()
                model.setTrim(start: 1.2)
                press(videoWindow, "z", keyCode: 6, modifiers: .command)
                check("⌘Z im Video-Editor widerruft genau einen Schritt (Anfang \(String(format: "%.1f", model.trimStart)) s)",
                      abs(model.trimStart - 0.8) < 0.001)
                checkHit(videoWindow, "Fertig (Video)", x: videoWindow.frame.width - 42, fromTop: 26, check: check)
                checkHit(videoWindow, "Stil (Video)", x: 400, fromTop: 14, check: check)
            }
            videoWindow.orderOut(nil)
            model.shutdown()
        }
        if !failed.isEmpty { throw CheckFailed(message: "Editoren: \(failed.joined(separator: ", "))") }
    }

    /// Zoom, schlaue Balken, sichtbarer Text und ⌘⏎ — unabhängig von der Darstellung, daher nur einmal.
    private static func editorBehaviour(_ editor: EditorWindowController, _ out: URL, check: (String, Bool) -> Void) async throws {
        let window = editor.window!
        editor.model.tool = .redact
        editor.canvas.zoomActualSize()
        try await shot(window, out, "live-editor-zoom100.png")
        editor.canvas.zoomIn(); editor.canvas.zoomIn(); editor.canvas.zoomIn(); editor.canvas.zoomIn()
        print("   Zoom jetzt \(editor.model.zoomPercent) %")
        try await shot(window, out, "live-editor-zoom250.png")
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
        let before = editor.model.annotations
        editor.model.annotations = smart
        try await shot(window, out, "live-editor-schlaue-balken.png")
        print("   Sichtbarer Text ohne Zensur:\n" + (await editor.model.renderedText()).split(separator: "\n").map { "     | " + $0 }.joined(separator: "\n"))
        editor.model.annotations = before
        editor.model.dirty = false

        // ⌘⏎ = Fertig: schließt das Fenster (Kürzel liegt außerhalb der wechselnden Leisten-Fassungen).
        press(window, "\r", keyCode: 36, modifiers: .command)
        check("⌘⏎ im Bild-Editor schließt das Fenster", !window.isVisible)

        // Die obere Leiste liegt in Höhe der durchsichtigen Titelleiste: Klicks auf „Fertig“ und die Werkzeuge
        // müssen bei der SwiftUI-Fläche ankommen, nicht bei der Titelleiste. Geprüft über hitTest des Fensterrahmens.
        let probe = EditorWindowController(item: editor.model.item, base: editor.model.base, document: ImageDocument(), tool: .redact)
        let probeWindow = probe.window!
        probeWindow.setContentSize(NSSize(width: 1180, height: 680))
        try await shot(probeWindow, out, "live-editor-klick.png")
        if let close = probeWindow.standardWindowButton(.closeButton) {
            let frame = close.convert(close.bounds, to: nil)
            print("   Ampel: Mitte \(Int(frame.midX)),\(Int(probeWindow.frame.height - frame.midY)) pt von oben links")
        }
        let height = probeWindow.frame.height
        for (name, x, fromTop) in [("Fertig", probeWindow.frame.width - 42, 26.0), ("Fertig oben", probeWindow.frame.width - 42, 12.0),
                                   ("Werkzeug", 140.0, 20.0), ("Zoom", 90.0, height - 20)] {
            checkHit(probeWindow, name, x: x, fromTop: fromTop, check: check)
        }
        probeWindow.orderOut(nil)
    }

    /// Bekäme ein Klick an dieser Stelle (pt von oben links) die SwiftUI-Fläche — oder die Titelleiste?
    private static func checkHit(_ window: NSWindow, _ name: String, x: CGFloat, fromTop: CGFloat, check: (String, Bool) -> Void) {
        let hit = window.contentView?.superview?.hitTest(CGPoint(x: x, y: window.frame.height - fromTop))
        check("Klick auf \(name) erreicht die Editor-Fläche (\(hit.map { String(describing: type(of: $0)) } ?? "nichts"))",
              hit.map { $0.isDescendant(of: window.contentView!) } ?? false)
    }

    /// Wie `windowShot` in SelfTest.swift: Fenster bis auf 1 pt neben den Bildschirm, per SCK fotografieren.
    private static func shot(_ window: NSWindow, _ out: URL, _ name: String) async throws {
        let size = window.frame.size
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
        let url = out.appendingPathComponent(name)
        guard let data = image.pngData() else { throw CaptureStore.StoreError.encode }
        try data.write(to: url)
        print("→ \(url.path) (\(image.width)×\(image.height), \(Int(size.width))×\(Int(size.height)) pt)")
    }

    /// Popover-Inhalt (z. B. Rahmen) in einem eigenen Fenster auf `surface` — Popovers selbst sind eigene Fenster.
    private static func panelShot<Content: View>(_ content: Content, appearance: NSAppearance?, _ out: URL, _ name: String) async throws {
        let host = NSHostingView(rootView: content.background(Color.brand(Brand.surface)))
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = Brand.surface
        window.contentView = host
        try await shot(window, out, name)
        window.orderOut(nil)
    }

    private static func press(_ window: NSWindow, _ chars: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode)
        else { return }
        _ = window.performKeyEquivalent(with: event)
        let end = Date().addingTimeInterval(0.3)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
}
#endif
