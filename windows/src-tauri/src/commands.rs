//! Tauri-Befehle — Gegenstück zu `src/shared/ipc.ts`. Lange Arbeiten laufen in eigenen Threads,
//! damit weder der Haupt-Thread noch die Oberfläche hängen.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;

use knips_core::geometry::Rect;
use knips_core::imageops;
use knips_core::model::{CaptureItem, CaptureKind, Finding, Id, ImageDocument, ImageFormat, RedactStyle, SensitiveKind, TextLine, TrackPoint, VideoDocument, VideoRedaction};
use knips_core::settings::{EditorPrefs, HotkeyAction, Settings};
use knips_core::RgbaImage;
use serde::Deserialize;
use serde_json::Value;
use tauri::ipc::{InvokeBody, Request};
use tauri::{AppHandle, Manager, WebviewWindow};

use crate::app::{knips, Bootstrap};
use crate::cards::CardsState;
use crate::editor::EditorSession;
use crate::pins::PinInfo;
use crate::promise::ImagePromise;
use crate::recording::RecordingState;
use crate::scroll::ScrollState;
use crate::video::VideoSession;
use crate::telemetry::count;
use crate::{hotkeys, wm};

type Res<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn parse_id(id: &str) -> Res<Id> {
    id.parse().map_err(|_| format!("Ungültige ID: {id}"))
}

fn item(id: &str) -> Res<CaptureItem> {
    knips().store.item(parse_id(id)?).ok_or_else(|| "Aufnahme nicht gefunden".to_string())
}

/// Blockierende Arbeit außerhalb des Async-Runtimes.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> anyhow::Result<T> + Send + 'static) -> Res<T> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(err)?.map_err(|e| format!("{e:#}"))
}

// ------------------------------------------------------------------ Start & Einstellungen

#[tauri::command]
pub fn get_bootstrap() -> Bootstrap {
    knips().bootstrap()
}

/// Fenster, die `set_settings` aufrufen, und welche Felder sie ändern dürfen: das Einstellungsfenster die
/// Einstellungen der Oberfläche, Bild-/Video-Editor nur den Zensurstil, alle anderen nichts. Die
/// Capabilities (`capabilities/*.json`) lassen den Befehl ohnehin nur aus diesen Fenstern zu.
fn settings_fields_for(label: &str) -> &'static [&'static str] {
    use knips_core::settings::{EDITOR_WINDOW_FIELDS, SETTINGS_WINDOW_FIELDS};
    if label == "settings" {
        &SETTINGS_WINDOW_FIELDS
    } else if label.starts_with("editor-") || label.starts_with("video-") {
        &EDITOR_WINDOW_FIELDS
    } else {
        &[]
    }
}

#[tauri::command]
pub fn set_settings(window: WebviewWindow, patch: Value) -> Res<Settings> {
    let k = knips();
    let before = k.settings.get();
    let after = k.settings.patch(&patch, settings_fields_for(window.label())).inspect_err(|e| log::warn!("set_settings aus {}: {e}", window.label()))?;
    if before.hotkeys != after.hotkeys || before.disabled_hotkeys != after.disabled_hotkeys {
        hotkeys::apply();
    }
    if before.quick_access_auto_hide != after.quick_access_auto_hide || before.quick_access_seconds != after.quick_access_seconds {
        k.cards.reschedule_all();
    }
    if before.launch_at_login != after.launch_at_login {
        sync_autostart(&k.app);
    }
    k.broadcast_bootstrap();
    Ok(after)
}

#[tauri::command]
pub fn set_editor_prefs(patch: Value) -> Res<()> {
    let k = knips();
    let current = serde_json::to_value(k.settings.get().editor).map_err(err)?;
    let mut merged = current;
    if let (Some(t), Some(s)) = (merged.as_object_mut(), patch.as_object()) {
        for (key, v) in s {
            t.insert(key.clone(), v.clone());
        }
    }
    let prefs: EditorPrefs = serde_json::from_value(merged).map_err(err)?;
    if prefs.tool.as_deref().is_some_and(|t| !knips_core::settings::EDITOR_TOOLS.contains(&t)) {
        return Err("Unbekanntes Werkzeug".into());
    }
    k.settings.update(|s| s.editor = prefs);
    Ok(())
}

