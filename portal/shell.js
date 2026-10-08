/* ==========================================================================
   Sentinel portal — shared shell script (shell.js)
   Renders the sidebar into <aside class="nav" id="nav"></aside>.
   ONE place to add, rename, reorder, or role-scope a nav item.

   Page usage:
     <aside class="nav" id="nav"></aside>
     <script src="/shell.js"></script>          <-- immediately after the aside

   Element IDs (agent-pulse / agent-state / agent-note) are preserved exactly,
   so existing page refresh() code keeps working untouched.
   ========================================================================== */

(function () {
  // ---- Single source of nav truth ---------------------------------------
  // ready:false  -> rendered dimmed and unclickable (page not built yet)
  // roles        -> which lenses see the item. UX only; real scoping is
  //                 server-side via getScopedPayload(role).
  const NAV = [
    { href: '/',                 label: 'Overview',    roles: ['owner','dev','staff'] },
    { href: '/timeline.html',    label: 'Timeline',    roles: ['owner','dev','staff'] },
    { href: '/performance.html', label: 'Performance', roles: ['owner','dev'] },
    { href: '/assets.html',      label: 'Assets',      roles: ['owner','dev'], ready: false },
    { href: '/economy.html',     label: 'Economy',     roles: ['owner','dev'] },
    { href: '/players.html',     label: 'Players',     roles: ['owner','dev','staff'] },
    { href: '/staff.html',       label: 'Staff Log',   roles: ['owner','dev'] },
    { href: '/alerts.html',      label: 'Alerts',      roles: ['owner','dev'] },
  ];

  const ACCOUNT = [
    { href: '/settings.html',    label: 'Settings',    roles: ['owner'], ready: false },
  ];

  // Set window.SENTINEL_ROLE before this script to preview a lens.
  const role = (window.SENTINEL_ROLE || 'owner').toLowerCase();

  // ---- Active-item detection --------------------------------------------
  const here = window.location.pathname.replace(/\/index\.html$/, '/');
  const isActive = (href) => (href === '/' ? here === '/' : here === href);

  const item = (n) => {
    const cls = [isActive(n.href) ? 'active' : '', n.ready === false ? 'soon' : ''].filter(Boolean).join(' ');
    const attrs = n.ready === false
      ? `class="${cls}" aria-disabled="true" title="Coming soon"`
      : `class="${cls}" href="${n.href}"`;
    const tag = n.ready === false ? 'span' : 'a';
    return `<${tag} ${attrs}>${n.label}${n.dot ? '<span class="alert-dot"></span>' : ''}</${tag}>`;
  };

  const visible = (list) => list.filter((n) => n.roles.includes(role));

  // ---- Render ------------------------------------------------------------
  const mount = document.getElementById('nav');
  if (!mount) {
    console.error('[shell] no #nav element found — sidebar not rendered');
    return;
  }

  const accountItems = visible(ACCOUNT);

  mount.innerHTML = `
    <div class="wordmark">
      <div class="brand">SENTINEL</div>
      <div class="sub">BlackStone Development</div>
    </div>
    ${visible(NAV).map(item).join('')}
    ${accountItems.length ? `<div class="grp">Account</div>${accountItems.map(item).join('')}` : ''}
    <div class="foot">
      <div class="st"><span class="pulse" id="agent-pulse"></span> <span id="agent-state">Connecting…</span></div>
      <div id="agent-note">—</div>
    </div>`;

  // ---- Optional helper: pages may call Sentinel.status(ok, note) ----------
  window.Sentinel = window.Sentinel || {};
  window.Sentinel.status = function (ok, note) {
    const pulse = document.getElementById('agent-pulse');
    const state = document.getElementById('agent-state');
    const noteEl = document.getElementById('agent-note');
    if (!pulse) return;
    pulse.classList.toggle('dead', !ok);
    state.textContent = ok ? 'Backend linked' : 'Backend unreachable';
    noteEl.textContent = note || (ok ? '' : 'is server.js running?');
  };
  window.Sentinel.role = role;

  // ---- Shared event rendering ---------------------------------------------
  const esc = (s) => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const NO_REASON = new Set(['', 'unknown', 'none', 'n/a', 'nil', 'null', 'undefined']);
  const usd = (n) => { n = Number(n) || 0; return (n < 0 ? '−' : '') + '$' + Math.abs(n).toLocaleString(); };

  // Money lines are written from the player's account: "+$100 cash" means
  // that much arrived in their cash. Never "deposited/withdrew": a bank
  // deposit is cash going OUT of the wallet, which reads backwards.
  window.Sentinel.money = function (ev, opts = {}) {
    const d = ev.data || {};
    const who = opts.player === false ? '' : `<b>${esc(d.player || '?')}</b> `;
    const acct = esc(d.account || 'money');
    const src = typeof d.source === 'string' ? d.source.trim() : '';
    const reason = NO_REASON.has(src.toLowerCase())
      ? '<span class="reason unk" title="The script that moved this money gave no reason">no reason given</span>'
      : `<span class="reason">${esc(src)}</span>`;
    if (ev.type === 'econ.set') {
      const delta = typeof d.delta === 'number' ? ` (${d.delta >= 0 ? '+' : '−'}${usd(Math.abs(d.delta))})` : '';
      return `${who}${acct} set to ${usd(d.value)}${delta} · ${reason}`;
    }
    const dir = d.direction === 'in' ? 'in' : 'out';
    const bal = opts.balance !== false && typeof d.balance_after === 'number' ? ` · balance ${usd(d.balance_after)}` : '';
    return `${who}<span class="amt ${dir}">${dir === 'in' ? '+' : '−'}${usd(d.amount)}</span> ${acct}${bal} · ${reason}`;
  };

  // Source column: the resource that moved it, plus the framework it went
  // through when that's a different resource ("bsd_banking via qbx_core").
  window.Sentinel.src = function (ev) {
    const s = esc(ev.src || 'server');
    const via = ev.data && ev.data.via;
    return via && via !== ev.src ? `${s} <span class="via">via ${esc(via)}</span>` : s;
  };
})();