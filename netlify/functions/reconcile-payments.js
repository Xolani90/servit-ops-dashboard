// ═══════════════════════════════════════════════════════════════
// reconcile-payments — STEP 3: Payment sanity check
// Scheduled function that checks Yoco paid transactions against bookings
// and fixes mismatches (e.g., payment succeeded in Yoco but not marked in DB).
//
// SECURITY FIX: Added isScheduled/INTERNAL_SECRET guard. Without this,
// any unauthenticated HTTP call could trigger Yoco API lookups for all
// pending payments in the last 24 hours.
//
// QUERY BUG FIX: The previous version queried for payments where
// provider_payment_id IS NULL, then immediately called
// getYocoPayment(payment.provider_payment_id) with a null argument,
// which always produced a 404 from Yoco. Reconciliation was completely
// broken. The fix queries for payments that HAVE a provider_checkout_id
// (set when the Yoco checkout was created) but no provider_payment_id yet
// (webhook hasn't fired). We then look up the checkout status via Yoco's
// checkouts API to determine if the payment succeeded.
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');

const INTERNAL_SECRET = process.env.INTERNAL_SECRET;

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const YOCO_SECRET_KEY = process.env.YOCO_SECRET_KEY;

// Fetch checkout details from Yoco API using the checkout ID
// (set at booking creation, stored as provider_checkout_id).
// This is what we can verify even before a webhook fires.
async function getYocoCheckout(checkoutId) {
  if (!checkoutId || !YOCO_SECRET_KEY) return null;
  try {
    const response = await fetch(`https://payments.yoco.com/api/checkouts/${checkoutId}`, {
      headers: { 'Authorization': `Bearer ${YOCO_SECRET_KEY}` },
    });
    if (!response.ok) return null;
    return response.json();
  } catch (err) {
    console.warn(`[reconcile-payments] Yoco checkout lookup failed for ${checkoutId}:`, err.message);
    return null;
  }
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: { 'Access-Control-Allow-Origin': '*' } };
  }

  // Netlify Clockwork scheduled invocations include x-nf-event: schedule header.
  // All manual HTTP calls must supply the x-internal-secret header.
  const isScheduled =
    event.headers?.['x-nf-event'] === 'schedule' ||
    event.headers?.['user-agent']?.includes('Netlify Clockwork') ||
    event.headers?.['user-agent']?.includes('Netlify');

  if (!isScheduled) {
    const callerSecret = (event.headers || {})['x-internal-secret'];
    if (!INTERNAL_SECRET || callerSecret !== INTERNAL_SECRET) {
      return { statusCode: 401, body: JSON.stringify({ error: 'Unauthorized' }) };
    }
  }

  console.log('[reconcile-payments] Starting payment reconciliation');

  try {
    // Find pending payment records that:
    //   - Have a Yoco checkout ID (checkout was created in create-booking)
    //   - Do NOT yet have a Yoco payment ID (webhook hasn't fired yet)
    //   - Were created in the last 24 hours (no need to chase stale sessions)
    // This is exactly the gap the reconciler is meant to fill: checkout
    // was created and customer paid, but the webhook was delayed or missed.
    const { data: pendingPayments, error: queryError } = await supabase
      .from('payments')
      .select('id, booking_id, provider_checkout_id, provider_payment_id, status, amount, created_at')
      .eq('status', 'pending')
      .eq('provider', 'yoco')
      .not('provider_checkout_id', 'is', null)      // BUG FIX: must have a checkout ID to verify
      .is('provider_payment_id', null)              // webhook hasn't confirmed this yet
      .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()) // Last 24 hours
      .order('created_at', { ascending: false })
      .limit(50);

    if (queryError) {
      console.error('[reconcile-payments] Query error:', queryError);
      return { statusCode: 500, body: JSON.stringify({ error: 'Database query failed' }) };
    }

    if (!pendingPayments || pendingPayments.length === 0) {
      console.log('[reconcile-payments] No pending payments to reconcile');
      return { statusCode: 200, body: JSON.stringify({ reconciled: 0, checked: 0 }) };
    }

    console.log(`[reconcile-payments] Found ${pendingPayments.length} unconfirmed checkouts to verify`);

    let reconciledCount = 0;
    let failedCount = 0;
    let stillPendingCount = 0;

    // Check all checkouts in parallel to reduce round-trip latency
    const paymentChecks = pendingPayments.map(async (payment) => {
      console.log(`[reconcile-payments] Verifying checkout ${payment.provider_checkout_id} for payment ${payment.id}`);

      try {
        const checkout = await getYocoCheckout(payment.provider_checkout_id);

        if (!checkout) {
          console.warn(`[reconcile-payments] Could not fetch checkout ${payment.provider_checkout_id} — skipping`);
          stillPendingCount++;
          return;
        }

        // Yoco checkout statuses: PENDING, COMPLETE, CANCELLED, EXPIRED
        if (checkout.status !== 'COMPLETE') {
          console.log(`[reconcile-payments] Checkout ${payment.provider_checkout_id} status is ${checkout.status} — not yet paid`);
          stillPendingCount++;
          return;
        }

        // Checkout is COMPLETE — call the same RPC the webhook calls to confirm the payment
        // and advance the booking to SEARCHING. This is idempotent: if the webhook already
        // fired and processed it before we got here, the RPC will return ok=true with no
        // duplicate state change (it guards on payment_status internally).
        const yocoPaymentId = checkout.payments?.[0]?.id || checkout.payment?.id;
        if (!yocoPaymentId) {
          console.warn(`[reconcile-payments] Checkout ${payment.provider_checkout_id} is COMPLETE but has no payment ID — cannot reconcile`);
          return;
        }

        const { error: rpcError } = await supabase.rpc('process_yoco_payment_success', {
          p_checkout_id:  payment.provider_checkout_id,
          p_payment_id:   yocoPaymentId,
          p_amount_cents: Math.round(Number(payment.amount || 0) * 100),
        });

        if (rpcError) {
          console.error(`[reconcile-payments] RPC failed for payment ${payment.id}:`, rpcError.message);
          failedCount++;
          return;
        }

        console.log(`[reconcile-payments] Successfully reconciled payment ${payment.id} (Yoco payment: ${yocoPaymentId})`);
        reconciledCount++;

      } catch (err) {
        console.error(`[reconcile-payments] Unexpected error for payment ${payment.id}:`, err.message);
        failedCount++;
      }
    });

    await Promise.allSettled(paymentChecks);

    const summary = {
      checked: pendingPayments.length,
      reconciled: reconciledCount,
      still_pending: stillPendingCount,
      failed: failedCount,
    };

    console.log('[reconcile-payments] Complete:', summary);

    return {
      statusCode: 200,
      body: JSON.stringify({ success: true, ...summary }),
    };

  } catch (error) {
    console.error('[reconcile-payments] Unexpected error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: error.message }),
    };
  }
};
