// Finance: invoices + AR, payments, expenses, time & labor.
import { db, page, register, refresh, go, state, setting, refreshBadges } from '../app.js';
import { html, raw, money, num, fmtDate, badge, modal, closeModal, toast, readForm, need, field, input, textarea, select,
         empty, kpi, today, addDays, periodRange, confirmDialog, toCSV, downloadFile } from '../ui.js';
import { custName, customersById, userName } from './common.js';

const EXPENSE_CATS = ['Materials', 'Labor', 'Subcontractor', 'Delivery', 'Disposal', 'Equipment', 'Fuel', 'Tools', 'Permit', 'Other Direct Cost', 'Overhead'];
const WORK_CATS = [['Field', 'Field — on the tools'], ['Sales', 'Sales — leads, estimates, site visits'], ['Management', 'Management — planning, crew, QC'], ['Admin', 'Admin — books, email, errands'], ['Travel', 'Travel']];
const activeProjects = () => db.list('projects', { is: ['archived_at'], in: { status: ['Pending Deposit', 'Ready to Schedule', 'Scheduled', 'Pre-Construction', 'In Progress', 'On Hold', 'Punch List', 'QC', 'Completed'] }, order: 'project_number desc' });

// ── INVOICES ───────────────────────────────────────────────────────
let invFilter = 'open';
page('invoices', {
  title: 'Invoices',
  async render() {
    const rows = await db.list('v_invoices', { order: 'issue_date desc' });
    const open = rows.filter((i) => ['Sent', 'Partially Paid'].includes(i.status));
    const shown = invFilter === 'open' ? open : invFilter === 'overdue' ? open.filter((i) => i.is_overdue) : rows;
    const bucket = (lo, hi) => open.filter((i) => i.days_overdue >= lo && i.days_overdue <= hi).reduce((a, i) => a + Number(i.balance_due), 0);
    return html`<div class="kpi-grid">
      ${kpi('Accounts receivable', money(open.reduce((a, i) => a + Number(i.balance_due), 0)), 'gold')}
      ${kpi('Current', money(bucket(0, 0)))}${kpi('1–30 days', money(bucket(1, 30)), bucket(1, 30) ? 'orange' : '')}
      ${kpi('31–60', money(bucket(31, 60)), bucket(31, 60) ? 'red' : '')}${kpi('61–90', money(bucket(61, 90)), bucket(61, 90) ? 'red' : '')}
      ${kpi('90+', money(bucket(91, 1e6)), bucket(91, 1e6) ? 'red' : '')}</div>
    <div class="toolbar"><div class="seg">${[['open', 'Open'], ['overdue', 'Overdue'], ['all', 'All']].map(([k, l]) => html`<button class="${invFilter === k ? 'on' : ''}" data-act="invFilter" data-f="${k}">${l}</button>`)}</div>
      <span class="grow"></span><button class="btn btn-gold" data-act="newInvoice">+ New invoice</button></div>
    <div class="card" style="padding:0"><div class="table-wrap"><table>
      <thead><tr><th>#</th><th>Customer</th><th>Project</th><th>Type</th><th class="num">Total</th><th class="num">Paid</th><th class="num">Balance</th><th>Status</th><th>Due</th><th></th></tr></thead>
      <tbody>${shown.map((i) => html`<tr>
        <td class="muted small nowrap">${i.invoice_number}</td><td>${i.customer_name}</td>
        <td class="small">${i.project_id ? html`<a href="#/project/${i.project_id}">${i.project_name}</a>` : '—'}</td><td class="small">${i.type}</td>
        <td class="num">${money(i.total, true)}</td><td class="num green">${money(i.amount_paid, true)}</td><td class="num gold">${money(i.balance_due, true)}</td>
        <td>${badge(i.is_overdue ? 'Overdue' : i.status)}${i.is_overdue ? html` <span class="small red">${i.days_overdue}d</span>` : ''}</td>
        <td class="small muted">${fmtDate(i.due_date) || '—'}</td>
        <td class="nowrap">${Number(i.balance_due) > 0 && i.status !== 'Void' ? html`<button class="btn btn-gold btn-xs" data-act="payInvoice" data-id="${i.id}">Record payment</button>` : ''}
          ${i.status === 'Draft' ? html`<button class="btn btn-dark btn-xs" data-act="invoiceSent" data-id="${i.id}">Mark sent</button>` : ''}
          ${Number(i.amount_paid) === 0 && i.status !== 'Void' ? html`<button class="btn btn-link" data-act="voidInvoice" data-id="${i.id}">Void</button>` : ''}</td></tr>`)}</tbody></table></div>
      ${shown.length ? '' : empty('▤', invFilter === 'all' ? 'No invoices yet' : 'Nothing outstanding 🎉')}</div>`;
  },
});

