import AppKit
import Sparkle

// Automatische Updates der Mac-App über Sparkle 2, ohne eigenen Server: Jede Version hängt ihr `appcast.xml` an das
// GitHub-Release, der Feed ist immer das des neuesten veröffentlichten Releases (`SUFeedURL`). Jede Version ist mit
// EdDSA signiert (`SUPublicEDKey`) und wird vor dem Entpacken geprüft, danach prüft Sparkle die Code-Signatur.
// Knips plant die Prüfung selbst (einmal am Tag, die erste einige Minuten nach dem Start), lädt im Hintergrund und
// installiert beim Beenden oder per Klick auf „Neu starten und aktualisieren“ — nie während einer Aufnahme, eines
// Scroll-Screenshots oder offener Schreibvorgänge (`QuitGuard`). Sparkle zeigt nie eigene Fenster: `UpdateDriver`
// meldet alles an `Updates`, Menü-Panel und Einstellungen zeigen es im Knips-Design.

/// Woher und ob überhaupt geprüft wird — rein aus Umgebung und Build-Art abgeleitet (wie `TelemetryConfig`).
struct UpdateConfig: Equatable, Sendable {
    static let defaultFeed = URL(string: "https://github.com/patrickbirkholz0000/knips/releases/latest/download/appcast.xml")!

    var feed: URL
    /// Feed aus `KNIPS_UPDATE_FEED` statt des echten (nur eigene Builds).
    var testChannel: Bool
    /// Grund, warum Knips nie nach Updates sucht (nil = erlaubt).
    var blockedReason: String?

    var enabled: Bool { blockedReason == nil }

    static var current: UpdateConfig {
        #if KNIPS_DEV
        let developerBuild = true
        #else
        let developerBuild = false
        #endif
        return resolve(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments, developerBuild: developerBuild)
    }

    /// Nie in Selbsttests, der Test-Sandbox oder CI. Eigene Builds (`build.sh`, `install.sh`) nur über den Testkanal
    /// `KNIPS_UPDATE_FEED` — sonst ersetzte sich ein Entwickler-Build durch das Release. Der Testkanal nimmt HTTPS oder
    /// HTTP auf 127.0.0.1/localhost. Im weitergegebenen Programm gilt immer `defaultFeed`: `KNIPS_UPDATE_FEED` wirkt dort
    /// nicht (wie `KNIPS_TELEMETRY_URL`), sonst könnte jedes Programm, das die Umgebung beim Start setzt, einen eigenen
    /// Feed unterschieben (installiert würde trotzdem nur, was mit dem Schlüssel von Knips signiert ist).
    static func resolve(environment env: [String: String], arguments: [String], developerBuild: Bool) -> UpdateConfig {
        var feed = defaultFeed
        var testChannel = false
        var invalidFeed = false
        #if KNIPS_DEV
        if developerBuild, let raw = env["KNIPS_UPDATE_FEED"], !raw.isEmpty {
            if let url = testFeed(raw) {
                feed = url
                testChannel = true
            } else {
                invalidFeed = true
            }
        }
        #endif
        let ci = ["CI", "GITHUB_ACTIONS", "TF_BUILD", "BUILDKITE", "JENKINS_URL"].contains { key in
            guard let value = env[key]?.lowercased() else { return false }
            return !value.isEmpty && value != "0" && value != "false"
        }
        let reason: String? =
            arguments.contains("--selftest") ? "Selbsttest"
            : !(env["KNIPS_TEST_DIR"] ?? "").isEmpty ? "Test-Sandbox"
            : ci ? "CI"
            : invalidFeed ? "KNIPS_UPDATE_FEED ungültig (https oder http://127.0.0.1)"
            : developerBuild && !testChannel ? "Eigener Build ohne KNIPS_UPDATE_FEED"
            : nil
        return UpdateConfig(feed: feed, testChannel: testChannel, blockedReason: reason)
    }

    /// Testkanal: HTTPS überall, HTTP nur auf diesem Mac.
    static func testFeed(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host) { return url }
        return nil
    }
}

