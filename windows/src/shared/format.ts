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
