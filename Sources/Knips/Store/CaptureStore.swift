import AppKit
import AVFoundation

enum CaptureKind: String, Codable { case image, video, gif }

struct CaptureItem: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var kind: CaptureKind
    var createdAt: Date
    /// Sichtbare Datei im Ablageordner — immer die gerenderte (zensierte) Fassung.
    var fileURL: URL
    var pixelWidth: Int
    var pixelHeight: Int
    /// Punkte → Pixel (2 bei Retina). Maßstab für Strichstärken und Schriftgrößen im Editor.
    var scale: Double
    var duration: Double?
    var revision: Int = 0
    /// Pixel pro Punkt der Datei im Ablageordner (1 bei verkleinerter Ausgabe). Fehlt bei alten Einträgen.
    var outputScale: Double?

    /// Für Anpinnen & Co.: wie groß die Datei auf dem Bildschirm erscheinen soll.
    var displayScale: CGFloat { CGFloat(outputScale ?? scale) }

    var title: String { fileURL.deletingPathExtension().lastPathComponent }
}

/// Bearbeitungsstand eines Bildes — liegt neben dem Original, nie im Ablageordner.
struct ImageDocument: Codable {
    var version = 1
    var annotations: [Annotation] = []
    var crop: CGRect?
}

struct VideoRedaction: Codable, Identifiable, Equatable {
    struct TrackPoint: Codable, Equatable {
        var time: Double
        var rect: CGRect
    }

    var id = UUID()
    /// Videopixel, Ursprung oben links.
    var rect: CGRect
    var start: Double
    var end: Double
    var style: RedactStyle
    var auto = false
    /// Wegpunkte, wenn der Balken bewegtem Inhalt folgt; dazwischen wird linear überblendet.
    var track: [TrackPoint]?

    func rect(at t: Double) -> CGRect {
        guard let track, let first = track.first, let last = track.last else { return rect }
        if t <= first.time { return first.rect }
        if t >= last.time { return last.rect }
        var lo = 0, hi = track.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if track[mid].time <= t { lo = mid } else { hi = mid }
        }
        let a = track[lo], b = track[hi]
        let f = CGFloat((t - a.time) / max(0.0001, b.time - a.time))
        return CGRect(x: a.rect.minX + (b.rect.minX - a.rect.minX) * f, y: a.rect.minY + (b.rect.minY - a.rect.minY) * f,
                      width: a.rect.width + (b.rect.width - a.rect.width) * f, height: a.rect.height + (b.rect.height - a.rect.height) * f)
    }

    mutating func offset(dx: CGFloat, dy: CGFloat) {
        rect.origin.x += dx
        rect.origin.y += dy
        track = track?.map { TrackPoint(time: $0.time, rect: $0.rect.offsetBy(dx: dx, dy: dy)) }
    }
}

struct VideoDocument: Codable {
    var version = 1
    var trimStart: Double?
    var trimEnd: Double?
    var redactions: [VideoRedaction] = []
}

@MainActor final class CaptureStore: ObservableObject {
    static let shared = CaptureStore()

    @Published private(set) var items: [CaptureItem] = []
    /// Laufende Schreibvorgänge je Aufnahme (in Reihe). Kopieren/Ziehen/Löschen warten darauf.
    private var writes: [UUID: Task<Void, Never>] = [:]
    /// Zuletzt aufgenommene Originale im Speicher — der Editor öffnet sie ohne Umweg über die Platte.
    private var memory: [(UUID, CGImage)] = []
    private var pendingCount: [UUID: Int] = [:]
    /// Dateinamen, die vergeben, aber noch nicht geschrieben sind.
    private var reservedNames: Set<String> = []

    private init() {
        Paths.ensure(Paths.items)
        load()
    }

    var recent: [CaptureItem] { Array(items.prefix(12)) }

    func directory(for item: CaptureItem) -> URL { Paths.items.appendingPathComponent(item.id.uuidString, isDirectory: true) }
    func originalURL(for item: CaptureItem) -> URL {
        directory(for: item).appendingPathComponent(item.kind == .image ? "original.png" : (item.kind == .gif ? "original.gif" : "original.mp4"))
    }
    func documentURL(for item: CaptureItem) -> URL { directory(for: item).appendingPathComponent("document.json") }
    func thumbnailURL(for item: CaptureItem) -> URL { directory(for: item).appendingPathComponent("thumb.png") }
    private func metaURL(for item: CaptureItem) -> URL { directory(for: item).appendingPathComponent("item.json") }

