# SERVIT v6.0 — Deploy Guide

## What's new in v6.0

| Feature | Description |
|---|---|
| Service Tiers | Basic / Standard / Premium — different matching weights |
| Fixer Status | online / offline / busy — replaces boolean `available` |
| Adaptive Matching | Tier-weighted scoring (price / distance / rating / response) |
| Dispatch Log | Every match attempt recorded with score |
| Admin Overrides | Assign fixer manually, force status, rematch stuck jobs |
| Expanded Categories | 20 service categories (was 9) |
| "See All" Bottom Sheet | Fixed — shows all categories above 9 |

---

## Run order in Supabase SQL Editor

Run these files IN ORDER:

```
1. supabase/RUNME_FIRST.sql                    ← migration record + category column
2. supabase/policies.sql                       ← fixes ALL 500/403 errors (run this first!)
3. supabase/triggers.sql                       ← idempotent realtime
4. supabase/v6_upgrade/01_schema_upgrade.sql   ← new columns + tables
5. supabase/v6_upgrade/02_match_fixers_v6.sql  ← tier-aware matching
6. supabase/v6_upgrade/03_fixer_status.sql     ← fixer status functions
7. supabase/v6_upgrade/04_admin_overrides.sql  ← admin functions
8. supabase/v6_upgrade/05_rls_v6.sql           ← RLS for new tables
9. supabase/functions/create-booking.sql       ← DB function
10. supabase/functions/09_update-job-status.sql
11. supabase/05_resolve-dispute.sql
12. supabase/10_cron.sql
```

---

## Admin operations (manual "fake Uber" mode)

Call `/.netlify/functions/admin-override` with your admin JWT:

### Assign fixer manually
```json
{ "action": "assign_fixer", "booking_id": "...", "fixer_id": "...", "note": "Manual dispatch" }
```

### Force job status (resolve stuck)
```json
{ "action": "force_status", "booking_id": "...", "new_status": "COMPLETED", "note": "Admin resolved" }
```

### Re-dispatch a stuck job
```json
{ "action": "rematch", "booking_id": "..." }
```

### Get dashboard summary
```json
{ "action": "dashboard" }
```

### Make a user admin (run in Supabase SQL Editor)
```sql
UPDATE profiles SET user_role = 'admin' WHERE email = 'your@email.com';
```

---

## Tier behavior summary

| Tier | Price weight | Distance weight | Rating weight | Response weight | Timeout | Min amount |
|---|---|---|---|---|---|---|
| Basic | 50% | 40% | 10% | 0% | 60s | R50 |
| Standard | 20% | 33% | 33% | 14% | 45s | R150 |
| Premium | 0% | 20% | 50% | 30% | 45s | R300 |

Premium tier also filters to verified fixers only (unless none available).

---

## What NOT to build yet

- Surge pricing — needs volume data first
- Separate apps per tier — one app adapts
- ML matching — current scoring is sufficient for MVP
- In-app payments — Yoco redirect works fine
- WhatsApp bot — add after launch when you have real traffic data