/// Mit Windows starten (nur in der echten App).
pub fn sync_autostart(app: &AppHandle) {
    if !knips_platform::IS_REAL || crate::paths::test_root().is_some() {
        return;
    }
    use tauri_plugin_autostart::ManagerExt;
    let want = knips().settings.get().launch_at_login;
    let launcher = app.autolaunch();
    let result = if want { launcher.enable() } else { launcher.disable() };
    if let Err(e) = result {
        log::error!("Autostart umschalten fehlgeschlagen: {e}");
    }
}

// ------------------------------------------------------------------ Kürzel

#[tauri::command]
pub fn hotkey_record(action: HotkeyAction) {
    hotkeys::record(action);
}

#[tauri::command]
pub fn hotkey_record_cancel() {
    knips_platform::hotkeys::cancel_record();
}

#[tauri::command]
pub fn hotkeys_reset_defaults() {
    let k = knips();
    k.settings.update(|s| {
        s.hotkeys = Settings::default_hotkeys();
        s.disabled_hotkeys.clear();
    });
    hotkeys::apply();
    k.broadcast_bootstrap();
}

#[tauri::command]
pub fn hotkeys_preset_mac() {
    let k = knips();
    k.settings.update(|s| {
        s.hotkeys = Settings::mac_hotkeys();
        s.disabled_hotkeys.clear();
    });
    hotkeys::apply();
    k.broadcast_bootstrap();
}

#[tauri::command]
pub fn snipping_takeover() -> bool {
    hotkeys::take_over()
}

#[tauri::command]
pub fn snipping_restore() {
    hotkeys::restore();
}

// ------------------------------------------------------------------ Aufnahmen

#[tauri::command]
pub fn list_items() -> Vec<CaptureItem> {
    knips().store.items()
}

#[tauri::command]
pub async fn item_copy(id: String) -> Res<()> {
    let item = item(&id)?;
    blocking(move || {
        let k = knips();
        k.store.wait_until_written(item.id);
        let path = PathBuf::from(&item.file_path);
        match item.kind {
            CaptureKind::Image => {
                // Fertige Bilddatei: Daten direkt übernehmen, nichts neu kodieren.
                let data = std::fs::read(&path)?;
                let format = path.extension().and_then(|e| e.to_str()).and_then(ImageFormat::from_extension).unwrap_or(ImageFormat::Png);
                let image = imageops::decode(&data)?;
                knips_platform::clipboard::set_image(Arc::new(ImagePromise::encoded(image, data, format)))?;
                count("copy_image");
            }
            CaptureKind::Video | CaptureKind::Gif => knips_platform::clipboard::set_files(&[path])?,
        }
        Ok(())
    })
    .await
}

/// Texterkennung auf der gespeicherten (bereits zensierten) Datei — Zensiertes kann so nie mitkommen.
#[tauri::command]
pub async fn item_copy_text(id: String) -> Res<()> {
    let item = item(&id)?;
    count("copy_text");
    blocking(move || {
        knips().store.wait_until_written(item.id);
        let image = imageops::load(std::path::Path::new(&item.file_path))?;
        crate::coordinator::copy_text_of(&image);
        Ok(())
    })
    .await
}

#[tauri::command]
pub async fn item_pin(id: String) -> Res<()> {
    let item = item(&id)?;
    blocking(move || {
        let k = knips();
        k.store.wait_until_written(item.id);
        let image = imageops::load(std::path::Path::new(&item.file_path))?;
        k.pins.pin(Arc::new(image), item.display_scale())?;
        count("pin");
        Ok(())
    })
    .await
}

#[tauri::command]
pub async fn item_reveal(id: String) -> Res<()> {
    let item = item(&id)?;
    blocking(move || knips_platform::shell::reveal(std::path::Path::new(&item.file_path))).await
}

#[tauri::command]
pub fn item_delete(id: String) -> Res<()> {
    // Ohne Papierkorb (Netzlaufwerk, USB-Stick) fragt `delete_item` erst nach.
    crate::store::delete_item(item(&id)?);
    Ok(())
}

#[tauri::command]
pub fn item_open(app: AppHandle, id: String, tool: Option<String>) -> Res<()> {
    let id = parse_id(&id)?;
    let tool = tool.filter(|t| knips_core::settings::EDITOR_TOOLS.contains(&t.as_str()));
    let app2 = app.clone();
    std::thread::spawn(move || open_item(&app2, id, tool));
    Ok(())
}

