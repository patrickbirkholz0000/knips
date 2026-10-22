//! Einstellungen und Tastenkürzel — Gegenstück zu `Support/Settings.swift` und `Support/Hotkeys.swift`.
//! Gespeichert als `settings.json` (siehe `src-tauri/src/settings.rs`).

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::model::{FrameStyle, ImageFormat, RedactStyle, Rgba, SensitiveKind, StrokeSize};

/// Modifier-Bits wie bei Win32 `RegisterHotKey`.
pub const MOD_ALT: u32 = 0x0001;
pub const MOD_CONTROL: u32 = 0x0002;
pub const MOD_SHIFT: u32 = 0x0004;
pub const MOD_WIN: u32 = 0x0008;

pub const VK_SNAPSHOT: u32 = 0x2C;

/// Globales Kürzel: Windows-Virtual-Key + Modifier-Bits.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub struct KeyCombo {
    pub vk: u32,
    pub mods: u32,
}

impl KeyCombo {
    pub const fn new(vk: u32, mods: u32) -> Self {
        Self { vk, mods }
    }

    /// Jede echte Taste taugt als Kürzel, auch allein (Pos1, „A“, Umschalt+A). Nicht: reine Modifier und
    /// Werte, die keine Taste sind — Zeichen per Unicode-Eingabe (VK_PACKET, Bildschirmtastatur, Passwortmanager),
    /// Eingabemethoden (VK_PROCESSKEY), 0 und 0xFF.
    pub fn is_valid(&self) -> bool {
        if matches!(self.vk, 0x10 | 0x11 | 0x12 | 0x5B | 0x5C | 0xA0..=0xA5) {
            return false; // reine Modifier
        }
        !matches!(self.vk, 0 | 0xE5 | 0xE7) && self.vk < 0xFF
    }

    /// Taste, die beim Tippen oder Navigieren gebraucht wird (Buchstaben, Ziffern, Zeichen, Leertaste, Eingabe,
    /// Tab, Pos1, Ende, Bild↑/↓, Pfeile, Entf, Ziffernblock), ohne Strg/Alt/Win — als Kürzel fehlt sie dann in
    /// allen anderen Apps. Die Einstellungen sagen das dazu; `RegisterHotKey` statt Tastatur-Hook.
    pub fn is_typing_key(&self) -> bool {
        self.mods & (MOD_CONTROL | MOD_ALT | MOD_WIN) == 0
            && matches!(self.vk, 0x09 | 0x0C | 0x0D | 0x20..=0x28 | 0x2E | 0x30..=0x39 | 0x41..=0x5A | 0x60..=0x6F | 0xBA..=0xC0 | 0xDB..=0xDF | 0xE2)
    }

    /// Braucht den Tastatur-Hook statt `RegisterHotKey` (Windows reserviert Win-Kombinationen).
    pub fn needs_hook(&self) -> bool {
        self.mods & MOD_WIN != 0
    }

    /// Anzeige wie in Windows: „Strg+Umschalt+4“, „Alt+Druck“, „Win+Umschalt+S“ — mit den deutschen
    /// Tastennamen aus `key_name` (Zeichentasten wie auf QWERTZ).
    pub fn display(&self) -> String {
        self.display_with(key_name)
    }

    /// Wie `display`, aber mit eigenen Tastennamen (die App nimmt die Beschriftung des aktuellen Layouts,
    /// `knips_platform::hotkeys::key_name`).
    pub fn display_with(&self, key_name: impl Fn(u32) -> String) -> String {
        let mut parts: Vec<String> = vec![];
        if self.mods & MOD_WIN != 0 {
            parts.push("Win".into());
        }
        if self.mods & MOD_CONTROL != 0 {
            parts.push("Strg".into());
        }
        if self.mods & MOD_ALT != 0 {
            parts.push("Alt".into());
        }
        if self.mods & MOD_SHIFT != 0 {
            parts.push("Umschalt".into());
        }
        parts.push(key_name(self.vk));
        parts.join("+")
    }
}

