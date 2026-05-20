/**
 * SERVIT v7.1 — MARKETPLACE ADDONS
 * marketplace.js — drop this file next to app.js and add:
 *   <script src="marketplace.js"></script>
 * AFTER the main <script src="app.js"> tag in index.html.
 *
 * This file monkey-patches / extends existing app.js functions.
 * No changes to app.js are required except the <script> tag.
 *
 * v7.1 fixes applied:
 *   FIX 1 — XSS: onclick string attrs replaced with data-* + addEventListener
 *   FIX 2 — Duplicate mkt-styles injection: CSS injected once in initMarketplace only
 *   FIX 3 — Push retry: failed-attempt counter on fixer_nudges, skip after 3 failures
 *   (FIX 3 is enforced server-side in process-nudges.js — see that file)
 *
 * Features implemented:
 *  1. Dispatch scoring   → SQL side (build_dispatch_queue) — no frontend change needed
 *  2. Quality gates      → SQL side — plus admin badge on fixer cards below
 *  3. Fixer onboarding drip + win celebration → push/in-app via Netlify scheduler
 *  4. Post-job rebook prompt (24h later) → in-app notification card + modal
 *  5. Dormant fixer re-engagement → Netlify scheduled function
 *  6. Surge signal to customer → shown on booking form
 *  7. Home screen personalization → top categories, last-fixer quick rebook, supply counts
 */