    // MARK: Anlegen

    /// Legt den Eintrag sofort an; Kodieren und Schreiben laufen im Hintergrund.
    /// Das Original bleibt in voller Auflösung (für spätere Bearbeitung), die Datei im Ablageordner
    /// kommt aus `output` (ggf. verkleinert, im gewählten Format).
    func addImage(_ image: CGImage, scale: CGFloat, output outputPromise: ImagePromise? = nil, name: String? = nil) throws -> CaptureItem {
        let id = UUID()
        let settings = AppSettings.shared
        let promise = outputPromise ?? settings.outputPromise(sourceScale: scale) { image }
        let factor = settings.outputFactor(sourceScale: scale)
        let output = try uniqueOutputURL(base: name ?? "Knips \(Format.fileDate.string(from: Date()))", ext: promise.format.fileExtension)
        reservedNames.insert(output.path)
        var item = CaptureItem(id: id, kind: .image, createdAt: Date(), fileURL: output,
                               pixelWidth: Int((CGFloat(image.width) * factor).rounded()),
                               pixelHeight: Int((CGFloat(image.height) * factor).rounded()), scale: Double(scale))
        item.outputScale = Double(scale * factor)
        Paths.ensure(directory(for: item))
        item.revision = 1
        persist(item)
        items.insert(item, at: 0)
        remember(image, for: id)
        ThumbnailCache.shared.seed(item, image: image)
        // Original verlustfrei in voller Auflösung; bei gleicher Ausgabe dieselben Daten wiederverwenden.
        let original = factor < 1 || promise.format != .png ? ImagePromise(image) : promise
        let originalURL = originalURL(for: item), thumbURL = thumbnailURL(for: item)
        let snapshot = item
        beginWrite(id)
        writes[id] = Task.detached(priority: .userInitiated) {
            if let data = await original.value() { try? data.write(to: originalURL, options: .atomic) }
            if let data = await promise.value() { try? data.write(to: output, options: .atomic) }
            let thumb = ImageIOHelper.downscale(image, maxPixel: 640)
            try? thumb.pngData()?.write(to: thumbURL, options: .atomic)
            await MainActor.run {
                ThumbnailCache.shared.seed(snapshot, image: thumb)
                self.reservedNames.remove(output.path)
                self.endWrite(id)
            }
        }
        return item
    }

    /// Wartet, bis alle Schreibvorgänge dieser Aufnahme auf der Platte sind.
    func waitUntilWritten(_ id: UUID) async {
        await writes[id]?.value
    }

    func memoryImage(for id: UUID) -> CGImage? { memory.first { $0.0 == id }?.1 }

    func isWriting(_ id: UUID) -> Bool { (pendingCount[id] ?? 0) > 0 }
    private func beginWrite(_ id: UUID) { pendingCount[id, default: 0] += 1 }
    private func endWrite(_ id: UUID) {
        let n = (pendingCount[id] ?? 1) - 1
        pendingCount[id] = n > 0 ? n : nil
    }

    /// Ein 4K-Original belegt ~37 MB. Nach einer Minute zählt der Zeitvorteil nicht mehr —
    /// dann lädt der Editor in ~50 ms von der Platte.
    private var evictWork: DispatchWorkItem?

