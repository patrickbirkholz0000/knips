import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Eine Seite für alle Fenster; das Fenster wählt seine Ansicht über den Hash (#/menu, #/editor/<id> …).
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1430, strictPort: true },
  build: { target: "es2022", sourcemap: false, chunkSizeWarningLimit: 1500 },
});