export async function openInvoiceForm(pre = {}) {
  const [{ list, by }, projects] = await Promise.all([customersById(), activeProjects()]);
  let amount = pre.subtotal ?? '';
  let customer = pre.customer_id ?? '';
  if (pre.project_id) {
    const [f] = await db.list('v_project_profit', { eq: { project_id: pre.project_id } });
    const p = projects.find((x) => x.id === pre.project_id) || await db.get('projects', pre.project_id);
    customer = p.customer_id;
    if (pre.type === 'Final' && f) amount = Math.max(0, Number(f.current_contract_value) - Number(f.invoiced));
  }
  const terms = setting('payment_terms', {}).default_days ?? 7;
  modal('New invoice', html`
    <div class="form-row">${field('Project', select('project_id', [['', 'No project'], ...projects.map((p) => [p.id, `${p.project_number} · ${p.project_name}`])], pre.project_id))}
      ${field('Customer', select('customer_id', [['', 'Select…'], ...list.map((c) => [c.id, custName(c)])], customer))}</div>
    <div class="form-row-3">${field('Type', select('type', ['Progress', 'Final', 'Deposit', 'Change Order', 'Other'], pre.type || 'Progress'))}
      ${field('Issue date', input('issue_date', today(), 'type="date"'))}${field('Due date', input('due_date', addDays(today(), terms), 'type="date"'))}</div>
    <div class="form-row-3">${field('Amount', input('subtotal', amount, 'type="number" step="0.01"'))}${field('Discount', input('discount', 0, 'type="number" step="0.01"'))}
      ${field('Tax', input('tax', 0, 'type="number" step="0.01"'))}</div>
    ${field('Description (shown to customer)', input('description', pre.type === 'Final' ? 'Final payment — balance of contract' : ''))}
    ${field('Status', select('status', [['Sent', 'Sent to customer'], ['Draft', 'Draft — not sent yet']], 'Sent'))}
    ${field('Internal notes', textarea('notes'))}
    <div class="hint">Invoice numbers are assigned by the server and never reused.</div>`,
  [{ label: 'Cancel' }, { label: 'Create invoice', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body);
    if (f.project_id && !f.customer_id) f.customer_id = projects.find((p) => p.id === f.project_id)?.customer_id;
    need(f, { customer_id: 'Customer', subtotal: 'Amount' });
    const inv = await db.insert('invoices', { ...f, discount: f.discount || 0, tax: f.tax || 0, payment_terms: `Net ${terms}` });
    toast(`Invoice ${inv.invoice_number} created`); closeModal(); refresh(); refreshBadges();
  } }]);
}

export async function openPaymentForm(invoiceId) {
  const [inv] = await db.list('v_invoices', { eq: { id: invoiceId } });
  const bal = Number(inv.balance_due);
  modal(`Record payment — ${inv.invoice_number}`, html`
    <div class="profit-row"><span class="lbl">${inv.customer_name} · ${inv.type}</span><span>Total ${money(inv.total, true)}</span></div>
    <div class="profit-row total" style="margin-bottom:14px"><span>Balance due</span><span class="gold">${money(bal, true)}</span></div>
    <div class="form-row">${field('Amount received', input('amount', bal.toFixed(2), 'type="number" step="0.01"'))}${field('Date', input('date', today(), 'type="date"'))}</div>
    <div class="form-row">${field('Method', select('method', setting('payment_methods', ['Zelle', 'Cash', 'Check']), 'Zelle'))}${field('Reference', input('reference', '', 'placeholder="Check #, Zelle confirmation…"'))}</div>
    ${field('Notes', input('notes'))}
    <label class="check"><input type="checkbox" name="overpayment"> This is an intentional overpayment (more than the balance)</label>
    <div class="hint">Payments over the balance are refused unless marked as an overpayment.${inv.type === 'Deposit' ? ' Paying the deposit in full moves the project to Ready to Schedule.' : inv.type === 'Final' ? ' Paying in full creates a review-request task.' : ''}</div>`,
  [{ label: 'Cancel' }, { label: 'Record payment', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body); need(f, { amount: 'Amount' });
    const r = await db.rpc('record_payment', { p_invoice_id: invoiceId, p_amount: f.amount, p_method: f.method, p_date: f.date,
      p_reference: f.reference, p_notes: f.notes, p_is_overpayment: f.overpayment });
    toast(r.invoice_status === 'Paid' ? `${inv.invoice_number} paid in full` : `Payment recorded — ${money(r.balance_due, true)} remaining`);
    closeModal(); refresh(); refreshBadges();
  } }]);
}

