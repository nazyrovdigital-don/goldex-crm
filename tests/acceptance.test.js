// Spec §84 developer acceptance tests (1–6), plus the controls V2 promises:
// payment validation, lost reasons, numbering, audit log, RLS, V1 import.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createDb, asUser, asService, one, all, val, OWNER } from './helpers.js';

const v1Seed = JSON.parse(readFileSync(new URL('../app/demo/v1_seed.json', import.meta.url), 'utf8'));
let db;

// Push every pending delayed automation into the past and run it.
async function fastForward() {
  await db.exec(`reset role`);
  await db.exec(`update scheduled_actions set run_at = now() - interval '1 second' where status = 'pending'`);
  await asUser(db, OWNER);
  return val(db, `select (run_maintenance()->>'actions_ran')::int`);
}

async function addPricebook() {
  return one(db, `insert into pricebook_items (service, item, unit, sell_price, labor_hours, labor_rate, material_cost)
                  values ('Cabinet Installation', 'Cabinet install', 'per cabinet', 130, 1.25, 40, 5) returning *`);
}

async function websiteLead(extra = {}) {
  await asService(db);
  const r = await val(db, `select intake_website_lead($1)`, [JSON.stringify({
    first_name: 'Dana', last_name: 'Reyes', phone: '(619) 555-0142', email: 'dana@example.com',
    address: '742 Coast Blvd, La Jolla, CA', service: 'Cabinet Installation',
    details: '18 kitchen cabinets + island', utm_source: 'google', utm_medium: 'cpc', utm_campaign: 'cabinets-fall',
    source_page: '/#quote', ...extra })]);
  await asUser(db, OWNER);
  return r;
}

before(async () => { db = await createDb(); });

test('Test 1 — website lead creates customer, property, lead, source, task, notification, SLA timers', async () => {
  const r = await websiteLead();
  assert.equal(r.new_customer, true);
  const lead = await one(db, `select * from v_leads where id = $1`, [r.lead_id]);
  assert.equal(lead.source, 'Website');
  assert.equal(lead.utm_campaign, 'cabinets-fall');
  assert.equal(lead.stage, 'NEW LEAD');
  assert.equal(lead.property_address, '742 Coast Blvd, La Jolla, CA');
  assert.equal(lead.customer_name, 'Dana Reyes');
  assert.match(lead.lead_number, /^LEAD-\d{5}$/);

  const task = await one(db, `select * from tasks where lead_id = $1`, [r.lead_id]);
  assert.match(task.title, /Contact new lead — Dana Reyes/);
  assert.equal(task.priority, 'Urgent');
  assert.equal(task.assigned_to, OWNER, 'website leads are assigned to the owner');
  assert.ok(await one(db, `select 1 from notifications where entity_id = $1 and title like 'New lead%'`, [r.lead_id]));
  assert.equal(await val(db, `select count(*)::int from scheduled_actions where entity_id = $1`, [r.lead_id]), 3);
  assert.ok(await one(db, `select 1 from communications where lead_id = $1 and type = 'Website Form'`, [r.lead_id]));

  // Uncontacted → all three reminders fire (15 min, 30 min, 2 hr + escalation task).
  await fastForward();
  assert.equal(await val(db, `select count(*)::int from notifications where entity_id = $1 and kind in ('reminder','escalation')`, [r.lead_id]), 3);
  assert.ok(await one(db, `select 1 from tasks where lead_id = $1 and title like 'ESCALATED%'`, [r.lead_id]));
});

test('Test 1b — returning customer is matched by phone; contacted lead skips SLA reminders', async () => {
  const r = await websiteLead({ email: '', phone: '+1 619-555-0142', details: 'Also need a pantry door' });
  assert.equal(r.new_customer, false);
  assert.equal(await val(db, `select count(*)::int from customers where last_name = 'Reyes'`), 1);
  assert.equal(await val(db, `select count(*)::int from properties where address ilike '742 Coast%'`), 1);
  await db.query(`insert into communications (customer_id, lead_id, type, direction, message) values ($1, $2, 'Phone', 'Outbound', 'Called')`,
    [r.customer_id, r.lead_id]);
  await db.query(`update leads set stage = 'CONTACTED' where id = $1`, [r.lead_id]);
  assert.equal(await val(db, `select status from tasks where lead_id = $1 and task_type = 'Contact Lead'`, [r.lead_id]), 'Completed',
    'moving out of NEW LEAD closes the contact task');
  await fastForward();
  assert.equal(await val(db, `select count(*)::int from notifications where entity_id = $1 and kind in ('reminder','escalation')`, [r.lead_id]), 0);
  assert.equal(await val(db, `select count(*)::int from scheduled_actions where entity_id = $1 and status = 'skipped'`, [r.lead_id]), 3);
});

