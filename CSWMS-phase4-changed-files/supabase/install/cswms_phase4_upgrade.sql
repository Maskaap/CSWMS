-- CSWMS Phase 4 upgrade (floor experience) for a database that already has Phases 1-3.
-- Supabase -> SQL Editor -> paste this whole file -> Run. Runs once, in one transaction:
-- if any statement fails, nothing is changed. Does not change any stock records.

do $$ begin if to_regclass('public.attachments') is not null then raise exception 'Phase 4 is already installed on this database'; end if;
  if to_regclass('private.analytics_runs') is null then raise exception 'Install Phases 1-3 first (cswms_full_install.sql)'; end if; end $$;

begin;

-- ===== 20261031001000_phase4_floor_counting.sql =====
-- =============================================================================
-- CSWMS Phase 4 — Floor experience (part 1): offline counting, guided count
-- route, cycle counting and the worker's task list.
--
--  * Counts may be captured on a phone without signal and sent later. Each count
--    keeps the time it was made on the phone (clamped to [cut-off, now]) so
--    movements are measured to the right moment; it is flagged entered_offline.
--    The existing request id makes a re-sent count harmless.
--  * stocktake_offline_pack: everything a counter's phone needs to keep
--    counting without a connection (scope, locations in walk order, lines,
--    products with units and barcodes).
--  * Cycle counts: small daily stocktakes of selected products, chosen by
--    A/B/C value and how long since each was last counted.
--  * my_tasks: one call for the worker's home screen.
-- =============================================================================

-- walk order for locations (guided route); null = by code
alter table public.storage_locations add column if not exists walk_order int;

-- count provenance
alter table public.stocktake_counts add column if not exists received_at timestamptz not null default clock_timestamp();
alter table public.stocktake_counts add column if not exists entered_offline boolean not null default false;
alter table public.stocktake_counts add column if not exists method text not null default 'typed'
  check (method in ('typed','scan','empty_bin'));

-- cycle counts: product-scoped stocktakes
alter table public.stocktakes add column if not exists product_ids uuid[];
alter table public.stocktakes add column if not exists kind text not null default 'full' check (kind in ('full','cycle'));
drop index if exists public.stocktakes_one_active_full;
create unique index stocktakes_one_active_full on public.stocktakes (warehouse_id)
  where status in ('counting','review','pending_approval') and category_ids is null and location_ids is null and product_ids is null;

insert into public.app_settings (key, value, category, description) values
  ('cycle.items_per_day',     '0',    'cycle', 'Items per warehouse counted each working day in a cycle count (0 = cycle counting off)'),
  ('cycle.a_days',            '30',   'cycle', 'A items (top 80% of consumption value) are counted at least this often (days)'),
  ('cycle.b_days',            '60',   'cycle', 'B items are counted at least this often (days)'),
  ('cycle.c_days',            '120',  'cycle', 'C items are counted at least this often (days)'),
  ('cycle.create_time',       '"06:00"', 'cycle', 'Local time after which the day''s cycle counts are created (Mon–Fri)'),
  ('counting.offline_max_hours', '72', 'stocktake', 'Counts captured offline are accepted up to this many hours after they were made')
on conflict (key) do nothing;

create or replace function private.stocktake_in_scope(p_st public.stocktakes, p_product uuid, p_location uuid) returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select (p_st.category_ids is null or (select category_id from public.products where id = p_product) = any(private.category_tree(p_st.category_ids)))
     and (p_st.location_ids is null or p_location = any(private.location_tree(p_st.location_ids)))
     and (p_st.product_ids is null or p_product = any(p_st.product_ids))
     and exists (select 1 from public.storage_locations where id = p_location and warehouse_id = p_st.warehouse_id)
$$;

-- -----------------------------------------------------------------------------
-- record_count: + p_counted_at (time on the phone), p_offline, p_method
-- -----------------------------------------------------------------------------
drop function if exists public.record_count(uuid, uuid, uuid, uuid, numeric, uuid);
create function public.record_count(
  p_request_id uuid, p_stocktake_id uuid, p_product_id uuid, p_location_id uuid, p_qty numeric, p_uom_id uuid default null,
  p_counted_at timestamptz default null, p_offline boolean default false, p_method text default 'typed')
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_st public.stocktakes; v_line public.stocktake_lines; v_uid uuid := auth.uid(); c record; v_round int; v_total numeric;
  v_existing public.stocktake_counts; v_dup boolean; v_at timestamptz; v_late boolean := false;
  v_max interval := make_interval(hours => private.setting_num('counting.offline_max_hours', 72)::int);
begin
  select * into v_existing from public.stocktake_counts where client_request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'count_id', v_existing.id,
      'line_total', (select counted_qty from public.stocktake_lines where id = v_existing.line_id));
  end if;
  if v_uid is null or not private.is_active_user(v_uid) then perform private.fail('CS401', 'Not signed in'); end if;
  select * into v_st from public.stocktakes where id = p_stocktake_id;
  if not found then perform private.fail('CS422', 'Stocktake not found'); end if;
  if not private.can_count(v_st, p_location_id) then
    perform private.fail('CS401', 'You are not assigned to count this stocktake / location');
  end if;
  if coalesce(p_method, 'typed') not in ('typed','scan','empty_bin') then perform private.fail('CS422', 'Unknown count method'); end if;

  -- when was it counted? the phone's time, never before the cut-off and never in the future
  v_at := clock_timestamp();
  if p_counted_at is not null then
    if p_counted_at < clock_timestamp() - v_max then
      perform private.fail('CS422', format('This count was made more than %s hours ago and can no longer be sent. Count the item again.',
                           private.setting_num('counting.offline_max_hours', 72)));
    end if;
    v_at := least(greatest(p_counted_at, coalesce(v_st.cutoff_at, p_counted_at)), clock_timestamp());
  end if;

  if v_st.status = 'review' and coalesce(p_offline, false) and v_at <= v_st.counting_closed_at then
    v_late := true;            -- counted while counting was open, arrived after it closed
  elsif v_st.status not in ('counting','review') then
    perform private.fail('CS423', case when coalesce(p_offline, false)
      then 'This count was sent after the stocktake was submitted (' || v_st.status || '). Tell your supervisor the item and quantity.'
      else 'Counting is not open for this stocktake (' || v_st.status || ')' end);
  end if;
  if p_qty is null or p_qty < 0 then perform private.fail('CS422', 'Enter the quantity counted (0 if none)'); end if;
  perform private.location_warehouse(p_location_id, v_st.warehouse_id);
  if not private.stocktake_in_scope(v_st, p_product_id, p_location_id) then
    perform private.fail('CS422', 'This product / location is outside the scope of this stocktake');
  end if;
  if p_qty = 0 then
    select uom_id, factor, 0::numeric as qty_base into c from private.to_base(p_product_id, p_uom_id, 1);
    c.qty_base := 0;
  else
    select * into c from private.to_base(p_product_id, p_uom_id, p_qty);
  end if;

  select * into v_line from public.stocktake_lines
  where stocktake_id = p_stocktake_id and product_id = p_product_id and location_id = p_location_id for update;
  if not found then
    if v_st.status <> 'counting' and not v_late then perform private.fail('CS423', 'New items can only be added while counting is open'); end if;
    insert into public.stocktake_lines (stocktake_id, product_id, location_id, expected_qty, is_unexpected)
    values (p_stocktake_id, p_product_id, p_location_id, private.physical_qty_at(p_product_id, p_location_id, v_st.cutoff_at), true)
    on conflict (stocktake_id, product_id, location_id) do nothing;
    select * into v_line from public.stocktake_lines
    where stocktake_id = p_stocktake_id and product_id = p_product_id and location_id = p_location_id for update;
  end if;
  if v_st.status = 'review' and not v_late and v_line.line_status <> 'recount_requested' then
    perform private.fail('CS423', 'Counting is closed. Only lines with a requested recount can be counted.');
  end if;
  v_round := v_line.current_round;

  select exists (select 1 from public.stocktake_counts where line_id = v_line.id and round = v_round and not voided
                 and counted_by = v_uid and qty_base = c.qty_base and c.qty_base > 0 and method <> 'scan'
                 and counted_at > v_at - interval '60 seconds' and counted_at < v_at + interval '60 seconds')
    into v_dup;

  insert into public.stocktake_counts (stocktake_id, line_id, round, qty_base, entered_qty, entered_uom_id, counted_by,
                                       client_request_id, counted_at, entered_offline, method)
  values (p_stocktake_id, v_line.id, v_round, c.qty_base, p_qty, c.uom_id, v_uid, p_request_id, v_at,
          coalesce(p_offline, false), coalesce(p_method, 'typed'));

  select sum(qty_base) into v_total from public.stocktake_counts where line_id = v_line.id and round = v_round and not voided;
  update public.stocktake_lines set counted_qty = v_total,
         counted_at = greatest(coalesce(counted_at, '-infinity'::timestamptz), v_at),
         first_count_qty = case when v_round = 1 then v_total else first_count_qty end,
         line_status = case when v_round = 1 then 'counted' else 'recounted' end,
         flags = case when v_dup and not ('possible_duplicate_entry' = any(flags)) then flags || 'possible_duplicate_entry'::text else flags end
  where id = v_line.id;

  if v_late then
    perform private.stocktake_compare(p_stocktake_id);
    perform private.raise_alert('stocktake_discrepancy', 'info', 'Late offline count: ' || v_st.stocktake_no,
      format('A count made before counting closed arrived later from a phone that was offline (%s). The comparison was refreshed.',
             (select full_name from public.app_users where id = v_uid)),
      'late_count:' || p_stocktake_id, null, v_st.warehouse_id, null, null, null, 'stocktake', p_stocktake_id::text, false,
      '/stocktake/' || p_stocktake_id);
  end if;

  return jsonb_build_object('ok', true, 'duplicate', false, 'line_id', v_line.id, 'line_total', v_total, 'round', v_round,
                            'possible_duplicate_entry', v_dup, 'unexpected', v_line.is_unexpected, 'late', v_late,
                            'counted_at', v_at);
