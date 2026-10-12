import { useEffect, useState } from "react";
import { Film, Image as ImageIcon } from "lucide-react";
import { api, thumbUrl } from "./ipc";
import type { Bootstrap, CaptureItem } from "./types";

// Pfade ändern sich nur selten; einmal laden reicht für alle Vorschaubilder.
let bootPromise: Promise<Bootstrap> | null = null;
function useThumbBoot(): Bootstrap | null {
  const [boot, setBoot] = useState<Bootstrap | null>(null);
  useEffect(() => {
    let alive = true;
    bootPromise ??= api.getBootstrap();
    bootPromise.then((b) => alive && setBoot(b));
    return () => {
      alive = false;
    };
  }, []);
  return boot;
}

/** Vorschaubild einer Aufnahme: eingepasst (contain) auf ruhigem Grund, wie `Thumbnail` auf dem Mac. */
export default function Thumbnail({ item, background = "rgb(26, 26, 26)", className }: { item: CaptureItem; background?: string; className?: string }) {
  const boot = useThumbBoot();
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [item.id, item.revision]);
  const style = { width: "100%", height: "100%", background, display: "flex", alignItems: "center", justifyContent: "center" } as const;
  if (!boot) return <div className={className} style={style} />;
  if (failed) {
    const Icon = item.kind === "image" ? ImageIcon : Film;
    return (
      <div className={className} style={style}>
        <Icon size={28} color="rgba(255,255,255,0.4)" />
      </div>
    );
  }
  return (
    <div className={className} style={style}>
      <img
        src={thumbUrl(boot, item)}
        alt=""
        draggable={false}
        onError={() => setFailed(true)}
        style={{ width: "100%", height: "100%", objectFit: "contain", display: "block" }}
      />
    </div>
  );
}
