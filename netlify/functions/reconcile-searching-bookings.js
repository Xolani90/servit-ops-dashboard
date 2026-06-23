// ═══════════════════════════════════════════════════════════════
// reconcile-searching-bookings — STEP 2: Reconcile stuck SEARCHING bookings
// Scheduled function (cron) that finds bookings stuck in SEARCHING > 2 minutes
// and aggressively re-triggers match_fixers with expanded radius.
//
// SECURITY FIX: Added isScheduled/INTERNAL_SECRET guard. Without this,
// any unauthenticated HTTP POST could trigger bulk request_matching RPC
// calls across all stuck bookings, causing unnecessary DB load and
// potential matching system abuse.
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');

const INTERNAL_SECRET = process.env.INTERNAL_SECRET;

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

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

  console.log('[reconcile-searching-bookings] Starting reconciliation check');

  try {
    // Find bookings stuck in SEARCHING for > 2 minutes
    const { data: stuckBookings, error: queryError } = await supabase
      .from('bookings')
      .select('id, updated_at, booking_mode, scheduled_for, category, customer_latitude, customer_longitude')
      .eq('status', 'SEARCHING')
      .eq('payment_status', 'paid')
      .lt('updated_at', new Date(Date.now() - 2 * 60 * 1000).toISOString()) // > 2 minutes ago
      .or('booking_mode.eq.asap,and(booking_mode.eq.scheduled,scheduled_for.lte.' + new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString() + ')');

    if (queryError) {
      console.error('[reconcile-searching-bookings] Query error:', queryError);
      return { statusCode: 500, body: JSON.stringify({ error: 'Database query failed' }) };
    }

    if (!stuckBookings || stuckBookings.length === 0) {
      console.log('[reconcile-searching-bookings] No stuck bookings found');
      return { statusCode: 200, body: JSON.stringify({ reconciled: 0 }) };
    }

    console.log(`[reconcile-searching-bookings] Found ${stuckBookings.length} stuck bookings`);

    let reconciledCount = 0;

    // PERFORMANCE FIX: Batch all matching requests instead of sequential loop
    // to reduce round-trip latency. Calculate radius for each booking and
    // execute all RPC calls in parallel.
    const matchingRequests = stuckBookings.map(booking => {
      const stuckDuration = Date.now() - new Date(booking.updated_at).getTime();
      const stuckMinutes = Math.floor(stuckDuration / (60 * 1000));

      console.log(`[reconcile-searching-bookings] Processing booking ${booking.id} (stuck for ${stuckMinutes} minutes)`);

      // Calculate expanded radius based on how long it's been stuck
      // 2-3 min: 50km, 3-4 min: 75km, 4-5 min: 100km, >5 min: 150km
      let expandedRadius;
      if (stuckMinutes <= 3) {
        expandedRadius = 50;
      } else if (stuckMinutes <= 4) {
        expandedRadius = 75;
      } else if (stuckMinutes <= 5) {
        expandedRadius = 100;
      } else {
        expandedRadius = 150;
      }

      return supabase.rpc('request_matching', {
        p_booking_id: booking.id,
        p_requested_by: 'reconcile-searching',
        p_priority: 7, // Medium-high priority for reconciliation
        p_radius_km: expandedRadius,
        p_batch_size: 5, // Increase batch size for stuck bookings
        p_metadata: { source: 'reconcile-searching', stuck_minutes: stuckMinutes }
      }).then(({ error }) => {
        if (error) {
          console.error(`[reconcile-searching-bookings] Request failed for booking ${booking.id}:`, error);
          return null;
        }
        console.log(`[reconcile-searching-bookings] Queued matching request for booking ${booking.id} with ${expandedRadius}km radius`);
        return booking.id;
      });
    });

    const results = await Promise.allSettled(matchingRequests);
    reconciledCount = results.filter(r => r.status === 'fulfilled' && r.value !== null).length;

    console.log(`[reconcile-searching-bookings] Reconciliation complete: ${reconciledCount}/${stuckBookings.length} bookings matched`);

    return {
      statusCode: 200,
      body: JSON.stringify({
        success: true,
        checked: stuckBookings.length,
        reconciled: reconciledCount
      })
    };

  } catch (error) {
    console.error('[reconcile-searching-bookings] Unexpected error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: error.message })
    };
  }
};
