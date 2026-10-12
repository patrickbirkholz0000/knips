// Attrappen für den Video-Editor ohne Tauri (Browser, Screenshots). Video: public/mock/sample.mp4 (14 s, scrollt 40 px/s).
import { api, inTauri, mockEmit, registerMock } from "../shared/ipc";
import { mockItems } from "../shared/mock";
import type { TrackPoint, VideoRedaction, VideoSession } from "../shared/types";

if (!inTauri) {
  const item = mockItems[1];
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  const run = async (id: string, steps = 8) => {
    for (let i = 1; i <= steps; i++) {
      await sleep(120);
      mockEmit("video-progress", { id, progress: i / steps });
    }
  };

  registerMock("video_open", (): VideoSession => ({
    item,
    sourcePath: "/mock/sample.mp4",
    scale: 2,
    info: { duration: 14, width: 1400, height: 880, fps: 30, hevc: false, hasAudio: false },
    document: { version: 1, trimStart: null, trimEnd: null, redactions: [] },
  }));
  registerMock("video_thumbnails", ({ count }) =>
    Array.from({ length: count }, (_, i) => `/mock/video-thumbs/t${String(i).padStart(2, "0")}.jpg`),
  );
  registerMock("video_track", async ({ id, rect, t0, start, end }): Promise<TrackPoint[]> => {
    await run(id);
    const pts: TrackPoint[] = [];
    for (let t = start; t < end; t += 0.5) pts.push({ time: t, rect: { ...rect, y: rect.y - 40 * (t - t0) } });
    pts.push({ time: end, rect: { ...rect, y: rect.y - 40 * (end - t0) } });
    return pts;
  });
  registerMock("video_detect", async ({ id, start, end, style }): Promise<VideoRedaction[]> => {
    await run(id);
    return [
      {
        id: crypto.randomUUID(),
        rect: { x: 210, y: 360, width: 520, height: 44 },
        start,
        end: Math.min(end, start + 4),
        style,
        auto: true,
        track: null,
      },
    ];
  });
  registerMock("video_save", async ({ id }) => {
    await run(id, 5);
    return item;
  });
  registerMock("video_export_gif", async ({ id }) => {
    await run(id, 5);
    return { ...item, kind: "gif" };
  });
  registerMock("video_cancel", () => undefined);

  // Zum Prüfen: `#/video/<id>?auto=1` blendet die Auto-Zensur ein.
  if (location.hash.includes("auto=1")) void api.setSettings({ showAutoRedact: true });
}
