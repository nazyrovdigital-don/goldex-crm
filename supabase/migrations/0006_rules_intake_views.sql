-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0006 AUTOMATION LIBRARY, WEBSITE INTAKE, VIEWS
-- ════════════════════════════════════════════════════════════════════

-- ── AUTOMATION LIBRARY (spec §33–§36, §59) ─────────────────────────
insert into public.automation_rules (name, trigger_event, conditions, actions, delay, is_system, sort_order, description) values
('New lead → contact task + owner alert', 'lead.created', '{}', '[
   {"type":"create_task","title":"Contact new lead — {{customer_name}} ({{service_type}})","priority":"Urgent","due_in":"15 minutes","task_type":"Contact Lead"},
   {"type":"notify","kind":"lead","title":"New lead: {{customer_name}}","body":"{{service_type}} · {{source}} · score {{qualification_score}}"}
 ]', '0', true, 10, 'Every new lead gets an urgent contact task due in 15 minutes and an owner notification.'),

('Lead untouched 15 min → reminder', 'lead.created', '{"stage":"NEW LEAD","last_contacted_at":null}', '[
   {"type":"notify","kind":"reminder","title":"Reminder: {{customer_name}} not contacted (15 min)","body":"{{service_type}} lead from {{source}}"}
 ]', '15 minutes', false, 20, 'Response-time SLA.'),
('Lead untouched 30 min → escalation', 'lead.created', '{"stage":"NEW LEAD","last_contacted_at":null}', '[
   {"type":"notify","kind":"escalation","title":"Escalation: {{customer_name}} waiting 30 min","body":"Call now — speed wins jobs."}
 ]', '30 minutes', false, 21, 'Response-time SLA.'),
('Lead untouched 2 hr → escalation', 'lead.created', '{"stage":"NEW LEAD","last_contacted_at":null}', '[
   {"type":"notify","kind":"escalation","title":"⚠ {{customer_name}} uncontacted for 2 hours","body":"Lead is going cold."},
   {"type":"create_task","title":"ESCALATED: call {{customer_name}} now","priority":"Urgent","due_in":"0","task_type":"Contact Lead"}
 ]', '2 hours', false, 22, 'Response-time SLA.'),

('Lead contacted → close contact tasks', 'lead.stage_changed', '{"old_stage":"NEW LEAD"}', '[
   {"type":"complete_tasks","by":"lead_id","task_types":["Contact Lead"]}
 ]', '0', false, 25, null),
('Lead lost → cancel its open tasks', 'lead.stage_changed', '{"stage":"LOST"}', '[
   {"type":"complete_tasks","by":"lead_id","status":"Cancelled"}
 ]', '0', false, 26, null),
('Site visit scheduled → calendar + task', 'lead.site_visit_scheduled', '{}', '[
   {"type":"create_calendar_event","event_type":"Site Visit","title":"Site visit — {{customer_name}}","date_field":"site_visit_date"},
   {"type":"create_task","title":"Site visit — {{customer_name}}","priority":"High","due_field":"site_visit_date","task_type":"Site Visit"}
 ]', '0', false, 30, null),
('Lead reached ESTIMATE → estimate task', 'lead.stage_changed', '{"stage":"ESTIMATE"}', '[
   {"type":"create_task","title":"Prepare estimate — {{customer_name}} ({{service_type}})","priority":"High","due_in":"1 day","task_type":"Estimate"}
 ]', '0', false, 31, 'Estimate due within 24–48 hours of the site visit.'),

('Estimate sent → follow-up', 'estimate.sent', '{}', '[
   {"type":"log_communication","comm_type":"Email","direction":"Outbound","subject":"Estimate {{estimate_number}} sent","message":"{{title}} — {{total|money}}"},
   {"type":"create_task","title":"Follow up on estimate {{estimate_number}} — {{customer_name}}","priority":"High","due_in":"2 days","task_type":"Follow-Up"}
 ]', '0', false, 40, null),
