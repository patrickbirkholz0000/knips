import { inTauri, registerMock } from "../shared/ipc";

if (!inTauri) {
  for (const c of ["item_copy", "item_open", "item_reveal", "item_delete", "item_start_drag"]) registerMock(c, () => undefined);
  // Leerer Verlauf zum Ansehen: „leer“ in der Adresse.
  if (/leer/.test(globalThis.location?.href ?? "")) registerMock("list_items", () => []);
}
