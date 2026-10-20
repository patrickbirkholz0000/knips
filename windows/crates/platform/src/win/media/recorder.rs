//! Bildschirmaufnahme: Windows.Graphics.Capture → Ausschnitt/Skalierung/NV12 auf der CPU →
//! IMFSinkWriter (MP4). Optional Mikrofon (Media Foundation, AAC) und Klick-Anzeige.
//!
//! **Weg: CPU.** Pro Bild wird nur der aufgenommene Ausschnitt per `CopySubresourceRegion` in eine
//! Staging-Textur kopiert, dann mehrfädig auf Ausgabegröße gemittelt und nach NV12 gewandelt.
//! Das ist langsamer als ein D3D11-Videoprozessor, aber unabhängig von Treibern; die Klickringe
//! werden dabei direkt in die Bildpunkte gezeichnet (bei einem GPU-Weg müssten sie als Overlay
//! entstehen).
//!
//! Threads: `session` (Hauptschleife, Kodierung), Fangthread-Pool von WGC (nur Weiterreichen),
//! optional `mic` und `hook` (Maus-Hook mit eigener Nachrichtenschleife).

use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use parking_lot::Mutex;
use windows::core::{IInspectable, Interface};
use windows::Foundation::TypedEventHandler;
use windows::Graphics::Capture::{Direct3D11CaptureFrame, Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession};
use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use windows::Graphics::DirectX::DirectXPixelFormat;
use windows::Graphics::SizeInt32;
use windows::Win32::Foundation::{HINSTANCE, HMODULE, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::IDXGIDevice;
use windows::Win32::Graphics::Gdi::HMONITOR;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;
use windows::Win32::UI::WindowsAndMessaging::*;

use super::pure::{self, AudioClock, FrameGate, Gate, HoldSequencer};
use super::util::*;
use super::writer::{Mp4Writer, VideoSpec};
use super::RecordOptions;
use crate::types::IRect;

const NO_FRAMES: &str = "Es wurde kein einziges Bild aufgenommen.";
const CLICK_TICKS: i64 = (pure::CLICK_SECS * pure::TICKS as f64) as i64;
const NOT_SET: i64 = i64::MIN;

enum Msg {
    Frame(SendCom<Direct3D11CaptureFrame>),
    Closed,
    Click { ts: i64, x: i32, y: i32 },
    Stop(i64),
    Cancel,
}

type OnError = Arc<dyn Fn(String) + Send + Sync>;
type WriterSlot = Arc<Mutex<Option<Mp4Writer>>>;
/// Hinweise, die die Aufnahme nicht abbrechen (Mikrofon fehlt/verweigert) — für die Oberfläche.
type Warnings = Arc<Mutex<Vec<String>>>;

/// Mikrofon nicht nutzbar: Kurzfassung für die Einblendung steht in der App, hier die Ursache.
fn mic_warning(e: &anyhow::Error) -> String {
    let detail = format!("{e:#}");
    // E_ACCESSDENIED: Datenschutz-Einstellung (Mikrofon, „Desktop-Apps den Zugriff erlauben“) ist aus.
    if detail.contains("0x80070005") {
        format!("Windows verweigert den Zugriff auf das Mikrofon ({detail}).")
    } else {
        format!("Das Mikrofon ließ sich nicht öffnen ({detail}).")
    }
}

/// Bildschirmaufnahme (Windows.Graphics.Capture → Media Foundation, H.264/HEVC-MP4, AAC-Mikro).
pub struct Recorder {
    tx: Sender<Msg>,
    join: Option<JoinHandle<std::result::Result<f64, String>>>,
    warnings: Warnings,
}

impl Recorder {
    /// `on_error` kommt, wenn die Aufnahme von selbst abbricht (Monitor weg, Encoder-Fehler).
    pub fn start(opts: RecordOptions, on_error: Box<dyn Fn(String) + Send + Sync>) -> Result<Recorder> {
        if opts.width < 2 || opts.height < 2 || opts.rect.width < 1 || opts.rect.height < 1 {
            bail!("Der Aufnahmebereich ist leer.");
        }
        let on_error: OnError = Arc::from(on_error);
        let (tx, rx) = channel::<Msg>();
        let (init_tx, init_rx) = channel::<std::result::Result<(), String>>();
        let tx2 = tx.clone();
        let warnings: Warnings = Arc::new(Mutex::new(Vec::new()));
        let warnings2 = warnings.clone();
        let join = std::thread::Builder::new()
            .name("knips-recorder".into())
            .spawn(move || session_main(opts, on_error, warnings2, tx2, rx, init_tx))
            .map_err(|e| anyhow!("Aufnahme-Thread: {e}"))?;
        match init_rx.recv_timeout(Duration::from_secs(20)) {
            Ok(Ok(())) => Ok(Recorder { tx, join: Some(join), warnings }),
            Ok(Err(m)) => {
                let _ = join.join();
                bail!("{m}")
            }
            Err(_) => {
                let _ = tx.send(Msg::Cancel);
                bail!("Die Aufnahme konnte nicht rechtzeitig gestartet werden.")
            }
        }
    }

    /// Beendet und schreibt die Datei fertig; liefert die Dauer in Sekunden.
    pub fn stop(mut self) -> Result<f64> {
        let _ = self.tx.send(Msg::Stop(qpc_100ns()));
        let join = self.join.take().ok_or_else(|| anyhow!("Die Aufnahme läuft nicht."))?;
        match join.join() {
            Ok(Ok(d)) => Ok(d),
            Ok(Err(m)) => Err(anyhow!(m)),
            Err(_) => Err(anyhow!("Video konnte nicht geschrieben werden: Aufnahme-Thread abgestürzt")),
        }
    }

    /// Verwirft die Aufnahme und löscht die Datei.
    pub fn cancel(mut self) {
        self.shutdown_cancel();
    }

    /// Hinweise ohne Abbruch, z. B. „Mikrofon verweigert — Video ohne Ton“ (beim Start oder später).
    pub fn warnings(&self) -> Vec<String> {
        self.warnings.lock().clone()
    }

    fn shutdown_cancel(&mut self) {
        if let Some(j) = self.join.take() {
            let _ = self.tx.send(Msg::Cancel);
            let _ = j.join();
        }
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        self.shutdown_cancel();
    }
}

fn session_main(
    opts: RecordOptions,
    on_error: OnError,
    warnings: Warnings,
    tx: Sender<Msg>,
    rx: Receiver<Msg>,
    init: Sender<std::result::Result<(), String>>,
) -> std::result::Result<f64, String> {
    let _com = match enter() {
        Ok(c) => c,
        Err(e) => {
            let m = format!("{e:#}");
            let _ = init.send(Err(m.clone()));
            return Err(m);
        }
    };
    let path = opts.path.clone();
    let mut s = match Session::new(opts, on_error, warnings, tx) {
        Ok(s) => s,
        Err(e) => {
            let m = format!("Die Aufnahme konnte nicht gestartet werden: {e:#}");
            log::error!("{m}");
            let _ = std::fs::remove_file(&path);
            let _ = init.send(Err(m.clone()));
            return Err(m);
        }
    };
    let _ = init.send(Ok(()));
    s.run(rx)
}

struct Click {
    ts: i64,
    x: i32,
    y: i32,
}

struct MicHandle {
    stop: Arc<AtomicBool>,
    done: Receiver<()>,
}

struct HookHandle {
    thread_id: u32,
    join: JoinHandle<()>,
}

struct Session {
    opts: RecordOptions,
    on_error: OnError,
    // Aufnahme
    device: ID3D11Device,
    ctx: ID3D11DeviceContext,
    d3d: IDirect3DDevice,
    item: GraphicsCaptureItem,
    pool: Direct3D11CaptureFramePool,
    capture: GraphicsCaptureSession,
    pool_size: SizeInt32,
    tokens: (i64, i64),
    staging: Option<(ID3D11Texture2D, u32, u32)>,
    rect: IRect,
    dw: usize,
    dh: usize,
    // Bildablauf
    first_ts: Option<i64>,
    video_first: Arc<AtomicI64>,
    gate: FrameGate,
    seq: HoldSequencer,
    pending: Option<(Direct3D11CaptureFrame, i64)>,
    clean: Vec<u8>,
    have_clean: bool,
    scratch: Vec<u8>,
    nv12_held: Vec<u8>,
    nv12_next: Vec<u8>,
    clicks: Vec<Click>,
    ring_dirty: bool,
    // Ausgabe
    spec: VideoSpec,
    pcm: Option<SendCom<IMFMediaType>>,
    writer: WriterSlot,
    written: u32,
    failed: Option<String>,
    mic: Option<MicHandle>,
    hook: Option<HookHandle>,
}

impl Session {
    fn new(opts: RecordOptions, on_error: OnError, warnings: Warnings, tx: Sender<Msg>) -> Result<Self> {
        let (dw, dh) = (pure::even(opts.width) as usize, pure::even(opts.height) as usize);
        // Graphics Capture gibt es ab Windows 10 1803, Bildschirme/freie Threads ab 1903.
        if !GraphicsCaptureSession::IsSupported().unwrap_or(false) {
            bail!("Diese Windows-Version unterstützt keine Bildschirmaufnahme (Windows.Graphics.Capture, ab Windows 10 Version 1903).");
        }

        // Direct3D-Gerät (BGRA für Capture) und Mehrfädigkeitsschutz.
        let mut device: Option<ID3D11Device> = None;
        let mut ctx: Option<ID3D11DeviceContext> = None;
        // SAFETY: Ausgabezeiger zeigen auf lokale Optionen.
        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut ctx),
            )
        }
        .ctx("Direct3D-Gerät")?;
        let device = device.ok_or_else(|| anyhow!("Direct3D-Gerät fehlt"))?;
        let ctx = ctx.ok_or_else(|| anyhow!("Direct3D-Kontext fehlt"))?;
        // SAFETY: Schutz einschalten ist jederzeit erlaubt.
        unsafe {
            if let Ok(mt) = device.cast::<ID3D11Multithread>() {
                let _ = mt.SetMultithreadProtected(true);
            }
        }
        let dxgi: IDXGIDevice = device.cast().ctx("DXGI-Gerät")?;
        // SAFETY: `dxgi` ist gültig; Ergebnis wird sofort in ein WinRT-Gerät umgewandelt.
        let d3d: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi) }.ctx("WinRT-Gerät")?.cast().ctx("WinRT-Gerät")?;

        // Capture-Objekt für den Bildschirm.
        let interop = windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().ctx("Capture-Fabrik")?;
        // SAFETY: HMONITOR stammt aus der Monitorliste (Handle als Zahl).
        let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(HMONITOR(opts.monitor.id as *mut core::ffi::c_void)) }
            .map_err(|e| werr("Bildschirm kann nicht aufgenommen werden", e))?;
        let size = item.Size().ctx("Bildschirmgröße")?;

        let rect = opts
            .rect
            .intersection(&IRect::new(0, 0, size.Width, size.Height))
            .ok_or_else(|| anyhow!("Der Aufnahmebereich liegt außerhalb des Bildschirms."))?;

        // Mikrofon vorbereiten (bestimmt, ob der Schreiber eine Tonspur bekommt).
        let mic = if opts.microphone {
            match init_mic() {
                Ok(m) => Some(m),
                Err(e) => {
                    log::warn!("Mikrofon nicht verfügbar, Aufnahme ohne Ton: {e:#}");
                    warnings.lock().push(mic_warning(&e));
                    None
                }
            }
        } else {
            None
        };

        let fps = opts.fps.clamp(1, 120);
        let (w, h) = (dw as u32, dh as u32);
        // HEVC nur, wenn sich das Ergebnis auch lesen lässt (Encoder und Decoder, `media::hevc_available`).
        let spec = VideoSpec { w, h, fps, hevc: opts.hevc && super::hevc_available(), bitrate: 0, hardware: true };
        let spec = VideoSpec { bitrate: pure::bitrate(w, h, fps, spec.hevc), ..spec };
        let _ = std::fs::remove_file(&opts.path);
        let created = Mp4Writer::create_with_fallback(&opts.path, &spec, mic.as_ref().map(|m| &m.pcm.0))?;
        if opts.hevc && !created.hevc {
            log::warn!("HEVC nicht verfügbar, Aufnahme mit H.264");
        }
        let spec = VideoSpec { hevc: created.hevc, hardware: created.hardware, bitrate: pure::bitrate(w, h, fps, created.hevc), ..spec };
        let pcm_for_retry = mic.as_ref().map(|m| SendCom(m.pcm.0.clone()));
        let writer: WriterSlot = Arc::new(Mutex::new(Some(created.writer)));
        let audio_ok = created.audio;
        let video_first = Arc::new(AtomicI64::new(NOT_SET));

        // Aufnahme starten.
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, 4, size).ctx("Bildpuffer")?;
        let tx_frames = tx.clone();
        let t1 = pool
            .FrameArrived(&TypedEventHandler::<Direct3D11CaptureFramePool, IInspectable>::new(move |p, _| {
                if let Some(p) = p.as_ref() {
                    if let Ok(f) = p.TryGetNextFrame() {
                        let _ = tx_frames.send(Msg::Frame(SendCom(f)));
                    }
                }
                Ok(())
            }))
            .ctx("Bildereignis")?;
        let tx_closed = tx.clone();
        let t2 = item
            .Closed(&TypedEventHandler::<GraphicsCaptureItem, IInspectable>::new(move |_, _| {
                let _ = tx_closed.send(Msg::Closed);
                Ok(())
            }))
            .ctx("Schließereignis")?;
        let capture = pool.CreateCaptureSession(&item).ctx("Aufnahmesitzung")?;
        // Beides gibt es erst in neueren Windows-Versionen (Mauszeiger: IGraphicsCaptureSession2 ab
        // Windows 10 2004, Rahmen: IGraphicsCaptureSession3 ab Windows 11). Fehlt es, bleibt die
        // Vorgabe des Systems (Mauszeiger sichtbar, gelber Rahmen) — kein Grund, nicht aufzunehmen.
        if let Err(e) = capture.SetIsCursorCaptureEnabled(opts.show_cursor) {
            log::info!("Mauszeiger-Schalter nicht verfügbar ({}), Systemvorgabe bleibt", e.message().trim());
        }
        let _ = capture.SetIsBorderRequired(false);

        let mut s = Session {
            on_error,
            device,
            ctx,
            d3d,
            item,
            pool,
            capture,
            pool_size: size,
            tokens: (t1, t2),
            staging: None,
            rect,
            dw,
            dh,
            first_ts: None,
            video_first: video_first.clone(),
            gate: FrameGate::new(fps),
            seq: HoldSequencer::default(),
            pending: None,
            clean: vec![0; dw * dh * 4],
            have_clean: false,
            scratch: Vec::new(),
            nv12_held: vec![0; pure::nv12_len(dw, dh)],
            nv12_next: vec![0; pure::nv12_len(dw, dh)],
            clicks: Vec::new(),
            ring_dirty: false,
            spec,
            pcm: pcm_for_retry,
            writer: writer.clone(),
            written: 0,
            failed: None,
            mic: None,
            hook: None,
            opts,
        };
        // Maus-Hook (für Klickringe) und Mikrofon-Thread, bevor die ersten Bilder kommen.
        if s.opts.show_clicks {
            s.hook = start_hook(tx);
        }
        match mic {
            Some(m) if audio_ok => s.mic = Some(start_mic(m, writer, video_first, warnings)),
            Some(m) => {
                // Schreiber hat keine Tonspur bekommen: Gerät gleich wieder freigeben.
                warnings.lock().push("Der Ton ließ sich nicht kodieren (AAC-Encoder fehlt).".into());
                // SAFETY: Quelle wurde in `init_mic` geöffnet und nirgends sonst benutzt.
                unsafe {
                    let _ = m.source.Shutdown();
                }
            }
            None => {}
        }
        if let Err(e) = s.capture.StartCapture() {
            s.stop_capture();
            s.stop_helpers();
            s.discard();
            return Err(werr("Aufnahme starten", e));
        }
        Ok(s)
    }

    fn fail(&mut self, msg: String) {
        log::error!("{msg}");
        if self.failed.is_none() {
            self.failed = Some(msg.clone());
            (self.on_error)(msg);
        }
    }

    fn now_rel(&self) -> Option<i64> {
        self.first_ts.map(|f| qpc_100ns() - f)
    }

    fn click_active(&self, abs: i64) -> bool {
        self.clicks.iter().any(|c| abs - c.ts >= 0 && abs - c.ts < CLICK_TICKS)
    }

    /// Wartezeit bis zur nächsten Aktion ohne eintreffende Nachricht.
    fn timeout(&self) -> Option<Duration> {
        if self.failed.is_some() {
            return None;
        }
        let now = self.now_rel()?;
        let last = self.gate.last()?;
        let due = match &self.pending {
            Some((_, due)) => *due,
            None => {
                let animating = self.opts.show_clicks && self.have_clean && (self.ring_dirty || self.click_active(self.first_ts? + now));
                if !animating {
                    return None;
                }
                last + self.gate.interval()
            }
        };
        Some(Duration::from_nanos((due - now).max(0) as u64 * 100))
    }

    fn run(&mut self, rx: Receiver<Msg>) -> std::result::Result<f64, String> {
        loop {
            let msg = match self.timeout() {
                Some(d) => rx.recv_timeout(d),
                None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match msg {
                Ok(Msg::Frame(f)) => self.on_frame(f.0),
                Ok(Msg::Closed) => {
                    log::warn!("Aufnahmequelle wurde geschlossen");
                    (self.on_error)("Der aufgenommene Bildschirm wurde getrennt.".to_string());
                }
                Ok(Msg::Click { ts, x, y }) => self.clicks.push(Click { ts, x, y }),
                Ok(Msg::Stop(t)) => return self.finish(t, &rx),
                Ok(Msg::Cancel) | Err(RecvTimeoutError::Disconnected) => return self.abort(),
                Err(RecvTimeoutError::Timeout) => self.on_tick(),
            }
        }
    }

    // ───────────── Bilder ─────────────

    /// Nimmt ein Bild aus dem Fangpuffer entgegen und kümmert sich um dessen Freigabe.
    fn on_frame(&mut self, frame: Direct3D11CaptureFrame) {
        match self.handle_frame(&frame) {
            Ok(None) => {
                let _ = frame.Close();
            }
            // Zurückgestellt: das Bild bleibt offen, bis es fällig ist; ein älteres wird freigegeben.
            Ok(Some(due)) => {
                if let Some((old, _)) = self.pending.replace((frame, due)) {
                    let _ = old.Close();
                }
            }
            Err(e) => {
                let _ = frame.Close();
                self.fail(format!("Video konnte nicht geschrieben werden: {e:#}"));
            }
        }
    }

    /// `Some(fällig)` = Bild zurückstellen, `None` = verarbeitet bzw. verworfen.
    fn handle_frame(&mut self, frame: &Direct3D11CaptureFrame) -> Result<Option<i64>> {
        if self.failed.is_some() {
            return Ok(None);
        }
        let content = frame.ContentSize().ctx("Bildgröße")?;
        if content.Width != self.pool_size.Width || content.Height != self.pool_size.Height {
            // Auflösung des Bildschirms hat sich geändert: Puffer neu anlegen, dieses Bild auslassen.
            log::info!("Bildschirmgröße {}×{} → {}×{}", self.pool_size.Width, self.pool_size.Height, content.Width, content.Height);
            self.pool.Recreate(&self.d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, 4, content).ctx("Puffer neu anlegen")?;
            self.pool_size = content;
            return Ok(None);
        }
        let ts = frame.SystemRelativeTime().ctx("Bildzeit")?.Duration;
        let first = match self.first_ts {
            Some(f) => f,
            None => {
                self.first_ts = Some(ts);
                self.video_first.store(ts, Ordering::SeqCst);
                ts
            }
        };
        match self.gate.check(ts - first) {
            Gate::Emit(pts) => {
                if let Some((old, _)) = self.pending.take() {
                    let _ = old.Close();
                }
                self.render(frame)?;
                self.encode_clean(pts);
                Ok(None)
            }
            Gate::Defer(due) => Ok(Some(due)),
        }
    }

    fn on_tick(&mut self) {
        if self.failed.is_some() {
            return;
        }
        if let Some((frame, _)) = self.pending.take() {
            let pts = self.gate.emit_deferred();
            let r = self.render(&frame);
            let _ = frame.Close();
            match r {
                Ok(()) => self.encode_clean(pts),
                Err(e) => self.fail(format!("Video konnte nicht geschrieben werden: {e:#}")),
            }
        } else if let Some(now) = self.now_rel() {
            // Klick-Animation auf stehendem Bild: letztes Bild mit Ring (oder ohne, wenn vorbei) neu ausgeben.
            let pts = self.gate.emit_at(now);
            self.encode_clean(pts);
        }
    }

    /// Ausschnitt des Capture-Bildes auf der GPU in die Staging-Textur kopieren, auslesen und auf
    /// Ausgabegröße mitteln → `self.clean` (BGRA, dw × dh).
    fn render(&mut self, frame: &Direct3D11CaptureFrame) -> Result<()> {
        let surface = frame.Surface().ctx("Bildfläche")?;
        let access: IDirect3DDxgiInterfaceAccess = surface.cast().ctx("DXGI-Zugriff")?;
        // SAFETY: `GetInterface` liefert eine neue Referenz auf die zugrunde liegende Textur.
        let tex: ID3D11Texture2D = unsafe { access.GetInterface() }.ctx("Textur")?;
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        // SAFETY: gültiger Ausgabezeiger.
        unsafe { tex.GetDesc(&mut desc) };
        let region = self
            .rect
            .intersection(&IRect::new(0, 0, desc.Width as i32, desc.Height as i32))
            .ok_or_else(|| anyhow!("Aufnahmebereich außerhalb des Bildes"))?;
        let (rw, rh) = (region.width as u32, region.height as u32);

        if self.staging.as_ref().map(|(_, w, h)| (*w, *h)) != Some((rw, rh)) {
            let d = D3D11_TEXTURE2D_DESC {
                Width: rw,
                Height: rh,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };
            let mut t: Option<ID3D11Texture2D> = None;
            // SAFETY: Beschreibung und Ausgabezeiger sind gültig.
            unsafe { self.device.CreateTexture2D(&d, None, Some(&mut t)) }.ctx("Staging-Textur")?;
            self.staging = Some((t.ok_or_else(|| anyhow!("Staging-Textur fehlt"))?, rw, rh));
        }
        let staging = &self.staging.as_ref().ok_or_else(|| anyhow!("Staging-Textur fehlt"))?.0;
        let bx = D3D11_BOX {
            left: region.x as u32,
            top: region.y as u32,
            front: 0,
            right: region.right() as u32,
            bottom: region.bottom() as u32,
            back: 1,
        };
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        // SAFETY: Beide Texturen gehören zu `self.device`; die Box liegt innerhalb der Quelle (oben
        // geschnitten). Nach erfolgreichem Map wird bis zum Unmap nichts mit `?` verlassen.
        unsafe {
            self.ctx.CopySubresourceRegion(staging, 0, 0, 0, 0, &tex, 0, Some(&bx));
            self.ctx.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).ctx("Bild auslesen")?;
            let pitch = mapped.RowPitch as usize;
            let ok = !mapped.pData.is_null() && pitch >= rw as usize * 4;
            if ok {
                let src = std::slice::from_raw_parts(mapped.pData as *const u8, pitch * rh as usize);
                pure::crop_scale_bgra(src, pitch, (0, 0, rw as usize, rh as usize), &mut self.clean, self.dw, self.dh);
            }
            self.ctx.Unmap(staging, 0);
            if !ok {
                bail!("Ausgelesenes Bild ist ungültig");
            }
        }
        self.have_clean = true;
        Ok(())
    }

    /// `self.clean` (ggf. mit Klickringen) als NV12 an `pts` einreihen; das vorige Bild wird mit
    /// seiner Dauer geschrieben.
    fn encode_clean(&mut self, pts: i64) {
        if self.failed.is_some() || !self.have_clean {
            return;
        }
        let abs = self.first_ts.unwrap_or(0) + pts;
        self.clicks.retain(|c| abs - c.ts < 5 * pure::TICKS);
        let rings: Vec<(f64, f64, f64)> = if self.opts.show_clicks {
            let k = self.dw as f64 / self.opts.rect.width.max(1) as f64;
            let origin = (self.opts.monitor.rect.x + self.opts.rect.x, self.opts.monitor.rect.y + self.opts.rect.y);
            self.clicks
                .iter()
                .filter(|c| abs - c.ts >= 0 && abs - c.ts < CLICK_TICKS)
                .map(|c| ((c.x - origin.0) as f64 * k, (c.y - origin.1) as f64 * k, pure::ticks_to_secs(abs - c.ts)))
                .collect()
        } else {
            Vec::new()
        };
        let (dw, dh) = (self.dw, self.dh);
        if rings.is_empty() {
            pure::bgra_to_nv12(&self.clean, dw, dh, &mut self.nv12_next);
            self.ring_dirty = false;
        } else {
            self.scratch.clear();
            self.scratch.extend_from_slice(&self.clean);
            let radius = pure::CLICK_RADIUS_PT * self.opts.monitor.scale * k_scale(dw, self.opts.rect.width);
            for (x, y, age) in rings {
                pure::draw_click(&mut self.scratch, dw, dh, x, y, radius, age);
            }
            pure::bgra_to_nv12(&self.scratch, dw, dh, &mut self.nv12_next);
            self.ring_dirty = true;
        }
        if let Some((p, d)) = self.seq.push(pts) {
            self.write_held(p, d);
        }
        std::mem::swap(&mut self.nv12_held, &mut self.nv12_next);
    }

    /// Schreibt `nv12_held`. Scheitert gleich zu Beginn ein Hardware-Encoder, wird der Schreiber
    /// einmal ohne Hardware neu angelegt und das Bild wiederholt.
    fn write_held(&mut self, pts: i64, dur: i64) {
        if self.failed.is_some() {
            return;
        }
        let r = self.writer.lock().as_ref().map(|w| w.write_video(&self.nv12_held, pts, dur));
        let r = match r {
            Some(Err(e)) if self.spec.hardware && self.written < 12 => {
                log::warn!("Hardware-Encoder scheitert ({e:#}), wechsle auf Software");
                match self.reopen_software() {
                    Ok(()) => self.writer.lock().as_ref().map(|w| w.write_video(&self.nv12_held, pts, dur)),
                    Err(e2) => Some(Err(e2)),
                }
            }
            other => other,
        };
        match r {
            Some(Ok(())) => self.written += 1,
            Some(Err(e)) => self.fail(format!("Video konnte nicht geschrieben werden: {e:#}")),
            None => {}
        }
    }

    fn reopen_software(&mut self) -> Result<()> {
        let mut spec = self.spec.clone();
        spec.hardware = false;
        let mut slot = self.writer.lock();
        *slot = None; // alten Schreiber freigeben (schließt die Datei)
        let created = Mp4Writer::create_with_fallback(&self.opts.path, &spec, self.pcm.as_ref().map(|p| &p.0))?;
        self.spec = VideoSpec { hevc: created.hevc, hardware: false, ..spec };
        *slot = Some(created.writer);
        Ok(())
    }

    // ───────────── Ende ─────────────

    fn stop_capture(&mut self) {
        let _ = self.pool.RemoveFrameArrived(self.tokens.0);
        let _ = self.item.RemoveClosed(self.tokens.1);
        let _ = self.capture.Close();
        let _ = self.pool.Close();
        if let Some((f, _)) = self.pending.take() {
            let _ = f.Close();
        }
    }

    fn stop_helpers(&mut self) {
        if let Some(h) = self.hook.take() {
            // SAFETY: Thread-ID gehört zum Hook-Thread; WM_QUIT beendet dessen Nachrichtenschleife.
            unsafe {
                let _ = PostThreadMessageW(h.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
            }
            let _ = h.join.join();
        }
        if let Some(m) = self.mic.take() {
            m.stop.store(true, Ordering::SeqCst);
            // Höchstens zwei Sekunden warten; hängt das Gerät, läuft der Thread ins Leere.
            if m.done.recv_timeout(Duration::from_secs(2)).is_err() {
                log::warn!("Mikrofon-Thread beendet sich nicht");
            }
        }
    }

    fn finish(&mut self, stop_abs: i64, rx: &Receiver<Msg>) -> std::result::Result<f64, String> {
        self.stop_capture();
        // Bereits eingereihte Bilder noch verarbeiten.
        while let Ok(m) = rx.try_recv() {
            match m {
                Msg::Frame(f) => {
                    let ts = f.0.SystemRelativeTime().map(|t| t.Duration).unwrap_or(0);
                    if ts <= stop_abs || self.first_ts.is_none() {
                        self.on_frame(f.0);
                    } else {
                        let _ = f.0.Close();
                    }
                }
                Msg::Click { ts, x, y } => self.clicks.push(Click { ts, x, y }),
                _ => {}
            }
        }
        if let Some((frame, _)) = self.pending.take() {
            let pts = self.gate.emit_deferred();
            let r = self.render(&frame);
            let _ = frame.Close();
            if r.is_ok() {
                self.encode_clean(pts);
            }
        }
        self.stop_helpers();
        let Some(first) = self.first_ts else {
            self.discard();
            return Err(NO_FRAMES.to_string());
        };
        if let Some(m) = self.failed.clone() {
            self.discard();
            return Err(m);
        }
        let interval = self.gate.interval();
        let last = self.seq.held().unwrap_or(0);
        // Das letzte Bild bleibt bis zum Stopp stehen (bei stehendem Bildschirm kommen keine neuen).
        let end = pure::end_time(stop_abs - first, last, interval);
        if let Some((p, d)) = self.seq.finish(end, interval) {
            self.write_held(p, d);
        }
        if let Some(m) = self.failed.clone() {
            self.discard();
            return Err(m);
        }
        let writer = self.writer.lock().take();
        let res = match writer {
            Some(w) => w.finalize().map_err(|e| format!("Video konnte nicht geschrieben werden: {e:#}")),
            None => Err("Video konnte nicht geschrieben werden: Schreiber fehlt".to_string()),
        };
        match res {
            Ok(()) => Ok(pure::ticks_to_secs(end)),
            Err(m) => {
                let _ = std::fs::remove_file(&self.opts.path);
                Err(m)
            }
        }
    }

    fn abort(&mut self) -> std::result::Result<f64, String> {
        self.stop_capture();
        self.stop_helpers();
        self.discard();
        Err("Die Aufnahme wurde abgebrochen.".to_string())
    }

    /// Schreiber ohne Abschluss freigeben und die Datei löschen.
    fn discard(&mut self) {
        *self.writer.lock() = None;
        let _ = std::fs::remove_file(&self.opts.path);
    }
}

