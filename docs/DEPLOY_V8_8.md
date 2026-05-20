# SERVIT v8.8 — Critical Bug Fixes

## What was broken (and why the flow stopped after payment)

### BUG 1 — `expire-offers` cron NEVER ran ⚠️ PRIMARY CAUSE

**File:** `supabase/10_cron.sql`

The `expire-offers` job was scheduled with a 6-field cron expression:
```
'*/10 * * * * *'   ← INVALID on Supabase pg_cron (seconds syntax = 6 fields)
```
Supabase's pg_cron only accepts standard 5-field cron syntax. This job **silently failed to schedule**, meaning:

- Offers sent to fixers (45-second window) **never expired**
- Bookings stuck in `OFFERED` were **never reset to `SEARCHING`**
- `match_fixers()` was never retried with the next batch of fixers
- The `RetrySearchExpandRadius` path on the flow diagram was **completely broken**

The `retry-matching` job had the same problem (`'*/30 * * * * *'`), though `v8_6_bugfixes.sql` fixed that one. The `expire-offers` job was missed.

**Fix:** `supabase/v8_8_cron_fixes.sql` reschedules `expire-offers` with valid 5-field syntax.

---

### BUG 2 — `expire-pending-payments` cron threw exceptions on every run

**File:** `supabase/10_cron.sql`

The cron job did a raw `UPDATE bookings SET status = 'EXPIRED' ...` directly in the cron SQL body. But the `prevent_booking_status_update` trigger (added in `triggers.sql`) fires on every status change and raises an exception if `app.allow_status_change` hasn't been set to `'true'` first.

A cron SQL body runs without any session config, so **every run threw an exception** and no `PENDING_PAYMENT` booking ever got expired.

**Fix:** New `expire_stale_pending_payments()` SECURITY DEFINER function sets the flag before updating. Cron now calls the function.

---

### BUG 3 — `retry-matching` had wrong schedule in base `10_cron.sql`

Same 6-field issue. `v8_6_bugfixes.sql` unschedules and corrects it, but only if applied. `v8_8` re-applies defensively.

---

### BUG 4 — `search-timeout-refunds` had no authentication guard

**File:** `netlify/functions/search-timeout-refunds.js`

This function issues real Yoco refunds. It had no check on HTTP requests — anyone who discovered the URL could POST to it and trigger refunds for all bookings that had been searching for 12+ minutes.

`process-nudges.js` had the correct `INTERNAL_SECRET` pattern. `search-timeout-refunds` was missing it.

**Fix:** Added the same `x-internal-secret` header guard as `process-nudges.js`.

---

## Files changed

| File | Change |
|------|--------|
| `supabase/v8_8_cron_fixes.sql` | **NEW** — fixes all 3 cron bugs |
| `netlify/functions/search-timeout-refunds.js` | Added `INTERNAL_SECRET` auth guard |

---

## Deploy steps

### 1. Apply the SQL migration

In Supabase SQL Editor, run:
```
supabase/v8_8_cron_fixes.sql
```

After running, verify the cron jobs registered correctly:
```sql
SELECT jobname, schedule, command, active
FROM cron.job
ORDER BY jobname;
```

Expected output — all 3 fixed jobs should show valid 5-field schedules:
| jobname | schedule |
|---------|----------|
| `expire-offers` | `* * * * *` |
| `expire-pending-payments` | `*/5 * * * *` |
| `retry-matching` | `*/2 * * * *` |

### 2. Deploy Netlify functions

Push the updated `netlify/functions/search-timeout-refunds.js`. No new environment variables needed — it uses the existing `INTERNAL_SECRET` env var.

### 3. Verify the flow

Create a test booking, pay, and confirm:
1. Booking transitions `PENDING_PAYMENT → SEARCHING` (webhook or verify-payment fallback)
2. `match_fixers()` is called — check `booking_events` for `offer_created` rows
3. If no fixer accepts within ~45s, `expire-offers` fires (within 1 minute) → booking resets to `SEARCHING`
4. `retry-matching` fires every 2 minutes to re-call `match_fixers()` with the same/expanded radius

You can also manually test the flow by checking:
```sql
SELECT jobname, last_run_started_at, last_run_status
FROM cron.job_run_details
ORDER BY last_run_started_at DESC
LIMIT 20;
```
