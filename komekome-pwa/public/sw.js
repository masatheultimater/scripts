const CACHE_VERSION = "20260221143912";
const STATIC_CACHE_NAME = `komekome-static-v2-${CACHE_VERSION}`;
const RUNTIME_CACHE_NAME = `komekome-runtime-v2-${CACHE_VERSION}`;
const CACHE_PREFIXES = ["komekome-static-v2-", "komekome-runtime-v2-"];
const STATIC_ASSETS = [
  "/",
  "/index.html",
  "/app.js",
  "/manifest.json",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
];
const STATIC_PATHS = new Set(STATIC_ASSETS);

// Install: cache static assets
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(STATIC_CACHE_NAME).then((cache) => cache.addAll(STATIC_ASSETS))
  );
  self.skipWaiting();
});

// Activate: clean ALL old caches (aggressive - ensures old SW caches are removed)
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => key !== STATIC_CACHE_NAME && key !== RUNTIME_CACHE_NAME)
          .map((key) => caches.delete(key))
      )
    )
  );
  self.clients.claim();
});

function putInCache(cacheName, request, response) {
  return caches
    .open(cacheName)
    .then((cache) => cache.put(request, response))
    .catch(() => undefined);
}

function offlineErrorResponse(request) {
  const pathname = new URL(request.url).pathname;

  if (pathname.startsWith("/api/")) {
    return new Response(
      JSON.stringify({
        error: "offline",
        message: "Network unavailable and no cached response found.",
      }),
      {
        status: 503,
        statusText: "Service Unavailable",
        headers: { "Content-Type": "application/json; charset=utf-8" },
      }
    );
  }

  if (request.mode === "navigate") {
    return new Response(
      "<!doctype html><html><body><h1>Offline</h1><p>キャッシュが見つかりませんでした。</p></body></html>",
      {
        status: 503,
        statusText: "Service Unavailable",
        headers: { "Content-Type": "text/html; charset=utf-8" },
      }
    );
  }

  return new Response("Offline and no cached response found.", {
    status: 503,
    statusText: "Service Unavailable",
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}

function handleApiNetworkFirst(request) {
  return fetch(request)
    .then((response) => {
      if (request.method === "GET" && response && response.ok) {
        putInCache(RUNTIME_CACHE_NAME, request, response.clone());
      }
      return response;
    })
    .catch(() =>
      caches
        .match(request)
        .then((cached) => cached || offlineErrorResponse(request))
    );
}

function handleStaticCacheFirstWithUpdate(request) {
  return caches.match(request, { ignoreSearch: true }).then((cached) => {
    const networkUpdate = fetch(request)
      .then((response) => {
        if (response && response.ok) {
          putInCache(STATIC_CACHE_NAME, request, response.clone());
        }
        return response;
      })
      .catch(() => undefined);

    if (cached) {
      return cached; // Return immediately; network update runs in background
    }

    return networkUpdate.then((response) => response || offlineErrorResponse(request));
  });
}

// Fetch strategy
self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);

  // Skip non-http(s) requests (chrome-extension:// etc.)
  if (!url.protocol.startsWith("http")) return;
  if (request.method !== "GET") return;

  // API endpoints: network-first with cache fallback
  if (url.pathname.startsWith("/api/komekome/page-image/")) {
    event.respondWith(handleApiNetworkFirst(request));
    return;
  }

  if (url.pathname.startsWith("/api/komekome/")) {
    event.respondWith(handleApiNetworkFirst(request));
    return;
  }

  // Same-origin static assets: cache-first + background network update
  if (url.origin !== self.location.origin) return;

  const isStaticRequest =
    request.mode === "navigate" ||
    STATIC_PATHS.has(url.pathname) ||
    request.destination === "script" ||
    request.destination === "style" ||
    request.destination === "document";

  if (isStaticRequest) {
    event.respondWith(handleStaticCacheFirstWithUpdate(request));
  }
});