/// Bild → Editor, Video → Video-Editor, GIF → Standard-App (`QuickAccessController.edit`).
pub fn open_item(app: &AppHandle, id: Id, tool: Option<String>) {
    let k = knips();
    let Some(item) = k.store.item(id) else { return };
    match item.kind {
        CaptureKind::Gif => {
            let _ = knips_platform::shell::open_path(std::path::Path::new(&item.file_path));
        }
        CaptureKind::Image => {
            let label = format!("editor-{id}");
            if let Some(w) = wm::get(app, &label) {
                wm::present(&w);
                return;
            }
            k.editors.set_initial_tool(id, tool);
            let m = knips_platform::monitors::at_cursor();
            let points = item.output_scale.unwrap_or(item.scale).max(0.01);
            // Bild + Rand der Arbeitsfläche (2 × 32) + deren Abstand zum Fenster (2 × 12); Leiste oben 60, Zoomzeile 50.
            let (w, h) = (item.pixel_width as f64 / points + 64.0 + 24.0, item.pixel_height as f64 / points + 64.0 + 110.0);
            let size = wm::clamp_to_work(&m, (w, h), (1140.0, 560.0));
            let (ww, wh) = m.work_points();
            let mut spec = wm::Spec::window(&label, &format!("editor/{id}"), &item.title(), size);
            spec.min_size = Some((1140f64.min(ww * 0.9), 520f64.min(wh * 0.9)));
            match wm::ensure(app, &spec) {
                Ok(w) => {
                    wm::center_on_cursor_monitor(&w, size);
                    wm::present(&w);
                    count("editor_open");
                }
                Err(e) => k.alert("Editor konnte nicht geöffnet werden", &format!("{e:#}")),
            }
        }
        CaptureKind::Video => {
            let label = format!("video-{id}");
            if let Some(w) = wm::get(app, &label) {
                wm::present(&w);
                return;
            }
            let info = match k.video.open(id) {
                Ok(session) => session.info,
                Err(e) => {
                    k.alert("Video konnte nicht geöffnet werden", &format!("{e:#}"));
                    return;
                }
            };
            let m = knips_platform::monitors::at_cursor();
            let scale = item.scale.max(1.0);
            let size = wm::clamp_to_work(&m, (info.width as f64 / scale + 80.0, info.height as f64 / scale + 260.0), (900.0, 600.0));
            let mut spec = wm::Spec::window(&label, &format!("video/{id}"), &item.title(), size);
            spec.min_size = Some((900.0, 600.0));
            match wm::ensure(app, &spec) {
                Ok(w) => {
                    wm::center_on_cursor_monitor(&w, size);
                    wm::present(&w);
                    count("video_editor_open");
                }
                Err(e) => k.alert("Video konnte nicht geöffnet werden", &format!("{e:#}")),
            }
        }
    }
}

/// Natives Herausziehen der Datei (wartet notfalls, bis sie fertig geschrieben ist).
#[tauri::command]
pub fn item_start_drag(window: WebviewWindow, id: String) -> Res<()> {
    let item = item(&id)?;
    let app = window.app_handle().clone();
    count("drag_out");
    std::thread::spawn(move || {
        let k = knips();
        k.store.wait_until_written(item.id);
        let file = PathBuf::from(&item.file_path);
        let thumb = k.store.thumbnail_path(item.id);
        let _ = app.run_on_main_thread(move || {
            let preview = if thumb.exists() { drag::Image::File(thumb) } else { drag::Image::Raw(vec![]) };
            if let Err(e) = drag::start_drag(&window, drag::DragItem::Files(vec![file]), preview, |_, _| {}, drag::Options::default()) {
                log::warn!("Ziehen fehlgeschlagen: {e}");
            }
        });
    });
    Ok(())
}

// ------------------------------------------------------------------ Menü & Fenster

#[tauri::command]
pub fn perform(app: AppHandle, action: HotkeyAction) {
    // Erst schließen, dann ausführen — das Panel soll nie im Screenshot landen.
    crate::menu::close(&app);
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(120));
        knips().coordinator.perform(action);
    });
}

#[tauri::command]
pub fn open_image_file(app: AppHandle) {
    crate::menu::close(&app);
    std::thread::spawn(|| knips().coordinator.open_image_file());
}

/// Ablageordner im Explorer öffnen — nur als Ordner (`shell::open_folder`), nie über die Standard-App eines
/// beliebigen Pfads: Ein Programm oder eine Datei an dieser Stelle würde sonst gestartet.
#[tauri::command]
pub fn open_save_folder(app: AppHandle) -> Res<()> {
    crate::menu::close(&app);
    let folder = knips().settings.save_folder();
    crate::paths::ensure(&folder);
    knips_platform::shell::open_folder(&folder).map_err(err)
}

