// ═══════════════════════════════════════════════════════════════
// SERVIT v6.5 — Frontend (UI only — all logic lives on the backend)
//
// FIXES applied vs the previous version:
//   1. ALL references to `pro_profiles` table renamed to `fixers`
//      (the actual table name in schema.sql).
//   2. `acceptOffer()` now passes { offer_id } instead of { booking_id }.
//      The DB function accept_offer() requires the offers.id UUID, not
//      the bookings.id UUID.  Previously this caused a silent mismatch
//      where the function received a booking UUID and tried to look it
//      up in the offers table — always failing.
//   3. `declineOffer()` likewise now passes { offer_id }.
//   4. `startMatchingPolling()` replaced with Supabase Realtime channel.
//      setInterval polling burned DB reads and had race conditions.
//      Realtime pushes state changes instantly and the channel is torn
//      down on navigation.
//   5. `toggleAvailability()` was updating `pro_profiles` — fixed to
//      update `fixers` table.
//   6. `loadUserProfile()` was querying `pro_profiles` — fixed to
//      query `fixers`.
//   7. `loadFixerDashboard()` was querying via `offer_fixer_id` and
//      `pro_id` columns — fixed to use correct schema column names
//      (`fixer_id` on bookings, `fixer_id` on offers).
//   8. `loadBookings()` was using `client_id` — fixed to `customer_id`.
//   9. `loadOfferDetails()` was trying to join `pro_profiles` — fixed
//      to join `fixers` via correct FK.
//  10. `subscribeToOffers()` added for fixer side so the dashboard
//      updates in real time when a new offer arrives.
// ═══════════════════════════════════════════════════════════════

// Use the Supabase client initialised in index.html
const supabaseClient = window.db;
// Expose for marketplace.js (and any other addon scripts)
window.supabaseClient = supabaseClient;

// ────────────────────────── State ──────────────────────────────
let currentUser         = null;
let currentUserProfile  = null;
let currentFixerProfile = null;   // FIX: renamed from currentProProfile for clarity
let currentAdminProfile = null;   // Set if profiles.is_admin = true
let currentBookingId    = null;
let currentOfferBookingId = null;
let currentOfferOfferId   = null; // FIX: store offer.id for accept/decline calls
let currentChatPartner  = null;
let currentChatBookingId = null;
let bookingChannel      = null;   // FIX: replaces matchingInterval + statusPollInterval
let offerChannel        = null;
let messageChannel      = null;
let demandAlertChannel  = null;   // IMPROVEMENT 3: demand alerts for fixers

// IMPROVEMENT 1 & 2: Geolocation + heartbeat state
let customerCoords      = null;   // { latitude, longitude } captured at booking time
let heartbeatInterval   = null;   // setInterval handle for fixer location ping
let heartbeatFailures   = 0;      // FIX v5.2: consecutive failure counter for banner

// Canonical customer-facing lifecycle states for trust messaging.
const JOB_STATE = {
  REQUEST_CREATED: 'REQUEST_CREATED',
  SEARCHING_FOR_FIXER: 'SEARCHING_FOR_FIXER',
  FIXER_NOTIFIED: 'FIXER_NOTIFIED',
  FIXER_ACCEPTED: 'FIXER_ACCEPTED',
  FIXER_ASSIGNED: 'FIXER_ASSIGNED',
  NO_FIXER_FOUND: 'NO_FIXER_FOUND',
  MATCHING_FAILED: 'MATCHING_FAILED',
  JOB_STARTED: 'JOB_STARTED',
  JOB_COMPLETED: 'JOB_COMPLETED',
  PAYMENT_CAPTURED: 'PAYMENT_CAPTURED',
  PAYMENT_REFUNDED: 'PAYMENT_REFUNDED',
  JOB_CANCELLED: 'JOB_CANCELLED',
};

function deriveJobState(booking) {
  if (!booking) return null;
  if (booking.payment_status === 'refunded') return JOB_STATE.PAYMENT_REFUNDED;
  if (booking.status === 'CREATED') return JOB_STATE.REQUEST_CREATED;
  if (booking.status === 'PENDING_PAYMENT' && booking.payment_status === 'paid') return JOB_STATE.PAYMENT_CAPTURED;
  if (booking.status === 'PENDING_PAYMENT') return JOB_STATE.REQUEST_CREATED;
  if (booking.status === 'SEARCHING') return JOB_STATE.SEARCHING_FOR_FIXER;
  if (booking.status === 'OFFERED') return JOB_STATE.FIXER_NOTIFIED;
  if (booking.status === 'CONFIRMED') return JOB_STATE.FIXER_ASSIGNED;
  if (booking.status === 'EN_ROUTE' || booking.status === 'ARRIVED' || booking.status === 'IN_PROGRESS') return JOB_STATE.JOB_STARTED;
  if (booking.status === 'PENDING_COMPLETION') return JOB_STATE.FIXER_ACCEPTED;
  if (booking.status === 'COMPLETED') return JOB_STATE.JOB_COMPLETED;
  if (booking.status === 'EXPIRED') return JOB_STATE.NO_FIXER_FOUND;
  if (booking.status === 'FAILED_MATCH') return JOB_STATE.MATCHING_FAILED;
  if (booking.status === 'CANCELLED') return JOB_STATE.JOB_CANCELLED;
  return null;
}

// ─────────────────────── Utilities ─────────────────────────────

function showToast(message, type = 'info') {
  const toast = document.getElementById('toast');
  if (!toast) return;
  toast.textContent = message;
  toast.classList.remove('error', 'success', 'info');
  toast.classList.add('show');
  if (type === 'error' || type === 'success' || type === 'info') toast.classList.add(type);
  clearTimeout(toast._toastTimer);
  toast._toastTimer = setTimeout(() => {
    toast.classList.remove('show', 'error', 'success', 'info');
  }, 3000);
}

function formatZAR(amount) {
  return new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR' }).format(amount || 0);
}

function timeAgo(dateStr) {
  if (!dateStr) return '';
  const diff = (Date.now() - new Date(dateStr)) / 1000;
  if (diff < 60) return 'Just now';
  if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
  if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
  if (diff < 604800) return Math.floor(diff / 86400) + 'd ago';
  return new Date(dateStr).toLocaleDateString('en-ZA');
}

function getCategoryEmoji(category) {
  const map = {
    'Cleaning': '🧹', 'Plumbing': '🔧', 'Electrical': '⚡',
    'Beauty & Wellness': '💅', 'Tutoring & Education': '📚',
    'Garden & Landscaping': '🌿', 'Security': '🔒',
    'Moving & Deliveries': '📦', 'IT Support': '💻',
    'Painting & Decorating': '🎨', 'Carpentry': '🪚',
    'Appliance Repair': '🔌', 'Pest Control': '🐛',
    'Photography': '📸', 'Catering': '🍽️',
    'Personal Training': '💪', 'Child Minding': '👶',
  };
  return map[category] || '⭐';
}

// escapeHtml is defined once in index.html (exported as window.escapeHtml) — no duplicate here.

// ─────────────────── Global error boundary ──────────────────────
window.onerror = function(msg, src, line, col, err) {
  console.error('[Servit error]', msg, src, line, col, err);
  trackEvent('js_error', { message: msg, source: src, line });
  return false;
};
window.onunhandledrejection = function(e) {
  const msg = e.reason?.message || String(e.reason);
  console.error('[Servit rejection]', msg);
  trackEvent('unhandled_rejection', { message: msg });
  // Only surface network-type errors to the user — skip expected auth/cancel noise
  if (msg && !msg.includes('AbortError') && !msg.includes('User cancelled')) {
    showToast('Something went wrong. Please try again.', 'error');
  }
};

// ─────────────────── Analytics ──────────────────────────────────
function trackEvent(name, props = {}) {
  try {
    const payload = {
      event_name: name,
      properties: props,
      user_id: (typeof currentUser !== 'undefined' && currentUser?.id) || null
    };
    if (typeof supabaseClient !== 'undefined') {
      supabaseClient.from('analytics_events').insert(payload).then(() => {}).catch(() => {});
    }
    console.debug('[analytics]', name, props);
  } catch (_) { /* never block on analytics */ }
}
window.trackEvent = trackEvent;

// ─────────────────── Friendly auth error messages ───────────────
function friendlyAuthError(raw = '') {
  const r = raw.toLowerCase();
  if (r.includes('invalid login') || r.includes('invalid credentials') || r.includes('wrong password'))
    return 'Incorrect email or password. Please try again.';
  if (r.includes('email not confirmed') || r.includes('not confirmed'))
    return 'Please confirm your email first — check your inbox for a link from Servit.';
  if (r.includes('already registered') || r.includes('already exists') || r.includes('duplicate'))
    return 'An account with this email already exists. Try signing in instead.';
  if (r.includes('password') && r.includes('length'))
    return 'Password must be at least 8 characters long.';
  if (r.includes('invalid email') || r.includes('unable to validate email'))
    return 'Please enter a valid email address.';
  if (r.includes('too many requests') || r.includes('rate limit'))
    return 'Too many attempts. Please wait a minute and try again.';
  if (r.includes('network') || r.includes('fetch'))
    return 'No connection. Please check your internet and try again.';
  return raw || 'Something went wrong. Please try again.';
}


async function apiCall(endpoint, data = {}) {
  const { data: { session } } = await supabaseClient.auth.getSession();
  const token = session?.access_token;
  if (!token) throw new Error('Not authenticated');

  const response = await fetch(`/.netlify/functions/${endpoint}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`,
    },
    body: JSON.stringify(data),
  });

  const result = await response.json();
  if (!response.ok) throw new Error(result.error || `${endpoint} failed`);
  return result;
}

// ─────────────────── Geolocation helpers ────────────────────────

// IMPROVEMENT 1: Get customer's current coordinates silently.
// Returns { latitude, longitude } or null if permission denied / unavailable.
// We never block booking creation on this — it's best-effort.
function getCurrentLocation() {
  return new Promise((resolve) => {
    if (!navigator.geolocation) { resolve(null); return; }
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({ latitude: pos.coords.latitude, longitude: pos.coords.longitude }),
      () => resolve(null),  // permission denied or timeout — continue without coords
      { timeout: 5000, maximumAge: 60000 }
    );
  });
}

// ── v8.5: Fixer heartbeat — hardened for mobile phone-lock scenarios ──────
//
// ROOT CAUSE (v8.4 and earlier):
//   setInterval() is throttled or frozen when the phone screen locks or the
//   browser tab moves to the background on iOS and Android. A fixer whose phone
//   auto-locks after 30s would miss the next 60s ping and drop off matching
//   (3-minute grace = only 3 pings before exclusion).
//
// FIXES APPLIED:
//   1. Page Visibility API: fires an immediate ping when the tab/screen becomes
//      visible again (covers phone unlock, tab switch, app resume).
//   2. Grace period raised to 8 minutes on the DB side (v8.5 migration).
//      Even if 2 pings are missed due to throttling, the fixer stays visible.
//   3. Exponential backoff on failure (30s → 60s → 120s → 240s, cap 300s).
//      Prevents hammering the server when offline; recovers quickly when back.
//   4. Uses fixer_heartbeat_v2 RPC (v8.5) which accepts visibility hint,
//      resolves fixer from JWT user_id server-side (no extra auth roundtrip).
//   5. Banner now shows: time of last successful ping so fixer knows recency.

const HEARTBEAT_FAIL_THRESHOLD = 2;
const HEARTBEAT_BASE_INTERVAL  = 60000;  // 60s normal cadence
const HEARTBEAT_MAX_INTERVAL   = 300000; // 5 min max backoff
let   _heartbeatBackoff        = HEARTBEAT_BASE_INTERVAL;
let   _lastPingSuccess         = null;   // timestamp of last successful ping

function setHeartbeatBannerVisible(visible) {
  const banner = document.getElementById('heartbeat-banner');
  if (!banner) return;
  if (visible) {
    const lastOk = _lastPingSuccess
      ? 'Last OK: ' + timeAgo(_lastPingSuccess)
      : 'No successful ping yet.';
    banner.style.display = 'flex';
    banner.innerHTML = `
      <span>⚠️</span>
      <span style="flex:1">Connection issue — you may miss job offers. ${lastOk}</span>
      <button onclick="document.getElementById('heartbeat-banner').style.display='none'"
              style="background:none;border:none;cursor:pointer;font-size:18px;line-height:1;padding:0 4px">×</button>
    `;
  } else {
    banner.style.display = 'none';
    banner.innerHTML = '';
  }
}

// Core ping — calls fixer_heartbeat_v2 RPC directly (no extra auth roundtrip).
async function _doHeartbeatPing(visibilityHint = 'visible') {
  try {
    const { data: { session } } = await supabaseClient.auth.getSession();
    if (!session?.user) return;  // signed out

    const coords = await getCurrentLocation().catch(() => null);
    const payload = {
      p_user_id:    session.user.id,
      p_visibility: visibilityHint,
      p_app_state:  document.hidden ? 'background' : 'foreground',
    };
    if (coords) {
      payload.p_lat = coords.latitude;
      payload.p_lng = coords.longitude;
    }

    const { error } = await supabaseClient.rpc('fixer_heartbeat_v2', payload);
    if (error) throw error;

    // Success
    heartbeatFailures  = 0;
    _heartbeatBackoff  = HEARTBEAT_BASE_INTERVAL;
    _lastPingSuccess   = new Date().toISOString();
    setHeartbeatBannerVisible(false);
    return true;
  } catch (e) {
    heartbeatFailures += 1;
    // Exponential backoff: double interval up to max
    _heartbeatBackoff = Math.min(_heartbeatBackoff * 2, HEARTBEAT_MAX_INTERVAL);
    console.warn(`Heartbeat failed (${heartbeatFailures}/${HEARTBEAT_FAIL_THRESHOLD}), next in ${_heartbeatBackoff/1000}s:`, e.message);
    if (heartbeatFailures >= HEARTBEAT_FAIL_THRESHOLD) {
      setHeartbeatBannerVisible(true);
    }
    return false;
  }
}

// Self-scheduling heartbeat (respects backoff)
function _scheduleNextHeartbeat() {
  if (!heartbeatInterval) return; // stopped
  heartbeatInterval = setTimeout(async () => {
    if (!heartbeatInterval) return; // stopped while waiting
    await _doHeartbeatPing('visible');
    _scheduleNextHeartbeat();
  }, _heartbeatBackoff);
}

// Page Visibility API — fires immediately on phone unlock / tab resume
function _onVisibilityChange() {
  if (!document.hidden && heartbeatInterval) {
    // Screen just turned on / tab became active — ping immediately
    _doHeartbeatPing('resume');
  }
}

function startFixerHeartbeat() {
  if (heartbeatInterval) return; // already running

  heartbeatFailures  = 0;
  _heartbeatBackoff  = HEARTBEAT_BASE_INTERVAL;
  heartbeatInterval  = true; // sentinel to keep _scheduleNextHeartbeat going

  // Immediate ping on start
  _doHeartbeatPing('visible').then(() => _scheduleNextHeartbeat()).catch(() => {
    // If first ping fails, still schedule next attempt
    _scheduleNextHeartbeat();
  });

  // Page Visibility listener — deduplicated (remove first to avoid double-attach)
  document.removeEventListener('visibilitychange', _onVisibilityChange);
  document.addEventListener('visibilitychange', _onVisibilityChange);
}

function stopFixerHeartbeat() {
  if (typeof heartbeatInterval === 'number') {
    clearTimeout(heartbeatInterval);
  }
  // heartbeatInterval may be `true` (sentinel set before first async ping returns)
  // or a timeout ID number — set to null in either case to halt _scheduleNextHeartbeat
  heartbeatInterval = null;
  heartbeatFailures = 0;
  _heartbeatBackoff = HEARTBEAT_BASE_INTERVAL;
  setHeartbeatBannerVisible(false);
  document.removeEventListener('visibilitychange', _onVisibilityChange);
}

// ─────────────────── Booking creation ───────────────────────────

async function createBooking(description, address, phone, amount, bookingMode, scheduledFor, category = null, serviceTier = 'standard', serviceType = 'mobile') {
  try {
    showToast('Getting your location...', 'info');
    customerCoords = await getCurrentLocation();
    showToast('Creating booking...', 'info');

    // Generate idempotency key once per booking session and cache it.
    // If the Yoco redirect fails and the user retries, they get the same key
    // so the server returns the existing booking rather than creating a new one.
    let idempotencyKey;
    try {
      idempotencyKey = sessionStorage.getItem('servit_booking_ikey');
      if (!idempotencyKey) {
        idempotencyKey = crypto.randomUUID();
        sessionStorage.setItem('servit_booking_ikey', idempotencyKey);
      }
    } catch (_) {
      idempotencyKey = crypto.randomUUID(); // storage blocked — still safe per-call
    }

    const payload = {
      description, address, phone, amount, bookingMode, scheduledFor,
      category, serviceTier, serviceType, idempotencyKey,
    };
    if (customerCoords) {
      payload.latitude  = customerCoords.latitude;
      payload.longitude = customerCoords.longitude;
    }

    const result = await apiCall('create-booking', payload);

    // BUG 6 FIX: Do NOT clear the idempotency key here.
    // Clearing it immediately after the API call means if the Yoco redirect
    // fails and the user retries, they get a NEW key and create a DUPLICATE booking.
    // The key is cleared in checkPaymentReturn() on ?payment=success only,
    // which means Yoco has confirmed the payment and we're in a new booking session.
    // If payment is cancelled or fails, the key is KEPT so the retry reuses the
    // same booking row (idempotent replay).

    // FIX (Audit H7): Show a trust bridge before the Yoco redirect.
    // Users in small cities who've never heard of Yoco think they're being phished.
    // Show a 2-second interstitial with the Yoco logo and a clear explanation.
    await new Promise(resolve => {
      const bridge = document.createElement('div');
      bridge.style.cssText = 'position:fixed;inset:0;background:var(--warm-white);z-index:99999;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:32px;text-align:center;animation:fadeIn .2s ease';
      bridge.innerHTML = `
        <div style="width:72px;height:72px;border-radius:var(--r-xl);background:var(--forest);display:flex;align-items:center;justify-content:center;font-size:32px;margin-bottom:20px;box-shadow:0 8px 32px rgba(26,58,42,.2)">🔒</div>
        <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;color:var(--text-dark);margin-bottom:8px">Redirecting to Yoco</p>
        <p style="font-size:13px;color:var(--text-muted);line-height:1.7;max-width:280px;margin-bottom:24px">
          Payment is held securely by <strong>Yoco</strong> — South Africa's leading payment provider. If no fixer accepts your job, you get a full refund within 3–5 days.
        </p>
        <div style="display:flex;align-items:center;gap:8px;color:var(--text-muted);font-size:12px">
          <span style="width:14px;height:14px;border-radius:50%;border:2px solid var(--gold);border-top-color:transparent;animation:spin .7s linear infinite;display:inline-block;flex-shrink:0"></span>
          Connecting securely…
        </div>`;
      document.body.appendChild(bridge);
      setTimeout(resolve, 2000);
    });

    window.location.href = result.checkout_url;
  } catch (err) {
    showToast(err.message, 'error');
  }
}

// Called from showApp() when URL contains ?payment=success|cancelled|failed.
// Running here (post-auth) ensures subscribeToBookingStatus gets an authenticated
// Supabase session and the realtime channel actually receives updates.
function checkPaymentReturn() {
  const params = new URLSearchParams(window.location.search);
  const paymentStatus = params.get('payment');
  const bookingId = params.get('booking_id');

  if (!paymentStatus) return;

  // Clean URL without reload
  window.history.replaceState({}, '', '/');

  if (paymentStatus === 'success' && bookingId) {
    trackEvent('payment_success', { booking_id: bookingId });
    // BUG 6 FIX: Only clear the idempotency key on confirmed payment success.
    // Payment cancelled/failed paths must KEEP the key so a retry creates the
    // same booking row (idempotent), not a new duplicate.
    try { sessionStorage.removeItem('servit_booking_ikey'); } catch (_) {}
    // FIX 3: Clear the booking draft on successful payment — without this the stale
    // draft persists in sessionStorage and pre-fills the next booking form with the
    // previous job's data, confusing customers who book a different service later.
    try { sessionStorage.removeItem('servit_booking_draft'); } catch (_) {}
    showPaymentSuccessScreen(bookingId);
  } else if (paymentStatus === 'success') {
    // Production hardening: Yoco can occasionally return without booking_id if
    // an upstream URL is cached/mangled. Resume active booking instead of silently
    // dropping the customer on home with a paid charge.
    trackEvent('payment_success_missing_booking_id');
    showToast('Payment received. Restoring your booking…');
    resumeActiveBookingIfAny();
  } else if (paymentStatus === 'cancelled') {
    trackEvent('payment_cancelled');
    // BUG 12 FIX: Cancel the orphan booking when payment is abandoned.
    // A CREATED/PENDING_PAYMENT booking exists in the DB from the earlier API call.
    // If the user cancels Yoco, this booking sits in CREATED state indefinitely — 
    // no refund is needed (no payment was taken) but the row should be cleaned up.
    // The idempotency key is KEPT (not cleared) so if the user retries from the
    // result sheet, the Netlify function returns the existing booking_id.
    if (bookingId) {
      apiCall('cancel-booking', { booking_id: bookingId }).catch(e =>
        console.warn('[Servit] Orphan booking cleanup failed (non-fatal):', e.message)
      );
    }
    showPaymentResultSheet('cancelled');
  } else if (paymentStatus === 'failed') {
    trackEvent('payment_failed', { booking_id: bookingId });
    showPaymentResultSheet('failed', bookingId);
  }
}

function showPaymentSuccessScreen(bookingId) {
  // FIX (v8.9): Guard against empty/null bookingId — if Yoco somehow returns without
  // one, fall back to resumeActiveBookingIfAny rather than creating a broken overlay
  // that polls forever against an undefined booking ID.
  if (!bookingId) {
    console.warn('[Servit] showPaymentSuccessScreen called without bookingId — running resumeActiveBookingIfAny');
    resumeActiveBookingIfAny();
    return;
  }

  // FIX (redirect stabilisation): Previously called showHomeScreen() here so
  // #screen-waiting was in the DOM when renderWaitingScreen ran later. The side
  // effect was that a failed overlay-→-waiting transition left the customer on
  // Home even though they had paid. We now silently pre-activate #screen-waiting
  // directly, so the success path NEVER lands on Home.
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  const ws = document.getElementById('screen-waiting');
  if (ws) ws.classList.add('active');
  // Pre-seed waiting content with a spinner so there is no blank flash if the
  // overlay is dismissed before the poll completes.
  const pre = document.getElementById('waiting-content') || document.querySelector('#screen-waiting .waiting-container');
  if (pre && !pre.innerHTML.trim()) {
    pre.innerHTML = '<div style="padding:48px 20px;text-align:center"><div style="font-size:40px;margin-bottom:16px;animation:servit-pulse 2s infinite">⏳</div><p style="font-size:15px;font-weight:600">Processing your payment…</p><p style="font-size:12px;color:var(--text-muted);margin-top:6px">Please wait — do not close this page.</p></div>';
  }
  // FIX: Stake the booking ID immediately so a disconnect/refresh during the
  // overlay still resumes here via resumeActiveBookingIfAny().
  currentBookingId = bookingId;

  // Show a dedicated success moment while we wait for the webhook to confirm
  const overlay = document.createElement('div');
  overlay.id = 'payment-success-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:var(--warm-white);z-index:99999;display:flex;align-items:center;justify-content:center;flex-direction:column;padding:32px;text-align:center;animation:fadeIn .3s ease';
  overlay.innerHTML = `
    <div style="width:88px;height:88px;border-radius:50%;background:linear-gradient(135deg,var(--forest),#2D5A3D);display:flex;align-items:center;justify-content:center;font-size:40px;margin-bottom:24px;box-shadow:0 12px 40px rgba(26,58,42,.25);animation:servit-pulse 1.5s ease 1">✅</div>
    <p style="font-family:'Playfair Display',serif;font-size:24px;font-weight:700;color:var(--text-dark);margin-bottom:8px">Payment confirmed!</p>
    <p style="font-size:14px;color:var(--text-muted);line-height:1.7;max-width:280px;margin-bottom:28px">Your payment is secured. We're now finding the best fixer for you.</p>
    <div style="background:var(--cream);border:1px solid var(--border);border-radius:var(--r-md);padding:10px 20px;margin-bottom:28px">
      <p style="font-size:10px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.5px;margin-bottom:3px">Booking reference</p>
      <p style="font-family:'DM Mono',monospace;font-size:13px;font-weight:700;color:var(--forest)">${bookingId.slice(0,8).toUpperCase()}</p>
    </div>
    <div id="pso-status" style="display:flex;align-items:center;gap:8px;color:var(--text-muted);font-size:12px">
      <span style="width:14px;height:14px;border-radius:50%;border:2px solid var(--gold);border-top-color:transparent;animation:spin .7s linear infinite;display:inline-block;flex-shrink:0"></span>
      Confirming with payment provider…
    </div>`;
  document.body.appendChild(overlay);

  // Poll the booking status until the webhook has fired (PENDING_PAYMENT → SEARCHING).
  // The Yoco webhook usually arrives within 2–5s; we poll every 2s for up to 30s,
  // then fall back to calling verify-payment ourselves so the customer is never stuck.
  let attempts = 0;
  const maxAttempts = 15; // 15 × 2s = 30s
  const pollInterval = setInterval(async () => {
    // FIX A: If the overlay was dismissed (user navigated away), stop polling silently.
    // Previously the poll would keep running and call showWaitingScreen on whatever
    // screen the user was on when the webhook finally fired.
    if (!document.getElementById('payment-success-overlay')) {
      clearInterval(pollInterval);
      return;
    }
    attempts++;
    try {
      const { data: bk } = await supabaseClient
        .from('bookings')
        .select('id, status')
        .eq('id', bookingId)
        .maybeSingle();

      if (bk && bk.status !== 'PENDING_PAYMENT' && bk.status !== 'CREATED') {
        // Webhook fired — booking is now SEARCHING (or further). Move on.
        // FIX (v8.9 BUG 4): Subscribe BEFORE calling showWaitingScreen so the
        // realtime channel is active before the screen renders and inline timers
        // start.  Previous order (showWaiting then subscribe) created a brief gap
        // where a fast OFFERED event could fire before the channel was ready and
        // handleBookingStatusChange would never run for that transition.
        clearInterval(pollInterval);
        overlay.remove();
        currentBookingId = bookingId;
        subscribeToBookingStatus(bookingId, handleBookingStatusChange);
        showWaitingScreen(bookingId);
        return;
      }
    } catch (_) { /* non-fatal — keep polling */ }

    if (attempts >= maxAttempts) {
      // Webhook hasn't arrived in 30s — call verify-payment ourselves as fallback.
      clearInterval(pollInterval);
      const statusEl = overlay.querySelector('#pso-status');
      if (statusEl) statusEl.innerHTML = '<span style="color:var(--gold-dark);font-size:12px">⏳ Verifying with payment provider…</span>';
      try {
        const vr = await apiCall('verify-payment', { booking_id: bookingId });
        // FIX: verify-payment returns { ok: false } when Yoco confirms the charge
        // was not successful. Show the failure sheet — never land on waiting screen.
        if (vr && vr.ok === false) {
          overlay.remove();
          showPaymentResultSheet('failed', bookingId);
          return;
        }
      } catch(e) {
        console.warn('[Servit] verify-payment fallback error:', e.message);
      }
      overlay.remove();
      currentBookingId = bookingId;
      // FIX (v8.9 BUG 4): Subscribe before showWaitingScreen (same race fix as above)
      subscribeToBookingStatus(bookingId, handleBookingStatusChange);
      showWaitingScreen(bookingId);
    }
  }, 2000);
}

function showPaymentResultSheet(status, bookingId = null) {
  const isCancelled = status === 'cancelled';
  const sheet = document.createElement('div');
  sheet.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end;animation:fadeIn .2s ease';

  // Try to recover saved booking draft so user doesn't have to re-enter everything
  let draft = null;
  try { draft = JSON.parse(sessionStorage.getItem('servit_booking_draft') || 'null'); } catch (_) {}

  sheet.innerHTML = `
    <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:28px 20px 44px;text-align:center;animation:slideUp .28s cubic-bezier(.25,.46,.45,.94)">
      <div style="font-size:52px;margin-bottom:16px">${isCancelled ? '❌' : '⚠️'}</div>
      <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;color:var(--text-dark);margin-bottom:8px">${isCancelled ? 'Payment cancelled' : 'Payment failed'}</p>
      <p style="font-size:13px;color:var(--text-muted);line-height:1.7;margin-bottom:${draft ? '12px' : '24px'};max-width:280px;margin-left:auto;margin-right:auto">
        ${isCancelled
          ? "You cancelled the payment — no charge was made."
          : "Your payment didn't go through. Please check your card details or try a different payment method."}
      </p>
      ${!isCancelled && bookingId ? `<div style="background:var(--cream);border:1px solid var(--border);border-radius:var(--r-md);padding:10px 14px;margin-bottom:16px;text-align:left">
        <p style="font-size:10px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.5px;margin-bottom:4px">Your booking is held for 15 minutes</p>
        <p style="font-family:monospace;font-size:13px;font-weight:700;color:var(--forest)">Ref: ${bookingId.slice(0,8).toUpperCase()}</p>
        <p style="font-size:11px;color:var(--text-muted);margin-top:4px">Complete payment to keep it, or it will be automatically cancelled.</p>
      </div>` : ''}
      ${draft ? `<div style="background:var(--cream);border:1px solid var(--border);border-radius:var(--r-md);padding:10px 14px;margin-bottom:20px;text-align:left">
        <p style="font-size:10px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px">Your booking details are saved</p>
        <p style="font-size:12px;color:var(--text-mid)">📝 ${escapeHtml(draft.description || '')}</p>
        <p style="font-size:12px;color:var(--text-muted)">📍 ${escapeHtml(draft.address || '')}</p>
      </div>` : ''}
      <button class="btn btn-primary btn-block" id="_prs-retry-btn" style="margin-bottom:10px">
        ${draft ? 'Try payment again →' : 'Try again →'}
      </button>
      <button class="btn btn-outline btn-block" onclick="this.closest('div').parentElement.remove()" style="color:var(--text-muted);border-color:var(--border);font-size:13px">Dismiss</button>
    </div>`;
  document.body.appendChild(sheet);
  sheet.addEventListener('click', e => { if (e.target === sheet) sheet.remove(); });

  // Retry button — restore draft if available, else go home
  sheet.querySelector('#_prs-retry-btn').onclick = () => {
    sheet.remove();
    if (draft) {
      showRequestScreen(draft.category, getCategoryEmoji(draft.category), draft.label || draft.category);
      // Restore fields after the screen renders
      setTimeout(() => {
        const setVal = (id, val) => { const el = document.getElementById(id); if (el && val) el.value = val; };
        setVal('job-description', draft.description);
        setVal('job-address', draft.address);
        setVal('job-phone', draft.phone);
        setVal('job-budget', draft.amount);
        if (draft.bookingMode) {
          const modeEl = document.getElementById('booking-mode');
          if (modeEl) { modeEl.value = draft.bookingMode; modeEl.dispatchEvent(new Event('change')); }
        }
        if (draft.scheduledFor) setVal('scheduled-datetime', draft.scheduledFor);
        if (draft.tier) selectTier(draft.tier);
        if (draft.amount) updatePricePreview(String(draft.amount));
      }, 100);
    } else {
      showHomeScreen();
    }
  };
}

// ─────────────────── Realtime subscriptions ─────────────────────

/**
 * FIX: Replaces startMatchingPolling() + setInterval patterns.
 * Subscribe to booking row changes via Supabase Realtime.
 * The callback receives the full new booking row on every change.
 */
function subscribeToBookingStatus(bookingId, onUpdate) {
  if (bookingChannel) {
    supabaseClient.removeChannel(bookingChannel);
  }

  bookingChannel = supabaseClient
    .channel(`booking-status-${bookingId}`)
    .on('postgres_changes', {
      event: 'UPDATE',
      schema: 'public',
      table: 'bookings',
      filter: `id=eq.${bookingId}`,
    }, (payload) => {
      if (payload.new.status !== payload.old?.status) {
        onUpdate(payload.new);
      }
    })
    .subscribe((status) => {
      if (status === 'SUBSCRIPTION_ERROR') {
        console.warn('[Realtime] Booking status subscription error - fallback polling will handle updates');
      }
    });

  // FIX: Fallback poll — realtime channels can silently fail (auth race, network
  // flap, Supabase plan limits). Poll every 5s so the customer is never stuck on
  // the waiting screen even if the realtime event is missed. We track the last
  // seen status so onUpdate is only called when the status actually changes.
  let _lastPolledStatus = null;
  const _pollInterval = setInterval(async () => {
    // Stop polling if the channel was torn down (navigation / cancellation)
    if (!bookingChannel) { clearInterval(_pollInterval); return; }
    try {
      const { data } = await supabaseClient
        .from('bookings')
        .select('id, status, fixer_id')
        .eq('id', bookingId)
        .maybeSingle();
      if (data && data.status !== _lastPolledStatus) {
        const prev = _lastPolledStatus;
        _lastPolledStatus = data.status;
        // FIX C: Fire onUpdate when:
        //   1. Normal case — status changed from a previously known state (prev !== null), OR
        //   2. First-tick reconnect — prev is null AND booking is already past SEARCHING.
        //      This handles: customer closes app while fixer is reviewing, reopens, and
        //      the first poll finds OFFERED/CONFIRMED/etc. Without this fix, _lastPolledStatus
        //      is seeded silently and the screen never advances — customer stuck on SEARCHING
        //      with money already taken.
        // We still skip first-tick for SEARCHING itself to avoid the redundant
        // handleBookingStatusChange that showWaitingScreen already handles.
        const isFirstTickAdvanced = (prev === null && data.status !== 'SEARCHING');
        if (prev !== null || isFirstTickAdvanced) {
          onUpdate(data);
        }
      }
    } catch (_) { /* non-fatal — realtime is primary */ }
  }, 5000);

  // Attach the interval to the channel object so teardownBookingSubscription can clear it
  bookingChannel._fallbackPoll = _pollInterval;
}

function teardownBookingSubscription() {
  if (bookingChannel) {
    // FIX: Clear the fallback poll interval before removing the channel
    if (bookingChannel._fallbackPoll) clearInterval(bookingChannel._fallbackPoll);
    supabaseClient.removeChannel(bookingChannel);
    bookingChannel = null;
  }
  // Also destroy the live map if it's running
  if (window.destroyServitMap) window.destroyServitMap();
}

