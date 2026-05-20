# Servit v8.6 — Bug-Fix Deploy Guide

Run **after** v8.5 is live. All steps are idempotent — safe to re-run on failure.

---

## What's fixed

| Bug | File(s) changed | Summary |
|-----|-----------------|---------|
| **Bug 2** | `netlify/functions/update-job-status.js` | `.single()` → `.maybeSingle()` on booking select; push notification fully fire-and-forget so a NULL `fixer_id` can never crash a committed status update |
| **Bug 3** | `frontend/sw.js` | Service-worker cache bumped from `servit-v4` to `servit-v8`; returning users will now bust the stale cache and re-fetch current app shell on next visit |
| **Bug 4** | `supabase/v8_6_bugfixes.sql` §1 | Retry-matching cron rescheduled to valid 5-field `*/2 * * * *` syntax; added `offer_expires_at < now()` guard so a live 90 s offer window is never trampled |
| **Bug 5** | `supabase/v8_6_bugfixes.sql` §2 + 7 Netlify functions | DB-side sliding-window rate limiter (`rate_limit_hits` table + `check_rate_limit()` RPC); wired into all write-path functions: `accept-offer` (20/hr), `create-booking` (10/hr), `update-location` (120/hr), `raise-dispute` (10/hr), `write-review` (20/hr), `toggle-availability` (60/hr), `decline-offer` (30/hr) |
| **Bug 6** | `supabase/v8_6_bugfixes.sql` §3 | `analytics_events` table created with RLS, indexes, and a 90-day pruning cron; `trackEvent()` in `app.js` will now persist correctly |
| **Sec-1** | `netlify/functions/send-push.js` + 3 callers | `send-push` was unauthenticated — any internet caller could push to any user ID. Now requires `X-Internal-Secret` header; all callers (`accept-offer`, `update-job-status`, `cancel-booking`) forward the secret. Fails closed if `INTERNAL_SECRET` env var is unset. |
| **Sec-2** | All 24 Netlify functions | `SUPABASE_SERVICE_ROLE_KEY` / `SUPABASE_SERVICE_KEY` naming split unified to `SUPABASE_SERVICE_KEY` across all functions — previously half the functions would silently fall back to anon-level DB access if only one name was set in the dashboard |
| **Sec-3** | `netlify.toml` | `Content-Security-Policy` header added: locks `script-src`, `style-src`, `connect-src` (Supabase + Yoco), `frame-ancestors 'none'` |

---

## Deploy order

### 1. Database migration (Supabase SQL editor)

```sql
-- Run this file in full:
supabase/v8_6_bugfixes.sql
```

Verify:
```sql
SELECT version FROM schema_migrations WHERE version = 'v8.6';
-- Should return one row

SELECT jobname, schedule, command
FROM cron.job
WHERE jobname IN ('retry-matching', 'prune-rate-limit-hits', 'prune-analytics-events');
-- retry-matching schedule should be '*/2 * * * *'

\d rate_limit_hits
\d analytics_events
```

### 2. Deploy Netlify functions

Files to deploy (all in `netlify/functions/`):

- `update-job-status.js` — Bug 2 fix
- `accept-offer.js` — Bug 5 fix (rate limiting)

No new environment variables are required; these use the existing `SUPABASE_URL` and `SUPABASE_SERVICE_KEY`.

### 3. Deploy frontend

File to deploy:

- `frontend/sw.js` — Bug 3 fix (cache version bump)

After deploying, verify the new SW is active:

1. Open DevTools → Application → Service Workers
2. Confirm the active SW shows `servit-v8` (not `servit-v4`)
3. Confirm the old `servit-v4` cache key is gone from the Cache Storage panel

> **Important:** Bump `CACHE_VERSION` in `sw.js` on *every* future deploy that changes any file listed in `CACHE_FILES`. Use a monotonic string (`servit-v9`, etc.) or a CI-injected content hash.

---

## Rate-limit coverage status

| Netlify function   | Limit        | Status after v8.6 |
|--------------------|--------------|-------------------|
| `accept-offer`     | 20 / hr      | ✅ Done            |
| `create-booking`   | 10 / hr      | ✅ Done            |
| `update-location`  | 120 / hr     | ✅ Done            |

All three functions now call `check_rate_limit()` immediately after auth, before any DB work. All fail open on RPC error so a DB hiccup on the rate-limit table never blocks legitimate traffic.

---

## New environment variable required

**`INTERNAL_SECRET`** — a shared secret used to authenticate internal function-to-function calls to `send-push`. Must be set in the Netlify dashboard before deploying.

Generate one with:
```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Set it once in the Netlify dashboard under **Site settings → Environment variables**. All functions read it from `process.env.INTERNAL_SECRET` at runtime — no code changes needed when rotating.

---

## Rollback

- **SQL**: The migration is additive (new tables, new cron jobs, updated cron schedule). To roll back Bug 4's cron reschedule: `SELECT cron.unschedule('retry-matching');` and restore the previous schedule.
- **Netlify functions**: Redeploy the previous versions from git.
- **SW cache**: Bump `CACHE_VERSION` to any new string to force another cache bust.
