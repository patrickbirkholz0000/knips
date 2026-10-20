import AppKit
import SwiftUI

/// Woher eine Aufnahme kommt. Per Link ausgelöste Aufnahmen landen nie von selbst in der Zwischenablage, und ein
/// per Link geöffnetes Auswahl-Overlay nimmt ⏎ und Klicks erst nach der Schutzzeit an (`SelectionOverlay`).
enum CaptureSource { case user, link }

/// knips://-Befehle für Raycast, Stream Deck, Kurzbefehle. Jede App und jede Webseite kann einen solchen Link
/// öffnen. Was ohne weitere Nutzeraktion sofort aufnimmt — ganzer Bildschirm, letzter Bereich, Start eines
/// Videos — fragt deshalb immer erst nach (`LinkConfirmWindowController`). Abschalten lässt sich das bewusst nicht:
/// Eine solche Einstellung läge in den Benutzereinstellungen, und die kann jedes andere Programm umschreiben.
/// Befehle, die nur Oberfläche öffnen (Auswahl-Overlay, Anpinnen, Menü, Verlauf, Einstellungen), und das Stoppen
/// einer laufenden Aufnahme laufen direkt. Kürzel und Menü-Panel rufen `CaptureCoordinator` direkt auf und kommen
/// hier nie vorbei.
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

        /// Was der Link auslösen will — Satzende nach „… möchte über einen knips://-Link“.
        private var request: String {
            switch self {
            case .fullscreen: "sofort den ganzen Bildschirm aufnehmen."
            case .last: "sofort den zuletzt aufgenommenen Bereich erneut aufnehmen."
            case .record: "eine Bildschirmaufnahme (Video) starten."
            }
        }

        /// `sender`: Absender aus dem Apple Event (`LinkSender`), sonst unbekannt.
        func prompt(sender: String?) -> LinkPrompt {
            LinkPrompt(name: rawValue, title: "Aufnahme per Link?",
                       message: "\(sender ?? "Eine andere App oder Webseite") möchte über einen knips://-Link \(request)",
                       hint: "Hast du das nicht selbst ausgelöst, klicke auf „Abbrechen“.", confirm: "Aufnehmen")
        }
    }

    /// Führt eine Aufnahme-Aktion aus. Der Selbsttest ersetzt das, damit nichts aufgenommen wird.
    var perform: (HotkeyAction, CaptureSource) -> Void = { CaptureCoordinator.shared.perform($0, source: $1) }
    /// Läuft eine Aufnahme (oder ihr Countdown)? Dann beendet `record` sie nur.
    var recordingBusy: () -> Bool = { RecordingController.shared.isBusy }
    /// Bringt eine Rückfrage nach vorn. Der Selbsttest legt sie stattdessen neben den sichtbaren Bildschirm.
    var place: (NSWindow) -> Void = { window in
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Offene Rückfrage. Es gibt höchstens eine; weitere verfallen, solange sie offen ist.
    private(set) var confirmation: LinkConfirmWindowController?

    /// Führt einen Befehl aus; `false`, wenn er unbekannt ist.
    /// `fromLink`: über einen knips://-Link von außen. Nur eigene Wege (Test-Kanal der Sandbox) übergeben `false`.
    /// `sender`: Absender des Links für die Rückfrage (`LinkSender`), falls bekannt.
    @discardableResult
    func run(_ command: String, fromLink: Bool, sender: String? = nil) -> Bool {
        let source: CaptureSource = fromLink ? .link : .user
        switch command {
        case "area": perform(.captureArea, source)
        case "window": perform(.captureWindow, source)
        case "text": perform(.captureText, source)
        case "scroll": perform(.captureScrolling, source)
        case "pin": perform(.pinClipboard, source)
        case "settings": SettingsWindowController.show()
        case "menu": StatusBarController.shared?.togglePanel()
        case "history": HistoryWindowController.show()
        default:
            guard let immediate = Immediate(rawValue: command) else { return false }
            request(immediate, fromLink: fromLink, sender: sender)
        }
        return true
    }

    private func request(_ kind: Immediate, fromLink: Bool, sender: String?) {
        // Stoppen nimmt nichts Neues auf — ohne Rückfrage.
        if kind == .record, recordingBusy() {
            perform(.toggleRecording, fromLink ? .link : .user)
            return
        }
        guard fromLink else {
            perform(kind.action, .user)
            return
        }
        ask(kind.prompt(sender: sender)) { [weak self] in
            // Inzwischen per Kürzel gestartet? Dann nicht versehentlich stoppen.
            guard let self, !(kind == .record && self.recordingBusy()) else { return }
            self.perform(kind.action, .link)
        }
    }

    /// Per Link erfasster Text kommt erst nach Rückfrage in die Zwischenablage; die Vorschau zeigt, was kopiert würde.
    func confirmTextCopy(_ text: String, copy: @escaping () -> Void) {
        ask(LinkPrompt(name: "text", title: "Text kopieren?",
                       message: "Diesen Text hat Knips über einen knips://-Link erfasst. In die Zwischenablage kommt er erst, wenn du zustimmst.",
                       preview: text, confirm: "Kopieren"), approved: copy)
    }

    /// Höchstens eine Rückfrage zur Zeit. Weitere verfallen, solange sie offen ist, und holen sie auch nicht erneut
    /// nach vorn — sonst könnte ein Link die Schutzzeit umgehen oder einer anderen App den Fokus wegnehmen.
    private func ask(_ prompt: LinkPrompt, approved: @escaping () -> Void) {
        if let open = confirmation {
            Log.info("knips://-Rückfrage „\(prompt.name)“ verworfen: „\(open.model.prompt.name)“ ist noch offen")
            return
        }
        let controller = LinkConfirmWindowController(prompt: prompt) { [weak self] ok in
            self?.confirmation = nil
            if ok { approved() } else { Log.info("knips://-Rückfrage „\(prompt.name)“ abgelehnt") }
        }
        confirmation = controller
        controller.present(place)
    }
}