// FIX: Central handler for all customer-side booking status changes
function handleBookingStatusChange(booking) {
  const derived = deriveJobState(booking);
  const toasts = {
    [JOB_STATE.SEARCHING_FOR_FIXER]: '🔍 Searching for a fixer...',
    [JOB_STATE.FIXER_NOTIFIED]: '📲 Nearby fixers notified. Waiting for acceptance...',
    [JOB_STATE.FIXER_ASSIGNED]: '✅ Fixer accepted! Loading job...',
    [JOB_STATE.JOB_STARTED]: '🚗 Your fixer is on the way / starting now.',
    [JOB_STATE.JOB_COMPLETED]: '✅ Job completed! Thank you.',
    [JOB_STATE.NO_FIXER_FOUND]: '😔 No fixer accepted in time. Refund in progress.',
    [JOB_STATE.MATCHING_FAILED]: '😔 Could not find a fixer. Refund in progress.',
    [JOB_STATE.PAYMENT_REFUNDED]: '💸 Payment refunded.',
    [JOB_STATE.JOB_CANCELLED]: '❌ Booking cancelled',
  };
  if (derived && toasts[derived]) showToast(toasts[derived], (derived === JOB_STATE.NO_FIXER_FOUND || derived === JOB_STATE.MATCHING_FAILED) ? 'error' : 'success');

  // FIX: PENDING_PAYMENT + paid means the webhook fired while we were still on
  // the payment overlay. Dismiss the overlay and move straight to waiting —
  // do NOT fall through to a home redirect.
  if (booking.status === 'PENDING_PAYMENT' && booking.payment_status === 'paid') {
    const overlay = document.getElementById('payment-success-overlay');
    if (overlay) overlay.remove();
    currentBookingId = booking.id;
    showWaitingScreen(booking.id);
    subscribeToBookingStatus(booking.id, handleBookingStatusChange);
    return;
  }

  if (booking.status === 'SEARCHING') {
    // Webhook just fired — we may still be on the "confirming payment" overlay
    // or on the waiting screen. Only navigate to waiting if not already there.
    const overlay = document.getElementById('payment-success-overlay');
    if (overlay) overlay.remove();
    const alreadyWaiting = document.getElementById('screen-waiting')?.classList.contains('active');
    if (!alreadyWaiting) {
      showWaitingScreen(booking.id);
    }
  } else if (booking.status === 'OFFERED') {
    // Re-render waiting screen to show "fixer reviewing" state
    renderWaitingScreen(booking.id, 'OFFERED');
  } else if (booking.status === 'CONFIRMED' || booking.status === 'EN_ROUTE' ||
      booking.status === 'ARRIVED'   || booking.status === 'IN_PROGRESS' ||
      booking.status === 'PENDING_COMPLETION') {
    loadActiveJob(booking.id);
  } else if (booking.status === 'COMPLETED') {
    // FIX 4: Tear down the subscription before rendering the completed state.
    // loadActiveJob() tears it down internally, but it also re-subscribes for
    // the completed booking — a live channel we no longer need. Tearing down
    // first means loadActiveJob fetches + renders without re-subscribing.
    teardownBookingSubscription();
    loadActiveJob(booking.id);
  } else if (booking.status === 'EXPIRED') {
    teardownBookingSubscription();
    showBookingExpiredScreen(booking);
  } else if (booking.status === 'FAILED_MATCH') {
    teardownBookingSubscription();
    showBookingExpiredScreen(booking);
  } else if (booking.status === 'CANCELLED') {
    teardownBookingSubscription();
    // FIX: Show toast before navigating home so customers know what happened.
    // Only go home — never silently drop a paid customer with no feedback.
    setTimeout(() => showHomeScreen(), 600);
  }
}

// FIX (Audit H9): Dedicated EXPIRED screen — explains what happened, confirms
// refund is in progress, offers next steps. Replaces the silent home redirect.
function showBookingExpiredScreen(booking) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-home').classList.add('active');
  updateActiveNav('home');
  loadCategories();
  loadFixers();

  // Overlay shown on top of home screen
  const overlay = document.createElement('div');
  overlay.id = 'expired-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.6);z-index:9990;display:flex;align-items:flex-end;animation:fadeIn .25s ease';
  overlay.innerHTML = `
    <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:28px 20px 48px;animation:slideUp .3s ease">
      <div style="text-align:center;margin-bottom:20px">
        <div style="font-size:52px;margin-bottom:12px">😔</div>
        <p style="font-family:'Playfair Display',serif;font-size:21px;font-weight:700;color:var(--text-dark);margin-bottom:8px">No fixer was available</p>
        <p style="font-size:13px;color:var(--text-muted);line-height:1.7;max-width:300px;margin:0 auto">No one in your area accepted the job in time. This happens in quieter areas or off-peak hours.</p>
      </div>
      <div style="background:var(--cream);border:1.5px solid var(--border);border-radius:var(--r-md);padding:14px;margin-bottom:20px">
        <p style="font-size:11px;font-weight:700;color:var(--forest);text-transform:uppercase;letter-spacing:.5px;margin-bottom:10px">What happens now</p>
        <div style="display:flex;align-items:flex-start;gap:10px;margin-bottom:8px">
          <span style="font-size:16px;flex-shrink:0">💳</span>
          <p style="font-size:13px;color:var(--text-mid);line-height:1.6"><strong>Full refund in progress</strong> — if you were charged, the refund will appear within 3–5 business days.</p>
        </div>
        <div style="display:flex;align-items:flex-start;gap:10px">
          <span style="font-size:16px;flex-shrink:0">📋</span>
          <p style="font-size:13px;color:var(--text-mid);line-height:1.6">Booking ref: <strong style="font-family:monospace">${(booking.id || '').slice(0,8).toUpperCase()}</strong></p>
        </div>
      </div>
      <p style="font-size:12px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.5px;margin-bottom:10px">What would you like to do?</p>
      <button class="btn btn-primary btn-block" style="margin-bottom:10px" onclick="document.getElementById('expired-overlay')?.remove();showRequestScreen('${escapeHtml(booking.category || 'Other')}','${getCategoryEmoji(booking.category)}','${escapeHtml(booking.category || 'Other')}')">
        Try again with higher budget →
      </button>
      <button class="btn btn-outline btn-block" style="margin-bottom:10px;font-size:13px" onclick="document.getElementById('expired-overlay')?.remove();window.open('https://wa.me/27782629774?text=Hi+Servit+Support,+my+booking+${(booking.id||'').slice(0,8).toUpperCase()}+expired','_blank')">
        💬 Contact support
      </button>
      <button class="btn btn-block" style="background:transparent;border:none;color:var(--text-muted);font-size:13px;padding:8px" onclick="document.getElementById('expired-overlay')?.remove()">
        Dismiss
      </button>
    </div>`;
  document.body.appendChild(overlay);
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
  trackEvent('booking_expired_screen_shown', { booking_id: booking.id });
}

// Fixer-side: subscribe to new offers sent to this fixer
function subscribeToFixerOffers(fixerId) {
  if (offerChannel) {
    supabaseClient.removeChannel(offerChannel);
  }

  offerChannel = supabaseClient
    .channel(`fixer-offers-${fixerId}`)
    .on('postgres_changes', {
      event: 'INSERT',
      schema: 'public',
      table: 'offers',
      filter: `fixer_id=eq.${fixerId}`,
    }, (payload) => {
      const offer = payload.new;
      // Immediately show the offer screen so the fixer doesn't miss the 45s window.
      // Also reload the dashboard in case they dismiss it.
      showToast('🔔 New job offer! Tap to review.', 'success');
      loadFixerDashboard();
      // Auto-navigate to the offer screen ONLY if fixer is on dashboard/home
      // (not if they're mid-job on screen-job — that would interrupt active work)
      const jobScreenActive = document.getElementById('screen-job')?.classList.contains('active');
      if (offer.booking_id && offer.id && !jobScreenActive) {
        showOfferScreen(offer.booking_id, offer.id);
      }
    })
    .subscribe((status) => {
      if (status === 'SUBSCRIPTION_ERROR') {
        console.warn('[Realtime] Fixer offers subscription error - dashboard will refresh manually');
      }
    });
}

// IMPROVEMENT 3: Fixer subscribes to demand_alert notifications.
// When match_fixers() finds no available fixers it inserts a notification
// row for every fixer in the area. This subscription wakes up any fixer
// who has the app open so they can toggle available and grab the job.
function subscribeToFixerDemandAlerts(userId) {
  if (demandAlertChannel) {
    supabaseClient.removeChannel(demandAlertChannel);
  }

  demandAlertChannel = supabaseClient
    .channel(`demand-alerts-${userId}`)
    .on('postgres_changes', {
      event: 'INSERT',
      schema: 'public',
      table: 'notifications',
      filter: `user_id=eq.${userId}`,
    }, (payload) => {
      if (payload.new.type === 'demand_alert') {
        // Show a persistent banner — demand alerts are actionable
        showToast('💼 ' + payload.new.title + ' — ' + payload.new.body, 'success');
        // If fixer is currently offline, nudge them
        if (currentFixerProfile && !currentFixerProfile.available) {
          setTimeout(() => {
            showToast('Toggle yourself online to accept this job!', 'info');
          }, 3000);
        }
        loadFixerDashboard();
      }
    })
    .subscribe((status) => {
      if (status === 'SUBSCRIPTION_ERROR') {
        console.warn('[Realtime] Demand alerts subscription error - manual refresh may be needed');
      }
    });
}

// ─────────────────── Waiting screen ─────────────────────────────

function showWaitingScreen(bookingId) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  const ws = document.getElementById('screen-waiting');
  if (ws) ws.classList.add('active');
  renderWaitingScreen(bookingId, 'SEARCHING');
}

function renderWaitingScreen(bookingId, currentStatus) {
  const container = document.getElementById('waiting-content') || document.querySelector('#screen-waiting .waiting-container');
  if (!container) return;

  // Clear any existing timers
  (container._searchTimers || []).forEach(t => clearTimeout(t));
  if (container._timeoutTimer) clearTimeout(container._timeoutTimer);
  container._searchTimers = [];

  if (currentStatus === 'SEARCHING') {
    container.innerHTML = `
      <div style="padding:32px 20px 24px;text-align:center">
        <div style="width:72px;height:72px;border-radius:50%;background:linear-gradient(135deg,var(--forest),#2D5A3D);display:flex;align-items:center;justify-content:center;font-size:32px;margin:0 auto 20px;box-shadow:0 8px 32px rgba(26,58,42,.25);animation:servit-pulse 2s infinite">🔧</div>
        <p id="search-headline" style="font-family:'Playfair Display',serif;font-size:19px;font-weight:700;color:var(--text-dark);margin-bottom:6px;transition:opacity .3s">Finding your fixer…</p>
        <p id="search-sub" style="font-size:13px;color:var(--text-muted);min-height:20px;transition:opacity .3s">Scanning available professionals nearby</p>

        <!-- Step indicators -->
        <div style="margin:24px 0 20px;text-align:left">
          <div id="step-scan" style="display:flex;align-items:center;gap:12px;padding:10px 14px;border-radius:var(--r-md);background:var(--cream);margin-bottom:8px;border:1.5px solid var(--forest);transition:all .4s">
            <span style="width:28px;height:28px;border-radius:50%;background:var(--forest);display:flex;align-items:center;justify-content:center;color:#fff;font-size:13px;flex-shrink:0">🔍</span>
            <div style="flex:1"><p style="font-size:13px;font-weight:600;color:var(--text-dark)">Scanning for available fixers nearby…</p><p style="font-size:11px;color:var(--text-muted)">Checking who's online in your area</p></div>
            <span id="ind-scan" style="width:16px;height:16px;border-radius:50%;border:2px solid var(--forest);border-top-color:transparent;animation:spin .7s linear infinite;flex-shrink:0;display:inline-block"></span>
          </div>
          <div id="step-match" style="display:flex;align-items:center;gap:12px;padding:10px 14px;border-radius:var(--r-md);background:var(--warm-white);margin-bottom:8px;border:1.5px solid var(--border);opacity:.4;transition:all .4s">
            <span id="icon-match" style="width:28px;height:28px;border-radius:50%;background:var(--border);display:flex;align-items:center;justify-content:center;color:var(--text-muted);font-size:13px;flex-shrink:0">⭐</span>
            <div style="flex:1"><p style="font-size:13px;font-weight:600;color:var(--text-mid)">Matching based on rating &amp; your location</p><p style="font-size:11px;color:var(--text-muted)">Rating, experience &amp; distance</p></div>
            <span id="ind-match" style="font-size:11px;color:var(--text-muted)">Next</span>
          </div>
          <div id="step-contact" style="display:flex;align-items:center;gap:12px;padding:10px 14px;border-radius:var(--r-md);background:var(--warm-white);border:1.5px solid var(--border);opacity:.4;transition:all .4s">
            <span id="icon-contact" style="width:28px;height:28px;border-radius:50%;background:var(--border);display:flex;align-items:center;justify-content:center;color:var(--text-muted);font-size:13px;flex-shrink:0">📲</span>
            <div style="flex:1"><p style="font-size:13px;font-weight:600;color:var(--text-mid)">Sending request to best match (1 at a time)</p><p style="font-size:11px;color:var(--text-muted)">Each fixer has 45s to accept</p></div>
            <span id="ind-contact" style="font-size:11px;color:var(--text-muted)">Soon</span>
          </div>
        </div>

        <!-- Progress bar -->
        <div style="height:4px;background:var(--border);border-radius:2px;margin-bottom:16px;overflow:hidden">
          <div id="search-prog" style="height:100%;background:linear-gradient(90deg,var(--forest),var(--gold));border-radius:2px;width:15%;transition:width 1.2s ease"></div>
        </div>

        <!-- Timeout banner — hidden initially -->
        <div id="timeout-banner" style="display:none;background:#FEF3CD;border:1.5px solid var(--gold-dark);border-radius:var(--r-md);padding:12px 14px;margin-bottom:16px;text-align:left">
          <p style="font-size:13px;font-weight:700;color:#856404;margin-bottom:4px">⏱️ Still looking…</p>
          <p style="font-size:12px;color:#856404;line-height:1.6;margin-bottom:10px">It's taking longer than usual. Fixers nearby have been notified — we're waiting for one to accept.</p>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-sm" onclick="retrySearch('${bookingId}')" style="background:var(--gold-dark);color:#fff;border:none;font-size:12px;padding:8px 14px;flex:1">Retry now</button>
            <button class="btn btn-sm btn-outline" onclick="scheduleInstead('${bookingId}')" style="font-size:12px;padding:8px 14px;flex:1;color:#856404;border-color:var(--gold-dark)">Schedule later</button>
            <button class="btn btn-sm btn-outline" onclick="cancelBooking('${bookingId}')" style="font-size:12px;padding:8px 14px;width:100%;color:var(--text-muted);border-color:var(--border);margin-top:4px">Cancel &amp; get refund</button>
          </div>
        </div>

        <!-- Normal footer -->
        <div id="normal-footer">
          <p style="font-size:11px;color:var(--text-muted);line-height:1.6;margin-bottom:8px">
            ${(typeof Notification !== 'undefined' && Notification.permission === 'granted') ? '🔔 You\'ll get a push notification the moment your fixer is confirmed.' : '🔔 Enable notifications so we can alert you when your fixer is confirmed — <span style="color:var(--forest);cursor:pointer;text-decoration:underline" onclick="requestPushPermission()">tap here</span>.'}
          </p>
          <p style="font-size:11px;color:var(--text-muted);margin-bottom:16px">You can safely close this screen.</p>
          <button class="btn btn-outline btn-sm" onclick="cancelBooking('${bookingId}')" style="color:var(--text-muted);border-color:var(--border);font-size:12px;margin-bottom:8px;width:100%">Cancel request</button>
          <p style="font-size:11px;color:var(--text-muted)">Need help? <span style="color:var(--forest);cursor:pointer;text-decoration:underline" onclick="window.open('https://wa.me/27782629774?text=Hi+I+need+help+with+booking+${bookingId}','_blank')">Contact support</span></p>
        </div>
      </div>`;

    const qs = id => container.querySelector('#' + id);
    const phases = [
      { pct:20, headline:'Finding your fixer…',       sub:'Scanning available professionals nearby' },
      { pct:48, headline:'Found matches!',             sub:'Comparing rating, experience & distance' },
      { pct:74, headline:'Contacting professionals…', sub:'Sending your request to the best match' },
      { pct:90, headline:'Almost there…',             sub:'Waiting for fixer to confirm' },
    ];
    let phase = 0;
    function advance() {
      phase++;
      const p = phases[Math.min(phase, phases.length - 1)];
      const hl = qs('search-headline'), sb = qs('search-sub'), bar = qs('search-prog');
      if (bar) bar.style.width = p.pct + '%';
      if (hl) { hl.style.opacity='0'; setTimeout(()=>{ hl.textContent=p.headline; hl.style.opacity='1'; },200); }
      if (sb) { sb.style.opacity='0'; setTimeout(()=>{ sb.textContent=p.sub; sb.style.opacity='1'; },300); }
      if (phase === 1) {
        const s = qs('step-match'); if (s) { s.style.opacity='1'; s.style.background='var(--cream)'; s.style.borderColor='var(--gold-dark)'; }
        const ic = qs('icon-match'); if (ic) { ic.style.background='var(--gold-dark)'; ic.style.color='#fff'; }
        const ind = qs('ind-match'); if (ind) ind.outerHTML = '<span id="ind-match" style="width:16px;height:16px;border-radius:50%;border:2px solid var(--gold-dark);border-top-color:transparent;animation:spin .7s linear infinite;flex-shrink:0;display:inline-block"></span>';
      }
      if (phase === 2) {
        const s = qs('step-contact'); if (s) { s.style.opacity='1'; s.style.background='var(--cream)'; s.style.borderColor='var(--info)'; }
        const ic = qs('icon-contact'); if (ic) { ic.style.background='var(--info)'; ic.style.color='#fff'; }
        const ind = qs('ind-contact'); if (ind) ind.outerHTML = '<span id="ind-contact" style="width:16px;height:16px;border-radius:50%;border:2px solid var(--info);border-top-color:transparent;animation:spin .7s linear infinite;flex-shrink:0;display:inline-block"></span>';
      }
    }
    container._searchTimers = [setTimeout(advance,2800), setTimeout(advance,6200), setTimeout(advance,11000)];

    // Timeout: show fallback banner after 50s
    container._timeoutTimer = setTimeout(() => {
      const banner = qs('timeout-banner');
      const footer = qs('normal-footer');
      const bar = qs('search-prog');
      const hl = qs('search-headline');
      const sb = qs('search-sub');
      if (banner) banner.style.display = 'block';
      if (footer) footer.style.display = 'none';
      if (bar) bar.style.width = '95%';
      if (hl) { hl.style.opacity='0'; setTimeout(()=>{ hl.textContent='Still looking…'; hl.style.opacity='1'; },200); }
      if (sb) { sb.style.opacity='0'; setTimeout(()=>{ sb.textContent='Fixers nearby have been notified — waiting for one to accept.'; sb.style.opacity='1'; },300); }
      trackEvent('search_timeout', { booking_id: bookingId });
    }, 50000);

  } else if (currentStatus === 'OFFERED') {
    container.innerHTML = `
      <div style="padding:32px 20px 24px;text-align:center">
        <div style="width:72px;height:72px;border-radius:50%;background:linear-gradient(135deg,#8B6420,#C9943A);display:flex;align-items:center;justify-content:center;font-size:32px;margin:0 auto 20px;box-shadow:0 8px 32px rgba(201,148,58,.3);animation:servit-pulse 1.5s infinite">📲</div>
        <p style="font-family:'Playfair Display',serif;font-size:19px;font-weight:700;color:var(--text-dark);margin-bottom:6px">Fixer reviewing your job</p>
        <p style="font-size:13px;color:var(--text-muted);margin-bottom:8px">They have 45 seconds to accept</p>
        <p style="font-size:11px;color:var(--text-muted);margin-bottom:24px">If they decline, we'll automatically try the next best match.</p>
        <div style="height:4px;background:var(--border);border-radius:2px;margin-bottom:20px;overflow:hidden">
          <div style="height:100%;background:linear-gradient(90deg,var(--gold-dark),var(--gold));border-radius:2px;width:88%;"></div>
        </div>
        <div style="background:var(--cream);border-radius:var(--r-md);padding:12px;margin-bottom:16px;text-align:left;font-size:12px;color:var(--text-mid)">
          <p style="font-weight:600;margin-bottom:6px;color:var(--text-dark)">What happens next</p>
          <p>✅ Fixer accepts → you see their name, rating &amp; ETA</p>
          <p style="margin-top:4px">❌ Fixer declines → we instantly try the next match</p>
        </div>
        <p style="font-size:11px;color:var(--text-muted);margin-bottom:16px">🔔 We'll notify you immediately when they accept.</p>
        <button class="btn btn-outline btn-sm" onclick="cancelBooking('${bookingId}')" style="color:var(--text-muted);border-color:var(--border);font-size:12px;width:100%">Cancel request</button>
      </div>`;
  } else {
    container.innerHTML = `
      <div style="padding:32px 20px 24px;text-align:center">
        <div style="font-size:40px;margin-bottom:16px;animation:servit-pulse 2s infinite">⏳</div>
        <p style="font-size:16px;font-weight:600;margin-bottom:8px">Processing your booking…</p>
        <p style="font-size:13px;color:var(--text-muted)">Please wait a moment</p>
      </div>`;
  }
}

window.keepWaiting = function(bookingId) {
  const container = document.getElementById('waiting-content') || document.querySelector('#screen-waiting .waiting-container');
  const banner = container?.querySelector('#timeout-banner');
  const footer = container?.querySelector('#normal-footer');
  if (banner) banner.style.display = 'none';
  if (footer) { footer.style.display = 'block'; }
  showToast('Still searching — we\'ll notify you the moment a fixer accepts.');
  trackEvent('timeout_keep_waiting', { booking_id: bookingId });
};
window.retrySearch = async function(bookingId) {
  try {
    const result = await apiCall('retry-matching', { booking_id: bookingId });
    const radius = Number(result.radius_km || 0);
    const offers = Number(result.offers_sent || 0);
    showToast(
      offers > 0
        ? `Retry sent to more fixers${radius ? ` (${radius}km radius)` : ''}.`
        : `Still searching${radius ? ` within ${radius}km` : ''}...`,
      offers > 0 ? 'success' : 'info'
    );
    trackEvent('search_manual_retry', { booking_id: bookingId, radius_km: radius, offers_sent: offers });
  } catch (e) {
    showToast(e.message || 'Could not retry search right now.', 'error');
  }
};

window.scheduleInstead = function(bookingId) {
  const s = document.createElement('div');
  s.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end';
  s.innerHTML = `<div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:28px 20px 44px;animation:slideUp .28s ease">
    <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;margin-bottom:8px">Schedule for later</p>
    <p style="font-size:13px;color:var(--text-muted);line-height:1.7;margin-bottom:20px">Keep your booking and let us retry closer to when more fixers are usually online.</p>
    <button class="btn btn-primary btn-block" id="_schedule-2h-btn">In 2 hours</button>
    <button class="btn btn-outline btn-block" id="_schedule-tomorrow-btn" style="margin-top:8px">Tomorrow 8:00 AM</button>
    <button class="btn btn-outline btn-block" onclick="this.closest('div').parentElement.remove();cancelBooking('${bookingId}')" style="margin-top:8px;color:var(--text-muted);border-color:var(--border)">Cancel booking</button>
  </div>`;
  document.body.appendChild(s);
  s.addEventListener('click', e => { if (e.target === s) s.remove(); });
  const schedule = async (when) => {
    try {
      await apiCall('schedule-booking', { booking_id: bookingId, schedule_for: when });
      s.remove();
      showToast('Booking scheduled. We will resume matching automatically.', 'success');
      trackEvent('booking_scheduled_after_timeout', { booking_id: bookingId });
      showHomeScreen();
    } catch (err) {
      showToast(err.message || 'Could not schedule booking', 'error');
    }
  };
  const plus2h = new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString();
  const tomorrow8 = (() => {
    const d = new Date();
    d.setDate(d.getDate() + 1);
    d.setHours(8, 0, 0, 0);
    return d.toISOString();
  })();
  const b2 = s.querySelector('#_schedule-2h-btn');
  const bT = s.querySelector('#_schedule-tomorrow-btn');
  if (b2) b2.onclick = () => schedule(plus2h);
  if (bT) bT.onclick = () => schedule(tomorrow8);
  trackEvent('timeout_schedule_instead', { booking_id: bookingId });
};

