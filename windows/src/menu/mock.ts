import { inTauri, registerMock } from "../shared/ipc";

if (!inTauri) {
  for (const c of ["menu_resize", "menu_close", "perform", "open_image_file", "open_save_folder", "open_settings", "open_history", "quit_app", "item_open", "item_start_drag"]) {
    registerMock(c, () => undefined);
  }
}