('Estimate expired → follow-up', 'estimate.expired', '{}', '[
   {"type":"create_task","title":"Estimate {{estimate_number}} expired — re-engage {{customer_name}}","priority":"Medium","due_in":"0","task_type":"Follow-Up"}
 ]', '0', false, 41, null),

('Proposal sent → follow-up in 2 days', 'proposal.sent', '{}', '[
   {"type":"set_lead_stage","stage":"PROPOSAL SENT"},
   {"type":"log_communication","comm_type":"Email","direction":"Outbound","subject":"Proposal {{proposal_number}} sent","message":"{{title}} — {{total|money}}"},
   {"type":"create_task","title":"Follow up on proposal {{proposal_number}} — {{customer_name}} ({{total|money}})","priority":"High","due_in":"2 days","task_type":"Follow-Up"}
 ]', '0', true, 50, null),
('Proposal not approved +5 days → follow-up', 'proposal.sent', '{"status":{"in":["Sent","Viewed","Follow-Up"]}}', '[
   {"type":"set_proposal_status","status":"Follow-Up","only_from":["Sent","Viewed"]},
   {"type":"set_lead_stage","stage":"FOLLOW-UP"},
   {"type":"create_task","title":"2nd follow-up: proposal {{proposal_number}} — {{customer_name}}","priority":"High","due_in":"0","task_type":"Follow-Up"}
 ]', '5 days', false, 51, null),
('Proposal not approved +10 days → follow-up', 'proposal.sent', '{"status":{"in":["Sent","Viewed","Follow-Up"]}}', '[
   {"type":"create_task","title":"Final follow-up: proposal {{proposal_number}} — {{customer_name}}","priority":"High","due_in":"0","task_type":"Follow-Up"},
   {"type":"notify","kind":"reminder","title":"Proposal {{proposal_number}} open 10 days","body":"{{customer_name}} — {{total|money}}"}
 ]', '10 days', false, 52, null),

('Proposal approved → project', 'proposal.approved', '{}', '[
   {"type":"complete_tasks","by":"proposal_id","task_types":["Follow-Up"]},
   {"type":"complete_tasks","by":"estimate_id","task_types":["Follow-Up"]},
   {"type":"complete_tasks","by":"lead_id","task_types":["Contact Lead","Estimate","Site Visit","Follow-Up"]},
   {"type":"set_lead_stage","stage":"WON","force":true},
   {"type":"set_customer_status","status":"Active","unless_in":["VIP","Do Not Contact"]},
   {"type":"create_project_from_proposal"},
   {"type":"create_deposit_invoice"},
   {"type":"create_checklist","setting":"default_project_checklist","phase":"Pre-Construction"},
   {"type":"create_calendar_event","event_type":"Project Start","title":"Project start — {{project_name}}"},
   {"type":"create_task","title":"Collect deposit {{deposit_amount|money}} — {{customer_name}}","priority":"High","due_in":"1 day","task_type":"Collect Deposit","if":{"deposit_amount":{"gt":0}}},
   {"type":"create_task","title":"Confirm scope & measurements — {{project_name}}","priority":"High","due_in":"2 days","task_type":"Pre-Construction"},
   {"type":"create_task","title":"Build material list — {{project_name}}","priority":"Medium","due_in":"2 days","task_type":"Materials"},
   {"type":"create_task","title":"Schedule project start — {{project_name}}","priority":"High","due_in":"1 day","task_type":"Scheduling","if":{"deposit_amount":{"lte":0}}},
   {"type":"notify","kind":"won","title":"🏆 Won: {{customer_name}} — {{total|money}}","body":"Project {{project_number}} created. Deposit {{deposit_amount|money}}."}
 ]', '0', true, 60, 'Lead → WON, customer → Active, project + deposit invoice + checklist + tasks + schedule placeholder + owner notification.'),
('Proposal declined → notify', 'proposal.declined', '{}', '[
   {"type":"complete_tasks","by":"proposal_id","status":"Cancelled"},
   {"type":"notify","kind":"lost","title":"Proposal declined: {{customer_name}}","body":"Reason: {{decline_reason}}"}
 ]', '0', false, 61, null),

