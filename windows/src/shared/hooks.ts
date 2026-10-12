import { useEffect, useState } from "react";
import { api, events } from "./ipc";
import type { Bootstrap, CaptureItem } from "./types";

/** Einstellungen, Kürzel-Anzeigen und Pfade; aktualisiert sich bei jeder Änderung. */
export function useBootstrap(): Bootstrap | null {
  const [boot, setBoot] = useState<Bootstrap | null>(null);
  useEffect(() => {
    let alive = true;
    api.getBootstrap().then((b) => alive && setBoot(b));
    const off = events.bootstrapChanged((b) => alive && setBoot(b));
    return () => {
      alive = false;
      off.then((f) => f());
    };
  }, []);
  return boot;
}

/** Alle Aufnahmen (neueste zuerst). */
export function useItems(): CaptureItem[] {
  const [items, setItems] = useState<CaptureItem[]>([]);
  useEffect(() => {
    let alive = true;
    api.listItems().then((i) => alive && setItems(i ?? []));
    const off = events.itemsChanged((i) => alive && setItems(i));
    return () => {
      alive = false;
      off.then((f) => f());
    };
  }, []);
  return items;
}