register({
  invFilter: ({ f }) => { invFilter = f; refresh(); },
  newInvoice: () => openInvoiceForm(),
  payInvoice: ({ id }) => openPaymentForm(id),
  invoiceSent: async ({ id }) => { await db.update('invoices', id, { status: 'Sent' }); toast('Marked sent'); refresh(); },
  voidInvoice: async ({ id }) => {
    if (!(await confirmDialog('Void invoice?', 'The invoice stays on record (numbers are never reused) but no longer counts toward AR.', 'Void', 'btn-red'))) return;
    await db.update('invoices', id, { status: 'Void' }); toast('Invoice voided'); refresh();
  },
});

// ── PAYMENTS ───────────────────────────────────────────────────────
page('payments', {
  title: 'Payments',
  async render() {
    const [rows, invoices, { by }] = await Promise.all([db.list('payments', { order: ['payment_date desc', 'created_at desc'] }),
      db.list('invoices', {}), customersById()]);
    const inv = Object.fromEntries(invoices.map((i) => [i.id, i]));
    const [from] = periodRange('month');
    const live = rows.filter((p) => !p.voided_at);
    return html`<div class="kpi-grid">${kpi('Collected this month', money(live.filter((p) => p.payment_date >= from).reduce((a, p) => a + Number(p.amount), 0)), 'green')}
      ${kpi('Collected all time', money(live.reduce((a, p) => a + Number(p.amount), 0)))}</div>
    <div class="card" style="padding:0"><div class="table-wrap"><table>
      <thead><tr><th>Date</th><th>Customer</th><th>Invoice</th><th>Kind</th><th>Method</th><th>Reference</th><th class="num">Amount</th><th></th></tr></thead>
      <tbody>${rows.map((p) => html`<tr style="${p.voided_at ? 'opacity:.45' : ''}">
        <td class="small muted">${fmtDate(p.payment_date)}</td><td>${custName(by[p.customer_id])}</td><td class="small">${inv[p.invoice_id]?.invoice_number}</td>
        <td class="small">${p.kind || ''}</td><td class="small">${p.method}</td><td class="small muted">${p.reference || ''}${p.voided_at ? ` · VOID: ${p.void_reason}` : ''}</td>
        <td class="num ${p.voided_at ? '' : 'green'}">${money(p.amount, true)}</td>
        <td>${p.voided_at ? '' : html`<button class="btn btn-link" data-act="voidPayment" data-id="${p.id}">Void</button>`}</td></tr>`)}</tbody></table></div>
      ${rows.length ? '' : empty('◈', 'No payments recorded')}</div>`;
  },
});
register({
  voidPayment: ({ id }) => modal('Void payment', html`${field('Reason (bounced check, entered twice…)', input('reason'))}
    <div class="hint">Payments are never deleted. Voiding keeps the record and re-opens the invoice balance.</div>`,
  [{ label: 'Cancel' }, { label: 'Void payment', cls: 'btn-red', onClick: async (body) => {
    const f = readForm(body); need(f, { reason: 'Reason' });
    await db.rpc('void_payment', { p_payment_id: id, p_reason: f.reason }); toast('Payment voided'); closeModal(); refresh();
  } }]),
});

