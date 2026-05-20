// Servit Service Worker — Push notifications + offline fallback
const CACHE_VERSION = 'servit-v8.9.3';
const CACHE_FILES = [
  '/',
  '/index.html',
  '/styles.css',
  '/app.js',
  '/marketplace.js',
  '/map.js',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
];

// Install — cache shell files
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then(cache => cache.addAll(CACHE_FILES))
  );
  self.skipWaiting();
});

// Activate — delete ALL caches that are not the current version.
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(k => k !== CACHE_VERSION).map(k => caches.delete(k))
    ))
  );
  self.clients.claim();
});

// Fetch — only handle same-origin requests, skip everything external
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // Only cache same-origin requests — skip ALL external CDNs and APIs
  if (url.origin !== self.location.origin) {
    return;
  }

  // Skip Netlify functions — never cache API calls
  if (url.pathname.startsWith('/.netlify/functions')) {
    return;
  }

  event.respondWith(
    fetch(event.request)
      .then(response => {
        const responseClone = response.clone();
        caches.open(CACHE_VERSION).then(cache => {
          cache.put(event.request, responseClone);
        });
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});

// Push notifications
self.addEventListener('push', event => {
  if (!event.data) return;

  let payload;
  try {
    payload = event.data.json();
  } catch {
    payload = { title: 'Servit', body: event.data.text() };
  }

  const options = {
    body:               payload.body || '',
    icon:               '/icons/icon-192.png',
    badge:              '/icons/icon-192.png',
    data:               payload.data || {},
    requireInteraction: payload.urgency === 'high',
    vibrate:            [200, 100, 200],
  };

  event.waitUntil(
    self.registration.showNotification(payload.title || 'Servit', options)
  );
});

// Notification click
self.addEventListener('notificationclick', event => {
  event.notification.close();

  const bookingId = event.notification.data?.bookingId;
  const targetUrl = bookingId ? `/?booking_id=${bookingId}` : '/';

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true })
      .then(clientList => {
        for (const client of clientList) {
          if (client.url.includes(self.location.origin) && 'focus' in client) {
            client.focus();
            if (bookingId) client.postMessage({ type: 'NAVIGATE_BOOKING', bookingId });
            return;
          }
        }
        return clients.openWindow(targetUrl);
      })
  );
});
