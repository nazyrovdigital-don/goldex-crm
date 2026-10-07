-- GOLDEX CRM V2 — complete Supabase setup (migrations 0001–0009 combined).
-- Paste into Supabase → SQL Editor → Run, ONCE, on a new empty project.
-- Generated from supabase/migrations/. Do not edit here.

-- ════════ 0001_core.sql ════════
-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0001 CORE
-- Users, settings, server-side numbering, timestamps, audit log,
-- notifications. Every later migration builds on these helpers.
-- ════════════════════════════════════════════════════════════════════

-- Business runs on San Diego time. Without this, Supabase (UTC) would roll
-- current_date over to "tomorrow" at 5 pm Pacific.
do $$ begin
  execute format('alter database %I set timezone to %L', current_database(), 'America/Los_Angeles');
end $$;
set timezone to 'America/Los_Angeles';

-- ── USERS ───────────────────────────────────────────────────────────
-- One row per Supabase Auth user. Roles beyond owner exist so the schema
-- does not need to change when employees are added (spec §5, §67).
create table public.users (
  id            uuid primary key references auth.users(id) on delete cascade,
  first_name    text not null default '',
  last_name     text not null default '',
  email         text,
  phone         text,
  role          text not null default 'owner'
                check (role in ('owner','admin','sales','project_manager','crew_leader',
                                'field_worker','estimator','bookkeeper','subcontractor')),
  status        text not null default 'pending' check (status in ('active','pending','disabled')),
  labor_rate    numeric(10,2) not null default 0,   -- $/hr base wage (owner = market replacement cost)
  burden_rate   numeric(10,2) not null default 0,   -- $/hr payroll taxes, insurance, workers comp
  avatar_url    text,
  last_login_at timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- The very first account becomes the active owner; every later sign-up waits
-- as 'pending' until the owner activates it. (Also disable public sign-ups in
-- the Supabase dashboard — see README.)
create or replace function public.handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare first_user boolean;
begin
  select not exists (select 1 from public.users) into first_user;
  insert into public.users (id, email, first_name, last_name, role, status)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'first_name', ''),
          coalesce(new.raw_user_meta_data->>'last_name', ''),
          case when first_user then 'owner' else 'field_worker' end,
          case when first_user then 'active' else 'pending' end);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_auth_user();

create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.users where id = auth.uid() and status = 'active')
$$;

create or replace function public.current_role_name() returns text
language sql stable security definer set search_path = public as $$
  select role from public.users where id = auth.uid() and status = 'active'
$$;

-- ── SETTINGS ────────────────────────────────────────────────────────
create table public.settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

create or replace function public.setting(p_key text) returns jsonb
language sql stable as $$ select value from public.settings where key = p_key $$;

create or replace function public.setting_num(p_key text, p_path text, p_default numeric) returns numeric
language sql stable as $$
  select coalesce((select (value #>> string_to_array(p_path, '.'))::numeric
                   from public.settings where key = p_key), p_default)
$$;

insert into public.settings (key, value) values
  ('company', '{"name":"GOLDEX Construction LLC","phone":"(858) 428-0124","email":"olim@goldexconst.com",
                "website":"goldexconst.com","address":"San Diego County, CA","license":"","tagline":"Gold Standard. Every Job."}'),
  -- Gross margin bands (spec §16). < red = RED, < warning = WARNING, < healthy = HEALTHY, else STRONG.
  ('margin_thresholds', '{"red":25,"warning":35,"healthy":45}'),
  ('pricing', '{"target_margin":40,"minimum_margin":30,"tax_rate":0}'),
  -- California B&P Code §7159: home-improvement down payment may not exceed the
  -- LESSER of $1,000 or 10% of the contract price. Verify with your attorney/CSLB.
  ('deposit', '{"percent":10,"max_amount":1000}'),
  ('labor', '{"owner_loaded_rate":40,"default_labor_rate":32,"default_burden_rate":8}'),
  ('lead_sources', '["Website","Google","Thumbtack","Referral","Repeat Customer","Social","Phone","Email","Other"]'),
  ('service_types', '["Cabinet Installation","Flooring","Drywall","Door Installation","Interior Finish","Remodeling","Handyman","Custom"]'),
  ('core_services', '["Cabinet Installation","Flooring","Drywall","Door Installation","Interior Finish","Remodeling"]'),
  ('loss_reasons', '["Competitor","Price","Timing","No response","Bad fit","Outside service area","Customer cancelled","Other"]'),
  ('payment_methods', '["Zelle","Venmo","Cash","Check","Card","Bank Transfer"]'),
  ('payment_terms', '{"default_days":7}'),
  ('lead_sla_minutes', '15'),
  ('default_project_checklist', '["Scope confirmed with customer","Measurements verified","Material list created","Materials ordered","Materials received","Crew assigned","Customer start date confirmed","Site protection / prep ready"]'),
  ('closeout_checklist', '["Scope completed","Change orders completed","QC check completed","Punch list completed","Final photos uploaded","Final walkthrough","Final invoice sent","Payment received","Customer review requested"]');

-- ── NUMBERING ───────────────────────────────────────────────────────
-- Sequences never hand out the same value twice, even after deletes,
-- rollbacks or concurrent inserts (spec §64).
create sequence public.seq_customer;
create sequence public.seq_lead;
create sequence public.seq_estimate;
create sequence public.seq_proposal;
create sequence public.seq_project;
create sequence public.seq_change_order;
create sequence public.seq_invoice;
create sequence public.seq_po;

create or replace function public.next_number(p_prefix text, p_seq regclass) returns text
language sql volatile as $$ select p_prefix || '-' || lpad(nextval(p_seq)::text, 5, '0') $$;

-- ── SHARED TRIGGERS ─────────────────────────────────────────────────
create or replace function public.tg_touch() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if to_jsonb(new) ? 'updated_by' then
    new := jsonb_populate_record(new, jsonb_build_object('updated_by', auth.uid()));
  end if;
  return new;
end $$;

-- ── AUDIT LOG ───────────────────────────────────────────────────────
create table public.audit_log (
  id          bigint generated always as identity primary key,
  user_id     uuid default auth.uid(),
  entity_type text not null,
  entity_id   uuid,
  action      text not null,
  old_value   jsonb,
  new_value   jsonb,
  created_at  timestamptz not null default now()
);
create index audit_log_entity_idx on public.audit_log (entity_type, entity_id, created_at desc);

-- Records only the fields that changed, so the log stays readable.
create or replace function public.tg_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare o jsonb; n jsonb; old_diff jsonb := '{}'; new_diff jsonb := '{}'; k text; act text;
begin
  if tg_op = 'INSERT' then
    insert into audit_log (entity_type, entity_id, action, new_value)
    values (tg_table_name, new.id, 'create', to_jsonb(new));
    return new;
  elsif tg_op = 'DELETE' then
    insert into audit_log (entity_type, entity_id, action, old_value)
    values (tg_table_name, old.id, 'delete', to_jsonb(old));
    return old;
  end if;
  o := to_jsonb(old); n := to_jsonb(new);
  for k in select jsonb_object_keys(n) loop
    continue when k in ('updated_at','updated_by');
    if o->k is distinct from n->k then
      old_diff := old_diff || jsonb_build_object(k, o->k);
      new_diff := new_diff || jsonb_build_object(k, n->k);
    end if;
  end loop;
  if new_diff = '{}' then return new; end if;
  act := case
    when new_diff ? 'archived_at' and n->>'archived_at' is not null then 'archive'
    when new_diff ? 'archived_at' then 'restore'
    when new_diff ? 'status' then 'status: ' || coalesce(o->>'status','') || ' → ' || coalesce(n->>'status','')
    when new_diff ? 'stage'  then 'stage: '  || coalesce(o->>'stage','')  || ' → ' || coalesce(n->>'stage','')
    else 'update' end;
  insert into audit_log (entity_type, entity_id, action, old_value, new_value)
  values (tg_table_name, new.id, act, old_diff, new_diff);
  return new;
end $$;

-- Workflow-level events ("proposal approved", "payment recorded") that are
-- more meaningful than the raw row changes they cause.
create or replace function public.log_event(p_entity text, p_id uuid, p_action text, p_detail jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into audit_log (entity_type, entity_id, action, new_value)
  select p_entity, p_id, p_action, p_detail
  where auth.uid() is null or public.is_active_user()
$$;

-- ── NOTIFICATIONS ───────────────────────────────────────────────────
create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references public.users(id) on delete cascade,  -- null = all owners/admins
  kind        text not null default 'info',
  title       text not null,
  body        text,
  entity_type text,
  entity_id   uuid,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index notifications_unread_idx on public.notifications (created_at desc) where read_at is null;

create trigger users_touch before update on public.users for each row execute function public.tg_touch();
create trigger users_audit after insert or update on public.users for each row execute function public.tg_audit();
create trigger settings_touch before update on public.settings for each row execute function public.tg_touch();

-- ════════ 0002_sales.sql ════════
-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0002 SALES
-- Customers, properties, leads (with qualification scoring), communications.
-- ════════════════════════════════════════════════════════════════════

create table public.customers (
  id               uuid primary key default gen_random_uuid(),
  customer_number  text not null unique default public.next_number('CUS', 'public.seq_customer'),
  first_name       text not null default '',
  last_name        text not null default '',
  company_name     text,
  phone            text,
  phone_digits     text generated always as (nullif(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), '')) stored,
  secondary_phone  text,
  email            text,
  secondary_email  text,
  billing_address  text,
  billing_city     text,
  billing_state    text default 'CA',
  billing_zip      text,
  lead_source      text,
  referral_source  text,
  customer_status  text not null default 'Lead'
                   check (customer_status in ('Lead','Active','Past Customer','VIP','Inactive','Do Not Contact')),
  notes            text,
  archived_at      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),
  updated_by       uuid default auth.uid(),
  constraint customers_has_name check (length(trim(first_name || last_name || coalesce(company_name, ''))) > 0)
);
create index customers_email_idx on public.customers (lower(email));
create index customers_phone_idx on public.customers (phone_digits);

-- One customer → many properties (home, rentals, second home...). Spec §8.
create table public.properties (
  id             uuid primary key default gen_random_uuid(),
  customer_id    uuid not null references public.customers(id),
  address        text not null,
  city           text,
  state          text default 'CA',
  zip            text,
  property_type  text default 'Single Family'
                 check (property_type in ('Single Family','Condo','Townhouse','Multi-Family','Rental','Commercial','Other')),
  square_footage integer,
  is_default     boolean not null default false,
  notes          text,
  archived_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  updated_by     uuid default auth.uid()
);
create index properties_customer_idx on public.properties (customer_id);

create table public.leads (
  id                        uuid primary key default gen_random_uuid(),
  lead_number               text not null unique default public.next_number('LEAD', 'public.seq_lead'),
  customer_id               uuid not null references public.customers(id),
  property_id               uuid references public.properties(id),
  source                    text,
  source_campaign           text,
  source_details            text,
  source_page               text,
  utm_source                text,
  utm_medium                text,
  utm_campaign              text,
  submitted_at              timestamptz,
  service_type              text,
  project_type              text,
  description               text,
  estimated_value           numeric(12,2) not null default 0,
  budget_min                numeric(12,2),
  budget_max                numeric(12,2),
  urgency                   text default 'Normal' check (urgency in ('Emergency','Urgent','Normal','Flexible')),
  preferred_start_date      date,
  preferred_completion_date date,
  -- qualification (spec §10)
  approx_size               text,
  photos_provided           boolean not null default false,
  decision_maker            text check (decision_maker in ('Yes','No','Unknown')) default 'Unknown',
  customer_availability     text,
  property_type             text,
  qualification_score       text check (qualification_score in ('A','B','C','D')),
  score_override            text check (score_override in ('A','B','C','D')),
  stage                     text not null default 'NEW LEAD'
                            check (stage in ('NEW LEAD','CONTACTED','QUALIFYING','SITE VISIT','ESTIMATE',
                                             'PROPOSAL SENT','FOLLOW-UP','WON','LOST')),
  stage_changed_at          timestamptz not null default now(),
  site_visit_required       boolean not null default false,
  site_visit_date           timestamptz,
  assigned_to               uuid references public.users(id) default auth.uid(),
  next_followup_at          timestamptz,
  last_contacted_at         timestamptz,
  lost_reason               text,
  lost_competitor           text,
  lost_notes                text,
  won_at                    timestamptz,
  notes                     text,
  archived_at               timestamptz,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  created_by                uuid default auth.uid(),
  updated_by                uuid default auth.uid(),
  -- A lead cannot silently disappear (spec §60).
  constraint leads_lost_needs_reason check (stage <> 'LOST' or lost_reason is not null)
);
create index leads_stage_idx on public.leads (stage) where archived_at is null;
create index leads_customer_idx on public.leads (customer_id);

