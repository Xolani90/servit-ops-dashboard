# SERVIT v8.1 — MERGE + PRODUCTION FIXES DEPLOY GUIDE

All 9 issues from the production audit have been addressed.
This guide covers exactly what changed and how to deploy it.

---

## What's in this package

```
supabase/v7_marketplace/
  01_schema_marketplace.sql       ← base schema (v7, unchanged)
  02_quality_gates.sql            ← quality gate functions (v7, unchanged)
  03_surge_and_personalisation.sql← surge + personalisation RPCs (v7, unchanged)
  04_fixer_lifecycle.sql          ← drip / rebook mechanics (v7, unchanged)
  05_fixes.sql                    ← availability sync + rebook RPC (v7, unchanged)
  06_production_hardening.sql     ← 20-issue audit fixes (v7, unchanged)
  07_v8_fixes.sql                 ← push retry, health alerts, wallet guard (v8)
  08_critical_fixes.sql           ← ALL 9 AUDIT ISSUES fixed (v8.1)
  09_yoco_fees.sql                ← Yoco fee tracking + revenue view ← NEW (v8.2)

frontend/
  marketplace.js                  ← v8.2: Yoco fee UI + all prior fixes merged

netlify/functions/
  surge-signal.js                 ← unchanged
  process-nudges.js               ← v8 version (retry backpressure)
  dormant-fixer-nudge.js          ← v7, unchanged
  redeem-referral.js              ← v7, unchanged
  health-alert.js                 ← v8 version (zero-cost WhatsApp alerting)
  serve-admin-dashboard.js        ← serves ops dashboard securely

admin/
  ops-dashboard.html              ← password-protected ops dashboard
```

---

## Migration order (Supabase SQL editor)

Run in order. Each file is idempotent — safe to re-run.

**New deployments:**
```
01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09
```

**Existing v7 deployments (already ran 01–06):**
```
07 → 08 → 09
```

**Existing v8 deployments (already ran 01–07):**
```
08 → 09
```

**Existing v8.1 deployments (already ran 01–08):**
```
09 only
```

---

## Issue-by-issue summary

### 🔴 ISSUE 1 — Duplicate bookings (idempotency) — FIXED

**What was wrong:** No deduplication on booking creation. Double-tap on a slow connection = two bookings.

**What changed:**
- `bookings.idempotency_key UUID` column + `UNIQUE` index (08_critical_fixes.sql)
- New RPC: `create_booking_idempotent()` — returns existing booking if key already used
- New JS method: `window._marketplace.createBooking({ category, serviceTier, address, city })`

**What to do in app.js:**
Replace:
```js
await supabase.from('bookings').insert({ customer_id, category, ... });
```
With:
```js
const result = await window._marketplace.createBooking({
  category, serviceTier, address, city
});
if (result.ok) {
  const bookingId = result.booking_id;
  // result.idempotent = true means it was a duplicate tap, not a new booking
}
```
The idempotency key is generated once per booking session using `crypto.randomUUID()` and stored in `sessionStorage`. A fresh session = a fresh key.

---

### 🔴 ISSUE 2 — Monkey-patches break on lazy app.js init — FIXED

**What was wrong:** `marketplace.js` patched `showHomeScreen` and `showRequestScreen` at load time. If `app.js` re-assigns those globals after marketplace.js loads (dynamic import, lazy init), the patches silently stop working.

**What changed:**
- Both patches now use a `applyHomeScreenPatch()` / `applyRequestScreenPatch()` wrapper
- Patches are applied immediately AND re-applied on `servit:app-ready`
- If `app.js` dispatches `window.dispatchEvent(new Event('servit:app-ready'))` after its lazy init completes, patches are re-applied automatically

**What to do in app.js:**
After any lazy module load that re-assigns `showHomeScreen` or `showRequestScreen`:
```js
window.dispatchEvent(new Event('servit:app-ready'));
```
Cost: one line.

---

### 🔴 ISSUE 3 — Fixer heartbeat was missing — FIXED

**What was wrong:** `fixer_is_online()` queries `last_online_at`, but nothing was writing to it. Every fixer appeared offline within 5 minutes.

