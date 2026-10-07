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
