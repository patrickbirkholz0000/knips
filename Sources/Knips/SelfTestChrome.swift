#if KNIPS_DEV
import AppKit
import SwiftUI

/// `--selftest chrome <ordner>`: die dunklen Schwebeflächen offscreen fotografieren — Aufnahme-Leiste, Countdown,
/// Scroll-Leiste, Hinweise (HUD), Pin-Steuerung, Aufnahmerahmen, Hinweiszeile des Overlays und das Menü-Panel
/// während eines Videos. Ohne echte Aufnahme (Attrappe ohne Fenster), kein Fenster erscheint auf dem Bildschirm:
/// SwiftUI über `ImageRenderer`, AppKit-Ebenen über `CALayer.render(in:)`.
/// Jedes Bild zeigt links die Fläche über einer hellen App, rechts über dunklem Grund.
extension SelfTest {
    static func chrome(_ out: URL) async throws {
        let backdrop = sampleImage(width: 1400, height: 880, scale: 2)
        var problems: [String] = []

        // Aufnahme-Leiste: ohne und mit Mikrofon.
        try chromeShot("chrome-aufnahme-leiste", out, backdrop) {
            VStack(spacing: 0) {
                RecordingBar(elapsed: 8, microphone: false, stop: {}, discard: {})
                RecordingBar(elapsed: 754, microphone: true, stop: {}, discard: {})
            }
        }

        // Countdown 3 · 2 · 1.
        try chromeShot("chrome-countdown", out, backdrop) {
            HStack(spacing: 0) {
                ForEach([3, 2, 1], id: \.self) { n in CountdownDial(number: n, cancel: {}) }
            }
        }

        // Scroll-Leiste: läuft, dann Obergrenze erreicht. Breite darf sich dabei nicht ändern.
        let running = ScrollBar(sections: 7, height: 12_480, limitReached: false, done: {}, cancel: {})
        let full = ScrollBar(sections: 41, height: ScrollStitcher.maxHeight, limitReached: true, done: {}, cancel: {})
        try chromeShot("chrome-scroll-leiste", out, backdrop) {
            VStack(spacing: 0) { running; full }
        }
        let widths = [running, full].map { NSHostingView(rootView: $0).fittingSize.width }
        if abs(widths[0] - widths[1]) > 0.5 { problems.append("Scroll-Leiste springt: \(widths)") }
        print("   Scroll-Leiste \(Int(widths[0])) pt breit (läuft und voll gleich)")

        // Hinweise.
        try chromeShot("chrome-hinweise", out, backdrop) {
            VStack(alignment: .leading, spacing: 0) {
                HUDView(text: "Kopiert", symbol: "checkmark.circle.fill")
                HUDView(text: "Text kopiert · 3 Zeilen", symbol: "text.viewfinder")
                HUDView(text: "Aufnahme verworfen", symbol: "trash.fill")
                HUDView(text: "Ablageordner nicht erreichbar – gespeichert in „Bilder/Knips“", symbol: "exclamationmark.triangle.fill")
            }
        }

        // Angepinntes Bild mit Steuerung (wie beim Darüberfahren).
        try chromePin(out, backdrop)

        // Rahmen um den Aufnahmebereich: Video (Rot) und Scroll-Screenshot (Königsblau).
        try chromeFrames(out, backdrop)

        // Hinweiszeile des Auswahl-Overlays für jede Art.
        let pills: [(SelectionPurpose, Bool)] = [(.screenshot, false), (.screenshot, true), (.recording, false), (.text, false), (.scroll, false)]
        let rendered = pills.compactMap { HintPill.render(HintPill.parts(purpose: $0.0, windowMode: $0.1), scale: 2) }
        if rendered.count != pills.count { problems.append("Hinweiszeile nicht gezeichnet") }
        try chromeShot("chrome-overlay-hinweise", out, backdrop) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rendered.enumerated()), id: \.offset) { _, pill in
                    Image(decorative: pill.image, scale: 2)
                        .compositingGroup()
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
            }
            .padding(14)
        }

        // Menü-Panel während eines Videos (Attrappe ohne Fenster): Lampe rot, Status mit Zeit, „Stoppen“.
        try await chromeMenuRecording(out, backdrop, &problems)

        if !problems.isEmpty { throw CheckFailed(message: problems.joined(separator: "; ")) }
    }

    // MARK: Einzelteile

    private static func chromePin(_ out: URL, _ backdrop: CGImage) throws {
        let image = sampleImage(width: 900, height: 560, scale: 2)
        let view = PinView(image: image, naturalWidth: 450)
        view.frame = NSRect(x: 0, y: 0, width: 405, height: 252)   // 90 % der Originalgröße
        view.layoutSubtreeIfNeeded()
        view.layout()
        view.debugShowControls()
        guard let controls = view.subviews.first as? NSHostingView<PinControls> else {
            throw CheckFailed(message: "Pin-Steuerung fehlt")
        }
        let pill = controls.frame
        print("   Pin 405×252, Steuerung \(Int(pill.width))×\(Int(pill.height)) bei \(Int(pill.minX)),\(Int(pill.minY)): \(controls.rootView.model.percent) %")
        if controls.rootView.model.percent != 90 { throw CheckFailed(message: "Pin-Größe \(controls.rootView.model.percent) % statt 90 %") }
        if controls.isHidden || !view.bounds.contains(pill) { throw CheckFailed(message: "Pin-Steuerung liegt nicht im Bild: \(pill)") }
        // Bild über die Ebene, die Pille (SwiftUI) an ihrer Stelle darüber.
        controls.isHidden = true
        guard let layer = view.layer, let base = layerImage(layer, size: view.bounds.size, scale: 2) else {
            throw CheckFailed(message: "Pin nicht gezeichnet")
        }
        try chromeShot("chrome-pin", out, backdrop) {
            Image(decorative: base, scale: 2)
                .overlay(alignment: .topTrailing) {
                    controls.rootView.padding(.top, 8).padding(.trailing, 8)
                }
                .clipShape(RoundedRectangle(cornerRadius: PinView.radius, style: .continuous))
                .compositingGroup()
                .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                .padding(18)
        }
    }

    private static func chromeFrames(_ out: URL, _ backdrop: CGImage) throws {
        let size = CGSize(width: 300, height: 180)
        var images: [CGImage] = []
        for color in [Brand.Dark.record, Brand.Dark.accent] {
            let view = AreaFrame.makeView(size: size, color: color)
            guard let layer = view.layer, let img = layerImage(layer, size: size, scale: 2) else {
                throw CheckFailed(message: "Rahmen nicht gezeichnet")
            }
            images.append(img)
        }
        try chromeShot("chrome-rahmen", out, backdrop) {
            HStack(spacing: 24) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, img in Image(decorative: img, scale: 2) }
            }
            .padding(10)
        }
    }

    private static func chromeMenuRecording(_ out: URL, _ backdrop: CGImage, _ problems: inout [String]) async throws {
        let rc = RecordingController.shared
        let previous = rc.onError
        var errors: [String] = []
        rc.onError = { title, _, _ in errors.append(title) }
        defer { rc.onError = previous }
        let session = FakeRecordingSession()
        rc.run(session, screen: nil, global: CGRect(x: 0, y: 0, width: 400, height: 300), isFull: true, countdown: false, showsWindows: false)
        let deadline = Date().addingTimeInterval(3)
        while rc.phase != .recording, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard rc.phase == .recording else { throw CheckFailed(message: "Attrappe nimmt nicht auf: \(rc.phase)") }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        // Zuletzt: drei Bilder und ein Video (Vorschau eines Bildes, nur im Modell als Video markiert).
        let store = CaptureStore.shared
        var recent: [CaptureItem] = []
        for (w, h) in [(1400, 880), (900, 1200), (1600, 700), (1200, 800)] {
            let item = try store.addImage(sampleImage(width: w, height: h), scale: 2)
            await store.waitUntilWritten(item.id)
            recent.append(item)
        }
        recent[1].kind = .video
        recent[1].duration = 14
        let model = MenuPanelModel()
        model.recent = recent
        let actions = MenuActions(capture: { _ in }, openImage: {}, openFolder: {}, openRecent: { _ in }, settings: {}, history: {}, quit: {})
        try chromeShot("chrome-menu-aufnahme", out, backdrop) {
            HStack(alignment: .top, spacing: 18) {
                MenuPanelView(model: model, actions: actions)
                RecordingBar(elapsed: rc.elapsed, microphone: false, stop: {}, discard: {})
            }
            .padding(18)
        }
        // Speichern scheitert bei der Attrappe absichtlich (keine Bilder) — so erscheint kein Hinweis auf dem Bildschirm.
        rc.stop(save: true)
        while rc.phase != .idle, Date() < deadline.addingTimeInterval(3) { try await Task.sleep(nanoseconds: 50_000_000) }
        if rc.phase != .idle { problems.append("Attrappe nicht beendet: \(rc.phase)") }
    }

    // MARK: Hilfen

    /// Fläche links über der hellen Test-App, rechts über dunklem Grund; als PNG in `out`.
    private static func chromeShot<V: View>(_ name: String, _ out: URL, _ backdrop: CGImage, @ViewBuilder _ content: () -> V) throws {
        let light = Image(decorative: backdrop, scale: 2).resizable().scaledToFill()
        let view = HStack(spacing: 0) {
            content()
                .padding(16)
                .background { light }
                .clipped()
            content()
                .padding(16)
                .background(Color.brand(Brand.canvas.darkVariant))
        }
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw CheckFailed(message: "\(name) nicht gezeichnet") }
        guard let data = image.pngData() else { throw CaptureStore.StoreError.encode }
        let url = out.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("→ \(url.path) (\(image.width)×\(image.height))")
    }

    private static func layerImage(_ layer: CALayer, size: CGSize, scale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}
#endif