// ── EXPENSES ───────────────────────────────────────────────────────
page('expenses', {
  title: 'Expenses',
  async render() {
    const [rows, projects] = await Promise.all([db.list('expenses', { is: ['archived_at'], order: ['expense_date desc', 'created_at desc'], limit: 500 }), db.list('projects', {})]);
    const pn = Object.fromEntries(projects.map((p) => [p.id, p.project_name]));
    const [from] = periodRange('month');
    const month = rows.filter((e) => e.expense_date >= from);
    const byCat = EXPENSE_CATS.map((c) => [c, month.filter((e) => e.category === c).reduce((a, e) => a + Number(e.total), 0)]).filter(([, v]) => v);
    return html`<div class="toolbar"><span class="grow muted small">This month: <b class="red">${money(month.reduce((a, e) => a + Number(e.total), 0))}</b>
      ${byCat.map(([c, v]) => ` · ${c} ${money(v)}`).join('')}</span>
      <button class="btn btn-dark" data-act="exportExpenses">Export CSV</button><button class="btn btn-gold" data-act="newExpense">+ Log expense</button></div>
    <div class="card" style="padding:0"><div class="table-wrap"><table>
      <thead><tr><th>Date</th><th>Project</th><th>Category</th><th>Vendor</th><th>Description</th><th class="num">Amount</th><th></th></tr></thead>
      <tbody>${rows.map((e) => html`<tr><td class="small muted">${fmtDate(e.expense_date)}</td>
        <td class="small">${e.project_id ? html`<a href="#/project/${e.project_id}">${pn[e.project_id]}</a>` : html`<span class="muted">Overhead / none</span>`}</td>
        <td>${badge(e.category, 'muted')}</td><td class="small">${e.vendor || ''}</td><td class="small">${e.description || ''}</td>
        <td class="num red">${money(e.total, true)}</td><td><button class="btn btn-link" data-act="archiveExpense" data-id="${e.id}">Remove</button></td></tr>`)}</tbody></table></div>
      ${rows.length ? '' : empty('▥', 'No expenses logged')}</div>
    <div class="hint" style="margin-top:8px">Receipt photo upload arrives in P1 (Supabase Storage). Until then, note the receipt location in the description.</div>`;
  },
});

export async function openExpenseForm(pre = {}) {
  const projects = await activeProjects();
  modal('Log expense', html`
    <div class="form-row">${field('Date', input('expense_date', today(), 'type="date"'))}${field('Category', select('category', EXPENSE_CATS, pre.category || 'Materials'))}</div>
    ${field('Project (job cost)', select('project_id', [['', 'No project — overhead'], ...projects.map((p) => [p.id, `${p.project_number} · ${p.project_name}`])], pre.project_id))}
    <div class="form-row-3">${field('Amount (pre-tax)', input('amount', '', 'type="number" step="0.01"'))}${field('Tax', input('tax', 0, 'type="number" step="0.01"'))}
      ${field('Paid with', select('payment_method', ['Card', 'Cash', 'Check', 'Zelle', 'Bank Transfer', 'Account'], 'Card'))}</div>
    <div class="form-row">${field('Vendor', input('vendor', '', 'placeholder="Home Depot"'))}${field('Description', input('description', '', 'placeholder="What was purchased"'))}</div>
    <label class="check"><input type="checkbox" name="billable"> Billable to customer</label>`,
  [{ label: 'Cancel' }, { label: 'Save expense', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body); need(f, { amount: 'Amount' });
    await db.insert('expenses', { ...f, tax: f.tax || 0 });
    toast(f.project_id ? 'Expense logged to job cost' : 'Expense logged as company overhead (no project)'); closeModal(); refresh();
  } }]);
}
register({
  newExpense: () => openExpenseForm(),
  archiveExpense: async ({ id }) => {
    if (!(await confirmDialog('Remove expense?', 'It will be archived (kept in the audit log) and removed from job cost.', 'Remove', 'btn-red'))) return;
    await db.update('expenses', id, { archived_at: new Date().toISOString() }); toast('Expense removed'); refresh();
  },
  exportExpenses: async () => downloadFile(`goldex-expenses-${today()}.csv`, toCSV(await db.list('expenses', { is: ['archived_at'], order: 'expense_date' })), 'text/csv'),
});

