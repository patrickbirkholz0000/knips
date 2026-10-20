import AppKit
import Combine
import SwiftUI

// MARK: - Berechtigung

/// Beim ersten Start ohne Bildschirmaufnahme-Freigabe: erklärt die drei Schritte und startet Knips danach neu.
@MainActor final class PermissionWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: PermissionWindowController?
    static let width: CGFloat = 520

    static func show() {
        if instance == nil { instance = PermissionWindowController() }
        // Schon offen: nicht noch einmal zählen, sonst bliebe das Dock-Symbol nach dem Schließen stehen.
        if instance?.window?.isVisible != true { DockPresence.windowOpened() }
        instance?.showWindow(nil)
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = BrandDialogWindow.make(width: Self.width, title: "Knips einrichten")
        super.init(window: window)
        window.delegate = self
        window.setDialogContent(PermissionView { [weak window] in window?.performClose(nil) })
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { DockPresence.windowClosed() }
}

private struct PermissionView: View {
    let later: () -> Void
    @State private var granted = ScreenCapture.hasPermission
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        BrandDialog(overline: "Freigabe", title: "Bildschirm aufnehmen erlauben",
                    message: "Knips braucht die macOS-Freigabe „Bildschirm- & Systemaudioaufnahme“, um Screenshots und Videos zu machen. Deine Aufnahmen bleiben auf deinem Mac.",
                    width: PermissionWindowController.width) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    BrandStatusIcon(tone: granted ? .done : .missing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(granted ? "Freigabe erteilt" : "Noch nicht erlaubt")
                            .font(Brand.font(14, .semibold))
                            .foregroundStyle(Color.brand(Brand.ink))
                        Text(granted ? "Jetzt nur noch Knips neu starten." : "Dieser Zustand aktualisiert sich von selbst.")
                            .font(Brand.font(12.5))
                            .foregroundStyle(Color.brand(Brand.inkSoft))
                    }
                    Spacer(minLength: 8)
                    Button("Systemeinstellungen") { NSWorkspace.shared.open(Readiness.screenSettingsURL) }
                        .buttonStyle(BrandButtonStyle(kind: .secondary, compact: true))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous).fill(Color.brand(Brand.surfaceRaised)))
                .overlay(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous).strokeBorder(Color.brand(Brand.line)))
                VStack(alignment: .leading, spacing: 9) {
                    step(1, "Auf „Freigabe anfragen“ klicken.")
                    step(2, "In den Systemeinstellungen bei „Bildschirm- & Systemaudioaufnahme“ Knips einschalten.")
                    step(3, "Knips neu starten. macOS übernimmt die Freigabe erst danach.")
                }
            }
        } buttons: {
            Button("Später", action: later).buttonStyle(BrandButtonStyle(kind: .quiet))
            Spacer(minLength: 8)
            Button("Freigabe anfragen") { _ = CGRequestScreenCaptureAccess() }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
            Button("Knips neu starten") { relaunch() }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
        .onReceive(timer) { _ in granted = ScreenCapture.hasPermission }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n).")
                .font(Brand.mono(12.5, .medium))
                .foregroundStyle(Color.brand(Brand.inkSoft))
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .font(Brand.font(13.5))
                .foregroundStyle(Color.brand(Brand.ink))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Pfad als eigenes Argument ($1), nie in den Befehl eingesetzt — ein Ordner- oder App-Name mit $(…) oder
        // Anführungszeichen würde sonst als Shell-Befehl ausgeführt.
        task.arguments = ["-c", "sleep 0.6; open \"$1\"", "sh", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
