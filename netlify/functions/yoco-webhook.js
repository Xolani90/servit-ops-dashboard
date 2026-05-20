// ═══════════════════════════════════════════════════════════════
// yoco-webhook — Verifies payment server-side and triggers matching
// POST /.netlify/functions/yoco-webhook
//
// FIX: Removed duplicate `const metadata` declaration (was redeclaring
//      a const inside the same scope, causing a ReferenceError at runtime).
//      Renamed inner variable to yocoMetadata.
// ═══════════════════════════════════════════════════════════════

const crypto = require('crypto');
const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const YOCO_SECRET_KEY = process.env.YOCO_SECRET_KEY;
const YOCO_WEBHOOK_SECRET = process.env.YOCO_WEBHOOK_SECRET;

// Verify Yoco HMAC-SHA256 webhook signature.
// FIX B: Yoco stores webhook secrets as "whsec_<base64>".
// The raw string (including the prefix) must NOT be used directly as the HMAC key —
// Yoco computes signatures using the decoded binary of the base64 portion only.
// Passing the raw "whsec_..." string caused every webhook to fail signature check (401),
// meaning process_yoco_payment_success and match_fixers were never called after payment.
function verifySignature(rawBody, signature, secret) {
  if (!signature || !secret) return false;
  // Decode whsec_<base64> → raw binary key
  let hmacKey = secret;
  if (typeof secret === 'string' && secret.startsWith('whsec_')) {
    try {
      hmacKey = Buffer.from(secret.slice(6), 'base64');
    } catch (_) {
      // Malformed base64 — fall back to raw string (will likely still fail, but don't throw)
      hmacKey = secret;
    }
  }
  const expected = crypto
    .createHmac('sha256', hmacKey)
    .update(rawBody)
    .digest('hex');
  try {
    return crypto.timingSafeEqual(
      Buffer.from(signature, 'hex'),
      Buffer.from(expected, 'hex')
    );
  } catch {
    return false;
  }
}

