import AppKit
import Carbon
import SwiftUI

/// Kleine Vorschaubilder für die Stil-Auswahl, mit dem echten Renderer erzeugt.
@MainActor enum RedactPreview {
    private static var cache: [RedactStyle: NSImage] = [:]

    static func image(for style: RedactStyle) -> NSImage {
        if let hit = cache[style] { return hit }
        // Doppelte Größe und Effektmaßstab 1: so zeigt die kleine Vorschau ein erkennbares Mosaik.
        let w = 448, h = 264, scale: CGFloat = 1
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.87, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 44))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: NSColor.black]
        NSAttributedString(string: "Kontakt", attributes: attrs.merging([.font: NSFont.systemFont(ofSize: 40, weight: .bold)]) { $1 })
            .draw(at: CGPoint(x: 32, y: 64))
        NSAttributedString(string: "max@example.com", attributes: attrs).draw(at: CGPoint(x: 32, y: 128))
        NSAttributedString(string: "+49 170 123456", attributes: attrs).draw(at: CGPoint(x: 32, y: 188))
        NSGraphicsContext.restoreGraphicsState()
        let base = ctx.makeImage()!
        var doc = ImageDocument()
        var a = Annotation(kind: .redact, start: CGPoint(x: 24, y: 126), end: CGPoint(x: 424, y: 248))
        a.redactStyle = style
        doc.annotations = [a]
        let rendered = Renderer.render(base: base, document: doc, scale: scale, effects: EffectsCache(base: base, scale: scale)) ?? base
        let image = NSImage(cgImage: rendered, size: NSSize(width: w / 4, height: h / 4))
        cache[style] = image
        return image
    }
}

extension SensitiveDetector.Kind {
    var longTitle: String {
        switch self {
        case .email: "E-Mail-Adressen"
        case .iban: "IBANs"
        case .phone: "Telefonnummern"
        case .card: "Kreditkartennummern"
        case .secret: "API-Schlüssel, Tokens, Passwörter"
        case .ip: "IP-Adressen"
        }
    }

    var example: String {
        switch self {
        case .email: "name@example.com"
        case .iban: "DE89 3704 0044 0532 0130 00 (mit Prüfsumme)"
        case .phone: "+49 170 1234567, 030 1234567"
        case .card: "4111 1111 1111 1111 (mit Luhn-Prüfung)"
        case .secret: "sk_live_…, ghp_…, xoxb-…, AKIA…, JWT, „Passwort: …“"
        case .ip: "192.168.178.1"
        }
    }
}

// MARK: - Kürzel aufnehmen

@MainActor final class HotkeyRecorderState: ObservableObject {
    static let shared = HotkeyRecorderState()
    @Published var recording: HotkeyAction?
    private var monitor: Any?

    enum Outcome: Equatable {
        case cancel, remove, combo(KeyCombo)
    }

    /// Esc bricht ab, ⌫ ohne ⌘/⌥/⌃ entfernt; jede andere Taste wird das Kürzel, auch allein (↖, „A“, ⇧A, ⌦).
    static func outcome(of event: NSEvent) -> Outcome {
        if event.keyCode == UInt16(kVK_Escape) { return .cancel }
        if event.keyCode == UInt16(kVK_Delete), event.modifierFlags.intersection([.command, .option, .control]).isEmpty { return .remove }
        return .combo(KeyCombo(event: event))
    }

    /// Liefert die neue Kombination, `keyCode == UInt32.max` für „entfernen“, oder nil bei Abbruch.
    func start(_ action: HotkeyAction, onCombo: @escaping (KeyCombo?) -> Void) {
        cancel()
        recording = action
        // Solange aufgenommen wird, dürfen die alten Kürzel nicht auslösen.
        HotkeyManager.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let outcome = Self.outcome(of: event)
            self.finish()
            switch outcome {
            case .cancel: onCombo(nil)
            case .remove: onCombo(KeyCombo(keyCode: UInt32.max, modifiers: 0))
            case .combo(let combo): onCombo(combo)
            }
            return nil
        }
    }

    func cancel() {
        if recording != nil { finish() }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        HotkeyManager.shared.apply(AppSettings.shared.activeHotkeys)
    }
}
