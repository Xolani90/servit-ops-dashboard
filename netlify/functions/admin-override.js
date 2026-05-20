// ═══════════════════════════════════════════════════════════════
// admin-override — v6.2
// Actions: assign_fixer | force_status | rematch | dashboard |
//          set_priority | dispatch_next | alert_check |
//          set_fixer_status
// ═══════════════════════════════════════════════════════════════
const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

// SECURITY FIX: Restrict admin endpoint to own origin only.
// process.env.URL is set automatically by Netlify to the site's primary URL.
const CORS = {
  'Access-Control-Allow-Origin': process.env.URL || '',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Vary': 'Origin',
};

const ok  = (data)  => ({ statusCode: 200, headers: { ...CORS, 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
const err = (msg, code = 400) => ({ statusCode: code, headers: CORS, body: JSON.stringify({ error: msg }) });

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS };
  if (event.httpMethod !== 'POST') return err('Method Not Allowed', 405);

  try {
    const token = (event.headers.authorization || '').replace('Bearer ', '');
    const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
    if (authErr || !user) return err('Unauthorized', 401);

    const { data: profile } = await supabase
      .from('profiles').select('user_role').eq('id', user.id).maybeSingle();
    if (profile?.user_role !== 'admin') return err('Admin access required', 403);

    const { action, booking_id, fixer_id, new_status, note: rawNote, priority } = JSON.parse(event.body || '{}');
    // Input length cap on freetext note field
    const note = rawNote ? String(rawNote).slice(0, 1000) : null;


    switch (action) {

      case 'assign_fixer': {
        if (!booking_id || !fixer_id) return err('booking_id and fixer_id required');
        const { data } = await supabase.rpc('admin_assign_fixer', {
          p_admin_id: user.id, p_booking_id: booking_id, p_fixer_id: fixer_id, p_note: note || null
        });
        return ok(data);
      }

      case 'force_status': {
        if (!booking_id || !new_status) return err('booking_id and new_status required');
        const { data } = await supabase.rpc('admin_force_status', {
          p_admin_id: user.id, p_booking_id: booking_id, p_new_status: new_status, p_note: note || null
        });
        return ok(data);
      }

      case 'set_priority': {
        if (!booking_id) return err('booking_id required');
        const { data } = await supabase.rpc('admin_set_priority', {
          p_admin_id:   user.id,
          p_booking_id: booking_id,
          p_priority:   priority !== false,
          p_note:       note || null
        });
        return ok(data);
      }

      case 'rematch': {
        if (!booking_id) return err('booking_id required');
        // Reset to SEARCHING
        await supabase.rpc('admin_force_status', {
          p_admin_id: user.id, p_booking_id: booking_id,
          p_new_status: 'SEARCHING', p_note: 'Admin rematch trigger'
        });
        // Kick off sequential dispatch
        const { data } = await supabase.rpc('dispatch_next_fixer', { p_booking_id: booking_id });
        return ok(data);
      }

      case 'dispatch_next': {
        // Manually advance to next fixer in queue (without waiting for timeout)
        if (!booking_id) return err('booking_id required');
        const { data } = await supabase.rpc('dispatch_next_fixer', { p_booking_id: booking_id });
        return ok(data);
      }

      case 'dashboard': {
        const { data } = await supabase.rpc('admin_dashboard');
        return ok(data);
      }

      case 'alert_check': {
        const { data } = await supabase.rpc('check_and_alert_stuck_jobs');
        return ok({ alerts_sent: data });
      }

      case 'watchdog': {
        const { data } = await supabase.rpc('run_watchdog');
        return ok({ stuck_jobs_found: data });
      }

      case 'refresh_pricing': {
        const { data } = await supabase.rpc('refresh_category_pricing');
        return ok({ categories_updated: data });
      }

      case 'price_guidance': {
        // FIX v6.2: body already parsed into { action, ... } on line 39 — reuse, don't re-parse
        if (!action) return err('category required');  // guard (action already destructured)
        const pgCategory = JSON.parse(event.body || '{}').category;
        if (!pgCategory) return err('category required');
        const { data } = await supabase.rpc('get_price_guidance', { p_category: pgCategory });
        return ok(data);
      }

      case 'set_fixer_status': {
        // FIX v6.2: was a raw client-side fixers.update() that silently failed due to RLS.
        // Routed through service key here so it actually lands, and writes an audit row.
        if (!fixer_id) return err('fixer_id required');
        const ALLOWED_STATUSES = ['approved', 'pending', 'suspended'];
        if (!ALLOWED_STATUSES.includes(new_status)) {
          return err('new_status must be one of: ' + ALLOWED_STATUSES.join(', '));
        }

        const { data: fixer, error: fxErr } = await supabase
          .from('fixers')
          .select('id, status, user_id, full_name')
          .eq('id', fixer_id)
          .maybeSingle();
        if (fxErr || !fixer) return err('Fixer not found');

        const oldStatus = fixer.status || 'pending';

        const { error: upErr } = await supabase
          .from('fixers')
          .update({ status: new_status, updated_at: new Date().toISOString() })
          .eq('id', fixer_id);
        if (upErr) return err(upErr.message, 500);

        // Audit trail — booking_id is nullable (see v8_9_3_fixer_status_audit.sql)
        try {
          await supabase.from('admin_overrides').insert({
            admin_id: user.id,
            action:   'set_fixer_status',
            payload:  { fixer_id, old_status: oldStatus, new_status },
            note:     note || null,
          });
        } catch (auditErr) {
          // Non-fatal: log but don't block the status update
          console.error('admin_overrides audit insert failed:', auditErr);
        }

        // Notify fixer
        const statusMsg = {
          approved:  '\u2705 Your account has been approved! You can now receive job offers.',
          suspended: '\u26a0\ufe0f Your account has been suspended. Please contact support.',
          pending:   '\u2139\ufe0f Your account is under review.',
        };
        try {
          await supabase.from('notifications').insert({
            user_id:    fixer.user_id,
            title:      'Account status update',
            body:       statusMsg[new_status] || ('Your account status is now: ' + new_status),
            type:       'admin_action',
            related_id: fixer_id,
          });
        } catch (_) { /* non-fatal */ }

        return ok({ success: true, fixer_id, old_status: oldStatus, new_status });
      }

      case 'update_metrics': {
        if (!fixer_id) return err('fixer_id required');
        await supabase.rpc('update_fixer_metrics', { p_fixer_id: fixer_id });
        await supabase.rpc('assign_fixer_badges', { p_fixer_id: fixer_id });
        return ok({ success: true });
      }

      default:
        return err(`Unknown action: ${action}`);
    }

  } catch (e) {
    console.error('admin-override error:', e);
    return err(e.message, 500);
  }
};
