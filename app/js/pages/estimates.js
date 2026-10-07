// Estimates (profit-controlled estimating) and proposals (full lifecycle).
import { db, page, register, refresh, go, state, setting } from '../app.js';
import { html, raw, money, pct, num, fmtDate, fmtDateLong, badge, modal, closeModal, toast, readForm, need, field, input,
         textarea, select, empty, marginBadge, marginTone, marginLabel, confirmDialog, today, addDays } from '../ui.js';
import { custName, customersById, setReopen } from './common.js';

// ── ESTIMATES LIST ─────────────────────────────────────────────────
page('estimates', {
  title: 'Estimates',
  async render() {
    const [rows, { by }] = await Promise.all([db.list('estimates', { is: ['archived_at'], order: 'created_at desc' }), customersById()]);
    return html`<div class="toolbar"><span class="grow muted small">Every estimate shows its cost and margin before it goes out.</span>
      <button class="btn btn-gold" data-act="newEstimate">+ New estimate</button></div>
    <div class="card" style="padding:0"><div class="table-wrap"><table>
      <thead><tr><th>#</th><th>Customer</th><th>Title</th><th class="num">Total</th><th class="num">Direct cost</th><th class="num">Gross profit</th><th>Margin</th><th>Status</th><th>Expires</th></tr></thead>
      <tbody>${rows.map((e) => html`<tr class="click" data-act="go" data-to="estimate/${e.id}">
        <td class="muted small nowrap">${e.estimate_number}</td><td>${custName(by[e.customer_id])}</td><td>${e.title}</td>
        <td class="num gold">${money(e.total)}</td><td class="num muted">${money(e.estimated_direct_cost)}</td>
        <td class="num">${money(e.estimated_gross_profit)}</td><td>${marginBadge(e.estimated_margin)}</td><td>${badge(e.status)}</td>
        <td class="muted small">${fmtDate(e.expiration_date)}</td></tr>`)}</tbody></table></div>
      ${rows.length ? '' : empty('◇', 'No estimates yet. Open a lead and click "Create estimate".')}</div>`;
  },
});

async function openNewEstimate(vals = {}) {
  const { list } = await customersById();
  setReopen(openNewEstimate);
  modal('New estimate', html`
    ${field('Customer', select('customer_id', [['', 'Select customer…'], ...list.map((c) => [c.id, custName(c)]), ['__new', '+ New customer…']], vals.customer_id, 'data-change="customerPicked"'))}
    ${field('Title', input('title', vals.title, 'placeholder="Kitchen cabinet install"'))}
    <div class="hint">Tip: starting from a lead (Pipeline → lead → Create estimate) links the estimate to the lead and moves it through the pipeline automatically.</div>`,
  [{ label: 'Cancel' }, { label: 'Create', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body);
    need(f, { customer_id: 'Customer' });
    const props = await db.list('properties', { eq: { customer_id: f.customer_id, is_default: true } });
    const e = await db.insert('estimates', { customer_id: f.customer_id, property_id: props[0]?.id ?? null, title: f.title || 'Estimate' });
    closeModal(); go('estimate/' + e.id);
  } }]);
}
register({ newEstimate: () => openNewEstimate() });

// ── ESTIMATE BUILDER ───────────────────────────────────────────────
let pricebook = [];
const COLS = [['unit_price', 'Price/unit'], ['unit_labor_hours', 'Labor h/unit'], ['unit_labor_cost', 'Labor $/unit'],
  ['unit_material_cost', 'Material $/unit'], ['unit_subcontractor_cost', 'Sub $/unit'], ['unit_other_cost', 'Other $/unit']];

const lineRow = (it = {}) => html`<tr class="line" data-pb="${it.pricebook_item_id || ''}">
  <td><input data-k="description" value="${it.description || ''}" placeholder="Description"><div class="hint">${it.category || ''}</div></td>
  <td class="w-qty"><input data-k="quantity" type="number" step="any" value="${it.quantity ?? 1}"></td>
  <td style="width:90px"><input data-k="unit" value="${it.unit || ''}" placeholder="unit"></td>
  ${COLS.map(([k]) => html`<td class="w-money"><input data-k="${k}" type="number" step="any" value="${it[k] ?? 0}"></td>`)}
  <td class="num" data-out="total"></td><td data-out="margin"></td>
  <td><button class="btn btn-link red" data-act="removeLine" title="Remove line">✕</button></td></tr>`;