('Deposit paid → ready to schedule', 'deposit.paid', '{}', '[
   {"type":"complete_tasks","by":"project_id","task_types":["Collect Deposit"]},
   {"type":"set_project_status","status":"Ready to Schedule","only_from":["Pending Deposit"]},
   {"type":"create_task","title":"Schedule project start — {{project_name}}","priority":"High","due_in":"1 day","task_type":"Scheduling"},
   {"type":"notify","kind":"payment","title":"Deposit received — {{project_name}}","body":"Ready to schedule."}
 ]', '0', true, 70, null),
('Payment recorded → notify', 'payment.recorded', '{}', '[
   {"type":"notify","kind":"payment","title":"Payment received: {{amount|money}} from {{customer_name}}","body":"{{method}} · {{kind}}"}
 ]', '0', false, 71, null),
-- Deposits do not trigger review requests — only money for finished work does.
('Invoice paid → review request', 'invoice.paid', '{"type":{"in":["Final","Other"]}}', '[
   {"type":"create_task","title":"Request Google review — {{customer_name}}","priority":"Medium","due_in":"1 day","task_type":"Review Request"}
 ]', '0', true, 72, 'V1 behaviour kept, limited to final/other invoices so deposits do not trigger reviews.'),

('Project scheduled → close scheduling tasks', 'project.scheduled', '{}', '[
   {"type":"complete_tasks","by":"project_id","task_types":["Scheduling"]}
 ]', '0', false, 75, null),
('Project completed → closeout checklist', 'project.completed', '{}', '[
   {"type":"create_checklist","setting":"closeout_checklist","phase":"Closeout"},
   {"type":"create_task","title":"Final walkthrough — {{project_name}}","priority":"High","due_in":"1 day","task_type":"Closeout"},
   {"type":"create_task","title":"Send final invoice — {{project_name}}","priority":"High","due_in":"1 day","task_type":"Closeout"}
 ]', '0', false, 80, null);

