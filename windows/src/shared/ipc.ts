// IPC-Vertrag zwischen Oberfläche und Rust (src-tauri/src/commands.rs). Jede Funktion hier ist
// genau ein Tauri-Befehl; Ereignisse stehen unten. Ohne Tauri (Browser, Screenshots auf dem Mac)
// antworten Attrappen aus `registerMock` — siehe shared/mock.ts und die mock.ts der Bereiche.

import { invoke as tauriInvoke, convertFileSrc, isTauri } from "@tauri-apps/api/core";
import { listen as tauriListen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  Annotation,
  Bootstrap,
  CaptureItem,
  CardsState,
  EditorPrefs,
  EditorSession,
  EditorTool,
  Finding,
  HotkeyAction,
  HotkeyRecorded,
  HudMessage,
  ImageDocument,
  PinInfo,
  Progress,
  Rect,
  RecordingState,
  RedactStyle,
  ScrollState,
  SensitiveKind,
  Settings,
  TextLine,
  TrackPoint,
  VideoDocument,
  VideoRedaction,
  VideoSession,
} from "./types";

export const inTauri: boolean = isTauri();

// ---------------------------------------------------------------- Attrappen

type MockHandler = (args: any) => any | Promise<any>;
const mocks = new Map<string, MockHandler>();
const mockListeners = new Map<string, Set<(payload: any) => void>>();

/** Attrappe für einen Befehl (nur ohne Tauri aktiv). */
export function registerMock(command: string, handler: MockHandler) {
  mocks.set(command, handler);
}

/** Ereignis in der Attrappe auslösen (z. B. aus Mock-Handlern oder Screenshot-Skripten). */
export function mockEmit(event: string, payload: unknown) {
  mockListeners.get(event)?.forEach((fn) => fn(payload));
}

async function call<T>(command: string, args?: Record<string, unknown>, options?: { headers: Record<string, string> }): Promise<T> {
  if (inTauri) return tauriInvoke<T>(command, args as any, options);
  const handler = mocks.get(command);
  if (!handler) {
    console.warn(`[mock] kein Handler für ${command}`, args);
    return undefined as T;
  }
  return (await handler(args ?? {})) as T;
}

/** Ereignis abonnieren; liefert die Abmeldefunktion. */
export async function on<T>(event: string, handler: (payload: T) => void): Promise<UnlistenFn> {
  if (inTauri) return tauriListen<T>(event, (e) => handler(e.payload));
  let set = mockListeners.get(event);
  if (!set) mockListeners.set(event, (set = new Set()));
  set.add(handler);
  return () => set!.delete(handler);
}

/** Lokale Datei → URL für <img>/<video> (Tauri-Asset-Protokoll; in der Attrappe direkt). */
export function fileUrl(path: string, revision?: number): string {
  const base = inTauri ? convertFileSrc(path) : path;
  return revision === undefined ? base : `${base}${base.includes("?") ? "&" : "?"}r=${revision}`;
}

function join(dir: string, ...parts: string[]): string {
  const sep = dir.includes("\\") ? "\\" : "/";
  return [dir.replace(/[\\/]+$/, ""), ...parts].join(sep);
}

/** Vorschaubild einer Aufnahme (640 px, PNG). */
export function thumbUrl(boot: Bootstrap, item: CaptureItem): string {
  if (!inTauri) return "/mock/sample.png";
  return fileUrl(join(boot.paths.itemsDir, item.id, "thumb.png"), item.revision);
}

/** Datei im Ablageordner (gerenderte Fassung). */
export function itemFileUrl(item: CaptureItem): string {
  if (!inTauri) return "/mock/sample.png";
  return fileUrl(item.filePath, item.revision);
}

export function itemTitle(item: CaptureItem): string {
  const name = item.filePath.split(/[\\/]/).pop() ?? "";
  return name.replace(/\.[^.]+$/, "");
}

// ---------------------------------------------------------------- Befehle

