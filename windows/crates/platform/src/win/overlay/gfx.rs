//! Zeichnen des Overlays mit Direct2D + DirectWrite — eine Routine für das Fenster (HwndRenderTarget)
//! und für den Offscreen-Selbsttest (WIC-Bitmap). Alles in DIPs (= Mac-Punkte): das Renderziel
//! läuft mit der DPI des Monitors, das Standbild wird auf seine Pixelgröße gezogen.
//! Farben und Schriften nur aus `brand.rs` (docs/design.md, „Auswahl-Overlay“).
//!
//! Nur auf einem Thread benutzen (Einzelthread-Factory).

use knips_core::RgbaImage;
use windows::core::{w, Interface, Result, HRESULT, HSTRING, PCWSTR};
use windows_numerics::{Matrix3x2, Vector2};
use windows::Win32::Foundation::HWND;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Imaging::*;
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};

use super::brand::{self, Rgba};
use super::layout::{self, Kind, RectF};

/// `D2DERR_RECREATE_TARGET`: Gerät verloren, Renderziel neu bauen.
pub const RECREATE_TARGET: HRESULT = HRESULT(0x8899000C_u32 as i32);

/// Alles, was ein Frame braucht und sich ändert (reine Daten → vergleichbar, um unnötiges Neuzeichnen zu sparen).
#[derive(Clone, Debug, PartialEq)]
pub struct Scene {
    pub kind: Kind,
    pub window_mode: bool,
    pub scale: f64,
    pub w_px: i32,
    pub h_px: i32,
    /// Zeiger monitor-lokal in px; nur wenn er auf diesem Monitor steht.
    pub mouse: Option<(i32, i32)>,
    /// Loch in der Abdunklung (Auswahl oder Fenster), px.
    pub hole: Option<RectF>,
    /// Aktive Auswahl dieses Monitors, px.
    pub selection: Option<RectF>,
    /// Unterkante des Arbeitsbereichs in pt (Hinweiszeile über der Taskleiste).
    pub work_bottom_pt: f64,
}

// Maße der Pillen in pt.
const SIZE_PILL_H: f64 = 26.0;
const SIZE_PILL_PAD: f64 = 11.0;
const HINT_H: f64 = 36.0;
const HINT_PAD: f64 = 14.0;
const KEY_H: f64 = 22.0;
const KEY_PAD: f64 = 7.0;
const KEY_GAP: f64 = 7.0;
/// Platz für den Trennpunkt zwischen zwei Abschnitten der Hinweiszeile.
const SEP_W: f64 = 21.0;

pub struct Factories {
    pub d2d: ID2D1Factory,
    pub dw: IDWriteFactory,
    /// Größe der Auswahl („1280 × 600“), Mono.
    fmt_size: IDWriteTextFormat,
    /// Tastenkappen, Mono.
    fmt_key: IDWriteTextFormat,
    /// Text der Hinweiszeile.
    fmt_hint: IDWriteTextFormat,
    /// Art der Aufnahme vorn in der Hinweiszeile („Video“), halbfett.
    fmt_title: IDWriteTextFormat,
    /// Koordinaten unter der Lupe, Mono.
    fmt_loupe: IDWriteTextFormat,
    /// Runde Enden für die Eckgriffe.
    round: ID2D1StrokeStyle,
}

