# SERVIT v6.1 — Patch Deploy Guide

## Run order in Supabase SQL Editor

Run ONLY these new files (v6.0 files already ran):

```
1. supabase/v6_upgrade/06_dispatch_v6.1.sql    ← sequential dispatch + tier hard rules
2. supabase/v6_upgrade/07_metrics_v6.1.sql     ← performance metrics + updated accept_offer
3. supabase/v6_upgrade/08_badges_admin_v6.1.sql ← trust badges + enhanced admin dashboard
```

## Add these cron jobs in Supabase Dashboard → Edge Functions → Cron

| Job | Schedule | SQL |
|---|---|---|
| Advance expired dispatches | every 15 seconds | `SELECT advance_expired_dispatches()` |
| Alert stuck jobs | every 3 minutes | `SELECT check_and_alert_stuck_jobs()` |
| Assign badges | every hour | `SELECT assign_fixer_badges()` |

---

## What changed (before vs after)

### Tier Matching

**BEFORE** — all tiers used the same weighted score formula, weights differed slightly

**AFTER:**
- **Basic** — `ORDER BY price ASC, distance ASC` — cheapest fixer first, period. No verified filter. 60s timeout, 3 attempts.
- **Standard** — balanced score: 40% rating, 35% distance, 25% acceptance_rate. 30s timeout, 4 attempts.
- **Premium** — `WHERE is_verified=true AND rating>=4.0 AND completion_rate>=80`. `ORDER BY rating DESC, response_time ASC, completion_rate DESC`. 10s timeout, 6 attempts.

### Dispatch Flow

**BEFORE** — broadcast to 3 fixers at once, one 45–60s window, passive

**AFTER — sequential chain:**
```
Job created
  → dispatch_next_fixer() → notifies fixer #1
  → 10/30/60s timeout (tier-dependent)
  → if no response → advance_expired_dispatches() (runs every 15s)
  → dispatch_next_fixer() → notifies fixer #2
  → ... repeat up to 3–6 times
  → if exhausted → reset to SEARCHING + admin alert
```

### Performance Metrics

| Metric | Source | Updates |
|---|---|---|
| acceptance_rate | offers table | after every job |
| completion_rate | bookings table | trigger on COMPLETED/CANCELLED |
| avg_response_time | dispatch_log | rolling average from responded_at - notified_at |
| total_completed | bookings | trigger |

### Trust Badges (auto-assigned)

| Badge | Criteria |
|---|---|
| ✓ Verified | Admin sets `is_verified = true` manually |
| 🏆 Top Fixer | rating ≥ 4.5 AND completion_rate ≥ 90% AND 10+ jobs |
| ⚡ Fast Responder | avg_response_time ≤ 30s AND 5+ accepted jobs |

---

## Admin operations (v6.1)

All via `POST /.netlify/functions/admin-override` with admin JWT:

```json
// Manually advance to next fixer without waiting for timeout
{ "action": "dispatch_next", "booking_id": "..." }

// Flag as priority (halves dispatch timeout)
{ "action": "set_priority", "booking_id": "...", "priority": true }

// Force rematch from scratch
{ "action": "rematch", "booking_id": "..." }

// Live dashboard with stuck jobs + dispatch stats
{ "action": "dashboard" }

// Update a fixer's metrics + badges immediately
{ "action": "update_metrics", "fixer_id": "..." }
```

---

## Verifying it works

```sql
-- Check dispatch is sequential (not broadcast)
SELECT booking_id, sequence_position, status, score, tier, timeout_secs
FROM dispatch_log ORDER BY created_at DESC LIMIT 20;

-- Check badges assigned correctly
SELECT full_name, rating, completion_rate, avg_response_time,
       badge_top_fixer, badge_fast_responder, is_verified
FROM fixers WHERE status = 'approved';

-- Check stuck job alerts going out
SELECT * FROM notifications WHERE type = 'admin_alert' ORDER BY created_at DESC LIMIT 10;
```
