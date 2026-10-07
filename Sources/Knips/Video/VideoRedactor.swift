import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Thread-sicherer Stand der Zensurfelder — die Videokomposition liest ihn pro Frame.
final class RedactionState: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [VideoRedaction] = []
    let pixelBlock: CGFloat
    let blurRadius: CGFloat

    init(scale: CGFloat) {
        pixelBlock = max(10, (12 * scale).rounded())
        blurRadius = 14 * scale
    }

    func set(_ redactions: [VideoRedaction]) {
        lock.lock(); items = redactions; lock.unlock()
    }

    func active(at t: Double) -> [VideoRedaction] {
        lock.lock(); defer { lock.unlock() }
        return items.filter { t >= $0.start - 0.0005 && t <= $0.end + 0.0005 }
    }
}

enum VideoRedactor {
    static func apply(_ redactions: [VideoRedaction], to image: CIImage, state: RedactionState) -> CIImage {
        let extent = image.extent
        var output = image
        var pixelated: CIImage?
        var blurred: CIImage?
        for r in redactions {
            let ciRect = CGRect(x: extent.minX + r.rect.minX, y: extent.maxY - r.rect.maxY, width: r.rect.width, height: r.rect.height)
                .integral.intersection(extent)
            guard !ciRect.isNull, ciRect.width > 0, ciRect.height > 0 else { continue }
            let patch: CIImage
            switch r.style {
            case .pixelate:
                if pixelated == nil {
                    pixelated = image.clampedToExtent()
                        .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: state.pixelBlock, kCIInputCenterKey: CIVector(x: 0, y: 0)])
                }
                patch = pixelated!.cropped(to: ciRect)
            case .blur:
                if blurred == nil {
                    blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: state.blurRadius])
                }
                patch = blurred!.cropped(to: ciRect)
            case .solid:
                patch = CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.06)).cropped(to: ciRect)
            }
            output = patch.composited(over: output)
        }
        return output.cropped(to: extent)
    }

    static func composition(for asset: AVAsset, state: RedactionState) -> AVVideoComposition {
        AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let active = state.active(at: request.compositionTime.seconds)
            if active.isEmpty {
                request.finish(with: source, context: nil)
            } else {
                request.finish(with: apply(active, to: source, state: state), context: nil)
            }
        }
    }

    // MARK: Export

    enum ExportError: LocalizedError {
        case session, failed(String), gif
        var errorDescription: String? {
            switch self {
            case .session: "Der Export konnte nicht vorbereitet werden."
            case .failed(let s): "Export fehlgeschlagen: \(s)"
            case .gif: "Die GIF-Datei konnte nicht geschrieben werden."
            }
        }
    }

    static func exportMP4(asset: AVAsset, state: RedactionState, range: CMTimeRange, to url: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw ExportError.session }
        session.outputURL = url
        session.outputFileType = .mp4
        session.timeRange = range
        session.videoComposition = composition(for: asset, state: state)
        session.shouldOptimizeForNetworkUse = true
        let box = SessionBox(session)
        let poll = Task.detached {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { cont.resume() }
        }
        poll.cancel()
        if session.status != .completed {
            throw ExportError.failed(session.error?.localizedDescription ?? "Status \(session.status.rawValue)")
        }
        progress(1)
    }

    static func exportGIF(asset: AVAsset, state: RedactionState, range: CMTimeRange, fps: Int, width: Int, to url: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> CGSize {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = composition(for: asset, state: state)
        generator.maximumSize = CGSize(width: width, height: width * 4)
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let start = range.start.seconds, duration = range.duration.seconds
        let count = max(1, Int((duration * Double(fps)).rounded(.down)))
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw ExportError.gif }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1.0 / Double(fps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        var size = CGSize.zero
        for i in 0..<count {
            try Task.checkCancellation()
            let t = CMTime(seconds: start + Double(i) * delay, preferredTimescale: 600)
            let image = try await generator.image(at: t).image
            size = CGSize(width: image.width, height: image.height)
            CGImageDestinationAddImage(dest, image, frameProps)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.gif }
        return size
    }

    // MARK: Auto-Zensur

    /// Texterkennung auf Einzelbildern (alle `step` Sekunden), Treffer werden zu Zeitbereichen verbunden.
    static func detect(asset: AVAsset, range: CMTimeRange, step: Double, style: RedactStyle,
                       kinds: Set<SensitiveDetector.Kind> = Set(SensitiveDetector.Kind.allCases),
                       progress: @escaping @Sendable (Double) -> Void) async throws -> [VideoRedaction] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Gleiche Obergrenze wie bei Bildern: Erkennung bleibt gut, Laufzeit fällt drastisch.
        generator.maximumSize = CGSize(width: SensitiveDetector.ocrMaxPixel, height: SensitiveDetector.ocrMaxPixel)
        let fullSize = try await VideoInfo.pixelSize(of: asset)
        let start = range.start.seconds, end = range.end.seconds
        let samples = max(1, Int(((end - start) / step).rounded(.up)) + 1)

        struct Track { var rect: CGRect; var text: String; var first: Double; var last: Double }
        var open: [Track] = []
        var done: [Track] = []
        var lastSignature: FrameSignature?
        var lastFindings: [SensitiveDetector.Finding]?
        for i in 0..<samples {
            try Task.checkCancellation()
            let t = min(end, start + Double(i) * step)
            guard let frame = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            // Bildschirmaufnahmen stehen oft still: unverändertes Bild → Funde vom letzten Mal übernehmen.
            let signature = FrameSignature(frame)
            let findings: [SensitiveDetector.Finding]
            if let last = lastSignature, let cached = lastFindings, signature.matches(last) {
                findings = cached
            } else {
                let f = frame.width == Int(fullSize.width) ? 1 : fullSize.width / CGFloat(frame.width)
                findings = SensitiveDetector.detectSync(in: frame, kinds: kinds).map {
                    SensitiveDetector.Finding(rect: CGRect(x: $0.rect.minX * f, y: $0.rect.minY * f, width: $0.rect.width * f, height: $0.rect.height * f),
                                              kind: $0.kind, text: $0.text)
                }
            }
            lastSignature = signature
            lastFindings = findings
            var seen = Set<Int>()
            for f in findings {
                if let idx = open.firstIndex(where: { $0.text == f.text && iou($0.rect, f.rect) > 0.3 }) {
                    open[idx].last = t
                    open[idx].rect = open[idx].rect.union(f.rect)
                    seen.insert(idx)
                } else {
                    open.append(Track(rect: f.rect, text: f.text, first: t, last: t))
                    seen.insert(open.count - 1)
                }
            }
            var still: [Track] = []
            for (idx, track) in open.enumerated() {
                if seen.contains(idx) { still.append(track) } else { done.append(track) }
            }
            open = still
            progress(Double(i + 1) / Double(samples))
        }
        done.append(contentsOf: open)
        // Zwischen zwei Stichproben kann der Text schon/noch sichtbar sein — Zeitbereich großzügig erweitern.
        return done.map { track in
            let pad = track.rect.height * 0.25
            return VideoRedaction(rect: track.rect.insetBy(dx: -pad, dy: -pad), start: max(start, track.first - step),
                                  end: min(end, track.last + step), style: style, auto: true)
        }
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }
}

/// AVAssetExportSession ist nicht Sendable; der Fortschritt wird nur gelesen.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ s: AVAssetExportSession) { session = s }
}

/// Winziges Graustufenbild (32×18) zum Erkennen unveränderter Frames.
struct FrameSignature {
    let pixels: [UInt8]

    init(_ image: CGImage) {
        let w = 32, h = 18
        var buffer = [UInt8](repeating: 0, count: w * h)
        if let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixels = buffer
    }

    func matches(_ other: FrameSignature) -> Bool {
        guard pixels.count == other.pixels.count else { return false }
        var diff = 0
        for i in pixels.indices { diff += abs(Int(pixels[i]) - Int(other.pixels[i])) }
        return Double(diff) / Double(pixels.count) < 1.5
    }
}
