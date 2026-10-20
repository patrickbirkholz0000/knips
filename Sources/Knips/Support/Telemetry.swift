import Foundation

// Anonyme Nutzungsstatistik (Opt-in, Vertrag v1 — gleich für macOS, Windows und den Worker).
// Gezählt wird nur, welche Funktionen wie oft genutzt werden. Nie Bilder, Texte, Dateinamen,
// Fenstertitel, App-Namen, Bildschirmgrößen oder Zeiten. Gesendet wird höchstens einmal pro 24 h.

/// Erlaubte Ereignisse — der Server verwirft alles andere.
enum TelemetryEvent: String, CaseIterable, Sendable {
    case appLaunch = "app_launch"
    case captureArea = "capture_area"
    case captureWindow = "capture_window"
    case captureFullscreen = "capture_fullscreen"
    case captureLastArea = "capture_last_area"
    case captureScroll = "capture_scroll"
    case captureText = "capture_text"
    case recordingStart = "recording_start"
    case recordingSaved = "recording_saved"
    case editorOpen = "editor_open"
    case videoEditorOpen = "video_editor_open"
    case censorManual = "censor_manual"
    case censorAuto = "censor_auto"
    case censorSmart = "censor_smart"
    case exportPNG = "export_png"
    case exportJPEG = "export_jpeg"
    case exportMP4 = "export_mp4"
    case exportGIF = "export_gif"
    case copyImage = "copy_image"
    case copyText = "copy_text"
    case pin = "pin"
    case dragOut = "drag_out"
    case historyOpen = "history_open"
    case settingsOpen = "settings_open"
}

/// Wohin und ob überhaupt gesendet wird — rein aus Umgebung und Build-Art abgeleitet.
struct TelemetryConfig: Equatable, Sendable {
    static let defaultEndpoint = URL(string: "https://knips.velno.ai/v1/ping")!

    var endpoint: URL
    var channel: String
    /// Grund, warum weder gefragt noch gezählt noch gesendet wird (nil = erlaubt).
    var blockedReason: String?

    var enabled: Bool { blockedReason == nil }

    static var current: TelemetryConfig {
        #if KNIPS_DEV
        let developerBuild = true
        #else
        let developerBuild = false
        #endif
        return resolve(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments, developerBuild: developerBuild)
    }

    /// Nie in Selbsttests, der Test-Sandbox oder CI. Entwickler-Builds nur mit `KNIPS_TELEMETRY=1` (Kanal „dev“).
    /// `KNIPS_TELEMETRY_URL` ersetzt den Endpunkt (Basis-URL oder vollständige Ping-URL).
    static func resolve(environment env: [String: String], arguments: [String], developerBuild: Bool) -> TelemetryConfig {
        var endpoint = defaultEndpoint
        if let raw = env["KNIPS_TELEMETRY_URL"], let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? ""), url.host != nil {
            endpoint = url.path.isEmpty || url.path == "/" ? url.appendingPathComponent("v1/ping") : url
        }
        let ci = ["CI", "GITHUB_ACTIONS", "TF_BUILD", "BUILDKITE", "JENKINS_URL"].contains { key in
            guard let value = env[key]?.lowercased() else { return false }
            return !value.isEmpty && value != "0" && value != "false"
        }
        let reason: String? =
            arguments.contains("--selftest") ? "Selbsttest"
            : !(env["KNIPS_TEST_DIR"] ?? "").isEmpty ? "Test-Sandbox"
            : ci ? "CI"
            : developerBuild && env["KNIPS_TELEMETRY"] != "1" ? "Entwickler-Build ohne KNIPS_TELEMETRY=1"
            : nil
        return TelemetryConfig(endpoint: endpoint, channel: developerBuild ? "dev" : "release", blockedReason: reason)
    }
}

/// Feste Angaben zu App und System, die jedem Ping beiliegen.
struct TelemetryClientInfo: Equatable, Sendable {
    var platform = "macos"
    var channel: String
    var appVersion: String
    var build: String
    var osVersion: String
    var arch: String
    var lang: String

    static func current(channel: String) -> TelemetryClientInfo {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return TelemetryClientInfo(channel: channel,
                                   appVersion: info?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                                   build: info?["CFBundleVersion"] as? String ?? "1",
                                   osVersion: "\(os.majorVersion).\(os.minorVersion)",
                                   arch: arch,
                                   lang: language(Locale.preferredLanguages.first))
    }

    /// Nur die zwei Buchstaben der Sprache („de-DE“ → „de“), sonst „xx“.
    static func language(_ identifier: String?) -> String {
        let code = String((identifier ?? "").prefix { $0.isLetter }.prefix(2)).lowercased()
        return code.count == 2 && code.allSatisfy({ $0.isASCII }) ? code : "xx"
    }
}

/// Baut den Ping — reine Funktion, damit der Selbsttest genau prüfen kann, was hinausgeht.
enum TelemetryPayload {
    static let keys: Set<String> = ["v", "app", "platform", "channel", "app_version", "build", "os_version", "arch", "lang", "install_id", "events"]
    static let maxCount = 10_000

    /// Nur erlaubte Ereignisse, jeder Zähler auf 1…10000 begrenzt, Nullen fallen weg.
    static func events(_ counts: [String: Int]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (name, count) in counts where TelemetryEvent(rawValue: name) != nil && count > 0 {
            result[name] = min(count, maxCount)
        }
        return result
    }

    static func body(info: TelemetryClientInfo, installID: String, counts: [String: Int]) -> [String: Any] {
        [
            "v": 1,
            "app": "knips",
            "platform": info.platform,
            "channel": info.channel,
            "app_version": info.appVersion,
            "build": info.build,
            "os_version": info.osVersion,
            "arch": info.arch,
            "lang": info.lang,
            "install_id": installID,
            "events": events(counts),
        ]
    }

