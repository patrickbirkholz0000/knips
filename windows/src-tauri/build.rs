/// Media Foundation (Video) fehlt in Windows-N/KN-Editionen ohne „Media Feature Pack“. Statisch
/// gelinkt würde Knips dort gar nicht starten („mfplat.dll nicht gefunden“). Die DLLs werden deshalb
/// erst beim ersten Aufruf geladen; vorher prüft `knips_platform::media::available()`, ob es sie gibt
/// (sonst sind Videofunktionen gesperrt, Screenshots gehen weiter). Muss zu `win/media/util.rs::MF_DLLS`
/// passen; der Selbsttest `nomedia` prüft die Importtabelle der fertigen knips.exe.
const DELAY_LOAD: [&str; 3] = ["mfplat.dll", "mfreadwrite.dll", "mf.dll"];

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
    tauri_build::build()
}
