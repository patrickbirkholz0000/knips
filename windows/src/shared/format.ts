/** `m:ss` (abgerundet), wie Format.duration auf dem Mac. */
export function duration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const total = Math.floor(seconds);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

/** `m:ss.t` (Zehntel, abgerundet). */
export function preciseDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00.0";
  const tenths = Math.floor(seconds * 10);
  return `${Math.floor(tenths / 600)}:${String(Math.floor(tenths / 10) % 60).padStart(2, "0")}.${tenths % 10}`;
}

/** Bytes → „734 MB“ / „1,2 GB“ (deutsch). */
export function bytes(n: number): string {
  const units = ["Byte", "KB", "MB", "GB", "TB"];
  let v = n;
  let i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  const digits = v >= 100 || i === 0 ? 0 : 1;
  return `${v.toLocaleString("de-DE", { maximumFractionDigits: digits, minimumFractionDigits: 0 })} ${units[i]}`;
}

/** Zeitpunkt (Unix-Sekunden) → „heute, 09:41“ / „gestern, 18:02“ / „12.10.2026, 09:41“. */
export function when(unixSeconds: number, now: Date = new Date()): string {
  const d = new Date(unixSeconds * 1000);
  const time = d.toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" });
  const day = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((day(now) - day(d)) / 86_400_000);
  if (days === 0) return `heute, ${time}`;
  if (days === 1) return `gestern, ${time}`;
  return `${d.toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit", year: "numeric" })}, ${time}`;
}
