import AppKit
import ScreenCaptureKit
import SwiftUI

/// Setzt beim Scrollen aufgenommene Bilder eines Bereichs zu einem langen Bild zusammen.
/// Jedes neue Bild wird gegen das vorige verschoben verglichen (Zeilenprofile); nur die neu
/// sichtbaren Zeilen unten werden behalten, als eigene Kopie — nie ganze Bilder. `add` und
/// `assemble` dürfen aus verschiedenen Threads kommen, sie laufen nacheinander.
final class ScrollStitcher: @unchecked Sendable {
    /// Höchste Höhe in Pixeln. JPEG schafft höchstens 65 535, und ein 2800 px breiter Bereich belegt
    /// bei 60 000 Zeilen schon ~670 MB.
    static let maxHeight = 60_000

    private let lock = NSLock()
    private var strips: [CGImage] = []
    private var previous: RowProfile?
    private var rows = 0
    private var full = false
    let width: Int
    let maxHeight: Int

    init(first: CGImage, maxHeight: Int = ScrollStitcher.maxHeight) {
        width = first.width
        self.maxHeight = maxHeight
        let take = min(first.height, maxHeight)
        if let strip = Self.copy(first, rows: 0..<take) { strips = [strip] }
        previous = RowProfile(first)
        rows = strips.first?.height ?? 0
        full = rows >= maxHeight
    }

    var height: Int { lock.withLock { rows } }
    /// Obergrenze erreicht: weitere Bilder werden ignoriert.
    var limitReached: Bool { lock.withLock { full } }
    /// Speicher der behaltenen Zeilen in Bytes.
    var storedBytes: Int { lock.withLock { strips.reduce(0) { $0 + $1.bytesPerRow * $1.height } } }

    /// true, wenn das Bild neue Zeilen beigetragen hat.
    @discardableResult
    func add(_ frame: CGImage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !full, frame.width == width, let prev = previous else { return false }
        let current = RowProfile(frame)
        guard let shift = prev.shift(to: current), shift > 0 else { return false }
        let take = min(shift, maxHeight - rows)
        let start = frame.height - shift
        guard let strip = Self.copy(frame, rows: start..<(start + take)) else { return false }
        strips.append(strip)
        rows += take
        previous = current
        full = rows >= maxHeight
        return true
    }

    func assemble() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = strips.first, rows > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Renderer.rgbSpace(first.colorSpace),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        var y = 0   // von oben
        for strip in strips {
            ctx.draw(strip, in: CGRect(x: 0, y: rows - y - strip.height, width: width, height: strip.height))
            y += strip.height
        }
        return ctx.makeImage()
    }

    /// Zeilen als eigenständiges Bild — `cropping` allein hielte das ganze Bild im Speicher.
    private static func copy(_ image: CGImage, rows: Range<Int>) -> CGImage? {
        guard !rows.isEmpty,
              let crop = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)),
              let ctx = CGContext(data: nil, width: image.width, height: rows.count, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Renderer.rgbSpace(image.colorSpace),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: rows.count))
        return ctx.makeImage()
    }
}

/// Graustufen-Profil: je Zeile 48 Stichproben.
struct RowProfile {
    static let columns = 48
    let rows: Int
    let values: [UInt8]