// FIX (Audit F4): Replaced direct update-job-status call with cancel-booking.
// The old route cancelled the booking but never triggered a Yoco refund for
// pre-match cancellations (when fixer_id IS NULL and payment was already collected).
// The new cancel-booking Netlify function cancels AND refunds when eligible.
async function cancelBooking(bookingId, refAmount) {
  // Show a styled confirmation bottom-sheet instead of browser confirm()
  await new Promise((resolve) => {
    const sheet = document.createElement('div');
    sheet.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end;animation:fadeIn .2s ease';
    const refLine = refAmount
      ? `<p style="font-size:12px;color:var(--text-muted);margin-top:4px">Refund of <strong style="color:var(--forest)">${formatZAR(refAmount)}</strong> will be returned to your card.</p>`
      : '';
    sheet.innerHTML = `
      <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:28px 20px 44px;animation:slideUp .28s cubic-bezier(.25,.46,.45,.94)">
        <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;color:var(--text-dark);margin-bottom:8px">Cancel this booking?</p>
        <p style="font-size:13px;color:var(--text-muted);line-height:1.7;margin-bottom:8px">If no fixer has been assigned yet, you'll receive a full refund.</p>
        ${refLine}
        <div style="display:flex;gap:10px;margin-top:20px">
          <button id="_cancel-keep-btn" class="btn btn-primary" style="flex:1">Keep it 🔒</button>
          <button id="_cancel-confirm-btn" class="btn" style="flex:1;background:transparent;border:1.5px solid var(--danger);color:var(--danger)">Cancel booking</button>
        </div>
      </div>`;
    document.body.appendChild(sheet);
    sheet.addEventListener('click', e => { if (e.target === sheet) { sheet.remove(); resolve(false); } });
    document.getElementById('_cancel-keep-btn').onclick = () => { sheet.remove(); resolve(false); };
    document.getElementById('_cancel-confirm-btn').onclick = () => { sheet.remove(); resolve(true); };
  }).then(async (confirmed) => {
    if (!confirmed) return;
    try {
      const result = await apiCall('cancel-booking', { booking_id: bookingId });
      teardownBookingSubscription();
      if (result && result.refunded) {
        showToast('Booking cancelled. Your payment will be refunded shortly.');
      } else if (result && result.refund_error) {
        showToast('Booking cancelled. ' + result.refund_error, 'error');
      } else {
        showToast('Booking cancelled.');
      }
      showHomeScreen();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });
}

// ─────────────────── Offer screen (fixer) ───────────────────────

function showOfferScreen(bookingId, offerId) {
  currentOfferBookingId = bookingId;
  currentOfferOfferId = offerId;  // FIX: store offer.id
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-offer').classList.add('active');
  loadOfferDetails(bookingId, offerId);
}

async function loadOfferDetails(bookingId, offerId) {
  // v8.3 fix: guard against undefined IDs that produce id=eq.undefined 400s
  if (!bookingId || !offerId) { console.warn("[Servit] loadOfferDetails called with undefined id"); return; }
  const { data: booking } = await supabaseClient
    .from('bookings')
    .select('*, fixers!fixer_id(full_name, rating, category, price, price_type, is_verified, badge_top_fixer, badge_fast_responder, avg_response_time, total_completed, completion_rate)')
    .eq('id', bookingId)
    .maybeSingle();

  if (!booking) return;

  const container = document.getElementById('offer-content');
  if (!container) return;

  const secsTotal  = Math.max(1, Math.ceil((new Date(booking.offer_expires_at) - Date.now()) / 1000));
  const amount     = booking.customer_total || booking.amount || 0;
  const commission = booking.commission || Math.max(amount * 0.12, 15);
  const earnings   = Math.round(amount - commission);
  const tier       = booking.service_tier || 'standard';
  const tierIcon   = tier === 'premium' ? '⭐' : tier === 'basic' ? '💰' : '⚡';
  const tierColor  = tier === 'premium' ? 'var(--gold-dark)' : tier === 'basic' ? '#4A7C59' : 'var(--forest)';

  container.innerHTML = `
    <!-- Urgency header -->
    <div style="background:linear-gradient(135deg,#1A3A2A,#2D5A3D);padding:16px 20px 20px;position:relative;overflow:hidden">
      <div style="position:absolute;top:-20px;right:-20px;width:100px;height:100px;border-radius:50%;background:radial-gradient(circle,rgba(201,148,58,.2) 0%,transparent 70%)"></div>
      <div style="display:flex;align-items:center;gap:10px;margin-bottom:12px">
        <span style="font-size:28px;animation:servit-pulse 1s infinite">📋</span>
        <div>
          <p style="font-family:'Playfair Display',serif;font-size:17px;font-weight:700;color:#fff">New Job Offer</p>
          <span style="background:rgba(255,255,255,.15);color:rgba(255,255,255,.9);font-size:10px;font-weight:700;padding:2px 8px;border-radius:8px">${tierIcon} ${tier.toUpperCase()}</span>
        </div>
        <div style="margin-left:auto;text-align:right">
          <p style="font-size:22px;font-weight:700;color:var(--gold-light)">+${formatZAR(earnings)}</p>
          <p style="font-size:10px;color:rgba(255,255,255,.55)">your earnings</p>
        </div>
      </div>
      <!-- Countdown bar -->
      <div id="offer-bar-bg" style="height:6px;background:rgba(255,255,255,.2);border-radius:3px;overflow:hidden;margin-bottom:6px">
        <div id="offer-bar" style="height:100%;background:var(--gold);border-radius:3px;width:100%;transition:width .9s linear"></div>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center">
        <p style="font-size:11px;color:rgba(255,255,255,.6)">You have ${secsTotal}s to accept</p>
        <p id="offer-timer-text" style="font-size:20px;font-weight:700;color:#fff;font-variant-numeric:tabular-nums">${secsTotal}s</p>
      </div>
    </div>

    <div style="padding:16px">
      <!-- Job details -->
      <div style="background:var(--cream);border:1px solid var(--border);border-radius:var(--r-lg);padding:14px;margin-bottom:14px">
        <p style="font-weight:700;font-size:15px;margin-bottom:6px">${escapeHtml(booking.description || 'Service request')}</p>
        <p style="font-size:12px;color:var(--text-muted);margin-bottom:3px">📍 ${escapeHtml(booking.address)}</p>
        <p style="font-size:12px;color:var(--text-muted);margin-bottom:3px">🔧 ${escapeHtml(booking.category || 'General')}</p>
        <p style="font-size:12px;color:var(--text-muted)">⏰ ${booking.booking_mode === 'scheduled' ? 'Scheduled: ' + new Date(booking.scheduled_for).toLocaleString('en-ZA',{weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}) : 'ASAP'}</p>
      </div>

      <!-- Earnings breakdown -->
      <div style="background:var(--warm-white);border:1px solid var(--border);border-radius:var(--r-lg);padding:12px 14px;margin-bottom:16px">
        <p style="font-size:10px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.6px;margin-bottom:10px">Earnings Breakdown</p>
        <div style="display:flex;justify-content:space-between;font-size:12px;margin-bottom:5px">
          <span style="color:var(--text-muted)">Job value</span>
          <span style="font-weight:600">${formatZAR(amount)}</span>
        </div>
        <div style="display:flex;justify-content:space-between;font-size:12px;margin-bottom:8px">
          <span style="color:var(--text-muted)">Service fee</span>
          <span style="font-weight:600;color:var(--danger)">−${formatZAR(commission)}</span>
        </div>
        <div style="border-top:1px solid var(--border);padding-top:8px;display:flex;justify-content:space-between">
          <span style="font-size:14px;font-weight:700">You earn</span>
          <span style="font-size:16px;font-weight:700;color:var(--forest)">${formatZAR(earnings)}</span>
        </div>
      </div>

      <!-- One-tap accept (big) -->
      <button id="accept-offer-btn" class="btn btn-primary btn-block"
        style="padding:16px;font-size:16px;font-weight:700;letter-spacing:.3px;box-shadow:0 4px 20px rgba(26,58,42,.25)"
        onclick="acceptOffer()">
        ✓ Accept Job — ${formatZAR(earnings)}
      </button>
      <p style="font-size:10px;text-align:center;color:var(--gold-dark);font-weight:600;margin:8px 0 2px;animation:servit-pulse 2s infinite">👀 Other fixers are also seeing this job</p>
      <button class="btn btn-block" onclick="declineOffer()"
        style="margin-top:6px;padding:12px;font-size:14px;color:var(--text-muted);background:transparent;border:1.5px solid var(--border)">
        Decline
      </button>
      <p style="font-size:10px;text-align:center;color:var(--text-muted);margin-top:8px">
        Declining too often may reduce your job offers
      </p>
    </div>
  `;

  startOfferCountdown(booking.offer_expires_at, bookingId, offerId);
}

// FIX 1: Track the active offer countdown so it can be cleared on navigation.
// Previously the interval was local to the function and leaked indefinitely —
// if the fixer navigated away (screen lock, dashboard tap), the interval kept
// running and called showFixerDashboard() at expiry even on unrelated screens.
let _offerCountdownInterval = null;

function clearOfferCountdown() {
  if (_offerCountdownInterval) {
    clearInterval(_offerCountdownInterval);
    _offerCountdownInterval = null;
  }
}

function startOfferCountdown(expiresAt, bookingId, offerId) {
  clearOfferCountdown(); // cancel any pre-existing countdown first

  // FIX 7: Guard against null/past expiry — if expiresAt is missing or already
  // past, totalMs would be ≤ 0, making pct = Infinity/NaN and breaking the bar.
  const expiryTime = expiresAt ? new Date(expiresAt) : null;
  const totalMs = expiryTime ? Math.max(1, expiryTime - Date.now()) : 45000;

  _offerCountdownInterval = setInterval(() => {
    // FIX 1: Stop immediately if the offer screen is no longer visible.
    // This prevents showFixerDashboard() from firing on unrelated screens.
    if (!document.getElementById('screen-offer')?.classList.contains('active')) {
      clearOfferCountdown();
      return;
    }

    const remaining = expiryTime ? Math.max(0, expiryTime - Date.now()) : 0;
    const secs = Math.ceil(remaining / 1000);
    const pct  = Math.min(100, Math.max(0, (remaining / totalMs) * 100));

    const timerEl = document.getElementById('offer-timer-text');
    const barEl   = document.getElementById('offer-bar');
    const btnEl   = document.getElementById('accept-offer-btn');

    if (timerEl) timerEl.textContent = `${secs}s`;
    if (barEl)   barEl.style.width   = `${pct}%`;

    // Turn red in last 10 seconds
    if (secs <= 10) {
      if (barEl)   barEl.style.background   = 'var(--danger)';
      if (timerEl) timerEl.style.color      = '#ff6b6b';
      if (btnEl)   btnEl.style.animation    = 'servit-pulse 0.6s infinite';
    }

    if (secs <= 0) {
      clearOfferCountdown();
      showToast('Offer expired — the job went to another fixer', 'error');
      showFixerDashboard();
    }
  }, 1000);
}

// FIX: now passes offer_id (not booking_id) to the backend
let _acceptOfferInFlight = false; // FIX 2: guard against double-tap
async function acceptOffer() {
  const offerId = currentOfferOfferId;
  if (!offerId) { showToast('No active offer', 'error'); return; }
  // FIX 2: Prevent double-tap — disable the button and block concurrent calls
  if (_acceptOfferInFlight) return;
  _acceptOfferInFlight = true;
  const btn = document.getElementById('accept-offer-btn');
  if (btn) { btn.disabled = true; btn.textContent = 'Accepting…'; }

  try {
    showToast('Accepting offer...', 'info');
    // FIX: { offer_id } — the Netlify function and DB both expect the offers.id UUID
    const result = await apiCall('accept-offer', { offer_id: offerId });
    if (result.success) {
      showToast('✅ Job accepted!', 'success');
      trackEvent('fixer_accepted_job', { offer_id: offerId });
      currentOfferOfferId = null;
      clearOfferCountdown(); // FIX 1: stop the countdown now that offer is accepted
      loadActiveJob(result.booking_id);
    }
  } catch (err) {
    showToast(err.message, 'error');
    // Re-enable on failure so fixer can retry
    if (btn) { btn.disabled = false; btn.textContent = `✓ Accept Job`; }
  } finally {
    _acceptOfferInFlight = false;
  }
}

// FIX: now passes offer_id (not booking_id) to the backend
async function declineOffer() {
  const offerId = currentOfferOfferId;
  if (!offerId) { showToast('No active offer', 'error'); return; }

  // FIX (Audit M14): Capture decline reason — gives supply-side insight for matching improvement
  const reason = await new Promise(resolve => {
    const s = document.createElement('div');
    s.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end';
    s.innerHTML = `<div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:24px 20px 44px;animation:slideUp .28s ease">
      <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;margin-bottom:6px">Why are you declining?</p>
      <p style="font-size:12px;color:var(--text-muted);margin-bottom:16px">Takes 1 tap — helps us send you better offers</p>
      ${[
        ['too_far',       '📍', 'Too far away'],
        ['price_low',     '💰', 'Price too low'],
        ['not_available', '🕒', 'Not available right now'],
        ['wrong_category','🔧', 'Not my type of work'],
      ].map(([val, em, lbl]) => `
        <button class="_dec-reason-btn" data-reason="${val}" style="width:100%;display:flex;align-items:center;gap:12px;padding:12px 14px;background:var(--cream);border:1.5px solid var(--border);border-radius:var(--r-md);margin-bottom:8px;font-family:'DM Sans',sans-serif;font-size:14px;font-weight:500;color:var(--text-dark);cursor:pointer;text-align:left;transition:all .15s">
          <span style="font-size:20px">${em}</span>${lbl}
        </button>`).join('')}
      <button id="_dec-skip" style="width:100%;background:transparent;border:none;font-size:13px;color:var(--text-muted);padding:8px;cursor:pointer;font-family:'DM Sans',sans-serif">Skip</button>
    </div>`;
    document.body.appendChild(s);
    s.querySelectorAll('._dec-reason-btn').forEach(btn => {
      btn.onclick = () => { s.remove(); resolve(btn.dataset.reason); };
    });
    s.querySelector('#_dec-skip').onclick = () => { s.remove(); resolve(null); };
    s.addEventListener('click', e => { if (e.target === s) { s.remove(); resolve(null); } });
  });

  if (reason === undefined) return; // user dismissed without choosing

  try {
    const result = await apiCall('decline-offer', { offer_id: offerId, decline_reason: reason });
    if (result.success) {
      showToast('Offer declined — next one is coming', 'info');
      currentOfferOfferId = null;
      clearOfferCountdown(); // FIX 1: stop countdown on decline
      showFixerDashboard();
    }
  } catch (err) {
    showToast(err.message, 'error');
  }
}

// ─────────────────── Job screen ─────────────────────────────────

async function loadActiveJob(bookingId) {
  // v8.3 fix: guard against undefined bookingId
  if (!bookingId) { console.warn("[Servit] loadActiveJob called with undefined bookingId"); return; }

  // BUG 5 FIX: Tear down any existing subscription BEFORE fetching and re-subscribing.
  // Previously, rapid status changes would call loadActiveJob() multiple times in quick
  // succession. Each call called subscribeToBookingStatus() which replaced bookingChannel,
  // but the old Supabase realtime channel may still fire callbacks during the brief window
  // between calls. Tearing down first eliminates that window.
  teardownBookingSubscription();
  // FIX: join fixers, not pro_profiles
  const { data: booking } = await supabaseClient
    .from('bookings')
    .select('*, fixers!fixer_id(*)')
    .eq('id', bookingId)
    .maybeSingle();

  if (!booking) return;

  currentBookingId = bookingId;
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-job').classList.add('active');
  renderJobScreen(booking);
  // FIX 4b: Don't re-subscribe for terminal statuses — no further updates expected.
  // FIX 8: Re-fetch the full booking row on each update rather than merging with
  // the stale `booking` snapshot from the initial load. The closure over `booking`
  // meant fields like `fixers` were carried forward from the original fetch even
  // if the DB row had changed (e.g. fixer details updated after assignment).
  const terminalStatuses = ['COMPLETED', 'CANCELLED', 'EXPIRED', 'DISPUTED'];
  if (!terminalStatuses.includes(booking.status)) {
    subscribeToBookingStatus(bookingId, async (updatedBooking) => {
      // Re-fetch fresh data so fixer join and all fields are current
      const { data: freshBooking } = await supabaseClient
        .from('bookings')
        .select('*, fixers!fixer_id(*)')
        .eq('id', bookingId)
        .maybeSingle();
      renderJobScreen(freshBooking || { ...booking, ...updatedBooking });
    });
  }
}

function renderJobScreen(booking) {
  const fixer = booking.fixers || {};
  const isFixerView = !!currentFixerProfile;

  // Clean up any existing map instance before re-rendering
  if (window.destroyServitMap) window.destroyServitMap();

  const statusDisplay = {
    'CONFIRMED': 'Confirmed', 'EN_ROUTE': 'En Route',
    'ARRIVED': 'Arrived', 'IN_PROGRESS': 'In Progress',
    'PENDING_COMPLETION': 'Awaiting Confirmation',
    'COMPLETED': 'Completed', 'CANCELLED': 'Cancelled',
  };

  const statusActions = {
    'CONFIRMED':   isFixerView ? `<button class="btn btn-primary" onclick="updateJobStatus('${booking.id}', 'EN_ROUTE')">Start En Route →</button>` : '',
    'EN_ROUTE':    isFixerView ? `<button class="btn btn-primary" onclick="updateJobStatus('${booking.id}', 'ARRIVED')">Mark Arrived</button>` : '',
    'ARRIVED':     isFixerView ? `<button class="btn btn-primary" onclick="updateJobStatus('${booking.id}', 'IN_PROGRESS')">Start Job</button>` : '',
    'IN_PROGRESS': isFixerView ? `<button class="btn btn-primary" onclick="updateJobStatus('${booking.id}', 'PENDING_COMPLETION')">Mark Complete</button>` : '',
    'PENDING_COMPLETION': !isFixerView
      ? `<button class="btn btn-primary" onclick="updateJobStatus('${booking.id}', 'COMPLETED')">Confirm Complete ✓</button>`
      : `<div style="background:var(--cream);border:1.5px solid var(--border);border-radius:var(--r-md);padding:12px 14px;text-align:center">
           <p style="font-size:13px;font-weight:600;color:var(--text-dark);margin-bottom:4px">⏳ Waiting for customer to confirm</p>
           <p style="font-size:12px;color:var(--text-muted);line-height:1.6">They've been notified. If they don't respond, the job auto-confirms and your payment is released within <strong>24 hours</strong>.</p>
         </div>`,
    'COMPLETED': '',
    'CANCELLED': '',
  };

  // Show map when pro is moving (customer view) or pro is confirmed (pro view)
  const showMap = ['CONFIRMED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS'].includes(booking.status);

  const container = document.getElementById('job-content');
  if (!container) return;

  container.innerHTML = `
    <div style="padding: 20px;">
      <div class="status-badge status-${booking.status.toLowerCase()}" style="margin-bottom: 16px;">
        ${statusDisplay[booking.status] || booking.status}
      </div>

      <div class="card" style="margin-bottom: 16px;">
        <h4>${escapeHtml(booking.description || 'Service')}</h4>
        <p style="font-size: 13px; color: var(--text-muted);">📍 ${escapeHtml(booking.address)}</p>
        <p style="font-size: 13px; font-weight: 600; color: var(--forest); margin-top: 8px;">
          💰 ${formatZAR(booking.customer_total || booking.amount_paid || booking.amount)}
        </p>
      </div>

      ${fixer.full_name ? `
        <div class="card" style="margin-bottom:16px;padding:14px">
          <div style="display:flex;align-items:center;gap:12px">
            <div style="width:48px;height:48px;border-radius:50%;background:var(--forest);display:flex;align-items:center;justify-content:center;font-size:22px;border:2px solid ${fixer.is_verified ? 'var(--gold)' : 'var(--border)'}">
              ${getCategoryEmoji(fixer.category)}
            </div>
            <div style="flex:1;min-width:0">
              <div style="font-weight:700;font-size:14px;margin-bottom:2px;display:flex;align-items:center;gap:6px">
                ${escapeHtml(fixer.full_name)}
                ${fixer.is_verified ? '<span style="background:#E8F5EE;color:#1A5C36;font-size:9px;font-weight:700;padding:1px 6px;border-radius:8px">✓ Verified</span>' : ''}
              </div>
              <div style="font-size:11px;color:var(--text-muted);margin-bottom:5px">${escapeHtml(fixer.category || '')}</div>
              <div style="display:flex;gap:5px;flex-wrap:wrap">
                ${fixer.rating ? `<span style="background:var(--cream-dark);font-size:10px;font-weight:600;padding:2px 7px;border-radius:8px">⭐ ${Number(fixer.rating).toFixed(1)}</span>` : ''}
                ${fixer.total_completed > 0 ? `<span style="background:var(--cream-dark);font-size:10px;font-weight:600;padding:2px 7px;border-radius:8px">📋 ${fixer.total_completed} jobs</span>` : ''}
                ${fixer.completion_rate >= 90 ? `<span style="background:var(--cream-dark);font-size:10px;font-weight:600;padding:2px 7px;border-radius:8px">✓ ${Math.round(fixer.completion_rate)}%</span>` : ''}
                ${fixer.badge_top_fixer    ? '<span style="background:#FDF3E0;color:#8B5E15;font-size:9px;font-weight:700;padding:2px 7px;border-radius:8px">🏆 Top Fixer</span>' : ''}
                ${fixer.badge_fast_responder ? '<span style="background:#E8F0FA;color:#1A3A6A;font-size:9px;font-weight:700;padding:2px 7px;border-radius:8px">⚡ Fast</span>' : ''}
              </div>
            </div>
            ${fixer.phone ? `<a href="tel:${escapeHtml(fixer.phone)}" class="btn btn-outline btn-sm" style="margin-left:auto;flex-shrink:0">📞 Call</a>` : ''}
          </div>
        </div>
      ` : ''}

      ${showMap ? `
        <div class="card" style="margin-bottom: 16px; padding: 0; overflow: hidden;">
          <div id="map-container" style="width: 100%; height: 240px; background: #e8e0d4;"></div>
          <div id="map-eta" style="padding: 10px 14px; font-size: 13px; font-weight: 600; color: var(--forest); border-top: 1px solid var(--border); min-height: 38px;">
            ${isFixerView ? '📍 Your live position' : '🔍 Loading position...'}
          </div>
          <p id="map-message" style="padding: 0 14px 10px; font-size: 12px; color: var(--text-muted); min-height: 0;"></p>
        </div>
      ` : ''}

      <div style="display: flex; flex-direction: column; gap: 8px;">
        ${statusActions[booking.status] || ''}
        ${['CONFIRMED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS'].includes(booking.status) ? `
          <button class="btn btn-outline btn-sm" onclick="window.raiseDispute('${booking.id}')">⚠️ Raise Dispute</button>
        ` : ''}
      </div>
    </div>
  `;

  // Initialise map after DOM is ready
  if (showMap && window.initServitMap) {
    // Small timeout lets the browser paint the container before Leaflet measures it
    setTimeout(() => window.initServitMap(booking, isFixerView), 50);
  }
}

// ─────────────────── Job status updates ─────────────────────────

async function updateJobStatus(bookingId, newStatus) {
  // Replace browser confirm() with styled bottom-sheet confirmations
  if (newStatus === 'CANCELLED') {
    const ok = await new Promise(resolve => {
      const s = document.createElement('div');
      s.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end';
      s.innerHTML = `<div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:28px 20px 44px;animation:slideUp .28s ease">
        <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;margin-bottom:8px">Cancel this job?</p>
        <p style="font-size:13px;color:var(--text-muted);line-height:1.7;margin-bottom:20px">This cannot be undone. Repeated cancellations affect your rating.</p>
        <div style="display:flex;gap:10px">
          <button id="_uj-keep" class="btn btn-primary" style="flex:1">Keep job</button>
          <button id="_uj-cancel" class="btn" style="flex:1;background:transparent;border:1.5px solid var(--danger);color:var(--danger)">Cancel job</button>
        </div></div>`;
      document.body.appendChild(s);
      s.addEventListener('click', e => { if (e.target === s) { s.remove(); resolve(false); } });
      s.querySelector('#_uj-keep').onclick = () => { s.remove(); resolve(false); };
      s.querySelector('#_uj-cancel').onclick = () => { s.remove(); resolve(true); };
    });
    if (!ok) return false;
  }
  if (newStatus === 'COMPLETED') {
    const ok = await new Promise(resolve => {
      const s = document.createElement('div');
      s.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end';
      s.innerHTML = `<div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:28px 20px 44px;animation:slideUp .28s ease">
        <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;margin-bottom:8px">Mark job complete?</p>
        <p style="font-size:13px;color:var(--text-muted);line-height:1.7;margin-bottom:20px">This confirms the job is done and releases payment to the fixer.</p>
        <div style="display:flex;gap:10px">
          <button id="_uj-notdone" class="btn btn-outline" style="flex:1">Not done yet</button>
          <button id="_uj-done" class="btn btn-primary" style="flex:1">Confirm complete ✓</button>
        </div></div>`;
      document.body.appendChild(s);
      s.addEventListener('click', e => { if (e.target === s) { s.remove(); resolve(false); } });
      s.querySelector('#_uj-notdone').onclick = () => { s.remove(); resolve(false); };
      s.querySelector('#_uj-done').onclick = () => { s.remove(); resolve(true); };
    });
    if (!ok) return false;
  }

  try {
    const result = await apiCall('update-job-status', { booking_id: bookingId, status: newStatus });
    if (result.success) {
      const messages = {
        'EN_ROUTE': '🚗 Marked as en route', 'ARRIVED': '📍 Marked as arrived',
        'IN_PROGRESS': '⚙️ Job started', 'PENDING_COMPLETION': '🎉 Job complete! Waiting for customer.',
        'COMPLETED': '✅ Job completed! Thank you.', 'CANCELLED': '❌ Booking cancelled',
      };
      showToast(messages[newStatus] || `Status: ${newStatus}`, 'success');
      await loadActiveJob(bookingId);
      // FIX H-03: Proactively prompt customer to rate after confirming completion.
      // Previously rating was buried in Bookings → History; this drives near-zero ratings at launch.
      if (newStatus === 'COMPLETED' && !currentFixerProfile) {
        // Look up the fixer id from the booking for the rating modal
        const { data: bk } = await supabaseClient
          .from('bookings')
          .select('fixer_id, fixers!fixer_id(full_name)')
          .eq('id', bookingId)
          .maybeSingle();
        const fixerName = bk?.fixers?.full_name || 'Your fixer';
        const fixerId   = bk?.fixer_id;
        if (fixerId) {
          setTimeout(() => openRatingModal(bookingId, fixerId, fixerName), 800);
        }
      }
      return true;
    }
    return false;
  } catch (err) {
    showToast(err.message, 'error');
    return false;
  }
}

// ─────────────────── Availability toggle ────────────────────────

// FIX (Audit F1): Replaced direct supabaseClient.from('fixers').update({ available })
// call with a secure API call. The old code bypassed all security — any authenticated
// user could flip any fixer's available flag, and a fixer could go online mid-job.
// Now routes through /api/toggle-availability (Netlify function) which:
//   • Authenticates the caller
//   • Verifies they own the fixer row (user_id check)
//   • Calls toggle_fixer_availability() DB function (active-job guard + atomic flip)
async function toggleAvailability() {
  if (!currentFixerProfile) return;

  // Optimistic UI update immediately so the toggle feels responsive
  const newAvailable = !currentFixerProfile.available;
  const toggle = document.getElementById('availability-toggle');
  const lbl = document.getElementById('fixer-avail-label');
  if (toggle) toggle.classList.toggle('on', newAvailable);
  if (lbl) { lbl.textContent = newAvailable ? 'ONLINE' : 'OFFLINE'; lbl.style.color = newAvailable ? 'rgba(74,222,128,.9)' : 'rgba(255,255,255,.6)'; }

  try {
    // Try the Netlify function first (production path)
    const result = await apiCall('toggle-availability', {});
    if (result && result.success) {
      currentFixerProfile.available = result.available;
      // Sync UI to confirmed server state (may differ from optimistic)
      if (toggle) toggle.classList.toggle('on', result.available);
      if (lbl) { lbl.textContent = result.available ? 'ONLINE' : 'OFFLINE'; lbl.style.color = result.available ? 'rgba(74,222,128,.9)' : 'rgba(255,255,255,.6)'; }
      showToast(result.available ? "🟢 Now online — you'll receive job offers" : '⚫ Now offline', result.available ? 'success' : '');
      loadFixerDashboard();
      return;
    }
    // Function returned 200 but no success flag — revert optimistic UI and bail
    if (toggle) toggle.classList.toggle('on', !newAvailable);
    if (lbl) { lbl.textContent = !newAvailable ? 'ONLINE' : 'OFFLINE'; lbl.style.color = !newAvailable ? 'rgba(74,222,128,.9)' : 'rgba(255,255,255,.6)'; }
    return;
  } catch (netlifyErr) {
    // If the function returned a real error (e.g. "Cannot go online while a job is active"),
    // surface it to the fixer and revert the optimistic UI — do NOT fall through to direct DB write.
    if (netlifyErr.message && !netlifyErr.message.includes('Failed to fetch')) {
      if (toggle) toggle.classList.toggle('on', !newAvailable);
      if (lbl) { lbl.textContent = !newAvailable ? 'ONLINE' : 'OFFLINE'; lbl.style.color = !newAvailable ? 'rgba(74,222,128,.9)' : 'rgba(255,255,255,.6)'; }
      showToast(netlifyErr.message, 'error');
      return;
    }
    // Network error — revert optimistic UI, inform user
    if (toggle) toggle.classList.toggle('on', !newAvailable);
    if (lbl) { lbl.textContent = !newAvailable ? 'ONLINE' : 'OFFLINE'; lbl.style.color = !newAvailable ? 'rgba(74,222,128,.9)' : 'rgba(255,255,255,.6)'; }
    showToast('Could not update availability — check your connection', 'error');
  }
}

// ─────────────────── Fixer dashboard ────────────────────────────

async function loadFixerDashboard() {
  if (!currentFixerProfile) return;

  // Update header
  const nameEl = document.getElementById('fixer-name-label');
  const avatarEl = document.getElementById('fixer-hero-avatar');
  const ratingEl = document.getElementById('fixer-rating-label');
  const jobsEl   = document.getElementById('fixer-jobs-count');
  const availLbl = document.getElementById('fixer-avail-label');
  const fp = currentFixerProfile;

  if (nameEl) nameEl.textContent = fp.full_name?.split(' ')[0] || 'Fixer';
  if (ratingEl) ratingEl.textContent = fp.rating ? fp.rating.toFixed(1) + ' ⭐' : 'New';
  if (availLbl) { availLbl.textContent = fp.available ? 'ONLINE' : 'OFFLINE'; availLbl.style.color = fp.available ? 'rgba(74,222,128,.9)' : 'rgba(255,255,255,.6)'; }
  if (avatarEl) {
    const initial = (fp.full_name || '?')[0].toUpperCase();
    avatarEl.textContent = fp.photo_url ? '' : initial;
    if (fp.photo_url) avatarEl.innerHTML = `<img src="${escapeHtml(fp.photo_url)}" style="width:100%;height:100%;border-radius:50%;object-fit:cover">`;
  }

  // Switch bottom nav to fixer mode
  _applyFixerNav();

  // Pending offers
  const { data: pendingOffers } = await supabaseClient
    .from('offers')
    .select('*, bookings!booking_id(id, description, address, customer_total, amount, offer_expires_at, customer_id)')
    .eq('fixer_id', fp.id)
    .eq('status', 'pending')
    .gt('expires_at', new Date().toISOString());

  const offersContainer = document.getElementById('pending-offers');
  const offerBadge = document.getElementById('offers-count-badge');

  if (offerBadge) {
    if (pendingOffers?.length) { offerBadge.style.display = ''; offerBadge.textContent = pendingOffers.length; }
    else offerBadge.style.display = 'none';
  }

  if (offersContainer) {
    if (!pendingOffers || pendingOffers.length === 0) {
      offersContainer.innerHTML = `
        <div style="text-align:center;padding:20px 16px;background:var(--card-bg);border:1px dashed var(--border);border-radius:var(--r-lg)">
          <p style="font-size:22px;margin-bottom:8px;opacity:.4">📭</p>
          <p style="font-size:13px;color:var(--text-muted)">No pending offers right now</p>
          <p style="font-size:11px;color:var(--text-muted);margin-top:4px">Go online to start receiving jobs</p>
        </div>`;
    } else {
      offersContainer.innerHTML = pendingOffers.map(offer => {
        const booking = offer.bookings || {};
        const secsLeft = Math.max(0, Math.floor((new Date(offer.expires_at) - Date.now()) / 1000));
        const pct = Math.round((secsLeft / 60) * 100);
        return `
          <div style="background:var(--card-bg);border:1.5px solid var(--gold);border-radius:var(--r-lg);padding:14px 16px;margin-bottom:10px;box-shadow:0 2px 12px rgba(201,148,58,.15)">
            <div style="display:flex;align-items:center;gap:8px;margin-bottom:10px">
              <span style="font-size:22px">📋</span>
              <div style="flex:1">
                <p style="font-weight:700;font-size:14px;margin-bottom:2px">${escapeHtml(booking.description || 'New request')}</p>
                <p style="font-size:12px;color:var(--text-muted)">📍 ${escapeHtml(booking.address || '—')}</p>
              </div>
              <div style="text-align:right;flex-shrink:0">
                <p style="font-weight:700;color:var(--forest);font-size:16px">${formatZAR(booking.customer_total || booking.amount || 0)}</p>
                <p style="font-size:10px;color:var(--gold-dark);font-weight:600">⏱ ${secsLeft}s left</p>
              </div>
            </div>
            <div style="height:4px;background:var(--border);border-radius:2px;margin-bottom:12px;overflow:hidden">
              <div style="height:100%;background:${secsLeft < 20 ? 'var(--danger)' : 'var(--gold)'};border-radius:2px;width:${pct}%;transition:width 1s"></div>
            </div>
            <div style="display:flex;gap:8px">
              <button class="btn btn-outline btn-sm" style="flex:1;font-size:13px;color:var(--danger);border-color:var(--danger)" onclick="currentOfferOfferId='${offer.id}';declineOffer()">✕ Decline</button>
              <button class="btn btn-primary btn-sm" style="flex:2;font-size:13px;padding:10px" onclick="showOfferScreen('${booking.id}','${offer.id}')">✓ Accept Job →</button>
            </div>
          </div>`;
      }).join('');
    }
  }

  // Active jobs
  const { data: activeJobs } = await supabaseClient
    .from('bookings')
    .select('*')
    .eq('fixer_id', fp.id)
    .in('status', ['CONFIRMED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS', 'PENDING_COMPLETION']);

  const jobsContainer = document.getElementById('fixer-active-jobs');
  if (jobsContainer) {
    if (!activeJobs || activeJobs.length === 0) {
      jobsContainer.innerHTML = `
        <div style="text-align:center;padding:20px 16px;background:var(--card-bg);border:1px dashed var(--border);border-radius:var(--r-lg)">
          <p style="font-size:22px;margin-bottom:8px;opacity:.4">🔧</p>
          <p style="font-size:13px;color:var(--text-muted)">No active jobs</p>
        </div>`;
    } else {
      const statusLbl = { CONFIRMED:'Confirmed ✓', EN_ROUTE:'En route 🚗', ARRIVED:'Arrived 📍', IN_PROGRESS:'In progress ⚡', PENDING_COMPLETION:'Awaiting customer ⏳' };
      const nextAction = { CONFIRMED:'Start driving →', EN_ROUTE:'Mark arrived →', ARRIVED:'Start job →', IN_PROGRESS:'Mark complete →', PENDING_COMPLETION:'Waiting for customer…' };
      const nextStatus = { CONFIRMED:'EN_ROUTE', EN_ROUTE:'ARRIVED', ARRIVED:'IN_PROGRESS', IN_PROGRESS:'PENDING_COMPLETION' };
      jobsContainer.innerHTML = activeJobs.map(job => `
        <div style="background:var(--card-bg);border:1px solid var(--border);border-radius:var(--r-lg);padding:14px 16px;margin-bottom:10px;cursor:pointer" onclick="loadActiveJob('${job.id}')">
          <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
            <span style="background:#E8F5EE;color:#2D7A4F;font-size:10px;font-weight:700;padding:3px 10px;border-radius:20px">${statusLbl[job.status] || job.status}</span>
            <span style="font-weight:700;color:var(--forest);font-size:14px">${formatZAR(job.customer_total || job.amount || 0)}</span>
          </div>
          <p style="font-weight:600;font-size:14px;margin-bottom:4px">${escapeHtml(job.description || 'Service')}</p>
          <p style="font-size:12px;color:var(--text-muted);margin-bottom:10px">📍 ${escapeHtml(job.address || '—')}</p>
          <div style="display:flex;gap:7px">
            ${nextStatus[job.status] ? `<button class="btn btn-primary btn-sm" style="flex:2;font-size:12px" onclick="event.stopPropagation();updateJobStatus('${job.id}','${nextStatus[job.status]}')">${nextAction[job.status]}</button>` : `<p style="font-size:12px;color:var(--text-muted);padding:6px 0">${nextAction[job.status]}</p>`}
            <button class="btn btn-outline btn-sm" style="flex:1;font-size:12px" onclick="event.stopPropagation();openChat('${job.customer_id || ''}','Customer','${job.id}')">💬 Chat</button>
          </div>
        </div>`).join('');
    }
  }

  // Earnings — Wire 4: use fixer_payout (net of Servit commission) where
  // available (v8.2+ rows), fall back to amount-commission for older rows.
  const { data: completed } = await supabaseClient
    .from('bookings')
    .select('amount, commission, fixer_payout')
    .eq('fixer_id', fp.id)
    .eq('status', 'COMPLETED');
  const totalEarned = completed?.reduce((sum, b) =>
    sum + (b.fixer_payout != null ? Number(b.fixer_payout) : (b.amount || 0) - (b.commission || 0))
  , 0) || 0;
  const earningsEl = document.getElementById('fixer-earnings');
  if (earningsEl) earningsEl.textContent = formatZAR(totalEarned);
  if (jobsEl) jobsEl.textContent = completed?.length || 0;

  const toggle = document.getElementById('availability-toggle');
  if (toggle) {
    toggle.classList.toggle('on', fp.available);
    toggle.onclick = toggleAvailability;
  }
  // Sync the fixer-avail-label once more in case it wasn't in DOM when first set
  if (availLbl) { availLbl.textContent = fp.available ? 'ONLINE' : 'OFFLINE'; availLbl.style.color = fp.available ? 'rgba(74,222,128,.9)' : 'rgba(255,255,255,.6)'; }
}

// Apply fixer-specific bottom nav labels
function _applyFixerNav() {
  const nav = document.querySelector('.bottom-nav');
  if (!nav || nav.dataset.fixerNav === '1') return;
  nav.dataset.fixerNav = '1';
  // Change "Bookings" label to "My Jobs" and "Home" to "Dashboard"
  const homeItem = document.getElementById('nav-home');
  if (homeItem) {
    const lbl = homeItem.querySelector('.nav-label');
    if (lbl) lbl.textContent = 'Dashboard';
    const icon = homeItem.querySelector('.nav-icon');
    if (icon) icon.textContent = '📊';
  }
  const bookingsItem = document.getElementById('nav-bookings');
  if (bookingsItem) {
    const lbl = bookingsItem.querySelector('.nav-label');
    if (lbl) lbl.textContent = 'My Jobs';
    const icon = bookingsItem.querySelector('.nav-icon');
    if (icon) icon.textContent = '🔧';
    bookingsItem.onclick = () => showFixerJobsScreen();
  }
}

async function showFixerJobsScreen() {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-bookings').classList.add('active');
  updateActiveNav('bookings');

  // Replace bookings tabs with fixer tabs
  const tabsEl = document.getElementById('bookings-tabs');
  if (tabsEl) {
    tabsEl.innerHTML = `
      <div class="tab active" data-tab="fixer-active" onclick="loadFixerJobs('fixer-active',this)" style="flex:1;text-align:center">Active</div>
      <div class="tab" data-tab="fixer-done" onclick="loadFixerJobs('fixer-done',this)" style="flex:1;text-align:center">Completed</div>
      <div class="tab" data-tab="fixer-earnings" onclick="loadFixerJobs('fixer-earnings',this)" style="flex:1;text-align:center">Earnings</div>`;
  }
  // Also change topbar
  const topbar = document.querySelector('#screen-bookings .topbar');
  if (topbar) {
    topbar.querySelector('.topbar-logo').innerHTML = 'Ser<span>vit</span> <span style="font-size:14px;font-weight:500;color:var(--text-mid);font-family:\'DM Sans\',sans-serif">· My Jobs</span>';
    const btn = topbar.querySelector('button');
    if (btn) btn.style.display = 'none';
  }
  loadFixerJobs('fixer-active', document.querySelector('#bookings-tabs .tab'));
}

async function loadFixerJobs(tab, tabEl) {
  // Sync tab highlight
  document.querySelectorAll('#bookings-tabs .tab').forEach(t => t.classList.remove('active'));
  if (tabEl) tabEl.classList.add('active');

  const container = document.getElementById('bookings-list');
  if (!container) return;

  if (tab === 'fixer-earnings') {
    await renderFixerEarningsTab(container);
    return;
  }

  const statuses = tab === 'fixer-active'
    ? ['CONFIRMED','EN_ROUTE','ARRIVED','IN_PROGRESS','PENDING_COMPLETION','OFFERED']
    : ['COMPLETED','CANCELLED','DISPUTED','EXPIRED'];

  const { data: jobs } = await supabaseClient
    .from('bookings')
    .select('*, profiles!customer_id(full_name, phone)')
    .eq('fixer_id', currentFixerProfile.id)
    .in('status', statuses)
    .order('created_at', { ascending: false });

  if (!jobs || jobs.length === 0) {
    container.innerHTML = `<div style="text-align:center;padding:56px 20px"><div style="font-size:48px;margin-bottom:16px;opacity:.4">🔧</div><p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;margin-bottom:8px">${tab === 'fixer-active' ? 'No active jobs' : 'No completed jobs yet'}</p><p style="font-size:13px;color:var(--text-muted)">Go online on your dashboard to receive job offers.</p></div>`;
    return;
  }

  const statusLbl = { CONFIRMED:'Confirmed ✓', EN_ROUTE:'En route 🚗', ARRIVED:'Arrived 📍', IN_PROGRESS:'In progress ⚡', PENDING_COMPLETION:'Awaiting approval ⏳', COMPLETED:'Completed ✅', CANCELLED:'Cancelled', DISPUTED:'Disputed ⚠️', OFFERED:'Offer pending' };
  const nextStatus = { CONFIRMED:'EN_ROUTE', EN_ROUTE:'ARRIVED', ARRIVED:'IN_PROGRESS', IN_PROGRESS:'PENDING_COMPLETION' };
  const nextLabel  = { CONFIRMED:'Start driving →', EN_ROUTE:'Mark arrived →', ARRIVED:'Start job →', IN_PROGRESS:'Mark complete →' };

  container.innerHTML = jobs.map(job => {
    const custName = job.profiles?.full_name || 'Customer';
    const custPhone = job.profiles?.phone || '';
    // Wire 5: use fixer_payout (locked net amount) where available, fall back to amount-commission
    const displayEarnings = job.fixer_payout != null
      ? Number(job.fixer_payout)
      : (job.amount || 0) - (job.commission || 0);
    return `
      <div style="background:var(--card-bg);border:1px solid var(--border);border-radius:var(--r-lg);padding:14px 16px;margin-bottom:10px;cursor:pointer" onclick="loadActiveJob('${job.id}')">
        <div style="display:flex;align-items:flex-start;justify-content:space-between;margin-bottom:8px">
          <div style="flex:1;min-width:0">
            <p style="font-weight:700;font-size:14px;margin-bottom:3px">${escapeHtml(job.description || 'Service')}</p>
            <p style="font-size:12px;color:var(--text-muted);margin-bottom:2px">👤 ${escapeHtml(custName)}</p>
            <p style="font-size:12px;color:var(--text-muted)">📍 ${escapeHtml(job.address || '—')}</p>
          </div>
          <div style="text-align:right;flex-shrink:0;margin-left:10px">
            <p style="font-weight:700;color:var(--forest);font-size:15px;margin-bottom:4px">${formatZAR(displayEarnings)}</p>
            <span style="background:#E8F5EE;color:#2D7A4F;font-size:10px;font-weight:700;padding:2px 8px;border-radius:10px">${statusLbl[job.status] || job.status}</span>
          </div>
        </div>
        <div style="border-top:1px solid var(--border);padding-top:8px;display:flex;gap:7px">
          ${nextStatus[job.status] ? `<button class="btn btn-primary btn-sm" style="flex:2;font-size:12px" onclick="event.stopPropagation();updateJobStatus('${job.id}','${nextStatus[job.status]}')">${nextLabel[job.status]}</button>` : ''}
          ${custPhone ? `<button class="btn btn-outline btn-sm" style="flex:1;font-size:12px" data-custphone="${escapeHtml(custPhone)}" onclick="event.stopPropagation();window.open('tel:'+this.dataset.custphone)">📞 Call</button>` : ''}
          <button class="btn btn-outline btn-sm" style="flex:1;font-size:12px" onclick="event.stopPropagation();openChat('${job.customer_id || ''}','${escapeHtml(custName)}','${job.id}')">💬 Chat</button>
        </div>
      </div>`;
  }).join('');
}

async function renderFixerEarningsTab(container) {
  container.innerHTML = `<div style="text-align:center;padding:40px 20px;color:var(--text-muted)">
    <div style="font-size:32px;margin-bottom:12px">⏳</div>
    <p style="font-size:13px">Loading earnings…</p>
  </div>`;

  // Wire 3: use get_fixer_earnings_statement RPC — returns fixer_payout (net of
  // Servit's 12% commission) per job, plus rating/review, plus career total.
  // Falls back to the old direct query if the RPC isn't available (pre-v8.2 DB).
  let jobs = [], total = 0, thisMonth = 0, commissionRatePct = 12, usingRpc = false;

  try {
    const { data: stmt, error } = await supabaseClient
      .rpc('get_fixer_earnings_statement', {
        p_fixer_id: currentFixerProfile.id,
        p_days: 365,
      });

    if (!error && stmt) {
      usingRpc = true;
      jobs = stmt.jobs || [];
      total = Number(stmt.total_all_time || 0);
      thisMonth = jobs
        .filter(j => new Date(j.completed_at).getMonth() === new Date().getMonth()
                  && new Date(j.completed_at).getFullYear() === new Date().getFullYear())
        .reduce((s, j) => s + Number(j.amount_earned || 0), 0);
      commissionRatePct = Number(stmt.commission_rate_pct || 12);
    }
  } catch (_) { /* fall through to legacy query */ }

  if (!usingRpc) {
    // Legacy fallback for pre-v8.2 deployments
    const { data: legacyJobs } = await supabaseClient
      .from('bookings')
      .select('amount, commission, created_at, description, customer_total')
      .eq('fixer_id', currentFixerProfile.id)
      .eq('status', 'COMPLETED')
      .order('created_at', { ascending: false });
    jobs = (legacyJobs || []).map(j => ({
      completed_at:  j.created_at,
      category:      j.description || 'Service',
      service_amount: j.amount,
      platform_fee:  j.commission,
      amount_earned: (j.amount || 0) - (j.commission || 0),
      is_legacy_row: true,
    }));
    total     = jobs.reduce((s, j) => s + j.amount_earned, 0);
    thisMonth = jobs
      .filter(j => new Date(j.completed_at).getMonth() === new Date().getMonth())
      .reduce((s, j) => s + j.amount_earned, 0);
  }

  container.innerHTML = `
    <div style="background:linear-gradient(135deg,var(--forest),var(--forest-mid));border-radius:var(--r-xl);padding:20px;margin-bottom:16px;text-align:center">
      <p style="font-size:11px;color:rgba(255,255,255,.6);font-weight:600;letter-spacing:.5px;text-transform:uppercase;margin-bottom:4px">Total Earned (All Time)</p>
      <p style="font-family:'Playfair Display',serif;font-size:32px;font-weight:700;color:var(--gold-light)">${formatZAR(total)}</p>
      <p style="font-size:12px;color:rgba(255,255,255,.6);margin-top:6px">This month: ${formatZAR(thisMonth)}</p>
    </div>
    <div style="background:var(--card-bg);border:1px solid var(--border);border-radius:var(--r-lg);padding:14px 16px;margin-bottom:12px">
      <p style="font-size:11px;font-weight:700;color:var(--text-muted);letter-spacing:.5px;text-transform:uppercase;margin-bottom:10px">Commission Structure</p>
      <div style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid var(--border)">
        <p style="font-size:13px">Servit commission</p>
        <p style="font-size:13px;font-weight:600;color:var(--danger)">${commissionRatePct}% (min R15)</p>
      </div>
      <div style="display:flex;justify-content:space-between;padding:8px 0">
        <p style="font-size:13px">Payout schedule</p>
        <p style="font-size:13px;font-weight:600;color:var(--success)">Daily</p>
      </div>
    </div>
    <p style="font-size:11px;font-weight:700;color:var(--text-muted);letter-spacing:.5px;text-transform:uppercase;margin-bottom:10px;padding:0 2px">Recent Payouts</p>
    ${jobs.length ? jobs.slice(0, 15).map(j => {
      const earned    = Number(j.amount_earned  || 0);
      const gross     = Number(j.service_amount || 0);
      const platFee   = Number(j.platform_fee   || 0);
      const label     = j.category || j.description || 'Service';
      const dateStr   = j.completed_at
        ? new Date(j.completed_at).toLocaleDateString('en-ZA', { day:'numeric', month:'short', year:'numeric' })
        : '—';
      const stars     = j.rating ? '⭐'.repeat(Math.round(j.rating)) : '';
      const review    = j.review_text ? `<p style="font-size:11px;color:var(--text-muted);margin-top:3px;font-style:italic">"${escapeHtml(j.review_text)}"</p>` : '';
      const feeNote   = gross > 0
        ? `after ${formatZAR(platFee)} Servit fee`
        : j.is_legacy_row ? `after commission` : '';
      const bookingRef = j.booking_id ? escapeHtml(j.booking_id) : '';
      return `
        <div style="background:var(--card-bg);border:1px solid var(--border);border-radius:var(--r-md);padding:12px 14px;margin-bottom:8px">
          <div style="display:flex;align-items:flex-start;justify-content:space-between">
            <div style="flex:1;min-width:0">
              <p style="font-size:13px;font-weight:600">${escapeHtml(label)}</p>
              <p style="font-size:11px;color:var(--text-muted)">${dateStr}${stars ? ' · ' + stars : ''}</p>
              ${review}
            </div>
            <div style="text-align:right;flex-shrink:0;margin-left:10px">
              <p style="font-weight:700;color:var(--forest);font-size:14px">+${formatZAR(earned)}</p>
              ${feeNote ? `<p style="font-size:10px;color:var(--text-muted)">${escapeHtml(feeNote)}</p>` : ''}
              ${bookingRef ? `<button class="btn btn-outline btn-sm" style="font-size:10px;padding:3px 8px;margin-top:5px;color:var(--text-muted);border-color:var(--border)" onclick="event.stopPropagation();raisePayDisputeModal('${bookingRef}','${escapeHtml(label)}',${earned})">❓ Question pay</button>` : ''}
            </div>
          </div>
        </div>`;
    }).join('') : '<div style="text-align:center;padding:24px;color:var(--text-muted)">No completed jobs yet</div>'}`;
}
window.loadFixerJobs = loadFixerJobs;
window.showFixerJobsScreen = showFixerJobsScreen;

function showFixerDashboard() {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-fixer-dashboard').classList.add('active');
  updateActiveNav('home');
  // IMPROVEMENT 2: start heartbeat whenever fixer views dashboard
  startFixerHeartbeat();
  loadFixerDashboard();
  // Show post-approval onboarding once for newly approved fixers
  maybeShowFixerOnboarding();
}

// ─────────────────── Bookings list (customer) ────────────────────

function getActiveBookingTab() {
  return document.querySelector('#screen-bookings .tab.active')?.dataset.tab || 'active';
}

async function loadBookings(tab = 'active') {
  const activeStatuses = ['SEARCHING', 'OFFERED', 'CONFIRMED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS', 'PENDING_COMPLETION'];
  const historyStatuses = ['COMPLETED', 'CANCELLED', 'DISPUTED', 'EXPIRED'];
  const statuses = tab === 'active' ? activeStatuses : historyStatuses;

  const container = document.getElementById('bookings-list');
  if (!container) return;

  container.innerHTML = [1,2].map(() => `
    <div class="skeleton-card" style="border-radius:var(--r-lg);border:1px solid var(--border);margin-bottom:12px;padding:16px">
      <div style="flex:1">
        <div class="skeleton skeleton-line" style="width:40%;margin-bottom:10px;height:14px"></div>
        <div class="skeleton skeleton-line" style="width:70%;margin-bottom:8px"></div>
        <div class="skeleton skeleton-line" style="width:50%"></div>
      </div>
    </div>`).join('');

  const { data: bookings, error } = await supabaseClient
    .from('bookings')
    .select('*, fixers!fixer_id(full_name, phone, category)')
    .eq('customer_id', currentUser.id)
    .in('status', statuses)
    .order('created_at', { ascending: false });

  if (error) {
    container.innerHTML = `
      <div style="text-align:center;padding:56px 20px;">
        <div style="font-size:48px;margin-bottom:16px;opacity:.5">⚠️</div>
        <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;color:var(--text-dark);margin-bottom:8px">Could not load bookings</p>
        <p style="font-size:13px;color:var(--text-muted);margin-bottom:24px;line-height:1.7;max-width:260px;margin-left:auto;margin-right:auto">Please check your connection and try again.</p>
        <button class="btn btn-primary" onclick="loadBookings('${tab}')">↻ Retry</button>
      </div>`;
    return;
  }

  if (!bookings || bookings.length === 0) {
    const isActive = tab === 'active';
    container.innerHTML = `
      <div style="text-align:center;padding:48px 20px;">
        <div style="width:72px;height:72px;border-radius:50%;background:var(--cream-dark);display:flex;align-items:center;justify-content:center;font-size:36px;margin:0 auto 18px">${isActive ? '📋' : '🗂️'}</div>
        <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;color:var(--text-dark);margin-bottom:8px">
          ${isActive ? 'No active bookings' : 'No jobs yet'}
        </p>
        <p style="font-size:13px;color:var(--text-muted);margin-bottom:24px;line-height:1.75;max-width:260px;margin-left:auto;margin-right:auto">
          ${isActive
            ? 'Tap a category below to book a verified fixer near you. Most jobs confirmed in under 2 minutes.'
            : 'Your completed and past bookings will appear here once you start booking.'}
        </p>
        ${isActive ? `
          <button class="btn btn-primary" onclick="navigate('home')" style="padding:12px 28px;font-size:14px;margin-bottom:14px">Browse services →</button>
          <div style="display:flex;align-items:center;justify-content:center;gap:10px;font-size:11px;color:var(--text-muted)">
            <span>🛡️ Verified</span><span style="width:3px;height:3px;border-radius:50%;background:var(--border)"></span>
            <span>⚡ Fast match</span><span style="width:3px;height:3px;border-radius:50%;background:var(--border)"></span>
            <span>🔒 Secure pay</span>
          </div>` : `
          <button class="btn btn-outline" onclick="navigate('home')" style="padding:12px 28px;font-size:14px">Book your first job →</button>`}
      </div>`;
    return;
  }

  // Show active job banner if any en_route / in_progress
  const liveJob = bookings.find(b => ['EN_ROUTE','ARRIVED','IN_PROGRESS'].includes(b.status));
  const banner = document.getElementById('active-job-banner');
  if (banner) {
    if (liveJob && tab === 'active') {
      const bannerText = { EN_ROUTE: '🚗 Fixer en route — tap to track', ARRIVED: '📍 Fixer has arrived!', IN_PROGRESS: '⚡ Work in progress' }[liveJob.status] || '';
      banner.style.display = 'flex';
      document.getElementById('active-job-banner-text').textContent = bannerText;
      window._activeBannerJobId = liveJob.id;
    } else {
      banner.style.display = 'none';
    }
  }

  const statusLabel = {
    SEARCHING: 'Searching for fixer',
    OFFERED: 'Offer received',
    CONFIRMED: 'Confirmed ✓',
    EN_ROUTE: 'En route 🚗',
    ARRIVED: 'Arrived 📍',
    IN_PROGRESS: 'In progress ⚡',
    PENDING_COMPLETION: 'Awaiting your approval',
    COMPLETED: 'Completed ✅',
    CANCELLED: 'Cancelled',
    DISPUTED: 'Disputed ⚠️',
    EXPIRED: 'Expired',
  };

  const statusBg = {
    SEARCHING: '#E8F0FA', OFFERED: '#FDF3E0', CONFIRMED: '#E8F5EE',
    EN_ROUTE: '#E8F0FA', ARRIVED: '#E8F0FA', IN_PROGRESS: '#FDF3E0',
    PENDING_COMPLETION: '#FFF3CD', COMPLETED: '#E8F5EE',
    CANCELLED: '#F5F5F5', DISPUTED: '#FEE2E2', EXPIRED: '#F5F5F5',
  };
  const statusColor = {
    SEARCHING: 'var(--info)', OFFERED: 'var(--gold-dark)', CONFIRMED: 'var(--success)',
    EN_ROUTE: 'var(--info)', ARRIVED: 'var(--info)', IN_PROGRESS: 'var(--gold-dark)',
    PENDING_COMPLETION: '#856404', COMPLETED: 'var(--success)',
    CANCELLED: 'var(--text-muted)', DISPUTED: 'var(--danger)', EXPIRED: 'var(--text-muted)',
  };

  // Status steps for Uber-style progress
  const steps = [
    { key: 'CONFIRMED', label: 'Confirmed', icon: '✓' },
    { key: 'EN_ROUTE',  label: 'En route',  icon: '🚗' },
    { key: 'ARRIVED',   label: 'Arrived',   icon: '📍' },
    { key: 'IN_PROGRESS', label: 'Working', icon: '⚡' },
    { key: 'PENDING_COMPLETION', label: 'Done', icon: '✅' },
  ];
  const stepOrder = ['CONFIRMED','EN_ROUTE','ARRIVED','IN_PROGRESS','PENDING_COMPLETION','COMPLETED'];

  container.innerHTML = bookings.map(booking => {
    const fixerName = booking.fixers?.full_name || 'Your fixer';
    const fixerCat  = booking.fixers?.category  || '';
    const fixerPhone = booking.fixers?.phone || '';
    const isLive = ['EN_ROUTE','ARRIVED','IN_PROGRESS','PENDING_COMPLETION'].includes(booking.status);
    const isHistory = ['COMPLETED','CANCELLED','DISPUTED','EXPIRED'].includes(booking.status);
    const currentStepIdx = stepOrder.indexOf(booking.status);

    // Uber-style step tracker (only for active confirmed+ jobs)
    const showTracker = ['CONFIRMED','EN_ROUTE','ARRIVED','IN_PROGRESS','PENDING_COMPLETION'].includes(booking.status);
    const trackerHtml = showTracker ? `
      <div class="booking-status-bar" style="margin:10px 0 8px">
        ${steps.map((step, i) => {
          const stepIdx = stepOrder.indexOf(step.key);
          const isDone   = stepIdx < currentStepIdx;
          const isActive = step.key === booking.status;
          return `<div class="booking-status-step">
            <div class="booking-status-dot ${isDone ? 'done' : isActive ? 'active' : ''}">${isDone ? '✓' : step.icon}</div>
            <span class="booking-status-label ${isActive ? 'active' : ''}">${step.label}</span>
          </div>`;
        }).join('')}
      </div>
    ` : '';

    const progressPct = showTracker ? Math.round((currentStepIdx / (stepOrder.length - 1)) * 100) : 0;
    const progressBar = showTracker ? `
      <div style="height:2px;background:var(--border);border-radius:1px;margin:-4px 0 8px;overflow:hidden">
        <div style="height:100%;background:var(--gold);border-radius:1px;width:${progressPct}%;transition:width .4s"></div>
      </div>` : '';

    const confirmedBanner = booking.status === 'CONFIRMED' ? (() => {
      const fixer = booking.fixers || {};
      const badges = [];
      if (fixer.is_verified)          badges.push({ icon:'✓', label:'Verified', bg:'rgba(74,222,128,.2)', color:'#4ADE80' });
      if (fixer.badge_top_fixer)      badges.push({ icon:'🏆', label:'Top Fixer', bg:'rgba(201,148,58,.25)', color:'var(--gold-light)' });
      if (fixer.badge_fast_responder) badges.push({ icon:'⚡', label:'Fast', bg:'rgba(147,197,253,.2)', color:'#93C5FD' });
      const initial = (fixer.full_name || '?')[0].toUpperCase();
      const hasPhoto = fixer.photo_url && fixer.photo_url.startsWith('http');
      const avatarHtml = hasPhoto
        ? `<img src="${escapeHtml(fixer.photo_url)}" style="width:52px;height:52px;border-radius:50%;object-fit:cover;border:2.5px solid var(--gold);flex-shrink:0" onerror="this.outerHTML='<div style=\\'width:52px;height:52px;border-radius:50%;background:rgba(255,255,255,.15);display:flex;align-items:center;justify-content:center;font-size:22px;font-weight:700;color:#fff;border:2.5px solid var(--gold);flex-shrink:0\\'>${initial}</div>'">`
        : `<div style="width:52px;height:52px;border-radius:50%;background:rgba(255,255,255,.15);display:flex;align-items:center;justify-content:center;font-size:22px;font-weight:700;color:#fff;border:2.5px solid var(--gold);flex-shrink:0">${initial}</div>`;
      const completedJobs = fixer.total_completed ? `${fixer.total_completed} jobs done` : '';
      const etaMins = 15; // default — will be updated by live location
      return `
        <div style="background:linear-gradient(135deg,#1A3A2A,#2D5A3D);padding:16px;border-radius:var(--r-md) var(--r-md) 0 0;margin:-14px -16px 14px;position:relative;overflow:hidden">
          <div style="position:absolute;top:-30px;right:-30px;width:120px;height:120px;border-radius:50%;background:radial-gradient(circle,rgba(201,148,58,.15) 0%,transparent 70%)"></div>
          <!-- Celebration flash row -->
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:12px">
            <span style="width:8px;height:8px;background:#4ADE80;border-radius:50%;animation:servit-pulse 1s infinite;flex-shrink:0"></span>
            <p style="font-size:11px;font-weight:700;color:rgba(255,255,255,.75);text-transform:uppercase;letter-spacing:.6px">✅ Fixer Assigned!</p>
          </div>
          <!-- Fixer row -->
          <div style="display:flex;align-items:center;gap:12px;margin-bottom:12px">
            <div style="position:relative;flex-shrink:0">${avatarHtml}${fixer.is_verified ? '<span style="position:absolute;bottom:1px;right:1px;width:14px;height:14px;background:#4ADE80;border-radius:50%;border:2px solid #1A3A2A;display:flex;align-items:center;justify-content:center;font-size:8px">✓</span>' : ''}</div>
            <div style="flex:1;min-width:0">
              <p style="font-weight:700;font-size:16px;color:#fff;margin-bottom:2px">${escapeHtml(fixer.full_name || 'Your fixer')}</p>
              <div style="display:flex;gap:5px;flex-wrap:wrap;margin-bottom:4px">
                ${fixer.rating ? `<span style="background:rgba(255,255,255,.15);color:rgba(255,255,255,.9);font-size:10px;font-weight:700;padding:2px 7px;border-radius:8px">⭐ ${Number(fixer.rating).toFixed(1)}</span>` : ''}
                ${completedJobs ? `<span style="background:rgba(255,255,255,.1);color:rgba(255,255,255,.7);font-size:10px;font-weight:600;padding:2px 7px;border-radius:8px">${completedJobs}</span>` : ''}
                ${badges.map(b => `<span style="background:${b.bg};color:${b.color};font-size:10px;font-weight:700;padding:2px 7px;border-radius:8px">${b.icon} ${b.label}</span>`).join('')}
              </div>
            </div>
            ${fixer.phone ? `<a href="tel:${escapeHtml(fixer.phone)}" style="background:rgba(255,255,255,.15);border:1px solid rgba(255,255,255,.3);color:#fff;font-size:12px;font-weight:700;padding:8px 14px;border-radius:var(--r-md);text-decoration:none;flex-shrink:0">📞 Call</a>` : ''}
          </div>
          <!-- ETA row -->
          <div style="background:rgba(0,0,0,.2);border-radius:var(--r-sm);padding:8px 12px;display:flex;align-items:center;gap:8px">
            <span style="font-size:16px">🚗</span>
            <div style="flex:1">
              <p style="font-size:12px;font-weight:700;color:#fff">On their way · ETA ~${etaMins} min</p>
              <p style="font-size:10px;color:rgba(255,255,255,.55)">They'll call when nearby · <span style="color:var(--gold-light)">Track live below ↓</span></p>
            </div>
          </div>
        </div>`; })() : '';

    const enRouteBanner = booking.status === 'EN_ROUTE' ? (() => {
      const fixer = booking.fixers || {};
      // Estimate ETA: confirmed_at + typical travel time
      const confirmedAt = new Date(booking.confirmed_at || booking.updated_at);
      const minsElapsed = Math.floor((Date.now() - confirmedAt) / 60000);
      const etaMins = Math.max(1, 20 - minsElapsed);  // rough: assume ~20 min travel
      return `
        <div style="background:linear-gradient(135deg,#1A3A5A,#2D4A7A);padding:10px 16px;border-radius:var(--r-md) var(--r-md) 0 0;margin:-14px -16px 12px;display:flex;align-items:center;gap:10px">
          <span style="width:8px;height:8px;background:#4ADE80;border-radius:50%;animation:servit-pulse 1.2s infinite;flex-shrink:0"></span>
          <div style="flex:1">
            <p style="font-size:13px;font-weight:700;color:#fff">${escapeHtml(fixer.full_name || 'Your fixer')} is on the way</p>
            <p style="font-size:11px;color:rgba(255,255,255,.65)">ETA ~${etaMins} min · They'll call when nearby</p>
          </div>
          ${fixer.phone ? `<a href="tel:${escapeHtml(fixer.phone)}" style="color:var(--gold-light);font-size:20px;text-decoration:none">📞</a>` : ''}
        </div>`; })() : '';

    return `
      <div class="booking-card" style="margin-bottom:12px;padding:14px 16px;${isHistory ? 'opacity:.85' : ''}">
        ${confirmedBanner}
        ${enRouteBanner}
        <div style="display:flex;align-items:flex-start;gap:10px;margin-bottom:${showTracker ? '0' : '8px'}">
          <div style="width:44px;height:44px;border-radius:50%;background:var(--forest-mid);display:flex;align-items:center;justify-content:center;font-size:19px;font-weight:700;color:#fff;flex-shrink:0;border:2px solid ${isLive ? 'var(--gold)' : 'var(--border)'}">
            ${fixerName[0] || '?'}
          </div>
          <div style="flex:1;min-width:0">
            <p style="font-weight:700;font-size:15px;margin-bottom:2px">${escapeHtml(booking.description || 'Service')}</p>
            <p style="font-size:12px;color:var(--text-mid);font-weight:500;margin-bottom:3px">${escapeHtml(fixerName)}${fixerCat ? ' · ' + escapeHtml(fixerCat) : ''}</p>
            <p style="font-size:11px;color:var(--text-muted)">📍 ${escapeHtml(booking.address || '—')}</p>
            <p style="font-size:11px;color:var(--text-muted)">📅 ${new Date(booking.created_at).toLocaleDateString('en-ZA', {weekday:'short',day:'numeric',month:'short'})}</p>
          </div>
          <div style="text-align:right;flex-shrink:0">
            <p style="font-weight:700;color:var(--forest);font-size:15px;margin-bottom:5px">${formatZAR(booking.customer_total || booking.amount || 0)}</p>
            <span style="display:inline-flex;padding:3px 9px;border-radius:20px;font-size:10px;font-weight:700;background:${statusBg[booking.status] || '#f5f5f5'};color:${statusColor[booking.status] || 'var(--text-muted)'}">${statusLabel[booking.status] || booking.status}</span>
          </div>
        </div>
        ${trackerHtml}
        ${progressBar}
        <div style="border-top:1px solid var(--border);padding-top:10px;margin-top:2px;display:flex;gap:7px;flex-wrap:wrap">
          ${booking.status === 'PENDING_COMPLETION' ? `
            <button class="btn btn-primary btn-sm" style="flex:2;font-size:12px" onclick="event.stopPropagation();updateJobStatus('${booking.id}','COMPLETED')">✔ Confirm Complete</button>
          ` : ''}
          ${isLive && fixerPhone ? `
            <button class="btn btn-outline btn-sm" style="flex:1;font-size:12px" onclick="event.stopPropagation();window.open('tel:'+this.dataset.phone)" data-phone="${escapeHtml(fixerPhone)}">📞 Call</button>
            <button class="btn btn-outline btn-sm" style="flex:1;font-size:12px" onclick="event.stopPropagation();openChat(this.dataset.uid,this.dataset.name,this.dataset.bid)" data-uid="${escapeHtml(booking.fixers?.user_id||'')}" data-name="${escapeHtml(fixerName)}" data-bid="${escapeHtml(booking.id)}">💬 Chat</button>
          ` : ''}
          ${booking.status === 'CONFIRMED' ? `
            <button class="btn btn-outline btn-sm" style="flex:1;font-size:12px;color:var(--danger);border-color:var(--danger)" onclick="event.stopPropagation();cancelBookingConfirm('${booking.id}')">Cancel</button>
          ` : ''}
          ${booking.status === 'COMPLETED' ? `
            <button class="btn btn-primary btn-sm" style="flex:2;font-size:12px" onclick="event.stopPropagation();rebookJob('${booking.id}','${escapeHtml(booking.category||'')}','${escapeHtml(fixerName)}')">🔄 Rebook</button>
            <button class="btn btn-outline btn-sm" style="flex:1;font-size:12px" onclick="event.stopPropagation();openRatingModal('${booking.id}','${booking.fixer_id}','${escapeHtml(fixerName)}')">⭐ Rate</button>
            ${booking.fixer_id ? `<button class="btn btn-outline btn-sm" style="flex:1;font-size:12px" onclick="event.stopPropagation();toggleFavourite('${booking.fixer_id}','${escapeHtml(fixerName)}',this)">🤍</button>` : ''}
          ` : ''}
          ${booking.status === 'OFFERED' ? `
            <p style="font-size:11px;color:var(--gold-dark);font-weight:600;padding:4px 0;animation:servit-pulse 2s infinite">⏳ Contacting fixer — please wait…</p>` : ''}
          ${booking.status === 'SEARCHING' ? `
            <div style="padding:6px 0">
              <div style="display:flex;align-items:center;gap:8px;margin-bottom:4px">
                <span style="width:8px;height:8px;background:var(--gold);border-radius:50%;animation:servit-pulse 1s infinite;flex-shrink:0"></span>
                <p style="font-size:12px;font-weight:600;color:var(--text-mid)">Finding your fixer…</p>
              </div>
              <p style="font-size:11px;color:var(--text-muted);line-height:1.6">Our system is contacting available fixers nearby. This usually takes under 2 minutes.</p>
            </div>` : ''}
          ${booking.status === 'DISPUTED' ? `
            <div style="background:#FEF2F2;border:1.5px solid #FECACA;border-radius:var(--r-md);padding:14px 16px;margin-top:4px">
              <p style="font-size:13px;font-weight:700;color:var(--danger);margin-bottom:6px">⚠️ Dispute in progress</p>
              <p style="font-size:12px;color:#7F1D1D;line-height:1.6;margin-bottom:10px">Our team is reviewing your case and will contact you within <b>24 hours</b> via the app and email. Your payment remains held safely in escrow until the dispute is resolved.</p>
              <div style="border-top:1px solid #FECACA;padding-top:10px;margin-bottom:10px">
                <p style="font-size:11px;font-weight:600;color:var(--danger);margin-bottom:6px;text-transform:uppercase;letter-spacing:.5px">What happens next</p>
                <p style="font-size:12px;color:#7F1D1D;line-height:1.7">
                  <b>1.</b> We review the job details &amp; messages<br>
                  <b>2.</b> Both parties may be contacted for more info<br>
                  <b>3.</b> A decision is made: refund, partial payment, or release to fixer<br>
                  <b>4.</b> You'll be notified via push notification &amp; email
                </p>
              </div>
              <button class="btn btn-outline btn-sm" style="width:100%;font-size:12px;color:var(--danger);border-color:var(--danger)" onclick="event.stopPropagation();openChat('${booking.fixers?.user_id || ''}','${escapeHtml(fixerName || 'Fixer')}','${booking.id}')">💬 Message the fixer</button>
            </div>` : ''}
        </div>
      </div>`;
  }).join('');
}

function showBookingsScreen(tab = 'active') {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-bookings').classList.add('active');
  updateActiveNav('bookings');
  document.querySelectorAll('#bookings-tabs .tab').forEach(t => {
    t.classList.toggle('active', t.dataset.tab === tab);
  });
  loadBookings(tab);
}

async function rebookJob(bookingId, category, fixerName) {
  try {
    const { data } = await supabaseClient.rpc('rebook_from_history', {
      p_customer_id: currentUser.id,
      p_booking_id: bookingId,
    });
    if (data?.error) { showToast(data.error, 'error'); return; }
    const prefill = data?.prefill || {};
    // Open booking form with pre-filled values
    const cat = prefill.category || category || 'Other';
    const emoji = getCategoryEmoji(cat);
    showRequestScreen(cat, emoji, cat);
    // Wait for DOM then fill in values
    setTimeout(() => {
      const desc = document.getElementById('job-description');
      const addr = document.getElementById('job-address');
      const budget = document.getElementById('job-budget');
      if (desc && prefill.description) desc.value = prefill.description;
      if (addr && prefill.address) addr.value = prefill.address;
      if (budget && prefill.amount) budget.value = prefill.amount;
      if (prefill.service_tier) {
        _selectedTier = prefill.service_tier;
        selectTier(prefill.service_tier);
      }
      showToast(`Re-booking ${fixerName ? 'with ' + fixerName : 'your previous job'}`, 'success');
    }, 200);
  } catch (err) {
    showToast(err.message, 'error');
  }
}
window.rebookJob = rebookJob;

async function toggleFavourite(fixerId, fixerName, btn) {
  try {
    const { data } = await supabaseClient.rpc('toggle_favourite_fixer', {
      p_customer_id: currentUser.id,
      p_fixer_id: fixerId,
    });
    const favourited = data?.favourited;
    if (btn) {
      btn.textContent = favourited ? '❤️' : '🤍';
      btn.title = favourited ? 'Remove from favourites' : 'Save fixer';
    }
    showToast(favourited ? `${fixerName} saved to favourites` : `Removed from favourites`, 'success');
  } catch (err) {
    showToast(err.message, 'error');
  }
}
window.toggleFavourite = toggleFavourite;

// ─────────────────── Rating modal (customer → fixer) ────────────
function openRatingModal(bookingId, fixerId, fixerName) {
  document.querySelector('.rating-modal-overlay')?.remove();
  let selectedStars = 0;

  const overlay = document.createElement('div');
  overlay.className = 'rating-modal-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end;animation:fadeIn .2s ease';
  overlay.innerHTML = `
    <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:24px 20px 44px;animation:slideUp .28s cubic-bezier(.25,.46,.45,.94)">
      <div style="width:40px;height:4px;background:var(--border);border-radius:2px;margin:0 auto 20px"></div>
      <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;color:var(--text-dark);text-align:center;margin-bottom:4px">Rate your fixer</p>
      <p style="font-size:13px;color:var(--text-muted);text-align:center;margin-bottom:20px">How was your experience with <strong>${escapeHtml(fixerName)}</strong>?</p>

      <!-- Stars -->
      <div id="star-row" style="display:flex;justify-content:center;gap:12px;margin-bottom:20px">
        ${[1,2,3,4,5].map(n => `
          <span data-star="${n}" onclick="ratingSetStars(${n})"
            style="font-size:36px;cursor:pointer;transition:transform .15s;opacity:.35;filter:grayscale(1)"
            onmouseenter="ratingHoverStars(${n})" onmouseleave="ratingHoverStars(0)">★</span>`).join('')}
      </div>
      <p id="star-label" style="text-align:center;font-size:13px;font-weight:600;color:var(--text-muted);min-height:20px;margin-bottom:16px"></p>

      <!-- Comment -->
      <div class="input-group" style="margin-bottom:18px">
        <label class="input-label">Leave a comment <span style="color:var(--text-muted);font-weight:400">(optional)</span></label>
        <textarea id="rating-comment" class="input" rows="3" placeholder="Great work, very professional…" style="resize:none"></textarea>
      </div>

      <button id="rating-submit-btn" class="btn btn-primary btn-block" disabled
        style="opacity:.45;transition:opacity .2s" onclick="submitRating('${bookingId}','${fixerId}')">
        Submit Rating
      </button>
      <button class="btn btn-outline btn-block" onclick="document.querySelector('.rating-modal-overlay')?.remove()"
        style="margin-top:10px;color:var(--text-muted);border-color:var(--border);font-size:13px">
        Maybe later
      </button>
    </div>`;

  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
  document.body.appendChild(overlay);
}

const STAR_LABELS = ['','Terrible','Poor','Good','Very good','Excellent! 🎉'];

window.ratingSetStars = function(n) {
  window._selectedRating = n;
  const stars = document.querySelectorAll('#star-row [data-star]');
  const lbl   = document.getElementById('star-label');
  const btn   = document.getElementById('rating-submit-btn');
  stars.forEach(s => {
    const v = parseInt(s.dataset.star);
    s.style.opacity = v <= n ? '1' : '.35';
    s.style.filter  = v <= n ? 'none' : 'grayscale(1)';
    s.style.transform = v <= n ? 'scale(1.15)' : 'scale(1)';
    s.style.color = v <= n ? 'var(--gold)' : '';
  });
  if (lbl) lbl.textContent = STAR_LABELS[n] || '';
  if (btn) { btn.disabled = false; btn.style.opacity = '1'; }
};

window.ratingHoverStars = function(n) {
  if (window._selectedRating) return; // don't disturb set rating
  const stars = document.querySelectorAll('#star-row [data-star]');
  stars.forEach(s => {
    const v = parseInt(s.dataset.star);
    s.style.opacity = v <= n ? '.8' : '.35';
    s.style.color = v <= n ? 'var(--gold)' : '';
  });
};

window.submitRating = async function(bookingId, fixerId) {
  const stars   = window._selectedRating || 0;
  const comment = document.getElementById('rating-comment')?.value?.trim() || '';
  const btn     = document.getElementById('rating-submit-btn');
  if (!stars) { showToast('Please select a star rating', 'error'); return; }
  if (btn) { btn.disabled = true; btn.textContent = 'Submitting…'; }
  try {
    await apiCall('write-review', { booking_id: bookingId, fixer_id: fixerId, rating: stars, comment });
    document.querySelector('.rating-modal-overlay')?.remove();
    trackEvent('review_submitted', { stars, booking_id: bookingId });
    showToast('Thank you for your rating! ⭐', 'success');
    window._selectedRating = null;
  } catch (err) {
    if (btn) { btn.disabled = false; btn.textContent = 'Submit Rating'; }
    showToast(err.message || 'Could not submit rating', 'error');
  }
};

window.openRatingModal = openRatingModal;

// ─────────────────── Customer welcome onboarding ────────────────
function maybeShowWelcome() {
  if (!currentUser) return;
  const key = `servit_welcomed_${currentUser.id}`;
  if (localStorage.getItem(key)) return;
  localStorage.setItem(key, '1');
  setTimeout(showWelcomeFlow, 600); // wait for home screen to settle
}

function showWelcomeFlow(preAuth = false) {
  document.querySelector('.welcome-overlay')?.remove();
  let slide = 0;
  const slides = [
    {
      emoji: '👋',
      title: 'Welcome to Servit!',
      body: 'Get any service done — plumber, electrician, cleaner, salon and more — in minutes. Right here in South Africa.',
      btn: 'How it works →',
    },
    {
      emoji: '🔧',
      title: '3 steps to a fixed home',
      body: '<b>1.</b> Pick a service &amp; set your budget<br><b>2.</b> We match you with a verified fixer nearby<br><b>3.</b> Fixer arrives · You approve · Pay securely',
      btn: 'What about trust? →',
    },
    {
      emoji: '🛡️',
      title: 'Safe &amp; trusted',
      body: 'Every fixer is ID-verified. Ratings &amp; reviews are shown on every profile. If something goes wrong, we have your back through our disputes system.',
      btn: preAuth ? 'Create free account →' : 'Book my first job →',
    },
  ];

  const overlay = document.createElement('div');
  overlay.className = 'welcome-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.65);z-index:99999;display:flex;align-items:flex-end;animation:fadeIn .25s ease';

  function render() {
    const s = slides[slide];
    overlay.innerHTML = `
      <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:28px 24px 44px;animation:slideUp .3s cubic-bezier(.25,.46,.45,.94)">
        <!-- Dots -->
        <div style="display:flex;justify-content:center;gap:6px;margin-bottom:24px">
          ${slides.map((_,i) => `<span style="width:${i===slide?'20px':'7px'};height:7px;border-radius:4px;background:${i===slide?'var(--forest)':'var(--border)'};transition:all .3s"></span>`).join('')}
        </div>
        <div style="text-align:center;margin-bottom:24px">
          <div style="font-size:56px;margin-bottom:16px">${s.emoji}</div>
          <p style="font-family:'Playfair Display',serif;font-size:21px;font-weight:700;color:var(--text-dark);margin-bottom:10px">${s.title}</p>
          <p style="font-size:14px;color:var(--text-mid);line-height:1.75">${s.body}</p>
        </div>
        <button class="btn btn-primary btn-block" onclick="welcomeNext()" style="padding:15px;font-size:15px">${s.btn}</button>
        <p style="text-align:center;font-size:12px;color:var(--text-muted);margin-top:12px;cursor:pointer" onclick="document.querySelector('.welcome-overlay')?.remove()">Skip</p>
      </div>`;
  }

  window.welcomeNext = function() {
    slide++;
    if (slide >= slides.length) {
      overlay.remove();
      trackEvent('onboarding_completed');
      // If shown pre-login, activate the Create Account tab to guide the user into signup
      if (preAuth) {
        const signupTabBtn = document.querySelector('.auth-tab-btn:nth-child(2)');
        if (signupTabBtn) signupTabBtn.click();
      }
    } else {
      render();
    }
  };

  render();
  document.body.appendChild(overlay);
  trackEvent('onboarding_started');
}

window.showWelcomeFlow = showWelcomeFlow;


// ─────────────────── Fixer post-approval onboarding ──────────────
function maybeShowFixerOnboarding() {
  if (!currentUser || !currentFixerProfile) return;
  const key = `servit_fixer_onboarded_${currentUser.id}`;
  if (localStorage.getItem(key)) return;
  localStorage.setItem(key, '1');
  setTimeout(showFixerOnboardingFlow, 700);
}

function showFixerOnboardingFlow() {
  document.querySelector('.fixer-onboard-overlay')?.remove();
  let slide = 0;

  const slides = [
    {
      emoji: '🎉',
      title: "You're approved!",
      body: "Welcome to Servit. Customers in your area are already looking for fixers like you. Here's how to get your first job.",
      btn: 'Show me →',
    },
    {
      emoji: '🏦',
      title: 'Set up your payout account',
      body: '<b>Before your first job</b>, add your bank details so we know where to pay you. Go to <b>Profile → Payout Details</b> now — you won\'t be able to receive money without this. Payouts are processed daily after job completion.',
      btn: 'Got it →',
    },
    {
      emoji: '🟢',
      title: 'Go online to get offers',
      body: 'Jobs only come to you when you\'re <b>Online</b>. Tap the toggle on your dashboard whenever you\'re ready to work. Go <b>Offline</b> when you\'re not available — you won\'t be disturbed.',
      btn: 'Got it →',
    },
    {
      emoji: '📍',
      title: 'Your location = more jobs',
      body: 'We match jobs by distance. The closer you are to the customer, the higher you rank. <b>Allow location access</b> when your browser asks — this is the single biggest factor in how often you get offered work.',
      btn: 'Understood →',
    },
    {
      emoji: '⏱️',
      title: 'Respond fast, rank higher',
      body: 'When an offer arrives you have a short window to accept or decline. <b>Faster responses earn you a ⚡ Fast Responder badge</b> and push you to the top of the queue. Ignoring offers hurts your ranking.',
      btn: 'One more →',
    },
    {
      emoji: '🛡️',
      title: 'Payment is protected',
      body: "The customer pays upfront into escrow. You only get paid once the job is marked complete — so <b>you're always covered</b>. Disputes are reviewed by our team within 24 hours.",
      btn: "Let's go →",
    },
  ];

  const overlay = document.createElement('div');
  overlay.className = 'fixer-onboard-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.65);z-index:99999;display:flex;align-items:flex-end;animation:fadeIn .25s ease';

  function render() {
    const s = slides[slide];
    const isLast = slide === slides.length - 1;
    overlay.innerHTML = `
      <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:28px 24px 44px;animation:slideUp .3s cubic-bezier(.25,.46,.45,.94)">
        <div style="display:flex;justify-content:center;gap:6px;margin-bottom:24px">
          ${slides.map((_,i) => `<span style="width:${i===slide?'20px':'7px'};height:7px;border-radius:4px;background:${i===slide?'var(--forest)':'var(--border)'};transition:all .3s"></span>`).join('')}
        </div>
        <div style="text-align:center;margin-bottom:24px">
          <div style="font-size:56px;margin-bottom:16px">${s.emoji}</div>
          <p style="font-family:'Playfair Display',serif;font-size:21px;font-weight:700;color:var(--text-dark);margin-bottom:10px">${s.title}</p>
          <p style="font-size:14px;color:var(--text-mid);line-height:1.75">${s.body}</p>
        </div>
        <button class="btn btn-primary btn-block" id="fixer-onboard-next-btn" style="padding:15px;font-size:15px">${s.btn}</button>
        ${isLast ? '' : `<p style="text-align:center;font-size:12px;color:var(--text-muted);margin-top:12px;cursor:pointer" onclick="document.querySelector('.fixer-onboard-overlay')?.remove();trackEvent('fixer_onboarding_skipped',{slide:${slide}})">Skip</p>`}
      </div>`;
    document.getElementById('fixer-onboard-next-btn').onclick = fixerOnboardNext;
  }

  window.fixerOnboardNext = function() {
    slide++;
    if (slide >= slides.length) {
      overlay.remove();
      trackEvent('fixer_onboarding_completed');
      // Prompt location immediately after onboarding completes
      if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(
          () => { /* location granted — heartbeat will use it */ },
          () => { /* denied — fixer can still work, just ranked lower */ }
        );
      }
    } else {
      render();
    }
  };

  render();
  document.body.appendChild(overlay);
  trackEvent('fixer_onboarding_started');
}