end $$;

-- -----------------------------------------------------------------------------
-- Everything a counter's phone needs to keep counting offline
-- -----------------------------------------------------------------------------
create or replace function public.stocktake_offline_pack(p_stocktake_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes; v_show boolean; v_scope uuid[]; v_assigned boolean;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id;
  if not found then perform private.fail('CS422', 'Stocktake not found'); end if;
  if not (private.has_wh_perm('stocktake.count', v_st.warehouse_id) or private.has_wh_perm('stocktake.manage', v_st.warehouse_id)
          or private.is_stocktake_assignee(p_stocktake_id)) then
    perform private.fail('CS401', 'You are not assigned to this stocktake');
  end if;
  v_show := not v_st.blind or private.has_wh_perm('stocktake.manage', v_st.warehouse_id)
            or private.has_wh_perm('stocktake.approve', v_st.warehouse_id);
  select location_ids, true into v_scope, v_assigned from public.stocktake_assignments
   where stocktake_id = p_stocktake_id and user_id = auth.uid();
  v_scope := coalesce(private.location_tree(v_scope), null);
  if v_scope = '{}' then v_scope := null; end if;
  if v_st.location_ids is not null then
    v_scope := case when v_scope is null then private.location_tree(v_st.location_ids)
                    else array(select unnest(v_scope) intersect select unnest(private.location_tree(v_st.location_ids))) end;
  end if;

  return jsonb_build_object(
    'generated_at', now(),
    'stocktake', jsonb_build_object('id', v_st.id, 'stocktake_no', v_st.stocktake_no, 'name', v_st.name, 'status', v_st.status,
       'kind', v_st.kind, 'blind', v_st.blind, 'warehouse_id', v_st.warehouse_id, 'cutoff_at', v_st.cutoff_at,
       'counting_closed_at', v_st.counting_closed_at, 'product_scoped', v_st.product_ids is not null,
       'warehouse_code', (select code from public.warehouses where id = v_st.warehouse_id)),
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'code', l.code, 'name', l.name, 'label_code', l.label_code,
                     'walk_order', l.walk_order) order by l.walk_order nulls last, l.code), '[]')
                  from public.storage_locations l
                  where l.warehouse_id = v_st.warehouse_id and l.status = 'active' and (v_scope is null or l.id = any(v_scope))),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_id', l.id, 'product_id', l.product_id, 'location_id', l.location_id,
                     'counted_qty', l.counted_qty, 'line_status', l.line_status, 'current_round', l.current_round,
                     'expected_qty', case when v_show then l.expected_qty end, 'is_unexpected', l.is_unexpected)), '[]')
              from public.stocktake_lines l
              where l.stocktake_id = p_stocktake_id and (v_scope is null or l.location_id = any(v_scope))),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'description', p.description,
                     'base_uom_id', p.base_uom_id, 'base_uom', u.code, 'decimals', u.decimals,
                     'units', (select coalesce(jsonb_agg(jsonb_build_object('uom_id', pu.uom_id, 'code', uu.code, 'factor', pu.factor_to_base,
                                  'decimals', uu.decimals) order by pu.factor_to_base), '[]')
                               from public.product_uoms pu join public.uoms uu on uu.id = pu.uom_id where pu.product_id = p.id),
                     'barcodes', (select coalesce(jsonb_agg(jsonb_build_object('code', b.code, 'uom_id', b.uom_id)), '[]')
                                  from public.barcodes b where b.product_id = p.id))), '[]')
                 from public.products p join public.uoms u on u.id = p.base_uom_id
                 where p.status = 'active' and (v_st.product_ids is null or p.id = any(v_st.product_ids))
                   and (v_st.category_ids is null or p.category_id = any(private.category_tree(v_st.category_ids)))),
    'my_counts', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'line_id', c.line_id, 'qty_base', c.qty_base,
                      'counted_at', c.counted_at, 'round', c.round, 'voided', c.voided, 'method', c.method) order by c.counted_at desc), '[]')
                  from (select * from public.stocktake_counts where stocktake_id = p_stocktake_id and counted_by = auth.uid()
                        order by counted_at desc limit 200) c));
end $$;

-- record 0 for every line of a bin the counter confirms is empty (one call, retry-safe)
create or replace function public.record_empty_location(p_request_id uuid, p_stocktake_id uuid, p_location_id uuid,
  p_counted_at timestamptz default null, p_offline boolean default false)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare l record; v_n int := 0; v_ns uuid := p_request_id; v_res jsonb;
begin
  for l in select sl.product_id from public.stocktake_lines sl
           where sl.stocktake_id = p_stocktake_id and sl.location_id = p_location_id and sl.counted_qty is null
           order by sl.product_id loop
    -- a deterministic id per (request, product) keeps the whole call retry-safe
    v_res := public.record_count(
      (substr(md5(v_ns::text || l.product_id::text), 1, 8) || '-' || substr(md5(v_ns::text || l.product_id::text), 9, 4) || '-4' ||
       substr(md5(v_ns::text || l.product_id::text), 14, 3) || '-a' || substr(md5(v_ns::text || l.product_id::text), 18, 3) || '-' ||
       substr(md5(v_ns::text || l.product_id::text), 21, 12))::uuid,
      p_stocktake_id, l.product_id, p_location_id, 0, null, p_counted_at, p_offline, 'empty_bin');
    if not coalesce((v_res ->> 'duplicate')::boolean, false) then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'lines_zeroed', v_n);
end $$;

-- -----------------------------------------------------------------------------
-- Cycle counting
-- -----------------------------------------------------------------------------
-- start a stocktake without a user session (used by the daily cycle-count job)
create or replace function private.start_stocktake_internal(p_stocktake_id uuid) returns int
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes; v_cut timestamptz; v_lines int;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id for update;
  lock table public.stock_balances in share mode;
  v_cut := clock_timestamp();
  insert into public.stocktake_lines (stocktake_id, product_id, location_id, expected_qty)
  select v_st.id, b.product_id, b.location_id, sum(b.qty)
  from public.stock_balances b
  where b.warehouse_id = v_st.warehouse_id and b.status <> 'in_transit'
    and private.stocktake_in_scope(v_st, b.product_id, b.location_id)
  group by b.product_id, b.location_id
  having sum(b.qty) <> 0;
  get diagnostics v_lines = row_count;
  update public.stocktakes set status = 'counting', cutoff_at = v_cut where id = p_stocktake_id;
  return v_lines;
end $$;

