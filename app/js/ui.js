// Shared UI helpers. All dynamic values go through html`` which escapes them,
// so text typed into the website form can never inject markup.

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ESC[c]);

class Raw { constructor(s) { this.s = s; } toString() { return this.s; } }
export const raw = (s) => new Raw(s);
const part = (v) => v instanceof Raw ? v.s : Array.isArray(v) ? v.map(part).join('') : v === false || v == null ? '' : esc(v);
export const html = (strings, ...vals) => raw(strings.reduce((a, s, i) => a + s + (i < vals.length ? part(vals[i]) : ''), ''));

// ── FORMATTING ─────────────────────────────────────────────────────
export const money = (n, cents = false) => {
  const v = Number(n || 0);
  return (v < 0 ? '-$' : '$') + Math.abs(v).toLocaleString('en-US', { minimumFractionDigits: cents ? 2 : 0, maximumFractionDigits: cents ? 2 : 0 });
};
export const num = (n, d = 1) => Number(n || 0).toLocaleString('en-US', { maximumFractionDigits: d });
export const pct = (n) => n == null ? '—' : `${num(n, 1)}%`;
const asDate = (d) => typeof d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d) ? new Date(d + 'T12:00:00') : new Date(d);
export const fmtDate = (d) => d ? asDate(d).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) : '';
export const fmtDateLong = (d) => d ? asDate(d).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) : '';
export const fmtDateTime = (d) => d ? new Date(d).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
export const ago = (d) => {
  if (!d) return '';
  const s = (Date.now() - new Date(d)) / 1000;
  if (s < 0) { const f = -s; return f < 3600 ? `in ${Math.round(f / 60)}m` : f < 86400 ? `in ${Math.round(f / 3600)}h` : `in ${Math.round(f / 86400)}d`; }
  return s < 60 ? 'just now' : s < 3600 ? `${Math.round(s / 60)}m ago` : s < 86400 ? `${Math.round(s / 3600)}h ago` : `${Math.round(s / 86400)}d ago`;
};
export const today = () => { const d = new Date(); return new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 10); };
export const addDays = (iso, n) => { const d = asDate(iso); d.setDate(d.getDate() + n); return new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 10); };
// Date-only inputs mean "by end of that business day" for due dates.
export const dueFromDate = (d) => d ? new Date(d + 'T17:00:00').toISOString() : null;
export const dateInput = (ts) => ts ? (() => { const d = new Date(ts); return new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 10); })() : '';
export const dtInput = (ts) => ts ? (() => { const d = new Date(ts); return new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16); })() : '';

export function periodRange(p) {
  const t = today(); const d = asDate(t);
  const iso = (x) => new Date(x - x.getTimezoneOffset() * 6e4).toISOString().slice(0, 10);
  switch (p) {
    case 'today': return [t, t];
    case 'week': { const s = new Date(d); s.setDate(d.getDate() - ((d.getDay() + 6) % 7)); return [iso(s), t]; }
    case 'quarter': return [iso(new Date(d.getFullYear(), Math.floor(d.getMonth() / 3) * 3, 1)), t];
    case 'year': return [iso(new Date(d.getFullYear(), 0, 1)), t];
    default: return [iso(new Date(d.getFullYear(), d.getMonth(), 1)), t];
  }
}

// ── BADGES ─────────────────────────────────────────────────────────
const TONE = {
  'NEW LEAD': 'blue', CONTACTED: 'orange', QUALIFYING: 'orange', 'SITE VISIT': 'orange', ESTIMATE: 'blue',
  'PROPOSAL SENT': 'blue', 'FOLLOW-UP': 'orange', WON: 'green', LOST: 'red',
  Draft: 'muted', Sent: 'blue', Viewed: 'blue', 'Follow-Up': 'orange', Approved: 'green', Declined: 'red',
  Expired: 'muted', Cancelled: 'muted', Converted: 'gold', 'Partially Paid': 'orange', Paid: 'green', Void: 'muted',
  'Pending Deposit': 'orange', 'Ready to Schedule': 'gold', Scheduled: 'blue', 'Pre-Construction': 'blue',
  'In Progress': 'green', 'On Hold': 'red', 'Punch List': 'orange', QC: 'orange', Completed: 'green', Closed: 'muted',
  Pending: 'orange', Urgent: 'red', High: 'red', Medium: 'orange', Low: 'muted',
  Needed: 'muted', Ordered: 'blue', Received: 'green', Installed: 'green',
  Lead: 'blue', Active: 'green', 'Past Customer': 'muted', VIP: 'gold', Inactive: 'muted', 'Do Not Contact': 'red',
  A: 'green', B: 'gold', C: 'orange', D: 'red', Overdue: 'red',
};
export const badge = (s, tone) => s ? html`<span class="badge badge-${tone || TONE[s] || 'muted'}">${s}</span>` : '';
export const scoreBadge = (s) => s ? html`<span class="score score-${s}" title="Lead score">${s}</span>` : '';

