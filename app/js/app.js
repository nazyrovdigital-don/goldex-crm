// App shell: auth gate, router, navigation, search, notifications and the
// click dispatcher. Elements declare data-act="name" (+ data-* params);
// pages register handlers with register().
import { html, esc, toast, closeModal, modal, ago, setThresholds } from './ui.js';

const bootMsg = (m) => { document.getElementById('boot-msg').textContent = m; };
let db, DEMO;
try {
  bootMsg('Connecting to database…');
  ({ db, DEMO } = await import('./db.js'));
} catch (e) {
  bootMsg('Could not start: ' + e.message);
  throw e;
}
export { db };

// ── ACTIONS ────────────────────────────────────────────────────────
const actions = {};
export const register = (map) => Object.assign(actions, map);

document.addEventListener('click', async (ev) => {
  const el = ev.target.closest('[data-act]');
  if (!el || el.disabled) return;
  const fn = actions[el.dataset.act];
  if (!fn) return;
  ev.preventDefault();
  try { await fn(el.dataset, el, ev); }
  catch (e) { console.error(e); toast(e.message, 'error'); }
});
document.addEventListener('change', async (ev) => {
  const el = ev.target.closest('[data-change]');
  if (!el) return;
  try { for (const name of el.dataset.change.split(' ')) await actions[name]?.(el.dataset, el, ev); }
  catch (e) { console.error(e); toast(e.message, 'error'); }
});
document.getElementById('modal').addEventListener('mousedown', (e) => { if (e.target.id === 'modal') closeModal(); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { closeModal(); hideFloating(); } });

// ── STATE ──────────────────────────────────────────────────────────
export const state = { settings: {}, me: null, users: [] };
export async function loadSettings() {
  for (const s of await db.list('settings')) state.settings[s.key] = s.value;
  setThresholds(state.settings.margin_thresholds);
}
export const setting = (k, fallback) => state.settings[k] ?? fallback;

// ── ROUTER ─────────────────────────────────────────────────────────
const NAV = [
  ['Overview', [['dashboard', '⬡', 'Dashboard']]],
  ['Sales', [['pipeline', '◈', 'Pipeline', 'leads'], ['leads', '◎', 'Leads'], ['estimates', '◇', 'Estimates'], ['proposals', '◻', 'Proposals']]],
  ['Operations', [['projects', '▣', 'Projects'], ['tasks', '☑', 'Tasks', 'tasks'], ['calendar', '▦', 'Calendar']]],
  ['Customers', [['customers', '◉', 'Customers']]],
  ['Finance', [['invoices', '▤', 'Invoices', 'ar'], ['payments', '◈', 'Payments'], ['expenses', '▥', 'Expenses'], ['time', '◷', 'Time & Labor']]],
  ['Setup', [['pricebook', '▦', 'Price Book'], ['settings', '⚙', 'Settings']]],
];
const pages = {};
export const page = (name, def) => { pages[name] = def; };

export const go = (path) => { if (location.hash === '#/' + path) render(); else location.hash = '#/' + path; };
let current = null;