export const api = {
  // Start & Einstellungen
  getBootstrap: () => call<Bootstrap>("get_bootstrap"),
  /** Teiländerung; liefert die neuen Einstellungen. Löst `bootstrap-changed` in allen Fenstern aus. */
  setSettings: (patch: Partial<Settings>) => call<Settings>("set_settings", { patch }),
  /** Editor-Vorlieben (Werkzeug, Farbe, Größe, letzter Rahmen). */
  setEditorPrefs: (patch: Partial<EditorPrefs>) => call<void>("set_editor_prefs", { patch }),

  // Kürzel (Einstellungen)
  /** Nimmt die nächste Tastenkombination auf → Ereignis `hotkey-recorded`. */
  hotkeyRecord: (action: HotkeyAction) => call<void>("hotkey_record", { action }),
  hotkeyRecordCancel: () => call<void>("hotkey_record_cancel"),
  /** Windows-Belegung (Druck, Alt+Druck, Strg+Druck, Umschalt+Druck). */
  hotkeysResetDefaults: () => call<void>("hotkeys_reset_defaults"),
  /** Mac-Belegung (Win+Umschalt+4/2/3/5). */
  hotkeysPresetMac: () => call<void>("hotkeys_preset_mac"),
  /** Druck-Taste vom Bildschirmausschnitt übernehmen (Registry). Liefert true bei Erfolg. */
  snippingTakeover: () => call<boolean>("snipping_takeover"),
  snippingRestore: () => call<void>("snipping_restore"),

  // Aufnahmen
  listItems: () => call<CaptureItem[]>("list_items"),
  itemCopy: (id: string) => call<void>("item_copy", { id }),
  /** Texterkennung auf der gespeicherten (zensierten) Datei → Zwischenablage + Einblendung. */
  itemCopyText: (id: string) => call<void>("item_copy_text", { id }),
  itemPin: (id: string) => call<void>("item_pin", { id }),
  itemReveal: (id: string) => call<void>("item_reveal", { id }),
  itemDelete: (id: string) => call<void>("item_delete", { id }),
  /** Bild → Editor (optional mit Werkzeug), Video → Video-Editor, GIF → Standard-App. */
  itemOpen: (id: string, tool?: EditorTool) => call<void>("item_open", { id, tool: tool ?? null }),
  /** Natives Herausziehen der Datei (aus `onDragStart` aufrufen und dort `preventDefault()`). */
  itemStartDrag: (id: string) => call<void>("item_start_drag", { id }),

  // Menü & Fenster
  perform: (action: HotkeyAction) => call<void>("perform", { action }),
  openImageFile: () => call<void>("open_image_file"),
  openSaveFolder: () => call<void>("open_save_folder"),
  openSettings: (pane?: string) => call<void>("open_settings", { pane: pane ?? null }),
  openHistory: () => call<void>("open_history"),
  openUrl: (url: string) => call<void>("open_url", { url }),
  quitApp: () => call<void>("quit_app"),
  /** Menü-Panel meldet seine Höhe (logische Pixel). */
  menuResize: (height: number) => call<void>("menu_resize", { height }),
  menuClose: () => call<void>("menu_close"),
  chooseSaveFolder: () => call<string | null>("choose_save_folder"),
  storageSize: () => call<number>("storage_size"),
  /** Bereit-Check: Ablageordner vorhanden oder anlegbar (Ort darüber erreichbar)? */
  saveFolderOk: () => call<boolean>("save_folder_ok"),
  purgeOriginals: () => call<void>("purge_originals"),
  clipboardText: (text: string) => call<void>("clipboard_text", { text }),
  hud: (message: HudMessage) => call<void>("hud", { message }),

  // Karten unten links
  getCards: () => call<CardsState>("get_cards"),
  cardsHover: (id: string | null) => call<void>("cards_hover", { id }),
  cardsDismiss: (id: string) => call<void>("cards_dismiss", { id }),
  cardsDismissAll: () => call<void>("cards_dismiss_all"),
  /** Größe des Panels und klickbare Flächen (logische Pixel, Ursprung oben links im Panel). */
  cardsLayout: (width: number, height: number, hit: Rect[]) => call<void>("cards_layout", { width, height, hit }),

  // Anpinnen
  pinInfo: (n: number) => call<PinInfo>("pin_info", { n }),
  pinCopy: (n: number) => call<void>("pin_copy", { n }),

  // Aufnahme- und Scroll-Leisten
  getRecordingState: () => call<RecordingState>("get_recording_state"),
  recordingStop: (save: boolean) => call<void>("recording_stop", { save }),
  getScrollState: () => call<ScrollState>("get_scroll_state"),
  scrollFinish: (save: boolean) => call<void>("scroll_finish", { save }),

  // Bild-Editor
  editorOpen: (id: string) => call<EditorSession>("editor_open", { id }),
  /** Erkannte Zeilen des Originals (Hintergrund; für schlaue Balken und „Text kopieren“). */
  editorTextLines: (id: string) => call<TextLine[]>("editor_text_lines", { id }),
  editorDetect: (id: string, kinds: SensitiveKind[]) => call<Finding[]>("editor_detect", { id, kinds }),
  /** Bearbeitungsstand vormerken; danach `editorCommit` mit den gerenderten Pixeln. */
  editorStage: (id: string, document: ImageDocument) => call<void>("editor_stage", { id, document }),
  /**
   * Gerendertes Bild (volle Auflösung, RGBA, width*height*4 Bytes) übergeben.
   * save: speichern · copy: speichern + kopieren · pin: anpinnen · done: speichern + Fenster schließen.
   * Liefert die aktualisierte Aufnahme.
   */
  editorCommit: (id: string, action: "save" | "copy" | "pin" | "done", width: number, height: number, rgba: Uint8Array) =>
    call<CaptureItem>(
      "editor_commit",
      inTauri ? (rgba as unknown as Record<string, unknown>) : { id, action, width, height, rgba },
      { headers: { "x-knips-id": id, "x-knips-action": action, "x-knips-size": `${width}x${height}` } },
    ),

  // Video-Editor
  videoOpen: (id: string) => call<VideoSession>("video_open", { id }),
  /** `count` Vorschaubilder gleichmäßig über die Länge (Dateipfade). */
  videoThumbnails: (id: string, count: number) => call<string[]>("video_thumbnails", { id, count }),
  /** Fortschritt als Ereignis `video-progress`. */
  videoDetect: (id: string, start: number, end: number, style: RedactStyle, kinds: SensitiveKind[]) =>
    call<VideoRedaction[]>("video_detect", { id, start, end, style, kinds }),
  videoTrack: (id: string, rect: Rect, t0: number, start: number, end: number) =>
    call<TrackPoint[]>("video_track", { id, rect, t0, start, end }),
  /** Exportiert bei Änderungen (gekürzt + zensiert) und ersetzt die Datei im Ablageordner. */
  videoSave: (id: string, document: VideoDocument) => call<CaptureItem>("video_save", { id, document }),
  /** GIF neben der Datei im Ablageordner; erscheint als Karte. */
  videoExportGif: (id: string, document: VideoDocument) => call<CaptureItem>("video_export_gif", { id, document }),
  videoCancel: (id: string) => call<void>("video_cancel", { id }),

  // Anonyme Nutzungsstatistik
  /** Zustimmung (neue Kennung, ab jetzt zählen) oder Ablehnung (Kennung und Zähler löschen). Schließt `#/consent`. */
  telemetrySetConsent: (consent: boolean) => call<void>("telemetry_set_consent", { consent }),
  /** Ereignis zählen, das nur die Oberfläche sieht. Rust nimmt nur Namen aus der Erlaubt-Liste an. */
  telemetryCount: (event: "censor_manual" | "censor_smart") => call<void>("telemetry_count", { event }),

  // Rückfrage vor Aufnahmen per knips://-Link (`#/link-confirm/<befehl>`)
  /**
   * Oberfläche bereit. true, sobald Rust das Fenster als sichtbar bestätigt — ab da läuft die Schutzzeit;
   * false: noch nicht sichtbar, gleich noch einmal fragen.
   */
  linkConfirmShown: () => call<boolean>("link_confirm_shown"),
  /**
   * „Aufnehmen“ (`approved`) oder „Abbrechen“; „Nicht mehr fragen“ zählt nur mit „Aufnehmen“. Gilt nur aus dem
   * Fenster der Rückfrage. Liefert false, wenn nichts passiert ist (Schutzzeit läuft noch). Schließt das Fenster.
   */
  linkConfirmDecide: (approved: boolean, dontAskAgain: boolean) => call<boolean>("link_confirm_decide", { approved, dontAskAgain }),
};

