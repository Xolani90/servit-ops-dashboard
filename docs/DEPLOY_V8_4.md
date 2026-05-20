# SERVIT v8.4 — Exhaustive Audit & Fix Deployment Guide

## What changed

This release fixes **14 bugs** across the booking creation pipeline, subscription management, cancel flow, and schema. Run the SQL migration first, then deploy the updated functions and frontend.

---

## Step 1: SQL Migration (Supabase)

Run in this order in the Supabase SQL Editor:

```
1. supabase/RUNME_FIRST.sql          (adds uuid-ossp extension — Bug 13)
2. supabase/v8_3_fixes.sql           (if not already applied)
3. supabase/v8_3_fixes_part2.sql     (if not already applied)
4. supabase/v8_4_fixes.sql           ← NEW
```

**What v8_4_fixes.sql does:**
- Adds `city TEXT` column to `bookings` (was missing from base schema, causing RPC INSERT failures)
- Relaxes `amount NOT NULL` → nullable so `create_booking_idempotent` can insert without it
- Rewrites `create_booking_idempotent` to accept `p_description` and `p_customer_phone` (no more NULL window)
- Adds `booking_events` audit insert on creation (ops timeline was missing creation event)
- City normalisation: extracts city name from full address string in the DB function (defence-in-depth — the Netlify function also extracts it)
- Adds `uuid-ossp` extension guard

---

## Step 2: Deploy Netlify Functions

Updated files (copy to your Netlify functions directory):
- `netlify/functions/create-booking.js`  — 4 bug fixes (see below)
- `netlify/functions/cancel-booking.js`  — 2 bug fixes
- `netlify/functions/update-job-status.js` — 1 bug fix

---

## Step 3: Deploy Frontend

- `frontend/app.js` — 4 bug fixes

---

## Bug Fix Inventory

### Bugs Fixed (all 14)

| # | File | Bug | Severity |
|---|------|-----|----------|
| 1 | create-booking.js | `p_city: address` — full address string passed as city; city extracted client-side now | **CRITICAL** |
| 2 | create-booking.js + v8_4_fixes.sql | `description` and `customer_phone` had NULL window between RPC and patch; now in RPC directly | **HIGH** |
| 3 | v8_4_fixes.sql | `create_booking_idempotent` had no `booking_events` insert; ops timeline missing creation | **HIGH** |
| 4 | v7_marketplace/09_yoco_fees.sql | `calculate_booking_fees` existence concern — confirmed it exists, no fix needed | N/A |
| 5 | app.js | `loadActiveJob` didn't call `teardownBookingSubscription()` before re-subscribing | **MEDIUM** |
| 6 | app.js | Idempotency key cleared immediately after API call; should be cleared only on payment success | **HIGH** |
| 7 | app.js | `_marketplace.createBooking()` ran before `createBooking()` — double booking on every submit | **CRITICAL** |
| 8 | cancel-booking.js | `.single()` on payments query — PGRST116 crash when no paid payment found | **HIGH** |
| 9 | v8_4_fixes.sql | `amount NOT NULL` constraint violated by `create_booking_idempotent` INSERT | **CRITICAL** |
| 10 | cancel-booking.js | Fixer not notified on post-match cancellation; left with stale job | **HIGH** |
| 11 | update-job-status.js | `CANCELLED` in valid statuses bypasses refund logic in cancel-booking | **CRITICAL** |
| 12 | app.js | Cancelled/failed Yoco payment leaves orphan booking in `CREATED` state forever | **MEDIUM** |
| 13 | RUNME_FIRST.sql | `uuid-ossp` extension not enabled; `uuid_generate_v4()` fails on fresh DB | **HIGH** |
| 14 | (pre-existing) | Cancelled booking now auto-cleans via cancel-booking API call from frontend | **MEDIUM** |

---

## Bug Detail Notes

### Bug 1 — City extraction (create-booking.js)

```javascript
// BEFORE (v8.3) — broken:
p_city: address   // "15 Berea Rd, Durban, 4001" never matches fixer.city

// AFTER (v8.4) — fixed:
const city = extractCityFromAddress(address);  // → "Durban"
p_city: city
```

The `extractCityFromAddress()` helper splits on commas, discards numeric-only tokens (postcodes), and returns the penultimate non-postcode token. Edge cases (bare city names, 2-part addresses) are handled. The SQL function also normalises city in the DB as defence-in-depth.

### Bug 7 — Double booking (app.js)

```javascript
// BEFORE (v8.3) — creates TWO bookings:
if (window._marketplace?.createBooking) {
  await window._marketplace.createBooking({ ... }); // booking #1 via RPC
}
await createBooking(...);  // booking #2 via Netlify function

// AFTER (v8.4) — single path:
await createBooking(...);  // single authoritative path
```

The `_marketplace.createBooking` wrapper used a different sessionStorage key (`mkt-booking-key-{category}`) than the Netlify function (`servit_booking_ikey`), so idempotency didn't deduplicate them.

### Bug 9 — amount NOT NULL (v8_4_fixes.sql)

The `bookings.amount` column was `NOT NULL` with no default. `create_booking_idempotent` inserted `service_amount` but never `amount`. On a fresh schema this would throw `ERROR: null value in column "amount" violates not-null constraint`. The migration relaxes the constraint and the rewritten RPC always sets `amount = p_service_amount`.

### Bug 11 — CANCELLED bypass (update-job-status.js)

```javascript
// BEFORE — allowed bypass:
const validStatuses = ['EN_ROUTE', ..., 'CANCELLED'];

// AFTER — forces correct path:
const validStatuses = ['EN_ROUTE', 'ARRIVED', 'IN_PROGRESS', 'PENDING_COMPLETION', 'COMPLETED'];
// CANCELLED removed — use /.netlify/functions/cancel-booking instead
```

A customer calling `update-job-status` with `status=CANCELLED` would cancel the booking but never trigger the Yoco refund.

---

## Rollback

If the migration causes issues, the following restores `create_booking_idempotent` to the v8.3 version:

```sql
-- Emergency rollback (run v8_3_fixes_part2.sql again to restore)
```

The `amount` column nullability change is safe to roll back:
```sql
-- Restore NOT NULL only if you're sure all existing rows have non-null amounts
ALTER TABLE bookings ALTER COLUMN amount SET NOT NULL;
```