// ── TIME & LABOR ───────────────────────────────────────────────────
page('time', {
  title: 'Time & Labor',
  async render() {
    const [from, to] = periodRange('month');
    const [rows, projects] = await Promise.all([db.list('time_entries', { is: ['archived_at'], order: ['entry_date desc', 'created_at desc'], limit: 300 }), db.list('projects', {})]);
    const pn = Object.fromEntries(projects.map((p) => [p.id, p.project_name]));
    const owner = state.users.find((u) => u.role === 'owner');
    const mine = rows.filter((r) => r.user_id === owner?.id && r.entry_date >= from && r.entry_date <= to);
    const h = (c) => mine.filter((r) => r.work_category === c).reduce((a, r) => a + Number(r.hours), 0);
    const goal = 80;
    return html`<div class="grid-2">
      <div class="card"><div class="card-title">Owner field hours — this month</div>
        <div style="display:flex;align-items:baseline;gap:10px"><span class="kpi-val gold" style="font-size:44px">${num(h('Field'))}</span><span class="muted">of ${goal} h goal → 0</span></div>
        <div class="progress" style="margin:10px 0"><div class="progress-bar ${h('Field') > goal ? 'red' : ''}" style="width:${Math.min(h('Field') / 160 * 100, 100)}%"></div></div>
        <div class="legend"><span>Sales ${num(h('Sales'))}h</span><span>Management ${num(h('Management'))}h</span><span>Admin ${num(h('Admin'))}h</span><span>Travel ${num(h('Travel'))}h</span></div></div>
      <div class="card"><div class="card-title">Log time</div>
        <p class="muted small" style="margin-bottom:12px">Every hour on a project is costed at the loaded labor rate (Settings → Labor). The owner's field hours are costed like an employee's, so job margins stay honest.</p>
        <button class="btn btn-gold btn-block" data-act="logTime">+ Log hours</button></div></div>
    <div class="card" style="padding:0"><div class="table-wrap"><table>
      <thead><tr><th>Date</th><th>Who</th><th>Project</th><th>Category</th><th>Start–end</th><th class="num">Hours</th><th class="num">Labor cost</th><th>Notes</th><th></th></tr></thead>
      <tbody>${rows.map((t) => html`<tr><td class="small muted">${fmtDate(t.entry_date)}</td><td class="small">${userName(t.user_id)}</td>
        <td class="small">${t.project_id ? html`<a href="#/project/${t.project_id}">${pn[t.project_id]}</a>` : '—'}</td><td>${badge(t.work_category, t.work_category === 'Field' ? 'gold' : 'muted')}</td>
        <td class="small muted">${t.start_time ? `${t.start_time}–${t.end_time}` : ''}</td><td class="num">${num(t.hours, 2)}</td><td class="num">${money(t.labor_cost)}</td>
        <td class="small muted">${t.notes || ''}</td><td><button class="btn btn-link" data-act="archiveTime" data-id="${t.id}">Remove</button></td></tr>`)}</tbody></table></div>
      ${rows.length ? '' : empty('◷', 'No time logged')}</div>`;
  },
});

export async function openLogTime(pre = {}) {
  const projects = await activeProjects();
  modal('Log hours', html`
    <div class="form-row">${field('Date', input('entry_date', today(), 'type="date"'))}
      ${field('Who', select('user_id', state.users.map((u) => [u.id, `${u.first_name} ${u.last_name}`]), state.me.id))}</div>
    ${field('Project', select('project_id', [['', 'No project (admin / sales / management)'], ...projects.map((p) => [p.id, `${p.project_number} · ${p.project_name}`])], pre.project_id))}
    ${field('Category', select('work_category', WORK_CATS, pre.project_id ? 'Field' : 'Admin'))}
    <div class="form-row-3">${field('Start', input('start_time', '07:00', 'type="time"'))}${field('End', input('end_time', '15:30', 'type="time"'))}${field('Break (min)', input('break_minutes', 30, 'type="number"'))}</div>
    ${field('…or total hours (leave start/end blank)', input('hours', '', 'type="number" step="0.25"'))}
    ${field('What was done', input('notes'))}`,
  [{ label: 'Cancel' }, { label: 'Save', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body);
    if (f.hours) { f.start_time = null; f.end_time = null; }
    if (!f.hours && !(f.start_time && f.end_time)) throw new Error('Enter start and end time, or total hours.');
    const t = await db.insert('time_entries', { ...f, break_minutes: f.break_minutes || 0, hours: f.hours || 0 });
    toast(`${num(t.hours, 2)} h logged · ${money(t.labor_cost)} labor cost`); closeModal(); refresh();
  } }]);
}
register({
  logTime: () => openLogTime(),
  archiveTime: async ({ id }) => {
    if (!(await confirmDialog('Remove time entry?', 'It will be archived and removed from labor cost.', 'Remove', 'btn-red'))) return;
    await db.update('time_entries', id, { archived_at: new Date().toISOString() }); refresh();
  },
});