window.showFixerOnboardingFlow = showFixerOnboardingFlow;

// ─────────────────── Profile settings handlers ───────────────────

function showPaymentMethodsInfo() {
  document.querySelector('.payment-info-overlay')?.remove();
  const overlay = document.createElement('div');
  overlay.className = 'payment-info-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.65);z-index:99999;display:flex;align-items:flex-end;animation:fadeIn .2s ease';
  overlay.innerHTML = `
    <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:24px 20px 40px">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:20px">
        <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700">💳 Payment Methods</p>
        <button onclick="document.querySelector('.payment-info-overlay')?.remove()" style="background:none;border:none;font-size:22px;cursor:pointer;color:var(--text-muted)">×</button>
      </div>
      <p style="font-size:13px;color:var(--text-mid);line-height:1.7;margin-bottom:16px">Servit uses <b>Yoco</b> to process payments securely. You can pay with:</p>
      <div style="display:flex;flex-direction:column;gap:10px;margin-bottom:20px">
        <div style="display:flex;align-items:center;gap:12px;padding:12px;background:var(--cream);border-radius:var(--r-md)">
          <span style="font-size:22px">💳</span>
          <div><p style="font-size:13px;font-weight:600">Credit & Debit Card</p><p style="font-size:11px;color:var(--text-muted)">Visa, Mastercard</p></div>
        </div>
        <div style="display:flex;align-items:center;gap:12px;padding:12px;background:var(--cream);border-radius:var(--r-md)">
          <span style="font-size:22px">🏦</span>
          <div><p style="font-size:13px;font-weight:600">EFT / Instant EFT</p><p style="font-size:11px;color:var(--text-muted)">All major South African banks</p></div>
        </div>
      </div>
      <p style="font-size:11px;color:var(--text-muted);text-align:center">🔒 Your payment details are never stored on Servit. All transactions are secured by Yoco.</p>
    </div>`;
  document.body.appendChild(overlay);
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
}
window.showPaymentMethodsInfo = showPaymentMethodsInfo;

