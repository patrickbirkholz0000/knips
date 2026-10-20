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

    /// Tasten, die beim normalen Tippen nicht vorkommen — dürfen ohne Strg/Alt/Win belegt werden
    /// (Druck, Pause, Rollen, F1–F24, Einfg).
    pub fn is_standalone_key(vk: u32) -> bool {
        matches!(vk, 0x2C | 0x13 | 0x91 | 0x2D) || (0x70..=0x87).contains(&vk)
    }

    /// Wie `KeyCombo(event:)` auf dem Mac: ohne Strg/Alt/Win wäre eine normale Taste beim Tippen belegt.
    pub fn is_valid(&self) -> bool {
        if matches!(self.vk, 0x10 | 0x11 | 0x12 | 0x5B | 0x5C | 0xA0..=0xA5) {
            return false; // reine Modifier
        }
        self.mods & (MOD_CONTROL | MOD_ALT | MOD_WIN) != 0 || Self::is_standalone_key(self.vk)
    }

    /// Braucht den Tastatur-Hook statt `RegisterHotKey` (Windows reserviert Win-Kombinationen).
    pub fn needs_hook(&self) -> bool {
        self.mods & MOD_WIN != 0
    }

    /// Anzeige wie in Windows: „Strg+Umschalt+4“, „Alt+Druck“, „Win+Umschalt+S“.
    pub fn display(&self) -> String {
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

/// Deutscher Tastenname für einen Virtual-Key.
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
    pub editor: EditorPrefs,
    // Interne Merker (Mac: einzelne UserDefaults-Schlüssel).
    pub did_first_launch: bool,
    pub asked_shortcut_takeover: bool,
    /// Knips hat „Druck-Taste öffnet Bildschirmausschnitt“ abgeschaltet.
    pub took_snipping_key: bool,
    pub settings_version: u32,
}

impl Settings {
    pub const QUICK_ACCESS_SECONDS: std::ops::RangeInclusive<u32> = 1..=3600;
    pub const VERSION: u32 = 1;

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
        self.quick_access_seconds = self.quick_access_seconds.clamp(1, 3600);
        self.recording_fps = self.recording_fps.clamp(5, 60);
        self.gif_fps = self.gif_fps.clamp(1, 50);
        self.gif_width = self.gif_width.clamp(160, 3840);
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
            editor: EditorPrefs::default(),
            did_first_launch: false,
            asked_shortcut_takeover: false,
            took_snipping_key: false,
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
        assert!(!KeyCombo::new(0x41, MOD_SHIFT).is_valid());
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
    }
}
