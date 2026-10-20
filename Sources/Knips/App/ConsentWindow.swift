import AppKit
import SwiftUI

/// Einmalige Frage nach der anonymen Nutzungsstatistik — nach Freigabe- und Kürzel-Dialog, nie gleichzeitig.
/// Schließen ohne Wahl zählt als Nein; dann fragt Knips beim nächsten Start noch einmal.
@MainActor final class ConsentWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: ConsentWindowController?
    static let width: CGFloat = 520

    static func showIfNeeded() {
        let telemetry = Telemetry.shared
        guard telemetry.shouldAsk, instance == nil else { return }
        telemetry.markAsked()
        let controller = ConsentWindowController(telemetry: telemetry)
        instance = controller
        DockPresence.windowOpened()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(telemetry: Telemetry) {
        let window = BrandDialogWindow.make(width: Self.width, title: "Knips verbessern?")
        super.init(window: window)
        window.delegate = self
        window.setDialogContent(ConsentView(telemetry: telemetry) { [weak self] in
            if self?.window?.isVisible == true { self?.close() }
        })
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        if Self.instance === self { Self.instance = nil }
        DockPresence.windowClosed()
    }
}

struct ConsentView: View {
    @ObservedObject var telemetry: Telemetry
    let close: () -> Void

    var body: some View {
        BrandDialog(overline: "Statistik", title: "Knips verbessern?",
                    message: "Darf Knips anonym mitzählen, welche Funktionen wie oft genutzt werden? Du kannst das jederzeit in den Einstellungen ändern.",
                    width: ConsentWindowController.width) {
            VStack(alignment: .leading, spacing: 14) {
                BrandDialogPoint(symbol: "number", title: "Nur Zähler",
                                 text: "Etwa „3 Screenshots“, dazu Version und Betriebssystem.")
                BrandDialogPoint(symbol: "eye.slash", title: "Nie Inhalte",
                                 text: "Keine Bilder, Texte, Dateinamen oder Fensterinhalte.")
                BrandDialogPoint(symbol: "switch.2", title: "Jederzeit änderbar",
                                 text: "In den Einstellungen unter Datenschutz.")
            }
        } buttons: {
            BrandLink(title: "Was wird gesendet?", url: Telemetry.infoURL)
            Spacer(minLength: 8)
            Button("Nein danke") { choose(false) }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
            // Bewusst ohne ⏎: Das Fenster holt sich beim Start den Fokus, ein Tastendruck für eine andere App
            // darf keine Zustimmung sein.
            Button("Anonym mitzählen") { choose(true) }
                .buttonStyle(BrandButtonStyle(kind: .primary))
        }
        // In den Einstellungen schon entschieden → Frage erledigt.
        .onChange(of: telemetry.consent) { _, value in if value != nil { close() } }
    }

    private func choose(_ on: Bool) {
        telemetry.setConsent(on)
        close()
    }
}