/// Deutscher Tastenname für einen Virtual-Key. Zeichentasten (0xBA–0xE2) so, wie sie auf dem deutschen
/// Layout beschriftet sind — die App fragt dafür das aktuelle Layout (`knips_platform::hotkeys::key_name`),
/// das hier ist der Rückfall und die Attrappe.
pub fn key_name(vk: u32) -> String {
    match vk {
        0x08 => "Rücktaste".into(),
        0x09 => "Tab".into(),
        0x0D => "Eingabe".into(),
        0x13 => "Pause".into(),
        0x1B => "Esc".into(),
        0x20 => "Leertaste".into(),
        0x21 => "Bild↑".into(),
        0x22 => "Bild↓".into(),
        0x23 => "Ende".into(),
        0x24 => "Pos1".into(),
        0x25 => "←".into(),
        0x26 => "↑".into(),
        0x27 => "→".into(),
        0x28 => "↓".into(),
        0x2C => "Druck".into(),
        0x2D => "Einfg".into(),
        0x2E => "Entf".into(),
        0x30..=0x39 | 0x41..=0x5A => char::from_u32(vk).map(String::from).unwrap_or_default(),
        0x60..=0x69 => format!("Num {}", vk - 0x60),
        0x6A => "Num *".into(),
        0x6B => "Num +".into(),
        0x6D => "Num -".into(),
        0x6E => "Num ,".into(),
        0x6F => "Num /".into(),
        0x70..=0x87 => format!("F{}", vk - 0x6F),
        0x91 => "Rollen".into(),
        0xBA => "Ü".into(),
        0xBB => "+".into(),
        0xBC => ",".into(),
        0xBD => "-".into(),
        0xBE => ".".into(),
        0xBF => "#".into(),
        0xC0 => "Ö".into(),
        0xDB => "ß".into(),
        0xDC => "^".into(),
        0xDD => "´".into(),
        0xDE => "Ä".into(),
        0xE2 => "<".into(),
        _ => format!("#{vk}"),
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub enum HotkeyAction {
    CaptureArea,
    CaptureWindow,
    CaptureFullscreen,
    CaptureLastArea,
    CaptureText,
    CaptureScrolling,
    ToggleRecording,
    PinClipboard,
}

impl HotkeyAction {
    pub const ALL: [HotkeyAction; 8] = [
        HotkeyAction::CaptureArea,
        HotkeyAction::CaptureWindow,
        HotkeyAction::CaptureFullscreen,
        HotkeyAction::CaptureLastArea,
        HotkeyAction::CaptureText,
        HotkeyAction::CaptureScrolling,
        HotkeyAction::ToggleRecording,
        HotkeyAction::PinClipboard,
    ];

    pub fn title(self) -> &'static str {
        match self {
            HotkeyAction::CaptureArea => "Bereich aufnehmen",
            HotkeyAction::CaptureWindow => "Fenster aufnehmen",
            HotkeyAction::CaptureFullscreen => "Ganzen Bildschirm aufnehmen",
            HotkeyAction::CaptureLastArea => "Letzten Bereich wiederholen",
            HotkeyAction::CaptureText => "Text aus Bereich erfassen",
            HotkeyAction::CaptureScrolling => "Scroll-Screenshot",
            HotkeyAction::ToggleRecording => "Bildschirmaufnahme starten/stoppen",
            HotkeyAction::PinClipboard => "Bild aus Zwischenablage anpinnen",
        }
    }

    /// Windows-Standard: Druck-Taste wie bei Greenshot/ShareX und Windows selbst.
    /// Druck = Bereich, Alt+Druck = Fenster, Strg+Druck = Vollbild, Umschalt+Druck = Video.
    pub fn default_combo(self) -> Option<KeyCombo> {
        match self {
            HotkeyAction::CaptureArea => Some(KeyCombo::new(VK_SNAPSHOT, 0)),
            HotkeyAction::CaptureWindow => Some(KeyCombo::new(VK_SNAPSHOT, MOD_ALT)),
            HotkeyAction::CaptureFullscreen => Some(KeyCombo::new(VK_SNAPSHOT, MOD_CONTROL)),
            HotkeyAction::ToggleRecording => Some(KeyCombo::new(VK_SNAPSHOT, MOD_SHIFT)),
            _ => None,
        }
    }

    /// „Mac-Belegung“: Win+Umschalt+4/3/5/2 — mit Mac-Tastatur am PC liegt Win dort, wo ⌘ ist.
    pub fn mac_combo(self) -> Option<KeyCombo> {
        let m = MOD_WIN | MOD_SHIFT;
        match self {
            HotkeyAction::CaptureArea => Some(KeyCombo::new(0x34, m)),
            HotkeyAction::CaptureWindow => Some(KeyCombo::new(0x32, m)),
            HotkeyAction::CaptureFullscreen => Some(KeyCombo::new(0x33, m)),
            HotkeyAction::ToggleRecording => Some(KeyCombo::new(0x35, m)),
            _ => None,
        }
    }
}

/// Zuletzt benutzte Editor-Werkzeuge (Mac: UserDefaults `editorTool`, `editorColor`, `editorSize`, `lastFrameStyle`).
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorPrefs {
    pub tool: Option<String>,
    pub color: Option<Rgba>,
    pub size: Option<StrokeSize>,
    pub last_frame_style: Option<FrameStyle>,
}

/// Hell/Dunkel aller Fenster (docs/design.md). Menü, Pillen und Leisten bleiben immer dunkel.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Leer = Standard (Bilder\Knips); der Store löst das auf.
    pub save_folder: String,
    pub copy_to_clipboard: bool,
    pub show_quick_access: bool,
    /// Karten unten links nach `quick_access_seconds` ausblenden.
    pub quick_access_auto_hide: bool,
    /// 1…3600.
    pub quick_access_seconds: u32,
    pub open_editor_after_capture: bool,
    pub play_sound: bool,
    pub recording_fps: u32,
    pub recording_show_cursor: bool,
    pub recording_countdown: bool,
    pub recording_microphone: bool,
    /// Videos in Bildschirmgröße (1×) statt voller Auflösung.
    pub recording_at_screen_size: bool,
    pub recording_hevc: bool,
    /// Klicks als Kreis einblenden.
    pub recording_show_clicks: bool,
    pub gif_fps: u32,
    pub gif_width: u32,
    pub redact_style: RedactStyle,
    /// Bildschirmgröße (1×) statt voller Auflösung.
    pub export_at_screen_size: bool,
    pub image_format: ImageFormat,
    /// Auto-Zensur-Knopf in den Editoren anbieten (standardmäßig aus).
    pub show_auto_redact: bool,
    pub auto_redact_kinds: BTreeSet<SensitiveKind>,
    /// Tage, die Originale + Bearbeitungsstand behalten werden (0 = unbegrenzt).
    pub retention_days: u32,
    /// Abgehakte Kürzel bleiben gespeichert, werden aber nicht registriert.
    pub disabled_hotkeys: BTreeSet<HotkeyAction>,
    pub hotkeys: BTreeMap<HotkeyAction, KeyCombo>,
    pub launch_at_login: bool,
    /// knips://fullscreen, knips://last und knips://record (Start) ohne Rückfrage ausführen (standardmäßig
    /// aus, weil jede App und jede Webseite solche Links öffnen kann — siehe `links`).
    pub link_capture_without_confirm: bool,
    /// Alle Knips-Fenster aus Bildschirmübertragungen und fremden Aufnahmen heraushalten (Teams, Discord, OBS …),
    /// z. B. damit unzensierte Originale im Editor nicht im Stream landen. Standardmäßig aus: Dann sehen andere
    /// Apps Knips wie jedes andere Fenster; nur Knips' eigene Bilder und Videos lassen Knips-Fenster weg.
    pub hide_from_screen_sharing: bool,
    pub appearance: Appearance,
    /// Einmal am Tag bei GitHub nach einer neuen Version fragen und sie im Hintergrund laden (siehe `update`).
    /// Installiert wird erst beim Beenden oder per „Neu starten und aktualisieren“. Standardmäßig an.
    pub auto_update: bool,
    pub editor: EditorPrefs,
    // Interne Merker (Mac: einzelne UserDefaults-Schlüssel).
    pub did_first_launch: bool,
    pub asked_shortcut_takeover: bool,
    /// Knips hat „Druck-Taste öffnet Bildschirmausschnitt“ abgeschaltet.
    pub took_snipping_key: bool,
    /// Unix-Sekunden der letzten erfolgreichen Suche nach Updates (Einstellungen → Über Knips).
    pub update_last_check: Option<i64>,
    pub settings_version: u32,
}