function requestPushPermission() {
  if (!('Notification' in window)) {
    showToast('Push notifications are not supported in this browser.', 'error');
    return;
  }
  if (Notification.permission === 'granted') {
    showToast('Push notifications are already enabled ✓');
    const el = document.getElementById('notif-status');
    if (el) el.textContent = 'Enabled ✓';
    return;
  }
  if (Notification.permission === 'denied') {
    showToast('Notifications are blocked. Please update this in your browser settings.', 'error');
    return;
  }
  Notification.requestPermission().then(permission => {
    const el = document.getElementById('notif-status');
    if (permission === 'granted') {
      showToast('Push notifications enabled ✓');
      if (el) el.textContent = 'Enabled ✓';
    } else {
      showToast('Notifications permission denied.', 'error');
      if (el) el.textContent = 'Disabled';
    }
  });
}
window.requestPushPermission = requestPushPermission;

function requestLocationPermission() {
  if (!navigator.geolocation) {
    showToast('Geolocation is not supported in this browser.', 'error');
    return;
  }
  const el = document.getElementById('location-status');
  if (el) el.textContent = 'Requesting…';
  navigator.geolocation.getCurrentPosition(
    (pos) => {
      showToast('Location access granted ✓');
      if (el) el.textContent = `Enabled · ${pos.coords.latitude.toFixed(3)}, ${pos.coords.longitude.toFixed(3)}`;
    },
    () => {
      showToast('Location access denied. Please enable it in browser settings.', 'error');
      if (el) el.textContent = 'Disabled — enable in browser settings';
    }
  );
}
window.requestLocationPermission = requestLocationPermission;


async function loadConversations() {
  const { data: msgs } = await supabaseClient
    .from('messages')
    .select('*')
    .or(`sender_id.eq.${currentUser.id},receiver_id.eq.${currentUser.id}`)
    .order('created_at', { ascending: false });

  const conversations = new Map();
  for (const msg of msgs || []) {
    const otherId = msg.sender_id === currentUser.id ? msg.receiver_id : msg.sender_id;
    const isUnread = !msg.read && msg.receiver_id === currentUser.id;
    if (!conversations.has(otherId)) {
      conversations.set(otherId, {
        id: otherId,
        name: 'Chat',
        lastMessage: msg.content,
        lastTime: msg.created_at,
        bookingId: msg.booking_id,
        unread: isUnread ? 1 : 0,
        isMine: msg.sender_id === currentUser.id,
      });
    } else if (isUnread) {
      conversations.get(otherId).unread++;
    }
  }

  const container = document.getElementById('conversations-list');
  if (!container) return;
  if (conversations.size === 0) {
    container.innerHTML = `
      <div style="text-align:center;padding:56px 20px;">
        <div style="font-size:56px;margin-bottom:16px;opacity:.5">💬</div>
        <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;color:var(--text-dark);margin-bottom:8px">No messages yet</p>
        <p style="font-size:13px;color:var(--text-muted);margin-bottom:24px;line-height:1.7;max-width:260px;margin-left:auto;margin-right:auto">Once you book a fixer, you can chat with them directly here.</p>
        <button class="btn btn-primary" onclick="navigate('bookings')" style="gap:8px">📋 View Bookings</button>
      </div>`;
    return;
  }

  const convList = Array.from(conversations.values());
  container.innerHTML = `<div id="convo-items">` + convList.map(conv => {
    const initials = (conv.name || '?')[0].toUpperCase();
    const colors = ['#1A3A2A','#2D5A3D','#5A3A1A','#1A3A5A','#3A1A5A','#5A1A3A'];
    const bg = colors[conv.id.charCodeAt(0) % colors.length];
    const preview = conv.isMine ? `You: ${conv.lastMessage}` : conv.lastMessage;
    return `<div class="convo-item ${conv.unread ? 'unread' : ''}" data-id="${conv.id}" data-name="${escapeHtml(conv.name)}" data-booking="${conv.bookingId || ''}" onclick="openChat(this.dataset.id,this.dataset.name,this.dataset.booking)">
      <div class="convo-avatar ${conv.unread ? 'unread-border' : ''}" style="background:${bg}">
        ${initials}
        <span class="convo-online-dot"></span>
      </div>
      <div class="convo-body">
        <div class="convo-header">
          <p class="convo-name">${escapeHtml(conv.name)}</p>
          <p class="convo-time">${timeAgo(conv.lastTime)}</p>
        </div>
        <p class="convo-preview">${escapeHtml((preview || '').substring(0, 65))}</p>
      </div>
      ${conv.unread ? `<div class="unread-badge">${conv.unread > 9 ? '9+' : conv.unread}</div>` : ''}
    </div>`;
  }).join('') + `</div>`;
}

function filterConversations(q) {
  const items = document.querySelectorAll('#convo-items .convo-item');
  items.forEach(item => {
    const name = item.querySelector('.convo-name')?.textContent?.toLowerCase() || '';
    const preview = item.querySelector('.convo-preview')?.textContent?.toLowerCase() || '';
    item.style.display = (name.includes(q.toLowerCase()) || preview.includes(q.toLowerCase())) ? '' : 'none';
  });
}
window.filterConversations = filterConversations;

function showMessagesScreen() {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-messages').classList.add('active');
  updateActiveNav('chat-list');
  loadConversations();
}

function openChat(userId, userName, bookingId) {
  currentChatPartner = userId;
  currentChatBookingId = bookingId;
  document.getElementById('chat-name').textContent = userName;
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-chat').classList.add('active');
  loadMessages();
  subscribeToMessages();
}

async function loadMessages() {
  if (!currentChatPartner) return;

  const { data: messages } = await supabaseClient
    .from('messages')
    .select('*')
    .or(`and(sender_id.eq.${currentUser.id},receiver_id.eq.${currentChatPartner}),and(sender_id.eq.${currentChatPartner},receiver_id.eq.${currentUser.id})`)
    .order('created_at', { ascending: true });

  const container = document.getElementById('chat-messages');
  if (!container) return;

  if (!messages || messages.length === 0) {
    container.innerHTML = '<div class="empty-state"><p>No messages yet. Say hello!</p></div>';
    return;
  }

  container.innerHTML = messages.map(msg => `
    <div class="message ${msg.sender_id === currentUser.id ? 'message-mine' : 'message-theirs'}">
      <div class="message-bubble">${escapeHtml(msg.content)}</div>
      <div class="message-time">${timeAgo(msg.created_at)}</div>
    </div>
  `).join('');

  container.scrollTop = container.scrollHeight;

  await supabaseClient
    .from('messages')
    .update({ read: true })
    .eq('sender_id', currentChatPartner)
    .eq('receiver_id', currentUser.id);
}

function subscribeToMessages() {
  if (messageChannel) supabaseClient.removeChannel(messageChannel);

  messageChannel = supabaseClient
    .channel(`messages-${currentUser.id}`)
    .on('postgres_changes', {
      event: 'INSERT',
      schema: 'public',
      table: 'messages',
      filter: `receiver_id=eq.${currentUser.id}`,
    }, (payload) => {
      if (payload.new.sender_id === currentChatPartner) {
        loadMessages();
      } else {
        showToast('New message received', 'info');
      }
    })
    .subscribe((status) => {
      if (status === 'SUBSCRIPTION_ERROR') {
        console.warn('[Realtime] Messages subscription error - messages may not update in real-time');
      }
    });
}

async function sendMessage() {
  const input = document.getElementById('chat-input');
  const content = input.value.trim();
  if (!content || !currentChatPartner) return;

  await supabaseClient.from('messages').insert({
    sender_id: currentUser.id,
    receiver_id: currentChatPartner,
    booking_id: currentChatBookingId,
    content,
  });

  input.value = '';
  loadMessages();
}

// ─────────────────── Profile ─────────────────────────────────────

function showProfileScreen() {
  document.querySelectorAll(".screen").forEach(s => s.classList.remove("active"));
  document.getElementById("screen-profile").classList.add("active");
  updateActiveNav("profile");
  if (!currentUserProfile && currentUser) {
    loadUserProfile().then(() => renderProfile()).catch(() => renderProfile());
  } else {
    renderProfile();
  }
}

function renderProfile() {
  const container = document.getElementById('profile-content');
  if (!container) return;

  const name = currentUserProfile?.full_name || currentUser?.email?.split('@')[0] || 'User';
  const initials = name.split(' ').map(w => w[0]).join('').toUpperCase().slice(0, 2);
  const email = currentUser?.email || '';
  const phone = currentUserProfile?.phone || '';
  const photoUrl = currentUserProfile?.avatar_url || '';
  const isFixer = !!currentFixerProfile;
  const memberSince = new Date(currentUser?.created_at || Date.now()).toLocaleDateString('en-ZA', { month: 'short', year: 'numeric' });
  const emailVerified = !!currentUser?.email_confirmed_at;

  const avatarInner = photoUrl
    ? `<img src="${escapeHtml(photoUrl)}" onerror="this.outerHTML='${initials}'" style="width:100%;height:100%;object-fit:cover;border-radius:50%">`
    : initials;

  container.innerHTML = `
    <!-- Hero -->
    <div class="profile-hero" style="padding-bottom:32px">
      <div style="position:absolute;top:-30px;right:-30px;width:160px;height:160px;border-radius:50%;background:radial-gradient(circle,rgba(201,148,58,.15) 0%,transparent 70%);pointer-events:none"></div>
      <div style="position:absolute;bottom:0;left:-20px;width:100px;height:100px;border-radius:50%;background:radial-gradient(circle,rgba(201,148,58,.08) 0%,transparent 70%);pointer-events:none"></div>
      <div class="profile-avatar-ring" onclick="document.getElementById('profile-photo-input').click()" style="width:82px;height:82px;font-size:30px;box-shadow:0 4px 20px rgba(0,0,0,.25)">
        ${avatarInner}
        <div class="profile-camera-badge" style="width:26px;height:26px;font-size:11px;bottom:0;right:0">📷</div>
        <input type="file" id="profile-photo-input" accept="image/*" style="display:none" onchange="uploadProfilePhoto(this)">
      </div>
      <h3 style="font-family:'Playfair Display',serif;font-size:22px;font-weight:700;color:#fff;margin-bottom:4px;margin-top:2px">${escapeHtml(name)}</h3>
      <p style="font-size:12px;color:rgba(255,255,255,.55);margin-bottom:14px">${escapeHtml(email)}</p>
      <div style="display:flex;gap:6px;justify-content:center;flex-wrap:wrap">
        ${emailVerified ? '<span style="background:rgba(255,255,255,.13);backdrop-filter:blur(8px);color:rgba(255,255,255,.9);font-size:10px;font-weight:600;padding:4px 12px;border-radius:20px;border:1px solid rgba(255,255,255,.15)">✅ Verified</span>' : ''}
        ${isFixer ? '<span style="background:rgba(201,148,58,.25);color:var(--gold-light);font-size:10px;font-weight:700;padding:4px 12px;border-radius:20px;border:1px solid rgba(201,148,58,.35)">🔧 Fixer</span>' : `<span style="background:rgba(255,255,255,.13);color:rgba(255,255,255,.8);font-size:10px;font-weight:600;padding:4px 12px;border-radius:20px;border:1px solid rgba(255,255,255,.15)">Member since ${memberSince}</span>`}
      </div>
    </div>

    <!-- Stats row -->
    <div class="profile-stats-row" id="profile-stats" style="box-shadow:0 2px 12px rgba(28,26,22,.06)">
      <div class="profile-stat-cell">
        <div class="profile-stat-val" id="stat-jobs" style="font-size:22px">
          <span class="skeleton" style="display:inline-block;width:24px;height:22px;border-radius:4px"></span>
        </div>
        <div class="profile-stat-label">${isFixer ? 'Jobs Done' : 'Bookings'}</div>
      </div>
      <div class="profile-stat-cell">
        <div class="profile-stat-val" id="stat-spend" style="font-size:18px">
          <span class="skeleton" style="display:inline-block;width:48px;height:20px;border-radius:4px"></span>
        </div>
        <div class="profile-stat-label">${isFixer ? 'Earned' : 'Total Spent'}</div>
      </div>
      <div class="profile-stat-cell">
        <div class="profile-stat-val" id="stat-rating" style="font-size:22px">${isFixer ? (currentFixerProfile?.rating?.toFixed(1) || '—') : '0'}</div>
        <div class="profile-stat-label">${isFixer ? 'Avg Rating' : 'Disputes'}</div>
      </div>
    </div>

    <!-- Quick links -->
    <div style="background:var(--warm-white);border-bottom:8px solid var(--cream)">
      ${isFixer ? `
        <div class="profile-menu-item" onclick="navigate('home')" style="padding:16px">
          <div class="profile-menu-icon" style="background:linear-gradient(135deg,#E8F5EE,#D4EDDA);width:42px;height:42px;border-radius:var(--r-md)">🔧</div>
          <div style="flex:1">
            <p class="profile-menu-label" style="font-size:15px">Fixer Dashboard</p>
            <p class="profile-menu-sub">Jobs, earnings & availability</p>
          </div>
          <span class="profile-menu-arrow" style="font-size:20px;color:var(--text-muted)">›</span>
        </div>` : ''}
      <div class="profile-menu-item" onclick="navigate('bookings')" style="padding:16px">
        <div class="profile-menu-icon" style="background:linear-gradient(135deg,#E8F5EE,#D4EDDA);width:42px;height:42px;border-radius:var(--r-md)">📋</div>
        <div style="flex:1">
          <p class="profile-menu-label" style="font-size:15px">My Bookings</p>
          <p class="profile-menu-sub">Active & past jobs</p>
        </div>
        <span class="profile-menu-arrow" style="font-size:20px;color:var(--text-muted)">›</span>
      </div>
    </div>

    <!-- Account section -->
    <div style="padding:16px 16px 8px"><p style="font-size:10px;font-weight:700;color:var(--text-muted);letter-spacing:.8px;text-transform:uppercase">Account</p></div>

    <div style="background:var(--warm-white);border-top:1px solid var(--border);border-bottom:1px solid var(--border);padding:18px 16px;margin-bottom:8px">
      <p style="font-size:11px;font-weight:700;color:var(--forest);text-transform:uppercase;letter-spacing:.6px;margin-bottom:14px">Personal Details</p>
      <div style="margin-bottom:12px">
        <label style="font-size:12px;font-weight:600;color:var(--text-mid);display:block;margin-bottom:6px">Full Name</label>
        <input class="input" id="profile-name" value="${escapeHtml(name)}" placeholder="Your full name" style="width:100%;font-size:14px;padding:12px 14px;border:1.5px solid var(--border);border-radius:var(--r-md);background:var(--cream);font-family:'DM Sans',sans-serif;outline:none">
      </div>
      <div style="margin-bottom:12px">
        <label style="font-size:12px;font-weight:600;color:var(--text-mid);display:block;margin-bottom:6px">Phone / WhatsApp</label>
        <input class="input" id="profile-phone" type="tel" value="${escapeHtml(phone)}" placeholder="+27 XX XXX XXXX" style="width:100%;font-size:14px;padding:12px 14px;border:1.5px solid var(--border);border-radius:var(--r-md);background:var(--cream);font-family:'DM Sans',sans-serif;outline:none">
      </div>
      <div style="margin-bottom:16px">
        <label style="font-size:12px;font-weight:600;color:var(--text-mid);display:block;margin-bottom:6px">Email</label>
        <div style="padding:12px 14px;border:1.5px solid var(--border);border-radius:var(--r-md);background:var(--cream);font-size:14px;color:var(--text-muted);display:flex;align-items:center;gap:8px">
          ${emailVerified ? '<span style="color:var(--success);font-size:12px">✅</span>' : ''}
          ${escapeHtml(email)}
        </div>
      </div>
      <button class="btn btn-primary" onclick="saveProfileDetails()" style="width:100%;padding:13px;font-size:14px">Save Changes</button>
    </div>

    <div style="background:var(--warm-white);border-top:1px solid var(--border);border-bottom:1px solid var(--border);padding:18px 16px;margin-bottom:8px">
      <p style="font-size:11px;font-weight:700;color:var(--forest);text-transform:uppercase;letter-spacing:.6px;margin-bottom:14px">Saved Addresses</p>
      <div style="margin-bottom:12px">
        <label style="font-size:12px;font-weight:600;color:var(--text-mid);display:block;margin-bottom:6px">🏠 Home Address</label>
        <input class="input" id="profile-address-home" value="${escapeHtml(currentUserProfile?.address_home || '')}" placeholder="e.g. 12 Oak Street, Sandton" style="width:100%;font-size:14px;padding:12px 14px;border:1.5px solid var(--border);border-radius:var(--r-md);background:var(--cream);font-family:'DM Sans',sans-serif;outline:none">
      </div>
      <div style="margin-bottom:16px">
        <label style="font-size:12px;font-weight:600;color:var(--text-mid);display:block;margin-bottom:6px">💼 Work Address <span style="font-weight:400;color:var(--text-muted)">(optional)</span></label>
        <input class="input" id="profile-address-work" value="${escapeHtml(currentUserProfile?.address_work || '')}" placeholder="e.g. 45 Main Road, Rosebank" style="width:100%;font-size:14px;padding:12px 14px;border:1.5px solid var(--border);border-radius:var(--r-md);background:var(--cream);font-family:'DM Sans',sans-serif;outline:none">
      </div>
      <button class="btn btn-outline" onclick="saveProfileAddresses()" style="width:100%;padding:13px;font-size:14px">Save Addresses</button>
    </div>

    <!-- Settings section -->
    <div style="padding:16px 16px 8px"><p style="font-size:10px;font-weight:700;color:var(--text-muted);letter-spacing:.8px;text-transform:uppercase">Settings</p></div>

    <div style="background:var(--warm-white);border-top:1px solid var(--border);border-bottom:1px solid var(--border);margin-bottom:8px">
      <div class="profile-menu-item" onclick="showPaymentMethodsInfo()" style="padding:16px;cursor:pointer">
        <div class="profile-menu-icon" style="background:linear-gradient(135deg,#E8F0FA,#D4E4F7);width:42px;height:42px;border-radius:var(--r-md)">💳</div>
        <div style="flex:1">
          <p class="profile-menu-label" style="font-size:15px">Payment Methods</p>
          <p class="profile-menu-sub">Pay via Yoco · Card & EFT</p>
        </div>
        <span class="profile-menu-arrow" style="font-size:20px;color:var(--text-muted)">›</span>
      </div>
      <div class="profile-menu-item" onclick="requestPushPermission()" style="padding:16px;cursor:pointer">
        <div class="profile-menu-icon" style="background:linear-gradient(135deg,#FDF3E0,#FAE4B8);width:42px;height:42px;border-radius:var(--r-md)">🔔</div>
        <div style="flex:1">
          <p class="profile-menu-label" style="font-size:15px">Push Notifications</p>
          <p class="profile-menu-sub" id="notif-status">Tap to enable</p>
        </div>
        <span style="font-size:12px;font-weight:600;color:var(--gold-dark);padding:5px 12px;background:var(--cream-dark);border-radius:20px">Manage</span>
      </div>
      <div class="profile-menu-item" onclick="requestLocationPermission()" style="padding:16px;cursor:pointer">
        <div class="profile-menu-icon" style="background:linear-gradient(135deg,#E8F5EE,#D4EDDA);width:42px;height:42px;border-radius:var(--r-md)">📍</div>
        <div style="flex:1">
          <p class="profile-menu-label" style="font-size:15px">Location Services</p>
          <p class="profile-menu-sub" id="location-status">Used to match nearby fixers</p>
        </div>
        <span style="font-size:12px;font-weight:600;color:var(--gold-dark);padding:5px 12px;background:var(--cream-dark);border-radius:20px">Manage</span>
      </div>
      <div class="profile-menu-item" onclick="window.open('https://wa.me/27782629774?text=Hi+Servit+Support','_blank')" style="padding:16px;cursor:pointer">
        <div class="profile-menu-icon" style="background:linear-gradient(135deg,#E8F5EE,#D4EDDA);width:42px;height:42px;border-radius:var(--r-md)">💬</div>
        <div style="flex:1">
          <p class="profile-menu-label" style="font-size:15px">Help & Support</p>
          <p class="profile-menu-sub">Chat with us on WhatsApp</p>
        </div>
        <span class="profile-menu-arrow" style="font-size:20px;color:var(--text-muted)">›</span>
      </div>
    </div>

    <!-- Sign out -->
    <div style="padding:16px 16px 32px">
      <button class="btn btn-block" onclick="signOut()" style="background:transparent;border:1.5px solid var(--danger);color:var(--danger);padding:14px;font-size:14px;border-radius:var(--r-md);transition:all .2s">
        🚪 Sign Out
      </button>
      <p style="font-size:11px;text-align:center;color:var(--text-muted);margin-top:14px">
        Servit v6.5 · <span style="color:var(--gold-dark);cursor:pointer" onclick="window.open('https://servit.co.za/privacy','_blank')">Privacy Policy</span> · <span style="color:var(--gold-dark);cursor:pointer" onclick="window.open('https://servit.co.za/terms','_blank')">Terms</span>
      </p>
    </div>
  `;

  // Load stats async — graceful on 500/403
  (async () => {
    if (!currentUser) return;
    try {
      const { data: bks } = await supabaseClient
        .from('bookings')
        .select('id,customer_total,status')
        .eq('customer_id', currentUser.id);
      const el1 = document.getElementById('stat-jobs');
      if (el1) el1.textContent = bks?.length ?? 0;
      const spent = (bks || []).filter(b => b.status === 'COMPLETED').reduce((s, b) => s + (b.customer_total || 0), 0);
      const el2 = document.getElementById('stat-spend');
      if (el2) el2.textContent = 'R' + Math.round(spent).toLocaleString();
    } catch {
      const el1 = document.getElementById('stat-jobs'); if (el1) el1.textContent = '—';
      const el2 = document.getElementById('stat-spend'); if (el2) el2.textContent = '—';
    }
  })();
}