    init(_ image: CGImage) {
        rows = image.height
        var buffer = [UInt8](repeating: 0, count: Self.columns * rows)
        let rows = rows
        // Der Zeiger gilt nur innerhalb des Blocks — der Kontext darf ihn nicht überleben.
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: Self.columns, height: rows, bitsPerComponent: 8, bytesPerRow: Self.columns,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: Self.columns, height: rows))
        }
        values = buffer   // Zeile 0 = oben (Bitmap-Speicher beginnt oben)
    }

    private func rowDiff(_ a: Int, _ other: RowProfile, _ b: Int) -> Int {
        var sum = 0
        let ia = a * Self.columns, ib = b * Self.columns
        for c in 0..<Self.columns { sum += abs(Int(values[ia + c]) - Int(other.values[ib + c])) }
        return sum
    }

    /// Wie weit der Inhalt nach oben gewandert ist (Pixel), oder nil, wenn nichts sicher passt.
    /// Oberes und unteres Zehntel bleiben beim Vergleich außen vor (feste Kopf-/Fußleisten).
    func shift(to next: RowProfile) -> Int? {
        let h = min(rows, next.rows)
        let margin = h / 10
        let minOverlap = h / 4
        func cost(_ d: Int, step: Int) -> Double {
            // Zeile r im neuen Bild entspricht Zeile r + d im alten.
            let lo = margin, hi = h - d - margin
            guard hi - lo >= minOverlap / 2 else { return .infinity }
            var sum = 0, n = 0
            var r = lo
            while r < hi { sum += rowDiff(r + d, next, r); n += 1; r += step }
            return n > 0 ? Double(sum) / Double(n * Self.columns) : .infinity
        }
        // Jede Verschiebung mit jeder 4. Zeile prüfen (sich wiederholende Zeilen verlangen das),
        // dann die drei besten Kandidaten mit allen Zeilen nachschärfen.
        var coarse: [(d: Int, c: Double)] = []
        for d in 0..<(h - minOverlap) { coarse.append((d, cost(d, step: 4))) }
        coarse.sort { $0.c < $1.c }
        var best = (d: 0, c: Double.infinity)
        for candidate in coarse.prefix(3) {
            for f in max(0, candidate.d - 2)...(candidate.d + 2) where f < h - minOverlap {
                let c = cost(f, step: 1)
                if c < best.c { best = (f, c) }
            }
        }
        // Unverändert oder kein eindeutiger Treffer.
        guard best.d > 0, best.c < 6 else { return nil }
        // Ganz ohne Bewegung ist genauso gut wie die beste Verschiebung → nicht gescrollt.
        if cost(0, step: 1) <= best.c + 0.3 { return nil }
        return best.d
    }
}

/// Ablauf: Bereich wählen → während des Scrollens alle 0,15 s aufnehmen → „Fertig“ setzt zusammen.
@MainActor final class ScrollCaptureController: ObservableObject {
    static let shared = ScrollCaptureController()

    @Published private(set) var active = false
    @Published private(set) var sections = 0
    @Published private(set) var pixelHeight = 0
    /// Obergrenze (`ScrollStitcher.maxHeight`) erreicht: Es wird nichts mehr angehängt.
    @Published private(set) var limitReached = false

    /// Höhe so, wie sie in der gespeicherten Datei herauskommt (1× oder Retina).
    var outputHeight: Int { Int(CGFloat(pixelHeight) * AppSettings.shared.outputFactor(sourceScale: scale)) }

