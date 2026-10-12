//! TODO(Windows): Startfassung = Kopie der Attrappe. Durch die echte Implementierung ersetzen,
//! Signaturen exakt beibehalten (Referenz: `mock/mod.rs`).

use crate::types::{IRect, Monitor};

pub fn list() -> Vec<Monitor> {
    vec![Monitor {
        id: 1,
        name: "MOCK1".into(),
        rect: IRect::new(0, 0, 2880, 1800),
        work: IRect::new(0, 0, 2880, 1720),
        scale: 2.0,
        primary: true,
    }]
}

/// Monitor unter einem globalen Punkt (sonst der primäre).
pub fn at_point(x: i32, y: i32) -> Monitor {
    list().into_iter().find(|m| m.rect.contains(x, y)).unwrap_or_else(primary)
}

pub fn at_cursor() -> Monitor {
    let (x, y) = cursor_pos();
    at_point(x, y)
}

pub fn primary() -> Monitor {
    list().remove(0)
}

pub fn cursor_pos() -> (i32, i32) {
    (1440, 900)
}
