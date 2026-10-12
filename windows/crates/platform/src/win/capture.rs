//! TODO(Windows): Startfassung = Kopie der Attrappe. Durch die echte Implementierung ersetzen,
//! Signaturen exakt beibehalten (Referenz: `mock/mod.rs`).

use anyhow::Result;
use knips_core::RgbaImage;

use crate::types::{Frozen, IRect, Monitor, WindowInfo};

/// Standbild aller angegebenen Monitore; eigene Fenster (mit `exclude_from_capture`) fehlen darin.
pub fn freeze(monitors: &[Monitor]) -> Result<Vec<Frozen>> {
    Ok(monitors
        .iter()
        .map(|m| Frozen {
            monitor: m.clone(),
            image: crate::sample::sample_image(m.rect.width as u32, m.rect.height as u32, m.scale),
        })
        .collect())
}

/// Sichtbare Fenster anderer Programme, von vorn nach hinten.
pub fn windows() -> Vec<WindowInfo> {
    vec![WindowInfo {
        hwnd: 42,
        rect: IRect::new(840, 600, 1400, 840),
        title: "Fenster".into(),
        owner: "test.exe".into(),
    }]
}

/// Einzelnes Fenster freigestellt (auch verdeckte Teile), physische Pixel.
pub fn window_image(w: &WindowInfo) -> Result<RgbaImage> {
    Ok(crate::sample::sample_image(w.rect.width as u32, w.rect.height as u32, 2.0))
}

/// Wiederholte Aufnahme eines festen Bereichs (Scroll-Screenshot): eine Sitzung, viele Bilder.
pub struct RegionCapturer {
    rect: IRect,
}

impl RegionCapturer {
    /// `rect`: monitor-lokal, physische Pixel.
    pub fn new(monitor: &Monitor, rect: IRect) -> Result<Self> {
        let _ = monitor;
        Ok(Self { rect })
    }
    /// Aktuelles Bild des Bereichs (eigene Fenster ausgeschlossen, ohne Mauszeiger).
    pub fn grab(&mut self) -> Result<RgbaImage> {
        Ok(crate::sample::sample_image(self.rect.width as u32, self.rect.height as u32, 2.0))
    }
}

/// Fenster aus allen Aufnahmen ausschließen (`WDA_EXCLUDEFROMCAPTURE`) bzw. wieder zulassen.
pub fn exclude_from_capture(hwnd: isize, exclude: bool) {
    let _ = (hwnd, exclude);
}

/// Eigenes Fenster fotografieren (Selbsttests). Darf nicht ausgeschlossen sein.
pub fn own_window_image(hwnd: isize) -> Result<RgbaImage> {
    let _ = hwnd;
    anyhow::bail!("nur unter Windows")
}