#[tauri::command]
pub fn open_settings(app: AppHandle, pane: Option<String>) {
    crate::menu::close(&app);
    let app2 = app.clone();
    std::thread::spawn(move || show_settings(&app2, pane));
}

/// Bereiche des Einstellungsfensters (`Pane` in src/settings/Settings.tsx). Andere Werte für `pane` werden
/// ignoriert — sie landen sonst in der Adresse und im ausgeführten Skript.
pub const SETTINGS_PANES: [&str; 9] = ["start", "general", "shortcuts", "recording", "redaction", "export", "storage", "privacy", "about"];

pub fn show_settings(app: &AppHandle, pane: Option<String>) {
    count("settings_open");
    let pane = pane.filter(|p| SETTINGS_PANES.contains(&p.as_str()));
    let route = match &pane {
        Some(p) => format!("settings/{p}"),
        None => "settings".into(),
    };
    if let Some(w) = wm::get(app, "settings") {
        if pane.is_some() {
            // Als JSON-Text eingesetzt: auch ohne die Liste oben nie Teil des Skripts selbst.
            let hash = serde_json::to_string(&format!("#/{route}")).unwrap_or_default();
            let _ = w.eval(format!("location.hash = {hash}"));
        }
        wm::present(&w);
        return;
    }
    let mut spec = wm::Spec::window("settings", &route, "Knips – Einstellungen", (900.0, 640.0));
    spec.min_size = Some((900.0, 520.0));
    spec.max_size = Some((900.0, 1400.0));
    match wm::ensure(app, &spec) {
        Ok(w) => wm::present(&w),
        Err(e) => log::error!("Einstellungen nicht geöffnet: {e:#}"),
    }
}

#[tauri::command]
pub fn open_history(app: AppHandle) {
    crate::menu::close(&app);
    let app2 = app.clone();
    std::thread::spawn(move || show_history(&app2));
}

pub fn show_history(app: &AppHandle) {
    count("history_open");
    if let Some(w) = wm::get(app, "history") {
        wm::present(&w);
        return;
    }
    let mut spec = wm::Spec::window("history", "history", "Knips – Verlauf", (980.0, 680.0));
    spec.min_size = Some((640.0, 420.0));
    match wm::ensure(app, &spec) {
        Ok(w) => wm::present(&w),
        Err(e) => log::error!("Verlauf nicht geöffnet: {e:#}"),
    }
}

/// Nur die Projektseite, der Statistik-Server und Seiten der Windows-Einstellungen
/// (`knips_core::links::allowed_external_url`) — nie beliebige Adressen oder Programme.
#[tauri::command]
pub fn open_url(url: String) -> Res<()> {
    if !knips_core::links::allowed_external_url(&url) {
        log::warn!("Adresse nicht erlaubt: {url}");
        return Err("Diese Adresse öffnet Knips nicht.".into());
    }
    knips_platform::shell::open_url(&url).map_err(err)
}

#[tauri::command]
pub fn quit_app(app: AppHandle) {
    app.exit(0);
}

#[tauri::command]
pub fn menu_resize(app: AppHandle, height: f64) {
    crate::menu::resize(&app, height);
}

#[tauri::command]
pub fn menu_close(app: AppHandle) {
    crate::menu::close(&app);
}

#[tauri::command]
pub async fn choose_save_folder(app: AppHandle) -> Res<Option<String>> {
    blocking(move || {
        use tauri_plugin_dialog::DialogExt;
        let picked = app
            .dialog()
            .file()
            .set_title("Ablageordner wählen")
            .set_directory(knips().settings.save_folder())
            .blocking_pick_folder();
        Ok(picked.and_then(|p| p.into_path().ok()).map(|p| p.to_string_lossy().into_owned()))
    })
    .await
}

#[tauri::command]
pub async fn storage_size() -> Res<u64> {
    blocking(|| Ok(knips().store.storage_size())).await
}

/// Bereit-Check (Einstellungen → Start): Ist der Ablageordner erreichbar? Im Hintergrund, weil ein getrenntes
/// Netzlaufwerk Sekunden hängen kann.
#[tauri::command]
pub async fn save_folder_ok() -> Res<bool> {
    blocking(|| Ok(folder_reachable(&knips().settings.save_folder()))).await
}