function readLines(root) {
  return [...root.querySelectorAll('tr.line')].map((tr, i) => {
    const o = { sort_order: i, pricebook_item_id: tr.dataset.pb || null };
    tr.querySelectorAll('[data-k]').forEach((el) => { o[el.dataset.k] = el.type === 'number' ? Number(el.value || 0) : el.value.trim(); });
    return o;
  }).filter((l) => l.description);
}

function recalc(root) {
  const lines = readLines(root);
  const t = { sell: 0, hours: 0, labor: 0, material: 0, sub: 0, other: 0 };
  root.querySelectorAll('tr.line').forEach((tr) => {
    const g = (k) => Number(tr.querySelector(`[data-k="${k}"]`).value || 0);
    const q = g('quantity'); const price = g('unit_price');
    const cost = g('unit_labor_cost') + g('unit_material_cost') + g('unit_subcontractor_cost') + g('unit_other_cost');
    tr.querySelector('[data-out="total"]').textContent = money(q * price);
    const m = price > 0 ? ((price - cost) / price) * 100 : null;
    tr.querySelector('[data-out="margin"]').innerHTML = String(marginBadge(m == null ? null : Math.round(m * 10) / 10));
  });
  for (const l of lines) {
    t.sell += l.quantity * l.unit_price; t.hours += l.quantity * l.unit_labor_hours; t.labor += l.quantity * l.unit_labor_cost;
    t.material += l.quantity * l.unit_material_cost; t.sub += l.quantity * l.unit_subcontractor_cost; t.other += l.quantity * l.unit_other_cost;
  }
  const discount = Number(root.querySelector('[name=discount]').value || 0);
  const tax = Number(root.querySelector('[name=tax]').value || 0);
  const revenue = t.sell - discount; const cost = t.labor + t.material + t.sub + t.other; const gp = revenue - cost;
  const margin = revenue > 0 ? Math.round((gp / revenue) * 1000) / 10 : null;
  const target = Number(setting('pricing', {}).target_margin ?? 40);
  const needed = cost > 0 ? cost / (1 - target / 100) : 0;
  const tone = marginTone(margin);
  root.querySelector('#est-summary').innerHTML = String(html`
    <div class="margin-meter" style="border-color:var(--${tone === 'muted' ? 'line' : tone})">
      <div><div class="big ${tone}">${pct(margin)}</div><div class="small muted">gross margin · ${marginLabel(margin)}</div></div>
      <div class="small muted" style="margin-left:auto;text-align:right">Target ${target}%<br>${needed && revenue < needed ? html`<span class="orange">Price ≥ ${money(needed)} to hit target</span>` : html`<span class="green">On target</span>`}</div>
    </div>
    <div style="margin-top:10px">
      <div class="profit-row"><span class="lbl">Subtotal</span><span>${money(t.sell, true)}</span></div>
      ${discount ? html`<div class="profit-row"><span class="lbl">Discount</span><span class="red">−${money(discount, true)}</span></div>` : ''}
      ${tax ? html`<div class="profit-row"><span class="lbl">Tax (pass-through)</span><span>${money(tax, true)}</span></div>` : ''}
      <div class="profit-row total"><span>Customer total</span><span class="gold">${money(revenue + tax, true)}</span></div>
      <div class="profit-row"><span class="lbl">Labor (${num(t.hours)} h)</span><span class="red">−${money(t.labor, true)}</span></div>
      <div class="profit-row"><span class="lbl">Materials</span><span class="red">−${money(t.material, true)}</span></div>
      <div class="profit-row"><span class="lbl">Subcontractors</span><span class="red">−${money(t.sub, true)}</span></div>
      <div class="profit-row"><span class="lbl">Other direct</span><span class="red">−${money(t.other, true)}</span></div>
      <div class="profit-row total"><span>Gross profit</span><span class="${gp >= 0 ? 'green' : 'red'}">${money(gp, true)}</span></div>
    </div>`);
}

