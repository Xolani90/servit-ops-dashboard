// Only load .env in non-production environments or when critical env vars are missing
if (process.env.NODE_ENV !== 'production' && !process.env.SUPABASE_URL) {
  require('./_env');
}
// ═══════════════════════════════════════════════════════════════
// create-booking — v8.6
// Fixes vs v8.3:
//  • BUG 1: Extract city from address string before calling RPC.
//    p_city was receiving the full address ("15 Berea Rd, Durban, 4001")
//    which never matched fixer.city. City is now extracted server-side.
//  • BUG 2: p_description and p_customer_phone are now passed directly
//    into create_booking_idempotent so the row is complete at creation.
//    The patch call is kept for coords/mode/tier but description and
//    phone are no longer in it (they are already on the row).
//  • BUG 6: Idempotency key is NOT cleared after the API call succeeds.
//    It is only cleared on ?payment=success (confirmed by webhook).
//    This means a failed Yoco redirect still retries with the same key.
//  • BUG 7: Removed the _marketplace.createBooking() call that ran
//    BEFORE createBooking() — this caused a double booking on every
//    device where window._marketplace was defined. The marketplace
//    wrapper was creating a booking via RPC, then createBooking() was
//    calling the Netlify function (which creates ANOTHER booking).
//  • BUG 5 FIX (v8.6): Added DB-side rate limiting (10 creates / hour
//    per user). Uses check_rate_limit() RPC added in v8_6_bugfixes.sql.
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');
const { randomUUID }   = require('crypto');
// Node 14 doesn't have crypto.randomUUID() globally — alias it
if (typeof crypto === 'undefined') global.crypto = { randomUUID };

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

// BUG 5 FIX: Rate limit constants
const RATE_LIMIT_ACTION   = 'create_booking';
const RATE_LIMIT_MAX      = 10;     // max calls
const RATE_LIMIT_WINDOW   = 3600;   // per hour (seconds)

const VALID_TIERS = ['basic', 'standard', 'premium'];
const TIER_MIN_AMOUNT = { basic: 50, standard: 150, premium: 300 };

