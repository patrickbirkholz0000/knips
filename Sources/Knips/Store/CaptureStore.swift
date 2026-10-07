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

    var title: String { fileURL.deletingPathExtension().lastPathComponent }
}

/// Bearbeitungsstand eines Bildes — liegt neben dem Original, nie im Ablageordner.
struct ImageDocument: Codable {
    var version = 1
    var annotations: [Annotation] = []
    var crop: CGRect?
}

struct VideoRedaction: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Videopixel, Ursprung oben links.
    var rect: CGRect
    var start: Double
    var end: Double
    var style: RedactStyle
    var auto = false
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

    /// Legt den Eintrag sofort an; PNG-Kodierung und Schreiben laufen im Hintergrund.
    func addImage(_ image: CGImage, scale: CGFloat, png: PNGPromise? = nil, name: String? = nil) throws -> CaptureItem {
        let id = UUID()
        let output = try uniqueOutputURL(base: name ?? "Knips \(Format.fileDate.string(from: Date()))", ext: "png")
        reservedNames.insert(output.path)
        var item = CaptureItem(id: id, kind: .image, createdAt: Date(), fileURL: output,
                               pixelWidth: image.width, pixelHeight: image.height, scale: Double(scale))
        Paths.ensure(directory(for: item))
        item.revision = 1
        persist(item)
        items.insert(item, at: 0)
        remember(image, for: id)
        ThumbnailCache.shared.seed(item, image: image)
        let promise = png ?? PNGPromise(image)
        let original = originalURL(for: item), thumbURL = thumbnailURL(for: item)
        let snapshot = item
        beginWrite(id)
        writes[id] = Task.detached(priority: .userInitiated) {
            guard let data = await promise.value() else { return }
            try? data.write(to: original, options: .atomic)
            try? data.write(to: output, options: .atomic)
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

    private func remember(_ image: CGImage, for id: UUID) {
        memory.removeAll { $0.0 == id }
        memory.insert((id, image), at: 0)
        if memory.count > 4 { memory.removeLast() }
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
        saveImage(png: PNGPromise(rendered), document: document, for: item, size: rendered.pixelSize)
    }

    /// `png` rendert und kodiert im Hintergrund; `size` ist die erwartete Bildgröße.
    @discardableResult
    func saveImage(png promise: PNGPromise, document: ImageDocument, for item: CaptureItem, size: CGSize) -> CaptureItem {
        let updated = bump(item) { $0.pixelWidth = Int(size.width); $0.pixelHeight = Int(size.height) }
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
