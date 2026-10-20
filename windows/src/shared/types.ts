// Gegenstücke zu den Rust-Typen in crates/core/src/{geometry,model,settings}.rs (JSON in camelCase).
// Alle Bildkoordinaten in Pixeln des Originals, Ursprung oben links.

export type Id = string;

export interface Point {
  x: number;
  y: number;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface Rgba {
  r: number;
  g: number;
  b: number;
  a: number;
}

export type AnnotationKind = "arrow" | "line" | "rectangle" | "ellipse" | "text" | "counter" | "highlight" | "redact";
export type StrokeSize = "small" | "medium" | "large";
export type RedactStyle = "pixelate" | "blur" | "solid";
export type ImageFormat = "png" | "jpeg";
export type CaptureKind = "image" | "video" | "gif";
export type SensitiveKind = "email" | "iban" | "phone" | "card" | "secret" | "ip";
export type HotkeyAction =
  | "captureArea"
  | "captureWindow"
  | "captureFullscreen"
  | "captureLastArea"
  | "captureText"
  | "captureScrolling"
  | "toggleRecording"
  | "pinClipboard";
export type EditorTool =
  | "select"
  | "arrow"
  | "rectangle"
  | "ellipse"
  | "line"
  | "text"
  | "counter"
  | "highlight"
  | "redact"
  | "crop";

export interface Annotation {
  id: Id;
  kind: AnnotationKind;
  start: Point;
  end: Point;
  color: Rgba;
  size: StrokeSize;
  filled: boolean;
  text: string;
  number: number;
  redactStyle: RedactStyle;
  auto: boolean;
}

export interface FrameStyle {
  gradient: number;
  padding: number;
  cornerRadius: number;
  shadow: boolean;
}

export interface ImageDocument {
  version: number;
  annotations: Annotation[];
  crop: Rect | null;
  frame: FrameStyle | null;
}

export interface CaptureItem {
  id: Id;
  kind: CaptureKind;
  /** Unix-Zeit in ms. */
  createdAt: number;
  /** Sichtbare Datei im Ablageordner (immer die gerenderte, zensierte Fassung). */
  filePath: string;
  pixelWidth: number;
  pixelHeight: number;
  /** Pixel pro logischem Punkt der Aufnahme (DPI/96). */
  scale: number;
  duration: number | null;
  revision: number;
  outputScale: number | null;
}

export interface TrackPoint {
  time: number;
  rect: Rect;
}

export interface VideoRedaction {
  id: Id;
  rect: Rect;
  start: number;
  end: number;
  style: RedactStyle;
  auto: boolean;
  track: TrackPoint[] | null;
}

export interface VideoDocument {
  version: number;
  trimStart: number | null;
  trimEnd: number | null;
  redactions: VideoRedaction[];
}

export interface TextWord {
  text: string;
  rect: Rect;
}

export interface TextLine {
  text: string;
  rect: Rect;
  words: TextWord[];
}

export interface Finding {
  rect: Rect;
  kind: SensitiveKind;
  text: string;
}

/** Windows-Virtual-Key + Modifier-Bits (MOD_ALT=1, MOD_CONTROL=2, MOD_SHIFT=4, MOD_WIN=8). */
export interface KeyCombo {
  vk: number;
  mods: number;
}

export interface EditorPrefs {
  tool: EditorTool | null;
  color: Rgba | null;
  size: StrokeSize | null;
  lastFrameStyle: FrameStyle | null;
}

export interface Settings {
  saveFolder: string;
  copyToClipboard: boolean;
  showQuickAccess: boolean;
  quickAccessAutoHide: boolean;
  quickAccessSeconds: number;
  openEditorAfterCapture: boolean;
  playSound: boolean;
  recordingFps: number;
  recordingShowCursor: boolean;
  recordingCountdown: boolean;
  recordingMicrophone: boolean;
  recordingAtScreenSize: boolean;
  recordingHevc: boolean;
  recordingShowClicks: boolean;
  gifFps: number;
  gifWidth: number;
  redactStyle: RedactStyle;
  exportAtScreenSize: boolean;
  imageFormat: ImageFormat;
  showAutoRedact: boolean;
  autoRedactKinds: SensitiveKind[];
  retentionDays: number;
  disabledHotkeys: HotkeyAction[];
  hotkeys: Partial<Record<HotkeyAction, KeyCombo>>;
  launchAtLogin: boolean;
  /** knips://fullscreen, knips://last und knips://record (Start) ohne Rückfrage ausführen (Standard: aus). */
  linkCaptureWithoutConfirm: boolean;
  editor: EditorPrefs;
  didFirstLaunch: boolean;
  askedShortcutTakeover: boolean;
  tookSnippingKey: boolean;
  settingsVersion: number;
}

export interface VideoInfo {
  duration: number;
  width: number;
  height: number;
  fps: number;
  hevc: boolean;
  hasAudio: boolean;
}

/** Alles, was ein Fenster beim Start braucht; kommt bei jeder Änderung erneut als Ereignis `bootstrap-changed`. */
export interface Bootstrap {
  settings: Settings;
  /** Anzeige je Kürzel, z. B. „Druck“, „Alt+Druck“, „Win+Umschalt+S“. Fehlt = nicht belegt. */
  hotkeyLabels: Partial<Record<HotkeyAction, string>>;
  /** Kürzel, die nicht registriert werden konnten. */
  hotkeyFailures: HotkeyAction[];
  /** Windows 11: „Druck-Taste öffnet Bildschirmausschnitt“ ist an. */
  snippingKeyEnabled: boolean;
  paths: {
    /** Originale, Bearbeitungsstand, Vorschaubilder: <itemsDir>\<id>\{original.png|original.mp4, document.json, thumb.png} */
    itemsDir: string;
    /** Aufgelöster Ablageordner (Standard: Bilder\Knips). */
    saveFolder: string;
    /** Standard-Ablageordner (zum Zurücksetzen). */
    defaultSaveFolder: string;
  };
  /** "windows" in der echten App, "mock" in der Attrappe (Mac/Browser). */
  platform: "windows" | "mock";
  version: string;
  ocrAvailable: boolean;
  hevcAvailable: boolean;
  /** Anonyme Nutzungsstatistik: null = noch nicht beantwortet (beim nächsten Start wird wieder gefragt). */
  telemetryConsent: boolean | null;
}

export type RecordingPhase = "idle" | "countdown" | "recording" | "finishing";

export interface RecordingState {
  phase: RecordingPhase;
  /** 3, 2, 1 während des Countdowns. */
  countdown: number;
  /** Sekunden seit Aufnahmebeginn. */
  elapsed: number;
}

export interface ScrollState {
  active: boolean;
  sections: number;
  /** Höhe so, wie sie in der gespeicherten Datei herauskommt (1× oder volle Auflösung). */
  outputHeight: number;
}

export interface CardsState {
  /** Älteste zuerst — die neueste Karte sitzt unten, am nächsten an der Ecke. */
  cards: CaptureItem[];
  /** Karten pro Spalte (aus der Höhe des Arbeitsbereichs). */
  rows: number;
}

export type HudIcon = "check" | "text" | "search" | "error" | "trash" | "dashed" | "pin" | "copy";

export interface HudMessage {
  text: string;
  icon: HudIcon;
}

export interface EditorSession {
  item: CaptureItem;
  document: ImageDocument;
  /** Original in voller Auflösung (für convertFileSrc). */
  originalPath: string;
  /** Pixel pro Punkt (max(1, item.scale)) — Maßstab für Strichstärken und Schrift. */
  scale: number;
  /** Werkzeug, mit dem der Editor starten soll (z. B. aus „Zensieren“), sonst null. */
  initialTool: EditorTool | null;
}

export interface VideoSession {
  item: CaptureItem;
  document: VideoDocument;
  /** Original-MP4 (für convertFileSrc / <video>). */
  sourcePath: string;
  info: VideoInfo;
  scale: number;
}

export interface PinInfo {
  /** PNG in voller Auflösung (für convertFileSrc). */
  path: string;
  pixelWidth: number;
  pixelHeight: number;
  /** Pixel pro Punkt — so groß soll das Bild erscheinen. */
  scale: number;
}

export interface HotkeyRecorded {
  action: HotkeyAction;
  result: "combo" | "remove" | "cancel";
  combo: KeyCombo | null;
}

export interface Progress {
  /** Fenster/Aufgabe, z. B. Item-ID. */
  id: string;
  /** 0…1 */
  progress: number;
}
