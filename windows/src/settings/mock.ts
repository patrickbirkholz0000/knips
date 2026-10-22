// Attrappen für die Einstellungen (nur ohne Tauri).
import { inTauri, mockEmit, registerMock } from "../shared/ipc";
import { mockBootstrap } from "../shared/mock";
import type { Bootstrap, HotkeyAction, KeyCombo, Settings } from "../shared/types";

const names: Record<number, string> = { 0x2c: "Druck", 0x20: "Leertaste", 0x24: "Pos1", 0x23: "Ende" };
/** Wie `KeyCombo::display` in Rust: Win, Strg, Alt, Umschalt, Taste. */
function label(c: KeyCombo): string {
  const m = [c.mods & 8 ? "Win" : "", c.mods & 2 ? "Strg" : "", c.mods & 1 ? "Alt" : "", c.mods & 4 ? "Umschalt" : ""].filter(Boolean);
  const key = names[c.vk] ?? (c.vk >= 0x30 && c.vk <= 0x5a ? String.fromCharCode(c.vk) : c.vk >= 0x70 && c.vk <= 0x87 ? `F${c.vk - 0x6f}` : `#${c.vk}`);
  return [...m, key].join("+");
}

/** Grob wie `typing_note` in Rust: Buchstaben, Ziffern, Leertaste, Pos1/Ende, Pfeile ohne Strg/Alt/Win. */
function note(c: KeyCombo): string | undefined {
  const typing = (c.mods & 11) === 0 && ((c.vk >= 0x20 && c.vk <= 0x28) || (c.vk >= 0x30 && c.vk <= 0x5a));
  return typing ? `${label(c)} wirkt jetzt überall – in anderen Apps geht ${label(c)} dann nicht mehr.` : undefined;
}

if (!inTauri) {
  // Zum Ansehen des Bereit-Checks mit offenen Schritten: „fehlt“ in der Adresse (Kürzel belegt, Ablage weg;
  // zusammen mit „nomedia“ auch ohne Video).
  const missing = /fehlt/.test(globalThis.location?.href ?? "");
  let boot: Bootstrap = structuredClone(mockBootstrap);
  if (missing) boot.hotkeyFailures = ["captureWindow"];
  // „bereit“: Druck-Taste schon übernommen — alles erledigt.
  if (/bereit/.test(globalThis.location?.href ?? "")) boot = { ...boot, snippingKeyEnabled: false, settings: { ...boot.settings, tookSnippingKey: true } };
  const labels = (s: Settings) => {
    const out: Bootstrap["hotkeyLabels"] = {};
    for (const [a, c] of Object.entries(s.hotkeys)) if (c) out[a as HotkeyAction] = label(c);
    return out;
  };
  const notes = (s: Settings) => {
    const out: Bootstrap["hotkeyNotes"] = {};
    for (const [a, c] of Object.entries(s.hotkeys)) if (c && note(c)) out[a as HotkeyAction] = note(c);
    return out;
  };
  const push = (patch: Partial<Bootstrap> = {}, sp: Partial<Settings> = {}) => {
    const settings = { ...boot.settings, ...sp };
    boot = { ...boot, ...patch, settings, hotkeyLabels: labels(settings), hotkeyNotes: notes(settings) };
    mockEmit("bootstrap-changed", boot);
    return settings;
  };
  const combo = (vk: number, mods: number): KeyCombo => ({ vk, mods });
  registerMock("get_bootstrap", () => boot);
  registerMock("set_settings", ({ patch }) =>
    push(patch.saveFolder ? { paths: { ...boot.paths, saveFolder: patch.saveFolder } } : {}, patch));
  // Zum Ansehen der Aufnahme: „aufnahme“ in der Adresse wartet ohne Ende, „ungueltig“ meldet dazu eine Eingabe, die
  // keine Taste ist; „einzeltaste“ nimmt Pos1 auf (mit Hinweis), sonst Win+Umschalt+S.
  const href = globalThis.location?.href ?? "";
  registerMock("hotkey_record", ({ action }) => {
    if (/ungueltig/.test(href)) {
      const c = combo(0xe7, 0);
      setTimeout(() => mockEmit("hotkey-recorded", { action, result: "invalid", combo: c, message: "Keine Taste erkannt – bitte eine Taste der Tastatur drücken." }), 250);
    }
    if (/aufnahme|ungueltig/.test(href)) return;
    setTimeout(() => {
      const c = /einzeltaste/.test(href) ? combo(0x24, 0) : combo(0x53, 12);
      push({}, { hotkeys: { ...boot.settings.hotkeys, [action]: c } });
      mockEmit("hotkey-recorded", { action, result: "combo", combo: c });
    }, 1800);
  });
  registerMock("hotkey_record_cancel", () => {});
  registerMock("hotkeys_reset_defaults", () =>
    push({}, { hotkeys: { captureArea: combo(0x2c, 0), captureWindow: combo(0x2c, 1), captureFullscreen: combo(0x2c, 2), toggleRecording: combo(0x2c, 4) }, disabledHotkeys: [] }));
  registerMock("hotkeys_preset_mac", () =>
    push({}, { hotkeys: { captureArea: combo(0x34, 12), captureWindow: combo(0x32, 12), captureFullscreen: combo(0x33, 12), toggleRecording: combo(0x35, 12) }, disabledHotkeys: [] }));
  registerMock("snipping_takeover", () => {
    push({ snippingKeyEnabled: false }, { tookSnippingKey: true });
    return true;
  });
  registerMock("snipping_restore", () => void push({ snippingKeyEnabled: true }, { tookSnippingKey: false }));
  registerMock("telemetry_set_consent", ({ consent }) => void push({ telemetryConsent: consent }));
  registerMock("choose_save_folder", () => "D:\\Aufnahmen\\Knips");
  registerMock("save_folder_ok", () => !missing);
  registerMock("purge_originals", () => {});
  registerMock("open_url", () => {});
  registerMock("open_save_folder", () => {});
}
