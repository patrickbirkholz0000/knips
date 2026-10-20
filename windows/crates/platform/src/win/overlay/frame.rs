//! Gestrichelter Rahmen um den Aufnahmebereich (Port von `showFrame` in RecordingController/ScrollCapture).
//!
//! Ein durchklickbares Layered-Fenster (UpdateLayeredWindow, Per-Pixel-Alpha) auf eigenem Thread mit
//! eigener Nachrichtenschleife. Das Fenster liegt 3 pt außerhalb des Bereichs; die Linie (2 pt, Strich 6 /
//! Lücke 4, mit dunklem Saum) sitzt 1 pt innerhalb der Fensterkante. Farben aus `brand.rs`: Aufnahme-Rot
//! bzw. Königsblau hell. Nimmt nie den Fokus, nicht in Aufnahmen.

use std::ffi::c_void;
use std::sync::mpsc;
use std::sync::Once;
use std::thread::JoinHandle;

use anyhow::{anyhow, Result};
use windows::core::{w, Interface, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::*;

use knips_core::RgbaImage;

use super::gfx::{self, Factories};
use super::{brand, layout};
use super::{FrameColor, IRect};

/// Dauerhafter Rahmen; schließt beim Drop (WM_CLOSE an den Fensterthread, dann Join).
pub struct FrameWindow {
    /// HWND als Zahl (HWND ist nicht `Send`).
    hwnd: isize,
    thread: Option<JoinHandle<()>>,
}

impl FrameWindow {
    /// `rect`: aufgenommener Bereich, global, physische Pixel.
    pub fn show(rect: IRect, color: FrameColor) -> Result<FrameWindow> {
        let (tx, rx) = mpsc::channel::<std::result::Result<isize, String>>();
        let thread = std::thread::Builder::new()
            .name("knips-frame".into())
            .spawn(move || frame_thread(rect, color, tx))
            .map_err(|e| anyhow!("Rahmen-Thread: {e}"))?;
        match rx.recv() {
            Ok(Ok(hwnd)) => Ok(FrameWindow { hwnd, thread: Some(thread) }),
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(anyhow!("Rahmen: {e}"))
            }
            Err(_) => {
                let _ = thread.join();
                Err(anyhow!("Rahmen-Thread beendet"))
            }
        }
    }
}

impl Drop for FrameWindow {
    fn drop(&mut self) {
        unsafe {
            // Schlägt fehl, wenn das Fenster schon weg ist — dann endet der Thread ohnehin.
            let _ = PostMessageW(Some(HWND(self.hwnd as *mut c_void)), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

static CLASS_ONCE: Once = Once::new();
const CLASS_NAME: PCWSTR = w!("KnipsFrameWindow");

unsafe extern "system" fn frame_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_NCHITTEST => LRESULT(-1), // HTTRANSPARENT
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_DESTROY => {
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp), // WM_CLOSE → DestroyWindow
        }
    }
}

fn frame_thread(rect: IRect, color: FrameColor, tx: mpsc::Sender<std::result::Result<isize, String>>) {
    unsafe {
        let _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let hwnd = match create_and_draw(rect, color) {
            Ok(h) => h,
            Err(e) => {
                let _ = tx.send(Err(e.to_string()));
                return;
            }
        };
        if tx.send(Ok(hwnd.0 as isize)).is_err() {
            // Aufrufer weg: Fenster gleich wieder schließen.
            let _ = DestroyWindow(hwnd);
        }
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            DispatchMessageW(&msg);
        }
    }
}

