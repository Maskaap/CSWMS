// CSWMS service worker.
//  - Makes the app installable and shows a clear offline page.
//  - Keeps the app's own code files (/_next/static, fingerprinted) and the counting
//    screens so a counter can keep counting without signal (offline counting).
//  - NEVER caches API responses or stock data, and never queues stock transactions:
//    the counting screen keeps its counts in the phone's own storage and sends them
//    itself, each with a request id so nothing is stored twice.
const VERSION = 'cswms-v2';
const SHELL = ['/offline', '/icons/icon-192.png', '/icons/icon-512.png'];
const OFFLINE_PAGES = [/^\/stocktake\/[0-9a-f-]{36}\/count$/, /^\/tasks$/];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;                       // never touch writes
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;        // never touch Supabase calls
  if (url.pathname.startsWith('/api/')) return;           // never touch API routes

  // fingerprinted code files: cache first (they never change under the same name)
  if (url.pathname.startsWith('/_next/static/')) {
    event.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(req, copy)); }
      return res;
    })));
    return;
  }
  if (req.mode === 'navigate') {
    const keep = OFFLINE_PAGES.some((re) => re.test(url.pathname));
    event.respondWith(fetch(req).then((res) => {
      if (keep && res.ok) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(url.pathname, copy)); }
      return res;
    }).catch(() => caches.match(url.pathname).then((hit) => hit || caches.match('/offline'))));
  }
});
