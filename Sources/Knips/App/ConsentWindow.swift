import AppKit
import SwiftUI

/// Einmalige Frage nach der anonymen Nutzungsstatistik — nach Freigabe- und Kürzel-Dialog, nie gleichzeitig.
/// Schließen ohne Wahl zählt als Nein; dann fragt Knips beim nächsten Start noch einmal.
@MainActor final class ConsentWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: ConsentWindowController?
    static let size = NSSize(width: 500, height: 272)

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
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Knips verbessern?"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(Theme.page)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ConsentView(telemetry: telemetry) { [weak self] in
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 54, height: 54)
                Text("Knips verbessern?")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.ink)
            }
            Text("Darf Knips anonym mitzählen, welche Funktionen wie oft genutzt werden? Gesendet werden nur Zähler wie „3 Screenshots“, dazu Version und Betriebssystem. Nie Bilder, Texte, Dateinamen oder Fensterinhalte. Du kannst das jederzeit in den Einstellungen ändern.")
                .font(.system(size: 13.5))
                .lineSpacing(2)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Link(destination: Telemetry.infoURL) {
                    HStack(spacing: 4) {
                        Text("Was wird gesendet?")
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Nein danke") { choose(false) }
                    .buttonStyle(PillButtonStyle())
                Button("Anonym mitzählen") { choose(true) }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: ConsentWindowController.size.width, height: ConsentWindowController.size.height, alignment: .topLeading)
        .background(Theme.page)
        .ignoresSafeArea()
        // In den Einstellungen schon entschieden → Frage erledigt.
        .onChange(of: telemetry.consent) { _, value in if value != nil { close() } }
    }

    private func choose(_ on: Bool) {
        telemetry.setConsent(on)
        close()
    }
}
