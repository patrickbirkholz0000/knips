//! Direct3D-/DXGI-/Graphics-Capture-Bausteine für `capture`: Desktop Duplication (schnell, ein
//! Bild pro Bildschirm) und Windows.Graphics.Capture (Rückfall, Fenster, eigene Fenster).

use std::ffi::c_void;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use knips_core::RgbaImage;
use windows::core::{factory, Interface};
use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession};
use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use windows::Graphics::DirectX::DirectXPixelFormat;
use windows::Graphics::SizeInt32;
use windows::Win32::Foundation::{HMODULE, HWND};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, D3D11_BOX, D3D11_CPU_ACCESS_READ,
    D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_SDK_VERSION,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter, IDXGIDevice, IDXGIFactory1, IDXGIOutput, IDXGIOutput1, IDXGIOutput5,
    IDXGIOutputDuplication, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
};
use windows::Win32::Graphics::Gdi::HMONITOR;
use windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;

use crate::types::{IRect, Monitor};

/// Neues Direct3D-Gerät (BGRA-fähig), optional auf einem bestimmten Adapter.
pub fn create_device(adapter: Option<&IDXGIAdapter>) -> Result<(ID3D11Device, ID3D11DeviceContext)> {
    let mut dev: Option<ID3D11Device> = None;
    let mut ctx: Option<ID3D11DeviceContext> = None;
    // SAFETY: Ausgabezeiger zeigen auf lokale Optionen; der Adapter lebt über den Aufruf.
    unsafe {
        D3D11CreateDevice(
            adapter,
            if adapter.is_some() { D3D_DRIVER_TYPE_UNKNOWN } else { D3D_DRIVER_TYPE_HARDWARE },
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut dev),
            None,
            Some(&mut ctx),
        )?;
    }
    match (dev, ctx) {
        (Some(d), Some(c)) => Ok((d, c)),
        _ => bail!("Direct3D-Gerät fehlt"),
    }
}

/// Liest Ausschnitte von GPU-Texturen über eine wiederverwendete Staging-Textur auf die CPU.
pub struct Reader {
    dev: ID3D11Device,
    ctx: ID3D11DeviceContext,
    staging: Option<(ID3D11Texture2D, u32, u32)>,
}

impl Reader {
    pub fn new(dev: ID3D11Device, ctx: ID3D11DeviceContext) -> Self {
        Self { dev, ctx, staging: None }
    }

    fn staging(&mut self, w: u32, h: u32) -> Result<ID3D11Texture2D> {
        if let Some((t, sw, sh)) = &self.staging {
            if *sw == w && *sh == h {
                return Ok(t.clone());
            }
        }
        let desc = D3D11_TEXTURE2D_DESC {
            Width: w,
            Height: h,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: 0,
        };
        let mut tex: Option<ID3D11Texture2D> = None;
        // SAFETY: desc/Ausgabe sind lokal und gültig.
        unsafe { self.dev.CreateTexture2D(&desc, None, Some(&mut tex))? };
        let tex = tex.ok_or_else(|| anyhow!("Staging-Textur fehlt"))?;
        self.staging = Some((tex.clone(), w, h));
        Ok(tex)
    }

    /// Ausschnitt `(x, y, w, h)` der Textur als RGBA. Der Ausschnitt wird auf die Textur begrenzt.
    pub fn read(&mut self, src: &ID3D11Texture2D, rect: Option<IRect>, opaque: bool) -> Result<RgbaImage> {
        let mut sd = D3D11_TEXTURE2D_DESC::default();
        // SAFETY: sd ist gültig.
        unsafe { src.GetDesc(&mut sd) };
        let full = IRect::new(0, 0, sd.Width as i32, sd.Height as i32);
        let r = match rect {
            Some(r) => r.intersection(&full).ok_or_else(|| anyhow!("Ausschnitt außerhalb des Bildschirms"))?,
            None => full,
        };
        let (w, h) = (r.width as u32, r.height as u32);
        let staging = self.staging(w, h)?;
        let b = D3D11_BOX { left: r.x as u32, top: r.y as u32, front: 0, right: r.right() as u32, bottom: r.bottom() as u32, back: 1 };
        // SAFETY: Staging und Quelle sind gleichformatige 2D-Texturen; Map/Unmap sind gepaart, die
        // Pixel werden vor Unmap kopiert (from_bgra erzeugt ein eigenes Bild).
        unsafe {
            self.ctx.CopySubresourceRegion(&staging, 0, 0, 0, 0, src, 0, Some(&b));
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            self.ctx.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut m))?;
            let stride = m.RowPitch as usize;
            let bytes = std::slice::from_raw_parts(m.pData as *const u8, stride * h as usize);
            let img = knips_core::imageops::from_bgra(w, h, stride, bytes, opaque);
            self.ctx.Unmap(&staging, 0);
            Ok(img)
        }
    }
}

// ---------------------------------------------------------------- Desktop Duplication

