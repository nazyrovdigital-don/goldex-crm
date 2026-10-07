// Sales: pipeline, leads, lead workspace, customers + Customer 360.
import { db, page, register, refresh, go, state, setting } from '../app.js';
import { html, raw, money, pct, fmtDate, fmtDateTime, ago, badge, scoreBadge, modal, closeModal, toast, readForm, need,
         field, input, textarea, select, empty, kpi, today, dueFromDate, dateInput, dtInput, confirmDialog } from '../ui.js';
import { custName, customersById, customerSelect, addressFields, createCustomer, setReopen, taskList, timeline, userName,
         openCustomerForm, openContactLog } from './common.js';
import { thumbtackPanel, responseBadge } from './thumbtack.js';

const STAGES = ['NEW LEAD', 'CONTACTED', 'QUALIFYING', 'SITE VISIT', 'ESTIMATE', 'PROPOSAL SENT', 'FOLLOW-UP', 'WON', 'LOST'];
const OPEN = STAGES.slice(0, 7);
const filters = { q: '', source: '', service: '', score: '', showLost: false };

register({
  go: ({ to }) => go(to),
  filterPipeline: (_d, el) => { filters[el.name] = el.type === 'checkbox' ? el.checked : el.value; refresh(); },
  openLead: ({ id }) => openLead(id),
  newLead: () => openLeadForm(),
  leadCustomerChanged: async (_d, el) => {
    if (el.value === '__new') return;
    const sel = document.querySelector('#modal-body select[name="property_id"]');
    if (!sel || !el.value) return;
    const props = await db.list('properties', { eq: { customer_id: el.value }, is: ['archived_at'] });
    sel.innerHTML = String(html`<option value="">${props.length ? 'Select property…' : 'No saved properties'}</option>
      ${props.map((p) => html`<option value="${p.id}" ${p.is_default ? raw('selected') : ''}>${p.address}</option>`)}`);
  },
  markLost: ({ id }) => markLost(id),
  createEstimate: async ({ id }) => { const eid = await db.rpc('create_estimate_from_lead', { p_lead_id: id }); closeModal(); go('estimate/' + eid); },
  scheduleVisit: ({ id }) => scheduleVisit(id),
  addProperty: ({ customer }) => addProperty(customer),
  editCustomer: async ({ id }) => openCustomerForm(await db.get('customers', id)),
  c360tab: ({ tab }, el) => {
    document.querySelectorAll('[data-c360]').forEach((x) => { x.hidden = x.dataset.c360 !== tab; });
    el.parentElement.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t === el));
  },
});

const matches = (l) => (!filters.source || l.source === filters.source) && (!filters.service || l.service_type === filters.service)
  && (!filters.score || l.qualification_score === filters.score)
  && (!filters.q || `${l.customer_name} ${l.description} ${l.lead_number} ${l.customer_phone} ${l.property_address}`.toLowerCase().includes(filters.q.toLowerCase()));

const filterBar = (leads) => html`<div class="toolbar">
  <input name="q" placeholder="Filter…" value="${filters.q}" data-change="filterPipeline" style="max-width:220px">
  ${select('source', [['', 'All sources'], ...setting('lead_sources', [])], filters.source, 'data-change="filterPipeline"')}
  ${select('service', [['', 'All services'], ...setting('service_types', [])], filters.service, 'data-change="filterPipeline"')}
  ${select('score', [['', 'All scores'], 'A', 'B', 'C', 'D'], filters.score, 'data-change="filterPipeline"')}
  <span class="grow muted small">Open pipeline <b class="gold">${money(leads.filter((l) => OPEN.includes(l.stage)).reduce((a, l) => a + Number(l.estimated_value), 0))}</b></span>
  <button class="btn btn-gold" data-act="newLead">+ New lead</button>
</div>`;

