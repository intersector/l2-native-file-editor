import { defineConfig } from "vite";

// Tauri loads the built files from `dist`; the dev server port is fixed so `devUrl` matches.
export default defineConfig({
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  envPrefix: ["VITE_", "TAURI_ENV_"],
  build: {
    target: "safari16",
    outDir: "dist",
    emptyOutDir: true,
  },
});
