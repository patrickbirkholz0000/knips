import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum Paths {
    /// Selbsttests laufen isoliert in `KNIPS_TEST_DIR`, nie in der echten Ablage.
    static var testRoot: URL? {
        #if KNIPS_DEV
        return ProcessInfo.processInfo.environment["KNIPS_TEST_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        return nil
        #endif
    }

    static var appSupport: URL {
        if let testRoot { return testRoot.appendingPathComponent("support", isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Knips", isDirectory: true)
    }

    static var items: URL { appSupport.appendingPathComponent("items", isDirectory: true) }

    static var temp: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Knips", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

extension CGImage {
    /// PNG ohne ungenutzten Alphakanal (deckende Bilder werden RGB statt RGBA: gleiche Pixel, ~12 % kleiner).
    /// `pointScale`: Pixel pro Punkt. Über 1 (Retina-Ausgabe) steht die Auflösung in der Datei (2× = 144 dpi), wie
    /// bei Bildschirmfotos von macOS — Vorschau, Mail, Pages und Keynote zeigen das Bild dann so groß wie auf dem
    /// Bildschirm statt doppelt so groß.
    func pngData(pointScale: CGFloat = 1) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, ImageIOHelper.withoutUnusedAlpha(self), ImageIOHelper.resolution(pointScale) as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    var pixelSize: CGSize { CGSize(width: width, height: height) }
}

enum ImageIOHelper {
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Auf `factor` (< 1) verkleinern, z. B. Retina → Bildschirmgröße.
    static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage {
        guard factor < 0.999 else { return image }
        // Retina → 1× ist genau die Hälfte: jedes Pixel als Mittel seiner 2×2 Pixel. Die allgemeine Interpolation
        // („.high“) legte helle und dunkle Säume um Schrift und ließ feine Linien verlaufen; die Dateien waren
        // dadurch auch rund ein Drittel größer (gemessen 13.11.2026 an 40 Aufnahmen).
        if abs(factor - 0.5) < 0.0001, image.width % 2 == 0, image.height % 2 == 0, let half = halved(image) { return half }
        let w = max(1, Int((CGFloat(image.width) * factor).rounded())), h = max(1, Int((CGFloat(image.height) * factor).rounded()))
        let space = Renderer.rgbSpace(image.colorSpace)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    private static let bgra = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    private static let bgrx = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Halbe Breite und Höhe: jedes Pixel ist das gerundete Mittel aus 2×2 Pixeln (vormultipliziert, je Kanal).
    /// Gelesen wird in Streifen, damit auch ein 60 000 px hoher Scroll-Screenshot keine zweite Kopie in voller
    /// Größe braucht. Deckende Bilder kommen ohne Alphakanal zurück.
    static func halved(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height, ow = w / 2, oh = h / 2
        guard ow > 0, oh > 0 else { return nil }
        let space = Renderer.rgbSpace(image.colorSpace)
        let band = min(h, 512)   // gerade Zeilenzahl
        guard let ctx = CGContext(data: nil, width: w, height: band, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: bgra),
              let raw = ctx.data, let out = malloc(ow * oh * 4) else { return nil }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        let src = raw.assumingMemoryBound(to: UInt8.self), dst = out.assumingMemoryBound(to: UInt8.self)
        var alpha: UInt8 = 255
        var top = 0
        while top < h {
            let rows = min(band, h - top)
            // Zeilen `top ..< top + rows` des Bildes (von oben) liegen danach in den ersten `rows` Zeilen des Streifens.
            ctx.draw(image, in: CGRect(x: 0, y: CGFloat(band + top - h), width: CGFloat(w), height: CGFloat(h)))
            for y in 0..<(rows / 2) {
                let a = src + (2 * y) * w * 4, b = a + w * 4, o = dst + (top / 2 + y) * ow * 4
                for x in 0..<ow {
                    let i = x * 8, j = x * 4
                    o[j] = UInt8((Int(a[i]) + Int(a[i + 4]) + Int(b[i]) + Int(b[i + 4]) + 2) >> 2)
                    o[j + 1] = UInt8((Int(a[i + 1]) + Int(a[i + 5]) + Int(b[i + 1]) + Int(b[i + 5]) + 2) >> 2)
                    o[j + 2] = UInt8((Int(a[i + 2]) + Int(a[i + 6]) + Int(b[i + 2]) + Int(b[i + 6]) + 2) >> 2)
                    let v = UInt8((Int(a[i + 3]) + Int(a[i + 7]) + Int(b[i + 3]) + Int(b[i + 7]) + 2) >> 2)
                    o[j + 3] = v
                    alpha &= v
                }
            }
            top += rows
        }
        return bitmapImage(out, width: ow, height: oh, space: space, opaque: alpha == 255)
    }

    /// Übernimmt den Speicher `pixels` (BGRA, vormultipliziert) als Bild; freigegeben wird er mit dem Bild.
    private static func bitmapImage(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int, space: CGColorSpace, opaque: Bool) -> CGImage? {
        let data = Data(bytesNoCopy: pixels, count: width * height * 4, deallocator: .free)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: opaque ? bgrx : bgra), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Größte Pixelzahl, für die `withoutUnusedAlpha` eine Kopie anlegt (6K-Bildschirm in 2× ≈ 20 MP).
    private static let alphaCheckMaxPixels = 40_000_000

    /// Dasselbe Bild ohne Alphakanal, wenn kein Pixel durchsichtig ist — PNG wird dann RGB statt RGBA.
    /// Bilder mit Durchsicht (Fenster mit runden Ecken) bleiben, wie sie sind.
    static func withoutUnusedAlpha(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast, .alphaOnly: return image
        default: break
        }
        let w = image.width, h = image.height
        guard image.bitsPerComponent == 8, w * h <= alphaCheckMaxPixels, let pixels = malloc(w * h * 4) else { return image }
        let space = rgbSpace(image)
        guard let ctx = CGContext(data: pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: bgra) else {
            free(pixels)
            return image
        }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = pixels.assumingMemoryBound(to: UInt8.self)
        var alpha: UInt8 = 255
        var i = 3
        let end = w * h * 4
        while i < end, alpha == 255 {
            // Zeilenweise, damit ein durchsichtiges Bild (Ecke oben links) sofort erkannt ist.
            let stop = min(end, i + w * 4)
            while i < stop { alpha &= p[i]; i += 4 }
        }
        guard alpha == 255, let opaque = bitmapImage(pixels, width: w, height: h, space: space, opaque: true) else {
            if alpha != 255 { free(pixels) }
            return image
        }
        return opaque
    }

    private static func rgbSpace(_ image: CGImage) -> CGColorSpace { Renderer.rgbSpace(image.colorSpace) }

    /// Auflösung für die Datei: `nil` bei 1× (72 dpi ist ohnehin die Annahme), sonst 72 dpi × Pixel pro Punkt.
    static func resolution(_ pointScale: CGFloat) -> [CFString: Any]? {
        guard pointScale > 1.01 else { return nil }
        let dpi = Double(72 * pointScale)
        return [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    }

    /// Pixel pro Punkt laut Auflösung in den Bilddaten (144 dpi → 2), ohne Angabe 1.
    static func pointScale(of source: CGImageSource) -> CGFloat {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi > 72.5 else { return 1 }
        return CGFloat(dpi / 72).clamped(to: 1...4)
    }

    static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let f = CGFloat(maxPixel) / CGFloat(longest)
        let w = max(1, Int(CGFloat(image.width) * f)), h = max(1, Int(CGFloat(image.height) * f))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func videoThumbnail(_ url: URL, maxPixel: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? await gen.image(at: .zero).image
    }
}

enum ImageFormat: String, CaseIterable, Identifiable, Codable {
    case png, jpeg
    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG (kleiner)" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var utType: UTType { self == .png ? .png : .jpeg }
    var pasteboardType: NSPasteboard.PasteboardType { self == .png ? .png : NSPasteboard.PasteboardType(UTType.jpeg.identifier) }

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        default: return nil
        }
    }
}

extension CGImage {
    /// PNG verlustfrei; JPEG mit 85 % — Schrift bleibt scharf, Datei ~3× kleiner als PNG. JPEG kennt keine
    /// Durchsicht: Durchsichtiges (runde Fensterecken) wird weiß statt schwarz.
    func encoded(as format: ImageFormat, pointScale: CGFloat = 1) -> Data? {
        if format == .png { return pngData(pointScale: pointScale) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85,
                                      kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)]
        if let resolution = ImageIOHelper.resolution(pointScale) { props.merge(resolution) { $1 } }
        CGImageDestinationAddImage(dest, self, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

/// Bild rendern und kodieren im Hintergrund. Ein 4K-PNG braucht ~80–180 ms — das darf weder das
/// Overlay noch die Karte aufhalten. `data`/`image` warten, falls die Arbeit noch läuft.
final class ImagePromise: @unchecked Sendable {
    let format: ImageFormat
    /// Ausgabe „Automatisch“: Auflösung und Farbtiefe stehen erst nach dem Kodieren fest (volle Auflösung mit 256
    /// Farben oder Bildschirmgröße). Solche Daten taugen nicht als Original, und die Maße des Eintrags zieht der
    /// Store nach (`CaptureStore.settleOutput`).
    let adaptive: Bool
    private var scale: CGFloat
    /// Pixel pro Punkt des fertigen Bildes (2 = Retina-Ausgabe): steht als Auflösung in der Datei. Wartet, falls
    /// die Arbeit noch läuft.
    var pointScale: CGFloat {
        group.wait()
        return scale
    }
    private let group = DispatchGroup()
    private var renderedImage: CGImage?
    private var result: Data?
    private static let queue = DispatchQueue(label: "de.birkgroup.knips.encode", qos: .userInitiated, attributes: .concurrent)

    convenience init(_ image: CGImage, format: ImageFormat = .png) {
        self.init(format: format, render: { image })
    }

    /// Rendert (z. B. Editor-Fassung mit Zensur, ggf. verkleinert) und kodiert anschließend.
    init(format: ImageFormat, pointScale: CGFloat = 1, render: @escaping @Sendable () -> CGImage?) {
        self.format = format
        adaptive = false
        scale = pointScale
        group.enter()
        Self.queue.async { [self] in
            renderedImage = render()
            result = renderedImage?.encoded(as: format, pointScale: pointScale)
            group.leave()
        }
    }

    /// Rendern und Kodieren in einem Schritt, der selbst über Auflösung und Daten entscheidet („Automatisch“).
    init(format: ImageFormat, adaptive work: @escaping @Sendable () -> (image: CGImage, data: Data?, pointScale: CGFloat)?) {
        self.format = format
        adaptive = true
        scale = 1
        group.enter()
        Self.queue.async { [self] in
            if let done = work() {
                renderedImage = done.image
                result = done.data
                scale = done.pointScale
            }
            group.leave()
        }
    }

    /// Bereits kodierte Daten (z. B. aus einer Datei) — keine erneute Kodierung.
    init(image: CGImage, data: Data, format: ImageFormat, pointScale: CGFloat = 1) {
        self.format = format
        adaptive = false
        scale = pointScale
        renderedImage = image
        result = data
    }

    var image: CGImage? {
        group.wait()
        return renderedImage
    }

    var data: Data? {
        group.wait()
        return result
    }

    func value() async -> Data? {
        await withCheckedContinuation { cont in
            group.notify(queue: .global(qos: .userInitiated)) { [self] in cont.resume(returning: result) }
        }
    }

    func imageValue() async -> CGImage? {
        await withCheckedContinuation { cont in
            group.notify(queue: .global(qos: .userInitiated)) { [self] in cont.resume(returning: renderedImage) }
        }
    }
}

/// Liefert die Bilddaten erst, wenn eine App sie wirklich anfragt.
private final class LazyImageProvider: NSObject, NSPasteboardItemDataProvider {
    let promise: ImagePromise
    init(promise: ImagePromise) { self.promise = promise }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == promise.format.pasteboardType {
            if let data = promise.data { item.setData(data, forType: type) }
        } else if type == .png {
            if let data = promise.image?.pngData(pointScale: promise.pointScale) { item.setData(data, forType: .png) }
        } else if type == .tiff {
            guard let image = promise.image else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            // Größe in Punkten → Auflösung im TIFF (Retina-Ausgabe: 144 dpi).
            rep.size = NSSize(width: CGFloat(image.width) / promise.pointScale, height: CGFloat(image.height) / promise.pointScale)
            if let data = rep.tiffRepresentation { item.setData(data, forType: .tiff) }
        }
    }
}

enum Clipboard {
    private static var provider: LazyImageProvider?
    /// Aufnahme, die Knips zuletzt in die Zwischenablage gelegt hat, mit dem `changeCount` danach. Solange niemand
    /// anderes etwas kopiert hat, ersetzt der Editor sie beim Speichern durch die neue (zensierte) Fassung.
    private static var owner: (item: UUID, changeCount: Int)?

    #if KNIPS_DEV
    /// Nur Selbsttests: eine private Zwischenablage (`NSPasteboard(name:)`) statt der echten.
    static var testPasteboard: NSPasteboard?
    #endif

    /// Die echte Zwischenablage — in der Test-Sandbox nie, dort höchstens die private des Selbsttests.
    private static var board: NSPasteboard? {
        #if KNIPS_DEV
        if let testPasteboard { return testPasteboard }
        #endif
        return Paths.testRoot != nil ? nil : .general
    }

    static func copy(image: CGImage, fileURL: URL?) {
        copy(ImagePromise(image), fileURL: fileURL)
    }

    /// Sofort zurück: die Daten werden erst beim Einfügen geliefert. PNG und TIFF gibt es immer
    /// (manche Apps lesen nur diese), bei JPEG-Ausgabe zusätzlich und bevorzugt JPEG.
    /// `item`: Aufnahme, aus der das Bild stammt — damit der Editor es nach dem Zensieren ersetzen kann.
    static func copy(_ promise: ImagePromise, fileURL: URL?, item id: UUID? = nil) {
        guard let pb = board else { return }
        pb.clearContents()
        let item = NSPasteboardItem()
        let provider = LazyImageProvider(promise: promise)
        self.provider = provider
        var types: [NSPasteboard.PasteboardType] = [promise.format.pasteboardType]
        if promise.format != .png { types.append(.png) }
        types.append(.tiff)
        item.setDataProvider(provider, forTypes: types)
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        pb.writeObjects([item])
        owner = id.map { ($0, pb.changeCount) }
    }

    /// Nach dem Speichern im Editor: Liegt noch das Bild dieser Aufnahme in der Zwischenablage (seitdem hat niemand
    /// etwas anderes kopiert), kommt die neue Fassung hinein — sonst fügte ⌘V weiter das unzensierte Original ein.
    @discardableResult
    static func replace(item id: UUID, with promise: ImagePromise, fileURL: URL) -> Bool {
        guard let pb = board, let owner, owner.item == id, owner.changeCount == pb.changeCount else { return false }
        copy(promise, fileURL: fileURL, item: id)
        return true
    }

    /// Fertige Bilddatei: Daten direkt übernehmen, nichts neu kodieren.
    static func copy(imageFile url: URL, item id: UUID? = nil) {
        guard let format = ImageFormat(fileExtension: url.pathExtension),
              let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            copy(fileURL: url)
            return
        }
        copy(ImagePromise(image: image, data: data, format: format, pointScale: ImageIOHelper.pointScale(of: src)), fileURL: url, item: id)
    }

    static func copy(text: String) {
        guard let pb = board else { return }
        pb.clearContents()
        pb.setString(text, forType: .string)
        owner = nil
    }

    static func copy(fileURL: URL) {
        guard let pb = board else { return }
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
        owner = nil
    }

    /// Bild zum Anpinnen: Bilddaten oder eine Bilddatei. Nur Datei-URLs — eine http(s)-Adresse in der
    /// Zwischenablage würde sonst synchron im Hauptthread aus dem Netz geladen.
    /// `scale`: Pixel pro Punkt laut Auflösung in den Bilddaten — Bildschirmfotos von macOS und Retina-Ausgaben
    /// von Knips tragen 144 dpi (2), alles andere gilt als 1 Pixel je Punkt, wie in jedem anderen Programm.
    static func image() -> (image: CGImage, scale: CGFloat)? {
        guard let pb = board else { return nil }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return (img, ImageIOHelper.pointScale(of: src))
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true,
                                                             .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL], let url = urls.first(where: \.isFileURL),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return (img, ImageIOHelper.pointScale(of: src))
        }
        return nil
    }
}

enum Sounds {
    private static let shutter: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if FileManager.default.fileExists(atPath: path) { return NSSound(contentsOfFile: path, byReference: true) }
        return NSSound(named: "Tink")
    }()

    @MainActor static func playShutter() {
        guard AppSettings.shared.playSound else { return }
        shutter?.stop()
        shutter?.play()
    }
}

