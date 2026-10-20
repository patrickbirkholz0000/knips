//! knips://-Befehle (`LinkCommands.swift`) und die Regeln für Adressen, die Knips nach außen öffnet.
//!
//! Jede App und jede Webseite kann einen knips://-Link öffnen. Was ohne weitere Nutzeraktion sofort
//! aufnimmt — ganzer Bildschirm, letzter Bereich, Start eines Videos — fragt deshalb erst nach, außer
//! unter Einstellungen → Allgemein ist „Aufnahmen per Link ohne Rückfrage“ eingeschaltet. Befehle, die
//! nur Oberfläche öffnen (Auswahl-Overlay, Anpinnen, Menü, Verlauf, Einstellungen), und das Stoppen
//! einer laufenden Aufnahme laufen direkt. Kürzel, Menü und Taskleisten-Symbol kommen hier nie vorbei.
//!
//! `LinkGate` ist nur die Entscheidungslogik (ohne Fenster, ohne Uhr): höchstens eine Rückfrage zur
//! Zeit, „Aufnehmen“ erst `ARM_DELAY` nachdem die Rückfrage sichtbar ist (`shown`), „Nicht mehr fragen“
//! nur zusammen mit „Aufnehmen“.

use std::time::{Duration, Instant};

use crate::settings::HotkeyAction;

/// „Aufnehmen“ wirkt erst nach dieser Schutzzeit, gemessen ab dem Moment, in dem die Rückfrage sichtbar
/// ist: ein Klick oder ⏎, der gerade für eine andere App gedacht war, als das Fenster aufging, bestätigt
/// nichts.
pub const ARM_DELAY: Duration = Duration::from_millis(600);

/// Befehle, die ohne Rückfrage sofort aufnehmen würden.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Immediate {
    Fullscreen,
    Last,
    Record,
}

impl Immediate {
    pub const ALL: [Immediate; 3] = [Immediate::Fullscreen, Immediate::Last, Immediate::Record];

    /// Name im Link (`knips://<name>`) und in der Route des Rückfrage-Fensters.
    pub fn name(self) -> &'static str {
        match self {
            Immediate::Fullscreen => "fullscreen",
            Immediate::Last => "last",
            Immediate::Record => "record",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.name() == name)
    }

    pub fn action(self) -> HotkeyAction {
        match self {
            Immediate::Fullscreen => HotkeyAction::CaptureFullscreen,
            Immediate::Last => HotkeyAction::CaptureLastArea,
            Immediate::Record => HotkeyAction::ToggleRecording,
        }
    }
}

/// Ein knips://-Befehl.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LinkCommand {
    /// Öffnet nur Oberfläche (Auswahl-Overlay, Anpinnen) — läuft direkt.
    Direct(HotkeyAction),
    /// Nimmt sofort auf — fragt bei Links von außen erst nach.
    Immediate(Immediate),
    Settings,
    Menu,
    History,
}

impl LinkCommand {
    /// `knips://area`, `knips://record/`, `knips://text?x=1` → Befehl; unbekannt → `None`.
    pub fn parse(url: &str) -> Option<Self> {
        let command = url.trim_start_matches("knips://").trim_matches('/').split(['/', '?', '#']).next().unwrap_or("");
        Some(match command {
            "area" => LinkCommand::Direct(HotkeyAction::CaptureArea),
            "window" => LinkCommand::Direct(HotkeyAction::CaptureWindow),
            "text" => LinkCommand::Direct(HotkeyAction::CaptureText),
            "scroll" => LinkCommand::Direct(HotkeyAction::CaptureScrolling),
            "pin" => LinkCommand::Direct(HotkeyAction::PinClipboard),
            "settings" => LinkCommand::Settings,
            "menu" => LinkCommand::Menu,
            "history" => LinkCommand::History,
            other => LinkCommand::Immediate(Immediate::from_name(other)?),
        })
    }
}

