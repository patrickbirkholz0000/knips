import AppKit
import SwiftUI

/// Kurze Einblendung („Kopiert“, „Text kopiert · 3 Zeilen“) unten mittig: dunkle Pille, Symbol, ein Satz
/// (docs/design.md, „HUD/Hinweise“). Nimmt keine Mausereignisse an und verschwindet nach 1,4 s.
@MainActor enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", on screen: NSScreen? = nil) {
        // Selbsttests zeigen nie etwas auf dem Bildschirm (Bilder der Pille macht `--selftest chrome` offscreen).
        if CommandLine.arguments.dropFirst().first == "--selftest" { return }
        let screen = screen ?? NSScreen.withMouse
        let host = NSHostingView(rootView: HUDView(text: text, symbol: symbol))
        host.appearance = Brand.Dark.appearance
        let size = host.fittingSize
        let p = panel ?? FloatingPanel.make(.zero, ignoresMouse: true)
        panel = p
        p.contentView = host
        let vf = screen.visibleFrame
        let m = HUDView.margin
        p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 64 - m, width: size.width, height: size.height), display: true)
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
}

/// Inhalt des Hinweises. Symbolfarbe nach Art: Häkchen grün („erledigt“), Warnung gelb, Papierkorb leise,
/// sonst Königsblau hell.
struct HUDView: View {
    let text: String
    let symbol: String

    /// Platz rundherum für den Schatten.
    static let margin: CGFloat = 14

    static func tint(for symbol: String) -> NSColor {
        if symbol.hasPrefix("checkmark") { return Brand.Dark.success }
        if symbol.contains("exclamationmark") { return Brand.Dark.warn }
        if symbol.hasPrefix("trash") { return Brand.Dark.muted }
        return Brand.Dark.accent
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.brand(Self.tint(for: symbol)))
            Text(text)
                .font(Brand.font(13.5, .medium))
                .foregroundStyle(Color.brand(Brand.Dark.ink))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 17)
        .frame(height: 38)
        .darkSurface(Capsule())
        .padding(Self.margin)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}
