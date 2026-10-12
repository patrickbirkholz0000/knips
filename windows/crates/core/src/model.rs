//! Datenmodell — 1:1 nach `Store/CaptureStore.swift`, `Editor/Annotation.swift`, `Support/Settings.swift`.
//! JSON in camelCase; die TypeScript-Gegenstücke stehen in `windows/src/shared/types.ts`.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::geometry::{Point, Rect};

pub type Id = Uuid;

/// Farbe 0…1 (sRGB), wie `RGBA` in Annotation.swift.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    #[serde(default = "one")]
    pub a: f64,
}

fn one() -> f64 {
    1.0
}

impl Rgba {
    pub const fn new(r: f64, g: f64, b: f64) -> Self {
        Self { r, g, b, a: 1.0 }
    }
    pub fn luminance(&self) -> f64 {
        0.2126 * self.r + 0.7152 * self.g + 0.0722 * self.b
    }
    pub const RED: Rgba = Rgba::new(1.0, 0.23, 0.19);
    pub const ORANGE: Rgba = Rgba::new(1.0, 0.58, 0.0);
    pub const YELLOW: Rgba = Rgba::new(1.0, 0.8, 0.0);
    pub const GREEN: Rgba = Rgba::new(0.2, 0.78, 0.35);
    pub const BLUE: Rgba = Rgba::new(0.0, 0.48, 1.0);
    pub const PURPLE: Rgba = Rgba::new(0.69, 0.32, 0.87);
    pub const BLACK: Rgba = Rgba::new(0.08, 0.08, 0.09);
    pub const WHITE: Rgba = Rgba::new(1.0, 1.0, 1.0);
    pub const PALETTE: [Rgba; 8] = [
        Rgba::RED,
        Rgba::ORANGE,
        Rgba::YELLOW,
        Rgba::GREEN,
        Rgba::BLUE,
        Rgba::PURPLE,
        Rgba::BLACK,
        Rgba::WHITE,
    ];
}

impl Default for Rgba {
    fn default() -> Self {
        Rgba::RED
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash)]
#[serde(rename_all = "lowercase")]
pub enum AnnotationKind {
    Arrow,
    Line,
    Rectangle,
    Ellipse,
    Text,
    Counter,
    Highlight,
    Redact,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash, Default)]
#[serde(rename_all = "lowercase")]
pub enum StrokeSize {
    Small,
    #[default]
    Medium,
    Large,
}

impl StrokeSize {
    fn index(self) -> usize {
        match self {
            StrokeSize::Small => 0,
            StrokeSize::Medium => 1,
            StrokeSize::Large => 2,
        }
    }
    pub fn line_width(self) -> f64 {
        [3.0, 5.0, 8.0][self.index()]
    }
    pub fn font_size(self) -> f64 {
        [16.0, 24.0, 36.0][self.index()]
    }
    pub fn counter_radius(self) -> f64 {
        [11.0, 15.0, 21.0][self.index()]
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash, Default)]
#[serde(rename_all = "lowercase")]
pub enum RedactStyle {
    Pixelate,
    Blur,
    #[default]
    Solid,
}

impl RedactStyle {
    pub fn title(self) -> &'static str {
        match self {
            RedactStyle::Pixelate => "Verpixeln",
            RedactStyle::Blur => "Unschärfe",
            RedactStyle::Solid => "Balken",
        }
    }
}

/// Alle Koordinaten in Pixeln des Originalbildes, Ursprung oben links.
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Annotation {
    pub id: Id,
    pub kind: AnnotationKind,
    pub start: Point,
    pub end: Point,
    #[serde(default)]
    pub color: Rgba,
    #[serde(default)]
    pub size: StrokeSize,
    #[serde(default)]
    pub filled: bool,
    #[serde(default)]
    pub text: String,
    #[serde(default = "default_number")]
    pub number: i32,
    #[serde(default = "default_annotation_redact")]
    pub redact_style: RedactStyle,
    /// Von der Auto-Zensur vorgeschlagen.
    #[serde(default)]
    pub auto: bool,
}

fn default_number() -> i32 {
    1
}
fn default_annotation_redact() -> RedactStyle {
    RedactStyle::Pixelate
}

impl Annotation {
    pub fn new(kind: AnnotationKind, start: Point, end: Point) -> Self {
        Self {
            id: Uuid::new_v4(),
            kind,
            start,
            end,
            color: Rgba::RED,
            size: StrokeSize::Medium,
            filled: false,
            text: String::new(),
            number: 1,
            redact_style: RedactStyle::Pixelate,
            auto: false,
        }
    }
    pub fn rect(&self) -> Rect {
        Rect::from_points(self.start, self.end)
    }
}