-- ── LEAD SCORE ─────────────────────────────────────────────────────
-- A = high-value / high-fit, B = good, C = small / low priority, D = poor fit.
-- $8k cabinet job with photos, ready within 30 days → A.
-- $150 repair, no photos, "urgent tonight" → D.
create or replace function public.compute_lead_score(l public.leads) returns text
language plpgsql stable as $$
declare pts int := 0; v numeric := greatest(coalesce(l.estimated_value, 0), coalesce(l.budget_max, 0));
begin
  pts := pts + case when v >= 5000 then 3 when v >= 2000 then 2 when v >= 500 then 1 else 0 end;
  if coalesce(l.service_type, '') in (select jsonb_array_elements_text(public.setting('core_services'))) then pts := pts + 1; end if;
  if l.photos_provided then pts := pts + 1; end if;
  if l.preferred_start_date is not null and l.preferred_start_date <= current_date + 60 then pts := pts + 1; end if;
  if l.decision_maker = 'Yes' then pts := pts + 1; end if;
  if l.budget_min is not null or l.budget_max is not null then pts := pts + 1; end if;
  if l.urgency = 'Emergency' then pts := pts - 1; end if;
  return case when pts >= 6 then 'A' when pts >= 4 then 'B' when pts >= 2 then 'C' else 'D' end;
end $$;

create or replace function public.tg_leads_before() returns trigger language plpgsql as $$
begin
  new.qualification_score := coalesce(new.score_override, public.compute_lead_score(new));
  if tg_op = 'UPDATE' and new.stage is distinct from old.stage then
    new.stage_changed_at := now();
    -- Moving out of NEW LEAD means someone reached the customer: stops SLA reminders.
    if old.stage = 'NEW LEAD' and new.last_contacted_at is null then new.last_contacted_at := now(); end if;
    if new.stage = 'WON' and new.won_at is null then new.won_at := now(); end if;
  end if;
  return new;
end $$;

create trigger leads_before before insert or update on public.leads
  for each row execute function public.tg_leads_before();

