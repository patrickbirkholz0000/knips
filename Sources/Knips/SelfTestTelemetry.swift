#if KNIPS_DEV
import AppKit
import Network

/// Winziger HTTP-Empfänger auf 127.0.0.1 — nimmt Pings an und antwortet mit `status`.
final class TestHTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "de.birkgroup.knips.test-http")
    private let lock = NSLock()
    private var received: [Request] = []
    private var answer = 204

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    var requests: [Request] { lock.withLock { received } }
    var status: Int {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = ResumeOnce(cont)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: once.resume(.success(self?.listener.port?.rawValue ?? 0))
                case .failed(let error): once.resume(.failure(error))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<UInt16, Error>?
        init(_ cont: CheckedContinuation<UInt16, Error>) { self.cont = cont }
        func resume(_ result: Result<UInt16, Error>) {
            lock.withLock {
                cont?.resume(with: result)
                cont = nil
            }
        }
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let status = self.lock.withLock { () -> Int in
                    self.received.append(request)
                    return self.answer
                }
                let head = "HTTP/1.1 \(status) \(status == 204 ? "No Content" : "Error")\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        var lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: first.first.map(String.init) ?? "", path: first.count > 1 ? String(first[1]) : "",
                       headers: headers, body: Data(body.prefix(length)))
    }
}

extension SelfTest {
    /// Nutzungsstatistik: Sperren, Payload, Zustimmung → Zählen → Senden → Abmelden gegen einen lokalen Server.
    /// Mit `live` zusätzlich ein echter Ping (nur mit `KNIPS_TELEMETRY=1`, Kanal „dev“).
    static func telemetry(_ out: URL, live: Bool) async throws {
        var failed: [String] = []
        func check(_ ok: Bool, _ name: String) {
            print("   \(ok ? "ok    " : "FALSCH") \(name)")
            if !ok { failed.append(name) }
        }
        func resolve(_ env: [String: String], args: [String] = ["Knips"], dev: Bool) -> TelemetryConfig {
            TelemetryConfig.resolve(environment: env, arguments: args, developerBuild: dev)
        }

        // 1) Wann gefragt, gezählt und gesendet werden darf
        let release = resolve([:], dev: false)
        check(release.enabled && release.channel == "release" && release.endpoint == TelemetryConfig.defaultEndpoint,
              "Weitergabe-Build: erlaubt, Kanal release, \(release.endpoint.absoluteString)")
        check(!resolve([:], dev: true).enabled, "Entwickler-Build ohne KNIPS_TELEMETRY=1: gesperrt")
        let dev = resolve(["KNIPS_TELEMETRY": "1"], dev: true)
        check(dev.enabled && dev.channel == "dev", "Entwickler-Build mit KNIPS_TELEMETRY=1: erlaubt, Kanal dev")
        check(!resolve(["KNIPS_TEST_DIR": "/tmp/x"], dev: false).enabled
              && !resolve(["KNIPS_TEST_DIR": "/tmp/x", "KNIPS_TELEMETRY": "1"], dev: true).enabled, "Test-Sandbox: gesperrt")
        check(!resolve([:], args: ["Knips", "--selftest", "render", "/tmp/x"], dev: false).enabled, "Selbsttest: gesperrt")
        check(!resolve(["CI": "true"], dev: false).enabled && !resolve(["GITHUB_ACTIONS": "true"], dev: false).enabled
              && resolve(["CI": "false"], dev: false).enabled, "CI: gesperrt")
        check(resolve(["KNIPS_TELEMETRY_URL": "http://127.0.0.1:9"], dev: true).endpoint.absoluteString == "http://127.0.0.1:9/v1/ping"
              && resolve(["KNIPS_TELEMETRY_URL": "http://127.0.0.1:9/x/ping"], dev: true).endpoint.absoluteString == "http://127.0.0.1:9/x/ping"
              && resolve(["KNIPS_TELEMETRY_URL": "kaputt"], dev: true).endpoint == TelemetryConfig.defaultEndpoint,
              "Entwickler-Build: KNIPS_TELEMETRY_URL ersetzt den Endpunkt")
        check(resolve(["KNIPS_TELEMETRY_URL": "http://127.0.0.1:9"], dev: false).endpoint == TelemetryConfig.defaultEndpoint,
              "Weitergabe-Build: KNIPS_TELEMETRY_URL wirkt nicht")
        check(!TelemetryConfig.current.enabled, "dieser Prozess (--selftest): gesperrt — \(TelemetryConfig.current.blockedReason ?? "-")")
        check(!Telemetry.shared.isCounting && !Telemetry.shared.shouldAsk && Telemetry.shared.defaults != .standard,
              "Telemetry.shared in der Sandbox: zählt nicht, fragt nicht, eigene Domäne")

        // 2) Payload
        let contract = ["app_launch", "capture_area", "capture_window", "capture_fullscreen", "capture_last_area", "capture_scroll",
                        "capture_text", "recording_start", "recording_saved", "editor_open", "video_editor_open", "censor_manual",
                        "censor_auto", "censor_smart", "export_png", "export_jpeg", "export_mp4", "export_gif", "copy_image",
                        "copy_text", "pin", "drag_out", "history_open", "settings_open"]
        check(TelemetryEvent.allCases.map(\.rawValue) == contract, "Ereignisliste = Vertrag (\(contract.count))")
        let info = TelemetryClientInfo(channel: "dev", appVersion: "1.3.0", build: "57", osVersion: "15.1", arch: "arm64", lang: "de")
        let sampleID = "8f0c2a4e-5b1d-4c3e-9f7a-0123456789ab"
        let data = TelemetryPayload.json(info: info, installID: sampleID,
                                         counts: ["capture_area": 3, "editor_open": 2, "fenstertitel": 5, "pin": 0, "copy_text": 99_999])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        check(Set(object.keys) == TelemetryPayload.keys && object.count == 11, "Payload: genau die 11 Felder, nichts sonst")
        check(object["v"] as? Int == 1 && object["app"] as? String == "knips" && object["platform"] as? String == "macos"
              && object["install_id"] as? String == sampleID, "Payload: v=1, app=knips, platform=macos, install_id")
        check(object["events"] as? [String: Int] == ["capture_area": 3, "editor_open": 2, "copy_text": 10_000],
              "Payload: nur erlaubte Ereignisse, gedeckelt auf 10000, ohne Nullen")
        let full = TelemetryPayload.json(info: info, installID: sampleID,
                                         counts: Dictionary(uniqueKeysWithValues: contract.map { ($0, 10_000) }))
        check(full.count <= 4096, "Payload mit allen Ereignissen: \(full.count) Bytes ≤ 4 KB")
        check(TelemetryClientInfo.language("de-DE") == "de" && TelemetryClientInfo.language("zh-Hans-CN") == "zh"
              && TelemetryClientInfo.language(nil) == "xx", "Sprache: nur zwei Buchstaben")
        let current = TelemetryClientInfo.current(channel: "dev")
        print("   Dieses System: \(current.osVersion), \(current.arch), \(current.lang), Version \(current.appVersion) (\(current.build))")

        // 3) Ablauf gegen den lokalen Server, Zustand in einer eigenen Defaults-Domäne
        let server = try TestHTTPServer()
        let port = try await server.start()
        let suite = "de.birkgroup.knips.selftest.telemetry"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailed(message: "Defaults-Domäne fehlt") }
        defaults.removePersistentDomain(forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            server.stop()
        }
        let endpoint = URL(string: "http://127.0.0.1:\(port)/v1/ping")!
        let t = Telemetry(defaults: defaults, config: TelemetryConfig(endpoint: endpoint, channel: "dev", blockedReason: nil))