// ── PIPELINE ───────────────────────────────────────────────────────
page('pipeline', {
  title: 'Pipeline',
  async render() {
    const monthAgo = new Date(Date.now() - 30 * 864e5).toISOString();
    const leads = (await db.list('v_leads', { is: ['archived_at'], order: 'created_at desc' }))
      .filter((l) => l.stage !== 'LOST' && (l.stage !== 'WON' || l.stage_changed_at > monthAgo)).filter(matches);
    return html`${filterBar(leads)}
    <div class="pipeline">${STAGES.slice(0, 8).map((stage) => {
      const col = leads.filter((l) => l.stage === stage);
      return html`<div class="pipeline-col" data-stage="${stage}">
        <div class="pipeline-col-title"><span>${stage}${stage === 'WON' ? ' (30d)' : ''}</span><span>${col.length}</span></div>
        <div class="pipeline-col-val">${money(col.reduce((a, l) => a + Number(l.estimated_value), 0))}</div>
        ${col.map((l) => html`<div class="pcard ${l.sla_breached ? 'sla' : ''}" draggable="${stage !== 'WON'}" data-id="${l.id}" data-act="openLead">
          <div class="pcard-top"><span class="pcard-name">${l.customer_name}</span>${scoreBadge(l.qualification_score)}</div>
          <div class="pcard-line">${l.service_type || 'Service TBD'}${l.source ? ' · ' + l.source : ''}</div>
          ${l.next_action ? html`<div class="pcard-next">→ ${l.next_action}</div>` : ''}
          ${l.thumbtack_lead_id && l.stage === 'NEW LEAD' ? html`<div style="margin-top:6px">${responseBadge(l.response_status)}</div>` : ''}
          <div class="pcard-foot"><span class="pcard-val">${money(l.estimated_value)}</span>
            <span title="Age">${l.sla_breached ? html`<b class="red">SLA</b> · ` : ''}${l.age_days}d${l.next_followup_at ? ' · f/u ' + fmtDate(l.next_followup_at) : ''}</span></div>
        </div>`)}
      </div>`;
    })}</div>
    <div class="hint">Drag cards between stages. WON happens when a proposal is approved — that is what creates the project.</div>`;
  },
  after(root) {
    let dragId = null;
    root.querySelectorAll('.pcard[draggable=true]').forEach((c) => c.addEventListener('dragstart', (e) => { dragId = c.dataset.id; e.dataTransfer.effectAllowed = 'move'; }));
    root.querySelectorAll('.pipeline-col').forEach((col) => {
      col.addEventListener('dragover', (e) => { e.preventDefault(); col.classList.add('drop'); });
      col.addEventListener('dragleave', () => col.classList.remove('drop'));
      col.addEventListener('drop', async (e) => {
        e.preventDefault(); col.classList.remove('drop');
        const stage = col.dataset.stage;
        if (!dragId) return;
        if (stage === 'WON') { toast('Approve the proposal to win this lead — that creates the project and deposit invoice.', 'error'); return; }
        try { await db.update('leads', dragId, { stage }); toast(`Moved to ${stage}`); refresh(); }
        catch (ex) { toast(ex.message, 'error'); }
      });
    });
  },
});

// ── LEADS TABLE + LOSS ANALYSIS ────────────────────────────────────
page('leads', {
  title: 'Leads', nav: 'leads',
  async render() {
    const all = await db.list('v_leads', { is: ['archived_at'], order: 'created_at desc' });
    const leads = all.filter(matches).filter((l) => filters.showLost || l.stage !== 'LOST');
    const lost = all.filter((l) => l.stage === 'LOST');
    const reasons = Object.entries(lost.reduce((a, l) => { a[l.lost_reason] = (a[l.lost_reason] || 0) + 1; return a; }, {})).sort((a, b) => b[1] - a[1]);
    return html`${filterBar(all)}
    <label class="check small" style="margin:-8px 0 10px"><input type="checkbox" name="showLost" data-change="filterPipeline" ${filters.showLost ? raw('checked') : ''}> Show lost leads</label>
    <div class="card" style="padding:0"><div class="table-wrap"><table>
      <thead><tr><th>Lead</th><th>Customer</th><th>Service</th><th class="num">Value</th><th>Score</th><th>Stage</th><th>Source</th><th>Next action</th><th>Age</th></tr></thead>
      <tbody>${leads.map((l) => html`<tr class="click" data-act="openLead" data-id="${l.id}">
        <td class="muted small nowrap">${l.lead_number}</td>
        <td><div class="list-name">${l.customer_name}</div><div class="list-sub">${(l.description || '').slice(0, 48)}</div></td>
        <td>${l.service_type || '—'}</td><td class="num gold">${money(l.estimated_value)}</td><td>${scoreBadge(l.qualification_score)}</td>
        <td>${badge(l.stage)}</td><td class="muted small">${l.source || ''}</td>
        <td class="small ${l.sla_breached ? 'red' : ''}">${l.stage === 'LOST' ? 'Lost: ' + l.lost_reason : l.next_action || ''}</td>
        <td class="muted small nowrap">${l.age_days}d</td></tr>`)}</tbody></table></div>
      ${leads.length ? '' : empty('◎', 'No leads match')}</div>
    <div class="section-h">Why are we losing?</div>
    <div class="card">${reasons.length ? reasons.map(([r, n]) => html`<div class="profit-row"><span class="lbl">${r}</span><span>${n} · ${Math.round(n / lost.length * 100)}%</span></div>`)
      : html`<div class="muted small">No lost leads yet. Every lost lead requires a reason, so this fills in over time.</div>`}</div>`;
  },
});

