import React, { Suspense, lazy } from "react";
import ReactDOM from "react-dom/client";
import "./shared/tokens.css";
import "./shared/theme.css";
import "./shared/mock";
import { useRoute } from "./shared/route";

// Jedes Fenster lädt dieselbe Seite und wählt seine Ansicht über den Hash.
const views: Record<string, React.LazyExoticComponent<React.ComponentType<{ params: string[]; query: URLSearchParams }>>> = {
  menu: lazy(() => import("./menu/MenuPanel")),
  cards: lazy(() => import("./cards/Cards")),
  hud: lazy(() => import("./hud/Hud")),
  pin: lazy(() => import("./pin/Pin")),
  "rec-controls": lazy(() => import("./recording/RecordingControls")),
  "rec-countdown": lazy(() => import("./recording/Countdown")),
  "scroll-controls": lazy(() => import("./recording/ScrollControls")),
  history: lazy(() => import("./history/History")),
  settings: lazy(() => import("./settings/Settings")),
  consent: lazy(() => import("./consent/Consent")),
  "link-confirm": lazy(() => import("./links/LinkConfirm")),
  editor: lazy(() => import("./editor/Editor")),
  video: lazy(() => import("./video/VideoEditor")),
  "selftest-render": lazy(() => import("./editor/SelftestRender")),
};

function App() {
  const route = useRoute();
  const View = views[route.view];
  if (!View) return <div style={{ padding: 20 }}>Unbekannte Ansicht: {route.view || "(leer)"}</div>;
  document.documentElement.dataset.view = route.view;
  return (
    <Suspense fallback={null}>
      <View params={route.params} query={route.query} />
    </Suspense>
  );
}

ReactDOM.createRoot(document.getElementById("root")!).render(<App />);