-- ── WEBSITE LEAD INTAKE (spec §11) ─────────────────────────────────
-- Called by the lead-intake Edge Function with the service-role key.
-- Finds or creates the customer (by email, then phone), the property,
-- and the lead. The lead.created rule then creates the task + alerts.
create or replace function public.intake_website_lead(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c_id uuid; prop_id uuid; l_id uuid; is_new boolean := false;
  em text := lower(nullif(trim(p->>'email'), ''));
  ph text := nullif(regexp_replace(coalesce(p->>'phone', ''), '\D', '', 'g'), '');
  addr text := nullif(trim(p->>'address'), '');
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_active_user() then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if coalesce(trim(p->>'first_name'), '') = '' and coalesce(trim(p->>'last_name'), '') = '' then
    raise exception 'Name is required';
  end if;
  if em is null and ph is null then raise exception 'Phone or email is required'; end if;
  if length(ph) = 11 and left(ph, 1) = '1' then ph := substr(ph, 2); end if;

  select id into c_id from customers
  where archived_at is null and ((em is not null and lower(email) = em) or (ph is not null and right(phone_digits, 10) = ph))
  order by created_at limit 1;

  if c_id is null then
    insert into customers (first_name, last_name, phone, email, lead_source, customer_status, billing_address)
    values (coalesce(trim(p->>'first_name'), ''), coalesce(trim(p->>'last_name'), ''), p->>'phone', em,
            coalesce(p->>'source', 'Website'), 'Lead', addr)
    returning id into c_id;
    is_new := true;
  end if;

  if addr is not null then
    select id into prop_id from properties where customer_id = c_id and lower(address) = lower(addr) limit 1;
    if prop_id is null then
      insert into properties (customer_id, address, city, zip, is_default)
      values (c_id, addr, nullif(p->>'city', ''), nullif(p->>'zip', ''),
              not exists (select 1 from properties where customer_id = c_id))
      returning id into prop_id;
    end if;
  end if;

  insert into leads (customer_id, property_id, source, source_page, source_campaign, utm_source, utm_medium, utm_campaign,
                     submitted_at, service_type, description, photos_provided, assigned_to, notes)
  values (c_id, prop_id, coalesce(p->>'source', 'Website'), p->>'source_page', p->>'utm_campaign',
          p->>'utm_source', p->>'utm_medium', p->>'utm_campaign', now(),
          nullif(p->>'service', ''), nullif(p->>'details', ''), coalesce((p->>'photos_provided')::boolean, false),
          public.owner_user_id(), case when is_new then null else 'Returning customer' end)
  returning id into l_id;

  insert into communications (customer_id, lead_id, type, direction, subject, message)
  values (c_id, l_id, 'Website Form', 'Inbound', 'Website quote request: ' || coalesce(p->>'service', ''), p->>'details');

  return jsonb_build_object('customer_id', c_id, 'property_id', prop_id, 'lead_id', l_id, 'new_customer', is_new,
                            'lead_number', (select lead_number from leads where id = l_id));
end $$;

-- ── GLOBAL SEARCH (spec §65) ───────────────────────────────────────
create or replace function public.global_search(q text) returns jsonb
language plpgsql stable set search_path = public as $$
declare pat text := '%' || trim(q) || '%'; digits text := nullif(regexp_replace(q, '\D', '', 'g'), '');
begin
  if length(trim(q)) < 2 then return '[]'; end if;
  return coalesce((select jsonb_agg(x) from (
    select 'customer' kind, c.id, coalesce(nullif(trim(c.first_name||' '||c.last_name),''), c.company_name) label,
           concat_ws(' · ', c.customer_number, c.phone, c.email) sub
    from customers c where c.archived_at is null and (c.first_name||' '||c.last_name ilike pat or c.company_name ilike pat
      or c.email ilike pat or c.customer_number ilike pat or (digits is not null and length(digits) >= 3 and c.phone_digits like '%'||digits||'%'))
    union all
    select 'property', pr.id, pr.address, public.customer_display_name(pr.customer_id)
    from properties pr where pr.archived_at is null and (pr.address ilike pat or pr.city ilike pat)
    union all
    select 'lead', l.id, l.lead_number || ' · ' || coalesce(l.service_type, ''), public.customer_display_name(l.customer_id) || ' · ' || l.stage
    from leads l where l.archived_at is null and (l.lead_number ilike pat or l.description ilike pat or l.service_type ilike pat
      or public.customer_display_name(l.customer_id) ilike pat)
    union all
    select 'estimate', e.id, e.estimate_number || ' · ' || e.title, e.status
    from estimates e where e.archived_at is null and (e.estimate_number ilike pat or e.title ilike pat)
    union all
    select 'proposal', p.id, p.proposal_number || ' · ' || p.title, p.status
    from proposals p where p.archived_at is null and (p.proposal_number ilike pat or p.title ilike pat)
    union all
    select 'project', j.id, j.project_number || ' · ' || j.project_name, j.status
    from projects j where j.archived_at is null and (j.project_number ilike pat or j.project_name ilike pat
      or public.customer_display_name(j.customer_id) ilike pat)
    union all
    select 'invoice', i.id, i.invoice_number, public.customer_display_name(i.customer_id) || ' · ' || i.status
    from invoices i where i.archived_at is null and (i.invoice_number ilike pat or public.customer_display_name(i.customer_id) ilike pat)
    union all
    select 'payment', pa.id, '$' || pa.amount || ' · ' || pa.method, coalesce(pa.reference, '') || ' ' || pa.payment_date
    from payments pa where pa.voided_at is null and pa.reference ilike pat
    limit 60) x), '[]');
end $$;

-- ── VIEWS ──────────────────────────────────────────────────────────
-- security_invoker: views obey the caller's row-level security.

-- Leads with what-to-do-next (spec §72) and the pipeline card fields (§13).
create view public.v_leads with (security_invoker = true) as
select l.*,
  public.customer_display_name(l.customer_id) as customer_name,
  c.phone as customer_phone, c.email as customer_email,
  pr.address as property_address,
  extract(day from now() - l.created_at)::int as age_days,
  (l.stage = 'NEW LEAD' and l.last_contacted_at is null
     and now() - l.created_at > make_interval(mins => coalesce((public.setting('lead_sla_minutes') #>> '{}')::int, 15))) as sla_breached,
  case l.stage
    when 'NEW LEAD' then 'Call customer'
    when 'CONTACTED' then 'Qualify: budget, timeline, photos'
    when 'QUALIFYING' then case when l.site_visit_required then 'Schedule site visit' else 'Build estimate' end
    when 'SITE VISIT' then case when l.site_visit_date is null then 'Schedule site visit' else 'Complete site visit' end
    when 'ESTIMATE' then 'Send estimate'
    when 'PROPOSAL SENT' then 'Follow up on proposal'
    when 'FOLLOW-UP' then 'Follow up — ask for decision'
    when 'WON' then 'Collect deposit'
    else null end as next_action,
  (select min(t.due_at) from public.tasks t where t.lead_id = l.id and t.status in ('Pending','In Progress')) as next_task_due
from public.leads l
join public.customers c on c.id = l.customer_id
left join public.properties pr on pr.id = l.property_id;

-- TRUE project profitability (spec §21, §55). Labor is costed from time
-- entries at loaded rates — including the owner's own hours.
create view public.v_project_financials with (security_invoker = true) as
with exp as (
  select project_id,
    sum(total) filter (where category = 'Materials') materials,
    sum(total) filter (where category = 'Labor') labor_exp,
    sum(total) filter (where category = 'Subcontractor') subcontractors,
    sum(total) filter (where category = 'Delivery') delivery,
    sum(total) filter (where category = 'Disposal') disposal,
    sum(total) filter (where category = 'Equipment') equipment,
    sum(total) filter (where category in ('Fuel','Tools','Permit','Other Direct Cost')) other_direct,
    sum(total) filter (where category = 'Overhead') overhead
  from public.expenses where archived_at is null and project_id is not null group by project_id),
lab as (
  select project_id, sum(hours) hours, sum(labor_cost) cost,
         sum(hours) filter (where u.role = 'owner') owner_hours
  from public.time_entries te join public.users u on u.id = te.user_id
  where te.archived_at is null and project_id is not null group by project_id),
inv as (
  select project_id, sum(total) invoiced, sum(amount_paid) collected
  from public.invoices where status <> 'Void' and archived_at is null and project_id is not null group by project_id)
select p.id as project_id, p.project_number, p.project_name, p.customer_id, p.status,
  p.contract_value, p.approved_change_orders, p.current_contract_value,
  coalesce(inv.invoiced, 0) invoiced, coalesce(inv.collected, 0) collected,
  p.current_contract_value - coalesce(inv.collected, 0) balance,
  coalesce(exp.materials, 0) materials,
  coalesce(lab.cost, 0) + coalesce(exp.labor_exp, 0) direct_labor,
  coalesce(exp.subcontractors, 0) subcontractors,
  coalesce(exp.delivery, 0) delivery, coalesce(exp.disposal, 0) disposal, coalesce(exp.equipment, 0) equipment,
  coalesce(exp.other_direct, 0) other_direct,
  coalesce(exp.materials,0) + coalesce(lab.cost,0) + coalesce(exp.labor_exp,0) + coalesce(exp.subcontractors,0)
    + coalesce(exp.delivery,0) + coalesce(exp.disposal,0) + coalesce(exp.equipment,0) + coalesce(exp.other_direct,0) as direct_cost,
  p.estimated_cost, p.budgeted_hours,
  coalesce(lab.hours, 0) actual_hours, coalesce(lab.owner_hours, 0) owner_hours,
  p.percent_complete
from public.projects p
left join exp on exp.project_id = p.id
left join lab on lab.project_id = p.id
left join inv on inv.project_id = p.id
where p.archived_at is null;

create view public.v_project_profit with (security_invoker = true) as
select f.*,
  f.current_contract_value - f.direct_cost as gross_profit,
  case when f.current_contract_value > 0 then round((f.current_contract_value - f.direct_cost) / f.current_contract_value * 100, 1) end as gross_margin,
  f.current_contract_value - f.estimated_cost as estimated_profit,
  case when f.current_contract_value > 0 then round((f.current_contract_value - f.estimated_cost) / f.current_contract_value * 100, 1) end as estimated_margin,
  -- Projection: whichever is larger — the budget, or actual cost extrapolated from % complete.
  greatest(f.estimated_cost, f.direct_cost,
           case when f.percent_complete > 0 then round(f.direct_cost / (f.percent_complete / 100), 2) else 0 end) as projected_cost,
  f.current_contract_value - greatest(f.estimated_cost, f.direct_cost,
           case when f.percent_complete > 0 then round(f.direct_cost / (f.percent_complete / 100), 2) else 0 end) as projected_profit,
  case p.status
    when 'Pending Deposit' then 'Collect deposit'
    when 'Ready to Schedule' then 'Schedule start date'
    when 'Scheduled' then 'Order materials & confirm crew'
    when 'Pre-Construction' then 'Finish pre-construction checklist'
    when 'In Progress' then 'Log today''s work'
    when 'On Hold' then 'Resolve hold'
    when 'Punch List' then 'Finish punch list'
    when 'QC' then 'QC inspection'
    when 'Completed' then case when f.balance > 0 then 'Collect final payment' else 'Request review & close' end
    else null end as next_action
from public.v_project_financials f join public.projects p on p.id = f.project_id;

-- The number to manage by: actual for finished jobs, projected for open ones.
-- (A brand-new job has no costs yet, so "actual" profit would read 100%.)
create view public.v_project_outlook with (security_invoker = true) as
select pp.*,
  case when pp.status in ('Completed','Closed') then pp.gross_profit else pp.projected_profit end as expected_profit,
  case when pp.current_contract_value > 0 then round(
    (case when pp.status in ('Completed','Closed') then pp.gross_profit else pp.projected_profit end)
    / pp.current_contract_value * 100, 1) end as expected_margin
from public.v_project_profit pp;

create view public.v_invoices with (security_invoker = true) as
select i.*, public.customer_display_name(i.customer_id) customer_name, p.project_name,
  (i.status in ('Sent','Partially Paid') and i.due_date < current_date) as is_overdue,
  case when i.status in ('Sent','Partially Paid') and i.due_date < current_date then current_date - i.due_date else 0 end as days_overdue
from public.invoices i left join public.projects p on p.id = i.project_id
where i.archived_at is null;

-- CEO dashboard numbers in one round trip (spec §51, §73, §86).
create or replace function public.dashboard_summary(p_from date default date_trunc('month', current_date)::date,
                                                    p_to date default current_date) returns jsonb
language sql stable set search_path = public as $$
  with
  pay as (select coalesce(sum(amount), 0) v from payments where voided_at is null and payment_date between p_from and p_to),
  won as (select count(*) n, coalesce(sum(total - tax), 0) v from proposals where status = 'Approved' and approved_at::date between p_from and p_to),
  leads_p as (select count(*) n, count(*) filter (where qualification_score in ('A','B')) q,
                     count(*) filter (where stage = 'WON') w, count(*) filter (where stage = 'LOST') l
              from leads where archived_at is null and created_at::date between p_from and p_to),
  closed as (select count(*) filter (where stage = 'WON') w, count(*) filter (where stage in ('WON','LOST')) d
             from leads where archived_at is null and stage_changed_at::date between p_from and p_to),
  pipe as (select coalesce(sum(estimated_value), 0) v,
                  coalesce(sum(estimated_value * case stage when 'NEW LEAD' then .1 when 'CONTACTED' then .15 when 'QUALIFYING' then .2
                    when 'SITE VISIT' then .3 when 'ESTIMATE' then .4 when 'PROPOSAL SENT' then .5 when 'FOLLOW-UP' then .5 else 0 end), 0) w
           from leads where archived_at is null and stage not in ('WON','LOST')),
  ar as (select coalesce(sum(balance_due), 0) v, coalesce(sum(balance_due) filter (where is_overdue), 0) overdue,
                count(*) filter (where is_overdue) overdue_n,
                coalesce(sum(balance_due) filter (where days_overdue = 0), 0) b_current,
                coalesce(sum(balance_due) filter (where days_overdue between 1 and 30), 0) b_30,
                coalesce(sum(balance_due) filter (where days_overdue between 31 and 60), 0) b_60,
                coalesce(sum(balance_due) filter (where days_overdue between 61 and 90), 0) b_90,
                coalesce(sum(balance_due) filter (where days_overdue > 90), 0) b_90p
         from v_invoices where status in ('Sent','Partially Paid')),
  prof as (select coalesce(sum(expected_profit), 0) gp, coalesce(sum(current_contract_value), 0) rev, count(*) n
           from v_project_outlook where status not in ('Cancelled')),
  act as (select count(*) n, count(*) filter (where projected_profit < 0 or (status = 'Pending Deposit') ) risk
          from v_project_profit where status in ('Pending Deposit','Ready to Schedule','Scheduled','Pre-Construction','In Progress','On Hold','Punch List','QC')),
  own as (select coalesce(sum(te.hours) filter (where work_category = 'Field'), 0) field,
                 coalesce(sum(te.hours) filter (where work_category = 'Admin'), 0) admin,
                 coalesce(sum(te.hours) filter (where work_category = 'Sales'), 0) sales,
                 coalesce(sum(te.hours) filter (where work_category = 'Management'), 0) mgmt,
                 coalesce(sum(te.hours), 0) total
          from time_entries te join users u on u.id = te.user_id
          where u.role = 'owner' and te.archived_at is null and te.entry_date between p_from and p_to),
  tk as (select count(*) filter (where due_at < now()) overdue, count(*) filter (where due_at::date = current_date) today
         from tasks where status in ('Pending','In Progress') and archived_at is null)
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'revenue_collected', pay.v,
    'contracted_revenue', won.v, 'won_count', won.n,
    'pipeline', pipe.v, 'weighted_pipeline', round(pipe.w, 2),
    'gross_profit', prof.gp, 'gross_margin', case when prof.rev > 0 then round(prof.gp / prof.rev * 100, 1) end,
    'accounts_receivable', ar.v, 'overdue_ar', ar.overdue, 'overdue_invoices', ar.overdue_n,
    'ar_aging', jsonb_build_object('current', ar.b_current, '1_30', ar.b_30, '31_60', ar.b_60, '61_90', ar.b_90, '90_plus', ar.b_90p),
    'leads', leads_p.n, 'qualified_leads', leads_p.q,
    'estimates', (select count(*) from estimates where archived_at is null and created_date between p_from and p_to),
    'proposals', (select count(*) from proposals where archived_at is null and created_at::date between p_from and p_to),
    'close_rate', case when closed.d > 0 then round(closed.w::numeric / closed.d * 100, 0) end,
    'avg_project_value', case when won.n > 0 then round(won.v / won.n, 0) end,
    'active_projects', act.n, 'projects_at_risk', act.risk,
    'overdue_tasks', tk.overdue, 'tasks_today', tk.today,
    'new_leads', (select count(*) from leads where stage = 'NEW LEAD' and archived_at is null),
    'leads_needing_action', (select count(*) from v_leads where archived_at is null and (sla_breached or (stage not in ('WON','LOST') and next_task_due < now()))),
    'owner_hours', jsonb_build_object('field', own.field, 'admin', own.admin, 'sales', own.sales, 'management', own.mgmt, 'total', own.total),
    'revenue_per_field_hour', case when own.field > 0 then round(pay.v / own.field, 0) end,
    -- ≈ period revenue × overall job margin ÷ field hours
    'profit_per_field_hour', case when own.field > 0 and prof.rev > 0 then round(pay.v * (prof.gp / prof.rev) / own.field, 0) end,
    'revenue_per_owner_hour', case when own.total > 0 then round(pay.v / own.total, 0) end
  )
  from pay, won, leads_p, closed, pipe, ar, prof, act, own, tk
$$;