fn k_scale(dw: usize, rect_w: i32) -> f64 {
    dw as f64 / rect_w.max(1) as f64
}

// ───────────────────────── Mikrofon ─────────────────────────

struct MicSetup {
    reader: IMFSourceReader,
    source: IMFMediaSource,
    pcm: SendCom<IMFMediaType>,
    rate: u32,
    block: u32,
}

const AUDIO: u32 = MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32;

fn init_mic() -> Result<MicSetup> {
    let attrs = new_attrs(2)?;
    // SAFETY: Attribut- und Erzeugungsaufrufe auf gültigen Objekten.
    unsafe {
        attrs.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_GUID).ctx("Mikrofon-Typ")?;
        let source = MFCreateDeviceSource(&attrs).ctx("Mikrofon öffnen")?;
        let reader = match MFCreateSourceReaderFromMediaSource(&source, None::<&IMFAttributes>) {
            Ok(r) => r,
            Err(e) => {
                let _ = source.Shutdown();
                return Err(werr("Mikrofon-Reader", e));
            }
        };
        let r = (|| -> Result<(IMFMediaType, u32, u32)> {
            reader.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false).ctx("Ströme abwählen")?;
            reader.SetStreamSelection(AUDIO, true).ctx("Tonstrom wählen")?;
            let native = reader.GetNativeMediaType(AUDIO, 0).ok();
            let nrate = native.as_ref().and_then(|n| n.GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND).ok()).unwrap_or(48_000);
            let nch = native.as_ref().and_then(|n| n.GetUINT32(&MF_MT_AUDIO_NUM_CHANNELS).ok()).unwrap_or(1).clamp(1, 2);
            // Wunsch: 48 kHz mono 16 Bit; sonst Rate, dann Rate+Kanäle des Geräts.
            let mut last = anyhow!("kein Format");
            for (rate, ch) in [(48_000u32, 1u32), (nrate, 1), (nrate, nch)] {
                let t = new_type()?;
                t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio).ctx("Typ")?;
                t.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_PCM).ctx("Typ")?;
                t.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16).ctx("Typ")?;
                t.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, rate).ctx("Typ")?;
                t.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, ch).ctx("Typ")?;
                t.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, ch * 2).ctx("Typ")?;
                t.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * ch * 2).ctx("Typ")?;
                match reader.SetCurrentMediaType(AUDIO, None, &t) {
                    Ok(()) => {
                        let cur = reader.GetCurrentMediaType(AUDIO).ctx("Tontyp")?;
                        let rate = cur.GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND).unwrap_or(rate);
                        let block = cur.GetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT).unwrap_or(ch * 2).max(1);
                        return Ok((cur, rate, block));
                    }
                    Err(e) => last = werr("Tonformat", e),
                }
            }
            Err(last)
        })();
        match r {
            Ok((pcm, rate, block)) => Ok(MicSetup { reader, source, pcm: SendCom(pcm), rate, block }),
            Err(e) => {
                let _ = source.Shutdown();
                Err(e)
            }
        }
    }
}