unsafe fn create_and_draw(rect: IRect, color: FrameColor) -> Result<HWND> {
    unsafe {
        let hinst = GetModuleHandleW(None).map(|h| HINSTANCE(h.0)).unwrap_or_default();
        CLASS_ONCE.call_once(|| {
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(frame_proc),
                hInstance: hinst,
                lpszClassName: CLASS_NAME,
                ..Default::default()
            };
            RegisterClassExW(&wc);
        });

        // Skalierung des Monitors, auf dem der Bereich liegt
        let center = POINT { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
        let hmon = MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST);
        let (mut dx, mut dy) = (96u32, 96u32);
        if GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dx, &mut dy).is_err() || dx == 0 {
            dx = 96;
        }
        let dpi = dx as f32;
        let scale = dx as f64 / 96.0;
        let (wx, wy, ww, wh, _) = layout::frame_window_rect((rect.x, rect.y, rect.width, rect.height), scale);

        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            CLASS_NAME,
            w!("Knips Rahmen"),
            WS_POPUP,
            wx,
            wy,
            ww,
            wh,
            None,
            None,
            Some(hinst),
            None,
        )
        .map_err(|e| anyhow!("Fenster: {e}"))?;

        if let Err(e) = draw_layered(hwnd, (wx, wy, ww, wh), dpi, scale, color) {
            let _ = DestroyWindow(hwnd);
            return Err(e);
        }
        // Aus Aufnahmen ausschließen (bei Layered-Fenstern nicht überall möglich → nur warnen). Vor
        // Windows 10 2004 nicht: Dort wäre das ganze Fenster — samt durchsichtigem Inneren, also dem
        // aufgenommenen Bereich — in der Aufnahme schwarz. Der Rahmen liegt außerhalb des Bereichs.
        crate::win::capture::set_excluded(hwnd, "Rahmen");
        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        let _ = SetWindowPos(hwnd, Some(HWND_TOPMOST), wx, wy, ww, wh, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        Ok(hwnd)
    }
}

/// Rahmen zeichnen (Fenstergröße `bw` × `bh` in pt): dunkler Saum, darauf die Strichlinie 2 pt (Strich 6 / Lücke 4)
/// 1 pt innerhalb der Kante — Aufnahme-Rot bei Bildschirmaufnahmen, Königsblau hell beim Scroll-Screenshot.
unsafe fn draw_frame(rt: &ID2D1RenderTarget, f: &Factories, bw: f64, bh: f64, color: FrameColor) -> windows::core::Result<()> {
    unsafe {
        let line = match color {
            FrameColor::Recording => brand::FRAME_RECORDING,
            FrameColor::Scroll => brand::FRAME_SCROLL,
        };
        let brush = rt.CreateSolidColorBrush(&gfx::color(line), None)?;
        let halo = rt.CreateSolidColorBrush(&gfx::color(brand::FRAME_HALO), None)?;
        // Strichlängen in D2D = Vielfache der Linienbreite: 6 pt Strich / 4 pt Lücke.
        let dashed = |width: f32| {
            let sp = D2D1_STROKE_STYLE_PROPERTIES {
                startCap: D2D1_CAP_STYLE_FLAT,
                endCap: D2D1_CAP_STYLE_FLAT,
                dashCap: D2D1_CAP_STYLE_FLAT,
                lineJoin: D2D1_LINE_JOIN_MITER,
                miterLimit: 10.0,
                dashStyle: D2D1_DASH_STYLE_CUSTOM,
                dashOffset: 0.0,
            };
            f.d2d.CreateStrokeStyle(&sp, Some(&[6.0 / width, 4.0 / width]))
        };
        let (line_w, halo_w) = (FRAME_WIDTH, FRAME_WIDTH + 1.5);
        let style = dashed(line_w)?;
        let halo_style = dashed(halo_w)?;
        let path = D2D_RECT_F { left: 1.0, top: 1.0, right: (bw - 1.0) as f32, bottom: (bh - 1.0) as f32 };

        rt.BeginDraw();
        rt.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));
        // Saum bleibt innerhalb der 3 pt Abstand zum Bereich (1 pt + 1,75 pt).
        rt.DrawRectangle(&path, &halo, halo_w, &halo_style);
        rt.DrawRectangle(&path, &brush, line_w, &style);
        rt.EndDraw(None, None)
    }
}