// ── LEAD FORM ──────────────────────────────────────────────────────
async function openLeadForm(l = {}) {
  const { list } = await customersById();
  const custId = l.customer_id || '';
  const props = custId ? await db.list('properties', { eq: { customer_id: custId }, is: ['archived_at'] }) : [];
  setReopen((vals) => openLeadForm({ ...l, ...vals }));
  const isNew = !l.id;
  modal(isNew ? 'New lead' : `Edit ${l.lead_number}`, html`
    <div class="fieldset"><div class="fieldset-title">Customer & property</div>
      <div class="form-row">${field('Customer', select('customer_id', [['', 'Select customer…'], ...list.map((c) => [c.id, custName(c) + (c.phone ? ' · ' + c.phone : '')]), ['__new', '+ New customer…']], custId, 'data-change="customerPicked leadCustomerChanged"'))}
      ${field('Property', select('property_id', [['', props.length ? 'Select property…' : 'Choose customer first'], ...props.map((p) => [p.id, p.address])], l.property_id || props.find((p) => p.is_default)?.id))}</div>
      ${field('…or new project address', input('new_address', l.new_address, 'placeholder="Only if the job is at a new address"'))}
    </div>
    <div class="fieldset"><div class="fieldset-title">Project</div>
      <div class="form-row">${field('Service', select('service_type', ['', ...setting('service_types', [])], l.service_type))}
        ${field('Project type / room', input('project_type', l.project_type, 'placeholder="Kitchen, garage, whole house…"'))}</div>
      ${field('Description', textarea('description', l.description, 'placeholder="Scope as the customer described it"'))}
      <div class="form-row-3">${field('Estimated value ($)', input('estimated_value', l.estimated_value, 'type="number" step="50"'))}
        ${field('Budget min', input('budget_min', l.budget_min, 'type="number"'))}${field('Budget max', input('budget_max', l.budget_max, 'type="number"'))}</div>
    </div>
    <div class="fieldset"><div class="fieldset-title">Qualification</div>
      <div class="form-row-3">${field('Approx. size', input('approx_size', l.approx_size, 'placeholder="650 sq ft, 18 cabinets…"'))}
        ${field('Desired start', input('preferred_start_date', l.preferred_start_date, 'type="date"'))}
        ${field('Urgency', select('urgency', ['Normal', 'Flexible', 'Urgent', 'Emergency'], l.urgency || 'Normal'))}</div>
      <div class="form-row-3">${field('Decision maker?', select('decision_maker', ['Unknown', 'Yes', 'No'], l.decision_maker || 'Unknown'))}
        ${field('Customer availability', input('customer_availability', l.customer_availability))}
        ${field('Score override', select('score_override', [['', l.qualification_score ? `Auto (${l.qualification_score})` : 'Auto'], 'A', 'B', 'C', 'D'], l.score_override))}</div>
      <label class="check"><input type="checkbox" name="photos_provided" ${l.photos_provided ? raw('checked') : ''}> Photos provided</label>
      <label class="check"><input type="checkbox" name="site_visit_required" ${l.site_visit_required ? raw('checked') : ''}> Site visit required</label>
    </div>
    <div class="fieldset"><div class="fieldset-title">Pipeline</div>
      <div class="form-row-3">${field('Source', select('source', ['', ...setting('lead_sources', [])], l.source))}
        ${field('Source details', input('source_details', l.source_details, 'placeholder="Who referred, which ad…"'))}
        ${field('Stage', select('stage', l.stage === 'WON' || l.stage === 'LOST' ? [l.stage] : OPEN, l.stage || 'NEW LEAD'))}</div>
      <div class="form-row">${field('Next follow-up', input('next_followup_at', dateInput(l.next_followup_at), 'type="date"'))}
        ${field('Assigned to', select('assigned_to', state.users.map((u) => [u.id, `${u.first_name} ${u.last_name}`]), l.assigned_to || state.me.id))}</div>
      ${field('Internal notes', textarea('notes', l.notes))}
    </div>`,
  [{ label: 'Cancel' }, { label: isNew ? 'Create lead' : 'Save', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body);
    need(f, { customer_id: 'Customer' });
    let property_id = f.property_id;
    if (f.new_address) property_id = (await db.insert('properties', { customer_id: f.customer_id, address: f.new_address })).id;
    const row = { customer_id: f.customer_id, property_id, service_type: f.service_type, project_type: f.project_type,
      description: f.description, estimated_value: f.estimated_value || 0, budget_min: f.budget_min, budget_max: f.budget_max,
      approx_size: f.approx_size, preferred_start_date: f.preferred_start_date, urgency: f.urgency, decision_maker: f.decision_maker,
      customer_availability: f.customer_availability, score_override: f.score_override, photos_provided: f.photos_provided,
      site_visit_required: f.site_visit_required, source: f.source, source_details: f.source_details, stage: f.stage,
      next_followup_at: dueFromDate(f.next_followup_at), assigned_to: f.assigned_to, notes: f.notes };
    const saved = isNew ? await db.insert('leads', row) : await db.update('leads', l.id, row);
    toast(isNew ? `Lead ${saved.lead_number} created — contact task added` : 'Lead saved');
    closeModal(); refresh();
  } }], 'lg');
}

