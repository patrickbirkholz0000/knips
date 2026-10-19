// Grund-Attrappen für die Entwicklung ohne Tauri (Browser, Screenshots auf dem Mac).
// Bereiche ergänzen eigene Attrappen in ihrer mock.ts über registerMock.

import { inTauri, mockEmit, registerMock } from "./ipc";
import type { Bootstrap, CaptureItem, Settings } from "./types";

export const mockSettings: Settings = {
  saveFolder: "",
  copyToClipboard: true,
  showQuickAccess: true,
  quickAccessAutoHide: false,
  quickAccessSeconds: 10,
  openEditorAfterCapture: false,
  playSound: true,
  recordingFps: 30,
  recordingShowCursor: true,
  recordingCountdown: true,
  recordingMicrophone: false,
  recordingAtScreenSize: true,
  recordingHevc: false,
  recordingShowClicks: true,
  gifFps: 15,
  gifWidth: 960,
  redactStyle: "solid",
  exportAtScreenSize: true,
  imageFormat: "png",
  showAutoRedact: false,
  autoRedactKinds: ["email", "iban", "phone", "card", "secret", "ip"],
  retentionDays: 30,
  disabledHotkeys: [],
  hotkeys: {
    captureArea: { vk: 0x2c, mods: 0 },
    captureWindow: { vk: 0x2c, mods: 1 },
    captureFullscreen: { vk: 0x2c, mods: 2 },
    toggleRecording: { vk: 0x2c, mods: 4 },
  },
  launchAtLogin: true,
  editor: { tool: null, color: null, size: null, lastFrameStyle: null },
  didFirstLaunch: true,
  askedShortcutTakeover: true,
  tookSnippingKey: false,
  settingsVersion: 1,
};

export const mockBootstrap: Bootstrap = {
  settings: mockSettings,
  hotkeyLabels: {
    captureArea: "Druck",
    captureWindow: "Alt+Druck",
    captureFullscreen: "Strg+Druck",
    toggleRecording: "Umschalt+Druck",
  },
  hotkeyFailures: [],
  snippingKeyEnabled: true,
  paths: {
    itemsDir: "C:\\Users\\Nutzer\\AppData\\Local\\Knips\\items",
    saveFolder: "C:\\Users\\Nutzer\\Pictures\\Knips",
    defaultSaveFolder: "C:\\Users\\Nutzer\\Pictures\\Knips",
  },
  platform: "mock",
  version: "0.1.0",
  ocrAvailable: true,
  hevcAvailable: true,
  telemetryConsent: null,
};

const now = Date.UTC(2026, 9, 12, 14, 3, 27);
function item(i: number, kind: CaptureItem["kind"] = "image"): CaptureItem {
  const ext = kind === "image" ? "png" : kind === "gif" ? "gif" : "mp4";
  const name = kind === "video" ? "Knips Aufnahme" : "Knips";
  return {
    id: `00000000-0000-4000-8000-00000000000${i}`,
    kind,
    createdAt: now - i * 3_600_000,
    filePath: `C:\\Users\\Nutzer\\Pictures\\Knips\\${name} 2026-10-12 um 1${4 - (i % 4)}.0${i}.27.${ext}`,
    pixelWidth: 1400,
    pixelHeight: 880,
    scale: 2,
    duration: kind === "image" ? null : 14,
    revision: 1,
    outputScale: 1,
  };
}

export const mockItems: CaptureItem[] = [item(1), item(2, "video"), item(3), item(4, "gif"), item(5), item(6)];

if (!inTauri) {
  let settings = { ...mockSettings };
  let telemetryConsent: boolean | null = mockBootstrap.telemetryConsent;
  registerMock("get_bootstrap", () => ({ ...mockBootstrap, settings, telemetryConsent }));
  registerMock("telemetry_set_consent", ({ consent }) => {
    telemetryConsent = consent;
    mockEmit("bootstrap-changed", { ...mockBootstrap, settings, telemetryConsent });
  });
  registerMock("telemetry_count", () => {});
  registerMock("set_settings", ({ patch }) => {
    settings = { ...settings, ...patch };
    mockEmit("bootstrap-changed", { ...mockBootstrap, settings });
    return settings;
  });
  registerMock("list_items", () => mockItems);
  registerMock("get_cards", () => ({ cards: mockItems.slice(0, 2).reverse(), rows: 6 }));
  registerMock("storage_size", () => 734_003_200);
  registerMock("get_recording_state", () => ({ phase: "recording", countdown: 0, elapsed: 83 }));
  registerMock("get_scroll_state", () => ({ active: true, sections: 7, outputHeight: 4210 }));
}
