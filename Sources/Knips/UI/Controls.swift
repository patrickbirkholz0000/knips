import AppKit
import Carbon
import SwiftUI

// Bedienelemente in der Markensprache (docs/design.md, „Fenster und Flächen“). Farben, Schrift und Radien kommen
// nur aus `Brand`. Alle Bausteine heißen `Brand…`, damit sie neben älteren Ansichten nicht kollidieren.
// Für helle Fenster (Einstellungen, Verlauf, Dialoge); sie folgen Hell/Dunkel über die dynamischen Brand-Farben.

// MARK: - Schrift

/// Kleine Überschrift in Versalien (JetBrains Mono 11, gesperrt), z. B. `AUFNAHME`, `STATISTIK`.
struct BrandOverline: View {
    let text: String
    var color: NSColor = Brand.inkSoft

    init(_ text: String, color: NSColor = Brand.inkSoft) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(11, .medium))
            .tracking(Brand.overlineTracking)
            .foregroundStyle(Color.brand(color))
            .lineLimit(1)
    }
}

// MARK: - Schalter

/// Schalter 38 × 22: Königsblau an, `lineStrong` aus, heller Knopf.
struct BrandToggle: View {
    @Binding var isOn: Bool
    var label = ""
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(Color.brand(isOn ? Brand.accent : Brand.lineStrong))
                Circle()
                    .fill(Color.brand(Brand.Dark.button))
                    .shadow(color: .brand(Brand.Dark.fill).opacity(0.18), radius: 1.5, y: 1)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .frame(width: 38, height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "an" : "aus")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Segment-Schalter

/// Segment-Schalter: `fill`-Spur mit Linie, gewähltes Segment als heller Daumen (`segmentThumb`).
struct BrandSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(Brand.font(12.5, on ? .semibold : .medium))
                        .foregroundStyle(Color.brand(on ? Brand.ink : Brand.inkSoft))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.brand(Brand.segmentThumb))
                                    .shadow(color: .brand(Brand.Dark.fill).opacity(0.1), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2.5)
        .background(RoundedRectangle(cornerRadius: 9.5, style: .continuous).fill(Color.brand(Brand.fill)))
        .overlay(RoundedRectangle(cornerRadius: 9.5, style: .continuous).strokeBorder(Color.brand(Brand.line)))
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

// MARK: - Auswahlfeld

/// Auswahlfeld 36 hoch mit Linie; ein Klick öffnet das Menü direkt unter dem Feld (Häkchen am gewählten Eintrag).
struct BrandSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var minWidth: CGFloat = 0
    @State private var anchor = BrandPopUpAnchor.Box()
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var title: String { options.first { $0.0 == selection }?.1 ?? "—" }

    var body: some View {
        Button(action: popUp) {
            HStack(spacing: 10) {
                Text(title)
                    .font(Brand.font(13.5, .medium))
                    .foregroundStyle(Color.brand(Brand.ink))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
            }
            .padding(.horizontal, 12)
            .frame(minWidth: minWidth, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                .fill(Color.brand(hovering ? Brand.surface : Brand.surfaceRaised)))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                .strokeBorder(Color.brand(hovering ? Brand.lineStrong : Brand.line)))
            .background(BrandPopUpAnchor(box: anchor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }

    private func popUp() {
        guard let view = anchor.view else { return }
        let target = BrandPopUpTarget()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = Brand.nsFont(13.5)
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.1, action: #selector(BrandPopUpTarget.choose(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            item.state = option.0 == selection ? .on : .off
            menu.addItem(item)
        }
        let binding = $selection
        let values = options.map(\.0)
        target.chosen = { index in binding.wrappedValue = values[index] }
        menu.minimumWidth = view.bounds.width
        // Unter dem Feld (die Ansicht ist nicht gespiegelt: y = 0 ist die Unterkante).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        withExtendedLifetime(target) {}
    }
}

/// Ziel der Menüeinträge von `BrandSelect`.
@MainActor final class BrandPopUpTarget: NSObject {
    var chosen: ((Int) -> Void)?
    @objc func choose(_ item: NSMenuItem) { chosen?(item.tag) }
}

/// Unsichtbare AppKit-Ansicht hinter einem SwiftUI-Element — Bezugspunkt für Menüs.
struct BrandPopUpAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

// MARK: - Knöpfe