impl Factories {
    pub fn new() -> Result<Self> {
        unsafe {
            let d2d: ID2D1Factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
            let dw: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
            let text = pick_family(&dw, &brand::TEXT_FAMILIES);
            let mono = pick_family(&dw, &brand::MONO_FAMILIES);
            let (text, mono) = (PCWSTR(text.as_ptr()), PCWSTR(mono.as_ptr()));
            let fmt_size = make_format(&dw, mono, DWRITE_FONT_WEIGHT_MEDIUM, 12.5)?;
            let fmt_key = make_format(&dw, mono, DWRITE_FONT_WEIGHT_MEDIUM, 11.5)?;
            let fmt_hint = make_format(&dw, text, DWRITE_FONT_WEIGHT_NORMAL, 13.0)?;
            let fmt_title = make_format(&dw, text, DWRITE_FONT_WEIGHT_SEMI_BOLD, 13.0)?;
            let fmt_loupe = make_format(&dw, mono, DWRITE_FONT_WEIGHT_MEDIUM, 10.5)?;
            let sp = D2D1_STROKE_STYLE_PROPERTIES {
                startCap: D2D1_CAP_STYLE_ROUND,
                endCap: D2D1_CAP_STYLE_ROUND,
                dashCap: D2D1_CAP_STYLE_ROUND,
                lineJoin: D2D1_LINE_JOIN_ROUND,
                miterLimit: 10.0,
                dashStyle: D2D1_DASH_STYLE_SOLID,
                dashOffset: 0.0,
            };
            let round = d2d.CreateStrokeStyle(&sp, None)?;
            Ok(Self { d2d, dw, fmt_size, fmt_key, fmt_hint, fmt_title, fmt_loupe, round })
        }
    }

    /// Textbreite in DIPs (ohne Umbruch).
    fn text_width(&self, fmt: &IDWriteTextFormat, s: &str) -> f64 {
        let wide: Vec<u16> = s.encode_utf16().collect();
        unsafe {
            let Ok(layout) = self.dw.CreateTextLayout(&wide, fmt, 10000.0, 200.0) else { return s.chars().count() as f64 * 7.0 };
            let mut m = DWRITE_TEXT_METRICS::default();
            if layout.GetMetrics(&mut m).is_err() {
                return s.chars().count() as f64 * 7.0;
            }
            m.widthIncludingTrailingWhitespace as f64
        }
    }
}

/// Erste vorhandene Schriftfamilie der Liste, sonst die letzte (DirectWrite ersetzt sie dann selbst).
unsafe fn pick_family(dw: &IDWriteFactory, names: &[&str]) -> HSTRING {
    for name in names {
        let h = HSTRING::from(*name);
        if unsafe { has_family(dw, PCWSTR(h.as_ptr())) } {
            return h;
        }
    }
    HSTRING::from(*names.last().unwrap_or(&"Segoe UI"))
}

unsafe fn has_family(dw: &IDWriteFactory, name: PCWSTR) -> bool {
    unsafe {
        let mut coll: Option<IDWriteFontCollection> = None;
        if dw.GetSystemFontCollection(&mut coll, false).is_err() {
            return false;
        }
        let Some(coll) = coll else { return false };
        let mut index = 0u32;
        let mut exists = windows::core::BOOL(0);
        coll.FindFamilyName(name, &mut index, &mut exists).is_ok() && exists.as_bool()
    }
}

unsafe fn make_format(dw: &IDWriteFactory, family: PCWSTR, weight: DWRITE_FONT_WEIGHT, size: f32) -> Result<IDWriteTextFormat> {
    unsafe {
        let f = dw.CreateTextFormat(family, None::<&IDWriteFontCollection>, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, w!("de-DE"))?;
        f.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)?;
        f.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER)?;
        f.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
        Ok(f)
    }
}

fn rf(r: &RectF) -> D2D_RECT_F {
    D2D_RECT_F { left: r.x as f32, top: r.y as f32, right: r.right() as f32, bottom: r.bottom() as f32 }
}

/// Markenfarbe → Direct2D.
pub fn color(c: Rgba) -> D2D1_COLOR_F {
    D2D1_COLOR_F { r: c.r, g: c.g, b: c.b, a: c.a }
}

fn pt(x: f64, y: f64) -> Vector2 {
    Vector2 { X: x as f32, Y: y as f32 }
}

/// RGBA (gerade) → BGRA, undurchsichtig: ein Bildschirmfoto hat nie Transparenz.
#[allow(clippy::chunks_exact_to_as_chunks)]
fn to_bgra_opaque(img: &RgbaImage) -> Vec<u8> {
    let src = img.as_raw();
    let mut out = vec![0u8; src.len()];
    for (d, s) in out.chunks_exact_mut(4).zip(src.chunks_exact(4)) {
        d[0] = s[2];
        d[1] = s[1];
        d[2] = s[0];
        d[3] = 255;
    }
    out
}

