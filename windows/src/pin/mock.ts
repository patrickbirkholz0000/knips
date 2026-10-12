import { inTauri, registerMock } from "../shared/ipc";

if (!inTauri) {
  registerMock("pin_info", () => ({ path: "/mock/sample.png", pixelWidth: 1400, pixelHeight: 880, scale: 2 }));
  registerMock("pin_copy", () => undefined);
}
