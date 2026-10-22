//! Selbsttest `hotkeyrecord` (Feature `dev`): ein Kürzel ändern wie ein Nutzer.
//!
//! Einstellungen → Tastaturkürzel öffnen, den Knopf eines Kürzels anklicken (im Fenster und einmal mit der
//! simulierten Maus), dann Tasten wie von einer Tastatur drücken (`SendInput` als fremde Eingabe — nicht mit
//! der Kennung, die der Hook als eigene überspringt). Geprüft: Ereignis `hotkey-recorded`, Einstellung und
//! Anzeige im Fenster, das neue Kürzel löst aus und das alte nicht mehr; einzelne Tasten („A“, Umschalt+A,
//! Pos1, Entf) werden angenommen und bekommen den Hinweis, dass sie in anderen Apps fehlen, Pos1 kommt in der
//! Seite nicht an (`RegisterHotKey` schluckt sie); eine Taste, die ein anderes Programm hat, steht als belegt da;
//! Umschalt+F-Taste, Esc bricht ab, Rücktaste entfernt, ein Zeichen per Unicode-Eingabe (keine Taste) bekommt
//! eine Rückmeldung und die Aufnahme läuft weiter; verliert das Fenster den Fokus oder wird es geschlossen, endet
//! die Aufnahme; ein Hook-Kürzel (Druck) löst aus, während die Einstellungen vorn sind. Jede Taste meldet die
//! Aufrufe des Tastatur-Hooks — bis 1.0.0 blieben sie bei 0, solange ein Knips-Fenster im Vordergrund war
//! (Raw Input, siehe main.rs). Ausführen ist durch eine Liste ersetzt: Es wird nie aufgenommen.
//! Bilder: `kuerzel-*.png` (hell und dunkel).

use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use knips_core::settings::{Appearance, HotkeyAction, KeyCombo, Settings, MOD_CONTROL, MOD_SHIFT, VK_SNAPSHOT};
use knips_platform::hotkeys as hk;
use parking_lot::Mutex;
use serde::Deserialize;
use tauri::{AppHandle, Listener, Manager, WebviewWindow};

use crate::selftest::{probe, shoot};

const VK_A: u32 = 0x41;
const VK_B: u32 = 0x42;
const VK_K: u32 = 0x4B;
const VK_L: u32 = 0x4C;
const VK_F7: u32 = 0x76;
const VK_ESCAPE: u32 = 0x1B;
const VK_BACK: u32 = 0x08;
const VK_END: u32 = 0x23;
const VK_HOME: u32 = 0x24;
const VK_DELETE: u32 = 0x2E;
const VK_PACKET: u32 = 0xE7;

/// Nutzlast von `hotkey-recorded` (wie `hotkeys::Recorded`).
#[derive(Deserialize, Debug, Clone)]
struct Recorded {
    action: HotkeyAction,
    result: String,
    combo: Option<KeyCombo>,
    message: Option<String>,
}

struct Run<'a> {
    app: &'a AppHandle,
    out: &'a Path,
    window: WebviewWindow,
    fired: Arc<Mutex<Vec<HotkeyAction>>>,
    events: Arc<Mutex<Vec<Recorded>>>,
    failures: Vec<String>,
}

pub fn hotkey_record(app: &AppHandle, out: &Path) -> Result<()> {
    let k = crate::app::knips();
    let fired: Arc<Mutex<Vec<HotkeyAction>>> = Arc::default();
    let f = fired.clone();
    crate::hotkeys::set_test_fire(Some(Arc::new(move |a| f.lock().push(a))));
    let events: Arc<Mutex<Vec<Recorded>>> = Arc::default();
    let e = events.clone();
    let listener = app.listen_any("hotkey-recorded", move |event| match serde_json::from_str::<Recorded>(event.payload()) {
        Ok(r) => e.lock().push(r),
        Err(err) => println!("   Ereignis nicht lesbar: {err} ({})", event.payload()),
    });
    let saved = k.settings.get();
    let result = steps(app, out, fired, events);
    app.unlisten(listener);
    crate::hotkeys::set_test_fire(None);
    k.settings.update(|s| {
        s.hotkeys = saved.hotkeys.clone();
        s.disabled_hotkeys = saved.disabled_hotkeys.clone();
        s.appearance = saved.appearance;
    });
    crate::hotkeys::apply();
    k.broadcast_bootstrap();
    result
}