/// Knöpfe: Primär Tinte (dunkel: Papier), Sekundär weiß mit Linie, Leise nur Text. Löschen ist nie rot.
struct BrandButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct BrandButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: BrandButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(Brand.font(compact ? 12.5 : 13, .medium))
            .lineLimit(1)
            .foregroundStyle(Color.brand(foreground))
            .padding(.horizontal, kind == .quiet ? (compact ? 8 : 10) : (compact ? 12 : 14))
            .frame(height: compact ? 28 : 34)
            .background(RoundedRectangle(cornerRadius: Brand.Radius.button, style: .continuous).fill(Color.brand(background)))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Brand.Radius.button, style: .continuous)
                        .strokeBorder(hovering ? Color.brand(Brand.inkSoft).opacity(0.5) : Color.brand(Brand.lineStrong))
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: NSColor {
        switch kind {
        case .primary: Brand.buttonInk
        case .secondary: Brand.ink
        case .quiet: hovering ? Brand.ink : Brand.inkSoft
        }
    }

    private var background: NSColor {
        switch kind {
        case .primary: hovering ? Brand.inkMuted : Brand.buttonFill
        case .secondary: hovering ? Brand.surfaceRaised : Brand.surface
        case .quiet: hovering ? Brand.fill : .clear
        }
    }
}

/// Textverweis in Königsblau mit kleinem Pfeil (öffnet eine Webseite).
struct BrandLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold))
            }
            .font(Brand.font(12.5, .medium))
            .foregroundStyle(Color.brand(Brand.accent))
        }
        .help(url.absoluteString)
    }
}

// MARK: - Tastenkappen

extension KeyCombo {
    /// Einzelne Tasten für Tastenkappen: Sondertasten in macOS-Reihenfolge, dann die Taste.
    var keycapLabels: [String] {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        return parts + [KeyCombo.keyName(keyCode)]
    }
}

extension KeyCombo {
    /// Sondertasten als SF Symbols — JetBrains Mono und Outfit haben ⌘ ⇧ ⌥ ⌃ nicht in passender Größe.
    static let modifierSymbols: [String: String] = ["⌘": "command", "⇧": "shift", "⌥": "option", "⌃": "control"]

    /// Kürzel im Fließtext: Sondertasten als Symbol, die Taste in Mono.
    func inlineText(size: CGFloat = 12.5) -> Text {
        keycapLabels.reduce(Text("")) { text, key in
            if let symbol = KeyCombo.modifierSymbols[key] {
                return text + Text(Image(systemName: symbol)).font(.system(size: size * 0.92, weight: .semibold))
            }
            return text + Text(key).font(Brand.mono(size, .medium))
        }
    }
}

/// Eine Tastenkappe: helle Kappe mit Linie und etwas dickerer Unterkante, Beschriftung in Mono
/// (Sondertasten als Symbol).
struct BrandKeycap: View {
    let label: String
    var large = false

    var body: some View {
        Group {
            if let symbol = KeyCombo.modifierSymbols[label] {
                Image(systemName: symbol).font(.system(size: large ? 13.5 : 11, weight: .semibold))
            } else {
                Text(label).font(Brand.mono(large ? 15 : 12, .medium))
            }
        }
            .foregroundStyle(Color.brand(Brand.ink))
            .lineLimit(1)
            .padding(.horizontal, large ? 8 : 5)
            .frame(minWidth: large ? 34 : 24, minHeight: large ? 34 : 24)
            .background(RoundedRectangle(cornerRadius: large ? 9 : 6, style: .continuous).fill(Color.brand(Brand.surface)))
            .overlay(RoundedRectangle(cornerRadius: large ? 9 : 6, style: .continuous).strokeBorder(Color.brand(Brand.lineStrong)))
            .background(RoundedRectangle(cornerRadius: large ? 9 : 6, style: .continuous)
                .fill(Color.brand(Brand.lineStrong)).offset(y: 1.5))
    }
}

/// Ein Kürzel als Reihe von Tastenkappen; ohne Kürzel ein leiser Strich.
struct BrandKeys: View {
    let combo: KeyCombo?
    var large = false

    var body: some View {
        if let combo {
            HStack(spacing: large ? 5 : 3) {
                ForEach(Array(combo.keycapLabels.enumerated()), id: \.offset) { _, key in BrandKeycap(label: key, large: large) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(combo.display)
        } else {
            Text("—").font(Brand.mono(large ? 15 : 12.5)).foregroundStyle(Color.brand(Brand.inkSoft))
        }
    }
}

// MARK: - Karten und Zeilen

/// Weiße Karte (dunkel: surface) mit feiner Linie und kaum Schatten; Zeilen darin mit 20 pt Rand.
struct BrandCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous).fill(Color.brand(Brand.surface)))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous).strokeBorder(Color.brand(Brand.line)))
            .shadow(color: .brand(Brand.Dark.fill).opacity(0.04), radius: 1, y: 1)
    }
}

/// Abschnitt: Titel (17 halbfett), optional ein Satz darunter, Karte, optional Fußnote.
struct BrandSection<Content: View>: View {
    var title: String?
    var detail: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(Brand.font(17, .semibold))
                    .foregroundStyle(Color.brand(Brand.ink))
                    .padding(.bottom, detail == nil ? 10 : 3)
            }
            if let detail {
                Text(detail)
                    .font(Brand.font(13))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            BrandCard { content }
            if let footer {
                Text(footer)
                    .font(Brand.font(12.5))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Zeile in einer Karte: Titel (14 mittel) und Beschreibung links, Bedienelement rechts.
struct BrandRow<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Brand.font(14, .medium))
                    .foregroundStyle(Color.brand(Brand.ink))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(Brand.font(12.5))
                        .foregroundStyle(Color.brand(Brand.inkSoft))
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.vertical, 14)
        .frame(minHeight: 58)
    }
}

