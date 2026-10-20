/// Media Foundation (Video) fehlt in Windows-N/KN-Editionen ohne „Media Feature Pack“. Statisch
/// gelinkt würde Knips dort gar nicht starten („mfplat.dll nicht gefunden“). Die DLLs werden deshalb
/// erst beim ersten Aufruf geladen; vorher prüft `knips_platform::media::available()`, ob es sie gibt
/// (sonst sind Videofunktionen gesperrt, Screenshots gehen weiter). Muss zu `win/media/util.rs::MF_DLLS`
/// passen; der Selbsttest `nomedia` prüft die Importtabelle der fertigen knips.exe.
const DELAY_LOAD: [&str; 3] = ["mfplat.dll", "mfreadwrite.dll", "mf.dll"];

// Eigene Befehle (`commands.rs`, `generate_handler!` in main.rs) bekommen Berechtigungen `allow-<befehl>`.
// Sobald es diese Liste gibt, darf ein Fenster nur noch die Befehle aufrufen, die ihm eine Capability in
// `capabilities/` erlaubt — neue Befehle deshalb hier UND dort eintragen.
const COMMANDS: &[&str] = &[
    "get_bootstrap",
    "set_settings",
    "set_editor_prefs",
    "hotkey_record",
    "hotkey_record_cancel",
    "hotkeys_reset_defaults",
    "hotkeys_preset_mac",
    "snipping_takeover",
    "snipping_restore",
    "list_items",
    "item_copy",
    "item_copy_text",
    "item_pin",
    "item_reveal",
    "item_delete",
    "item_open",
    "item_start_drag",
    "perform",
    "open_image_file",
    "open_save_folder",
    "open_settings",
    "open_history",
    "open_url",
    "quit_app",
    "menu_resize",
    "menu_close",
    "choose_save_folder",
    "storage_size",
    "purge_originals",
    "clipboard_text",
    "hud",
    "get_cards",
    "cards_hover",
    "cards_dismiss",
    "cards_dismiss_all",
    "cards_layout",
    "pin_info",
    "pin_copy",
    "get_recording_state",
    "recording_stop",
    "get_scroll_state",
    "scroll_finish",
    "editor_open",
    "editor_text_lines",
    "editor_detect",
    "editor_stage",
    "editor_commit",
    "video_open",
    "video_thumbnails",
    "video_detect",
    "video_track",
    "video_save",
    "video_export_gif",
    "video_cancel",
    "telemetry_set_consent",
    "telemetry_count",
    "link_confirm_shown",
    "link_confirm_decide",
    // Nur mit Feature `dev` registriert; erlaubt erst die Capability, die `selftest.rs` zur Laufzeit anlegt.
    "selftest_report",
    "selftest_probe",
];

fn main() {
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    if os == "windows" && env == "msvc" {
        for dll in DELAY_LOAD {
            println!("cargo:rustc-link-arg-bins=/DELAYLOAD:{dll}");
        }
        // Lade-Helfer für verzögerte Importe (MSVC-Laufzeit).
        println!("cargo:rustc-link-arg-bins=delayimp.lib");
    }
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)))
        .expect("tauri-build fehlgeschlagen");
}
