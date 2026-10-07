// Erzeugt Resources/AppIcon.icns: Sucher-Ecken über einem verpixelten Block (Screenshot + Zensur).
// Aufruf: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS-Raster: Kachel 824/1024 mit ~10 % Rand
    let tile = CGRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
    let radius = tile.width * 0.2237
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 0.20, green: 0.21, blue: 0.25, alpha: 1).cgColor,
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // Verpixelter Block in der Mitte
    let grid = 4
    let block = tile.width * 0.105
    let blockOrigin = CGPoint(x: tile.midX - block * CGFloat(grid) / 2, y: tile.midY - block * CGFloat(grid - 1) / 2)
    let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.24, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.33, blue: 0.38, alpha: 1),
    ]
    let pattern = [[0, 2, 1, 3], [2, 0, 3, 1], [1, 3, 0, 2]]
    for row in 0..<3 {
        for col in 0..<grid {
            let c = palette[pattern[row][col]]
            ctx.setFillColor(c.withAlphaComponent(row == 1 ? 1 : 0.82).cgColor)
            ctx.fill(CGRect(x: blockOrigin.x + CGFloat(col) * block, y: blockOrigin.y + CGFloat(row) * block,
                            width: block - s * 0.004, height: block - s * 0.004))
        }
    }

    // Sucher-Ecken
    let inset = tile.width * 0.17
    let frame = tile.insetBy(dx: inset, dy: inset)
    let arm = frame.width * 0.24
    let lw = tile.width * 0.052
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let r = lw * 1.4
    for (cx, cy, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                             (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx, y: cy + dy * arm))
        p.addLine(to: CGPoint(x: cx, y: cy + dy * r))
        p.addQuadCurve(to: CGPoint(x: cx + dx * r, y: cy), control: CGPoint(x: cx, y: cy))
        p.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
        ctx.addPath(p)
    }
    ctx.strokePath()
    ctx.restoreGState()

    // feine Kante
    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.setLineWidth(max(1, s * 0.002))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try draw(1024).write(to: root.appendingPathComponent("build/AppIcon-1024.png"))
print(task.terminationStatus == 0 ? "Resources/AppIcon.icns geschrieben" : "iconutil fehlgeschlagen")