    private func remember(_ image: CGImage, for id: UUID) {
        memory.removeAll { $0.0 == id }
        memory.insert((id, image), at: 0)
        if memory.count > 4 { memory.removeLast() }
        evictWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.memory.removeAll() }
        evictWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    func addVideo(from tempURL: URL, scale: CGFloat) async throws -> CaptureItem {
        let id = UUID()
        let output = try uniqueOutputURL(base: "Knips Aufnahme \(Format.fileDate.string(from: Date()))", ext: "mp4")
        let asset = AVURLAsset(url: tempURL)
        let duration = try await asset.load(.duration).seconds
        let size = try await VideoInfo.pixelSize(of: asset)
        var item = CaptureItem(id: id, kind: .video, createdAt: Date(), fileURL: output,
                               pixelWidth: Int(size.width), pixelHeight: Int(size.height), scale: Double(scale), duration: duration)
        Paths.ensure(directory(for: item))
        try FileManager.default.moveItem(at: tempURL, to: originalURL(for: item))
        try linkOrCopy(originalURL(for: item), to: output)
        if let thumb = await ImageIOHelper.videoThumbnail(output, maxPixel: 640) { writeThumbnail(thumb, for: item) }
        item.revision = 1
        persist(item)
        items.insert(item, at: 0)
        return item
    }

    func addGIF(at url: URL, size: CGSize, duration: Double) -> CaptureItem {
        var item = CaptureItem(id: UUID(), kind: .gif, createdAt: Date(), fileURL: url,
                               pixelWidth: Int(size.width), pixelHeight: Int(size.height), scale: 1, duration: duration)
        Paths.ensure(directory(for: item))
        if let thumb = ImageIOHelper.thumbnail(url, maxPixel: 640) { writeThumbnail(thumb, for: item) }
        item.revision = 1
        persist(item)
        items.insert(item, at: 0)
        return item
    }

    func importImage(at url: URL) throws -> CaptureItem {
        guard let image = ImageIOHelper.load(url) else { throw StoreError.read }
        let name = url.deletingPathExtension().lastPathComponent + " bearbeitet"
        return try addImage(image, scale: 1, name: name)
    }

    // MARK: Bearbeiten

    func loadImageDocument(for item: CaptureItem) -> ImageDocument {
        guard let data = try? Data(contentsOf: documentURL(for: item)),
              let doc = try? JSONDecoder().decode(ImageDocument.self, from: data) else { return ImageDocument() }
        return doc
    }

    func loadVideoDocument(for item: CaptureItem) -> VideoDocument {
        guard let data = try? Data(contentsOf: documentURL(for: item)),
              let doc = try? JSONDecoder().decode(VideoDocument.self, from: data) else { return VideoDocument() }
        return doc
    }

    /// Schreibt die gerenderte Fassung in den Ablageordner und merkt sich den Bearbeitungsstand.
    /// Kehrt sofort zurück; geschrieben wird im Hintergrund, in Reihe nach früheren Schreibvorgängen.
    @discardableResult
    func saveImage(_ rendered: CGImage, document: ImageDocument, for item: CaptureItem) -> CaptureItem {
        let format = ImageFormat(fileExtension: item.fileURL.pathExtension) ?? .png
        return saveImage(output: ImagePromise(rendered, format: format), document: document, for: item,
                         size: rendered.pixelSize, outputScale: item.scale)
    }

    /// `promise` rendert und kodiert im Hintergrund; `size`/`outputScale` beschreiben die Ausgabedatei.
    @discardableResult
    func saveImage(output promise: ImagePromise, document: ImageDocument, for item: CaptureItem, size: CGSize, outputScale: Double) -> CaptureItem {
        let updated = bump(item) {
            $0.pixelWidth = Int(size.width)
            $0.pixelHeight = Int(size.height)
            $0.outputScale = outputScale
        }
        let previous = writes[item.id]
        let docData = try? JSONEncoder().encode(document)
        let docURL = documentURL(for: item), output = item.fileURL, thumbURL = thumbnailURL(for: item)
        let id = item.id
        beginWrite(id)
        writes[item.id] = Task.detached(priority: .userInitiated) {
            await previous?.value
            try? docData?.write(to: docURL, options: .atomic)
            if let data = await promise.value() { try? data.write(to: output, options: .atomic) }
            guard let rendered = await promise.imageValue() else {
                await MainActor.run { self.endWrite(id) }
                return
            }
            let thumb = ImageIOHelper.downscale(rendered, maxPixel: 640)
            try? thumb.pngData()?.write(to: thumbURL, options: .atomic)
            await MainActor.run {
                ThumbnailCache.shared.seed(updated, image: thumb)
                self.endWrite(id)
            }
        }
        return updated
    }

