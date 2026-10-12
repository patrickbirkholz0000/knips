import { useEffect, useState } from "react";

export interface Route {
  /** erstes Segment, z. B. "editor" */
  view: string;
  /** weitere Segmente, z. B. die Item-ID */
  params: string[];
  query: URLSearchParams;
}

/** `#/editor/<id>?tool=redact` → { view: "editor", params: ["<id>"], query: tool=redact } */
export function parseRoute(hash: string): Route {
  const raw = hash.replace(/^#\/?/, "");
  const [path, qs = ""] = raw.split("?");
  const [view = "", ...params] = path.split("/").filter(Boolean).map(decodeURIComponent);
  return { view, params, query: new URLSearchParams(qs) };
}

export function useRoute(): Route {
  const [route, setRoute] = useState(() => parseRoute(window.location.hash));
  useEffect(() => {
    const onHash = () => setRoute(parseRoute(window.location.hash));
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  return route;
}
