#if KNIPS_DEV
import AppKit
import Combine
import Darwin
import Sparkle

extension SelfTest {
    /// Kennung der Testkopien aus `scripts/update-test.sh`. Eigene Kennung: eigene Einstellungen (Sparkles
    /// `SULastCheckTime` & Co.), eigene Caches und ein eigener Installer — die echte App und ihre Domäne bleiben unberührt.
    static let updateTestID = "de.birkgroup.knips.aktualisierungstest"

    /// Automatische Updates: Sperren, Zeitplan, Info.plist, Bundle, Texte. Mit `<feed-ordner>` (nur in der alten Testkopie
    /// aus `scripts/update-test.sh`) zusätzlich Ende zu Ende gegen einen lokalen Server: Gegenproben (Einstellung aus,
    /// gleiche und ältere Version, falsche Signatur im Hintergrund und von Hand), dann lädt, prüft und bereitet die App das
    /// neue Update vor und beendet sich — Sparkle installiert es beim Beenden, ohne Neustart. Nie ein Fenster.
    static func update(_ out: URL, feedDir: URL?) async throws {
        var failed: [String] = []
        func check(_ ok: Bool, _ name: String) {
            print("   \(ok ? "ok    " : "FALSCH") \(name)")
            if !ok { failed.append(name) }
        }
        func resolve(_ env: [String: String], args: [String] = ["Knips"], dev: Bool) -> UpdateConfig {
            UpdateConfig.resolve(environment: env, arguments: args, developerBuild: dev)
        }

        // 1) Wann geprüft werden darf
        let release = resolve([:], dev: false)
        check(release.enabled && !release.testChannel && release.feed == UpdateConfig.defaultFeed && release.feed.scheme == "https",
              "Weitergabe-Build: erlaubt, \(release.feed.absoluteString)")
        let releaseFeed = resolve(["KNIPS_UPDATE_FEED": "http://127.0.0.1:9/appcast.xml"], dev: false)
        check(releaseFeed.enabled && releaseFeed.feed == UpdateConfig.defaultFeed && !releaseFeed.testChannel,
              "Weitergabe-Build: KNIPS_UPDATE_FEED wirkt nicht")
        check(!resolve([:], dev: true).enabled, "Eigener Build ohne Testkanal: nie eine Prüfung (\(resolve([:], dev: true).blockedReason ?? "-"))")
        let local = resolve(["KNIPS_UPDATE_FEED": "http://127.0.0.1:9/appcast.xml"], dev: true)
        check(local.enabled && local.testChannel && local.feed.absoluteString == "http://127.0.0.1:9/appcast.xml",
              "Eigener Build mit KNIPS_UPDATE_FEED=http://127.0.0.1: Testkanal")
        check(resolve(["KNIPS_UPDATE_FEED": "https://example.org/appcast.xml"], dev: true).testChannel,
              "Testkanal über HTTPS")
        check(!resolve(["KNIPS_UPDATE_FEED": "http://example.org/appcast.xml"], dev: true).enabled
              && !resolve(["KNIPS_UPDATE_FEED": "kaputt"], dev: true).enabled, "Testkanal: HTTP nur auf diesem Mac, Unsinn gesperrt")
        check(!resolve(["KNIPS_TEST_DIR": "/tmp/x"], dev: false).enabled
              && !resolve(["KNIPS_TEST_DIR": "/tmp/x", "KNIPS_UPDATE_FEED": "http://127.0.0.1:9/a.xml"], dev: true).enabled,
              "Test-Sandbox: nie eine Prüfung, auch nicht mit Testkanal")
        check(!resolve([:], args: ["Knips", "--selftest", "render", "/tmp/x"], dev: false).enabled, "Selbsttest: nie eine Prüfung")
        check(!resolve(["CI": "true"], dev: false).enabled && !resolve(["GITHUB_ACTIONS": "true"], dev: false).enabled
              && resolve(["CI": "false"], dev: false).enabled, "CI: nie eine Prüfung")
        check(!UpdateConfig.current.enabled, "dieser Prozess (--selftest): gesperrt — \(UpdateConfig.current.blockedReason ?? "-")")
        Updates.shared.start()
        check(Updates.shared.updater == nil && !Updates.shared.isActive, "Updates.shared startet hier kein Sparkle")

        // 2) Zeitplan
        let timing = UpdateTiming.standard
        let now = Date()
        check(timing.firstCheckDelay >= 60 && timing.interval == 24 * 3600 && timing.checkEvery <= 3600,
              "Erste Prüfung nach \(Int(timing.firstCheckDelay)) s, dann höchstens alle 24 h (nachsehen alle \(Int(timing.checkEvery)) s)")
        check(timing.isDue(lastCheck: nil, now: now) && !timing.isDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now)
              && timing.isDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now)
              && timing.isDue(lastCheck: now.addingTimeInterval(3600), now: now),
              "Fällig: nie geprüft, nach 24 h, bei Uhr in der Zukunft; nach 23 h nicht")
        let offSuite = "de.birkgroup.knips.selftest.update"
        guard let offDefaults = UserDefaults(suiteName: offSuite) else { throw CheckFailed(message: "Defaults-Domäne fehlt") }
        offDefaults.removePersistentDomain(forName: offSuite)
        defer { offDefaults.removePersistentDomain(forName: offSuite) }
        let fresh = Updates(config: release, timing: timing, defaults: offDefaults)
        check(fresh.automatic, "„Automatisch aktualisieren“ ist anfangs an")
        fresh.automatic = false
        check(Updates(config: release, timing: timing, defaults: offDefaults).automatic == false, "„Automatisch aktualisieren“ aus bleibt gespeichert")

        // 3) Info.plist und Bundle
        let info = Bundle.main.infoDictionary ?? [:]
        let key = (info["SUPublicEDKey"] as? String).flatMap { Data(base64Encoded: $0) }
        check(key?.count == 32, "SUPublicEDKey: öffentlicher EdDSA-Schlüssel (32 Byte)")
        check(info["SUFeedURL"] as? String == UpdateConfig.defaultFeed.absoluteString, "SUFeedURL = \(UpdateConfig.defaultFeed.absoluteString)")
        check(info["SUEnableAutomaticChecks"] as? Bool == false && info["SUAllowsAutomaticUpdates"] as? Bool == true
              && info["SUAutomaticallyUpdate"] as? Bool == true, "Sparkle plant nicht selbst, lädt im Hintergrund")
        check(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true, "EdDSA-Prüfung vor dem Entpacken")
        check(info["NSAppTransportSecurity"] == nil, "Keine ATS-Ausnahme")
        check(info["SUEnableInstallerLauncherService"] == nil && info["SUEnableDownloaderService"] == nil, "XPC-Dienste aus (nicht sandboxed)")
        let framework = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        let fm = FileManager.default
        check(fm.fileExists(atPath: framework.appendingPathComponent("Versions/B/Sparkle").path)
              && fm.fileExists(atPath: framework.appendingPathComponent("Versions/B/Autoupdate").path)
              && fm.fileExists(atPath: framework.appendingPathComponent("Versions/B/Updater.app").path),
              "Sparkle.framework mit Autoupdate und Updater.app in Contents/Frameworks")
        check(!fm.fileExists(atPath: framework.appendingPathComponent("Versions/B/XPCServices").path)
              && !fm.fileExists(atPath: framework.appendingPathComponent("Versions/B/Headers").path), "ohne XPC-Dienste und Header")
        check(Bundle.main.url(forResource: "Sparkle-LICENSE", withExtension: "txt") != nil, "Lizenztext von Sparkle liegt bei")

        // 4) Sparkle ruft Knips über diese Methoden (falsch geschriebene optionale Methoden fielen sonst nicht auf)
        let selectors = ["feedURLStringForUpdater:", "updater:mayPerformUpdateCheck:error:",
                         "updaterShouldPromptForPermissionToCheckForUpdates:", "updater:shouldDownloadReleaseNotesForUpdate:",
                         "updater:willDownloadUpdate:withRequest:", "updater:willExtractUpdate:", "updaterDidNotFindUpdate:error:",
                         "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
                         "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:", "updater:didAbortWithError:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:"]
        let missing = selectors.filter { !Updates.instancesRespond(to: NSSelectorFromString($0)) }
            + (UpdateDriver.instancesRespond(to: NSSelectorFromString("showUpdateInFocus")) ? [] : ["showUpdateInFocus"])
        check(missing.isEmpty, "Delegate und Oberfläche: \(selectors.count + 1) Methoden\(missing.isEmpty ? "" : ", fehlen: \(missing.joined(separator: ", "))")")

        // 5) Texte
        let validation = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue))
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        check(Updates.message(for: validation).contains("Prüfung") && Updates.message(for: offline).contains("Verbindung"),
              "Fehlertexte: „\(Updates.message(for: validation))“")
        let today = Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: now) ?? now
        check(Updates.describe(today, now: today) == "heute, 14:02"
              && Updates.describe(today.addingTimeInterval(-24 * 3600), now: today) == "gestern, 14:02",
              "Letzte Prüfung: „\(Updates.describe(today, now: today))“")

        if let feedDir {
            try await updateEndToEnd(feedDir, check: check)
        } else {
            print("   (Ende zu Ende mit zwei Builds: scripts/update-test.sh)")
        }
        if !failed.isEmpty { throw CheckFailed(message: "Updates: \(failed.joined(separator: "; "))") }
    }

    /// Alte Testkopie gegen den lokalen Feed. Endet mit einem geladenen, geprüften Update, das Sparkle beim Beenden
    /// dieses Prozesses installiert (`update-installed` prüft das danach).
    private static func updateEndToEnd(_ feedDir: URL, check: (Bool, String) -> Void) async throws {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == updateTestID else {
            throw CheckFailed(message: "Ende zu Ende nur in der Testkopie aus scripts/update-test.sh (Kennung \(updateTestID))")
        }
        guard !bundle.bundlePath.hasPrefix("/Applications") else { throw CheckFailed(message: "Testkopie liegt in /Applications") }
        let appURL = bundle.bundleURL
        let oldBuild = AppVersion.build
        let newVersion = AppVersion.short
        print("   Testkopie \(appURL.path), Build \(oldBuild)")
        // Sparkles Zustand der Testkopie (letzte Prüfung …) — eigene Domäne, nie die echte.
        UserDefaults.standard.removePersistentDomain(forName: updateTestID)

        let server = try TestHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let base = "http://localhost:\(port)"
        server.responder = { request in
            let name = String(request.path.split(separator: "?").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard request.method == "GET", !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
                  let data = try? Data(contentsOf: feedDir.appendingPathComponent(name)) else { return .init(status: 404) }
            if name.hasSuffix(".xml") {
                // Ein Cookie wie bei GitHub — zurückkommen darf es nie.
                let xml = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "__BASE__", with: base)
                return .init(status: 200, headers: ["Content-Type": "application/xml", "Set-Cookie": "knips-test=1; Path=/"], body: Data(xml.utf8))
            }
            return .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: data)
        }
        func requests(_ suffix: String) -> Int { server.requests.filter { $0.path.hasSuffix(suffix) }.count }
        func onDisk() -> String {
            (NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String) ?? "?"
        }

        let suite = "de.birkgroup.knips.selftest.update"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailed(message: "Defaults-Domäne fehlt") }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = Updates(config: UpdateConfig(feed: URL(string: "\(base)/appcast-gleich.xml")!, testChannel: true, blockedReason: nil),
                              timing: UpdateTiming(interval: 24 * 3600, firstCheckDelay: 0.3, checkEvery: 0.3), defaults: defaults)
        var cycles: [Error?] = []
        updates.onCycleFinished = { cycles.append($0) }
        var states: [UpdateState] = []
        let observer = updates.$state.sink { states.append($0) }
        defer { observer.cancel() }
        var windows = Set<String>()
        /// Wartet höchstens `seconds`, bis `condition` gilt, und sieht dabei nach sichtbaren Fenstern.
        func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                windows.formUnion(updateWindows(near: appURL))
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return condition()
        }
        /// Sparkles Installer (läuft aus dem Bundle der Testkopie) hat sich nach einem abgelehnten Update beendet.
        func installerGone() -> Bool {
            !(updates.updater?.sessionInProgress ?? true)
                && processes(containing: realPath(appURL.appendingPathComponent("Contents/Frameworks"))).isEmpty
                && processes(containing: updateTestID).isEmpty
        }
        /// Zustände in Kurzform, ohne Wiederholungen: „Suche → Laden → Prüfen → aus“.
        func flow() -> String {
            let labels = states.map { state -> String in
                switch state {
                case .idle: "aus"
                case .checking: "Suche"
                case .downloading: "Laden"
                case .verifying: "Prüfen"
                case .available: "gefunden"
                case .info: "Hinweis"
                case .ready: "bereit"
                case .installing: "Installieren"
                }
            }
            return labels.enumerated().filter { $0.offset == 0 || labels[$0.offset - 1] != $0.element }.map(\.element).joined(separator: " → ")
        }

        // a) Einstellung aus: keine automatische Prüfung
        updates.automatic = false
        updates.start()
        check(updates.isActive, "Sparkle läuft in der Testkopie (Testkanal \(base))")
        _ = await wait(1.5) { false }
        check(server.requests.isEmpty, "Automatisch aktualisieren aus: keine Prüfung (1,5 s bei Takt 0,3 s)")

        // b) Einstellung an, Feed mit derselben Version: genau eine Prüfung, nichts geladen
        updates.feedOverride = URL(string: "\(base)/appcast-gleich.xml")
        updates.automatic = true
        check(await wait(15) { cycles.count == 1 }, "Einstellung an: Prüfung nach \(updates.timing.firstCheckDelay) s")
        check(requests("/appcast-gleich.xml") == 1 && requests(".dmg") == 0 && updates.state == .idle && updates.note == .upToDate,
              "Gleiche Version im Feed: nichts geladen, „auf dem neuesten Stand“")
        check(updates.lastCheck != nil, "Letzte Prüfung gemerkt: \(updates.lastCheck.map { Updates.describe($0) } ?? "-")")
        _ = await wait(1.5) { false }
        check(server.requests.count == 1, "Innerhalb von 24 h keine zweite Prüfung (\(server.requests.count) Anfrage)")

        // c) Ältere Version im Feed
        updates.feedOverride = URL(string: "\(base)/appcast-aelter.xml")
        updates.checkInBackgroundNow()
        check(await wait(15) { cycles.count == 2 }, "Prüfung mit älterer Version beendet")
        check(requests("/appcast-aelter.xml") == 1 && requests(".dmg") == 0 && updates.state == .idle, "Ältere Version im Feed: nichts geladen")

        // d) Falsche EdDSA-Signatur, im Hintergrund
        updates.feedOverride = URL(string: "\(base)/appcast-falsch.xml")
        updates.checkInBackgroundNow()
        check(await wait(60) { cycles.count == 3 }, "Prüfung mit falscher Signatur beendet")
        let backgroundError = cycles.count >= 3 ? cycles[2].map { $0 as NSError } : nil
        check(requests(".dmg") == 1 && backgroundError != nil && !updates.state.isReady && onDisk() == oldBuild,
              "Falsche Signatur im Hintergrund: geladen, abgelehnt (\(backgroundError.map { "\($0.domain) \($0.code)" } ?? "kein Fehler")), Build \(onDisk()) bleibt")
        check(await wait(15) { installerGone() }, "Installer nach der Ablehnung beendet")

        // e) Falsche Signatur, „Jetzt nach Updates suchen“
        states.removeAll()
        updates.checkNow()
        check(await wait(60) { cycles.count == 4 }, "Suche von Hand mit falscher Signatur beendet")
        let manualError = updates.lastError.map { $0 as NSError }
        check(requests(".dmg") == 2 && states.contains(.checking) && states.contains { if case .downloading = $0 { true } else { false } }
              && states.contains { if case .verifying = $0 { true } else { false } } && updates.state == .idle && onDisk() == oldBuild,
              "Von Hand: \(flow()), abgelehnt (\(manualError.map { "\($0.domain) \($0.code)" } ?? "kein Fehler")), Build \(onDisk()) bleibt")
        if case let .failed(message) = updates.note {
            check(message.contains("Prüfung"), "Hinweis in den Einstellungen: „\(message)“")
        } else {
            check(false, "Hinweis nach abgelehntem Update fehlt (\(String(describing: updates.note)))")
        }
        check(await wait(15) { installerGone() }, "Installer nach der Ablehnung beendet")

        // f) Richtig signiert, im Hintergrund: laden, prüfen, beim Beenden installieren
        updates.feedOverride = URL(string: "\(base)/appcast.xml")
        states.removeAll()
        updates.checkInBackgroundNow()
        check(await wait(90) { updates.state.isReady }, "Im Hintergrund: \(flow())")
        check(updates.state == .ready(version: newVersion) && requests(".dmg") == 3, "Bereit: Knips \(newVersion), Hinweis in Menü und Einstellungen")
        check(onDisk() == oldBuild, "Noch nicht installiert, solange Knips läuft (Build \(onDisk()))")
        let userAgents = Set(server.requests.map { $0.headers["user-agent"] ?? "-" })
        let languages = Set(server.requests.map { $0.headers["accept-language"] ?? "-" })
        check(userAgents == ["Knips"] && languages == ["*"], "Anfragen ohne Version und Sprache: User-Agent \(userAgents.sorted()), Accept-Language \(languages.sorted())")
        check(server.requests.allSatisfy { $0.headers["cookie"] == nil }, "Keine Cookies zurückgeschickt (\(server.requests.count) Anfragen)")
        check(server.requests.allSatisfy { $0.method == "GET" && $0.body.isEmpty }, "Nur GET, ohne Inhalt")
        windows.formUnion(updateWindows(near: appURL))
        check(windows.isEmpty, "Keine sichtbaren Fenster\(windows.isEmpty ? "" : ": \(windows.sorted().joined(separator: "; "))")")
        print("   → Beende die Testkopie; Sparkle installiert Build \((Int(oldBuild) ?? 0) + 1) beim Beenden (ohne Neustart).")
    }

    /// Beobachter neben `update` (startet vorher): sieht die ganze Zeit nach Fenstern der Testkopie und ihrer Helfer,
    /// wartet, bis Sparkle nach dem Beenden die neue Fassung an dieselbe Stelle gelegt hat, und prüft sie.
    static func updateInstalled(_ out: URL, app: URL, build: String) async throws {
        var failed: [String] = []
        func check(_ ok: Bool, _ name: String) {
            print("   \(ok ? "ok    " : "FALSCH") \(name)")
            if !ok { failed.append(name) }
        }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        func installed() -> String? { NSDictionary(contentsOf: plist)?["CFBundleVersion"] as? String }
        // Prozesspfade sind echte Pfade (/private/var/… statt /var/…).
        let appPath = realPath(app)
        let executable = realPath(app.appendingPathComponent("Contents/MacOS/Knips"))
        var windows = Set<String>()
        var sawOld = false
        var oldEnded: Date?
        let start = Date()
        while Date().timeIntervalSince(start) < 240, installed() != build {
            windows.formUnion(updateWindows(near: app))
            let running = !processes(containing: executable).isEmpty
            if running { sawOld = true; oldEnded = nil } else if sawOld, oldEnded == nil { oldEnded = Date() }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Endete die alte Fassung im letzten Takt, lag die Installation innerhalb dieses Takts.
        let ended = oldEnded ?? (sawOld ? Date() : nil)
        let after = ended.map { String(format: "%.1f s nach dem Beenden der alten Fassung", Date().timeIntervalSince($0)) }
            ?? "alte Fassung lief nicht"
        check(sawOld, "Beobachtet, solange die alte Fassung lief")
        check(installed() == build, "Build \(installed() ?? "?") liegt in \(app.path) (\(after))")
        // Noch kurz beobachten: kein Neustart, keine Fenster, Sparkles Helfer beenden sich.
        let settle = Date()
        while Date().timeIntervalSince(settle) < 4 {
            windows.formUnion(updateWindows(near: app))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Sparkles Installer läuft aus dem Bundle bzw. dem Cache der Testkennung und beendet sich nach der Installation.
        func helpers() -> [String] {
            Array(Set(processes(containing: appPath) + processes(containing: updateTestID))).filter { !$0.hasPrefix(executable) }.sorted()
        }
        let helperWait = Date()
        while !helpers().isEmpty, Date().timeIntervalSince(helperWait) < 15 {
            windows.formUnion(updateWindows(near: app))
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        check(helpers().isEmpty, "Sparkles Installer beendet\(helpers().isEmpty ? "" : ": \(helpers().joined(separator: ", "))")")
        let relaunched = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == app.standardizedFileURL.path }
        check(relaunched.isEmpty && processes(containing: executable).isEmpty, "Kein Neustart: keine Knips-Instanz aus dem Temp-Ordner")
        check(windows.isEmpty, "Keine sichtbaren Fenster, weder vorher noch während der Installation\(windows.isEmpty ? "" : ": \(windows.sorted().joined(separator: "; "))")")

        var code: SecStaticCode?
        var errors: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess && code != nil
            ? SecStaticCodeCheckValidityWithErrors(code!, flags, nil, &errors) : errSecCSStaticCodeNotFound
        let reason = errors.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? ""
        check(status == errSecSuccess, "Code-Signatur gültig (streng, alle Architekturen, verschachtelter Code)\(reason.isEmpty ? "" : ": \(reason)")")
        var signing: CFDictionary?
        if let code, SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
           let signing = signing as? [String: Any] {
            print("   Kennung \(signing[kSecCodeInfoIdentifier as String] as? String ?? "?"), Team \(signing[kSecCodeInfoTeamIdentifier as String] as? String ?? "-")")
        }
        if !failed.isEmpty { throw CheckFailed(message: "Installation: \(failed.joined(separator: "; "))") }
    }

    /// Sichtbare Fenster von Knips selbst, der Testkopie und Sparkles Helfern (Installer, Fortschritt).
    private static func updateWindows(near app: URL) -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var found = Set<String>()
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let path = processPath(pid)
            guard pid == me || path.hasPrefix(realPath(app)) || path.contains(updateTestID) else { continue }
            let name = entry[kCGWindowOwnerName as String] as? String ?? "?"
            let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            found.insert("\(name) [\(pid)] \(Int(bounds["Width"] ?? 0))×\(Int(bounds["Height"] ?? 0))")
        }
        return found
    }

    /// Pfad ohne symbolische Links, wie ihn `proc_pidpath` liefert (/var → /private/var).
    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }

    /// Laufende Prozesse, deren Programmpfad `needle` enthält (ohne diesen Prozess).
    private static func processes(containing needle: String) -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let me = ProcessInfo.processInfo.processIdentifier
        return pids.prefix(Int(max(0, n))).compactMap { pid in
            guard pid > 0, pid != me else { return nil }
            let path = processPath(pid)
            return path.contains(needle) ? "\(path) [\(pid)]" : nil
        }
    }
}
#endif