**What changed:**
- New RPCs: `fixer_heartbeat(fixer_id, lat, lng)` and `fixer_go_offline(fixer_id)` (08_critical_fixes.sql)
- `marketplace.js` now calls `startFixerHeartbeat()` on auth — pings every 60 seconds
- Pauses when tab goes to background (visibility API), resumes when it returns
- Calls `fixer_go_offline` when tab hides, so online status is accurate within seconds

**Nothing to do in app.js** — heartbeat starts automatically via marketplace.js.

---

### 🟡 ISSUE 4 — Missing composite index on bookings — FIXED

**What changed (08_critical_fixes.sql):**
```sql
CREATE INDEX idx_bookings_fixer_status_created ON bookings (fixer_id, status, created_at DESC);
CREATE INDEX idx_bookings_customer_status_created ON bookings (customer_id, status, created_at DESC);
```
One SQL migration, zero code changes. Pays off at ~5k rows.

---

### 🟡 ISSUE 5 — Personalisation query on every home screen open — FIXED

**What changed:**
- Two new columns on `profiles`: `personalisation_cache JSONB` and `personalisation_cached_at TIMESTAMPTZ`
- New RPC: `get_home_personalisation_cached()` — returns cached result if < 5 min old, otherwise re-computes and writes the cache
- `marketplace.js` now calls the cached version

**Nothing to do in app.js** — marketplace.js handles it.

---

### 🟡 ISSUE 6 — Referral codes were guessable — FIXED

**What changed:**
- Trigger function upgraded to generate `SV-` + 8 cryptographically random chars from an unambiguous alphabet (no 0/O, 1/I/l)
- Gives ~2.8 billion combinations vs ~16 million before
- Existing codes are NOT changed (would break shared links)
- New sign-ups get the stronger format automatically

---

### 🟠 ISSUE 7 — No admin UI — FIXED

**What's new:**
- `admin/ops-dashboard.html` — password-protected ops dashboard showing:
  - Match rate, completion rate, time-to-match (with alert thresholds highlighted)
  - Booking funnel (created → paid → matched → completed → cancelled)
  - Cancellation breakdown by reason (which party caused it)
  - Per-fixer performance table (completions, earnings, rating, last seen)
- `netlify/functions/serve-admin-dashboard.js` — serves the HTML with credentials injected server-side (never in git)

**Deploy steps:**
1. Set Netlify environment variables:
   - `ADMIN_DASHBOARD_PASSWORD` — your chosen password
   - `SUPABASE_URL` — your project URL
   - `SUPABASE_SERVICE_ROLE_KEY` — from Supabase Settings → API
2. Add to `netlify.toml` (already in `netlify.toml.additions`):
   ```toml
   [[redirects]]
   from = "/ops"
   to   = "/.netlify/functions/serve-admin-dashboard"
   status = 200
   ```
3. Visit `yourdomain.com/ops` — browser Basic Auth prompt → enter password

**Cost: R0. Time: 30 minutes.**

---

### 🟠 ISSUE 8 — No fixer earnings statement — FIXED

**What's new:**
- New RPC: `get_fixer_earnings_statement(fixer_id, days)` — returns:
  - Total earnings this period
  - Total earnings all-time
  - Per-job breakdown (date, category, tier, city, amount, rating, review)
- RLS enforced: fixers can only query their own statement

**What to do in app.js:**
```js
const { data } = await supabase.rpc('get_fixer_earnings_statement', {
  p_fixer_id: currentFixer.id,
  p_days: 30
});
// data.jobs = array of jobs with amounts
// data.total_period = sum for this period
// data.total_all_time = career total
```
Surface this in the fixer earnings screen. Each row shows the job + amount — fixers can verify their pay.

---

### 🟠 ISSUE 9 — Wallet credit was cosmetic — FIXED

**What changed:**
- New RPC: `apply_wallet_credit_to_booking(customer_id, booking_id, booking_amount)`
  - Deducts from `wallet_credit` (with row lock to prevent double-drain)
  - Logs debit to `wallet_transactions`
  - Returns `{ credit_applied, amount_due, wallet_after }`
- New JS method: `window._marketplace.applyWalletCredit(bookingId, bookingAmount)`