// ---------------------------------------------------------------- Ereignisse

export const events = {
  /** Einstellungen, Kürzel, Pfade geändert. */
  bootstrapChanged: (fn: (b: Bootstrap) => void) => on<Bootstrap>("bootstrap-changed", fn),
  /** Liste aller Aufnahmen (neueste zuerst). */
  itemsChanged: (fn: (items: CaptureItem[]) => void) => on<CaptureItem[]>("items-changed", fn),
  cardsChanged: (fn: (s: CardsState) => void) => on<CardsState>("cards-changed", fn),
  hudShow: (fn: (m: HudMessage) => void) => on<HudMessage>("hud-show", fn),
  recordingState: (fn: (s: RecordingState) => void) => on<RecordingState>("recording-state", fn),
  scrollState: (fn: (s: ScrollState) => void) => on<ScrollState>("scroll-state", fn),
  hotkeyRecorded: (fn: (r: HotkeyRecorded) => void) => on<HotkeyRecorded>("hotkey-recorded", fn),
  videoProgress: (fn: (p: Progress) => void) => on<Progress>("video-progress", fn),
  /** Menü wurde geöffnet (Zuletzt-Liste neu laden, Hover zurücksetzen). */
  menuOpened: (fn: () => void) => on<null>("menu-opened", () => fn()),
  /** Editor soll speichern (z. B. Fenster schließen über die Taskleiste). */
  editorSaveRequest: (fn: (id: string) => void) => on<string>("editor-save-request", fn),
};

export type { Annotation };