fn start_mic(m: MicSetup, writer: WriterSlot, video_first: Arc<AtomicI64>, warnings: Warnings) -> MicHandle {
    let stop = Arc::new(AtomicBool::new(false));
    let (done_tx, done_rx) = channel::<()>();
    let stop2 = stop.clone();
    let m = SendCom(m);
    let spawned = std::thread::Builder::new().name("knips-mic".into()).spawn(move || {
        let m = m;
        let _com = com_init();
        if let Err(e) = mic_loop(&m.0, &writer, &stop2, &video_first) {
            warnings.lock().push(e);
        }
        // SAFETY: gibt das Gerät frei (Mikrofon-Symbol verschwindet).
        unsafe {
            let _ = m.0.source.Shutdown();
        }
        let _ = done_tx.send(());
    });
    if let Err(e) = spawned {
        log::warn!("Mikrofon-Thread: {e}");
    }
    MicHandle { stop, done: done_rx }
}

/// Liest bis `stop`. `Err` = Mikrofon ist unterwegs ausgefallen (Rest des Videos ohne Ton).
fn mic_loop(m: &MicSetup, writer: &WriterSlot, stop: &AtomicBool, video_first: &AtomicI64) -> std::result::Result<(), String> {
    let mut clock = AudioClock::default();
    while !stop.load(Ordering::SeqCst) {
        let mut flags = 0u32;
        let mut ts = 0i64;
        let mut sample: Option<IMFSample> = None;
        // SAFETY: Ausgabezeiger zeigen auf lokale Variablen; synchroner Aufruf.
        let r = unsafe { m.reader.ReadSample(AUDIO, 0, None, Some(&mut flags), Some(&mut ts), Some(&mut sample)) };
        if let Err(e) = r {
            log::warn!("Mikrofon-Lesefehler, Aufnahme geht ohne Ton weiter: {e}");
            return Err(mic_warning(&werr("Mikrofon lesen", e)));
        }
        if flags & MF_SOURCE_READERF_ERROR.0 as u32 != 0 || flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
            log::warn!("Mikrofon-Strom beendet (Flags {flags:#x})");
            return Err("Das Mikrofon wurde während der Aufnahme getrennt — ab dort fehlt der Ton.".into());
        }
        let Some(sample) = sample else { continue };
        let first = video_first.load(Ordering::SeqCst);
        if first == NOT_SET {
            continue; // vor dem ersten Videobild
        }
        // SAFETY: Lesezugriff auf die Probe.
        let bytes = unsafe { sample.GetTotalLength() }.unwrap_or(0) as i64;
        let dur = bytes / m.block as i64 * pure::TICKS / m.rate.max(1) as i64;
        let Some(pts) = clock.map(ts, dur, qpc_100ns(), first) else { continue };
        // SAFETY: Probe gehört uns; nur Zeit/Dauer setzen.
        let ok = unsafe { sample.SetSampleTime(pts).is_ok() && sample.SetSampleDuration(dur).is_ok() };
        if !ok {
            continue;
        }
        if let Some(w) = writer.lock().as_ref() {
            if let Err(e) = w.write_audio(&sample) {
                log::warn!("Ton konnte nicht geschrieben werden: {e:#}");
            }
        }
    }
    Ok(())
}