/// Hintergrund und Rahmen („Beautify“). Maße in Punkten.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct FrameStyle {
    pub gradient: usize,
    pub padding: f64,
    pub corner_radius: f64,
    pub shadow: bool,
}

impl Default for FrameStyle {
    fn default() -> Self {
        Self { gradient: 0, padding: 48.0, corner_radius: 12.0, shadow: true }
    }
}

/// Name und zwei Farben (Verlauf unten links → oben rechts), wie `FrameStyle.gradients`.
pub const FRAME_GRADIENTS: [(&str, [Rgba; 2]); 6] = [
    ("Indigo", [Rgba::new(0.39, 0.40, 0.95), Rgba::new(0.66, 0.33, 0.97)]),
    ("Abendrot", [Rgba::new(0.98, 0.45, 0.09), Rgba::new(0.93, 0.28, 0.60)]),
    ("Ozean", [Rgba::new(0.02, 0.71, 0.83), Rgba::new(0.23, 0.51, 0.96)]),
    ("Minze", [Rgba::new(0.65, 0.95, 0.82), Rgba::new(0.20, 0.78, 0.55)]),
    ("Graphit", [Rgba::new(0.22, 0.25, 0.32), Rgba::new(0.07, 0.09, 0.15)]),
    ("Hell", [Rgba::new(0.96, 0.96, 0.97), Rgba::new(0.88, 0.89, 0.91)]),
];

/// Bearbeitungsstand eines Bildes — liegt neben dem Original, nie im Ablageordner.
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ImageDocument {
    #[serde(default = "one_u32")]
    pub version: u32,
    #[serde(default)]
    pub annotations: Vec<Annotation>,
    #[serde(default)]
    pub crop: Option<Rect>,
    #[serde(default)]
    pub frame: Option<FrameStyle>,
}

fn one_u32() -> u32 {
    1
}

impl Default for ImageDocument {
    fn default() -> Self {
        Self { version: 1, annotations: vec![], crop: None, frame: None }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash)]
#[serde(rename_all = "lowercase")]
pub enum CaptureKind {
    Image,
    Video,
    Gif,
}

/// Eine Aufnahme. `file_path` ist die sichtbare Datei im Ablageordner — immer die gerenderte
/// (zensierte) Fassung. Original, Bearbeitungsstand und Vorschaubild liegen in
/// `<items>/<id>/` (siehe Store in `src-tauri/src/store.rs`).
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct CaptureItem {
    pub id: Id,
    pub kind: CaptureKind,
    /// Unix-Zeit in Millisekunden.
    pub created_at: i64,
    pub file_path: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// Pixel pro logischem Punkt der Aufnahme (Windows: DPI/96, z. B. 1,5 oder 2).
    /// Maßstab für Strichstärken und Schriftgrößen im Editor.
    pub scale: f64,
    #[serde(default)]
    pub duration: Option<f64>,
    #[serde(default)]
    pub revision: u32,
    /// Pixel pro Punkt der Datei im Ablageordner (1 bei verkleinerter Ausgabe).
    #[serde(default)]
    pub output_scale: Option<f64>,
}