        check(t.consent == nil && t.shouldAsk, "Erster Start: noch keine Antwort, Frage fällig")
        t.record(.captureArea)
        var result = await t.sendIfDue(force: true)
        check(t.counts.isEmpty && server.requests.isEmpty && result == .skipped("keine Zustimmung"), "Ohne Antwort: nichts gezählt, nichts gesendet")
        t.markAsked()
        check(!t.shouldAsk && t.consent == nil, "Dialog geschlossen ohne Wahl: zählt als Nein, kein zweites Mal in diesem Start")

        t.setConsent(true)
        let id = t.installID ?? ""
        let uuidV4 = try NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        check(uuidV4.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil, "Zustimmung: zufällige install_id (UUID v4)")
        for _ in 0..<3 { t.record(.captureArea) }
        t.record(.editorOpen); t.record(.editorOpen); t.record(.appLaunch)
        check(t.counts == ["capture_area": 3, "editor_open": 2, "app_launch": 1], "Zählt nur nach Zustimmung")

        result = await t.sendIfDue()
        check(result == .sent(204) && server.requests.count == 1, "Versand an 127.0.0.1:\(port): \(result)")
        if let request = server.requests.last {
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            check(request.method == "POST" && request.path == "/v1/ping" && request.headers["content-type"] == "application/json",
                  "POST /v1/ping, application/json")
            check(request.headers["cookie"] == nil && request.headers["authorization"] == nil, "Keine Cookies, keine Anmeldung")
            check(Set(body.keys) == TelemetryPayload.keys, "Gesendet: genau die Vertragsfelder")
            check(body["install_id"] as? String == id && body["channel"] as? String == "dev"
                  && body["events"] as? [String: Int] == ["capture_area": 3, "editor_open": 2, "app_launch": 1],
                  "Gesendet: install_id, Kanal dev, Zähler")
            check(request.body.count <= 4096, "Körper \(request.body.count) Bytes")
            print("   Körper: \(String(decoding: request.body, as: UTF8.self))")
        }
        check(t.counts.isEmpty && t.lastSent != nil, "Nach Erfolg: Zähler zurückgesetzt, Versandzeit gemerkt")