// BUG 1 FIX: Extract a city name from a full address string.
// "15 Berea Rd, Durban, 4001" → "Durban"
// "Sandton, Johannesburg" → "Johannesburg"
// "Cape Town" → "Cape Town"
// Never throws — returns the last fallback if heuristics produce nothing.
function extractCityFromAddress(address) {
  if (!address) return '';
  const trimmed = address.trim();
  if (!trimmed.includes(',')) return trimmed; // already a bare city/suburb

  // Split on commas, strip whitespace, discard bare postcodes (pure digits)
  const parts = trimmed
    .split(',')
    .map(p => p.trim())
    .filter(p => p.length > 1 && !/^\d{4,5}$/.test(p));

  if (parts.length === 0) return trimmed;

  // Prefer the second-to-last or last part: in SA addresses the pattern is
  // "street, suburb, city, postcode" so city is typically the penultimate token.
  // If there are only 2 parts (suburb, city), return the last.
  if (parts.length === 1) return parts[0];
  if (parts.length === 2) return parts[1];
  // 3+ parts: return the second-to-last (city is before the postcode)
  return parts[parts.length - 2];
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS_HEADERS };
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };

  try {
    // BUG 7 FIX: Removed ENV CHECK console.log — it leaked Supabase key names to
    // Netlify logs (log4j-style info disclosure). Gate on DEBUG_ENV if needed locally:
    // if (process.env.DEBUG_ENV) console.log('ENV CHECK:', ...);
    const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });
    const YOCO_SECRET_KEY = process.env.YOCO_SECRET_KEY;
    const authHeader = event.headers.authorization;
    if (!authHeader) return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Unauthorized' }) };

    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid token' }) };

    // ── BUG 5 FIX: Rate limit check ─────────────────────────────
    const { data: allowed, error: rlError } = await supabase.rpc('check_rate_limit', {
      p_user_id:        user.id,
      p_action:         RATE_LIMIT_ACTION,
      p_max_calls:      RATE_LIMIT_MAX,
      p_window_seconds: RATE_LIMIT_WINDOW,
    });
    if (rlError) {
      console.error('Rate limit check error:', rlError.message);
      // Fail open — do not block legitimate traffic on a rate-limit DB error
    } else if (!allowed) {
      return {
        statusCode: 429,
        headers: { ...CORS_HEADERS, 'Retry-After': '3600' },
        body: JSON.stringify({ error: 'Rate limit exceeded. Try again later.' }),
      };
    }

    const {
      description, address, phone, amount,
      category       = null,
      serviceTier    = 'standard',
      serviceType    = 'mobile',  // 'mobile' | 'venue' — determines who pays the blended fee
      bookingMode    = 'asap',
      scheduledFor   = null,
      latitude       = null,
      longitude      = null,
      idempotencyKey = null,   // UUID generated client-side; prevents duplicate bookings on retry
    } = JSON.parse(event.body || '{}');

    if (!description || !address || !amount || amount <= 0) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Missing required fields' }) };
    }

    const tier = VALID_TIERS.includes(serviceTier) ? serviceTier : 'standard';
    const minAmount = TIER_MIN_AMOUNT[tier];
    if (amount < minAmount) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: `Minimum amount for ${tier} tier is R${minAmount}` }) };
    }

    console.log('Step 1: auth passed, user:', user.id);
    console.log('Step 2: calling create_booking_idempotent RPC...');

    // Use the idempotent RPC so Netlify retries and client double-taps are safe.
    // The client should send a UUID it generated with crypto.randomUUID() and
    // stored in sessionStorage for this booking session; if absent we generate
    // one here (still safe — just loses cross-retry deduplication for that call).
    const iKey = idempotencyKey || crypto.randomUUID();

    // BUG 1 FIX: Extract the city name from the full address string.
    // Previously: p_city: address → "15 Berea Rd, Durban, 4001" → never matches fixer.city
    // Now:        p_city: extractCityFromAddress(address) → "Durban" → matches correctly
    const city = extractCityFromAddress(address);

    const { data: bookingResult, error: bookingError } = await supabase.rpc('create_booking_idempotent', {
      p_customer_id:     user.id,
      p_category:        category || null,
      p_service_tier:    tier,
      p_address:         address,
      p_city:            city,             // BUG 1 FIX: city, not full address
      p_idempotency_key: iKey,
      p_service_amount:  amount,
      p_description:     description || null,  // BUG 2 FIX: no longer left to patch call
      p_customer_phone:  phone || null,         // BUG 2 FIX: no longer left to patch call
    });

    console.log('Step 3: RPC result:', JSON.stringify({bookingResult, bookingError}));
    if (bookingError) {
      console.error('Booking creation error:', bookingError);
      return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: bookingError.message }) };
    }
    if (!bookingResult?.ok) {
      return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Booking creation failed' }) };
    }

    const bookingId = bookingResult.booking_id;

    // ── Idempotent replay: booking already exists ─────────────────
    // Skip the patch and create_payment_session — the row and payment
    // session are already committed. Look up the existing checkout URL
    // from the payments table and return it directly.
    if (bookingResult.idempotent) {
      console.log('Step 3b: idempotent replay — fetching existing checkout URL for booking', bookingId);
      const { data: existingPayment, error: existingPaymentError } = await supabase
        .from('payments')
        .select('id, provider_checkout_url')
        .eq('booking_id', bookingId)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (existingPaymentError || !existingPayment?.provider_checkout_url) {
        console.error('Idempotent replay: no checkout URL found, will re-create payment session');
        // Fall through to create a new payment session below
      } else {
        console.log('Step 3b: returning existing checkout URL', existingPayment.provider_checkout_url);
        return {
          statusCode: 200,
          headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            booking_id:   bookingId,
            payment_id:   existingPayment.id,
            checkout_url: existingPayment.provider_checkout_url,
            tier,
            idempotent:   true,
          }),
        };
      }
    }

    // ── Patch remaining fields (coords, mode, scheduled time) ─────
    // Uses a service-role RPC wrapper to bypass RLS on the bookings table.
    // The direct .update() call was hitting RLS even with the service key
    // because the table has restrictive policies — going via RPC avoids this.
    const patchFields = {
      service_tier: tier,
      ...(bookingMode  && { booking_mode: bookingMode }),
      ...(scheduledFor && { scheduled_for: scheduledFor }),
      ...(latitude     && { customer_latitude: latitude }),
      ...(longitude    && { customer_longitude: longitude }),
    };

    if (latitude && longitude) {
      supabase.from('booking_events').insert({
        booking_id:  bookingId,
        event_type:  'coordinates_received',
        new_status:  'CREATED',
        created_by:  user.id,
        metadata:    { latitude, longitude, match_method: 'haversine' },
      }).then(() => {}); // fire-and-forget
    }

    // BUG 15 FIX (v8.9.2): Use patch_booking_fields SECURITY DEFINER RPC instead of a
    // direct .update() which silently fails RLS even with the service key.
    // The RPC performs an ownership check then bypasses RLS safely.
    const { data: patchResult, error: patchError } = await supabase.rpc('patch_booking_fields', {
      p_booking_id:    bookingId,
      p_customer_id:   user.id,
      p_service_tier:  patchFields.service_tier  || null,
      p_booking_mode:  patchFields.booking_mode  || null,
      p_scheduled_for: patchFields.scheduled_for || null,
      p_latitude:      patchFields.customer_latitude  || null,
      p_longitude:     patchFields.customer_longitude || null,
    });
    if (patchError) {
      // RPC call itself failed (DB connection issue etc.) — log as warning, not fatal
      console.warn('[create-booking] patch_booking_fields RPC error (non-fatal):', patchError.message);
    } else if (patchResult && !patchResult.ok) {
      // RPC returned a structured error — log the reason for operators
      console.warn('[create-booking] patch_booking_fields refused patch:', patchResult.error, { bookingId });
    }

    console.log('Step 4: calling create_payment_session...');
    const { data: paymentResult, error: paymentError } = await supabase.rpc('create_payment_session', {
      p_booking_id:  bookingId,
      p_customer_id: user.id,
      p_amount:      amount,
    });

    console.log('Step 5: payment result:', JSON.stringify({paymentResult, paymentError}));
    if (paymentError) {
      return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: paymentError.message || 'Failed to create payment session' }) };
    }

    // FIX A: Netlify auto-injects process.env.URL as the live site URL.
    // APP_URL takes precedence (set this to your custom domain in Netlify dashboard).
    // Without this fix, APP_URL missing in prod defaulted to localhost — Yoco
    // redirected the customer there after payment and checkPaymentReturn() never fired.
    // FIX (v8.9 BUG 3): APP_URL must point to the live domain so Yoco redirects
    // the customer back to the real app after payment.  If APP_URL is missing in
    // production Netlify injects process.env.URL automatically.  The only dangerous
    // case is APP_URL set to localhost in .env — we detect and warn loudly.
    const appUrl = process.env.APP_URL || process.env.URL || 'http://localhost:8888';
    if ((appUrl.includes('localhost') || appUrl.includes('localhost:8888')) && process.env.NODE_ENV !== 'development') {
      console.error('[FATAL CONFIG] APP_URL resolves to localhost in a non-development environment. ' +
        'Yoco will redirect customers to localhost after payment — they will be stranded. ' +
        'Set APP_URL=https://your-domain.com in the Netlify dashboard immediately.');
    }
    // ── Fee split (mirrors frontend updatePricePreview + handleRequestContinue) ──
    // MOBILE: customer pays exactly their quoted `amount`. Platform fee (15%, min R15)
    //         is deducted from the fixer's payout. Yoco fee is absorbed by Servit.
    //         Yoco is charged the raw `amount` — platform fee comes out of what Servit remits to the fixer.
    // VENUE:  provider sets a fixed price. Customer pays that price + platform fee on top.
    //         Yoco is charged `amount + platformFee` — fixer always gets full `amount`.
    const platformFee  = Math.max(amount * 0.15, 15);
    const isVenue      = serviceType === 'venue';
    let   totalCharged;
    if (isVenue) {
      totalCharged    = amount + platformFee;
    } else {
      totalCharged    = amount;  // customer pays exactly their quoted price
    }
    console.log('Step 6: calling Yoco, serviceType:', serviceType, 'amount:', amount, 'platformFee:', platformFee, 'totalCharged:', totalCharged, 'appUrl:', appUrl);
    const yocoResponse = await fetch('https://payments.yoco.com/api/checkouts', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${YOCO_SECRET_KEY}` },
      body: JSON.stringify({
        amount:     Math.round(totalCharged * 100),
        currency:   'ZAR',
        successUrl: `${appUrl}?payment=success&booking_id=${bookingId}`,
        cancelUrl:  `${appUrl}?payment=cancelled&booking_id=${bookingId}`,
        metadata:   { booking_id: bookingId, payment_id: paymentResult.payment_id, tier, category },
      }),
    });

    const yocoData = await yocoResponse.json();
    console.log('Step 7: Yoco response status:', yocoResponse.status, 'body:', JSON.stringify(yocoData));
    if (!yocoResponse.ok || !yocoData.id) {
      return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: yocoData.displayMessage || yocoData.message || 'Failed to create payment checkout' }) };
    }

    const { error: checkoutUpdateError } = await supabase.from('payments').update({
      provider_checkout_id:  yocoData.id,
      provider_checkout_url: yocoData.redirectUrl,
    }).eq('id', paymentResult.payment_id);
    // FIX D: Log if this update fails. A silent failure here means the idempotent
    // replay path won't find the checkout URL and will re-create a new Yoco session
    // on retry, which is wasteful but not catastrophic (the old session expires unused).
    if (checkoutUpdateError) {
      console.error('Failed to persist checkout URL to payments row — idempotent replay will re-create session:', checkoutUpdateError.message);
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify({ booking_id: bookingId, payment_id: paymentResult.payment_id, checkout_url: yocoData.redirectUrl, tier }),
    };

  } catch (error) {
    console.error('create-booking error:', error);
    return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: error.message }) };
  }
};
