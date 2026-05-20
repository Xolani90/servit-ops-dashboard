# SERVIT v6.3 — Final Pre-Launch Patch

## One file to run (after v6.2)

```
supabase/v6_upgrade/10_patch_v6.3.sql
```

## Add 2 cron jobs in Supabase Dashboard → Database → Cron Jobs

```sql
SELECT cron.schedule('watchdog',         '5 minutes', $$SELECT run_watchdog()$$);
SELECT cron.schedule('refresh-pricing',  '6 hours',   $$SELECT refresh_category_pricing()$$);
```

---

## Fix details

### 1. Cold-start boost
`get_new_fixer_boost(jobs_completed, pass)` returns a score addition:
- 0 jobs: +0.18 (pass 1), +0.09 (pass 2), 0 (pass 3+)
- 1–2 jobs: +0.12 / +0.06 / 0
- 3–5 jobs: +0.06 / +0.03 / 0
- 6+ jobs: 0 (compete on merit)

For premium, new-but-verified fixers bypass pass 3+ hard gates entirely — admin verification is the trust signal.

### 2. Penalty tolerance buffer
Three mechanisms:
- **Grace period**: `ignore_grace_remaining` starts at 3. First 3 ignores cost nothing. Restored by 1 per completion.
- **Window cap**: max 3 penalty events per 24-hour window. After cap hit, only a cooldown is applied, no metric damage.
- **Window reset**: 24 hours after `penalty_window_start`, counter resets.

### 3. Geographic radius hard filter
Hard `WHERE distance <= v_radius_km` before scoring:

| Tier | Pass 1 | Pass 2 | Pass 3+ |
|---|---|---|---|
| Basic | 30 km | 50 km | 50 km |
| Standard | 20 km | 35 km | 35 km |
| Premium | 15 km | 20 km | 30 km |

City-text fallback kicks in when either party has no GPS coordinates.
Normalization bounds computed only from fixers within radius — so scores reflect the local pool.

### 4. Dispatch cooldown
- **Ignore**: 3 min cooldown (5 min if `ignore_count >= 5`)
- **Decline**: 2 min cooldown (no metric damage — honest decline respected)
- Cooldown stored as `cooldown_until TIMESTAMPTZ` — simple `WHERE cooldown_until < now()` filter in queue builder
- Grace period burns before cooldowns start

### 5. Price intelligence
`category_pricing` table updated by `refresh_category_pricing()` every 6 hours.
- Rolling 90-day window of COMPLETED bookings
- Minimum 3 samples required before showing guidance
- `get_price_guidance(category)` returns avg, median, min, max + human-readable suggestion string
- Frontend calls this when booking form opens — non-blocking, shows "Loading..." then updates

### 6. Watchdog
`run_watchdog()` runs every 5 minutes. Triggers:

| Status | Threshold | Action |
|---|---|---|
| SEARCHING/OFFERED (premium) | > 2 min | Admin alert + auto-redispatch if seq ≤ 1 |
| SEARCHING/OFFERED (other) | > 5 min | Admin alert + auto-redispatch if seq ≤ 1 |
| CONFIRMED | > 20 min | Nudge fixer + admin alert |
| IN_PROGRESS | > 4 hours | Admin alert |

Anti-spam: one log entry per booking per 10-minute window.
All events logged to `watchdog_log` for audit.

### 7. Premium hard enforcement
Pass 2 now enforces `rating >= 4.2 AND completion_rate >= 85` as a hard WHERE clause — not a scoring preference. Pass 3 keeps the same floor but opens to unverified. Pass 4 absolute floor: `rating >= 4.0 AND completion_rate >= 80`. There is no pass that sends a 3.8★ fixer to a premium customer.

---

## Verify after deploy

```sql
-- Check cold-start boost values
SELECT get_new_fixer_boost(0,1), get_new_fixer_boost(3,1), get_new_fixer_boost(6,1);
-- Should return: 0.18, 0.06, 0.00

-- Check radius filter working
SELECT * FROM build_dispatch_queue('<searching_booking_id>', 1);

-- Check price guidance (needs completed bookings)
SELECT refresh_category_pricing();
SELECT * FROM category_pricing ORDER BY sample_count DESC;

-- Check watchdog runs cleanly
SELECT run_watchdog();
SELECT * FROM watchdog_log ORDER BY checked_at DESC LIMIT 10;

-- Verify premium hard gate
-- This should return 0 fixers if none meet the bar:
SELECT count(*) FROM fixers
WHERE status = 'approved' AND fixer_status = 'online'
  AND is_verified = true AND rating >= 4.2 AND completion_rate >= 85;

-- Check cooldown column exists
SELECT id, full_name, cooldown_until, ignore_grace_remaining, penalty_window_count
FROM fixers ORDER BY cooldown_until DESC NULLS LAST LIMIT 10;
```

---

## New admin actions

```json
{ "action": "watchdog" }
{ "action": "refresh_pricing" }
{ "action": "price_guidance", "category": "Plumbing" }
```

## Price guidance frontend
Booking form now calls `get_price_guidance` via Supabase RPC when the form opens.
Shows median, range, and sample count inline below the budget field.
Falls back gracefully if no data exists for a category yet.
