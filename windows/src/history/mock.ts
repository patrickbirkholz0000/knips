import { inTauri, registerMock } from "../shared/ipc";

if (!inTauri) {
  for (const c of ["item_copy", "item_open", "item_reveal", "item_delete", "item_start_drag"]) registerMock(c, () => undefined);
}