// MARK: - Absender

/// Absender eines knips://-Links aus dem Apple Event (`keySenderAuditTokenAttr`) — nur zur Information in der
/// Rückfrage. Der Name stammt aus dem Bundle der sendenden App und lässt sich fälschen; er ersetzt die Rückfrage nie.
enum LinkSender {
    /// Absender eines Apple Events als Satzanfang für die Rückfrage: der App-Name in Anführungszeichen oder
    /// „Das Programm …“; nil, wenn er sich nicht bestimmen lässt (etwa weil der Absender schon beendet ist).
    static func describe(_ event: NSAppleEventDescriptor?) -> String? {
        guard let token = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data else { return nil }
        return describe(auditToken: token)
    }

    static func describe(auditToken: Data) -> String? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return nil }
        var staticCode: SecStaticCode?
        var path: CFURL?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let url = path as URL? else { return nil }
        return describe(path: url)
    }

    /// Äußerstes App-Bundle (…/Google Chrome.app/…/Helper.app → Google Chrome), sonst der Programmname.
    static func describe(path url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return "Das Programm „\(url.lastPathComponent)“" }
        var name = FileManager.default.displayName(atPath: NSString.path(withComponents: Array(parts[...i])))
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return "„\(name)“"
    }
}

// MARK: - Rückfrage

/// Inhalt einer Rückfrage.
struct LinkPrompt {
    /// Kurzname für Protokoll und Selbsttest („fullscreen“, „text“ …).
    var name: String
    var title: String
    var message: String
    var hint: String?
    /// Was bei Zustimmung herausgeht, z. B. der Text für die Zwischenablage.
    var preview: String?
    var confirm: String
}

@MainActor final class LinkConfirmModel: ObservableObject {
    let prompt: LinkPrompt
    /// Zustimmung (Knopf oder ⏎) wirkt erst nach `armDelay`: ein Klick oder ⏎, der gerade für eine andere App
    /// gedacht war, als das Fenster aufging, bestätigt nichts. Beginnt bei jedem Zeigen neu.
    @Published var armed = false
    /// Nur für die Anzeige: zählt jedes Zeigen, damit der Fortschritt der Schutzzeit neu beginnt.
    @Published var presentations = 0
    init(prompt: LinkPrompt) { self.prompt = prompt }
}

@MainActor final class LinkConfirmWindowController: NSWindowController, NSWindowDelegate {
    static let armDelay: TimeInterval = 0.6

