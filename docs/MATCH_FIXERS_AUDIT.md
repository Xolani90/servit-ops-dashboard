# match_fixers() Call Site Audit

## Executive Summary

**Total Direct Call Sites: 7**

Current architecture has **7 different entry points** that directly call `match_fixers()`, creating race conditions, duplicate matching attempts, and inconsistent behavior.

---

## Call Site Inventory

### 1. yoco-webhook.js (PRIMARY PATHWAY)
**File:** `netlify/functions/yoco-webhook.js`
**Line:** 231
**Context:** After successful Yoco payment verification
```javascript
const { error: matchError } = await supabase.rpc('match_fixers', {
  p_booking_id: bookingId,
});
```
**Trigger:** Yoco webhook POST when payment succeeds
**Parameters:** Default (radius=25km, batch=3)
**Race Condition Risk:** HIGH - If webhook fires multiple times

---

### 2. verify-payment.js (FALLBACK PATHWAY)
**File:** `netlify/functions/verify-payment.js`
**Lines:** 104, 172 (two calls)
**Context:** Client-side fallback when webhook misses
```javascript
// Line 104 - inside payment already paid check
await supabase.rpc('match_fixers', { p_booking_id: booking_id }).catch(e =>
  console.warn('[verify-payment] match_fixers error (non-fatal):', e.message)
);

// Line 172 - after processing payment
const { error: matchError } = await supabase.rpc('match_fixers', { p_booking_id: booking_id });
```
**Trigger:** Frontend polling after payment=success URL param
**Parameters:** Default (radius=25km, batch=3)
**Race Condition Risk:** HIGH - Can race with webhook

---

### 3. retry-matching.js (CRON PATHWAY)
**File:** `netlify/functions/retry-matching.js`
**Line:** 64
**Context:** Scheduled retry for stuck bookings
```javascript
const { data: matchRes, error: matchErr } = await supabase.rpc('match_fixers', {
  p_booking_id: booking_id,
  p_radius_km: radiusKm,
  p_batch_size: 4,
});
```
**Trigger:** Netlify scheduled function (every 30s)
**Parameters:** Expanded radius (25km + 15km per retry), batch=4
**Race Condition Risk:** MEDIUM - Has grace period but can still race

---

### 4. reconcile-searching-bookings.js (RECONCILIATION PATHWAY)
**File:** `netlify/functions/reconcile-searching-bookings.js`
**Line:** 62
**Context:** Aggressive retry for bookings stuck >2 minutes
```javascript
const { data: matchResult, error: matchError } = await supabase.rpc('match_fixers', {
  p_booking_id: booking.id,
  p_radius_km: expandedRadius,
  p_batch_size: 5 // Increase batch size for stuck bookings
});
```
**Trigger:** Netlify scheduled function (every 2 minutes)
**Parameters:** Expanded radius (50-150km based on stuck duration), batch=5
**Race Condition Risk:** MEDIUM - Can race with other retry mechanisms

---

### 5. reconcile-payments.js (PAYMENT RECONCILIATION PATHWAY)
**File:** `netlify/functions/reconcile-payments.js`
**Line:** 121
**Context:** Re-trigger matching for stuck SEARCHING bookings with paid payments
```javascript
const { error: matchError } = await supabase.rpc('match_fixers', {
  p_booking_id: booking.id,
  p_radius_km: 50, // Expanded radius
  p_batch_size: 5
});
```
**Trigger:** Netlify scheduled function (every 10 minutes)
**Parameters:** Fixed radius=50km, batch=5
**Race Condition Risk:** MEDIUM - Can race with other retry mechanisms

---

### 6. decline-offer.js (DECLINE RETRY PATHWAY)
**File:** `netlify/functions/decline-offer.js`
**Line:** 98
**Context:** Immediate retry after fixer declines offer
```javascript
supabase.rpc('match_fixers', { p_booking_id: result.booking_id })
  .then(({ error }) => { if (error) console.error('Rematch error after decline:', error.message); });
```
**Trigger:** Fixer declines job offer
**Parameters:** Default (radius=25km, batch=3)
**Race Condition Risk:** LOW - Fire-and-forget, but still duplicates logic

