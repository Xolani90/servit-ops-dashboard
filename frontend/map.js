// ═══════════════════════════════════════════════════════════════
// Servit v4.3 — Live Map (map.js)
// Drop into your root alongside app.js.
// Add to index.html AFTER app.js:
//   <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
//   <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
//   <script src="/map.js"></script>
//
// What this does:
//   • Customer view (EN_ROUTE / ARRIVED): shows pro moving on a map
//   • Pro view (CONFIRMED onward): shows their own GPS position
//   • Subscribes to pro_profiles via Supabase Realtime for live updates
//   • Computes ETA from distance_km stored in booking_events
//   • Cleans up all subscriptions when the job screen is left
// ═══════════════════════════════════════════════════════════════

(function () {
  'use strict';

  // ── State ────────────────────────────────────────────────────
  let _map            = null;   // Leaflet map instance
  let _proMarker      = null;   // moving pro marker
  let _customerMarker = null;   // static customer/destination pin
  let _proChannel     = null;   // Supabase Realtime channel
  let _watchId        = null;   // navigator.geolocation.watchPosition handle
  let _currentProId   = null;   // pro_profiles.id being tracked

  // South Africa centre — fallback when no coords available yet
  const SA_CENTRE = [-29.0, 25.0];
  const SA_ZOOM   = 5;

  // ── Tile layer (OpenStreetMap — free, no key needed) ─────────
  const TILE_URL = 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png';
  const TILE_ATTR = '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>';

  // ── Marker icons ─────────────────────────────────────────────
  function makeIcon(emoji, size) {
    return L.divIcon({
      html: `<div style="font-size:${size}px;line-height:1;filter:drop-shadow(0 2px 4px rgba(0,0,0,.4))">${emoji}</div>`,
      className: '',
      iconAnchor: [size / 2, size / 2],
    });
  }

  const PRO_ICON      = makeIcon('🔧', 32);
  const CUSTOMER_ICON = makeIcon('📍', 28);

  // ── Public API ───────────────────────────────────────────────

  /**
   * Call this after renderJobScreen() inserts #map-container into the DOM.
   *
   * @param {object} booking  - full booking row (from loadActiveJob)
   * @param {boolean} isProView - true when the logged-in user is the pro
   */
  window.initServitMap = function (booking, isProView) {
    if (!window.L) { console.warn('[map] Leaflet not loaded'); return; }

    const container = document.getElementById('map-container');
    if (!container) return;

    // Destroy previous instance if any
    destroyMap();

    // ── Create map ───────────────────────────────────────────
    _map = L.map('map-container', {
      zoomControl: true,
      attributionControl: true,
    }).setView(SA_CENTRE, SA_ZOOM);

    L.tileLayer(TILE_URL, { attribution: TILE_ATTR, maxZoom: 19 }).addTo(_map);

    // ── Customer destination pin (from booking.address coords) ──
    // bookings don't store lat/lng yet — use the pro's city as fallback.
    // When you add geocoding, replace this with the booking's coords.
    const destLat = booking.customer_latitude  || null;
    const destLng = booking.customer_longitude || null;
    if (destLat && destLng) {
      _customerMarker = L.marker([destLat, destLng], { icon: CUSTOMER_ICON })
        .addTo(_map)
        .bindPopup('<b>\ud83d\udccd Job location</b><br>' + String(booking.address || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'));
    }

    if (isProView) {
      // ── PRO VIEW: show own GPS position, update as they move ──
      _startProSelfTracking(booking);
    } else {
      // ── CUSTOMER VIEW: watch pro_profiles for lat/lng changes ─
      // FIX v8.9.3: bookings table uses fixer_id, not pro_id — was always undefined
      const proId = booking.fixer_id;
      if (!proId) return;
      _currentProId = proId;
      _loadInitialProPosition(proId, booking);
      _subscribeToProLocation(proId);
    }
  };

  /**
   * Call this when leaving the job screen (e.g. navigate() away).
   * Cleans up map, markers, and all subscriptions.
   */
  window.destroyServitMap = async function () {
    await destroyMap();
  };

  // ── Internal helpers ─────────────────────────────────────────

  async function destroyMap() {
    // Stop GPS watch
    if (_watchId !== null) {
      navigator.geolocation.clearWatch(_watchId);
      _watchId = null;
    }
    // Remove Realtime channel
    if (_proChannel && window.supabaseClient) {
      await supabaseClient.removeChannel(_proChannel).catch(() => {});
      _proChannel = null;
    }
    // Destroy Leaflet map
    if (_map) {
      _map.remove();
      _map = null;
    }
    _proMarker      = null;
    _customerMarker = null;
    _currentProId   = null;
  }

  // ── Pro self-tracking (pro view) ─────────────────────────────

  function _startProSelfTracking(booking) {
    if (!navigator.geolocation) {
      showMapMessage('GPS not available on this device.');
      return;
    }

    _watchId = navigator.geolocation.watchPosition(
      (pos) => {
        const lat = pos.coords.latitude;
        const lng = pos.coords.longitude;
        _movePro(lat, lng, 'You');
        // Also push to DB so customer sees it
        _pushProLocation(lat, lng);
      },
      (err) => {
        console.warn('[map] GPS error:', err.message);
        showMapMessage('Enable location to show your position.');
      },
      { enableHighAccuracy: true, maximumAge: 10000, timeout: 15000 }
    );
  }

  function _pushProLocation(lat, lng) {
    if (!window.supabaseClient || !window.currentFixerProfile) return;
    // Update pro_profiles — heartbeat in app.js already does this every 60s.
    // watchPosition fires more often, so we throttle to once per 15s.
    const now = Date.now();
    if (_pushProLocation._last && now - _pushProLocation._last < 15000) return;
    _pushProLocation._last = now;

    supabaseClient
      .from('fixers')
      .update({ latitude: lat, longitude: lng, last_seen_at: new Date().toISOString() })
      .eq('id', currentFixerProfile.id)
      .then(({ error }) => { if (error) console.warn('[map] push location:', error.message); });
  }

  // ── Customer-side pro tracking ────────────────────────────────

  async function _loadInitialProPosition(proId, booking) {
    const { data: pro } = await supabaseClient
      .from('fixers')
      .select('latitude, longitude, full_name, city')
      .eq('id', proId)
      .maybeSingle();

    if (pro?.latitude && pro?.longitude) {
      _movePro(pro.latitude, pro.longitude, pro.full_name || 'Your pro');
      _fitMapToBoth(pro.latitude, pro.longitude, booking);
    } else if (pro?.city) {
      showMapMessage(`${pro.full_name || 'Your pro'} is in ${pro.city} — live position loading...`);
    }

    // Also load ETA from booking_events
    _loadETA(booking.id);
  }

  function _subscribeToProLocation(proId) {
    if (_proChannel) supabaseClient.removeChannel(_proChannel);

    _proChannel = supabaseClient
      .channel(`pro-location-${proId}`)
      .on('postgres_changes', {
        event:  'UPDATE',
        schema: 'public',
        table:  'fixers',
        filter: `id=eq.${proId}`,
      }, (payload) => {
        const { latitude, longitude, full_name } = payload.new;
        if (latitude && longitude) {
          _movePro(latitude, longitude, full_name || 'Your pro');
        }
      })
      .subscribe();
  }

  // ── Shared map helpers ────────────────────────────────────────

  function _movePro(lat, lng, label) {
    if (!_map) return;

    if (_proMarker) {
      _proMarker.setLatLng([lat, lng]);
    } else {
      // FIX v8.9.3: label (fixer full_name) was injected raw — escape before HTML context
      const _safeLabel = String(label || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      _proMarker = L.marker([lat, lng], { icon: PRO_ICON })
        .addTo(_map)
        .bindPopup(`<b>🔧 ${_safeLabel}</b>`);

      // Only fly to pro on first fix — don't yank the map on every update
      _map.flyTo([lat, lng], 14, { duration: 1.2 });
    }
  }

  function _fitMapToBoth(proLat, proLng, booking) {
    if (!_map) return;
    const destLat = booking.customer_latitude;
    const destLng = booking.customer_longitude;
    if (destLat && destLng) {
      const bounds = L.latLngBounds(
        [[proLat, proLng], [destLat, destLng]]
      ).pad(0.3);
      _map.fitBounds(bounds);
    } else {
      _map.flyTo([proLat, proLng], 14, { duration: 1.2 });
    }
  }

  // ── ETA calculation ───────────────────────────────────────────
  // Reads the latest offer_created event which stores distance_km in metadata.
  // ETA = distance_km / 30 km/h * 60 minutes (conservative urban speed).

  async function _loadETA(bookingId) {
    const { data: events } = await supabaseClient
      .from('booking_events')
      .select('metadata')
      .eq('booking_id', bookingId)
      .eq('event_type', 'offer_created')
      .order('created_at', { ascending: false })
      .limit(1);

    const km = events?.[0]?.metadata?.distance_km;
    if (!km || km <= 0) return;

    const minutes = Math.round((km / 30) * 60);
    const etaEl = document.getElementById('map-eta');
    if (etaEl) {
      etaEl.textContent = minutes < 2
        ? '🟢 Arriving now'
        : `🕐 ETA ~${minutes} min · ${km.toFixed(1)} km away`;
    }
  }

  function showMapMessage(msg) {
    const el = document.getElementById('map-message');
    if (el) el.textContent = msg;
  }

})();
