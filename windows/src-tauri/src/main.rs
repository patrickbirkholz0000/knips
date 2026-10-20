// Kein Konsolenfenster im Release-Build.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod app;
mod cards;
mod commands;
mod coordinator;
mod crash;
mod editor;
mod hotkeys;
mod hud;
mod links;
mod menu;
mod paths;
mod pins;
mod promise;
mod recording;
mod scroll;
#[cfg(feature = "dev")]
mod pe;
#[cfg(feature = "dev")]
mod selftest;
#[cfg(feature = "dev")]
mod selftest_media;
mod settings;
mod store;
mod telemetry;
mod tray;
mod video;
mod wm;

use tauri::{Manager, RunEvent, WindowEvent};

fn main() {
    crash::install_panic_hook();
    let args: Vec<String> = std::env::args().collect();
    #[cfg(feature = "dev")]
    if args.get(1).map(String::as_str) == Some("--selftest") {
        if let Some(code) = selftest::run(&args[2..]) {
            std::process::exit(code);
        }
    }
    run(args);
}

fn run(args: Vec<String>) {
    let mut builder = tauri::Builder::default();
    // Zweiter Start (z. B. knips://area aus Stream Deck) → an die laufende Instanz.
    if paths::test_root().is_none() {
        builder = builder.plugin(tauri_plugin_single_instance::init(|_app, argv, _cwd| {
            for arg in argv.iter().filter(|a| a.starts_with("knips://")) {
                app::handle_url(arg);
            }
        }));
    }
    let app = builder
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                .target(tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::LogDir { file_name: Some("knips".into()) }))
                .target(tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout))
                .build(),
        )
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_deep_link::init())
        .setup(move |app| {
            app::setup(app.handle())?;
            {
                use tauri_plugin_deep_link::DeepLinkExt;
                #[cfg(windows)]
                if paths::test_root().is_none() {
                    let _ = app.deep_link().register_all();
                }
                app.deep_link().on_open_url(|event| {
                    for url in event.urls() {
                        app::handle_url(url.as_str());
                    }
                });
            }
            for arg in args.iter().filter(|a| a.starts_with("knips://")) {
                app::handle_url(arg);
            }
            #[cfg(feature = "dev")]
            selftest::after_setup(app.handle());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_bootstrap,
            commands::set_settings,
            commands::set_editor_prefs,
            commands::hotkey_record,
            commands::hotkey_record_cancel,
            commands::hotkeys_reset_defaults,
            commands::hotkeys_preset_mac,
            commands::snipping_takeover,
            commands::snipping_restore,
            commands::list_items,
            commands::item_copy,
            commands::item_copy_text,
            commands::item_pin,
            commands::item_reveal,
            commands::item_delete,
            commands::item_open,
            commands::item_start_drag,
            commands::perform,
            commands::open_image_file,
            commands::open_save_folder,
            commands::open_settings,
            commands::open_history,
            commands::open_url,
            commands::quit_app,
            commands::menu_resize,
            commands::menu_close,
            commands::choose_save_folder,
            commands::storage_size,
            commands::purge_originals,
            commands::clipboard_text,
            commands::hud,
            commands::get_cards,
            commands::cards_hover,
            commands::cards_dismiss,
            commands::cards_dismiss_all,
            commands::cards_layout,
            commands::pin_info,
            commands::pin_copy,
            commands::get_recording_state,
            commands::recording_stop,
            commands::get_scroll_state,
            commands::scroll_finish,
            commands::editor_open,
            commands::editor_text_lines,
            commands::editor_detect,
            commands::editor_stage,
            commands::editor_commit,
            commands::video_open,
            commands::video_thumbnails,
            commands::video_detect,
            commands::video_track,
            commands::video_save,
            commands::video_export_gif,
            commands::video_cancel,
            commands::telemetry_set_consent,
            commands::telemetry_count,
            commands::link_confirm_decide,
            #[cfg(feature = "dev")]
            selftest::selftest_report,
            #[cfg(feature = "dev")]
            selftest::selftest_probe,
        ])
        .build(tauri::generate_context!())
        .expect("Knips konnte nicht starten");

    app.run(|handle, event| match event {
        // Menüleisten-App: ohne offene Fenster weiterlaufen; nur „Beenden“ beendet.
        RunEvent::ExitRequested { api, code: None, .. } => api.prevent_exit(),
        RunEvent::WindowEvent { label, event: WindowEvent::Destroyed, .. } => app::on_window_destroyed(&label),
        RunEvent::Exit => {
            let _ = handle.webview_windows();
        }
        _ => {}
    });
}