/// Was mit einer Anfrage für einen sofort aufnehmenden Befehl geschieht.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Request {
    /// Direkt ausführen (eigener Weg, Einstellung an, oder Stoppen einer laufenden Aufnahme).
    Perform(HotkeyAction),
    /// Rückfrage `id` öffnen.
    Ask { id: u32, kind: Immediate },
    /// Verworfen: Rückfrage `open` ist noch offen. Sie bleibt, wie sie ist — ein weiterer Link holt sie
    /// nicht nach vorn (sonst bekäme sie bei jedem Link den Fokus, mitten ins Tippen hinein).
    Dropped { open: u32, open_kind: Immediate },
}

/// Antwort aus der Rückfrage.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Decision {
    /// Keine offene Rückfrage mit dieser Kennung (schon beantwortet oder geschlossen).
    Stale,
    /// „Aufnehmen“, bevor die Rückfrage sichtbar war oder vor Ablauf der Schutzzeit danach — nichts
    /// passiert, die Rückfrage bleibt offen.
    NotArmed,
    Cancelled(Immediate),
    /// Aufnehmen; `remember` = „Nicht mehr fragen“ war angehakt.
    Approved { kind: Immediate, remember: bool },
}

#[derive(Clone, Copy, Debug)]
struct Pending {
    id: u32,
    kind: Immediate,
    /// Seit wann die Rückfrage sichtbar ist (`None`: noch nicht gemeldet).
    shown: Option<Instant>,
}

#[derive(Default, Debug)]
pub struct LinkGate {
    pending: Option<Pending>,
    next_id: u32,
}

impl LinkGate {
    /// `from_link`: über einen knips://-Link von außen (nur eigene Wege übergeben `false`).
    /// `without_confirm`: Einstellung „Aufnahmen per Link ohne Rückfrage“.
    pub fn request(&mut self, kind: Immediate, from_link: bool, without_confirm: bool, recording_busy: bool) -> Request {
        // Stoppen nimmt nichts Neues auf — ohne Rückfrage.
        if kind == Immediate::Record && recording_busy {
            return Request::Perform(HotkeyAction::ToggleRecording);
        }
        if !from_link || without_confirm {
            return Request::Perform(kind.action());
        }
        if let Some(open) = self.pending {
            return Request::Dropped { open: open.id, open_kind: open.kind };
        }
        self.next_id = self.next_id.wrapping_add(1).max(1);
        let id = self.next_id;
        self.pending = Some(Pending { id, kind, shown: None });
        Request::Ask { id, kind }
    }

    /// Rückfrage `id` ist jetzt sichtbar (Fenster gezeigt, Oberfläche bereit): Ab hier läuft die
    /// Schutzzeit. Gilt nur beim ersten Mal; `false`, wenn es keine offene Rückfrage `id` gibt.
    pub fn shown(&mut self, id: u32, now: Instant) -> bool {
        match self.pending.as_mut().filter(|p| p.id == id) {
            Some(open) => {
                open.shown.get_or_insert(now);
                true
            }
            None => false,
        }
    }

    /// „Aufnehmen“ (`approved`) oder „Abbrechen“/Esc aus der Rückfrage `id`. Aufnehmen erst, wenn die
    /// Rückfrage seit mindestens `ARM_DELAY` sichtbar ist.
    pub fn decide(&mut self, id: u32, approved: bool, dont_ask_again: bool, now: Instant) -> Decision {
        let Some(open) = self.pending.filter(|p| p.id == id) else { return Decision::Stale };
        let armed = open.shown.is_some_and(|shown| now.saturating_duration_since(shown) >= ARM_DELAY);
        if approved && !armed {
            return Decision::NotArmed;
        }
        self.pending = None;
        if approved {
            Decision::Approved { kind: open.kind, remember: dont_ask_again }
        } else {
            Decision::Cancelled(open.kind)
        }
    }

    /// Fenster der Rückfrage `id` wurde geschlossen = Abbrechen. Liefert den verworfenen Befehl.
    pub fn closed(&mut self, id: u32) -> Option<Immediate> {
        let open = self.pending.filter(|p| p.id == id)?;
        self.pending = None;
        Some(open.kind)
    }

    /// Offene Rückfrage (Kennung, Befehl).
    pub fn pending(&self) -> Option<(u32, Immediate)> {
        self.pending.map(|p| (p.id, p.kind))
    }
}

