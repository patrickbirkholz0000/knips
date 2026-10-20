// Erzeugt das App-Icon von Knips im Zeichen der App-Familie (docs/design.md, „Logo und Wortmarke“):
// vier Auswahl-Ecken in Papier und ein Zensurbalken in Königsblau auf Tinte — gleiche Machart wie die App-Familie.
//
//   Resources/AppIcon.icns              macOS, alle Größen (16…1024), macOS-Squircle mit Apple-Rand (824/1024)
//   design/app-icon-1024.png            macOS-Icon als Vorlage (README, Website)
//   design/app-icon.svg                 dasselbe als Vektor
//   windows/design/app-icon-1024.png    Windows-Fassung: abgerundetes Quadrat fast randlos
//   windows/public/icon.png             = Windows-Fassung (Oberfläche)
//   windows/src-tauri/icons/*           Icon-Satz wie `tauri icon` (PNG-Größen, icon.ico mit 16…256, icon.icns)
//
// Klein (16–48 px) wird das Zeichen nicht nur verkleinert: Strich etwas kräftiger, Linien aufs Pixelraster gelegt.
// Aufruf: swift scripts/make-icon.swift
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default

// MARK: - Farben (docs/design.md)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255,
                                           CGFloat(v & 0xFF) / 255, a])!
}
let inkTop: UInt32 = 0x24262E, inkBottom: UInt32 = 0x111216
let paper: UInt32 = 0xF4F5F7, blue: UInt32 = 0x7B88FF

// MARK: - Fläche

enum Platform { case mac, windows }

/// Kachel im Bild (Pixel, y nach unten) und ihr Umriss.
func tile(_ px: Int, _ platform: Platform) -> (rect: CGRect, path: CGPath) {
    let s = CGFloat(px)
    switch platform {
    case .mac:
        // Apple-Raster: 824 von 1024, Ecken als durchgehende Kurve (Squircle). Rand aufs Pixel gerundet.
        let inset = (s * 100 / 1024).rounded()
        let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = RoundedRectangle(cornerRadius: rect.width * 185.4 / 824, style: .continuous).path(in: rect).cgPath
        return (rect, path)
    case .windows:
        // Windows: abgerundetes Quadrat, fast randlos (Taskleiste, Explorer).
        let inset = (s * 32 / 1024).rounded()
        let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        return (rect, CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2, cornerHeight: rect.width * 0.2, transform: nil))
    }
}

// MARK: - Zeichen

/// Geometrie in Einheiten 0…100 (wie `BrandGeometry` in Sources/Knips/UI/BrandMark.swift).
struct Mark {
    var lo: CGFloat = 22, hi: CGFloat = 78, arm: CGFloat = 17, stroke: CGFloat = 9
    var barX: ClosedRange<CGFloat> = 33...67

    static let standard = Mark()
    /// Anteil der Kachel, auf den die Einheiten 0…100 fallen: groß 0,9 (Strich und Ausdehnung wie das d im
    /// Icon), klein die ganze Kachel, damit der Strich kräftig genug bleibt.
    static func scale(tile: CGFloat) -> CGFloat { tile >= 64 ? 0.9 : 1 }
}

/// Zeichnet das Zeichen in die Kachel `tile`: ab 20 px als Vektor mit runden Enden (Linien klein aufs
/// Pixelraster gelegt), darunter aus ganzen Pixeln.
func drawMark(_ ctx: CGContext, tile: CGRect, ink: CGColor, accent: CGColor) {
    guard tile.width >= 20 else { return drawPixelMark(ctx, tile: tile, ink: ink, accent: accent) }
    let k = Mark.scale(tile: tile.width)
    let rect = tile.insetBy(dx: tile.width * (1 - k) / 2, dy: tile.height * (1 - k) / 2)
    drawMark(ctx, in: rect, mark: .standard, ink: ink, accent: accent, snap: tile.width < 80)
}

