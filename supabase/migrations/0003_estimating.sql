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
