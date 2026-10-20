import { api } from "../shared/ipc";
import { useRecordingState } from "./useRecordingState";
import "./recording.css";

const R = 57;
const RING = 2 * Math.PI * R;

// Countdown (docs/design.md): dunkle runde Fläche, große Mono-Ziffer; der rote Ring läuft je Sekunde einmal ab.
export default function Countdown(_: { params: string[]; query: URLSearchParams }) {
  const rec = useRecordingState();
  const running = rec.phase === "countdown";
  return (
    <div className="countdown" data-tauri-drag-region>
      <div className="disc" data-tauri-drag-region>
        <svg className="ring" viewBox="0 0 128 128" aria-hidden="true">
          <circle className="track" cx={64} cy={64} r={R} />
          {running && (
            <circle
              key={rec.countdown}
              className="run"
              cx={64}
              cy={64}
              r={R}
              strokeDasharray={RING}
              style={{ ["--ring-len" as string]: `${RING}` }}
            />
          )}
        </svg>
        {running && (
          <span key={rec.countdown} className="num" data-tauri-drag-region>
            {rec.countdown}
          </span>
        )}
      </div>
      <button className="cancel" onClick={() => api.recordingStop(false)}>
        Abbrechen
      </button>
    </div>
  );
}
