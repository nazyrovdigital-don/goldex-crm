-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0005 AUTOMATION ENGINE
-- Every important event produces the next required action (spec §2, §32, §70).
--
--   TRIGGER (event)  +  CONDITIONS  →  ACTIONS   [optionally after a DELAY]
--
-- Rules are rows in automation_rules, not hard-coded functions. Database
-- triggers emit events, so automation fires no matter how a record changes
-- (UI, website intake, import, SQL). Immediate actions run in the SAME
-- transaction as the change: a proposal approval either creates the project,
-- invoice and tasks, or nothing happens at all.
-- ════════════════════════════════════════════════════════════════════

create table public.automation_rules (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  description   text,
  trigger_event text not null,
  conditions    jsonb not null default '{}',
  actions       jsonb not null default '[]',
  delay         interval not null default '0',
  active        boolean not null default true,
  is_system     boolean not null default false,   -- core workflow; UI warns before disabling
  sort_order    integer not null default 100,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index automation_rules_event_idx on public.automation_rules (trigger_event) where active;

create table public.scheduled_actions (
  id          uuid primary key default gen_random_uuid(),
  rule_id     uuid not null references public.automation_rules(id) on delete cascade,
  event       text not null,
  entity_type text not null,
  entity_id   uuid not null,
  extra       jsonb not null default '{}',
  run_at      timestamptz not null,
  status      text not null default 'pending' check (status in ('pending','done','skipped','failed')),
  error       text,
  executed_at timestamptz,
  created_at  timestamptz not null default now()
);
create index scheduled_actions_due_idx on public.scheduled_actions (run_at) where status = 'pending';

create table public.automation_log (
  id          bigint generated always as identity primary key,
  rule_id     uuid references public.automation_rules(id) on delete set null,
  rule_name   text,
  event       text,
  entity_type text,
  entity_id   uuid,
  status      text,
  detail      jsonb,
  created_at  timestamptz not null default now()
);
create index automation_log_entity_idx on public.automation_log (entity_id, created_at desc);

create trigger automation_rules_touch before update on public.automation_rules
  for each row execute function public.tg_touch();

-- ── HELPERS ────────────────────────────────────────────────────────
create or replace function public.customer_display_name(p_customer_id uuid) returns text
language sql stable as $$
  select coalesce(nullif(trim(first_name || ' ' || last_name), ''), company_name, 'Unknown')
  from public.customers where id = p_customer_id
$$;

create or replace function public.owner_user_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.users where role = 'owner' and status = 'active' order by created_at limit 1
$$;

create or replace function public.entity_table(p_entity text) returns text
language sql immutable as $$
  select case p_entity
    when 'lead' then 'leads' when 'customer' then 'customers' when 'estimate' then 'estimates'
    when 'proposal' then 'proposals' when 'project' then 'projects' when 'invoice' then 'invoices'
    when 'payment' then 'payments' when 'task' then 'tasks' end
$$;

-- Context = the entity row + ids + friendly names, used for conditions and templates.
create or replace function public.build_ctx(p_entity text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; tbl text := public.entity_table(p_entity);
begin
  if tbl is null then raise exception 'Unknown entity type %', p_entity; end if;
  execute format('select to_jsonb(t) from public.%I t where id = $1', tbl) into r using p_id;
  if r is null then return null; end if;
  r := r || jsonb_build_object('entity_type', p_entity, 'entity_id', p_id, p_entity || '_id', p_id);
  if r->>'customer_id' is not null then
    r := r || jsonb_build_object('customer_name', public.customer_display_name((r->>'customer_id')::uuid));
  end if;
  if r->>'project_id' is not null and not r ? 'project_name' then
    r := r || (select jsonb_build_object('project_name', project_name, 'project_number', project_number)
               from public.projects where id = (r->>'project_id')::uuid);
  end if;
  return r;
end $$;

-- {{field}} and {{field|money}} placeholders.
create or replace function public.render_tpl(p_tpl text, ctx jsonb) returns text
language plpgsql stable as $$
declare m text[]; val text; result text := p_tpl;
begin
  if p_tpl is null then return null; end if;
  for m in select regexp_matches(p_tpl, '\{\{([a-z_]+)(\|money)?\}\}', 'g') loop
    val := ctx->>m[1];
    if m[2] = '|money' and val is not null then
      val := '$' || to_char(val::numeric, case when val::numeric = trunc(val::numeric) then 'FM999,999,990' else 'FM999,999,990.00' end);
    end if;
    result := replace(result, '{{' || m[1] || coalesce(m[2], '') || '}}', coalesce(val, ''));
  end loop;
  return result;
end $$;

-- Condition language (all keys must match):
--   {"stage": "NEW LEAD"}             equals
--   {"last_contacted_at": null}       is empty
--   {"status": {"in": ["Sent","Viewed"]}}  / {"not_in": [...]}
--   {"deposit_amount": {"gt": 0}}     gt / gte / lt / lte
create or replace function public.eval_conditions(c jsonb, ctx jsonb) returns boolean
language plpgsql stable as $$
declare k text; v jsonb; cur jsonb; cur_t text;
begin
  if c is null or c = '{}'::jsonb then return true; end if;
  for k, v in select key, value from jsonb_each(c) loop
    cur := ctx->k;
    cur_t := case when cur is null or jsonb_typeof(cur) = 'null' then null else cur #>> '{}' end;
    if jsonb_typeof(v) = 'null' then
      if cur_t is not null then return false; end if;
    elsif jsonb_typeof(v) = 'object' then
      if v ? 'in' and not coalesce(cur_t in (select jsonb_array_elements_text(v->'in')), false) then return false; end if;
      if v ? 'not_in' and coalesce(cur_t in (select jsonb_array_elements_text(v->'not_in')), false) then return false; end if;
      if v ? 'gt'  and not coalesce(cur_t::numeric >  (v->>'gt')::numeric, false) then return false; end if;
      if v ? 'gte' and not coalesce(cur_t::numeric >= (v->>'gte')::numeric, false) then return false; end if;
      if v ? 'lt'  and not coalesce(cur_t::numeric <  (v->>'lt')::numeric, false) then return false; end if;
      if v ? 'lte' and not coalesce(cur_t::numeric <= (v->>'lte')::numeric, false) then return false; end if;
      if v ? 'is_null' and ((cur_t is null) <> (v->>'is_null')::boolean) then return false; end if;
    else
      if cur_t is distinct from (v #>> '{}') then return false; end if;
    end if;
  end loop;
  return true;
end $$;

create or replace function public.lead_stage_rank(p_stage text) returns int
language sql immutable as $$
  select array_position(array['NEW LEAD','CONTACTED','QUALIFYING','SITE VISIT','ESTIMATE',
                              'PROPOSAL SENT','FOLLOW-UP','WON','LOST'], p_stage)
$$;

-- ── ACTIONS ────────────────────────────────────────────────────────
-- Each action receives the context and returns it, possibly enriched
-- (e.g. create_project_from_proposal adds project_id for later actions).
create or replace function public.run_action(a jsonb, ctx jsonb, p_rule public.automation_rules, p_idx int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  kind text := a->>'type';
  pr public.proposals; ld public.leads; prj public.projects;
  new_id uuid; due timestamptz; items jsonb; i int; terms int;
begin
  if a ? 'if' and not public.eval_conditions(a->'if', ctx) then return ctx; end if;

  case kind
  when 'create_task' then
    due := case when a ? 'due_field' and ctx->>(a->>'due_field') is not null
                then (ctx->>(a->>'due_field'))::timestamptz
                else now() + coalesce(a->>'due_in', '0')::interval end;
    insert into tasks (title, description, customer_id, lead_id, project_id, estimate_id, proposal_id, invoice_id,
                       assigned_to, due_at, priority, task_type, automation_source, dedupe_key)
    values (public.render_tpl(a->>'title', ctx), public.render_tpl(a->>'description', ctx),
            (ctx->>'customer_id')::uuid, (ctx->>'lead_id')::uuid, (ctx->>'project_id')::uuid,
            (ctx->>'estimate_id')::uuid, (ctx->>'proposal_id')::uuid, (ctx->>'invoice_id')::uuid,
            coalesce(auth.uid(), public.owner_user_id()), due, coalesce(a->>'priority', 'Medium'),
            a->>'task_type', p_rule.name,
            p_rule.id || ':' || p_idx || ':' || (ctx->>'entity_id'))
    on conflict (dedupe_key) where dedupe_key is not null do nothing;

  when 'notify' then
    insert into notifications (kind, title, body, entity_type, entity_id)
    values (coalesce(a->>'kind', 'info'), public.render_tpl(a->>'title', ctx), public.render_tpl(a->>'body', ctx),
            ctx->>'entity_type', (ctx->>'entity_id')::uuid);

  when 'set_lead_stage' then
    update leads set stage = a->>'stage'
    where id = (ctx->>'lead_id')::uuid and stage <> (a->>'stage')
      and (coalesce((a->>'force')::boolean, false)
           or (stage not in ('WON','LOST') and public.lead_stage_rank(stage) < public.lead_stage_rank(a->>'stage')));

  when 'set_customer_status' then
    update customers set customer_status = a->>'status'
    where id = (ctx->>'customer_id')::uuid
      and not coalesce(customer_status in (select jsonb_array_elements_text(a->'unless_in')), false);

  when 'set_project_status' then
    update projects set status = a->>'status'
    where id = (ctx->>'project_id')::uuid
      and (not a ? 'only_from' or status in (select jsonb_array_elements_text(a->'only_from')));

  when 'set_proposal_status' then
    update proposals set status = a->>'status'
    where id = (ctx->>'proposal_id')::uuid
      and (not a ? 'only_from' or status in (select jsonb_array_elements_text(a->'only_from')));

  when 'create_project_from_proposal' then
    select * into pr from proposals where id = (ctx->>'proposal_id')::uuid;
    if pr.project_id is null then
      select * into ld from leads where id = pr.lead_id;
      insert into projects (customer_id, property_id, lead_id, estimate_id, proposal_id, project_name, project_type,
                            service_category, status, contract_value, estimated_cost, budgeted_hours,
                            deposit_required, deposit_amount, scope_of_work, start_date, project_manager_id)
      values (pr.customer_id, pr.property_id, pr.lead_id, pr.estimate_id, pr.id,
              coalesce(nullif(pr.title, ''), public.customer_display_name(pr.customer_id) || ' — ' || coalesce(ld.service_type, 'Project')),
              ld.project_type, ld.service_type,
              case when pr.deposit_amount > 0 then 'Pending Deposit' else 'Ready to Schedule' end,
              pr.total - pr.tax, pr.estimated_direct_cost, pr.estimated_labor_hours,
              pr.deposit_amount > 0, pr.deposit_amount, pr.scope_of_work, ld.preferred_start_date,
              coalesce(auth.uid(), public.owner_user_id()))
      returning id into new_id;
      update proposals set project_id = new_id where id = pr.id;
      update estimates set project_id = new_id, status = 'Approved' where id = pr.estimate_id;
      update tasks set project_id = new_id where proposal_id = pr.id and project_id is null;
    else
      new_id := pr.project_id;
    end if;
    select * into prj from projects where id = new_id;
    ctx := ctx || jsonb_build_object('project_id', prj.id, 'project_name', prj.project_name,
                                     'project_number', prj.project_number, 'contract_value', prj.contract_value);

  when 'create_deposit_invoice' then
    select * into prj from projects where id = (ctx->>'project_id')::uuid;
    if prj.deposit_amount > 0 then
      select id into new_id from invoices where project_id = prj.id and type = 'Deposit' and status <> 'Void' limit 1;
      if new_id is null then
        insert into invoices (customer_id, project_id, proposal_id, type, status, due_date, subtotal, description, payment_terms)
        values (prj.customer_id, prj.id, prj.proposal_id, 'Deposit', 'Sent', current_date, prj.deposit_amount,
                'Deposit — ' || prj.project_name, 'Due on signing')
        returning id into new_id;
      end if;
      ctx := ctx || jsonb_build_object('invoice_id', new_id);
    end if;

  when 'create_checklist' then
    items := public.setting(a->>'setting');
    if not exists (select 1 from project_checklist_items where project_id = (ctx->>'project_id')::uuid
                   and phase = coalesce(a->>'phase', 'Pre-Construction')) then
      for i in 0 .. coalesce(jsonb_array_length(items), 0) - 1 loop
        insert into project_checklist_items (project_id, phase, label, sort_order)
        values ((ctx->>'project_id')::uuid, coalesce(a->>'phase', 'Pre-Construction'), items->>i, i);
      end loop;
    end if;

  when 'create_calendar_event' then
    insert into calendar_events (title, type, customer_id, project_id, lead_id, assigned_to, event_date, start_time, status, location)
    values (public.render_tpl(a->>'title', ctx), coalesce(a->>'event_type', 'Other'),
            (ctx->>'customer_id')::uuid, (ctx->>'project_id')::uuid, (ctx->>'lead_id')::uuid,
            coalesce(auth.uid(), public.owner_user_id()),
            case when a ? 'date_field' then (ctx->>(a->>'date_field'))::timestamptz::date end,
            case when a ? 'date_field' then (ctx->>(a->>'date_field'))::timestamptz::time end,
            case when a ? 'date_field' and ctx->>(a->>'date_field') is not null then 'Scheduled' else 'Unscheduled' end,
            (select address from properties where id = (ctx->>'property_id')::uuid));

  -- Close automation-created tasks whose reason has gone away (deposit paid,
  -- proposal decided, lead contacted…). Tasks people created are never touched.
  when 'complete_tasks' then
    execute format('update tasks set status = $1 where %I = $2 and status in (''Pending'',''In Progress'')
                      and automation_source is not null and ($3::text[] is null or task_type = any($3))',
                   a->>'by')
    using coalesce(a->>'status', 'Completed'), (ctx->>(a->>'by'))::uuid,
          case when a ? 'task_types' then array(select jsonb_array_elements_text(a->'task_types')) end;

  when 'log_communication' then
    insert into communications (customer_id, lead_id, project_id, type, direction, subject, message)
    values ((ctx->>'customer_id')::uuid, (ctx->>'lead_id')::uuid, (ctx->>'project_id')::uuid,
            coalesce(a->>'comm_type', 'Internal Note'), coalesce(a->>'direction', 'Internal'),
            public.render_tpl(a->>'subject', ctx), public.render_tpl(a->>'message', ctx));

  else
    raise exception 'Unknown automation action type: %', kind;
  end case;
  return ctx;
end $$;

create or replace function public.run_rule(p_rule public.automation_rules, ctx jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a jsonb; idx int := 0;
begin
  for a in select value from jsonb_array_elements(p_rule.actions) loop
    ctx := public.run_action(a, ctx, p_rule, idx);
    idx := idx + 1;
  end loop;
  insert into automation_log (rule_id, rule_name, event, entity_type, entity_id, status)
  values (p_rule.id, p_rule.name, p_rule.trigger_event, ctx->>'entity_type', (ctx->>'entity_id')::uuid, 'ran');
  return ctx;
end $$;

-- ── EMIT ───────────────────────────────────────────────────────────
create or replace function public.emit(p_event text, p_entity text, p_id uuid, p_extra jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare ctx jsonb; r public.automation_rules;
begin
  -- Bulk imports set this so historical records do not spawn tasks/alerts.
  if current_setting('goldex.suppress_automation', true) = 'on' then return null; end if;
  ctx := public.build_ctx(p_entity, p_id);
  if ctx is null then return null; end if;
  ctx := ctx || coalesce(p_extra, '{}');
  for r in select * from automation_rules where trigger_event = p_event and active order by sort_order, created_at loop
    if r.delay > interval '0' then
      insert into scheduled_actions (rule_id, event, entity_type, entity_id, extra, run_at)
      values (r.id, p_event, p_entity, p_id, coalesce(p_extra, '{}'), now() + r.delay);
    elsif public.eval_conditions(r.conditions, ctx) then
      ctx := public.run_rule(r, ctx);
    end if;
  end loop;
  return ctx;
end $$;

-- Delayed rules re-check their conditions against the record AS IT IS NOW,
-- so "proposal still not approved after 5 days" really means still.
create or replace function public.process_scheduled_actions() returns integer
language plpgsql security definer set search_path = public as $$
declare s public.scheduled_actions; r public.automation_rules; ctx jsonb; n int := 0;
begin
  for s in select * from scheduled_actions where status = 'pending' and run_at <= now()
           order by run_at for update skip locked loop
    select * into r from automation_rules where id = s.rule_id;
    ctx := public.build_ctx(s.entity_type, s.entity_id);
    if r.id is null or not r.active or ctx is null or ctx->>'archived_at' is not null
       or not public.eval_conditions(r.conditions, ctx || s.extra) then
      update scheduled_actions set status = 'skipped', executed_at = now() where id = s.id;
      continue;
    end if;
    begin
      perform public.run_rule(r, ctx || s.extra);
      update scheduled_actions set status = 'done', executed_at = now() where id = s.id;
      n := n + 1;
    exception when others then
      update scheduled_actions set status = 'failed', error = sqlerrm, executed_at = now() where id = s.id;
      insert into automation_log (rule_id, rule_name, event, entity_type, entity_id, status, detail)
      values (r.id, r.name, s.event, s.entity_type, s.entity_id, 'failed', jsonb_build_object('error', sqlerrm));
    end;
  end loop;
  return n;
end $$;

-- Expire stale estimates/proposals and run due automations. Scheduled every
-- 5 minutes with pg_cron (0007), and also called when the app opens.
create or replace function public.run_maintenance() returns jsonb
language plpgsql security definer set search_path = public as $$
declare exp_est int; exp_prop int; ran int;
begin
  if auth.uid() is not null and not public.is_active_user() then raise exception 'Not authorized'; end if;
  update estimates set status = 'Expired'
  where status = 'Sent' and expiration_date < current_date and archived_at is null;
  get diagnostics exp_est = row_count;
  update proposals set status = 'Expired'
  where status in ('Sent','Viewed','Follow-Up') and valid_until < current_date and archived_at is null;
  get diagnostics exp_prop = row_count;
  ran := public.process_scheduled_actions();
  return jsonb_build_object('estimates_expired', exp_est, 'proposals_expired', exp_prop, 'actions_ran', ran);
end $$;

-- ── EVENT TRIGGERS ─────────────────────────────────────────────────
create or replace function public.tg_leads_events() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform public.emit('lead.created', 'lead', new.id);
  else
    if new.stage is distinct from old.stage then
      perform public.emit('lead.stage_changed', 'lead', new.id, jsonb_build_object('old_stage', old.stage));
    end if;
    if new.site_visit_date is not null and new.site_visit_date is distinct from old.site_visit_date then
      perform public.emit('lead.site_visit_scheduled', 'lead', new.id);
    end if;
  end if;
  return null;
end $$;
create trigger leads_events after insert or update on public.leads for each row execute function public.tg_leads_events();

create or replace function public.tg_status_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare ent text := case tg_table_name when 'estimates' then 'estimate' when 'proposals' then 'proposal'
                                       when 'projects' then 'project' end;
begin
  if new.status is distinct from old.status then
    perform public.emit(ent || '.' || replace(lower(new.status), ' ', '_'), ent, new.id,
                        jsonb_build_object('old_status', old.status));
    if ent = 'project' then
      perform public.emit('project.status_changed', ent, new.id, jsonb_build_object('old_status', old.status));
    end if;
  end if;
  return null;
end $$;
create trigger estimates_events after update on public.estimates for each row execute function public.tg_status_events();
create trigger proposals_events after update on public.proposals for each row execute function public.tg_status_events();
create trigger projects_events  after update on public.projects  for each row execute function public.tg_status_events();

create or replace function public.tg_invoices_events() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'Paid' and old.status is distinct from 'Paid' then
    if new.type = 'Deposit' and new.project_id is not null then
      update projects set deposit_paid = true where id = new.project_id;
      perform public.emit('deposit.paid', 'invoice', new.id);
    end if;
    perform public.emit('invoice.paid', 'invoice', new.id);
  elsif old.status = 'Paid' and new.status <> 'Paid' and new.type = 'Deposit' and new.project_id is not null then
    update projects set deposit_paid = false where id = new.project_id;   -- deposit payment was voided
  end if;
  return null;
end $$;
create trigger invoices_events after update on public.invoices for each row execute function public.tg_invoices_events();

create or replace function public.tg_payments_events() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.emit('payment.recorded', 'payment', new.id);
  return null;
end $$;
create trigger payments_events after insert on public.payments for each row execute function public.tg_payments_events();

-- ── WORKFLOW RPCs (what the UI buttons call) ───────────────────────
create or replace function public.assert_active() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_active_user() then raise exception 'Not authorized' using errcode = '42501'; end if;
end $$;

-- Lead → Estimate (copies customer/property, moves lead to ESTIMATE).
create or replace function public.create_estimate_from_lead(p_lead_id uuid) returns uuid
language plpgsql set search_path = public as $$
declare ld leads; new_id uuid;
begin
  perform public.assert_active();
  select * into ld from leads where id = p_lead_id;
  if not found then raise exception 'Lead not found'; end if;
  insert into estimates (lead_id, customer_id, property_id, title, notes)
  values (ld.id, ld.customer_id, ld.property_id,
          coalesce(ld.service_type, 'Project') || ' — ' || public.customer_display_name(ld.customer_id), ld.description)
  returning id into new_id;
  update leads set stage = 'ESTIMATE' where id = ld.id and public.lead_stage_rank(stage) < public.lead_stage_rank('ESTIMATE');
  return new_id;
end $$;

-- Estimate → Proposal. Values are snapshotted; later estimate edits do not
-- change a proposal the customer may already be reading.
create or replace function public.create_proposal_from_estimate(p_estimate_id uuid) returns uuid
language plpgsql set search_path = public as $$
declare e estimates; new_id uuid; scope text;
begin
  perform public.assert_active();
  select * into e from estimates where id = p_estimate_id;
  if not found then raise exception 'Estimate not found'; end if;
  if not exists (select 1 from estimate_items where estimate_id = e.id) then
    raise exception 'Estimate % has no line items.', e.estimate_number;
  end if;
  select string_agg('• ' || description || ' — ' || trim(to_char(quantity, 'FM999,990.###')) || coalesce(' ' || unit, ''), E'\n' order by sort_order)
    into scope from estimate_items where estimate_id = e.id;
  insert into proposals (estimate_id, lead_id, customer_id, property_id, title, scope_of_work, exclusions, assumptions,
                         subtotal, discount, tax, estimated_direct_cost, estimated_labor_hours,
                         deposit_type, deposit_percent, payment_terms)
  values (e.id, e.lead_id, e.customer_id, e.property_id, e.title,
          coalesce(nullif(e.notes, '') || E'\n\n', '') || scope, e.exclusions, e.assumptions,
          e.subtotal, e.discount, e.tax, e.estimated_direct_cost, e.estimated_labor_hours,
          'Percent', public.setting_num('deposit', 'percent', 10),
          'Deposit due on signing. Balance due on completion.')
  returning id into new_id;
  insert into proposal_items (proposal_id, sort_order, description, quantity, unit, unit_price)
  select new_id, sort_order, description, quantity, unit, unit_price from estimate_items where estimate_id = e.id;
  update estimates set status = 'Converted' where id = e.id and status in ('Draft','Sent');
  return new_id;
end $$;

create or replace function public.send_proposal(p_proposal_id uuid) returns void
language plpgsql set search_path = public as $$
begin
  perform public.assert_active();
  update proposals set status = 'Sent', sent_at = coalesce(sent_at, now())
  where id = p_proposal_id and status in ('Draft','Expired');
  if not found then raise exception 'Only Draft or Expired proposals can be sent.'; end if;
end $$;

create or replace function public.mark_proposal_viewed(p_proposal_id uuid) returns void
language plpgsql set search_path = public as $$
begin
  perform public.assert_active();
  update proposals set status = 'Viewed', viewed_at = coalesce(viewed_at, now())
  where id = p_proposal_id and status in ('Sent','Follow-Up');
end $$;

-- THE critical workflow (spec §18). Setting status = Approved fires the
-- proposal.approved rule which creates the project, deposit invoice,
-- checklist, tasks and owner notification in this same transaction.
create or replace function public.approve_proposal(p_proposal_id uuid, p_signature text default null) returns jsonb
language plpgsql set search_path = public as $$
declare pr proposals;
begin
  perform public.assert_active();
  select * into pr from proposals where id = p_proposal_id for update;
  if not found then raise exception 'Proposal not found'; end if;
  if pr.status = 'Approved' then raise exception 'Proposal % is already approved.', pr.proposal_number; end if;
  if pr.status in ('Declined','Cancelled') then raise exception 'Proposal % is %.', pr.proposal_number, lower(pr.status); end if;
  update proposals set status = 'Approved', approved_at = now(),
         customer_signature = coalesce(nullif(trim(p_signature), ''), customer_signature),
         signed_at = case when nullif(trim(p_signature), '') is not null then now() else signed_at end
  where id = p_proposal_id;
  perform public.log_event('proposal', p_proposal_id, 'proposal approved', jsonb_build_object('total', pr.total));
  select * into pr from proposals where id = p_proposal_id;
  if pr.project_id is null then
    raise exception 'Approval automation did not create a project. Check that the "Proposal approved → project" rule is active.';
  end if;
  return jsonb_build_object('proposal_id', pr.id, 'project_id', pr.project_id,
    'deposit_invoice_id', (select id from invoices where project_id = pr.project_id and type = 'Deposit' limit 1));
end $$;

create or replace function public.decline_proposal(p_proposal_id uuid, p_reason text) returns void
language plpgsql set search_path = public as $$
declare pr proposals;
begin
  perform public.assert_active();
  if coalesce(trim(p_reason), '') = '' then raise exception 'A loss reason is required.'; end if;
  update proposals set status = 'Declined', declined_at = now(), decline_reason = p_reason
  where id = p_proposal_id and status not in ('Approved','Declined') returning * into pr;
  if not found then raise exception 'Proposal cannot be declined in its current status.'; end if;
  update leads set stage = 'LOST', lost_reason = p_reason where id = pr.lead_id and stage <> 'WON';
end $$;

create or replace function public.record_payment(
  p_invoice_id uuid, p_amount numeric, p_method text default 'Zelle', p_date date default current_date,
  p_reference text default null, p_notes text default null, p_is_overpayment boolean default false
) returns jsonb language plpgsql set search_path = public as $$
declare pay_id uuid; inv invoices;
begin
  perform public.assert_active();
  insert into payments (invoice_id, customer_id, amount, method, payment_date, reference, notes, is_overpayment)
  select p_invoice_id, customer_id, p_amount, p_method, p_date, p_reference, p_notes, p_is_overpayment
  from invoices where id = p_invoice_id
  returning id into pay_id;
  if pay_id is null then raise exception 'Invoice not found'; end if;
  select * into inv from invoices where id = p_invoice_id;
  return jsonb_build_object('payment_id', pay_id, 'invoice_status', inv.status, 'balance_due', inv.balance_due);
end $$;

create or replace function public.void_payment(p_payment_id uuid, p_reason text) returns void
language plpgsql set search_path = public as $$
declare inv_id uuid;
begin
  perform public.assert_active();
  update payments set voided_at = now(), void_reason = p_reason
  where id = p_payment_id and voided_at is null returning invoice_id into inv_id;
  if inv_id is null then raise exception 'Payment not found or already void'; end if;
  perform public.recalc_invoice_paid(inv_id);
end $$;

create or replace function public.mark_lead_lost(p_lead_id uuid, p_reason text, p_competitor text default null, p_notes text default null)
returns void language plpgsql set search_path = public as $$
begin
  perform public.assert_active();
  if coalesce(trim(p_reason), '') = '' then raise exception 'A loss reason is required.'; end if;
  update leads set stage = 'LOST', lost_reason = p_reason, lost_competitor = p_competitor, lost_notes = p_notes
  where id = p_lead_id;
end $$;