/// Ordner vorhanden — oder noch nicht angelegt (z. B. `Bilder\Knips` vor der ersten Aufnahme), aber der nächste
/// vorhandene Ort darüber ist ein Ordner: Dann legt die Ablage ihn beim Speichern an. Schreibt nichts.
pub fn folder_reachable(folder: &std::path::Path) -> bool {
    if folder.is_dir() {
        return true;
    }
    if folder.exists() {
        return false; // eine Datei statt eines Ordners
    }
    folder.ancestors().skip(1).find(|p| p.exists()).is_some_and(|p| p.is_dir())
}

#[tauri::command]
pub fn purge_originals() {
    let k = knips();
    k.cards.dismiss_all();
    k.store.purge_originals();
}

#[tauri::command]
pub fn clipboard_text(text: String) -> Res<()> {
    // Nur der Editor („Text kopieren“) ruft das auf.
    knips_platform::clipboard::set_text(&text).map_err(err)?;
    count("copy_text");
    Ok(())
}

#[derive(Deserialize)]
pub struct HudArgs {
    text: String,
    icon: String,
}

#[tauri::command]
pub fn hud(message: HudArgs) {
    let icon: &'static str = match message.icon.as_str() {
        "text" => "text",
        "search" => "search",
        "error" => "error",
        "trash" => "trash",
        "dashed" => "dashed",
        "pin" => "pin",
        "copy" => "copy",
        _ => "check",
    };
    knips().hud.show(message.text, icon);
}

// ------------------------------------------------------------------ Karten

#[tauri::command]
pub fn get_cards() -> CardsState {
    knips().cards.state()
}

#[tauri::command]
pub fn cards_hover(id: Option<String>) {
    knips().cards.hover(id.and_then(|i| i.parse().ok()));
}

#[tauri::command]
pub fn cards_dismiss(id: String) -> Res<()> {
    knips().cards.dismiss(parse_id(&id)?);
    Ok(())
}

#[tauri::command]
pub fn cards_dismiss_all() {
    knips().cards.dismiss_all();
}

#[tauri::command]
pub fn cards_layout(width: f64, height: f64, hit: Vec<Rect>) {
    knips().cards.layout(width, height, hit);
}

// ------------------------------------------------------------------ Pins

#[tauri::command]
pub fn pin_info(n: u32) -> Res<PinInfo> {
    knips().pins.info(n).ok_or_else(|| "Pin nicht gefunden".into())
}

#[tauri::command]
pub fn pin_copy(n: u32) {
    std::thread::spawn(move || {
        if knips().pins.copy(n) {
            count("copy_image");
        }
    });
}

// ------------------------------------------------------------------ Aufnahme- und Scroll-Leisten

#[tauri::command]
pub fn get_recording_state() -> RecordingState {
    knips().recording.state()
}

#[tauri::command]
pub fn recording_stop(save: bool) {
    knips().recording.stop(save);
}

#[tauri::command]
pub fn get_scroll_state() -> ScrollState {
    knips().scroll.state()
}

#[tauri::command]
pub fn scroll_finish(save: bool) {
    knips().scroll.finish(save);
}

// ------------------------------------------------------------------ Bild-Editor

#[tauri::command]
pub async fn editor_open(id: String) -> Res<EditorSession> {
    let id = parse_id(&id)?;
    blocking(move || knips().editors.open(id)).await
}

#[tauri::command]
pub async fn editor_text_lines(id: String) -> Res<Vec<TextLine>> {
    let id = parse_id(&id)?;
    blocking(move || knips().editors.text_lines(id).map(|l| l.as_ref().clone())).await
}

#[tauri::command]
pub async fn editor_detect(id: String, kinds: BTreeSet<SensitiveKind>) -> Res<Vec<Finding>> {
    let id = parse_id(&id)?;
    let found = blocking(move || knips().editors.detect(id, &kinds)).await?;
    count("censor_auto");
    Ok(found)
}

#[tauri::command]
pub fn editor_stage(id: String, document: ImageDocument) -> Res<()> {
    knips().editors.stage(parse_id(&id)?, document);
    Ok(())
}