fn steps(app: &AppHandle, out: &Path, fired: Arc<Mutex<Vec<HotkeyAction>>>, events: Arc<Mutex<Vec<Recorded>>>) -> Result<()> {
    use HotkeyAction as A;
    let k = crate::app::knips();
    // Ausgangslage wie nach der Installation: Windows-Belegung, alle an, hell.
    k.settings.update(|s| {
        s.hotkeys = Settings::default_hotkeys();
        s.disabled_hotkeys.clear();
        s.appearance = Appearance::Light;
    });
    crate::hotkeys::apply();
    k.broadcast_bootstrap();
    println!("Druck-Taste beim Bildschirmausschnitt: {}", hk::snipping_key_enabled());
    println!("Hook vor dem Öffnen: {}", hk::hook_installed());

    crate::commands::show_settings(app, Some("shortcuts".into()));
    let window = wait_window(app)?;
    std::thread::sleep(Duration::from_millis(600));
    let mut run = Run { app, out, window, fired, events, failures: vec![] };
    println!("Einstellungen im Vordergrund: {}", run.window.is_focused().unwrap_or(false));
    run.shoot("kuerzel-vorher.png");

    // 1. Ganzen Bildschirm (Strg+Druck) → nur „A“: angenommen, mit Hinweis, löst aus.
    run.start("captureFullscreen", false);
    run.shoot("kuerzel-aufnahme.png");
    let a = KeyCombo::new(VK_A, 0);
    run.record(A::CaptureFullscreen, a, "A");
    run.note("captureFullscreen", Some("A"));
    run.fires(a, Some(A::CaptureFullscreen), "A löst „Bildschirm“ aus");

    // 2. Umschalt+A: angenommen, mit Hinweis; „A“ allein löst nichts mehr aus.
    run.start("captureFullscreen", false);
    let shift_a = KeyCombo::new(VK_A, MOD_SHIFT);
    run.record(A::CaptureFullscreen, shift_a, "Umschalt+A");
    run.note("captureFullscreen", Some("Umschalt+A"));
    run.fires(shift_a, Some(A::CaptureFullscreen), "Umschalt+A löst „Bildschirm“ aus");
    run.fires(a, None, "„A“ allein löst nichts mehr aus");

    // 3. Pos1: angenommen, mit Hinweis; löst aus, Umschalt+A nicht mehr. Die Seite im Vordergrund bekommt Pos1 nicht
    // (`RegisterHotKey` gibt den Tastendruck nicht weiter), eine freie Taste schon.
    run.start("captureFullscreen", false);
    let home = KeyCombo::new(VK_HOME, 0);
    run.record(A::CaptureFullscreen, home, "Pos1");
    run.note("captureFullscreen", Some("Pos1"));
    run.shoot("kuerzel-einzeltaste.png");
    run.fires(home, Some(A::CaptureFullscreen), "Pos1 löst „Bildschirm“ aus");
    run.fires(shift_a, None, "altes Umschalt+A löst nichts mehr aus");
    run.swallowed(home, "Pos1");

    // 4. Ein Zeichen per Unicode-Eingabe ist keine Taste: Rückmeldung, die Aufnahme läuft weiter. Dann
    // Strg+Umschalt+K: kein Hinweis mehr, Pos1 löst nichts mehr aus.
    run.start("captureFullscreen", false);
    run.invalid('x');
    run.shoot("kuerzel-ungueltig.png");
    let ctrl_shift_k = KeyCombo::new(VK_K, MOD_CONTROL | MOD_SHIFT);
    run.record(A::CaptureFullscreen, ctrl_shift_k, "Strg+Umschalt+K");
    run.note("captureFullscreen", None);
    run.shoot("kuerzel-neu.png");
    run.fires(ctrl_shift_k, Some(A::CaptureFullscreen), "Strg+Umschalt+K löst „Bildschirm“ aus");
    run.fires(home, None, "altes Pos1 löst nichts mehr aus");

    // 5. Noch einmal ändern: Strg+Umschalt+L; das alte Strg+Umschalt+K löst nichts mehr aus.
    run.start("captureFullscreen", false);
    let ctrl_shift_l = KeyCombo::new(VK_L, MOD_CONTROL | MOD_SHIFT);
    run.record(A::CaptureFullscreen, ctrl_shift_l, "Strg+Umschalt+L");
    run.fires(ctrl_shift_l, Some(A::CaptureFullscreen), "Strg+Umschalt+L löst „Bildschirm“ aus");
    run.fires(ctrl_shift_k, None, "altes Strg+Umschalt+K löst nichts mehr aus");

    // 6. Unbelegtes Kürzel mit echtem Mausklick → Umschalt+F7 (F-Taste: kein Hinweis).
    run.start("captureText", true);
    let shift_f7 = KeyCombo::new(VK_F7, MOD_SHIFT);
    run.record(A::CaptureText, shift_f7, "Umschalt+F7");
    run.note("captureText", None);
    run.fires(shift_f7, Some(A::CaptureText), "Umschalt+F7 löst „Text erfassen“ aus");

    // 7. Ende hat ein anderes Programm: gespeichert, aber als belegt angezeigt (kein Hook, der es ihm wegnimmt);
    // ist die Taste wieder frei, gilt das Kürzel nach dem nächsten Registrieren.
    let end = KeyCombo::new(VK_END, 0);
    match hk::occupy(end) {
        Some(held) => {
            run.start("captureLastArea", false);
            run.record(A::CaptureLastArea, end, "Ende");
            let failures = k.hotkey_failures.lock().clone();
            run.check("belegtes Ende: nicht registriert", failures.contains(&A::CaptureLastArea), format!("{failures:?}"));
            let fail = run.fail("captureLastArea");
            run.check("belegtes Ende: Zeile „belegt“", fail.contains("Von einer anderen App belegt"), format!("„{fail}“"));
            run.note("captureLastArea", None);
            run.shoot("kuerzel-belegt.png");
            run.fires(end, None, "belegtes Ende löst nichts aus");
            drop(held);
            crate::hotkeys::apply();
            k.broadcast_bootstrap();
            run.settled();
            let fail = run.fail("captureLastArea");
            run.check("freies Ende: keine Zeile „belegt“", fail.is_empty(), format!("„{fail}“"));
            run.note("captureLastArea", Some("Ende"));
            run.fires(end, Some(A::CaptureLastArea), "freies Ende löst „Letzter Bereich“ aus");
        }
        None => run.check("Ende belegen wie ein anderes Programm", false, "schon belegt"),
    }

    // 8. Esc bricht ab: Kürzel bleibt.
    run.start("captureText", false);
    run.press(KeyCombo::new(VK_ESCAPE, 0));
    let ev = run.wait_event(Duration::from_secs(2));
    let ok = ev.as_ref().is_some_and(|e| e.result == "cancel" && e.action == A::CaptureText);
    run.check("Esc bricht ab (Ereignis)", ok, format!("{ev:?}"));
    run.settled();
    let now = k.settings.get().hotkeys.get(&A::CaptureText).copied();
    run.check("Esc: Einstellung unverändert", now == Some(shift_f7), format!("{now:?}"));
    let shown = run.button("captureText");
    run.check("Esc: Anzeige unverändert", shown == "Umschalt+F7", &shown);

    // 9. Entf entfernt nicht (das macht nur die Rücktaste), sondern wird selbst zum Kürzel.
    run.start("captureScrolling", false);
    let delete = KeyCombo::new(VK_DELETE, 0);
    run.record(A::CaptureScrolling, delete, "Entf");
    run.note("captureScrolling", Some("Entf"));

    // 10. Rücktaste entfernt: danach „Nicht belegt“, Strg+Umschalt+L löst nichts mehr aus.
    run.start("captureFullscreen", false);
    run.press(KeyCombo::new(VK_BACK, 0));
    let ev = run.wait_event(Duration::from_secs(2));
    let ok = ev.as_ref().is_some_and(|e| e.result == "remove" && e.action == A::CaptureFullscreen);
    run.check("Rücktaste entfernt (Ereignis)", ok, format!("{ev:?}"));
    run.settled();
    let now = k.settings.get().hotkeys.get(&A::CaptureFullscreen).copied();
    run.check("Rücktaste: Einstellung leer", now.is_none(), format!("{now:?}"));
    let shown = run.button("captureFullscreen");
    run.check("Rücktaste: Anzeige", shown == "Nicht belegt", &shown);
    run.fires(ctrl_shift_l, None, "entferntes Strg+Umschalt+L löst nichts mehr aus");

    // Ein Kürzel über den Tastatur-Hook (Druck, solange Windows die Taste dem Bildschirmausschnitt gibt) löst auch
    // aus, während ein Knips-Fenster vorn ist (bis 1.0.0 nicht: Raw-Input-Anmeldung von tao, siehe main.rs).
    run.fires(KeyCombo::new(VK_SNAPSHOT, 0), Some(A::CaptureArea), "Druck löst „Bereich“ aus, Einstellungen vorn");

    // 11. Zweiter Klick auf denselben Knopf bricht ab (ohne Taste).
    run.start("captureArea", false);
    run.click("captureArea");
    std::thread::sleep(Duration::from_millis(400));
    let shown = run.button("captureArea");
    run.check("zweiter Klick beendet die Aufnahme", !hk::is_recording() && shown == "Druck", format!("Hook wartet: {}, Anzeige {shown}", hk::is_recording()));

    // Dunkel: Aufnahme mit Hinweis, Rückmeldung zu einer Eingabe, die keine Taste ist, und Pos1 mit Hinweis.
    k.settings.update(|s| s.appearance = Appearance::Dark);
    k.broadcast_bootstrap();
    std::thread::sleep(Duration::from_millis(500));
    run.start("captureArea", false);
    run.shoot("kuerzel-aufnahme-dunkel.png");
    run.invalid('x');
    run.shoot("kuerzel-ungueltig-dunkel.png");
    run.press(KeyCombo::new(VK_ESCAPE, 0));
    let _ = run.wait_event(Duration::from_secs(2));
    run.settled();
    run.start("captureFullscreen", false);
    run.record(A::CaptureFullscreen, home, "Pos1");
    run.note("captureFullscreen", Some("Pos1"));
    run.shoot("kuerzel-einzeltaste-dunkel.png");
    k.settings.update(|s| s.appearance = Appearance::Light);
    k.broadcast_bootstrap();

    // 12. Ein anderes Fenster kommt nach vorn: Die Aufnahme endet (der Hook schluckt sonst Tasten in jeder App).
    run.start("captureArea", false);
    if run.window.is_focused().unwrap_or(false) {
        crate::commands::show_history(app);
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline && hk::is_recording() {
            std::thread::sleep(Duration::from_millis(50));
        }
        let shown = run.button("captureArea");
        run.check("Fokus weg beendet die Aufnahme", !hk::is_recording() && shown == "Druck", format!("Hook wartet: {}, Anzeige {shown}", hk::is_recording()));
        if let Some(h) = app.get_webview_window("history") {
            let _ = h.hide();
        }
        crate::commands::show_settings(app, Some("shortcuts".into()));
        std::thread::sleep(Duration::from_millis(600));
    } else {
        println!("   (Fokus weg nicht prüfbar: Einstellungen nicht im Vordergrund)");
        run.click("captureArea");
        std::thread::sleep(Duration::from_millis(300));
    }

    // 13. Einstellungen schließen, während aufgenommen wird: Der Hook hört auf zu schlucken.
    run.start("captureArea", false);
    let _ = run.window.destroy();
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline && hk::is_recording() {
        std::thread::sleep(Duration::from_millis(50));
    }
    run.check("Schließen beendet die Aufnahme", !hk::is_recording(), format!("Hook wartet: {}", hk::is_recording()));
    let now = k.settings.get().hotkeys.get(&A::CaptureArea).copied();
    run.check("Schließen: Kürzel unverändert", now == Some(KeyCombo::new(VK_SNAPSHOT, 0)), format!("{now:?}"));

    let leftover = run.take_events();
    if !leftover.is_empty() {
        println!("   übrige Ereignisse: {leftover:?}");
    }
    if !run.failures.is_empty() {
        bail!("Kürzel ändern: {}", run.failures.join(", "));
    }
    Ok(())
}

