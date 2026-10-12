import { api } from "../shared/ipc";
import { useRecordingState } from "./useRecordingState";
import "./recording.css";

export default function Countdown(_: { params: string[]; query: URLSearchParams }) {
  const rec = useRecordingState();
  return (
    <div className="countdown" data-tauri-drag-region>
      <div className="disc">{rec.phase === "countdown" && <span key={rec.countdown} className="num">{rec.countdown}</span>}</div>
      <button className="cancel" onClick={() => api.recordingStop(false)}>Abbrechen</button>
    </div>
  );
}