// ── LEAD WORKSPACE ─────────────────────────────────────────────────
async function openLead(id) {
  const [l] = await db.list('v_leads', { eq: { id } });
  if (!l) return toast('Lead not found', 'error');
  const [tasks, estimates, proposals, tl] = await Promise.all([
    db.list('tasks', { eq: { lead_id: id }, in: { status: ['Pending', 'In Progress'] }, order: 'due_at' }),
    db.list('estimates', { eq: { lead_id: id }, is: ['archived_at'], order: 'created_at desc' }),
    db.list('proposals', { eq: { lead_id: id }, is: ['archived_at'], order: 'created_at desc' }),
    timeline({ lead: id }),
  ]);
  const ttPanel = await thumbtackPanel(l);
  const closed = ['WON', 'LOST'].includes(l.stage);
  modal(`${l.customer_name} — ${l.service_type || 'Lead'}`, html`
    <div class="pill-row" style="margin-bottom:12px">${badge(l.stage)} ${scoreBadge(l.qualification_score)}
      <span class="muted small">${l.lead_number} · ${l.source || 'unknown source'} · created ${ago(l.created_at)}${l.last_contacted_at ? ' · contacted ' + ago(l.last_contacted_at) : ' · not contacted yet'}</span></div>
    ${l.sla_breached ? html`<div class="toast toast-error" style="max-width:none;margin-bottom:12px">Not contacted within ${setting('lead_sla_minutes', 15)} minutes. Call now.</div>` : ''}
    <div class="grid-2" style="margin-bottom:8px">
      <div>
        <div class="profit-row"><span class="lbl">Phone</span>${l.customer_phone ? html`<a href="tel:${l.customer_phone}">${l.customer_phone}</a>` : '—'}</div>
        <div class="profit-row"><span class="lbl">Email</span>${l.customer_email ? html`<a href="mailto:${l.customer_email}">${l.customer_email}</a>` : '—'}</div>
        <div class="profit-row"><span class="lbl">Address</span><span class="right">${l.property_address || '—'}</span></div>
        <div class="profit-row"><span class="lbl">Estimated value</span><span class="gold">${money(l.estimated_value)}</span></div>
        <div class="profit-row"><span class="lbl">Desired start</span><span>${fmtDate(l.preferred_start_date) || '—'} · ${l.urgency}</span></div>
        <div class="profit-row"><span class="lbl">Site visit</span><span>${l.site_visit_date ? fmtDateTime(l.site_visit_date) : l.site_visit_required ? 'Required — not scheduled' : 'Not required'}</span></div>
        ${l.utm_campaign ? html`<div class="profit-row"><span class="lbl">Campaign</span><span>${l.utm_source}/${l.utm_medium} · ${l.utm_campaign}</span></div>` : ''}
        ${l.stage === 'LOST' ? html`<div class="profit-row"><span class="lbl">Lost reason</span><span class="red">${l.lost_reason}${l.lost_competitor ? ' · ' + l.lost_competitor : ''}</span></div>` : ''}
      </div>
      <div>
        <div class="card-title">Next action</div><div class="gold" style="margin-bottom:10px">${l.next_action || '—'}</div>
        <div class="card-title">Open tasks</div>${taskList(tasks)}
      </div>
    </div>
    ${ttPanel}
    ${l.description ? html`<div class="card-title">Description</div><div style="white-space:pre-wrap;margin-bottom:12px">${l.description}</div>` : ''}
    ${estimates.length || proposals.length ? html`<div class="card-title">Estimates & proposals</div>
      ${estimates.map((e) => html`<div class="list-item click" data-act="go" data-to="estimate/${e.id}"><div class="list-main"><div class="list-name">${e.estimate_number} · ${e.title}</div></div>${badge(e.status)}<span class="list-val">${money(e.total)}</span></div>`)}
      ${proposals.map((p) => html`<div class="list-item click" data-act="go" data-to="proposal/${p.id}"><div class="list-main"><div class="list-name">${p.proposal_number} · ${p.title}</div></div>${badge(p.status)}<span class="list-val">${money(p.total)}</span></div>`)}` : ''}
    <div class="card-title" style="margin-top:12px">Communication</div>${tl}`,
  [{ label: 'Edit', cls: 'btn-ghost', onClick: () => openLeadForm(l) },
   ...(closed ? [] : [
     { label: 'Mark lost', cls: 'btn-red', onClick: () => markLost(id) },
     { label: 'Log contact', cls: 'btn-dark', onClick: () => openContactLog({ lead: id, customer: l.customer_id }) },
     { label: 'Site visit', cls: 'btn-dark', onClick: () => scheduleVisit(id) },
     { label: 'Create estimate →', cls: 'btn-gold', onClick: async () => { const eid = await db.rpc('create_estimate_from_lead', { p_lead_id: id }); closeModal(); go('estimate/' + eid); } },
   ])], 'lg');
}

