// Operations: projects + project command center, tasks, calendar/scheduling.
import { db, page, register, refresh, go, state, setting, refreshBadges } from '../app.js';
import { html, raw, money, pct, num, fmtDate, fmtDateTime, ago, badge, modal, closeModal, toast, readForm, need, field, input,
         textarea, select, empty, kpi, marginBadge, marginTone, today, addDays, dueFromDate, confirmDialog } from '../ui.js';
import { custName, customersById, taskList, timeline, userName, openTaskForm } from './common.js';
import { openLogTime, openExpenseForm, openInvoiceForm, openPaymentForm } from './finance.js';

const PROJECT_STATUSES = ['Pending Deposit', 'Ready to Schedule', 'Scheduled', 'Pre-Construction', 'In Progress', 'On Hold',
  'Punch List', 'QC', 'Completed', 'Closed', 'Cancelled'];
const ACTIVE = PROJECT_STATUSES.slice(0, 8);
const MAT_STATUSES = ['Needed', 'Quoted', 'Approved', 'Ordered', 'Partially Received', 'Received', 'Installed', 'Returned', 'Cancelled'];
let projFilter = 'active';
let projTab = 'overview';

// ── PROJECTS LIST ──────────────────────────────────────────────────
page('projects', {
  title: 'Projects',
  async render() {
    const [rows, { by }] = await Promise.all([db.list('v_project_outlook', { order: 'project_number desc' }), customersById()]);
    const shown = rows.filter((p) => projFilter === 'all' || (projFilter === 'active' ? ACTIVE.includes(p.status) : !ACTIVE.includes(p.status)));
    const tot = (k) => shown.reduce((a, p) => a + Number(p[k] || 0), 0);
    return html`<div class="toolbar">
      <div class="seg">${[['active', 'Active'], ['done', 'Completed / closed'], ['all', 'All']].map(([k, l]) => html`<button class="${projFilter === k ? 'on' : ''}" data-act="projFilter" data-f="${k}">${l}</button>`)}</div>
      <span class="grow"></span><button class="btn btn-dark" data-act="newProject">+ Manual project</button></div>
    <div class="card" style="padding:0"><div class="table-wrap"><table>
      <thead><tr><th>Project</th><th>Customer</th><th>Status</th><th class="num">Contract</th><th class="num">Collected</th><th class="num">Cost to date</th><th class="num" title="Projected for open jobs, actual for completed">Gross profit</th><th>Margin</th><th>Next action</th></tr></thead>
      <tbody>${shown.map((p) => html`<tr class="click" data-act="go" data-to="project/${p.project_id}">
        <td><div class="list-name">${p.project_name}</div><div class="list-sub">${p.project_number}</div></td>
        <td>${custName(by[p.customer_id])}</td><td>${badge(p.status)}</td>
        <td class="num gold">${money(p.current_contract_value)}</td><td class="num green">${money(p.collected)}</td>
        <td class="num muted">${money(p.direct_cost)}</td><td class="num">${money(p.expected_profit)}</td><td>${marginBadge(p.expected_margin)}</td>
        <td class="small">${p.next_action || ''}</td></tr>`)}</tbody>
      ${shown.length ? html`<tfoot><tr><td colspan="3">Totals</td><td class="num">${money(tot('current_contract_value'))}</td><td class="num">${money(tot('collected'))}</td>
        <td class="num">${money(tot('direct_cost'))}</td><td class="num">${money(tot('expected_profit'))}</td><td colspan="2"></td></tr></tfoot>` : ''}
    </table></div>${shown.length ? '' : empty('▣', 'No projects here. Projects are created automatically when a proposal is approved.')}</div>`;
  },
});

