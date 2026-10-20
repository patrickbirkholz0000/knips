import AppKit
import SwiftUI

/// Bausteine der Editor-Oberfläche (Bild- und Video-Editor) in der Markensprache aus `docs/design.md`:
/// Papier als Fensterfläche, weiße Leisten mit feiner Linie, Werkzeug-Knöpfe 32 × 32, aktives Werkzeug in
/// Königsblau, Primärknopf Tinte, Hinweise als dunkle Pille. Farben und Schriften nur über `Brand`.
enum EditorChrome {
    /// Obere Leiste mit den Ampel-Knöpfen.
    static let topBarHeight: CGFloat = 52
    /// Zweite Leiste mit den Eigenschaften des Werkzeugs.
    static let propertiesHeight: CGFloat = 46
    /// Untere Leiste mit Zoom und Maßen.
    static let statusHeight: CGFloat = 40
    /// Abstand der Bühne und der Leisten zum Fensterrand.
    static let margin: CGFloat = 16
    /// Platz für die Ampel-Knöpfe (Schließen, Minimieren, Zoomen) links oben.
    static let trafficLights: CGFloat = 62
    static let toolSize: CGFloat = 32
    /// Weiße Leiste um eine Gruppe von Knöpfen.
    static let groupRadius: CGFloat = 12
    static let groupPadding: CGFloat = 4
    /// Kleinste Fensterbreite beider Editoren — passt in 1024-pt-Bildschirme.
    static let minWidth: CGFloat = 860
}

extension NSColor {
    /// Token in einer festen Darstellung, z. B. Grün auf einer immer dunklen Pille.
    func resolved(dark: Bool) -> NSColor {
        var color = self
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = self.usingColorSpace(.sRGB) ?? self
        }
        return color
    }
}

extension NSWindow {
    /// Editor-Fenster: Inhalt bis oben unter der durchsichtigen Titelleiste, Fensterfläche Papier. Eine leere
    /// Werkzeugleiste im Stil „unified“ macht die Titelleiste so hoch wie die obere Leiste (52 pt) — damit sitzen
    /// die Ampel-Knöpfe mittig daneben statt oben in der Ecke. Klicks gehen weiter an die SwiftUI-Fläche.
    func applyEditorChrome() {
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "de.birkgroup.knips.editor")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar
        toolbarStyle = .unified
        // Folgt der App-Darstellung (Einstellung „Darstellung“ bzw. System) — kein festes Dunkel mehr.
        backgroundColor = Brand.canvas
    }
}

extension NSView {
    /// Farben einer Bühne (Fläche `fill`, Linie, Ecken wie Karten) — bei jedem Wechsel Hell/Dunkel neu setzen.
    func applyStageLayerStyle() {
        guard let layer else { return }
        layer.cornerRadius = Brand.Radius.card
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Brand.line.cgColor
        }
    }
}

// MARK: - Gruppe

private struct ChromeGroup: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: EditorChrome.groupRadius, style: .continuous).fill(Color.brand(Brand.surface)))
            .overlay(RoundedRectangle(cornerRadius: EditorChrome.groupRadius, style: .continuous).strokeBorder(Color.brand(Brand.line)))
    }
}

extension View {
    /// Weiße Leiste (dunkel: `surface`) mit Radius 12 und feiner Linie.
    func chromeGroup(padding: CGFloat = EditorChrome.groupPadding) -> some View {
        modifier(ChromeGroup(padding: padding))
    }
}

/// Senkrechte Trennlinie in einer Gruppe.
struct ChromeDivider: View {
    var height: CGFloat = 20

    var body: some View {
        Rectangle().fill(Color.brand(Brand.line)).frame(width: 1, height: height).padding(.horizontal, 4)
    }
}

/// Kleine Überschrift in Versalien (Mono, gesperrt), z. B. `FARBE`.
struct ChromeOverline: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(10.5, .medium))
            .tracking(Brand.overlineTracking)
            .foregroundStyle(Color.brand(Brand.inkSoft))
            .fixedSize()
    }
}

// MARK: - Knöpfe

/// Werkzeug- und Symbolknopf: 32 × 32 (mit Beschriftung breiter), aktiv Königsblau auf `accentSoft`.
struct ChromeToolButton: View {
    let symbol: String
    var title: String?
    var active = false
    var enabled = true
    var size: CGFloat = EditorChrome.toolSize
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: size >= 32 ? 14 : 12, weight: .medium))
                    .frame(width: size >= 32 ? 18 : 14)
                if let title {
                    Text(title).font(Brand.font(13, .medium)).fixedSize()
                }
            }
            .padding(.horizontal, title == nil ? 0 : 10)
            .frame(minWidth: size, minHeight: size, maxHeight: size)
            .foregroundStyle(Color.brand(active ? Brand.accent : Brand.inkMuted))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Color.brand(Brand.accentSoft) : hover && enabled ? Color.brand(Brand.fill) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(title ?? help)
    }
}