/// Adapter + Ausgabe, die zu einem Monitor gehören (über `DXGI_OUTPUT_DESC.Monitor`).
fn find_output(monitor: &Monitor) -> Result<(IDXGIAdapter, IDXGIOutput)> {
    // SAFETY: reine COM-Aufzählung.
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1()?;
        let mut i = 0;
        while let Ok(adapter) = factory.EnumAdapters1(i) {
            i += 1;
            let mut j = 0;
            while let Ok(out) = adapter.EnumOutputs(j) {
                j += 1;
                if let Ok(desc) = out.GetDesc() {
                    if desc.Monitor.0 as isize == monitor.id {
                        return Ok((adapter.cast::<IDXGIAdapter>()?, out));
                    }
                }
            }
        }
    }
    bail!("keine DXGI-Ausgabe für {}", monitor.name)
}

/// Was `AcquireNextFrame` zu einem Bild meldet.
#[derive(Clone, Copy, Debug, Default)]
pub struct DdaFrame {
    /// Zeitstempel des letzten Desktop-Bilds. 0 = die Meldung bringt kein neues Desktop-Bild (nur der
    /// Mauszeiger hat sich geändert) — direkt nach `DuplicateOutput` ist die Textur dann noch leer.
    pub last_present: i64,
    /// Bildwechsel seit dem letzten abgeholten Bild.
    pub accumulated: u32,
    /// Mauszeiger bewegt bzw. Form geändert.
    pub pointer: bool,
}

impl DdaFrame {
    /// Bringt die Meldung ein Desktop-Bild?
    pub fn has_image(&self) -> bool {
        self.last_present != 0
    }
}

/// Ergebnis von `Dda::acquire`.
pub enum DdaGrab {
    /// Bis zum Zeitlimit nichts Neues.
    Timeout,
    /// Meldung mit Textur (auch ohne neues Desktop-Bild, siehe `DdaFrame::has_image`).
    Frame(DdaFrame, RgbaImage),
}

/// Eine Desktop-Duplication-Sitzung für einen Monitor.
pub struct Dda {
    output: IDXGIOutput,
    dup: IDXGIOutputDuplication,
    dev: ID3D11Device,
    reader: Reader,
}

// SAFETY: Eine Sitzung wird immer nur von einem Thread gleichzeitig benutzt (Aufrufer hält `&mut`).
unsafe impl Send for Dda {}

fn duplicate(output: &IDXGIOutput, dev: &ID3D11Device) -> Result<IDXGIOutputDuplication> {
    // SAFETY: COM-Aufrufe mit gültigen Objekten.
    unsafe {
        // Bevorzugt DuplicateOutput1 mit BGRA: HDR-Desktops werden dann in SDR gewandelt.
        if let Ok(o5) = output.cast::<IDXGIOutput5>() {
            if let Ok(d) = o5.DuplicateOutput1(dev, 0, &[DXGI_FORMAT_B8G8R8A8_UNORM]) {
                return Ok(d);
            }
        }
        let o1: IDXGIOutput1 = output.cast()?;
        Ok(o1.DuplicateOutput(dev)?)
    }
}

impl Dda {
    pub fn open(monitor: &Monitor) -> Result<Dda> {
        let (adapter, output) = find_output(monitor)?;
        let (dev, ctx) = create_device(Some(&adapter))?;
        let dup = duplicate(&output, &dev)?;
        // SAFETY: desc ist gültig.
        let desc = unsafe { dup.GetDesc() };
        // 0 = unbestimmt, 1 = Identität. Gedrehte Anzeigen liefern ein gedrehtes Bild — die
        // geht über Graphics Capture, das die Drehung selbst erledigt.
        if desc.Rotation.0 > 1 {
            bail!("Anzeige ist gedreht");
        }
        if desc.ModeDesc.Width as i32 != monitor.rect.width || desc.ModeDesc.Height as i32 != monitor.rect.height {
            bail!("Duplication-Größe weicht vom Monitor ab");
        }
        Ok(Dda {
            output,
            dup,
            dev: dev.clone(),
            reader: Reader::new(dev, ctx),
        })
    }