    static let width: CGFloat = 520

    let model: LinkConfirmModel
    private var decide: ((_ approved: Bool) -> Void)?
    private var arming: DispatchWorkItem?

    init(prompt: LinkPrompt, decide: @escaping (_ approved: Bool) -> Void) {
        model = LinkConfirmModel(prompt: prompt)
        self.decide = decide
        // Schwebende Karte im Stil der Dialoge (`BrandDialogWindow`), folgt Hell/Dunkel.
        let window = BrandDialogWindow.make(width: Self.width, title: prompt.title)
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        window.setDialogContent(LinkConfirmView(model: model, confirm: { [weak self] in self?.confirm() },
                                                cancel: { [weak self] in self?.cancel() }))
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Zeigt die Rückfrage (`place` bringt das Fenster nach vorn); die Schutzzeit beginnt dabei neu.
    func present(_ place: (NSWindow) -> Void) {
        arming?.cancel()
        model.armed = false
        model.presentations += 1
        let work = DispatchWorkItem { [weak self] in self?.model.armed = true }
        arming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armDelay, execute: work)
        if let window { place(window) }
    }

    /// Zustimmen (Knopf oder ⏎) — erst nach der Schutzzeit.
    func confirm() {
        guard model.armed else { return }
        resolve(true)
    }

    /// „Abbrechen“, Esc oder Schließen.
    func cancel() { resolve(false) }

    private func resolve(_ approved: Bool) {
        guard let decide else { return }
        self.decide = nil
        arming?.cancel()
        window?.orderOut(nil)
        decide(approved)
    }

    func windowWillClose(_ notification: Notification) { resolve(false) }
}

/// „Aufnahme per Link?“ bzw. „Text kopieren?“: Karte wie die Onboarding-Karte wie in der App-Familie. Die Schutzzeit ist
/// sichtbar — der Primärknopf bleibt blass, darunter läuft ein leiser Fortschritt, bis er wirkt.
struct LinkConfirmView: View {
    @ObservedObject var model: LinkConfirmModel
    let confirm: () -> Void
    let cancel: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        let prompt = model.prompt
        BrandDialog(overline: prompt.preview == nil ? "Link von außen" : "Text per Link", title: prompt.title,
                    message: prompt.message, width: LinkConfirmWindowController.width) {
            VStack(alignment: .leading, spacing: 14) {
                if let preview = prompt.preview {
                    ScrollView {
                        Text(preview)
                            .font(Brand.mono(12))
                            .foregroundStyle(Color.brand(Brand.ink))
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(height: 132)
                    .background(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous).fill(Color.brand(Brand.surfaceRaised)))
                    .overlay(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous).strokeBorder(Color.brand(Brand.line)))
                }
                if let hint = prompt.hint {
                    HStack(spacing: 12) {
                        BrandIconTile(symbol: "hand.raised", size: 28)
                        Text(hint)
                            .font(Brand.font(12.5))
                            .foregroundStyle(Color.brand(Brand.inkSoft))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } buttons: {
            Spacer()
            Button("Abbrechen", action: cancel)
                .buttonStyle(BrandButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
            Button(prompt.confirm, action: confirm)
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .opacity(model.armed ? 1 : 0.5)
                .overlay(alignment: .bottom) {
                    // Leiser Fortschritt der Schutzzeit unter dem Knopf; verschwindet, sobald er wirkt.
                    GeometryReader { geo in
                        Capsule().fill(Color.brand(Brand.line))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.brand(Brand.accent)).frame(width: geo.size.width * progress)
                            }
                    }
                    .frame(height: 2.5)
                    .offset(y: 8)
                    .opacity(model.armed ? 0 : 1)
                    .accessibilityHidden(true)
                }
        }
        .onAppear(perform: restartProgress)
        .onChange(of: model.presentations) { _, _ in restartProgress() }
        .animation(.easeOut(duration: 0.2), value: model.armed)
    }

    private func restartProgress() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { progress = 0 }
        // Erst im nächsten Durchlauf animieren, sonst fasst SwiftUI beide Änderungen zusammen.
        DispatchQueue.main.async {
            withAnimation(.linear(duration: LinkConfirmWindowController.armDelay)) { progress = 1 }
        }
    }
}