// ───────────────────────── Maus-Hook ─────────────────────────

static HOOK_TX: Mutex<Option<Sender<Msg>>> = Mutex::new(None);

unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let m = wparam.0 as u32;
        if m == WM_LBUTTONDOWN || m == WM_RBUTTONDOWN || m == WM_MBUTTONDOWN {
            // SAFETY: Bei HC_ACTION zeigt lParam auf eine gültige MSLLHOOKSTRUCT.
            let info = unsafe { &*(lparam.0 as *const MSLLHOOKSTRUCT) };
            if let Some(tx) = HOOK_TX.lock().as_ref() {
                let _ = tx.send(Msg::Click { ts: qpc_100ns(), x: info.pt.x, y: info.pt.y });
            }
        }
    }
    // SAFETY: Weiterreichen der unveränderten Parameter.
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

/// Startet den Hook-Thread; `None`, wenn der Hook nicht gesetzt werden konnte (dann keine Klickringe).
fn start_hook(tx: Sender<Msg>) -> Option<HookHandle> {
    let (ready_tx, ready_rx) = channel::<u32>();
    *HOOK_TX.lock() = Some(tx);
    let join = std::thread::Builder::new()
        .name("knips-hook".into())
        .spawn(move || {
            // SAFETY: Standard-Hook-Muster: Hook setzen, Nachrichtenschleife, Hook entfernen — alles
            // auf demselben Thread.
            unsafe {
                let hmod = GetModuleHandleW(None).map(|h| HINSTANCE(h.0)).ok();
                match SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), hmod, 0) {
                    Ok(hook) => {
                        // Nachrichtenwarteschlange anlegen, bevor die Thread-ID veröffentlicht wird.
                        let mut msg = MSG::default();
                        let _ = PeekMessageW(&mut msg, None, WM_USER, WM_USER, PM_NOREMOVE);
                        let _ = ready_tx.send(GetCurrentThreadId());
                        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
                            let _ = TranslateMessage(&msg);
                            DispatchMessageW(&msg);
                        }
                        let _ = UnhookWindowsHookEx(hook);
                    }
                    Err(e) => {
                        log::warn!("Maus-Hook fehlgeschlagen, keine Klickringe: {e}");
                        let _ = ready_tx.send(0);
                    }
                }
            }
            *HOOK_TX.lock() = None;
        })
        .ok()?;
    match ready_rx.recv_timeout(Duration::from_secs(5)) {
        Ok(id) if id != 0 => Some(HookHandle { thread_id: id, join }),
        _ => {
            *HOOK_TX.lock() = None;
            None
        }
    }
}