const FRAME_WIDTH: f32 = 2.0;

/// Rahmen offscreen (Selbsttest): gleiche Zeichnung auf einer WIC-Bitmap. COM muss initialisiert sein.
pub fn render_offscreen(area: (i32, i32), scale: f64, color: FrameColor) -> Result<RgbaImage> {
    let (_, _, ww, wh, _) = layout::frame_window_rect((0, 0, area.0, area.1), scale);
    let f = Factories::new().map_err(|e| anyhow!("Direct2D: {e}"))?;
    let bmp = gfx::wic_bitmap(ww as u32, wh as u32).map_err(|e| anyhow!("WIC: {e}"))?;
    {
        let rt = gfx::wic_target(&f, &bmp, (96.0 * scale) as f32).map_err(|e| anyhow!("Renderziel: {e}"))?;
        unsafe { draw_frame(&rt, &f, ww as f64 / scale, wh as f64 / scale, color) }.map_err(|e| anyhow!("Zeichnen: {e}"))?;
    }
    gfx::read_wic(&bmp, ww as u32, wh as u32).map_err(|e| anyhow!("Lesen: {e}"))
}

/// Rahmen mit Direct2D in eine 32-Bit-DIB (vormultipliziertes Alpha) zeichnen und per UpdateLayeredWindow setzen.
unsafe fn draw_layered(hwnd: HWND, win: (i32, i32, i32, i32), dpi: f32, scale: f64, color: FrameColor) -> Result<()> {
    unsafe {
        let (wx, wy, ww, wh) = win;
        let memdc = CreateCompatibleDC(None);
        if memdc.is_invalid() {
            return Err(anyhow!("Speicher-DC"));
        }
        let bi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: ww,
                biHeight: -wh, // von oben nach unten
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut c_void = std::ptr::null_mut();
        let dib = match CreateDIBSection(Some(memdc), &bi, DIB_RGB_COLORS, &mut bits, None, 0) {
            Ok(b) => b,
            Err(e) => {
                let _ = DeleteDC(memdc);
                return Err(anyhow!("DIB: {e}"));
            }
        };
        let old = SelectObject(memdc, dib.into());

        let result = (|| -> Result<()> {
            let f = Factories::new().map_err(|e| anyhow!("Direct2D: {e}"))?;
            let props = D2D1_RENDER_TARGET_PROPERTIES {
                r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
                pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED },
                dpiX: dpi,
                dpiY: dpi,
                usage: D2D1_RENDER_TARGET_USAGE_GDI_COMPATIBLE,
                ..Default::default()
            };
            let dcrt = f.d2d.CreateDCRenderTarget(&props)?;
            dcrt.BindDC(memdc, &RECT { left: 0, top: 0, right: ww, bottom: wh })?;
            let rt: ID2D1RenderTarget = dcrt.cast()?;
            rt.SetDpi(dpi, dpi);
            draw_frame(&rt, &f, ww as f64 / scale, wh as f64 / scale, color)?;
            Ok(())
        })();

        let update = if result.is_ok() {
            let ptdst = POINT { x: wx, y: wy };
            let size = SIZE { cx: ww, cy: wh };
            let ptsrc = POINT { x: 0, y: 0 };
            let blend = BLENDFUNCTION { BlendOp: AC_SRC_OVER as u8, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: AC_SRC_ALPHA as u8 };
            UpdateLayeredWindow(hwnd, None, Some(&ptdst), Some(&size), Some(memdc), Some(&ptsrc), COLORREF(0), Some(&blend), ULW_ALPHA)
                .map_err(|e| anyhow!("UpdateLayeredWindow: {e}"))
        } else {
            Ok(())
        };

        // Die Ebene hat die Pixel kopiert; GDI-Objekte jetzt freigeben (Renderziel ist im Closure schon gefallen).
        SelectObject(memdc, old);
        let _ = DeleteObject(dib.into());
        let _ = DeleteDC(memdc);
        result?;
        update
    }
}
