//! Abstürze (Panics) sichtbar machen und Zustand danach aufräumen.
//!
//! Die App läuft ohne Konsole: Ein Panic in einem Hintergrund-Thread verschwand bisher spurlos, und
//! Merker wie „Overlay wird vorbereitet“ blieben stehen — danach wurde jede Bereichsaufnahme still
//! ignoriert. Deshalb: Panic-Hook ins Log (`%LOCALAPPDATA%\de.birkgroup.knips\logs\knips.log`) und
//! `OnDrop`-Wächter, die Merker auch beim Abwickeln eines Panics zurücksetzen (`panic = "unwind"`).

/// Schreibt jeden Panic mit Thread, Stelle und Rückverfolgung ins Log; die Standardausgabe (stderr)
/// bleibt wie gehabt. So früh wie möglich in `main` aufrufen.
pub fn install_panic_hook() {
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current();
        let name = thread.name().unwrap_or("ohne Namen");
        let message = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| (*s).to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "(ohne Text)".into());
        let place = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_else(|| "?".into());
        let trace = std::backtrace::Backtrace::force_capture();
        log::error!("Absturz im Thread „{name}“ bei {place}: {message}\n{trace}");
        default(info);
    }));
}

/// Führt die Funktion beim Verlassen des Bereichs aus — auch, wenn ein Panic ihn verlässt.
pub struct OnDrop<F: FnMut()>(pub F);

impl<F: FnMut()> Drop for OnDrop<F> {
    fn drop(&mut self) {
        (self.0)();
    }
}