function markLost(id) {
  modal('Mark lead lost', html`
    ${field('Reason (required)', select('reason', ['', ...setting('loss_reasons', [])], ''))}
    ${field('Competitor (if any)', input('competitor'))}
    ${field('Notes', textarea('notes', '', 'placeholder="What would have won it?"'))}`,
  [{ label: 'Cancel' }, { label: 'Mark lost', cls: 'btn-red', onClick: async (body) => {
    const f = readForm(body);
    need(f, { reason: 'Reason' });
    await db.rpc('mark_lead_lost', { p_lead_id: id, p_reason: f.reason, p_competitor: f.competitor, p_notes: f.notes });
    toast('Lead marked lost'); closeModal(); refresh();
  } }]);
}

function scheduleVisit(id) {
  modal('Schedule site visit', html`
    ${field('Date & time', input('when', dtInput(new Date(Date.now() + 864e5).setHours(10, 0, 0, 0)), 'type="datetime-local"'))}
    <div class="hint">Creates a calendar event and a site-visit task automatically.</div>`,
  [{ label: 'Cancel' }, { label: 'Schedule', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body);
    need(f, { when: 'Date' });
    const l = await db.get('leads', id);
    await db.update('leads', id, { site_visit_date: new Date(f.when).toISOString(), site_visit_required: true,
      stage: ['NEW LEAD', 'CONTACTED', 'QUALIFYING'].includes(l.stage) ? 'SITE VISIT' : l.stage });
    toast('Site visit scheduled'); closeModal(); refresh();
  } }]);
}

function addProperty(customerId) {
  modal('Add property', addressFields(), [{ label: 'Cancel' }, { label: 'Add', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body);
    need(f, { address: 'Address' });
    await db.insert('properties', { customer_id: customerId, address: f.address, city: f.city, zip: f.zip, property_type: f.property_type });
    toast('Property added'); closeModal(); refresh();
  } }]);
}