/// Werkzeuge des Bild-Editors (`EditorTool` in src/shared/types.ts).
pub const EDITOR_TOOLS: [&str; 10] = ["select", "arrow", "rectangle", "ellipse", "line", "text", "counter", "highlight", "redact", "crop"];

/// Felder, die das Einstellungsfenster über `set_settings` ändern darf. Alles andere (Kürzel, interne
/// Merker, Nutzungsstatistik) ändert nur Rust selbst.
pub const SETTINGS_WINDOW_FIELDS: [&str; 28] = [
    "saveFolder",
    "copyToClipboard",
    "showQuickAccess",
    "quickAccessAutoHide",
    "quickAccessSeconds",
    "openEditorAfterCapture",
    "playSound",
    "recordingFps",
    "recordingShowCursor",
    "recordingCountdown",
    "recordingMicrophone",
    "recordingAtScreenSize",
    "recordingHevc",
    "recordingShowClicks",
    "gifFps",
    "gifWidth",
    "redactStyle",
    "exportAtScreenSize",
    "imageFormat",
    "showAutoRedact",
    "autoRedactKinds",
    "retentionDays",
    "disabledHotkeys",
    "launchAtLogin",
    "linkCaptureWithoutConfirm",
    "hideFromScreenSharing",
    "appearance",
    "autoUpdate",
];

