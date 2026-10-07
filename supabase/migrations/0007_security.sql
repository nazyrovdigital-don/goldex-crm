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
