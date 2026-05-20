// Only load .env in non-production environments or when critical env vars are missing
if (process.env.NODE_ENV !== 'production' && !process.env.SUPABASE_URL) {
  require('./_env');
}
// ═══════════════════════════════════════════════════════════════
// send-fixer-offer-emails — Send backup email to fixers on new offers
// POST /.netlify/functions/send-fixer-offer-emails
//
// This function is called by a cron job to send backup emails to fixers
// when new job offers are created. It queries for offers that were
// created in the last minute but haven't had an email sent yet.
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

    // Atomically claim offers with email_pending flag that haven't had emails sent
    const { data: offers, error: offersError } = await supabase.rpc('claim_pending_offer_emails', { max_offers: 50 });

    if (offersError) {
      console.error('[send-fixer-offer-emails] Error fetching offers:', offersError);
      return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: offersError.message }) };
    }

    if (!offers || offers.length === 0) {
      return { statusCode: 200, headers: CORS_HEADERS, body: JSON.stringify({ sent: 0, message: 'No new offers to process' }) };
    }

    let sentCount = 0;
    const errors = [];

    for (const offer of offers) {
      try {
        const fixerEmail = offer.fixer_email;
        
        // Null check: if fixer has no email, skip and mark as processed
        if (!fixerEmail || fixerEmail === '') {
          await supabase
            .from('offers')
            .update({ metadata: { email_sent: true, skipped: true, reason: 'no_email' } })
            .eq('id', offer.id);
          continue;
        }

        const serviceCategory = offer.booking_category || 'Service';
        const customerArea = offer.customer_city || 'your area';

        // Send email
        await sendEmail(
          fixerEmail,
          'New job offer — respond in 45 seconds',
          `
            <div style="font-family: sans-serif; max-width: 520px; margin: 0 auto; padding: 24px; color: #1C1A16;">
              <h2 style="margin: 0 0 16px 0;">🔔 New Job Offer</h2>
              <p style="margin: 0 0 16px 0;">You have a new job offer waiting for you!</p>
              <p style="margin: 0 0 16px 0;"><strong>Service Category:</strong> ${serviceCategory}</p>
              <p style="margin: 0 0 16px 0;"><strong>Location:</strong> ${customerArea}</p>
              <p style="margin: 0 0 16px 0;"><strong>Response Time:</strong> 45 seconds</p>
              <p style="margin: 0 0 24px 0;">Open the <strong>Servit app</strong> immediately to accept this offer before it expires.</p>
              <div style="background: #f5f5f5; padding: 16px; border-radius: 8px; text-align: center;">
                <p style="margin: 0; font-weight: bold;">⚡ Act fast — offers expire in 45 seconds!</p>
              </div>
            </div>
          `
        );

        // Mark offer as email sent
        await supabase
          .from('offers')
          .update({ metadata: { email_sent: true, sent_at: new Date().toISOString() } })
          .eq('id', offer.id);

        sentCount++;
        console.log('[send-fixer-offer-emails] Email sent to fixer', offer.fixer_id, 'for offer', offer.id);
      } catch (emailError) {
        console.error('[send-fixer-offer-emails] Error sending email for offer', offer.id, ':', emailError.message);
        errors.push({ offer_id: offer.id, error: emailError.message });
        
        // Mark as attempted even if failed to avoid retry loops
        await supabase
          .from('offers')
          .update({ metadata: { email_sent: false, error: emailError.message, attempted_at: new Date().toISOString() } })
          .eq('id', offer.id);
      }
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sent: sentCount,
        total: offers.length,
        errors: errors.length,
        message: `Processed ${offers.length} offers, sent ${sentCount} emails`
      }),
    };

  } catch (error) {
    console.error('[send-fixer-offer-emails] Unhandled error:', error);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message }),
    };
  }
};
