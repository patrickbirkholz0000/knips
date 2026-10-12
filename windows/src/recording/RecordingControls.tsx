import { Square, Trash2 } from "lucide-react";
import { api } from "../shared/ipc";
import { duration } from "../shared/format";
import { useRecordingState } from "./useRecordingState";
import "./recording.css";

export default function RecordingControls(_: { params: string[]; query: URLSearchParams }) {
  const rec = useRecordingState();
  return (
    <div className="bar rec-bar" data-tauri-drag-region>
      <span className="rec-dot" data-tauri-drag-region />
      <span className="rec-time" data-tauri-drag-region>{duration(rec.elapsed)}</span>
      <button className="pill-red" title="Aufnahme beenden und speichern" onClick={() => api.recordingStop(true)}>
        <Square size={11} fill="#fff" strokeWidth={0} /> Stopp
      </button>
      <button className="round" title="Aufnahme verwerfen" onClick={() => api.recordingStop(false)}>
        <Trash2 size={13} strokeWidth={2.2} />
      </button>
    </div>
  );
}
