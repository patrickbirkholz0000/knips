// Attrappen für die Karten: 5 Karten bei 3 Zeilen ergeben zwei Spalten (?n=<Anzahl>&rows=<Zeilen> ändert das).
import { inTauri, registerMock } from "../shared/ipc";
import { mockItems } from "../shared/mock";

if (!inTauri) {
  const q = new URLSearchParams(window.location.hash.split("?")[1] ?? "");
  const n = Number(q.get("n") ?? 5);
  const rows = Number(q.get("rows") ?? 3);
  registerMock("get_cards", () => ({ cards: mockItems.slice(0, n).reverse(), rows }));
  for (const c of ["cards_hover", "cards_dismiss", "cards_dismiss_all", "cards_layout", "item_copy", "item_pin", "item_reveal", "item_copy_text", "item_delete", "item_open", "item_start_drag"]) {
    registerMock(c, () => undefined);
  }
}
