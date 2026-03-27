// === Service Worker v17 — Pedidos ML (final PWA GitHub) ===

const CACHE_NAME = "pedidos-ml-v25";
const OFFLINE_URLS = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  // Asegurate de tener estos íconos o comentá estas líneas si no existen
  // "./icon-192.png", 
  // "./icon-512.png"
];

// 🟢 INSTALACIÓN
self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE_NAME)
      .then(c => c.addAll(OFFLINE_URLS))
      .then(() => self.skipWaiting())
  );
  console.log("✅ Service Worker instalado correctamente");
});

// 🟢 ACTIVACIÓN
self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.map(k => (k !== CACHE_NAME ? caches.delete(k) : null)))
    )
  );
  console.log("✅ Service Worker activado y limpio");
  self.clients.claim();
});

// 🟢 FETCH — solo GET local (no intercepta Google Sheets ni scripts externos)
self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);

  // 1. Solo interceptamos GET
  if (req.method !== "GET") return;

  // 2. CRÍTICO: Solo interceptamos archivos de NUESTRO propio dominio (localhost o github.io)
  // Esto hace que requests a docs.google.com pasen directo a la red sin guardarse en caché.
  if (url.origin !== self.location.origin) return;

  // 3. Ignorar scripts de macros de Google por seguridad extra (aunque el paso 2 ya los filtra)
  if (url.href.includes("https://script.google.com/macros/")) return;

  // Estrategia: Cache First, falling back to Network (para archivos locales)
  e.respondWith(
    caches.match(req).then(cached =>
      cached ||
      fetch(req)
        .then(resp => {
          // Si la respuesta es válida, la guardamos en caché (solo archivos locales)
          const clone = resp.clone();
          caches.open(CACHE_NAME).then(c => c.put(req, clone));
          return resp;
        })
        .catch(() => {
          // Si falla la red y no está en caché (ej: offline), mostramos el index
          if (req.headers.get("accept").includes("text/html")) {
            return caches.match("./index.html");
          }
        })
    )
  );
});
