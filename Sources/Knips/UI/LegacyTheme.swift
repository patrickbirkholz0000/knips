import SwiftUI

// Alte Farben und Knöpfe von vor der Markensprache (docs/design.md). Unverändert aus SettingsWindow.swift
// hierher verschoben, damit Ansichten, die noch nicht auf `Brand` umgestellt sind, weiter bauen.
// Neue Oberflächen nehmen `Brand` und die Bausteine aus `UI/Controls.swift`.

/// Farben und Formen der Einstellungen: helle Fläche, dunkle Seitenleiste, weiße Karten, schwarze Knöpfe.
enum Theme {
    static let page = Color(red: 0.955, green: 0.955, blue: 0.962)
    static let sidebar = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let sidebarSelected = Color(white: 0.2)
    static let card = Color.white
    static let border = Color.black.opacity(0.07)
    static let ink = Color(white: 0.09)
    static let muted = Color(white: 0.45)
    static let soft = Color(white: 0.93)
}

/// Schwarze Schaltfläche als Hauptaktion, hellgrau als Nebenaktion.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(primary ? Theme.ink : (destructive ? Color.red.opacity(0.1) : Theme.soft)))
            .foregroundStyle(primary ? .white : (destructive ? .red : Theme.ink))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}
