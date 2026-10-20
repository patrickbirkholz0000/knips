import { Trash2 } from "lucide-react";
import { api } from "../shared/ipc";
import { duration } from "../shared/format";
import { useRecordingState } from "./useRecordingState";
import "./recording.css";

// Aufnahme-Leiste (docs/design.md): dunkle Pille, roter pulsierender Punkt, Zeit in Mono, Stopp als Papier-Knopf.
export default function RecordingControls(_: { params: string[]; query: URLSearchParams }) {
  const rec = useRecordingState();
  return (
    <div className="bar rec-bar" data-tauri-drag-region>
      <span className="rec-dot" data-tauri-drag-region />
      <span className="rec-time bar-mono" data-tauri-drag-region>
        {duration(rec.elapsed)}
      </span>
      <span className="grow" data-tauri-drag-region />
      <button className="pill-paper" title="Aufnahme beenden und speichern" onClick={() => api.recordingStop(true)}>
        <span className="stop-square" /> Stopp
      </button>
      <button className="round" title="Aufnahme verwerfen" onClick={() => api.recordingStop(false)}>
        <Trash2 size={14} strokeWidth={2} />
      </button>
    </div>
  );
}
