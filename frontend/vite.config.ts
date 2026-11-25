import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    outDir: '../public',
    emptyOutDir: true,
    assetsDir: 'assets',
  },
  server: {
    host: '127.0.0.1',
    port: 5173,
    proxy: {
      '/v1': 'http://127.0.0.1:8787',
      '/mcp': 'http://127.0.0.1:8787',
      '/webhooks': 'http://127.0.0.1:8787',
      '/oauth': 'http://127.0.0.1:8787',
      '/openapi.json': 'http://127.0.0.1:8787',
      '/docs': 'http://127.0.0.1:8787',
      '/manifest.json': 'http://127.0.0.1:8787',
      '/sw.js': 'http://127.0.0.1:8787',
      '/icon.svg': 'http://127.0.0.1:8787',
    },
  },
});