    private var stitcher: ScrollStitcher?
    private var loop: Task<Void, Never>?
    /// Laufendes Anhängen im Hintergrund — „Fertig“ wartet darauf.
    private var ingesting: Task<(added: Bool, height: Int, full: Bool), Never>?
    /// Zusammensetzen und Speichern nach „Fertig“ (Beenden der App wartet darauf).
    private var finishing: Task<Void, Never>?
    /// Jede Aufnahme bekommt eine Nummer. Bilder, die erst nach „Fertig“ zurückkommen, gehören zu
    /// einer alten Sitzung und dürfen nie in der nächsten landen.
    private var session = 0
    private var failures = 0
    private var panel: NSPanel?
    private var frameWindow: NSPanel?
    private var screen: NSScreen?
    private var screenFrame: CGRect = .zero
    private var scale: CGFloat = 2

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            onMainActor { ScrollCaptureController.shared.screensChanged() }
        }
    }

    func begin(screen: NSScreen, display: SCDisplay, localRect: CGRect, content: SCShareableContent) {
        guard !active else { return }
        let id = startSession()
        self.screen = screen
        screenFrame = screen.frame
        scale = screen.backingScaleFactor
        let global = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        showFrame(around: global)
        showControls(below: global)
        let filter = ScreenCapture.filter(for: display, in: content)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: localRect.minX, y: screen.frame.height - localRect.maxY, width: localRect.width, height: localRect.height)
        config.width = Int(localRect.width * scale)
        config.height = Int(localRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    await self?.ingest(image, session: id)
                } catch {
                    self?.captureFailed(error, session: id)
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func startSession() -> Int {
        session += 1
        active = true
        stitcher = nil
        ingesting = nil
        sections = 0
        pixelHeight = 0
        limitReached = false
        failures = 0
        return session
    }

    /// Vergleichen und Anhängen im Hintergrund (bei 4K-Bereichen ~0,1 s pro Bild).
    func ingest(_ image: CGImage, session id: Int) async {
        guard active, id == session, !limitReached else { return }
        failures = 0
        guard let stitcher else {
            stitcher = ScrollStitcher(first: image)
            sections = 1
            pixelHeight = stitcher?.height ?? 0
            return
        }
        // Höchstens ein Anhängen zur Zeit; die Reihenfolge der Bilder muss stimmen.
        _ = await ingesting?.value
        guard id == session else { return }
        let task = Task.detached(priority: .userInitiated) { (added: stitcher.add(image), height: stitcher.height, full: stitcher.limitReached) }
        ingesting = task
        let result = await task.value
        guard id == session else { return }
        if result.added { sections += 1 }
        pixelHeight = result.height
        if result.full {
            limitReached = true
            loop?.cancel()
            loop = nil
        }
    }

    /// Der Bildschirm lässt sich nicht mehr aufnehmen (abgesteckt, Freigabe entzogen): nach ~3 s beenden.
    private func captureFailed(_ error: Error, session id: Int) {
        guard active, id == session else { return }
        failures += 1
        guard failures >= 20 else { return }
        Log.error("Scroll-Aufnahme: Bildschirm nicht mehr erreichbar: \(error.localizedDescription)")
        HUD.show("Scroll-Aufnahme beendet – Bildschirm nicht erreichbar", symbol: "exclamationmark.triangle.fill")
        finish(save: true)
    }

    /// Bildschirm abgesteckt oder umgestellt: Bereich und Leiste stimmen nicht mehr — beenden und behalten, was da ist.
    private func screensChanged() {
        guard active, let screen else { return }
        let same = NSScreen.screens.first { $0.displayID == screen.displayID }
        if let same, same.frame == screenFrame, same.backingScaleFactor == scale { return }
        HUD.show("Bildschirme geändert – Scroll-Aufnahme beendet", symbol: "display.trianglebadge.exclamationmark")
        finish(save: true)
    }

    func finish(save: Bool) {
        guard let (stitcher, pending) = end(), save, let stitcher, let screen else { return }
        let scale = self.scale
        finishing = Task {
            // Laufendes Anhängen abwarten, damit das letzte Stück dabei ist.
            _ = await pending?.value
            let image = await Task.detached(priority: .userInitiated) { stitcher.assemble() }.value
            guard let image else { return }
            Sounds.playShutter()
            Telemetry.count(.captureScroll)
            CaptureCoordinator.shared.finish(image: image, scale: scale, screen: screen)
        }
    }

    /// Beenden der App: laufende Aufnahme speichern und warten, bis sie angelegt ist.
    func finishForQuit() async {
        if active { finish(save: true) }
        await finishing?.value
    }

    /// Schleife und Fenster beenden; neue Sitzungsnummer, damit nachzügelnde Bilder verworfen werden.
    private func end() -> (ScrollStitcher?, Task<(added: Bool, height: Int, full: Bool), Never>?)? {
        guard active else { return nil }
        loop?.cancel()
        loop = nil
        panel?.orderOut(nil)
        frameWindow?.orderOut(nil)
        panel = nil
        frameWindow = nil
        active = false
        session += 1
        let result = (stitcher, ingesting)
        stitcher = nil
        ingesting = nil
        return result
    }

    #if KNIPS_DEV
    /// Nur Selbsttest: Sitzung ohne Bildschirm, Fenster und Aufnahme-Schleife.
    func debugBeginSession() -> Int { startSession() }
    var debugStitcher: ScrollStitcher? { stitcher }
    var debugIsIngesting: Bool { ingesting != nil }
    /// Wie „Fertig“, liefert das Bild aber zurück, statt eine Aufnahme anzulegen.
    func debugFinish() async -> CGImage? {
        guard let (stitcher, pending) = end(), let stitcher else { return nil }
        _ = await pending?.value
        return stitcher.assemble()
    }
    #endif

    /// Rahmen in Königsblau knapp außerhalb des Bereichs (Knips-Fenster sind ohnehin nicht im Bild).
    private func showFrame(around rect: CGRect) {
        let outer = rect.insetBy(dx: -AreaFrame.outset, dy: -AreaFrame.outset)
        let p = FloatingPanel.make(outer, ignoresMouse: true)
        p.contentView = AreaFrame.makeView(size: outer.size, color: Brand.Dark.accent)
        p.orderFrontRegardless()
        frameWindow = p
    }

    private func showControls(below rect: CGRect) {
        let host = FirstMouseHostingView(rootView: ScrollControlsView(controller: self))
        // Breite für den längsten Text, damit die Leiste beim Zählen nicht springt; `ScrollBar.margin` für den Schatten.
        let size = host.fittingSize
        let m = ScrollBar.margin
        let vf = (screen ?? NSScreen.withMouse).visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12 + m)
        if origin.y < vf.minY + 4 - m { origin.y = min(rect.maxY + 12 - m, vf.maxY - size.height - 4 + m) }
        origin.x = max(vf.minX + 8 - m, min(origin.x, vf.maxX - size.width - 8 + m))
        let p = FloatingPanel.make(NSRect(origin: origin, size: size), ignoresMouse: false)
        p.isMovableByWindowBackground = true
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
    }
}

