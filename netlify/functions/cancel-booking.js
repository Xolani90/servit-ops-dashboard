// ═══════════════════════════════════════════════════════════════
// cancel-booking — Cancel a booking and issue Yoco refund
// POST /api/cancel-booking
//
// FIX (Audit Failure 4): The frontend called update-job-status
// for customer cancellations, which transitioned the booking to
// CANCELLED but never called the Yoco refund API. Customers who
// paid and then cancelled pre-match lost their money silently.
//
// This function:
//   1. Authenticates the caller
//   2. Calls update_job_status() to CANCELLED (all existing guards apply)
//   3. If payment_status = 'paid' AND fixer_id IS NULL (pre-match),
//      calls the Yoco refund API and marks the payment refunded
//   4. If a fixer was assigned and cancels (post-match), no refund
//      is issued (business rule — handled separately via disputes)
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');
const { sendEmail } = require('./utils/email');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const YOCO_SECRET_KEY = process.env.YOCO_SECRET_KEY;

async function issueYocoRefund(providerPaymentId, amountCents) {
  const response = await fetch(`https://payments.yoco.com/api/payments/${providerPaymentId}/refund`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${YOCO_SECRET_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ amount: amountCents }),
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`Yoco refund failed (${response.status}): ${err}`);
  }

  return response.json();
}

const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS_HEADERS };
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };
  }

  try {
    const authHeader = event.headers.authorization;
    if (!authHeader) {
      return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Unauthorized' }) };
    }

    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);

    if (userError || !user) {
      return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid token' }) };
    }

    const { booking_id } = JSON.parse(event.body || '{}');

    if (!booking_id) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Missing booking_id' }) };
    }

    // Step 1: Cancel the booking via the existing guarded DB function
    const { data: cancelResult, error: cancelError } = await supabase.rpc('update_job_status', {
      p_booking_id: booking_id,
      p_actor_user_id: user.id,
      p_new_status: 'CANCELLED',
    });

    if (cancelError) {
      return {
        statusCode: 400,
        headers: CORS_HEADERS,
        body: JSON.stringify({ error: cancelError.message }),
      };
    }

    // BUG 8 FIX: Use maybeSingle() not single().
    // .single() throws PGRST116 if there are 0 or 2+ rows — e.g. booking never paid,
    // or was already refunded. This was crashing the handler and leaving the booking
    // in CANCELLED state while the frontend received a 500.
    const { data: payment } = await supabase
      .from('payments')
      .select('id, status, provider_payment_id, amount')
      .eq('booking_id', booking_id)
      .eq('status', 'paid')
      .maybeSingle();

    const { data: booking } = await supabase
      .from('bookings')
      .select('fixer_id, customer_id')
      .eq('id', booking_id)
      .maybeSingle();

    const isPreMatchCancellation = payment && booking && booking.fixer_id === null;

    // Fetch customer email for notification
    const { data: customerProfile } = await supabase
      .from('profiles')
      .select('email')
      .eq('id', booking?.customer_id)
      .maybeSingle();

    // BUG 10 FIX: Notify the fixer when a post-match cancellation occurs.
    // Previously the fixer was left with a stale job in their dashboard — no notification,
    // no status change visible until they polled. The booking IS already cancelled in DB
    // (update_job_status ran above), but the fixer needs a push so their realtime
    // subscription fires and their job screen clears.
    if (!isPreMatchCancellation && booking?.fixer_id) {
      const { data: fixer } = await supabase
        .from('fixers')
        .select('user_id')
        .eq('id', booking.fixer_id)
        .maybeSingle();
      if (fixer?.user_id) {
        // BUG 4 FIX: Validate INTERNAL_SECRET before attempting push — empty string
        // causes send-push to silently reject the request with no visible error.
        const internalSecret = process.env.INTERNAL_SECRET;
        const appUrl = process.env.APP_URL || process.env.URL;
        if (!internalSecret) {
          console.error('[FATAL CONFIG] INTERNAL_SECRET not set — skipping fixer cancellation push');
        } else if (!appUrl) {
          console.error('[FATAL CONFIG] Neither APP_URL nor URL is set — skipping fixer cancellation push');
        } else {
          fetch(`${appUrl}/.netlify/functions/send-push`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Internal-Secret': internalSecret },
            body: JSON.stringify({
              userId: fixer.user_id,
              title:  '❌ Booking cancelled',
              body:   'The customer cancelled this booking.',
              data:   { type: 'booking', bookingId: booking_id },
            }),
          }).catch(e => console.error('Fixer cancellation push failed:', e));
        }
      }
    }

    // Send cancellation email to customer
    if (customerProfile?.email) {
      const refundStatus = isPreMatchCancellation && payment
        ? 'A refund will be processed to your original payment method within 3-5 business days.'
        : 'No refund will be issued as this cancellation occurred after a fixer was assigned.';
      
      const emailHtml = `
        <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
          <h2 style="color: #333;">Your Servit booking has been cancelled</h2>
          <p style="color: #666;">Your booking <strong>#${booking_id}</strong> has been successfully cancelled.</p>
          <p style="color: #666;">${refundStatus}</p>
          <p style="color: #666;">If you have any questions, please contact our support team.</p>
          <p style="color: #999; font-size: 12px;">This is an automated message. Please do not reply.</p>
        </div>
      `;

      sendEmail(customerProfile.email, 'Your Servit booking has been cancelled', emailHtml)
        .catch(err => console.error('Failed to send cancellation email:', err));
    }

    if (isPreMatchCancellation && payment.provider_payment_id) {
      const amountCents = Math.round(payment.amount * 100);

      try {
        await issueYocoRefund(payment.provider_payment_id, amountCents);

        // Mark payment as refunded in our DB atomically
        const { error: refundMarkError } = await supabase.rpc('mark_payment_refunded', {
          p_booking_id: booking_id,
          p_payment_id: payment.id,
        });

        if (refundMarkError) {
          // Refund went through with Yoco but we failed to mark it — log for manual reconciliation
          console.error('RECONCILIATION NEEDED: Yoco refund issued but DB mark failed', {
            booking_id,
            payment_id: payment.id,
            error: refundMarkError.message,
          });
        }

        return {
          statusCode: 200,
          headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' },
          body: JSON.stringify({
            ...cancelResult,
            refunded: true,
            refund_amount: payment.amount,
          }),
        };

      } catch (refundError) {
        // Booking is already cancelled — log the refund failure for manual processing
        console.error('REFUND FAILED — booking cancelled, manual refund required', {
          booking_id,
          payment_id: payment.id,
          provider_payment_id: payment.provider_payment_id,
          error: refundError.message,
        });

        return {
          statusCode: 200,
          headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' },
          body: JSON.stringify({
            ...cancelResult,
            refunded: false,
            refund_error: 'Booking cancelled. Refund could not be processed automatically — support has been notified.',
          }),
        };
      }
    }

    // Post-match cancellation or no payment — no refund
    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' },
      body: JSON.stringify({ ...cancelResult, refunded: false }),
    };

  } catch (error) {
    console.error('cancel-booking error:', error);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};