export async function render() {
  if (!pages.dashboard) return;                       // pages still loading during startup
  const [path, query] = location.hash.replace(/^#\/?/, '').split('?');
  const [name, ...params] = path.split('/');
  if (query) {
    const q = new URLSearchParams(query);
    if (q.get('thumbtack')) setTimeout(() => toast(q.get('thumbtack') === 'connected' ? 'Thumbtack connected ✓' : 'Thumbtack connection failed: ' + q.get('thumbtack'), q.get('thumbtack') === 'connected' ? 'ok' : 'error'), 300);
  }
  const p = pages[name] || pages.dashboard;
  current = { name: pages[name] ? name : 'dashboard', params };
  document.querySelectorAll('.nav-item, .mobile-tabs a').forEach((n) => n.classList.toggle('active', n.dataset.page === (p.nav || current.name)));
  document.getElementById('page-title').textContent = typeof p.title === 'function' ? '' : p.title;
  document.getElementById('sidebar').classList.remove('open');
  document.getElementById('sidebar-overlay').classList.remove('open');
  const root = document.getElementById('content');
  try {
    root.innerHTML = String(await p.render(...params));
    await p.after?.(root, ...params);
  } catch (e) {
    console.error(e);
    root.innerHTML = String(html`<div class="empty"><div class="empty-icon">⚠</div><div>${e.message}</div></div>`);
  }
  refreshBadges();
}
export const refresh = () => render();
window.addEventListener('hashchange', render);

function drawNav() {
  document.getElementById('nav').innerHTML = NAV.map(([label, items]) => String(html`
    <div class="nav-section"><div class="nav-label">${label}</div>
      ${items.map(([id, icon, text, badgeKey]) => html`
        <a class="nav-item" data-page="${id}" href="#/${id}"><span class="icon">${icon}</span>${text}
          ${badgeKey ? html`<span class="nav-badge" id="badge-${badgeKey}" hidden></span>` : ''}</a>`)}
    </div>`)).join('');
}

export async function refreshBadges() {
  try {
    const [newLeads, tasks, inv, notes] = await Promise.all([
      db.list('leads', { eq: { stage: 'NEW LEAD' }, is: ['archived_at'] }),
      db.list('tasks', { in: { status: ['Pending', 'In Progress'] }, is: ['archived_at'], lte: { due_at: new Date().toISOString() } }),
      db.list('v_invoices', { eq: { is_overdue: true } }),
      db.list('notifications', { is: ['read_at'], limit: 99 }),
    ]);
    const set = (id, n, red) => { const el = document.getElementById(id); if (!el) return; el.hidden = !n; el.textContent = n; el.classList.toggle('red', !!red); };
    set('badge-leads', newLeads.length);
    set('badge-tasks', tasks.length, true);
    set('badge-ar', inv.length, true);
    set('bell-count', notes.length);
  } catch { /* badges are best-effort */ }
}

// ── SEARCH ─────────────────────────────────────────────────────────
const ROUTE = { customer: 'customer', property: 'customer', lead: 'lead', estimate: 'estimate', proposal: 'proposal',
  project: 'project', invoice: 'invoices', payment: 'payments' };
let searchTimer;
const results = document.getElementById('search-results');
document.getElementById('search-input').addEventListener('input', (e) => {
  clearTimeout(searchTimer);
  const q = e.target.value.trim();
  if (q.length < 2) { results.hidden = true; return; }
  searchTimer = setTimeout(async () => {
    const hits = await db.rpc('global_search', { q });
    results.innerHTML = hits.length ? hits.map((h) => String(html`
      <div class="search-hit" data-act="openHit" data-kind="${h.kind}" data-id="${h.id}">
        <span class="kind">${h.kind}</span><div class="list-main"><div class="list-name">${h.label}</div><div class="list-sub">${h.sub}</div></div>
      </div>`)).join('') : '<div class="empty small">No matches</div>';
    results.hidden = false;
  }, 220);
});
register({
  openHit: async ({ kind, id }) => {
    hideFloating();
    document.getElementById('search-input').value = '';
    if (kind === 'property') { const p = await db.get('properties', id); return go('customer/' + p.customer_id); }
    if (kind === 'lead') return actions.openLead({ id });
    if (kind === 'invoice' || kind === 'payment') return go(ROUTE[kind]);
    go(ROUTE[kind] + '/' + id);
  },
  closeModal,
});

// ── NOTIFICATIONS ──────────────────────────────────────────────────
const panel = document.getElementById('notif-panel');
function hideFloating() { results.hidden = true; panel.hidden = true; }
document.addEventListener('mousedown', (e) => {
  if (!e.target.closest('#search')) results.hidden = true;
  if (!e.target.closest('#notif-panel, #bell')) panel.hidden = true;
});
document.getElementById('bell').onclick = async () => {
  if (!panel.hidden) { panel.hidden = true; return; }
  const items = await db.list('notifications', { order: 'created_at desc', limit: 40 });
  panel.innerHTML = String(html`
    <div class="card-title" style="padding:12px 14px 0">Notifications <button class="btn btn-link" data-act="readAll">Mark all read</button></div>
    ${items.length ? items.map((n) => html`<div class="notif ${n.read_at ? '' : 'unread'} ${n.entity_type === 'lead' ? 'click' : ''}" data-act="openNotif" data-id="${n.id}" data-entity="${n.entity_type || ''}" data-ref="${n.entity_id || ''}">
        <div>${n.title}</div>${n.body ? html`<div class="small muted">${n.body}</div>` : ''}<div class="when">${ago(n.created_at)}</div></div>`)
      : html`<div class="empty small">Nothing yet</div>`}`);
  panel.hidden = false;
};
register({
  openNotif: async ({ id, entity, ref }) => {
    await db.update('notifications', id, { read_at: new Date().toISOString() });
    panel.hidden = true; refreshBadges();
    if (entity === 'lead' && ref) actions.openLead({ id: ref });
    else if (entity === 'project' && ref) go('project/' + ref);
  },
  readAll: async () => { await db.updateWhere('notifications', { is: ['read_at'] }, { read_at: new Date().toISOString() }); panel.hidden = true; refreshBadges(); },
});

// ── SIDEBAR ────────────────────────────────────────────────────────
document.getElementById('menu-toggle').onclick = () => {
  document.getElementById('sidebar').classList.toggle('open');
  document.getElementById('sidebar-overlay').classList.toggle('open');
};
document.getElementById('sidebar-overlay').onclick = () => document.getElementById('menu-toggle').click();

// ── AUTH ───────────────────────────────────────────────────────────
async function start() {
  const session = await db.auth.session();
  if (!session) return showLogin();
  bootMsg('Loading your workspace…');
  state.me = await db.get('users', session.user.id);
  if (!state.me || state.me.status !== 'active') {
    document.getElementById('boot').hidden = false;
    bootMsg(`Your account (${session.user.email ?? ''}) is waiting for the owner to activate it.`);
    return;
  }
  await loadSettings();
  state.users = await db.list('users', { eq: { status: 'active' } });
  db.rpc('run_maintenance').catch(() => {});          // fire due automations now; cron also runs them
  drawNav();
  document.getElementById('sidebar-foot').innerHTML = String(html`
    <div>${state.me.first_name} ${state.me.last_name}</div><div class="small">${state.me.role} · ${DEMO ? 'demo mode' : 'Supabase'}</div>
    ${DEMO ? '' : html`<button class="btn btn-link" style="padding-left:0" data-act="signOut">Sign out</button>`}`);
  if (DEMO) {
    const b = document.getElementById('demo-banner');
    b.hidden = false;
    b.innerHTML = 'DEMO MODE — a real Postgres database running in this browser with your V1 sample data. Nothing is shared or backed up. Add your Supabase keys in <code>app/js/config.js</code> to go live.';
  }
  document.getElementById('boot').hidden = true;
  document.getElementById('login').hidden = true;
  document.getElementById('app').hidden = false;
  await Promise.all([
    import('./pages/dashboard.js'), import('./pages/sales.js'), import('./pages/estimates.js'),
    import('./pages/projects.js'), import('./pages/finance.js'), import('./pages/admin.js'),
  ]);
  render();
  setInterval(refreshBadges, 60_000);
}

function showLogin() {
  document.getElementById('boot').hidden = true;
  document.getElementById('login').hidden = false;
  const form = document.getElementById('login-form');
  const err = document.getElementById('login-err');
  form.onsubmit = async (e) => {
    e.preventDefault();
    err.textContent = '';
    try { await db.auth.signIn(form.email.value, form.password.value); location.reload(); }
    catch (ex) { err.textContent = ex.message; }
  };
  document.getElementById('forgot').onclick = async () => {
    if (!form.email.value) { err.textContent = 'Enter your email first.'; return; }
    try { await db.auth.resetPassword(form.email.value); err.textContent = 'Password reset email sent.'; }
    catch (ex) { err.textContent = ex.message; }
  };
}

register({
  signOut: async () => { await db.auth.signOut(); location.reload(); },
  quickAdd: () => modal('Quick add', html`<div class="grid-2" style="margin:0">
    ${[['newLead', '◎', 'New Lead'], ['newCustomer', '◉', 'New Customer'], ['newTask', '☑', 'New Task'],
       ['newExpense', '▥', 'Log Expense'], ['logTime', '◷', 'Log Hours'], ['newInvoice', '▤', 'New Invoice']]
      .map(([act, icon, label]) => html`<button class="btn btn-dark" style="padding:18px;flex-direction:column" data-act="${act}">
        <span style="font-size:22px">${icon}</span>${label}</button>`)}</div>`),
});

// Home-screen app support (offline shell + push notifications).
if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost')) {
  navigator.serviceWorker.register('sw.js').catch((e) => console.warn('service worker', e));
}

start().catch((e) => { console.error(e); bootMsg('Error: ' + e.message); document.getElementById('boot').hidden = false; });
export { esc };
