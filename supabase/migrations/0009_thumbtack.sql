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