async function saveProfileDetails() {
  if (!currentUser) { showToast('Not logged in — please sign in again', 'error'); return; }
  const name = document.getElementById('profile-name')?.value?.trim();
  const phone = document.getElementById('profile-phone')?.value?.trim();
  if (!name) { showToast('Name cannot be empty', 'error'); return; }
  const btn = document.querySelector('#profile-content .btn-primary');
  if (btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
  try {
    const { error } = await supabaseClient.from('profiles').update({ full_name: name, phone }).eq('id', currentUser.id);
    if (error) { showToast('Could not save — try again', 'error'); return; }
    if (currentUserProfile) { currentUserProfile.full_name = name; currentUserProfile.phone = phone; }
    showToast('Profile updated ✓', 'success');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Save Changes'; }
  }
}

async function saveProfileAddresses() {
  if (!currentUser) { showToast('Not logged in — please sign in again', 'error'); return; }
  const home = document.getElementById('profile-address-home')?.value?.trim();
  const work = document.getElementById('profile-address-work')?.value?.trim();
  const btn = document.querySelector('#profile-content .btn-outline');
  if (btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
  try {
    const { error } = await supabaseClient.from('profiles').update({ address_home: home, address_work: work }).eq('id', currentUser.id);
    if (error) { showToast('Could not save — try again', 'error'); return; }
    if (currentUserProfile) { currentUserProfile.address_home = home; currentUserProfile.address_work = work; }
    showToast('Addresses saved ✓', 'success');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Save Addresses'; }
  }
}
window.saveProfileDetails = saveProfileDetails;
window.saveProfileAddresses = saveProfileAddresses;

// ─────────────────── Authentication ──────────────────────────────

async function initAuth() {
  // CRITICAL FIX: Preserve payment return params BEFORE any auth redirect can clear them.
  // Yoco redirects back to /?payment=success&booking_id=XXX — if the Supabase session
  // has expired, getSession() returns null → showAuthScreen() is called → the URL is
  // never cleaned up but the payment screen never shows. We stash the params in
  // sessionStorage so they survive a sign-in flow.
  const _initParams = new URLSearchParams(window.location.search);
  const _initPayment = _initParams.get('payment');
  const _initBookingId = _initParams.get('booking_id');
  if (_initPayment) {
    try {
      sessionStorage.setItem('servit_pending_payment', _initPayment);
      if (_initBookingId) sessionStorage.setItem('servit_pending_booking_id', _initBookingId);
    } catch (_) {}
    // Clean the URL immediately so refreshing doesn't re-trigger
    window.history.replaceState({}, '', '/');
  }

  // Track whether showApp has been called from getSession() so the
  // onAuthStateChange SIGNED_IN event (which Supabase ALSO fires on page load
  // when a session exists) doesn't call showApp() a second time and clobber
  // the payment-return flow that the first showApp() just launched.
  let _initialShowAppDone = false;

  const { data: { session } } = await supabaseClient.auth.getSession();
  if (session?.user) {
    currentUser = session.user;
    window.currentUser = currentUser; // expose for marketplace.js
    await loadUserProfile();
    showApp();
    _initialShowAppDone = true;
    window.dispatchEvent(new CustomEvent('servit:user-ready', { detail: { user: currentUser } }));
  } else {
    showAuthScreen();
  }

  supabaseClient.auth.onAuthStateChange(async (event, session) => {
    if (event === 'SIGNED_IN' && session?.user) {
      // Skip the duplicate SIGNED_IN that fires immediately after getSession()
      // on page load — we already called showApp() above.
      if (_initialShowAppDone) {
        _initialShowAppDone = false; // only skip once; future sign-ins are real
        return;
      }
      currentUser = session.user;
      window.currentUser = currentUser; // expose for marketplace.js
      await loadUserProfile();
      showApp();
      window.dispatchEvent(new CustomEvent('servit:user-ready', { detail: { user: currentUser } }));
    } else if (event === 'SIGNED_OUT') {
      currentUser = null;
      window.currentUser = null; // clear for marketplace.js
      currentUserProfile = null;
      currentFixerProfile = null;
      teardownBookingSubscription();
      stopFixerHeartbeat(); // IMPROVEMENT 2: stop pinging when signed out
      if (demandAlertChannel) { supabaseClient.removeChannel(demandAlertChannel); demandAlertChannel = null; }
      showAuthScreen();
    }
  });
}

// FIX: was querying pro_profiles — now queries fixers table
async function loadUserProfile() {
  const { data: profile } = await supabaseClient
    .from('profiles')
    .select('*')
    .eq('id', currentUser.id)
    .maybeSingle();
  currentUserProfile = profile;

  // Detect admin — is_admin DB flag OR user_role column OR Supabase app_metadata
  // NOTE: email-domain fallback removed — it granted admin UI to any @servit.co.za
  // registrant regardless of their actual role, leaking booking/user data.
  const isAdmin = profile?.is_admin === true || profile?.user_role === 'admin'
    || currentUser?.app_metadata?.role === 'admin';
  currentAdminProfile = isAdmin ? profile : null;

  const { data: fixer } = await supabaseClient
    .from('fixers')
    .select('*')
    .eq('user_id', currentUser.id)
    .maybeSingle();
  currentFixerProfile = fixer || null;

  // If fixer, subscribe to incoming offers AND demand alerts
  if (currentFixerProfile) {
    subscribeToFixerOffers(currentFixerProfile.id);
    subscribeToFixerDemandAlerts(currentUser.id);
  }

  // Notify addon scripts (marketplace.js etc.) that app globals are ready.
  // Fired after every sign-in, including page reload with an existing session.
  window.dispatchEvent(new CustomEvent('servit:app-ready', { detail: { user: currentUser } }));
}

let _splashHidden = false;
function hideSplash() {
  if (_splashHidden) return;
  _splashHidden = true;
  const splash = document.getElementById('splash-screen');
  if (!splash) return;
  // Uber-style: let the bar finish (2s min on screen), then fade out over 400ms
  const elapsed = Date.now() - window._splashStart;
  const minDuration = 1500; // FIX H-06: Reduced from 2200ms — splash should be fast, not decorative
  const delay = Math.max(0, minDuration - elapsed);
  setTimeout(() => {
    splash.style.transition = 'opacity 0.4s ease';
    splash.style.opacity = '0';
    splash.style.pointerEvents = 'none';
    setTimeout(() => { splash.style.display = 'none'; }, 420);
  }, delay);
}

// ─────────────────────────────────────────────────────────────────────────────
// resumeActiveBookingIfAny
// Called from showApp() when there is no ?payment= URL param.
// Checks if the authenticated customer has an active booking in the DB and
// resumes the correct UI state for it, so closing/reopening the app or
// clicking the confirmation email link never strands the customer on the home screen.
//
// PERF FIX (v8.9.2): Previous implementation made 3 sequential Supabase queries
// (active → expired → pending-payment).  On a 100ms Cape Town↔EU RTT this added
// 200-300ms of dead wait on every app open for users without an active booking
// (the common case).  All three queries now run in parallel via Promise.all with
// priority-ordered early-exit: active > expired > pending.
// ─────────────────────────────────────────────────────────────────────────────
async function resumeActiveBookingIfAny() {
  const activeStatuses  = ['SEARCHING', 'OFFERED', 'CONFIRMED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS', 'PENDING_COMPLETION'];
  const twoHoursAgo    = new Date(Date.now() - 2  * 60 * 60 * 1000).toISOString();
  const fifteenMinsAgo = new Date(Date.now() - 15 * 60 * 1000).toISOString();

  try {
    // Fire all three queries in parallel — eliminates 200-300ms sequential penalty
    const [activeRes, expiredRes, pendingRes] = await Promise.all([

      // 1. Fully active booking (post-payment, has a fixer or searching)
      supabaseClient
        .from('bookings')
        .select('id, status, payment_status, category')
        .eq('customer_id', currentUser.id)
        .in('status', activeStatuses)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle(),

      // 2. Recently EXPIRED booking (within 2h) — show refund info not home screen
      supabaseClient
        .from('bookings')
        .select('id, status, payment_status, category')
        .eq('customer_id', currentUser.id)
        .eq('status', 'EXPIRED')
        .eq('payment_status', 'paid')
        .gte('updated_at', twoHoursAgo)
        .order('updated_at', { ascending: false })
        .limit(1)
        .maybeSingle(),

      // 3. PENDING_PAYMENT/CREATED booking in the Yoco webhook race window (0-30s).
      // FIX (v8.9 BUG 2): match payment_status='paid' OR recently-created so we
      // don't lose customers who reopen during the 2-30s webhook delay.
      supabaseClient
        .from('bookings')
        .select('id, status, payment_status')
        .eq('customer_id', currentUser.id)
        .in('status', ['PENDING_PAYMENT', 'CREATED'])
        .or(`payment_status.eq.paid,created_at.gte.${fifteenMinsAgo}`)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle(),
    ]);

    const booking   = activeRes.data;
    const expiredBk = expiredRes.data;
    const pendingBk = pendingRes.data;

    // Priority: active > expired > pending (matches original sequential priority)
    if (booking) {
      currentBookingId = booking.id;
      if (booking.status === 'SEARCHING' || booking.status === 'OFFERED') {
        showWaitingScreen(booking.id);
        subscribeToBookingStatus(booking.id, handleBookingStatusChange);
      } else {
        loadActiveJob(booking.id);
      }
      return;
    }

    if (expiredBk) {
      currentBookingId = expiredBk.id;
      showBookingExpiredScreen(expiredBk);
      return;
    }

    if (pendingBk) {
      showPaymentSuccessScreen(pendingBk.id);
      return;
    }

  } catch (e) {
    console.warn('[Servit] resumeActiveBookingIfAny failed (non-fatal):', e.message);
  }
  // No active booking found — show normal home screen
  showHomeScreen();
  if (!currentFixerProfile && !currentAdminProfile) maybeShowWelcome();
}

function _showFixerPendingHome() {
  showHomeScreen();
  // Remove any existing pending banner before inserting a fresh one
  document.getElementById('fixer-pending-banner')?.remove();
  const banner = document.createElement('div');
  banner.id = 'fixer-pending-banner';
  banner.style.cssText = 'background:linear-gradient(135deg,var(--forest),var(--forest-mid));color:#fff;padding:14px 16px;display:flex;align-items:flex-start;gap:12px;margin:12px 16px;border-radius:var(--r-lg);box-shadow:0 2px 12px rgba(0,0,0,.15)';
  const name = currentUserProfile?.full_name?.split(' ')[0] || 'there';
  banner.innerHTML = `
    <span style="font-size:24px;flex-shrink:0">🔧</span>
    <div style="flex:1">
      <p style="font-weight:700;font-size:14px;margin-bottom:4px">Hi ${escapeHtml(name)}, your Fixer account is under review</p>
      <p style="font-size:12px;color:rgba(255,255,255,.8);line-height:1.5">We review all fixer applications within <strong>48 hours</strong>. You'll receive a WhatsApp message once approved. Need help? <span style="color:var(--gold-light);text-decoration:underline;cursor:pointer" onclick="window.open('https://wa.me/27782629774?text=Hi+Servit,+my+fixer+account+is+pending+approval','_blank')">Contact support</span>.</p>
    </div>
    <span style="cursor:pointer;opacity:.6;font-size:18px;flex-shrink:0;align-self:flex-start;padding-top:2px" onclick="document.getElementById('fixer-pending-banner')?.remove()">✕</span>
  `;
  // Insert after the home screen topbar / hero area
  const homeScreen = document.getElementById('screen-home');
  if (homeScreen) homeScreen.insertAdjacentElement('afterbegin', banner);
}

async function showApp() {
  hideSplash();
  const authOverlay = document.getElementById('auth-overlay');
  if (authOverlay) authOverlay.classList.add('hidden');
  const mainApp = document.getElementById('main-app');
  if (mainApp) mainApp.style.display = '';
  // Route by role: admin > fixer > customer
  if (currentAdminProfile) showAdminDashboard();
  else if (currentFixerProfile) showFixerDashboard();
  else {
    // Check if user registered as fixer but hasn't been approved yet.
    // In that case, show the customer home screen but display a clear
    // pending-approval notice so they know their role.
    if (currentUserProfile?.user_role === 'fixer') {
      _showFixerPendingHome();
      return;
    }
    // FIX: Check payment return AFTER auth resolves so the Supabase realtime
    // subscription is established with an active session.
    // Also check sessionStorage for params saved by initAuth() in case the
    // Yoco redirect arrived while the session was expired (causing a sign-in flow).
    const params = new URLSearchParams(window.location.search);
    const pendingPayment = params.get('payment') || (() => {
      try { return sessionStorage.getItem('servit_pending_payment'); } catch (_) { return null; }
    })();
    const pendingBookingId = params.get('booking_id') || (() => {
      try { return sessionStorage.getItem('servit_pending_booking_id'); } catch (_) { return null; }
    })();
    if (pendingPayment) {
      // Clear sessionStorage stash now that we're processing it
      try { sessionStorage.removeItem('servit_pending_payment'); sessionStorage.removeItem('servit_pending_booking_id'); } catch (_) {}
      // Re-inject into URL search so checkPaymentReturn() can read them normally
      if (!params.get('payment')) {
        const syntheticParams = new URLSearchParams({ payment: pendingPayment });
        if (pendingBookingId) syntheticParams.set('booking_id', pendingBookingId);
        window.history.replaceState({}, '', '/?' + syntheticParams.toString());
      }
      checkPaymentReturn();
    } else {
      // FIX: Before showing home screen, check if this customer has an active
      // booking in progress (SEARCHING, OFFERED, CONFIRMED, EN_ROUTE, etc.).
      // This handles: app closed and reopened, email link clicked, page refresh.
      // Without this, a customer whose payment succeeded but app was closed sees
      // the home screen with their money taken and no way to track the job.
      await resumeActiveBookingIfAny();
    }
  }
}

// Expose to window
window.showAdminDashboard = function() {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  const screen = document.getElementById('screen-admin');
  if (screen) { screen.classList.add('active'); renderAdminDashboard(); }
  else showHomeScreen();
};
window.showApp = showApp;

function showAuthScreen() {
  hideSplash();
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  const authOverlay = document.getElementById('auth-overlay');
  if (authOverlay) authOverlay.classList.remove('hidden');
  const mainApp = document.getElementById('main-app');
  if (mainApp) mainApp.style.display = 'none';

  // FIX (Audit C1): Show welcome slides BEFORE the signup wall for first-time visitors.
  // Previously maybeShowWelcome() only fired post-login inside showApp() — meaning
  // a visitor who had never used the app saw no value prop before being asked to register.
  const introKey = 'servit_seen_intro';
  if (!localStorage.getItem(introKey)) {
    localStorage.setItem(introKey, '1');
    setTimeout(() => showWelcomeFlow(true), 400); // true = pre-auth mode
  }
}

async function _appSignIn(email, password) {
  const { error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) { showToast(friendlyAuthError(error.message), 'error'); return false; }
  trackEvent('sign_in');
  return true;
}

async function _appSignUp(name, email, phone, password, role) {
  const msgEl = document.getElementById('auth-msg');
  if (msgEl) { msgEl.textContent = ''; msgEl.className = 'auth-msg'; }

  const { data, error } = await supabaseClient.auth.signUp({
    email, password,
    options: { data: { full_name: name, phone, user_role: role } },
  });

  if (error) {
    const msg = friendlyAuthError(error.message);
    if (msgEl) { msgEl.textContent = msg; msgEl.className = 'auth-msg error'; }
    showToast(msg, 'error');
    return false;
  }

  trackEvent('sign_up', { role });

  // Supabase returns identities=[] when email is already registered but unconfirmed.
  // In that case signUp() succeeds silently — detect it and tell the user.
  const alreadyExists = data?.user && (!data.user.identities || data.user.identities.length === 0);
  if (alreadyExists) {
    const msg = 'An account with this email already exists. Try signing in instead, or use "Forgot password?" to reset your password.';
    if (msgEl) { msgEl.textContent = msg; msgEl.className = 'auth-msg error'; }
    return false;
  }

  if (role === 'fixer') {
    // Fixer: show 48-hour review screen (existing logic)
    const authOverlay = document.getElementById('auth-overlay');
    if (authOverlay) authOverlay.classList.add('hidden');
    const overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;inset:0;background:var(--forest);z-index:99998;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:32px;text-align:center;animation:fadeIn .3s ease;overflow-y:auto';
    overlay.innerHTML = `
      <div style="width:80px;height:80px;border-radius:50%;background:var(--gold);display:flex;align-items:center;justify-content:center;font-size:36px;margin-bottom:20px;box-shadow:0 8px 32px rgba(0,0,0,.25)">🎉</div>
      <p style="font-family:'Playfair Display',serif;font-size:24px;font-weight:700;color:#fff;margin-bottom:10px;max-width:300px">Application received!</p>
      <p style="font-size:14px;color:rgba(255,255,255,.75);line-height:1.7;max-width:320px;margin-bottom:20px">
        We review all fixer applications within <strong style="color:var(--gold-light)">48 hours</strong>. You'll receive a WhatsApp message on <strong style="color:var(--gold-light)">${escapeHtml(phone || 'your number')}</strong> once you're approved.
      </p>
      <div style="background:rgba(255,255,255,.1);border-radius:var(--r-lg);padding:16px 20px;max-width:320px;width:100%;margin-bottom:20px;text-align:left">
        <p style="font-size:11px;font-weight:700;color:var(--gold-light);text-transform:uppercase;letter-spacing:.6px;margin-bottom:10px">Important — do this now</p>
        <p style="font-size:13px;color:#fff;margin-bottom:8px;font-weight:600">📧 Check your email for a confirmation link</p>
        <p style="font-size:12px;color:rgba(255,255,255,.75);margin-bottom:6px">An email was sent to <strong>${escapeHtml(email)}</strong>. You must click the link to activate your account before we can process your application.</p>
        <p style="font-size:12px;color:rgba(255,255,255,.65)">Also check your spam / junk folder if you don't see it within 2 minutes.</p>
      </div>
      <div style="background:rgba(255,255,255,.07);border-radius:var(--r-lg);padding:14px 18px;max-width:320px;width:100%;margin-bottom:24px;text-align:left">
        <p style="font-size:11px;font-weight:700;color:var(--gold-light);text-transform:uppercase;letter-spacing:.6px;margin-bottom:8px">While you wait</p>
        <p style="font-size:13px;color:rgba(255,255,255,.8);margin-bottom:4px">✓ Make sure WhatsApp is active on ${escapeHtml(phone || 'your number')}</p>
        <p style="font-size:13px;color:rgba(255,255,255,.8)">✓ Our team will contact you if we need more info</p>
      </div>
      <button class="btn btn-gold btn-block" style="max-width:320px;padding:15px;font-size:15px" onclick="this.closest('div[style]').remove()">
        Got it — I'll check my email →
      </button>`;
    document.body.appendChild(overlay);

  } else {
    // Customer: show a persistent confirmation screen (not just a 3-second toast)
    const authOverlay = document.getElementById('auth-overlay');
    const authCard = document.querySelector('.auth-card');
    if (authCard) {
      authCard.innerHTML = `
        <div style="text-align:center;padding:8px 0 16px">
          <div style="font-size:56px;margin-bottom:16px">📧</div>
          <p style="font-family:'Playfair Display',serif;font-size:22px;font-weight:700;color:var(--text-dark);margin-bottom:10px">Check your email!</p>
          <p style="font-size:14px;color:var(--text-mid);line-height:1.7;margin-bottom:16px">
            We sent a confirmation link to<br>
            <strong style="color:var(--forest)">${escapeHtml(email)}</strong>
          </p>
          <div style="background:var(--cream);border:1.5px solid var(--gold);border-radius:var(--r-md);padding:14px 16px;margin-bottom:20px;text-align:left">
            <p style="font-size:12px;font-weight:700;color:var(--gold-dark);margin-bottom:8px">👇 What to do next</p>
            <p style="font-size:13px;color:var(--text-mid);margin-bottom:6px;line-height:1.5"><strong>1.</strong> Open the email from Servit</p>
            <p style="font-size:13px;color:var(--text-mid);margin-bottom:6px;line-height:1.5"><strong>2.</strong> Click the <strong>"Confirm your email"</strong> link</p>
            <p style="font-size:13px;color:var(--text-mid);line-height:1.5"><strong>3.</strong> You'll be signed in automatically</p>
          </div>
          <p style="font-size:12px;color:var(--text-muted);margin-bottom:16px;line-height:1.6">
            ⚠️ Can't find it? Check your <strong>spam / junk</strong> folder.<br>
            The email comes from <strong>noreply@mail.supabase.io</strong>
          </p>
          <button class="btn btn-outline btn-block" style="font-size:13px;color:var(--text-muted);border-color:var(--border);margin-bottom:10px" onclick="
            document.querySelector('.auth-card').innerHTML = '<p style=\\'text-align:center;padding:20px;color:var(--text-muted);font-size:13px\\'>Refreshing…</p>';
            window.location.reload();
          ">Already confirmed? Sign in →</button>
          <button class="btn btn-block" style="background:transparent;border:none;font-size:12px;color:var(--text-muted);cursor:pointer" data-resend-email="${escapeHtml(email)}" onclick="
            const btn = this;
            const emailAddr = btn.getAttribute('data-resend-email');
            const sp = document.getElementById('auth-spinner');
            if(sp){sp.style.display='block';sp.textContent='Resending…';}
            window.db.auth.resend({type:'signup',email:emailAddr}).then(()=>{
              if(sp)sp.style.display='none';
              alert('Confirmation email resent! Check your inbox (and spam folder).');
            }).catch(err=>{
              if(sp)sp.style.display='none';
              alert('Failed to resend email: ' + (err.message || 'Unknown error'));
            });
          ">Resend confirmation email</button>
        </div>`;
    }
  }
  return true;
}

async function signOut() {
  await supabaseClient.auth.signOut();
  showToast('Signed out');
}

// ─────────────────── Home screen ─────────────────────────────────

// First 9 shown on home screen; all shown in "See all" sheet
// service_type:
//   'mobile' — provider travels to customer (plumber, cleaner, etc.)
//              customer provides their address + sets their own budget
//   'venue'  — customer travels to provider (salon, tattoo, gym, etc.)
//              provider's studio address is used; provider sets fixed price
const CATEGORIES = [
  { id: 'Cleaning',             emoji: '🧹', label: 'Cleaning',    type: 'mobile' },
  { id: 'Plumbing',             emoji: '🔧', label: 'Plumbing',    type: 'mobile' },
  { id: 'Electrical',           emoji: '⚡', label: 'Electrical',  type: 'mobile' },
  { id: 'Beauty & Wellness',    emoji: '💅', label: 'Beauty',      type: 'venue'  },
  { id: 'Garden & Landscaping', emoji: '🌿', label: 'Garden',      type: 'mobile' },
  { id: 'IT Support',           emoji: '💻', label: 'IT Support',  type: 'mobile' },
  { id: 'Moving & Deliveries',  emoji: '📦', label: 'Moving',      type: 'mobile' },
  { id: 'Painting & Decorating',emoji: '🎨', label: 'Painting',    type: 'mobile' },
  { id: 'Tutoring & Education', emoji: '📚', label: 'Tutoring',    type: 'mobile' },
  // Extra — only visible in "See all"
  { id: 'Carpentry',            emoji: '🪚', label: 'Carpentry',   type: 'mobile' },
  { id: 'Appliance Repair',     emoji: '🔌', label: 'Appliances',  type: 'mobile' },
  { id: 'Hair & Barbering',     emoji: '✂️', label: 'Hair',        type: 'venue'  },
  { id: 'Tattoos & Piercing',   emoji: '🖊️', label: 'Tattoos',     type: 'venue'  },
  { id: 'Personal Training',    emoji: '💪', label: 'Training',    type: 'venue'  },
  { id: 'Photography',          emoji: '📸', label: 'Photography', type: 'mobile' },
  { id: 'Security',             emoji: '🔒', label: 'Security',    type: 'mobile' },
  { id: 'Pest Control',         emoji: '🐛', label: 'Pest Control',type: 'mobile' },
  { id: 'Catering',             emoji: '🍽️', label: 'Catering',    type: 'mobile' },
  { id: 'Child Minding',        emoji: '👶', label: 'Child Care',  type: 'mobile' },
  { id: 'Other',                emoji: '⭐', label: 'Other',       type: 'mobile' },
];

// Helper — look up service type for a category id
function getCategoryType(categoryId) {
  return CATEGORIES.find(c => c.id === categoryId)?.type || 'mobile';
}

function showHomeScreen() {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-home').classList.add('active');
  updateActiveNav('home');
  loadCategories();
  loadFixers();
  updateHomeGreeting();
  updateHomeAvatar();
  loadReferralCard();
  _updateRoleBadge();
  // Show location prompt if permission not already granted
  if (navigator.permissions) {
    navigator.permissions.query({ name: 'geolocation' }).then(perm => {
      const prompt = document.getElementById('location-prompt');
      if (prompt) prompt.style.display = perm.state === 'granted' ? 'none' : 'flex';
    }).catch(() => {});
  }
}

// Inject/update the role badge in the home screen hero so it's immediately
// obvious whether you're logged in as a Customer or a Fixer.
function _updateRoleBadge() {
  // Remove any existing badge
  document.getElementById('home-role-badge')?.remove();
  if (!currentUser) return;
  const isFixer = !!currentFixerProfile;
  const isAdmin = !!currentAdminProfile;
  const label = isAdmin ? '⚙️ Admin' : isFixer ? '🔧 Fixer Account' : '👤 Customer Account';
  const bg    = isAdmin ? 'rgba(201,148,58,.3)'  : isFixer ? 'rgba(74,222,128,.2)'  : 'rgba(255,255,255,.15)';
  const color = isAdmin ? 'var(--gold-light)'     : isFixer ? '#4ADE80'              : 'rgba(255,255,255,.85)';
  const badge = document.createElement('div');
  badge.id = 'home-role-badge';
  badge.style.cssText = `display:inline-flex;align-items:center;gap:5px;background:${bg};border:1px solid ${color};color:${color};font-size:11px;font-weight:700;padding:4px 12px;border-radius:20px;letter-spacing:.3px;margin-top:6px;pointer-events:none`;
  badge.textContent = label;
  // Insert after the greeting line inside the hero
  const greeting = document.getElementById('home-greeting');
  if (greeting && greeting.parentNode) {
    greeting.parentNode.insertBefore(badge, greeting.nextSibling);
  }
}

// ─────────────────── Referral system ───────────────────────────
function getReferralCode() {
  if (!currentUser) return null;
  // Deterministic short code from user UUID prefix
  return 'SERVIT-' + currentUser.id.replace(/-/g,'').slice(0,6).toUpperCase();
}

function loadReferralCard() {
  const container = document.getElementById('home-referral-card');
  if (!container || !currentUser) return;
  const code = getReferralCode();
  container.innerHTML = `
    <div style="background:linear-gradient(135deg,var(--forest),#2D5A3D);border-radius:var(--r-lg);padding:16px;margin-bottom:20px;position:relative;overflow:hidden;cursor:pointer" onclick="showReferralSheet()">
      <div style="position:absolute;top:-20px;right:-20px;width:90px;height:90px;border-radius:50%;background:radial-gradient(circle,rgba(201,148,58,.25) 0%,transparent 70%)"></div>
      <div style="position:absolute;bottom:-15px;left:20px;width:60px;height:60px;border-radius:50%;background:radial-gradient(circle,rgba(255,255,255,.06) 0%,transparent 70%)"></div>
      <div style="display:flex;align-items:center;gap:12px">
        <div style="width:42px;height:42px;border-radius:50%;background:rgba(255,255,255,.12);display:flex;align-items:center;justify-content:center;font-size:20px;flex-shrink:0">🎁</div>
        <div style="flex:1;min-width:0">
          <p style="font-weight:700;font-size:14px;color:#fff;margin-bottom:2px">Give R50 · Get R50</p>
          <p style="font-size:11px;color:rgba(255,255,255,.65)">Credit valid 90 days · First booking only · T&Cs apply</p>
        </div>
        <div style="text-align:right;flex-shrink:0">
          <p style="font-family:'DM Mono',monospace;font-size:11px;font-weight:700;color:var(--gold-light);background:rgba(0,0,0,.25);padding:4px 8px;border-radius:6px;letter-spacing:.5px">${escapeHtml(code)}</p>
          <p style="font-size:10px;color:rgba(255,255,255,.45);margin-top:3px">Tap to share →</p>
        </div>
      </div>
    </div>`;
  container.style.display = 'block';
}

function showReferralSheet() {
  document.querySelector('.referral-sheet-overlay')?.remove();
  const code = getReferralCode();
  const shareText = `Use my Servit referral code ${code} and get R50 credit on your first booking! Download the app at servit.co.za`;
  const overlay = document.createElement('div');
  overlay.className = 'referral-sheet-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end;animation:fadeIn .2s ease';
  overlay.innerHTML = `
    <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:24px 20px 40px;animation:slideUp .28s cubic-bezier(.25,.46,.45,.94)">
      <div style="width:40px;height:4px;background:var(--border);border-radius:2px;margin:0 auto 20px"></div>
      <div style="text-align:center;margin-bottom:24px">
        <div style="font-size:44px;margin-bottom:12px">🎁</div>
        <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;color:var(--text-dark);margin-bottom:6px">Invite friends, earn R50</p>
        <p style="font-size:13px;color:var(--text-muted);line-height:1.6">Share your code below. When a friend books their first job, you both get R50 credit on your next booking. Credit expires 90 days after issue. Valid once per new user only.</p>
      </div>
      <!-- Code display -->
      <div style="background:var(--cream);border:2px dashed var(--gold);border-radius:var(--r-md);padding:16px;text-align:center;margin-bottom:20px">
        <p style="font-size:11px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.6px;margin-bottom:6px">Your referral code</p>
        <p style="font-family:'DM Mono',monospace;font-size:24px;font-weight:700;color:var(--forest);letter-spacing:1.5px">${escapeHtml(code)}</p>
      </div>
      <!-- Share buttons -->
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:12px">
        <button class="btn btn-primary" onclick="shareReferral('whatsapp','${escapeHtml(code)}')" style="font-size:13px;padding:12px">
          📱 WhatsApp
        </button>
        <button class="btn btn-outline" onclick="shareReferral('copy','${escapeHtml(code)}')" style="font-size:13px;padding:12px">
          📋 Copy Code
        </button>
      </div>
      <button class="btn btn-outline btn-block" onclick="document.querySelector('.referral-sheet-overlay')?.remove()" style="font-size:13px;color:var(--text-muted);border-color:var(--border)">
        Maybe later
      </button>
    </div>`;
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
  document.body.appendChild(overlay);
}

function shareReferral(method, code) {
  const msg = `Join Servit — get a fixer for anything at home! Use code ${code} for R50 off your first booking. 🔧 servit.co.za`;
  if (method === 'whatsapp') {
    window.open('https://wa.me/?text=' + encodeURIComponent(msg), '_blank');
  } else if (method === 'copy') {
    navigator.clipboard.writeText(code).then(() => showToast('Code copied! 📋', 'success')).catch(() => {
      showToast('Your code: ' + code);
    });
  } else if (navigator.share) {
    navigator.share({ title: 'Servit — R50 off', text: msg, url: 'https://servit.co.za' }).catch(() => {});
  }
}
window.showReferralSheet = showReferralSheet;
window.shareReferral     = shareReferral;

function updateHomeGreeting() {
  const el = document.getElementById('home-greeting');
  if (!el) return;
  const hour = new Date().getHours();
  const name = currentUserProfile?.full_name?.split(' ')[0] || '';
  const prefix = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
  el.textContent = name ? `${prefix}, ${name} 👋` : 'What do you need done today?';
}

function updateHomeAvatar() {
  const el = document.getElementById('home-user-avatar');
  if (!el) return;
  const name = currentUserProfile?.full_name || currentUser?.email || '?';
  const initials = name.split(' ').map(w => w[0]).join('').toUpperCase().slice(0, 2) || '?';
  const photoUrl = currentUserProfile?.avatar_url || '';
  if (photoUrl) {
    el.innerHTML = `<img src="${escapeHtml(photoUrl)}" style="width:100%;height:100%;border-radius:50%;object-fit:cover" onerror="this.outerHTML='${initials}'">`;
  } else {
    el.textContent = initials;
  }
}

function loadCategories() {
  const grid = document.getElementById('category-grid');
  if (!grid) return;
  // FIX M-01: Show skeleton tiles while categories render — prevents blank grid on slow 3G
  grid.innerHTML = Array(9).fill(0).map(() =>
    `<div class="skeleton-card" style="aspect-ratio:1;border-radius:var(--r-md);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px">
       <div class="skeleton" style="width:32px;height:32px;border-radius:50%"></div>
       <div class="skeleton skeleton-line" style="width:60%;height:10px;border-radius:4px"></div>
     </div>`
  ).join('');
  // Defer actual render to next frame so skeleton is visible immediately
  requestAnimationFrame(() => {
    grid.innerHTML = CATEGORIES.slice(0, 9).map(cat => `
      <div class="category-card" data-category-id="${cat.id}" onclick="showRequestScreen('${cat.id}', '${cat.emoji}', '${cat.label}')">
        <span class="category-emoji">${cat.emoji}</span>
        <span class="category-name">${cat.label}</span>
      </div>
    `).join('');
  });
}

function showAllCategories() {
  // Remove any existing overlay
  document.querySelector('.all-categories-overlay')?.remove();

  const overlay = document.createElement('div');
  overlay.className = 'all-categories-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end;animation:fadeIn .2s ease';
  overlay.innerHTML = `
    <div class="all-categories-sheet" style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;max-height:80vh;overflow-y:auto;padding:20px 16px 40px;animation:slideUp .28s cubic-bezier(.25,.46,.45,.94)">
      <div style="width:40px;height:4px;background:var(--border);border-radius:2px;margin:0 auto 20px"></div>
      <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;color:var(--text-dark);margin-bottom:16px">All Services</p>
      <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:10px">
        ${CATEGORIES.map(cat => `
          <div class="category-card" data-category-id="${cat.id}" onclick="document.querySelector('.all-categories-overlay')?.remove();showRequestScreen('${cat.id}','${cat.emoji}','${cat.label}')">
            <span class="category-emoji">${cat.emoji}</span>
            <span class="category-name">${cat.label}</span>
          </div>
        `).join('')}
      </div>
    </div>`;
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
  document.body.appendChild(overlay);
}
window.showAllCategories = showAllCategories;

// FIX: was querying pro_profiles — now queries fixers
async function loadFixers() {
  const container = document.getElementById('fixer-list');
  if (!container) return;

  // Show skeleton while loading
  container.innerHTML = [1,2,3].map(() => `
    <div class="skeleton-card">
      <div class="skeleton skeleton-avatar"></div>
      <div style="flex:1">
        <div class="skeleton skeleton-line" style="width:55%;margin-bottom:8px"></div>
        <div class="skeleton skeleton-line" style="width:35%;margin-bottom:8px"></div>
        <div class="skeleton skeleton-line" style="width:70%"></div>
      </div>
    </div>`).join('');

  const { data: fixers, error } = await supabaseClient
    .from('fixers')
    .select('*')
    .eq('status', 'approved')
    .eq('available', true)
    .limit(10);

  if (error || !fixers || fixers.length === 0) {
    container.innerHTML = `
      <div style="text-align:center;padding:24px 16px;background:var(--card-bg);border:1px solid var(--border);border-radius:var(--r-lg);">
        <div style="font-size:40px;margin-bottom:12px;opacity:.5">🔍</div>
        <p style="font-weight:600;font-size:15px;color:var(--text-dark);margin-bottom:6px;">No fixers online right now</p>
        <p style="font-size:12px;color:var(--text-muted);margin-bottom:16px;line-height:1.6;">This could be your location or time of day. Post a job — fixers get notified and respond shortly.</p>
        <button class="btn btn-primary btn-sm" onclick="showRequestScreen('general','🔧','General')">📋 Post a Job</button>
      </div>`;
    return;
  }

  const bgColors = ['#1A3A2A','#2D5A3D','#5A3A1A','#1A3A5A','#3A1A5A'];
  container.innerHTML = fixers.map((fixer, i) => {
    const bg = bgColors[i % bgColors.length];
    const initial = (fixer.full_name || '?')[0].toUpperCase();
    const hasPhoto = fixer.photo_url && fixer.photo_url.startsWith('http');
    const avatarHtml = hasPhoto
      ? `<img src="${escapeHtml(fixer.photo_url)}" style="width:54px;height:54px;border-radius:50%;object-fit:cover;border:2px solid var(--gold);flex-shrink:0" onerror="this.outerHTML='<div style=\\'width:54px;height:54px;border-radius:50%;background:${bg};display:flex;align-items:center;justify-content:center;color:#fff;font-size:22px;font-weight:700;flex-shrink:0;border:2px solid var(--gold)\\'>${initial}</div>'">`
      : `<div style="width:54px;height:54px;border-radius:50%;background:${bg};display:flex;align-items:center;justify-content:center;color:#fff;font-size:22px;font-weight:700;flex-shrink:0;position:relative;border:2px solid ${fixer.is_verified ? 'var(--gold)' : 'var(--border)'}">
          ${initial}
          <span style="position:absolute;bottom:1px;right:1px;width:11px;height:11px;background:#4ADE80;border-radius:50%;border:2px solid #fff"></span>
        </div>`;

    // Build badge row
    const badges = [];
    if (fixer.is_verified)        badges.push('<span style="background:#E8F5EE;color:#1A5C36;font-size:9px;font-weight:700;padding:2px 7px;border-radius:8px;border:1px solid #B6DEC7">✓ Verified</span>');
    if (fixer.badge_top_fixer)    badges.push('<span style="background:#FDF3E0;color:#8B5E15;font-size:9px;font-weight:700;padding:2px 7px;border-radius:8px;border:1px solid #F5CFA0">🏆 Top Fixer</span>');
    if (fixer.badge_fast_responder) badges.push('<span style="background:#E8F0FA;color:#1A3A6A;font-size:9px;font-weight:700;padding:2px 7px;border-radius:8px;border:1px solid #A0C0EF">⚡ Fast</span>');

    const rating = fixer.rating ? fixer.rating.toFixed(1) : null;
    const completionText = fixer.completion_rate ? `${Math.round(fixer.completion_rate)}% done` : null;
    const jobsText = fixer.total_completed > 0 ? `${fixer.total_completed} jobs` : (fixer.jobs_completed > 0 ? `${fixer.jobs_completed} jobs` : 'New');
    const responseText = fixer.avg_response_time && fixer.avg_response_time < 300
      ? `~${fixer.avg_response_time}s response`
      : null;

    return `
    <div class="fixer-card" style="padding:14px;gap:12px">
      ${avatarHtml}
      <div class="fixer-info" style="flex:1;min-width:0">
        <div style="display:flex;align-items:center;gap:6px;margin-bottom:3px;flex-wrap:wrap">
          <p class="fixer-name" style="font-size:14px;font-weight:700">${escapeHtml(fixer.full_name)}</p>
          <span style="background:#E8F5EE;color:#2D7A4F;font-size:9px;font-weight:700;padding:1px 6px;border-radius:8px">● ONLINE</span>
        </div>
        <p style="font-size:11px;color:var(--text-muted);margin-bottom:5px">${getCategoryEmoji(fixer.category)} ${escapeHtml(fixer.service_title || fixer.category || 'General')}</p>
        <div style="display:flex;gap:5px;flex-wrap:wrap;margin-bottom:5px">
          ${rating ? `<span style="background:var(--cream-dark);font-size:10px;font-weight:600;color:var(--text-mid);padding:2px 8px;border-radius:10px">⭐ ${rating}${fixer.review_count ? ` (${fixer.review_count})` : ''}</span>` : '<span style="background:var(--cream-dark);font-size:10px;color:var(--text-muted);padding:2px 8px;border-radius:10px">New</span>'}
          <span style="background:var(--cream-dark);font-size:10px;font-weight:600;color:var(--text-mid);padding:2px 8px;border-radius:10px">📋 ${jobsText}</span>
          ${completionText ? `<span style="background:var(--cream-dark);font-size:10px;font-weight:600;color:var(--text-mid);padding:2px 8px;border-radius:10px">✓ ${completionText}</span>` : ''}
          ${responseText ? `<span style="background:var(--cream-dark);font-size:10px;font-weight:600;color:var(--text-mid);padding:2px 8px;border-radius:10px">⏱ ${responseText}</span>` : ''}
        </div>
        ${badges.length ? `<div style="display:flex;gap:4px;flex-wrap:wrap">${badges.join('')}</div>` : ''}
      </div>
      <div style="text-align:right;flex-shrink:0;display:flex;flex-direction:column;align-items:flex-end;gap:6px">
        <p style="font-size:13px;font-weight:700;color:var(--forest)">${formatZAR(fixer.price)}/${fixer.price_type || 'hr'}</p>
        <button class="btn btn-primary btn-sm" style="font-size:11px;padding:6px 14px" onclick="event.stopPropagation();showRequestScreen('${escapeHtml(fixer.category||'Other')}','${getCategoryEmoji(fixer.category)}','${escapeHtml(fixer.service_title||fixer.category||'General')}')">Book</button>
      </div>
    </div>`;
  }).join('');
}

function showRequestScreen(category, emoji, label, fixerStudioAddress) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  const screen = document.getElementById('screen-request');
  if (screen) screen.classList.add('active');

  const content = document.getElementById('request-content');
  if (!content) return;

  _currentCategoryType = getCategoryType(category);
  const savedAddress = currentUserProfile?.address_home || '';
  const savedPhone   = currentUserProfile?.phone || '';

  content.innerHTML = `
    <div style="background:var(--forest);padding:16px 20px 24px;color:#fff;position:relative;overflow:hidden">
      <div style="position:absolute;top:-30px;right:-20px;width:120px;height:120px;border-radius:50%;background:radial-gradient(circle,rgba(201,148,58,.2) 0%,transparent 70%);pointer-events:none"></div>
      <div style="display:flex;align-items:center;gap:12px">
        <span style="font-size:36px;filter:drop-shadow(0 2px 6px rgba(0,0,0,.3))">${emoji}</span>
        <div style="flex:1;min-width:0">
          <p style="font-family:'Playfair Display',serif;font-size:19px;font-weight:700">${label}</p>
          <p style="font-size:12px;opacity:.65">${getCategoryType(category) === 'venue' ? 'Book your appointment' : "We'll find the best fixer nearby"}</p>
        </div>
      </div>
      <!-- Wire 6: wallet-credit-badge — marketplace.js writes to this element
           when loadWalletCredit() runs and when applyWalletCredit() is called.
           Hidden by default; marketplace.js shows it when credit > 0. -->
      <div id="wallet-credit-badge" style="display:none;margin-top:10px;background:rgba(255,255,255,.15);border-radius:20px;padding:5px 12px;font-size:12px;font-weight:600;width:fit-content"></div>
    </div>

    <div style="padding:16px">

      <!-- Tier Selector -->
      <div style="margin-bottom:18px">
        <label style="font-size:11px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.6px;display:block;margin-bottom:10px">Service Tier</label>
        <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px" id="tier-selector">
          ${[
            { id:'basic',    icon:'💰', label:'Basic',    sub:'Best price',     color:'#4A7C59' },
            { id:'standard', icon:'⚡', label:'Standard', sub:'Most popular',   color:'var(--forest)' },
            { id:'premium',  icon:'⭐', label:'Premium',  sub:'Top rated',      color:'#8B6914', hot:true },
          ].map(t => `
            <div class="tier-card ${t.id === 'standard' ? 'tier-selected' : ''}"
                 data-tier="${t.id}"
                 onclick="selectTier('${t.id}')"
                 style="border:2px solid ${t.id === 'standard' ? 'var(--forest)' : 'var(--border)'};border-radius:var(--r-md);padding:10px 6px;text-align:center;cursor:pointer;transition:all .18s;background:${t.id === 'standard' ? 'var(--cream)' : 'var(--warm-white)'};position:relative">
              ${t.hot ? '<span style="position:absolute;top:-8px;left:50%;transform:translateX(-50%);background:var(--gold-dark);color:#fff;font-size:8px;font-weight:700;padding:2px 7px;border-radius:8px;white-space:nowrap;letter-spacing:.3px">PRIORITY</span>' : ''}
              <div style="font-size:20px;margin-bottom:4px">${t.icon}</div>
              <div style="font-size:12px;font-weight:700;color:var(--text-dark)">${t.label}</div>
              <div style="font-size:9px;color:var(--text-muted);line-height:1.3">${t.sub}</div>
            </div>`).join('')}
        </div>
        <div id="tier-info" style="margin-top:8px;padding:8px 12px;background:var(--cream);border-radius:var(--r-sm);font-size:11px;color:var(--text-mid)">
          ⚡ <strong>Standard:</strong> Balanced price, rating &amp; speed · Min R150
        </div>
      </div>

      <!-- Description -->
      <div class="input-group">
        <label class="input-label">Describe the job <span style="color:var(--danger)">*</span></label>
        <textarea class="input" id="job-description" rows="3" placeholder="e.g. Leaking tap in kitchen, needs fixing urgently..."></textarea>
      </div>

      <!-- Address — mobile: customer provides address; venue: provider's studio shown -->
      ${getCategoryType(category) === 'venue' ? `
      <div class="input-group">
        <label class="input-label">Provider location</label>
        <div style="background:var(--cream);border:1.5px solid var(--border);border-radius:var(--r-sm);padding:10px 12px;font-size:13px;color:var(--text-mid)">
          📍 ${fixerStudioAddress ? escapeHtml(fixerStudioAddress) : '<em style="color:var(--text-muted)">Studio address will be confirmed after booking</em>'}
        </div>
        <input type="hidden" id="job-address" value="${fixerStudioAddress ? escapeHtml(fixerStudioAddress) : 'Provider studio'}">
      </div>` : `
      <div class="input-group">
        <label class="input-label">Service address <span style="color:var(--danger)">*</span></label>
        <div id="location-denied-banner" style="display:none;background:#FFF8E7;border:1.5px solid var(--gold);border-radius:var(--r-sm);padding:8px 12px;margin-bottom:8px;font-size:12px;color:var(--gold-dark);line-height:1.5">
          📍 <strong>Location access blocked</strong> — fixers are matched by distance. Enable location in your browser settings for faster, more accurate matching. Your exact address is still required below.
        </div>
        <input class="input" id="job-address" placeholder="Street, suburb, city" value="${escapeHtml(savedAddress)}">
        ${savedAddress ? '<p style="font-size:11px;color:var(--success);margin-top:4px">✓ Pre-filled from saved home address</p>' : ''}
      </div>`}

      <!-- Phone -->
      <div class="input-group">
        <label class="input-label">Contact number <span style="color:var(--danger)">*</span></label>
        <input class="input" id="job-phone" type="tel" placeholder="+27 XX XXX XXXX" value="${escapeHtml(savedPhone)}">
      </div>

      <!-- When -->
      <div class="input-group">
        <label class="input-label">When?</label>
        <select class="input" id="booking-mode" onchange="document.getElementById('scheduled-fields').style.display=this.value==='scheduled'?'block':'none'">
          <option value="asap">⚡ As soon as possible</option>
          <option value="scheduled">📅 Schedule for later</option>
        </select>
      </div>
      <div id="scheduled-fields" style="display:none">
        <div class="input-group">
          <label class="input-label">Date &amp; Time</label>
          <input class="input" type="datetime-local" id="scheduled-datetime">
        </div>
      </div>

      <!-- Budget — mobile: customer sets amount; venue: provider sets fixed price -->
      <div class="input-group">
        ${getCategoryType(category) === 'venue' ? `
        <label class="input-label">Service price (set by provider) <span style="color:var(--danger)">*</span></label>
        <input class="input" id="job-budget" type="number" placeholder="Enter agreed price (R)" min="50" oninput="updatePricePreview(this.value)">
        <p style="font-size:11px;color:var(--text-muted);margin-top:4px">💡 Enter the price quoted by the provider. You'll pay this + a small processing fee.</p>
        ` : `
        <label class="input-label">What you'd like to pay the fixer (R) <span style="color:var(--danger)">*</span></label>
        <input class="input" id="job-budget" type="number" placeholder="e.g. 500" min="50" oninput="updatePricePreview(this.value)">
        `}
        <div id="price-guidance" style="margin-top:6px;padding:8px 10px;background:var(--cream);border-radius:var(--r-sm);font-size:11px;color:var(--text-mid)">
          <span style="opacity:.5">Loading price guide...</span>
        </div>
        <div id="price-preview" style="display:none;margin-top:6px;padding:10px 12px;background:var(--forest);border-radius:var(--r-sm);font-size:12px;color:#fff;line-height:1.5">
          ${getCategoryType(category) === 'venue' ? `
          <!-- VENUE: customer pays fixed price + fees on top -->
          <div style="display:flex;justify-content:space-between;margin-bottom:4px">
            <span style="opacity:.7">Service price</span>
            <span id="preview-fixer">—</span>
          </div>
          <div style="display:flex;justify-content:space-between;margin-bottom:4px">
            <span style="opacity:.7">Service fee</span>
            <span id="preview-fee" style="color:var(--gold-light)">—</span>
          </div>
          <div style="display:flex;justify-content:space-between;padding-top:6px;border-top:1px solid rgba(255,255,255,.15)">
            <span style="font-weight:700">You'll be charged</span>
            <span id="preview-total" style="font-weight:700;font-size:14px;color:var(--gold-light)">—</span>
          </div>
          ` : `
          <!-- MOBILE: customer pays what they quoted; fixer receives that minus blended fees -->
          <div style="display:flex;justify-content:space-between;padding-bottom:6px;border-bottom:1px solid rgba(255,255,255,.15);margin-bottom:6px">
            <span style="font-weight:700">You'll be charged</span>
            <span id="preview-total" style="font-weight:700;font-size:14px;color:var(--gold-light)">—</span>
          </div>
          <div style="display:flex;justify-content:space-between;margin-bottom:2px">
            <span style="opacity:.6;font-size:11px">Fixer receives (after fees)</span>
            <span id="preview-fixer" style="font-size:11px;opacity:.75">—</span>
          </div>
          <div style="display:flex;justify-content:space-between">
            <span style="opacity:.6;font-size:11px">Platform &amp; processing fee</span>
            <span id="preview-fee" style="font-size:11px;opacity:.75">—</span>
          </div>
          `}
        </div>
      </div>

      <!-- Summary -->
      <div id="booking-summary" style="display:none;background:var(--cream);border:1.5px solid var(--border);border-radius:var(--r-md);padding:14px;margin-bottom:16px">
        <p style="font-size:11px;font-weight:700;color:var(--forest);text-transform:uppercase;letter-spacing:.5px;margin-bottom:10px">Booking Summary</p>
        <div id="summary-lines"></div>
        <div style="border-top:1px solid var(--border);margin-top:10px;padding-top:10px">
          <div style="display:flex;justify-content:space-between;font-size:12px;margin-bottom:4px">
            <span style="color:var(--text-muted)" id="summary-fee-label">Service fee</span>
            <span id="summary-fee">R0.00</span>
          </div>
          <div style="display:flex;justify-content:space-between;font-size:15px;font-weight:700">
            <span>Total</span>
            <span id="summary-total" style="color:var(--forest)">R0.00</span>
          </div>
        </div>
      </div>

      <button class="btn btn-primary btn-block" id="request-btn" onclick="handleRequestContinue('${escapeHtml(category)}', '${escapeHtml(label)}')">
        Review &amp; Continue →
      </button>
      <p style="font-size:11px;text-align:center;color:var(--text-muted);margin-top:10px">🔒 Secure payment via Yoco · Full refund if no fixer is found</p>
    </div>
  `;

  // Fetch price guidance async — non-blocking
  supabaseClient.rpc('get_price_guidance', { p_category: category })
    .then(({ data }) => {
      const el = document.getElementById('price-guidance');
      if (!el || !data) return;
      if (data.has_data) {
        el.innerHTML = `💡 ${escapeHtml(data.suggestion)}<br>
          <span style="color:var(--text-muted)">Based on ${data.sample_count} recent jobs</span>`;
      } else {
        el.innerHTML = `💡 ${escapeHtml(data.suggestion)}`;
      }
    })
    .catch(() => {
      const el = document.getElementById('price-guidance');
      if (el) el.innerHTML = '💡 Enter your budget. You only pay when the job is done.';
    });

  // FIX (Audit L17): Show soft banner if location permission is denied — don't block,
  // just make the impact clear so users understand why matching might be slower.
  if (navigator.permissions) {
    navigator.permissions.query({ name: 'geolocation' }).then(perm => {
      const banner = document.getElementById('location-denied-banner');
      if (banner) banner.style.display = perm.state === 'denied' ? 'block' : 'none';
    }).catch(() => {});
  }
}

const TIER_INFO = {
  basic:    { icon:'💰', label:'Basic',    desc:'ID-checked fixer · Closest match · Min R50 · Standard response time',  min:50,  color:'#4A7C59',
              bullets:['✓ ID-checked fixer','✓ Closest available fixer','✓ Best price','✗ No police clearance required','✗ No guaranteed response time'] },
  standard: { icon:'⚡', label:'Standard', desc:'ID-verified fixer · Balanced rating &amp; speed · Min R150', min:150, color:'var(--forest)',
              bullets:['✓ ID &amp; address verified','✓ Rating ≥ 4.0 required','✓ Avg. 15-min response','✓ Most popular tier'] },
  premium:  { icon:'⭐', label:'Premium',  desc:'Top-rated, police-cleared fixer · Guaranteed match in 5 min · Min R300', min:300, color:'#8B6914',
              bullets:['✓ Police-cleared &amp; insured','✓ Rating ≥ 4.7 required','✓ Guaranteed 5-min match','✓ Priority dispatch','✓ Dedicated support'] },
};
let _selectedTier        = 'standard';
let _currentCategoryType = 'mobile'; // 'mobile' | 'venue' — set in showRequestScreen

function selectTier(tier) {
  _selectedTier = tier;
  document.querySelectorAll('.tier-card').forEach(el => {
    const isSelected = el.dataset.tier === tier;
    el.style.borderColor  = isSelected ? 'var(--forest)' : 'var(--border)';
    el.style.background   = isSelected ? 'var(--cream)' : 'var(--warm-white)';
  });
  const info = TIER_INFO[tier];
  const infoEl = document.getElementById('tier-info');
  if (infoEl && info) {
    infoEl.innerHTML = `
      <p style="font-size:11px;font-weight:700;color:var(--text-dark);margin-bottom:6px">${info.icon} ${info.label}</p>
      ${(info.bullets || []).map(b => `<p style="font-size:11px;color:${b.startsWith('✓') ? 'var(--success)' : 'var(--text-muted)'};margin-bottom:2px">${b}</p>`).join('')}
      <p style="font-size:11px;color:var(--text-muted);margin-top:4px">Minimum R${info.min}</p>`;
  }

  // Update min amount hint
  const previewBox = document.getElementById('price-preview');
  if (previewBox) {
    const amt = parseFloat(document.getElementById('job-budget')?.value);
    if (amt) updatePricePreview(String(amt));
  }
}
window.selectTier = selectTier;

function updatePricePreview(val) {
  const previewBox = document.getElementById('price-preview');
  const summary    = document.getElementById('booking-summary');
  const amount     = parseFloat(val);
  if (!amount || amount < 50) {
    if (previewBox) previewBox.style.display = 'none';
    if (summary) summary.style.display = 'none';
    // Clear the marketplace fee summary too
    const mktWrap = document.getElementById('mkt-fee-summary-wrap');
    if (mktWrap) mktWrap.innerHTML = '';
    return;
  }
  // Keep the simple inline preview visible immediately (no RPC latency).
  // It will be hidden automatically once the detailed mkt-fee-summary loads.
  // Blended service fee: Servit 12% + Yoco 2.95% shown as one line
  // ── Fee calculation (mirrors create-booking.js and calculate_booking_fees SQL) ──
  // MOBILE: customer pays exactly their quoted amount. Platform fee (12%, min R15) +
  //         Yoco fee (2.95% of quoted amount) are DEDUCTED from the fixer's payout.
  //         Customer sees: "You'll be charged R800" | "Fixer receives R680.40 after fees"
  // VENUE:  provider sets fixed price. Customer pays price + blended fees ON TOP.
  //         Fixer always receives their full fixed price.
  //         Customer sees: "Service price R150" + "Service fee R22.96" = "You'll be charged R172.96"
  const platformFee = Math.max(amount * 0.12, 15);
  const isVenue     = _currentCategoryType === 'venue';
  let   total, blendedFee, fixerReceives;
  if (isVenue) {
    const subtotal = amount + platformFee;
    const yocoFee  = Math.ceil(subtotal * 0.0295 * 100) / 100;
    blendedFee     = platformFee + yocoFee;
    total          = amount + blendedFee;
    fixerReceives  = amount; // provider always gets their full fixed price
  } else {
    const yocoFee  = Math.ceil(amount * 0.0295 * 100) / 100;
    blendedFee     = platformFee + yocoFee;
    total          = amount;  // customer pays exactly what they quoted
    fixerReceives  = amount - blendedFee;
  }
  if (previewBox) {
    previewBox.style.display = 'block';
    const setTxt = (id, v) => { const el = document.getElementById(id); if (el) el.textContent = v; };
    setTxt('preview-fixer', formatZAR(isVenue ? amount : fixerReceives));
    setTxt('preview-fee',   formatZAR(blendedFee));
    setTxt('preview-total', formatZAR(total));
  }
  // Wire 2: also fire the marketplace live fee summary (shows Yoco fee + wallet
  // credit line, server-side accurate). Inject its container after price-preview
  // if it doesn't exist yet.
  if (window._marketplace?.showBookingSummary) {
    let mktWrap = document.getElementById('mkt-fee-summary-wrap');
    if (!mktWrap) {
      mktWrap = document.createElement('div');
      mktWrap.id = 'mkt-fee-summary-wrap';
      const priceGuidance = document.getElementById('price-guidance');
      const insertAfter = previewBox || priceGuidance;
      if (insertAfter) {
        insertAfter.insertAdjacentElement('afterend', mktWrap);
      }
    }
    // Once the detailed RPC-backed summary loads, hide the simple preview so
    // both don't stack. Use a MutationObserver to detect when content arrives.
    if (previewBox) {
      const observer = new MutationObserver(() => {
        if (mktWrap.querySelector('#mkt-fee-summary')) {
          previewBox.style.display = 'none';
          observer.disconnect();
        }
      });
      observer.observe(mktWrap, { childList: true, subtree: true });
    }
    window._marketplace.showBookingSummary(mktWrap, amount);
  }
}
window.updatePricePreview = updatePricePreview;

function handleRequestContinue(category, label) {
  const description = document.getElementById('job-description')?.value?.trim();
  const address     = document.getElementById('job-address')?.value?.trim();
  const phone       = document.getElementById('job-phone')?.value?.trim();
  const amount      = parseFloat(document.getElementById('job-budget')?.value);
  const bookingMode = document.getElementById('booking-mode')?.value;
  const scheduledFor = document.getElementById('scheduled-datetime')?.value;
  const tier        = _selectedTier || 'standard';
  const minAmount   = TIER_INFO[tier]?.min || 50;

  if (!description || !address || !phone || !amount || amount < minAmount) {
    showToast(`Please fill in all fields (min budget R${minAmount} for ${tier} tier)`, 'error');
    return;
  }

  // Same fee split as updatePricePreview — must stay in sync.
  // MOBILE: total = amount (customer pays quoted price); fixer receives amount - blended fees.
  // VENUE:  total = amount + blended fees (customer pays on top); fixer gets full fixed price.
  const platformFee = Math.max(amount * 0.12, 15);
  const isVenue     = _currentCategoryType === 'venue';
  let   total, blendedFee, fixerReceives;
  if (isVenue) {
    const subtotal = amount + platformFee;
    const yocoFee  = Math.ceil(subtotal * 0.0295 * 100) / 100;
    blendedFee     = platformFee + yocoFee;
    total          = amount + blendedFee;
    fixerReceives  = amount;
  } else {
    const yocoFee  = Math.ceil(amount * 0.0295 * 100) / 100;
    blendedFee     = platformFee + yocoFee;
    total          = amount;
    fixerReceives  = amount - blendedFee;
  }
  const summaryEl    = document.getElementById('booking-summary');
  const summaryLines = document.getElementById('summary-lines');
  if (summaryEl && summaryLines) {
    const tierInfo = TIER_INFO[tier];
    summaryLines.innerHTML = `
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:8px">
        <span style="font-size:16px">${tierInfo.icon}</span>
        <span style="font-size:13px;font-weight:700">${escapeHtml(label)} · ${tierInfo.label}</span>
      </div>
      <p style="font-size:12px;color:var(--text-muted);margin-bottom:2px">📍 ${escapeHtml(address)}</p>
      <p style="font-size:12px;color:var(--text-muted);margin-bottom:2px">📞 ${escapeHtml(phone)}</p>
      <p style="font-size:12px;color:var(--text-muted)">⏰ ${bookingMode === 'scheduled' ? 'Scheduled: ' + (scheduledFor ? new Date(scheduledFor).toLocaleString('en-ZA',{weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}) : 'TBD') : 'As soon as possible'}</p>
      ${isVenue
        ? `<p style="font-size:12px;margin-top:6px"><strong>Service price:</strong> ${formatZAR(amount)}</p>`
        : `<p style="font-size:12px;margin-top:6px"><strong>You pay:</strong> ${formatZAR(amount)} · <span style="color:var(--text-muted)">Fixer receives ${formatZAR(fixerReceives)}</span></p>`
      }
      <div style="margin-top:12px;padding:10px 12px;background:var(--warm-white);border:1px solid var(--border);border-radius:var(--r-md)">
        <p style="font-size:10px;font-weight:700;color:var(--forest);text-transform:uppercase;letter-spacing:.5px;margin-bottom:7px">What happens next</p>
        <div style="display:flex;align-items:flex-start;gap:8px;margin-bottom:5px">
          <span style="font-size:13px;flex-shrink:0">💳</span>
          <p style="font-size:11px;color:var(--text-mid);line-height:1.5">Payment is collected securely now via Yoco</p>
        </div>
        <div style="display:flex;align-items:flex-start;gap:8px;margin-bottom:5px">
          <span style="font-size:13px;flex-shrink:0">🔍</span>
          <p style="font-size:11px;color:var(--text-mid);line-height:1.5">We immediately search for the best fixer nearby</p>
        </div>
        <div style="display:flex;align-items:flex-start;gap:8px">
          <span style="font-size:13px;flex-shrink:0">💸</span>
          <p style="font-size:11px;color:var(--text-mid);line-height:1.5"><strong>Full refund</strong> within 3–5 days if no fixer accepts</p>
        </div>
      </div>
    `;
    document.getElementById('summary-fee').textContent        = formatZAR(blendedFee);
    document.getElementById('summary-total').textContent      = formatZAR(total);
    const feeLabel = document.getElementById('summary-fee-label');
    if (feeLabel) feeLabel.textContent = isVenue ? 'Service fee (added on top)' : 'Platform & processing fee (deducted from fixer)';
    summaryEl.style.display = 'block';
    summaryEl.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  const btn = document.getElementById('request-btn');
  if (btn) {
    btn.textContent = '✓ Pay & Find My Fixer →';
    btn.onclick = () => submitRequest(category, tier);
    btn.style.background = 'var(--gold)';
    btn.style.color      = '#fff';
  }
}
window.handleRequestContinue = handleRequestContinue;

let _submitRequestInFlight = false; // FIX C: guard against double-tap on "Confirm & Pay"
async function submitRequest(category, tier = 'standard') {
  if (_submitRequestInFlight) return;
  _submitRequestInFlight = true;
  const btn = document.getElementById('request-btn');
  if (btn) { btn.disabled = true; btn.textContent = 'Processing…'; }

  const description  = document.getElementById('job-description')?.value?.trim();
  const address      = document.getElementById('job-address')?.value?.trim();
  const phone        = document.getElementById('job-phone')?.value?.trim();
  const amount       = parseFloat(document.getElementById('job-budget')?.value);
  const bookingMode  = document.getElementById('booking-mode')?.value;
  const scheduledFor = document.getElementById('scheduled-datetime')?.value;

  if (!description || !address || !amount || amount <= 0) {
    showToast('Please fill in all required fields', 'error');
    if (btn) { btn.disabled = false; btn.textContent = '✓ Confirm & Pay Now'; }
    _submitRequestInFlight = false;
    return;
  }

  // Save form state before Yoco redirect so we can restore it if payment is cancelled
  try {
    sessionStorage.setItem('servit_booking_draft', JSON.stringify({
      category, tier, description, address, phone, amount, bookingMode, scheduledFor,
      label: document.getElementById('screen-request')?.querySelector('[style*="Playfair"]')?.textContent || category,
    }));
  } catch (_) { /* storage full — non-blocking */ }

  // BUG 7 FIX: Removed window._marketplace.createBooking() call that was here in v8.3.
  // The marketplace wrapper was calling create_booking_idempotent() directly via Supabase RPC,
  // creating a booking row in the DB. Then createBooking() below called the Netlify function
  // which ALSO called create_booking_idempotent — but with a DIFFERENT idempotency key
  // (marketplace used mkt-booking-key-{category}, Netlify function used servit_booking_ikey).
  // Result: two booking rows on every submitRequest() call on any device with marketplace loaded.
  // The Netlify function (createBooking()) is the single authoritative path. It handles
  // idempotency, city extraction, description/phone, fee calculation, and Yoco redirect.

  try {
    await createBooking(
      description, address, phone, amount, bookingMode,
      bookingMode === 'scheduled' ? scheduledFor : null,
      category,
      tier || _selectedTier || 'standard',
      _currentCategoryType  // 'mobile' | 'venue' — determines who pays the blended fee
    );
  } finally {
    // Re-enable if createBooking threw (e.g. API error) — if redirect succeeds
    // the page navigates away so this never runs in the success case.
    _submitRequestInFlight = false;
    if (btn) { btn.disabled = false; btn.textContent = '✓ Confirm & Pay Now'; }
  }
}

function updateActiveNav(navId) {
  document.querySelectorAll('.nav-item').forEach(item => {
    // Support both data-nav attribute and element id (e.g. id="nav-home")
    const itemNav = item.dataset.nav || item.id?.replace('nav-', '');
    item.classList.toggle('active', itemNav === navId);
  });
}

// ─────────────────── Event listeners ────────────────────────────

document.getElementById('send-btn')?.addEventListener('click', sendMessage);
document.getElementById('chat-input')?.addEventListener('keypress', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});

document.getElementById('login-btn')?.addEventListener('click', async () => {
  const email = document.getElementById('login-email').value;
  const password = document.getElementById('login-password').value;
  await _appSignIn(email, password);
});

// ── Unified signup handler ─────────────────────────────────────
// Reads the correct field IDs for whichever role is active.
// Customer fields: signup-name, signup-email, signup-customer-phone, signup-password
// Fixer fields:    fx-signup-name, fx-signup-email, signup-phone, fx-signup-password
// Both buttons (#signup-btn and #signup-fixer-btn) and the signUp() / _signUpImpl()
// wrapper all route here so there is one single code path.
async function _signUpImpl() {
  const role = document.querySelector('.role-btn.active')?.dataset.role || 'customer';
  let name, email, phone, password;

  if (role === 'fixer') {
    name     = document.getElementById('fx-signup-name')?.value?.trim()     || '';
    email    = document.getElementById('fx-signup-email')?.value?.trim()    || '';
    phone    = document.getElementById('signup-phone')?.value?.trim()       || '';
    password = document.getElementById('fx-signup-password')?.value         || '';

    // Fixer-specific validation
    const city     = document.getElementById('signup-city')?.value;
    const category = document.getElementById('signup-category')?.value;
    const terms    = document.getElementById('signup-fixer-terms')?.checked;
    const msgEl    = document.getElementById('auth-msg');

    if (!name || !email || !phone || !password) {
      if (msgEl) { msgEl.textContent = 'Please fill in your name, email, phone and password.'; msgEl.className = 'auth-msg error'; }
      return;
    }
    if (password.length < 8) {
      if (msgEl) { msgEl.textContent = 'Password must be at least 8 characters.'; msgEl.className = 'auth-msg error'; }
      return;
    }
    if (!city) {
      if (msgEl) { msgEl.textContent = 'Please select your city.'; msgEl.className = 'auth-msg error'; }
      return;
    }
    if (!category) {
      if (msgEl) { msgEl.textContent = 'Please select your primary service category.'; msgEl.className = 'auth-msg error'; }
      return;
    }
    if (!terms) {
      if (msgEl) { msgEl.textContent = 'Please accept the Terms of Service to continue.'; msgEl.className = 'auth-msg error'; }
      return;
    }
  } else {
    name     = document.getElementById('signup-name')?.value?.trim()         || '';
    email    = document.getElementById('signup-email')?.value?.trim()        || '';
    phone    = document.getElementById('signup-customer-phone')?.value?.trim() || '';
    password = document.getElementById('signup-password')?.value             || '';

    const msgEl = document.getElementById('auth-msg');
    if (!name || !email || !password) {
      if (msgEl) { msgEl.textContent = 'Please fill in your name, email and password.'; msgEl.className = 'auth-msg error'; }
      return;
    }
    if (password.length < 8) {
      if (msgEl) { msgEl.textContent = 'Password must be at least 8 characters.'; msgEl.className = 'auth-msg error'; }
      return;
    }
  }

  // Disable buttons during submission
  const btn1 = document.getElementById('signup-btn');
  const btn2 = document.getElementById('signup-fixer-btn');
  const spinner = document.getElementById('auth-spinner');
  if (btn1) { btn1.disabled = true; btn1.textContent = 'Creating account…'; }
  if (btn2) { btn2.disabled = true; btn2.textContent = 'Submitting…'; }
  if (spinner) { spinner.style.display = 'block'; spinner.textContent = role === 'fixer' ? 'Submitting your application…' : 'Creating your account…'; }

  try {
    await _appSignUp(name, email, phone, password, role);
  } finally {
    if (btn1) { btn1.disabled = false; btn1.textContent = 'Create Account'; }
    if (btn2) { btn2.disabled = false; btn2.textContent = 'Submit Fixer Application →'; }
    if (spinner) spinner.style.display = 'none';
  }
}
window._signUpImpl = _signUpImpl;

document.getElementById('signup-btn')?.addEventListener('click', () => _signUpImpl());
document.getElementById('signup-fixer-btn')?.addEventListener('click', () => _signUpImpl());

document.querySelectorAll('.nav-item').forEach(item => {
  // nav items use id="nav-X" pattern — already handled by onclick attrs in HTML
  // This listener is a fallback for any nav items without onclick
  item.addEventListener('click', () => {
    const nav = item.id?.replace('nav-', '') || item.dataset.nav;
    if (!nav) return;
    if (nav === 'home') {
      if (currentFixerProfile) showFixerDashboard();
      else showHomeScreen();
    } else if (nav === 'bookings') showBookingsScreen('active');
    else if (nav === 'chat-list') showMessagesScreen();
    else if (nav === 'notifications') showNotificationsScreen();
    else if (nav === 'profile') showProfileScreen();
  });
});

document.querySelectorAll('.back-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    if (currentFixerProfile) showFixerDashboard();
    else showHomeScreen();
  });
});

