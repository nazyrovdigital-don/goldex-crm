// Setup: price book and settings (company, pricing, sales lists, automations,
// users, data import/export, audit log).
import { db, page, register, refresh, state, setting, loadSettings } from '../app.js';
import { DEMO } from '../db.js';
import { integrationsTab } from './thumbtack.js';
import { html, raw, money, pct, num, fmtDateTime, ago, badge, modal, closeModal, toast, readForm, need, field, input, textarea,
         select, empty, marginBadge, confirmDialog, toCSV, downloadFile, today } from '../ui.js';

// ── PRICE BOOK ─────────────────────────────────────────────────────
page('pricebook', {
  title: 'Price Book',
  async render() {
    const rows = await db.list('pricebook_items', { is: ['archived_at'], order: ['service', 'item'] });
    const target = Number(setting('pricing', {}).target_margin ?? 40);
    const services = [...new Set(rows.map((r) => r.service))];
    const rec = (p) => Number(p.unit_cost) > 0 ? Number(p.unit_cost) / (1 - (Number(p.target_margin ?? target)) / 100) : null;
    return html`<div class="toolbar"><span class="grow muted small">Sell price and full unit cost for every item. Estimates copy these in, so margin is known before a proposal goes out. Target margin ${target}%.</span>
      <button class="btn btn-gold" data-act="editPb">+ Add item</button></div>
    ${services.map((s) => html`<div class="card" style="margin-bottom:14px;padding:0"><div class="card-title" style="padding:14px 14px 0">${s}</div>
      <div class="table-wrap"><table><thead><tr><th>Item</th><th>Unit</th><th class="num">Sell</th><th class="num">Labor</th><th class="num">Material</th><th class="num">Sub</th><th class="num">Other</th><th class="num">Unit cost</th><th>Margin</th><th class="num">Price @ target</th></tr></thead>
      <tbody>${rows.filter((r) => r.service === s).map((p) => { const r = rec(p); return html`<tr class="click" data-act="editPb" data-id="${p.id}" style="${p.active ? '' : 'opacity:.5'}">
        <td>${p.item}${p.notes ? html`<div class="list-sub">${p.notes}</div>` : ''}</td><td class="small muted">${p.unit}</td>
        <td class="num gold">${money(p.sell_price, true)}</td>
        <td class="num">${money(p.labor_cost, true)}${Number(p.labor_hours) ? html`<div class="list-sub">${num(p.labor_hours, 2)} h × ${money(p.labor_rate)}</div>` : ''}</td>
        <td class="num">${money(p.material_cost, true)}</td><td class="num">${money(p.subcontractor_cost, true)}</td>
        <td class="num">${money(Number(p.equipment_cost) + Number(p.other_cost), true)}</td><td class="num">${money(p.unit_cost, true)}</td>
        <td>${marginBadge(p.margin)}</td><td class="num ${r && r > Number(p.sell_price) ? 'orange' : 'muted'}">${r ? money(r, true) : '—'}</td></tr>`; })}</tbody></table></div></div>`)}
    ${rows.length ? '' : empty('▦', 'Price book is empty')}`;
  },
});

