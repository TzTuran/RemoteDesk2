/**
 * vite.config.ts
 *
 * Vite build configuration for Moonlight-Web.
 *
 * Key points:
 *  - Preact (via @preact/preset-vite)
 *  - WASM support (vite-plugin-wasm)
 *  - Service worker compiled as a separate Rollup entry → /sw.js
 *  - Output goes to ../server/static for the Go/Node server to serve
 *  - Dev server proxies /api/* to http://localhost:8080
 *  - vite-plugin-pwa configures the Web App Manifest and injects the
 *    Workbox-based SW; our custom sw.ts overrides the generated one.
 */

import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';
import wasm from 'vite-plugin-wasm';
import { resolve } from 'path';
// PWA manifest is served directly from public/manifest.json — no plugin needed.
// Service worker (sw.ts) is compiled as a separate Rollup entry below.

export default defineConfig(({ mode }) => ({
  // ---------------------------------------------------------------------------
  // Plugins
  // ---------------------------------------------------------------------------
  plugins: [
    preact(),
    wasm(),
  ],

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------
  build: {
    outDir: '../server/static',
    emptyOutDir: true,
    sourcemap: mode !== 'production',
    target: 'es2022',

    rollupOptions: {
      input: {
        // Main application bundle
        main: resolve(__dirname, 'index.html'),
        // Service worker — compiled as a separate chunk at the root
        sw: resolve(__dirname, 'src/sw.ts'),
      },
      output: {
        // Place the service worker at the output root (not /assets/)
        // so it can claim the full scope.
        entryFileNames: (chunkInfo) => {
          if (chunkInfo.name === 'sw') return 'sw.js';
          return 'assets/[name]-[hash].js';
        },
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },

  // ---------------------------------------------------------------------------
  // Dev server
  // ---------------------------------------------------------------------------
  server: {
    port: 3000,
    strictPort: false,
    proxy: {
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
        rewrite: (path) => path, // keep /api prefix intact
        ws: true, // also proxy WebSocket upgrades
      },
    },
  },

  // ---------------------------------------------------------------------------
  // Resolve
  // ---------------------------------------------------------------------------
  resolve: {
    alias: {
      react: 'preact/compat',
      'react-dom': 'preact/compat',
      'react/jsx-runtime': 'preact/jsx-runtime',
    },
  },

  // ---------------------------------------------------------------------------
  // Optimise deps
  // ---------------------------------------------------------------------------
  optimizeDeps: {
    exclude: ['openh264-fallback'],
  },

  // ---------------------------------------------------------------------------
  // Define: runtime constants
  // ---------------------------------------------------------------------------
  define: {
    '__APP_VERSION__': JSON.stringify(process.env.npm_package_version ?? '0.0.0'),
  },
}));
