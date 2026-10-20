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
    /// Hintergrund und Rahmen („Beautify“) — nil = ohne.
    var frame: FrameStyle?
}

/// Farbverlauf, Abstand, Ecken und Schatten rund um den Screenshot. Maße in Punkten.
struct FrameStyle: Codable, Equatable {
    var gradient = 0
    var padding: Double = 48
    var cornerRadius: Double = 12
    var shadow = true

    static let gradients: [(name: String, colors: [RGBA])] = [
        ("Indigo", [RGBA(r: 0.39, g: 0.40, b: 0.95), RGBA(r: 0.66, g: 0.33, b: 0.97)]),
        ("Abendrot", [RGBA(r: 0.98, g: 0.45, b: 0.09), RGBA(r: 0.93, g: 0.28, b: 0.60)]),
        ("Ozean", [RGBA(r: 0.02, g: 0.71, b: 0.83), RGBA(r: 0.23, g: 0.51, b: 0.96)]),
        ("Minze", [RGBA(r: 0.65, g: 0.95, b: 0.82), RGBA(r: 0.20, g: 0.78, b: 0.55)]),
        ("Graphit", [RGBA(r: 0.22, g: 0.25, b: 0.32), RGBA(r: 0.07, g: 0.09, b: 0.15)]),
        ("Hell", [RGBA(r: 0.96, g: 0.96, b: 0.97), RGBA(r: 0.88, g: 0.89, b: 0.91)]),
    ]
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
    private var housekeeping: Timer?
    private var lastWriteAlert: Date?