async function saveEstimate(root, id) {
  const f = readForm(root.querySelector('#est-head'));
  const lines = readLines(root);
  await db.update('estimates', id, { title: f.title || '', customer_id: f.customer_id, expiration_date: f.expiration_date,
    discount: f.discount || 0, tax: f.tax || 0, notes: f.notes, exclusions: f.exclusions, assumptions: f.assumptions });
  await db.removeWhere('estimate_items', { eq: { estimate_id: id } });
  await db.insertMany('estimate_items', lines.map((l) => ({ ...l, estimate_id: id })));
  return db.get('estimates', id);
}

page('estimate', {
  title: 'Estimate', nav: 'estimates',
  async render(id) {
    const [e, items, pb, { list }] = await Promise.all([db.get('estimates', id),
      db.list('estimate_items', { eq: { estimate_id: id }, order: 'sort_order' }),
      db.list('pricebook_items', { eq: { active: true }, is: ['archived_at'], order: ['service', 'item'] }), customersById()]);
    if (!e) return empty('◇', 'Estimate not found');
    pricebook = pb;
    const services = [...new Set(pb.map((p) => p.service))];
    const proposals = await db.list('proposals', { eq: { estimate_id: id } });
    return html`
    <div class="hero"><div><h1>${e.estimate_number} ${badge(e.status)}</h1>
      <div class="muted small">${e.lead_id ? html`<a href="#" data-act="openLead" data-id="${e.lead_id}">View lead</a> · ` : ''}created ${fmtDate(e.created_date)}
      ${proposals.length ? html` · proposal <a href="#/proposal/${proposals[0].id}">${proposals[0].proposal_number}</a>` : ''}</div></div>
      <div class="pill-row">
        <button class="btn btn-dark" data-act="saveEstimate" data-id="${id}">Save</button>
        ${e.status === 'Draft' ? html`<button class="btn btn-dark" data-act="estimateSent" data-id="${id}">Mark sent</button>` : ''}
        <button class="btn btn-gold" data-act="toProposal" data-id="${id}">Create proposal →</button></div></div>
    ${proposals.length ? html`<div class="demo-banner" style="margin:-6px 0 14px;border-radius:6px">A proposal already exists. Edits here do not change it — the proposal is a snapshot the customer may already have.</div>` : ''}
    <div class="grid-2" style="grid-template-columns:2fr 1fr">
      <div class="card" id="est-head">
        <div class="form-row">${field('Title', input('title', e.title))}
          ${field('Customer', select('customer_id', list.map((c) => [c.id, custName(c)]), e.customer_id))}</div>
        <div class="form-row-3">${field('Expires', input('expiration_date', e.expiration_date, 'type="date"'))}
          ${field('Discount ($)', input('discount', e.discount, 'type="number" step="any" data-recalc'))}
          ${field('Tax ($)', input('tax', e.tax, 'type="number" step="any" data-recalc'))}</div>
        ${field('Scope summary (shown on proposal)', textarea('notes', e.notes))}
        <div class="form-row">${field('Exclusions', textarea('exclusions', e.exclusions, 'placeholder="Cabinet procurement, permits, electrical…"'))}
          ${field('Assumptions', textarea('assumptions', e.assumptions, 'placeholder="Walls are plumb, clear access…"'))}</div>
      </div>
      <div class="card"><div class="card-title">Profit check</div><div id="est-summary"></div></div>
    </div>
    <div class="card">
      <div class="card-title">Line items
        <span class="pill-row">${select('pb_pick', [['', '+ Add from price book…'], ...services.flatMap((s) => pb.filter((p) => p.service === s).map((p) => [p.id, `${s} — ${p.item} (${money(p.sell_price, true)}/${p.unit})`]))], '', 'data-change="addPbLine" style="max-width:340px"')}
        <button class="btn btn-dark btn-sm" data-act="addLine">+ Custom line</button></span></div>
      <div class="table-wrap"><table class="lines"><thead><tr><th>Description</th><th>Qty</th><th>Unit</th>${COLS.map(([, l]) => html`<th>${l}</th>`)}<th class="num">Total</th><th>Margin</th><th></th></tr></thead>
        <tbody id="est-lines">${items.map(lineRow)}</tbody></table></div>
      ${items.length ? '' : html`<div class="hint" id="est-empty">Add items from the price book — sell price and every unit cost are copied in so margin is known before you send.</div>`}
    </div>`;
  },
  after(root) {
    if (!root.querySelector('#est-lines')) return;
    root.addEventListener('input', (ev) => { if (ev.target.closest('tr.line') || ev.target.hasAttribute('data-recalc')) recalc(root); });
    recalc(root);
  },
});