/// Wann geprüft wird: frühestens `firstCheckDelay` nach dem Start, danach jede `checkEvery` nachsehen, ob die letzte
/// Prüfung `interval` her ist.
struct UpdateTiming: Equatable, Sendable {
    var interval: TimeInterval = 24 * 3600
    var firstCheckDelay: TimeInterval = 5 * 60
    var checkEvery: TimeInterval = 3600

    static let standard = UpdateTiming()

    /// Noch nie geprüft, 24 h vorbei oder die letzte Prüfung liegt (falsche Uhr) in der Zukunft.
    func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age < 0 || age >= interval
    }
}

enum UpdateState: Equatable {
    case idle
    /// Nur nach „Jetzt nach Updates suchen“ sichtbar.
    case checking
    /// `progress` nil = unbekannt (Laden im Hintergrund).
    case downloading(version: String, progress: Double?)
    /// Geladen, Sparkle prüft Signatur und Code-Signatur und packt aus.
    case verifying(version: String)
    /// Gefunden, wartet auf „Laden und installieren“ (z. B. wenn Sparkle nicht still laden darf).
    case available(version: String)
    /// Nur ein Hinweis auf eine neue Version, nichts zu installieren.
    case info(version: String, url: URL?)
    /// Geladen und geprüft: wird beim Beenden installiert oder per „Neu starten und aktualisieren“.
    case ready(version: String)
    case installing

    var version: String? {
        switch self {
        case let .downloading(version, _), let .verifying(version), let .available(version), let .info(version, _), let .ready(version): version
        case .idle, .checking, .installing: nil
        }
    }
}

/// Ergebnis der letzten Suche (Fehler nur nach „Jetzt nach Updates suchen“).
enum UpdateNote: Equatable {
    case upToDate
    case failed(String)
}

/// Zustand, Einstellung und Zeitplan der Updates. Sparkle läuft nur, wenn `config` es erlaubt — sonst entsteht nicht
/// einmal ein `SPUUpdater` (keine Anfrage, keine Einträge in den Einstellungen).
@MainActor final class Updates: NSObject, ObservableObject {
    static let shared = Updates(config: .current, timing: .standard, defaults: .knips)

    enum Key {
        static let automatic = "updateAutomatically"
    }

    let config: UpdateConfig
    let timing: UpdateTiming
    let defaults: UserDefaults

