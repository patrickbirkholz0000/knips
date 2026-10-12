//! Zeichnen des Overlays mit Direct2D + DirectWrite — eine Routine für das Fenster (HwndRenderTarget)
//! und für den Offscreen-Selbsttest (WIC-Bitmap). Alles in DIPs (= Mac-Punkte): das Renderziel
//! läuft mit der DPI des Monitors, das Standbild wird auf seine Pixelgröße gezogen.
//!
//! Nur auf einem Thread benutzen (Einzelthread-Factory).

use knips_core::RgbaImage;
use windows::core::{w, Interface, Result, HRESULT, PCWSTR};
use windows_numerics::{Matrix3x2, Vector2};
use windows::Win32::Foundation::HWND;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Imaging::*;
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};

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
    /// Oberkante des Arbeitsbereichs in pt (für das Hinweisschild).
    pub work_top_pt: f64,
}

pub struct Factories {
    pub d2d: ID2D1Factory,
    pub dw: IDWriteFactory,
    fmt_size: IDWriteTextFormat,
    fmt_hint: IDWriteTextFormat,
    fmt_loupe: IDWriteTextFormat,
}

impl Factories {
    pub fn new() -> Result<Self> {
        unsafe {
            let d2d: ID2D1Factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
            let dw: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
            let text_family = if has_family(&dw, w!("Segoe UI Variable Text")) { w!("Segoe UI Variable Text") } else { w!("Segoe UI") };
            // Ziffern: Segoe UI hat von Haus aus gleich breite Ziffern.
            let digit_family = w!("Segoe UI");
            let fmt_size = make_format(&dw, digit_family, DWRITE_FONT_WEIGHT_SEMI_BOLD, 12.0)?;
            let fmt_hint = make_format(&dw, text_family, DWRITE_FONT_WEIGHT_MEDIUM, 12.5)?;
            let fmt_loupe = make_format(&dw, digit_family, DWRITE_FONT_WEIGHT_SEMI_BOLD, 10.5)?;
            Ok(Self { d2d, dw, fmt_size, fmt_hint, fmt_loupe })
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

fn col(r: f32, g: f32, b: f32, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F { r, g, b, a }
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
        unsafe {
            let props = D2D1_RENDER_TARGET_PROPERTIES {
                r#type: D2D1_RENDER_TARGET_TYPE_SOFTWARE,
                pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED },
                dpiX: dpi,
                dpiY: dpi,
                ..Default::default()
            };
            let rt = f.d2d.CreateWicBitmapRenderTarget(bmp, &props)?;
            Self::finish(rt, None, dpi, image)
        }
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
            let solid = rt.CreateSolidColorBrush(&col(0.0, 0.0, 0.0, 1.0), None)?;
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

    unsafe fn set(&self, c: D2D1_COLOR_F) {
        unsafe { self.solid.SetColor(&c) }
    }

    unsafe fn fill(&self, r: &RectF, c: D2D1_COLOR_F) {
        unsafe {
            self.set(c);
            self.rt.FillRectangle(&rf(r), &self.solid);
        }
    }

    unsafe fn stroke(&self, r: &RectF, c: D2D1_COLOR_F, width: f32) {
        unsafe {
            self.set(c);
            self.rt.DrawRectangle(&rf(r), &self.solid, width, None::<&ID2D1StrokeStyle>);
        }
    }

    /// Schild mit abgerundeter Kapsel (Hintergrund rgb(20,20,20) α0.82, Rand weiß α0.12) und Text.
    unsafe fn pill(&self, f: &Factories, r: &RectF, radius: f32, fmt: &IDWriteTextFormat, text: &str) {
        unsafe {
            let rr = D2D1_ROUNDED_RECT { rect: rf(r), radiusX: radius, radiusY: radius };
            self.set(col(0.08, 0.08, 0.08, 0.82));
            self.rt.FillRoundedRectangle(&rr, &self.solid);
            // Rand innen, 1 pt
            let ir = D2D1_ROUNDED_RECT { rect: rf(&r.inset(0.5, 0.5)), radiusX: (radius - 0.5).max(0.0), radiusY: (radius - 0.5).max(0.0) };
            self.set(col(1.0, 1.0, 1.0, 0.12));
            self.rt.DrawRoundedRectangle(&ir, &self.solid, 1.0, None::<&ID2D1StrokeStyle>);
            self.set(col(1.0, 1.0, 1.0, 1.0));
            let wide: Vec<u16> = text.encode_utf16().collect();
            self.rt.DrawText(&wide, fmt, &rf(r), &self.solid, D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL);
            let _ = f;
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
                self.fill(&strip, col(0.0, 0.0, 0.0, 0.38));
            }

            // 3. Fenster-Hervorhebung (nur im Fenstermodus, nicht beim Ziehen)
            if s.window_mode && s.selection.is_none() {
                if let Some(h) = hole_pt {
                    let r = h.inset(1.5, 1.5);
                    self.fill(&r, col(0.0, 122.0 / 255.0, 1.0, 0.16));
                    self.stroke(&r, col(0.0, 122.0 / 255.0, 1.0, 1.0), 3.0);
                }
            }

            // 4. Auswahlrahmen: weiß 1 pt mit weichem dunklem Schatten, Größenschild
            if let Some(sel_px) = s.selection {
                let sel = sel_px.scaled(k);
                let path = sel.inset(-0.5, -0.5);
                self.stroke(&path, col(0.0, 0.0, 0.0, 0.30), 3.0);
                self.stroke(&path, col(1.0, 1.0, 1.0, 1.0), 1.0);

                let text = format!("{} × {}", sel_px.w.round() as i64, sel_px.h.round() as i64);
                let lh = 24.0;
                let lw = f.text_width(&f.fmt_size, &text).ceil() + 18.0;
                let (lx, ly) = layout::size_label_origin(sel, lw, lh, bw, bh);
                self.pill(f, &RectF::new(lx, ly, lw, lh), (lh / 2.0) as f32, &f.fmt_size, &text);
            }

            // 5. Fadenkreuz (nur auf dem Monitor mit Zeiger, nicht im Fenstermodus, nicht beim Ziehen)
            if let Some((mx, my)) = s.mouse {
                if !s.window_mode && s.selection.is_none() {
                    let (y0, t) = layout::cross_line(my, s.scale);
                    let (x0, _) = layout::cross_line(mx, s.scale);
                    let hline = RectF::new(0.0, y0 as f64 * k, bw, t as f64 * k);
                    let vline = RectF::new(x0 as f64 * k, 0.0, t as f64 * k, bh);
                    // weicher Schatten: ein Gerätepixel Rand rechts/links bzw. oben/unten
                    self.fill(&RectF::new(0.0, hline.y - k, bw, hline.h + 2.0 * k), col(0.0, 0.0, 0.0, 0.22));
                    self.fill(&RectF::new(vline.x - k, 0.0, vline.w + 2.0 * k, bh), col(0.0, 0.0, 0.0, 0.22));
                    self.fill(&hline, col(1.0, 1.0, 1.0, 0.55));
                    self.fill(&vline, col(1.0, 1.0, 1.0, 0.55));
                }
            }

            // 6. Hinweisschild oben mittig (nur auf dem Monitor mit Zeiger, nicht beim Ziehen)
            if s.mouse.is_some() && s.selection.is_none() {
                let text = layout::hint_text(s.kind, s.window_mode);
                let pw = f.text_width(&f.fmt_hint, &text).ceil() + 28.0;
                let ph = 30.0;
                let (hx, hy) = layout::hint_origin(bw, pw, s.work_top_pt);
                self.pill(f, &RectF::new(hx, hy, pw, ph), (ph / 2.0) as f32, &f.fmt_hint, &text);
            }

            // 7. Lupe (nur auf dem Monitor mit Zeiger, nicht im Fenstermodus)
            if let Some((mx, my)) = s.mouse {
                if !s.window_mode {
                    self.draw_loupe(f, s, (mx, my), bw, bh);
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
            let ellipse = D2D1_ELLIPSE { point: Vector2 { X: (ox + size / 2.0) as f32, Y: (oy + size / 2.0) as f32 }, radiusX: (size / 2.0) as f32, radiusY: (size / 2.0) as f32 };

            // schwarzer Grund (Bereiche außerhalb des Bilds)
            self.set(col(0.0, 0.0, 0.0, 1.0));
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
            self.stroke(&mid.inset(0.75, 0.75), col(1.0, 1.0, 1.0, 1.0), 1.5);

            // Ring: weiß 2 pt, innen im Kreis
            self.set(col(1.0, 1.0, 1.0, 1.0));
            let ring = D2D1_ELLIPSE { radiusX: (size / 2.0 - 1.0) as f32, radiusY: (size / 2.0 - 1.0) as f32, ..ellipse };
            rt.DrawEllipse(&ring, &self.solid, 2.0, None::<&ID2D1StrokeStyle>);

            // Koordinaten unter der Lupe (Pixel im Standbild)
            let t = layout::loupe_text_rect((ox, oy));
            let rr = D2D1_ROUNDED_RECT { rect: rf(&t), radiusX: 5.0, radiusY: 5.0 };
            self.set(col(0.08, 0.08, 0.08, 0.82));
            rt.FillRoundedRectangle(&rr, &self.solid);
            self.set(col(1.0, 1.0, 1.0, 1.0));
            let text: Vec<u16> = format!("{}, {}", m.0, m.1).encode_utf16().collect();
            rt.DrawText(&text, &f.fmt_loupe, &rf(&t), &self.solid, D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL);
        }
    }
}

/// Szene in ein Bild rendern (WIC-Bitmap, Software). Läuft auf dem aufrufenden Thread; COM muss initialisiert sein.
#[allow(clippy::chunks_exact_to_as_chunks)]
pub fn render_to_image(f: &Factories, image: &RgbaImage, scene: &Scene) -> Result<RgbaImage> {
    unsafe {
        let (w, h) = (image.width(), image.height());
        let wic: IWICImagingFactory = CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
        let bmp = wic.CreateBitmap(w, h, &GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad)?;
        {
            let target = Target::for_wic(f, &bmp, (96.0 * scene.scale) as f32, image)?;
            target.render(f, scene)?;
        }
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
                // PBGRA → RGBA gerade (Ergebnis ist undurchsichtig; α=0 nur bei fehlerhaften Pixeln)
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