enum Format {
    static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return f
    }()

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func preciseDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let tenths = Int((seconds * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static var withMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens.first ?? NSScreen()
    }

    /// Höhe des Hauptbildschirms — Bezug für die Umrechnung Quartz (oben links) ↔ Cocoa (unten links).
    static var primaryHeight: CGFloat { screens.first?.frame.height ?? 0 }
}

extension CGRect {
    /// Quartz-Koordinaten (Ursprung oben links am Hauptbildschirm) → Cocoa (unten links).
    var quartzToCocoa: CGRect {
        CGRect(x: minX, y: NSScreen.primaryHeight - maxY, width: width, height: height)
    }

    var cocoaToQuartz: CGRect { quartzToCocoa }

    func normalizedRect() -> CGRect { standardized }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

@MainActor enum Alerts {
    static func error(_ title: String, _ error: Error? = nil, info: String? = nil) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info ?? error?.localizedDescription ?? ""
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// Wechselt in den Dock-Modus, solange ein normales Fenster (Editor, Einstellungen) offen ist,
/// damit es per ⌘-Tab erreichbar bleibt — danach wieder reine Menüleisten-App.
@MainActor enum DockPresence {
    private static var count = 0

    static func windowOpened() {
        count += 1
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed() {
        count = max(0, count - 1)
        if count == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

extension NSApplication {
    /// Stammt das laufende Ereignis von einer gehaltenen Taste (Tastenwiederholung)? Für Knöpfe mit Tastenkürzel,
    /// deren Aktion umschaltet — SwiftUI löst sie bei jeder Wiederholung erneut aus.
    var currentEventIsKeyRepeat: Bool {
        guard let event = currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }
}

/// Wie `MainActor.assumeIsolated`, aber ohne Quelldatei-Namen im fertigen Programm.
func onMainActor<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
    try MainActor.assumeIsolated(body, file: "", line: 0)
}
