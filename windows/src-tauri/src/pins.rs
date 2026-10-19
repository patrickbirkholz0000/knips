//! Angepinnte Bilder: schweben über allen Fenstern (`PinWindowController` in PinWindow.swift).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use anyhow::Result;
use knips_core::imageops;
use knips_core::model::ImageFormat;
use knips_core::RgbaImage;
use knips_platform::monitors;
use parking_lot::Mutex;
use serde::Serialize;

use crate::app::knips;
use crate::promise::ImagePromise;
use crate::{paths, wm};

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct PinInfo {
    pub path: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub scale: f64,
}

#[derive(Default)]
pub struct Pins {
    next: AtomicU32,
    pins: Mutex<HashMap<u32, PinInfo>>,
}

impl Pins {
    /// Bild anpinnen: so groß wie auf dem Bildschirm (`scale` Pixel pro Punkt), höchstens 60 % des
    /// Arbeitsbereichs, mittig unter der Maus.
    pub fn pin(&self, image: Arc<RgbaImage>, scale: f64) -> Result<()> {
        let n = self.next.fetch_add(1, Ordering::SeqCst) + 1;
        let path: PathBuf = paths::temp_dir().join(format!("pin-{n}.png"));
        std::fs::write(&path, imageops::encode(&image, ImageFormat::Png)?)?;
        let info = PinInfo {
            path: path.to_string_lossy().into_owned(),
            pixel_width: image.width(),
            pixel_height: image.height(),
            scale: scale.max(0.1),
        };
        self.pins.lock().insert(n, info.clone());
        let m = monitors::at_cursor();
        let (ww, wh) = m.work_points();
        let mut size = (image.width() as f64 / info.scale, image.height() as f64 / info.scale);
        let f = (ww * 0.6 / size.0).min(wh * 0.6 / size.1).min(1.0);
        size = (size.0 * f, size.1 * f);
        let k = knips();
        let mut spec = wm::Spec::floating(&format!("pin-{n}"), &format!("pin/{n}"), size);
        spec.resizable = true;
        spec.focusable = true;
        let window = wm::ensure(&k.app, &spec)?;
        let (cx, cy) = monitors::cursor_pos();
        let (pw, ph) = ((size.0 * m.scale) as i32, (size.1 * m.scale) as i32);
        let x = (cx - pw / 2).clamp(m.work.x, m.work.right() - pw);
        let y = (cy - ph / 2).clamp(m.work.y, m.work.bottom() - ph);
        wm::place(&window, &m, size, (x, y));
        let _ = window.show();
        let _ = window.set_focus();
        Ok(())
    }

    pub fn info(&self, n: u32) -> Option<PinInfo> {
        self.pins.lock().get(&n).cloned()
    }

    /// Liefert, ob kopiert wurde.
    pub fn copy(&self, n: u32) -> bool {
        let Some(info) = self.info(n) else { return false };
        if let Ok(data) = std::fs::read(&info.path) {
            if let Ok(image) = imageops::decode(&data) {
                let promise = ImagePromise::encoded(image, data, ImageFormat::Png);
                let _ = knips_platform::clipboard::set_image(Arc::new(promise));
                knips().hud.show("Kopiert", "check");
                return true;
            }
        }
        false
    }

    pub fn remove(&self, n: u32) {
        if let Some(info) = self.pins.lock().remove(&n) {
            let _ = std::fs::remove_file(info.path);
        }
    }
}
