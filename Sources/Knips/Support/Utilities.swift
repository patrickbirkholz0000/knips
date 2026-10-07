import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum Paths {
    /// Selbsttests laufen isoliert in `KNIPS_TEST_DIR`, nie in der echten Ablage.
    static var testRoot: URL? {
        ProcessInfo.processInfo.environment["KNIPS_TEST_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
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
    func pngData() -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, self, nil)
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

/// PNG-Kodierung im Hintergrund. Ein 4K-Screenshot braucht ~180 ms — das darf weder das Overlay
/// noch die Karte aufhalten. `data` wartet, falls die Kodierung noch läuft.
final class PNGPromise: @unchecked Sendable {
    private let group = DispatchGroup()
    private var renderedImage: CGImage?
    private var result: Data?
    private static let queue = DispatchQueue(label: "de.birkgroup.knips.png", qos: .userInitiated, attributes: .concurrent)

    convenience init(_ image: CGImage) {
        self.init(render: { image })
    }

    /// Rendert (z. B. Editor-Fassung mit Zensur) und kodiert anschließend — beides im Hintergrund.
    init(render: @escaping @Sendable () -> CGImage?) {
        group.enter()
        Self.queue.async { [self] in
            renderedImage = render()
            result = renderedImage?.pngData()
            group.leave()
        }
    }

    /// Bereits kodierte Daten (z. B. aus einer Datei) — keine erneute Kodierung.
    init(image: CGImage, data: Data) {
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

/// Liefert PNG und TIFF erst, wenn eine App sie wirklich anfragt.
private final class LazyImageProvider: NSObject, NSPasteboardItemDataProvider {
    let png: PNGPromise
    init(png: PNGPromise) { self.png = png }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .png:
            if let data = png.data { item.setData(data, forType: .png) }
        case .tiff:
            if let image = png.image, let data = NSBitmapImageRep(cgImage: image).tiffRepresentation { item.setData(data, forType: .tiff) }
        default:
            break
        }
    }
}

enum Clipboard {
    private static var provider: LazyImageProvider?

    static func copy(image: CGImage, fileURL: URL?) {
        copy(png: PNGPromise(image), fileURL: fileURL)
    }

    /// Sofort zurück: die Daten werden erst beim Einfügen geliefert.
    static func copy(png: PNGPromise, fileURL: URL?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        let provider = LazyImageProvider(png: png)
        self.provider = provider
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        pb.writeObjects([item])
    }

    /// Fertige PNG-Datei: Daten direkt übernehmen, nichts neu kodieren.
    static func copy(pngFile url: URL) {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            copy(fileURL: url)
            return
        }
        copy(png: PNGPromise(image: image, data: data), fileURL: url)
    }

    static func copy(fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
    }

    static func image() -> CGImage? {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first {
            return ImageIOHelper.load(url)
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
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
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

/// Kurze Einblendung („Kopiert“, „Gespeichert“) unten mittig.
@MainActor enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", on screen: NSScreen? = nil) {
        let screen = screen ?? NSScreen.withMouse
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 16)
        let size = stack.fittingSize
        let p = panel ?? makePanel()
        panel = p
        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
        bg.layer?.cornerRadius = size.height / 2
        stack.frame = bg.bounds
        bg.addSubview(stack)
        p.contentView = bg
        let vf = screen.visibleFrame
        p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 64, width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }
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
