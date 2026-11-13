import AppKit
import CImageQuant
import zlib

/// PNG in voller Auflösung mit höchstens 256 Farben (Farbtabelle statt drei Bytes je Pixel) — die Ausgabe
/// „Automatisch“. Ein Retina-Bild wird so etwa so groß wie die 1×-Fassung, bleibt aber scharf. Die Farben wählt
/// libimagequant (`Sources/CImageQuant`); reichen 256 nicht, ohne dass man es sähe (Fotos, Videobilder), gibt es
/// kein Ergebnis und die Ausgabe fällt auf Bildschirmgröße zurück (`AppSettings.outputPromise`).
///
/// Gemessen 13.11.2026 an 80 echten Aufnahmen (M4): 76 bestehen die Schwelle (Abstand zum Original im Mittel 56 dB,
/// nie unter 40 dB), 4 fallen zurück. Zusammen 32,5 MB statt 39,6 MB mit der 1×-Ausgabe bis 1.0.2 — in doppelter
/// Auflösung. Ein Ausschnitt braucht im Mittel 0,15 s, ein 4K-Vollbild 0,5–0,7 s, alles im Hintergrund.
enum PalettePNG {
    /// Mindestgüte nach dem Maß von libimagequant (0–100). Darunter sähe man Körnung in Fotos und Verläufen.
    static let minQuality: Int32 = 85
    /// Größere Bilder (sehr lange Scroll-Screenshots) bleiben bei der bisherigen Ausgabe: Die Farbreduktion braucht
    /// das ganze Bild als RGBA im Speicher.
    static let maxPixels = 40_000_000

    struct Indexed {
        let width: Int
        let height: Int
        /// Je Pixel der Platz in `palette`, zeilenweise von oben.
        let indices: [UInt8]
        /// RGBA, nicht vormultipliziert.
        let palette: [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]
        /// Erreichte Güte (0–100).
        let quality: Int
    }

    /// `nil`: Farben reichen nicht, Bild zu groß oder Fehler — dann die bisherige Ausgabe nehmen.
    static func encode(_ image: CGImage, pointScale: CGFloat) -> Data? {
        guard let indexed = quantize(image) else { return nil }
        return png(indexed, colorSpace: Renderer.rgbSpace(image.colorSpace), pointScale: pointScale)
    }

    /// Farben auf höchstens 256 reduzieren, mit feinem Raster (Dithering) an Verläufen.
    static func quantize(_ image: CGImage, minQuality: Int32 = minQuality) -> Indexed? {
        let w = image.width, h = image.height, count = w * h
        guard w > 0, h > 0, count <= maxPixels, let pixels = malloc(count * 4) else { return nil }
        defer { free(pixels) }
        // RGBA in der Reihenfolge R, G, B, A. Core Graphics zeichnet nur vormultipliziert …
        guard let ctx = CGContext(data: pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: Renderer.rgbSpace(image.colorSpace), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // … libimagequant erwartet die Farbe ohne Vormultiplikation (nur bei Durchsicht ein Unterschied).
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break
        default:
            let p = pixels.assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < count * 4 {
                let a = Int(p[i + 3])
                if a != 255, a != 0 {
                    p[i] = UInt8(min(255, (Int(p[i]) * 255 + a / 2) / a))
                    p[i + 1] = UInt8(min(255, (Int(p[i + 1]) * 255 + a / 2) / a))
                    p[i + 2] = UInt8(min(255, (Int(p[i + 2]) * 255 + a / 2) / a))
                }
                i += 4
            }
        }

        guard let attr = liq_attr_create() else { return nil }
        defer { liq_attr_destroy(attr) }
        liq_set_speed(attr, 4)
        guard liq_set_quality(attr, minQuality, 100) == LIQ_OK,
              let input = liq_image_create_rgba(attr, pixels, Int32(w), Int32(h), 0) else { return nil }
        defer { liq_image_destroy(input) }
        var output: OpaquePointer?
        // Unter der Mindestgüte bricht libimagequant hier ab (LIQ_QUALITY_TOO_LOW).
        guard liq_image_quantize(input, attr, &output) == LIQ_OK, let result = output else { return nil }
        defer { liq_result_destroy(result) }
        liq_set_dithering_level(result, 1)
        var indices = [UInt8](repeating: 0, count: count)
        guard liq_write_remapped_image(result, input, &indices, count) == LIQ_OK,
              let table = liq_get_palette(result)?.pointee, table.count > 0 else { return nil }
        let entries = withUnsafeBytes(of: table.entries) { raw in
            Array(raw.bindMemory(to: liq_color.self).prefix(Int(table.count)))
        }
        return Indexed(width: w, height: h, indices: indices, palette: entries.map { ($0.r, $0.g, $0.b, $0.a) },
                       quality: Int(liq_get_quantization_quality(result)))
    }

