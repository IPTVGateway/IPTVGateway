/// <reference types="vitest" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// During dev the React app runs on :5173 and proxies API calls to the Delphi
// backend on :7777, so the browser sees a single origin (no CORS surprises).
export default defineConfig({
  plugins: [react()],
  // The repo lives on a `subst` drive (W: -> D:\...OneDrive...). Without this,
  // Vite realpath-resolves W: back to the spaced OneDrive path and fails to load
  // modules (e.g. the test setup file). Keep paths as-seen on the working drive.
  resolve: { preserveSymlinks: true },
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:7777',
    },
  },
  // Vitest: jsdom for component tests, jest-dom matchers via the setup file.
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: './src/test/setup.ts',
    css: false,
  },
})
