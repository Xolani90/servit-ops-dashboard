# SERVIT v8.9.8 — Production Launch Checklist

## Critical Issues Found

### ⚠️ CRITICAL: Duplicate Function Definitions Across SQL Files

**Issue**: Multiple SQL files define the same functions with different implementations. Running these in the wrong order will cause the wrong version to be active.

**Affected Functions**:
- `match_fixers()` defined in: v8_9_4_recovery_logic.sql, v8_9_4_structured_logging.sql, v8_9_5_match_consolidation.sql, v8_9_6_match_lock.sql
- `request_matching()` defined in: v8_9_5_match_consolidation.sql, v8_9_6_booking_state_consistency.sql
- `process_matching_requests()` defined in: v8_9_5_match_consolidation.sql, v8_9_6_booking_state_consistency.sql

**Resolution**: The v8.9.6 files contain the final authoritative versions. The migration order below ensures v8.9.6 files run last.

---

## SQL Migration Order (Exact Sequence)

### Phase 1: Base Schema (Run Once)
1. `RUNME_FIRST.sql` — Enable extensions, add missing columns, create schema_migrations table
2. `schema.sql` — Core tables and enums
3. `policies.sql` — Row-level security policies
4. `triggers.sql` — Database triggers

### Phase 2: Core Functions (Run Once)
5. `create-booking.sql` — Booking creation RPC
6. `create-payment-session.sql` — Payment session creation
7. `process-yoco-webhook.sql` — Yoco webhook handler
8. `06_match-fixers.sql` — Original match_fixers (will be replaced by v8.9.6)
9. `07_accept-offer.sql` — Offer acceptance
10. `08_decline-offer.sql` — Offer decline
11. `09_update-job-status.sql` — Job status updates
12. `05_resolve-dispute.sql` — Dispute resolution
13. `03_payouts.sql` — Payout functions
14. `04_write-review.sql` — Review writing
15. `raise-dispute.sql` — Dispute raising
16. `scheduled-activation.sql` — Scheduled booking activation
17. `expire-offers.sql` — Offer expiry

### Phase 3: v6 Upgrade (Run Once)
18. `v6_upgrade/01_schema_upgrade.sql`
19. `v6_upgrade/02_match_fixers_v6.sql`
20. `v6_upgrade/03_fixer_status.sql`
21. `v6_upgrade/04_admin_overrides.sql`
22. `v6_upgrade/05_rls_v6.sql`
23. `v6_upgrade/06_dispatch_v6.1.sql`
24. `v6_upgrade/07_metrics_v6.1.sql`
25. `v6_upgrade/08_badges_admin_v6.1.sql`
26. `v6_upgrade/09_patch_v6.2.sql`
27. `v6_upgrade/10_patch_v6.3.sql`
28. `v6_upgrade/11_schema_v6.4.sql`
29. `v6_upgrade/12_backend_v6.4.sql`

### Phase 4: v7 Marketplace (Run Once)
30. `v7_marketplace/01_schema_marketplace.sql`
31. `v7_marketplace/02_quality_gates.sql`
32. `v7_marketplace/03_surge_and_personalisation.sql`
33. `v7_marketplace/04_fixer_lifecycle.sql`
34. `v7_marketplace/05_fixes.sql`
35. `v7_marketplace/06_production_hardening.sql`
36. `v7_marketplace/07_v8_fixes.sql`
37. `v7_marketplace/08_critical_fixes.sql`
38. `v7_marketplace/09_yoco_fees.sql`

### Phase 5: v8 Bugfixes (Run Once)
39. `v8_7_assignment_safety.sql`
40. `v8_8_cron_fixes.sql`
41. `v8_9_1_audit_fixes.sql`
42. `v8_9_1_cancel_fix.sql`
43. `v8_9_2_patch_booking_rpc.sql`
44. `v8_9_3_fixer_status_audit.sql`
45. `v8_9_4_structured_logging.sql`
46. `v8_9_4_recovery_logic.sql`
47. `v8_9_5_match_consolidation.sql` — Introduces request_matching pattern
48. `v8_9_6_match_lock.sql` — Adds cooldown guard to match_fixers (FINAL VERSION)
49. `v8_9_6_booking_state_consistency.sql` — Adds FAILED_MATCH handling (FINAL VERSION)

### Phase 6: Cron Jobs (Run Once)
50. `10_cron.sql` — Schedule all cron jobs

---

## Required Environment Variables

