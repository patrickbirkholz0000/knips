import AppKit
import SwiftUI

/// knips://-Befehle für Raycast, Stream Deck, Kurzbefehle. Jede App und jede Webseite kann einen solchen Link
/// öffnen. Was ohne weitere Nutzeraktion sofort aufnimmt — ganzer Bildschirm, letzter Bereich, Start eines
/// Videos — fragt deshalb erst nach (`LinkConfirmWindowController`), außer unter Einstellungen → Allgemein ist
/// „Aufnahmen per Link ohne Rückfrage“ eingeschaltet. Befehle, die nur Oberfläche öffnen (Auswahl-Overlay,
/// Anpinnen, Menü, Verlauf, Einstellungen), und das Stoppen einer laufenden Aufnahme laufen direkt.
/// Kürzel und Menü-Panel rufen `CaptureCoordinator` direkt auf und kommen hier nie vorbei.
@MainActor final class LinkCommands {
    static let shared = LinkCommands()

    /// Befehle, die ohne Rückfrage sofort aufnehmen würden.
    enum Immediate: String, CaseIterable {
        case fullscreen, last, record

        var action: HotkeyAction {
            switch self {
            case .fullscreen: .captureFullscreen
            case .last: .captureLastArea
            case .record: .toggleRecording
            }
        }

        /// Satz im Bestätigungsfenster — nennt, was der Link auslösen will.
        var message: String {
            switch self {
            case .fullscreen: "Eine andere App oder Webseite möchte über einen knips://-Link sofort den ganzen Bildschirm aufnehmen."
            case .last: "Eine andere App oder Webseite möchte über einen knips://-Link sofort den zuletzt aufgenommenen Bereich erneut aufnehmen."
            case .record: "Eine andere App oder Webseite möchte über einen knips://-Link eine Bildschirmaufnahme (Video) starten."
            }
        }
    }

    /// Führt eine Aufnahme-Aktion aus. Der Selbsttest ersetzt das, damit nichts aufgenommen wird.
    var perform: (HotkeyAction) -> Void = { CaptureCoordinator.shared.perform($0) }
    /// Läuft eine Aufnahme (oder ihr Countdown)? Dann beendet `record` sie nur.
    var recordingBusy: () -> Bool = { RecordingController.shared.isBusy }
    /// Zeigt die Rückfrage. Der Selbsttest legt sie stattdessen neben den sichtbaren Bildschirm.
    var show: (LinkConfirmWindowController) -> Void = { $0.present() }
    /// Offene Rückfrage. Es gibt höchstens eine; weitere Links verfallen, solange sie offen ist.
    private(set) var confirmation: LinkConfirmWindowController?

    /// Führt einen Befehl aus; `false`, wenn er unbekannt ist.
    /// `fromLink`: über einen knips://-Link von außen. Nur eigene Wege (Test-Kanal der Sandbox) übergeben `false`.
    @discardableResult
    func run(_ command: String, fromLink: Bool) -> Bool {
        switch command {
        case "area": perform(.captureArea)
        case "window": perform(.captureWindow)
        case "text": perform(.captureText)
        case "scroll": perform(.captureScrolling)
        case "pin": perform(.pinClipboard)
        case "settings": SettingsWindowController.show()
        case "menu": StatusBarController.shared?.togglePanel()
        case "history": HistoryWindowController.show()
        default:
            guard let immediate = Immediate(rawValue: command) else { return false }
            request(immediate, fromLink: fromLink)
        }
        return true
    }

    private func request(_ kind: Immediate, fromLink: Bool) {
        // Stoppen nimmt nichts Neues auf — ohne Rückfrage.
        if kind == .record, recordingBusy() {
            perform(.toggleRecording)
            return
        }
        guard fromLink, !AppSettings.shared.linkCaptureWithoutConfirm else {
            perform(kind.action)
            return
        }
        if let open = confirmation {
            Log.info("knips://\(kind.rawValue) verworfen: Rückfrage für knips://\(open.model.kind.rawValue) ist noch offen")
            show(open)
            return
        }
        let controller = LinkConfirmWindowController(kind: kind) { [weak self] approved, dontAskAgain in
            self?.finish(kind, approved: approved, dontAskAgain: dontAskAgain)
        }
        confirmation = controller
        show(controller)
    }

    private func finish(_ kind: Immediate, approved: Bool, dontAskAgain: Bool) {
        confirmation = nil
        guard approved else {
            Log.info("knips://\(kind.rawValue) abgelehnt")
            return
        }
        if dontAskAgain { AppSettings.shared.linkCaptureWithoutConfirm = true }
        // Inzwischen per Kürzel gestartet? Dann nicht versehentlich stoppen.
        if kind == .record, recordingBusy() { return }
        perform(kind.action)
    }
}

// MARK: - Rückfrage

@MainActor final class LinkConfirmModel: ObservableObject {
    let kind: LinkCommands.Immediate
    @Published var dontAskAgain = false
    /// „Aufnehmen“ wird erst nach `armDelay` wirksam: ein Klick oder ⏎, der gerade für eine andere App
    /// gedacht war, als das Fenster aufging, bestätigt nichts.
    @Published var armed = false
    init(kind: LinkCommands.Immediate) { self.kind = kind }
}

@MainActor final class LinkConfirmWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 500, height: 248)
    static let armDelay: TimeInterval = 0.6

    let model: LinkConfirmModel
    private var decide: ((_ approved: Bool, _ dontAskAgain: Bool) -> Void)?

    init(kind: LinkCommands.Immediate, decide: @escaping (_ approved: Bool, _ dontAskAgain: Bool) -> Void) {
        model = LinkConfirmModel(kind: kind)
        self.decide = decide
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Aufnahme per Link?"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(Theme.page)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: LinkConfirmView(model: model, confirm: { [weak self] in self?.confirm() },
                                                                     cancel: { [weak self] in self?.cancel() }))
        window.center()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armDelay) { [weak self] in self?.model.armed = true }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// „Aufnehmen“ (Knopf oder ⏎) — erst nach der Schutzzeit.
    func confirm() {
        guard model.armed else { return }
        resolve(true)
    }

    /// „Abbrechen“, Esc oder Schließen.
    func cancel() { resolve(false) }

    private func resolve(_ approved: Bool) {
        guard let decide else { return }
        self.decide = nil
        window?.orderOut(nil)
        decide(approved, approved && model.dontAskAgain)
    }

    func windowWillClose(_ notification: Notification) { resolve(false) }
}

struct LinkConfirmView: View {
    @ObservedObject var model: LinkConfirmModel
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 54, height: 54)
                Text("Aufnahme per Link?")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.ink)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.kind.message)
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Hast du das nicht selbst ausgelöst, klicke auf „Abbrechen“.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Toggle(isOn: $model.dontAskAgain) {
                    Text("Nicht mehr fragen").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button("Abbrechen", action: cancel)
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Aufnehmen", action: confirm)
                    .buttonStyle(PillButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .opacity(model.armed ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: LinkConfirmWindowController.size.width, height: LinkConfirmWindowController.size.height, alignment: .topLeading)
        .background(Theme.page)
        .ignoresSafeArea()
    }
}