/// Felder, die Bild- und Video-Editor ändern dürfen (zuletzt gewählter Zensurstil).
pub const EDITOR_WINDOW_FIELDS: [&str; 1] = ["redactStyle"];

/// Prüft einen Ablageordner aus der Oberfläche (Windows-Pfad, nur Text — ob es den Ordner gibt, prüft die
/// App). Leer = Standard. Erlaubt nur absolute Pfade auf einem Laufwerk (`C:\…`): keine Netzwerk- (UNC,
/// `\\server\freigabe`) oder Gerätepfade (`\\?\`, `\\.\`, `CON`, `NUL`, `COM1` …), keine Datenströme
/// (`…:stream`), kein `.`/`..`, keine in Windows-Namen verbotenen Zeichen.
pub fn check_save_folder(path: &str) -> Result<(), String> {
    if path.is_empty() {
        return Ok(());
    }
    let bad = |why: &str| Err(format!("Dieser Ordner geht nicht als Ablage: {why}."));
    if path.len() > 1024 {
        return bad("Pfad zu lang");
    }
    if path.chars().any(|c| c.is_control() || matches!(c, '<' | '>' | '"' | '|' | '?' | '*')) {
        return bad("ungültige Zeichen im Pfad");
    }
    let bytes = path.as_bytes();
    let drive = bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && matches!(bytes[2], b'\\' | b'/');
    if !drive {
        if path.starts_with(r"\\") || path.starts_with("//") {
            return bad("Netzwerk- und Gerätepfade sind nicht erlaubt");
        }
        return bad(r"nur vollständige Pfade auf einem Laufwerk, z. B. C:\Bilder\Knips");
    }
    for part in path[3..].split(['\\', '/']) {
        if part.is_empty() {
            continue; // abschließender oder doppelter Trenner
        }
        if part == "." || part == ".." {
            return bad("„.“ und „..“ sind im Pfad nicht erlaubt");
        }
        if part.contains(':') {
            return bad("„:“ ist nur nach dem Laufwerksbuchstaben erlaubt");
        }
        if part.ends_with([' ', '.']) {
            return bad("Ordnernamen dürfen nicht auf Leerzeichen oder Punkt enden");
        }
        // Gerätenamen gelten auch mit Endung („nul.txt“).
        let stem = part.split('.').next().unwrap_or("").trim_end().to_uppercase();
        let numbered = stem
            .strip_prefix("COM")
            .or_else(|| stem.strip_prefix("LPT"))
            .is_some_and(|n| matches!(n, "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"));
        if numbered || matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$") {
            return bad("Gerätenamen wie CON, NUL oder COM1 sind nicht erlaubt");
        }
    }
    Ok(())
}

impl Settings {
    pub const QUICK_ACCESS_SECONDS: std::ops::RangeInclusive<u32> = 1..=3600;
    pub const RECORDING_FPS: std::ops::RangeInclusive<u32> = 5..=60;
    pub const GIF_FPS: std::ops::RangeInclusive<u32> = 1..=50;
    pub const GIF_WIDTH: std::ops::RangeInclusive<u32> = 160..=3840;
    /// 0 = unbegrenzt; sonst höchstens zehn Jahre.
    pub const RETENTION_DAYS: std::ops::RangeInclusive<u32> = 0..=3650;
    pub const VERSION: u32 = 1;

