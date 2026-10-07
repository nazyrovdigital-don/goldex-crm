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
