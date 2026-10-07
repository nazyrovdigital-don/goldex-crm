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