test('Lead qualification score — A for high-fit, D for poor fit', async () => {
  const c = await one(db, `insert into customers (first_name, last_name) values ('Score', 'Test') returning id`);
  const a = await one(db, `insert into leads (customer_id, service_type, estimated_value, photos_provided, preferred_start_date)
                           values ($1, 'Cabinet Installation', 8000, true, current_date + 20) returning qualification_score`, [c.id]);
  const d = await one(db, `insert into leads (customer_id, service_type, estimated_value, urgency)
                           values ($1, 'Handyman', 150, 'Emergency') returning qualification_score`, [c.id]);
  assert.equal(a.qualification_score, 'A');
  assert.equal(d.qualification_score, 'D');
});

let estimateId, proposalId, leadId;

test('Test 2 — estimate from price book calculates sell, labor, material, gross profit, margin', async () => {
  const pb = await addPricebook();
  assert.equal(Number(pb.labor_cost), 50, 'labor cost = 1.25 h × $40');
  assert.equal(Number(pb.margin), 57.7);

  const r = await websiteLead({ email: 'kim@example.com', phone: '858-555-0199', first_name: 'Kim', last_name: 'Park' });
  leadId = r.lead_id;
  estimateId = await val(db, `select create_estimate_from_lead($1)`, [leadId]);
  assert.equal(await val(db, `select stage from leads where id = $1`, [leadId]), 'ESTIMATE');
  assert.ok(await one(db, `select 1 from tasks where lead_id = $1 and title like 'Prepare estimate%'`, [leadId]));

  await db.query(`insert into estimate_items (estimate_id, pricebook_item_id, quantity, description) values ($1, $2, 17, '')`, [estimateId, pb.id]);
  await db.query(`insert into estimate_items (estimate_id, description, quantity, unit, unit_price, unit_subcontractor_cost)
                  values ($1, 'Countertop templating (sub)', 1, 'job', 600, 450)`, [estimateId]);
  await db.query(`update estimates set discount = 110 where id = $1`, [estimateId]);

  const e = await one(db, `select * from estimates where id = $1`, [estimateId]);
  assert.equal(Number(e.subtotal), 17 * 130 + 600);                 // 2810
  assert.equal(Number(e.estimated_labor_cost), 850);                // 17 × 50
  assert.equal(Number(e.estimated_material_cost), 85);              // 17 × 5
  assert.equal(Number(e.estimated_subcontractor_cost), 450);
  assert.equal(Number(e.estimated_labor_hours), 21.25);
  assert.equal(Number(e.total), 2700);
  assert.equal(Number(e.estimated_gross_profit), 2700 - 850 - 85 - 450); // 1315
  assert.equal(Number(e.estimated_margin), 48.7);
  assert.match(e.estimate_number, /^EST-\d{5}$/);
});

test('Test 3 — proposal from estimate, send creates follow-ups; deposit capped by CA rule', async () => {
  proposalId = await val(db, `select create_proposal_from_estimate($1)`, [estimateId]);
  const p = await one(db, `select * from proposals where id = $1`, [proposalId]);
  assert.equal(Number(p.total), 2700);
  assert.equal(Number(p.deposit_amount), 270, '10% of 2700');
  assert.match(p.scope_of_work, /Cabinet install — 17 per cabinet/);
  assert.equal(await val(db, `select status from estimates where id = $1`, [estimateId]), 'Converted');
  assert.equal(await val(db, `select count(*)::int from proposal_items where proposal_id = $1`, [proposalId]), 2);

  await db.query(`select send_proposal($1)`, [proposalId]);
  assert.equal(await val(db, `select stage from leads where id = $1`, [leadId]), 'PROPOSAL SENT');
  const fu = await one(db, `select * from tasks where proposal_id = $1 and title like 'Follow up on proposal%'`, [proposalId]);
  assert.ok(fu);
  const daysOut = (new Date(fu.due_at) - Date.now()) / 864e5;
  assert.ok(daysOut > 1.9 && daysOut < 2.1, 'follow-up due in 2 days');
  assert.equal(await val(db, `select count(*)::int from scheduled_actions where entity_id = $1 and status = 'pending'`, [proposalId]), 2);

  // Big job: 10% would be $5,000 but California caps the down payment at $1,000.
  const c = await one(db, `select customer_id from leads where id = $1`, [leadId]);
  const big = await one(db, `insert into proposals (customer_id, subtotal, deposit_type, deposit_percent) values ($1, 50000, 'Percent', 10) returning deposit_amount`, [c.customer_id]);
  assert.equal(Number(big.deposit_amount), 1000);
});