register({
  editPb: async ({ id }) => {
    const p = id ? await db.get('pricebook_items', id) : { active: true, labor_rate: setting('labor', {}).owner_loaded_rate ?? 40 };
    modal(id ? 'Edit price book item' : 'New price book item', html`
      <div class="form-row">${field('Service', select('service', setting('service_types', []), p.service))}${field('Item', input('item', p.item))}</div>
      <div class="form-row">${field('Unit', input('unit', p.unit || 'each', 'placeholder="per cabinet, sq ft, linear ft…"'))}${field('Sell price / unit', input('sell_price', p.sell_price, 'type="number" step="0.01"'))}</div>
      <div class="fieldset"><div class="fieldset-title">Unit cost</div>
        <div class="form-row-3">${field('Labor hours / unit', input('labor_hours', p.labor_hours, 'type="number" step="0.01"'))}
          ${field('Loaded labor $/hr', input('labor_rate', p.labor_rate, 'type="number" step="0.01"'))}
          ${field('…or labor $ / unit', input('labor_cost', p.labor_cost, 'type="number" step="0.01"'))}</div>
        <div class="hint" style="margin:-6px 0 10px">If hours and rate are both set, labor $ = hours × rate.</div>
        <div class="form-row-4">${field('Material', input('material_cost', p.material_cost, 'type="number" step="0.01"'))}${field('Subcontractor', input('subcontractor_cost', p.subcontractor_cost, 'type="number" step="0.01"'))}
          ${field('Equipment', input('equipment_cost', p.equipment_cost, 'type="number" step="0.01"'))}${field('Other', input('other_cost', p.other_cost, 'type="number" step="0.01"'))}</div></div>
      <div class="form-row">${field('Target margin % (blank = company default)', input('target_margin', p.target_margin, 'type="number" step="1"'))}${field('Minimum charge', input('minimum_charge', p.minimum_charge, 'type="number" step="1"'))}</div>
      ${field('Notes', input('notes', p.notes))}
      <label class="check"><input type="checkbox" name="active" ${p.active ? raw('checked') : ''}> Active (available in estimates)</label>`,
    [...(id ? [{ label: 'Archive', cls: 'btn-red', onClick: async () => { await db.update('pricebook_items', id, { archived_at: new Date().toISOString(), active: false }); closeModal(); refresh(); } }] : []),
     { label: 'Cancel' }, { label: 'Save', cls: 'btn-gold', onClick: async (body) => {
       const f = readForm(body); need(f, { service: 'Service', item: 'Item' });
       for (const k of ['sell_price', 'labor_hours', 'labor_rate', 'labor_cost', 'material_cost', 'subcontractor_cost', 'equipment_cost', 'other_cost']) f[k] = f[k] ?? 0;
       id ? await db.update('pricebook_items', id, f) : await db.insert('pricebook_items', f);
       toast('Saved'); closeModal(); refresh();
     } }], 'lg');
  },
});

// ── SETTINGS ───────────────────────────────────────────────────────
let tab = 'company';
const TABS = [['company', 'Company'], ['pricing', 'Pricing & labor'], ['sales', 'Sales & lists'], ['integrations', 'Integrations'], ['automations', 'Automations'],
  ['users', 'Users'], ['data', 'Import / export'], ['audit', 'Audit log']];
const listText = (k) => (setting(k, []) || []).join('\n');