/// Trennlinie zwischen Zeilen (die Karte rückt sie ein).
struct BrandRowDivider: View {
    var body: some View { Rectangle().fill(Color.brand(Brand.line)).frame(height: 1) }
}

// MARK: - Zustand

/// Zustand im Bereit-Check: erledigt (grünes Häkchen), fehlt (roter Punkt), freiwillig (gestrichelter Kreis).
enum BrandCheckTone { case done, missing, optional }

struct BrandStatusIcon: View {
    let tone: BrandCheckTone

    var body: some View {
        switch tone {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.brand(Brand.success))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.brand(Brand.successSoft)))
                .accessibilityLabel("Erledigt")
        case .missing:
            Circle().fill(Color.brand(Brand.record)).frame(width: 8, height: 8)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.brand(Brand.recordSoft)))
                .accessibilityLabel("Fehlt")
        case .optional:
            Circle().strokeBorder(Color.brand(Brand.lineStrong), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                .frame(width: 24, height: 24)
                .accessibilityLabel("Freiwillig")
        }
    }
}

/// Kleiner Punkt mit Text (Seitenleiste, Kopfzeilen): grün bereit, rot offen.
struct BrandStatusDot: View {
    let ok: Bool
    let text: String
    var ink: NSColor = Brand.ink
    var green: NSColor = Brand.success
    var red: NSColor = Brand.record

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.brand(ok ? green : red)).frame(width: 7, height: 7)
            Text(text).font(Brand.font(12.5, .medium)).foregroundStyle(Color.brand(ink)).lineLimit(1)
        }
    }
}

/// Icon-Kachel: `accentSoft`-Fläche, Königsblau-Icon (Dialoge, Infozeilen).
struct BrandIconTile: View {
    let symbol: String
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(Color.brand(Brand.accent))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.brand(Brand.accentSoft)))
            .accessibilityHidden(true)
    }
}

// MARK: - Dialoge

/// Fenster für Dialoge im Stil der Onboarding-Karte: randlos, die Karte selbst (Radius 22) ist das
/// Fenster. Kann Schlüsselfenster werden; Esc und ⌘W schließen es wie ein normales Fenster.
final class BrandDialogWindow: NSWindow {
    static func make(width: CGFloat, title: String) -> BrandDialogWindow {
        let window = BrandDialogWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.borderless],
                                       backing: .buffered, defer: false)
        window.title = title
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        return window
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Randlose Fenster haben keinen Schließen-Knopf — ⌘W schließt trotzdem (über den Delegate, wie sonst auch).
    override func performClose(_ sender: Any?) {
        if let delegate, delegate.windowShouldClose?(self) == false { return }
        close()
    }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    /// Inhalt setzen und die Fensterhöhe an den Inhalt anpassen (Breite bleibt).
    func setDialogContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        let width = frame.width
        host.frame = NSRect(x: 0, y: 0, width: width, height: frame.height)
        let fitting = host.fittingSize
        contentView = host
        setContentSize(NSSize(width: width, height: max(120, fitting.height)))
        invalidateShadow()
    }
}

/// Inhalt eines Dialogs: Mono-Überschrift, Titel 22 halbfett, Text, eigener Inhalt, Knöpfe rechts.
struct BrandDialog<Content: View, Buttons: View>: View {
    let overline: String
    let title: String
    var message: String?
    var width: CGFloat = 520
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandMark(size: 18, ink: .brand(Brand.ink), accent: .brand(Brand.accent))
                BrandOverline(overline)
            }
            Text(title)
                .font(Brand.font(22, .semibold))
                .foregroundStyle(Color.brand(Brand.ink))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            if let message {
                Text(message)
                    .font(Brand.font(14))
                    .foregroundStyle(Color.brand(Brand.inkMuted))
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            content
                .padding(.top, 18)
            HStack(spacing: 10) { buttons }
                .padding(.top, 24)
        }
        .padding(.horizontal, 36)
        .padding(.top, 30)
        .padding(.bottom, 28)
        .frame(width: width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: Brand.Radius.dialog, style: .continuous).fill(Color.brand(Brand.surface)))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.dialog, style: .continuous).strokeBorder(Color.brand(Brand.line)))
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.dialog, style: .continuous))
    }
}

/// Punkt in einem Dialog: Icon-Kachel, Titel, ein Satz.
struct BrandDialogPoint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BrandIconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.font(14, .semibold)).foregroundStyle(Color.brand(Brand.ink))
                Text(text)
                    .font(Brand.font(12.5))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)
        }
    }
}
