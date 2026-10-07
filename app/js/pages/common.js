// Helpers shared by several pages: customer picker + create, tasks,
// communication log, activity timeline.
import { db, register, refresh, state, setting, refreshBadges } from '../app.js';
import { html, raw, modal, closeModal, toast, readForm, need, field, input, textarea, select,
         dueFromDate, today, fmtDateTime, ago, esc } from '../ui.js';

export const custName = (c) => c ? (`${c.first_name ?? ''} ${c.last_name ?? ''}`.trim() || c.company_name || 'Unknown') : '';
export const userName = (id) => { const u = state.users.find((x) => x.id === id); return u ? `${u.first_name} ${u.last_name}`.trim() : ''; };

export async function customersById() {
  const list = await db.list('customers', { is: ['archived_at'], order: ['first_name', 'last_name'] });
  return { list, by: Object.fromEntries(list.map((c) => [c.id, c])) };
}

export const customerSelect = (customers, value, name = 'customer_id') => select(name,
  [['', 'Select customer…'], ...customers.map((c) => [c.id, custName(c) + (c.phone ? ' · ' + c.phone : '')]), ['__new', '+ New customer…']],
  value, 'data-change="customerPicked"');

// Contact + address fields used by "new customer" and "new lead with new customer".
export const contactFields = (c = {}) => html`
  <div class="form-row">${field('First name', input('first_name', c.first_name))}${field('Last name', input('last_name', c.last_name))}</div>
  <div class="form-row">${field('Phone', input('phone', c.phone, 'type="tel"'))}${field('Email', input('email', c.email, 'type="email"'))}</div>
  ${field('Company (optional)', input('company_name', c.company_name))}`;

export const addressFields = (p = {}) => html`
  ${field('Project address', input('address', p.address, 'placeholder="Street address"'))}
  <div class="form-row-3">${field('City', input('city', p.city))}${field('ZIP', input('zip', p.zip))}
  ${field('Property type', select('property_type', ['Single Family', 'Condo', 'Townhouse', 'Multi-Family', 'Rental', 'Commercial', 'Other'], p.property_type || 'Single Family'))}</div>`;

export async function createCustomer(f) {
  need(f, { first_name: 'First name' });
  if (!f.phone && !f.email) throw new Error('Phone or email is required.');
  const c = await db.insert('customers', {
    first_name: f.first_name, last_name: f.last_name || '', company_name: f.company_name, phone: f.phone, email: f.email,
    billing_address: f.address, lead_source: f.lead_source || f.source, customer_status: f.customer_status || 'Lead', notes: f.customer_notes,
  });
  let p = null;
  if (f.address) {
    p = await db.insert('properties', { customer_id: c.id, address: f.address, city: f.city, zip: f.zip,
      property_type: f.property_type || 'Single Family', is_default: true });
  }
  return { customer: c, property: p };
}

let afterCustomerCreated = null;
// A form that contains a customer dropdown registers how to reopen itself.
// Picking "+ New customer…" saves what was typed, creates the customer, then
// reopens the original form with everything restored and the customer chosen.
let reopenForm = null;
export const setReopen = (fn) => { reopenForm = fn; };

register({
  customerPicked: async (_d, el) => {
    if (el.value !== '__new') return;
    const values = readForm(document.getElementById('modal-body'));
    const back = reopenForm;
    openCustomerForm(null, (c) => back ? back({ ...values, customer_id: c.id }) : closeModal(), true);
  },
  newCustomer: () => openCustomerForm(),
  newTask: (d) => openTaskForm(d),
  logContact: (d) => openContactLog(d),
  completeTask: async ({ id }, el) => {
    await db.update('tasks', id, { status: el.checked ? 'Completed' : 'Pending' });
    toast(el.checked ? 'Task completed' : 'Task reopened');
    refreshBadges();
    el.closest('.check-item')?.classList.toggle('done', el.checked);
  },
});

export function openCustomerForm(c = null, onSaved = null, nested = false) {
  afterCustomerCreated = onSaved;
  modal(c ? 'Edit customer' : 'New customer', html`
    ${contactFields(c || {})}
    ${c ? '' : addressFields()}
    <div class="form-row">
      ${field('Lead source', select('lead_source', ['', ...setting('lead_sources', [])], c?.lead_source))}
      ${field('Status', select('customer_status', ['Lead', 'Active', 'Past Customer', 'VIP', 'Inactive', 'Do Not Contact'], c?.customer_status || 'Lead'))}
    </div>
    ${c ? html`${field('Billing address', input('billing_address', c.billing_address))}` : ''}
    ${field('Notes', textarea('customer_notes', c?.notes))}`,
  [{ label: 'Cancel' },
   { label: c ? 'Save' : 'Create customer', cls: 'btn-gold', onClick: async (body) => {
      const f = readForm(body);
      let saved;
      if (c) {
        need(f, { first_name: 'First name' });
        saved = await db.update('customers', c.id, { first_name: f.first_name, last_name: f.last_name || '', company_name: f.company_name,
          phone: f.phone, email: f.email, lead_source: f.lead_source, customer_status: f.customer_status, billing_address: f.billing_address, notes: f.customer_notes });
      } else {
        saved = (await createCustomer(f)).customer;
      }
      toast(c ? 'Customer saved' : 'Customer created');
      if (afterCustomerCreated) { const cb = afterCustomerCreated; afterCustomerCreated = null; return cb(saved); }
      closeModal();
      if (!nested) refresh();
    } }]);
}

