# SERVIT v6.2 — Patch Deploy Guide

## One file to run

```
supabase/v6_upgrade/09_patch_v6.2.sql
```

Run this after v6.1 files. It replaces:
- `build_dispatch_queue()` — fully rewritten
- `dispatch_next_fixer()` — atomic guard added
- `accept_offer()` — atomic guard added  
- `advance_expired_dispatches()` — penalty wired in
- `assign_fixer_badges()` — dynamic thresholds
- `check_and_alert_stuck_jobs()` — tier-aware timing
- `trigger_update_fixer_metrics()` — reward/penalty wired

## 7 issues fixed

### 1. Normalized scoring
All inputs now 0→1 before weights applied:
```
norm_price    = (max_price - price) / (max_price - min_price)
norm_distance = 1 - (distance_km / 25)
norm_rating   = rating / 5.0
norm_response = 1 - (response_secs / 300)
norm_comp     = completion_rate / 100
```
Bounds computed live from the active fixer pool — so they adapt as fixers go online/offline.

### 2. Race condition eliminated
Both `dispatch_next_fixer` and `accept_offer` now use:
```sql
WHERE fixer_id IS NULL AND status IN ('SEARCHING','OFFERED')
```
`GET DIAGNOSTICS v_rows = ROW_COUNT` — if 0, another process won. Returns `already_assigned` cleanly.
`FOR UPDATE SKIP LOCKED` on the booking row.

### 3. Dynamic timeout
```
get_dispatch_timeout(tier, priority) returns:
  BASIC:    25s base × time_mult
  STANDARD: 18s base × time_mult
  PREMIUM:  10s base × time_mult

time_mult:
  0:00–5:59 → 2.0× (overnight)
  6:00–8:59 → 1.4× (early morning)
  9:00–17:59 → 1.0× (peak)
  18:00–21:59 → 1.2× (evening)
  22:00–23:59 → 1.6× (late night)

priority_flag → halves the result
```

### 4. Multi-pass dispatch (PREMIUM)
```
Pass 1: verified + rating≥4.5 + completion≥90% → 3 fixers
Pass 2: verified + rating≥4.0 + completion≥80% → 4 fixers  
Pass 3: unverified OK + rating≥4.0 + completion≥75% → 5 fixers
Pass 4: any available → 5 fixers
→ fallback
```
Basic/Standard: 2 passes. Premium: 4 passes.

### 5. Behavioral penalties

| Event | acceptance_rate | cancel_penalty | Recovery |
|---|---|---|---|
| Ignore (timeout) | -2 pts | +0.02 | +1 ignore decay per completion |
| Cancel after accept | -10 pts | +0.15 | +0.02 per completion (~7 jobs) |
| Good completion | — | -0.02 | Score approaches baseline |

`cancel_penalty` is a multiplier applied to match score: `score × (1 - penalty)`. Caps at 0.5 (50% reduction).

### 6. Dynamic badges (vs system median)
```sql
-- Runs PERCENTILE_CONT(0.5) on live approved fixers each time
Fast Responder: response_time < median_response AND accepted ≥ 5
Top Fixer:      completion_rate ≥ max(median_comp, 85%) AND rating ≥ 4.5 AND jobs ≥ p75_jobs
```
As the fixer pool quality improves, thresholds tighten automatically.

### 7. Early warning (proactive)
- **PREMIUM jobs**: admin alerted at 90 seconds stuck
- **All others**: admin alerted at 3 minutes stuck
- **Per-dispatch**: warning fires inside `dispatch_next_fixer` at attempt #2 (premium) or #3 (others) — before failure, not after
- Anti-spam: max one alert per booking per 4-minute window

## Cron schedule (update if already set)
```sql
SELECT cron.schedule('advance-dispatch',   '15 seconds', $$SELECT advance_expired_dispatches()$$);
SELECT cron.schedule('alert-stuck-jobs',   '2 minutes',  $$SELECT check_and_alert_stuck_jobs()$$);
SELECT cron.schedule('assign-badges',      '1 hour',     $$SELECT assign_fixer_badges()$$);
```

## Verify
```sql
-- Check normalized scores are in 0–1 range
SELECT * FROM build_dispatch_queue('<any_booking_id_in_SEARCHING>');

-- Check dynamic timeout values
SELECT
  get_dispatch_timeout('basic', false)   AS basic,
  get_dispatch_timeout('standard', false) AS standard,
  get_dispatch_timeout('premium', false) AS premium,
  get_dispatch_timeout('premium', true)  AS premium_priority;

-- Check badges use live medians
SELECT assign_fixer_badges();
SELECT full_name, badge_top_fixer, badge_fast_responder, avg_response_time, completion_rate FROM fixers;

-- Check penalties accumulating correctly
SELECT full_name, acceptance_rate, cancel_penalty, ignore_count FROM fixers ORDER BY cancel_penalty DESC;
```