page('settings', {
  title: 'Settings',
  async render() {
    let body = '';
    const co = setting('company', {}); const pr = setting('pricing', {}); const mt = setting('margin_thresholds', {});
    const dep = setting('deposit', {}); const lab = setting('labor', {});
    if (tab === 'company') body = html`<div class="card" id="set-form" style="max-width:720px">
      <div class="form-row">${field('Company name', input('company.name', co.name))}${field('Phone', input('company.phone', co.phone))}</div>
      <div class="form-row">${field('Email', input('company.email', co.email))}${field('Website', input('company.website', co.website))}</div>
      <div class="form-row">${field('Address', input('company.address', co.address))}${field('CSLB license #', input('company.license', co.license))}</div>
      ${field('Tagline (on proposals)', input('company.tagline', co.tagline))}
      <button class="btn btn-gold" data-act="saveSettings">Save</button></div>`;
    if (tab === 'pricing') body = html`<div class="card" id="set-form" style="max-width:720px">
      <div class="fieldset"><div class="fieldset-title">Margins</div>
        <div class="form-row">${field('Target gross margin %', input('pricing.target_margin', pr.target_margin, 'type="number"'))}${field('Minimum margin %', input('pricing.minimum_margin', pr.minimum_margin, 'type="number"'))}</div>
        <div class="form-row-3">${field('RED below %', input('margin_thresholds.red', mt.red, 'type="number"'))}${field('WARNING below %', input('margin_thresholds.warning', mt.warning, 'type="number"'))}${field('HEALTHY below % (above = STRONG)', input('margin_thresholds.healthy', mt.healthy, 'type="number"'))}</div></div>
      <div class="fieldset"><div class="fieldset-title">Deposit</div>
        <div class="form-row">${field('Default deposit %', input('deposit.percent', dep.percent, 'type="number"'))}${field('Maximum deposit $', input('deposit.max_amount', dep.max_amount, 'type="number"'))}</div>
        <div class="hint" style="margin:-6px 0 12px">California B&P Code §7159: a home-improvement down payment may not exceed $1,000 or 10% of the contract, whichever is less. Confirm with CSLB / your attorney before raising these.</div></div>
      <div class="fieldset"><div class="fieldset-title">Labor cost</div>
        <div class="form-row-3">${field('Owner loaded $/hr', input('labor.owner_loaded_rate', lab.owner_loaded_rate, 'type="number"'))}${field('Default employee wage $/hr', input('labor.default_labor_rate', lab.default_labor_rate, 'type="number"'))}${field('Default burden $/hr', input('labor.default_burden_rate', lab.default_burden_rate, 'type="number"'))}</div>
        <div class="hint" style="margin:-6px 0 12px">Owner rate = what you'd pay someone to replace you in the field. Burden = payroll tax, workers' comp, insurance per hour.</div></div>
      <div class="form-row">${field('Default payment terms (days)', input('payment_terms.default_days', setting('payment_terms', {}).default_days, 'type="number"'))}
        ${field('New-lead response SLA (minutes)', input('lead_sla_minutes', setting('lead_sla_minutes', 15), 'type="number"'))}</div>
      <button class="btn btn-gold" data-act="saveSettings">Save</button></div>`;
    if (tab === 'sales') body = html`<div class="card" id="set-form"><div class="grid-3" style="margin:0">
      ${field('Lead sources (one per line)', textarea('lead_sources', listText('lead_sources'), 'style="min-height:180px"'))}
      ${field('Service types', textarea('service_types', listText('service_types'), 'style="min-height:180px"'))}
      ${field('Core services (scored higher)', textarea('core_services', listText('core_services'), 'style="min-height:180px"'))}
      ${field('Loss reasons', textarea('loss_reasons', listText('loss_reasons'), 'style="min-height:180px"'))}
      ${field('Payment methods', textarea('payment_methods', listText('payment_methods'), 'style="min-height:180px"'))}
      ${field('Pre-construction checklist', textarea('default_project_checklist', listText('default_project_checklist'), 'style="min-height:180px"'))}
      ${field('Closeout checklist', textarea('closeout_checklist', listText('closeout_checklist'), 'style="min-height:180px"'))}</div>
      <button class="btn btn-gold" data-act="saveSettings">Save</button></div>`;
    if (tab === 'integrations') body = await integrationsTab();
    if (tab === 'automations') {
      const [rules, log, pending] = await Promise.all([db.list('automation_rules', { order: ['sort_order', 'name'] }),
        db.list('automation_log', { order: 'created_at desc', limit: 25 }), db.list('scheduled_actions', { eq: { status: 'pending' } })]);
      body = html`<div class="muted small" style="margin-bottom:12px">TRIGGER + CONDITIONS → ACTIONS. Rules run inside the same database transaction as the event, so nothing is half-done. ${pending.length} delayed action(s) waiting.</div>
      <div class="card" style="padding:0;margin-bottom:14px"><div class="table-wrap"><table><thead><tr><th>On</th><th>Rule</th><th>When</th><th>Does</th><th>Active</th></tr></thead>
      <tbody>${rules.map((r) => html`<tr><td class="small nowrap"><code>${r.trigger_event}</code></td>
        <td><div class="list-name">${r.name}${r.is_system ? html` <span class="badge badge-gold">core</span>` : ''}</div>${r.description ? html`<div class="list-sub">${r.description}</div>` : ''}</td>
        <td class="small">${r.delay === '00:00:00' ? 'immediately' : 'after ' + r.delay}${Object.keys(r.conditions || {}).length ? html`<div class="list-sub">if ${JSON.stringify(r.conditions)}</div>` : ''}</td>
        <td class="small">${(r.actions || []).map((a) => a.type.replace(/_/g, ' ')).join(' → ')}</td>
        <td><input type="checkbox" data-change="toggleRule" data-id="${r.id}" data-system="${r.is_system}" ${r.active ? raw('checked') : ''}></td></tr>`)}</tbody></table></div></div>
      <div class="card"><div class="card-title">Recent runs</div>${log.map((l) => html`<div class="profit-row"><span class="lbl">${ago(l.created_at)} · ${l.rule_name}</span><span class="${l.status === 'failed' ? 'red' : 'green'}">${l.status}</span></div>`)}
        ${log.length ? '' : html`<div class="muted small">No runs yet.</div>`}</div>`;
    }
    if (tab === 'users') {
      const users = await db.list('users', { order: 'created_at' });
      body = html`<div class="card" style="padding:0"><div class="table-wrap"><table><thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Status</th><th class="num">Wage $/h</th><th class="num">Burden $/h</th><th></th></tr></thead>
        <tbody>${users.map((u) => html`<tr data-user="${u.id}"><td>${u.first_name} ${u.last_name}</td><td class="small muted">${u.email}</td>
          <td>${select('role', ['owner', 'admin', 'sales', 'project_manager', 'crew_leader', 'field_worker', 'estimator', 'bookkeeper', 'subcontractor'], u.role, 'style="width:auto"')}</td>
          <td>${select('status', ['active', 'pending', 'disabled'], u.status, 'style="width:auto"')}</td>
          <td><input name="labor_rate" type="number" value="${u.labor_rate}" style="width:90px"></td><td><input name="burden_rate" type="number" value="${u.burden_rate}" style="width:90px"></td>
          <td><button class="btn btn-gold btn-xs" data-act="saveUser" data-id="${u.id}">Save</button></td></tr>`)}</tbody></table></div></div>
        <div class="hint" style="margin-top:8px">New people sign up (or are invited from the Supabase dashboard) and appear here as <b>pending</b> with no access until you activate them. Wage 0 = use the defaults in Pricing & labor. Role-based restrictions arrive with the first employee.</div>`;
    }
    if (tab === 'data') body = html`<div class="grid-2">
      <div class="card"><div class="card-title">Import from CRM V1</div>
        <ol class="small muted" style="margin:0 0 12px 18px;line-height:1.7"><li>Open the old <code>goldex-crm.html</code> in the same browser you used it in.</li>
          <li>Press <b>⌥⌘J</b> (Chrome) to open the console, paste this, press Enter — it copies your data:</li></ol>
        <pre class="small" style="background:var(--navy-950);padding:10px;border-radius:6px;white-space:pre-wrap;user-select:all;margin-bottom:12px">copy(JSON.stringify(Object.fromEntries(Object.keys(localStorage).filter(k=>k.startsWith('gx_')&&k!=='gx_seeded').map(k=>[k.slice(3),JSON.parse(localStorage[k])]))))</pre>
        ${field('3. Paste it here', textarea('v1', '', 'id="v1-json" style="min-height:120px" placeholder=\'{"customers":[...],"leads":[...]}\''))}
        <button class="btn btn-gold" data-act="importV1">Import V1 data</button>
        <div class="hint">Runs in one transaction: all or nothing. Historical records do not trigger automations. Can only be run once.</div></div>
      <div class="card"><div class="card-title">Export</div>
        <p class="small muted" style="margin-bottom:12px">Supabase takes daily backups automatically (7 days on Pro; see README). These exports are your own extra copy.</p>
        <div class="pill-row" style="margin-bottom:12px"><button class="btn btn-gold" data-act="exportAll">Full CRM (JSON)</button></div>
        <div class="pill-row">${['customers', 'properties', 'leads', 'estimates', 'proposals', 'v_project_profit', 'invoices', 'payments', 'expenses', 'time_entries', 'tasks']
          .map((t) => html`<button class="btn btn-dark btn-sm" data-act="exportCsv" data-t="${t}">${t.replace('v_project_profit', 'project financials')}.csv</button>`)}</div>
        ${DEMO ? html`<div class="card-title" style="margin-top:20px">Demo</div><button class="btn btn-red btn-sm" data-act="resetDemo">Reset demo database</button>` : ''}</div></div>`;
    if (tab === 'audit') {
      const rows = await db.list('audit_log', { order: 'id desc', limit: 150 });
      const who = Object.fromEntries(state.users.map((u) => [u.id, u.first_name]));
      body = html`<div class="card" style="padding:0"><div class="table-wrap"><table><thead><tr><th>When</th><th>Who</th><th>Record</th><th>Action</th><th>Changed</th></tr></thead>
        <tbody>${rows.map((r) => html`<tr><td class="small muted nowrap">${fmtDateTime(r.created_at)}</td><td class="small">${who[r.user_id] || (r.user_id ? '?' : 'system')}</td>
          <td class="small">${r.entity_type}</td><td class="small">${r.action}</td>
          <td class="small muted" style="max-width:520px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${r.action === 'create' ? '' : Object.keys(r.new_value || {}).filter((k) => k !== 'id').map((k) => `${k}: ${JSON.stringify(r.old_value?.[k] ?? null)} → ${JSON.stringify(r.new_value[k])}`).join(' · ')}</td></tr>`)}</tbody></table></div></div>`;
    }
    return html`<div class="tabs">${TABS.map(([k, l]) => html`<div class="tab ${k === tab ? 'active' : ''}" data-act="setTab" data-t="${k}">${l}</div>`)}</div>${body}`;
  },
});