test('Test 4 — approval automatically creates project, deposit invoice, tasks; lead WON, customer Active', async () => {
  const r = await val(db, `select approve_proposal($1, 'Kim Park')`, [proposalId]);
  assert.ok(r.project_id);
  const prj = await one(db, `select * from projects where id = $1`, [r.project_id]);
  assert.equal(Number(prj.contract_value), 2700);
  assert.equal(Number(prj.estimated_cost), 1385);
  assert.equal(Number(prj.budgeted_hours), 21.25);
  assert.equal(prj.status, 'Pending Deposit');
  assert.equal(prj.proposal_id, proposalId);
  assert.match(prj.project_number, /^PRJ-\d{5}$/);

  assert.equal(await val(db, `select stage from leads where id = $1`, [leadId]), 'WON');
  assert.equal(await val(db, `select customer_status from customers where id = $1`, [prj.customer_id]), 'Active');
  assert.equal(await val(db, `select project_id from estimates where id = $1`, [estimateId]), r.project_id);

  const inv = await one(db, `select * from invoices where id = $1`, [r.deposit_invoice_id]);
  assert.equal(inv.type, 'Deposit');
  assert.equal(Number(inv.total), 270);
  assert.equal(inv.status, 'Sent');

  const titles = (await all(db, `select title from tasks where project_id = $1 order by title`, [r.project_id])).map(t => t.title);
  assert.ok(titles.some(t => t.startsWith('Collect deposit $270')), titles.join(' | '));
  assert.ok(titles.some(t => t.startsWith('Confirm scope')));
  assert.ok(titles.some(t => t.startsWith('Build material list')));
  assert.ok(!titles.some(t => t.startsWith('Schedule project start')), 'not schedulable until deposit paid');
  const fu = await one(db, `select status, project_id from tasks where proposal_id = $1 and title like 'Follow up on proposal%'`, [proposalId]);
  assert.equal(fu.status, 'Completed', 'approval closes the proposal follow-up');
  assert.equal(fu.project_id, r.project_id, 'proposal tasks re-linked to project');
  assert.equal(await val(db, `select count(*)::int from tasks where lead_id = $1 and task_type = 'Contact Lead' and status = 'Pending'`, [leadId]), 0);
  assert.equal(await val(db, `select count(*)::int from project_checklist_items where project_id = $1`, [r.project_id]), 8);
  assert.ok(await one(db, `select 1 from calendar_events where project_id = $1 and type = 'Project Start' and status = 'Unscheduled'`, [r.project_id]));
  assert.ok(await one(db, `select 1 from notifications where title like '🏆 Won: Kim Park — $2,700%'`));
  assert.ok(await one(db, `select 1 from audit_log where entity_id = $1 and action = 'proposal approved'`, [proposalId]));

  // Contract value is locked; double approval is refused.
  await assert.rejects(db.query(`update proposals set subtotal = 9999 where id = $1`, [proposalId]), /locked/);
  await assert.rejects(db.query(`select approve_proposal($1)`, [proposalId]), /already approved/);

  // Delayed proposal follow-ups no longer apply once approved.
  await fastForward();
  assert.equal(await val(db, `select count(*)::int from tasks where proposal_id = $1 and title like '%follow-up%'`, [proposalId]), 0);
});