---

### 7. supabase/10_cron.sql (DATABASE CRON PATHWAY)
**File:** `supabase/10_cron.sql`
**Line:** 40
**Context:** pg_cron job for retry-matching
```sql
SELECT match_fixers(
  b.id,
  LEAST(70.0, 25.0 + (
    SELECT COUNT(*)::DOUBLE PRECISION * 15.0
    FROM   booking_events be
    WHERE  be.booking_id  = b.id
      AND  be.event_type IN ('match_attempt', 'manual_retry_search')
  )),
  3   -- p_batch_size
)
```
**Trigger:** pg_cron schedule (every 30 seconds)
**Parameters:** Dynamic radius expansion, batch=3
**Race Condition Risk:** HIGH - Runs at DB level, can race with Netlify functions

---

## Problems Identified

### 1. Race Conditions
- **Webhook vs verify-payment:** Both can fire simultaneously after payment
- **Multiple cron jobs:** retry-matching (30s), reconcile-searching (2m), reconcile-payments (10m) can all target same booking
- **DB cron vs Netlify cron:** Both retry-matching mechanisms can run concurrently

### 2. Inconsistent Parameters
- Different batch sizes: 3, 4, 5
- Different radius strategies: default, dynamic, fixed, time-based
- No coordination between strategies

### 3. Duplicate Audit Events
- Each call creates a `match_attempt` booking_event
- Multiple concurrent calls create confusing audit trails
- Hard to track which attempt actually succeeded

### 4. No Single Source of Truth
- No canonical "matching requested" signal
- Each pathway independently decides when to match
- No way to prevent redundant matching

### 5. Debugging Difficulty
- 7 different call sites to investigate when matching fails
- No centralized logging (until v8.9.4 logging added)
- Hard to trace which pathway triggered a specific match

---

## Consolidation Plan

### Proposed Architecture: Signal-Then-Match Pattern

**Concept:** All pathways signal intent to match via a single table. One authoritative worker processes signals and calls match_fixers().

#### New Table: matching_requests
```sql
CREATE TABLE matching_requests (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  requested_by TEXT NOT NULL, -- 'webhook', 'verify-payment', 'cron', 'decline', 'reconcile'
  priority INTEGER DEFAULT 0, -- Higher priority = process first
  radius_km DOUBLE PRECISION DEFAULT 25.0,
  batch_size INTEGER DEFAULT 3,
  metadata JSONB DEFAULT '{}'::jsonb,
  processed BOOLEAN DEFAULT false,
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(booking_id, processed) -- Only one unprocessed request per booking
);
```

#### New Function: request_matching()
```sql
CREATE OR REPLACE FUNCTION request_matching(
  p_booking_id UUID,
  p_requested_by TEXT,
  p_priority INTEGER DEFAULT 0,
  p_radius_km DOUBLE PRECISION DEFAULT 25.0,
  p_batch_size INTEGER DEFAULT 3,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_request_id UUID;
BEGIN
  -- Insert or update matching request
  INSERT INTO matching_requests (
    booking_id, requested_by, priority, radius_km, batch_size, metadata
  ) VALUES (
    p_booking_id, p_requested_by, p_priority, p_radius_km, p_batch_size, p_metadata
  )
  ON CONFLICT (booking_id, processed) WHERE processed = false
  DO UPDATE SET
    priority = GREATEST(matching_requests.priority, p_priority),
    radius_km = GREATEST(matching_requests.radius_km, p_radius_km),
    batch_size = GREATEST(matching_requests.batch_size, p_batch_size),
    metadata = matching_requests.metadata || p_metadata,
    created_at = now()
  RETURNING id INTO v_request_id;

  RETURN v_request_id;
END;
$$;
```

