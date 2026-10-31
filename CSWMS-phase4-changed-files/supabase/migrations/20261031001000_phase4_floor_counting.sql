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