test('Payment controls — no overpayment; deposit paid → Ready to Schedule; deposits do not request reviews', async () => {
  const prjId = await val(db, `select project_id from proposals where id = $1`, [proposalId]);
  const invId = await val(db, `select id from invoices where project_id = $1 and type = 'Deposit'`, [prjId]);

  await assert.rejects(db.query(`select record_payment($1, 500)`, [invId]), /exceeds the remaining balance of \$270/);
  const p1 = await val(db, `select record_payment($1, 100, 'Zelle')`, [invId]);
  assert.equal(p1.invoice_status, 'Partially Paid');
  assert.equal(await val(db, `select deposit_paid from projects where id = $1`, [prjId]), false);

  const p2 = await val(db, `select record_payment($1, 170, 'Zelle')`, [invId]);
  assert.equal(p2.invoice_status, 'Paid');
  const prj = await one(db, `select * from projects where id = $1`, [prjId]);
  assert.equal(prj.deposit_paid, true);
  assert.equal(prj.status, 'Ready to Schedule');
  assert.ok(await one(db, `select 1 from tasks where project_id = $1 and title like 'Schedule project start%'`, [prjId]));
  assert.equal(await val(db, `select status from tasks where project_id = $1 and task_type = 'Collect Deposit'`, [prjId]), 'Completed',
    'paying the deposit closes the collect-deposit task');
  await db.query(`update projects set status = 'Scheduled', start_date = current_date + 7 where id = $1`, [prjId]);
  assert.equal(await val(db, `select count(*)::int from tasks where project_id = $1 and task_type = 'Scheduling' and status = 'Pending'`, [prjId]), 0);
  assert.equal(await val(db, `select count(*)::int from tasks where project_id = $1 and task_type = 'Review Request'`, [prjId]), 0);

  // Voiding the deposit payment un-pays the deposit.
  const payId = await val(db, `select id from payments where invoice_id = $1 and amount = 170`, [invId]);
  await db.query(`select void_payment($1, 'bounced')`, [payId]);
  assert.equal(await val(db, `select status from invoices where id = $1`, [invId]), 'Partially Paid');
  assert.equal(await val(db, `select deposit_paid from projects where id = $1`, [prjId]), false);
  await db.query(`select record_payment($1, 170, 'Cash')`, [invId]);
  await assert.rejects(db.query(`delete from payments where id = $1`, [payId]), /permission denied/);
});

test('Test 5 — job costing: labor (incl. owner at loaded rate), materials, subs → actual GP and margin', async () => {
  const prjId = await val(db, `select project_id from proposals where id = $1`, [proposalId]);
  const te = await one(db, `insert into time_entries (project_id, start_time, end_time, break_minutes) values ($1, '07:00', '15:30', 30) returning *`, [prjId]);
  assert.equal(Number(te.hours), 8);
  assert.equal(Number(te.labor_cost), 320, '8 h × $40 owner loaded rate');
  await db.query(`insert into expenses (project_id, category, vendor, amount) values
                  ($1, 'Materials', 'Home Depot', 180), ($1, 'Subcontractor', 'Stone Co', 450), ($1, 'Disposal', 'Dump', 40)`, [prjId]);
  const f = await one(db, `select * from v_project_profit where project_id = $1`, [prjId]);
  assert.equal(Number(f.direct_labor), 320);
  assert.equal(Number(f.materials), 180);
  assert.equal(Number(f.subcontractors), 450);
  assert.equal(Number(f.direct_cost), 990);
  assert.equal(Number(f.gross_profit), 1710);
  assert.equal(Number(f.gross_margin), 63.3);
  assert.equal(Number(f.collected), 270);
  assert.equal(Number(f.balance), 2430);
  assert.equal(Number(f.owner_hours), 8);
  assert.equal(Number(f.projected_cost), 1385, 'projection never below the estimate');
});

test('Final invoice paid → review request task (V1 behaviour kept)', async () => {
  const prjId = await val(db, `select project_id from proposals where id = $1`, [proposalId]);
  const c = await val(db, `select customer_id from projects where id = $1`, [prjId]);
  const inv = await one(db, `insert into invoices (customer_id, project_id, type, status, subtotal) values ($1, $2, 'Final', 'Sent', 2430) returning id`, [c, prjId]);
  await db.query(`select record_payment($1, 2430, 'Check')`, [inv.id]);
  assert.ok(await one(db, `select 1 from tasks where project_id = $1 and task_type = 'Review Request'`, [prjId]));
});

test('Lost leads require a reason', async () => {
  const c = await one(db, `insert into customers (first_name) values ('Lost') returning id`);
  const l = await one(db, `insert into leads (customer_id) values ($1) returning id`, [c.id]);
  await assert.rejects(db.query(`update leads set stage = 'LOST' where id = $1`, [l.id]), /leads_lost_needs_reason/);
  await assert.rejects(db.query(`select mark_lead_lost($1, '')`, [l.id]), /reason is required/);
  await db.query(`select mark_lead_lost($1, 'Price', 'Big Box Installers')`, [l.id]);
  assert.equal(await val(db, `select stage from leads where id = $1`, [l.id]), 'LOST');
});