// ─────────────────── Global exports ──────────────────────────────

// Fixer pay discrepancy modal — accessible from the Earnings tab.
// Separate from raiseDispute (which is about job quality) so ops
// can route pay queries to the finance team instead of the dispute queue.
window.raisePayDisputeModal = function(bookingId, jobLabel, expectedEarnings) {
  document.querySelector('.pay-dispute-modal-overlay')?.remove();
  const overlay = document.createElement('div');
  overlay.className = 'pay-dispute-modal-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;display:flex;align-items:flex-end;justify-content:center;animation:fadeIn .2s ease';
  overlay.innerHTML = `
    <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;padding:24px 20px 32px;width:100%;max-width:480px;animation:slideUp .25s ease">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:16px">
        <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;color:var(--text-dark)">❓ Question a payout</p>
        <button onclick="document.querySelector('.pay-dispute-modal-overlay')?.remove()" style="background:none;border:none;font-size:20px;cursor:pointer;color:var(--text-muted)">×</button>
      </div>
      <div style="background:#FFF8EC;border:1px solid #FDE68A;border-radius:var(--r-md);padding:12px 14px;margin-bottom:14px;font-size:12px;color:#92400E;line-height:1.6">
        <strong>${escapeHtml(jobLabel)}</strong><br>
        Expected: <strong>${formatZAR(expectedEarnings)}</strong><br>
        Ref: <code style="font-size:11px">${escapeHtml(bookingId)}</code>
      </div>
      <textarea id="pay-dispute-input" class="input" rows="4" placeholder="Describe the discrepancy — e.g. the platform fee looks higher than 12%, or the payout hasn't arrived after 48 hours…" style="resize:none;font-size:13px;margin-bottom:10px"></textarea>
      <button id="pay-dispute-submit" class="btn btn-primary btn-block" style="padding:14px;font-size:14px">Send to finance team</button>
    </div>`;
  document.body.appendChild(overlay);
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
  document.getElementById('pay-dispute-submit').onclick = async function() {
    const reason = document.getElementById('pay-dispute-input')?.value?.trim();
    if (!reason || reason.length < 10) { showToast('Please describe the issue (at least 10 characters)', 'error'); return; }
    this.textContent = 'Sending…';
    this.disabled = true;
    try {
      // Raise as a dispute with a pay_discrepancy type so ops can route it correctly
      await apiCall('raise-dispute', {
        booking_id:   bookingId,
        reason:       `[PAY DISCREPANCY] ${reason}`,
        dispute_type: 'pay_discrepancy',
      });
      overlay.remove();
      showToast('Pay query sent — our finance team will review within 48 hours', 'success');
      trackEvent('pay_dispute_raised', { booking_id: bookingId });
    } catch (err) {
      this.textContent = 'Send to finance team';
      this.disabled = false;
      showToast(err.message || 'Could not send — please try again', 'error');
    }
  };
};

window.raiseDispute = function(bookingId) {
  document.querySelector('.dispute-modal-overlay')?.remove();
  const overlay = document.createElement('div');
  overlay.className = 'dispute-modal-overlay';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.65);z-index:99999;display:flex;align-items:flex-end;animation:fadeIn .2s ease';
  overlay.innerHTML = `
    <div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:24px 20px 40px">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:16px">
        <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;color:var(--text-dark)">⚠️ Raise a dispute</p>
        <button onclick="document.querySelector('.dispute-modal-overlay')?.remove()" style="background:none;border:none;font-size:20px;cursor:pointer;color:var(--text-muted)">×</button>
      </div>
      <p style="font-size:13px;color:var(--text-mid);line-height:1.6;margin-bottom:16px">Explain what went wrong. Be as specific as possible — this helps us resolve your case faster.</p>
      <textarea id="dispute-reason-input" class="input" rows="4" placeholder="e.g. The fixer did not show up, or the work was not completed as agreed…" style="resize:none;font-size:13px;margin-bottom:6px"></textarea>
      <p style="font-size:11px;color:var(--text-muted);margin-bottom:16px">Your payment stays held in escrow until this is resolved. Our team responds within 24 hours.</p>
      <button id="dispute-submit-btn" class="btn btn-primary btn-block" style="background:var(--danger);border-color:var(--danger);padding:14px;font-size:14px">Submit dispute</button>
    </div>`;
  document.body.appendChild(overlay);

  document.getElementById('dispute-submit-btn').onclick = async function() {
    const reason = document.getElementById('dispute-reason-input')?.value?.trim();
    if (!reason) { showToast('Please describe the issue first.', 'error'); return; }
    this.disabled = true;
    this.textContent = 'Submitting…';
    try {
      const result = await apiCall('raise-dispute', { booking_id: bookingId, reason });
      if (result.success) {
        overlay.remove();
        trackEvent('dispute_raised', { booking_id: bookingId });
        loadActiveJob(bookingId);
        showToast('Dispute submitted — we\'ll review within 24 hours.');
      }
    } catch (err) {
      showToast(err.message, 'error');
      this.disabled = false;
      this.textContent = 'Submit dispute';
    }
  };
};

window.showRequestScreen  = showRequestScreen;
window.showFixerDashboard = showFixerDashboard;
window.showHomeScreen     = showHomeScreen;
window.showBookingsScreen = showBookingsScreen;
window.showMessagesScreen = showMessagesScreen;
window.showProfileScreen  = showProfileScreen;
window.showOfferScreen    = showOfferScreen;
window.loadActiveJob      = loadActiveJob;
window.acceptOffer        = acceptOffer;
window.declineOffer       = declineOffer;
window.updateJobStatus    = updateJobStatus;
window.openChat           = openChat;
window.submitRequest      = submitRequest;
window.cancelBooking      = cancelBooking;
// Alias used in loadBookings() card — cancels a booking from the list view
window.cancelBookingConfirm = cancelBooking;
window.signOut            = signOut;
window.toggleAvailability = toggleAvailability;
window.detectHomeLocation = detectHomeLocation;
window.selectCategory     = selectCategory;
window.loadBookings       = loadBookings;

// ── Message popup helpers ─────────────────────────────────────────
window.handleMsgPopupTap = function() {
  const popup = document.getElementById('msg-popup');
  if (popup) popup.style.display = 'none';
  showMessagesScreen();
};

window.showMsgPopup = function(name, text, bookingId) {
  const popup  = document.getElementById('msg-popup');
  const avatar = document.getElementById('mp-avatar');
  const nameEl = document.getElementById('mp-name');
  const textEl = document.getElementById('mp-text');
  const timeEl = document.getElementById('mp-time');
  if (!popup) return;
  if (avatar) avatar.textContent = (name || '?')[0].toUpperCase();
  if (nameEl) nameEl.textContent = name || 'Message';
  if (textEl) textEl.textContent = text || '';
  if (timeEl) timeEl.textContent = 'now';
  popup.style.display = 'flex';
  setTimeout(() => { popup.style.display = 'none'; }, 5000);
};


// ─────────────────── Screen scaffolding ──────────────────────────
// index.html only ships screen-home. All other screens are injected
// here so classList.add/remove('active') never hits null.
function bootstrapScreens() {
  const app = document.getElementById('main-app');
  if (!app) return;
  const screens = [
    'screen-fixer-dashboard',
    'screen-bookings',
    'screen-messages',
    'screen-chat',
    'screen-profile',
    'screen-request',
    'screen-waiting',
    'screen-offer',
    'screen-job',
    'screen-notifications',
    'screen-admin',
  ];
  screens.forEach(id => {
    if (!document.getElementById(id)) {
      const div = document.createElement('div');
      div.className = 'screen';
      div.id = id;
      app.appendChild(div);
    }
  });
}

// ─────────────────── Notifications ───────────────────────────────

