import AppKit
import SwiftUI

// MARK: - Berechtigung

@MainActor final class PermissionWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: PermissionWindowController?

    static func show() {
        if instance == nil { instance = PermissionWindowController() }
        DockPresence.windowOpened()
        instance?.showWindow(nil)
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Knips einrichten"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: PermissionView())
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { DockPresence.windowClosed() }
}

private struct PermissionView: View {
    @State private var granted = ScreenCapture.hasPermission
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bildschirmaufnahme erlauben").font(.system(size: 17, weight: .semibold))
                    Text("Knips braucht die macOS-Freigabe, um Screenshots und Videos zu machen. Deine Aufnahmen bleiben auf deinem Mac.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Auf „Freigabe anfragen“ klicken.")
                step(2, "In den Systemeinstellungen bei „Bildschirm- & Systemaudioaufnahme“ Knips einschalten.")
                step(3, "Knips neu starten — macOS übernimmt die Freigabe erst danach.")
            }
            Spacer()
            HStack {
                if granted {
                    Label("Freigabe erteilt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Systemeinstellungen") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Button("Freigabe anfragen") { _ = CGRequestScreenCaptureAccess() }
                Button("Knips neu starten") { relaunch() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460, height: 330)
        .onReceive(timer) { _ in granted = ScreenCapture.hasPermission }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).font(.system(size: 13))
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
