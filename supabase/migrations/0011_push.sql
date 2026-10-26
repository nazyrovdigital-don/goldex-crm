-- ════════════════════════════════════════════════════════════════════
-- GOLDEX CRM V2 — 0011 PUSH NOTIFICATIONS
-- Every CRM notification (new lead, Thumbtack message, payment, escalation…)
-- is also pushed to the phones/computers the user enabled.
--   notifications INSERT → trigger → pg_net POST → edge fn push-send → Apple/Google push
-- Push is best-effort: if anything in the push path fails, the notification
-- itself is still saved and shown in the CRM.
-- ════════════════════════════════════════════════════════════════════

create table public.push_subscriptions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.users(id) on delete cascade default auth.uid(),
  endpoint     text not null unique,
  p256dh       text not null,
  auth         text not null,
  user_agent   text,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  failed_count integer not null default 0
);
create index push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
create policy own_select on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
create policy own_delete on public.push_subscriptions for delete to authenticated using (user_id = auth.uid());
revoke insert, update on public.push_subscriptions from authenticated, anon;

-- Register (or move) this device's subscription to the signed-in user.
create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  perform assert_active();
  if p_endpoint !~ '^https://' then raise exception 'Invalid push endpoint'; end if;
  insert into push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth,
    user_agent = excluded.user_agent, failed_count = 0
  returning id into sid;
  return sid;
end $$;

-- "Send test notification" button.
create or replace function public.push_test() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform assert_active();
  insert into notifications (user_id, kind, title, body)
  values (auth.uid(), 'test', '✅ GOLDEX notifications are working', 'New leads and messages will appear like this.');
end $$;

-- One-time setup (owner): where the push-send function lives + its shared secret.
create or replace function public.push_setup(p_url text, p_secret text) returns text
language plpgsql security definer set search_path = public, vault as $$
declare sid uuid;
begin
  -- Owner in the app, or an administrator running it from the SQL editor / CLI (no app login).
  if auth.uid() is not null and current_role_name() is distinct from 'owner' then raise exception 'Owner only'; end if;
  if not exists (select 1 from pg_extension where extname = 'pg_net') then create extension if not exists pg_net; end if;
  select id into sid from vault.secrets where name = 'push_secret';
  if sid is null then perform vault.create_secret(p_secret, 'push_secret', 'Shared secret for the push-send edge function');
  else perform vault.update_secret(sid, p_secret); end if;
  insert into settings (key, value) values ('push', jsonb_build_object('url', p_url))
  on conflict (key) do update set value = excluded.value;
  return 'Push notifications configured';
end $$;

create or replace function public.tg_notifications_push() returns trigger
language plpgsql security definer set search_path = public, vault as $$
declare url text := setting('push')->>'url'; secret text;
begin
  if url is null or to_regproc('net.http_post') is null then return null; end if;
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_secret';
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 5000)'
    using url, jsonb_build_object('notification_id', new.id),
          jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', coalesce(secret, ''));
  return null;
exception when others then
  raise warning 'push dispatch failed: %', sqlerrm;          -- never block the notification itself
  return null;
end $$;
create trigger notifications_push after insert on public.notifications
  for each row execute function public.tg_notifications_push();

revoke execute on all functions in schema public from anon, public;
revoke execute on function public.tg_notifications_push() from authenticated;
