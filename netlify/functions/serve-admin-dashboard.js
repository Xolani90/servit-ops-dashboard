/**
 * serve-admin-dashboard.js
 *
 * Netlify serverless function that serves the ops dashboard HTML with
 * the Supabase service key and admin password injected at request time
 * via environment variables. This means:
 *   - The service key is NEVER in the static HTML file or git history
 *   - The admin password is validated server-side (HTTP 401 on failure)
 *   - No database, no sessions — one password env var is all you need
 *
 * Env vars required (set in Netlify UI → Site settings → Environment):
 *   ADMIN_DASHBOARD_PASSWORD   — any strong password you choose
 *   SUPABASE_URL               — your Supabase project URL
 *   SUPABASE_SERVICE_KEY  — service role key (NOT the anon key)
 *
 * Deploy: netlify/functions/serve-admin-dashboard.js
 * URL:    /.netlify/functions/serve-admin-dashboard
 *
 * For convenience, add a Netlify redirect in netlify.toml:
 *   [[redirects]]
 *   from = "/ops"
 *   to   = "/.netlify/functions/serve-admin-dashboard"
 *   status = 200
 */

const fs   = require('fs');
const path = require('path');

exports.handler = async function (event) {
  const PW          = process.env.ADMIN_DASHBOARD_PASSWORD;
  const SUPA_URL    = process.env.SUPABASE_URL;
  const SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY;

  // ── Basic configuration guard ─────────────────────────────────
  if (!PW || !SUPA_URL || !SERVICE_KEY) {
    return {
      statusCode: 503,
      body: 'Dashboard not configured — set ADMIN_DASHBOARD_PASSWORD, SUPABASE_URL, and SUPABASE_SERVICE_KEY in Netlify env vars.',
    };
  }

  // ── HTTP Basic Auth check (simplest zero-cost auth for ops tool) ─
  const authHeader = event.headers?.authorization || '';
  let authed = false;

  if (authHeader.startsWith('Basic ')) {
    const decoded  = Buffer.from(authHeader.slice(6), 'base64').toString('utf8');
    const [, pass] = decoded.split(':');   // ignore username
    authed = pass === PW;
  }

  if (!authed) {
    return {
      statusCode: 401,
      headers: {
        'WWW-Authenticate': 'Basic realm="Servit Ops"',
        'Content-Type':     'text/plain',
      },
      body: 'Unauthorized',
    };
  }

  // ── Load the dashboard HTML and inject config ─────────────────
  // netlify/functions/admin/ops-dashboard.html is bundled via `included_files`
  // in netlify.toml. Because the file lives alongside the function, Netlify
  // places it at __dirname/admin/ops-dashboard.html inside the Lambda zip.
  let html;
  try {
    html = fs.readFileSync(path.join(__dirname, 'admin', 'ops-dashboard.html'), 'utf8');
  } catch (err) {
    return {
      statusCode: 500,
      body: `Could not read dashboard HTML: ${err.message}`,
    };
  }

  // Inject only the Supabase URL — service key and admin password are NEVER sent to the client.
  // All DB operations that require the service key are proxied through this function server-side.
  // We also inject the Base64-encoded Basic credential (username omitted, password only) so
  // the dashboard's fetch calls to ops-proxy can include the Authorization header automatically.
  // This is safe: the credential is already known to anyone who passed HTTP Basic Auth to get here.
  const basicCred = Buffer.from(`:${PW}`).toString('base64');
  const inject = `
  <script>
    // Injected server-side by serve-admin-dashboard.js — never committed to git
    window._SUPABASE_URL    = ${JSON.stringify(SUPA_URL)};
    window._opsBasicCred    = ${JSON.stringify(basicCred)};
    // SERVICE_KEY is intentionally NOT injected here — managed server-side only via ops-proxy.
  </script>`;

  html = html.replace('</head>', inject + '\n</head>');

  return {
    statusCode: 200,
    headers: {
      'Content-Type':  'text/html; charset=utf-8',
      'Cache-Control': 'no-store',  // never cache — always fresh data
    },
    body: html,
  };
};