        t.record(.pin)
        result = await t.sendIfDue()
        check(server.requests.count == 1 && t.counts == ["pin": 1], "Innerhalb von 24 h: kein zweiter Versand (\(result))")
        result = await t.sendIfDue(now: Date().addingTimeInterval(25 * 3600))
        check(result == .sent(204) && server.requests.count == 2 && t.counts.isEmpty, "Nach 25 h: wieder gesendet")

        server.status = 500
        t.record(.copyImage); t.record(.copyImage)
        let lastBefore = t.lastSent
        result = await t.sendIfDue(force: true)
        check(result == .failed("HTTP 500") && t.counts == ["copy_image": 2] && t.lastSent == lastBefore, "Serverfehler 500: Zähler bleiben")
        let unreachable = Telemetry(defaults: defaults, config: TelemetryConfig(endpoint: URL(string: "http://127.0.0.1:1/v1/ping")!,
                                                                                channel: "dev", blockedReason: nil))
        let started = Date()
        result = await unreachable.sendIfDue(force: true)
        if case .failed = result {} else { failed.append("unerreichbar") }
        check(unreachable.counts == ["copy_image": 2] && Date().timeIntervalSince(started) < 11,
              "Server nicht erreichbar: Zähler bleiben, nach \(String(format: "%.1f", Date().timeIntervalSince(started))) s aufgegeben")
        server.status = 204
        result = await t.sendIfDue(force: true)
        check(result == .sent(204) && t.counts.isEmpty, "Nächste Prüfung: nachgeholt, Zähler leer")

        t.record(.pin)
        t.setConsent(false)
        check(t.consent == false && t.installID == nil && t.counts.isEmpty && t.lastSent == nil, "Abmeldung: install_id und offene Zähler sofort gelöscht")
        t.record(.pin)
        let sentBefore = server.requests.count
        result = await t.sendIfDue(force: true)
        check(t.counts.isEmpty && server.requests.count == sentBefore && result == .skipped("keine Zustimmung"), "Nach Abmeldung: nichts gezählt, nichts gesendet")
        let stored = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        check(stored == [Telemetry.Key.consent], "Gespeichert bleibt nur die Antwort: \(stored.sorted().joined(separator: ", "))")

        // Sandbox schlägt KNIPS_TELEMETRY=1: dieselbe Umgebung wie hier, aber ohne --selftest
        var env = ProcessInfo.processInfo.environment
        env["KNIPS_TELEMETRY"] = "1"
        env["KNIPS_TELEMETRY_URL"] = "http://127.0.0.1:\(port)"
        let gatedConfig = resolve(env, dev: true)
        let gated = Telemetry(defaults: defaults, config: gatedConfig)
        gated.setConsent(true)
        gated.record(.captureArea)
        result = await gated.sendIfDue(force: true)
        check(!gatedConfig.enabled && !gated.shouldAsk && gated.counts.isEmpty && server.requests.count == sentBefore,
              "Test-Sandbox trotz KNIPS_TELEMETRY=1: nicht fragen, nicht zählen, nicht senden (\(gatedConfig.blockedReason ?? "-"))")
        defaults.removePersistentDomain(forName: suite)

        // 4) Echter Ping (nur auf ausdrücklichen Wunsch)
        if live {
            let liveEnv = ProcessInfo.processInfo.environment
            guard liveEnv["KNIPS_TELEMETRY"] == "1" else { throw CheckFailed(message: "Live-Versand nur mit KNIPS_TELEMETRY=1") }
            let liveConfig = TelemetryConfig(endpoint: resolve(liveEnv.filter { $0.key == "KNIPS_TELEMETRY_URL" }, dev: true).endpoint,
                                             channel: "dev", blockedReason: nil)
            let liveT = Telemetry(defaults: defaults, config: liveConfig)
            liveT.setConsent(true)
            liveT.record(.appLaunch)
            liveT.record(.settingsOpen)
            result = await liveT.sendIfDue()
            check(result == .sent(204), "Live: \(liveConfig.endpoint.absoluteString) → \(result)")
            liveT.setConsent(false)
            defaults.removePersistentDomain(forName: suite)
        }

        if !failed.isEmpty { throw CheckFailed(message: "Nutzungsstatistik: \(failed.joined(separator: "; "))") }
    }
}
#endif
