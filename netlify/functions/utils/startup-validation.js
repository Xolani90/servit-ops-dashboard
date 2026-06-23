// ═══════════════════════════════════════════════════════════════
// utils/startup-validation.js — Required environment variable checker
//
// Call validateEnv(requiredVars) at the top of any Netlify function
// handler to fail fast with a clear error rather than crashing
// cryptically mid-flight when an env var is missing.
//
// Usage:
//   const { validateEnv } = require('./utils/startup-validation');
//   const missing = validateEnv(['SUPABASE_URL', 'SUPABASE_SERVICE_KEY', 'YOCO_SECRET_KEY']);
//   if (missing) return missing; // returns a 500 response object
// ═══════════════════════════════════════════════════════════════

/**
 * Checks that all required env vars are present and non-empty.
 * @param {string[]} vars - List of required env var names
 * @param {object} [corsHeaders] - Optional CORS headers to include in the error response
 * @returns {null | object} null if all present, or a Netlify response object (statusCode 500) if any missing
 */
function validateEnv(vars, corsHeaders = {}) {
  const missing = vars.filter(v => !process.env[v]);
  if (missing.length === 0) return null;

  const message = `[startup-validation] FATAL: Missing required environment variables: ${missing.join(', ')}. ` +
    'Set these in Netlify UI → Site settings → Environment variables.';
  console.error(message);

  return {
    statusCode: 500,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
    body: JSON.stringify({
      error: 'Server misconfiguration — required environment variables are not set.',
      missing,
    }),
  };
}

module.exports = { validateEnv };