-- which items are due for a cycle count at a warehouse, most important first
create or replace function private.cycle_candidates(p_warehouse uuid, p_limit int)
returns table (product_id uuid, abc text, last_counted timestamptz, due_days int)
language sql stable security definer set search_path = public, private, pg_temp as $$
  with c as (select * from private.an_unit_costs(now())),
  onhand as (
    select b.product_id, sum(b.qty) as q from public.stock_balances b
     where b.warehouse_id = p_warehouse and b.status <> 'in_transit' group by 1 having sum(b.qty) > 0),
  usage as (
    select l.product_id, -sum(l.qty_delta * coalesce(c.unit_cost, 1)) as v
      from public.stock_ledger l left join c on c.product_id = l.product_id
     where l.warehouse_id = p_warehouse and l.txn_type in ('withdrawal','return') and l.posted_at > now() - interval '90 days'
     group by 1),
  ranked as (
    select o.product_id, coalesce(u.v, 0) as v,
           sum(coalesce(u.v, 0)) over (order by coalesce(u.v, 0) desc, o.product_id rows unbounded preceding) as cum,
           sum(coalesce(u.v, 0)) over () as tot
      from onhand o left join usage u on u.product_id = o.product_id
      join public.products p on p.id = o.product_id and p.status = 'active' and not p.is_asset),
  cls as (
    select product_id, case when tot = 0 or v = 0 then 'C' when cum - v < 0.8 * tot then 'A' when cum - v < 0.95 * tot then 'B' else 'C' end as abc
      from ranked),
  last as (
    select sl.product_id, max(coalesce(s.finalised_at, sl.counted_at)) as at
      from public.stocktake_lines sl join public.stocktakes s on s.id = sl.stocktake_id
     where s.warehouse_id = p_warehouse and sl.counted_qty is not null and s.status <> 'cancelled' group by 1),
  open_cycles as (
    select distinct unnest(s.product_ids) as product_id from public.stocktakes s
     where s.warehouse_id = p_warehouse and s.kind = 'cycle' and s.status in ('scheduled','counting','review','pending_approval'))
  select cls.product_id, cls.abc, last.at,
         case cls.abc when 'A' then private.setting_num('cycle.a_days', 30) when 'B' then private.setting_num('cycle.b_days', 60)
                      else private.setting_num('cycle.c_days', 120) end::int
    from cls left join last on last.product_id = cls.product_id
   where cls.product_id not in (select product_id from open_cycles)
     and (last.at is null or last.at < now() - make_interval(days =>
           case cls.abc when 'A' then private.setting_num('cycle.a_days', 30) when 'B' then private.setting_num('cycle.b_days', 60)
                        else private.setting_num('cycle.c_days', 120) end::int))
   order by case cls.abc when 'A' then 1 when 'B' then 2 else 3 end, last.at nulls first
   limit p_limit
$$;

create or replace function private.create_cycle_count(p_warehouse uuid, p_items int, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_ids uuid[]; v_id uuid; v_code text; v_day date := (now() at time zone 'Africa/Johannesburg')::date;
begin
  select array_agg(product_id) into v_ids from private.cycle_candidates(p_warehouse, p_items);
  if v_ids is null then return null; end if;
  select code into v_code from public.warehouses where id = p_warehouse;
  insert into public.stocktakes (stocktake_no, name, period, warehouse_id, product_ids, kind, blind, due_date, notes, created_by)
  values (private.next_doc_no('CYC'), 'Cycle count ' || to_char(v_day, 'DD/MM/YYYY') || ' — ' || v_code,
          to_char(v_day, 'YYYY-MM'), p_warehouse, v_ids, 'cycle', true, v_day,
          cardinality(v_ids) || ' items due by A/B/C class', coalesce(p_by, '00000000-0000-0000-0000-000000000000'))
  returning id into v_id;
  perform private.start_stocktake_internal(v_id);
  -- tell the counters of that warehouse
  insert into public.notifications (user_id, title, body, link)
  select distinct u.id, 'Today''s cycle count: ' || v_code, cardinality(v_ids) || ' items to count — about 10 minutes.', '/tasks'
    from public.app_users u join public.user_role_assignments a on a.user_id = u.id
    join public.roles r on r.id = a.role_id and 'stocktake.count' = any(r.permissions)
    join private.warehouse_tree t on t.warehouse_id = p_warehouse
   where u.is_active and (a.scope_type = 'group' or (a.scope_type = 'company' and a.scope_id = t.company_id)
         or (a.scope_type = 'branch' and a.scope_id = t.branch_id) or (a.scope_type = 'warehouse' and a.scope_id = p_warehouse))
     and a.scope_type <> 'group';
  return v_id;
end $$;

-- manual: a manager creates a cycle count now (e.g. to try it, or for one warehouse)
create or replace function public.create_cycle_count(p_warehouse_id uuid, p_items int default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_id uuid; v_n int;
begin
  v_uid := private.require_perm('stocktake.manage', p_warehouse_id);
  v_n := coalesce(p_items, nullif(private.setting_num('cycle.items_per_day', 0), 0)::int, 15);
  if v_n < 1 or v_n > 500 then perform private.fail('CS422', 'Choose 1 to 500 items'); end if;
  v_id := private.create_cycle_count(p_warehouse_id, v_n, v_uid);
  if v_id is null then
    return jsonb_build_object('ok', true, 'created', false, 'message', 'Nothing is due for a count at this warehouse right now.');
  end if;
  return jsonb_build_object('ok', true, 'created', true, 'stocktake_id', v_id,
    'stocktake_no', (select stocktake_no from public.stocktakes where id = v_id),
    'items', (select cardinality(product_ids) from public.stocktakes where id = v_id));
end $$;

-- daily job: Mon–Fri after cycle.create_time, one cycle count per active warehouse with stock
create or replace function private.ops_cycle_counts() returns jsonb
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_local timestamp := now() at time zone 'Africa/Johannesburg'; v_n int := private.setting_num('cycle.items_per_day', 0)::int;
        w record; v_made int := 0;
begin
  if v_n <= 0 then return jsonb_build_object('skipped', 'off'); end if;
  if extract(isodow from v_local) > 5 then return jsonb_build_object('skipped', 'weekend'); end if;
  if v_local::time < private.setting_text('cycle.create_time', '06:00')::time then return jsonb_build_object('skipped', 'too early'); end if;
  for w in select wh.id from public.warehouses wh where wh.status = 'active'
             and not exists (select 1 from public.stocktakes s where s.warehouse_id = wh.id and s.kind = 'cycle'
                             and (s.created_at at time zone 'Africa/Johannesburg')::date = v_local::date)
             and exists (select 1 from public.stock_balances b where b.warehouse_id = wh.id and b.qty > 0) loop
    if private.create_cycle_count(w.id, v_n) is not null then v_made := v_made + 1; end if;
  end loop;
  return jsonb_build_object('created', v_made);
end $$;

-- -----------------------------------------------------------------------------
-- The worker's home screen: everything waiting for me today
-- -----------------------------------------------------------------------------
create or replace function public.my_tasks()
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('CS401', 'Not signed in'); end if;
  return jsonb_build_object(
    'counts', (select coalesce(jsonb_agg(x order by x ->> 'due_date', x ->> 'stocktake_no'), '[]') from (
        select jsonb_build_object('id', s.id, 'stocktake_no', s.stocktake_no, 'name', s.name, 'kind', s.kind, 'status', s.status,
               'due_date', s.due_date, 'warehouse_code', w.code, 'is_overdue', s.due_date < (now() at time zone 'Africa/Johannesburg')::date,
               'lines', (select count(*) from public.stocktake_lines l where l.stocktake_id = s.id),
               'counted', (select count(*) from public.stocktake_lines l where l.stocktake_id = s.id and l.counted_qty is not null),
               'recounts', (select count(*) from public.stocktake_lines l where l.stocktake_id = s.id and l.line_status = 'recount_requested'),
               'assigned', exists (select 1 from public.stocktake_assignments a where a.stocktake_id = s.id and a.user_id = v_uid)) as x
          from public.stocktakes s join public.warehouses w on w.id = s.warehouse_id
         where (s.status = 'counting' or (s.status = 'review' and exists (select 1 from public.stocktake_lines l where l.stocktake_id = s.id and l.line_status = 'recount_requested')))
           and (exists (select 1 from public.stocktake_assignments a where a.stocktake_id = s.id and a.user_id = v_uid)
                or (s.warehouse_id = any(private.my_warehouses('stocktake.count'))
                    and not exists (select 1 from public.stocktake_assignments a where a.stocktake_id = s.id)))) q),
    'tools', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'asset_tag', a.asset_tag, 'description', p.description,
                 'due_back_at', a.due_back_at, 'is_overdue', a.due_back_at < now(), 'job_reference', a.job_reference) order by a.due_back_at), '[]')
              from public.assets a join public.products p on p.id = a.product_id
             where a.status = 'checked_out' and a.holder_user_id = v_uid),
    'transfers', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'transfer_no', t.transfer_no, 'from', fw.code, 'to', tw.code,
                     'expected_arrival_at', t.expected_arrival_at, 'is_overdue', t.expected_arrival_at < now()) order by t.expected_arrival_at), '[]')
                  from public.transfers t join public.warehouses fw on fw.id = t.from_warehouse_id join public.warehouses tw on tw.id = t.to_warehouse_id
                 where t.status in ('dispatched','partially_received') and t.to_warehouse_id = any(private.my_warehouses('stock.transfer.receive'))),
    'approvals', (select count(*) from public.approval_requests a where a.status = 'pending' and a.id = any(public.approvals_i_can_decide())),
    'unread', (select count(*) from public.notifications n where n.user_id = v_uid and n.read_at is null));
end $$;