    @discardableResult
    func saveVideo(exported url: URL?, document: VideoDocument, for item: CaptureItem) async throws -> CaptureItem {
        try JSONEncoder().encode(document).write(to: documentURL(for: item), options: .atomic)
        let fm = FileManager.default
        if let url {
            if fm.fileExists(atPath: item.fileURL.path) { try fm.removeItem(at: item.fileURL) }
            try fm.moveItem(at: url, to: item.fileURL)
        } else {
            // Keine Änderungen: Ablage wieder auf das Original zeigen lassen.
            if fm.fileExists(atPath: item.fileURL.path) { try fm.removeItem(at: item.fileURL) }
            try linkOrCopy(originalURL(for: item), to: item.fileURL)
        }
        let duration = try? await AVURLAsset(url: item.fileURL).load(.duration).seconds
        if let thumb = await ImageIOHelper.videoThumbnail(item.fileURL, maxPixel: 640) { writeThumbnail(thumb, for: item) }
        return bump(item) { $0.duration = duration ?? $0.duration }
    }

    func delete(_ item: CaptureItem) {
        items.removeAll { $0.id == item.id }
        memory.removeAll { $0.0 == item.id }
        let pending = writes[item.id]
        writes[item.id] = nil
        let dir = directory(for: item)
        // Erst nach dem letzten Schreibvorgang löschen, sonst legt er die Datei wieder an.
        Task.detached {
            await pending?.value
            let fm = FileManager.default
            if fm.fileExists(atPath: item.fileURL.path) { try? fm.trashItem(at: item.fileURL, resultingItemURL: nil) }
            try? fm.removeItem(at: dir)
        }
    }

    func item(with id: UUID) -> CaptureItem? { items.first { $0.id == id } }

    /// Platzbedarf der Originale in Bytes.
    func storageSize() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: Paths.items, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Entfernt alle Originale (Bearbeitung danach nicht mehr umkehrbar). Dateien im Ablageordner bleiben.
    func purgeOriginals() {
        try? FileManager.default.removeItem(at: Paths.items)
        Paths.ensure(Paths.items)
        items.removeAll()
    }

    // MARK: Intern

    private func bump(_ item: CaptureItem, _ change: (inout CaptureItem) -> Void) -> CaptureItem {
        var updated = items.first { $0.id == item.id } ?? item
        change(&updated)
        updated.revision += 1
        persist(updated)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = updated }
        return updated
    }

    private func persist(_ item: CaptureItem) {
        if let data = try? JSONEncoder().encode(item) { try? data.write(to: metaURL(for: item), options: .atomic) }
    }

    private func writeThumbnail(_ image: CGImage, for item: CaptureItem) {
        try? image.pngData()?.write(to: thumbnailURL(for: item), options: .atomic)
    }

    private func load() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.items, includingPropertiesForKeys: nil) else { return }
        var loaded: [CaptureItem] = []
        // Originale + Bearbeitungsstand verfallen nach der eingestellten Frist; die Dateien im Ablageordner bleiben.
        let days = AppSettings.shared.retentionDays
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 24 * 3600) : .distantPast
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("item.json")),
                  let item = try? JSONDecoder().decode(CaptureItem.self, from: data) else {
                try? fm.removeItem(at: dir)
                continue
            }
            if item.createdAt < cutoff {
                try? fm.removeItem(at: dir)
                continue
            }
            loaded.append(item)
        }
        items = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    private func uniqueOutputURL(base: String, ext: String) throws -> URL {
        let folder = AppSettings.shared.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || reservedNames.contains(url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// Hardlink spart bei Videos den doppelten Platz; beim Speichern wird die Ablage atomar ersetzt,
    /// das Original bleibt dadurch unberührt.
    private func linkOrCopy(_ src: URL, to dst: URL) throws {
        do { try FileManager.default.linkItem(at: src, to: dst) } catch { try FileManager.default.copyItem(at: src, to: dst) }
    }

    enum StoreError: LocalizedError {
        case encode, read
        var errorDescription: String? {
            switch self {
            case .encode: "Das Bild konnte nicht als PNG gespeichert werden."
            case .read: "Die Datei konnte nicht gelesen werden."
            }
        }
    }
}

enum VideoInfo {
    static func pixelSize(of asset: AVAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .zero }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }
}
