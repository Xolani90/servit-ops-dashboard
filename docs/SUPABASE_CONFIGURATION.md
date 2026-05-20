# Supabase Project Configuration Requirements

## Critical Configuration

### Connection Pooling
- **Mode**: Transaction pooling (PGBouncer)
- **Reason**: Serverless functions (Netlify) open many short-lived connections. Without transaction pooling, the database will exhaust connections under load.
- **Configuration**: In Supabase dashboard → Database → Connection pooling, enable transaction pooling mode.

### Plan Requirement
- **Plan**: Paid plan (Pro or higher)
- **Reason**: Free tier projects auto-pause after 1 week of inactivity. This will silently break scheduled functions and webhook handlers.
- **Configuration**: Upgrade to Pro plan in Supabase dashboard.

### pg_cron Extension
- **Status**: Must be enabled
- **Reason**: Scheduled database jobs (expire_stuck_searching_bookings, auto_complete_stuck_bookings, etc.) depend on pg_cron.
- **Configuration**: In Supabase dashboard → Database → Extensions, enable `pg_cron`.

### Realtime
- **Tables**: Enable on `bookings` table
- **Reason**: Frontend may use Realtime for live booking status updates.
- **Configuration**: In Supabase dashboard → Database → Replication, enable Realtime for the `bookings` table.

### Auth Settings
- **Email confirmation**: Disabled (optional, depending on signup flow)
- **Email templates**: Configure custom templates for verification if enabled
- **JWT expiry**: Default (1 hour) is acceptable for this application
- **Row Level Security**: Must be enabled (default in Supabase)

## Required Extensions

- `pg_cron` - For scheduled database jobs
- `uuid-ossp` - For UUID generation (default enabled)
- `postgis` - Optional, for geospatial queries if needed in future

## Database Migration Order

Run migrations in this order:

1. `RUNME_FIRST.sql` - Base schema and initial setup
2. `schema.sql` - Core tables and enums
3. `01_migrate-v4.2-to-v4.3.sql` - Initial RLS policies
4. `02_policies-v4.3-additions.sql` - Additional policies
5. `03_payouts.sql` - Payout system
6. `04_write-review.sql` - Review system
7. `05_resolve-dispute.sql` - Dispute resolution
8. `06_match-fixers.sql` - Matching logic
9. `07_accept-offer.sql` - Offer acceptance
10. `08_decline-offer.sql` - Offer decline
11. `09_update-job-status.sql` - Job status updates
12. `10_cron.sql` - Scheduled jobs
13. `11_audit-fixes-v5.1.sql` - Audit fixes
14. `12_fixer-heartbeat-v2.sql` - Heartbeat improvements
15. `create-booking.sql` - Booking creation
16. `create-payment-session.sql` - Payment sessions
17. `expire-offers.sql` - Offer expiry
18. `process-yoco-webhook.sql` - Yoco webhook handling
19. `raise-dispute.sql` - Dispute raising
20. `scheduled-activation.sql` - Scheduled activation
21. `policies.sql` - RLS policies
22. `triggers.sql` - Database triggers

Then apply version upgrades in order:
- `v6_upgrade/*.sql` (in numerical order)
- `v7_marketplace/*.sql` (in numerical order)
- `v8_*.sql` (in numerical order)

## Environment Variables

The following Supabase-related environment variables must be set in Netlify:

- `SUPABASE_URL` - Your Supabase project URL (e.g., https://xyz.supabase.co)
- `SUPABASE_SERVICE_KEY` - Service role key (NOT anon key) for server-side operations

## Service Role Key Security

**CRITICAL**: Never expose the `SUPABASE_SERVICE_KEY` to client-side code. This key bypasses RLS and has full database access. It should only be used in server-side Netlify functions.

## Connection String Format

For direct database connections (if needed):
```
postgresql://postgres:[YOUR-PASSWORD]@db.[PROJECT-REF].supabase.co:5432/postgres
```

## Monitoring

- Enable query performance monitoring in Supabase dashboard
- Set up alerts for high connection usage
- Monitor function execution logs in Netlify dashboard

## Backup Configuration

- Ensure daily backups are enabled (default on paid plans)
- Point-in-time recovery should be enabled for critical data
- Test backup restoration procedure before production deployment