-- -----------------------------------------------------------------------------
-- Setup helpers: create many bins at once, and the walking route for counting
-- -----------------------------------------------------------------------------
-- e.g. prefix 'A', aisles 3, bays 4, levels 2 -> A1-01-1 … A3-04-2 (24 bins) in walking order (snake through the aisles)
create or replace function public.generate_locations(p_warehouse_id uuid, p_prefix text, p_aisles int, p_bays int, p_levels int default 1)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_wh public.warehouses; a int; b int; l int; v_code text; v_made int := 0; v_skip int := 0;
        v_order int; v_bay int;
begin
  v_uid := private.require_perm('setup.manage');
  select * into v_wh from public.warehouses where id = p_warehouse_id and status = 'active';
  if not found then perform private.fail('CS422', 'Choose an active warehouse'); end if;
  p_prefix := upper(trim(coalesce(p_prefix, '')));
  if p_prefix !~ '^[A-Z0-9][A-Z0-9_-]{0,9}$' then perform private.fail('CS422', 'Use a short prefix of letters and numbers, e.g. A or RACK'); end if;
  if p_aisles not between 1 and 50 or p_bays not between 1 and 99 or coalesce(p_levels, 1) not between 1 and 9 then
    perform private.fail('CS422', 'Aisles 1–50, bays 1–99, levels 1–9');
  end if;
  if p_aisles * p_bays * coalesce(p_levels, 1) > 2000 then perform private.fail('CS422', 'At most 2 000 bins at a time'); end if;
  select coalesce(max(walk_order), 0) into v_order from public.storage_locations where warehouse_id = p_warehouse_id;
  for a in 1..p_aisles loop
    for b in 1..p_bays loop
      v_bay := case when a % 2 = 1 then b else p_bays + 1 - b end;     -- up one aisle, down the next
      for l in 1..coalesce(p_levels, 1) loop
        v_code := p_prefix || a || '-' || lpad(v_bay::text, 2, '0') || case when coalesce(p_levels, 1) > 1 then '-' || l else '' end;
        v_order := v_order + 1;
        insert into public.storage_locations (warehouse_id, kind, code, name, label_code, walk_order)
        values (p_warehouse_id, 'bin', v_code, format('Aisle %s%s, bay %s%s', p_prefix, a, v_bay, case when coalesce(p_levels, 1) > 1 then ', level ' || l else '' end),
                'LOC-' || v_wh.code || '-' || v_code, v_order)
        on conflict do nothing;
        if found then v_made := v_made + 1; else v_skip := v_skip + 1; end if;
      end loop;
    end loop;
  end loop;
  perform private.log_action('GENERATE_LOCATIONS', 'warehouses', p_warehouse_id::text,
    jsonb_build_object('prefix', p_prefix, 'aisles', p_aisles, 'bays', p_bays, 'levels', p_levels, 'created', v_made));
  return jsonb_build_object('ok', true, 'created', v_made, 'skipped_existing', v_skip);
end $$;

-- the order bins are visited when counting (first id = first bin)
create or replace function public.set_walk_order(p_warehouse_id uuid, p_location_ids uuid[])
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_n int;
begin
  v_uid := private.require_perm('setup.manage');
  if exists (select 1 from unnest(p_location_ids) x where not exists (
               select 1 from public.storage_locations where id = x and warehouse_id = p_warehouse_id)) then
    perform private.fail('CS422', 'Every location must belong to this warehouse');
  end if;
  update public.storage_locations s set walk_order = o.ord
    from unnest(p_location_ids) with ordinality as o(id, ord) where s.id = o.id;
  get diagnostics v_n = row_count;
  update public.storage_locations set walk_order = null
   where warehouse_id = p_warehouse_id and not (id = any(p_location_ids));
  return jsonb_build_object('ok', true, 'ordered', v_n);
end $$;


-- ===== 20261031001100_phase4_floor_people.sql =====
-- =============================================================================
-- CSWMS Phase 4 — Floor experience (part 2): self-correction, photo evidence,
-- personal settings (language, text size, WhatsApp), training warehouse,
-- WhatsApp alerts, accounting journal export, weekly management summary.
-- =============================================================================

insert into public.app_settings (key, value, category, description) values
  ('undo.minutes',                 '10',    'controls',   'Staff may undo their own receipt, withdrawal, return, move or status change within this many minutes, without approval (0 = off)'),
  ('alerts.whatsapp_enabled',      'false', 'alerts',     'Send alerts by WhatsApp to people who opted in (needs the WhatsApp settings in Vercel)'),
  ('reports.weekly_summary',       'true',  'alerts',     'E-mail a weekly management summary every Monday morning (needs alert e-mails switched on)'),
  ('accounting.inventory_account', '"630"', 'accounting', 'General-ledger account for stock on hand (inventory asset)'),
  ('accounting.receipts_account',  '"800"', 'accounting', 'Contra account for stock received (goods received not invoiced / accounts payable)'),
  ('accounting.consumption_account','"310"','accounting', 'Account for stock issued (cost of sales / consumables expense)'),
  ('accounting.adjustment_account','"315"', 'accounting', 'Account for stock adjustments, stocktake variances and write-offs'),
  ('accounting.opening_account',   '"960"', 'accounting', 'Account for opening balances (e.g. opening balance equity / suspense)'),
  ('accounting.intercompany_account','"815"','accounting','Account for stock moved between companies'),
  ('accounting.tax_rate',          '"No VAT"', 'accounting', 'Tax-rate name written on journal lines (Xero "TaxRate" column)')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- 1. Undo my own transaction (self-correction)
-- -----------------------------------------------------------------------------
create or replace function public.undo_my_transaction(p_request_id uuid, p_txn_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_orig public.stock_transactions; v_txn public.stock_transactions;
  r record; i int := 0; v_res jsonb; v_min numeric := private.setting_num('undo.minutes', 10); v_perm text; v_appr uuid;
begin
  v_payload := jsonb_build_object('txn', p_txn_id, 'reason', p_reason);
  v_prev := private.idem_begin(p_request_id, 'undo_my_transaction', v_payload);
  if v_prev is not null then return v_prev; end if;
  select * into v_orig from public.stock_transactions where id = p_txn_id for update;
  if not found then perform private.fail('CS422', 'Transaction not found'); end if;
  v_perm := case v_orig.txn_type when 'receipt' then 'stock.receive' when 'withdrawal' then 'stock.withdraw'
                 when 'return' then 'stock.return' when 'move' then 'stock.move' when 'status_change' then 'stock.adjust' end;
  if v_perm is null then
    perform private.fail('CS422', 'Only receipts, withdrawals, returns, moves and status changes can be undone this way. Ask a manager for a reversal.');
  end if;
  v_uid := private.require_perm(v_perm, v_orig.warehouse_id);
  if v_min <= 0 then perform private.fail('CS423', 'Quick undo is switched off. Ask a manager for a reversal.'); end if;
  if v_orig.created_by <> v_uid then perform private.fail('CS401', 'You can only undo your own transactions. Ask a manager for a reversal.'); end if;
  if v_orig.status <> 'posted' then perform private.fail('CS423', 'Only posted transactions can be undone'); end if;
  if v_orig.posted_at < now() - make_interval(mins => v_min::int) then
    perform private.fail('CS423', format('The %s-minute undo window has passed. Ask a manager for a reversal.', v_min));
  end if;
  if coalesce(trim(p_reason), '') = '' then perform private.fail('CS422', 'Say briefly what was wrong (e.g. "wrong item scanned")'); end if;
  if exists (select 1 from public.stock_transaction_lines where txn_id = p_txn_id and extra ? 'po_id') then
    perform private.fail('CS423', 'Receipts against a purchase order are corrected by purchasing (ask your supervisor).');
  end if;
  if exists (select 1 from public.stock_transactions where related_txn_id = p_txn_id and txn_type = 'reversal'
             and status in ('pending_approval','posted')) then
    perform private.fail('CS423', 'This transaction has already been undone or reversed');
  end if;

  v_txn := private.new_txn('reversal', 'pending_approval', v_orig.warehouse_id, p_request_id, null,
                           'Undo of ' || v_orig.txn_no, 'Self-correction: ' || trim(p_reason), null, p_txn_id);
  for r in select * from public.stock_ledger where txn_id = p_txn_id order by id loop
    i := i + 1;
    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status,
         qty_base, entered_qty, entered_uom_id, factor, extra)
    values (v_txn.id, i, r.product_id, r.location_id, r.owner_company_id, r.status, -r.qty_delta,
            -sign(r.qty_delta) * r.entered_qty, r.entered_uom_id, r.factor,
            jsonb_build_object('reverses_ledger_id', r.id, 'self_correction', true));
  end loop;
  -- recorded as approved under the self-correction rule (decided_by null = the system, the rule is in the note)
  insert into public.approval_requests (kind, status, required_perm, warehouse_id, txn_id, summary, details, requested_by,
                                        decided_at, decision_note)
  values ('reversal', 'approved', 'stock.approve', v_orig.warehouse_id, v_txn.id,
          'Self-correction: undo of ' || v_orig.txn_no,
          jsonb_build_object('rule', 'self_correction', 'window_minutes', v_min, 'original', v_orig.txn_no, 'reason', trim(p_reason)),
          v_uid, now(), format('Approved automatically: own %s undone within %s minutes (rule undo.minutes).', v_orig.txn_type, v_min))
  returning id into v_appr;
  v_res := private.post_movements(v_txn.id, private.moves_from_lines(v_txn.id), v_uid);
  perform private.log_action('SELF_UNDO', 'stock_transactions', p_txn_id::text,
    jsonb_build_object('undo_txn', v_txn.txn_no, 'reason', trim(p_reason)));
  return private.idem_finish(p_request_id, 'undo_my_transaction', v_payload,
    jsonb_build_object('ok', true, 'status', 'posted', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no, 'undid', v_orig.txn_no));