    static func json(info: TelemetryClientInfo, installID: String, counts: [String: Int]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body(info: info, installID: installID, counts: counts), options: [.sortedKeys])) ?? Data()
    }
}

/// Zustimmung, Zähler und Versand. Zustand in den UserDefaults (`telemetry…`), in der Test-Sandbox
/// in einer eigenen Domäne — die echte Zustimmung wird dort nie angefasst.
@MainActor final class Telemetry: ObservableObject {
    static let infoURL = URL(string: "https://github.com/patrickbirkholz0000/knips#datenschutz")!
    static let sandboxSuite = UserDefaults.sandboxSuite

    static let shared = Telemetry(defaults: .knips, config: .current)

    enum Key {
        static let consent = "telemetryConsent"
        static let installID = "telemetryInstallID"
        static let counts = "telemetryCounts"
        static let lastSent = "telemetryLastSent"
    }

    enum SendResult: Equatable {
        case skipped(String)
        case sent(Int)
        case failed(String)
    }

    static let interval: TimeInterval = 24 * 3600
    static let checkEvery: TimeInterval = 6 * 3600
    static let firstCheckDelay: TimeInterval = 30

    let config: TelemetryConfig
    let defaults: UserDefaults
    /// nil = noch nicht gefragt.
    @Published private(set) var consent: Bool?
    private let session: URLSession
    private var sending = false
    private var askedThisLaunch = false
    private var timer: Timer?

    init(defaults: UserDefaults, config: TelemetryConfig) {
        self.defaults = defaults
        self.config = config
        consent = defaults.object(forKey: Key.consent) as? Bool
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    var installID: String? { defaults.string(forKey: Key.installID) }
    var counts: [String: Int] { defaults.dictionary(forKey: Key.counts) as? [String: Int] ?? [:] }
    var lastSent: Date? { defaults.object(forKey: Key.lastSent) as? Date }
    var isCounting: Bool { config.enabled && consent == true }
    var shouldAsk: Bool { config.enabled && consent == nil && !askedThisLaunch }

    /// Hook an den Aufrufstellen: `Telemetry.count(.captureArea)`.
    static func count(_ event: TelemetryEvent) { shared.record(event) }

    func record(_ event: TelemetryEvent) {
        guard isCounting else { return }
        var c = counts
        c[event.rawValue] = min((c[event.rawValue] ?? 0) + 1, TelemetryPayload.maxCount)
        defaults.set(c, forKey: Key.counts)
    }

    /// Ja: neue zufällige Kennung, ab jetzt zählen. Nein: Kennung und offene Zähler sofort löschen.
    func setConsent(_ on: Bool) {
        consent = on
        defaults.set(on, forKey: Key.consent)
        defaults.removeObject(forKey: Key.counts)
        defaults.removeObject(forKey: Key.lastSent)
        if on {
            defaults.set(UUID().uuidString.lowercased(), forKey: Key.installID)
            if config.enabled { scheduleCheck(after: Self.firstCheckDelay) }
        } else {
            defaults.removeObject(forKey: Key.installID)
        }
    }

    /// Dialog geschlossen ohne Wahl: zählt als Nein, beim nächsten Start wird erneut gefragt.
    func markAsked() { askedThisLaunch = true }

    /// Beim Start: Start zählen, nach ~30 s und dann alle 6 h prüfen, ob gesendet werden soll.
    func start() {
        guard config.enabled else {
            Log.info("Nutzungsstatistik aus: \(config.blockedReason ?? "")")
            return
        }
        record(.appLaunch)
        scheduleCheck(after: Self.firstCheckDelay)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sendIfDue() }
        }
        timer?.tolerance = 600
    }

    private func scheduleCheck(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            Task { @MainActor in await self?.sendIfDue() }
        }
    }

    /// Sendet die gesammelten Zähler, höchstens einmal pro 24 h. Erfolg: Zähler zurücksetzen und Zeit merken;
    /// Fehler: Zähler bleiben für die nächste Prüfung. Netzwerk läuft im Hintergrund, 10 s Zeitlimit, kein Wiederholen.
    @discardableResult
    func sendIfDue(now: Date = Date(), force: Bool = false) async -> SendResult {
        guard config.enabled else { return .skipped(config.blockedReason ?? "gesperrt") }
        guard consent == true, let id = installID else { return .skipped("keine Zustimmung") }
        guard !sending else { return .skipped("läuft bereits") }
        if !force, let last = lastSent {
            let age = now.timeIntervalSince(last)
            if age >= 0, age < Self.interval { return .skipped("letzter Versand vor weniger als 24 h") }
        }
        let snapshot = TelemetryPayload.events(counts)
        var request = URLRequest(url: config.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Knips", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.httpBody = TelemetryPayload.json(info: .current(channel: config.channel), installID: id, counts: snapshot)
        sending = true
        defer { sending = false }
        let status: Int
        do {
            let (_, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return .failed(error.localizedDescription)
        }
        guard (200..<300).contains(status) else { return .failed("HTTP \(status)") }
        // Während des Versands abgemeldet oder neu angemeldet: nichts zurückschreiben.
        guard consent == true, installID == id else { return .sent(status) }
        var rest = counts
        for (name, sent) in snapshot {
            let left = (rest[name] ?? 0) - sent
            rest[name] = left > 0 ? left : nil
        }
        defaults.set(rest, forKey: Key.counts)
        defaults.set(now, forKey: Key.lastSent)
        return .sent(status)
    }
}