private struct ScrollControlsView: View {
    @ObservedObject var controller: ScrollCaptureController

    var body: some View {
        ScrollBar(sections: controller.sections, height: controller.outputHeight, limitReached: controller.limitReached,
                  done: { controller.finish(save: true) }, cancel: { controller.finish(save: false) })
    }
}

/// Scroll-Leiste (docs/design.md): dunkle Pille mit Anleitung, Abschnitte und Höhe in Mono, „Fertig“ (Papier) und
/// „Abbrechen“. Ist die Obergrenze erreicht, steht dort „Maximale Länge erreicht“.
struct ScrollBar: View {
    var sections: Int
    /// Höhe in Pixeln, wie sie in der Datei herauskommt.
    var height: Int
    var limitReached: Bool
    var done: () -> Void
    var cancel: () -> Void

    /// Platz rundherum für den Schatten.
    static let margin: CGFloat = 14

    /// „12 480 px“ — Tausender mit schmalem Leerzeichen.
    static func pixels(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"
        f.usesGroupingSeparator = true
        return (f.string(from: NSNumber(value: value)) ?? "\(value)") + " px"
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: limitReached ? "exclamationmark.circle.fill" : "arrow.down.to.line.compact")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brand(limitReached ? Brand.Dark.warn : Brand.Dark.accent))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.brand(limitReached ? Brand.Dark.warn.withAlphaComponent(0.14) : Brand.Dark.accentSoft)))
            VStack(alignment: .leading, spacing: 2) {
                // Beide Texte liegen übereinander: die Leiste ist so breit wie der längere und springt nie.
                ZStack(alignment: .leading) {
                    Text("Jetzt langsam nach unten scrollen").opacity(limitReached ? 0 : 1)
                    Text("Maximale Länge erreicht").opacity(limitReached ? 1 : 0)
                }
                .font(Brand.font(13, .medium))
                .foregroundStyle(Color.brand(Brand.Dark.ink))
                .lineLimit(1)
                .fixedSize()
                Text("\(sections) Abschnitt\(sections == 1 ? "" : "e") · \(Self.pixels(height))")
                    .font(Brand.mono(11))
                    .foregroundStyle(Color.brand(Brand.Dark.muted))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 10)
            Spacer(minLength: 18)
            Button(action: cancel) { Text("Abbrechen") }
                .buttonStyle(DarkButtonStyle(kind: .ghost, height: 30, fontSize: 13))
            Button(action: done) { Text("Fertig") }
                .buttonStyle(DarkButtonStyle(kind: .primary, height: 30, fontSize: 13))
                .padding(.leading, 4)
        }
        .padding(.leading, 9)
        .padding(.trailing, 8)
        .frame(height: 48)
        .fixedSize()
        .darkSurface(Capsule())
        .padding(Self.margin)
        .environment(\.colorScheme, .dark)
    }
}
