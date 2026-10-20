// Texte und Kürzel-Typen wie in SettingsSupport.swift / Hotkeys.swift.
import type { HotkeyAction, SensitiveKind, Settings } from "../shared/types";

/** Bereiche der Einstellungen — gleiche Namen wie `SETTINGS_PANES` in src-tauri/src/commands.rs. */
export type Pane = "start" | "general" | "shortcuts" | "recording" | "redaction" | "export" | "storage" | "privacy" | "about";

export const hotkeyTitle: Record<HotkeyAction, string> = {
  captureArea: "Bereich aufnehmen",
  captureWindow: "Fenster aufnehmen",
  captureFullscreen: "Ganzen Bildschirm aufnehmen",
  captureLastArea: "Letzten Bereich wiederholen",
  captureText: "Text aus Bereich erfassen",
  captureScrolling: "Scroll-Screenshot",
  toggleRecording: "Bildschirmaufnahme starten/stoppen",
  pinClipboard: "Bild aus Zwischenablage anpinnen",
};

export const kindLongTitle: Record<SensitiveKind, string> = {
  email: "E-Mail-Adressen",
  iban: "IBANs",
  phone: "Telefonnummern",
  card: "Kreditkartennummern",
  secret: "API-Schlüssel, Tokens, Passwörter",
  ip: "IP-Adressen",
};

export const kindExample: Record<SensitiveKind, string> = {
  email: "name@example.com",
  iban: "DE89 3704 0044 0532 0130 00 (mit Prüfsumme)",
  phone: "+49 170 1234567, 030 1234567",
  card: "4111 1111 1111 1111 (mit Luhn-Prüfung)",
  secret: "sk_live_…, ghp_…, xoxb-…, AKIA…, JWT, „Passwort: …“",
  ip: "192.168.178.1",
};

export const kindOrder: SensitiveKind[] = ["email", "iban", "phone", "card", "secret", "ip"];

export const styleTitle = { pixelate: "Verpixeln", blur: "Unschärfe", solid: "Balken" } as const;

export const VK_SNAPSHOT = 0x2c;

/** Eingeschaltete Kürzel mit Tastenkombination. */
export function activeHotkeys(s: Settings): HotkeyAction[] {
  return (Object.keys(s.hotkeys) as HotkeyAction[]).filter((a) => !!s.hotkeys[a] && !s.disabledHotkeys.includes(a));
}

/** Liegt ein eingeschaltetes Kürzel auf der Druck-Taste? */
export function usesPrintKey(s: Settings): boolean {
  return activeHotkeys(s).some((a) => s.hotkeys[a]!.vk === VK_SNAPSHOT);
}

/** „1 Schritt“, „2 Schritte“. */
export function steps(n: number): string {
  return n === 1 ? "1 Schritt" : `${n} Schritte`;
}