/// Ein Stück der Hinweiszeile, fertig vermessen (x relativ zur Pille).
enum HintItem {
    Title(f64, f64, &'static str),
    Text(f64, f64, &'static str),
    Key(f64, f64, &'static str),
    Sep(f64),
}

/// Hinweiszeile vermessen: Stücke und Gesamtbreite.
fn hint_layout(f: &Factories, kind: Kind, window_mode: bool) -> (Vec<HintItem>, f64) {
    let hint = layout::hint(kind, window_mode);
    let mut items = vec![];
    let mut x = HINT_PAD;
    if let Some(t) = hint.title {
        let w = f.text_width(&f.fmt_title, t).ceil();
        items.push(HintItem::Title(x, w, t));
        x += w;
    }
    for (i, g) in hint.groups.iter().enumerate() {
        if i > 0 || hint.title.is_some() {
            items.push(HintItem::Sep(x + SEP_W / 2.0));
            x += SEP_W;
        }
        if let Some(k) = g.key {
            let w = (f.text_width(&f.fmt_key, k).ceil() + 2.0 * KEY_PAD).max(KEY_H);
            items.push(HintItem::Key(x, w, k));
            x += w + KEY_GAP;
        }
        let w = f.text_width(&f.fmt_hint, g.text).ceil();
        items.push(HintItem::Text(x, w, g.text));
        x += w;
    }
    (items, x + HINT_PAD)
}

/// Renderziel + geräteabhängige Ressourcen (Standbild, Pinsel). Wird bei `RECREATE_TARGET` neu gebaut.
pub struct Target {
    rt: ID2D1RenderTarget,
    hwnd_rt: Option<ID2D1HwndRenderTarget>,
    solid: ID2D1SolidColorBrush,
    bitmap: ID2D1Bitmap,
    img_brush: ID2D1BitmapBrush,
    img_w: i32,
    img_h: i32,
}

impl Target {
    /// Renderziel für ein Fenster; `dpi` = Monitor-DPI.
    pub fn for_hwnd(f: &Factories, hwnd: HWND, w_px: i32, h_px: i32, dpi: f32, image: &RgbaImage) -> Result<Target> {
        unsafe {
            let props = D2D1_RENDER_TARGET_PROPERTIES { dpiX: dpi, dpiY: dpi, ..Default::default() };
            let hprops = D2D1_HWND_RENDER_TARGET_PROPERTIES {
                hwnd,
                pixelSize: D2D_SIZE_U { width: w_px.max(1) as u32, height: h_px.max(1) as u32 },
                presentOptions: D2D1_PRESENT_OPTIONS_IMMEDIATELY,
            };
            let hrt = f.d2d.CreateHwndRenderTarget(&props, &hprops)?;
            let rt: ID2D1RenderTarget = hrt.cast()?;
            Self::finish(rt, Some(hrt), dpi, image)
        }
    }

    /// Renderziel für eine WIC-Bitmap (Offscreen).
    pub fn for_wic(f: &Factories, bmp: &IWICBitmap, dpi: f32, image: &RgbaImage) -> Result<Target> {
        let rt = wic_target(f, bmp, dpi)?;
        unsafe { Self::finish(rt, None, dpi, image) }
    }

    unsafe fn finish(rt: ID2D1RenderTarget, hwnd_rt: Option<ID2D1HwndRenderTarget>, dpi: f32, image: &RgbaImage) -> Result<Target> {
        unsafe {
            rt.SetDpi(dpi, dpi);
            rt.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
            let (iw, ih) = (image.width() as i32, image.height() as i32);
            let data = to_bgra_opaque(image);
            // Bitmap-DPI 96: ein Bildpixel = eine Einheit im Pinsel-/Quellraum, unabhängig vom Ziel-DPI.
            let bp = D2D1_BITMAP_PROPERTIES {
                pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED },
                dpiX: 96.0,
                dpiY: 96.0,
            };
            let bitmap = rt.CreateBitmap(D2D_SIZE_U { width: iw as u32, height: ih as u32 }, Some(data.as_ptr() as *const _), (iw * 4) as u32, &bp)?;
            drop(data);
            let solid = rt.CreateSolidColorBrush(&color(brand::DARK), None)?;
            let bbp = D2D1_BITMAP_BRUSH_PROPERTIES {
                extendModeX: D2D1_EXTEND_MODE_CLAMP,
                extendModeY: D2D1_EXTEND_MODE_CLAMP,
                interpolationMode: D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR,
            };
            let img_brush = rt.CreateBitmapBrush(&bitmap, Some(&bbp), None)?;
            Ok(Target { rt, hwnd_rt, solid, bitmap, img_brush, img_w: iw, img_h: ih })
        }
    }

    pub fn resize(&self, w_px: i32, h_px: i32) {
        if let Some(h) = &self.hwnd_rt {
            let size = D2D_SIZE_U { width: w_px.max(1) as u32, height: h_px.max(1) as u32 };
            unsafe {
                let _ = h.Resize(&size);
            }
        }
    }

    /// Ein Frame. Fehler `RECREATE_TARGET` → Aufrufer verwirft das Ziel.
    pub fn render(&self, f: &Factories, s: &Scene) -> Result<()> {
        unsafe {
            let rt = &self.rt;
            rt.BeginDraw();
            self.draw(f, s);
            rt.EndDraw(None, None)
        }
    }

    unsafe fn set(&self, c: Rgba) {
        unsafe { self.solid.SetColor(&color(c)) }
    }

    unsafe fn fill(&self, r: &RectF, c: Rgba) {
        unsafe {
            self.set(c);
            self.rt.FillRectangle(&rf(r), &self.solid);
        }
    }

    unsafe fn stroke(&self, r: &RectF, c: Rgba, width: f32) {
        unsafe {
            self.set(c);
            self.rt.DrawRectangle(&rf(r), &self.solid, width, None::<&ID2D1StrokeStyle>);
        }
    }

    /// Abgerundete Fläche mit feiner Linie innen.
    unsafe fn rounded(&self, r: &RectF, radius: f64, fill: Rgba, line: Rgba) {
        unsafe {
            let rr = D2D1_ROUNDED_RECT { rect: rf(r), radiusX: radius as f32, radiusY: radius as f32 };
            self.set(fill);
            self.rt.FillRoundedRectangle(&rr, &self.solid);
            let inner = (radius - 0.5).max(0.0) as f32;
            let ir = D2D1_ROUNDED_RECT { rect: rf(&r.inset(0.5, 0.5)), radiusX: inner, radiusY: inner };
            self.set(line);
            self.rt.DrawRoundedRectangle(&ir, &self.solid, 1.0, None::<&ID2D1StrokeStyle>);
        }
    }

    unsafe fn text(&self, fmt: &IDWriteTextFormat, s: &str, r: &RectF, c: Rgba) {
        unsafe {
            self.set(c);
            let wide: Vec<u16> = s.encode_utf16().collect();
            self.rt.DrawText(&wide, fmt, &rf(r), &self.solid, D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL);
        }
    }

    /// Dunkle Pille (Radius = halbe Höhe) mit Text in der Mitte.
    unsafe fn pill(&self, r: &RectF, fmt: &IDWriteTextFormat, text: &str) {
        unsafe {
            self.rounded(r, r.h / 2.0, brand::PILL, brand::PILL_LINE);
            self.text(fmt, text, r, brand::PILL_INK);
        }
    }

    unsafe fn draw(&self, f: &Factories, s: &Scene) {
        unsafe {
            let rt = &self.rt;
            let k = 1.0 / s.scale; // px → pt
            let (bw, bh) = (s.w_px as f64 * k, s.h_px as f64 * k);
            rt.SetTransform(&Matrix3x2::identity());

            // 1. Standbild über das ganze Fenster (Pixel 1:1)
            let dest = rf(&RectF::new(0.0, 0.0, bw, bh));
            rt.DrawBitmap(&self.bitmap, Some(&dest), 1.0, D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR, None);

            // 2. Abdunkeln, Even-Odd-Loch als Streifen
            let hole_pt = s.hole.map(|h| h.scaled(k));
            for strip in layout::dim_strips(bw, bh, hole_pt) {
                self.fill(&strip, brand::DIM);
            }

            // 3. Fenster-Hervorhebung (nur im Fenstermodus, nicht beim Ziehen): Königsblau-Fläche 12 % und Rand
            if s.window_mode && s.selection.is_none() {
                if let Some(h) = hole_pt {
                    let w = brand::WINDOW_STROKE_WIDTH as f64;
                    let r = h.inset(w / 2.0, w / 2.0);
                    self.fill(&r, brand::WINDOW_FILL);
                    self.stroke(&r, brand::WINDOW_STROKE, brand::WINDOW_STROKE_WIDTH);
                }
            }

            // 4. Auswahlrahmen: Königsblau hell 1,5 pt mit Eckgriffen, Größe als dunkle Pille in Mono
            if let Some(sel_px) = s.selection {
                let sel = sel_px.scaled(k);
                let half = brand::SELECTION_WIDTH as f64 / 2.0;
                let path = sel.inset(-half, -half);
                self.stroke(&path, brand::HALO, brand::SELECTION_WIDTH + 2.0);
                self.stroke(&path, brand::SELECTION, brand::SELECTION_WIDTH);
                let handles = layout::corner_handles(path, brand::HANDLE_ARM);
                // erst der Saum aller Winkel, dann die Winkel selbst (sonst läge Saum über Farbe)
                for (c, width) in [(brand::HALO, brand::HANDLE_WIDTH + 2.0), (brand::SELECTION, brand::HANDLE_WIDTH)] {
                    self.set(c);
                    for &(a, b) in &handles {
                        rt.DrawLine(pt(a.0, a.1), pt(b.0, b.1), &self.solid, width, &f.round);
                    }
                }

                let text = format!("{} × {}", sel_px.w.round() as i64, sel_px.h.round() as i64);
                let lh = SIZE_PILL_H;
                let lw = f.text_width(&f.fmt_size, &text).ceil() + 2.0 * SIZE_PILL_PAD;
                let (lx, ly) = layout::size_label_origin(sel, lw, lh, bw, bh);
                self.pill(&RectF::new(lx, ly, lw, lh), &f.fmt_size, &text);
            }

            // 5. Fadenkreuz (nur auf dem Monitor mit Zeiger, nicht im Fenstermodus, nicht beim Ziehen)
            if let Some((mx, my)) = s.mouse {
                if !s.window_mode && s.selection.is_none() {
                    let (y0, t) = layout::cross_line(my, s.scale);
                    let (x0, _) = layout::cross_line(mx, s.scale);
                    let hline = RectF::new(0.0, y0 as f64 * k, bw, t as f64 * k);
                    let vline = RectF::new(x0 as f64 * k, 0.0, t as f64 * k, bh);
                    // weicher Schatten: ein Gerätepixel Rand rechts/links bzw. oben/unten
                    self.fill(&RectF::new(0.0, hline.y - k, bw, hline.h + 2.0 * k), brand::CROSSHAIR_SHADOW);
                    self.fill(&RectF::new(vline.x - k, 0.0, vline.w + 2.0 * k, bh), brand::CROSSHAIR_SHADOW);
                    self.fill(&hline, brand::CROSSHAIR);
                    self.fill(&vline, brand::CROSSHAIR);
                }
            }

            // 6. Hinweiszeile unten mittig (nur auf dem Monitor mit Zeiger, nicht beim Ziehen)
            if s.mouse.is_some() && s.selection.is_none() {
                self.draw_hint(f, s, bw);
            }

            // 7. Lupe (nur auf dem Monitor mit Zeiger, nicht im Fenstermodus)
            if let Some((mx, my)) = s.mouse {
                if !s.window_mode {
                    self.draw_loupe(f, s, (mx, my), bw, bh);
                }
            }
        }
    }

    /// Dunkle Pille: „[Art] · Bereich ziehen · [Leertaste] Fenster · [⏎] Bildschirm · [Esc] Abbrechen“.
    unsafe fn draw_hint(&self, f: &Factories, s: &Scene, bw: f64) {
        unsafe {
            let (items, pw) = hint_layout(f, s.kind, s.window_mode);
            let (hx, hy) = layout::hint_origin(bw, pw, HINT_H, s.work_bottom_pt);
            let hx = hx.max(8.0);
            self.rounded(&RectF::new(hx, hy, pw, HINT_H), HINT_H / 2.0, brand::PILL, brand::PILL_LINE);
            let mid = hy + HINT_H / 2.0;
            for item in &items {
                match *item {
                    HintItem::Title(x, w, t) => self.text(&f.fmt_title, t, &RectF::new(hx + x, hy, w, HINT_H), brand::PILL_INK),
                    HintItem::Text(x, w, t) => self.text(&f.fmt_hint, t, &RectF::new(hx + x, hy, w, HINT_H), brand::PILL_INK),
                    HintItem::Key(x, w, t) => {
                        let r = RectF::new(hx + x, mid - KEY_H / 2.0, w, KEY_H);
                        self.rounded(&r, 6.0, brand::KEYCAP, brand::KEYCAP_LINE);
                        self.text(&f.fmt_key, t, &r, brand::PILL_INK);
                    }
                    HintItem::Sep(cx) => {
                        self.set(brand::PILL_MUTED);
                        let dot = D2D1_ELLIPSE { point: pt(hx + cx, mid), radiusX: 1.5, radiusY: 1.5 };
                        self.rt.FillEllipse(&dot, &self.solid);
                    }
                }
            }
        }
    }

    unsafe fn draw_loupe(&self, f: &Factories, s: &Scene, m: (i32, i32), bw: f64, bh: f64) {
        unsafe {
            let rt = &self.rt;
            let k = 1.0 / s.scale;
            let size = layout::LOUPE_SIZE;
            let local = (m.0 as f64 * k, m.1 as f64 * k);
            let (ox, oy) = layout::loupe_origin(local, bw, bh);
            let cell = size / layout::LOUPE_PIXELS as f64;
            let ellipse = D2D1_ELLIPSE { point: pt(ox + size / 2.0, oy + size / 2.0), radiusX: (size / 2.0) as f32, radiusY: (size / 2.0) as f32 };

            // dunkler Grund (Bereiche außerhalb des Bilds)
            self.set(brand::DARK);
            rt.FillEllipse(&ellipse, &self.solid);

            if let Some(((rx, ry), (cx, cy, cw, ch))) = layout::loupe_source(m.0, m.1, self.img_w, self.img_h) {
                // Pinsel bildet Bildpixel (Pinselraum) auf die Lupe ab; geklemmt auf den sichtbaren Ausschnitt.
                let mat = Matrix3x2 { M11: cell as f32, M12: 0.0, M21: 0.0, M22: cell as f32, M31: (ox - rx as f64 * cell) as f32, M32: (oy - ry as f64 * cell) as f32 };
                self.img_brush.SetTransform(&mat);
                let clip = RectF::new(ox + (cx - rx) as f64 * cell, oy + (cy - ry) as f64 * cell, cw as f64 * cell, ch as f64 * cell);
                rt.PushAxisAlignedClip(&rf(&clip), D2D1_ANTIALIAS_MODE_ALIASED);
                rt.FillEllipse(&ellipse, &self.img_brush);
                rt.PopAxisAlignedClip();
            }

            // mittleres Pixel: Rahmen 1,5 pt innen
            let mid = RectF::new(ox + (size - cell) / 2.0, oy + (size - cell) / 2.0, cell, cell);
            self.stroke(&mid.inset(0.75, 0.75), brand::LOUPE_RING, 1.5);

            // Ring: 2 pt, innen im Kreis
            self.set(brand::LOUPE_RING);
            let ring = D2D1_ELLIPSE { radiusX: (size / 2.0 - 1.0) as f32, radiusY: (size / 2.0 - 1.0) as f32, ..ellipse };
            rt.DrawEllipse(&ring, &self.solid, 2.0, None::<&ID2D1StrokeStyle>);

            // Koordinaten unter der Lupe (Pixel im Standbild) als dunkle Pille in Mono
            let t = layout::loupe_text_rect((ox, oy));
            self.pill(&t, &f.fmt_loupe, &format!("{}, {}", m.0, m.1));
        }
    }
}

/// WIC-Bitmap (vormultipliziertes BGRA) für Offscreen-Bilder.
pub fn wic_bitmap(w: u32, h: u32) -> Result<IWICBitmap> {
    unsafe {
        let wic: IWICImagingFactory = CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
        wic.CreateBitmap(w, h, &GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad)
    }
}

/// Software-Renderziel auf einer WIC-Bitmap.
pub fn wic_target(f: &Factories, bmp: &IWICBitmap, dpi: f32) -> Result<ID2D1RenderTarget> {
    unsafe {
        let props = D2D1_RENDER_TARGET_PROPERTIES {
            r#type: D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED },
            dpiX: dpi,
            dpiY: dpi,
            ..Default::default()
        };
        let rt = f.d2d.CreateWicBitmapRenderTarget(bmp, &props)?;
        rt.SetDpi(dpi, dpi);
        Ok(rt)
    }
}

/// Inhalt einer WIC-Bitmap als RGBA mit geradem Alpha.
#[allow(clippy::chunks_exact_to_as_chunks)]
pub fn read_wic(bmp: &IWICBitmap, w: u32, h: u32) -> Result<RgbaImage> {
    unsafe {
        let rect = WICRect { X: 0, Y: 0, Width: w as i32, Height: h as i32 };
        let lock = bmp.Lock(&rect, WICBitmapLockRead.0 as u32)?;
        let mut size = 0u32;
        let mut ptr: *mut u8 = std::ptr::null_mut();
        lock.GetDataPointer(&mut size, &mut ptr)?;
        let stride = lock.GetStride()? as usize;
        if ptr.is_null() || stride < w as usize * 4 || (size as usize) < stride * (h as usize - 1) + w as usize * 4 {
            return Err(windows::core::Error::from(windows::Win32::Foundation::E_FAIL));
        }
        let src = std::slice::from_raw_parts(ptr, size as usize);
        let mut out = vec![0u8; (w * h * 4) as usize];
        for y in 0..h as usize {
            let row = &src[y * stride..y * stride + w as usize * 4];
            let dst = &mut out[y * w as usize * 4..(y + 1) * w as usize * 4];
            for (d, s) in dst.chunks_exact_mut(4).zip(row.chunks_exact(4)) {
                // PBGRA → RGBA gerade
                let a = s[3] as u32;
                let un = |c: u8| if a == 0 || a == 255 { c } else { ((c as u32 * 255 + a / 2) / a).min(255) as u8 };
                d[0] = un(s[2]);
                d[1] = un(s[1]);
                d[2] = un(s[0]);
                d[3] = s[3];
            }
        }
        drop(lock);
        RgbaImage::from_raw(w, h, out).ok_or_else(|| windows::core::Error::from(windows::Win32::Foundation::E_FAIL))
    }
}

/// Szene in ein Bild rendern (WIC-Bitmap, Software). Läuft auf dem aufrufenden Thread; COM muss initialisiert sein.
pub fn render_to_image(f: &Factories, image: &RgbaImage, scene: &Scene) -> Result<RgbaImage> {
    let (w, h) = (image.width(), image.height());
    let bmp = wic_bitmap(w, h)?;
    {
        let target = Target::for_wic(f, &bmp, (96.0 * scene.scale) as f32, image)?;
        target.render(f, scene)?;
    }
    read_wic(&bmp, w, h)
}