-- ── COMMUNICATIONS (log only in V2; two-way email/SMS is P1) ─────────
create table public.communications (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customers(id),
  lead_id     uuid references public.leads(id),
  project_id  uuid,          -- FK added in 0004 once projects exists
  type        text not null check (type in ('Email','SMS','Phone','Internal Note','Website Form','Meeting')),
  direction   text not null default 'Outbound' check (direction in ('Inbound','Outbound','Internal')),
  subject     text,
  message     text,
  sent_at     timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create index communications_customer_idx on public.communications (customer_id, sent_at desc);

-- Logging a call/email with a lead counts as contact.
create or replace function public.tg_communications_after() returns trigger language plpgsql as $$
begin
  if new.lead_id is not null and new.direction = 'Outbound' then
    update public.leads set last_contacted_at = greatest(coalesce(last_contacted_at, new.sent_at), new.sent_at)
    where id = new.lead_id;
  end if;
  return new;
end $$;
create trigger communications_after after insert on public.communications
  for each row execute function public.tg_communications_after();

-- ── TRIGGERS ───────────────────────────────────────────────────────
create trigger customers_touch  before update on public.customers  for each row execute function public.tg_touch();
create trigger properties_touch before update on public.properties for each row execute function public.tg_touch();
create trigger leads_touch      before update on public.leads      for each row execute function public.tg_touch();
create trigger customers_audit  after insert or update or delete on public.customers  for each row execute function public.tg_audit();
create trigger properties_audit after insert or update or delete on public.properties for each row execute function public.tg_audit();
create trigger leads_audit      after insert or update or delete on public.leads      for each row execute function public.tg_audit();

-- ════════ 0003_estimating.sql ════════
-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0003 ESTIMATING
-- Price book is the foundation of estimating (spec §16, §48).
-- Every estimate line carries sell price AND labor / material / sub / other
-- cost, so gross profit and margin are known before the proposal goes out.
-- ════════════════════════════════════════════════════════════════════

create table public.pricebook_items (
  id                 uuid primary key default gen_random_uuid(),
  service            text not null,
  item               text not null,
  description        text,
  unit               text not null default 'each',
  sell_price         numeric(12,2) not null default 0,
  labor_hours        numeric(10,3) not null default 0,   -- per unit
  labor_rate         numeric(10,2) not null default 0,   -- loaded $/hr
  labor_cost         numeric(12,2) not null default 0,   -- per unit (= hours × rate when both set)
  material_cost      numeric(12,2) not null default 0,
  subcontractor_cost numeric(12,2) not null default 0,
  equipment_cost     numeric(12,2) not null default 0,
  other_cost         numeric(12,2) not null default 0,
  unit_cost          numeric(12,2) generated always as
                     (labor_cost + material_cost + subcontractor_cost + equipment_cost + other_cost) stored,
  margin             numeric(6,1) generated always as
                     (case when sell_price > 0 then round((sell_price - (labor_cost + material_cost + subcontractor_cost
                       + equipment_cost + other_cost)) / sell_price * 100, 1) end) stored,
  target_margin      numeric(5,2),
  minimum_charge     numeric(12,2),
  notes              text,
  active             boolean not null default true,
  active_from        date,
  active_to          date,
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid default auth.uid(),
  updated_by         uuid default auth.uid()
);

create or replace function public.tg_pricebook_before() returns trigger language plpgsql as $$
begin
  if new.labor_hours > 0 and new.labor_rate > 0 then
    new.labor_cost := round(new.labor_hours * new.labor_rate, 2);
  end if;
  return new;
end $$;
create trigger pricebook_before before insert or update on public.pricebook_items
  for each row execute function public.tg_pricebook_before();

-- Price that hits the target margin for this item's cost: cost ÷ (1 − margin).
create or replace function public.recommended_sell_price(p public.pricebook_items) returns numeric
language sql stable as $$
  select case when p.unit_cost > 0 then round(p.unit_cost /
    (1 - coalesce(p.target_margin, public.setting_num('pricing', 'target_margin', 40)) / 100.0), 2) end
$$;

-- ── ESTIMATES ──────────────────────────────────────────────────────
create table public.estimates (
  id                           uuid primary key default gen_random_uuid(),
  estimate_number              text not null unique default public.next_number('EST', 'public.seq_estimate'),
  lead_id                      uuid references public.leads(id),
  customer_id                  uuid not null references public.customers(id),
  property_id                  uuid references public.properties(id),
  project_id                   uuid,       -- FK added in 0004
  title                        text not null default '',
  status                       text not null default 'Draft'
                               check (status in ('Draft','Sent','Approved','Declined','Expired','Converted')),
  created_date                 date not null default current_date,
  expiration_date              date default current_date + 30,
  subtotal                     numeric(12,2) not null default 0,
  discount                     numeric(12,2) not null default 0 check (discount >= 0),
  tax                          numeric(12,2) not null default 0 check (tax >= 0),
  total                        numeric(12,2) not null default 0,
  estimated_labor_hours        numeric(10,2) not null default 0,
  estimated_labor_cost         numeric(12,2) not null default 0,
  estimated_material_cost      numeric(12,2) not null default 0,
  estimated_subcontractor_cost numeric(12,2) not null default 0,
  estimated_other_direct_cost  numeric(12,2) not null default 0,
  estimated_direct_cost        numeric(12,2) not null default 0,
  estimated_gross_profit       numeric(12,2) not null default 0,
  estimated_margin             numeric(6,1),
  notes                        text,
  exclusions                   text,
  assumptions                  text,
  sent_at                      timestamptz,
  approved_by                  uuid references public.users(id),
  archived_at                  timestamptz,
  created_at                   timestamptz not null default now(),
  updated_at                   timestamptz not null default now(),
  created_by                   uuid default auth.uid(),
  updated_by                   uuid default auth.uid()
);
create index estimates_customer_idx on public.estimates (customer_id);
create index estimates_lead_idx on public.estimates (lead_id);

create table public.estimate_items (
  id                      uuid primary key default gen_random_uuid(),
  estimate_id             uuid not null references public.estimates(id) on delete cascade,
  pricebook_item_id       uuid references public.pricebook_items(id),
  sort_order              integer not null default 0,
  description             text not null,
  category                text,
  quantity                numeric(12,3) not null default 1 check (quantity >= 0),
  unit                    text,
  -- per-unit values, snapshotted from the price book when the line is added
  unit_price              numeric(12,2) not null default 0,
  unit_labor_hours        numeric(10,3) not null default 0,
  unit_labor_cost         numeric(12,2) not null default 0,
  unit_material_cost      numeric(12,2) not null default 0,
  unit_subcontractor_cost numeric(12,2) not null default 0,
  unit_other_cost         numeric(12,2) not null default 0,
  -- line totals
  sell_total              numeric(12,2) generated always as (round(quantity * unit_price, 2)) stored,
  labor_hours             numeric(10,2) generated always as (round(quantity * unit_labor_hours, 2)) stored,
  labor_cost              numeric(12,2) generated always as (round(quantity * unit_labor_cost, 2)) stored,
  material_cost           numeric(12,2) generated always as (round(quantity * unit_material_cost, 2)) stored,
  subcontractor_cost      numeric(12,2) generated always as (round(quantity * unit_subcontractor_cost, 2)) stored,
  other_direct_cost       numeric(12,2) generated always as (round(quantity * unit_other_cost, 2)) stored,
  gross_profit            numeric(12,2) generated always as (round(quantity * (unit_price - unit_labor_cost
                            - unit_material_cost - unit_subcontractor_cost - unit_other_cost), 2)) stored,
  margin                  numeric(6,1) generated always as (case when unit_price > 0 then round((unit_price
                            - unit_labor_cost - unit_material_cost - unit_subcontractor_cost - unit_other_cost)
                            / unit_price * 100, 1) end) stored,
  notes                   text,
  created_at              timestamptz not null default now()
);
create index estimate_items_estimate_idx on public.estimate_items (estimate_id, sort_order);

-- Estimate header math lives in one place:
--   revenue        = subtotal − discount          (tax is pass-through, not revenue)
--   gross profit   = revenue − direct cost
--   margin         = gross profit ÷ revenue
create or replace function public.tg_estimates_before() returns trigger language plpgsql as $$
declare revenue numeric;
begin
  new.estimated_direct_cost := new.estimated_labor_cost + new.estimated_material_cost
                             + new.estimated_subcontractor_cost + new.estimated_other_direct_cost;
  revenue := new.subtotal - new.discount;
  new.total := revenue + new.tax;
  new.estimated_gross_profit := revenue - new.estimated_direct_cost;
  new.estimated_margin := case when revenue > 0 then round(new.estimated_gross_profit / revenue * 100, 1) end;
  if tg_op = 'UPDATE' and new.status = 'Sent' and old.status <> 'Sent' and new.sent_at is null then
    new.sent_at := now();
  end if;
  return new;
end $$;
create trigger estimates_before before insert or update on public.estimates
  for each row execute function public.tg_estimates_before();

create or replace function public.recalc_estimate(p_estimate_id uuid) returns void language sql as $$
  update public.estimates e set
    subtotal                     = coalesce(s.sell, 0),
    estimated_labor_hours        = coalesce(s.hours, 0),
    estimated_labor_cost         = coalesce(s.labor, 0),
    estimated_material_cost      = coalesce(s.material, 0),
    estimated_subcontractor_cost = coalesce(s.sub, 0),
    estimated_other_direct_cost  = coalesce(s.other, 0)
  from (select sum(sell_total) sell, sum(labor_hours) hours, sum(labor_cost) labor, sum(material_cost) material,
               sum(subcontractor_cost) sub, sum(other_direct_cost) other
        from public.estimate_items where estimate_id = p_estimate_id) s
  where e.id = p_estimate_id
$$;

create or replace function public.tg_estimate_items_after() returns trigger language plpgsql as $$
begin
  perform public.recalc_estimate(coalesce(new.estimate_id, old.estimate_id));
  if tg_op = 'UPDATE' and new.estimate_id <> old.estimate_id then perform public.recalc_estimate(old.estimate_id); end if;
  return null;
end $$;
create trigger estimate_items_after after insert or update or delete on public.estimate_items
  for each row execute function public.tg_estimate_items_after();

-- A price-book line inserted WITHOUT a description is a request to "fill it in
-- from the price book": snapshot sell price and every unit cost. Lines that
-- arrive with a description are taken exactly as sent (so a cost the estimator
-- deliberately set to $0 stays $0).
create or replace function public.tg_estimate_items_before() returns trigger language plpgsql as $$
declare p public.pricebook_items;
begin
  if tg_op = 'INSERT' and new.pricebook_item_id is not null and coalesce(new.description, '') = '' then
    select * into p from public.pricebook_items where id = new.pricebook_item_id;
    if found then
      new.description := p.item;
      new.category := coalesce(new.category, p.service);
      new.unit := coalesce(new.unit, p.unit);
      new.unit_price := p.sell_price;
      new.unit_labor_hours := p.labor_hours;
      new.unit_labor_cost := p.labor_cost;
      new.unit_material_cost := p.material_cost;
      new.unit_subcontractor_cost := p.subcontractor_cost;
      new.unit_other_cost := p.equipment_cost + p.other_cost;
    end if;
  end if;
  return new;
end $$;
create trigger estimate_items_before before insert on public.estimate_items
  for each row execute function public.tg_estimate_items_before();

create trigger pricebook_touch before update on public.pricebook_items for each row execute function public.tg_touch();
create trigger estimates_touch before update on public.estimates for each row execute function public.tg_touch();
create trigger pricebook_audit after insert or update or delete on public.pricebook_items for each row execute function public.tg_audit();
create trigger estimates_audit after insert or update or delete on public.estimates for each row execute function public.tg_audit();

-- ════════ 0004_projects_finance.sql ════════
-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0004 PROPOSALS, PROJECTS, FINANCE
-- ════════════════════════════════════════════════════════════════════

-- ── PROPOSALS ──────────────────────────────────────────────────────
create table public.proposals (
  id                     uuid primary key default gen_random_uuid(),
  proposal_number        text not null unique default public.next_number('PROP', 'public.seq_proposal'),
  estimate_id            uuid references public.estimates(id),
  lead_id                uuid references public.leads(id),
  customer_id            uuid not null references public.customers(id),
  property_id            uuid references public.properties(id),
  project_id             uuid,         -- set when approval creates the project
  status                 text not null default 'Draft'
                         check (status in ('Draft','Sent','Viewed','Follow-Up','Approved','Declined','Expired','Cancelled')),
  title                  text not null default '',
  scope_of_work          text,
  exclusions             text,
  assumptions            text,
  subtotal               numeric(12,2) not null default 0,
  discount               numeric(12,2) not null default 0,
  tax                    numeric(12,2) not null default 0,
  total                  numeric(12,2) not null default 0,
  estimated_direct_cost  numeric(12,2) not null default 0,
  estimated_labor_hours  numeric(10,2) not null default 0,
  estimated_gross_profit numeric(12,2) not null default 0,
  estimated_margin       numeric(6,1),
  deposit_type           text not null default 'Percent' check (deposit_type in ('Percent','Fixed','None')),
  deposit_percent        numeric(5,2) default 10,
  deposit_amount         numeric(12,2) not null default 0,
  payment_terms          text,
  valid_until            date default current_date + 30,
  sent_at                timestamptz,
  viewed_at              timestamptz,
  approved_at            timestamptz,
  declined_at            timestamptz,
  decline_reason         text,
  customer_signature     text,
  signed_at              timestamptz,
  contract_document_id   uuid,
  archived_at            timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid default auth.uid(),
  updated_by             uuid default auth.uid()
);
create index proposals_customer_idx on public.proposals (customer_id);

create table public.proposal_items (
  id          uuid primary key default gen_random_uuid(),
  proposal_id uuid not null references public.proposals(id) on delete cascade,
  sort_order  integer not null default 0,
  description text not null,
  quantity    numeric(12,3) not null default 1,
  unit        text,
  unit_price  numeric(12,2) not null default 0,
  total       numeric(12,2) generated always as (round(quantity * unit_price, 2)) stored
);
create index proposal_items_proposal_idx on public.proposal_items (proposal_id, sort_order);

-- Deposit is computed on the server and capped by settings.deposit.max_amount
-- (California B&P §7159: lesser of $1,000 or 10%).
create or replace function public.tg_proposals_before() returns trigger language plpgsql as $$
declare cap numeric := public.setting_num('deposit', 'max_amount', 1000);
begin
  if tg_op = 'UPDATE' and old.status = 'Approved' then
    -- Contract value is locked once approved. Changes go through change orders.
    if (new.total, new.subtotal, new.discount, new.tax, new.deposit_amount)
       is distinct from (old.total, old.subtotal, old.discount, old.tax, old.deposit_amount) then
      raise exception 'Proposal % is approved — contract value is locked. Use a change order.', old.proposal_number;
    end if;
    if new.status <> 'Approved' then
      raise exception 'Proposal % is approved and cannot change status.', old.proposal_number;
    end if;
    return new;
  end if;
  new.total := new.subtotal - new.discount + new.tax;
  new.estimated_gross_profit := (new.subtotal - new.discount) - new.estimated_direct_cost;
  new.estimated_margin := case when new.subtotal - new.discount > 0
    then round(new.estimated_gross_profit / (new.subtotal - new.discount) * 100, 1) end;
  if new.deposit_type = 'Percent' then
    new.deposit_amount := least(round(new.total * coalesce(new.deposit_percent, 0) / 100, 2), cap);
  elsif new.deposit_type = 'None' then
    new.deposit_amount := 0;
  end if;
  if new.deposit_amount > new.total then
    raise exception 'Deposit (%) cannot exceed the proposal total (%).', new.deposit_amount, new.total;
  end if;
  return new;
end $$;
create trigger proposals_before before insert or update on public.proposals
  for each row execute function public.tg_proposals_before();

-- ── PROJECTS ───────────────────────────────────────────────────────
create table public.projects (
  id                     uuid primary key default gen_random_uuid(),
  project_number         text not null unique default public.next_number('PRJ', 'public.seq_project'),
  customer_id            uuid not null references public.customers(id),
  property_id            uuid references public.properties(id),
  lead_id                uuid references public.leads(id),
  estimate_id            uuid references public.estimates(id),
  proposal_id            uuid unique references public.proposals(id),   -- one project per proposal, ever
  project_name           text not null,
  project_type           text,
  service_category       text,
  status                 text not null default 'Pending Deposit'
                         check (status in ('Pending Deposit','Ready to Schedule','Scheduled','Pre-Construction',
                                           'In Progress','On Hold','Punch List','QC','Completed','Closed','Cancelled')),
  contract_value         numeric(12,2) not null default 0,
  approved_change_orders numeric(12,2) not null default 0,
  current_contract_value numeric(12,2) generated always as (contract_value + approved_change_orders) stored,
  estimated_cost         numeric(12,2) not null default 0,
  budgeted_hours         numeric(10,2) not null default 0,
  deposit_required       boolean not null default false,
  deposit_amount         numeric(12,2) not null default 0,
  deposit_paid           boolean not null default false,
  start_date             date,
  estimated_end_date     date,
  actual_start_date      date,
  actual_end_date        date,
  percent_complete       numeric(5,2) not null default 0 check (percent_complete between 0 and 100),
  project_manager_id     uuid references public.users(id),
  crew_leader_id         uuid references public.users(id),
  scope_of_work          text,
  notes                  text,
  archived_at            timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid default auth.uid(),
  updated_by             uuid default auth.uid()
);
create index projects_status_idx on public.projects (status) where archived_at is null;
create index projects_customer_idx on public.projects (customer_id);

alter table public.proposals add constraint proposals_project_fk foreign key (project_id) references public.projects(id);
alter table public.estimates add constraint estimates_project_fk foreign key (project_id) references public.projects(id);
alter table public.communications add constraint communications_project_fk foreign key (project_id) references public.projects(id);

create or replace function public.tg_projects_before() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'In Progress' and new.actual_start_date is null then new.actual_start_date := current_date; end if;
    if new.status in ('Completed','Closed') and new.actual_end_date is null then new.actual_end_date := current_date; end if;
    if new.status in ('Completed','Closed') then new.percent_complete := 100; end if;
  end if;
  return new;
end $$;
create trigger projects_before before insert or update on public.projects
  for each row execute function public.tg_projects_before();

create table public.project_checklist_items (
  id         uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  phase      text not null default 'Pre-Construction' check (phase in ('Pre-Construction','Closeout','QC')),
  label      text not null,
  sort_order integer not null default 0,
  done_at    timestamptz,
  done_by    uuid references public.users(id),
  created_at timestamptz not null default now()
);
create index checklist_project_idx on public.project_checklist_items (project_id, phase, sort_order);

-- ── TASKS ──────────────────────────────────────────────────────────
create table public.tasks (
  id                uuid primary key default gen_random_uuid(),
  title             text not null,
  description       text,
  customer_id       uuid references public.customers(id),
  lead_id           uuid references public.leads(id),
  project_id        uuid references public.projects(id),
  estimate_id       uuid references public.estimates(id),
  proposal_id       uuid references public.proposals(id),
  invoice_id        uuid,                 -- FK below
  assigned_to       uuid references public.users(id) default auth.uid(),
  due_at            timestamptz,
  priority          text not null default 'Medium' check (priority in ('Urgent','High','Medium','Low')),
  status            text not null default 'Pending' check (status in ('Pending','In Progress','Completed','Cancelled')),
  task_type         text,
  automation_source text,                -- rule name that created it; null = manual
  dedupe_key        text,                -- stops an automation creating the same task twice
  completed_at      timestamptz,
  completed_by      uuid references public.users(id),
  notes             text,
  archived_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid default auth.uid(),
  updated_by        uuid default auth.uid()
);
create unique index tasks_dedupe_idx on public.tasks (dedupe_key) where dedupe_key is not null;
create index tasks_open_idx on public.tasks (due_at) where status in ('Pending','In Progress') and archived_at is null;
create index tasks_project_idx on public.tasks (project_id);

create or replace function public.tg_tasks_before() returns trigger language plpgsql as $$
begin
  if new.status = 'Completed' and (tg_op = 'INSERT' or old.status <> 'Completed') then
    new.completed_at := coalesce(new.completed_at, now());
    new.completed_by := coalesce(new.completed_by, auth.uid());
  elsif new.status <> 'Completed' then
    new.completed_at := null; new.completed_by := null;
  end if;
  return new;
end $$;
create trigger tasks_before before insert or update on public.tasks for each row execute function public.tg_tasks_before();

-- ── CALENDAR ───────────────────────────────────────────────────────
create table public.calendar_events (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  type        text not null default 'Other'
              check (type in ('Lead Call','Site Visit','Estimate','Customer Meeting','Material Pickup','Project Start',
                              'Project Work','Inspection','Final Walkthrough','QC','Other')),
  customer_id uuid references public.customers(id),
  project_id  uuid references public.projects(id),
  lead_id     uuid references public.leads(id),
  assigned_to uuid references public.users(id) default auth.uid(),
  event_date  date,                       -- null = placeholder waiting to be scheduled
  start_time  time,
  end_time    time,
  location    text,
  status      text not null default 'Scheduled' check (status in ('Unscheduled','Tentative','Scheduled','Completed','Cancelled')),
  notes       text,
  reminder_minutes integer,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  updated_by  uuid default auth.uid()
);
create index calendar_date_idx on public.calendar_events (event_date);

-- ── INVOICES ───────────────────────────────────────────────────────
create table public.invoices (
  id             uuid primary key default gen_random_uuid(),
  invoice_number text not null unique default public.next_number('INV', 'public.seq_invoice'),
  customer_id    uuid not null references public.customers(id),
  project_id     uuid references public.projects(id),
  proposal_id    uuid references public.proposals(id),
  type           text not null default 'Other' check (type in ('Deposit','Progress','Change Order','Final','Other')),
  status         text not null default 'Draft' check (status in ('Draft','Sent','Partially Paid','Paid','Void')),
  issue_date     date not null default current_date,
  due_date       date,
  subtotal       numeric(12,2) not null default 0,
  discount       numeric(12,2) not null default 0,
  tax            numeric(12,2) not null default 0,
  total          numeric(12,2) generated always as (subtotal - discount + tax) stored,
  amount_paid    numeric(12,2) not null default 0,
  balance_due    numeric(12,2) generated always as (subtotal - discount + tax - amount_paid) stored,
  payment_terms  text,
  description    text,
  sent_at        timestamptz,
  viewed_at      timestamptz,
  paid_at        timestamptz,
  notes          text,
  archived_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  updated_by     uuid default auth.uid(),
  constraint invoices_total_nonneg check (subtotal - discount + tax >= 0)
);
create index invoices_project_idx on public.invoices (project_id);
create index invoices_open_idx on public.invoices (due_date) where status in ('Sent','Partially Paid');
alter table public.tasks add constraint tasks_invoice_fk foreign key (invoice_id) references public.invoices(id);

-- Status follows money. Draft and Void are set by people; everything else is derived.
create or replace function public.tg_invoices_before() returns trigger language plpgsql as $$
declare tot numeric := new.subtotal - new.discount + new.tax;
begin
  if new.status = 'Void' then return new; end if;
  if new.amount_paid >= tot and tot > 0 then
    new.status := 'Paid'; new.paid_at := coalesce(new.paid_at, now());
  elsif new.amount_paid > 0 then
    new.status := 'Partially Paid'; new.paid_at := null;
  elsif new.status in ('Paid','Partially Paid') then
    new.status := 'Sent'; new.paid_at := null;
  end if;
  if new.status = 'Sent' and new.sent_at is null then new.sent_at := now(); end if;
  return new;
end $$;
create trigger invoices_before before insert or update on public.invoices for each row execute function public.tg_invoices_before();

-- ── PAYMENTS ───────────────────────────────────────────────────────
create table public.payments (
  id             uuid primary key default gen_random_uuid(),
  invoice_id     uuid not null references public.invoices(id),
  customer_id    uuid not null references public.customers(id),
  project_id     uuid references public.projects(id),
  amount         numeric(12,2) not null check (amount > 0),
  payment_date   date not null default current_date,
  method         text not null default 'Zelle',
  reference      text,
  kind           text check (kind in ('Deposit','Progress','Change Order','Final','Other')),
  is_overpayment boolean not null default false,
  notes          text,
  voided_at      timestamptz,
  void_reason    text,
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid()
);
create index payments_invoice_idx on public.payments (invoice_id);
create index payments_date_idx on public.payments (payment_date);

-- Never accept more than the remaining balance unless explicitly flagged (spec §42).
create or replace function public.tg_payments_before() returns trigger language plpgsql as $$
declare inv public.invoices;
begin
  select * into inv from public.invoices where id = new.invoice_id for update;
  if not found then raise exception 'Invoice not found'; end if;
  if inv.status = 'Void' then raise exception 'Invoice % is void.', inv.invoice_number; end if;
  new.customer_id := inv.customer_id;
  new.project_id := inv.project_id;
  new.kind := coalesce(new.kind, inv.type);
  if tg_op = 'INSERT' and new.amount > inv.balance_due and not new.is_overpayment then
    raise exception 'Payment of $% exceeds the remaining balance of $% on %. Mark it as an overpayment to proceed.',
      new.amount, inv.balance_due, inv.invoice_number using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE' and (new.amount, new.invoice_id) is distinct from (old.amount, old.invoice_id) then
    raise exception 'Payments cannot be edited. Void it and record a new one.';
  end if;
  return new;
end $$;
create trigger payments_before before insert or update on public.payments for each row execute function public.tg_payments_before();

create or replace function public.recalc_invoice_paid(p_invoice_id uuid) returns void language sql as $$
  update public.invoices set amount_paid = coalesce((select sum(amount) from public.payments
    where invoice_id = p_invoice_id and voided_at is null), 0)
  where id = p_invoice_id
$$;

create or replace function public.tg_payments_after() returns trigger language plpgsql as $$
begin
  perform public.recalc_invoice_paid(new.invoice_id);
  return null;
end $$;
create trigger payments_after after insert or update on public.payments for each row execute function public.tg_payments_after();

-- ── EXPENSES ───────────────────────────────────────────────────────
create table public.expenses (
  id                   uuid primary key default gen_random_uuid(),
  project_id           uuid references public.projects(id),
  vendor               text,
  expense_date         date not null default current_date,
  category             text not null default 'Materials'
                       check (category in ('Materials','Labor','Subcontractor','Delivery','Disposal','Equipment',
                                           'Fuel','Tools','Permit','Other Direct Cost','Overhead')),
  subcategory          text,
  description          text,
  amount               numeric(12,2) not null check (amount >= 0),
  tax                  numeric(12,2) not null default 0,
  total                numeric(12,2) generated always as (amount + tax) stored,
  payment_method       text,
  receipt_file_id      uuid,               -- storage upload is P1
  billable             boolean not null default false,
  change_order_id      uuid,               -- change orders arrive in Phase 6
  archived_at          timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  created_by           uuid default auth.uid(),
  updated_by           uuid default auth.uid()
);
create index expenses_project_idx on public.expenses (project_id);

-- ── TIME / LABOR ───────────────────────────────────────────────────
create table public.time_entries (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users(id) default auth.uid(),
  project_id    uuid references public.projects(id),
  entry_date    date not null default current_date,
  start_time    time,
  end_time      time,
  break_minutes integer not null default 0 check (break_minutes >= 0),
  hours         numeric(6,2) not null default 0 check (hours >= 0 and hours <= 24),
  labor_rate    numeric(10,2),
  burden_rate   numeric(10,2),
  labor_cost    numeric(12,2) generated always as
                (round(hours * (coalesce(labor_rate, 0) + coalesce(burden_rate, 0)), 2)) stored,
  -- Owner KPI buckets (spec §23). Field = on the tools; the rest is running the company.
  work_category text not null default 'Field' check (work_category in ('Field','Admin','Sales','Management','Travel')),
  notes         text,
  archived_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  updated_by    uuid default auth.uid()
);
create index time_entries_project_idx on public.time_entries (project_id);
create index time_entries_user_date_idx on public.time_entries (user_id, entry_date);

-- Hours from clock times, and a loaded labor rate so owner hours are costed
-- like an employee's: "is this job profitable if someone else does it?"
create or replace function public.tg_time_entries_before() returns trigger language plpgsql as $$
declare u public.users; mins numeric;
begin
  if new.start_time is not null and new.end_time is not null then
    mins := extract(epoch from (new.end_time - new.start_time)) / 60;
    if mins < 0 then mins := mins + 1440; end if;            -- crossed midnight
    new.hours := round(greatest(mins - new.break_minutes, 0) / 60, 2);
  end if;
  if new.labor_rate is null or new.burden_rate is null then
    select * into u from public.users where id = new.user_id;
    if coalesce(u.labor_rate, 0) + coalesce(u.burden_rate, 0) > 0 then
      new.labor_rate := coalesce(new.labor_rate, u.labor_rate);
      new.burden_rate := coalesce(new.burden_rate, u.burden_rate);
    elsif u.role = 'owner' then
      new.labor_rate := coalesce(new.labor_rate, public.setting_num('labor', 'owner_loaded_rate', 40));
      new.burden_rate := coalesce(new.burden_rate, 0);
    else
      new.labor_rate := coalesce(new.labor_rate, public.setting_num('labor', 'default_labor_rate', 32));
      new.burden_rate := coalesce(new.burden_rate, public.setting_num('labor', 'default_burden_rate', 8));
    end if;
  end if;
  return new;
end $$;
create trigger time_entries_before before insert or update on public.time_entries
  for each row execute function public.tg_time_entries_before();

-- ── MATERIALS (tracking; actual spend is recorded as expenses) ─────
create table public.materials (
  id                 uuid primary key default gen_random_uuid(),
  project_id         uuid not null references public.projects(id),
  name               text not null,
  description        text,
  category           text,
  quantity           numeric(12,3) not null default 1,
  unit               text,
  vendor             text,
  vendor_item_number text,
  estimated_cost     numeric(12,2) not null default 0,
  actual_cost        numeric(12,2),
  status             text not null default 'Needed'
                     check (status in ('Needed','Quoted','Approved','Ordered','Partially Received','Received',
                                       'Installed','Returned','Cancelled')),
  ordered_date       date,
  expected_date      date,
  received_date      date,
  installed_date     date,
  notes              text,
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid default auth.uid(),
  updated_by         uuid default auth.uid()
);
create index materials_project_idx on public.materials (project_id);

-- ── TRIGGERS ───────────────────────────────────────────────────────
do $$ declare t text; begin
  foreach t in array array['proposals','projects','tasks','calendar_events','invoices','expenses','time_entries','materials'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.tg_touch()', t || '_touch', t);
  end loop;
  foreach t in array array['proposals','projects','tasks','invoices','payments','expenses','time_entries','materials','calendar_events'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.tg_audit()', t || '_audit', t);
  end loop;
end $$;

-- ════════ 0005_automation.sql ════════
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

-- ════════ 0006_rules_intake_views.sql ════════
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

-- ════════ 0007_security.sql ════════
-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0007 SECURITY
-- Row-level security on every table. Today: any ACTIVE user (the owner)
-- has full access; anonymous visitors and pending sign-ups see nothing.
-- When employees are added, these policies are where crew-level scoping
-- goes (spec §67) — the tables do not change.
-- ════════════════════════════════════════════════════════════════════

do $$
declare t text;
begin
  foreach t in array array[
    'customers','properties','leads','communications','pricebook_items','estimates','estimate_items',
    'proposals','proposal_items','projects','project_checklist_items','tasks','calendar_events',
    'invoices','payments','expenses','time_entries','materials','notifications'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy staff_all on public.%I for all to authenticated
                    using (public.is_active_user()) with check (public.is_active_user())', t);
  end loop;
end $$;

-- Users: everyone active can see the team; you can edit yourself; owner/admin edit anyone.
alter table public.users enable row level security;
create policy users_read on public.users for select to authenticated using (public.is_active_user() or id = auth.uid());
create policy users_update on public.users for update to authenticated
  using (id = auth.uid() or public.current_role_name() in ('owner','admin'))
  with check (id = auth.uid() or public.current_role_name() in ('owner','admin'));

-- Nobody can promote themselves or change their own status.
create or replace function public.tg_users_guard() returns trigger language plpgsql as $$
begin
  if auth.uid() = new.id and (new.role is distinct from old.role or new.status is distinct from old.status)
     and coalesce(public.current_role_name(), '') <> 'owner' then
    raise exception 'You cannot change your own role or status.';
  end if;
  return new;
end $$;
create trigger users_guard before update on public.users for each row execute function public.tg_users_guard();

-- Settings and automation rules: read by staff, changed by owner/admin.
alter table public.settings enable row level security;
create policy settings_read on public.settings for select to authenticated using (public.is_active_user());
create policy settings_write on public.settings for all to authenticated
  using (public.current_role_name() in ('owner','admin')) with check (public.current_role_name() in ('owner','admin'));

alter table public.automation_rules enable row level security;
create policy rules_read on public.automation_rules for select to authenticated using (public.is_active_user());
create policy rules_write on public.automation_rules for all to authenticated
  using (public.current_role_name() in ('owner','admin')) with check (public.current_role_name() in ('owner','admin'));

-- Audit and automation logs are append-only from triggers; staff can read them.
alter table public.audit_log enable row level security;
create policy audit_read on public.audit_log for select to authenticated using (public.current_role_name() in ('owner','admin'));
alter table public.automation_log enable row level security;
create policy autolog_read on public.automation_log for select to authenticated using (public.is_active_user());
alter table public.scheduled_actions enable row level security;
create policy sched_read on public.scheduled_actions for select to authenticated using (public.is_active_user());

-- Financial history is never hard-deleted: void payments, archive the rest.
revoke delete on public.payments, public.invoices, public.audit_log, public.automation_log from authenticated, anon;
revoke update on public.audit_log, public.automation_log from authenticated, anon;

-- ── FUNCTION EXPOSURE ──────────────────────────────────────────────
-- Supabase exposes every public function as an RPC endpoint. Anonymous
-- callers get none of them; the engine internals are not callable directly.
revoke execute on all functions in schema public from anon, public;
revoke execute on function
  public.emit(text, text, uuid, jsonb),
  public.run_action(jsonb, jsonb, public.automation_rules, int),
  public.run_rule(public.automation_rules, jsonb),
  public.process_scheduled_actions(),
  public.build_ctx(text, uuid),
  public.handle_new_auth_user(),
  public.intake_website_lead(jsonb)
from authenticated;
grant execute on function public.intake_website_lead(jsonb) to service_role;

-- ── SCHEDULER ──────────────────────────────────────────────────────
-- On Supabase, pg_cron runs delayed automations every 5 minutes.
-- (Skipped automatically where pg_cron is unavailable, e.g. local tests.)
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    execute $cron$ select cron.schedule('goldex-maintenance', '*/5 * * * *', 'select public.run_maintenance()') $cron$;
  end if;
end $$;

-- ════════ 0008_import_v1.sql ════════
-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0008 V1 IMPORT
-- import_v1(payload) takes the V1 browser export
--   { "customers": [...], "leads": [...], "projects": [...], ... }
-- (the gx_* localStorage keys without the prefix) and loads it into V2,
-- turning name/array-position links into real foreign keys.
-- Runs in one transaction with automations suppressed.
-- ════════════════════════════════════════════════════════════════════

create or replace function public.v1_due(d text) returns timestamptz language sql stable as $$
  select case when nullif(d, '') is null then null
              else (d::date + time '17:00')::timestamp at time zone 'America/Los_Angeles' end
$$;

create or replace function public.import_v1(payload jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare
  m jsonb := '{}';          -- v1 id → v2 uuid
  r jsonb; it jsonb; i int; new_id uuid; prop_id uuid; owner uuid;
  counts jsonb := '{}'; n int; paid_sum numeric; status_map jsonb;
begin
  perform public.assert_active();
  if exists (select 1 from customers where notes like '%[v1:%') then
    raise exception 'V1 data has already been imported.';
  end if;
  perform set_config('goldex.suppress_automation', 'on', true);
  owner := coalesce(auth.uid(), public.owner_user_id());

  -- price book
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'pricebook', '[]')) loop
    insert into pricebook_items (service, item, unit, sell_price, labor_cost, material_cost, notes, active)
    values (coalesce(r->>'service', 'Custom'), coalesce(r->>'item', 'Item'), coalesce(r->>'unit', 'each'),
            coalesce((r->>'sell')::numeric, 0), coalesce((r->>'labor')::numeric, 0), coalesce((r->>'material')::numeric, 0),
            r->>'notes', coalesce((r->>'active')::boolean, true))
    returning id into new_id;
    m := m || jsonb_build_object(r->>'id', new_id); n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('pricebook', n);

  -- customers (+ address → property)
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'customers', '[]')) loop
    insert into customers (first_name, last_name, company_name, phone, email, billing_address, lead_source,
                           customer_status, notes, created_at)
    values (coalesce(r->>'first', ''), coalesce(r->>'last', ''), nullif(r->>'company', ''), r->>'phone', r->>'email',
            r->>'address', r->>'source',
            case when r->>'status' in ('Lead','Active','Past Customer','VIP','Inactive','Do Not Contact') then r->>'status' else 'Active' end,
            trim(coalesce(r->>'notes', '') || ' [v1:' || (r->>'id') || ']'),
            coalesce((r->>'created')::date, current_date))
    returning id into new_id;
    m := m || jsonb_build_object(r->>'id', new_id);
    if nullif(r->>'address', '') is not null then
      insert into properties (customer_id, address, is_default) values (new_id, r->>'address', true) returning id into prop_id;
      m := m || jsonb_build_object('prop:' || (r->>'id'), prop_id);
    end if;
    n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('customers', n);

  -- leads
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'leads', '[]')) loop
    continue when m->>(r->>'customer') is null;
    insert into leads (customer_id, property_id, service_type, estimated_value, stage, source, description,
                       next_followup_at, notes, created_at, lost_reason, assigned_to)
    values ((m->>(r->>'customer'))::uuid, (m->>('prop:' || (r->>'customer')))::uuid, r->>'type',
            coalesce((r->>'value')::numeric, 0),
            case when r->>'stage' like 'SITE VISIT%' then 'SITE VISIT'
                 when r->>'stage' in ('NEW LEAD','CONTACTED','QUALIFYING','ESTIMATE','PROPOSAL SENT','FOLLOW-UP','WON','LOST') then r->>'stage'
                 else 'NEW LEAD' end,
            r->>'source', r->>'desc', public.v1_due(r->>'followup'), r->>'notes',
            coalesce((r->>'created')::date, current_date),
            case when r->>'stage' = 'LOST' then 'Other' end, owner)
    returning id into new_id;
    m := m || jsonb_build_object(r->>'id', new_id); n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('leads', n);

  -- projects (+ embedded materials and closeout checklist)
  n := 0;
  status_map := '{"WON":"Pending Deposit","CONTRACTED":"Pending Deposit","DEPOSIT PAID":"Ready to Schedule",
                  "SCHEDULED":"Scheduled","MATERIALS READY":"Pre-Construction","IN PROGRESS":"In Progress",
                  "PUNCH LIST":"Punch List","COMPLETED":"Completed","FINAL INVOICE":"Completed","PAID":"Completed","CLOSED":"Closed"}';
  for r in select value from jsonb_array_elements(coalesce(payload->'projects', '[]')) loop
    continue when m->>(r->>'customer') is null;
    insert into projects (customer_id, property_id, project_name, project_type, service_category, status, contract_value,
                          deposit_required, deposit_amount, deposit_paid, start_date, estimated_end_date, scope_of_work, notes,
                          project_manager_id)
    values ((m->>(r->>'customer'))::uuid, (m->>('prop:' || (r->>'customer')))::uuid,
            coalesce(r->>'name', 'Project'), r->>'type', r->>'type',
            case when coalesce(status_map->>(r->>'status'), 'Pending Deposit') = 'Pending Deposit'
                      and (coalesce((r->>'deposited')::boolean, false) or coalesce((r->>'deposit')::numeric, 0) = 0)
                 then 'Ready to Schedule' else coalesce(status_map->>(r->>'status'), 'Pending Deposit') end,
            coalesce((r->>'value')::numeric, 0),
            coalesce((r->>'deposit')::numeric, 0) > 0, coalesce((r->>'deposit')::numeric, 0),
            coalesce((r->>'deposited')::boolean, false),
            nullif(r->>'start', '')::date, nullif(r->>'end', '')::date, r->>'desc', r->>'notes', owner)
    returning id into new_id;
    m := m || jsonb_build_object(r->>'id', new_id);
    for it in select value from jsonb_array_elements(coalesce(r->'materials', '[]')) loop
      insert into materials (project_id, name, vendor, estimated_cost, status)
      values (new_id, coalesce(it->>'name', 'Material'), it->>'vendor', coalesce((it->>'cost')::numeric, 0),
              case when it->>'status' in ('Needed','Ordered','Received','Installed') then it->>'status' else 'Needed' end);
    end loop;
    if jsonb_array_length(coalesce(r->'closeout', '[]')) > 0 then
      for i in 0 .. jsonb_array_length(public.setting('closeout_checklist')) - 1 loop
        insert into project_checklist_items (project_id, phase, label, sort_order, done_at)
        values (new_id, 'Closeout', public.setting('closeout_checklist')->>i, i,
                case when r->'closeout' @> to_jsonb(i) then now() end);
      end loop;
    end if;
    n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('projects', n);

  -- estimates (+ items; price-book costs attached when the description matches an item)
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'estimates', '[]')) loop
    continue when m->>(r->>'customer') is null;
    insert into estimates (customer_id, property_id, title, status, created_date, expiration_date, discount, tax, notes)
    values ((m->>(r->>'customer'))::uuid, (m->>('prop:' || (r->>'customer')))::uuid, coalesce(r->>'project', ''),
            case when r->>'status' in ('Draft','Sent','Approved','Declined','Expired') then r->>'status' else 'Draft' end,
            coalesce(nullif(r->>'created', '')::date, current_date), nullif(r->>'expires', '')::date,
            coalesce((r->>'discount')::numeric, 0), coalesce((r->>'tax')::numeric, 0), r->>'notes')
    returning id into new_id;
    m := m || jsonb_build_object(r->>'id', new_id);
    i := 0;
    for it in select value from jsonb_array_elements(coalesce(r->'items', '[]')) loop
      -- A matching price-book item is inserted with a blank description so the
      -- trigger snapshots its costs; the V1 sell price then overrides.
      insert into estimate_items (estimate_id, pricebook_item_id, sort_order, description, quantity, unit, unit_price)
      select new_id, pb.id, i, case when pb.id is null then coalesce(it->>'desc', 'Item') else '' end,
             coalesce((it->>'qty')::numeric, 1), it->>'unit', coalesce((it->>'price')::numeric, 0)
      from (select (select id from pricebook_items where lower(item) = lower(it->>'desc') limit 1) id) pb
      returning id into prop_id;
      update estimate_items set unit_price = coalesce((it->>'price')::numeric, 0) where id = prop_id;
      i := i + 1;
    end loop;
    n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('estimates', n);

  -- proposals
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'proposals', '[]')) loop
    continue when m->>(r->>'customer') is null;
    insert into proposals (estimate_id, customer_id, title, status, subtotal, discount, scope_of_work, sent_at, approved_at, deposit_type)
    values ((m->>(r->>'estimate'))::uuid, (m->>(r->>'customer'))::uuid, coalesce(r->>'project', ''),
            case when r->>'status' in ('Draft','Sent','Approved') then r->>'status' else 'Draft' end,
            (select coalesce(sum(coalesce((x->>'qty')::numeric, 1) * coalesce((x->>'price')::numeric, 0)), 0)
             from jsonb_array_elements(coalesce(r->'items', '[]')) x),
            coalesce((r->>'discount')::numeric, 0), r->>'notes',
            public.v1_due(r->>'sent'), case when r->>'status' = 'Approved' then now() end, 'None')
    returning id into new_id;
    i := 0;
    for it in select value from jsonb_array_elements(coalesce(r->'items', '[]')) loop
      insert into proposal_items (proposal_id, sort_order, description, quantity, unit, unit_price)
      values (new_id, i, coalesce(it->>'desc', 'Item'), coalesce((it->>'qty')::numeric, 1), it->>'unit', coalesce((it->>'price')::numeric, 0));
      i := i + 1;
    end loop;
    n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('proposals', n);

  -- invoices + payments (keeps V1 invoice numbers customers may already have)
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'invoices', '[]')) loop
    continue when m->>(r->>'customer') is null;
    insert into invoices (invoice_number, customer_id, project_id, type, status, issue_date, due_date, subtotal, notes)
    values (coalesce(nullif(r->>'number', ''), public.next_number('INV', 'public.seq_invoice')),
            (m->>(r->>'customer'))::uuid, (m->>(r->>'project'))::uuid, 'Other', 'Sent',
            coalesce(nullif(r->>'created', '')::date, current_date), nullif(r->>'due', '')::date,
            coalesce((r->>'amount')::numeric, 0), r->>'notes')
    returning id into new_id;
    m := m || jsonb_build_object(r->>'id', new_id); n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('invoices', n);

  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'payments', '[]')) loop
    continue when m->>(r->>'invoice') is null or coalesce((r->>'amount')::numeric, 0) <= 0;
    insert into payments (invoice_id, customer_id, amount, payment_date, method, reference, notes, is_overpayment)
    values ((m->>(r->>'invoice'))::uuid, (m->>(r->>'customer'))::uuid, (r->>'amount')::numeric,
            coalesce(nullif(r->>'date', '')::date, current_date), coalesce(nullif(r->>'method', ''), 'Other'),
            nullif(r->>'ref', ''), r->>'notes', true);
    n := n + 1;
  end loop;
  -- V1 sometimes stored "paid" on the invoice without a payment record; carry the difference over.
  for r in select value from jsonb_array_elements(coalesce(payload->'invoices', '[]')) loop
    continue when m->>(r->>'id') is null;
    select coalesce(sum(amount), 0) into paid_sum from payments where invoice_id = (m->>(r->>'id'))::uuid;
    if coalesce((r->>'paid')::numeric, 0) > paid_sum then
      insert into payments (invoice_id, customer_id, amount, method, notes, is_overpayment)
      values ((m->>(r->>'id'))::uuid, (m->>(r->>'customer'))::uuid, (r->>'paid')::numeric - paid_sum, 'Other',
              'Paid amount carried over from V1', true);
      n := n + 1;
    end if;
  end loop;
  counts := counts || jsonb_build_object('payments', n);

  -- expenses
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'expenses', '[]')) loop
    insert into expenses (project_id, expense_date, category, vendor, description, amount)
    values ((m->>(r->>'project'))::uuid, coalesce(nullif(r->>'date', '')::date, current_date),
            case when r->>'category' in ('Materials','Subcontractor','Delivery','Disposal','Fuel','Tools') then r->>'category'
                 else 'Other Direct Cost' end,
            r->>'vendor', r->>'desc', coalesce((r->>'amount')::numeric, 0));
    n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('expenses', n);

  -- time entries (all V1 time was the owner's)
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'timeentries', '[]')) loop
    insert into time_entries (user_id, project_id, entry_date, start_time, end_time, break_minutes, hours, work_category, notes)
    values (owner, (m->>(r->>'project'))::uuid, coalesce(nullif(r->>'date', '')::date, current_date),
            nullif(r->>'start', '')::time, nullif(r->>'end', '')::time, coalesce((r->>'break')::int, 0),
            coalesce((r->>'hours')::numeric, 0),
            case when m->>(r->>'project') is not null then 'Field' else 'Admin' end, r->>'notes');
    n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('time_entries', n);

  -- tasks
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'tasks', '[]')) loop
    insert into tasks (title, customer_id, project_id, due_at, priority, status, notes, assigned_to)
    values (coalesce(r->>'title', 'Task'), (m->>(r->>'customer'))::uuid, (m->>(r->>'project'))::uuid,
            public.v1_due(r->>'due'),
            case when r->>'priority' in ('Urgent','High','Medium','Low') then r->>'priority' else 'Medium' end,
            case when r->>'status' = 'Done' then 'Completed' else 'Pending' end, r->>'notes', owner);
    n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('tasks', n);

  -- calendar
  n := 0;
  for r in select value from jsonb_array_elements(coalesce(payload->'calendar', '[]')) loop
    insert into calendar_events (title, type, project_id, event_date, status)
    values (coalesce(r->>'title', 'Event'),
            case r->>'type' when 'project' then 'Project Work' when 'appointment' then 'Customer Meeting'
                            when 'estimate' then 'Site Visit' else 'Other' end,
            (m->>(r->>'ref'))::uuid, nullif(r->>'date', '')::date, 'Scheduled');
    n := n + 1;
  end loop;
  counts := counts || jsonb_build_object('calendar_events', n);

  perform public.log_event('import', null, 'v1 import', counts);
  perform set_config('goldex.suppress_automation', 'off', true);
  return counts;
