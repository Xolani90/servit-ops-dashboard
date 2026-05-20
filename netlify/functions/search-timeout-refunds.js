// FIX (v8.8): Added INTERNAL_SECRET guard — this function issues real Yoco
// refunds and must never be callable by unauthenticated HTTP requests.
// Netlify's own scheduler invokes with event.httpMethod === undefined.
// All HTTP calls must supply the x-internal-secret header.
const { createClient } = require('@supabase/supabase-js');

const TIMEOUT_MINUTES = 12;
const INTERNAL_SECRET = process.env.INTERNAL_SECRET;
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

async function issueYocoRefund(secret, providerPaymentId, amountCents) {
  const response = await fetch(`https://payments.yoco.com/api/payments/${providerPaymentId}/refund`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${secret}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ amount: amountCents }),
  });
  if (!response.ok) {
    const err = await response.text();
    throw new Error(`Yoco refund failed (${response.status}): ${err}`);
  }
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS_HEADERS };

  // FIX (v8.8): Reject HTTP calls that don't carry the internal secret.
  // Netlify's own scheduler invokes functions with event.httpMethod === undefined.
  if (event && event.httpMethod) {
    const callerSecret = (event.headers || {})['x-internal-secret'];
    if (!INTERNAL_SECRET || callerSecret !== INTERNAL_SECRET) {
      return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Unauthorized' }) };
    }
  }

  try {
    const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });
    const yocoSecret = process.env.YOCO_SECRET_KEY;
    const cutoffIso = new Date(Date.now() - (TIMEOUT_MINUTES * 60 * 1000)).toISOString();

    const { data: staleBookings, error: staleErr } = await supabase
      .from('bookings')
      .select('id, status, payment_status, created_at, updated_at, customer_id')
      .in('status', ['SEARCHING', 'OFFERED'])
      .eq('payment_status', 'paid')
      .lte('updated_at', cutoffIso)
      .limit(100);

    if (staleErr) throw staleErr;

    const summary = { scanned: staleBookings?.length || 0, expired: 0, refunded: 0, refund_failed: 0, failed: [] };

    for (const booking of staleBookings || []) {
      try {
        const { data: payment } = await supabase
          .from('payments')
          .select('id, status, amount, provider_payment_id')
          .eq('booking_id', booking.id)
          .eq('status', 'paid')
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle();

        // NOTE: Expiry is now handled by expire_stuck_searching_bookings() in v8.9.4
        // This function only handles refunds for already-expired bookings
        summary.expired += 1;

        if (payment?.provider_payment_id && yocoSecret) {
          try {
            await issueYocoRefund(yocoSecret, payment.provider_payment_id, Math.round(Number(payment.amount || 0) * 100));
            await supabase.rpc('mark_payment_refunded', {
              p_booking_id: booking.id,
              p_payment_id: payment.id,
            });
            summary.refunded += 1;

            // Notify the customer — they need to know why money is coming back.
            // Without this they see a silent refund with no explanation, which
            // causes support tickets and chargebacks at launch.
            if (booking.customer_id) {
              const refundAmountRand = (Number(payment.amount || 0)).toFixed(2);

              // 1. In-app notification (survives if push subscription is absent)
              await supabase.from('notifications').insert({
                user_id:    booking.customer_id,
                title:      '💸 Booking refunded',
                body:       `We couldn't find a Fixer in time for your booking. A full refund of R${refundAmountRand} is on its way — funds typically appear within 1–3 business days.`,
                type:       'search_timeout_refund',
                related_id: booking.id,
              }).catch(e => console.warn('[search-timeout-refunds] Failed to insert notification:', e.message));

              // 2. Push notification (best-effort — no subscription is fine)
              const internalSecret = process.env.INTERNAL_SECRET;
              const appUrl = process.env.URL || process.env.APP_URL;
              if (internalSecret && appUrl) {
                fetch(`${appUrl}/.netlify/functions/send-push`, {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json', 'x-internal-secret': internalSecret },
                  body: JSON.stringify({
                    userId: booking.customer_id,
                    title:  '💸 Booking refunded',
                    body:   `No Fixer was available in time. Your R${refundAmountRand} refund is on its way.`,
                    data:   { type: 'refund', bookingId: booking.id },
                    urgency: 'high',
                  }),
                }).catch(e => console.warn('[search-timeout-refunds] Push notification failed:', e.message));
              } else {
                console.warn('[search-timeout-refunds] Skipping push — INTERNAL_SECRET or app URL not set');
              }
            }
          } catch (refundErr) {
            // FIX: Record refund failures as booking events so they are visible
            // in the admin audit trail and can be retried manually.
            console.error('[search-timeout-refunds] Refund failed for booking', booking.id, ':', refundErr.message);
            summary.refund_failed += 1;
            await supabase.from('booking_events').insert({
              booking_id: booking.id,
              event_type: 'refund_failed',
              old_status: 'EXPIRED',
              new_status: 'EXPIRED',
              metadata: {
                reason: refundErr.message,
                payment_id: payment.id,
                provider_payment_id: payment.provider_payment_id,
                amount: payment.amount,
                attempted_at: new Date().toISOString(),
              },
            }).catch(e => console.warn('[search-timeout-refunds] Failed to log refund_failed event:', e.message));
            summary.failed.push({ booking_id: booking.id, error: refundErr.message, type: 'refund' });
          }
        }
      } catch (err) {
        summary.failed.push({ booking_id: booking.id, error: err.message });
      }
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify(summary),
    };
  } catch (error) {
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};