register({
  addLine: () => { document.getElementById('est-lines').insertAdjacentHTML('beforeend', String(lineRow())); recalc(document.getElementById('content')); },
  addPbLine: (_d, el) => {
    const p = pricebook.find((x) => x.id === el.value);
    el.value = '';
    if (!p) return;
    document.getElementById('est-lines').insertAdjacentHTML('beforeend', String(lineRow({ pricebook_item_id: p.id, description: p.item,
      category: p.service, unit: p.unit, quantity: 1, unit_price: p.sell_price, unit_labor_hours: p.labor_hours, unit_labor_cost: p.labor_cost,
      unit_material_cost: p.material_cost, unit_subcontractor_cost: p.subcontractor_cost, unit_other_cost: Number(p.equipment_cost) + Number(p.other_cost) })));
    document.getElementById('est-empty')?.remove();
    const rows = document.querySelectorAll('#est-lines tr.line');
    rows[rows.length - 1].querySelector('[data-k="quantity"]').select();
    recalc(document.getElementById('content'));
  },
  removeLine: (_d, el) => { el.closest('tr').remove(); recalc(document.getElementById('content')); },
  saveEstimate: async ({ id }) => { await saveEstimate(document.getElementById('content'), id); toast('Estimate saved'); refresh(); },
  estimateSent: async ({ id }) => {
    await saveEstimate(document.getElementById('content'), id);
    await db.update('estimates', id, { status: 'Sent' });
    toast('Marked sent — follow-up task created'); refresh();
  },
  toProposal: async ({ id }) => {
    await saveEstimate(document.getElementById('content'), id);
    const existing = await db.list('proposals', { eq: { estimate_id: id }, neq: { status: 'Cancelled' } });
    if (existing.length && !(await confirmDialog('Another proposal?', `${existing[0].proposal_number} already exists for this estimate. Create a new one from the current numbers?`, 'Create new'))) return;
    const pid = await db.rpc('create_proposal_from_estimate', { p_estimate_id: id });
    toast('Proposal created'); go('proposal/' + pid);
  },
});

// ── PROPOSALS ──────────────────────────────────────────────────────
page('proposals', {
  title: 'Proposals',
  async render() {
    const [rows, { by }] = await Promise.all([db.list('proposals', { is: ['archived_at'], order: 'created_at desc' }), customersById()]);
    const open = rows.filter((p) => ['Sent', 'Viewed', 'Follow-Up'].includes(p.status));
    return html`<div class="kpi-grid">
      <div class="kpi"><div class="kpi-val gold">${money(open.reduce((a, p) => a + Number(p.total), 0))}</div><div class="kpi-label">Awaiting decision (${open.length})</div></div>
      <div class="kpi"><div class="kpi-val green">${rows.filter((p) => p.status === 'Approved').length}</div><div class="kpi-label">Approved</div></div>
      <div class="kpi"><div class="kpi-val">${rows.filter((p) => p.status === 'Draft').length}</div><div class="kpi-label">Drafts</div></div></div>
    <div class="card" style="padding:0"><div class="table-wrap"><table>
      <thead><tr><th>#</th><th>Customer</th><th>Title</th><th class="num">Total</th><th>Margin</th><th>Status</th><th>Sent</th><th>Valid until</th></tr></thead>
      <tbody>${rows.map((p) => html`<tr class="click" data-act="go" data-to="proposal/${p.id}">
        <td class="muted small nowrap">${p.proposal_number}</td><td>${custName(by[p.customer_id])}</td><td>${p.title}</td>
        <td class="num gold">${money(p.total)}</td><td>${marginBadge(p.estimated_margin)}</td><td>${badge(p.status)}</td>
        <td class="muted small">${fmtDate(p.sent_at) || '—'}</td><td class="muted small">${fmtDate(p.valid_until)}</td></tr>`)}</tbody></table></div>
      ${rows.length ? '' : empty('◻', 'No proposals yet — create one from an estimate.')}</div>`;
  },
});