export async function openTaskForm(d = {}) {
  const [{ list }, projects] = await Promise.all([customersById(), db.list('projects', { is: ['archived_at'], order: 'created_at desc' })]);
  modal('New task', html`
    ${field('Task', input('title', '', 'placeholder="Call customer, order materials…"'))}
    <div class="form-row">
      ${field('Customer', select('customer_id', [['', 'None'], ...list.map((c) => [c.id, custName(c)])], d.customer))}
      ${field('Project', select('project_id', [['', 'None'], ...projects.map((p) => [p.id, p.project_name])], d.project))}
    </div>
    <div class="form-row">
      ${field('Due date', input('due', d.due || today(), 'type="date"'))}
      ${field('Priority', select('priority', ['Urgent', 'High', 'Medium', 'Low'], 'Medium'))}
    </div>
    ${field('Assigned to', select('assigned_to', state.users.map((u) => [u.id, `${u.first_name} ${u.last_name}`]), state.me.id))}
    ${field('Notes', textarea('notes'))}
    <input type="hidden" name="lead_id" value="${d.lead || ''}">`,
  [{ label: 'Cancel' }, { label: 'Save task', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body);
    need(f, { title: 'Task' });
    await db.insert('tasks', { title: f.title, customer_id: f.customer_id, project_id: f.project_id, lead_id: f.lead_id,
      due_at: dueFromDate(f.due), priority: f.priority, notes: f.notes, assigned_to: f.assigned_to });
    toast('Task added'); closeModal(); refresh();
  } }]);
}

export function openContactLog(d) {
  modal('Log contact', html`
    <div class="form-row">
      ${field('Type', select('type', ['Phone', 'SMS', 'Email', 'Meeting', 'Internal Note'], 'Phone'))}
      ${field('Direction', select('direction', ['Outbound', 'Inbound', 'Internal'], 'Outbound'))}
    </div>
    ${field('Summary', textarea('message', '', 'placeholder="What was discussed? Next step?"'))}
    ${d.lead ? html`<label class="check"><input type="checkbox" name="advance" checked> Move lead from NEW LEAD to CONTACTED</label>` : ''}`,
  [{ label: 'Cancel' }, { label: 'Save', cls: 'btn-gold', onClick: async (body) => {
    const f = readForm(body);
    await db.insert('communications', { customer_id: d.customer || null, lead_id: d.lead || null, project_id: d.project || null,
      type: f.type, direction: f.direction, message: f.message, subject: f.type === 'Phone' ? 'Call' : null });
    if (d.lead && f.advance) await db.updateWhere('leads', { eq: { id: d.lead, stage: 'NEW LEAD' } }, { stage: 'CONTACTED' });
    toast('Contact logged'); closeModal(); refresh();
  } }]);
}

// Tasks rendered as a checklist (used on dashboard, project, lead, customer).
export const taskList = (tasks, { showWho = true } = {}) => tasks.length ? html`<div class="checklist">${tasks.map((t) => {
  const overdue = t.due_at && new Date(t.due_at) < new Date() && t.status !== 'Completed';
  return html`<div class="check-item ${t.status === 'Completed' ? 'done' : ''}">
    <input type="checkbox" data-change="completeTask" data-id="${t.id}" ${t.status === 'Completed' ? raw('checked') : ''}>
    <div class="ci-text"><div>${t.title}</div>
      <div class="list-sub">${t.due_at ? html`<span class="${overdue ? 'red' : ''}">Due ${fmtDateTime(t.due_at)}${overdue ? ' · overdue' : ''}</span>` : 'No due date'}
      ${t.automation_source ? html` · <span title="Created by automation: ${t.automation_source}">⚡ auto</span>` : ''}
      ${showWho && t.assigned_to && t.assigned_to !== state.me.id ? ' · ' + userName(t.assigned_to) : ''}</div></div>
    <span class="badge badge-${t.priority === 'Urgent' || t.priority === 'High' ? 'red' : t.priority === 'Medium' ? 'orange' : 'muted'}">${t.priority}</span>
  </div>`;
})}</div>` : html`<div class="muted small" style="padding:8px 0">No open tasks</div>`;

export async function timeline({ customer, lead, project }) {
  const opts = (k, v) => ({ eq: { [k]: v }, order: 'sent_at desc', limit: 50 });
  const comms = customer ? await db.list('communications', opts('customer_id', customer))
    : lead ? await db.list('communications', opts('lead_id', lead)) : await db.list('communications', opts('project_id', project));
  if (!comms.length) return html`<div class="muted small">No communication logged yet.</div>`;
  return html`${comms.map((c) => html`<div class="timeline-item"><div class="timeline-time">${ago(c.sent_at)}</div>
    <div><b>${c.type}</b> <span class="muted small">${c.direction}</span>${c.subject ? html` — ${c.subject}` : ''}
    ${c.message ? html`<div class="muted small" style="white-space:pre-wrap">${c.message}</div>` : ''}</div></div>`)}`;
}

export { esc };