async function showNotificationsScreen() {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screen-notifications').classList.add('active');
  updateActiveNav('notifications');
  const dot = document.getElementById('notif-dot');
  if (dot) dot.style.display = 'none';
  const homeDot = document.getElementById('home-notif-dot');
  if (homeDot) homeDot.style.display = 'none';

  const container = document.getElementById('notifications-list');
  if (!container) return;
  container.innerHTML = '<div style="text-align:center;padding:32px;color:var(--text-muted);font-size:14px">Loading…</div>';

  try {
    const { data: notifs } = await supabaseClient
      .from('notifications')
      .select('*')
      .eq('user_id', currentUser.id)
      .order('created_at', { ascending: false })
      .limit(40);

    if (!notifs || notifs.length === 0) {
      container.innerHTML = `
        <div style="text-align:center;padding:56px 20px;">
          <div style="font-size:56px;margin-bottom:16px;opacity:.5">🔔</div>
          <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;color:var(--text-dark);margin-bottom:8px">All caught up!</p>
          <p style="font-size:13px;color:var(--text-muted);line-height:1.7">Booking updates, messages, and alerts will appear here.</p>
          <button class="btn btn-primary" style="margin-top:20px" onclick="navigate('home')">Browse Services</button>
        </div>`;
      return;
    }

    const iconMap = { booking: '📋', payment: '💰', review: '⭐', message: '💬', payout: '✅', dispute: '⚠️', demand_alert: '🔔' };
    const bgMap  = { booking: '#E8F5EE', payment: '#FDF3E0', review: '#FDF3E0', message: '#E8F0FA', payout: '#E8F5EE', dispute: '#FEE2E2' };

    container.innerHTML = `<div id="notif-items">` + notifs.map(n => {
      const type = n.type || 'booking';
      const icon = iconMap[type] || '🔔';
      const bg   = bgMap[type] || '#F0EBE0';
      const isUnread = !n.read;
      const navDest = type === 'booking' || type === 'payment' ? 'bookings' : type === 'message' ? 'chat-list' : '';
      return `<div class="notif-item ${isUnread ? 'unread' : ''}" data-type="${type}" data-id="${n.id}" data-dest="${navDest}" onclick="handleNotifTap(this.dataset.id,this.dataset.dest)">
        <div class="notif-icon-circle" style="background:${bg}">${icon}</div>
        <div class="notif-body">
          <p class="notif-title ${isUnread ? '' : 'read'}">${escapeHtml(n.message || n.title || 'Notification')}</p>
          ${n.title && n.message && n.title !== n.message ? `<p class="notif-text">${escapeHtml(n.message)}</p>` : ''}
          <p class="notif-time">${timeAgo(n.created_at)}</p>
        </div>
        ${isUnread ? '<div class="notif-unread-dot"></div>' : ''}
      </div>`;
    }).join('') + `</div>`;

    await supabaseClient.from('notifications').update({ read: true }).eq('user_id', currentUser.id).eq('read', false);
  } catch (e) {
    container.innerHTML = '<div style="text-align:center;padding:24px;color:var(--text-muted)">Could not load notifications</div>';
  }
}
window.showNotificationsScreen = showNotificationsScreen;

async function markAllNotifsRead() {
  await supabaseClient.from('notifications').update({ read: true }).eq('user_id', currentUser.id);
  document.querySelectorAll('.notif-item').forEach(el => {
    el.classList.remove('unread');
    el.querySelector('.notif-unread-dot')?.remove();
    const title = el.querySelector('.notif-title'); if (title) title.classList.add('read');
  });
}
window.markAllNotifsRead = markAllNotifsRead;

function filterNotifsByType(type, btn) {
  document.querySelectorAll('#screen-notifications button[id^="notif-filter"]').forEach(b => {
    b.style.background = 'var(--cream)'; b.style.color = 'var(--text-muted)'; b.style.border = '1.5px solid var(--border)';
  });
  btn.style.background = 'var(--forest)'; btn.style.color = '#fff'; btn.style.border = 'none';
  document.querySelectorAll('#notif-items .notif-item').forEach(item => {
    if (type === 'all') item.style.display = '';
    else if (type === 'unread') item.style.display = item.classList.contains('unread') ? '' : 'none';
    else item.style.display = (item.dataset.type === type) ? '' : 'none';
  });
}
window.filterNotifsByType = filterNotifsByType;

async function handleNotifTap(notifId, dest) {
  await supabaseClient.from('notifications').update({ read: true }).eq('id', notifId);
  if (dest) navigate(dest);
}
window.handleNotifTap = handleNotifTap;

// ─────────────────── navigate() — wires bottom nav ───────────────
window.navigate = function(dest) {
  if (dest === 'home') {
    if (currentAdminProfile) showAdminDashboard();
    else if (currentFixerProfile) showFixerDashboard();
    else if (currentUserProfile?.user_role === 'fixer') _showFixerPendingHome();
    else showHomeScreen();
  } else if (dest === 'bookings') {
    if (currentFixerProfile) showFixerJobsScreen();
    else showBookingsScreen('active');
  } else if (dest === 'chat-list') {
    showMessagesScreen();
  } else if (dest === 'profile') {
    showProfileScreen();
  } else if (dest === 'post-job') {
    showHomeScreen();
  } else if (dest === 'notifications') {
    showNotificationsScreen();
  } else if (dest === 'admin') {
    showAdminDashboard();
  }
};

// ─────────────────── Home screen utilities ───────────────────────

let currentCity = '';

function detectHomeLocation() {
  const label = document.getElementById('home-location-label');
  if (label) label.textContent = 'Detecting…';
  if (!navigator.geolocation) {
    if (label) label.textContent = 'Location unavailable';
    return;
  }
  navigator.geolocation.getCurrentPosition(
    (pos) => {
      // Reverse geocode with a free nominatim call (best-effort)
      fetch(`https://nominatim.openstreetmap.org/reverse?lat=${pos.coords.latitude}&lon=${pos.coords.longitude}&format=json`)
        .then(r => r.json())
        .then(d => {
          const suburb = d.address?.suburb || d.address?.town || d.address?.city || 'Your area';
          if (label) label.textContent = suburb;
        })
        .catch(() => { if (label) label.textContent = 'Your area'; });
    },
    () => { if (label) label.textContent = 'Location off'; }
  );
}

function selectCategory(id, emoji, label) {
  showRequestScreen(id, emoji, label);
}

// ─────────────────── Bootstrap ───────────────────────────────────
bootstrapScreens();
// FIX L-02: Restore emergency banner dismiss state across page views within session
if (sessionStorage.getItem('servit_emrg_dismissed')) {
  const emrg = document.getElementById('emergency-banner');
  if (emrg) emrg.style.display = 'none';
}
initAuth();
// NOTE: checkPaymentReturn() is now called inside showApp() after auth resolves,
// so the Supabase realtime subscription has an active session when it's set up.

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.addEventListener('message', (event) => {
    const msg = event.data;
    if (msg?.type === 'NAVIGATE_BOOKING' && msg.bookingId) {
      loadActiveJob(msg.bookingId);
    }
  });
}
// ═══════════════════════════════════════════════════════════════
// ADMIN DASHBOARD
// ═══════════════════════════════════════════════════════════════

async function showAdminDashboard() {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  const screen = document.getElementById('screen-admin');
  if (!screen) { showHomeScreen(); return; }
  screen.classList.add('active');
  // Give the admin a special nav
  _applyAdminNav();
  updateActiveNav('home');
  await renderAdminDashboard();
}
window.showAdminDashboard = showAdminDashboard;

function _applyAdminNav() {
  const nav = document.querySelector('.bottom-nav');
  if (!nav || nav.dataset.adminNav === '1') return;
  nav.dataset.adminNav = '1';
  // Home -> Dashboard
  const homeItem = document.getElementById('nav-home');
  if (homeItem) { const l = homeItem.querySelector('.nav-label'); if (l) l.textContent = 'Overview'; const i = homeItem.querySelector('.nav-icon'); if (i) i.textContent = '📊'; }
  // Bookings -> Bookings (keep but rename)
  const bookItem = document.getElementById('nav-bookings');
  if (bookItem) { const l = bookItem.querySelector('.nav-label'); if (l) l.textContent = 'Bookings'; bookItem.onclick = () => adminShowTab('bookings'); }
  // Messages -> Fixers
  const msgItem = document.getElementById('nav-chat-list');
  if (msgItem) { const l = msgItem.querySelector('.nav-label'); if (l) l.textContent = 'Fixers'; const i = msgItem.querySelector('.nav-icon'); if (i) i.textContent = '🔧'; msgItem.onclick = () => adminShowTab('fixers'); }
  // Notifs -> Users
  const notifItem = document.getElementById('nav-notifications');
  if (notifItem) { const l = notifItem.querySelector('.nav-label'); if (l) l.textContent = 'Users'; const i = notifItem.querySelector('.nav-icon'); if (i) i.textContent = '👥'; notifItem.onclick = () => adminShowTab('users'); }
  // Profile -> Settings (keep)
  const profItem = document.getElementById('nav-profile');
  if (profItem) { const l = profItem.querySelector('.nav-label'); if (l) l.textContent = 'Settings'; }
}

let _adminTab = 'overview';

async function adminShowTab(tab) {
  _adminTab = tab;
  updateActiveNav(tab === 'bookings' ? 'bookings' : tab === 'fixers' ? 'chat-list' : tab === 'users' ? 'notifications' : 'home');
  await renderAdminDashboard();
}
window.adminShowTab = adminShowTab;

async function renderAdminDashboard() {
  const container = document.getElementById('admin-content');
  if (!container) return;
  container.innerHTML = '<div style="text-align:center;padding:40px;color:var(--text-muted)">Loading…</div>';

  if (_adminTab === 'overview') { await _renderAdminOverview(container); return; }
  if (_adminTab === 'bookings') { await _renderAdminBookings(container); return; }
  if (_adminTab === 'fixers')   { await _renderAdminFixers(container); return; }
  if (_adminTab === 'users')    { await _renderAdminUsers(container); return; }
}

async function _renderAdminOverview(container) {
  // Fetch stats in parallel
  const [bkRes, fxRes, usRes, revRes] = await Promise.all([
    supabaseClient.from('bookings').select('id, status, created_at', { count: 'exact' }).limit(1),
    supabaseClient.from('fixers').select('id, available, status', { count: 'exact' }).limit(1),
    supabaseClient.from('profiles').select('id, created_at', { count: 'exact' }).limit(1),
    supabaseClient.from('bookings').select('amount, commission, status').eq('status', 'COMPLETED'),
  ]);

  const totalBookings = bkRes.count || 0;
  const totalFixers   = fxRes.count || 0;
  const totalUsers    = usRes.count || 0;
  const totalRevenue  = revRes.data?.reduce((s, b) => s + (b.commission || 0), 0) || 0;
  const totalPaidOut  = revRes.data?.reduce((s, b) => s + ((b.amount || 0) - (b.commission || 0)), 0) || 0;

  // Recent bookings
  const { data: recent } = await supabaseClient
    .from('bookings')
    .select('id, description, status, amount, commission, created_at, fixers!fixer_id(full_name)')
    .order('created_at', { ascending: false })
    .limit(8);

  // Active fixers count
  const { count: onlineFixers } = await supabaseClient
    .from('fixers').select('*', { count: 'exact', head: true }).eq('available', true);

  // Disputed bookings
  const { count: disputes } = await supabaseClient
    .from('bookings').select('*', { count: 'exact', head: true }).eq('status', 'DISPUTED');

  const statusColors = { SEARCHING:'#E8F0FA', OFFERED:'#FDF3E0', CONFIRMED:'#E8F5EE', EN_ROUTE:'#E8F0FA', ARRIVED:'#E8F0FA', IN_PROGRESS:'#FDF3E0', PENDING_COMPLETION:'#FFF3CD', COMPLETED:'#E8F5EE', CANCELLED:'#F5F5F5', DISPUTED:'#FEE2E2', EXPIRED:'#F5F5F5' };
  const statusText   = { SEARCHING:'var(--info)', OFFERED:'var(--gold-dark)', CONFIRMED:'var(--success)', EN_ROUTE:'var(--info)', ARRIVED:'var(--info)', IN_PROGRESS:'var(--gold-dark)', PENDING_COMPLETION:'#856404', COMPLETED:'var(--success)', CANCELLED:'var(--text-muted)', DISPUTED:'var(--danger)', EXPIRED:'var(--text-muted)' };

  container.innerHTML = `
    <!-- Admin Header -->
    <div style="background:linear-gradient(160deg,#0F2A1A 0%,#1A3A2A 60%,#0F1F12 100%);padding:20px 18px 22px;position:relative;overflow:hidden">
      <div style="position:absolute;top:-20px;right:-20px;width:100px;height:100px;border-radius:50%;background:rgba(201,148,58,.08);pointer-events:none"></div>
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:16px">
        <div>
          <p style="font-size:10px;color:rgba(255,255,255,.45);font-weight:600;letter-spacing:1px;text-transform:uppercase;margin-bottom:3px">Admin Console</p>
          <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;color:#fff">Ser<span style="color:var(--gold-light)">vit</span> Dashboard</p>
        </div>
        <div style="width:42px;height:42px;border-radius:50%;background:var(--gold);display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:700;color:#fff;border:2px solid rgba(255,255,255,.2)">
          ${(currentUserProfile?.full_name || 'A')[0].toUpperCase()}
        </div>
      </div>
      <!-- KPI row -->
      <div style="display:grid;grid-template-columns:repeat(2,1fr);gap:8px">
        <div style="background:rgba(255,255,255,.1);border-radius:var(--r-md);padding:12px">
          <p style="font-family:'Playfair Display',serif;font-size:22px;font-weight:700;color:var(--gold-light)">${formatZAR(totalRevenue)}</p>
          <p style="font-size:10px;color:rgba(255,255,255,.55);font-weight:600;letter-spacing:.3px;margin-top:2px">Commission Revenue</p>
        </div>
        <div style="background:rgba(255,255,255,.1);border-radius:var(--r-md);padding:12px">
          <p style="font-family:'Playfair Display',serif;font-size:22px;font-weight:700;color:var(--gold-light)">${formatZAR(totalPaidOut)}</p>
          <p style="font-size:10px;color:rgba(255,255,255,.55);font-weight:600;letter-spacing:.3px;margin-top:2px">Paid to Fixers</p>
        </div>
      </div>
    </div>

    <!-- Quick stats row -->
    <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:0;border-bottom:1px solid var(--border);background:var(--warm-white)">
      ${[
        { val: totalBookings, lbl: 'Bookings', icon: '📋' },
        { val: totalFixers,   lbl: 'Fixers',   icon: '🔧' },
        { val: totalUsers,    lbl: 'Users',     icon: '👥' },
        { val: disputes || 0, lbl: 'Disputes',  icon: '⚠️', danger: (disputes||0) > 0 },
      ].map((s, i) => `
        <div style="padding:12px 6px;text-align:center;${i < 3 ? 'border-right:1px solid var(--border)' : ''}">
          <p style="font-size:10px;margin-bottom:3px">${s.icon}</p>
          <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;color:${s.danger ? 'var(--danger)' : 'var(--forest)'}">${s.val}</p>
          <p style="font-size:9px;color:var(--text-muted);font-weight:600;letter-spacing:.3px">${s.lbl}</p>
        </div>`).join('')}
    </div>

    <!-- Live status -->
    <div style="padding:14px 16px 0">
      <div style="display:flex;gap:10px;flex-wrap:wrap;margin-bottom:14px">
        <div style="background:var(--card-bg);border:1px solid var(--border);border-radius:var(--r-md);padding:10px 14px;flex:1;min-width:110px;text-align:center">
          <div style="display:flex;align-items:center;justify-content:center;gap:5px;margin-bottom:4px">
            <span style="width:8px;height:8px;background:#4ADE80;border-radius:50%;box-shadow:0 0 0 3px rgba(74,222,128,.2)"></span>
            <p style="font-size:12px;font-weight:700;color:var(--success)">${onlineFixers || 0} Online</p>
          </div>
          <p style="font-size:11px;color:var(--text-muted)">Fixers available now</p>
        </div>
        ${disputes ? `
        <div style="background:#FEE2E2;border:1px solid var(--danger);border-radius:var(--r-md);padding:10px 14px;flex:1;min-width:110px;text-align:center;cursor:pointer" onclick="adminShowTab('bookings')">
          <p style="font-size:12px;font-weight:700;color:var(--danger);margin-bottom:3px">⚠️ ${disputes} Dispute${disputes > 1 ? 's' : ''}</p>
          <p style="font-size:11px;color:var(--danger);opacity:.8">Tap to review →</p>
        </div>` : ''}
      </div>

      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:10px">
        <p style="font-size:11px;font-weight:700;color:var(--text-muted);letter-spacing:.6px;text-transform:uppercase">Recent Bookings</p>
        <button onclick="adminShowTab('bookings')" style="font-size:11px;font-weight:600;color:var(--gold-dark);background:none;border:none;cursor:pointer">View all →</button>
      </div>
    </div>

    <div style="padding:0 16px 20px">
      ${recent?.map(b => `
        <div style="background:var(--card-bg);border:1px solid var(--border);border-radius:var(--r-md);padding:11px 14px;margin-bottom:8px;display:flex;align-items:center;gap:10px">
          <div style="flex:1;min-width:0">
            <p style="font-weight:600;font-size:13px;margin-bottom:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${escapeHtml(b.description || 'Service')}</p>
            <p style="font-size:11px;color:var(--text-muted)">${b.fixers?.full_name ? `🔧 ${escapeHtml(b.fixers.full_name)} · ` : ''}${new Date(b.created_at).toLocaleDateString('en-ZA',{day:'numeric',month:'short'})}</p>
          </div>
          <div style="text-align:right;flex-shrink:0">
            <p style="font-weight:700;color:var(--forest);font-size:13px">${formatZAR(b.amount||0)}</p>
            <span style="font-size:9px;font-weight:700;padding:2px 6px;border-radius:8px;background:${statusColors[b.status]||'#f5f5f5'};color:${statusText[b.status]||'#666'}">${b.status}</span>
          </div>
        </div>`).join('') || '<p style="text-align:center;color:var(--text-muted);padding:20px">No bookings yet</p>'}
    </div>`;
}

async function _renderAdminBookings(container) {
  // FIX: Join disputes so adminResolveDispute has the dispute_id (not booking_id).
  // The resolve-dispute backend requires dispute_id + outcome — previously we were
  // passing booking_id + resolution which caused a 400 every time an admin resolved
  // a dispute from this dashboard.
  const { data: bookings } = await supabaseClient
    .from('bookings')
    .select('*, fixers!fixer_id(full_name), profiles!customer_id(full_name), disputes(id)')
    .order('created_at', { ascending: false })
    .limit(50);

  const statusColors = { SEARCHING:'#E8F0FA', OFFERED:'#FDF3E0', CONFIRMED:'#E8F5EE', EN_ROUTE:'#E8F0FA', ARRIVED:'#E8F0FA', IN_PROGRESS:'#FDF3E0', PENDING_COMPLETION:'#FFF3CD', COMPLETED:'#E8F5EE', CANCELLED:'#F5F5F5', DISPUTED:'#FEE2E2', EXPIRED:'#F5F5F5' };
  const statusText   = { SEARCHING:'var(--info)', OFFERED:'var(--gold-dark)', CONFIRMED:'var(--success)', EN_ROUTE:'var(--info)', IN_PROGRESS:'var(--gold-dark)', PENDING_COMPLETION:'#856404', COMPLETED:'var(--success)', CANCELLED:'var(--text-muted)', DISPUTED:'var(--danger)', EXPIRED:'var(--text-muted)' };

  container.innerHTML = `
    <div style="background:linear-gradient(160deg,#0F2A1A,#1A3A2A);padding:16px 18px 14px">
      <p style="font-size:10px;color:rgba(255,255,255,.45);font-weight:600;letter-spacing:.8px;text-transform:uppercase;margin-bottom:3px">Admin Console</p>
      <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;color:#fff">All Bookings</p>
    </div>
    <div style="padding:8px 16px;background:var(--warm-white);border-bottom:1px solid var(--border);display:flex;gap:6px;overflow-x:auto;scrollbar-width:none">
      ${['ALL','SEARCHING','CONFIRMED','EN_ROUTE','IN_PROGRESS','COMPLETED','DISPUTED','CANCELLED'].map(s => `
        <button onclick="adminFilterBookings('${s}',this)" style="flex-shrink:0;padding:4px 12px;border-radius:20px;font-size:10px;font-weight:600;border:1.5px solid var(--border);background:${s==='ALL'?'var(--forest)':'var(--cream)'};color:${s==='ALL'?'#fff':'var(--text-muted)'};cursor:pointer" id="admin-bk-filter-${s}">${s}</button>`).join('')}
    </div>
    <div id="admin-bookings-list" style="padding:14px 16px">
      ${bookings?.length ? bookings.map(b => `
        <div class="admin-bk-item" data-status="${b.status}" style="background:var(--card-bg);border:1px solid ${b.status==='DISPUTED'?'var(--danger)':b.status==='COMPLETED'?'rgba(45,122,79,.2)':'var(--border)'};border-radius:var(--r-md);padding:12px 14px;margin-bottom:8px">
          <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:8px;margin-bottom:8px">
            <div style="flex:1;min-width:0">
              <p style="font-weight:700;font-size:13px;margin-bottom:2px">${escapeHtml(b.description || 'Service')}</p>
              <p style="font-size:11px;color:var(--text-muted)">👤 ${escapeHtml(b.profiles?.full_name || 'Customer')}${b.fixers?.full_name ? ` · 🔧 ${escapeHtml(b.fixers.full_name)}` : ''}</p>
              <p style="font-size:11px;color:var(--text-muted)">📍 ${escapeHtml(b.address || '—')} · ${new Date(b.created_at).toLocaleDateString('en-ZA',{day:'numeric',month:'short',year:'2-digit'})}</p>
            </div>
            <div style="text-align:right;flex-shrink:0">
              <p style="font-weight:700;color:var(--forest);font-size:14px">${formatZAR(b.amount||0)}</p>
              <p style="font-size:10px;color:var(--success);font-weight:600">+${formatZAR(b.commission||0)} fee</p>
              <span style="font-size:9px;font-weight:700;padding:2px 7px;border-radius:8px;display:inline-block;margin-top:4px;background:${statusColors[b.status]||'#f5f5f5'};color:${statusText[b.status]||'#666'}">${b.status}</span>
            </div>
          </div>
          ${b.status === 'DISPUTED' ? (() => {
            // FIX: resolve-dispute backend expects dispute_id (not booking_id) and
            // outcome values of 'pay_fixer' | 'refund_customer' (not 'COMPLETED'/'CANCELLED').
            // The dispute row is fetched via the disputes(id) join above.
            const disputeId = (b.disputes && b.disputes[0]) ? b.disputes[0].id : null;
            if (!disputeId) return `<p style="font-size:11px;color:var(--text-muted);padding:8px 0;border-top:1px solid var(--border);margin-top:4px">⚠️ No dispute record found — check DB</p>`;
            return `
            <div style="display:flex;gap:6px;border-top:1px solid var(--border);padding-top:8px">
              <button onclick="adminResolveDispute('${disputeId}','pay_fixer')" style="flex:1;background:var(--success);color:#fff;border:none;border-radius:var(--r-sm);padding:7px;font-size:11px;font-weight:600;cursor:pointer">✓ Resolve — Pay Fixer</button>
              <button onclick="adminResolveDispute('${disputeId}','refund_customer')" style="flex:1;background:none;border:1.5px solid var(--danger);color:var(--danger);border-radius:var(--r-sm);padding:7px;font-size:11px;font-weight:600;cursor:pointer">✕ Resolve — Refund Customer</button>
            </div>`;
          })() : ''}
        </div>`).join('') : '<p style="text-align:center;color:var(--text-muted);padding:40px">No bookings</p>'}
    </div>`;
}
window.adminFilterBookings = function(status, btn) {
  document.querySelectorAll('[id^="admin-bk-filter-"]').forEach(b => { b.style.background = 'var(--cream)'; b.style.color = 'var(--text-muted)'; });
  btn.style.background = 'var(--forest)'; btn.style.color = '#fff';
  document.querySelectorAll('.admin-bk-item').forEach(item => {
    item.style.display = (status === 'ALL' || item.dataset.status === status) ? '' : 'none';
  });
};
window.adminResolveDispute = async function(disputeId, outcome) {
  // FIX: Backend resolve-dispute expects { dispute_id, outcome } where outcome is
  // one of: refund_customer | pay_fixer | split | dismissed
  // Previously we passed { booking_id, resolution } with values 'COMPLETED'/'CANCELLED'
  // which caused a 400 on every admin dispute resolution.
  const label = outcome === 'pay_fixer' ? 'Resolve — Pay Fixer (release to fixer)' : 'Resolve — Refund Customer (refund payment)';
  const ok = await new Promise(resolve => {
    const s = document.createElement('div');
    s.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.55);z-index:9999;display:flex;align-items:flex-end';
    s.innerHTML = `<div style="background:var(--warm-white);border-radius:var(--r-xl) var(--r-xl) 0 0;width:100%;max-width:480px;margin:0 auto;padding:28px 20px 44px;animation:slideUp .28s ease">
      <p style="font-family:'Playfair Display',serif;font-size:20px;font-weight:700;margin-bottom:8px">Resolve dispute?</p>
      <p style="font-size:13px;color:var(--text-muted);line-height:1.7;margin-bottom:20px">This action will notify both the customer and the fixer.</p>
      <div style="display:flex;gap:10px">
        <button id="_ar-no" class="btn btn-outline" style="flex:1">Go back</button>
        <button id="_ar-yes" class="btn ${outcome === 'pay_fixer' ? 'btn-primary' : ''}" style="flex:1;${outcome === 'refund_customer' ? 'background:transparent;border:1.5px solid var(--danger);color:var(--danger)' : ''}">${label}</button>
      </div></div>`;
    document.body.appendChild(s);
    s.addEventListener('click', e => { if (e.target === s) { s.remove(); resolve(false); } });
    s.querySelector('#_ar-no').onclick = () => { s.remove(); resolve(false); };
    s.querySelector('#_ar-yes').onclick = () => { s.remove(); resolve(true); };
  });
  if (!ok) return;
  try {
    await apiCall('resolve-dispute', { dispute_id: disputeId, outcome });
    showToast(`Dispute resolved: ${outcome.replace('_', ' ')}`, 'success');
    await renderAdminDashboard();
  } catch (err) {
    showToast('Failed to resolve dispute: ' + err.message, 'error');
  }
};

async function _renderAdminFixers(container) {
  const { data: fixers } = await supabaseClient
    .from('fixers')
    .select('*')
    .order('created_at', { ascending: false });

  container.innerHTML = `
    <div style="background:linear-gradient(160deg,#0F2A1A,#1A3A2A);padding:16px 18px 14px">
      <p style="font-size:10px;color:rgba(255,255,255,.45);font-weight:600;letter-spacing:.8px;text-transform:uppercase;margin-bottom:3px">Admin Console</p>
      <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;color:#fff">Fixer Management</p>
    </div>
    <div style="padding:8px 16px;background:var(--warm-white);border-bottom:1px solid var(--border);display:flex;gap:6px;overflow-x:auto;scrollbar-width:none">
      ${['ALL','approved','pending','suspended'].map((s,i) => `
        <button onclick="adminFilterFixers('${s}',this)" style="flex-shrink:0;padding:4px 12px;border-radius:20px;font-size:10px;font-weight:600;border:1.5px solid var(--border);background:${i===0?'var(--forest)':'var(--cream)'};color:${i===0?'#fff':'var(--text-muted)'};cursor:pointer">${s.charAt(0).toUpperCase()+s.slice(1)}</button>`).join('')}
    </div>
    <div id="admin-fixers-list" style="padding:14px 16px">
      ${fixers?.length ? fixers.map(f => `
        <div class="admin-fx-item" data-status="${f.status||'approved'}" style="background:var(--card-bg);border:1px solid var(--border);border-radius:var(--r-md);padding:13px 14px;margin-bottom:8px">
          <div style="display:flex;align-items:center;gap:12px;margin-bottom:10px">
            <div style="width:44px;height:44px;border-radius:50%;background:var(--forest-mid);display:flex;align-items:center;justify-content:center;color:#fff;font-size:18px;font-weight:700;flex-shrink:0">${(f.full_name||'?')[0].toUpperCase()}</div>
            <div style="flex:1;min-width:0">
              <div style="display:flex;align-items:center;gap:6px;margin-bottom:2px">
                <p style="font-weight:700;font-size:14px">${escapeHtml(f.full_name||'—')}</p>
                <span style="font-size:9px;font-weight:700;padding:2px 7px;border-radius:8px;background:${f.available?'#E8F5EE':'#F5F5F5'};color:${f.available?'var(--success)':'var(--text-muted)'}">${f.available?'ONLINE':'OFFLINE'}</span>
              </div>
              <p style="font-size:11px;color:var(--text-muted)">${getCategoryEmoji(f.category)} ${escapeHtml(f.category||'—')} · 📍 ${escapeHtml(f.city||'—')}</p>
              <p style="font-size:11px;color:var(--text-muted)">⭐ ${f.rating?.toFixed(1)||'New'} · ${f.review_count||0} reviews · ${formatZAR(f.price||0)}/${f.price_type||'hr'}</p>
            </div>
            <div style="text-align:right;flex-shrink:0">
              <span style="font-size:10px;font-weight:700;padding:3px 9px;border-radius:10px;background:${f.status==='approved'?'#E8F5EE':f.status==='pending'?'#FDF3E0':'#FEE2E2'};color:${f.status==='approved'?'var(--success)':f.status==='pending'?'var(--gold-dark)':'var(--danger)'}">${(f.status||'approved').toUpperCase()}</span>
            </div>
          </div>
          <div style="display:flex;gap:6px;border-top:1px solid var(--border);padding-top:8px">
            ${f.status !== 'approved' ? `<button onclick="adminSetFixerStatus('${f.id}','approved')" style="flex:1;background:var(--success);color:#fff;border:none;border-radius:var(--r-sm);padding:7px;font-size:11px;font-weight:600;cursor:pointer">✓ Approve</button>` : ''}
            ${f.status !== 'suspended' ? `<button onclick="adminSetFixerStatus('${f.id}','suspended')" style="flex:1;background:none;border:1.5px solid var(--danger);color:var(--danger);border-radius:var(--r-sm);padding:7px;font-size:11px;font-weight:600;cursor:pointer">⊘ Suspend</button>` : `<button onclick="adminSetFixerStatus('${f.id}','approved')" style="flex:1;background:var(--success);color:#fff;border:none;border-radius:var(--r-sm);padding:7px;font-size:11px;font-weight:600;cursor:pointer">✓ Reinstate</button>`}
            ${f.phone ? `<button data-fixerphone="${escapeHtml(f.phone)}" onclick="window.open('tel:'+this.dataset.fixerphone)" style="flex:1;background:none;border:1.5px solid var(--border);color:var(--text-mid);border-radius:var(--r-sm);padding:7px;font-size:11px;font-weight:600;cursor:pointer">📞 Call</button>` : ''}
          </div>
        </div>`).join('') : '<p style="text-align:center;color:var(--text-muted);padding:40px">No fixers registered yet</p>'}
    </div>`;
}
window.adminFilterFixers = function(status, btn) {
  document.querySelectorAll('[id^="admin-bk-filter-"],[style*="admin-fx"]').forEach(b => { if (b.tagName === 'BUTTON') { b.style.background = 'var(--cream)'; b.style.color = 'var(--text-muted)'; } });
  btn.style.background = 'var(--forest)'; btn.style.color = '#fff';
  document.querySelectorAll('.admin-fx-item').forEach(item => {
    item.style.display = (status === 'ALL' || item.dataset.status === status) ? '' : 'none';
  });
};
window.adminSetFixerStatus = async function(fixerId, status) {
  // FIX v8.9.3: was a raw supabaseClient.from('fixers').update() that silently failed
  // because the fixers_update_own RLS policy blocks admin users (auth.uid() ≠ fixer.user_id).
  // Now routes through admin-override.js which uses the service key and writes an audit row.
  try {
    const token = (await supabaseClient.auth.getSession())?.data?.session?.access_token;
    const res = await fetch('/.netlify/functions/admin-override', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ action: 'set_fixer_status', fixer_id: fixerId, new_status: status }),
    });
    const data = await res.json();
    if (data.success) {
      showToast(`Fixer ${status}`, 'success');
      await renderAdminDashboard();
    } else {
      showToast(data.error || 'Update failed', 'error');
    }
  } catch (e) {
    console.error('[Admin] set_fixer_status error:', e);
    showToast('Update failed', 'error');
  }
};

async function _renderAdminUsers(container) {
  const { data: users } = await supabaseClient
    .from('profiles')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(40);

  container.innerHTML = `
    <div style="background:linear-gradient(160deg,#0F2A1A,#1A3A2A);padding:16px 18px 14px">
      <p style="font-size:10px;color:rgba(255,255,255,.45);font-weight:600;letter-spacing:.8px;text-transform:uppercase;margin-bottom:3px">Admin Console</p>
      <p style="font-family:'Playfair Display',serif;font-size:18px;font-weight:700;color:#fff">User Management</p>
    </div>
    <div style="padding:10px 16px;background:var(--warm-white);border-bottom:1px solid var(--border)">
      <div style="background:var(--cream);border:1.5px solid var(--border);border-radius:var(--r-md);padding:8px 12px;display:flex;align-items:center;gap:8px">
        <span style="color:var(--text-muted)">🔍</span>
        <input id="admin-user-search" placeholder="Search users…" oninput="adminSearchUsers(this.value)" style="flex:1;border:none;background:transparent;font-family:'DM Sans',sans-serif;font-size:13px;outline:none">
      </div>
    </div>
    <div id="admin-users-list" style="padding:14px 16px">
      ${users?.length ? users.map(u => `
        <div class="admin-user-item" data-name="${(u.full_name||u.email||'').toLowerCase()}" data-email="${(u.email||'').toLowerCase()}" style="background:var(--card-bg);border:1px solid var(--border);border-radius:var(--r-md);padding:12px 14px;margin-bottom:8px;display:flex;align-items:center;gap:12px">
          <div style="width:40px;height:40px;border-radius:50%;background:var(--forest);display:flex;align-items:center;justify-content:center;color:var(--gold-light);font-size:16px;font-weight:700;flex-shrink:0">${(u.full_name||u.email||'?')[0].toUpperCase()}</div>
          <div style="flex:1;min-width:0">
            <p style="font-weight:600;font-size:13px;margin-bottom:1px">${escapeHtml(u.full_name||'—')}</p>
            <p style="font-size:11px;color:var(--text-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${escapeHtml(u.email||'—')}</p>
            <p style="font-size:10px;color:var(--text-muted)">Joined ${new Date(u.created_at||Date.now()).toLocaleDateString('en-ZA',{month:'short',year:'numeric'})}</p>
          </div>
          ${u.is_admin ? '<span style="font-size:9px;font-weight:700;background:#FDF3E0;color:var(--gold-dark);padding:2px 8px;border-radius:8px;flex-shrink:0">ADMIN</span>' : ''}
        </div>`).join('') : '<p style="text-align:center;color:var(--text-muted);padding:40px">No users found</p>'}
    </div>`;
}
window.adminSearchUsers = function(q) {
  const lq = q.toLowerCase();
  document.querySelectorAll('.admin-user-item').forEach(item => {
    item.style.display = (!lq || item.dataset.name.includes(lq) || item.dataset.email.includes(lq)) ? '' : 'none';
  });
};

// Register admin screen in screen list so navigation works
const _origScreenIds = window._SCREEN_IDS || [];
if (!_origScreenIds.includes('screen-admin')) {
  _origScreenIds.push('screen-admin');
  window._SCREEN_IDS = _origScreenIds;
}