// ── PROJECT COMMAND CENTER ─────────────────────────────────────────
page('project', {
  title: 'Project', nav: 'projects',
  async render(id) {
    const [p, f] = await Promise.all([db.get('projects', id), db.list('v_project_outlook', { eq: { project_id: id } }).then((r) => r[0])]);
    if (!p) return empty('▣', 'Project not found');
    const eq = { eq: { project_id: id } };
    const [c, prop, tasks, doneTasks, checklist, materials, invoices, payments, time, expenses, events, tl] = await Promise.all([
      db.get('customers', p.customer_id), p.property_id ? db.get('properties', p.property_id) : null,
      db.list('tasks', { ...eq, in: { status: ['Pending', 'In Progress'] }, order: 'due_at' }),
      db.list('tasks', { ...eq, eq: { project_id: id, status: 'Completed' }, order: 'completed_at desc', limit: 10 }),
      db.list('project_checklist_items', { ...eq, order: ['phase', 'sort_order'] }),
      db.list('materials', { ...eq, is: ['archived_at'], order: 'created_at' }),
      db.list('v_invoices', { ...eq, order: 'issue_date' }), db.list('payments', { ...eq, order: 'payment_date desc' }),
      db.list('time_entries', { ...eq, is: ['archived_at'], order: 'entry_date desc' }),
      db.list('expenses', { ...eq, is: ['archived_at'], order: 'expense_date desc' }),
      db.list('calendar_events', { ...eq, order: 'event_date' }), timeline({ project: id }),
    ]);
    const est = { labor: 0, material: 0, sub: 0, other: 0 };
    if (p.estimate_id) {
      const e = await db.get('estimates', p.estimate_id);
      if (e) Object.assign(est, { labor: e.estimated_labor_cost, material: e.estimated_material_cost, sub: e.estimated_subcontractor_cost, other: e.estimated_other_direct_cost });
    }
    const done = ['Completed', 'Closed'].includes(p.status);
    const hoursPct = Number(f.budgeted_hours) ? Number(f.actual_hours) / Number(f.budgeted_hours) * 100 : 0;
    const pre = checklist.filter((x) => x.phase === 'Pre-Construction');
    const close = checklist.filter((x) => x.phase === 'Closeout');
    const invoiced = invoices.filter((i) => i.status !== 'Void').reduce((a, i) => a + Number(i.total), 0);
    const startEvt = events.find((e) => e.type === 'Project Start');
    const checks = (items) => html`<div class="checklist">${items.map((x) => html`<label class="check-item ${x.done_at ? 'done' : ''}">
      <input type="checkbox" data-change="toggleCheck" data-id="${x.id}" ${x.done_at ? raw('checked') : ''}><span class="ci-text">${x.label}</span>
      ${x.done_at ? html`<span class="small muted">${fmtDate(x.done_at)}</span>` : ''}</label>`)}</div>`;
    const tabs = [['overview', 'Overview'], ['finance', 'Finance'], ['tasks', `Tasks (${tasks.length})`], ['materials', `Materials (${materials.length})`],
      ['labor', 'Time & expenses'], ['closeout', 'Closeout'], ['activity', 'Activity']];
    const row = (label, e, a, proj, cls = '') => html`<div class="${cls}">${label}</div><div class="n ${cls}">${e == null ? '—' : money(e)}</div><div class="n ${cls}">${money(a)}</div><div class="n ${cls}">${proj == null ? '—' : money(proj)}</div>`;

    return html`
    <div class="hero"><div><h1>${p.project_name}</h1>
      <div class="muted small">${p.project_number} · <a href="#/customer/${c.id}">${custName(c)}</a>${prop ? ' · ' + prop.address : ''}${c.phone ? html` · <a href="tel:${c.phone}">${c.phone}</a>` : ''}</div>
      <div class="pill-row" style="margin-top:8px">${badge(p.status)}${f.next_action ? html`<span class="gold small">→ ${f.next_action}</span>` : ''}</div></div>
      <div class="pill-row">
        ${['Ready to Schedule', 'Pending Deposit'].includes(p.status) ? html`<button class="btn btn-gold" data-act="scheduleProject" data-id="${id}">Schedule start</button>` : ''}
        <button class="btn btn-dark" data-act="logTimeFor" data-project="${id}">Log hours</button>
        <button class="btn btn-dark" data-act="expenseFor" data-project="${id}">Log expense</button>
        <button class="btn btn-dark" data-act="invoiceFor" data-project="${id}">Invoice</button></div></div>

    <div class="kpi-grid">
      ${kpi('Contract value', money(f.current_contract_value), 'gold', Number(p.approved_change_orders) ? `incl. ${money(p.approved_change_orders)} change orders` : 'locked from proposal')}
      ${kpi('Collected', money(f.collected), 'green')}${kpi('Balance', money(f.balance), Number(f.balance) > 0 ? 'orange' : '')}
      ${kpi('Cost to date', money(f.direct_cost), '', `budget ${money(f.estimated_cost)}`)}
      ${kpi(done ? 'Gross profit' : 'Projected profit', money(f.expected_profit), Number(f.expected_profit) >= 0 ? 'green' : 'red', done ? 'final' : `if costs land on budget`)}
      ${kpi(done ? 'Gross margin' : 'Projected margin', pct(f.expected_margin), marginTone(f.expected_margin), done ? '' : `estimated ${pct(f.estimated_margin)}`)}
      ${kpi('Hours', `${num(f.actual_hours)} / ${num(f.budgeted_hours)}`, hoursPct > 100 ? 'red' : '', 'actual / budgeted')}
      ${kpi('Complete', pct(p.percent_complete))}
    </div>

    <div class="tabs">${tabs.map(([k, l]) => html`<div class="tab ${k === projTab ? 'active' : ''}" data-act="projTab" data-tab="${k}">${l}</div>`)}</div>

    <section data-ptab="overview" ${projTab === 'overview' ? '' : raw('hidden')}>
      <div class="grid-2">
        <div class="card" id="proj-form"><div class="card-title">Project <button class="btn btn-gold btn-sm" data-act="saveProject" data-id="${id}">Save</button></div>
          <div class="form-row">${field('Status', select('status', PROJECT_STATUSES, p.status))}${field('% complete', input('percent_complete', p.percent_complete, 'type="number" min="0" max="100"'))}</div>
          <div class="form-row">${field('Start date', input('start_date', p.start_date, 'type="date"'))}${field('Est. end date', input('estimated_end_date', p.estimated_end_date, 'type="date"'))}</div>
          <div class="form-row">${field('Project manager', select('project_manager_id', [['', '—'], ...state.users.map((u) => [u.id, `${u.first_name} ${u.last_name}`])], p.project_manager_id))}
            ${field('Crew leader', select('crew_leader_id', [['', '—'], ...state.users.map((u) => [u.id, `${u.first_name} ${u.last_name}`])], p.crew_leader_id))}</div>
          ${field('Scope of work', textarea('scope_of_work', p.scope_of_work, 'style="min-height:120px"'))}
          ${field('Notes', textarea('notes', p.notes))}
          <div class="small muted">Actual start ${fmtDate(p.actual_start_date) || '—'} · actual end ${fmtDate(p.actual_end_date) || '—'} · deposit ${p.deposit_required ? (p.deposit_paid ? 'paid ✓' : money(p.deposit_amount) + ' unpaid') : 'not required'}</div>
        </div>
        <div>
          <div class="card" style="margin-bottom:14px"><div class="card-title">Pre-construction checklist <span class="muted">${pre.filter((x) => x.done_at).length}/${pre.length}</span></div>
            ${pre.length ? checks(pre) : html`<button class="btn btn-dark btn-sm" data-act="addChecklist" data-id="${id}" data-phase="Pre-Construction">Add default checklist</button>`}</div>
          <div class="card"><div class="card-title">Schedule</div>
            ${events.length ? events.map((e) => html`<div class="list-item"><div class="list-main"><div class="list-name">${e.title}</div><div class="list-sub">${e.type} · ${e.event_date ? fmtDate(e.event_date) + (e.start_time ? ' ' + e.start_time.slice(0, 5) : '') : 'not scheduled'}</div></div>${badge(e.status, e.status === 'Unscheduled' ? 'orange' : 'blue')}</div>`)
              : html`<div class="muted small">Nothing scheduled.</div>`}
            ${startEvt?.status === 'Unscheduled' ? html`<button class="btn btn-gold btn-sm" style="margin-top:8px" data-act="scheduleProject" data-id="${id}">Set start date</button>` : ''}</div>
        </div>
      </div>
    </section>

    <section data-ptab="finance" ${projTab === 'finance' ? '' : raw('hidden')}>
      <div class="grid-2">
        <div class="card"><div class="card-title">Job cost — estimated vs actual vs projected</div>
          <div class="cmp"><div class="h"></div><div class="h n">Estimated</div><div class="h n">Actual</div><div class="h n">Projected</div>
            ${row('Revenue', f.current_contract_value, f.current_contract_value, f.current_contract_value)}
            ${row('Direct labor', est.labor, f.direct_labor, null)}${row('Materials', est.material, f.materials, null)}
            ${row('Subcontractors', est.sub, f.subcontractors, null)}
            ${row('Delivery / disposal / equipment / other', est.other, Number(f.delivery) + Number(f.disposal) + Number(f.equipment) + Number(f.other_direct), null)}
            ${row('Direct cost', f.estimated_cost, f.direct_cost, f.projected_cost, 'gold')}
            ${row('Gross profit', f.estimated_profit, f.gross_profit, f.projected_profit, 'green')}
            <div>Margin</div><div class="n">${pct(f.estimated_margin)}</div><div class="n">${pct(f.gross_margin)}</div>
            <div class="n">${pct(Number(f.current_contract_value) ? Math.round(Number(f.projected_profit) / Number(f.current_contract_value) * 1000) / 10 : null)}</div>
          </div>
          <div class="hint">Labor = hours × loaded rate, including the owner's own hours — so the margin answers "is this job profitable if someone else does the work?"</div>
        </div>
        <div class="card"><div class="card-title">Invoices & payments <span><button class="btn btn-dark btn-sm" data-act="invoiceFor" data-project="${id}">+ Invoice</button></span></div>
          <div class="profit-row"><span class="lbl">Contract value</span><span>${money(f.current_contract_value)}</span></div>
          <div class="profit-row"><span class="lbl">Invoiced</span><span>${money(invoiced)}</span></div>
          <div class="profit-row"><span class="lbl">Not yet invoiced</span><span class="orange">${money(Number(f.current_contract_value) - invoiced)}</span></div>
          <div class="profit-row total"><span>Collected</span><span class="green">${money(f.collected)}</span></div>
          ${invoices.map((i) => html`<div class="list-item"><div class="list-main"><div class="list-name">${i.invoice_number} · ${i.type}</div>
            <div class="list-sub">${money(i.total)} · paid ${money(i.amount_paid)} · due ${fmtDate(i.due_date) || '—'}</div></div>
            ${badge(i.is_overdue ? 'Overdue' : i.status)}
            ${Number(i.balance_due) > 0 && i.status !== 'Void' ? html`<button class="btn btn-gold btn-xs" data-act="payInvoice" data-id="${i.id}">Record payment</button>` : ''}</div>`)}
          ${payments.length ? html`<div class="card-title" style="margin-top:12px">Payments</div>${payments.map((pm) => html`<div class="profit-row"><span class="lbl">${fmtDate(pm.payment_date)} · ${pm.method} · ${pm.kind || ''}${pm.voided_at ? ' · VOID' : ''}</span><span class="${pm.voided_at ? 'muted' : 'green'}">${money(pm.amount, true)}</span></div>`)}` : ''}
        </div>
      </div>
    </section>

    <section data-ptab="tasks" ${projTab === 'tasks' ? '' : raw('hidden')}><div class="card">
      <div class="card-title">Open tasks <button class="btn btn-dark btn-sm" data-act="newTask" data-project="${id}" data-customer="${p.customer_id}">+ Task</button></div>
      ${taskList(tasks)}
      ${doneTasks.length ? html`<div class="card-title" style="margin-top:14px">Recently completed</div>${taskList(doneTasks)}` : ''}</div></section>

    <section data-ptab="materials" ${projTab === 'materials' ? '' : raw('hidden')}><div class="card" style="padding:0">
      <div class="card-title" style="padding:14px 14px 0">Materials <button class="btn btn-dark btn-sm" data-act="addMaterial" data-project="${id}">+ Material</button></div>
      <div class="table-wrap"><table><thead><tr><th>Material</th><th>Qty</th><th>Vendor</th><th class="num">Est. cost</th><th class="num">Actual</th><th>Expected</th><th>Status</th></tr></thead>
      <tbody>${materials.map((m) => html`<tr><td>${m.name}${m.notes ? html`<div class="list-sub">${m.notes}</div>` : ''}</td><td>${num(m.quantity)} ${m.unit || ''}</td><td class="muted">${m.vendor || ''}</td>
        <td class="num">${money(m.estimated_cost)}</td><td class="num">${m.actual_cost == null ? '—' : money(m.actual_cost)}</td><td class="small">${fmtDate(m.expected_date)}</td>
        <td>${select('status', MAT_STATUSES, m.status, `data-change="materialStatus" data-id="${m.id}" style="width:auto;padding:4px 8px;font-size:12px"`)}</td></tr>`)}</tbody></table></div>
      ${materials.length ? '' : html`<div class="hint" style="padding:0 14px 14px">Track what's needed, ordered and received. Record the actual spend as an expense so it lands in job cost.</div>`}</div></section>

    <section data-ptab="labor" ${projTab === 'labor' ? '' : raw('hidden')}><div class="grid-2">
      <div class="card"><div class="card-title">Time <button class="btn btn-dark btn-sm" data-act="logTimeFor" data-project="${id}">+ Hours</button></div>
        <div class="progress" style="margin-bottom:10px"><div class="progress-bar ${hoursPct > 100 ? 'red' : ''}" style="width:${Math.min(hoursPct, 100)}%"></div></div>
        ${time.map((t) => html`<div class="profit-row"><span class="lbl">${fmtDate(t.entry_date)} · ${userName(t.user_id)} · ${t.work_category}${t.notes ? ' — ' + t.notes : ''}</span><span>${num(t.hours, 2)} h · ${money(t.labor_cost)}</span></div>`)}
        ${time.length ? '' : html`<div class="muted small">No hours logged.</div>`}</div>
      <div class="card"><div class="card-title">Expenses <button class="btn btn-dark btn-sm" data-act="expenseFor" data-project="${id}">+ Expense</button></div>
        ${expenses.map((e) => html`<div class="profit-row"><span class="lbl">${fmtDate(e.expense_date)} · ${e.category} · ${e.vendor || ''}${e.description ? ' — ' + e.description : ''}</span><span class="red">${money(e.total, true)}</span></div>`)}
        ${expenses.length ? '' : html`<div class="muted small">No expenses logged.</div>`}</div>
    </div></section>

    <section data-ptab="closeout" ${projTab === 'closeout' ? '' : raw('hidden')}><div class="card">
      <div class="card-title">Closeout checklist <span class="muted">${close.filter((x) => x.done_at).length}/${close.length}</span></div>
      ${close.length ? checks(close) : html`<div class="muted small" style="margin-bottom:8px">Created automatically when the project is marked Completed.</div>
        <button class="btn btn-dark btn-sm" data-act="addChecklist" data-id="${id}" data-phase="Closeout">Add closeout checklist now</button>`}
      ${Number(f.balance) > 0 && ['Completed', 'Punch List', 'QC'].includes(p.status) ? html`<button class="btn btn-gold btn-sm" style="margin-top:12px" data-act="finalInvoice" data-project="${id}">Create final invoice for ${money(Number(f.current_contract_value) - invoiced)}</button>` : ''}
    </div></section>

    <section data-ptab="activity" ${projTab === 'activity' ? '' : raw('hidden')}><div class="card">
      <div class="card-title">Communication <button class="btn btn-dark btn-sm" data-act="logContact" data-project="${id}" data-customer="${p.customer_id}">Log contact</button></div>${tl}</div></section>`;
  },
});

register({
  projFilter: ({ f }) => { projFilter = f; refresh(); },
  projTab: ({ tab }, el) => {
    projTab = tab;
    document.querySelectorAll('[data-ptab]').forEach((s) => { s.hidden = s.dataset.ptab !== tab; });
    el.parentElement.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t === el));
  },
  saveProject: async ({ id }) => {
    const f = readForm(document.getElementById('proj-form'));
    const before = await db.get('projects', id);
    await db.update('projects', id, f);
    toast(f.status !== before.status ? `Status → ${f.status}${f.status === 'Completed' ? ' — closeout checklist & tasks created' : ''}` : 'Project saved');
    refresh();
  },
  toggleCheck: async ({ id }, el) => {
    await db.update('project_checklist_items', id, { done_at: el.checked ? new Date().toISOString() : null, done_by: el.checked ? state.me.id : null });
    el.closest('.check-item').classList.toggle('done', el.checked);
  },
  addChecklist: async ({ id, phase }) => {
    const items = setting(phase === 'Closeout' ? 'closeout_checklist' : 'default_project_checklist', []);
    await db.insertMany('project_checklist_items', items.map((label, i) => ({ project_id: id, phase, label, sort_order: i })));
    refresh();
  },
  materialStatus: async ({ id }, el) => {
    const d = today(); const patch = { status: el.value };
    if (el.value === 'Ordered') patch.ordered_date = d;
    if (el.value === 'Received') patch.received_date = d;
    if (el.value === 'Installed') patch.installed_date = d;
    await db.update('materials', id, patch); toast(`Material ${el.value.toLowerCase()}`);
  },
  addMaterial: ({ project }) => modal('Add material', html`
    ${field('Material', input('name', '', 'placeholder="Crown molding 3-5/8 in"'))}
    <div class="form-row-3">${field('Quantity', input('quantity', 1, 'type="number" step="any"'))}${field('Unit', input('unit', '', 'placeholder="pcs, sq ft…"'))}
      ${field('Estimated cost', input('estimated_cost', '', 'type="number" step="any"'))}</div>
    <div class="form-row">${field('Vendor', input('vendor', '', 'placeholder="Home Depot"'))}${field('Expected date', input('expected_date', '', 'type="date"'))}</div>
    ${field('Status', select('status', MAT_STATUSES, 'Needed'))}${field('Notes', input('notes'))}`,
  [{ label: 'Cancel' }, { label: 'Add', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body); need(f, { name: 'Material' });
    await db.insert('materials', { ...f, project_id: project, quantity: f.quantity ?? 1, estimated_cost: f.estimated_cost ?? 0 });
    toast('Material added'); closeModal(); refresh();
  } }]),
  logTimeFor: ({ project }) => openLogTime({ project_id: project }),
  expenseFor: ({ project }) => openExpenseForm({ project_id: project }),
  invoiceFor: ({ project }) => openInvoiceForm({ project_id: project }),
  finalInvoice: ({ project }) => openInvoiceForm({ project_id: project, type: 'Final' }),
  payInvoice: ({ id }) => openPaymentForm(id),
  scheduleProject: async ({ id }) => {
    const p = await db.get('projects', id);
    modal('Schedule project start', html`
      ${p.status === 'Pending Deposit' ? html`<div class="toast toast-error" style="max-width:none;margin-bottom:12px">⚠ The deposit is unpaid. Scheduling before the deposit is a payment risk.</div>` : ''}
      <div class="form-row">${field('Start date', input('start_date', p.start_date || addDays(today(), 7), 'type="date"'))}${field('Start time', input('start_time', '07:30', 'type="time"'))}</div>
      ${field('Estimated end date', input('estimated_end_date', p.estimated_end_date, 'type="date"'))}`,
    [{ label: 'Cancel' }, { label: 'Schedule', cls: 'btn-gold', onClick: async (body) => {
      const f = readForm(body); need(f, { start_date: 'Start date' });
      await db.update('projects', id, { start_date: f.start_date, estimated_end_date: f.estimated_end_date,
        status: p.status === 'Ready to Schedule' ? 'Scheduled' : p.status });
      const evs = await db.list('calendar_events', { eq: { project_id: id, type: 'Project Start' } });
      const evPatch = { event_date: f.start_date, start_time: f.start_time, status: 'Scheduled', title: `Project start — ${p.project_name}` };
      if (evs.length) await db.update('calendar_events', evs[0].id, evPatch);
      else await db.insert('calendar_events', { ...evPatch, type: 'Project Start', project_id: id, customer_id: p.customer_id });
      toast('Project scheduled'); closeModal(); refresh();
    } }]);
  },
  newProject: async () => {
    const { list } = await customersById();
    modal('Manual project', html`<div class="hint" style="margin-bottom:12px">Normally projects are created by approving a proposal. Use this only for work that skipped the sales process.</div>
      ${field('Customer', select('customer_id', [['', 'Select…'], ...list.map((c) => [c.id, custName(c)])], ''))}
      ${field('Project name', input('project_name'))}
      <div class="form-row">${field('Service', select('service_category', setting('service_types', []), ''))}${field('Contract value', input('contract_value', '', 'type="number" step="any"'))}</div>
      ${field('Scope', textarea('scope_of_work'))}`,
    [{ label: 'Cancel' }, { label: 'Create', cls: 'btn-gold', onClick: async (body) => {
      const f = readForm(body); need(f, { customer_id: 'Customer', project_name: 'Project name' });
      const p = await db.insert('projects', { ...f, contract_value: f.contract_value || 0, status: 'Ready to Schedule', project_manager_id: state.me.id });
      closeModal(); go('project/' + p.id);
    } }]);
  },
});

// ── TASKS ──────────────────────────────────────────────────────────
let taskScope = 'all';
page('tasks', {
  title: 'Tasks',
  async render() {
    const open = await db.list('tasks', { in: { status: ['Pending', 'In Progress'] }, is: ['archived_at'], order: 'due_at' });
    const done = await db.list('tasks', { eq: { status: 'Completed' }, order: 'completed_at desc', limit: 15 });
    const mine = (t) => taskScope === 'all' || t.assigned_to === state.me.id;
    const eod = new Date(); eod.setHours(23, 59, 59, 999);
    const sow = new Date(eod); sow.setDate(sow.getDate() + 7);
    const groups = [
      ['Overdue', open.filter((t) => mine(t) && t.due_at && new Date(t.due_at) < new Date())],
      ['Today', open.filter((t) => mine(t) && t.due_at && new Date(t.due_at) >= new Date() && new Date(t.due_at) <= eod)],
      ['Next 7 days', open.filter((t) => mine(t) && t.due_at && new Date(t.due_at) > eod && new Date(t.due_at) <= sow)],
      ['Later', open.filter((t) => mine(t) && t.due_at && new Date(t.due_at) > sow)],
      ['No due date', open.filter((t) => mine(t) && !t.due_at)],
    ];
    return html`<div class="toolbar"><div class="seg">${[['all', 'Everyone'], ['mine', 'Mine']].map(([k, l]) => html`<button class="${taskScope === k ? 'on' : ''}" data-act="taskScope" data-s="${k}">${l}</button>`)}</div>
      <span class="grow muted small">${open.length} open · ⚡ = created by automation</span><button class="btn btn-gold" data-act="newTask">+ New task</button></div>
    <div class="grid-2">${groups.filter(([, t]) => t.length).map(([g, t]) => html`<div class="card"><div class="card-title"><span class="${g === 'Overdue' ? 'red' : ''}">${g}</span><span>${t.length}</span></div>${taskList(t)}</div>`)}
      <div class="card"><div class="card-title">Recently completed</div>${taskList(done)}</div></div>`;
  },
});
register({ taskScope: ({ s }) => { taskScope = s; refresh(); } });

// ── CALENDAR ───────────────────────────────────────────────────────
let calY = new Date().getFullYear(); let calM = new Date().getMonth();
const EVENT_TYPES = ['Lead Call', 'Site Visit', 'Estimate', 'Customer Meeting', 'Material Pickup', 'Project Start', 'Project Work', 'Inspection', 'Final Walkthrough', 'QC', 'Other'];
page('calendar', {
  title: 'Calendar',
  async render() {
    const first = new Date(calY, calM, 1); const days = new Date(calY, calM + 1, 0).getDate();
    const iso = (d) => `${calY}-${String(calM + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    const [events, unscheduled] = await Promise.all([
      db.list('calendar_events', { gte: { event_date: iso(1) }, lte: { event_date: iso(days) }, neq: { status: 'Cancelled' }, order: ['event_date', 'start_time'] }),
      db.list('calendar_events', { eq: { status: 'Unscheduled' } }),
    ]);
    const t = today();
    const cells = [...Array(first.getDay())].map(() => html`<div class="cal-day other"></div>`);
    for (let d = 1; d <= days; d++) {
      const ev = events.filter((e) => e.event_date === iso(d));
      cells.push(html`<div class="cal-day ${iso(d) === t ? 'today' : ''}"><div class="cal-num">${d}</div>
        ${ev.map((e) => html`<div class="cal-event" title="${e.type}: ${e.title}" data-act="${e.project_id ? 'go' : 'noop'}" data-to="project/${e.project_id || ''}">${e.start_time ? e.start_time.slice(0, 5) + ' ' : ''}${e.title}</div>`)}</div>`);
    }
    return html`
    ${unscheduled.length ? html`<div class="card" style="margin-bottom:14px"><div class="card-title orange">Needs scheduling (${unscheduled.length})</div>
      ${unscheduled.map((e) => html`<div class="list-item"><div class="list-main"><div class="list-name">${e.title}</div><div class="list-sub">${e.type}</div></div>
        ${e.project_id ? html`<button class="btn btn-gold btn-xs" data-act="scheduleProject" data-id="${e.project_id}">Schedule</button>` : ''}</div>`)}</div>` : ''}
    <div class="toolbar"><button class="btn btn-dark" data-act="calMove" data-n="-1">←</button>
      <b style="min-width:150px;text-align:center">${first.toLocaleDateString('en-US', { month: 'long', year: 'numeric' })}</b>
      <button class="btn btn-dark" data-act="calMove" data-n="1">→</button><span class="grow"></span>
      <button class="btn btn-gold" data-act="newEvent">+ Event</button></div>
    <div class="cal-grid" style="margin-bottom:4px">${['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map((d) => html`<div class="cal-header">${d}</div>`)}</div>
    <div class="cal-grid">${cells}</div>`;
  },
});
register({
  noop: () => {},
  calMove: ({ n }) => { calM += Number(n); if (calM < 0) { calM = 11; calY--; } if (calM > 11) { calM = 0; calY++; } refresh(); },
  newEvent: async () => {
    const projects = await db.list('projects', { is: ['archived_at'], in: { status: ACTIVE } });
    modal('New event', html`${field('Title', input('title'))}
      <div class="form-row">${field('Type', select('type', EVENT_TYPES, 'Other'))}${field('Project', select('project_id', [['', 'None'], ...projects.map((p) => [p.id, p.project_name])], ''))}</div>
      <div class="form-row-3">${field('Date', input('event_date', today(), 'type="date"'))}${field('Start', input('start_time', '', 'type="time"'))}${field('End', input('end_time', '', 'type="time"'))}</div>
      ${field('Location', input('location'))}${field('Notes', textarea('notes'))}`,
    [{ label: 'Cancel' }, { label: 'Add', cls: 'btn-gold', onClick: async (body) => {
      const f = readForm(body); need(f, { title: 'Title', event_date: 'Date' });
      await db.insert('calendar_events', f); toast('Event added'); closeModal(); refresh();
    } }]);
  },
});
