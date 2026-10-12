// Attrappen für die Einstellungen (nur ohne Tauri).
import { inTauri, mockEmit, registerMock } from "../shared/ipc";
import { mockBootstrap } from "../shared/mock";
import type { Bootstrap, HotkeyAction, KeyCombo, Settings } from "../shared/types";

const names: Record<number, string> = { 0x2c: "Druck", 0x20: "Leertaste" };
function label(c: KeyCombo): string {
  const m = [c.mods & 2 ? "Strg" : "", c.mods & 1 ? "Alt" : "", c.mods & 4 ? "Umschalt" : "", c.mods & 8 ? "Win" : ""].filter(Boolean);
  const key = names[c.vk] ?? (c.vk >= 0x30 && c.vk <= 0x5a ? String.fromCharCode(c.vk) : `#${c.vk}`);
  return [...m, key].join("+");
}

if (!inTauri) {
  let boot: Bootstrap = structuredClone(mockBootstrap);
  const labels = (s: Settings) => {
    const out: Bootstrap["hotkeyLabels"] = {};
    for (const [a, c] of Object.entries(s.hotkeys)) if (c) out[a as HotkeyAction] = label(c);
    return out;
  };
  const push = (patch: Partial<Bootstrap> = {}, sp: Partial<Settings> = {}) => {
    const settings = { ...boot.settings, ...sp };
    boot = { ...boot, ...patch, settings, hotkeyLabels: labels(settings) };
    mockEmit("bootstrap-changed", boot);
    return settings;
  };
  const combo = (vk: number, mods: number): KeyCombo => ({ vk, mods });
  registerMock("get_bootstrap", () => boot);
  registerMock("set_settings", ({ patch }) =>
    push(patch.saveFolder ? { paths: { ...boot.paths, saveFolder: patch.saveFolder } } : {}, patch));
  registerMock("hotkey_record", ({ action }) => {
    setTimeout(() => {
      const c = combo(0x53, 12);
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
  registerMock("choose_save_folder", () => "D:\\Aufnahmen\\Knips");
  registerMock("purge_originals", () => {});
  registerMock("open_url", () => {});
  registerMock("open_save_folder", () => {});
}
