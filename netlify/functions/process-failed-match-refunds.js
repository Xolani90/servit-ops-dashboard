// ═══════════════════════════════════════════════════════════════
// process-failed-match-refunds — Scheduled function to refund FAILED_MATCH bookings
// POST /.netlify/functions/process-failed-match-refunds (or scheduled via Netlify)
//
// This function processes bookings that have exhausted 5 matching attempts
// and are now in FAILED_MATCH state. It issues Yoco refunds and notifies customers.
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');
const { sendEmail } = require('./utils/email');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const YOCO_SECRET_KEY = process.env.YOCO_SECRET_KEY;
const INTERNAL_SECRET = process.env.INTERNAL_SECRET;

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

exports.handler = async (event) => {
  // Allow both scheduled invocation (x-nf-event: schedule header) and manual HTTP trigger
  const isScheduled = 
    event.headers?.['x-nf-event'] === 'schedule' ||
    event.headers?.['user-agent']?.includes('Netlify Clockwork') ||
    event.headers?.['user-agent']?.includes('Netlify');

  if (event.httpMethod === 'OPTIONS') {
    return {
      statusCode: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      },
    };
  }

  // For manual HTTP calls, require INTERNAL_SECRET
  if (!isScheduled) {
    const callerSecret = (event.headers || {})['x-internal-secret'];
    if (!INTERNAL_SECRET || callerSecret !== INTERNAL_SECRET) {
      return { statusCode: 401, body: JSON.stringify({ error: 'Unauthorized' }) };
    }
  }

  console.log('[process-failed-match-refunds] Starting FAILED_MATCH refund processing');

  try {
    // Find FAILED_MATCH bookings with paid payments that haven't been refunded
    const { data: failedBookings, error: queryError } = await supabase
      .from('bookings')
      .select('id, customer_id, status, updated_at')
      .eq('status', 'FAILED_MATCH')
      .gte('updated_at', new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()) // Last 7 days
      .limit(50);

    if (queryError) {
      console.error('[process-failed-match-refunds] Query error:', queryError);
      return { statusCode: 500, body: JSON.stringify({ error: 'Database query failed' }) };
    }

    if (!failedBookings || failedBookings.length === 0) {
      console.log('[process-failed-match-refunds] No FAILED_MATCH bookings to process');
      return { statusCode: 200, body: JSON.stringify({ processed: 0, refunded: 0 }) };
    }

    console.log(`[process-failed-match-refunds] Found ${failedBookings.length} FAILED_MATCH bookings`);

    let processedCount = 0;
    let refundedCount = 0;
    let failedCount = 0;

    for (const booking of failedBookings) {
      console.log(`[process-failed-match-refunds] Processing booking ${booking.id}`);

      try {
        // Get payment record
        const { data: payment, error: paymentError } = await supabase
          .from('payments')
          .select('id, status, amount, provider_payment_id')
          .eq('booking_id', booking.id)
          .eq('status', 'paid')
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle();

        if (paymentError || !payment) {
          console.warn(`[process-failed-match-refunds] No paid payment found for booking ${booking.id}`);
          continue;
        }

        // Check if already refunded
        if (payment.status === 'refunded') {
          console.log(`[process-failed-match-refunds] Payment ${payment.id} already refunded`);
          continue;
        }

        // Issue Yoco refund
        if (payment.provider_payment_id && YOCO_SECRET_KEY) {
          try {
            await issueYocoRefund(payment.provider_payment_id, Math.round(Number(payment.amount || 0) * 100));
            
            // Mark payment as refunded
            const { error: updateError } = await supabase.rpc('mark_payment_refunded', {
              p_booking_id: booking.id,
              p_payment_id: payment.id,
            });

            if (updateError) {
              console.error(`[process-failed-match-refunds] Failed to mark payment ${payment.id} as refunded:`, updateError);
              failedCount++;
            } else {
              console.log(`[process-failed-match-refunds] Successfully refunded payment ${payment.id}`);
              refundedCount++;

              // Get customer email
              const { data: customer, error: customerError } = await supabase
                .from('customers')
                .select('email')
                .eq('id', booking.customer_id)
                .maybeSingle();

              if (!customerError && customer && customer.email) {
                // Send refund email
                const emailHtml = `
                  <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
                    <h2 style="color: #333;">We could not find a fixer — your refund is on the way</h2>
                    <p>Hi there,</p>
                    <p>We sincerely apologize, but we were unable to find a Fixer for your booking.</p>
                    <p>Your refund of <strong>R${Number(payment.amount || 0).toFixed(2)}</strong> is being processed and should appear in your account within <strong>3-5 business days</strong>.</p>
                    <p>Booking ID: <strong>${booking.id}</strong></p>
                    <p>If you have any questions, please don't hesitate to reach out to our support team.</p>
                    <p>Best regards,<br>The Servit Team</p>
                  </div>
                `;
                await sendEmail(customer.email, 'We could not find a fixer — your refund is on the way', emailHtml)
                  .catch(e => console.warn('[process-failed-match-refunds] Failed to send refund email:', e.message));
              }

              // Notify customer
              await supabase.from('notifications').insert({
                user_id: booking.customer_id,
                title: '💸 Refund Processed',
                body: `We were unable to find a Fixer for your booking. A full refund of R${Number(payment.amount || 0).toFixed(2)} has been processed.`,
                type: 'failed_match_refund',
                related_id: booking.id,
              }).catch(e => console.warn('[process-failed-match-refunds] Failed to insert notification:', e.message));
            }

            processedCount++;
          } catch (refundErr) {
            console.error(`[process-failed-match-refunds] Yoco refund failed for booking ${booking.id}:`, refundErr.message);
            
            // Log failure for manual reconciliation
            await supabase.from('webhook_errors').insert({
              booking_id: booking.id,
              error_type: 'failed_match_refund_failed',
              error_msg: refundErr.message,
              created_at: new Date().toISOString(),
            }).catch(e => console.warn('[process-failed-match-refunds] Failed to log error:', e.message));
            
            failedCount++;
          }
        } else {
          console.warn(`[process-failed-match-refunds] No provider_payment_id or YOCO_SECRET_KEY not set for booking ${booking.id}`);
        }
      } catch (err) {
        console.error(`[process-failed-match-refunds] Error processing booking ${booking.id}:`, err.message);
        failedCount++;
      }
    }

    console.log(`[process-failed-match-refunds] Complete: ${processedCount} processed, ${refundedCount} refunded, ${failedCount} failed`);

    return {
      statusCode: 200,
      body: JSON.stringify({
        success: true,
        processed: processedCount,
        refunded: refundedCount,
        failed: failedCount,
      }),
    };

  } catch (error) {
    console.error('[process-failed-match-refunds] Unexpected error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};
