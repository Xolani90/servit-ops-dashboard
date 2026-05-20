// ═══════════════════════════════════════════════════════════════
// reconcile-payments — STEP 3: Payment sanity check
// Scheduled function that checks Yoco paid transactions against bookings
// and fixes mismatches (e.g., payment succeeded in Yoco but not marked in DB)
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const YOCO_SECRET_KEY = process.env.YOCO_SECRET_KEY;

// Fetch payment details from Yoco API
async function getYocoPayment(yocoPaymentId) {
  const response = await fetch(`https://payments.yoco.com/api/payments/${yocoPaymentId}`, {
    headers: { 'Authorization': `Bearer ${YOCO_SECRET_KEY}` },
  });
  if (!response.ok) return null;
  return response.json();
}

exports.handler = async (event) => {
  console.log('[reconcile-payments] Starting payment reconciliation');

  try {
    // Find bookings in PENDING_PAYMENT with payment records
    const { data: pendingPayments, error: queryError } = await supabase
      .from('payments')
      .select('id, booking_id, provider_payment_id, status, created_at')
      .eq('status', 'pending')
      .eq('provider', 'yoco')
      .isnot('provider_payment_id', null)
      .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()) // Last 24 hours
      .order('created_at', { ascending: false })
      .limit(100);

    if (queryError) {
      console.error('[reconcile-payments] Query error:', queryError);
      return { statusCode: 500, body: JSON.stringify({ error: 'Database query failed' }) };
    }

    if (!pendingPayments || pendingPayments.length === 0) {
      console.log('[reconcile-payments] No pending payments to reconcile');
      return { statusCode: 200, body: JSON.stringify({ reconciled: 0, checked: 0 }) };
    }

    console.log(`[reconcile-payments] Found ${pendingPayments.length} pending payments to check`);

    let reconciledCount = 0;
    let failedCount = 0;
    let stillPendingCount = 0;

    // PERFORMANCE FIX: Batch Yoco API calls and DB updates in parallel
    // to reduce sequential round-trip latency. Process all payments concurrently.
    const paymentChecks = pendingPayments.map(async (payment) => {
      console.log(`[reconcile-payments] Checking payment ${payment.id} (Yoco ID: ${payment.provider_payment_id})`);

      // Verify payment status with Yoco
      const yocoPayment = await getYocoPayment(payment.provider_payment_id);

      if (!yocoPayment) {
        console.error(`[reconcile-payments] Failed to fetch Yoco payment ${payment.provider_payment_id}`);
        return { status: 'failed' };
      }

      if (yocoPayment.status === 'SUCCESSFUL') {
        // Payment succeeded in Yoco but not marked in DB - fix it
        console.log(`[reconcile-payments] Payment ${payment.provider_payment_id} is SUCCESSFUL in Yoco - reconciling`);

        const { error: updateError } = await supabase.rpc('process_yoco_payment_success', {
          p_payment_id: payment.id,
          p_yoco_payment_id: payment.provider_payment_id
        });

        if (updateError) {
          console.error(`[reconcile-payments] Failed to process payment ${payment.id}:`, updateError);
          return { status: 'failed' };
        } else {
          console.log(`[reconcile-payments] Successfully reconciled payment ${payment.id}`);
          return { status: 'reconciled' };
        }
      } else if (yocoPayment.status === 'FAILED' || yocoPayment.status === 'CANCELLED') {
        // Payment failed in Yoco - mark as failed in DB
        console.log(`[reconcile-payments] Payment ${payment.provider_payment_id} is ${yocoPayment.status} in Yoco - marking as failed`);

        const { error: updateError } = await supabase
          .from('payments')
          .update({ status: 'failed', updated_at: new Date().toISOString() })
          .eq('id', payment.id);

        if (updateError) {
          console.error(`[reconcile-payments] Failed to mark payment ${payment.id} as failed:`, updateError);
          return { status: 'failed' };
        } else {
          console.log(`[reconcile-payments] Marked payment ${payment.id} as failed`);
          return { status: 'reconciled' };
        }
      } else {
        // Payment still pending in Yoco
        console.log(`[reconcile-payments] Payment ${payment.provider_payment_id} still ${yocoPayment.status} in Yoco`);
        return { status: 'pending' };
      }
    });

    const results = await Promise.allSettled(paymentChecks);
    for (const result of results) {
      if (result.status === 'fulfilled') {
        const { status } = result.value;
        if (status === 'reconciled') reconciledCount++;
        else if (status === 'failed') failedCount++;
        else if (status === 'pending') stillPendingCount++;
      } else {
        failedCount++;
      }
    }

    // Also check for bookings in SEARCHING with paid payments that might have missed the webhook
    const { data: stuckBookings, error: stuckError } = await supabase
      .from('bookings')
      .select('id, payment_status, updated_at')
      .eq('status', 'SEARCHING')
      .eq('payment_status', 'paid')
      .lt('updated_at', new Date(Date.now() - 5 * 60 * 1000).toISOString()) // Stuck for > 5 min
      .limit(50);

    if (!stuckError && stuckBookings && stuckBookings.length > 0) {
      console.log(`[reconcile-payments] Found ${stuckBookings.length} stuck SEARCHING bookings with paid payments - queuing matching requests`);

      // PERFORMANCE FIX: Batch matching requests in parallel
      const matchingRequests = stuckBookings.map(booking =>
        supabase.rpc('request_matching', {
          p_booking_id: booking.id,
          p_requested_by: 'reconcile-payment',
          p_priority: 6, // Medium priority for payment reconciliation
          p_radius_km: 50, // Expanded radius
          p_batch_size: 5,
          p_metadata: { source: 'reconcile-payments' }
        }).then(({ error }) => {
          if (error) {
            console.error(`[reconcile-payments] Failed to queue matching for booking ${booking.id}:`, error);
          } else {
            console.log(`[reconcile-payments] Queued matching request for booking ${booking.id}`);
          }
        })
      );

      await Promise.allSettled(matchingRequests);
    }

    console.log(`[reconcile-payments] Reconciliation complete: ${reconciledCount} reconciled, ${failedCount} failed, ${stillPendingCount} still pending`);

    return {
      statusCode: 200,
      body: JSON.stringify({
        success: true,
        checked: pendingPayments.length,
        reconciled: reconciledCount,
        failed: failedCount,
        still_pending: stillPendingCount
      })
    };

  } catch (error) {
    console.error('[reconcile-payments] Unexpected error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: error.message })
    };
  }
};