    @Published fileprivate(set) var state: UpdateState = .idle
    @Published fileprivate(set) var note: UpdateNote?
    @Published private(set) var lastCheck: Date?
    /// „Automatisch aktualisieren“ (Standard an): einmal am Tag prüfen und im Hintergrund laden.
    @Published var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: Key.automatic)
            if automatic, updater != nil { scheduleCheck(after: timing.firstCheckDelay) }
        }
    }

    private(set) var updater: SPUUpdater?
    private var driver: UpdateDriver?
    private var timer: Timer?
    /// Installiert sofort (Sparkle beendet Knips dafür und startet es neu).
    fileprivate var installAction: (() -> Void)?
    /// Lädt ein gefundenes Update (`available`).
    fileprivate var downloadAction: (() -> Void)?
    fileprivate var userInitiated = false

    #if KNIPS_DEV
    /// Selbsttest: Oberfläche mit festem Zustand (`simulate`).
    private var simulating = false
    /// Selbsttest: Feed für die nächste Prüfung.
    var feedOverride: URL?
    /// Selbsttest: wird bei jedem Ende einer Prüfung aufgerufen (Fehler oder nil).
    var onCycleFinished: ((Error?) -> Void)?
    /// Selbsttest: der letzte Fehler, den Sparkle gemeldet hat.
    var lastError: Error?
    #endif

    init(config: UpdateConfig, timing: UpdateTiming, defaults: UserDefaults) {
        self.config = config
        self.timing = timing
        self.defaults = defaults
        automatic = defaults.object(forKey: Key.automatic) as? Bool ?? true
        super.init()
    }

    /// Beim Start: Sparkle einrichten, erste Prüfung nach `firstCheckDelay`, danach stündlich nachsehen.
    func start() {
        guard config.enabled else {
            Log.info("Updates aus: \(config.blockedReason ?? "")")
            return
        }
        guard updater == nil else { return }
        let driver = UpdateDriver()
        driver.updates = self
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        // Nichts über Version, Sprache oder Gerät: GitHub sieht nur die Anfrage (und die IP-Adresse).
        updater.userAgentString = "Knips"
        updater.httpHeaders = ["Accept-Language": "*"]
        // GitHub setzt beim Weiterleiten Cookies. Zurückgeschickt würden sie Knips Tag für Tag wiedererkennbar machen.
        HTTPCookieStorage.shared.cookieAcceptPolicy = .never
        do {
            try updater.start()
        } catch {
            Log.error("Updates: Sparkle startet nicht: \(error.localizedDescription)")
            return
        }
        self.driver = driver
        self.updater = updater
        lastCheck = updater.lastUpdateCheckDate
        Log.info("Updates an: \(config.testChannel ? config.feed.absoluteString : "GitHub"), automatisch \(automatic ? "an" : "aus")")
        scheduleCheck(after: timing.firstCheckDelay)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timing.checkEvery, repeats: true) { [weak self] _ in
            onMainActor { self?.checkIfDue() }
        }
        timer?.tolerance = min(600, timing.checkEvery / 10)
    }

    private func scheduleCheck(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            onMainActor { self?.checkIfDue() }
        }
    }

    /// Automatische Prüfung im Hintergrund, höchstens einmal in 24 h. Lädt ein neues Update still, ohne Fenster.
    func checkIfDue(now: Date = Date()) {
        guard automatic, let updater, !updater.sessionInProgress else { return }
        switch state {
        case .idle, .info: break
        default: return   // läuft schon, ist geladen oder wartet auf einen Klick
        }
        lastCheck = updater.lastUpdateCheckDate
        guard timing.isDue(lastCheck: lastCheck, now: now) else { return }
        updater.checkForUpdatesInBackground()
    }

    /// Sparkle läuft (oder der Selbsttest zeigt einen Zustand) — sonst sind Knöpfe und Schalter der Updates aus.
    var isActive: Bool {
        #if KNIPS_DEV
        if simulating { return true }
        #endif
        return updater != nil
    }

    /// „Jetzt nach Updates suchen“ geht, solange nichts anderes läuft.
    var canCheck: Bool {
        switch state {
        case .idle, .info: break
        default: return false
        }
        #if KNIPS_DEV
        if simulating { return true }
        #endif
        guard let updater else { return false }
        return !updater.sessionInProgress
    }

    /// „Jetzt nach Updates suchen“: zeigt den Verlauf in den Einstellungen und lädt ein gefundenes Update gleich.
    func checkNow() {
        guard canCheck, let updater else { return }
        note = nil
        userInitiated = true
        updater.checkForUpdates()
    }

    /// Ein Update, das gerade nicht installiert werden darf: während einer Aufnahme, eines Scroll-Screenshots oder offener
    /// Schreibvorgänge. Knips würde sonst mitten darin beendet.
    var installBlocked: Bool { QuitGuard.needsTime }

    /// „Neu starten und aktualisieren“.
    func installNow() {
        guard let action = installAction, !installBlocked else { return }
        installAction = nil
        state = .installing
        action()
    }

    /// „Laden und installieren“ für ein gefundenes Update.
    func download() {
        guard let action = downloadAction else { return }
        downloadAction = nil
        action()
    }

    /// Der Knopf im Menü-Panel: installieren, laden oder (nur ein Hinweis) die Release-Seite öffnen.
    func continueUpdate() {
        switch state {
        case .ready: installNow()
        case .available: download()
        case let .info(_, url): NSWorkspace.shared.open(url ?? AboutPane.sourceURL.appendingPathComponent("releases/latest"))
        default: break
        }
    }

    /// Ein Satz für die Einstellungen (Fehler nur nach „Jetzt nach Updates suchen“).
    static func message(for error: Error) -> String {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if ns.domain == NSURLErrorDomain || underlying?.domain == NSURLErrorDomain {
            return "Keine Verbindung zu GitHub. Später noch einmal versuchen."
        }
        guard ns.domain == SUSparkleErrorDomain, let code = SUError(rawValue: OSStatus(ns.code)) else {
            return "Das hat nicht geklappt. Später noch einmal versuchen."
        }
        switch code {
        case .noUpdateError:
            if let raw = ns.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber, SPUNoUpdateFoundReason(rawValue: raw.int32Value) == .systemIsTooOld {
                return "Die neue Version braucht ein neueres macOS."
            }
            return "Knips ist auf dem neuesten Stand."
        case .downloadError, .temporaryDirectoryError:
            return "Das Update ließ sich nicht laden. Später noch einmal versuchen."
        case .unarchivingError, .signatureError, .validationError, .installationError, .notValidUpdateError:
            return "Das Update hat die Prüfung nicht bestanden und wurde verworfen."
        case .runningFromDiskImageError, .runningTranslocated:
            return "Erst Knips in den Programme-Ordner ziehen und von dort starten, dann aktualisieren."
        case .installationWriteNoPermissionError, .fileCopyFailure, .authenticationFailure:
            return "Knips darf sich an seinem Ort nicht selbst ersetzen."
        case .appcastParseError, .appcastError:
            return "Die Liste der Versionen ist gerade nicht lesbar. Später noch einmal versuchen."
        default:
            return "Das hat nicht geklappt. Später noch einmal versuchen."
        }
    }

    /// „heute, 14:02“, „gestern, 09:10“, sonst „12.10.2026“.
    static func describe(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "de_DE")))
        if calendar.isDate(date, inSameDayAs: now) { return "heute, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "gestern, \(time)"
        }
        return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(Locale(identifier: "de_DE")))
    }

    #if KNIPS_DEV
    /// Selbsttest: fester Zustand für die Bilder der Oberfläche; `active: false` beendet das.
    func simulate(_ state: UpdateState, note: UpdateNote? = nil, lastCheck: Date? = nil, active: Bool = true) {
        simulating = active
        self.state = state
        self.note = note
        self.lastCheck = lastCheck
        installAction = state.isReady ? {} : nil
        downloadAction = nil
        if case .available = state { downloadAction = {} }
    }

    /// Selbsttest: Prüfung im Hintergrund sofort, ohne auf den Zeitplan zu warten.
    func checkInBackgroundNow() {
        updater?.checkForUpdatesInBackground()
    }
    #endif

    fileprivate func refreshLastCheck() {
        if let date = updater?.lastUpdateCheckDate { lastCheck = date }
    }
}