// Server-side verification — NEVER trust the webhook payload alone
async function verifyPaymentWithYoco(paymentId) {
  const response = await fetch(`https://payments.yoco.com/api/payments/${paymentId}`, {
    headers: { 'Authorization': `Bearer ${YOCO_SECRET_KEY}` },
  });
  if (!response.ok) return null;
  return response.json();
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return {
      statusCode: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
      },
    };
  }

  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  try {
    const rawBody = event.body;
    const signature = event.headers['yoco-webhook-signature'];

    // Reject if signature invalid (when secret is configured)
    if (YOCO_WEBHOOK_SECRET && !verifySignature(rawBody, signature, YOCO_WEBHOOK_SECRET)) {
      console.error('Invalid webhook signature');
      return { statusCode: 401, body: 'Invalid signature' };
    }

    const payload = JSON.parse(rawBody);
    // FIX: renamed from `const { id, status, metadata }` — 'metadata' was re-declared
    //      below as `const metadata = verifiedPayment.metadata`, causing ReferenceError.
    const { id: yocoPaymentId, status: payloadStatus } = payload;

    if (!yocoPaymentId || payloadStatus !== 'SUCCESSFUL') {
      return { statusCode: 200, body: 'Not a successful payment event' };
    }

    // CRITICAL: Verify payment server-side with Yoco API — never trust webhook alone
    const verifiedPayment = await verifyPaymentWithYoco(yocoPaymentId);

    if (!verifiedPayment || verifiedPayment.status !== 'SUCCESSFUL') {
      console.error('Payment verification failed for:', yocoPaymentId);
      return { statusCode: 200, body: 'Payment verification failed' };
    }

    const amountPaid = verifiedPayment.amount / 100; // Yoco sends cents
    // FIX: renamed to yocoMetadata to avoid collision with earlier destructuring
    const yocoMetadata = verifiedPayment.metadata || {};
    const paymentUuid = yocoMetadata.payment_id;   // our internal payments.id
    const bookingId = yocoMetadata.booking_id;

    if (!paymentUuid || !bookingId) {
      console.error('Missing metadata in verified payment:', yocoPaymentId);
      return { statusCode: 200, body: 'Missing metadata' };
    }

    // Atomically mark payment paid and advance booking to SEARCHING
    const { data: result, error: processError } = await supabase.rpc('process_yoco_payment_success', {
      p_payment_id: paymentUuid,
      p_provider_payment_id: yocoPaymentId,
      p_amount: amountPaid,
    });

    if (processError) {
      console.error('Payment processing DB error:', processError);
      return { statusCode: 500, body: 'Payment processing failed' };
    }

    console.log(`Payment processed: booking ${bookingId} → SEARCHING`);

    // Apply wallet credit if the customer had any — deducts from wallet balance
    // and logs the transaction. Non-fatal: log failure for manual reconciliation
    // rather than returning 500 (which would cause Yoco to retry the whole webhook).
    try {
      const { data: booking } = await supabase
        .from('bookings')
        .select('customer_id, service_amount, wallet_credit_used')
        .eq('id', bookingId)
        .maybeSingle();

      if (booking?.customer_id && (booking.wallet_credit_used == null || booking.wallet_credit_used === 0)) {
        // wallet_credit_used is 0/null — credit hasn't been deducted yet; apply it now
        const { error: walletError } = await supabase.rpc('apply_wallet_credit_to_booking', {
          p_customer_id:    booking.customer_id,
          p_booking_id:     bookingId,
          p_booking_amount: amountPaid,
        });
        if (walletError) {
          console.error('Wallet credit application failed — needs manual reconciliation:', bookingId, walletError.message);
          await supabase.from('webhook_errors').insert({
            booking_id:  bookingId,
            error_type:  'wallet_credit_failed',
            error_msg:   walletError.message,
            created_at:  new Date().toISOString(),
          }).then(() => {}); // fire-and-forget
        } else {
          console.log(`Wallet credit applied for booking ${bookingId}`);
        }
      }
    } catch (walletErr) {
      console.error('Wallet credit step threw unexpectedly:', walletErr.message);
    }

    // Send confirmation email to the customer.
    // Uses Resend (RESEND_API_KEY env var). Non-fatal — never block the webhook response.
    try {
      const resendKey = process.env.RESEND_API_KEY;
      if (resendKey) {
        // Fetch customer email and booking details for the receipt
        const { data: bookingDetails } = await supabase
          .from('bookings')
          .select('description, address, service_tier, created_at, profiles!customer_id(email, full_name)')
          .eq('id', bookingId)
          .maybeSingle();

        const customerEmail = bookingDetails?.profiles?.email;
        const customerName  = bookingDetails?.profiles?.full_name || 'Customer';
        const serviceName   = bookingDetails?.description || 'Home service';
        const serviceAddr   = bookingDetails?.address || '';
        const bookingRef    = bookingId.slice(0, 8).toUpperCase();
        const bookingDate   = new Date().toLocaleDateString('en-ZA', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
        const appUrl        = process.env.APP_URL || 'https://servit.co.za';

        if (customerEmail) {
          await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: { 'Authorization': `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({
              from:    'Servit <bookings@servit.co.za>',
              to:      customerEmail,
              subject: `Booking confirmed – Ref SV-${bookingRef}`,
              html: `
                <div style="font-family:sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1C1A16">
                  <div style="background:#1A3A2A;border-radius:12px;padding:24px;text-align:center;margin-bottom:24px">
                    <p style="color:#D4A853;font-size:24px;font-weight:700;margin:0">Booking Confirmed ✅</p>
                    <p style="color:rgba(255,255,255,.7);font-size:13px;margin:8px 0 0">Reference: <strong style="color:#fff">SV-${bookingRef}</strong></p>
                  </div>
                  <p style="font-size:15px;margin-bottom:16px">Hi ${customerName},</p>
                  <p style="font-size:14px;color:#374151;line-height:1.7;margin-bottom:20px">
                    Your payment of <strong>R ${amountPaid.toFixed(2)}</strong> has been received and we're now finding you the best available fixer.
                  </p>
                  <div style="background:#F9F6F1;border:1px solid #E8E0D4;border-radius:10px;padding:16px;margin-bottom:20px;font-size:13px">
                    <p style="font-weight:700;margin:0 0 10px;color:#1C1A16">Booking details</p>
                    <p style="margin:4px 0;color:#374151">🔧 <strong>Service:</strong> ${serviceName}</p>
                    <p style="margin:4px 0;color:#374151">📍 <strong>Address:</strong> ${serviceAddr}</p>
                    <p style="margin:4px 0;color:#374151">📅 <strong>Date:</strong> ${bookingDate}</p>
                    <p style="margin:4px 0;color:#374151">💳 <strong>Amount paid:</strong> R ${amountPaid.toFixed(2)}</p>
                    <p style="margin:4px 0;color:#374151">🔖 <strong>Reference:</strong> SV-${bookingRef}</p>
                  </div>
                  <p style="font-size:13px;color:#6B7280;line-height:1.6;margin-bottom:20px">
                    You'll receive another notification once a fixer accepts your job. Track your booking in real time in the app.
                  </p>
                  <div style="text-align:center;margin-bottom:24px">
                    <a href="${appUrl}?booking_id=${bookingId}" style="background:#1A3A2A;color:#D4A853;text-decoration:none;padding:12px 28px;border-radius:8px;font-weight:700;font-size:14px;display:inline-block">Track my booking →</a>
                  </div>
                  <p style="font-size:12px;color:#9CA3AF;text-align:center;border-top:1px solid #E8E0D4;padding-top:16px">
                    Servit · South Africa's home services marketplace<br>
                    If you have questions, open the app and tap Support.
                  </p>
                </div>`,
            }),
          });
          console.log(`Confirmation email sent to ${customerEmail} for booking ${bookingId}`);
        }
      }
    } catch (emailErr) {
      // Never fail the webhook response over an email error
      console.error('Confirmation email failed (non-fatal):', emailErr.message);
    }

    // Signal matching request (worker will process via queue)
    const { error: requestError } = await supabase.rpc('request_matching', {
      p_booking_id: bookingId,
      p_requested_by: 'webhook',
      p_priority: 10, // Highest priority for webhook
      p_radius_km: 25.0,
      p_batch_size: 3,
      p_metadata: jsonb_build_object('source', 'yoco-webhook')
    });

    if (requestError) {
      // Non-fatal: cron will retry; log for visibility
      console.error('Matching request failed (cron will retry):', requestError.message);
    }

    // Push notification: let the customer know we're actively searching.
    // Sent AFTER match_fixers so we never claim "searching" before the DB agrees.
    // Non-fatal — never block the webhook response over a push failure.
    try {
      const internalSecret = process.env.INTERNAL_SECRET;
      const appUrl = process.env.APP_URL || process.env.URL;
      const { data: bkForPush } = await supabase
        .from('bookings')
        .select('customer_id')
        .eq('id', bookingId)
        .maybeSingle();

      if (bkForPush?.customer_id && internalSecret && appUrl) {
        fetch(`${appUrl}/.netlify/functions/send-push`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'x-internal-secret': internalSecret },
          body: JSON.stringify({
            userId:  bkForPush.customer_id,
            title:   '💳 Payment confirmed',
            body:    "We're searching for your Fixer now. You'll be notified the moment one accepts.",
            data:    { type: 'booking', bookingId },
            urgency: 'high',
          }),
        }).catch(e => console.error('Payment-confirmed push failed (non-fatal):', e.message));
      }
    } catch (pushErr) {
      console.error('Payment-confirmed push step threw unexpectedly (non-fatal):', pushErr.message);
    }

    return { statusCode: 200, body: 'OK' };

  } catch (error) {
    console.error('Webhook handler error:', error);
    // Always return 200 to Yoco so it doesn't retry indefinitely
    // Log structured error for operator visibility
    try {
      await supabase.from('webhook_errors').insert({
        error_type: 'handler_exception',
        error_msg: error.message,
        error_detail: error.stack,
        created_at: new Date().toISOString(),
      }).then(() => {}); // fire-and-forget
    } catch (logErr) {
      console.error('Failed to log webhook error:', logErr.message);
    }
    return { statusCode: 200, body: 'OK' };
  }
};
