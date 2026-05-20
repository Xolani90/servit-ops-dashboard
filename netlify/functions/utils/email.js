const { Resend } = require('resend');

let resendClient = null;

if (process.env.RESEND_API_KEY) {
  resendClient = new Resend(process.env.RESEND_API_KEY);
}

async function sendEmail(to, subject, html) {
  if (!resendClient) {
    console.warn('[email] RESEND_API_KEY not set, skipping email send');
    return;
  }

  try {
    await resendClient.emails.send({
      from: 'Servit <noreply@servitapp.online>',
      to,
      subject,
      html
    });
  } catch (error) {
    console.error('[email] Failed to send email:', error);
    throw error;
  }
}

module.exports = { sendEmail };
