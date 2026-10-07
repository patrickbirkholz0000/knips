import AppKit
import ScreenCaptureKit

/// Eingefrorener Bildschirm: Standbild eines Displays, auf dem dann ausgewählt wird.
struct FrozenScreen {
    let screen: NSScreen
    /// Fehlt nur in Selbsttests mit synthetischem Standbild.
    let display: SCDisplay?
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

struct WindowInfo: Equatable {
    let windowID: CGWindowID
    /// Cocoa-Koordinaten (global, Ursprung unten links).
    let frame: CGRect
    let owner: String
    let title: String
}

enum CaptureError: LocalizedError {
    case noPermission
    case noDisplay
    case windowGone

    var errorDescription: String? {
        switch self {
        case .noPermission: "Knips hat keine Berechtigung für Bildschirmaufnahmen."
        case .noDisplay: "Kein Bildschirm gefunden."
        case .windowGone: "Das Fenster ist nicht mehr da."
        }
    }
}

enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !hasPermission { throw CaptureError.noPermission }
            throw error
        }
    }

    static func ownApp(in content: SCShareableContent) -> SCRunningApplication? {
        content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
    }

    /// Eigene Fenster (Quick-Access-Karten, Pins, HUD) gehören nie ins Bild.
    static func filter(for display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        SCContentFilter(display: display, excludingApplications: ownApp(in: content).map { [$0] } ?? [], exceptingWindows: [])
    }

    static func freeze(_ screens: [NSScreen], content: SCShareableContent) async throws -> [FrozenScreen] {
        var result: [FrozenScreen] = []
        try await withThrowingTaskGroup(of: FrozenScreen?.self) { group in
            for screen in screens {
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
                let filter = filter(for: display, in: content)
                let scale = screen.backingScaleFactor
                group.addTask {
                    let config = SCStreamConfiguration()
                    config.width = Int((CGFloat(display.width) * scale).rounded())
                    config.height = Int((CGFloat(display.height) * scale).rounded())
                    config.showsCursor = false
                    config.captureResolution = .best
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return FrozenScreen(screen: screen, display: display, image: image)
                }
            }
            for try await frozen in group { if let frozen { result.append(frozen) } }
        }
        guard !result.isEmpty else { throw CaptureError.noDisplay }
        return screens.compactMap { s in result.first { $0.screen == s } }
    }

    /// Fenster von vorn nach hinten (CGWindowList liefert die Z-Reihenfolge, SCShareableContent nicht).
    static func windows(excludingPID pid: pid_t = ProcessInfo.processInfo.processIdentifier) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != pid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            return WindowInfo(windowID: id, frame: bounds.quartzToCocoa,
                              owner: info[kCGWindowOwnerName as String] as? String ?? "",
                              title: info[kCGWindowName as String] as? String ?? "")
        }
    }

    /// Einzelnes Fenster freigestellt (auch verdeckte Teile), mit transparenten Ecken.
    static func captureWindow(_ window: WindowInfo, content: SCShareableContent, scale: CGFloat) async throws -> CGImage {
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else { throw CaptureError.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int((scWindow.frame.width * scale).rounded())
        config.height = Int((scWindow.frame.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func crop(_ frozen: FrozenScreen, localRect r: CGRect) -> CGImage? {
        // localRect: Punkte im Bildschirm, Ursprung unten links → Pixel im Standbild (oben links).
        let s = frozen.scale
        let px = CGRect(x: r.minX * s, y: (frozen.screen.frame.height - r.maxY) * s, width: r.width * s, height: r.height * s).integral
        return frozen.image.cropping(to: px)
    }
}
