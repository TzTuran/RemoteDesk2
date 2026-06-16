/**
 * sw.ts — Service Worker
 *
 * Compiled by Vite as a separate entry point and served at /sw.js.
 *
 * Strategies:
 *   - Static assets (/assets/, *.wasm, fonts)  → Cache-first
 *   - API routes   (/api/)                      → Network-first
 *   - App shell    (/, /index.html, *.tsx, etc) → Cache-first after precache
 *
 * The service worker sends skipWaiting() + clients.claim() on activation so
 * new builds take effect immediately without requiring a browser restart.
 */

/// <reference lib="webworker" />
declare const self: ServiceWorkerGlobalScope;

// ---------------------------------------------------------------------------
// Cache names — bump APP_VERSION to invalidate all caches on new deploy
// ---------------------------------------------------------------------------

const APP_VERSION = '__APP_VERSION__'; // replaced at build time by Vite define
const CACHE_STATIC = `static-v${APP_VERSION}`;
const CACHE_API    = `api-v${APP_VERSION}`;

// ---------------------------------------------------------------------------
// App shell: files to precache on install
// ---------------------------------------------------------------------------

const APP_SHELL: string[] = [
  '/',
  '/index.html',
  '/manifest.json',
];

// ---------------------------------------------------------------------------
// Install: precache the app shell
// ---------------------------------------------------------------------------

self.addEventListener('install', (event: ExtendableEvent) => {
  console.debug('[SW] install event');
  event.waitUntil(
    caches
      .open(CACHE_STATIC)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => {
        console.debug('[SW] App shell precached');
        // Skip waiting so the new SW activates immediately
        return self.skipWaiting();
      }),
  );
});

// ---------------------------------------------------------------------------
// Activate: take control and clean up old caches
// ---------------------------------------------------------------------------

self.addEventListener('activate', (event: ExtendableEvent) => {
  console.debug('[SW] activate event');
  event.waitUntil(
    (async () => {
      // Delete any cache that doesn't match the current version names
      const allKeys = await caches.keys();
      await Promise.all(
        allKeys
          .filter((k) => k !== CACHE_STATIC && k !== CACHE_API)
          .map((k) => {
            console.debug('[SW] Deleting stale cache:', k);
            return caches.delete(k);
          }),
      );
      // Claim all open clients so they use this new SW immediately
      await self.clients.claim();
      console.debug('[SW] Activated — clients claimed');
    })(),
  );
});

// ---------------------------------------------------------------------------
// Fetch: route to the appropriate strategy
// ---------------------------------------------------------------------------

self.addEventListener('fetch', (event: FetchEvent) => {
  const { request } = event;
  const url = new URL(request.url);

  // Only handle same-origin requests (plus CDN assets if needed)
  if (url.origin !== self.location.origin) return;

  // API routes → network-first
  if (url.pathname.startsWith('/api/')) {
    event.respondWith(networkFirst(request));
    return;
  }

  // WASM files → cache-first (large, immutable binaries)
  if (url.pathname.endsWith('.wasm')) {
    event.respondWith(cacheFirst(request, CACHE_STATIC));
    return;
  }

  // Vite-built static assets contain content hash → cache-first, long TTL
  if (url.pathname.startsWith('/assets/')) {
    event.respondWith(cacheFirst(request, CACHE_STATIC));
    return;
  }

  // Fonts → cache-first
  if (url.pathname.includes('/fonts/') || request.destination === 'font') {
    event.respondWith(cacheFirst(request, CACHE_STATIC));
    return;
  }

  // Navigation (HTML pages) → cache-first with network fallback
  if (request.mode === 'navigate') {
    event.respondWith(navigationHandler(request));
    return;
  }

  // Everything else → stale-while-revalidate
  event.respondWith(staleWhileRevalidate(request, CACHE_STATIC));
});

// ---------------------------------------------------------------------------
// Strategy implementations
// ---------------------------------------------------------------------------

/**
 * Cache-first: serve from cache; fetch and cache if missing.
 */
async function cacheFirst(request: Request, cacheName: string): Promise<Response> {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);
  if (cached) return cached;

  const response = await fetch(request);
  if (response.ok) {
    await cache.put(request, response.clone());
  }
  return response;
}

/**
 * Network-first: try network; fall back to cache on failure.
 * Used for API routes where freshness matters.
 */
async function networkFirst(request: Request): Promise<Response> {
  const cache = await caches.open(CACHE_API);
  try {
    const response = await fetch(request);
    if (response.ok) {
      await cache.put(request, response.clone());
    }
    return response;
  } catch (err) {
    const cached = await cache.match(request);
    if (cached) {
      console.debug('[SW] Network failed, serving from API cache:', request.url);
      return cached;
    }
    // Return a structured error response if no cache entry exists
    return new Response(JSON.stringify({ error: 'Offline', message: 'No cached response available' }), {
      status: 503,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}

/**
 * Stale-while-revalidate: serve from cache immediately, then update the cache
 * in the background.
 */
async function staleWhileRevalidate(request: Request, cacheName: string): Promise<Response> {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);

  const fetchPromise = fetch(request).then((response) => {
    if (response.ok) {
      cache.put(request, response.clone());
    }
    return response;
  });

  return cached ?? fetchPromise;
}

/**
 * Navigation handler: serve index.html for all navigation requests (SPA
 * routing). Falls back to network if the cache is cold.
 */
async function navigationHandler(request: Request): Promise<Response> {
  const cache = await caches.open(CACHE_STATIC);
  // Try exact match first
  const exact = await cache.match(request);
  if (exact) return exact;

  // SPA fallback: serve index.html
  const shell = await cache.match('/index.html') ?? await cache.match('/');
  if (shell) return shell;

  // Cold cache: fetch from network
  return fetch(request);
}

// ---------------------------------------------------------------------------
// Message: allow the client to trigger skipWaiting programmatically
// ---------------------------------------------------------------------------

self.addEventListener('message', (event: ExtendableMessageEvent) => {
  if (event.data?.type === 'SKIP_WAITING') {
    console.debug('[SW] Received SKIP_WAITING message');
    self.skipWaiting();
  }
});