let thresholds = { red: 25, warning: 35, healthy: 45 };
export const setThresholds = (t) => { if (t) thresholds = t; };
export const marginTone = (m) => m == null ? 'muted' : m < thresholds.red ? 'red' : m < thresholds.warning ? 'orange' : m < thresholds.healthy ? 'green' : 'gold';
export const marginLabel = (m) => m == null ? '' : m < thresholds.red ? 'LOW' : m < thresholds.warning ? 'WARNING' : m < thresholds.healthy ? 'HEALTHY' : 'STRONG';
export const marginBadge = (m) => m == null ? html`<span class="badge badge-muted">—</span>` : html`<span class="badge badge-${marginTone(m)}">${pct(m)}</span>`;

// ── MODAL / TOAST ──────────────────────────────────────────────────
export function modal(title, body, buttons = [], size = '') {
  document.getElementById('modal-title').textContent = title;
  document.getElementById('modal-body').innerHTML = String(body);
  document.getElementById('modal-inner').className = 'modal ' + size;
  document.getElementById('modal-footer').innerHTML = buttons.map((b) =>
    `<button class="btn ${b.cls || 'btn-ghost'}" data-modal-btn="${esc(b.label)}">${esc(b.label)}</button>`).join('');
  document.getElementById('modal-footer').querySelectorAll('[data-modal-btn]').forEach((el, i) => {
    el.onclick = async () => {
      const b = buttons[i];
      if (!b.onClick) return closeModal();
      el.disabled = true;
      try { await b.onClick(document.getElementById('modal-body')); }
      catch (e) { toast(e.message, 'error'); }
      finally { el.disabled = false; }
    };
  });
  document.getElementById('modal').hidden = false;
  document.querySelector('#modal-body input:not([type=hidden]), #modal-body select, #modal-body textarea')?.focus();
}
export const closeModal = () => { document.getElementById('modal').hidden = true; };

export function confirmDialog(title, message, label = 'Confirm', cls = 'btn-gold') {
  return new Promise((resolve) => modal(title, html`<p>${message}</p>`, [
    { label: 'Cancel', onClick: () => { closeModal(); resolve(false); } },
    { label, cls, onClick: () => { closeModal(); resolve(true); } },
  ]));
}

export function toast(msg, kind = 'ok') {
  const el = document.createElement('div');
  el.className = 'toast toast-' + kind;
  el.textContent = msg;
  document.getElementById('toasts').appendChild(el);
  setTimeout(() => el.remove(), kind === 'error' ? 7000 : 3500);
}

// ── FORMS ──────────────────────────────────────────────────────────
// Reads every [name] field inside root. data-type="number" → number|null,
// checkboxes → boolean, empty strings → null.
export function readForm(root) {
  const out = {};
  root.querySelectorAll('[name]').forEach((el) => {
    let v = el.type === 'checkbox' ? el.checked : el.value.trim();
    if (el.type !== 'checkbox') {
      if (v === '') v = null;
      else if (el.dataset.type === 'number' || el.type === 'number') v = Number(v);
    }
    out[el.name] = v;
  });
  return out;
}
export function need(obj, fields) {
  for (const [k, label] of Object.entries(fields)) if (obj[k] == null || obj[k] === '') throw new Error(`${label} is required.`);
}

export const field = (label, input, cls = '') => html`<div class="form-group ${cls}"><label class="form-label">${label}</label>${input}</div>`;
export const input = (name, value = '', attrs = '') => html`<input name="${name}" value="${value ?? ''}" ${raw(attrs)}>`;
export const textarea = (name, value = '', attrs = '') => html`<textarea name="${name}" ${raw(attrs)}>${value ?? ''}</textarea>`;
export const select = (name, options, value, attrs = '') => html`<select name="${name}" ${raw(attrs)}>${options.map((o) => {
  const [v, l] = Array.isArray(o) ? o : [o, o];
  return html`<option value="${v ?? ''}" ${String(v ?? '') === String(value ?? '') ? raw('selected') : ''}>${l}</option>`;
})}</select>`;

export const empty = (icon, text) => html`<div class="empty"><div class="empty-icon">${icon}</div><div>${text}</div></div>`;
export const kpi = (label, value, tone = '', sub = '') => html`<div class="kpi"><div class="kpi-val ${tone}">${value}</div><div class="kpi-label">${label}</div>${sub ? html`<div class="kpi-sub">${sub}</div>` : ''}</div>`;

export function downloadFile(name, content, type = 'application/json') {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([content], { type }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
export function toCSV(rows) {
  if (!rows.length) return '';
  const cols = Object.keys(rows[0]);
  const cell = (v) => { const s = v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  return [cols.join(','), ...rows.map((r) => cols.map((c) => cell(r[c])).join(','))].join('\n');
}