/// Rohdaten (RGBA) im Körper, Kennung/Aktion/Größe in den Kopfzeilen.
#[tauri::command]
pub async fn editor_commit(app: AppHandle, request: Request<'_>) -> Res<CaptureItem> {
    let header = |name: &str| request.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_string);
    let id = parse_id(&header("x-knips-id").ok_or("Kennung fehlt")?)?;
    let action = header("x-knips-action").unwrap_or_else(|| "save".into());
    let size = header("x-knips-size").ok_or("Größe fehlt")?;
    let (w, h) = size.split_once('x').and_then(|(w, h)| Some((w.parse::<u32>().ok()?, h.parse::<u32>().ok()?))).ok_or("Größe ungültig")?;
    let InvokeBody::Raw(bytes) = request.body() else { return Err("Bilddaten fehlen".into()) };
    let bytes = bytes.clone();
    let result = blocking(move || {
        let image = RgbaImage::from_raw(w, h, bytes).ok_or_else(|| anyhow::anyhow!("Bilddaten passen nicht zur Größe {w}×{h}"))?;
        knips().editors.commit(id, &action, image)
    })
    .await;
    // „Fertig“ schließt nur, wenn wirklich gespeichert wurde.
    if header("x-knips-action").as_deref() == Some("done") && result.is_ok() {
        if let Some(w) = wm::get(&app, &format!("editor-{id}")) {
            let _ = w.destroy();
        }
    }
    result
}

// ------------------------------------------------------------------ Video-Editor

#[tauri::command]
pub async fn video_open(id: String) -> Res<VideoSession> {
    let id = parse_id(&id)?;
    blocking(move || knips().video.open(id)).await
}

#[tauri::command]
pub async fn video_thumbnails(id: String, count: usize) -> Res<Vec<String>> {
    let id = parse_id(&id)?;
    blocking(move || knips().video.thumbnails(id, count.clamp(1, 48))).await
}

#[tauri::command]
pub async fn video_detect(id: String, start: f64, end: f64, style: RedactStyle, kinds: BTreeSet<SensitiveKind>) -> Res<Vec<VideoRedaction>> {
    let id = parse_id(&id)?;
    let found = blocking(move || knips().video.detect(id, start, end, style, kinds)).await?;
    count("censor_auto");
    Ok(found)
}

#[tauri::command]
pub async fn video_track(id: String, rect: Rect, t0: f64, start: f64, end: f64) -> Res<Vec<TrackPoint>> {
    let id = parse_id(&id)?;
    blocking(move || knips().video.track(id, rect, t0, start, end)).await
}

#[tauri::command]
pub async fn video_save(id: String, document: VideoDocument) -> Res<CaptureItem> {
    let id = parse_id(&id)?;
    blocking(move || knips().video.save(id, document)).await
}

#[tauri::command]
pub async fn video_export_gif(id: String, document: VideoDocument) -> Res<CaptureItem> {
    let id = parse_id(&id)?;
    blocking(move || knips().video.export_gif(id, document)).await
}

#[tauri::command]
pub fn video_cancel(id: String) {
    knips().video.cancel(&id);
}

// ------------------------------------------------------------------ Nutzungsstatistik

/// Antwort aus dem Fenster „Knips verbessern?“ oder dem Schalter in den Einstellungen.
#[tauri::command]
pub fn telemetry_set_consent(app: AppHandle, consent: bool) {
    let k = knips();
    k.telemetry.set_consent(consent);
    k.broadcast_bootstrap();
    // Fenster erst schließen, wenn der Befehl beantwortet ist.
    std::thread::spawn(move || {
        if let Some(w) = wm::get(&app, crate::telemetry::CONSENT_LABEL) {
            let _ = w.destroy();
        }
    });
}

/// Ereignis aus der Oberfläche: nur die beiden, die allein der Editor sieht (Balken gezogen, Klick auf
/// Text). Alles andere zählt Rust dort, wo es passiert — die Oberfläche kann keine Zähler aufblähen.
#[tauri::command]
pub fn telemetry_count(event: String) {
    if matches!(event.as_str(), "censor_manual" | "censor_smart") {
        count(&event);
    }
}

// ------------------------------------------------------------------ knips://-Links

/// Das Fenster „Aufnahme per Link?“ meldet: Oberfläche bereit. Ab dem Moment, in dem es auch wirklich
/// sichtbar ist, läuft die Schutzzeit (`true`); vorher `false`, die Oberfläche fragt dann erneut.
#[tauri::command]
pub fn link_confirm_shown(window: WebviewWindow) -> bool {
    let visible = window.is_visible().unwrap_or(false) && !window.is_minimized().unwrap_or(false);
    knips().links.shown(window.label(), visible)
}

/// Antwort aus dem Fenster „Aufnahme per Link?“. Zählt nur aus genau diesem Fenster; `false`, wenn
/// nichts passiert ist (Schutzzeit läuft noch).
#[tauri::command]
pub fn link_confirm_decide(window: WebviewWindow, approved: bool, dont_ask_again: bool) -> bool {
    knips().links.decide(window.label(), approved, dont_ask_again)
}