#### New Worker Function: process_matching_requests()
```sql
CREATE OR REPLACE FUNCTION process_matching_requests()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_request RECORD;
  v_processed_count INTEGER := 0;
BEGIN
  -- Process highest priority unprocessed requests
  FOR v_request IN
    SELECT *
    FROM matching_requests
    WHERE processed = false
    ORDER BY priority DESC, created_at ASC
    LIMIT 10
    FOR UPDATE
  LOOP
    -- Call match_fixers with request parameters
    PERFORM match_fixers(
      v_request.booking_id,
      v_request.radius_km,
      v_request.batch_size
    );

    -- Mark as processed
    UPDATE matching_requests
    SET processed = true,
        processed_at = now()
    WHERE id = v_request.id;

    v_processed_count := v_processed_count + 1;
  END LOOP;

  RETURN jsonb_build_object('processed', v_processed_count);
END;
$$;
```

#### Scheduled Worker
```sql
-- Run every 5 seconds to process matching requests
SELECT cron.schedule(
  'process-matching-requests',
  '*/5 * * * *',
  $$ SELECT process_matching_requests(); $$
);
```

---

## Migration Strategy

### Phase 1: Add Infrastructure
1. Create `matching_requests` table
2. Create `request_matching()` function
3. Create `process_matching_requests()` worker
4. Add scheduled worker cron job
5. Run in parallel with existing system (no breaking changes)

### Phase 2: Migrate Call Sites (One by One)
1. **yoco-webhook.js** → Change to call `request_matching('webhook', priority=10)`
2. **verify-payment.js** → Change to call `request_matching('verify-payment', priority=9)`
3. **decline-offer.js** → Change to call `request_matching('decline', priority=8)`
4. **retry-matching.js** → Change to call `request_matching('cron', priority=5)`
5. **reconcile-searching-bookings.js** → Change to call `request_matching('reconcile-searching', priority=7)`
6. **reconcile-payments.js** → Change to call `request_matching('reconcile-payment', priority=6)`
7. **supabase/10_cron.sql** → Change to call `request_matching('db-cron', priority=4)`

### Phase 3: Remove Old Direct Calls
1. Monitor for 24-48 hours to ensure stability
2. Remove all direct `match_fixers()` calls
3. Keep `match_fixers()` function (called only by worker)
4. Update documentation

### Phase 4: Cleanup
1. Remove old retry-matching Netlify function (now redundant)
2. Consolidate reconcile-searching and reconcile-payments into single worker
3. Add metrics to matching_requests table for observability

---

## Benefits of Consolidation

### 1. Eliminates Race Conditions
- Single worker processes requests serially
- No concurrent matching attempts on same booking
- Deduplication via UNIQUE constraint

### 2. Consistent Parameters
- Worker uses parameters from highest-priority request
- No conflicting radius/batch strategies
- Predictable behavior

### 3. Better Observability
- All matching requests logged in one table
- Can trace which pathway triggered each match
- Easy to audit and debug

### 4. Priority-Based Processing
- Webhook/verify-payment get highest priority (immediate)
- Reconciliation gets medium priority (catch-up)
- Background cron gets lowest priority (maintenance)

### 5. Throttling & Backpressure
- Worker can limit concurrent matches
- Can add rate limiting per booking
- Prevents matching storms

### 6. Future Extensibility
- Easy to add new request sources
- Can add A/B testing for matching strategies
- Can add ML-based parameter selection

---

## Implementation Order

1. **Create SQL migration file** (`v8_9_5_match_consolidation.sql`)
2. **Update Netlify functions** (6 files)
3. **Update Supabase cron** (1 file)
4. **Test in staging**
5. **Deploy to production**
6. **Monitor for 48 hours**
7. **Remove legacy code**

---

## Risk Assessment

### Low Risk
- Adding new infrastructure (non-breaking)
- Migrating one call site at a time
- Running in parallel during transition

### Medium Risk
- Worker performance under load
- Priority ordering correctness
- Backlog accumulation if worker falls behind

### Mitigation
- Start with conservative worker limits (10 per batch)
- Add monitoring for backlog size
- Can increase worker frequency if needed
- Fallback: Can temporarily disable worker and revert to direct calls