/// Knöpfe der Editoren mit Text und Symbol: Primär (Tinte), Sekundär (weiß mit Linie), Leise (nur Text).
struct ChromeButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(label: configuration.label, pressed: configuration.isPressed, kind: kind, height: height)
    }
}

private struct BrandButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let kind: ChromeButtonStyle.Kind
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.button, style: .continuous)
        label
            .labelStyle(ChromeLabelStyle())
            .font(Brand.font(height < 30 ? 12.5 : 13, .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, height < 30 ? 10 : 12)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .foregroundStyle(foreground)
            .background(shape.fill(background))
            .overlay { if kind == .secondary { shape.strokeBorder(Color.brand(Brand.lineStrong)) } }
            .opacity(isEnabled ? (pressed ? 0.82 : 1) : 0.4)
            .contentShape(shape)
            .onHover { hover = $0 }
    }

    private var active: Bool { hover && isEnabled }

    private var foreground: Color {
        switch kind {
        case .primary: .brand(Brand.buttonInk)
        case .secondary: .brand(Brand.ink)
        case .quiet: .brand(active ? Brand.ink : Brand.inkMuted)
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .brand(active ? Brand.inkMuted : Brand.buttonFill)
        case .secondary: .brand(active ? Brand.surfaceRaised : Brand.surface)
        case .quiet: active ? .brand(Brand.fill) : .clear
        }
    }
}

/// Symbol + Text mit festem Abstand; das Symbol etwas kleiner als die Schrift.
struct ChromeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12.5, weight: .medium))
            configuration.title
        }
    }
}

// MARK: - Segment-Schalter

/// Segment-Schalter wie in der App-Familie: `fill`-Spur mit Linie, gewählter Teil als heller Daumen.
struct BrandSegment<Value: Hashable>: View {
    struct Item {
        let value: Value
        var title: String?
        var symbol: String?
        var help: String?
        var mono = false
    }

    let items: [Item]
    let selection: Value?
    var height: CGFloat = 26
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                SegmentButton(item: item, on: item.value == selection, height: height) { onSelect(item.value) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.brand(Brand.fill)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.brand(Brand.line)))
    }

    private struct SegmentButton: View {
        let item: Item
        let on: Bool
        let height: CGFloat
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let symbol = item.symbol {
                        Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    }
                    if let title = item.title {
                        Text(title)
                            .font(item.mono ? Brand.mono(11.5, .medium) : Brand.font(12.5, .medium))
                            .fixedSize()
                    }
                }
                .padding(.horizontal, item.title == nil ? 0 : 10)
                .frame(minWidth: height + 2, minHeight: height, maxHeight: height)
                .foregroundStyle(Color.brand(on || hover ? Brand.ink : Brand.inkSoft))
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.brand(Brand.segmentThumb))
                            .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(item.help ?? item.title ?? "")
            .accessibilityLabel(item.title ?? item.help ?? "")
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

// MARK: - Tastenkappe

/// Tastenkappe für Kürzel in Hinweisen (weiße Kappe, Linie, Mono). `symbol` statt Text für Tasten wie ⏎,
/// deren Zeichen in der Mono-Schrift zu klein gerät.
struct ChromeKeyCap: View {
    var key: String = ""
    var symbol: String?

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            } else {
                Text(key).font(Brand.mono(11, .medium))
            }
        }
            .foregroundStyle(Color.brand(Brand.ink))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.brand(Brand.surface)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.brand(Brand.lineStrong)))
            .fixedSize()
    }
}

// MARK: - Schalter

/// Schalter wie in der App-Familie (38 × 22): an Königsblau, aus `lineStrong`, Knopf Papier. Gleich in aktiven und
/// inaktiven Fenstern — der System-Schalter wird in Popovers sonst grau.
struct BrandSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(Color.brand(on ? Brand.accent : Brand.lineStrong))
                .frame(width: 38, height: 22)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(Color.brand(Brand.Dark.button))
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: on)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

// MARK: - Hinweis-Pille

/// Hinweis über der Bühne: immer dunkle Pille mit Symbol und einem Satz (`docs/design.md`, HUD).
struct EditorHUD: View {
    let text: String
    var symbol: String?
    var spinning = false
    /// Fortschritt 0…1 als schmaler Balken (Video-Export).
    var progress: Double?

    var body: some View {
        HStack(spacing: 9) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.brand(Brand.Dark.accent))
                    .frame(width: 110)
            } else if spinning {
                ProgressView().controlSize(.small)
            }
            if let symbol {
                Image(systemName: symbol).foregroundStyle(Color.brand(Brand.success.resolved(dark: true)))
            }
            Text(text).font(Brand.font(13, .medium)).fixedSize()
        }
        .padding(.horizontal, 15)
        .frame(height: 36)
        .foregroundStyle(Color.brand(Brand.Dark.ink))
        .background(Capsule().fill(Color.brand(Brand.Dark.fill)))
        .overlay(Capsule().strokeBorder(Color.brand(Brand.Dark.line)))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        .environment(\.colorScheme, .dark)
    }
}
