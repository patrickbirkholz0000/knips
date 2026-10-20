//! knips://-Befehle für Stream Deck, Raycast & Co. (`LinkCommands.swift`). Jede App und jede Webseite
//! kann einen solchen Link öffnen. Was ohne weitere Nutzeraktion sofort aufnimmt — ganzer Bildschirm,
//! letzter Bereich, Start eines Videos — fragt deshalb erst nach (Fenster „Aufnahme per Link?“,
//! `#/link-confirm/<befehl>`), außer unter Einstellungen → Allgemein ist „Aufnahmen per Link ohne
//! Rückfrage“ eingeschaltet. Befehle, die nur Oberfläche öffnen (Auswahl-Overlay, Anpinnen, Menü,
//! Verlauf, Einstellungen), und das Stoppen einer laufenden Aufnahme laufen direkt.
//!
//! Kürzel, Menü-Panel und Taskleisten-Symbol rufen `Coordinator::perform` direkt auf und kommen hier
//! nie vorbei. Regeln (eine Rückfrage zur Zeit, Schutzzeit, „Nicht mehr fragen“): `knips_core::links`.

use std::sync::Arc;
use std::time::{Duration, Instant};

use knips_core::links::{Decision, Immediate, LinkCommand, LinkGate, Request};
use knips_core::settings::HotkeyAction;
use parking_lot::{Mutex, RwLock};
use tauri::AppHandle;

use crate::app::knips;
use crate::wm;

/// Fenster der Rückfrage heißen `link-confirm-<kennung>` (jede Rückfrage ein neues Fenster).
pub const LABEL_PREFIX: &str = "link-confirm-";
const SIZE: (f64, f64) = (500.0, 252.0);

pub type PerformFn = Arc<dyn Fn(HotkeyAction) + Send + Sync>;
pub type BusyFn = Arc<dyn Fn() -> bool + Send + Sync>;

pub struct Links {
    gate: Mutex<LinkGate>,
    /// Führt eine Aufnahme-Aktion aus. Der Selbsttest ersetzt das, damit nichts aufgenommen wird.
    perform: RwLock<PerformFn>,
    /// Läuft eine Aufnahme (oder ihr Countdown)? Dann beendet `record` sie nur.
    recording_busy: RwLock<BusyFn>,
}

fn real_perform() -> PerformFn {
    Arc::new(|action| knips().coordinator.perform(action))
}

fn real_busy() -> BusyFn {
    Arc::new(|| knips().recording.is_busy())
}

impl Default for Links {
    fn default() -> Self {
        Self { gate: Mutex::new(LinkGate::default()), perform: RwLock::new(real_perform()), recording_busy: RwLock::new(real_busy()) }
    }
}

pub fn label(id: u32) -> String {
    format!("{LABEL_PREFIX}{id}")
}

fn id_of(label: &str) -> Option<u32> {
    label.strip_prefix(LABEL_PREFIX)?.parse().ok()
}

impl Links {
    /// Führt einen Befehl aus; `false`, wenn er unbekannt ist. `from_link`: über einen knips://-Link
    /// von außen. Nur eigene Wege (Selbsttest) übergeben `false`.
    pub fn run(&self, url: &str, from_link: bool) -> bool {
        let Some(command) = LinkCommand::parse(url) else { return false };
        let k = knips();
        match command {
            LinkCommand::Direct(action) => self.perform(action),
            LinkCommand::Immediate(kind) => self.request(kind, from_link),
            LinkCommand::Settings => crate::commands::show_settings(&k.app, None),
            LinkCommand::Menu => crate::menu::toggle(&k.app, None),
            LinkCommand::History => crate::commands::show_history(&k.app),
        }
        true
    }

    fn perform(&self, action: HotkeyAction) {
        let perform = self.perform.read().clone();
        perform(action);
    }

    fn recording_busy(&self) -> bool {
        let busy = self.recording_busy.read().clone();
        busy()
    }

    fn request(&self, kind: Immediate, from_link: bool) {
        let k = knips();
        let without_confirm = k.settings.get().link_capture_without_confirm;
        let busy = self.recording_busy();
        let request = self.gate.lock().request(kind, from_link, without_confirm, busy);
        match request {
            Request::Perform(action) => self.perform(action),
            Request::Ask { id, kind } => {
                log::info!("knips://{}: Rückfrage", kind.name());
                show(&k.app, id, kind);
            }
            // Die offene Rückfrage bleibt, wo sie ist (schwebt ohnehin über allem). Nicht erneut den Fokus
            // holen: Eine Seite, die Links nachschiebt, könnte sie sonst mitten ins Tippen nach vorn holen.
            Request::Dropped { open, open_kind } => {
                log::info!("knips://{} verworfen: Rückfrage {} für knips://{} ist noch offen", kind.name(), label(open), open_kind.name());
            }
        }
    }

