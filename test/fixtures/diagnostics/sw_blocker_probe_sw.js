// The probe's service worker, served at /sw/sw.js with scope /sw/ by
// sw_blocker_probe_server.js.
//
// Two ways a site's worker makes requests, one column of the probe each:
//   worker:  the worker's own fetch(), asked for over a MessageChannel;
//   proxied: a page it controls (/sw/frame.html) fetches, and the fetch
//            handler re-issues the request itself, as a caching worker does.
// Either way the request leaves from the worker, so only the blocker of the
// worker's profile (CB-022) can see it.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

async function probe(target) {
  try {
    const res = await fetch(target.url, { cache: 'no-store', mode: target.mode });
    const body = res.type === 'opaque' ? '' : await res.text();
    return { id: target.id, status: res.status, type: res.type, body: body.slice(0, 40) };
  } catch (e) {
    return { id: target.id, error: String(e) };
  }
}

self.addEventListener('message', (event) => {
  const port = event.ports[0];
  const targets = event.data && event.data.targets;
  if (!port || !Array.isArray(targets)) return;
  event.waitUntil(Promise.all(targets.map(probe)).then((results) => port.postMessage(results)));
});

self.addEventListener('fetch', (event) => {
  if (event.request.mode === 'navigate') return;
  event.respondWith(fetch(event.request));
});