function proposalDoc(p, items, c, prop) {
  const co = setting('company', {});
  return html`<div class="doc">
    <div style="display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap">
      <div><h2>✦ GOLDEX</h2><div style="font-size:11px;letter-spacing:.12em;color:#6E6E73">CONSTRUCTION LLC</div>
        <div style="font-size:12px;color:#6E6E73;margin-top:6px">${co.phone || ''} · ${co.email || ''}<br>${co.website || ''}${co.license ? ' · CSLB #' + co.license : ''}</div></div>
      <div style="text-align:right;font-size:12px;color:#6E6E73"><div style="font-size:16px;color:#1D1D1F;font-weight:600">PROPOSAL ${p.proposal_number}</div>
        Date ${fmtDateLong(p.sent_at || p.created_at)}<br>Valid until ${fmtDateLong(p.valid_until)}</div>
    </div>
    <div style="margin:22px 0 14px"><div style="font-size:11px;color:#6E6E73">PREPARED FOR</div>
      <div style="font-weight:600">${custName(c)}</div><div style="font-size:12px">${prop?.address || c?.billing_address || ''}</div></div>
    <div style="font-weight:600;font-size:15px;margin-bottom:6px">${p.title}</div>
    ${p.scope_of_work ? html`<div style="font-size:11px;color:#6E6E73;margin-top:10px">SCOPE OF WORK</div><pre>${p.scope_of_work}</pre>` : ''}
    <table style="margin:14px 0"><thead><tr><th>Description</th><th class="num">Qty</th><th class="num">Price</th><th class="num">Amount</th></tr></thead>
      <tbody>${items.map((it) => html`<tr><td>${it.description}</td><td class="num">${num(it.quantity, 3)} ${it.unit || ''}</td><td class="num">${money(it.unit_price, true)}</td><td class="num">${money(it.total, true)}</td></tr>`)}</tbody></table>
    ${Number(p.discount) ? html`<div style="display:flex;justify-content:space-between"><span>Discount</span><span>−${money(p.discount, true)}</span></div>` : ''}
    ${Number(p.tax) ? html`<div style="display:flex;justify-content:space-between"><span>Tax</span><span>${money(p.tax, true)}</span></div>` : ''}
    <div class="doc-total"><span>Total investment</span><span>${money(p.total, true)}</span></div>
    ${Number(p.deposit_amount) ? html`<div style="margin-top:8px;font-size:13px">Deposit due on signing: <b>${money(p.deposit_amount, true)}</b>. ${p.payment_terms || ''}</div>` : p.payment_terms ? html`<div style="margin-top:8px;font-size:13px">${p.payment_terms}</div>` : ''}
    ${p.exclusions ? html`<div style="font-size:11px;color:#6E6E73;margin-top:16px">EXCLUSIONS</div><pre style="font-size:12.5px">${p.exclusions}</pre>` : ''}
    ${p.assumptions ? html`<div style="font-size:11px;color:#6E6E73;margin-top:10px">ASSUMPTIONS</div><pre style="font-size:12.5px">${p.assumptions}</pre>` : ''}
    <div class="sig"><div>Customer signature${p.customer_signature ? html` — <b style="color:#1D1D1F">${p.customer_signature}</b> ${fmtDate(p.signed_at)}` : ''}</div><div>GOLDEX Construction LLC</div></div>
    <div style="margin-top:18px;font-size:11px;color:#6E6E73">${co.tagline || 'Gold Standard. Every Job.'}</div>
  </div>`;
}