end $$;

-- the transactions I could still undo (for the "Undo" buttons)
create or replace function public.my_undoable_transactions()
returns setof jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('id', t.id, 'txn_no', t.txn_no, 'txn_type', t.txn_type, 'posted_at', t.posted_at, 'reference', t.reference,
           'warehouse_code', w.code,
           'seconds_left', greatest(0, extract(epoch from t.posted_at + make_interval(mins => private.setting_num('undo.minutes', 10)::int) - now()))::int,
           'items', (select string_agg(p.sku || ' ' || trim(to_char(abs(l.qty_base), 'FM999999990.####')), ', ' order by l.line_no)
                       from public.stock_transaction_lines l join public.products p on p.id = l.product_id where l.txn_id = t.id))
    from public.stock_transactions t join public.warehouses w on w.id = t.warehouse_id
   where t.created_by = auth.uid() and t.status = 'posted'
     and t.txn_type in ('receipt','withdrawal','return','move','status_change')
     and t.posted_at > now() - make_interval(mins => private.setting_num('undo.minutes', 10)::int)
     and not exists (select 1 from public.stock_transactions r where r.related_txn_id = t.id and r.txn_type = 'reversal' and r.status in ('pending_approval','posted'))
     and not exists (select 1 from public.stock_transaction_lines l where l.txn_id = t.id and l.extra ? 'po_id')
   order by t.posted_at desc
$$;

-- -----------------------------------------------------------------------------
-- 2. Photo evidence (files live in the private Storage bucket "evidence";
--    the app server uploads and signs links only after these checks)
-- -----------------------------------------------------------------------------
create table public.attachments (
  id            uuid primary key default gen_random_uuid(),
  entity_type   text not null check (entity_type in ('txn','stocktake_line','asset','stocktake')),
  entity_id     uuid not null,
  warehouse_id  uuid not null references public.warehouses(id),
  storage_path  text not null unique,
  mime          text not null check (mime in ('image/jpeg','image/png','image/webp')),
  bytes         int not null check (bytes > 0 and bytes <= 8388608),
  caption       text,
  uploaded_by   uuid not null,
  created_at    timestamptz not null default now()
);
create index on public.attachments (entity_type, entity_id);
create trigger attachments_immutable before update or delete on public.attachments
  for each row execute function private.block_modification();

