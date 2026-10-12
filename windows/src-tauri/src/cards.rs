//! Schwebende Karten unten links nach jeder Aufnahme (`QuickAccessController` in QuickAccess.swift).
//! Die Oberfläche (`#/cards`) zeichnet und meldet Größe + klickbare Flächen; hier liegen Liste,
//! Ausblende-Zeitgeber und Fensterplatzierung. Ist eine Spalte bis zur Bildschirmhöhe voll,
//! stapeln sich neue Karten rechts daneben; erst wenn auch die Breite voll ist, fällt die älteste weg.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use knips_core::cards;
use knips_core::geometry::Rect;
use knips_core::model::{CaptureItem, Id};
use knips_platform::{monitors, Monitor};
use parking_lot::Mutex;
use serde::Serialize;

use crate::app::knips;
use crate::wm;

pub const LABEL: &str = "cards";

pub fn spec() -> wm::Spec {
    wm::Spec::floating(LABEL, "cards", (cards::CARD_WIDTH + 2.0 * cards::PADDING, 200.0))
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CardsState {
    pub cards: Vec<CaptureItem>,
    pub rows: usize,
}

#[derive(Default)]
struct Inner {
    /// Älteste zuerst — die neueste Karte sitzt unten, am nächsten an der Ecke.
    cards: Vec<CaptureItem>,
    rows: usize,
    monitor: Option<Monitor>,
    hovered: Option<Id>,
    /// Generation je Ausblende-Zeitgeber; ein älterer Zeitgeber tut nichts.
    timers: HashMap<Id, u64>,
    generation: u64,
    /// Panelgröße und klickbare Flächen (logische Pixel, oben links).
    size: (f64, f64),
    hit: Vec<Rect>,
    visible: bool,
}

#[derive(Default)]
pub struct Cards {
    inner: Mutex<Inner>,
}

impl Cards {
    pub fn state(&self) -> CardsState {
        let inner = self.inner.lock();
        CardsState { cards: inner.cards.clone(), rows: inner.rows.max(1) }
    }

    fn publish(&self) {
        knips().emit("cards-changed", self.state());
    }

    pub fn show(&self, item: CaptureItem, monitor: Monitor) {
        let (w, h) = monitor.work_points();
        let (rows, columns) = cards::grid(w, h);
        {
            let mut inner = self.inner.lock();
            inner.rows = rows;
            inner.monitor = Some(monitor);
            inner.cards.retain(|c| c.id != item.id);
            inner.cards.push(item.clone());
            // Erst wenn auch nebeneinander nichts mehr passt, fällt die älteste Karte weg.
            while inner.cards.len() > rows * columns {
                let old = inner.cards.remove(0);
                inner.timers.remove(&old.id);
            }
        }
        if let Ok(window) = wm::ensure(&knips().app, &spec()) {
            let _ = window.set_ignore_cursor_events(false);
        }
        self.publish();
        self.schedule_auto_close(item.id);
    }

    pub fn dismiss(&self, id: Id) {
        let empty = {
            let mut inner = self.inner.lock();
            inner.cards.retain(|c| c.id != id);
            inner.timers.remove(&id);
            if inner.hovered == Some(id) {
                inner.hovered = None;
            }
            inner.cards.is_empty()
        };
        self.publish();
        if empty {
            self.hide();
        }
    }

    pub fn dismiss_all(&self) {
        {
            let mut inner = self.inner.lock();
            inner.cards.clear();
            inner.timers.clear();
            inner.hovered = None;
        }
        self.publish();
        self.hide();
    }

    fn hide(&self) {
        self.inner.lock().visible = false;
        if let Some(w) = wm::get(&knips().app, LABEL) {
            let _ = w.hide();
        }
    }

    /// Unter der Maus läuft kein Ausblende-Zeitgeber ab.
    pub fn hover(&self, id: Option<Id>) {
        let ids: Vec<Id> = {
            let mut inner = self.inner.lock();
            if inner.hovered == id {
                return;
            }
            inner.hovered = id;
            if id.is_some() {
                return;
            }
            inner.cards.iter().map(|c| c.id).collect()
        };
        for id in ids {
            self.schedule_auto_close(id);
        }
    }

    /// Neue Anzeigedauer gilt sofort auch für Karten, die gerade stehen.
    pub fn reschedule_all(&self) {
        let ids: Vec<Id> = self.inner.lock().cards.iter().map(|c| c.id).collect();
        for id in ids {
            self.schedule_auto_close(id);
        }
    }

    fn schedule_auto_close(&self, id: Id) {
        let seconds = knips().settings.get().quick_access_auto_close();
        let generation = {
            let mut inner = self.inner.lock();
            inner.generation += 1;
            let g = inner.generation;
            if seconds == 0 {
                inner.timers.remove(&id);
                return;
            }
            inner.timers.insert(id, g);
            g
        };
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(seconds as u64));
            let cards = &knips().cards;
            let fire = {
                let inner = cards.inner.lock();
                inner.timers.get(&id) == Some(&generation) && inner.hovered != Some(id)
            };
            if fire {
                cards.dismiss(id);
            }
        });
    }

    /// Aufnahmen haben sich geändert (neue Revision, gelöscht): Karten nachziehen.
    pub fn sync(&self, items: &[CaptureItem]) {
        let mut changed = false;
        let empty = {
            let mut inner = self.inner.lock();
            for card in inner.cards.iter_mut() {
                if let Some(fresh) = items.iter().find(|i| i.id == card.id) {
                    if fresh != card {
                        *card = fresh.clone();
                        changed = true;
                    }
                }
            }
            let before = inner.cards.len();
            inner.cards.retain(|c| items.iter().any(|i| i.id == c.id));
            changed |= before != inner.cards.len();
            inner.cards.is_empty() && before > 0
        };
        if changed {
            self.publish();
        }
        if empty {
            self.hide();
        }
    }

    /// Die Oberfläche meldet Panelgröße und klickbare Flächen → Fenster unten links verankern.
    pub fn layout(&self, width: f64, height: f64, hit: Vec<Rect>) {
        let (monitor, any) = {
            let mut inner = self.inner.lock();
            inner.size = (width, height);
            inner.hit = hit;
            (inner.monitor.clone().unwrap_or_else(monitors::at_cursor), !inner.cards.is_empty())
        };
        let Some(window) = wm::get(&knips().app, LABEL) else { return };
        if !any || width < 1.0 || height < 1.0 {
            self.hide();
            return;
        }
        let s = monitor.scale;
        let margin = (cards::MARGIN * s).round() as i32;
        let h = (height * s).round() as i32;
        wm::place(&window, &monitor, (width, height), (monitor.work.x + margin, monitor.work.bottom() - margin - h));
        let first = {
            let mut inner = self.inner.lock();
            let first = !inner.visible;
            inner.visible = true;
            first
        };
        if first {
            let _ = window.show();
        }
    }

    /// Liegt der (globale, physische) Punkt auf einer klickbaren Fläche?
    fn hit_test(&self, x: i32, y: i32, origin: (i32, i32)) -> bool {
        let inner = self.inner.lock();
        let Some(m) = inner.monitor.as_ref() else { return false };
        let p = knips_core::geometry::Point::new((x - origin.0) as f64 / m.scale, (y - origin.1) as f64 / m.scale);
        inner.hit.iter().any(|r| r.contains(p))
    }

    fn is_visible(&self) -> bool {
        self.inner.lock().visible
    }
}

/// Transparente Flächen des Kartenfensters lassen Klicks durch (Windows: WebView2 fängt sonst alles ab).
pub fn start_click_through() {
    if !knips_platform::IS_REAL {
        return;
    }
    static STARTED: AtomicBool = AtomicBool::new(false);
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::Builder::new()
        .name("knips-cards-hit".into())
        .spawn(|| {
            let mut ignoring: Option<bool> = None;
            loop {
                std::thread::sleep(Duration::from_millis(40));
                let cards = &knips().cards;
                if !cards.is_visible() {
                    ignoring = None;
                    continue;
                }
                let Some(window) = wm::get(&knips().app, LABEL) else { continue };
                let Ok(pos) = window.outer_position() else { continue };
                let (x, y) = monitors::cursor_pos();
                let ignore = !cards.hit_test(x, y, (pos.x, pos.y));
                if ignoring != Some(ignore) {
                    let _ = window.set_ignore_cursor_events(ignore);
                    ignoring = Some(ignore);
                }
            }
        })
        .expect("Karten-Thread");
}
