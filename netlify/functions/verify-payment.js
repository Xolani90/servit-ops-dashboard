// Only load .env in non-production environments or when critical env vars are missing
if (process.env.NODE_ENV !== 'production' && !process.env.SUPABASE_URL) {
  require('./_env');
}
// ═══════════════════════════════════════════════════════════════
// verify-payment — Client-side fallback for missed Yoco webhooks
// POST /.netlify/functions/verify-payment
//
// WHY THIS EXISTS:
//   The yoco-webhook function is the primary way to confirm payment and
//   advance the booking to SEARCHING. But webhooks can be delayed, missed,
//   or misconfigured. When the frontend sees payment=success in the URL but
//   the booking is still PENDING_PAYMENT after 30s of polling, it calls this
//   function as a fallback.
//
//   This function:
//     1. Looks up the booking's payment record to get the Yoco checkout ID
//     2. Calls the Yoco API to verify the checkout was SUCCESSFUL
//     3. If confirmed, calls process_yoco_payment_success (same as webhook)
//        to advance the booking to SEARCHING and trigger match_fixers
//     4. Is idempotent — safe to call even if webhook already fired
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');
const { sendEmail } = require('./utils/email');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS_HEADERS };
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };

  try {
    const supabase = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_KEY,
      { auth: { persistSession: false } }
    );
    const YOCO_SECRET_KEY = process.env.YOCO_SECRET_KEY;

    // ── Auth ────────────────────────────────────────────────────
    const authHeader = event.headers.authorization;
    if (!authHeader) {
      return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Unauthorized' }) };
    }
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) {
      return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid token' }) };
    }

    // ── Input ────────────────────────────────────────────────────
    const { booking_id } = JSON.parse(event.body || '{}');
    if (!booking_id) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Missing booking_id' }) };
    }

    // ── Verify caller owns this booking ─────────────────────────
    const { data: booking, error: bookingErr } = await supabase
      .from('bookings')
      .select('id, status, customer_id')
      .eq('id', booking_id)
      .maybeSingle();

    if (bookingErr || !booking) {
      return { statusCode: 404, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Booking not found' }) };
    }
    if (booking.customer_id !== user.id) {
      return { statusCode: 403, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Forbidden' }) };
    }

    // ── Idempotency: if already past PENDING_PAYMENT, nothing to do ──
    if (!['PENDING_PAYMENT', 'CREATED'].includes(booking.status)) {
      return {
        statusCode: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
        body: JSON.stringify({ ok: true, status: booking.status, message: 'Booking already advanced — no action needed' }),
      };
    }

    // ── Look up payment record ───────────────────────────────────
    const { data: payment, error: paymentErr } = await supabase
      .from('payments')
      .select('id, provider_checkout_id, status')
      .eq('booking_id', booking_id)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (paymentErr || !payment) {
      return { statusCode: 404, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Payment record not found' }) };
    }

    // If payment was already marked paid in our DB, just re-trigger matching
    if (payment.status === 'paid') {
      console.log('[verify-payment] Payment already paid in DB, re-triggering matching for', booking_id);
      // Only re-trigger if no active offers exist — avoids double-notifying fixers.
      const { count: existingOffers } = await supabase
        .from('offers')
        .select('id', { count: 'exact', head: true })
        .eq('booking_id', booking_id)
        .in('status', ['pending']); // 'sent' is not a valid offer_status_enum value;
      if (!existingOffers || existingOffers === 0) {
        await supabase.rpc('request_matching', {
          p_booking_id: booking_id,
          p_requested_by: 'verify-payment',
          p_priority: 9, // High priority for verify-payment
          p_radius_km: 25.0,
          p_batch_size: 3,
          p_metadata: { source: 'verify-payment-fallback' }
        }).catch(e =>
          console.warn('[verify-payment] request_matching error (non-fatal):', e.message)
        );
      }
      return {
        statusCode: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
        body: JSON.stringify({ ok: true, status: 'SEARCHING', message: 'Re-triggered matching' }),
      };
    }

    if (!payment.provider_checkout_id) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'No checkout ID on payment record — cannot verify' }) };
    }

    // ── Verify checkout with Yoco API ────────────────────────────
    // Yoco checkouts endpoint: GET /api/checkouts/{id}
    console.log('[verify-payment] Verifying Yoco checkout:', payment.provider_checkout_id);
    const yocoResponse = await fetch(`https://payments.yoco.com/api/checkouts/${payment.provider_checkout_id}`, {
      headers: { 'Authorization': `Bearer ${YOCO_SECRET_KEY}` },
    });

    if (!yocoResponse.ok) {
      console.error('[verify-payment] Yoco API error:', yocoResponse.status);
      return { statusCode: 502, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Could not verify with Yoco' }) };
    }

    const checkout = await yocoResponse.json();
    console.log('[verify-payment] Yoco checkout status:', checkout.status, 'for booking:', booking_id);

    // FIX (CRITICAL — v8.9.10): Yoco's checkout object uses lowercase status values
    // ("created", "completed", "failed", "cancelled") per their Create Checkout docs —
    // NOT "SUCCESSFUL"/"complete". The old check only matched 'SUCCESSFUL' or 'complete',
    // so a checkout that came back "completed" (the real value seen in production) was
    // wrongly treated as a failed payment, even though Yoco had charged the customer.
    // Source: https://developer.yoco.com/online/api-reference/checkout/payments/accept-payments/
    const successStatuses = ['successful', 'complete', 'completed'];
    const checkoutStatus = (checkout.status || '').toLowerCase();
    if (!successStatuses.includes(checkoutStatus)) {
      // Payment genuinely not successful
      return {
        statusCode: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
        body: JSON.stringify({ ok: false, status: checkout.status, message: 'Payment not yet successful' }),
      };
    }

    // ── Payment confirmed — process it (same as webhook) ────────
    const amountPaid = checkout.totalAmount ? checkout.totalAmount / 100 : (checkout.amount ? checkout.amount / 100 : null);
    // FIX: Yoco's documented Checkout object exposes the payment ID as a top-level
    // `paymentId` field (null until paid, populated once complete) — not nested under
    // `checkout.payments[0].id`, which doesn't exist in Yoco's schema. Fall back to the
    // checkout id itself only if paymentId is genuinely absent.
    const yocoPaymentId = checkout.paymentId || checkout.payments?.[0]?.id || checkout.id;

    const { data: result, error: processError } = await supabase.rpc('process_yoco_payment_success', {
      p_payment_id:          payment.id,
      p_provider_payment_id: yocoPaymentId,
      p_amount:              amountPaid,
    });

    if (processError) {
      console.error('[verify-payment] process_yoco_payment_success error:', processError.message);
      return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: processError.message }) };
    }

    console.log('[verify-payment] Payment processed, booking', booking_id, '→ SEARCHING');

    // ── Send customer confirmation email ───────────────────────────
    try {
      const { data: bookingDetails } = await supabase
        .from('bookings')
        .select('description, profiles!customer_id(email)')
        .eq('id', booking_id)
        .maybeSingle();

      const customerEmail = bookingDetails?.profiles?.email;
      const serviceCategory = bookingDetails?.description || 'Service';

      if (customerEmail) {
        await sendEmail(
          customerEmail,
          'Your Servit booking is confirmed',
          `
            <div style="font-family: sans-serif; max-width: 520px; margin: 0 auto; padding: 24px; color: #1C1A16;">
              <h2 style="margin: 0 0 16px 0;">Payment Received</h2>
              <p style="margin: 0 0 16px 0;">Your payment has been successfully received and your booking is confirmed.</p>
              <p style="margin: 0 0 16px 0;">We are now finding a Fixer for you. You'll be notified the moment one accepts your booking.</p>
              <p style="margin: 0 0 16px 0;"><strong>Booking ID:</strong> ${booking_id}</p>
              <p style="margin: 0 0 16px 0;"><strong>Service Category:</strong> ${serviceCategory}</p>
            </div>
          `
        );
        console.log('[verify-payment] Confirmation email sent to', customerEmail);
      }
    } catch (emailErr) {
      console.error('[verify-payment] Email send failed (non-fatal):', emailErr.message);
    }

    // ── Trigger matching ─────────────────────────────────────────
    // FIX: Check whether offers already exist before requesting matching so
    // a webhook+verify-payment race doesn't double-offer the same fixers.
    const { count: existingOffers } = await supabase
      .from('offers')
      .select('id', { count: 'exact', head: true })
      .eq('booking_id', booking_id)
      .in('status', ['pending']); // 'sent' is not a valid offer_status_enum value;

    if (!existingOffers || existingOffers === 0) {
      const { error: requestError } = await supabase.rpc('request_matching', {
        p_booking_id: booking_id,
        p_requested_by: 'verify-payment',
        p_priority: 9, // High priority for verify-payment
        p_radius_km: 25.0,
        p_batch_size: 3,
        p_metadata: { source: 'verify-payment-primary' }
      });
      if (requestError) {
        console.warn('[verify-payment] request_matching error (non-fatal, cron will retry):', requestError.message);
      }
    } else {
      console.log('[verify-payment] Offers already exist for booking', booking_id, '— skipping request_matching');
    }

    // Push notification — same message as yoco-webhook path so the customer
    // always hears "we're searching" regardless of which path confirmed the payment.
    try {
      const internalSecret = process.env.INTERNAL_SECRET;
      const appUrl = process.env.APP_URL || process.env.URL;
      if (internalSecret && appUrl && booking?.customer_id) {
        fetch(`${appUrl}/.netlify/functions/send-push`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'x-internal-secret': internalSecret },
          body: JSON.stringify({
            userId:  booking.customer_id,
            title:   '💳 Payment confirmed',
            body:    "We're searching for your Fixer now. You'll be notified the moment one accepts.",
            data:    { type: 'booking', bookingId: booking_id },
            urgency: 'high',
          }),
        }).catch(e => console.error('[verify-payment] push failed (non-fatal):', e.message));
      }
    } catch (pushErr) {
      console.error('[verify-payment] push step threw (non-fatal):', pushErr.message);
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ok: true, status: 'SEARCHING', message: 'Payment verified and booking advanced to SEARCHING' }),
    };

  } catch (error) {
    console.error('[verify-payment] Unhandled error:', error);
    return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: error.message }) };
  }
};