fn wait_window(app: &AppHandle) -> Result<WebviewWindow> {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if let Some(w) = app.get_webview_window("settings") {
            let ready = probe(&w, "document.querySelector('[data-hotkey=captureFullscreen]') ? 'bereit' : 'nein'", Duration::from_millis(500));
            if ready.ok().as_deref() == Some("bereit") {
                return Ok(w);
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let w = app.get_webview_window("settings").context("Einstellungsfenster fehlt")?;
    let page = probe(&w, "location.hash + ' | ' + document.body.innerText.slice(0, 200)", Duration::from_secs(2)).unwrap_or_default();
    bail!("Tastaturkürzel nicht geöffnet: {page}")
}

impl Run<'_> {
    fn check(&mut self, name: &str, ok: bool, detail: impl std::fmt::Display) {
        println!("   {} {name}: {detail}", if ok { "ok    " } else { "FALSCH" });
        if !ok {
            self.failures.push(name.to_string());
        }
    }

    fn shoot(&mut self, name: &str) {
        if let Err(err) = shoot(self.app, "settings", self.out, name) {
            self.check(name, false, format!("{err:#}"));
        }
    }

    fn js(&self, expr: &str) -> String {
        probe(&self.window, expr, Duration::from_secs(3)).unwrap_or_else(|e| format!("Fehler: {e:#}"))
    }

    /// Kürzel-Knopf: die Anzeige der Tastenkappen (aria-label) oder sein Text („Tasten drücken …“, „Nicht belegt“).
    fn button(&self, action: &str) -> String {
        self.js(&format!(
            "(b => b ? (b.querySelector('.k-keys')?.getAttribute('aria-label') ?? b.textContent.trim()) : 'fehlt')(document.querySelector('[data-hotkey={action}]'))"
        ))
    }

    /// Hinweis unter dem Kürzel während der Aufnahme (leer, wenn keiner da ist).
    fn hint(&self, action: &str) -> String {
        self.js(&format!("document.querySelector('[data-hotkey-hint={action}]')?.textContent ?? ''"))
    }

    /// Knopf anklicken wie ein Nutzer: im Fenster (Fokus + Klick) oder mit der simulierten Maus.
    fn click(&mut self, action: &str) {
        let r = self.js(&format!(
            "(b => b ? (b.scrollIntoView({{ block: 'center' }}), b.focus(), b.click(), 'ok') : 'fehlt')(document.querySelector('[data-hotkey={action}]'))"
        ));
        if r != "ok" {
            self.check(&format!("Knopf {action}"), false, r);
        }
    }

    fn mouse_click(&mut self, action: &str) {
        let rect = self.js(&format!(
            "(b => {{ if (!b) return 'fehlt'; b.scrollIntoView({{ block: 'center' }}); const r = b.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2].join(','); }})(document.querySelector('[data-hotkey={action}]'))"
        ));
        let at: Vec<f64> = rect.split(',').filter_map(|v| v.parse().ok()).collect();
        let (Ok(origin), Ok(scale), [x, y]) = (self.window.inner_position(), self.window.scale_factor(), at.as_slice()) else {
            self.check(&format!("Mausklick {action}"), false, rect);
            return;
        };
        let (px, py) = (origin.x + (x * scale).round() as i32, origin.y + (y * scale).round() as i32);
        println!("   Mausklick auf {action} bei {px},{py}");
        knips_platform::testinput::click(px, py);
    }

    /// Aufnahme für `action` starten und prüfen, dass Oberfläche und Hook bereit sind.
    fn start(&mut self, action: &str, with_mouse: bool) {
        self.take_events();
        if with_mouse {
            self.mouse_click(action);
        } else {
            self.click(action);
        }
        // Ein Nutzer drückt frühestens nach ein paar hundert Millisekunden.
        std::thread::sleep(Duration::from_millis(400));
        let shown = self.button(action);
        let ui = shown.starts_with("Tasten drücken");
        let hook = hk::is_recording();
        let hint = self.hint(action);
        println!("   Aufnahme {action}: Anzeige „{shown}“, Hook wartet {hook}, Hook aktiv {}, Fokus {}, Hinweis „{hint}“", hk::hook_installed(), self.window.is_focused().unwrap_or(false));
        self.check(&format!("Klick auf {action} startet die Aufnahme"), ui && hook, format!("Anzeige {shown}, Hook wartet {hook}"));
    }

    fn press(&self, combo: KeyCombo) {
        self.fired.lock().clear();
        let before = hk::hook_calls();
        hk::simulate(combo);
        std::thread::sleep(Duration::from_millis(150));
        println!("   Taste vk {:#x} mods {}: Hook-Aufrufe {before} → {}", combo.vk, combo.mods, hk::hook_calls());
    }

    fn take_events(&self) -> Vec<Recorded> {
        std::mem::take(&mut *self.events.lock())
    }

    fn wait_event(&self, timeout: Duration) -> Option<Recorded> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            {
                let mut events = self.events.lock();
                if !events.is_empty() {
                    return Some(events.remove(0));
                }
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        None
    }

    /// Nach dem Ende einer Aufnahme: Einstellungen und Fenster nachziehen lassen.
    fn settled(&self) {
        std::thread::sleep(Duration::from_millis(500));
    }

    /// Zeichen per Unicode-Eingabe (VK_PACKET, keine Taste): Rückmeldung `invalid` mit Text, die Aufnahme läuft weiter.
    fn invalid(&mut self, c: char) {
        let before = hk::hook_calls();
        hk::simulate_char(c);
        std::thread::sleep(Duration::from_millis(150));
        println!("   Zeichen „{c}“ per Unicode-Eingabe: Hook-Aufrufe {before} → {}", hk::hook_calls());
        let ev = self.wait_event(Duration::from_millis(1200));
        std::thread::sleep(Duration::from_millis(200));
        let still = hk::is_recording();
        let current = self.events.lock().first().map(|e| e.action);
        let shown = self.js("document.querySelector('.st-keybtn.is-rec')?.textContent ?? 'keine Aufnahme'");
        let hint = self.js("document.querySelector('[data-hotkey-hint]')?.textContent ?? ''");
        let message = ev.as_ref().and_then(|e| e.message.clone()).unwrap_or_default();
        let combo = KeyCombo::new(VK_PACKET, 0);
        let ok = still
            && shown.starts_with("Tasten drücken")
            && ev.as_ref().is_some_and(|e| e.result == "invalid" && e.combo == Some(combo))
            && message == crate::hotkeys::INVALID_MESSAGE
            && hint.contains(&message);
        self.check(
            &format!("Unicode-Zeichen „{c}“ abgelehnt, Aufnahme läuft weiter"),
            ok,
            format!("Ereignis {ev:?}, Hook wartet {still}, Anzeige „{shown}“, Hinweis „{hint}“, weitere {current:?}"),
        );
    }

    /// Hinweis unter einem gespeicherten Kürzel, das eine Taste zum Tippen allein belegt (`None` = keiner).
    fn note(&mut self, action: &str, key: Option<&str>) {
        let shown = self.js(&format!("document.querySelector('[data-hotkey-note={action}]')?.textContent ?? ''"));
        let (name, ok) = match key {
            Some(k) => (format!("{k}: Hinweis „wirkt jetzt überall“"), shown == format!("{k} wirkt jetzt überall – in anderen Apps geht {k} dann nicht mehr.")),
            None => (format!("{action}: kein Hinweis"), shown.is_empty()),
        };
        self.check(&name, ok, format!("„{shown}“"));
    }

    /// Zeile „Von einer anderen App belegt …“ unter dem Kürzel (leer, wenn keine da ist).
    fn fail(&self, action: &str) -> String {
        self.js(&format!(
            "document.querySelector('[data-hotkey={action}]')?.closest('.k-row')?.querySelector('.st-fail')?.textContent ?? ''"
        ))
    }

    /// Ein Kürzel aus einer einzelnen Taste kommt in der Seite im Vordergrund nicht an (`RegisterHotKey` schluckt den
    /// Tastendruck, ohne Hook); eine freie Taste schon — sonst hat die Seite keinen Tastaturfokus und es ist nicht prüfbar.
    fn swallowed(&mut self, combo: KeyCombo, name: &str) {
        let keys = |run: &mut Self, c: KeyCombo| {
            run.js("(window.__keys = [], window.__keysOn || window.addEventListener('keydown', (e) => window.__keys.push(e.key), true), window.__keysOn = true, 'ok')");
            run.press(c);
            std::thread::sleep(Duration::from_millis(200));
            run.js("window.__keys.join(',')")
        };
        let free = keys(self, KeyCombo::new(VK_B, 0));
        let got = keys(self, combo);
        if free.is_empty() {
            println!("   (Schlucken von {name} nicht prüfbar: Die Seite bekommt keine Tasten, Fokus {})", self.window.is_focused().unwrap_or(false));
            return;
        }
        self.check(&format!("{name} kommt in der Seite nicht an"), got.is_empty(), format!("freie Taste: „{free}“, {name}: „{got}“"));
    }

    /// Gültige Kombination: Ereignis, Einstellung, Anzeige.
    fn record(&mut self, action: HotkeyAction, combo: KeyCombo, label: &str) {
        let k = crate::app::knips();
        self.press(combo);
        let ev = self.wait_event(Duration::from_secs(2));
        let ok = ev.as_ref().is_some_and(|e| e.result == "combo" && e.action == action && e.combo == Some(combo));
        self.check(&format!("{label} aufgenommen (Ereignis)"), ok, format!("{ev:?}, Hook wartet {}", hk::is_recording()));
        self.settled();
        let now = k.settings.get().hotkeys.get(&action).copied();
        self.check(&format!("{label} in den Einstellungen"), now == Some(combo), format!("{now:?}"));
        let name = serde_json::to_value(action).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default();
        let shown = self.button(&name);
        self.check(&format!("{label} angezeigt"), shown == label, format!("„{shown}“ (Rust: „{}“)", crate::hotkeys::label(&combo)));
        let hint = self.hint(&name);
        self.check(&format!("{label}: Hinweis wieder weg"), hint.is_empty(), format!("„{hint}“"));
    }

    /// Kürzel drücken: `want` = erwartete Aktion, `None` = nichts darf auslösen.
    fn fires(&mut self, combo: KeyCombo, want: Option<HotkeyAction>, name: &str) {
        self.press(combo);
        let deadline = Instant::now() + Duration::from_millis(if want.is_some() { 1500 } else { 800 });
        while Instant::now() < deadline && self.fired.lock().is_empty() {
            std::thread::sleep(Duration::from_millis(20));
        }
        std::thread::sleep(Duration::from_millis(100));
        let got = std::mem::take(&mut *self.fired.lock());
        let ok = match want {
            Some(a) => got == [a],
            None => got.is_empty(),
        };
        self.check(name, ok, format!("ausgelöst {got:?}"));
    }
}