    /// Teiländerung aus der Oberfläche prüfen und anwenden: `patch` ist ein JSON-Objekt nur mit Feldern
    /// aus `allowed` (sonst Fehler), Typen und Auswahlwerte wie in `Settings`, Zahlen in ihren Bereichen,
    /// Ablageordner nach `check_save_folder` (wenn er sich ändert). Liefert den neuen Stand; `self` bleibt.
    pub fn patched(&self, patch: &serde_json::Value, allowed: &[&str]) -> Result<Settings, String> {
        let fields = patch.as_object().ok_or_else(|| "Einstellungen: Objekt erwartet".to_string())?;
        let mut merged = serde_json::to_value(self).map_err(|e| e.to_string())?;
        let target = merged.as_object_mut().ok_or_else(|| "Einstellungen: Objekt erwartet".to_string())?;
        for (key, value) in fields {
            if !allowed.contains(&key.as_str()) {
                return Err(format!("Die Einstellung „{key}“ lässt sich hier nicht ändern."));
            }
            target.insert(key.clone(), value.clone());
        }
        let next: Settings = serde_json::from_value(merged).map_err(|e| format!("Ungültige Einstellung: {e}"))?;
        let ranges = [
            ("quickAccessSeconds", next.quick_access_seconds, Self::QUICK_ACCESS_SECONDS),
            ("recordingFps", next.recording_fps, Self::RECORDING_FPS),
            ("gifFps", next.gif_fps, Self::GIF_FPS),
            ("gifWidth", next.gif_width, Self::GIF_WIDTH),
            ("retentionDays", next.retention_days, Self::RETENTION_DAYS),
        ];
        for (name, value, range) in ranges {
            if fields.contains_key(name) && !range.contains(&value) {
                return Err(format!("Ungültige Einstellung: {name} muss zwischen {} und {} liegen.", range.start(), range.end()));
            }
        }
        if next.save_folder != self.save_folder {
            check_save_folder(next.save_folder.trim())?;
        }
        Ok(next)
    }

    pub fn default_hotkeys() -> BTreeMap<HotkeyAction, KeyCombo> {
        HotkeyAction::ALL.iter().filter_map(|a| a.default_combo().map(|c| (*a, c))).collect()
    }

    pub fn mac_hotkeys() -> BTreeMap<HotkeyAction, KeyCombo> {
        HotkeyAction::ALL.iter().filter_map(|a| a.mac_combo().map(|c| (*a, c))).collect()
    }

    /// Tatsächlich registrierte Kürzel.
    pub fn active_hotkeys(&self) -> BTreeMap<HotkeyAction, KeyCombo> {
        self.hotkeys.iter().filter(|(a, _)| !self.disabled_hotkeys.contains(a)).map(|(a, c)| (*a, *c)).collect()
    }

    /// 0 = nie automatisch ausblenden.
    pub fn quick_access_auto_close(&self) -> u32 {
        if self.quick_access_auto_hide {
            self.quick_access_seconds
        } else {
            0
        }
    }

    /// Verkleinerungsfaktor für die Ausgabe eines Bildes mit `scale` Pixeln pro Punkt.
    pub fn output_factor(&self, source_scale: f64) -> f64 {
        if self.export_at_screen_size && source_scale > 1.0 {
            1.0 / source_scale
        } else {
            1.0
        }
    }

