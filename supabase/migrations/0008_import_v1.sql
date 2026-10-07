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
