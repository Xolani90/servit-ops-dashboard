# SERVIT v8.5 — Production-Hardening Deployment Guide

Run all steps in order. Each is idempotent — safe to re-run on failure.

---

## Prerequisites

- v8.4 migration already applied (`schema_migrations` has `v8.4`)
- Supabase project is **not paused** during migration
- `platform_config` table exists (added in v8.2)

---

## Step 1 — Apply the SQL migration

In Supabase SQL Editor (or `psql`):

```sql
-- Run supabase/v8_5_production.sql
-- This is idempotent. Safe to re-run if it errors partway through.
```

Verify:

```sql
SELECT version, applied_at FROM schema_migrations ORDER BY applied_at DESC LIMIT 5;
-- Should show: v8.5

SELECT key, value FROM platform_config WHERE key IN (
  'heartbeat_grace_seconds', 'offer_window_seconds'
);
-- heartbeat_grace_seconds → {"seconds": 480, ...}
-- offer_window_seconds    → {"seconds": 90,  ...}

-- Verify payout_runs table exists
SELECT COUNT(*) FROM payout_runs;

-- Verify cron jobs are correct (no 6-field schedules)
SELECT jobname, schedule FROM cron.job
WHERE jobname IN ('expire-offers','release-payouts','extend-active-heartbeats');
-- expire-offers           | * * * * *
-- release-payouts         | */30 * * * *
-- extend-active-heartbeats| */4 * * * *
```

---

## Step 2 — Deploy Netlify functions

```bash
# The new/changed files in netlify/functions/:
#   release-payouts.js  — NEW: scheduled + manual payout release
#
# The updated files:
#   (none — update-location.js still works; heartbeat now goes via RPC)

netlify deploy --prod
```

Verify:

```bash
# Manual trigger (requires admin JWT):
curl -X POST https://your-site.netlify.app/.netlify/functions/release-payouts \
  -H "Authorization: Bearer <admin-jwt>" \
  -H "Content-Type: application/json"
# Expected: {"ok":true,"released":N,"total_amount":X,"run_id":"..."}

# Check audit log
# In Supabase SQL Editor:
SELECT trigger, started_at, payouts_released, total_amount, error_msg
FROM payout_runs ORDER BY started_at DESC LIMIT 10;
```

---

## Step 3 — Deploy frontend

```bash
# app.js has been updated with the hardened heartbeat (Page Visibility API)
# No index.html changes required — the heartbeat-banner element already exists

netlify deploy --prod
```

Verify in browser (fixer logged in):

1. Open DevTools → Console
2. You should see no `update-location` calls — heartbeat now uses `fixer_heartbeat_v2` RPC directly
3. Lock your test phone screen for 30s, unlock → check Console for `"resume"` ping
4. Network tab: look for `supabase.co/rest/v1/rpc/fixer_heartbeat_v2` calls

---

## What Changed (Summary)

### Issue 1 — Fixer supply / offline matching

**Before:** `match_fixers()` only matched online + geo-located fixers. A city with
5 approved fixers all currently offline → booking sits in `SEARCHING` forever.

**After:** Three-tier matching:
- **Tier 1** — online + within GPS radius (best; geo-ranked)
- **Tier 2** — online + city text match (same city, no GPS)
- **Tier 3** — all approved fixers in city regardless of online status →
  push notification sent to each saying "R[X] job waiting, come online!"

Demand broadcast now includes amount and category so fixers can make an
informed decision before opening the app.

New view `fixer_supply_by_city` gives ops a live count of:
`online_now`, `available_but_stale`, `offline`, `flagged` per city.

---

### Issue 2 — Heartbeat expiry / phone lock

**Before:** `setInterval(ping, 60000)` — frozen when phone screen locks on iOS/Android.
3-minute DB grace = 3 misses = fixer excluded. Easily triggered by a 1-minute
screen auto-lock + 2 missed pings.

**After (DB):**
- Grace period extended to **8 minutes** (stored in `platform_config`)
- New cron every **4 minutes**: auto-extends `last_seen_at` for any fixer with
  an active assigned job (they can't be offline — they're working)
- `fixer_heartbeat_v2()` RPC accepts `p_visibility` hint