/// Kachel unter 20 px (16er-Icons): Ecken als 1–2 px breite Winkel, Balken 2 px hoch, alles auf ganzen Pixeln.
/// Runde Enden und die genauen Maße verschwimmen hier nur zu einem Fleck.
func drawPixelMark(_ ctx: CGContext, tile: CGRect, ink: CGColor, accent: CGColor) {
    let t = Int(tile.width.rounded())
    let w = t >= 14 ? 2 : 1
    let margin = Int((CGFloat(t) * 0.16).rounded())
    let box = t - 2 * margin
    let arm = Int((CGFloat(box) * 0.38).rounded())
    let x0 = Int(tile.minX) + margin, y0 = Int(tile.minY) + margin
    func fill(_ x: Int, _ y: Int, _ wd: Int, _ ht: Int) {
        ctx.fill(CGRect(x: x0 + x, y: y0 + y, width: wd, height: ht))
    }
    ctx.setFillColor(ink)
    for (x, y, dx, dy) in [(0, 0, 1, 1), (box, 0, -1, 1), (box, box, -1, -1), (0, box, 1, -1)] {
        let hx = dx > 0 ? x : x - arm, vy = dy > 0 ? y : y - arm
        fill(hx, dy > 0 ? y : y - w, arm, w)                 // waagerechter Schenkel
        fill(dx > 0 ? x : x - w, vy, w, arm)                 // senkrechter Schenkel
    }
    ctx.setFillColor(accent)
    let barW = box - 2 * w - 2, barH = 2
    fill((box - barW) / 2, (box - barH) / 2, barW, barH)
}