end $$;

revoke execute on function public.import_v1(jsonb) from anon, public;

-- ════════ 0009_thumbtack.sql ════════
-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0009 THUMBTACK INTEGRATION
--
--   Thumbtack ──webhook──▶ edge fn thumbtack-webhook ──▶ tt_ingest_lead / tt_ingest_message
--                                                        │  customer, property, lead, conversation,
--                                                        │  metrics, auto-response queued (outbox)
--   edge fn thumbtack-dispatch ◀── immediately + pg_cron every 15 s
--        │ tt_claim_outbox → POST message to Thumbtack → tt_complete_outbox
--        ▼ retries at +15 s, +60 s, +3 min, then 🚨 owner alert + urgent task
--
-- Everything is idempotent: the same webhook can arrive any number of times
-- and produce one customer, one lead, one stored message and at most ONE
-- automatic response per lead (enforced by a unique index, not just code).
-- ════════════════════════════════════════════════════════════════════

-- ── SETTINGS ───────────────────────────────────────────────────────
insert into public.settings (key, value) values ('thumbtack', jsonb_build_object(
  'auto_response_enabled', true,
  'template', 'Hi {{first_name}}! Thanks for reaching out to GOLDEX Construction. We received your project request and would be happy to help. We''re reviewing the details now and will follow up shortly with the next steps. Thank you!',
  'retry_seconds', jsonb_build_array(15, 60, 180),
  -- Confirm these with Thumbtack when partner access is approved:
  'client_id', '',
  'auth_url', 'https://auth.thumbtack.com/oauth2/auth',
  'scopes', 'messages',
  'api_base', 'https://pro-api.thumbtack.com',
  'send_path', '/api/v4/negotiations/{negotiationID}/messages'
)) on conflict (key) do nothing;