**What to do in app.js** at the point where payment is initiated:
```js
// Before charging the payment gateway:
const credit = await window._marketplace.applyWalletCredit(bookingId, totalAmount);
// credit.credit_applied = how much wallet covered
// credit.amount_due = what the payment gateway should charge
// credit.wallet_after = new wallet balance (for UI update)

if (credit.amount_due > 0) {
  // initiate payment for credit.amount_due, not totalAmount
} else {
  // fully covered by wallet — no payment needed
}
```

---

## Netlify toml additions

Append to your existing `netlify.toml`:

```toml
[functions]
  node_bundler = "esbuild"

[[redirects]]
  from = "/ops"
  to   = "/.netlify/functions/serve-admin-dashboard"
  status = 200

[[redirects]]
  from = "/ops/*"
  to   = "/.netlify/functions/serve-admin-dashboard"
  status = 200
```

---

## Environment variables (Netlify UI)

| Variable | Value |
|---|---|
| `ADMIN_DASHBOARD_PASSWORD` | Strong password — you choose |
| `SUPABASE_URL` | `https://xxxxx.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key from Supabase Settings → API |

The existing `process.env.SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` vars are probably already set for your other functions — the dashboard reuses them.

---

---

## v8.2 additions — Yoco fee tracking (09_yoco_fees.sql)

### What this migration does

- Adds `service_amount`, `wallet_credit_used`, `yoco_fee`, `total_charged`, `platform_fee`, `fixer_payout` columns to `bookings`
- Creates `platform_config` table — stores the Yoco rate (2.95%) and your commission rate (12%) so you can change either in one place without a deployment
- `calculate_booking_fees(service_amount, wallet_credit)` — server-side fee calculator used by both the UI preview and at checkout
- Updates `create_booking_idempotent` to accept `p_service_amount` and stamp all fee columns at booking creation time
- Updates `apply_wallet_credit_to_booking` to recalculate the Yoco fee after credit is applied and stamp the booking row
- Updates `after_booking_completed` trigger with rate-lock: the trigger only back-fills `platform_fee`/`fixer_payout` when they are NULL (pre-v8.2 rows). It never overwrites values locked at booking creation, so fixers are always paid what was quoted regardless of future rate changes.
- `revenue_summary` view — daily breakdown: gross service value, Yoco fees paid, Servit revenue, fixer payouts, wallet credits redeemed, and net Servit cash

### What to do in app.js

When creating a booking, pass `serviceAmount` so fee columns are stamped immediately:
```js
const result = await window._marketplace.createBooking({
  category, serviceTier, address, city,
  serviceAmount: quotedPrice,  // ← add this
});
// result.fees has the full itemised breakdown if you need it immediately
```

To show a live fee breakdown on the booking summary screen:
```js
// Call whenever the quoted amount is known or updated:
window._marketplace.showBookingSummary('your-container-id', quotedPrice);
```

### Update Yoco rate (if Yoco changes pricing)
Run once in Supabase SQL editor — no deployment needed:
```sql
UPDATE platform_config
SET value = '{"rate": 0.029, "label": "Yoco processing fee (2.9%)", "vat_inclusive": true}',
    updated_at = now()
WHERE key = 'yoco_fee_rate';
```

### Update your commission rate
```sql
UPDATE platform_config
SET value = '{"rate": 0.12, "label": "Servit platform fee (12%)"}',
    updated_at = now()
WHERE key = 'platform_commission_rate';
```
Note: this only affects bookings created after the change. Existing booked (but incomplete) jobs retain the rate that was locked in at the time of booking.

---

## What's still not done (and why)

**Fixer earnings UI** — The RPC is ready, but wiring the frontend earnings screen is app.js work that requires knowledge of your exact screen/modal structure. The data is there; just call the RPC and render the rows.

**Wallet credit UI update** — `applyWalletCredit` updates the `#wallet-credit-badge` element if it exists. Make sure your checkout screen has an element with that ID so the balance updates live.

**Admin phone number for health alerts** — Run this once in Supabase SQL editor after deploying:
```sql
INSERT INTO admin_contacts (label, phone)
VALUES ('ops_lead', '+27821234567')  -- ← your number
ON CONFLICT (label) WHERE active = true DO NOTHING;
```