page('proposal', {
  title: 'Proposal', nav: 'proposals',
  async render(id) {
    const p = await db.get('proposals', id);
    if (!p) return empty('◻', 'Proposal not found');
    const [items, c, prop] = await Promise.all([db.list('proposal_items', { eq: { proposal_id: id }, order: 'sort_order' }),
      db.get('customers', p.customer_id), p.property_id ? db.get('properties', p.property_id) : null]);
    const draft = p.status === 'Draft';
    const open = ['Sent', 'Viewed', 'Follow-Up'].includes(p.status);
    const dep = setting('deposit', {});
    return html`
    <div class="hero"><div><h1>${p.proposal_number} ${badge(p.status)}</h1><div class="muted small">${custName(c)} · ${money(p.total)}
      ${p.estimate_id ? html` · <a href="#/estimate/${p.estimate_id}">estimate</a>` : ''}${p.project_id ? html` · <a href="#/project/${p.project_id}">project →</a>` : ''}</div></div>
      <div class="pill-row">
        <button class="btn btn-dark" data-act="printProposal" data-id="${id}">Print / PDF</button>
        ${draft ? html`<button class="btn btn-dark" data-act="saveProposal" data-id="${id}">Save</button><button class="btn btn-gold" data-act="sendProposal" data-id="${id}">Mark sent</button>` : ''}
        ${p.status === 'Expired' ? html`<button class="btn btn-gold" data-act="sendProposal" data-id="${id}">Re-send</button>` : ''}
        ${open ? html`${p.status !== 'Viewed' ? html`<button class="btn btn-dark" data-act="viewedProposal" data-id="${id}">Customer viewed</button>` : ''}
          <button class="btn btn-red" data-act="declineProposal" data-id="${id}">Declined</button>
          <button class="btn btn-green" data-act="approveProposal" data-id="${id}">✓ Approved</button>` : ''}
        ${p.project_id ? html`<button class="btn btn-gold" data-act="go" data-to="project/${p.project_id}">Open project →</button>` : ''}
      </div></div>
    <div class="grid-2" style="grid-template-columns:1.6fr 1fr;align-items:start">
      <div>${proposalDoc(p, items, c, prop)}</div>
      <div>
        <div class="card" style="margin-bottom:14px"><div class="card-title">Internal — not shown to customer</div>
          <div class="profit-row"><span class="lbl">Revenue</span><span>${money(Number(p.subtotal) - Number(p.discount))}</span></div>
          <div class="profit-row"><span class="lbl">Estimated direct cost</span><span class="red">−${money(p.estimated_direct_cost)}</span></div>
          <div class="profit-row total"><span>Estimated gross profit</span><span class="green">${money(p.estimated_gross_profit)}</span></div>
          <div class="profit-row"><span class="lbl">Margin</span>${marginBadge(p.estimated_margin)}</div>
          <div class="profit-row"><span class="lbl">Budgeted labor</span><span>${num(p.estimated_labor_hours)} h</span></div>
          ${p.decline_reason ? html`<div class="profit-row"><span class="lbl">Decline reason</span><span class="red">${p.decline_reason}</span></div>` : ''}
          <div class="profit-row"><span class="lbl">Timeline</span><span class="small right">${[['Sent', p.sent_at], ['Viewed', p.viewed_at], ['Approved', p.approved_at], ['Declined', p.declined_at]].filter((x) => x[1]).map((x) => `${x[0]} ${fmtDate(x[1])}`).join(' · ') || 'Draft'}</span></div>
        </div>
        ${draft ? html`<div class="card" id="prop-form"><div class="card-title">Edit before sending</div>
          ${field('Title', input('title', p.title))}
          ${field('Scope of work', textarea('scope_of_work', p.scope_of_work, 'style="min-height:140px"'))}
          ${field('Exclusions', textarea('exclusions', p.exclusions))}
          <div class="form-row">${field('Deposit', select('deposit_type', [['Percent', '% of total'], ['Fixed', 'Fixed $'], ['None', 'No deposit']], p.deposit_type))}
            ${field(p.deposit_type === 'Fixed' ? 'Deposit $' : 'Deposit %', input(p.deposit_type === 'Fixed' ? 'deposit_amount' : 'deposit_percent', p.deposit_type === 'Fixed' ? p.deposit_amount : p.deposit_percent, 'type="number" step="any"'))}</div>
          <div class="hint" style="margin:-6px 0 12px">Capped at ${money(dep.max_amount ?? 1000)} (Settings → Deposit). California B&P §7159 limits home-improvement down payments to the lesser of $1,000 or 10%.</div>
          <div class="form-row">${field('Valid until', input('valid_until', p.valid_until, 'type="date"'))}${field('Payment terms', input('payment_terms', p.payment_terms))}</div>
        </div>` : ''}
      </div>
    </div>`;
  },
});