### Core Supabase
- `SUPABASE_URL` — Supabase project URL (e.g., https://xxx.supabase.co)
- `SUPABASE_SERVICE_KEY` — Service role key (NOT anon key)
- `SUPABASE_ANON_KEY` — Anonymous key for frontend

### Payment Processing
- `YOCO_SECRET_KEY` — Yoco secret key for payment processing
- `YOCO_PUBLIC_KEY` — Yoco public key for frontend (injected via netlify.toml build command)
- `YOCO_WEBHOOK_SECRET` — Yoco webhook secret for signature verification

### Application
- `APP_URL` — Live site URL (e.g., https://servit.co.za) — CRITICAL for Yoco redirects
- `ALLOWED_ORIGIN` — CORS origin for surge-signal function
- `INTERNAL_SECRET` — Internal secret for function-to-function auth

### Push Notifications
- `VAPID_PUBLIC_KEY` — VAPID public key for web push
- `VAPID_PRIVATE_KEY` — VAPID private key for web push
- `VAPID_SUBJECT` — VAPID subject (mailto:)

### Admin
- `ADMIN_DASHBOARD_PASSWORD` — HTTP Basic auth for ops dashboard

### Optional (WhatsApp)
- `WHATSAPP_API_URL` — WhatsApp Business API endpoint
- `WHATSAPP_API_TOKEN` — WhatsApp Business API token

---

## Risk Assessment (Ranked by Severity)

### 🔴 CRITICAL (Launch Blockers)

1. **Duplicate Function Definitions**
   - **Risk**: Wrong version of match_fixers/request_matching/process_matching_requests active
   - **Impact**: Matching system could fail or behave unexpectedly
   - **Mitigation**: Follow exact SQL migration order above, verify final versions are active
   - **Verification**: After migration, run `SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'match_fixers'` and verify it matches v8_9_6_match_lock.sql

2. **Missing APP_URL**
   - **Risk**: Yoco redirects customers to localhost after payment
   - **Impact**: Customers stranded, checkPaymentReturn() never fires
   - **Mitigation**: Set APP_URL in Netlify environment variables before deployment
   - **Verification**: Test payment flow end-to-end in staging

3. **Matching Request Queue Not Processing**
   - **Risk**: process_matching_requests() cron job not scheduled
   - **Risk**: matching_requests table fills up, bookings stuck in SEARCHING
   - **Impact**: No fixers get matched, customers wait indefinitely
   - **Mitigation**: Verify cron job exists after migration: `SELECT * FROM cron.job WHERE jobname = 'process-matching-requests'`
   - **Verification**: Monitor matching_requests table for unprocessed requests

### 🟠 HIGH (Monitor Closely)

4. **Cold Start Latency on Offer Acceptance**
   - **Risk**: accept-offer/decline-offer functions cold start during 45-second window
   - **Impact**: Fixers miss acceptance window, offers expire
   - **Mitigation**: Timeout configuration added to netlify.toml (10s)
   - **Verification**: Monitor Netlify function cold start times in first hour

5. **Set-Based UPDATE Lock Contention**
   - **Risk**: New set-based UPDATE queries could cause lock contention under high load
   - **Impact**: Expiry functions could block, delayed refunds
   - **Mitigation**: FOR UPDATE SKIP LOCKED used, operations are batched
   - **Verification**: Monitor database lock wait times during peak load

6. **FAILED_MATCH Refund Path**
   - **Risk**: FAILED_MATCH bookings not refunded automatically
   - **Impact**: Customers charged but no fixer found, manual refund required
   - **Mitigation**: process_failed_match_refunds() function exists, needs Netlify scheduled function
   - **Verification**: Monitor webhook_errors table for 'failed_match_refund_needed' entries

### 🟡 MEDIUM (Standard Monitoring)

7. **Parallel Execution Errors**
   - **Risk**: Promise.allSettled() in reconciliation functions could mask errors
   - **Impact**: Some bookings not reconciled, silent failures
   - **Mitigation**: Errors are logged, continue processing others
   - **Verification**: Monitor Netlify function logs for reconciliation errors

8. **Frontend Resilience**
   - **Risk**: Unhandled promise rejections in app.js
   - **Impact**: UI freezes, poor user experience
   - **Mitigation**: Error handling added to all async operations
   - **Verification**: Monitor browser console for unhandled rejections

### 🟢 LOW (Nice to Have)

9. **app.js Size (295KB)**
   - **Risk**: Large unminified file affects initial load
   - **Impact**: Slower initial page load
   - **Mitigation**: Acceptable for monolithic SPA without build step
   - **Verification**: Monitor page load times

---

## First 48 Hours Monitoring

### Database Metrics
- **matching_requests table**: Unprocessed request count (should be < 10)
- **booking_events table**: Error event types (match_fixers_error, match_fixers_cooldown)
- **bookings table**: Status distribution (watch for stuck SEARCHING/OFFERED)
- **webhook_errors table**: Error types and counts
- **cron.job table**: Verify all scheduled jobs are active

### Netlify Functions
- **Function cold start times**: Especially accept-offer, decline-offer
- **Function errors**: All functions, especially reconciliation functions
- **Function duration**: Watch for timeouts (>10s)
- **Invocation count**: Verify expected traffic patterns

### Application Metrics
- **Booking flow completion rate**: Payment → Matched → Completed
- **Offer acceptance rate**: Offers sent / Offers accepted
- **Refund rate**: Automatic refunds for EXPIRED/FAILED_MATCH
- **Error rates**: Frontend errors, API errors

### Business Metrics
- **Time to match**: Payment to first offer sent
- **Time to accept**: First offer to acceptance
- **Cancellation rate**: Customer cancellations
- **Fixer availability**: Online fixers at peak times

---

## Rollback Strategy

### If Matching Breaks in Production

**Immediate Actions**:
1. Disable new matching: `UPDATE bookings SET status = 'PAUSED' WHERE status = 'SEARCHING'` (if PAUSED status exists) or stop accepting new bookings
2. Check cron jobs: `SELECT * FROM cron.job WHERE jobname LIKE '%match%'` — verify process-matching-requests is active
3. Check function versions: Verify match_fixers, request_matching, process_matching_requests match v8.9.6 versions
4. Check for errors: `SELECT * FROM booking_events WHERE event_type LIKE '%error%' ORDER BY created_at DESC LIMIT 50`

**Rollback Steps**:
1. If v8.9.6 match_fixers is broken, revert to v8.9.5 version by running v8_9_5_match_consolidation.sql again
2. If request_matching queue is stuck, manually process: `SELECT process_matching_requests()`
3. If cooldown guard is too aggressive, remove it: Run v8_9_5_match_consolidation.sql to revert match_fixers
4. If all else fails, disable matching queue and use direct match_fixers calls (old pattern)

**Verification**:
- Test matching with a staging booking
- Verify offers are sent to fixers
- Verify accept/decline flow works

### If Expiry System Breaks

**Immediate Actions**:
1. Check cron jobs: `SELECT * FROM cron.job WHERE jobname LIKE '%expire%'`
2. Manually expire stuck bookings: `SELECT expire_stuck_searching_bookings()`, `SELECT expire_stuck_offered_bookings()`
3. Check for lock contention: Monitor database locks

**Rollback Steps**:
1. If set-based UPDATE is causing issues, revert to FOR LOOP version by running v8_9_4_recovery_logic.sql (original version)
2. If expire_offers is broken, run the original expire-offers.sql

### If Payment Flow Breaks

**Immediate Actions**:
1. Stop accepting new payments: Disable create-booking function or return error
2. Check Yoco webhook: Verify webhook is receiving events
3. Check process_yoco_payment_success: Test with a known payment ID

**Rollback Steps**:
1. If v8.9 payment flow is broken, revert to v8.8 version
2. Manually process stuck payments: Call process_yoco_payment_success directly

### General Rollback Procedure

1. **Identify the breaking change**: Which SQL file or code change caused the issue
2. **Revert the specific change**: Run the previous version of the SQL file or revert code
3. **Verify the fix**: Test in staging before applying to production
4. **Monitor closely**: Watch for related issues for 24 hours

---

## Pre-Deployment Validation Checklist

### Database
- [ ] All SQL migrations run in exact order above
- [ ] Verify match_fixers matches v8_9_6_match_lock.sql
- [ ] Verify request_matching matches v8_9_6_booking_state_consistency.sql
- [ ] Verify process_matching_requests matches v8_9_6_booking_state_consistency.sql
- [ ] All cron jobs scheduled: `SELECT * FROM cron.job`
- [ ] All indexes created: Check for idx_matching_requests_*, idx_bookings_last_match_triggered_at
- [ ] FAILED_MATCH status added to booking_status_enum: `SELECT unnest(enum_range(NULL::booking_status_enum))`

### Netlify Functions
- [ ] All functions deploy without errors
- [ ] Environment variables set in Netlify dashboard
- [ ] APP_URL set to live domain
- [ ] YOCO_PUBLIC_KEY injected via build command
- [ ] CORS headers configured for all public functions

### Frontend
- [ ] app.js loads without errors
- [ ] marketplace.js loads without errors
- [ ] index.html loads without errors
- [ ] Supabase client initializes correctly
- [ ] Realtime subscriptions connect
- [ ] Payment flow works end-to-end

### Integration Testing
- [ ] Test booking creation → payment → matching → offer → acceptance → completion
- [ ] Test booking expiry → refund
- [ ] Test FAILED_MATCH → refund
- [ ] Test fixer availability toggle
- [ ] Test push notifications
- [ ] Test admin dashboard access

---

## Post-Deployment Verification

### Immediate (First 5 Minutes)
- [ ] No errors in Netlify function logs
- [ ] No errors in Supabase logs
- [ ] Cron jobs running: `SELECT * FROM cron.job`
- [ ] matching_requests table processing: `SELECT COUNT(*) FROM matching_requests WHERE processed = false`
- [ ] New bookings can be created
- [ ] Payments can be processed

### Short-term (First Hour)
- [ ] Matching system working: Bookings moving from SEARCHING to OFFERED
- [ ] Offers being sent to fixers
- [ ] Fixers can accept/decline offers
- [ ] Expiry system working: Old offers expiring
- [ ] Recovery system working: Stuck bookings being reconciled
- [ ] No FAILED_MATCH bookings appearing unexpectedly

### Medium-term (First 24 Hours)
- [ ] Booking completion rate normal
- [ ] Refund rate normal
- [ ] Error rates within acceptable range
- [ ] No lock contention issues
- [ ] Function cold starts acceptable
- [ ] Push notifications delivering

### Long-term (First 48 Hours)
- [ ] All metrics stable
- [ ] No accumulation of stuck bookings
- [ ] No accumulation of unprocessed matching requests
- [ ] Customer complaints within normal range
- [ ] Fixer complaints within normal range