// ── CUSTOMERS ──────────────────────────────────────────────────────
page('customers', {
  title: 'Customers',
  async render() {
    const [{ list }, projects, payments, props] = await Promise.all([customersById(),
      db.list('projects', { is: ['archived_at'] }), db.list('payments', { is: ['voided_at'] }), db.list('properties', { is: ['archived_at'] })]);
    const sum = (arr, k, id) => arr.filter((x) => x.customer_id === id).reduce((a, x) => a + Number(x[k] || 0), 0);
    return html`<div class="toolbar"><input placeholder="Filter customers…" oninput="document.querySelectorAll('#cust-table tbody tr').forEach(r=>r.hidden=!r.textContent.toLowerCase().includes(this.value.toLowerCase()))" style="max-width:280px">
      <span class="grow"></span><button class="btn btn-gold" data-act="newCustomer">+ New customer</button></div>
    <div class="card" style="padding:0"><div class="table-wrap"><table id="cust-table">
      <thead><tr><th>#</th><th>Name</th><th>Phone</th><th>Email</th><th>Status</th><th>Source</th><th class="num">Properties</th><th class="num">Projects</th><th class="num">Paid to date</th></tr></thead>
      <tbody>${list.map((c) => { const np = props.filter((p) => p.customer_id === c.id).length; return html`<tr class="click" data-act="go" data-to="customer/${c.id}">
        <td class="muted small">${c.customer_number}</td>
        <td><div class="list-name">${custName(c)}</div>${np > 1 ? html`<div class="list-sub gold">Potential repeat customer</div>` : ''}</td>
        <td class="nowrap">${c.phone || ''}</td><td class="muted small">${c.email || ''}</td><td>${badge(c.customer_status)}</td>
        <td class="muted small">${c.lead_source || ''}</td><td class="num">${np}</td>
        <td class="num">${projects.filter((p) => p.customer_id === c.id).length}</td><td class="num gold">${money(sum(payments, 'amount', c.id))}</td></tr>`; })}</tbody>
    </table></div>${list.length ? '' : empty('◉', 'No customers yet')}</div>`;
  },
});