register({
  setTab: ({ t }) => { tab = t; refresh(); },
  saveSettings: async () => {
    const f = readForm(document.getElementById('set-form'));
    const updates = {};
    for (const [k, v] of Object.entries(f)) {
      if (k.includes('.')) {
        const [key, prop] = k.split('.');
        updates[key] = updates[key] || { ...(setting(key, {}) || {}) };
        updates[key][prop] = typeof v === 'number' || v === null ? v : v;
      } else if (['lead_sla_minutes'].includes(k)) updates[k] = v;
      else updates[k] = (v || '').split('\n').map((s) => s.trim()).filter(Boolean);
    }
    for (const [key, value] of Object.entries(updates)) await db.updateWhere('settings', { eq: { key } }, { value });
    await loadSettings();
    toast('Settings saved'); refresh();
  },
  toggleRule: async ({ id, system }, el) => {
    if (system === 'true' && !el.checked && !(await confirmDialog('Disable a core workflow?', 'This rule is part of the core Lead → Project → Payment flow. Disabling it means that step will no longer happen automatically.', 'Disable', 'btn-red'))) { el.checked = true; return; }
    await db.update('automation_rules', id, { active: el.checked }); toast(el.checked ? 'Rule enabled' : 'Rule disabled');
  },
  saveUser: async ({ id }) => {
    const row = document.querySelector(`tr[data-user="${id}"]`);
    const f = readForm(row);
    await db.update('users', id, { ...f, labor_rate: f.labor_rate || 0, burden_rate: f.burden_rate || 0 });
    state.users = await db.list('users', { eq: { status: 'active' } });
    toast('User saved');
  },
  importV1: async () => {
    let payload;
    try { payload = JSON.parse(document.getElementById('v1-json').value); } catch { throw new Error('That is not valid JSON — copy it again from the V1 console.'); }
    const counts = await db.rpc('import_v1', { payload });
    toast('Imported: ' + Object.entries(counts).filter(([, n]) => n).map(([k, n]) => `${n} ${k}`).join(', '));
  },
  exportCsv: async ({ t }) => downloadFile(`goldex-${t}-${today()}.csv`, toCSV(await db.list(t, {})), 'text/csv'),
  exportAll: async () => {
    const tables = ['customers', 'properties', 'leads', 'communications', 'pricebook_items', 'estimates', 'estimate_items', 'proposals',
      'proposal_items', 'projects', 'project_checklist_items', 'tasks', 'calendar_events', 'invoices', 'payments', 'expenses',
      'time_entries', 'materials', 'settings', 'automation_rules'];
    const out = { exported_at: new Date().toISOString(), version: 'goldex-crm-v2' };
    for (const t of tables) out[t] = await db.list(t, {});
    downloadFile(`goldex-crm-full-${today()}.json`, JSON.stringify(out, null, 1));
  },
  resetDemo: async () => {
    if (!(await confirmDialog('Reset demo?', 'Deletes the demo database in this browser and reloads with fresh sample data.', 'Reset', 'btn-red'))) return;
    await db.reset(); setTimeout(() => location.reload(), 300);
  },
});
