-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0010 MATERIALS MARKUP
-- Material lines on an estimate are priced at COST + MARKUP. The markup
-- tier comes from the estimate's total material cost (small orders cost the
-- most time per dollar), unless the estimate sets its own override.
--   under $500 → 20% · $500–$2,000 → 15% · over $2,000 → 10%   (Settings)
-- ════════════════════════════════════════════════════════════════════

insert into public.settings (key, value) values ('materials', '{
  "tiers": [ {"up_to": 500, "markup": 20}, {"up_to": 2000, "markup": 15}, {"up_to": null, "markup": 10} ],
  "trip_charge": 60
}') on conflict (key) do nothing;

alter table public.estimate_items add column item_type text not null default 'service' check (item_type in ('service','material'));
alter table public.estimates
  add column materials_cost             numeric(12,2) not null default 0,
  add column materials_markup_pct       numeric(5,2),
  add column materials_markup_override  numeric(5,2) check (materials_markup_override between 0 and 200);

-- Markup % for a given total material cost, from the Settings tiers.
create or replace function public.material_markup_for(p_cost numeric) returns numeric
language sql stable as $$
  select coalesce((
    select (t->>'markup')::numeric
    from jsonb_array_elements(coalesce(public.setting('materials')->'tiers', '[]')) with ordinality as x(t, i)
    where t->>'up_to' is null or p_cost < (t->>'up_to')::numeric
    order by i limit 1), 15)
$$;

-- Recalculate an estimate. Material lines get their sell price from cost +
-- markup first (that update re-enters this function once and changes
-- nothing, so it terminates), then the header totals are summed as before.
create or replace function public.recalc_estimate(p_estimate_id uuid) returns void
language plpgsql as $$
declare mat numeric; pct numeric;
begin
  select coalesce(sum(round(quantity * unit_material_cost, 2)), 0) into mat
  from public.estimate_items where estimate_id = p_estimate_id and item_type = 'material';
  select coalesce(materials_markup_override, public.material_markup_for(mat)) into pct
  from public.estimates where id = p_estimate_id;

  update public.estimate_items
  set unit_price = round(unit_material_cost * (1 + pct / 100), 2)
  where estimate_id = p_estimate_id and item_type = 'material'
    and unit_price is distinct from round(unit_material_cost * (1 + pct / 100), 2);

  update public.estimates e set
    materials_cost               = mat,
    materials_markup_pct         = case when mat > 0 then pct end,
    subtotal                     = coalesce(s.sell, 0),
    estimated_labor_hours        = coalesce(s.hours, 0),
    estimated_labor_cost         = coalesce(s.labor, 0),
    estimated_material_cost      = coalesce(s.material, 0),
    estimated_subcontractor_cost = coalesce(s.sub, 0),
    estimated_other_direct_cost  = coalesce(s.other, 0)
  from (select sum(sell_total) sell, sum(labor_hours) hours, sum(labor_cost) labor, sum(material_cost) material,
               sum(subcontractor_cost) sub, sum(other_direct_cost) other
        from public.estimate_items where estimate_id = p_estimate_id) s
  where e.id = p_estimate_id;
end $$;

-- Changing the override re-prices the material lines.
create or replace function public.tg_estimates_markup() returns trigger language plpgsql as $$
begin
  if new.materials_markup_override is distinct from old.materials_markup_override then
    perform public.recalc_estimate(new.id);
  end if;
  return null;
end $$;
create trigger estimates_markup after update on public.estimates
  for each row execute function public.tg_estimates_markup();

-- Proposals state the material terms in writing ("cost + X%").
create or replace function public.create_proposal_from_estimate(p_estimate_id uuid) returns uuid
language plpgsql set search_path = public as $$
declare e estimates; new_id uuid; scope text; mat_note text;
begin
  perform public.assert_active();
  select * into e from estimates where id = p_estimate_id;
  if not found then raise exception 'Estimate not found'; end if;
  if not exists (select 1 from estimate_items where estimate_id = e.id) then
    raise exception 'Estimate % has no line items.', e.estimate_number;
  end if;
  select string_agg('• ' || description || ' — ' || trim(to_char(quantity, 'FM999,990.###')) || coalesce(' ' || unit, ''), E'\n' order by sort_order)
    into scope from estimate_items where estimate_id = e.id;
  mat_note := case when e.materials_cost > 0 then
    'Materials are priced at cost + ' || trim(to_char(e.materials_markup_pct, 'FM990.##')) || '% (sourcing, pickup, handling and replacement of defective pieces). Receipts available on request.' end;
  insert into proposals (estimate_id, lead_id, customer_id, property_id, title, scope_of_work, exclusions, assumptions,
                         subtotal, discount, tax, estimated_direct_cost, estimated_labor_hours,
                         deposit_type, deposit_percent, payment_terms)
  values (e.id, e.lead_id, e.customer_id, e.property_id, e.title,
          coalesce(nullif(e.notes, '') || E'\n\n', '') || scope, e.exclusions,
          nullif(concat_ws(E'\n', nullif(e.assumptions, ''), mat_note), ''),
          e.subtotal, e.discount, e.tax, e.estimated_direct_cost, e.estimated_labor_hours,
          'Percent', public.setting_num('deposit', 'percent', 10),
          'Deposit due on signing. Balance due on completion.')
  returning id into new_id;
  insert into proposal_items (proposal_id, sort_order, description, quantity, unit, unit_price)
  select new_id, sort_order, description, quantity, unit, unit_price from estimate_items where estimate_id = e.id;
  update estimates set status = 'Converted' where id = e.id and status in ('Draft','Sent');
  return new_id;
end $$;

revoke execute on all functions in schema public from anon, public;

-- Trip charge for material pickup/delivery, ready to add to any estimate.
insert into public.pricebook_items (service, item, unit, sell_price, labor_hours, labor_rate, other_cost, notes)
select 'Labor', 'Material pickup / delivery trip', 'trip', 60, 0.75, public.setting_num('labor', 'owner_loaded_rate', 40), 5,
       'Charge when you have to go get materials. Fuel included in cost.'
where not exists (select 1 from public.pricebook_items where item = 'Material pickup / delivery trip');