extension UpdateState {
    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

// MARK: - Sparkle-Delegate

extension Updates: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if KNIPS_DEV
        if let feedOverride { return feedOverride.absoluteString }
        #endif
        // nil: der Feed aus der Info.plist (`SUFeedURL` = `UpdateConfig.defaultFeed`).
        return config.testChannel ? config.feed.absoluteString : nil
    }

    /// Doppelte Sicherung: Ist `config` gesperrt, gibt es zwar keinen `SPUUpdater` — falls doch, prüft er nie.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let reason = config.blockedReason {
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.incorrectAPIUsageError.rawValue),
                          userInfo: [NSLocalizedDescriptionKey: "Updates aus: \(reason)"])
        }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        request.httpShouldHandleCookies = false
        // Im Hintergrund (ohne Fortschritt); von Hand meldet `UpdateDriver` gleich danach den Fortschritt.
        if state == .idle { state = .downloading(version: item.displayVersionString, progress: nil) }
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        if case .downloading = state { state = .verifying(version: item.displayVersionString) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let tooOld = reason.flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) } == .systemIsTooOld
        note = tooOld ? .failed(Self.message(for: error)) : .upToDate
    }

    /// Im Hintergrund geladen und geprüft: Knips merkt sich das sofortige Installieren für den Knopf
    /// „Neu starten und aktualisieren“; sonst installiert Sparkle beim Beenden.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installAction = immediateInstallHandler
        state = .ready(version: item.displayVersionString)
        Log.info("Update \(item.displayVersionString) (\(item.versionString)) geladen, wird beim Beenden installiert")
        return true
    }

    /// Letzte Sicherung vor dem Neustart: läuft gerade eine Aufnahme oder wird geschrieben, wartet die Installation.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard QuitGuard.needsTime else { return false }
        func waitUntilIdle() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                onMainActor { QuitGuard.needsTime ? waitUntilIdle() : installHandler() }
            }
        }
        waitUntilIdle()
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        #if KNIPS_DEV
        lastError = error
        #endif
        let code = (error as NSError).code
        if (error as NSError).domain == SUSparkleErrorDomain, code == Int(SUError.noUpdateError.rawValue) { return }
        Log.error("Update abgebrochen: \(error.localizedDescription)")
        switch state {
        case .checking, .downloading, .verifying, .available, .ready, .installing:
            state = .idle
            installAction = nil
            downloadAction = nil
        case .idle, .info:
            break
        }
        if userInitiated { note = .failed(Self.message(for: error)) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        refreshLastCheck()
        userInitiated = false
        #if KNIPS_DEV
        onCycleFinished?(error)
        #endif
    }
}

