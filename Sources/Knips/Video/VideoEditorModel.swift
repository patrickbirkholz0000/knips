import AppKit
import AVFoundation
import Combine

@MainActor final class VideoEditorModel: ObservableObject {
    private(set) var item: CaptureItem
    let asset: AVURLAsset
    let player: AVPlayer
    let state: RedactionState
    let duration: Double
    let videoSize: CGSize

    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var trimStart: Double
    @Published var trimEnd: Double
    @Published var redactions: [VideoRedaction] { didSet { state.set(redactions) } }
    @Published var selectedID: UUID?
    @Published var style: RedactStyle
    @Published var dirty = false
    @Published var busy: String?
    @Published var progress: Double?
    @Published var toast: String?
    @Published var thumbnails: [CGImage] = []
    @Published private(set) var canUndo = false

    private var timeObserver: Any?
    private var undoStack: [(redactions: [VideoRedaction], trimStart: Double, trimEnd: Double)] = []
    private var toastWork: DispatchWorkItem?
    private var work: Task<Void, Never>?

    init(item: CaptureItem, asset: AVURLAsset, duration: Double, videoSize: CGSize, document: VideoDocument) {
        self.item = item
        self.asset = asset
        self.duration = duration
        self.videoSize = videoSize
        self.state = RedactionState(scale: CGFloat(max(1, item.scale)))
        self.trimStart = max(0, min(document.trimStart ?? 0, duration))
        self.trimEnd = min(duration, max(document.trimEnd ?? duration, 0))
        self.redactions = document.redactions
        self.style = AppSettings.shared.redactStyle
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        state.set(redactions)
        player.currentItem?.videoComposition = VideoRedactor.composition(for: asset, state: state)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                if self.isPlaying, time.seconds >= self.trimEnd - 0.01 {
                    self.player.pause()
                    self.isPlaying = false
                }
            }
        }
        seek(to: trimStart)
        loadThumbnails()
    }

    func shutdown() {
        work?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    static func load(_ item: CaptureItem) async throws -> VideoEditorModel {
        let url = CaptureStore.shared.originalURL(for: item)
        let source = FileManager.default.fileExists(atPath: url.path) ? url : item.fileURL
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let size = try await VideoInfo.pixelSize(of: asset)
        return VideoEditorModel(item: item, asset: asset, duration: duration, videoSize: size,
                                document: CaptureStore.shared.loadVideoDocument(for: item))
    }

    var document: VideoDocument {
        VideoDocument(trimStart: trimStart > 0.001 ? trimStart : nil,
                      trimEnd: trimEnd < duration - 0.001 ? trimEnd : nil,
                      redactions: redactions)
    }

    var hasEdits: Bool { document.trimStart != nil || document.trimEnd != nil || !redactions.isEmpty }
    var selected: VideoRedaction? { redactions.first { $0.id == selectedID } }
    var trimRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), end: CMTime(seconds: trimEnd, preferredTimescale: 600))
    }

    // MARK: Wiedergabe

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= trimEnd - 0.05 || currentTime < trimStart { seek(to: trimStart) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to t: Double) {
        let clamped = max(0, min(t, duration))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Standbild neu rendern, nachdem sich Zensurfelder geändert haben.
    func refreshFrame() {
        player.currentItem?.videoComposition = VideoRedactor.composition(for: asset, state: state)
        if !isPlaying { seek(to: currentTime) }
    }

    // MARK: Bearbeiten

    func checkpoint() {
        undoStack.append((redactions, trimStart, trimEnd))
        if undoStack.count > 200 { undoStack.removeFirst() }
        canUndo = true
        dirty = true
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redactions = last.redactions
        trimStart = last.trimStart
        trimEnd = last.trimEnd
        canUndo = !undoStack.isEmpty
        dirty = true
        refreshFrame()
    }

    func setTrim(start: Double? = nil, end: Double? = nil) {
        if let start { trimStart = max(0, min(start, trimEnd - 0.2)) }
        if let end { trimEnd = min(duration, max(end, trimStart + 0.2)) }
        dirty = true
    }

    /// Neue Felder gelten zunächst für die ganze (gekürzte) Länge — lieber zu viel als zu wenig verdecken.
    func addRedaction(rect: CGRect) {
        checkpoint()
        let r = VideoRedaction(rect: rect.integral, start: trimStart, end: trimEnd, style: style)
        redactions.append(r)
        selectedID = r.id
        refreshFrame()
    }

    func updateRedaction(_ id: UUID, refresh: Bool = true, _ change: (inout VideoRedaction) -> Void) {
        guard let i = redactions.firstIndex(where: { $0.id == id }) else { return }
        change(&redactions[i])
        dirty = true
        if refresh { refreshFrame() }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        checkpoint()
        redactions.removeAll { $0.id == id }
        selectedID = nil
        refreshFrame()
    }

    func setStyle(_ s: RedactStyle) {
        style = s
        AppSettings.shared.redactStyle = s
        guard let id = selectedID else { return }
        checkpoint()
        updateRedaction(id) { $0.style = s }
    }

    func selectedStartHere() {
        guard let id = selectedID else { return }
        checkpoint()
        updateRedaction(id) { $0.start = min(self.currentTime, $0.end - 0.05) }
    }

    func selectedEndHere() {
        guard let id = selectedID else { return }
        checkpoint()
        updateRedaction(id) { $0.end = max(self.currentTime, $0.start + 0.05) }
    }

    func selectedWholeClip() {
        guard let id = selectedID else { return }
        checkpoint()
        updateRedaction(id) { $0.start = 0; $0.end = self.duration }
    }

    func isActive(_ r: VideoRedaction) -> Bool { currentTime >= r.start - 0.001 && currentTime <= r.end + 0.001 }

    /// Ausgewählter Balken folgt dem Inhalt (z. B. beim Scrollen) — ab der aktuellen Position vor und zurück.
    func followSelected() {
        guard busy == nil, let sel = selected else { return }
        busy = "Balken folgt dem Inhalt …"
        progress = 0
        let t0 = max(sel.start, min(currentTime, sel.end))
        let rect = sel.rect(at: t0)
        let asset = asset, size = videoSize, id = sel.id
        work = Task {
            do {
                let points = try await VideoRedactor.track(asset: asset, rect: rect, at: t0, start: sel.start, end: sel.end,
                                                           videoSize: size) { p in Task { @MainActor in self.progress = p } }
                busy = nil
                progress = nil
                checkpoint()
                updateRedaction(id) { $0.rect = rect; $0.track = points }
                showToast("Balken folgt dem Inhalt (\(points.count) Positionen)")
            } catch {
                busy = nil
                progress = nil
            }
        }
    }

    func unfollowSelected() {
        guard let id = selectedID else { return }
        checkpoint()
        let t = currentTime
        updateRedaction(id) { r in
            r.rect = r.rect(at: t)
            r.track = nil
        }
    }

    // MARK: Auto-Zensur

    func autoRedact() {
        guard busy == nil else { return }
        busy = "Suche sensible Daten im Video …"
        progress = 0
        let asset = asset, range = trimRange, style = style
        let kinds = AppSettings.shared.autoRedactKinds
        work = Task {
            do {
                let found = try await VideoRedactor.detect(asset: asset, range: range, step: 0.5, style: style, kinds: kinds) { p in
                    Task { @MainActor in self.progress = p }
                }
                busy = nil
                progress = nil
                guard !found.isEmpty else { showToast("Nichts Sensibles gefunden"); return }
                checkpoint()
                redactions.append(contentsOf: found)
                refreshFrame()
                showToast("\(found.count) Fundstelle\(found.count == 1 ? "" : "n") zensiert — bitte kurz prüfen")
            } catch {
                busy = nil
                progress = nil
            }
        }
    }

    // MARK: Speichern / Export

    func save() async -> Bool {
        busy = "Video wird gespeichert …"
        progress = 0
        defer { busy = nil; progress = nil }
        do {
            var exported: URL?
            if hasEdits {
                let tmp = Paths.temp.appendingPathComponent("export-\(UUID().uuidString).mp4")
                try await VideoRedactor.exportMP4(asset: asset, state: state, range: trimRange, to: tmp) { p in
                    Task { @MainActor in self.progress = p }
                }
                exported = tmp
            }
            item = try await CaptureStore.shared.saveVideo(exported: exported, document: document, for: item)
            dirty = false
            showToast("Gespeichert")
            return true
        } catch {
            Alerts.error("Speichern fehlgeschlagen", error)
            return false
        }
    }

    func exportGIF() {
        guard busy == nil else { return }
        busy = "GIF wird erstellt …"
        progress = 0
        let settings = AppSettings.shared
        let base = item.fileURL.deletingPathExtension()
        var url = base.appendingPathExtension("gif")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = URL(fileURLWithPath: base.path + " (\(n)).gif")
            n += 1
        }
        let target = url
        let asset = asset, range = trimRange
        work = Task {
            do {
                let size = try await VideoRedactor.exportGIF(asset: asset, state: state, range: range, fps: settings.gifFPS,
                                                             width: min(settings.gifWidth, Int(videoSize.width)), to: target) { p in
                    Task { @MainActor in self.progress = p }
                }
                busy = nil
                progress = nil
                let gif = CaptureStore.shared.addGIF(at: target, size: size, duration: range.duration.seconds)
                QuickAccessController.shared.show(gif, on: NSScreen.withMouse)
                showToast("GIF gespeichert")
            } catch {
                busy = nil
                progress = nil
                if !(error is CancellationError) { Alerts.error("GIF-Export fehlgeschlagen", error) }
            }
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: w)
    }

    private func loadThumbnails() {
        let asset = asset, duration = duration
        Task {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 220, height: 220)
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
            var images: [CGImage] = []
            let count = 12
            for i in 0..<count {
                let t = duration * (Double(i) + 0.5) / Double(count)
                if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { images.append(img) }
            }
            thumbnails = images
        }
    }
}
