// ═══════════════════════════════════════════════════════════════
// update-job-status — Update job progression
// POST /api/update-job-status
//
// FIX (Bug 2): The fixer lookup used .single() which throws PGRST116
// when fixer_id is NULL (booking not yet assigned).  The status UPDATE
// had already committed, leaving the booking in the new state but the
// push notification silently crashing — inconsistent UX.
//
// Fix: use .maybeSingle() for the booking select and guard fixer_id
// before the second lookup.  All notification paths are now
// fire-and-forget (.catch()) so a push failure can NEVER roll back or
// mask a successful status transition.
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');
const { sendEmail } = require('./utils/email');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

const STATUS_MESSAGES = {
  EN_ROUTE:           { title: '🚗 On the way!',    body: 'Your fixer is en route to your location.' },
  ARRIVED:            { title: '📍 Arrived!',        body: 'Your fixer has arrived at your location.' },
  IN_PROGRESS:        { title: '⚙️ Job started',     body: 'Your fixer has started working on your job.' },
  PENDING_COMPLETION: { title: '🎉 Job done!',       body: 'Your fixer says the job is complete. Please confirm.' },
  COMPLETED:          { title: '✅ Job complete!',   body: 'Your job has been completed. Thank you for using Servit!' },
};

const VALID_STATUSES = Object.keys(STATUS_MESSAGES);

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: CORS_HEADERS };
  }
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };
  }

  try {
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

    // ── Input validation ────────────────────────────────────────
    const { booking_id, status } = JSON.parse(event.body || '{}');
    if (!booking_id || !status) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Missing booking_id or status' }) };
    }
    if (!VALID_STATUSES.includes(status)) {
      return {
        statusCode: 400,
        headers: CORS_HEADERS,
        body: JSON.stringify({ error: 'Invalid status. To cancel a booking use the cancel-booking endpoint.' }),
      };
    }

    // ── Status update (via RPC so server-side auth rules apply) ─
    const { data: result, error: updateError } = await supabase.rpc('update_job_status', {
      p_booking_id:    booking_id,
      p_actor_user_id: user.id,
      p_new_status:    status,
    });

    if (updateError) {
      return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: updateError.message }) };
    }

    // ── Push notification (best-effort — never blocks the response) ──
    // BUG 2 FIX: Use .maybeSingle() instead of .single() so that a NULL
    // fixer_id (booking not yet assigned) returns null rather than throwing
    // PGRST116.  The notification step is fully fire-and-forget via .catch()
    // so any failure here cannot affect the already-committed status update.
    sendNotification(user.id, booking_id, status).catch(e =>
      console.error('Push notification error (non-fatal):', e)
    );

    // ── Email notification for COMPLETED status ─────────────────────
    if (status === 'COMPLETED') {
      sendCompletionEmail(booking_id).catch(e =>
        console.error('Completion email error (non-fatal):', e)
      );
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify(result),
    };

  } catch (error) {
    console.error('Update job status error:', error);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};

// ── Notification helper — isolated so failures never leak upward ─────────
async function sendNotification(actorUserId, bookingId, status) {
  const msg = STATUS_MESSAGES[status];
  if (!msg) return; // no message defined for this status — skip silently

  // BUG 2 FIX: .maybeSingle() returns { data: null } when no row is found,
  // instead of throwing PGRST116.  This is safe for unassigned bookings.
  const { data: booking, error: bookingErr } = await supabase
    .from('bookings')
    .select('customer_id, fixer_id')
    .eq('id', bookingId)
    .maybeSingle();

  if (bookingErr || !booking) {
    console.warn('Notification skipped — booking not found or error:', bookingErr?.message);
    return;
  }

  let otherUserId = null;

  if (actorUserId === booking.customer_id) {
    // Actor is the customer → notify the fixer (if one is assigned)
    if (booking.fixer_id) {
      // BUG 2 FIX: guard fixer_id before this lookup; was crashing on unassigned bookings
      const { data: fixer } = await supabase
        .from('fixers')
        .select('user_id')
        .eq('id', booking.fixer_id)
        .maybeSingle();
      otherUserId = fixer?.user_id ?? null;
    }
  } else {
    // Actor is the fixer → notify the customer
    otherUserId = booking.customer_id;
  }

  if (!otherUserId) {
    // Booking not yet assigned or fixer user_id missing — nothing to notify
    return;
  }

  const internalSecret = process.env.INTERNAL_SECRET;
  const appUrl = process.env.APP_URL || process.env.URL;
  if (!internalSecret) {
    console.error('[FATAL CONFIG] INTERNAL_SECRET is not set — skipping job-status push notification.');
    return;
  }
  if (!appUrl) {
    console.error('[FATAL CONFIG] Neither APP_URL nor URL is set — skipping job-status push notification.');
    return;
  }

  await fetch(`${appUrl}/.netlify/functions/send-push`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Internal-Secret': internalSecret },
    body: JSON.stringify({
      userId:    otherUserId,
      title:     msg.title,
      body:      msg.body,
      data:      { type: 'booking', bookingId },
    }),
  });
}

// ── Completion email helper — sends review request email to customer ─────
async function sendCompletionEmail(bookingId) {
  const appUrl = process.env.APP_URL || process.env.URL || 'https://servit.co.za';

  const { data: booking, error: bookingErr } = await supabase
    .from('bookings')
    .select(`
      customer_id,
      fixer_id,
      fixers (
        full_name,
        user_id
      )
    `)
    .eq('id', bookingId)
    .maybeSingle();

  if (bookingErr || !booking) {
    console.warn('Completion email skipped — booking not found or error:', bookingErr?.message);
    return;
  }

  if (!booking.fixer_id || !booking.fixers) {
    console.warn('Completion email skipped — no fixer assigned');
    return;
  }

  const { data: profile } = await supabase
    .from('profiles')
    .select('email')
    .eq('id', booking.customer_id)
    .maybeSingle();

  if (!profile || !profile.email) {
    console.warn('Completion email skipped — customer email not found');
    return;
  }

  const fixerName = booking.fixers.full_name || 'your fixer';
  const reviewLink = `${appUrl}/?review=${bookingId}`;

  const html = `
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
      <div style="text-align: center; margin-bottom: 30px;">
        <h2 style="color: #8B6420; margin: 0;">Your Servit job is complete!</h2>
      </div>
      <p style="font-size: 16px; line-height: 1.6; color: #333;">
        Thank you for using Servit! Your job with <strong>${fixerName}</strong> has been successfully completed.
      </p>
      <p style="font-size: 16px; line-height: 1.6; color: #333;">
        We'd love to hear about your experience. Please take a moment to leave a review for your fixer — it helps our community grow and helps other customers make informed decisions.
      </p>
      <div style="text-align: center; margin: 30px 0;">
        <a href="${reviewLink}" style="display: inline-block; background-color: #8B6420; color: white; padding: 14px 28px; text-decoration: none; border-radius: 6px; font-size: 16px; font-weight: bold;">
          Leave a Review →
        </a>
      </div>
      <p style="font-size: 14px; line-height: 1.6; color: #666; margin-top: 30px;">
        If you have any questions or concerns, please don't hesitate to contact us.
      </p>
      <p style="font-size: 14px; line-height: 1.6; color: #666;">
        Thank you for choosing Servit!
      </p>
    </div>
  `;

  await sendEmail(profile.email, 'Your Servit job is complete — leave a review', html);
}