    /// PNG mit Farbtabelle (Farbtyp 3, 8 Bit): IHDR, Farbraum, Auflösung, PLTE, tRNS, IDAT, IEND.
    static func png(_ image: Indexed, colorSpace: CGColorSpace, pointScale: CGFloat) -> Data? {
        let w = image.width, h = image.height
        guard image.indices.count == w * h, !image.palette.isEmpty, image.palette.count <= 256 else { return nil }
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func be(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func chunk(_ type: String, _ body: Data) {
            var typed = Data(type.utf8)
            typed.append(body)
            let crc = typed.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            out.append(contentsOf: be(body.count))
            out.append(typed)
            out.append(contentsOf: be(Int(crc)))
        }
        chunk("IHDR", Data(be(w) + be(h) + [8, 3, 0, 0, 0]))
        // Farbraum wie beim Bild: sRGB als Kennung, alles andere (Profil des Bildschirms) als ICC-Profil.
        if colorSpace.name == CGColorSpace.sRGB {
            chunk("sRGB", Data([0]))
        } else if let icc = colorSpace.copyICCData() as Data?, let packed = deflate(icc) {
            chunk("iCCP", Data("ICC Profile".utf8) + [0, 0] + packed)
        }
        if pointScale > 1.01 {
            // Pixel pro Meter: 72 dpi × Pixel pro Punkt (2× = 144 dpi), wie Bildschirmfotos von macOS.
            let perMetre = Int((72 * Double(pointScale) / 0.0254).rounded())
            chunk("pHYs", Data(be(perMetre) + be(perMetre) + [1]))
        }
        chunk("PLTE", Data(image.palette.flatMap { [$0.r, $0.g, $0.b] }))
        if let last = image.palette.lastIndex(where: { $0.a < 255 }) {
            chunk("tRNS", Data(image.palette[...last].map(\.a)))
        }
        // Jede Zeile beginnt mit dem Filter-Byte 0 (keiner): bei Farbtabellen packt das am besten.
        var rows = Data(count: (w + 1) * h)
        rows.withUnsafeMutableBytes { raw in
            guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            image.indices.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                for y in 0..<h {
                    dst[y * (w + 1)] = 0
                    (dst + y * (w + 1) + 1).update(from: base + y * w, count: w)
                }
            }
        }
        guard let data = deflate(rows) else { return nil }
        chunk("IDAT", data)
        chunk("IEND", Data())
        return out
    }

    /// zlib mit höchster Stufe: an einem 4K-Bild 0,2 s statt 0,08 s mit Stufe 7, dafür 2–15 % kleiner (am meisten bei
    /// Flächen und Schrift).
    private static func deflate(_ input: Data, level: Int32 = 9) -> Data? {
        var length = compressBound(uLong(input.count))
        var packed = Data(count: Int(length))
        let status = packed.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compress2(dst.bindMemory(to: Bytef.self).baseAddress, &length, src.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), level)
            }
        }
        guard status == Z_OK else { return nil }
        packed.count = Int(length)
        return packed
    }
}