impl CaptureItem {
    /// Für Anpinnen & Co.: wie groß die Datei auf dem Bildschirm erscheinen soll.
    pub fn display_scale(&self) -> f64 {
        self.output_scale.unwrap_or(self.scale)
    }
    /// Dateiname ohne Endung.
    pub fn title(&self) -> String {
        std::path::Path::new(&self.file_path)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default()
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
pub struct TrackPoint {
    pub time: f64,
    pub rect: Rect,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct VideoRedaction {
    pub id: Id,
    /// Videopixel, Ursprung oben links.
    pub rect: Rect,
    pub start: f64,
    pub end: f64,
    pub style: RedactStyle,
    #[serde(default)]
    pub auto: bool,
    /// Wegpunkte, wenn der Balken bewegtem Inhalt folgt; dazwischen wird linear überblendet.
    #[serde(default)]
    pub track: Option<Vec<TrackPoint>>,
}

impl VideoRedaction {
    pub fn new(rect: Rect, start: f64, end: f64, style: RedactStyle) -> Self {
        Self { id: Uuid::new_v4(), rect, start, end, style, auto: false, track: None }
    }

    /// Position zu Zeitpunkt `t` (mitlaufende Balken linear interpoliert).
    pub fn rect_at(&self, t: f64) -> Rect {
        let Some(track) = self.track.as_ref().filter(|t| !t.is_empty()) else { return self.rect };
        let first = track[0];
        let last = track[track.len() - 1];
        if t <= first.time {
            return first.rect;
        }
        if t >= last.time {
            return last.rect;
        }
        let (mut lo, mut hi) = (0usize, track.len() - 1);
        while hi - lo > 1 {
            let mid = (lo + hi) / 2;
            if track[mid].time <= t {
                lo = mid
            } else {
                hi = mid
            }
        }
        let (a, b) = (track[lo], track[hi]);
        let f = (t - a.time) / (b.time - a.time).max(0.0001);
        Rect::new(
            a.rect.x + (b.rect.x - a.rect.x) * f,
            a.rect.y + (b.rect.y - a.rect.y) * f,
            a.rect.width + (b.rect.width - a.rect.width) * f,
            a.rect.height + (b.rect.height - a.rect.height) * f,
        )
    }

    /// Ist das Feld zum Zeitpunkt `t` aktiv (wie `RedactionState.active`)?
    pub fn is_active(&self, t: f64) -> bool {
        t >= self.start - 0.0005 && t <= self.end + 0.0005
    }
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct VideoDocument {
    #[serde(default = "one_u32")]
    pub version: u32,
    #[serde(default)]
    pub trim_start: Option<f64>,
    #[serde(default)]
    pub trim_end: Option<f64>,
    #[serde(default)]
    pub redactions: Vec<VideoRedaction>,
}

impl Default for VideoDocument {
    fn default() -> Self {
        Self { version: 1, trim_start: None, trim_end: None, redactions: vec![] }
    }
}

impl VideoDocument {
    pub fn has_edits(&self) -> bool {
        self.trim_start.is_some() || self.trim_end.is_some() || !self.redactions.is_empty()
    }
    /// Aktive Felder zum Zeitpunkt `t`, jeweils an ihrer Position zu `t`.
    pub fn active_at(&self, t: f64) -> Vec<(Rect, RedactStyle)> {
        self.redactions.iter().filter(|r| r.is_active(t)).map(|r| (r.rect_at(t), r.style)).collect()
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash, Default)]
#[serde(rename_all = "lowercase")]
pub enum ImageFormat {
    #[default]
    Png,
    Jpeg,
}

impl ImageFormat {
    pub fn extension(self) -> &'static str {
        match self {
            ImageFormat::Png => "png",
            ImageFormat::Jpeg => "jpg",
        }
    }
    pub fn from_extension(ext: &str) -> Option<Self> {
        match ext.to_ascii_lowercase().as_str() {
            "png" => Some(ImageFormat::Png),
            "jpg" | "jpeg" => Some(ImageFormat::Jpeg),
            _ => None,
        }
    }
}

/// Erkannte Textzeile mit Wörtern (Pixel, Ursprung oben links). `text` = Wörter mit einem
/// Leerzeichen verbunden — die Zeichenpositionen der Mustererkennung beziehen sich darauf.
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct TextWord {
    pub text: String,
    pub rect: Rect,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct TextLine {
    pub text: String,
    pub rect: Rect,
    pub words: Vec<TextWord>,
}

impl TextLine {
    /// Zeile aus Wörtern: Text = Wörter mit Leerzeichen, Rechteck = Vereinigung.
    pub fn from_words(words: Vec<TextWord>) -> Self {
        let text = words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ");
        let rect = words.iter().fold(Rect::NULL, |acc, w| acc.union(&w.rect));
        Self { text, rect, words }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Hash, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum SensitiveKind {
    Email,
    Iban,
    Phone,
    Card,
    Secret,
    Ip,
}

impl SensitiveKind {
    pub const ALL: [SensitiveKind; 6] = [
        SensitiveKind::Email,
        SensitiveKind::Iban,
        SensitiveKind::Phone,
        SensitiveKind::Card,
        SensitiveKind::Secret,
        SensitiveKind::Ip,
    ];
    pub fn title(self) -> &'static str {
        match self {
            SensitiveKind::Email => "E-Mail",
            SensitiveKind::Iban => "IBAN",
            SensitiveKind::Phone => "Telefon",
            SensitiveKind::Card => "Karte",
            SensitiveKind::Secret => "Schlüssel",
            SensitiveKind::Ip => "IP",
        }
    }
}

/// Fund der Auto-Zensur. Pixel, Ursprung oben links.
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Finding {
    pub rect: Rect,
    pub kind: SensitiveKind,
    pub text: String,
}