    /// Wartet bis `timeout_ms` auf eine Meldung und liest die Textur (auch wenn die Meldung kein neues
    /// Desktop-Bild bringt — dann zeigt die Textur den alten Stand, direkt nach dem Öffnen nichts).
    pub fn acquire(&mut self, rect: Option<IRect>, timeout_ms: u32) -> Result<DdaGrab> {
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut res = None;
        // SAFETY: info/res sind lokal; ReleaseFrame folgt auf jedes erfolgreiche Acquire.
        let acquired = unsafe { self.dup.AcquireNextFrame(timeout_ms, &mut info, &mut res) };
        match acquired {
            Ok(()) => {
                let frame = DdaFrame {
                    last_present: info.LastPresentTime,
                    accumulated: info.AccumulatedFrames,
                    pointer: info.LastMouseUpdateTime != 0,
                };
                let out = (|| -> Result<RgbaImage> {
                    let res = res.ok_or_else(|| anyhow!("kein Bild"))?;
                    let tex: ID3D11Texture2D = res.cast()?;
                    self.reader.read(&tex, rect, true)
                })();
                // SAFETY: gepaart mit dem erfolgreichen AcquireNextFrame.
                unsafe {
                    let _ = self.dup.ReleaseFrame();
                }
                out.map(|img| DdaGrab::Frame(frame, img))
            }
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => Ok(DdaGrab::Timeout),
            Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                // Auflösungswechsel, UAC, Sperrbildschirm: neu aufsetzen, nächster Versuch liefert wieder.
                self.dup = duplicate(&self.output, &self.dev)?;
                Ok(DdaGrab::Timeout)
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Wartet bis `timeout_ms` auf ein Bild. `None` = nichts Neues. Der erste Aufruf nach dem
    /// Öffnen liefert sofort den aktuellen Desktop.
    pub fn grab(&mut self, rect: Option<IRect>, timeout_ms: u32) -> Result<Option<RgbaImage>> {
        match self.acquire(rect, timeout_ms)? {
            DdaGrab::Frame(_, img) => Ok(Some(img)),
            DdaGrab::Timeout => Ok(None),
        }
    }
}

// ---------------------------------------------------------------- Windows.Graphics.Capture

pub fn item_for_monitor(id: isize) -> Result<GraphicsCaptureItem> {
    let interop = factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
    // SAFETY: HMONITOR kommt aus der Aufzählung; ungültige Handles ergeben einen Fehler.
    Ok(unsafe { interop.CreateForMonitor::<GraphicsCaptureItem>(HMONITOR(id as *mut c_void))? })
}

pub fn item_for_window(hwnd: isize) -> Result<GraphicsCaptureItem> {
    let interop = factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
    // SAFETY: ungültige HWND ergeben einen Fehler.
    Ok(unsafe { interop.CreateForWindow::<GraphicsCaptureItem>(HWND(hwnd as *mut c_void))? })
}

/// Laufende Graphics-Capture-Sitzung (freier Thread-Pool, kein Dispatcher nötig).
pub struct Wgc {
    pool: Direct3D11CaptureFramePool,
    session: GraphicsCaptureSession,
    reader: Reader,
}

// SAFETY: Frame-Pool und Sitzung sind agile WinRT-Objekte; der Reader wird nur über `&mut self` benutzt.
unsafe impl Send for Wgc {}

impl Wgc {
    pub fn start(item: &GraphicsCaptureItem) -> Result<Wgc> {
        if !GraphicsCaptureSession::IsSupported()? {
            bail!("Windows Graphics Capture wird nicht unterstützt");
        }
        let (dev, ctx) = create_device(None)?;
        let dxgi: IDXGIDevice = dev.cast()?;
        // SAFETY: dxgi ist gültig.
        let d3d: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi)? }.cast()?;
        let size: SizeInt32 = item.Size()?;
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            &d3d,
            DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2,
            SizeInt32 { Width: size.Width.max(1), Height: size.Height.max(1) },
        )?;
        let session = pool.CreateCaptureSession(item)?;
        // Neuere Windows-Versionen: Mauszeiger und gelben Rahmen abschalten; Fehler sind egal.
        let _ = session.SetIsCursorCaptureEnabled(false);
        let _ = session.SetIsBorderRequired(false);
        session.StartCapture()?;
        Ok(Wgc { pool, session, reader: Reader::new(dev, ctx) })
    }

    /// Neuestes Bild (ältere werden verworfen), wartet bis `timeout_ms`. Liefert Bild und Inhaltsgröße.
    pub fn grab(&mut self, rect: Option<IRect>, timeout_ms: u64, opaque: bool) -> Result<Option<(RgbaImage, (i32, i32))>> {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        loop {
            let mut latest = None;
            while let Ok(f) = self.pool.TryGetNextFrame() {
                latest = Some(f);
            }
            if let Some(frame) = latest {
                let content = frame.ContentSize()?;
                let access: IDirect3DDxgiInterfaceAccess = frame.Surface()?.cast()?;
                // SAFETY: das Surface gehört zu einer ID3D11Texture2D.
                let tex: ID3D11Texture2D = unsafe { access.GetInterface()? };
                let mut desc = D3D11_TEXTURE2D_DESC::default();
                // SAFETY: desc ist gültig.
                unsafe { tex.GetDesc(&mut desc) };
                let valid = IRect::new(0, 0, content.Width.min(desc.Width as i32), content.Height.min(desc.Height as i32));
                let want = match rect {
                    Some(r) => r.intersection(&valid),
                    None => Some(valid),
                };
                let img = match want {
                    Some(r) => self.reader.read(&tex, Some(r), opaque),
                    None => Err(anyhow!("Ausschnitt außerhalb des Bildes")),
                };
                let _ = frame.Close();
                return img.map(|i| Some((i, (content.Width, content.Height))));
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            std::thread::sleep(Duration::from_millis(3));
        }
    }
}

impl Drop for Wgc {
    fn drop(&mut self) {
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}
