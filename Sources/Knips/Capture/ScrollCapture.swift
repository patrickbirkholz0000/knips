import AppKit
import ScreenCaptureKit
import SwiftUI

/// Setzt beim Scrollen aufgenommene Bilder eines Bereichs zu einem langen Bild zusammen.
/// Jedes neue Bild wird gegen das vorige verschoben verglichen (Zeilenprofile); nur die neu
/// sichtbaren Zeilen unten werden angehängt.
final class ScrollStitcher: @unchecked Sendable {
    private(set) var pieces: [(image: CGImage, rows: Range<Int>)] = []
    private var previous: RowProfile?
    private(set) var height = 0
    let width: Int

    init(first: CGImage) {
        width = first.width
        pieces = [(first, 0..<first.height)]
        previous = RowProfile(first)
        height = first.height
    }

    /// true, wenn das Bild neue Zeilen beigetragen hat.
    @discardableResult
    func add(_ frame: CGImage) -> Bool {
        guard frame.width == width, let prev = previous else { return false }
        let current = RowProfile(frame)
        guard let shift = prev.shift(to: current), shift > 0 else { return false }
        pieces.append((frame, (frame.height - shift)..<frame.height))
        height += shift
        previous = current
        return true
    }

    func assemble() -> CGImage? {
        guard let first = pieces.first?.image else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Renderer.rgbSpace(first.colorSpace),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        var y = 0   // von oben
        for piece in pieces {
            let rows = piece.rows
            guard let strip = piece.image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: width, height: rows.count)) else { continue }
            ctx.draw(strip, in: CGRect(x: 0, y: height - y - rows.count, width: width, height: rows.count))
            y += rows.count
        }
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
        if let ctx = CGContext(data: &buffer, width: Self.columns, height: rows, bitsPerComponent: 8, bytesPerRow: Self.columns,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
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

    /// Höhe so, wie sie in der gespeicherten Datei herauskommt (1× oder Retina).
    var outputHeight: Int { Int(CGFloat(pixelHeight) * AppSettings.shared.outputFactor(sourceScale: scale)) }

    private var stitcher: ScrollStitcher?
    private var loop: Task<Void, Never>?
    private var panel: NSPanel?
    private var frameWindow: NSPanel?
    private var screen: NSScreen?
    private var scale: CGFloat = 2

    func begin(screen: NSScreen, display: SCDisplay, localRect: CGRect, content: SCShareableContent) {
        guard !active else { return }
        self.screen = screen
        scale = screen.backingScaleFactor
        active = true
        sections = 0
        pixelHeight = 0
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
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    await self?.ingest(image)
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    /// Vergleichen und Anhängen im Hintergrund (bei 4K-Bereichen ~0,1 s pro Bild).
    private func ingest(_ image: CGImage) async {
        guard let stitcher else {
            stitcher = ScrollStitcher(first: image)
            sections = 1
            pixelHeight = image.height
            return
        }
        let (added, height) = await Task.detached(priority: .userInitiated) { (stitcher.add(image), stitcher.height) }.value
        if added { sections += 1 }
        pixelHeight = height
    }

    func finish(save: Bool) {
        loop?.cancel()
        loop = nil
        panel?.orderOut(nil)
        frameWindow?.orderOut(nil)
        panel = nil
        frameWindow = nil
        active = false
        let stitcher = self.stitcher
        self.stitcher = nil
        guard save, let stitcher, let screen else { return }
        let scale = self.scale
        Task {
            let image = await Task.detached(priority: .userInitiated) { stitcher.assemble() }.value
            guard let image else { return }
            Sounds.playShutter()
            CaptureCoordinator.shared.finish(image: image, scale: scale, screen: screen)
        }
    }

    private func panelWindow(_ rect: NSRect, ignoresMouse: Bool) -> NSPanel {
        let p = ClickablePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = ignoresMouse
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.setFrame(rect, display: false)
        return p
    }

    private func showFrame(around rect: CGRect) {
        let outer = rect.insetBy(dx: -3, dy: -3)
        let p = panelWindow(outer, ignoresMouse: true)
        let view = NSView(frame: NSRect(origin: .zero, size: outer.size))
        view.wantsLayer = true
        let shape = CAShapeLayer()
        shape.path = CGPath(rect: CGRect(origin: .zero, size: outer.size).insetBy(dx: 1, dy: 1), transform: nil)
        shape.fillColor = nil
        shape.strokeColor = NSColor.controlAccentColor.cgColor
        shape.lineWidth = 2
        shape.lineDashPattern = [6, 4]
        view.layer?.addSublayer(shape)
        p.contentView = view
        p.orderFrontRegardless()
        frameWindow = p
    }

    private func showControls(below rect: CGRect) {
        let size = CGSize(width: 380, height: 48)
        let vf = (screen ?? NSScreen.withMouse).visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < vf.minY + 4 { origin.y = min(rect.maxY + 12, vf.maxY - size.height - 4) }
        origin.x = max(vf.minX + 8, min(origin.x, vf.maxX - size.width - 8))
        let p = panelWindow(NSRect(origin: origin, size: size), ignoresMouse: false)
        p.isMovableByWindowBackground = true
        p.contentView = FirstMouseHostingView(rootView: ScrollControlsView(controller: self))
        p.orderFrontRegardless()
        panel = p
    }
}

private struct ScrollControlsView: View {
    @ObservedObject var controller: ScrollCaptureController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 1) {
                Text("Jetzt langsam nach unten scrollen")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Text("\(controller.sections) Abschnitt\(controller.sections == 1 ? "" : "e") · \(controller.outputHeight) px hoch")
                    .font(.system(size: 11).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white)
            Spacer(minLength: 4)
            Button { controller.finish(save: true) } label: {
                Text("Fertig")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Color.white))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            Button { controller.finish(save: false) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Abbrechen")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.95)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
    }
}