test('Numbers are server-generated and never reused after deletion', async () => {
  const c = await one(db, `insert into customers (first_name) values ('Num') returning id`);
  const a = await val(db, `insert into leads (customer_id) values ($1) returning lead_number`, [c.id]);
  await db.query(`delete from tasks where lead_id = (select id from leads where lead_number = $1)`, [a]);
  await db.query(`delete from leads where lead_number = $1`, [a]);
  const b = await val(db, `insert into leads (customer_id) values ($1) returning lead_number`, [c.id]);
  assert.notEqual(a, b);
  assert.ok(Number(b.slice(5)) > Number(a.slice(5)));
});

test('Audit log records stage changes with old and new values', async () => {
  const row = await one(db, `select * from audit_log where entity_type = 'leads' and entity_id = $1 and action like 'stage:%' order by id limit 1`, [leadId]);
  assert.equal(row.action, 'stage: NEW LEAD → ESTIMATE');
  assert.equal(row.user_id, OWNER);
});

test('Security — anon and pending users see nothing and cannot run engine internals', async () => {
  await asUser(db, null);
  assert.equal(await val(db, `select count(*)::int from customers`), 0, 'RLS hides every row from anon');
  await assert.rejects(db.query(`select dashboard_summary()`), /permission denied/);

  await db.exec(`reset role`);
  const pending = '00000000-0000-4000-8000-000000000002';
  await db.query(`insert into auth.users (id, email) values ($1, 'stranger@example.com')`, [pending]);
  assert.equal(await val(db, `select status from users where id = $1`, [pending]), 'pending');
  await asUser(db, pending);
  assert.equal(await val(db, `select count(*)::int from customers`), 0);
  await assert.rejects(db.query(`select emit('lead.created', 'lead', gen_random_uuid())`), /permission denied/);
  await assert.rejects(db.query(`select intake_website_lead('{}')`), /permission denied/);
  await assert.rejects(db.query(`select create_estimate_from_lead(gen_random_uuid())`), /Not authorized/);
  await assert.rejects(db.query(`update users set status = 'active', role = 'owner' where id = $1`, [pending]), /cannot change your own role/);
  await asUser(db, OWNER);
  assert.ok(await val(db, `select count(*)::int from customers`) > 0);
});

test('Dashboard summary returns CEO numbers', async () => {
  const s = await val(db, `select dashboard_summary()`);
  assert.ok(Number(s.revenue_collected) >= 2700);
  assert.equal(s.owner_hours.field, 8);
  assert.ok(s.active_projects >= 0);
  assert.ok('ar_aging' in s);
});

test('Global search finds the whole customer ecosystem', async () => {
  const hits = await val(db, `select global_search('Park')`);
  const kinds = new Set(hits.map(h => h.kind));
  for (const k of ['customer', 'lead', 'project', 'invoice']) assert.ok(kinds.has(k), `missing ${k}: ${[...kinds]}`);
});

test('V1 import — seed data lands with real relationships and no automation side effects', async () => {
  const fresh = await createDb();
  const counts = await val(fresh, `select import_v1($1)`, [JSON.stringify(v1Seed)]);
  assert.deepEqual(counts, { pricebook: 6, customers: 3, leads: 3, projects: 1, estimates: 1, proposals: 0,
    invoices: 1, payments: 1, expenses: 2, time_entries: 2, tasks: 3, calendar_events: 4 });
  assert.equal(await val(fresh, `select count(*)::int from tasks`), 3, 'no automation tasks created');
  assert.equal(await val(fresh, `select count(*)::int from notifications`), 0);
  const inv = await one(fresh, `select * from invoices`);
  assert.equal(inv.invoice_number, 'INV-001');
  assert.equal(Number(inv.amount_paid), 1000);
  assert.equal(inv.status, 'Partially Paid');
  const f = await one(fresh, `select * from v_project_profit`);
  assert.equal(Number(f.materials), 232);
  assert.equal(Number(f.actual_hours), 14);
  assert.equal(Number(f.direct_labor), 560, '14 h × $40 — V1 ignored labor entirely');
  assert.equal(await val(fresh, `select stage from leads where description like 'Garage%'`), 'NEW LEAD');
  assert.equal(await val(fresh, `select count(*)::int from properties`), 3);
  await assert.rejects(fresh.query(`select import_v1($1)`, [JSON.stringify(v1Seed)]), /already been imported/);
});