/// Darf `open_url` diese Adresse öffnen? Nur die Projektseite (Quellcode, Datenschutz-Abschnitt),
/// der Statistik-Server und Seiten der Windows-Einstellungen (`ms-settings:…`). Alles andere würde
/// eine beliebige Oberfläche zum Starten beliebiger Programme/Protokolle machen.
pub fn allowed_external_url(url: &str) -> bool {
    const SITES: [&str; 2] = ["https://github.com/patrickbirkholz0000/knips", "https://knips.velno.ai"];
    if let Some(page) = url.strip_prefix("ms-settings:") {
        return !page.is_empty() && page.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    }
    if url.chars().any(|c| c.is_whitespace() || c.is_control() || c == '\\') {
        return false;
    }
    SITES.iter().any(|site| match url.strip_prefix(site) {
        Some(rest) => rest.is_empty() || rest.starts_with(['/', '#', '?']),
        None => false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn later(t: Instant, ms: u64) -> Instant {
        t + Duration::from_millis(ms)
    }

    #[test]
    fn parse_commands() {
        use LinkCommand::*;
        assert_eq!(LinkCommand::parse("knips://area"), Some(Direct(HotkeyAction::CaptureArea)));
        assert_eq!(LinkCommand::parse("knips://pin/"), Some(Direct(HotkeyAction::PinClipboard)));
        assert_eq!(LinkCommand::parse("knips://fullscreen"), Some(Immediate(super::Immediate::Fullscreen)));
        assert_eq!(LinkCommand::parse("knips://last?x=1"), Some(Immediate(super::Immediate::Last)));
        assert_eq!(LinkCommand::parse("knips://record/"), Some(Immediate(super::Immediate::Record)));
        assert_eq!(LinkCommand::parse("knips://menu"), Some(Menu));
        assert_eq!(LinkCommand::parse("knips://settings"), Some(Settings));
        assert_eq!(LinkCommand::parse("knips://history"), Some(History));
        assert_eq!(LinkCommand::parse("knips://debug-sample"), None);
        assert_eq!(LinkCommand::parse("knips://"), None);
        for kind in super::Immediate::ALL {
            assert_eq!(super::Immediate::from_name(kind.name()), Some(kind));
        }
    }

    #[test]
    fn asks_once_and_drops_further_links() {
        let mut gate = LinkGate::default();
        let t = Instant::now();
        let Request::Ask { id, kind } = gate.request(Immediate::Fullscreen, true, false, false) else { panic!("keine Rückfrage") };
        assert_eq!(kind, Immediate::Fullscreen);
        assert_eq!(gate.request(Immediate::Last, true, false, false), Request::Dropped { open: id, open_kind: Immediate::Fullscreen });
        assert_eq!(gate.pending(), Some((id, Immediate::Fullscreen)));
        // Abbrechen geht immer, auch bevor die Rückfrage sichtbar war.
        assert_eq!(gate.decide(id, false, true, t), Decision::Cancelled(Immediate::Fullscreen));
        assert_eq!(gate.pending(), None);
        assert_eq!(gate.decide(id, true, false, later(t, 900)), Decision::Stale);
    }

    #[test]
    fn approve_only_after_arm_delay() {
        let mut gate = LinkGate::default();
        let t = Instant::now();
        let Request::Ask { id, .. } = gate.request(Immediate::Last, true, false, false) else { panic!() };
        assert!(gate.shown(id, t));
        assert_eq!(gate.decide(id, true, false, t), Decision::NotArmed);
        assert_eq!(gate.decide(id, true, false, later(t, 599)), Decision::NotArmed);
        assert_eq!(gate.pending(), Some((id, Immediate::Last)));
        assert_eq!(gate.decide(id + 1, true, false, later(t, 700)), Decision::Stale);
        assert_eq!(gate.decide(id, true, false, later(t, 600)), Decision::Approved { kind: Immediate::Last, remember: false });
        // neue Rückfrage, neue Kennung
        let Request::Ask { id: id2, .. } = gate.request(Immediate::Fullscreen, true, false, false) else { panic!() };
        assert_ne!(id, id2);
        assert!(gate.shown(id2, t));
        assert_eq!(gate.decide(id2, true, true, later(t, 800)), Decision::Approved { kind: Immediate::Fullscreen, remember: true });
    }

    #[test]
    fn arm_delay_counts_from_shown() {
        let mut gate = LinkGate::default();
        let t = Instant::now();
        let Request::Ask { id, .. } = gate.request(Immediate::Fullscreen, true, false, false) else { panic!() };
        // Noch nie sichtbar: Aufnehmen wirkt nie, egal wie lange die Anfrage her ist.
        assert_eq!(gate.decide(id, true, false, later(t, 10_000)), Decision::NotArmed);
        // Erst nach 5 s sichtbar (langsamer Start): Schutzzeit ab da, nicht ab der Anfrage.
        assert!(gate.shown(id, later(t, 5_000)));
        assert_eq!(gate.decide(id, true, false, later(t, 5_400)), Decision::NotArmed);
        // Eine zweite Meldung „sichtbar“ verschiebt nichts (und verkürzt nichts).
        assert!(gate.shown(id, later(t, 5_500)));
        assert_eq!(gate.decide(id, true, false, later(t, 5_600)), Decision::Approved { kind: Immediate::Fullscreen, remember: false });
        // Meldungen für erledigte oder fremde Rückfragen zählen nicht.
        assert!(!gate.shown(id, later(t, 6_000)));
        let Request::Ask { id: id2, .. } = gate.request(Immediate::Last, true, false, false) else { panic!() };
        assert!(!gate.shown(id2 + 1, t));
        assert_eq!(gate.decide(id2, true, false, later(t, 9_000)), Decision::NotArmed);
    }

    #[test]
    fn close_cancels() {
        let mut gate = LinkGate::default();
        let Request::Ask { id, .. } = gate.request(Immediate::Record, true, false, false) else { panic!() };
        assert_eq!(gate.closed(id + 7), None);
        assert_eq!(gate.closed(id), Some(Immediate::Record));
        assert_eq!(gate.closed(id), None);
        assert!(matches!(gate.request(Immediate::Record, true, false, false), Request::Ask { .. }));
    }

    #[test]
    fn direct_paths() {
        let mut gate = LinkGate::default();
        // Stoppen einer laufenden Aufnahme: immer direkt
        assert_eq!(gate.request(Immediate::Record, true, false, true), Request::Perform(HotkeyAction::ToggleRecording));
        // eigener Weg (kein Link von außen)
        assert_eq!(gate.request(Immediate::Fullscreen, false, false, false), Request::Perform(HotkeyAction::CaptureFullscreen));
        // Einstellung „ohne Rückfrage“
        for kind in Immediate::ALL {
            assert_eq!(gate.request(kind, true, true, false), Request::Perform(kind.action()));
        }
        assert_eq!(gate.pending(), None);
    }

    #[test]
    fn external_urls() {
        for ok in [
            "https://github.com/patrickbirkholz0000/knips",
            "https://github.com/patrickbirkholz0000/knips#datenschutz",
            "https://github.com/patrickbirkholz0000/knips/releases",
            "https://knips.velno.ai",
            "https://knips.velno.ai/v1/health",
            "ms-settings:privacy-microphone",
            "ms-settings:easeofaccess-keyboard",
        ] {
            assert!(allowed_external_url(ok), "{ok}");
        }
        for bad in [
            "",
            "https://github.com/patrickbirkholz0000/knips.evil.example",
            "https://github.com/patrickbirkholz0000/knipsx",
            "https://github.com/patrickbirkholz0000/knips\\..\\x",
            "https://knips.velno.ai.evil.example",
            "https://knips.velno.ai@evil.example",
            "http://knips.velno.ai",
            "https://example.com",
            "file:///C:/Windows/System32/calc.exe",
            "C:\\Windows\\System32\\calc.exe",
            "ms-settings:",
            "ms-settings:privacy microphone",
            "ms-settings:x&calc",
            "ms-settings-other:abc",
            "javascript:alert(1)",
        ] {
            assert!(!allowed_external_url(bad), "{bad}");
        }
    }
}