create or replace function private.attachment_entity_warehouse(p_type text, p_id uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select case p_type
    when 'txn' then (select warehouse_id from public.stock_transactions where id = p_id)
    when 'stocktake' then (select warehouse_id from public.stocktakes where id = p_id)
    when 'stocktake_line' then (select s.warehouse_id from public.stocktake_lines l join public.stocktakes s on s.id = l.stocktake_id where l.id = p_id)
    when 'asset' then (select warehouse_id from public.assets where id = p_id) end
$$;

create or replace function public.register_attachment(p_entity_type text, p_entity_id uuid, p_mime text, p_bytes int, p_caption text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid := auth.uid(); v_wh uuid; v_id uuid := gen_random_uuid(); v_path text; v_ext text;
begin
  if v_uid is null or not private.is_active_user(v_uid) then perform private.fail('CS401', 'Not signed in'); end if;
  v_wh := private.attachment_entity_warehouse(p_entity_type, p_entity_id);
  if v_wh is null then perform private.fail('CS422', 'Nothing to attach the photo to'); end if;
  if not (v_wh = any(private.my_warehouses('stock.view')) or v_wh = any(private.my_warehouses('stocktake.count'))
          or (p_entity_type = 'txn' and exists (select 1 from public.stock_transactions where id = p_entity_id and created_by = v_uid))) then
    perform private.fail('CS401', 'You may not add photos for this warehouse');
  end if;
  if (select count(*) from public.attachments where entity_type = p_entity_type and entity_id = p_entity_id) >= 10 then
    perform private.fail('CS422', 'At most 10 photos per record');
  end if;
  v_ext := case p_mime when 'image/png' then 'png' when 'image/webp' then 'webp' else 'jpg' end;
  v_path := v_wh || '/' || p_entity_type || '/' || p_entity_id || '/' || v_id || '.' || v_ext;
  insert into public.attachments (id, entity_type, entity_id, warehouse_id, storage_path, mime, bytes, caption, uploaded_by)
  values (v_id, p_entity_type, p_entity_id, v_wh, v_path, p_mime, p_bytes, nullif(trim(p_caption), ''), v_uid);
  perform private.log_action('ATTACH', p_entity_type, p_entity_id::text, jsonb_build_object('attachment', v_id));
  return jsonb_build_object('ok', true, 'id', v_id, 'storage_path', v_path);
end $$;

-- a visible attachment's path (the app server then signs a short-lived link)
create or replace function public.attachment_path(p_id uuid) returns text
language sql stable security definer set search_path = public, private, pg_temp as $$
  select a.storage_path from public.attachments a
   where a.id = p_id and (a.uploaded_by = auth.uid() or a.warehouse_id = any(private.my_warehouses('stock.view'))
                          or a.warehouse_id = any(private.my_warehouses('stocktake.manage')))
$$;

create or replace function public.list_attachments(p_entity_type text, p_entity_id uuid)
returns setof jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('id', a.id, 'caption', a.caption, 'mime', a.mime, 'bytes', a.bytes, 'created_at', a.created_at,
           'uploaded_by', coalesce(u.full_name, u.email))
    from public.attachments a left join public.app_users u on u.id = a.uploaded_by
   where a.entity_type = p_entity_type and a.entity_id = p_entity_id
     and (a.uploaded_by = auth.uid() or a.warehouse_id = any(private.my_warehouses('stock.view'))
          or a.warehouse_id = any(private.my_warehouses('stocktake.manage')))
   order by a.created_at
$$;

alter table public.attachments enable row level security;
revoke all on public.attachments from anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. Personal settings: language, text size, WhatsApp
-- -----------------------------------------------------------------------------
alter table public.app_users add column if not exists language text not null default 'en' check (language in ('en','af','zu','xh'));
alter table public.app_users add column if not exists text_size text not null default 'normal' check (text_size in ('normal','large','xlarge'));
alter table public.app_users add column if not exists whatsapp_opt_in boolean not null default false;
alter table public.notification_preferences add column if not exists whatsapp_min_severity text not null default 'warning'
  check (whatsapp_min_severity in ('info','warning','critical'));

create or replace function public.my_preferences()
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('language', u.language, 'text_size', u.text_size, 'phone', u.phone, 'whatsapp_opt_in', u.whatsapp_opt_in,
           'whatsapp_min_severity', coalesce(np.whatsapp_min_severity, 'warning'),
           'whatsapp_system_enabled', private.setting_bool('alerts.whatsapp_enabled', false),
           'undo_minutes', private.setting_num('undo.minutes', 10))
    from public.app_users u left join public.notification_preferences np on np.user_id = u.id
   where u.id = auth.uid()
$$;

create or replace function public.set_my_preferences(p_language text default null, p_text_size text default null,
  p_phone text default null, p_whatsapp_opt_in boolean default null, p_whatsapp_min_severity text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid := auth.uid(); v_phone text;
begin
  if v_uid is null or not private.is_active_user(v_uid) then perform private.fail('CS401', 'Not signed in'); end if;
  if p_language is not null and p_language not in ('en','af','zu','xh') then perform private.fail('CS422', 'Unknown language'); end if;
  if p_text_size is not null and p_text_size not in ('normal','large','xlarge') then perform private.fail('CS422', 'Unknown text size'); end if;
  if p_phone is not null then
    v_phone := regexp_replace(p_phone, '[\s()-]', '', 'g');
    if v_phone ~ '^0[6-8][0-9]{8}$' then v_phone := '+27' || substr(v_phone, 2); end if;   -- SA mobile 0821234567 -> +27821234567
    if v_phone <> '' and v_phone !~ '^\+[1-9][0-9]{7,14}$' then
      perform private.fail('CS422', 'Enter the mobile number like 082 123 4567 or +27 82 123 4567');
    end if;
  end if;
  if coalesce(p_whatsapp_opt_in, false) and coalesce(nullif(v_phone, ''), (select phone from public.app_users where id = v_uid)) is null then
    perform private.fail('CS422', 'Add your mobile number to receive WhatsApp alerts');
  end if;
  update public.app_users set
    language = coalesce(p_language, language), text_size = coalesce(p_text_size, text_size),
    phone = case when p_phone is null then phone else nullif(v_phone, '') end,
    whatsapp_opt_in = coalesce(p_whatsapp_opt_in, whatsapp_opt_in)
  where id = v_uid;
  if p_whatsapp_min_severity is not null then
    if p_whatsapp_min_severity not in ('info','warning','critical') then perform private.fail('CS422', 'Invalid severity'); end if;
    insert into public.notification_preferences (user_id, whatsapp_min_severity) values (v_uid, p_whatsapp_min_severity)
    on conflict (user_id) do update set whatsapp_min_severity = excluded.whatsapp_min_severity, updated_at = now();
  end if;
  return jsonb_build_object('ok', true) || public.my_preferences();
end $$;

-- -----------------------------------------------------------------------------
-- 4. WhatsApp outbox (delivered by /api/cron through the WhatsApp Cloud API)
-- -----------------------------------------------------------------------------
create table private.message_outbox (
  id          uuid primary key default gen_random_uuid(),
  channel     text not null default 'whatsapp' check (channel in ('whatsapp')),
  to_phone    text not null,
  title       text not null,
  body        text not null,
  link        text,
  status      text not null default 'pending' check (status in ('pending','sending','sent','failed')),
  attempts    int not null default 0,
  last_error  text,
  dedupe_key  text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create unique index message_outbox_dedupe on private.message_outbox (dedupe_key, to_phone) where dedupe_key is not null;
create index on private.message_outbox (status, created_at);

create or replace function public.message_outbox_claim(p_limit int default 40)
returns table (id uuid, channel text, to_phone text, title text, body text, link text)
language sql security definer set search_path = private, pg_temp as $$
  update private.message_outbox o set status = 'sending', attempts = attempts + 1
  where o.id in (select id from private.message_outbox
                 where status = 'pending' or (status = 'failed' and attempts < 5)
                    or (status = 'sending' and created_at < now() - interval '30 minutes' and attempts < 5)
                 order by created_at limit p_limit for update skip locked)
  returning o.id, o.channel, o.to_phone, o.title, o.body, o.link
$$;
create or replace function public.message_outbox_result(p_id uuid, p_ok boolean, p_error text default null)
returns void language sql security definer set search_path = private, pg_temp as $$
  update private.message_outbox set status = case when p_ok then 'sent' else 'failed' end,
         sent_at = case when p_ok then now() end, last_error = p_error
  where id = p_id
$$;

-- raise_alert: as Phase 2, plus WhatsApp for people who opted in
create or replace function private.raise_alert(
  p_type text, p_severity text, p_title text, p_message text, p_dedupe_key text, p_product uuid default null,
  p_warehouse uuid default null, p_company uuid default null, p_location uuid default null, p_qty numeric default null,
  p_ref_type text default null, p_ref_id text default null, p_escalate boolean default false, p_link text default null)
returns uuid language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_alert public.alerts;
  v_notify boolean := false;
  v_company uuid := p_company;
  r record;
  sev_rank constant jsonb := '{"info":1,"warning":2,"critical":3}';
  v_pref public.notification_preferences;
  v_user public.app_users;
begin
  if v_company is null and p_warehouse is not null then
    select company_id into v_company from private.warehouse_tree where warehouse_id = p_warehouse;
  end if;
  select * into v_alert from public.alerts where dedupe_key = p_dedupe_key and status <> 'resolved' for update;
  if found then
    v_notify := (sev_rank ->> p_severity)::int > (sev_rank ->> v_alert.severity)::int
                or (p_escalate and not v_alert.escalated);
    update public.alerts set
      severity = case when (sev_rank ->> p_severity)::int > (sev_rank ->> severity)::int then p_severity else severity end,
      title = p_title, message = p_message, qty = p_qty,
      escalated = escalated or p_escalate,
      occurrences = occurrences + 1, last_raised_at = now()
    where id = v_alert.id
    returning * into v_alert;
  else
    insert into public.alerts (alert_type, severity, title, message, product_id, warehouse_id, company_id, location_id,
                               qty, ref_type, ref_id, dedupe_key, escalated)
    values (p_type, p_severity, p_title, p_message, p_product, p_warehouse, v_company, p_location,
            p_qty, p_ref_type, p_ref_id, p_dedupe_key, p_escalate)
    returning * into v_alert;
    v_notify := true;
  end if;
  if v_notify then
    for r in select * from private.alert_recipients(p_warehouse, v_company, p_escalate) loop
      select * into v_pref from public.notification_preferences where user_id = r.user_id;
      if v_alert.severity <> 'critical' and coalesce(p_type = any(v_pref.muted_types), false) then
        continue;
      end if;
      insert into public.notifications (user_id, alert_id, title, body, link)
      values (r.user_id, v_alert.id, p_title, p_message, p_link)
      on conflict do nothing;
      if private.setting_bool('alerts.email_enabled', false)
         and coalesce(v_pref.email_enabled, true)
         and (sev_rank ->> v_alert.severity)::int >= (sev_rank ->> coalesce(v_pref.email_min_severity, 'warning'))::int then
        insert into private.email_outbox (to_email, subject, body_text, dedupe_key)
        values (r.email, '[CSWMS ' || upper(v_alert.severity) || '] ' || p_title, p_message,
                v_alert.id::text || ':' || v_alert.occurrences)
        on conflict do nothing;
      end if;
      if private.setting_bool('alerts.whatsapp_enabled', false) then
        select * into v_user from public.app_users where id = r.user_id;
        if v_user.whatsapp_opt_in and v_user.phone is not null
           and (sev_rank ->> v_alert.severity)::int >= (sev_rank ->> coalesce(v_pref.whatsapp_min_severity, 'warning'))::int then
          insert into private.message_outbox (to_phone, title, body, link, dedupe_key)
          values (v_user.phone, p_title, left(p_message, 900), p_link, v_alert.id::text || ':' || v_alert.occurrences)
          on conflict do nothing;
        end if;
      end if;
    end loop;
  end if;
  return v_alert.id;
end $$;

-- -----------------------------------------------------------------------------
-- 5. Training warehouse (practice without touching real stock)
-- -----------------------------------------------------------------------------
alter table public.warehouses add column if not exists is_training boolean not null default false;

create or replace function public.create_training_warehouse(p_branch_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_wh uuid; v_code text; v_n int; v_cat uuid; v_ea uuid; v_box uuid; v_p uuid; i int; v_loc uuid;
  v_items constant jsonb := '[
    ["TRN-TAPE","Training: packaging tape 48mm","EA",120,12],["TRN-GLOVE","Training: work gloves (pair)","EA",60,10],
    ["TRN-BOLT","Training: hex bolt M10 x 50","EA",500,100],["TRN-OIL","Training: hydraulic oil 20L","EA",8,3],
    ["TRN-BOX","Training: shipping box medium","EA",200,50],["TRN-MASK","Training: dust mask FFP2","EA",90,30],
    ["TRN-CABLE","Training: cable ties 300mm (pack)","EA",40,10],["TRN-PAINT","Training: marking paint white","EA",24,6]]';
  it jsonb; v_moves jsonb := '[]'; v_txn public.stock_transactions;
begin
  v_uid := private.require_perm('setup.manage');
  if not exists (select 1 from public.branches where id = p_branch_id and status = 'active') then
    perform private.fail('CS422', 'Choose an active branch');
  end if;
  select count(*) + 1 into v_n from public.warehouses where is_training;
  v_code := 'TRAIN-' || v_n;
  insert into public.warehouses (branch_id, code, name, is_training)
  values (p_branch_id, v_code, 'Training warehouse ' || v_n || ' (practice only)', true) returning id into v_wh;
  for i in 1..6 loop
    insert into public.storage_locations (warehouse_id, kind, code, name, label_code, walk_order)
    values (v_wh, 'bin', 'T-' || lpad(i::text, 2, '0'), 'Training bin ' || i, 'LOC-' || v_code || '-T' || i, i);
  end loop;
  select id into v_cat from public.categories where code = 'CONS';
  select id into v_ea from public.uoms where code = 'EA';
  v_txn := private.new_txn('receipt', 'pending_approval', v_wh, gen_random_uuid(), null, 'Training stock', 'Training warehouse opening stock');
  i := 0;
  for it in select * from jsonb_array_elements(v_items) loop
    i := i + 1;
    select id into v_p from public.products where upper(sku) = it ->> 0;
    if v_p is null then
      insert into public.products (sku, description, category_id, base_uom_id, created_by)
      values (it ->> 0, it ->> 1, v_cat, v_ea, v_uid) returning id into v_p;
      insert into public.barcodes (code, product_id, is_generated, is_primary) values (it ->> 0, v_p, true, true) on conflict do nothing;
    end if;
    insert into public.stock_thresholds (product_id, warehouse_id, min_qty, reorder_qty)
    values (v_p, v_wh, (it ->> 4)::numeric, (it ->> 4)::numeric * 2) on conflict do nothing;
    select id into v_loc from public.storage_locations where warehouse_id = v_wh and code = 'T-' || lpad((((i - 1) % 6) + 1)::text, 2, '0');
    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status, qty_base, entered_qty, entered_uom_id, factor)
    values (v_txn.id, i, v_p, v_loc, private.warehouse_company(v_wh), 'available', (it ->> 3)::numeric, (it ->> 3)::numeric, v_ea, 1);
    v_moves := v_moves || jsonb_build_object('line_no', i, 'product_id', v_p, 'location_id', v_loc, 'owner_company_id', private.warehouse_company(v_wh),
       'status', 'available', 'qty_delta', (it ->> 3)::numeric, 'entered_qty', (it ->> 3)::numeric, 'entered_uom_id', v_ea, 'factor', 1);
  end loop;
  perform private.post_movements(v_txn.id, v_moves, v_uid);
  perform private.log_action('TRAINING_WAREHOUSE', 'warehouses', v_wh::text, jsonb_build_object('code', v_code));
  return jsonb_build_object('ok', true, 'warehouse_id', v_wh, 'code', v_code, 'items', jsonb_array_length(v_items));
end $$;

-- my_context: + training flag per warehouse, language and text size
create or replace function public.my_context() returns jsonb
language plpgsql volatile security definer set search_path = public, private, pg_temp as $$
declare v_u public.app_users;
begin
  select * into v_u from public.app_users where id = auth.uid();
  if not found then return jsonb_build_object('registered', false); end if;
  update public.app_users set last_seen_at = now() where id = v_u.id and (last_seen_at is null or last_seen_at < now() - interval '5 minutes');
  return jsonb_build_object('registered', true, 'active', v_u.is_active,
    'user', jsonb_build_object('id', v_u.id, 'email', v_u.email, 'full_name', v_u.full_name, 'employee_number', v_u.employee_number,
                   'language', v_u.language, 'text_size', v_u.text_size),
    'requires_mfa', private.setting_bool('auth.require_mfa_for_admins', true) and exists (
        select 1 from public.user_role_assignments a join public.roles r on r.id = a.role_id where a.user_id = v_u.id and r.requires_mfa),
    'roles', (select coalesce(jsonb_agg(jsonb_build_object('role', r.code, 'name', r.name, 'scope_type', a.scope_type, 'scope_id', a.scope_id,
                 'scope_label', case a.scope_type when 'group' then 'All companies'
                     when 'company' then (select code || ' — ' || name from public.companies where id = a.scope_id)
                     when 'branch' then (select code || ' — ' || name from public.branches where id = a.scope_id)
                     else (select code || ' — ' || name from public.warehouses where id = a.scope_id) end)), '[]')
              from public.user_role_assignments a join public.roles r on r.id = a.role_id where a.user_id = v_u.id),
    'permissions', (select coalesce(jsonb_agg(distinct p), '[]') from public.user_role_assignments a join public.roles r on r.id = a.role_id,
                    unnest(r.permissions) p where a.user_id = v_u.id),
    'group_permissions', (select coalesce(jsonb_agg(distinct p), '[]') from public.user_role_assignments a join public.roles r on r.id = a.role_id,
                    unnest(r.permissions) p where a.user_id = v_u.id and a.scope_type = 'group'),
    'warehouses', (select coalesce(jsonb_agg(jsonb_build_object('id', t.warehouse_id, 'code', t.warehouse_code, 'name', t.warehouse_name,
                      'branch_code', t.branch_code, 'is_training', w.is_training, 'company_code', t.company_code, 'company_id', t.company_id,
                      'perms', (select jsonb_agg(distinct p) from public.user_role_assignments a join public.roles r on r.id = a.role_id,
                                unnest(r.permissions) p
                                where a.user_id = v_u.id and (a.scope_type = 'group' or (a.scope_type = 'company' and a.scope_id = t.company_id)
                                      or (a.scope_type = 'branch' and a.scope_id = t.branch_id) or (a.scope_type = 'warehouse' and a.scope_id = t.warehouse_id))))
                      order by t.warehouse_code), '[]')
                   from private.warehouse_tree t join public.warehouses w on w.id = t.warehouse_id and w.status = 'active'
                   where exists (select 1 from public.user_role_assignments a where a.user_id = v_u.id
                                 and (a.scope_type = 'group' or (a.scope_type = 'company' and a.scope_id = t.company_id)
                                      or (a.scope_type = 'branch' and a.scope_id = t.branch_id) or (a.scope_type = 'warehouse' and a.scope_id = t.warehouse_id)))),
    'unread_notifications', (select count(*) from public.notifications where user_id = v_u.id and read_at is null),
    'settings', (select jsonb_object_agg(key, value) from public.app_settings where category in ('business','controls','stocktake','transfers')));
end $$;

-- -----------------------------------------------------------------------------
-- 6. Accounting journal (Xero / Sage import), values at weighted-average cost
-- -----------------------------------------------------------------------------
create or replace function public.accounting_journal(p_from date, p_to date, p_company uuid)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_whs uuid[];
  a_inv text := private.setting_text('accounting.inventory_account', '630');
  a_rec text := private.setting_text('accounting.receipts_account', '800');
  a_con text := private.setting_text('accounting.consumption_account', '310');
  a_adj text := private.setting_text('accounting.adjustment_account', '315');
  a_opn text := private.setting_text('accounting.opening_account', '960');
  a_ic  text := private.setting_text('accounting.intercompany_account', '815');
begin
  if not private.has_perm('cost.view') then perform private.fail('CS401', 'The accounting journal needs permission to view prices (cost.view)'); end if;
  if p_company is null then perform private.fail('CS422', 'Choose the company — each company has its own books'); end if;
  if p_from is null or p_to is null or p_to < p_from then perform private.fail('CS422', 'Choose a valid date range'); end if;
  v_whs := private.my_warehouses('reports.view');
  if cardinality(v_whs) = 0 then perform private.fail('CS401', 'You do not have permission to run reports'); end if;
  return query
  with c as (select * from private.an_unit_costs(((p_to + 1)::timestamp at time zone 'Africa/Johannesburg'))),
  m as (
    select (l.posted_at at time zone 'Africa/Johannesburg')::date as d,
           case when l.txn_type = 'receipt' then 'receipts'
                when l.txn_type = 'opening' then 'opening'
                when l.txn_type in ('withdrawal','return') then 'consumption'
                when l.txn_type in ('transfer_dispatch','transfer_receipt','move') then 'intercompany'
                else 'adjustments' end as grp,
           l.qty_delta * coalesce(c.unit_cost, 0) as v
      from public.stock_ledger l left join c on c.product_id = l.product_id
     where l.owner_company_id = p_company and l.warehouse_id = any(v_whs)
       and l.posted_at >= (p_from::timestamp at time zone 'Africa/Johannesburg')
       and l.posted_at <  ((p_to + 1)::timestamp at time zone 'Africa/Johannesburg')),
  g as (select d, grp, round(sum(v), 2) as v from m group by 1, 2 having round(sum(v), 2) <> 0),
  lines as (
    select d, grp, v, a_inv as account, case when v > 0 then v else 0 end as debit, case when v < 0 then -v else 0 end as credit, 1 as ord from g
    union all
    select d, grp, v, case grp when 'receipts' then a_rec when 'opening' then a_opn when 'consumption' then a_con
                               when 'intercompany' then a_ic else a_adj end,
           case when v < 0 then -v else 0 end, case when v > 0 then v else 0 end, 2 from g)
  select jsonb_build_object('date', d, 'reference', 'CSWMS-' || (select code from public.companies where id = p_company) || '-' || to_char(d, 'YYYYMMDD'),
           'group', grp,
           'description', case grp when 'receipts' then 'Stock received' when 'opening' then 'Opening stock balances'
                                   when 'consumption' then 'Stock issued (net of returns)' when 'intercompany' then 'Stock moved between companies'
                                   else 'Stock adjustments, stocktake variances and write-offs' end || ' ' || to_char(d, 'DD/MM/YYYY'),
           'account', account, 'debit', debit, 'credit', credit, 'amount', debit - credit,
           'tax_rate', private.setting_text('accounting.tax_rate', 'No VAT'))
    from lines order by d, grp, ord;
end $$;

-- -----------------------------------------------------------------------------
-- 7. Weekly management summary (Monday after 07:00, by e-mail)
-- -----------------------------------------------------------------------------
create or replace function private.ops_weekly_summary() returns jsonb
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_local timestamp := now() at time zone 'Africa/Johannesburg';
  v_week text := to_char(v_local, 'IYYY-"W"IW');
  v_from timestamptz; v_to timestamptz; u record; v_whs uuid[]; v_body text; v_sent int := 0; v_cost boolean;
  v_rcv int; v_wd int; v_val numeric; v_low int; v_out int; v_risk int; v_appr int; v_jobs text; v_int text; v_tools int;
begin
  if not private.setting_bool('reports.weekly_summary', true) or not private.setting_bool('alerts.email_enabled', false) then
    return jsonb_build_object('skipped', 'off');
  end if;
  if extract(isodow from v_local) <> 1 or v_local::time < time '07:00' then return jsonb_build_object('skipped', 'not Monday morning'); end if;
  v_to := date_trunc('week', v_local)::timestamp at time zone 'Africa/Johannesburg';
  v_from := v_to - interval '7 days';
  select coalesce(result, status) into v_int from integrity.runs where status = 'completed' order by started_at desc limit 1;
  for u in select distinct au.id, au.email, au.full_name from public.app_users au
             join public.user_role_assignments a on a.user_id = au.id join public.roles r on r.id = a.role_id
            where au.is_active and 'reports.view' = any(r.permissions) and 'alerts.receive' = any(r.permissions) loop
    if exists (select 1 from private.email_outbox where dedupe_key = 'weekly:' || v_week and to_email = u.email) then continue; end if;
    v_whs := private.user_warehouses(u.id, 'reports.view');
    if cardinality(v_whs) = 0 then continue; end if;
    v_cost := exists (select 1 from public.user_role_assignments a join public.roles r on r.id = a.role_id
                      where a.user_id = u.id and 'cost.view' = any(r.permissions));
    select count(*) filter (where txn_type = 'receipt'), count(*) filter (where txn_type = 'withdrawal') into v_rcv, v_wd
      from public.stock_transactions where status = 'posted' and warehouse_id = any(v_whs) and posted_at >= v_from and posted_at < v_to;
    select -sum(l.qty_delta * c.unit_cost) into v_val from public.stock_ledger l
      join private.an_unit_costs(v_to) c on c.product_id = l.product_id
     where l.txn_type in ('withdrawal','return') and l.status <> 'in_transit' and l.warehouse_id = any(v_whs) and l.posted_at >= v_from and l.posted_at < v_to;
    select count(*) filter (where alert_type = 'low_stock'), count(*) filter (where alert_type = 'out_of_stock'),
           count(*) filter (where alert_type = 'stockout_risk')
      into v_low, v_out, v_risk from public.alerts where status <> 'resolved' and warehouse_id = any(v_whs);
    select count(*) into v_appr from public.approval_requests where status = 'pending' and (warehouse_id = any(v_whs) or warehouse_id is null);
    select count(*) into v_tools from public.assets where status = 'checked_out' and due_back_at < now() and warehouse_id = any(v_whs);
    select string_agg(format('  %s. %s — %s issue lines', rn, ref, n), E'\n') into v_jobs from (
      select row_number() over (order by count(*) desc) as rn, upper(btrim(t.reference)) as ref, count(*) as n
        from public.stock_transactions t where t.txn_type = 'withdrawal' and t.status = 'posted' and t.reference is not null
         and t.warehouse_id = any(v_whs) and t.posted_at >= v_from and t.posted_at < v_to
       group by 2 order by 3 desc limit 5) j;
    v_body := format(E'Good morning %s,\n\nCSWMS summary for the week %s to %s (%s warehouse(s)):\n\n'
      || E'Activity\n  Receipts: %s\n  Withdrawals: %s\n%s\n'
      || E'Needs attention\n  Low stock: %s · Out of stock: %s · Likely to run out: %s\n  Approvals waiting: %s · Tools overdue: %s\n  Latest integrity check: %s\n\n'
      || E'Top jobs / clients\n%s\n\nOpen CSWMS for details: Analytics and Low Stock & Alerts.\n(You receive this because your role can run reports. Switch it off under Low Stock & Alerts → Notification settings → e-mail.)',
      split_part(u.full_name, ' ', 1), to_char(v_from at time zone 'Africa/Johannesburg', 'DD/MM/YYYY'),
      to_char((v_to - interval '1 second') at time zone 'Africa/Johannesburg', 'DD/MM/YYYY'), cardinality(v_whs),
      v_rcv, v_wd, case when v_cost then '  Consumption value: R ' || to_char(coalesce(v_val, 0), 'FM999G999G990D00') else '' end,
      v_low, v_out, v_risk, v_appr, v_tools, coalesce(upper(v_int), 'none yet'), coalesce(v_jobs, '  (none)'));
    insert into private.email_outbox (to_email, subject, body_text, dedupe_key)
    values (u.email, '[CSWMS] Weekly summary ' || v_week, v_body, 'weekly:' || v_week) on conflict do nothing;
    v_sent := v_sent + 1;
  end loop;
  return jsonb_build_object('queued', v_sent, 'week', v_week);
end $$;

-- -----------------------------------------------------------------------------
-- 8. Scheduler: integrity check + housekeeping + prediction + cycle counts + weekly summary
-- -----------------------------------------------------------------------------
create or replace function integrity.dispatch()
returns jsonb language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare
  v_local timestamp := now() at time zone 'Africa/Johannesburg';
  v_sched time := private.setting_text('integrity.daily_run_time', '02:00')::time;
  v_attempts int; v_res jsonb := '{}'; v_done boolean; v_ops jsonb; v_pred jsonb; v_cyc jsonb; v_week jsonb;
begin
  select count(*), bool_or(status = 'completed') into v_attempts, v_done
  from integrity.runs where business_date = v_local::date and trigger in ('scheduled','retry');
  if v_local::time >= v_sched and not coalesce(v_done, false)
     and v_attempts < private.setting_num('integrity.max_attempts_per_day', 3) then
    v_res := integrity.run_check(case when v_attempts = 0 then 'scheduled' else 'retry' end, null);
    if v_attempts = 0 then
      perform private.stocktake_reminders();
    end if;
  end if;
  begin
    v_ops := private.ops_housekeeping();
  exception when others then
    v_ops := jsonb_build_object('error', sqlerrm);
    insert into public.system_events (source, event, ok, detail) values ('scheduler', 'ops_housekeeping', false, v_ops);
  end;
  begin
    v_pred := private.ops_predictive(false);
  exception when others then
    v_pred := jsonb_build_object('error', sqlerrm);
    insert into public.system_events (source, event, ok, detail) values ('scheduler', 'ops_predictive', false, v_pred);
    update private.analytics_runs set error = sqlerrm where run_date = v_local::date;
  end;
  begin
    v_cyc := private.ops_cycle_counts();
  exception when others then
    v_cyc := jsonb_build_object('error', sqlerrm);
    insert into public.system_events (source, event, ok, detail) values ('scheduler', 'ops_cycle_counts', false, v_cyc);
  end;
  begin
    v_week := private.ops_weekly_summary();
  exception when others then
    v_week := jsonb_build_object('error', sqlerrm);
    insert into public.system_events (source, event, ok, detail) values ('scheduler', 'ops_weekly_summary', false, v_week);
  end;
  return jsonb_build_object('check', v_res, 'watchdog', integrity.watchdog(), 'operations', v_ops, 'prediction', v_pred,
                            'cycle_counts', v_cyc, 'weekly_summary', v_week);
end $$;

-- private evidence bucket (only the app server, with the secret key, reads and writes it)
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') and to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('evidence', 'evidence', false, 8388608, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do nothing;
  end if;
end $$;


-- ===== 20261031009000_phase4_security_lockdown.sql =====
-- =============================================================================
-- CSWMS Phase 4 — Migration 9000: privilege lockdown re-applied over the floor-experience functions (keep LAST).
-- Phase 4 adds: public.attachments (no direct client access; RPCs check warehouse scope),
-- private.message_outbox (WhatsApp queue, server-only; claimed by /api/cron with the secret key).
-- =============================================================================
revoke all on private.analytics_runs from public, anon, authenticated;
revoke all on private.message_outbox from public, anon, authenticated;
revoke all on public.attachments from anon, authenticated;   -- read through list_attachments / attachment_path only

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


commit;