page('customer', {
  title: 'Customer', nav: 'customers',
  async render(id) {
    const c = await db.get('customers', id);
    if (!c) return empty('◉', 'Customer not found');
    const eq = { eq: { customer_id: id } };
    const [props, leads, estimates, proposals, projects, invoices, payments, tasks, tl] = await Promise.all([
      db.list('properties', { ...eq, is: ['archived_at'] }), db.list('v_leads', { ...eq, order: 'created_at desc' }),
      db.list('estimates', { ...eq, order: 'created_at desc' }), db.list('proposals', { ...eq, order: 'created_at desc' }),
      db.list('v_project_outlook', { ...eq }), db.list('v_invoices', { ...eq, order: 'issue_date desc' }),
      db.list('payments', { ...eq, order: 'payment_date desc' }), db.list('tasks', { ...eq, in: { status: ['Pending', 'In Progress'] }, order: 'due_at' }),
      timeline({ customer: id }),
    ]);
    const paid = payments.filter((p) => !p.voided_at).reduce((a, p) => a + Number(p.amount), 0);
    const gp = projects.reduce((a, p) => a + Number(p.expected_profit), 0);
    const lastProject = projects.map((p) => p).sort((a, b) => (b.project_number > a.project_number ? 1 : -1))[0];
    const comms = await db.list('communications', { eq: { customer_id: id }, order: 'sent_at desc', limit: 1 });
    const nextFu = leads.map((l) => l.next_task_due).filter(Boolean).sort()[0];
    const tabs = [['leads', `Leads (${leads.length})`], ['estimates', `Estimates (${estimates.length})`], ['proposals', `Proposals (${proposals.length})`],
      ['projects', `Projects (${projects.length})`], ['invoices', `Invoices (${invoices.length})`], ['payments', `Payments (${payments.length})`],
      ['tasks', `Tasks (${tasks.length})`], ['comms', 'Communication']];
    const row = (to, a, b, st, v) => html`<div class="list-item click" data-act="go" data-to="${to}"><div class="list-main"><div class="list-name">${a}</div><div class="list-sub">${b}</div></div>${badge(st)}<span class="list-val">${v}</span></div>`;
    return html`
    <div class="hero"><div><h1>${custName(c)} ${badge(c.customer_status)}</h1>
      <div class="muted small">${c.customer_number}${c.company_name ? ' · ' + c.company_name : ''} · since ${fmtDate(c.created_at)}${c.lead_source ? ' · via ' + c.lead_source : ''}</div></div>
      <div class="pill-row"><button class="btn btn-dark" data-act="editCustomer" data-id="${id}">Edit</button>
        <button class="btn btn-dark" data-act="logContact" data-customer="${id}">Log contact</button>
        <button class="btn btn-gold" data-act="newLeadFor" data-customer="${id}">+ New lead</button></div></div>
    <div class="kpi-grid">
      ${kpi('Total paid', money(paid), 'green')}${kpi('Gross profit', money(gp))}${kpi('Projects', projects.length)}
      ${kpi('Last project', lastProject ? lastProject.project_name : '—')}${kpi('Last contact', comms[0] ? ago(comms[0].sent_at) : '—')}
      ${kpi('Next follow-up', nextFu ? fmtDate(nextFu) : '—')}
    </div>
    <div class="grid-2">
      <div class="card"><div class="card-title">Contact</div>
        <div class="profit-row"><span class="lbl">Phone</span>${c.phone ? html`<a href="tel:${c.phone}">${c.phone}</a>` : '—'}</div>
        <div class="profit-row"><span class="lbl">Email</span>${c.email ? html`<a href="mailto:${c.email}">${c.email}</a>` : '—'}</div>
        <div class="profit-row"><span class="lbl">Billing</span><span class="right">${c.billing_address || '—'}</span></div>
        ${c.notes ? html`<div class="muted small" style="margin-top:8px;white-space:pre-wrap">${c.notes.replace(/\s*\[v1:[^\]]+\]/, '')}</div>` : ''}</div>
      <div class="card"><div class="card-title">Properties ${props.length > 1 ? html`<span class="badge badge-gold">Potential repeat customer</span>` : ''}
        <button class="btn btn-link" data-act="addProperty" data-customer="${id}">+ Add</button></div>
        ${props.map((p) => html`<div class="list-item"><div class="list-main"><div class="list-name">${p.address}</div><div class="list-sub">${[p.city, p.property_type].filter(Boolean).join(' · ')}</div></div>${p.is_default ? badge('Default', 'muted') : ''}</div>`)}
        ${props.length ? '' : html`<div class="muted small">No properties yet.</div>`}</div>
    </div>
    <div class="tabs">${tabs.map(([k, l], i) => html`<div class="tab ${i ? '' : 'active'}" data-act="c360tab" data-tab="${k}">${l}</div>`)}</div>
    <div data-c360="leads">${leads.map((l) => html`<div class="list-item click" data-act="openLead" data-id="${l.id}"><div class="list-main"><div class="list-name">${l.lead_number} · ${l.service_type || ''}</div><div class="list-sub">${(l.description || '').slice(0, 80)}</div></div>${badge(l.stage)}<span class="list-val">${money(l.estimated_value)}</span></div>`)}</div>
    <div data-c360="estimates" hidden>${estimates.map((e) => row('estimate/' + e.id, `${e.estimate_number} · ${e.title}`, fmtDate(e.created_date), e.status, money(e.total)))}</div>
    <div data-c360="proposals" hidden>${proposals.map((p) => row('proposal/' + p.id, `${p.proposal_number} · ${p.title}`, fmtDate(p.created_at), p.status, money(p.total)))}</div>
    <div data-c360="projects" hidden>${projects.map((p) => row('project/' + p.project_id, `${p.project_number} · ${p.project_name}`, `GP ${money(p.expected_profit)} · ${pct(p.expected_margin)}`, p.status, money(p.current_contract_value)))}</div>
    <div data-c360="invoices" hidden>${invoices.map((i) => row('invoices', `${i.invoice_number} · ${i.type}`, `Due ${fmtDate(i.due_date)} · balance ${money(i.balance_due)}`, i.is_overdue ? 'Overdue' : i.status, money(i.total)))}</div>
    <div data-c360="payments" hidden>${payments.map((p) => html`<div class="list-item"><div class="list-main"><div class="list-name">${money(p.amount, true)} · ${p.method}</div><div class="list-sub">${fmtDate(p.payment_date)} · ${p.kind || ''}${p.voided_at ? ' · VOID' : ''}</div></div></div>`)}</div>
    <div data-c360="tasks" hidden>${taskList(tasks)}</div>
    <div data-c360="comms" hidden>${tl}</div>`;
  },
});
register({ newLeadFor: ({ customer }) => openLeadForm({ customer_id: customer }) });

export { openLead, openLeadForm };
