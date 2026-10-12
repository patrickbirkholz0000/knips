//! Testbild wie `SelfTest.sampleImage` (Swift), mit GDI in eine 32-Bit-DIB gezeichnet.
//! Graustufen-Antialiasing (kein ClearType), damit die Texterkennung die Schrift sicher liest.

use std::ffi::c_void;

use knips_core::RgbaImage;
use windows::core::w;
use windows::Win32::Foundation::{COLORREF, RECT};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, CreateFontW, CreateSolidBrush, DeleteDC, DeleteObject, Ellipse, FillRect,
    GdiFlush, GetStockObject, RoundRect, SelectObject, SetBkMode, SetTextColor, TextOutW, ANTIALIASED_QUALITY,
    BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DIB_RGB_COLORS, FF_DONTCARE,
    HDC, NULL_PEN, OUT_DEFAULT_PRECIS, TRANSPARENT, VARIABLE_PITCH,
};

fn rgb(r: u8, g: u8, b: u8) -> COLORREF {
    COLORREF(r as u32 | (g as u32) << 8 | (b as u32) << 16)
}

/// Testbild wie `SelfTest.sampleImage`: helles App-Fenster mit Seitenleiste und Kundendaten
/// (Name, E-Mail, Telefon, IBAN, Stripe-Key, Bestellnummer, Hinweis, Knopf) — mit echter
/// Schrift, damit Texterkennung und Auto-Zensur etwas finden. `scale`: Pixel pro Punkt.
pub fn sample_image(width: u32, height: u32, scale: f64) -> RgbaImage {
    let (width, height) = (width.max(1), height.max(1));
    let mut pixels: Vec<u8> = Vec::new();
    // SAFETY: Alle GDI-Objekte werden in umgekehrter Reihenfolge freigegeben; der DIB-Speicher gehört
    // der Bitmap und wird vor deren Löschung kopiert.
    unsafe {
        let dc = CreateCompatibleDC(None);
        if dc.is_invalid() {
            return RgbaImage::new(width, height);
        }
        let bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width as i32,
                biHeight: -(height as i32), // von oben nach unten
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut c_void = std::ptr::null_mut();
        let Ok(bmp) = CreateDIBSection(Some(dc), &bmi, DIB_RGB_COLORS, &mut bits, None, 0) else {
            let _ = DeleteDC(dc);
            return RgbaImage::new(width, height);
        };
        if bits.is_null() {
            let _ = DeleteObject(bmp.into());
            let _ = DeleteDC(dc);
            return RgbaImage::new(width, height);
        }
        let old_bmp = SelectObject(dc, bmp.into());
        let s = scale;
        let px = |v: f64| (v * s).round() as i32;

        let fill = |dc: HDC, r: RECT, c: COLORREF| {
            let br = CreateSolidBrush(c);
            FillRect(dc, &r, br);
            let _ = DeleteObject(br.into());
        };
        fill(dc, RECT { left: 0, top: 0, right: width as i32, bottom: height as i32 }, rgb(237, 240, 245));
        // Titelleiste
        fill(dc, RECT { left: 0, top: 0, right: width as i32, bottom: px(34.0) }, rgb(214, 217, 224));
        // Ampel (macOS-Systemfarben)
        let old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
        for (i, c) in [rgb(255, 59, 48), rgb(255, 204, 0), rgb(52, 199, 89)].into_iter().enumerate() {
            let br = CreateSolidBrush(c);
            let old = SelectObject(dc, br.into());
            let x = px(14.0 + i as f64 * 20.0);
            let y = px(11.0);
            let _ = Ellipse(dc, x, y, x + px(12.0) + 1, y + px(12.0) + 1);
            SelectObject(dc, old);
            let _ = DeleteObject(br.into());
        }
        // Seitenleiste
        fill(dc, RECT { left: 0, top: px(34.0), right: px(170.0), bottom: height as i32 }, rgb(51, 56, 69));

        let text = |dc: HDC, str_: &str, x: f64, y: f64, size: f64, weight: i32, color: COLORREF| {
            let font = CreateFontW(
                -((size * s).round() as i32),
                0,
                0,
                0,
                weight,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                ANTIALIASED_QUALITY,
                (VARIABLE_PITCH.0 | FF_DONTCARE.0) as u32,
                w!("Segoe UI"),
            );
            let old = SelectObject(dc, font.into());
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, color);
            let wide: Vec<u16> = str_.encode_utf16().collect();
            let _ = TextOutW(dc, px(x), px(y), &wide);
            SelectObject(dc, old);
            let _ = DeleteObject(font.into());
        };
        let (regular, medium, semibold, bold) = (400, 500, 600, 700);
        let black = rgb(0, 0, 0);
        let dark_gray = rgb(85, 85, 85);
        let white = rgb(255, 255, 255);

        for (i, t) in ["Übersicht", "Kunden", "Rechnungen", "Einstellungen"].iter().enumerate() {
            text(dc, t, 18.0, 56.0 + i as f64 * 30.0, 13.0, medium, white);
        }
        text(dc, "Kundendaten", 196.0, 52.0, 22.0, bold, black);
        text(dc, "Name: Erika Mustermann", 196.0, 96.0, 14.0, regular, black);
        text(dc, "E-Mail: erika.mustermann@example.com", 196.0, 124.0, 14.0, regular, black);
        text(dc, "Telefon: +49 170 1234567", 196.0, 152.0, 14.0, regular, black);
        text(dc, "IBAN: DE89 3704 0044 0532 0130 00", 196.0, 180.0, 14.0, regular, black);
        text(dc, "Stripe-Key: sk_live_KnipsBeispiel42", 196.0, 208.0, 13.0, regular, dark_gray);
        text(dc, "Bestellung #48213 wurde am 03.10. versendet und ist unterwegs.", 196.0, 252.0, 14.0, regular, black);
        text(dc, "Hinweis: Lieferzeit 2–3 Werktage, Sendungsverfolgung folgt per Mail.", 196.0, 280.0, 14.0, regular, dark_gray);

        // Knopf (systemBlue, Radius 7 pt)
        let br = CreateSolidBrush(rgb(0, 122, 255));
        let old = SelectObject(dc, br.into());
        let (bx, by) = (px(196.0), px(318.0));
        let _ = RoundRect(dc, bx, by, bx + px(140.0) + 1, by + px(30.0) + 1, px(14.0), px(14.0));
        SelectObject(dc, old);
        let _ = DeleteObject(br.into());
        text(dc, "Speichern", 232.0, 324.0, 13.0, semibold, white);

        let _ = GdiFlush();
        let len = width as usize * height as usize * 4;
        pixels.extend_from_slice(std::slice::from_raw_parts(bits as *const u8, len));

        SelectObject(dc, old_pen);
        SelectObject(dc, old_bmp);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(dc);
    }
    // BGRX → RGBA, Alpha 255 (GDI setzt es nicht).
    for p in pixels.chunks_exact_mut(4) {
        p.swap(0, 2);
        p[3] = 255;
    }
    RgbaImage::from_raw(width, height, pixels).unwrap_or_else(|| RgbaImage::new(width, height))
}