    /// Werte in gültige Bereiche bringen (nach dem Laden und nach jeder Änderung aus der UI).
    pub fn sanitize(&mut self) {
        let clamp = |v: u32, r: std::ops::RangeInclusive<u32>| v.clamp(*r.start(), *r.end());
        self.quick_access_seconds = clamp(self.quick_access_seconds, Self::QUICK_ACCESS_SECONDS);
        self.recording_fps = clamp(self.recording_fps, Self::RECORDING_FPS);
        self.gif_fps = clamp(self.gif_fps, Self::GIF_FPS);
        self.gif_width = clamp(self.gif_width, Self::GIF_WIDTH);
        self.retention_days = clamp(self.retention_days, Self::RETENTION_DAYS);
        self.hotkeys.retain(|_, c| c.is_valid());
    }
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            save_folder: String::new(),
            copy_to_clipboard: true,
            show_quick_access: true,
            quick_access_auto_hide: false,
            quick_access_seconds: 10,
            open_editor_after_capture: false,
            play_sound: true,
            recording_fps: 30,
            recording_show_cursor: true,
            recording_countdown: true,
            recording_microphone: false,
            recording_at_screen_size: true,
            recording_hevc: false,
            recording_show_clicks: true,
            gif_fps: 15,
            gif_width: 960,
            redact_style: RedactStyle::Solid,
            export_at_screen_size: true,
            image_format: ImageFormat::Png,
            show_auto_redact: false,
            auto_redact_kinds: SensitiveKind::ALL.into_iter().collect(),
            retention_days: 30,
            disabled_hotkeys: BTreeSet::new(),
            hotkeys: Settings::default_hotkeys(),
            launch_at_login: false,
            link_capture_without_confirm: false,
            hide_from_screen_sharing: false,
            appearance: Appearance::System,
            auto_update: true,
            editor: EditorPrefs::default(),
            did_first_launch: false,
            asked_shortcut_takeover: false,
            took_snipping_key: false,
            update_last_check: None,
            settings_version: Settings::VERSION,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_and_display() {
        let s = Settings::default();
        assert_eq!(s.hotkeys.len(), 4);
        assert_eq!(s.hotkeys[&HotkeyAction::CaptureArea].display(), "Druck");
        assert_eq!(s.hotkeys[&HotkeyAction::CaptureWindow].display(), "Alt+Druck");
        assert_eq!(KeyCombo::new(0x53, MOD_WIN | MOD_SHIFT).display(), "Win+Umschalt+S");
        assert_eq!(KeyCombo::new(0xBA, MOD_CONTROL | MOD_SHIFT).display(), "Strg+Umschalt+Ü");
        // Mit Namen aus einem anderen Layout (US: „;“ auf derselben Taste); Sondertasten bleiben deutsch.
        let us = |vk: u32| if vk == 0xBA { ";".to_string() } else { key_name(vk) };
        assert_eq!(KeyCombo::new(0xBA, MOD_CONTROL | MOD_SHIFT).display_with(us), "Strg+Umschalt+;");
        assert_eq!(KeyCombo::new(VK_SNAPSHOT, MOD_ALT).display_with(us), "Alt+Druck");
        assert!(KeyCombo::new(0x2C, MOD_SHIFT).is_valid());
        let json = serde_json::to_string(&s).unwrap();
        let back: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(back, s);
        // Fehlende Felder → Standardwerte
        let partial: Settings = serde_json::from_str(r#"{"playSound": false}"#).unwrap();
        assert!(!partial.play_sound && partial.copy_to_clipboard);
        // Links nehmen ohne Einstellung nie ohne Rückfrage auf, auch mit alter settings.json ohne das Feld.
        assert!(!s.link_capture_without_confirm && !partial.link_capture_without_confirm);
        assert!(json.contains(r#""linkCaptureWithoutConfirm":false"#));
        // Knips-Fenster sind für Bildschirmübertragungen standardmäßig sichtbar, auch mit alter settings.json.
        assert!(!s.hide_from_screen_sharing && !partial.hide_from_screen_sharing);
        assert!(json.contains(r#""hideFromScreenSharing":false"#));
        // Automatisch aktualisieren ist standardmäßig an, auch mit alter settings.json ohne das Feld.
        assert!(s.auto_update && partial.auto_update && partial.update_last_check.is_none());
        assert!(json.contains(r#""autoUpdate":true"#) && json.contains(r#""updateLastCheck":null"#));
    }

    #[test]
    fn single_keys() {
        // Jede Taste taugt, auch allein: Buchstaben, Ziffern, Pos1, Pfeile, Ziffernblock, F-Tasten, Druck.
        for vk in [0x41, 0x5A, 0x30, 0x24, 0x23, 0x21, 0x22, 0x25, 0x28, 0x20, 0x0D, 0x09, 0x2E, 0x2D, 0x60, 0x6B, 0x77, 0x2C, 0x13, 0x91, 0xBA, 0xE2, 0xAD] {
            for mods in [0, MOD_SHIFT, MOD_CONTROL, MOD_ALT | MOD_SHIFT, MOD_WIN] {
                assert!(KeyCombo::new(vk, mods).is_valid(), "{vk:#x} mit {mods} gültig");
            }
        }
        // Nicht: reine Modifier, Unicode-Eingabe, Eingabemethode, keine Taste.
        for vk in [0x10, 0x11, 0x12, 0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xE5, 0xE7, 0, 0xFF, 0x100] {
            assert!(!KeyCombo::new(vk, 0).is_valid(), "{vk:#x} ungültig");
            assert!(!KeyCombo::new(vk, MOD_CONTROL).is_valid(), "Strg+{vk:#x} ungültig");
        }
        // Tasten zum Tippen und Navigieren, allein oder nur mit Umschalt → Hinweis in den Einstellungen.
        for vk in [0x41, 0x5A, 0x30, 0x39, 0x20, 0x0D, 0x09, 0x24, 0x23, 0x21, 0x22, 0x25, 0x26, 0x27, 0x28, 0x2E, 0x60, 0x69, 0x6A, 0x6F, 0x0C, 0xBA, 0xC0, 0xDB, 0xDE, 0xE2] {
            assert!(KeyCombo::new(vk, 0).is_typing_key(), "{} ist eine Tipptaste", key_name(vk));
            assert!(KeyCombo::new(vk, MOD_SHIFT).is_typing_key(), "Umschalt+{} ist eine Tipptaste", key_name(vk));
            for mods in [MOD_CONTROL, MOD_ALT, MOD_WIN, MOD_CONTROL | MOD_SHIFT] {
                assert!(!KeyCombo::new(vk, mods).is_typing_key(), "{} mit Modifier {mods} ist keine", key_name(vk));
            }
        }
        // F-Tasten, Druck, Pause, Rollen, Einfg, Medientasten: wie bisher ohne Hinweis.
        for vk in [0x70, 0x77, 0x87, 0x2C, 0x13, 0x91, 0x2D, 0xAD, 0xB3] {
            assert!(!KeyCombo::new(vk, 0).is_typing_key(), "{} ist keine Tipptaste", key_name(vk));
            assert!(!KeyCombo::new(vk, MOD_SHIFT).is_typing_key(), "Umschalt+{} ist keine Tipptaste", key_name(vk));
        }
        assert_eq!(KeyCombo::new(0x24, 0).display(), "Pos1");
        assert_eq!(KeyCombo::new(0x41, MOD_SHIFT).display(), "Umschalt+A");
        // Gespeicherte Einzeltasten bleiben beim Laden erhalten, unbrauchbare fallen weg.
        let mut s = Settings::default();
        s.hotkeys.insert(HotkeyAction::CaptureText, KeyCombo::new(0x24, 0));
        s.hotkeys.insert(HotkeyAction::PinClipboard, KeyCombo::new(0x41, MOD_SHIFT));
        s.hotkeys.insert(HotkeyAction::CaptureScrolling, KeyCombo::new(0xE7, 0));
        s.sanitize();
        assert_eq!(s.hotkeys.get(&HotkeyAction::CaptureText), Some(&KeyCombo::new(0x24, 0)));
        assert_eq!(s.hotkeys.get(&HotkeyAction::PinClipboard), Some(&KeyCombo::new(0x41, MOD_SHIFT)));
        assert!(!s.hotkeys.contains_key(&HotkeyAction::CaptureScrolling));
    }

    #[test]
    fn patch_from_settings_window() {
        use serde_json::json;
        let s = Settings::default();
        let all = &SETTINGS_WINDOW_FIELDS[..];
        // erlaubte Felder, gültige Werte
        let patch = json!({
            "playSound": false,
            "quickAccessSeconds": 3600,
            "redactStyle": "blur",
            "linkCaptureWithoutConfirm": true,
            "hideFromScreenSharing": true,
            "autoUpdate": false,
            "disabledHotkeys": ["captureArea"],
            "saveFolder": r"D:\Screenshots\Knips",
        });
        let next = s.patched(&patch, all).unwrap();
        assert!(!next.play_sound && next.link_capture_without_confirm && next.hide_from_screen_sharing && !next.auto_update);
        assert_eq!(next.quick_access_seconds, 3600);
        assert_eq!(next.redact_style, RedactStyle::Blur);
        assert_eq!(next.save_folder, r"D:\Screenshots\Knips");
        assert_eq!(s, Settings::default(), "self bleibt unverändert");
        // leerer Ablageordner = Standard; unveränderter Ordner wird nicht erneut geprüft
        assert!(next.patched(&json!({ "saveFolder": "" }), all).is_ok());
        // nicht erlaubte Felder (Kürzel, interne Merker, Nutzungsstatistik, Unbekanntes)
        for key in ["hotkeys", "didFirstLaunch", "askedShortcutTakeover", "tookSnippingKey", "updateLastCheck", "settingsVersion", "editor", "telemetryConsent", "telemetryInstallId", "unbekannt"] {
            assert!(s.patched(&json!({ key: true }), all).is_err(), "{key}");
        }
        // falsche Typen, unbekannte Auswahlwerte, Bereiche, kein Objekt
        for bad in [
            json!({ "playSound": "ja" }),
            json!({ "hideFromScreenSharing": 1 }),
            json!({ "autoUpdate": "nie" }),
            json!({ "redactStyle": "schwarz" }),
            json!({ "imageFormat": "bmp" }),
            json!({ "autoRedactKinds": ["email", "passwort"] }),
            json!({ "disabledHotkeys": ["formatC"] }),
            json!({ "quickAccessSeconds": 0 }),
            json!({ "quickAccessSeconds": 3601 }),
            json!({ "quickAccessSeconds": -5 }),
            json!({ "recordingFps": 240 }),
            json!({ "gifFps": 0 }),
            json!({ "gifWidth": 100000 }),
            json!({ "retentionDays": 100000 }),
            json!({ "saveFolder": 42 }),
            json!({ "saveFolder": r"\\server\freigabe" }),
            json!(["playSound"]),
            json!("playSound"),
        ] {
            assert!(s.patched(&bad, all).is_err(), "{bad}");
        }
        // Editoren dürfen nur den Zensurstil ändern
        assert_eq!(s.patched(&json!({ "redactStyle": "pixelate" }), &EDITOR_WINDOW_FIELDS).unwrap().redact_style, RedactStyle::Pixelate);
        for key in ["linkCaptureWithoutConfirm", "hideFromScreenSharing", "saveFolder", "launchAtLogin", "autoUpdate"] {
            assert!(s.patched(&json!({ key: true }), &EDITOR_WINDOW_FIELDS).is_err(), "{key}");
        }
        assert!(s.patched(&json!({ "playSound": false }), &[]).is_err());
        assert!(s.patched(&json!({}), &[]).is_ok());
    }

    #[test]
    fn save_folder_rules() {
        for ok in [
            "",
            r"C:\Users\Anna\Pictures\Knips",
            r"C:\Users\Anna\Pictures\Knips\",
            "d:/Screenshots",
            r"E:\",
            r"C:\Users\Anna\Bilder\Österreich 2026",
            r"C:\Users\Anna\Console",
            r"C:\COM10",
            r"C:\Daten\v1.2",
        ] {
            assert_eq!(check_save_folder(ok), Ok(()), "{ok}");
        }
        for bad in [
            r"\\server\freigabe\Knips",
            "//server/freigabe",
            r"\\?\C:\Knips",
            r"\\.\PhysicalDrive0",
            r"\\?\UNC\server\freigabe",
            "Knips",
            r"Bilder\Knips",
            r"\Knips",
            "C:Knips",
            r"C:\Users\..\Windows",
            r"C:\Users\.\Anna",
            r"C:\Knips:versteckt",
            r"C:\Knips\NUL",
            r"C:\Knips\con.txt",
            r"C:\Knips\COM1",
            r"C:\Knips\lpt9",
            r"C:\Knips\COM¹",
            r"C:\Knips\a<b",
            r"C:\Knips\a|b",
            r"C:\Knips\a?",
            r"C:\Knips\a*",
            r"C:\Knips\name.",
            r"C:\Knips\name ",
            "C:\\Knips\\a\nb",
            r"1:\Knips",
            "https://example.com/knips",
            "file:///C:/Knips",
        ] {
            assert!(check_save_folder(bad).is_err(), "{bad:?}");
        }
        assert!(check_save_folder(&format!(r"C:\{}", "a".repeat(1100))).is_err());
    }

    #[test]
    fn sanitize_clamps_ranges() {
        let mut s = Settings { quick_access_seconds: 0, recording_fps: 500, gif_fps: 0, gif_width: 1, retention_days: 99_999, ..Settings::default() };
        s.sanitize();
        assert_eq!((s.quick_access_seconds, s.recording_fps, s.gif_fps, s.gif_width, s.retention_days), (1, 60, 1, 160, 3650));
    }

    #[test]
    fn appearance_from_settings_window() {
        use serde_json::json;
        let s = Settings::default();
        assert_eq!(s.appearance, Appearance::System);
        let next = s.patched(&json!({ "appearance": "dark" }), &SETTINGS_WINDOW_FIELDS).unwrap();
        assert_eq!(next.appearance, Appearance::Dark);
        assert!(s.patched(&json!({ "appearance": "grau" }), &SETTINGS_WINDOW_FIELDS).is_err());
        assert!(s.patched(&json!({ "appearance": "light" }), &EDITOR_WINDOW_FIELDS).is_err());
        // Ältere settings.json ohne das Feld: Standard „system“.
        let old: Settings = serde_json::from_value(json!({ "playSound": false })).unwrap();
        assert_eq!(old.appearance, Appearance::System);
    }
}
