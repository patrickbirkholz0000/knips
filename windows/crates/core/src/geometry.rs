//! Punkte und Rechtecke wie `CGPoint`/`CGRect` auf dem Mac: Ursprung oben links, y nach unten.
//! Im JSON als `{x, y}` bzw. `{x, y, width, height}`.

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug, Default)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug, Default)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// Rechteck mit nicht-negativer Breite/Höhe (`standardized`). Ein „leeres“ Rechteck
/// (`is_null`) entsteht bei Schnittmengen ohne Überlappung — wie `CGRect.null`.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug, Default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const NULL: Rect = Rect { x: f64::INFINITY, y: f64::INFINITY, width: 0.0, height: 0.0 };

    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    /// Aus zwei Eckpunkten, egal in welcher Reihenfolge.
    pub fn from_points(a: Point, b: Point) -> Self {
        Self::new(a.x.min(b.x), a.y.min(b.y), (b.x - a.x).abs(), (b.y - a.y).abs())
    }

    pub fn is_null(&self) -> bool {
        !self.x.is_finite() || !self.y.is_finite()
    }
    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
    pub fn center(&self) -> Point {
        Point::new(self.mid_x(), self.mid_y())
    }
    pub fn area(&self) -> f64 {
        if self.is_null() {
            0.0
        } else {
            self.width * self.height
        }
    }

    pub fn contains(&self, p: Point) -> bool {
        !self.is_null() && p.x >= self.x && p.x < self.max_x() && p.y >= self.y && p.y < self.max_y()
    }

    pub fn intersects(&self, o: &Rect) -> bool {
        !self.intersection(o).is_null()
    }

    /// Schnittmenge; `NULL`, wenn sich die Rechtecke nicht überlappen (Berührung zählt nicht).
    pub fn intersection(&self, o: &Rect) -> Rect {
        if self.is_null() || o.is_null() {
            return Rect::NULL;
        }
        let x0 = self.x.max(o.x);
        let y0 = self.y.max(o.y);
        let x1 = self.max_x().min(o.max_x());
        let y1 = self.max_y().min(o.max_y());
        if x1 <= x0 || y1 <= y0 {
            return Rect::NULL;
        }
        Rect::new(x0, y0, x1 - x0, y1 - y0)
    }

    pub fn union(&self, o: &Rect) -> Rect {
        if self.is_null() {
            return *o;
        }
        if o.is_null() {
            return *self;
        }
        let x0 = self.x.min(o.x);
        let y0 = self.y.min(o.y);
        Rect::new(x0, y0, self.max_x().max(o.max_x()) - x0, self.max_y().max(o.max_y()) - y0)
    }

    /// Wie `CGRect.insetBy`: positive Werte verkleinern, negative vergrößern.
    pub fn inset(&self, dx: f64, dy: f64) -> Rect {
        if self.is_null() {
            return *self;
        }
        let w = self.width - 2.0 * dx;
        let h = self.height - 2.0 * dy;
        if w < 0.0 || h < 0.0 {
            return Rect::NULL;
        }
        Rect::new(self.x + dx, self.y + dy, w, h)
    }

    pub fn offset(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.width, self.height)
    }

    /// Wie `CGRect.integral`: kleinstes Rechteck mit ganzzahligen Kanten, das dieses enthält.
    pub fn integral(&self) -> Rect {
        if self.is_null() {
            return *self;
        }
        let x0 = self.x.floor();
        let y0 = self.y.floor();
        Rect::new(x0, y0, self.max_x().ceil() - x0, self.max_y().ceil() - y0)
    }

    pub fn scaled(&self, f: f64) -> Rect {
        Rect::new(self.x * f, self.y * f, self.width * f, self.height * f)
    }
}

/// Ganzzahliges Rechteck in physischen Pixeln (Bildschirmkoordinaten unter Windows).
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default, Hash)]
pub struct IRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl IRect {
    pub const fn new(x: i32, y: i32, width: i32, height: i32) -> Self {
        Self { x, y, width, height }
    }
    pub fn right(&self) -> i32 {
        self.x + self.width
    }
    pub fn bottom(&self) -> i32 {
        self.y + self.height
    }
    pub fn contains(&self, px: i32, py: i32) -> bool {
        px >= self.x && px < self.right() && py >= self.y && py < self.bottom()
    }
    pub fn intersection(&self, o: &IRect) -> Option<IRect> {
        let x0 = self.x.max(o.x);
        let y0 = self.y.max(o.y);
        let x1 = self.right().min(o.right());
        let y1 = self.bottom().min(o.bottom());
        (x1 > x0 && y1 > y0).then(|| IRect::new(x0, y0, x1 - x0, y1 - y0))
    }
    pub fn offset(&self, dx: i32, dy: i32) -> IRect {
        IRect::new(self.x + dx, self.y + dy, self.width, self.height)
    }
    pub fn to_rect(&self) -> Rect {
        Rect::new(self.x as f64, self.y as f64, self.width as f64, self.height as f64)
    }
    pub fn from_rect(r: &Rect) -> IRect {
        let r = r.integral();
        IRect::new(r.x as i32, r.y as i32, r.width as i32, r.height as i32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intersection_and_union() {
        let a = Rect::new(0.0, 0.0, 10.0, 10.0);
        let b = Rect::new(5.0, 5.0, 10.0, 10.0);
        assert_eq!(a.intersection(&b), Rect::new(5.0, 5.0, 5.0, 5.0));
        assert_eq!(a.union(&b), Rect::new(0.0, 0.0, 15.0, 15.0));
        assert!(a.intersection(&Rect::new(20.0, 0.0, 1.0, 1.0)).is_null());
        assert_eq!(Rect::new(0.2, 0.7, 1.0, 1.0).integral(), Rect::new(0.0, 0.0, 2.0, 2.0));
    }
}