    /// Die Oberfläche des Fensters `label` ist bereit und meldet „sichtbar“. Zählt nur, wenn das Fenster
    /// wirklich gezeigt wird (`visible`, von Windows) — ab da läuft die Schutzzeit. `false`: noch nicht
    /// sichtbar oder keine offene Rückfrage; die Oberfläche fragt dann gleich noch einmal.
    pub fn shown(&self, label: &str, visible: bool) -> bool {
        let Some(id) = id_of(label) else { return false };
        visible && self.gate.lock().shown(id, Instant::now())
    }

    /// Antwort aus dem Fenster `label`: „Aufnehmen“ (`approved`, wirkt erst, wenn die Rückfrage seit der
    /// Schutzzeit sichtbar ist) oder „Abbrechen“/Esc. „Nicht mehr fragen“ gilt nur zusammen mit
    /// „Aufnehmen“. `false`: nichts passiert (nicht sichtbar, Schutzzeit läuft noch, oder die Rückfrage
    /// ist schon erledigt).
    pub fn decide(&self, label: &str, approved: bool, dont_ask_again: bool) -> bool {
        let Some(id) = id_of(label) else { return false };
        let decision = self.gate.lock().decide(id, approved, dont_ask_again, Instant::now());
        match decision {
            Decision::Stale | Decision::NotArmed => false,
            Decision::Cancelled(kind) => {
                log::info!("knips://{} abgelehnt", kind.name());
                close(label);
                true
            }
            Decision::Approved { kind, remember } => {
                close(label);
                let k = knips();
                if remember {
                    k.settings.update(|s| s.link_capture_without_confirm = true);
                    k.broadcast_bootstrap();
                }
                // Inzwischen per Kürzel gestartet? Dann nicht versehentlich stoppen.
                if kind == Immediate::Record && self.recording_busy() {
                    return true;
                }
                log::info!("knips://{} bestätigt", kind.name());
                let perform = self.perform.read().clone();
                std::thread::spawn(move || {
                    // Erst verschwinden lassen — die Rückfrage soll nie im Bild landen.
                    std::thread::sleep(Duration::from_millis(150));
                    perform(kind.action());
                });
                true
            }
        }
    }

    /// Fenster der Rückfrage zu (Schließen-Knopf, Alt+F4) = Abbrechen.
    pub fn window_destroyed(&self, label: &str) {
        let Some(id) = id_of(label) else { return };
        if let Some(kind) = self.gate.lock().closed(id) {
            log::info!("knips://{} abgelehnt (Fenster geschlossen)", kind.name());
        }
    }

    /// Offene Rückfrage: Fenster-Label und Befehl.
    #[allow(dead_code)]
    pub fn pending(&self) -> Option<(String, Immediate)> {
        self.gate.lock().pending().map(|(id, kind)| (label(id), kind))
    }

    /// Selbsttest: Ausführen und Aufnahme-Zustand ersetzen (`None` = wieder die echten).
    #[cfg(feature = "dev")]
    pub fn set_test_hooks(&self, hooks: Option<(PerformFn, BusyFn)>) {
        let (perform, busy) = hooks.unwrap_or_else(|| (real_perform(), real_busy()));
        *self.perform.write() = perform;
        *self.recording_busy.write() = busy;
    }
}

/// Rückfrage zeigen: schwebend, mittig auf dem Bildschirm mit der Maus, mit Fokus (wie auf dem Mac, damit
/// Esc und ⏎ wirken). Die Schutzzeit beginnt erst, wenn die Oberfläche „sichtbar“ meldet (`shown`).
fn show(app: &AppHandle, id: u32, kind: Immediate) {
    let app = app.clone();
    std::thread::spawn(move || {
        let label = label(id);
        let mut spec = wm::Spec::window(&label, &format!("link-confirm/{}", kind.name()), "Aufnahme per Link?", SIZE);
        spec.resizable = false;
        match wm::ensure(&app, &spec) {
            Ok(w) => {
                let _ = w.set_always_on_top(true);
                let _ = w.set_minimizable(false);
                let _ = w.set_maximizable(false);
                wm::center_on_cursor_monitor(&w, SIZE);
                wm::present(&w);
            }
            Err(err) => {
                log::error!("Rückfrage für knips://{} nicht geöffnet: {err:#}", kind.name());
                knips().links.window_destroyed(&label);
            }
        }
    });
}

/// Sofort verstecken, danach zerstören (erst wenn der Befehl beantwortet ist).
fn close(label: &str) {
    let app = knips().app.clone();
    if let Some(w) = wm::get(&app, label) {
        let _ = w.hide();
    }
    let label = label.to_string();
    std::thread::spawn(move || {
        if let Some(w) = wm::get(&app, &label) {
            let _ = w.destroy();
        }
    });
}