func drawMark(_ ctx: CGContext, in rect: CGRect, mark m: Mark, ink: CGColor, accent: CGColor, snap: Bool) {
    let u = rect.width / 100
    var w = m.stroke * u
    func at(_ v: CGFloat) -> CGFloat { v * u }
    // Pixelraster: Strichstärke ganzzahlig, Mittellinien so, dass die Kanten auf Pixelgrenzen liegen.
    func snapLine(_ p: CGFloat) -> CGFloat {
        guard snap else { return p }
        let half = w / 2
        return (p - half).rounded() + half
    }
    if snap { w = max(1, w.rounded()) }
    let lo = CGPoint(x: snapLine(rect.minX + at(m.lo)), y: snapLine(rect.minY + at(m.lo)))
    let hi = CGPoint(x: snapLine(rect.minX + at(m.hi)), y: snapLine(rect.minY + at(m.hi)))
    // Klein enden auch die runden Enden der Schenkel auf einer Pixelgrenze.
    let arm = snap ? (at(m.arm) + w).rounded() - w : at(m.arm)
    let path = CGMutablePath()
    for (cx, cy, dx, dy) in [(lo.x, lo.y, 1.0, 1.0), (hi.x, lo.y, -1.0, 1.0), (hi.x, hi.y, -1.0, -1.0), (lo.x, hi.y, 1.0, -1.0)] {
        path.move(to: CGPoint(x: cx, y: cy + dy * arm))
        path.addLine(to: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
    }
    ctx.addPath(path)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(w)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    let midY = snapLine((lo.y + hi.y) / 2)
    var x0 = rect.minX + at(m.barX.lowerBound), x1 = rect.minX + at(m.barX.upperBound)
    if snap { (x0, x1) = (x0.rounded(), x1.rounded()) }
    let bar = CGRect(x: x0, y: midY - w / 2, width: x1 - x0, height: w)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
    ctx.setFillColor(accent)
    ctx.fillPath()
}

// MARK: - Icon

func render(_ px: Int, _ platform: Platform) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1) // y nach unten wie im SVG
    let (rect, path) = tile(px, platform)

    // Fläche: Tinte, oben einen Hauch heller (wie in der App-Familie)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let ink = CGGradient(colorsSpace: srgb, colors: [hex(inkTop), hex(inkBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ink, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])

    // Feine Innenkante: oben heller, unten fast weg (wie die Kante, 6 % Weiß)
    let edge = max(1, s * 2 / 1024)
    ctx.addPath(path)
    ctx.setLineWidth(edge * 2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = CGGradient(colorsSpace: srgb, colors: [hex(0xFFFFFF, 0.10), hex(0xFFFFFF, 0.03)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    ctx.restoreGState()

    drawMark(ctx, tile: rect, ink: hex(paper), accent: hex(blue))
    return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func write(_ data: Data, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

/// .ico mit PNG-Einträgen (Windows Vista und neuer).
func ico(_ sizes: [Int], _ platform: Platform) -> Data {
    let images = sizes.map { png(render($0, platform)) }
    var out = Data()
    func le16(_ v: Int) { out.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func le32(_ v: Int) { for i in 0..<4 { out.append(UInt8((v >> (8 * i)) & 0xFF)) } }
    le16(0); le16(1); le16(sizes.count)
    var offset = 6 + 16 * sizes.count
    for (size, data) in zip(sizes, images) {
        out.append(UInt8(size >= 256 ? 0 : size)); out.append(UInt8(size >= 256 ? 0 : size))
        out.append(0); out.append(0) // Palette, reserviert
        le16(1); le16(32)            // Ebenen, Bit je Pixel
        le32(data.count); le32(offset)
        offset += data.count
    }
    for data in images { out.append(data) }
    return out
}

// MARK: - SVG (gleiche Zeichnung als Vektor, 1024)

func svgPath(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".00", with: "") }
    path.applyWithBlock { el in
        let p = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svg() -> String {
    let (rect, path) = tile(1024, .mac)
    let k = Mark.scale(tile: rect.width)
    let area = rect.insetBy(dx: rect.width * (1 - k) / 2, dy: rect.height * (1 - k) / 2)
    let u = area.width / 100
    let m = Mark.standard
    func x(_ v: CGFloat) -> String { String(format: "%g", Double(area.minX + v * u)) }
    let top = String(format: "%g", Double(rect.minY)), bottom = String(format: "%g", Double(rect.maxY))
    let lo = m.lo, hi = m.hi, a = m.arm
    let corners = "M\(x(lo)) \(x(lo + a))V\(x(lo))H\(x(lo + a))M\(x(hi - a)) \(x(lo))H\(x(hi))V\(x(lo + a))"
        + "M\(x(hi)) \(x(hi - a))V\(x(hi))H\(x(hi - a))M\(x(lo + a)) \(x(hi))H\(x(lo))V\(x(hi - a))"
    let tilePath = svgPath(path)
    func len(_ v: CGFloat) -> String { String(format: "%g", Double(v * u)) }
    let w = len(m.stroke)
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <!-- Knips-Zeichen in der Markensprache der App-Familie (docs/design.md): vier Auswahl-Ecken (die Auswahl)
           in Papier, ein Balken (die Zensur) in Königsblau, auf Tinte. Erzeugt von scripts/make-icon.swift. -->
      <defs>
        <linearGradient id="ink" x1="0" y1="\(top)" x2="0" y2="\(bottom)" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#24262E"/><stop offset="1" stop-color="#111216"/>
        </linearGradient>
        <linearGradient id="rim" x1="0" y1="\(top)" x2="0" y2="\(bottom)" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#fff" stop-opacity=".10"/><stop offset="1" stop-color="#fff" stop-opacity=".03"/>
        </linearGradient>
        <clipPath id="tile"><path d="\(tilePath)"/></clipPath>
      </defs>
      <path d="\(tilePath)" fill="url(#ink)"/>
      <path d="\(tilePath)" fill="none" stroke="url(#rim)" stroke-width="4" clip-path="url(#tile)"/>
      <path d="\(corners)" fill="none" stroke="#F4F5F7" stroke-width="\(w)" stroke-linecap="round" stroke-linejoin="round"/>
      <rect x="\(x(m.barX.lowerBound))" y="\(x(50 - m.stroke / 2))" width="\(len(m.barX.upperBound - m.barX.lowerBound))" height="\(w)" rx="\(len(m.stroke / 2))" fill="#7B88FF"/>
    </svg>

    """
}

// MARK: - Ausgabe

// Vorschau einzelner Größen: swift scripts/make-icon.swift --preview <ordner>
if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for size in [16, 20, 24, 32, 40, 48, 64, 128, 256, 1024] {
        try png(render(size, .mac)).write(to: dir.appendingPathComponent("mac-\(size).png"))
        try png(render(size, .windows)).write(to: dir.appendingPathComponent("win-\(size).png"))
    }
    print("Vorschau in \(dir.path)")
    exit(0)
}

let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(render(size, .mac)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(render(size * 2, .mac)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { print("iconutil fehlgeschlagen"); exit(1) }

try write(png(render(1024, .mac)), "design/app-icon-1024.png")
try write(Data(svg().utf8), "design/app-icon.svg")

// Windows (Namen wie `tauri icon`; die Square*-Logos braucht nur ein MSIX-Paket)
let win = "windows/src-tauri/icons/"
try write(png(render(1024, .windows)), "windows/design/app-icon-1024.png")
try write(png(render(1024, .windows)), "windows/public/icon.png")
for (name, size) in [("32x32", 32), ("64x64", 64), ("128x128", 128), ("128x128@2x", 256), ("icon", 512),
                     ("Square30x30Logo", 30), ("Square44x44Logo", 44), ("Square71x71Logo", 71), ("Square89x89Logo", 89),
                     ("Square107x107Logo", 107), ("Square142x142Logo", 142), ("Square150x150Logo", 150),
                     ("Square284x284Logo", 284), ("Square310x310Logo", 310), ("StoreLogo", 50)] {
    try write(png(render(size, .windows)), win + name + ".png")
}
try write(ico([16, 20, 24, 32, 40, 48, 64, 256], .windows), win + "icon.ico")
try write(try Data(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns")), win + "icon.icns")

print("Resources/AppIcon.icns, design/app-icon-1024.png, design/app-icon.svg und windows/src-tauri/icons/* geschrieben")