(function () {
  'use strict';

  // ─────────────────────────────────────────────────────────────────
  // UTILS
  // ─────────────────────────────────────────────────────────────────

  function getSupabase() {
    // app.js v8.6+ exposes window.supabaseClient; fall back to window.db for older deploys
    return window.supabaseClient || window.db;
  }

  function getCurrentUser() {
    // app.js v8.6+ writes window.currentUser on every sign-in/sign-out
    return window.currentUser || null;
  }

  function getApiBase() {
    return '/.netlify/functions';
  }

  async function mktApiCall(fn, body) {
    const user = getCurrentUser();
    const token = user ? (await getSupabase().auth.getSession())?.data?.session?.access_token : null;
    const res = await fetch(`${getApiBase()}/${fn}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    });
    return res.json();
  }

  // Safe escape for HTML text nodes (NOT for onclick attrs — use data-* instead)
  function escSafe(s) {
    const _escMap = { '`': '&#96;', "'": '&#39;', '"': '&quot;', '&': '&amp;', '<': '&lt;', '>': '&gt;' };
    return String(s || '').replace(/[`'"&<>]/g, c => _escMap[c] || c);
  }

  // ─────────────────────────────────────────────────────────────────
  // REBOOK DISPATCHER
  // FIX 1: was called via inline onclick string — now called via
  // addEventListener on data-* elements. No user data ever touches
  // a JS string context in HTML.
  // ─────────────────────────────────────────────────────────────────

  window._mktRebook = function (bookingId, fixerId, fixerName) {
    if (window.rebookJob) {
      window.rebookJob(bookingId, fixerId || '', fixerName);
    }
  };

  // Attach rebook click handlers to any element with data-mkt-rebook
  function bindRebookButtons(root) {
    (root || document).querySelectorAll('[data-mkt-rebook]').forEach(el => {
      if (el._mktRebookBound) return;
      el._mktRebookBound = true;
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        window._mktRebook(
          el.dataset.bookingId,
          el.dataset.fixerId,
          el.dataset.fixerName
        );
      });
    });
  }

  // ─────────────────────────────────────────────────────────────────
  // FEATURE 7: HOME SCREEN PERSONALISATION
  //
  // ISSUE 2 FIX: Monkey-patches for showHomeScreen and showRequestScreen
  // are applied inside the servit:app-ready event (or as late as possible)
  // so a dynamic import / lazy init in app.js that re-assigns those globals
  // after marketplace.js loads doesn't silently break our patches.
  // ─────────────────────────────────────────────────────────────────

  function applyHomeScreenPatch() {
    const _origShowHomeScreen = window.showHomeScreen;
    window.showHomeScreen = function () {
      _origShowHomeScreen?.();
      loadPersonalisedHome();
      loadRebookPromptCard();
    };
  }

  // Apply immediately (covers the synchronous case) and re-apply on app-ready
  // (covers the lazy-init / dynamic-import case).
  applyHomeScreenPatch();
  window.addEventListener('servit:app-ready', applyHomeScreenPatch, { once: true });

  async function loadPersonalisedHome() {
    const user = getCurrentUser();
    if (!user) return;

    try {
      // ISSUE 5 FIX: use the cached version — skips the DB read if < 5 min old
      const { data, error } = await getSupabase()
        .rpc('get_home_personalisation_cached', { p_customer_id: user.id });

      if (error || !data || !data.personalised) return;

      const topCats = (data.top_categories || []).map(c => c.id);
      if (topCats.length > 0) reorderCategoryGrid(topCats, data.supply_counts || {});

      if (data.last_fixer) {
        injectLastFixerCard(data.last_fixer);
      }
    } catch (err) {
      console.debug('[marketplace] personalisation load error:', err);
    }
  }

  function reorderCategoryGrid(topCatIds, supplyCounts) {
    const grid = document.getElementById('category-grid');
    if (!grid) return;

    requestAnimationFrame(() => {
      const cards = Array.from(grid.querySelectorAll('.category-card'));
      if (!cards.length) return;

      const cardMap = {};
      cards.forEach(card => {
        // Prefer the explicit data-category-id attribute (set by app.js v8.6+).
        // Fall back to parsing the onclick string for older deploys.
        const catId = card.dataset.categoryId ||
          (card.getAttribute('onclick') || '').match(/showRequestScreen\('([^']+)'/)?.[1];
        if (catId) cardMap[catId] = card;
      });

      const reordered = [];
      topCatIds.forEach(catId => {
        if (cardMap[catId]) {
          const card = cardMap[catId];
          reordered.push(card);

          const supplyCount = supplyCounts[catId];
          if (supplyCount > 0) {
            const existingBadge = card.querySelector('.supply-badge');
            if (!existingBadge) {
              const badge = document.createElement('span');
              badge.className = 'supply-badge';
              badge.style.cssText = `
                position:absolute;top:4px;right:4px;
                background:var(--success,#22C55E);color:#fff;
                font-size:9px;font-weight:700;padding:2px 5px;
                border-radius:8px;line-height:1.2;
              `;
              badge.textContent = `${supplyCount} online`;
              card.style.position = 'relative';
              card.appendChild(badge);
            }
          }

          if (catId === topCatIds[0] && !card.querySelector('.top-cat-label')) {
            const label = document.createElement('span');
            label.className = 'top-cat-label';
            label.style.cssText = `
              display:block;font-size:9px;font-weight:700;
              color:var(--forest,#2D6A4F);text-transform:uppercase;
              letter-spacing:.4px;margin-top:2px;
            `;
            label.textContent = 'Your go-to';
            card.appendChild(label);
          }
        }
      });

      cards.forEach(card => {
        if (!reordered.includes(card)) reordered.push(card);
      });

      reordered.slice(0, 9).forEach(card => grid.appendChild(card));
    });
  }

  function injectLastFixerCard(fixer) {
    const container = document.getElementById('home-last-fixer');
    if (!container) {
      const categorySection = document.getElementById('category-grid')?.closest('section') ||
                              document.getElementById('category-grid')?.parentElement;
      if (!categorySection) return;

      const wrapper = document.createElement('div');
      wrapper.id = 'home-last-fixer';
      wrapper.style.cssText = 'margin-bottom:20px;';
      categorySection.insertAdjacentElement('afterend', wrapper);
      renderLastFixerCard(wrapper, fixer);
    } else {
      renderLastFixerCard(container, fixer);
    }
  }

  function renderLastFixerCard(container, fixer) {
    const isOnline = fixer.is_online;
    const rating = fixer.rating ? Number(fixer.rating).toFixed(1) : null;

    // FIX 1: no user data in onclick strings. Build DOM, store data in data-* attrs.
    const photoHtml = fixer.photo_url
      ? `<img src="${escSafe(fixer.photo_url)}" style="width:44px;height:44px;border-radius:50%;object-fit:cover;border:2px solid var(--border,#E8E0D4)" alt="">`
      : `<div style="width:44px;height:44px;border-radius:50%;background:var(--cream,#F5EFE6);display:flex;align-items:center;justify-content:center;font-size:20px;flex-shrink:0">🔧</div>`;

    container.innerHTML = `
      <div class="mkt-rebook-card" style="background:var(--card-bg,#fff);border:1px solid var(--border,#E8E0D4);border-radius:var(--r-lg,14px);padding:14px 16px;display:flex;align-items:center;gap:12px;cursor:pointer"
           data-mkt-rebook data-booking-id="${escSafe(fixer.booking_id)}" data-fixer-id="${escSafe(fixer.fixer_id)}" data-fixer-name="${escSafe(fixer.full_name)}">
        <div style="position:relative;flex-shrink:0">
          ${photoHtml}
          <span style="position:absolute;bottom:1px;right:1px;width:10px;height:10px;border-radius:50%;background:${isOnline ? '#22C55E' : '#9CA3AF'};border:1.5px solid #fff"></span>
        </div>
        <div style="flex:1;min-width:0">
          <p style="font-size:12px;font-weight:700;color:var(--text-muted,#888);text-transform:uppercase;letter-spacing:.5px;margin-bottom:2px">Book again</p>
          <p style="font-weight:700;font-size:14px;color:var(--text-dark,#1C1A16);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${escSafe(fixer.full_name || 'Your fixer')}</p>
          <p style="font-size:12px;color:var(--text-muted,#888)">
            ${rating ? `⭐ ${rating}` : ''}
            ${fixer.category ? `· ${escSafe(fixer.category)}` : ''}
            · ${isOnline ? '<span style="color:#22C55E;font-weight:600">Online now</span>' : 'Offline'}
          </p>
        </div>
        <button class="btn btn-primary btn-sm" style="flex-shrink:0;font-size:12px;padding:8px 14px"
                data-mkt-rebook data-booking-id="${escSafe(fixer.booking_id)}" data-fixer-id="${escSafe(fixer.fixer_id)}" data-fixer-name="${escSafe(fixer.full_name)}">
          Rebook →
        </button>
      </div>`;

    bindRebookButtons(container);
  }

  // ─────────────────────────────────────────────────────────────────
  // FEATURE 4: POST-JOB REBOOK PROMPT
  // ─────────────────────────────────────────────────────────────────

  async function loadRebookPromptCard() {
    const user = getCurrentUser();
    if (!user) return;

    try {
      const { data: promptData } = await getSupabase()
        .rpc('get_rebook_prompt', { p_customer_id: user.id });

      if (!promptData || !promptData.fixer_id) return;

      document.getElementById('rebook-prompt-card')?.remove();

      const card = document.createElement('div');
      card.id = 'rebook-prompt-card';
      card.style.cssText = 'margin-bottom:16px';

      // FIX 1: rebook button uses data-* attrs, no onclick string
      card.innerHTML = `
        <div style="background:linear-gradient(135deg,#FDF3E0,#FBE8C0);border:1px solid #F5D88A;border-radius:var(--r-lg,14px);padding:14px 16px;position:relative">
          <button class="mkt-dismiss-rebook" style="position:absolute;top:10px;right:12px;background:none;border:none;font-size:16px;color:var(--text-muted);cursor:pointer;padding:0;line-height:1">×</button>
          <p style="font-size:12px;font-weight:700;color:#92400E;text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px">👏 Job well done!</p>
          <p style="font-weight:700;font-size:15px;color:var(--text-dark,#1C1A16);margin-bottom:4px">Book ${escSafe(promptData.full_name || 'your fixer')} again?</p>
          <p style="font-size:13px;color:var(--text-muted,#888);margin-bottom:12px">You had a great ${escSafe(promptData.category || 'job')}. Rebook in one tap — no searching needed.</p>
          <div style="display:flex;gap:10px">
            <button class="btn btn-primary btn-sm" style="flex:1;font-size:13px"
                    data-mkt-rebook data-booking-id="${escSafe(promptData.booking_id)}" data-fixer-id="${escSafe(promptData.fixer_id)}" data-fixer-name="${escSafe(promptData.full_name)}">
              🔄 Rebook ${escSafe((promptData.full_name || 'fixer').split(' ')[0])}
            </button>
            <button class="btn btn-outline btn-sm mkt-dismiss-rebook" style="font-size:12px;color:var(--text-muted)">
              Not now
            </button>
          </div>
        </div>`;

      card.querySelectorAll('.mkt-dismiss-rebook').forEach(btn => {
        btn.addEventListener('click', () => document.getElementById('rebook-prompt-card')?.remove());
      });
      bindRebookButtons(card);

      const homeContent = document.getElementById('screen-home');
      const firstSection = homeContent?.querySelector('section, .home-section, [id^="home-"]');
      const container = document.getElementById('home-referral-card') ||
                        document.getElementById('category-grid')?.parentElement;

      if (firstSection) {
        firstSection.parentElement.insertBefore(card, firstSection);
      } else if (container?.parentElement) {
        container.parentElement.insertBefore(card, container);
      }
    } catch (err) {
      console.debug('[marketplace] rebook prompt error:', err);
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // FEATURE 6: SURGE SIGNAL ON BOOKING FORM
  // ─────────────────────────────────────────────────────────────────

  // ISSUE 2 FIX: same safe-patching pattern for showRequestScreen
  function applyRequestScreenPatch() {
    const _origShowRequestScreen = window.showRequestScreen;
    window.showRequestScreen = function (categoryId, emoji, label) {
      _origShowRequestScreen?.(categoryId, emoji, label);
      setTimeout(() => {
        checkSurgeSignal(categoryId);
        autoWireBookingSummary();  // attach fee summary to amount input
      }, 600);
    };
  }
  applyRequestScreenPatch();
  window.addEventListener('servit:app-ready', applyRequestScreenPatch, { once: true });

  async function checkSurgeSignal(category) {
    try {
      const user = getCurrentUser();
      if (!user) return;

      const { data: profile } = await getSupabase()
        .from('profiles')
        .select('city')
        .eq('id', user.id)
        .maybeSingle();

      if (!profile?.city) return;

      const res = await fetch(
        `${getApiBase()}/surge-signal?city=${encodeURIComponent(profile.city)}&category=${encodeURIComponent(category || '')}`
      );
      const surge = await res.json();

      if (surge.is_surge && surge.message) {
        injectSurgeBanner(surge.message, surge.available_fixers);
      }
    } catch (err) {
      console.debug('[marketplace] surge check error:', err);
    }
  }

  function injectSurgeBanner(message, availableFixers) {
    document.getElementById('surge-banner')?.remove();

    const amountInput = document.getElementById('job-budget') ||
                        document.getElementById('booking-amount') ||
                        document.querySelector('input[name="amount"]') ||
                        document.querySelector('input[placeholder*="budget"], input[placeholder*="Budget"]');

    if (!amountInput) return;

    const banner = document.createElement('div');
    banner.id = 'surge-banner';
    banner.style.cssText = `
      background:linear-gradient(135deg,#FFF7ED,#FEE8C8);
      border:1px solid #F59E0B;
      border-radius:10px;
      padding:12px 14px;
      margin-bottom:12px;
      display:flex;
      gap:10px;
      align-items:flex-start;
    `;

    // FIX 1: dismiss button uses addEventListener, not onclick string
    const closeBtn = document.createElement('button');
    closeBtn.style.cssText = 'background:none;border:none;color:#9CA3AF;font-size:18px;cursor:pointer;padding:0;flex-shrink:0;line-height:1';
    closeBtn.textContent = '×';
    closeBtn.addEventListener('click', () => document.getElementById('surge-banner')?.remove());

    const inner = document.createElement('div');
    inner.style.cssText = 'display:flex;gap:10px;align-items:flex-start;flex:1';
    inner.innerHTML = `
      <span style="font-size:20px;flex-shrink:0;margin-top:1px">⏰</span>
      <div style="flex:1">
        <p style="font-weight:700;font-size:13px;color:#92400E;margin-bottom:3px">High demand right now</p>
        <p style="font-size:12px;color:#78350F;line-height:1.5">${escSafe(message)}</p>
        ${availableFixers === 0 ? `<p style="font-size:11px;color:#6B7280;margin-top:4px">Alternatively, try scheduling for later when fixers are available.</p>` : ''}
      </div>`;

    banner.appendChild(inner);
    banner.appendChild(closeBtn);

    const parent = amountInput.closest('.form-group, .input-group, .field-wrap, div') || amountInput.parentElement;
    parent.insertAdjacentElement('beforebegin', banner);
  }

  // ─────────────────────────────────────────────────────────────────
  // FEATURE 3: FIXER WIN CELEBRATION
  // ─────────────────────────────────────────────────────────────────

  async function checkFixerWinCelebration() {
    const user = getCurrentUser();
    if (!user) return;

    try {
      const { data: notif } = await getSupabase()
        .from('notifications')
        .select('id, title, body')
        .eq('user_id', user.id)
        .eq('type', 'win_celebration')
        .eq('read', false)
        .maybeSingle();

      if (!notif) return;

      showFixerWinCelebrationModal(notif);

      await getSupabase()
        .from('notifications')
        .update({ read: true })
        .eq('id', notif.id);
    } catch (err) {
      console.debug('[marketplace] win celebration error:', err);
    }
  }

  function showFixerWinCelebrationModal(notif) {
    document.querySelector('.win-celebration-overlay')?.remove();

    const overlay = document.createElement('div');
    overlay.className = 'win-celebration-overlay';
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(28,26,22,.7);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px;animation:fadeIn .3s ease';

    // FIX 1: close button uses addEventListener, not onclick string
    // FIX 2: CSS is NOT re-injected here — initMarketplace() handles it once
    const milestones = [
      { jobs: 1, label: 'First job ✅', done: true },
      { jobs: 5, label: 'Top Fixer badge', done: false },
      { jobs: 10, label: 'Priority job offers', done: false },
    ];

    const inner = document.createElement('div');
    inner.style.cssText = 'background:var(--warm-white,#FAFAF7);border-radius:var(--r-xl,20px);width:100%;max-width:380px;padding:32px 24px;text-align:center;animation:slideUp .35s cubic-bezier(.25,.46,.45,.94);position:relative';
    inner.innerHTML = `
      <div style="font-size:64px;margin-bottom:16px;animation:bounce .6s ease infinite alternate">🏆</div>
      <h2 style="font-family:'Playfair Display',serif;font-size:24px;font-weight:700;color:var(--text-dark,#1C1A16);margin-bottom:10px">First job done!</h2>
      <p style="font-size:14px;color:var(--text-muted,#888);line-height:1.7;margin-bottom:24px">${escSafe(notif.body || "You're officially a Servit fixer. Keep going — your next job is coming!")}</p>
      <div style="background:var(--cream,#F5EFE6);border-radius:12px;padding:14px;margin-bottom:24px;text-align:left">
        <p style="font-size:11px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.5px;margin-bottom:10px">Your journey</p>
        ${milestones.map(m => `
          <div style="display:flex;align-items:center;gap:10px;margin-bottom:6px">
            <div style="width:24px;height:24px;border-radius:50%;background:${m.done ? 'var(--forest,#2D6A4F)' : 'var(--border,#E8E0D4)'};display:flex;align-items:center;justify-content:center;font-size:11px;color:${m.done ? '#fff' : 'var(--text-muted)'};font-weight:700;flex-shrink:0">${m.jobs}</div>
            <p style="font-size:13px;color:${m.done ? 'var(--text-dark)' : 'var(--text-muted)'};font-weight:${m.done ? '600' : '400'}">${m.label}</p>
          </div>`).join('')}
      </div>
      <button class="btn btn-primary btn-block mkt-close-celebration" style="padding:14px;font-size:15px">
        Let's get the next one 💪
      </button>`;

    overlay.appendChild(inner);

    inner.querySelector('.mkt-close-celebration').addEventListener('click', () => overlay.remove());
    overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
    document.body.appendChild(overlay);

    // Confetti burst — CSS only, no library
    const emojis = ['🎉', '⭐', '🔧', '💪', '🏆'];
    emojis.forEach((emoji, i) => {
      const span = document.createElement('span');
      span.style.cssText = `
        position:fixed;font-size:24px;z-index:10000;pointer-events:none;
        left:${20 + i * 18}%;top:${80 + (i % 2) * 5}%;
        animation:celebBurst${i % 2} 1.2s ease forwards;
      `;
      span.textContent = emoji;
      document.body.appendChild(span);
      setTimeout(() => span.remove(), 1400);
    });
  }

  // ─────────────────────────────────────────────────────────────────
  // FEATURE 5: QUALITY FLAG BADGE (admin)
  // ─────────────────────────────────────────────────────────────────

  function enhanceNotificationCards() {
    const notifList = document.getElementById('notifications-list') ||
                      document.querySelector('.notifications-container');
    if (!notifList) return;

    notifList.querySelectorAll('[data-notif-type="admin_quality_flag"], [data-notif-type="admin_quality_alert"]')
      .forEach(card => {
        if (card.querySelector('.quality-action-btn')) return;
        const btn = document.createElement('button');
        btn.className = 'btn btn-outline btn-sm quality-action-btn';
        btn.style.cssText = 'font-size:11px;margin-top:8px;color:var(--danger,#DC2626);border-color:var(--danger)';
        btn.textContent = 'Review fixer →';
        card.appendChild(btn);
      });
  }

  // ─────────────────────────────────────────────────────────────────
  // FEATURE 6: REFERRAL CODE CAPTURE
  // ─────────────────────────────────────────────────────────────────

  function checkReferralCodeOnSignup() {
    const urlParams = new URLSearchParams(window.location.search);
    const urlCode = urlParams.get('ref');
    if (urlCode) {
      localStorage.setItem('servit_pending_referral', urlCode.toUpperCase());
      window.history.replaceState({}, '', window.location.pathname);
    }
  }

  async function applyPendingReferral() {
    const code = localStorage.getItem('servit_pending_referral');
    if (!code) return;

    const user = getCurrentUser();
    if (!user) return;

    try {
      const result = await mktApiCall('redeem-referral', { referral_code: code });
      if (result.success) {
        localStorage.removeItem('servit_pending_referral');
        if (window.showToast) window.showToast('🎁 R50 referral credit added to your wallet!', 'success');
      } else if (result.error && result.error !== 'Referral already redeemed') {
        if (result.error === 'Referral code not found') {
          localStorage.removeItem('servit_pending_referral');
        }
      }
    } catch (err) {
      console.debug('[marketplace] referral apply error:', err);
    }
  }

  async function loadWalletCredit() {
    const user = getCurrentUser();
    if (!user) return;

    try {
      const { data: profile } = await getSupabase()
        .from('profiles')
        .select('wallet_credit')
        .eq('id', user.id)
        .maybeSingle();

      if (!profile || !profile.wallet_credit || profile.wallet_credit <= 0) return;

      const creditText = `💰 R${Number(profile.wallet_credit).toFixed(0)} credit`;

      // Case 1: request screen badge (placed by app.js — just populate + show it)
      const requestBadge = document.getElementById('wallet-credit-badge');
      if (requestBadge) {
        requestBadge.textContent = creditText;
        requestBadge.style.display = 'block';
        requestBadge.title = 'Wallet credit — applied automatically at checkout';
      }

      // Case 2: home screen badge (create if not already present)
      const header = document.querySelector('#screen-home .topbar, #screen-home .home-header');
      if (header && !header.querySelector('.home-wallet-badge')) {
        const homeBadge = document.createElement('div');
        homeBadge.className = 'home-wallet-badge';
        homeBadge.style.cssText = `
          display:inline-flex;align-items:center;gap:5px;
          background:linear-gradient(135deg,var(--gold,#C9943A),#F5C060);
          color:#fff;font-weight:700;font-size:11px;
          padding:4px 10px;border-radius:20px;
          cursor:pointer;
        `;
        homeBadge.textContent = creditText;
        homeBadge.title = 'Wallet credit — applied automatically on your next booking';
        header.appendChild(homeBadge);
      }
    } catch (err) {
      console.debug('[marketplace] wallet credit error:', err);
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // BOOKING SUMMARY — YOCO FEE BREAKDOWN
  //
  // Renders a live itemised summary below the amount input.
  // Updates as the customer types. Shows:
  //   Service fee      R xxx
  //   💰 Wallet credit − R xx   (if they have credit)
  //   Yoco processing    R x.xx  (2.95% on cash amount only)
  //   ──────────────────────────
  //   Total              R xxx
  //
  // Call window._marketplace.showBookingSummary(containerId, amount)
  // from app.js whenever the booking amount is set/updated.
  // ─────────────────────────────────────────────────────────────────

  let _summaryDebounceTimer = null;

  async function renderBookingSummary(containerEl, serviceAmount) {
    if (!containerEl) return;
    if (!serviceAmount || isNaN(serviceAmount) || serviceAmount <= 0) {
      containerEl.innerHTML = '';
      return;
    }

    // Show skeleton while loading
    containerEl.innerHTML = `
      <div id="mkt-fee-summary" style="
        background:#F9F6F1;border:1px solid #E8E0D4;border-radius:12px;
        padding:14px 16px;margin-top:12px;font-size:13px;
      ">
        <div style="color:#9CA3AF;font-size:12px">Calculating…</div>
      </div>`;

    try {
      const user = getCurrentUser();
      let walletCredit = 0;

      if (user) {
        const { data: profile } = await getSupabase()
          .from('profiles')
          .select('wallet_credit')
          .eq('id', user.id)
          .maybeSingle();
        walletCredit = Math.max(0, Number(profile?.wallet_credit || 0));
      }

      // Calculate fees server-side for accuracy
      const { data: fees, error } = await getSupabase()
        .rpc('calculate_booking_fees', {
          p_service_amount: serviceAmount,
          p_wallet_credit:  walletCredit,
        });

      if (error || !fees) {
        // FIX 2: fallback uses a hardcoded rate. We warn loudly so a rate change in
        // platform_config is not silently missed in the UI. In production this should
        // not fire — if it does, check the Supabase RPC grant on calculate_booking_fees.
        console.warn(
          '[marketplace] calculate_booking_fees RPC failed — falling back to hardcoded rate 0.0295.',
          'If Yoco has changed their pricing, update platform_config AND this fallback.',
          error
        );
        const yocoRate = 0.0295; // ← keep in sync with platform_config.yoco_fee_rate
        const walletApplied = Math.min(walletCredit, serviceAmount);
        const cashBeforeFee = serviceAmount - walletApplied;
        const yocoFee = Math.ceil(cashBeforeFee * yocoRate * 100) / 100;
        renderFeeBreakdown(containerEl, {
          service_amount:  serviceAmount,
          wallet_applied:  walletApplied,
          yoco_fee:        yocoFee,
          total_charged:   cashBeforeFee + yocoFee,
          _fallback:       true,  // flag so renderFeeBreakdown can annotate if desired
        });
        return;
      }

      renderFeeBreakdown(containerEl, fees);

    } catch (err) {
      containerEl.innerHTML = '';
      console.debug('[marketplace] fee summary error:', err);
    }
  }

  function renderFeeBreakdown(containerEl, fees) {
    const sa  = Number(fees.service_amount || 0);
    const wa  = Number(fees.wallet_applied || 0);
    const yf  = Number(fees.yoco_fee || 0);
    const tot = Number(fees.total_charged || sa);

    const fmt = (n) => `R ${Math.abs(n).toFixed(2)}`;

    const rows = [];

    rows.push({ label: 'Service fee',           amount: fmt(sa),  color: '',          weight: 'normal' });

    if (wa > 0) {
      rows.push({ label: '💰 Wallet credit',    amount: `− ${fmt(wa)}`, color: '#16A34A', weight: '600' });
    }

    if (yf > 0) {
      rows.push({
        label: 'Yoco processing fee',
        sub:   '2.95% · Secure card payment',
        amount: fmt(yf),
        color: '#6B7280',
        weight: 'normal',
      });
    } else if (wa >= sa) {
      rows.push({
        label: 'Yoco processing fee',
        sub:   'Fully covered by wallet credit',
        amount: 'R 0.00',
        color: '#16A34A',
        weight: 'normal',
      });
    }

    const rowHtml = rows.map(r => `
      <div style="display:flex;justify-content:space-between;align-items:flex-start;padding:4px 0">
        <div>
          <span style="color:#374151">${escSafe(r.label)}</span>
          ${r.sub ? `<div style="font-size:11px;color:#9CA3AF;margin-top:1px">${escSafe(r.sub)}</div>` : ''}
        </div>
        <span style="font-weight:${r.weight || 'normal'};color:${r.color || '#374151'};white-space:nowrap;margin-left:12px">${escSafe(r.amount)}</span>
      </div>`
    ).join('');

    containerEl.innerHTML = `
      <div id="mkt-fee-summary" style="
        background:#F9F6F1;border:1px solid #E8E0D4;border-radius:12px;
        padding:14px 16px;margin-top:12px;font-size:13px;
      ">
        ${rowHtml}
        <div style="border-top:1px solid #E8E0D4;margin-top:8px;padding-top:8px;display:flex;justify-content:space-between;align-items:center">
          <span style="font-weight:700;color:#1C1A16">Total</span>
          <span style="font-weight:700;font-size:16px;color:#1C1A16">${escSafe(fmt(tot))}</span>
        </div>
        ${wa > 0 ? `
        <div style="margin-top:8px;font-size:11px;color:#6B7280;line-height:1.5">
          Wallet credit applied: ${escSafe(fmt(wa))} · Cash payment: ${escSafe(fmt(tot))}
        </div>` : ''}
      </div>`;
  }

  // Public API: call from app.js with the container element + service amount
  function showBookingSummary(containerOrId, serviceAmount) {
    const el = typeof containerOrId === 'string'
      ? document.getElementById(containerOrId)
      : containerOrId;

    // Debounce — don't fire an RPC on every keystroke
    clearTimeout(_summaryDebounceTimer);
    _summaryDebounceTimer = setTimeout(() => {
      renderBookingSummary(el, Number(serviceAmount));
    }, 350);
  }

  // Auto-wire: if the booking form has a #booking-amount input, attach live updates
  function autoWireBookingSummary() {
    const amountInput =
      document.getElementById('job-budget') ||        // app.js request form uses this ID
      document.getElementById('booking-amount') ||    // fallback for older layouts
      document.querySelector('input[name="amount"]') ||
      document.querySelector('input[placeholder*="budget" i], input[placeholder*="amount" i]');

    if (!amountInput || amountInput._mktSummaryWired) return;
    amountInput._mktSummaryWired = true;

    // Create a container for the summary directly after the input group
    let container = document.getElementById('mkt-fee-summary-wrap');
    if (!container) {
      container = document.createElement('div');
      container.id = 'mkt-fee-summary-wrap';
      const parent = amountInput.closest('.form-group, .input-group, .field-wrap, div') || amountInput.parentElement;
      parent.insertAdjacentElement('afterend', container);
    }

    amountInput.addEventListener('input', () => {
      showBookingSummary(container, amountInput.value);
    });
    amountInput.addEventListener('change', () => {
      showBookingSummary(container, amountInput.value);
    });

    // Show immediately if already has a value
    if (amountInput.value) showBookingSummary(container, amountInput.value);
  }

  // ─────────────────────────────────────────────────────────────────
  // FIXER HEARTBEAT
  // Removed in v8.6 — app.js owns the heartbeat (fixer_heartbeat_v2 RPC)
  // with exponential backoff, visibility events, and error banners.
  // marketplace.js must not run a second loop or it doubles DB load.
  // ─────────────────────────────────────────────────────────────────

  // ─────────────────────────────────────────────────────────────────
  // ISSUE 1 FIX: Idempotency key on booking creation
  // app.js should call window._marketplace.createBooking() instead of
  // calling supabase.from('bookings').insert() directly. This wrapper
  // generates a UUID per booking session and uses the idempotent RPC
  // so a double-tap on a slow connection never creates two bookings.
  // ─────────────────────────────────────────────────────────────────

  async function createBookingIdempotent({ category, serviceTier, address, city, serviceAmount }) {
    const user = getCurrentUser();
    if (!user) throw new Error('Not authenticated');

    // Generate one key per booking attempt — stored in sessionStorage so a
    // page refresh gets a fresh key, but a double-tap in the same session reuses it.
    const storageKey = `mkt-booking-key-${category}`;
    let idempotencyKey = sessionStorage.getItem(storageKey);
    if (!idempotencyKey) {
      idempotencyKey = crypto.randomUUID();
      sessionStorage.setItem(storageKey, idempotencyKey);
    }

    // FIX 1: pass serviceAmount so the DB stamps all fee columns at creation time.
    // This means revenue_summary and reconciliation reports are accurate even if the
    // customer abandons before reaching the payment step.
    const rpcParams = {
      p_customer_id:     user.id,
      p_category:        category,
      p_service_tier:    serviceTier,
      p_address:         address,
      p_city:            city,
      p_idempotency_key: idempotencyKey,
    };
    if (serviceAmount != null && !isNaN(serviceAmount) && serviceAmount > 0) {
      rpcParams.p_service_amount = Number(serviceAmount);
    }

    const { data, error } = await getSupabase().rpc('create_booking_idempotent', rpcParams);

    if (error) throw error;

    // Clear the key after successful creation so the next booking gets a fresh one
    if (data?.ok && !data?.idempotent) {
      sessionStorage.removeItem(storageKey);
    }

    return data;  // { ok, booking_id, idempotent }
  }

  // ─────────────────────────────────────────────────────────────────
  // ISSUE 9 FIX: Wire wallet credit at checkout
  // Call window._marketplace.applyWalletCredit() at the moment the
  // customer confirms payment. Returns { credit_applied, amount_due }.
  // The payment step should charge amount_due, not the original total.
  // ─────────────────────────────────────────────────────────────────

  async function applyWalletCreditAtCheckout(bookingId, bookingAmount) {
    const user = getCurrentUser();
    if (!user) return { credit_applied: 0, amount_due: bookingAmount };

    try {
      const { data, error } = await getSupabase().rpc('apply_wallet_credit_to_booking', {
        p_customer_id:   user.id,
        p_booking_id:    bookingId,
        p_booking_amount: bookingAmount,
      });

      if (error) throw error;

      // Update wallet badge in the UI — both request screen and home screen
      const newBalance = Number(data.wallet_after || 0);
      const newText = newBalance > 0 ? `💰 R${newBalance.toFixed(0)} credit` : '';
      [
        document.getElementById('wallet-credit-badge'),
        document.querySelector('.home-wallet-badge'),
      ].forEach(el => {
        if (!el) return;
        if (newBalance > 0) {
          el.textContent = newText;
          el.style.display = 'block';
        } else {
          el.style.display = 'none';
        }
      });

      return data;  // { ok, credit_applied, amount_due, wallet_after }
    } catch (err) {
      console.debug('[marketplace] wallet credit error:', err);
      return { credit_applied: 0, amount_due: bookingAmount };
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // INITIALISATION
  // FIX 2: CSS injected ONCE here — removed duplicate in showFixerWinCelebrationModal
  // ─────────────────────────────────────────────────────────────────

  function initMarketplace() {
    checkReferralCodeOnSignup();

    if (!document.getElementById('mkt-styles')) {
      const style = document.createElement('style');
      style.id = 'mkt-styles';
      style.textContent = `
        @keyframes celebBurst0 { 0%{opacity:1;transform:translateY(0) scale(1)} 100%{opacity:0;transform:translateY(-120px) scale(1.5)} }
        @keyframes celebBurst1 { 0%{opacity:1;transform:translateY(0) scale(1)} 100%{opacity:0;transform:translateY(-100px) rotate(30deg) scale(1.3)} }
        @keyframes bounce { from{transform:translateY(0)} to{transform:translateY(-8px)} }
        @keyframes fadeIn { from{opacity:0} to{opacity:1} }
        @keyframes slideUp { from{opacity:0;transform:translateY(40px)} to{opacity:1;transform:translateY(0)} }
        .supply-badge { pointer-events:none; animation: fadeIn .3s ease; }
        #surge-banner { animation:fadeIn .3s ease; }
        #rebook-prompt-card > div { animation:fadeIn .4s ease; }
      `;
      document.head.appendChild(style);
    }
  }

  function waitForAuth(callback, maxWait = 8000) {
    let called = false;
    function once() { if (called) return; called = true; callback(); }

    if (window.currentUser !== undefined && window.currentUser !== null) {
      once(); return;
    }
    const start = Date.now();
    window.addEventListener('servit:user-ready', once, { once: true });
    const check = () => {
      if (window.currentUser !== undefined) {
        once();
      } else if (Date.now() - start < maxWait) {
        setTimeout(check, 200);
      } else {
        console.debug('[marketplace] waitForAuth timed out — user may not be logged in');
      }
    };
    check();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
      initMarketplace();
      waitForAuth(() => {
        applyPendingReferral();
        loadWalletCredit();
        setTimeout(checkFixerWinCelebration, 1200);
      });
    });
  } else {
    initMarketplace();
    waitForAuth(() => {
      applyPendingReferral();
      loadWalletCredit();
      setTimeout(checkFixerWinCelebration, 1200);
    });
  }

  window._marketplace = {
    checkSurgeSignal,
    loadPersonalisedHome,
    loadRebookPromptCard,
    checkFixerWinCelebration,
    loadWalletCredit,
    createBooking: createBookingIdempotent,
    applyWalletCredit: applyWalletCreditAtCheckout,
    showBookingSummary,              // call from app.js: showBookingSummary('container-id', amount)
    calculateFees: async (amount, wallet) => {    // utility for any custom UI
      const { data } = await getSupabase().rpc('calculate_booking_fees', {
        p_service_amount: amount, p_wallet_credit: wallet || 0
      });
      return data;
    },
  };
})();
