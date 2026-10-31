-- =============================================================================
-- CSWMS Phase 5 — Migration 9000: privilege lockdown re-applied over the inter-company functions (keep LAST).
-- Phase 5 adds: ic_orders, ic_order_lines, ic_invoices, ic_invoice_lines (no direct client access;
-- read and changed only through the permission-checked inter-company functions).
-- =============================================================================
revoke all on private.analytics_runs from public, anon, authenticated;
revoke all on private.message_outbox from public, anon, authenticated;
revoke all on public.attachments from anon, authenticated;   -- read through list_attachments / attachment_path only
revoke all on public.ic_orders, public.ic_order_lines, public.ic_invoices, public.ic_invoice_lines from anon, authenticated;

-- ----------------------------------------------------------------------------
-- Privilege lockdown (identical to 20261023000900_final_lockdown.sql)
-- ----------------------------------------------------------------------------
-- future objects: no automatic PUBLIC execute
alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;

-- anon: nothing at all
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from public, anon;
revoke all on schema private from anon;
revoke all on schema integrity from anon;

-- private / integrity functions: only the explicitly allowed helpers
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on all functions in schema integrity from public, anon, authenticated;
grant execute on function private.my_warehouses(text) to authenticated;
grant execute on function private.my_owner_companies(text) to authenticated;
grant execute on function private.has_perm(text) to authenticated;
grant execute on function private.has_group_perm(text) to authenticated;
grant execute on function private.has_wh_perm(text, uuid) to authenticated;
grant execute on function private.setting_num(text, numeric) to authenticated;
grant execute on function private.is_stocktake_assignee(uuid) to authenticated;
grant execute on function private.stocktake_warehouse(uuid) to authenticated;
grant execute on function integrity.dispatch() to service_role;
grant execute on function integrity.watchdog() to service_role;

-- public API for signed-in users, except the server-only job functions
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' loop
    if f.proname in ('cron_dispatch','email_outbox_claim','email_outbox_result','log_system_event','message_outbox_claim','message_outbox_result') then
      execute format('revoke execute on function %s from authenticated', f.sig);
      execute format('grant execute on function %s to service_role', f.sig);
    else
      execute format('grant execute on function %s to authenticated, service_role', f.sig);
    end if;
  end loop;
end $$;

-- sanity check: fail the migration if anything is still reachable by anon
do $$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public','private','integrity') and has_function_privilege('anon', p.oid, 'execute');
  if v_bad is not null then raise exception 'Lockdown failed — anon can execute: %', v_bad; end if;
  select string_agg(c.relname, ', ') into v_bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public','private','integrity') and c.relkind in ('r','v','m')
    and has_table_privilege('anon', c.oid, 'select');
  if v_bad is not null then raise exception 'Lockdown failed — anon can read: %', v_bad; end if;
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'integrity' and has_function_privilege('authenticated', p.oid, 'execute');
  if v_bad is not null then raise exception 'Lockdown failed — users can execute monitor internals: %', v_bad; end if;
end $$;