    private init() {
        Paths.ensure(Paths.items)
        load()
        Task.detached(priority: .utility) { Self.cleanTemp() }
        // Knips läuft oft wochenlang durch: abgelaufene Originale nicht nur beim Start entfernen.
        housekeeping = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            onMainActor { CaptureStore.shared.purgeExpired() }
        }
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
        var promise = outputPromise ?? settings.outputPromise(sourceScale: scale) { image }
        let factor = settings.outputFactor(sourceScale: scale)
        let width = Int((CGFloat(image.width) * factor).rounded()), height = Int((CGFloat(image.height) * factor).rounded())
        if Self.format(promise.format, width: width, height: height) != promise.format {
            // Zu lang für JPEG (z. B. Scroll-Screenshot): als PNG speichern statt still gar nicht.
            let rendered = promise
            promise = ImagePromise(format: .png) { rendered.image }
        }
        let output = try uniqueOutputURL(base: name ?? "Knips \(Format.fileDate.string(from: Date()))", ext: promise.format.fileExtension)
        reservedNames.insert(output.path)
        var item = CaptureItem(id: id, kind: .image, createdAt: Date(), fileURL: output,
                               pixelWidth: width, pixelHeight: height, scale: Double(scale))
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
            let originalError = Self.write(await original.value(), to: originalURL)
            let failure = Self.write(await promise.value(), to: output) ?? originalError
            let thumb = ImageIOHelper.downscale(image, maxPixel: 640)
            if let error = Self.write(thumb.pngData(), to: thumbURL) { Log.error("Vorschaubild nicht geschrieben: \(error.localizedDescription)") }
            await MainActor.run {
                ThumbnailCache.shared.seed(snapshot, image: thumb)
                self.reservedNames.remove(output.path)
                self.endWrite(id)
                if let failure { self.reportWriteFailure(failure, "Aufnahme konnte nicht gespeichert werden") }
            }
        }
        return item
    }

    /// Schreibt atomar und liefert den Fehler, statt ihn zu verschlucken (`nil` = geschrieben).
    nonisolated static func write(_ data: Data?, to url: URL) -> Error? {
        do {
            guard let data else { throw StoreError.encode }
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error
        }
    }

    /// JPEG schafft höchstens 65 535 px je Kante (darüber liefert ImageIO still keine Daten) → dann PNG.
    nonisolated static let jpegMaxPixel = 65_535
    nonisolated static func format(_ format: ImageFormat, width: Int, height: Int) -> ImageFormat {
        format == .jpeg && max(width, height) > jpegMaxPixel ? .png : format
    }

    /// Schreibfehler nie verschlucken: Meldung (höchstens eine alle 10 s, sonst als Einblendung) und Protokoll.
    func reportWriteFailure(_ error: Error, _ title: String) {
        Log.error("\(title): \(error.localizedDescription)")
        #if KNIPS_DEV
        if Paths.testRoot != nil {
            debugWriteFailures.append(title)
            return
        }
        #endif
        if let last = lastWriteAlert, Date().timeIntervalSince(last) < 10 {
            HUD.show(title, symbol: "exclamationmark.triangle.fill")
            return
        }
        lastWriteAlert = Date()
        Task { @MainActor in Alerts.error(title, error) }
    }

    #if KNIPS_DEV
    /// Nur Test-Sandbox: gemeldete Schreibfehler statt Dialog.
    var debugWriteFailures: [String] = []
    #endif

    /// Wartet, bis alle Schreibvorgänge dieser Aufnahme auf der Platte sind.
    func waitUntilWritten(_ id: UUID) async {
        await writes[id]?.value
    }

    /// Wartet auf alle laufenden Schreibvorgänge (Beenden der App).
    func waitForAllWrites() async {
        for task in Array(writes.values) { await task.value }
    }

    var hasPendingWrites: Bool { !pendingCount.isEmpty }

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
        reservedNames.insert(output.path)
        defer { reservedNames.remove(output.path) }
        let asset = AVURLAsset(url: tempURL)
        let duration = try await asset.load(.duration).seconds
        let size = try await VideoInfo.pixelSize(of: asset)
        var item = CaptureItem(id: id, kind: .video, createdAt: Date(), fileURL: output,
                               pixelWidth: Int(size.width), pixelHeight: Int(size.height), scale: Double(scale), duration: duration)
        let dir = directory(for: item), original = originalURL(for: item)
        // Auf ein anderes Laufwerk wird echt kopiert — das dauert bei langen Videos und darf nie den
        // Hauptthread aufhalten. Schlägt es fehl, kommt die Aufnahme zurück an ihren alten Platz.
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: tempURL, to: original)
            do {
                try Self.linkOrCopy(original, to: output)
            } catch {
                try? fm.removeItem(at: output)
                try? fm.moveItem(at: original, to: tempURL)
                try? fm.removeItem(at: dir)
                throw StoreError.videoCopy(tempURL, error)
            }
        }.value
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
            let docError = Self.write(docData, to: docURL)
            let failure = Self.write(await promise.value(), to: output) ?? docError
            let thumb = await promise.imageValue().map { ImageIOHelper.downscale($0, maxPixel: 640) }
            if let thumb, let error = Self.write(thumb.pngData(), to: thumbURL) {
                Log.error("Vorschaubild nicht geschrieben: \(error.localizedDescription)")
            }
            await MainActor.run {
                if let thumb { ThumbnailCache.shared.seed(updated, image: thumb) }
                self.endWrite(id)
                if let failure { self.reportWriteFailure(failure, "Änderungen konnten nicht gespeichert werden") }
            }
        }
        return updated
    }

    @discardableResult
    func saveVideo(exported url: URL?, document: VideoDocument, for item: CaptureItem) async throws -> CaptureItem {
        let docData = try JSONEncoder().encode(document)
        let docURL = documentURL(for: item), fileURL = item.fileURL, original = originalURL(for: item)
        // Verschieben bzw. Kopieren (anderes Laufwerk) im Hintergrund, nie im Hauptthread.
        try await Task.detached(priority: .userInitiated) {
            try docData.write(to: docURL, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) { try fm.removeItem(at: fileURL) }
            if let url {
                try fm.moveItem(at: url, to: fileURL)
            } else {
                // Keine Änderungen: Ablage wieder auf das Original zeigen lassen.
                try Self.linkOrCopy(original, to: fileURL)
            }
        }.value
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
        if let error = Self.write(image.pngData(), to: thumbnailURL(for: item)) {
            Log.error("Vorschaubild nicht geschrieben: \(error.localizedDescription)")
        }
    }

    /// Originale + Bearbeitungsstand, die älter als die eingestellte Frist sind, entfernen (beim Start und
    /// alle 6 h). Die Dateien im Ablageordner bleiben; was gerade geschrieben wird, kommt beim nächsten Mal dran.
    func purgeExpired(now: Date = Date(), days: Int? = nil) {
        let days = days ?? AppSettings.shared.retentionDays
        Task.detached(priority: .utility) { Self.cleanTemp() }
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 3600)
        let expired = items.filter { $0.createdAt < cutoff && !isWriting($0.id) }
        guard !expired.isEmpty else { return }
        let ids = Set(expired.map(\.id))
        items.removeAll { ids.contains($0.id) }
        memory.removeAll { ids.contains($0.0) }
        for id in ids { writes[id] = nil }
        let dirs = expired.map { directory(for: $0) }
        Task.detached(priority: .utility) { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }
    }

    /// Reste in `$TMPDIR/Knips` (Aufnahmen und Exporte, etwa nach einem Absturz): alles, woran seit einer
    /// Stunde nicht mehr geschrieben wurde. Eine laufende Aufnahme schreibt ständig und bleibt unberührt.
    /// In der Test-Sandbox nur mit eigenem Ordner — `$TMPDIR/Knips` gehört dann der installierten App.
    nonisolated static func cleanTemp(olderThan age: TimeInterval = 3600, in folder: URL? = nil) {
        guard folder != nil || Paths.testRoot == nil else { return }
        let folder = folder ?? Paths.temp
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
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
        let preferred = AppSettings.shared.saveFolder
        let (folder, fellBack) = try Self.usableFolder(preferred, fallback: Self.defaultFolder)
        if fellBack {
            Log.error("Ablageordner nicht erreichbar: \(preferred.path) – gespeichert in \(folder.path)")
            HUD.show("Ablageordner nicht erreichbar – gespeichert in „Bilder/Knips“", symbol: "exclamationmark.triangle.fill")
        }
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || reservedNames.contains(url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// Standard-Ablage `~/Pictures/Knips` — Ausweichziel, wenn der eingestellte Ordner nicht erreichbar ist.
    static var defaultFolder: URL? {
        if Paths.testRoot != nil { return nil }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("Knips", isDirectory: true)
    }

    /// Ablageordner anlegen und prüfen. Ist er nicht erreichbar (Netzlaufwerk nicht eingehängt, keine
    /// Schreibrechte), kommt `fallback` zum Zug; `true` = ausgewichen.
    nonisolated static func usableFolder(_ preferred: URL, fallback: URL?) throws -> (URL, Bool) {
        let fm = FileManager.default
        func prepare(_ folder: URL) throws {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard fm.isWritableFile(atPath: folder.path) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
            }
        }
        do {
            try prepare(preferred)
            return (preferred, false)
        } catch {
            guard let fallback, fallback.standardizedFileURL.path != preferred.standardizedFileURL.path else { throw error }
            try prepare(fallback)
            return (fallback, true)
        }
    }

    /// Hardlink spart bei Videos den doppelten Platz; beim Speichern wird die Ablage atomar ersetzt,
    /// das Original bleibt dadurch unberührt.
    nonisolated private static func linkOrCopy(_ src: URL, to dst: URL) throws {
        do { try FileManager.default.linkItem(at: src, to: dst) } catch { try FileManager.default.copyItem(at: src, to: dst) }
    }

    enum StoreError: LocalizedError {
        case encode, read
        case videoCopy(URL, Error)
        var errorDescription: String? {
            switch self {
            case .encode: "Das Bild konnte nicht als PNG gespeichert werden."
            case .read: "Die Datei konnte nicht gelesen werden."
            case .videoCopy(let temp, let error):
                "Das Video konnte nicht in den Ablageordner kopiert werden (\(error.localizedDescription)). "
                    + "Die Aufnahme liegt vorerst unter \(temp.path) – bitte gleich sichern, Knips räumt den Ordner nach einer Stunde auf."
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
