import { useEffect, useState } from "react";
import { api, events } from "../shared/ipc";
import type { RecordingState } from "../shared/types";
import "./mock";

/** Aufnahmezustand: erst abfragen, dann per Ereignis nachführen. */
export function useRecordingState(): RecordingState {
  const [state, setState] = useState<RecordingState>({ phase: "idle", countdown: 0, elapsed: 0 });
  useEffect(() => {
    let alive = true;
    api.getRecordingState().then((s) => alive && s && setState(s));
    const off = events.recordingState((s) => alive && setState(s));
    return () => {
      alive = false;
      off.then((f) => f());
    };
  }, []);
  return state;
}