register({
  printProposal: async ({ id }) => {
    const p = await db.get('proposals', id);
    const [items, c] = await Promise.all([db.list('proposal_items', { eq: { proposal_id: id }, order: 'sort_order' }), db.get('customers', p.customer_id)]);
    const prop = p.property_id ? await db.get('properties', p.property_id) : null;
    modal(p.proposal_number, proposalDoc(p, items, c, prop), [{ label: 'Close' }, { label: 'Print', cls: 'btn-gold', onClick: () => window.print() }], 'lg');
  },
  saveProposal: async ({ id }) => {
    const f = readForm(document.getElementById('prop-form'));
    await db.update('proposals', id, f);
    toast('Proposal saved'); refresh();
  },
  sendProposal: async ({ id }) => {
    const form = document.getElementById('prop-form');
    if (form) await db.update('proposals', id, readForm(form));
    await db.rpc('send_proposal', { p_proposal_id: id });
    toast('Marked sent — follow-ups scheduled for +2, +5 and +10 days'); refresh();
  },
  viewedProposal: async ({ id }) => { await db.rpc('mark_proposal_viewed', { p_proposal_id: id }); toast('Marked viewed'); refresh(); },
  approveProposal: async ({ id }) => {
    const p = await db.get('proposals', id);
    const c = await db.get('customers', p.customer_id);
    modal('Customer approved', html`
      <p style="margin-bottom:12px">Approving <b>${p.proposal_number}</b> for <b>${money(p.total)}</b> will automatically:</p>
      <ul class="small muted" style="margin:0 0 14px 18px;line-height:1.8">
        <li>mark the lead WON and the customer Active</li><li>create the project with the contract value locked</li>
        ${Number(p.deposit_amount) ? html`<li>create a ${money(p.deposit_amount)} deposit invoice</li>` : html`<li>set the project Ready to Schedule (no deposit)</li>`}
        <li>add the pre-construction checklist, first tasks and a schedule placeholder</li></ul>
      ${field('Customer signature (typed name)', input('signature', custName(c)))}`,
    [{ label: 'Cancel' }, { label: 'Approve & create project', cls: 'btn-green', onClick: async (body) => {
      const r = await db.rpc('approve_proposal', { p_proposal_id: id, p_signature: readForm(body).signature });
      closeModal(); toast('🏆 Won! Project created.'); go('project/' + r.project_id);
    } }]);
  },
  declineProposal: ({ id }) => modal('Proposal declined', html`
      ${field('Reason (required — the lead is marked LOST)', select('reason', ['', ...setting('loss_reasons', [])], ''))}`,
    [{ label: 'Cancel' }, { label: 'Mark declined', cls: 'btn-red', onClick: async (body) => {
      const f = readForm(body); need(f, { reason: 'Reason' });
      await db.rpc('decline_proposal', { p_proposal_id: id, p_reason: f.reason });
      closeModal(); toast('Proposal declined; lead marked lost'); refresh();
    } }]),
});