**After (Frontend):**
- `setTimeout` + self-scheduling (not `setInterval`) with **exponential backoff**
  on failure (30s → 60s → 120s → 240s → 300s max)
- **Page Visibility API** (`visibilitychange` event) fires an immediate ping
  the moment the phone is unlocked or the tab becomes active again
- Heartbeat banner now shows timestamp of last successful ping
- On backoff recovery, interval resets to normal 60s

---

### Issue 3 — 24h payout hold / cron reliability

**Before:** `release_due_payouts()` called by pg_cron only. No audit trail.
If pg_cron missed a run (DB pause, extension restart), payouts silently stalled.
`create_payout` defaulted to **15% commission** instead of the correct 12%.
`fixers.total_earnings` never updated when payout was released.

**After:**
- `payout_runs` audit table: every release attempt (pg_cron or Netlify) logged
  with `started_at`, `finished_at`, `payouts_released`, `total_amount`, `error_msg`
- `release_due_payouts_v2()`: wraps release in a BEGIN/EXCEPTION block, logs
  to `payout_runs`, updates `fixers.total_earnings`
- **Netlify scheduled function** `release-payouts.js`: runs every 30 minutes
  on Netlify's independent scheduler — if pg_cron fails, this fires it
- `create_payout()` fixed: uses `fixer_payout` (rate-locked at booking time)
  for v8.2+ bookings; falls back to `platform_commission_pct()` (12%) for
  older bookings — never the old hardcoded 15%

---

### Other Bugs Fixed

| Bug | Impact | Fix |
|-----|--------|-----|
| **A** `expire-offers` cron used `'*/10 * * * * *'` (6-field — invalid on Supabase pg_cron) | Offers never expired; bookings stuck in OFFERED forever | Fixed to `'* * * * *'` (every 1 min) |
| **B** Heartbeat cutoff inconsistency: `match_fixers` = 3 min, `surge_signal` = 5 min | Fixer could appear in surge metrics but be excluded from matching | All now use `heartbeat_grace_interval()` from `platform_config` |
| **C** `create_payout` defaulted to 15% commission | Fixers underpaid relative to quoted 12% | Fixed to use `platform_commission_pct()` or booking's rate-locked value |
| **D** `release_due_payouts` never updated `fixers.total_earnings` | Running total always stale; earnings statement wrong | Fixed in `release_due_payouts_v2` |
| **E** No index on `payouts(hold_until)` for cron query | Full table scan on every 30-min cron tick | Added `idx_payouts_held_due` partial index |

---

## Rollback

All changes are additive (new tables, new functions, extended columns).
To roll back the heartbeat grace period only:

```sql
UPDATE platform_config SET value = '{"seconds": 180}' WHERE key = 'heartbeat_grace_seconds';
```

To roll back the offer window:

```sql
UPDATE platform_config SET value = '{"seconds": 45}' WHERE key = 'offer_window_seconds';
```

No rollback is needed for `payout_runs` or `release-payouts.js` — they are
append-only and additive.

---

## Monitoring Checklist (post-deploy)

Run these queries daily for the first week:

```sql
-- 1. Are payouts releasing on time?
SELECT trigger, started_at, payouts_released, total_amount, error_msg
FROM payout_runs WHERE started_at > now() - interval '24 hours'
ORDER BY started_at DESC;

-- 2. Are there any stuck held payouts (over 25h)?
SELECT COUNT(*), SUM(net_amount) FROM payouts
WHERE status = 'held' AND hold_until < now() - interval '1 hour';
-- Should be 0. If > 0, trigger manually:
-- SELECT release_due_payouts_v2('manual_sql');

-- 3. Fixer supply health per city
SELECT city, online_now, available_but_stale, offline, total_approved
FROM fixer_supply_by_city;

-- 4. Any bookings stuck in SEARCHING > 30 min?
SELECT id, city, category, created_at, age(now(), created_at) AS waiting
FROM bookings WHERE status = 'SEARCHING' AND created_at < now() - interval '30 minutes'
ORDER BY created_at;

-- 5. Heartbeat cron running?
SELECT jobname, last_run_at, next_run_at, status
FROM cron.job_run_details
ORDER BY start_time DESC LIMIT 20;
```