// MARK: - Oberfläche für Sparkle

/// Ersetzt Sparkles Fenster: Jeder Schritt landet als Zustand in `Updates`, angezeigt in Menü-Panel und Einstellungen.
/// Bei der automatischen Prüfung ruft Sparkle hier fast nichts auf (still laden), bei „Jetzt nach Updates suchen“ den
/// ganzen Ablauf.
@MainActor final class UpdateDriver: NSObject, SPUUserDriver {
    weak var updates: Updates?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var version = ""

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Kommt wegen `SUEnableAutomaticChecks` nicht vor. Knips plant selbst und sendet kein Systemprofil.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        updates?.state = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let updates else { return reply(.dismiss) }
        version = appcastItem.displayVersionString
        if appcastItem.isInformationOnlyUpdate {
            updates.state = .info(version: version, url: appcastItem.infoURL)
            reply(.dismiss)
            return
        }
        switch state.stage {
        case .installing:
            // Schon geladen und vorbereitet (z. B. nach einer Prüfung von Hand): wartet auf Beenden oder den Knopf.
            updates.installAction = { reply(.install) }
            updates.state = .ready(version: version)
        default:
            if state.userInitiated {
                // Von Hand gesucht: gleich laden, installiert wird erst beim Beenden oder per Knopf.
                updates.state = state.stage == .downloaded ? .verifying(version: version) : .downloading(version: version, progress: 0)
                reply(.install)
            } else {
                let version = version
                updates.downloadAction = { [weak updates] in
                    updates?.state = .downloading(version: version, progress: 0)
                    reply(.install)
                }
                updates.state = .available(version: version)
            }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        updates?.state = .idle
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        #if KNIPS_DEV
        updates?.lastError = error
        #endif
        if let updates {
            updates.state = .idle
            updates.installAction = nil
            updates.downloadAction = nil
            updates.note = .failed(Updates.message(for: error))
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0
        received = 0
        updates?.state = .downloading(version: version, progress: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        guard expected > 0 else { return }
        updates?.state = .downloading(version: version, progress: min(1, Double(received) / Double(expected)))
    }

    func showDownloadDidStartExtractingUpdate() {
        updates?.state = .verifying(version: version)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let updates else { return reply(.dismiss) }
        // Antwort erst beim Klick auf „Neu starten und aktualisieren“; beendet sich Knips vorher, installiert Sparkle dann.
        updates.installAction = { reply(.install) }
        updates.state = .ready(version: version)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        updates?.state = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        SettingsWindowController.show(.about)
    }

    /// Ende einer Prüfung: Zustände, die auf eine Antwort an Sparkle warten, verfallen. Geladene Updates aus dem
    /// Hintergrund (`willInstallUpdateOnQuit`) und reine Hinweise bleiben.
    func dismissUpdateInstallation() {
        guard let updates else { return }
        switch updates.state {
        case .checking, .downloading, .verifying, .available, .installing:
            updates.state = .idle
            updates.downloadAction = nil
        case .ready, .idle, .info:
            break
        }
    }
}