-- ── EXISTING TABLES ────────────────────────────────────────────────
alter table public.customers add column thumbtack_customer_id text;
create unique index customers_thumbtack_idx on public.customers (thumbtack_customer_id) where thumbtack_customer_id is not null;

alter table public.leads
  add column thumbtack_lead_id        text,
  add column response_status          text check (response_status in
            ('WAITING','PROCESSING','RESPONSE_PENDING','RESPONSE_SENT','RESPONSE_FAILED','OWNER_TAKEOVER')),
  add column auto_response_sent       boolean not null default false,
  add column auto_response_sent_at    timestamptz,
  add column auto_response_message_id text,
  add column auto_response_text       text,
  add column owner_takeover_at        timestamptz,
  add column external_url             text;
create unique index leads_thumbtack_idx on public.leads (thumbtack_lead_id) where thumbtack_lead_id is not null;

alter table public.communications drop constraint communications_type_check;
alter table public.communications add constraint communications_type_check
  check (type in ('Email','SMS','Phone','Internal Note','Website Form','Meeting','Thumbtack'));

-- ── NEW TABLES ─────────────────────────────────────────────────────
create table public.integrations (
  id                      uuid primary key default gen_random_uuid(),
  provider                text not null unique,
  provider_account_id     text,
  status                  text not null default 'not_connected'
                          check (status in ('not_connected','connected','error','disconnected')),
  access_token_reference  uuid,          -- vault.secrets id, never the token itself
  refresh_token_reference uuid,
  token_expires_at        timestamptz,
  scopes                  text,
  oauth_state_hash        text,          -- pending "Connect Thumbtack" request
  oauth_state_expires_at  timestamptz,
  connected_at            timestamptz,
  last_sync_at            timestamptz,
  last_error              text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
insert into public.integrations (provider) values ('thumbtack');

-- Every webhook delivery, as received. event_key makes retries harmless.
create table public.webhook_events (
  id          bigint generated always as identity primary key,
  provider    text not null,
  event_key   text not null,
  event_type  text,
  status      text not null default 'received' check (status in ('received','processed','duplicate','ignored','failed')),
  error       text,
  raw_payload jsonb,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (provider, event_key)
);

create table public.thumbtack_leads (
  id                    uuid primary key default gen_random_uuid(),
  lead_id               uuid not null unique references public.leads(id),
  thumbtack_lead_id     text not null unique,
  thumbtack_customer_id text,
  thumbtack_business_id text,
  thumbtack_request_id  text,
  thumbtack_status      text,
  category              text,
  raw_payload           jsonb,
  thumbtack_created_at  timestamptz,
  received_at           timestamptz not null default now(),
  last_synced_at        timestamptz not null default now(),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create table public.thumbtack_messages (
  id                   uuid primary key default gen_random_uuid(),
  lead_id              uuid references public.leads(id),      -- null until the lead webhook arrives
  thumbtack_lead_id    text not null,
  thumbtack_message_id text unique,
  outbox_id            uuid,
  direction            text not null check (direction in ('INBOUND','OUTBOUND')),
  sender_type          text not null check (sender_type in ('CUSTOMER','OWNER','AUTOMATION')),
  sender_name          text,
  message_text         text,
  sent_at              timestamptz not null default now(),
  received_at          timestamptz not null default now(),
  raw_payload          jsonb,
  created_at           timestamptz not null default now()
);
create index thumbtack_messages_lead_idx on public.thumbtack_messages (thumbtack_lead_id, sent_at);

create table public.thumbtack_outbox (
  id                   uuid primary key default gen_random_uuid(),
  lead_id              uuid not null references public.leads(id),
  thumbtack_lead_id    text not null,
  kind                 text not null check (kind in ('auto_response','owner')),
  message_text         text not null,
  status               text not null default 'pending' check (status in ('pending','sending','sent','failed','cancelled')),
  attempt_count        integer not null default 0,
  max_attempts         integer not null default 4,
  next_attempt_at      timestamptz not null default now(),
  last_error           text,
  thumbtack_message_id text,
  sent_at              timestamptz,
  created_by           uuid default auth.uid(),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
-- THE duplicate-response guard: one automatic response per lead, ever.
create unique index thumbtack_outbox_one_auto on public.thumbtack_outbox (lead_id) where kind = 'auto_response';
create index thumbtack_outbox_due on public.thumbtack_outbox (next_attempt_at) where status = 'pending';

create table public.automation_events (
  id            bigint generated always as identity primary key,
  event_type    text not null,
  entity_type   text,
  entity_id     uuid,
  status        text not null,
  attempt_count integer,
  started_at    timestamptz,
  completed_at  timestamptz,
  failed_at     timestamptz,
  error_message text,
  detail        jsonb,
  created_at    timestamptz not null default now()
);
create index automation_events_entity_idx on public.automation_events (entity_id, created_at desc);

create table public.lead_response_metrics (
  id                  uuid primary key default gen_random_uuid(),
  lead_id             uuid not null unique references public.leads(id),
  source              text,
  lead_received_at    timestamptz not null,     -- when the customer submitted (Thumbtack's timestamp)
  webhook_received_at timestamptz,
  crm_created_at      timestamptz,
  first_response_at   timestamptz,
  response_seconds    numeric(10,1),
  response_method     text check (response_method in ('auto','owner_thumbtack','owner_crm')),
  under_5_minutes     boolean generated always as (response_seconds <= 300) stored,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

do $$ declare t text; begin
  foreach t in array array['integrations','thumbtack_leads','thumbtack_outbox','lead_response_metrics'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.tg_touch()', t || '_touch', t);
  end loop;
  foreach t in array array['thumbtack_leads','thumbtack_outbox','lead_response_metrics'] loop
    execute format('create trigger %I after insert or update on public.%I for each row execute function public.tg_audit()', t || '_audit', t);
  end loop;
end $$;

-- Thumbtack messages in the timeline must not count as the owner contacting
-- the lead: an automatic reply is not a conversation. Owner replies set
-- last_contacted_at explicitly (tt_ingest_message / tt_complete_outbox).
create or replace function public.tg_communications_after() returns trigger language plpgsql as $$
begin
  if new.lead_id is not null and new.direction = 'Outbound' and new.type <> 'Thumbtack' then
    update public.leads set last_contacted_at = greatest(coalesce(last_contacted_at, new.sent_at), new.sent_at)
    where id = new.lead_id;
  end if;
  return new;
end $$;

-- Mirror the Thumbtack conversation into the customer's communication timeline.
create or replace function public.tg_tt_messages_comm() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is not null and (tg_op = 'INSERT' or old.lead_id is null) then
    insert into communications (customer_id, lead_id, type, direction, subject, message, sent_at)
    select l.customer_id, l.id, 'Thumbtack',
           case when new.direction = 'INBOUND' then 'Inbound' else 'Outbound' end,
           'Thumbtack · ' || initcap(new.sender_type), new.message_text, new.sent_at
    from leads l where l.id = new.lead_id;
  end if;
  return null;
end $$;
create trigger thumbtack_messages_comm after insert or update of lead_id on public.thumbtack_messages
  for each row execute function public.tg_tt_messages_comm();

-- ── HELPERS ────────────────────────────────────────────────────────
create or replace function public.assert_service_role() returns void
language plpgsql stable as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and current_user not in ('postgres', 'service_role', 'supabase_admin') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
end $$;

-- Thumbtack category → GOLDEX service type.
create or replace function public.tt_service_for(p_category text) returns text
language sql immutable as $$
  select case
    when p_category ilike '%cabinet%' then 'Cabinet Installation'
    when p_category ilike '%floor%' or p_category ilike '%tile%' or p_category ilike '%laminate%' then 'Flooring'
    when p_category ilike '%drywall%' then 'Drywall'
    when p_category ilike '%door%' then 'Door Installation'
    when p_category ilike '%remodel%' or p_category ilike '%renovat%' then 'Remodeling'
    when p_category ilike '%trim%' or p_category ilike '%molding%' or p_category ilike '%carpentr%' then 'Interior Finish'
    when p_category ilike '%handyman%' or p_category ilike '%mount%' or p_category ilike '%assembl%' then 'Handyman'
    else nullif(p_category, '') end
$$;

-- Record the first response and its speed (only the first one counts).
create or replace function public.tt_record_first_response(p_lead uuid, p_at timestamptz, p_method text) returns void
language sql security definer set search_path = public as $$
  update lead_response_metrics
  set first_response_at = p_at, response_method = p_method,
      response_seconds = round(greatest(extract(epoch from (p_at - lead_received_at)), 0)::numeric, 1)
  where lead_id = p_lead and first_response_at is null
$$;

-- ── INGEST: NEW LEAD ───────────────────────────────────────────────
-- p is the NORMALIZED lead (see supabase/functions/_shared/thumbtack.js):
-- { event_key, thumbtack_lead_id, thumbtack_customer_id, business_id, request_id, created_at,
--   customer:{first_name,last_name,phone,email}, category, title, description, schedule,
--   details:[{question,answer}], attachments_count, location:{address1,address2,city,state,zip},
--   status, url, received_at, raw }
create or replace function public.tt_ingest_lead(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c_id uuid; prop_id uuid; l_id uuid; out_id uuid; tl thumbtack_leads; is_new_customer boolean := false;
  cust jsonb := coalesce(p->'customer', '{}'); loc jsonb := coalesce(p->'location', '{}');
  ph text := nullif(right(regexp_replace(coalesce(cust->>'phone', ''), '\D', '', 'g'), 10), '');
  em text := lower(nullif(trim(cust->>'email'), ''));
  street text := nullif(concat_ws(', ', nullif(trim(loc->>'address1'), ''), nullif(trim(loc->>'address2'), '')), '');
  addr text; created timestamptz := coalesce((p->>'created_at')::timestamptz, now());
  descr text; cfg jsonb := coalesce(setting('thumbtack'), '{}'); connected boolean; resp_status text;
begin
  perform assert_service_role();
  if coalesce(p->>'thumbtack_lead_id', '') = '' then raise exception 'thumbtack_lead_id missing'; end if;

  insert into webhook_events (provider, event_key, event_type, raw_payload)
  values ('thumbtack', coalesce(p->>'event_key', 'lead:' || (p->>'thumbtack_lead_id')), 'lead', p->'raw')
  on conflict (provider, event_key) do nothing;

  -- Idempotency: this Thumbtack lead already exists → refresh it, change nothing else.
  select * into tl from thumbtack_leads where thumbtack_lead_id = p->>'thumbtack_lead_id';
  if found then
    update thumbtack_leads set raw_payload = coalesce(p->'raw', raw_payload), thumbtack_status = coalesce(p->>'status', thumbtack_status),
           last_synced_at = now() where id = tl.id;
    update webhook_events set status = 'duplicate', processed_at = now()
    where provider = 'thumbtack' and event_key = coalesce(p->>'event_key', 'lead:' || (p->>'thumbtack_lead_id')) and status = 'received';
    return jsonb_build_object('lead_id', tl.lead_id, 'created', false);
  end if;

  -- Customer: Thumbtack customer id → phone → email → new.
  select id into c_id from customers where thumbtack_customer_id = p->>'thumbtack_customer_id' and archived_at is null;
  if c_id is null and ph is not null then
    select id into c_id from customers where right(phone_digits, 10) = ph and archived_at is null order by created_at limit 1;
  end if;
  if c_id is null and em is not null then
    select id into c_id from customers where lower(email) = em and archived_at is null order by created_at limit 1;
  end if;
  if c_id is null then
    insert into customers (first_name, last_name, phone, email, lead_source, customer_status, thumbtack_customer_id, billing_address)
    values (coalesce(nullif(trim(cust->>'first_name'), ''), 'Thumbtack'), coalesce(trim(cust->>'last_name'), ''),
            cust->>'phone', em, 'Thumbtack', 'Lead', nullif(p->>'thumbtack_customer_id', ''), street)
    returning id into c_id;
    is_new_customer := true;
  else
    update customers set thumbtack_customer_id = coalesce(thumbtack_customer_id, nullif(p->>'thumbtack_customer_id', '')),
           phone = coalesce(phone, cust->>'phone'), email = coalesce(email, em)
    where id = c_id;
  end if;

  -- Property (street if given, otherwise "City, ST ZIP" so the job location is still recorded).
  addr := coalesce(street, nullif(trim(concat_ws(' ', concat_ws(', ', nullif(loc->>'city', ''), nullif(loc->>'state', '')), nullif(loc->>'zip', ''))), ''));
  if addr is not null then
    select id into prop_id from properties where customer_id = c_id and lower(address) = lower(addr) limit 1;
    if prop_id is null then
      insert into properties (customer_id, address, city, state, zip, is_default)
      values (c_id, addr, nullif(loc->>'city', ''), coalesce(nullif(loc->>'state', ''), 'CA'), nullif(loc->>'zip', ''),
              not exists (select 1 from properties where customer_id = c_id))
      returning id into prop_id;
    end if;
  end if;

  descr := concat_ws(E'\n\n', nullif(p->>'title', ''), nullif(p->>'description', ''),
    (select string_agg('• ' || (d->>'question') || ': ' || (d->>'answer'), E'\n') from jsonb_array_elements(coalesce(p->'details', '[]')) d),
    case when nullif(p->>'schedule', '') is not null then 'Schedule: ' || (p->>'schedule') end);

  insert into leads (customer_id, property_id, source, source_details, submitted_at, service_type, project_type, description,
                     photos_provided, customer_availability, assigned_to, thumbtack_lead_id, response_status, external_url, created_at,
                     notes)
  values (c_id, prop_id, 'Thumbtack', p->>'category', created, tt_service_for(p->>'category'), nullif(p->>'title', ''), descr,
          coalesce((p->>'attachments_count')::int, 0) > 0, nullif(p->>'schedule', ''), owner_user_id(),
          p->>'thumbtack_lead_id', 'PROCESSING', nullif(p->>'url', ''), now(),
          case when is_new_customer then null else 'Returning customer' end)
  returning id into l_id;

  insert into thumbtack_leads (lead_id, thumbtack_lead_id, thumbtack_customer_id, thumbtack_business_id, thumbtack_request_id,
                               thumbtack_status, category, raw_payload, thumbtack_created_at, received_at)
  values (l_id, p->>'thumbtack_lead_id', p->>'thumbtack_customer_id', p->>'business_id', p->>'request_id',
          p->>'status', p->>'category', p->'raw', created, coalesce((p->>'received_at')::timestamptz, now()));

  insert into lead_response_metrics (lead_id, source, lead_received_at, webhook_received_at, crm_created_at)
  values (l_id, 'Thumbtack', created, coalesce((p->>'received_at')::timestamptz, now()), now());

  -- The customer's original request is the first message of the conversation.
  insert into thumbtack_messages (lead_id, thumbtack_lead_id, direction, sender_type, sender_name, message_text, sent_at)
  values (l_id, p->>'thumbtack_lead_id', 'INBOUND', 'CUSTOMER', trim(concat_ws(' ', cust->>'first_name', cust->>'last_name')), descr, created);

  -- Messages that arrived before the lead webhook (Thumbtack does not guarantee order).
  update thumbtack_messages set lead_id = l_id where thumbtack_lead_id = p->>'thumbtack_lead_id' and lead_id is null;
  if exists (select 1 from thumbtack_messages where lead_id = l_id and sender_type = 'OWNER') then
    update leads set owner_takeover_at = now(), response_status = 'OWNER_TAKEOVER' where id = l_id;
    perform tt_record_first_response(l_id, (select min(sent_at) from thumbtack_messages where lead_id = l_id and sender_type = 'OWNER'), 'owner_thumbtack');
  end if;

  -- Automatic response.
  select status = 'connected' into connected from integrations where provider = 'thumbtack';
  if (select owner_takeover_at from leads where id = l_id) is not null then
    resp_status := 'OWNER_TAKEOVER';
  elsif coalesce((cfg->>'auto_response_enabled')::boolean, true) and coalesce(connected, false) then
    insert into thumbtack_outbox (lead_id, thumbtack_lead_id, kind, message_text)
    values (l_id, p->>'thumbtack_lead_id', 'auto_response',
            render_tpl(coalesce(cfg->>'template', 'Thanks for reaching out to GOLDEX Construction!'),
                       jsonb_build_object('first_name', coalesce(nullif(trim(cust->>'first_name'), ''), 'there'))))
    on conflict do nothing
    returning id into out_id;
    resp_status := 'RESPONSE_PENDING';
  else
    resp_status := 'WAITING';
    insert into notifications (kind, title, body, entity_type, entity_id)
    values ('lead', '🔔 NEW THUMBTACK LEAD — ' || customer_display_name(c_id),
            concat_ws(' · ', tt_service_for(p->>'category'), addr) || E'\nAuto-response: '
              || case when not coalesce(connected, false) then 'Thumbtack not connected' else 'turned off' end
              || ' — reply in the Thumbtack app now.', 'lead', l_id);
    insert into automation_events (event_type, entity_type, entity_id, status, error_message)
    values ('thumbtack.auto_response', 'lead', l_id, 'skipped',
            case when not coalesce(connected, false) then 'Thumbtack messaging not connected' else 'Auto-response disabled' end);
  end if;
  update leads set response_status = resp_status where id = l_id and response_status <> 'OWNER_TAKEOVER';

  update webhook_events set status = 'processed', processed_at = now()
  where provider = 'thumbtack' and event_key = coalesce(p->>'event_key', 'lead:' || (p->>'thumbtack_lead_id'));
  update integrations set last_sync_at = now() where provider = 'thumbtack';

  return jsonb_build_object('lead_id', l_id, 'customer_id', c_id, 'created', true, 'outbox_id', out_id, 'response_status', resp_status,
                            'lead_number', (select lead_number from leads where id = l_id));
end $$;

-- ── INGEST: MESSAGE ────────────────────────────────────────────────
-- p: { event_key, thumbtack_message_id, thumbtack_lead_id, from ('CUSTOMER'|'BUSINESS'), sender_name, text, sent_at, raw }
create or replace function public.tt_ingest_message(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l leads; m_id uuid; outbound boolean := upper(coalesce(p->>'from', '')) not in ('CUSTOMER', ''); auto_out thumbtack_outbox;
        at timestamptz := coalesce((p->>'sent_at')::timestamptz, now());
begin
  perform assert_service_role();
  if coalesce(p->>'thumbtack_lead_id', '') = '' then raise exception 'thumbtack_lead_id missing'; end if;
  insert into webhook_events (provider, event_key, event_type, raw_payload)
  values ('thumbtack', coalesce(p->>'event_key', 'message:' || coalesce(p->>'thumbtack_message_id', md5(p::text))), 'message', p->'raw')
  on conflict (provider, event_key) do nothing;

  if p->>'thumbtack_message_id' is not null and exists (select 1 from thumbtack_messages where thumbtack_message_id = p->>'thumbtack_message_id') then
    return jsonb_build_object('duplicate', true);
  end if;

  select * into l from leads where thumbtack_lead_id = p->>'thumbtack_lead_id';

  -- Our own automatic message echoed back by Thumbtack before we stored its id.
  if outbound and l.id is not null then
    select * into auto_out from thumbtack_outbox
    where lead_id = l.id and status in ('sending','sent') and trim(message_text) = trim(coalesce(p->>'text', ''))
      and (thumbtack_message_id is null or thumbtack_message_id = p->>'thumbtack_message_id')
    order by created_at desc limit 1;
  end if;

  insert into thumbtack_messages (lead_id, thumbtack_lead_id, thumbtack_message_id, outbox_id, direction, sender_type, sender_name,
                                  message_text, sent_at, raw_payload)
  values (l.id, p->>'thumbtack_lead_id', p->>'thumbtack_message_id', auto_out.id,
          case when outbound then 'OUTBOUND' else 'INBOUND' end,
          case when not outbound then 'CUSTOMER' when auto_out.id is not null then
            case when auto_out.kind = 'auto_response' then 'AUTOMATION' else 'OWNER' end else 'OWNER' end,
          p->>'sender_name', p->>'text', at, p->'raw')
  on conflict (thumbtack_message_id) do nothing
  returning id into m_id;

  if l.id is not null and m_id is not null then
    if not outbound then
      insert into notifications (kind, title, body, entity_type, entity_id)
      values ('message', '💬 Thumbtack message from ' || customer_display_name(l.customer_id), left(p->>'text', 280), 'lead', l.id);
    elsif auto_out.id is null then
      -- The owner replied from the Thumbtack app: that is a takeover and a response.
      update leads set owner_takeover_at = coalesce(owner_takeover_at, at), response_status = 'OWNER_TAKEOVER',
             last_contacted_at = greatest(coalesce(last_contacted_at, at), at)
      where id = l.id;
      update thumbtack_outbox set status = 'cancelled', last_error = 'Owner replied in Thumbtack'
      where lead_id = l.id and kind = 'auto_response' and status = 'pending';
      perform tt_record_first_response(l.id, at, 'owner_thumbtack');
    end if;
  end if;

  update webhook_events set status = case when m_id is null then 'duplicate' else 'processed' end, processed_at = now()
  where provider = 'thumbtack' and event_key = coalesce(p->>'event_key', 'message:' || coalesce(p->>'thumbtack_message_id', md5(p::text)));
  return jsonb_build_object('message_id', m_id, 'lead_id', l.id, 'orphan', l.id is null);
end $$;

-- ── OUTBOX ─────────────────────────────────────────────────────────
-- Claim due messages for sending. Rows stuck in 'sending' for 2 minutes
-- (crashed function) become claimable again.
create or replace function public.tt_claim_outbox(p_limit int default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o thumbtack_outbox; out jsonb := '[]';
begin
  perform assert_service_role();
  for o in select * from thumbtack_outbox
           where (status = 'pending' and next_attempt_at <= now())
              or (status = 'sending' and updated_at < now() - interval '2 minutes')
           order by next_attempt_at limit p_limit for update skip locked loop
    if o.kind = 'auto_response' and (select owner_takeover_at from leads where id = o.lead_id) is not null then
      update thumbtack_outbox set status = 'cancelled', last_error = 'Owner took over' where id = o.id;
      continue;
    end if;
    update thumbtack_outbox set status = 'sending', attempt_count = attempt_count + 1 where id = o.id returning * into o;
    insert into automation_events (event_type, entity_type, entity_id, status, attempt_count, started_at, detail)
    values ('thumbtack.send_message', 'lead', o.lead_id, 'started', o.attempt_count, now(), jsonb_build_object('outbox_id', o.id, 'kind', o.kind));
    out := out || jsonb_build_object('id', o.id, 'lead_id', o.lead_id, 'thumbtack_lead_id', o.thumbtack_lead_id, 'kind', o.kind,
      'text', o.message_text, 'attempt', o.attempt_count, 'business_id',
      (select thumbtack_business_id from thumbtack_leads where lead_id = o.lead_id));
  end loop;
  return out;
end $$;

create or replace function public.tt_complete_outbox(p_id uuid, p_ok boolean, p_message_id text default null,
                                                     p_error text default null, p_retryable boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o thumbtack_outbox; l leads; m lead_response_metrics; delays jsonb; delay int; c customers; pr properties;
begin
  perform assert_service_role();
  select * into o from thumbtack_outbox where id = p_id for update;
  if not found then raise exception 'outbox row not found'; end if;
  if o.status = 'sent' then return jsonb_build_object('status', 'sent'); end if;
  select * into l from leads where id = o.lead_id;

  if p_ok then
    update thumbtack_outbox set status = 'sent', sent_at = now(), thumbtack_message_id = p_message_id, last_error = null where id = o.id;
    insert into thumbtack_messages (lead_id, thumbtack_lead_id, thumbtack_message_id, outbox_id, direction, sender_type, sender_name, message_text, sent_at)
    values (o.lead_id, o.thumbtack_lead_id, p_message_id, o.id, 'OUTBOUND',
            case when o.kind = 'auto_response' then 'AUTOMATION' else 'OWNER' end, 'GOLDEX Construction', o.message_text, now())
    on conflict (thumbtack_message_id) do update set sender_type = excluded.sender_type, outbox_id = excluded.outbox_id;
    insert into automation_events (event_type, entity_type, entity_id, status, attempt_count, completed_at, detail)
    values ('thumbtack.send_message', 'lead', o.lead_id, 'sent', o.attempt_count, now(), jsonb_build_object('outbox_id', o.id, 'message_id', p_message_id));

    if o.kind = 'auto_response' then
      update leads set auto_response_sent = true, auto_response_sent_at = now(), auto_response_message_id = p_message_id,
             auto_response_text = o.message_text,
             response_status = case when response_status = 'OWNER_TAKEOVER' then response_status else 'RESPONSE_SENT' end
      where id = o.lead_id;
      perform tt_record_first_response(o.lead_id, now(), 'auto');
      select * into m from lead_response_metrics where lead_id = o.lead_id;
      select * into c from customers where id = l.customer_id;
      select * into pr from properties where id = l.property_id;
      insert into notifications (kind, title, body, entity_type, entity_id)
      values ('lead', '🔔 NEW THUMBTACK LEAD — ' || customer_display_name(l.customer_id),
              concat_ws(' · ', l.service_type, coalesce(pr.city || coalesce(', ' || pr.state, ''), pr.address))
              || E'\nLead score: ' || coalesce(l.qualification_score, '—')
              || ' · Auto-response: Sent · Response time: ' || coalesce(round(m.response_seconds)::text || ' sec', '—')
              || E'\nNext: review the lead and take over the conversation.', 'lead', o.lead_id);
    else
      perform tt_record_first_response(o.lead_id, now(), 'owner_crm');
      update leads set last_contacted_at = now() where id = o.lead_id;
    end if;
    return jsonb_build_object('status', 'sent');
  end if;

  -- Failure: schedule a retry, or give up loudly.
  delays := coalesce(setting('thumbtack')->'retry_seconds', '[15,60,180]');
  if p_retryable and o.attempt_count < o.max_attempts then
    delay := coalesce((delays->>(o.attempt_count - 1))::int, 180);
    update thumbtack_outbox set status = 'pending', last_error = p_error, next_attempt_at = now() + make_interval(secs => delay) where id = o.id;
    insert into automation_events (event_type, entity_type, entity_id, status, attempt_count, failed_at, error_message, detail)
    values ('thumbtack.send_message', 'lead', o.lead_id, 'retry_scheduled', o.attempt_count, now(), p_error, jsonb_build_object('retry_in_seconds', delay));
    if o.kind = 'auto_response' then update leads set response_status = 'RESPONSE_FAILED' where id = o.lead_id and response_status <> 'OWNER_TAKEOVER'; end if;
    return jsonb_build_object('status', 'retry', 'retry_in_seconds', delay);
  end if;

  update thumbtack_outbox set status = 'failed', last_error = p_error where id = o.id;
  insert into automation_events (event_type, entity_type, entity_id, status, attempt_count, failed_at, error_message)
  values ('thumbtack.send_message', 'lead', o.lead_id, 'failed', o.attempt_count, now(), p_error);
  if o.kind = 'auto_response' then update leads set response_status = 'RESPONSE_FAILED' where id = o.lead_id and response_status <> 'OWNER_TAKEOVER'; end if;
  insert into notifications (kind, title, body, entity_type, entity_id)
  values ('escalation', '🚨 Thumbtack response failed — ' || customer_display_name(l.customer_id),
          'Gave up after ' || o.attempt_count || ' attempt(s): ' || coalesce(p_error, 'unknown error') || E'\nReply in the Thumbtack app now.', 'lead', o.lead_id);
  insert into tasks (title, customer_id, lead_id, assigned_to, due_at, priority, task_type, automation_source, dedupe_key)
  values ('Reply in Thumbtack NOW — automatic message failed (' || customer_display_name(l.customer_id) || ')',
          l.customer_id, l.id, owner_user_id(), now(), 'Urgent', 'Contact Lead', 'Thumbtack response failed', 'tt-failed:' || o.id)
  on conflict (dedupe_key) where dedupe_key is not null do nothing;
  return jsonb_build_object('status', 'failed');
end $$;

-- ── OWNER ACTIONS (from the CRM) ───────────────────────────────────
create or replace function public.tt_take_over(p_lead_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform assert_active();
  update leads set owner_takeover_at = coalesce(owner_takeover_at, now()), response_status = 'OWNER_TAKEOVER' where id = p_lead_id;
  update thumbtack_outbox set status = 'cancelled', last_error = 'Owner took over'
  where lead_id = p_lead_id and kind = 'auto_response' and status in ('pending');
  perform log_event('lead', p_lead_id, 'thumbtack takeover', null);
end $$;

create or replace function public.tt_send_owner_message(p_lead_id uuid, p_text text) returns uuid
language plpgsql security definer set search_path = public as $$
declare l leads; o uuid;
begin
  perform assert_active();
  if coalesce(trim(p_text), '') = '' then raise exception 'Message is empty.'; end if;
  select * into l from leads where id = p_lead_id;
  if l.thumbtack_lead_id is null then raise exception 'This lead did not come from Thumbtack.'; end if;
  if (select status from integrations where provider = 'thumbtack') <> 'connected' then
    raise exception 'Thumbtack messaging is not connected yet — reply in the Thumbtack app.';
  end if;
  perform tt_take_over(p_lead_id);
  insert into thumbtack_outbox (lead_id, thumbtack_lead_id, kind, message_text) values (p_lead_id, l.thumbtack_lead_id, 'owner', trim(p_text))
  returning id into o;
  return o;
end $$;

-- ── TOKENS (Supabase Vault — encrypted at rest) ───────────────────
create or replace function public.tt_store_tokens(p_access text, p_refresh text, p_expires_in int,
                                                  p_account_id text default null, p_scopes text default null) returns void
language plpgsql security definer set search_path = public, vault as $$
declare i integrations;
begin
  perform assert_service_role();
  select * into i from integrations where provider = 'thumbtack' for update;
  if i.access_token_reference is null then
    i.access_token_reference := vault.create_secret(p_access, 'thumbtack_access_token', 'Thumbtack OAuth access token');
  else perform vault.update_secret(i.access_token_reference, p_access); end if;
  if p_refresh is not null then
    if i.refresh_token_reference is null then
      i.refresh_token_reference := vault.create_secret(p_refresh, 'thumbtack_refresh_token', 'Thumbtack OAuth refresh token');
    else perform vault.update_secret(i.refresh_token_reference, p_refresh); end if;
  end if;
  update integrations set access_token_reference = i.access_token_reference, refresh_token_reference = i.refresh_token_reference,
         token_expires_at = now() + make_interval(secs => coalesce(p_expires_in, 3600)), status = 'connected',
         provider_account_id = coalesce(p_account_id, provider_account_id), scopes = coalesce(p_scopes, scopes),
         connected_at = coalesce(connected_at, now()), last_error = null
  where provider = 'thumbtack';
end $$;

create or replace function public.tt_get_tokens() returns jsonb
language plpgsql security definer set search_path = public, vault as $$
declare i integrations;
begin
  perform assert_service_role();
  select * into i from integrations where provider = 'thumbtack';
  return jsonb_build_object('status', i.status, 'expires_at', i.token_expires_at,
    'access_token', (select decrypted_secret from vault.decrypted_secrets where id = i.access_token_reference),
    'refresh_token', (select decrypted_secret from vault.decrypted_secrets where id = i.refresh_token_reference));
end $$;

create or replace function public.tt_set_integration_error(p_error text, p_status text default 'error') returns void
language plpgsql security definer set search_path = public as $$
begin
  perform assert_service_role();
  update integrations set status = p_status, last_error = p_error where provider = 'thumbtack';
end $$;

-- "Connect Thumbtack": the CRM asks for a one-time state value; the OAuth
-- callback must present it within 10 minutes. Stops anyone else from
-- attaching their Thumbtack account to this CRM.
create or replace function public.tt_oauth_begin() returns text
language plpgsql security definer set search_path = public as $$
declare st text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  if current_role_name() not in ('owner','admin') then raise exception 'Only the owner can connect Thumbtack.'; end if;
  update integrations set oauth_state_hash = md5(st), oauth_state_expires_at = now() + interval '10 minutes' where provider = 'thumbtack';
  return st;
end $$;

create or replace function public.tt_oauth_consume_state(p_state text) returns boolean
language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  perform assert_service_role();
  update integrations set oauth_state_hash = null, oauth_state_expires_at = null
  where provider = 'thumbtack' and oauth_state_hash = md5(p_state) and oauth_state_expires_at > now()
  returning true into ok;
  return coalesce(ok, false);
end $$;

create or replace function public.tt_disconnect() returns void
language plpgsql security definer set search_path = public as $$
begin
  if current_role_name() not in ('owner','admin') then raise exception 'Only the owner can disconnect Thumbtack.'; end if;
  delete from vault.secrets where id in (select access_token_reference from integrations where provider = 'thumbtack')
                               or id in (select refresh_token_reference from integrations where provider = 'thumbtack');
  update integrations set status = 'disconnected', access_token_reference = null, refresh_token_reference = null,
         token_expires_at = null where provider = 'thumbtack';
end $$;

create or replace function public.tt_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when is_active_user() then jsonb_build_object('status', status, 'account_id', provider_account_id,
    'connected_at', connected_at, 'last_sync_at', last_sync_at, 'last_error', last_error, 'token_expires_at', token_expires_at)
  end from integrations where provider = 'thumbtack'
$$;

-- ── KPIs (spec §12–13) ─────────────────────────────────────────────
create or replace function public.tt_kpis(p_from date default current_date, p_to date default current_date) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not is_active_user() then null else (
    with m as (select * from lead_response_metrics where source = 'Thumbtack' and lead_received_at::date between p_from and p_to),
    f as (select count(distinct o.lead_id) n from thumbtack_outbox o join m on m.lead_id = o.lead_id where o.kind = 'auto_response' and o.status = 'failed')
    select jsonb_build_object(
      'leads', (select count(*) from m),
      'responded', (select count(*) from m where first_response_at is not null),
      'auto_responses', (select count(*) from m join leads l on l.id = m.lead_id where l.auto_response_sent),
      'avg_seconds', (select round(avg(response_seconds)) from m),
      'median_seconds', (select round(percentile_cont(0.5) within group (order by response_seconds)::numeric) from m where response_seconds is not null),
      'fastest_seconds', (select min(response_seconds) from m), 'slowest_seconds', (select max(response_seconds) from m),
      'pct_under_1_min', (select round(100.0 * count(*) filter (where response_seconds <= 60) / nullif(count(*), 0)) from m),
      'pct_under_5_min', (select round(100.0 * count(*) filter (where response_seconds <= 300) / nullif(count(*), 0)) from m),
      'pct_over_5_min', (select round(100.0 * count(*) filter (where response_seconds > 300 or first_response_at is null) / nullif(count(*), 0)) from m),
      'not_responded', (select count(*) from m where first_response_at is null),
      'failed', (select n from f),
      'connected', (select status = 'connected' from integrations where provider = 'thumbtack'))) end
$$;

-- ── VIEW: leads with response metrics ──────────────────────────────
drop view public.v_leads;
create view public.v_leads with (security_invoker = true) as
select l.*,
  public.customer_display_name(l.customer_id) as customer_name,
  c.phone as customer_phone, c.email as customer_email, c.thumbtack_customer_id,
  pr.address as property_address,
  extract(day from now() - l.created_at)::int as age_days,
  (l.stage = 'NEW LEAD' and l.last_contacted_at is null
     and now() - l.created_at > make_interval(mins => coalesce((public.setting('lead_sla_minutes') #>> '{}')::int, 15))) as sla_breached,
  case l.stage
    when 'NEW LEAD' then case when l.source = 'Thumbtack' and l.response_status in ('RESPONSE_SENT','WAITING','RESPONSE_FAILED')
                              then 'Take over the Thumbtack conversation' else 'Call customer' end
    when 'CONTACTED' then 'Qualify: budget, timeline, photos'
    when 'QUALIFYING' then case when l.site_visit_required then 'Schedule site visit' else 'Build estimate' end
    when 'SITE VISIT' then case when l.site_visit_date is null then 'Schedule site visit' else 'Complete site visit' end
    when 'ESTIMATE' then 'Send estimate'
    when 'PROPOSAL SENT' then 'Follow up on proposal'
    when 'FOLLOW-UP' then 'Follow up — ask for decision'
    when 'WON' then 'Collect deposit'
    else null end as next_action,
  (select min(t.due_at) from public.tasks t where t.lead_id = l.id and t.status in ('Pending','In Progress')) as next_task_due,
  m.lead_received_at, m.webhook_received_at, m.crm_created_at, m.first_response_at, m.response_seconds, m.response_method
from public.leads l
join public.customers c on c.id = l.customer_id
left join public.properties pr on pr.id = l.property_id
left join public.lead_response_metrics m on m.lead_id = l.id;

-- The generic new-lead alert is replaced for Thumbtack leads by the richer
-- alert above (sent once the auto-response result is known).
update public.automation_rules
set actions = jsonb_set(actions, '{1}', (actions->1) || '{"if":{"source":{"not_in":["Thumbtack"]}}}')
where name = 'New lead → contact task + owner alert' and actions->1->>'type' = 'notify';

-- ── SCHEDULER (Supabase only) ──────────────────────────────────────
-- Run once after deploying the edge functions:
--   select tt_setup_dispatch('https://<ref>.supabase.co/functions/v1/thumbtack-dispatch', '<DISPATCH_SECRET>');
create or replace function public.tt_setup_dispatch(p_url text, p_secret text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if current_role_name() is distinct from 'owner' and current_user <> 'postgres' then raise exception 'Owner only'; end if;
  if not exists (select 1 from pg_extension where extname = 'pg_cron') or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise exception 'Enable the pg_cron and pg_net extensions first (Database → Extensions).';
  end if;
  execute format($cron$select cron.schedule('thumbtack-dispatch', '15 seconds',
    %L)$cron$, format($sql$select net.http_post(url := %L, headers := jsonb_build_object('Content-Type','application/json','x-dispatch-secret', %L), body := '{}'::jsonb)$sql$, p_url, p_secret));
  return 'Scheduled every 15 seconds';
end $$;

-- ── SECURITY ───────────────────────────────────────────────────────
do $$ declare t text; begin
  foreach t in array array['thumbtack_leads','thumbtack_messages','lead_response_metrics','automation_events','thumbtack_outbox','webhook_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy staff_read on public.%I for select to authenticated using (public.is_active_user())', t);
  end loop;
end $$;
-- Integrations: no direct table access at all; the CRM reads tt_status().
alter table public.integrations enable row level security;
revoke all on public.integrations from authenticated, anon;
revoke insert, update, delete on public.thumbtack_leads, public.thumbtack_messages, public.thumbtack_outbox,
  public.lead_response_metrics, public.automation_events, public.webhook_events from authenticated, anon;

revoke execute on all functions in schema public from anon, public;
revoke execute on function public.tt_ingest_lead(jsonb), public.tt_ingest_message(jsonb), public.tt_claim_outbox(int),
  public.tt_complete_outbox(uuid, boolean, text, text, boolean), public.tt_store_tokens(text, text, int, text, text),
  public.tt_get_tokens(), public.tt_set_integration_error(text, text), public.tt_oauth_consume_state(text),
  public.tt_record_first_response(uuid, timestamptz, text)
from authenticated;
grant execute on function public.tt_ingest_lead(jsonb), public.tt_ingest_message(jsonb), public.tt_claim_outbox(int),
  public.tt_complete_outbox(uuid, boolean, text, text, boolean), public.tt_store_tokens(text, text, int, text, text),
  public.tt_get_tokens(), public.tt_set_integration_error(text, text), public.tt_oauth_consume_state(text)
to service_role;
