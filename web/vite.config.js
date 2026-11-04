import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  base: "/app/",
  plugins: [react()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: false,
  },
  server: {
    port: 5174,
    strictPort: true,
    proxy: {
      "/api": { target: "https://127.0.0.1:5099", secure: false, changeOrigin: true },
      "/manifest.webmanifest": { target: "https://127.0.0.1:5099", secure: false, changeOrigin: true },
      "/icon-192.png": { target: "https://127.0.0.1:5099", secure: false, changeOrigin: true },
      "/icon-512.png": { target: "https://127.0.0.1:5099", secure: false, changeOrigin: true },
    },
  },
});
