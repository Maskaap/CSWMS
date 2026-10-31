-- =============================================================================
-- CSWMS Phase 5 — Inter-company trading: orders and (tax) invoices for stock
-- that moves from one company to another.
--
--   Order    ICO-…  the buying company asks the selling company for stock
--                   (or is created automatically when an inter-company transfer
--                   is dispatched without an order)
--   Transfer TRF-…  the existing transfer moves the stock; ownership changes on receipt
--   Invoice  ICI-…  issued automatically for what was received (good + damaged in
--                   transit); shortages that are written off are not invoiced
--   Credit   ICC-…  full or partial credit note against an invoice
--
-- Prices: the order's agreed unit price; otherwise weighted-average cost plus the
-- inter-company mark-up (setting). VAT at intercompany.vat_rate when the seller
-- has a VAT number. Issued invoices and credit notes can never be changed or
-- deleted; only their payment status is recorded.
-- =============================================================================

-- ---------------------------------------------------------------- settings, permissions, company details
insert into public.app_settings (key, value, category, description) values
  ('intercompany.markup_pct',      '0',     'intercompany', 'Mark-up on weighted-average cost for inter-company prices when the order has no agreed price (%)'),
  ('intercompany.vat_rate',        '15',    'intercompany', 'VAT rate (%) on inter-company invoices of companies that have a VAT number'),
  ('intercompany.payment_days',    '30',    'intercompany', 'Inter-company invoices are due this many days after the invoice date'),
  ('accounting.ic_sales_account',  '"205"', 'accounting',   'Income account for inter-company sales (seller)'),
  ('accounting.ic_purchases_account','"310"','accounting',  'Account for inter-company purchases (buyer)'),
  ('accounting.vat_sales_type',    '"Standard Rate Sales"',     'accounting', 'Tax type on inter-company sales invoices (Xero/Sage)'),
  ('accounting.vat_purchases_type','"Standard Rate Purchases"', 'accounting', 'Tax type on inter-company purchase invoices / bills (Xero/Sage)')
on conflict (key) do nothing;

insert into public.permissions (code, description) values
  ('intercompany.order',   'Order stock from another company (buying side)'),
  ('intercompany.approve', 'Approve or reject orders from other companies and agree prices (selling side)'),
  ('invoice.view',         'View inter-company invoices and credit notes'),
  ('invoice.manage',       'Record payments and issue credit notes for inter-company invoices')
on conflict (code) do nothing;

update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['intercompany.order','intercompany.approve','invoice.view','invoice.manage']) p)
 where code in ('SUPER_ADMIN', 'COMPANY_MANAGER');
update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['intercompany.approve','invoice.view','invoice.manage']) p)
 where code = 'HEAD_OFFICE';
update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['intercompany.order','intercompany.approve','invoice.view']) p)
 where code = 'BRANCH_MANAGER';
update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['intercompany.order']) p)
 where code = 'WAREHOUSE_SUPERVISOR';
update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['invoice.view']) p)
 where code = 'AUDITOR';

alter table public.companies add column if not exists address text;
alter table public.companies add column if not exists email text;
alter table public.companies add column if not exists phone text;

-- companies a user acts for with a permission (company/group scope, or through any warehouse of the company)
create or replace function private.my_companies(p_perm text) returns uuid[]
language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce(array_agg(distinct x), '{}') from (
    select unnest(private.my_owner_companies(p_perm)) as x
    union select t.company_id from private.warehouse_tree t where t.warehouse_id = any(private.my_warehouses(p_perm))) s
$$;

-- tell everyone holding a permission for a warehouse
create or replace function private.notify_perm(p_perm text, p_warehouse uuid, p_title text, p_body text, p_link text)
returns int language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_n int;
begin
  insert into public.notifications (user_id, title, body, link)
  select distinct u.id, p_title, p_body, p_link
    from public.app_users u where u.is_active and p_warehouse = any(private.user_warehouses(u.id, p_perm))
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------- orders
create table public.ic_orders (
  id                 uuid primary key default gen_random_uuid(),
  order_no           text not null unique,
  origin             text not null default 'order' check (origin in ('order','transfer')),
  buyer_company_id   uuid not null references public.companies(id),
  seller_company_id  uuid not null references public.companies(id),
  from_warehouse_id  uuid not null references public.warehouses(id),
  to_warehouse_id    uuid not null references public.warehouses(id),
  status             text not null default 'submitted'
                     check (status in ('submitted','approved','rejected','in_transit','completed','cancelled')),
  needed_by          date,
  reference          text,
  notes              text,
  transfer_id        uuid references public.transfers(id),
  client_request_id  uuid unique,
  requested_by       uuid not null,
  requested_at       timestamptz not null default now(),
  decided_by         uuid,
  decided_at         timestamptz,
  decision_note      text,
  closed_at          timestamptz,
  check (buyer_company_id <> seller_company_id),
  check (from_warehouse_id <> to_warehouse_id),
  check (decided_by is null or decided_by <> requested_by or origin = 'transfer')
);
create index on public.ic_orders (status);
create index on public.ic_orders (transfer_id);
create index on public.ic_orders (buyer_company_id);
create index on public.ic_orders (seller_company_id);

create table public.ic_order_lines (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.ic_orders(id),
  line_no       int not null,
  product_id    uuid not null references public.products(id),
  entered_qty   numeric(18,4) not null check (entered_qty > 0),
  entered_uom_id uuid not null references public.uoms(id),
  factor        numeric(18,6) not null,
  qty_base      numeric(18,4) not null check (qty_base > 0),
  unit_price    numeric(14,4) not null default 0 check (unit_price >= 0),   -- per base unit, excl. VAT
  unique (order_id, line_no)
);

-- ---------------------------------------------------------------- invoices / credit notes
create table public.ic_invoices (
  id                 uuid primary key default gen_random_uuid(),
  invoice_no         text not null unique,
  kind               text not null check (kind in ('invoice','credit_note')),
  seller_company_id  uuid not null references public.companies(id),
  buyer_company_id   uuid not null references public.companies(id),
  transfer_id        uuid references public.transfers(id),
  receipt_txn_id     uuid references public.stock_transactions(id),
  order_id           uuid references public.ic_orders(id),
  original_invoice_id uuid references public.ic_invoices(id),
  issue_date         date not null,
  due_date           date not null,
  seller_snapshot    jsonb not null,        -- name, legal name, address, VAT and registration numbers at issue
  buyer_snapshot     jsonb not null,
  vat_rate           numeric(5,2) not null,
  subtotal           numeric(14,2) not null,
  vat_amount         numeric(14,2) not null,
  total              numeric(14,2) not null,
  reason             text,
  status             text not null default 'issued' check (status in ('issued','paid','credited','partly_credited')),
  paid_on            date,
  paid_reference     text,
  paid_recorded_by   uuid,
  issued_by          uuid,
  created_at         timestamptz not null default now(),
  check (seller_company_id <> buyer_company_id),
  check (kind = 'invoice' or original_invoice_id is not null)
);
create unique index ic_invoices_one_per_receipt on public.ic_invoices (receipt_txn_id, seller_company_id, buyer_company_id) where kind = 'invoice';
create index on public.ic_invoices (transfer_id);
create index on public.ic_invoices (seller_company_id, issue_date);
create index on public.ic_invoices (buyer_company_id, issue_date);

create table public.ic_invoice_lines (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references public.ic_invoices(id),
  line_no      int not null,
  product_id   uuid not null references public.products(id),
  description  text not null,
  qty          numeric(18,4) not null check (qty > 0),
  uom_code     text not null,
  unit_price   numeric(14,4) not null,
  line_total   numeric(14,2) not null,
  source_line_id uuid,                      -- credit note: the invoice line credited
  unique (invoice_id, line_no)
);

create trigger ic_invoice_lines_immutable before update or delete on public.ic_invoice_lines
  for each row execute function private.block_modification();

-- ---------------------------------------------------------------- pricing helpers
create or replace function private.ic_company_snapshot(p_company uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('code', code, 'name', name, 'legal_name', coalesce(legal_name, name), 'address', address,
           'vat_number', vat_number, 'registration_number', registration_number, 'email', email, 'phone', phone)
    from public.companies where id = p_company
$$;

-- default inter-company price per base unit: weighted-average cost + mark-up, else purchase price
create or replace function private.ic_default_prices(p_products uuid[])
returns table (product_id uuid, unit_price numeric)
language sql stable security definer set search_path = public, private, pg_temp as $$
  select p.id, round(coalesce(c.unit_cost, pc.purchase_price, 0) * (1 + private.setting_num('intercompany.markup_pct', 0) / 100), 4)
    from unnest(p_products) as p(id)
    left join private.an_unit_costs(now()) c on c.product_id = p.id
    left join public.product_costs pc on pc.product_id = p.id
$$;

-- ---------------------------------------------------------------- order API
-- p_lines: [{product_id, qty, uom_id?}]
create or replace function public.create_ic_order(p_request_id uuid, p_from_warehouse_id uuid, p_to_warehouse_id uuid, p_lines jsonb,
  p_needed_by date default null, p_reference text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_payload jsonb; v_buyer uuid; v_seller uuid; v_o public.ic_orders; l jsonb; i int := 0; c record;
        v_product uuid; v_ids uuid[];
begin
  v_payload := jsonb_build_object('from', p_from_warehouse_id, 'to', p_to_warehouse_id, 'lines', p_lines, 'needed', p_needed_by,
                                  'ref', p_reference, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'create_ic_order', v_payload);
  if v_prev is not null then return v_prev; end if;
  v_uid := private.require_perm('intercompany.order', p_to_warehouse_id);
  perform private.require_lines(p_lines);
  if not exists (select 1 from public.warehouses where id = p_from_warehouse_id and status = 'active') then
    perform private.fail('CS422', 'Choose the warehouse that supplies the stock');
  end if;
  v_buyer := private.warehouse_company(p_to_warehouse_id);
  v_seller := private.warehouse_company(p_from_warehouse_id);
  if v_buyer = v_seller then
    perform private.fail('CS422', 'Both warehouses belong to the same company — use a normal transfer, no order or invoice is needed');
  end if;
  if p_needed_by is not null and p_needed_by < (now() at time zone 'Africa/Johannesburg')::date then
    perform private.fail('CS422', 'The needed-by date is in the past');
  end if;
  insert into public.ic_orders (order_no, buyer_company_id, seller_company_id, from_warehouse_id, to_warehouse_id, needed_by,
                                reference, notes, client_request_id, requested_by)
  values (private.next_doc_no('ICO'), v_buyer, v_seller, p_from_warehouse_id, p_to_warehouse_id, p_needed_by,
          nullif(trim(p_reference), ''), nullif(trim(p_notes), ''), p_request_id, v_uid)
  returning * into v_o;
  select array_agg((x ->> 'product_id')::uuid) into v_ids from jsonb_array_elements(p_lines) x;
  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_product := (l ->> 'product_id')::uuid;
    if not exists (select 1 from public.products where id = v_product and status = 'active') then
      perform private.fail('CS422', format('Line %s: unknown or inactive product', i));
    end if;
    select * into c from private.to_base(v_product, nullif(l ->> 'uom_id', '')::uuid, (l ->> 'qty')::numeric);
    insert into public.ic_order_lines (order_id, line_no, product_id, entered_qty, entered_uom_id, factor, qty_base, unit_price)
    values (v_o.id, i, v_product, (l ->> 'qty')::numeric, c.uom_id, c.factor, c.qty_base,
            coalesce((select unit_price from private.ic_default_prices(array[v_product])), 0));
  end loop;
  perform private.log_action('IC_ORDER_CREATED', 'ic_orders', v_o.id::text, jsonb_build_object('order_no', v_o.order_no));
  perform private.notify_perm('intercompany.approve', p_from_warehouse_id, 'Order from ' || (select code from public.companies where id = v_buyer) || ': ' || v_o.order_no,
    format('%s lines requested for %s. Approve or reject it.', i, (select code from public.warehouses where id = p_to_warehouse_id)),
    '/intercompany/orders/' || v_o.id);
  return private.idem_finish(p_request_id, 'create_ic_order', v_payload,
    jsonb_build_object('ok', true, 'order_id', v_o.id, 'order_no', v_o.order_no, 'status', v_o.status));
end $$;

-- seller approves (optionally agreeing prices per base unit: [{line_id, unit_price}]) or rejects
create or replace function public.decide_ic_order(p_order_id uuid, p_approve boolean, p_note text default null, p_prices jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_o public.ic_orders; v_uid uuid; x jsonb;
begin
  select * into v_o from public.ic_orders where id = p_order_id for update;
  if not found then perform private.fail('CS422', 'Order not found'); end if;
  v_uid := private.require_perm('intercompany.approve', v_o.from_warehouse_id);
  if v_o.status <> 'submitted' then perform private.fail('CS423', 'This order is already ' || v_o.status); end if;
  if v_o.requested_by = v_uid then perform private.fail('CS401', 'You cannot approve your own order'); end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then perform private.fail('CS422', 'Say why the order is rejected'); end if;
  if p_approve and p_prices is not null and jsonb_array_length(p_prices) > 0 then
    if not private.has_perm('cost.view') then perform private.fail('CS401', 'Changing prices needs permission to view prices (cost.view)'); end if;
    for x in select * from jsonb_array_elements(p_prices) loop
      if (x ->> 'unit_price')::numeric < 0 then perform private.fail('CS422', 'Prices cannot be negative'); end if;
      update public.ic_order_lines set unit_price = (x ->> 'unit_price')::numeric
       where id = (x ->> 'line_id')::uuid and order_id = p_order_id;
    end loop;
  end if;
  update public.ic_orders set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = v_uid, decided_at = now(), decision_note = nullif(trim(p_note), ''),
         closed_at = case when p_approve then null else now() end
   where id = p_order_id;
  perform private.log_action(case when p_approve then 'IC_ORDER_APPROVED' else 'IC_ORDER_REJECTED' end, 'ic_orders', p_order_id::text,
    jsonb_build_object('note', p_note));
  insert into public.notifications (user_id, title, body, link)
  values (v_o.requested_by, v_o.order_no || case when p_approve then ' approved' else ' rejected' end,
          coalesce(nullif(trim(p_note), ''), case when p_approve then 'The supplying company will dispatch the stock.' else '' end),
          '/intercompany/orders/' || v_o.id)
  on conflict do nothing;
  return jsonb_build_object('ok', true, 'status', case when p_approve then 'approved' else 'rejected' end);
end $$;

create or replace function public.cancel_ic_order(p_order_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_o public.ic_orders; v_uid uuid := auth.uid();
begin
  select * into v_o from public.ic_orders where id = p_order_id for update;
  if not found then perform private.fail('CS422', 'Order not found'); end if;
  if not (private.has_wh_perm('intercompany.order', v_o.to_warehouse_id) or private.has_wh_perm('intercompany.approve', v_o.from_warehouse_id)) then
    perform private.fail('CS401', 'You may not cancel this order');
  end if;
  if v_o.status not in ('submitted','approved') or v_o.transfer_id is not null then
    perform private.fail('CS423', 'Only orders that have not been dispatched can be cancelled');
  end if;
  if coalesce(trim(p_reason), '') = '' then perform private.fail('CS422', 'Give a reason'); end if;
  update public.ic_orders set status = 'cancelled', closed_at = now(),
         notes = concat_ws(E'\n', notes, 'Cancelled: ' || trim(p_reason)) where id = p_order_id;
  perform private.log_action('IC_ORDER_CANCELLED', 'ic_orders', p_order_id::text, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

-- seller dispatches an approved order: the stock is picked from the seller's own stock at the
-- supplying warehouse (largest bins first, split over bins when needed) into a transfer to the buyer
create or replace function public.create_transfer_from_ic_order(p_request_id uuid, p_order_id uuid, p_dispatch_now boolean default true,
  p_expected_arrival_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_o public.ic_orders; v_uid uuid; v_prev jsonb; v_payload jsonb; ol record; b record; v_need numeric; v_take numeric;
        v_lines jsonb := '[]'; v_res jsonb; v_short text := '';
begin
  v_payload := jsonb_build_object('order', p_order_id, 'now', p_dispatch_now, 'eta', p_expected_arrival_at);
  v_prev := private.idem_begin(p_request_id, 'create_transfer_from_ic_order', v_payload);
  if v_prev is not null then return v_prev; end if;
  select * into v_o from public.ic_orders where id = p_order_id for update;
  if not found then perform private.fail('CS422', 'Order not found'); end if;
  v_uid := private.require_perm('stock.transfer.dispatch', v_o.from_warehouse_id);
  if v_o.status <> 'approved' or v_o.transfer_id is not null then
    perform private.fail('CS423', 'Only approved orders that have not been dispatched can be turned into a transfer');
  end if;
  for ol in select l.*, p.sku from public.ic_order_lines l join public.products p on p.id = l.product_id where l.order_id = p_order_id order by l.line_no loop
    v_need := ol.qty_base;
    for b in select bl.location_id, sum(bl.qty) as qty from public.stock_balances bl
              where bl.product_id = ol.product_id and bl.warehouse_id = v_o.from_warehouse_id and bl.status = 'available'
                and bl.owner_company_id = v_o.seller_company_id and bl.qty > 0
              group by bl.location_id order by sum(bl.qty) desc, bl.location_id loop
      exit when v_need <= 0;
      v_take := least(v_need, b.qty);
      v_lines := v_lines || jsonb_build_object('product_id', ol.product_id, 'from_location_id', b.location_id,
                   'owner_company_id', v_o.seller_company_id, 'qty', v_take);
      v_need := v_need - v_take;
    end loop;
    if v_need > 0 then v_short := v_short || format('%s short by %s; ', ol.sku, trim(to_char(v_need, 'FM999999990.####'))); end if;
  end loop;
  if v_short <> '' then
    perform private.fail('CS409', 'Not enough stock of the selling company at the supplying warehouse: ' || v_short);
  end if;
  v_res := public.create_transfer(gen_random_uuid(), v_o.from_warehouse_id, v_o.to_warehouse_id, v_lines, v_o.buyer_company_id,
             p_expected_arrival_at, v_o.order_no, 'Inter-company order ' || v_o.order_no, false);
  update public.ic_orders set transfer_id = (v_res ->> 'transfer_id')::uuid where id = p_order_id;
  if p_dispatch_now then
    v_res := v_res || jsonb_build_object('dispatch', private.dispatch_transfer_internal((v_res ->> 'transfer_id')::uuid, v_uid, gen_random_uuid()),
                                         'status', 'dispatched');
  end if;
  return private.idem_finish(p_request_id, 'create_transfer_from_ic_order', v_payload,
    jsonb_build_object('ok', true, 'order_no', v_o.order_no) || v_res);
end $$;

-- ---------------------------------------------------------------- automatic documents from transfers
-- 1. dispatch: every inter-company transfer has an order (one per selling company)
-- 2. receipt: an invoice per selling company for what arrived (good + damaged)
-- 3. completion: the order is completed
create or replace function private.ic_on_transfer_status() returns trigger
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare s record; v_id uuid; i int;
begin
  if new.to_owner_company_id is null then return new; end if;
  if new.status = 'dispatched' and old.status = 'draft' then
    update public.ic_orders set status = 'in_transit' where transfer_id = new.id and status = 'approved';
    for s in select distinct owner_company_id as seller from public.transfer_lines
              where transfer_id = new.id and owner_company_id <> new.to_owner_company_id loop
      if exists (select 1 from public.ic_orders where transfer_id = new.id and seller_company_id = s.seller) then continue; end if;
      insert into public.ic_orders (order_no, origin, buyer_company_id, seller_company_id, from_warehouse_id, to_warehouse_id, status,
                                    reference, notes, transfer_id, requested_by, requested_at, decided_by, decided_at, decision_note)
      values (private.next_doc_no('ICO'), 'transfer', new.to_owner_company_id, s.seller, new.from_warehouse_id, new.to_warehouse_id, 'in_transit',
              new.transfer_no, 'Created automatically for inter-company transfer ' || new.transfer_no, new.id,
              new.created_by, new.created_at, new.dispatched_by, now(), 'Recorded at dispatch of ' || new.transfer_no)
      returning id into v_id;
      i := 0;
      insert into public.ic_order_lines (order_id, line_no, product_id, entered_qty, entered_uom_id, factor, qty_base, unit_price)
      select v_id, row_number() over (order by g.first_line), g.product_id, g.qty, p.base_uom_id, 1, g.qty, coalesce(dp.unit_price, 0)
        from (select product_id, sum(qty_dispatched) as qty, min(line_no) as first_line from public.transfer_lines
               where transfer_id = new.id and owner_company_id = s.seller group by product_id) g
        join public.products p on p.id = g.product_id
        left join private.ic_default_prices(array(select product_id from public.transfer_lines where transfer_id = new.id)) dp on dp.product_id = g.product_id;
    end loop;
  elsif new.status in ('received','closed_with_discrepancy') and old.status <> new.status then
    update public.ic_orders set status = 'completed', closed_at = now() where transfer_id = new.id and status = 'in_transit';
  end if;
  return new;
end $$;
create trigger transfers_intercompany after update of status on public.transfers
  for each row execute function private.ic_on_transfer_status();

create or replace function private.ic_issue_invoices_for_receipt(p_txn_id uuid) returns int
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare t public.stock_transactions; tr public.transfers; g record; v_inv uuid; v_rate numeric; v_sub numeric; v_vat numeric; v_n int := 0;
        v_day date := (now() at time zone 'Africa/Johannesburg')::date; v_order uuid;
begin
  select * into t from public.stock_transactions where id = p_txn_id;
  select * into tr from public.transfers where id = t.transfer_id;
  for g in select l.owner_company_id as seller, (l.extra ->> 'new_owner')::uuid as buyer
             from public.stock_transaction_lines l
            where l.txn_id = p_txn_id and (l.extra ->> 'new_owner') is not null and (l.extra ->> 'new_owner')::uuid <> l.owner_company_id
            group by 1, 2 loop
    if exists (select 1 from public.ic_invoices where receipt_txn_id = p_txn_id and seller_company_id = g.seller
                and buyer_company_id = g.buyer and kind = 'invoice') then continue; end if;
    select id into v_order from public.ic_orders where transfer_id = tr.id and seller_company_id = g.seller order by requested_at limit 1;
    v_rate := case when (select nullif(trim(vat_number), '') from public.companies where id = g.seller) is not null
                   then private.setting_num('intercompany.vat_rate', 15) else 0 end;
    insert into public.ic_invoices (invoice_no, kind, seller_company_id, buyer_company_id, transfer_id, receipt_txn_id, order_id,
           issue_date, due_date, seller_snapshot, buyer_snapshot, vat_rate, subtotal, vat_amount, total, issued_by)
    values (private.next_doc_no('ICI'), 'invoice', g.seller, g.buyer, tr.id, p_txn_id, v_order, v_day,
            v_day + private.setting_num('intercompany.payment_days', 30)::int,
            private.ic_company_snapshot(g.seller), private.ic_company_snapshot(g.buyer), v_rate, 0, 0, 0, t.posted_by)
    returning id into v_inv;
    -- (totals are written once, below, in the same statement that would otherwise be refused as a change)
    insert into public.ic_invoice_lines (invoice_id, line_no, product_id, description, qty, uom_code, unit_price, line_total)
    select v_inv, row_number() over (order by x.first_line), x.product_id, p.sku || ' — ' || p.description, x.qty, u.code, x.price, round(x.qty * x.price, 2)
      from (select l.product_id, sum(l.qty_base) as qty, min(l.line_no) as first_line,
                   coalesce((select ol.unit_price from public.ic_order_lines ol where ol.order_id = v_order and ol.product_id = l.product_id
                             order by ol.line_no limit 1),
                            (select dp.unit_price from private.ic_default_prices(array[l.product_id]) dp), 0) as price
              from public.stock_transaction_lines l
             where l.txn_id = p_txn_id and l.owner_company_id = g.seller and (l.extra ->> 'new_owner')::uuid = g.buyer
             group by l.product_id) x
      join public.products p on p.id = x.product_id join public.uoms u on u.id = p.base_uom_id;
    select coalesce(sum(line_total), 0) into v_sub from public.ic_invoice_lines where invoice_id = v_inv;
    v_vat := round(v_sub * v_rate / 100, 2);
    perform set_config('cswms.ic_totals', v_inv::text, true);
    update public.ic_invoices set subtotal = v_sub, vat_amount = v_vat, total = v_sub + v_vat where id = v_inv;
    perform set_config('cswms.ic_totals', '', true);
    perform private.log_action('IC_INVOICE_ISSUED', 'ic_invoices', v_inv::text, jsonb_build_object('transfer', tr.transfer_no, 'total', v_sub + v_vat));
    perform private.notify_perm('invoice.view', tr.to_warehouse_id, 'Inter-company invoice ' || (select invoice_no from public.ic_invoices where id = v_inv),
      format('For transfer %s, total R %s.', tr.transfer_no, to_char(v_sub + v_vat, 'FM999G999G990D00')), '/intercompany/invoices/' || v_inv);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- the totals of a brand-new invoice are filled in once, inside the issuing function only
create or replace function private.ic_invoice_protect() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then perform private.fail('CS423', 'Invoices and credit notes cannot be deleted — issue a credit note'); end if;
  if current_setting('cswms.ic_totals', true) = old.id::text and old.subtotal = 0 and old.total = 0
     and (to_jsonb(new) - array['subtotal','vat_amount','total']) = (to_jsonb(old) - array['subtotal','vat_amount','total']) then
    return new;
  end if;
  if (to_jsonb(new) - array['status','paid_on','paid_reference','paid_recorded_by'])
     is distinct from (to_jsonb(old) - array['status','paid_on','paid_reference','paid_recorded_by']) then
    perform private.fail('CS423', 'An issued invoice cannot be changed — issue a credit note');
  end if;
  return new;
end $$;

create trigger ic_invoices_protect before update or delete on public.ic_invoices
  for each row execute function private.ic_invoice_protect();

create or replace function private.ic_on_receipt_posted() returns trigger
language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if new.txn_type = 'transfer_receipt' and new.status = 'posted' and old.status is distinct from 'posted' then
    perform private.ic_issue_invoices_for_receipt(new.id);
  end if;
  return new;
end $$;
create trigger stock_transactions_ic_invoice after update of status on public.stock_transactions
  for each row execute function private.ic_on_receipt_posted();

-- ---------------------------------------------------------------- payments and credit notes
create or replace function public.record_ic_payment(p_invoice_id uuid, p_paid_on date, p_reference text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_i public.ic_invoices; v_uid uuid := auth.uid();
begin
  select * into v_i from public.ic_invoices where id = p_invoice_id for update;
  if not found then perform private.fail('CS422', 'Invoice not found'); end if;
  if v_uid is null or not (v_i.seller_company_id = any(private.my_companies('invoice.manage'))) then
    perform private.fail('CS401', 'Only the selling company records payment (invoice.manage)');
  end if;
  if v_i.kind <> 'invoice' or v_i.status <> 'issued' then perform private.fail('CS423', 'Only unpaid invoices can be marked as paid'); end if;
  if p_paid_on is null or p_paid_on > (now() at time zone 'Africa/Johannesburg')::date or p_paid_on < v_i.issue_date then
    perform private.fail('CS422', 'Enter the payment date (not before the invoice date, not in the future)');
  end if;
  if coalesce(trim(p_reference), '') = '' then perform private.fail('CS422', 'Enter the payment reference'); end if;
  update public.ic_invoices set status = 'paid', paid_on = p_paid_on, paid_reference = trim(p_reference), paid_recorded_by = v_uid
   where id = p_invoice_id;
  perform private.log_action('IC_INVOICE_PAID', 'ic_invoices', p_invoice_id::text, jsonb_build_object('paid_on', p_paid_on, 'reference', p_reference));
  return jsonb_build_object('ok', true, 'status', 'paid');
end $$;

-- p_lines null = credit everything still open; else [{invoice_line_id, qty}]
create or replace function public.credit_ic_invoice(p_request_id uuid, p_invoice_id uuid, p_reason text, p_lines jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid := auth.uid(); v_prev jsonb; v_payload jsonb; v_i public.ic_invoices; v_cn uuid; il record; v_q numeric; v_open numeric;
        n int := 0; v_sub numeric; v_vat numeric; v_left numeric; v_day date := (now() at time zone 'Africa/Johannesburg')::date;
begin
  v_payload := jsonb_build_object('invoice', p_invoice_id, 'reason', p_reason, 'lines', p_lines);
  v_prev := private.idem_begin(p_request_id, 'credit_ic_invoice', v_payload);
  if v_prev is not null then return v_prev; end if;
  select * into v_i from public.ic_invoices where id = p_invoice_id for update;
  if not found then perform private.fail('CS422', 'Invoice not found'); end if;
  if v_uid is null or not (v_i.seller_company_id = any(private.my_companies('invoice.manage'))) then
    perform private.fail('CS401', 'Only the selling company issues credit notes (invoice.manage)');
  end if;
  if v_i.kind <> 'invoice' or v_i.status not in ('issued','partly_credited','paid') then
    perform private.fail('CS423', 'This invoice is already fully credited');
  end if;
  if coalesce(trim(p_reason), '') = '' then perform private.fail('CS422', 'Give the reason for the credit (e.g. damaged in transit)'); end if;
  insert into public.ic_invoices (invoice_no, kind, seller_company_id, buyer_company_id, transfer_id, order_id, original_invoice_id,
         issue_date, due_date, seller_snapshot, buyer_snapshot, vat_rate, subtotal, vat_amount, total, reason, issued_by)
  values (private.next_doc_no('ICC'), 'credit_note', v_i.seller_company_id, v_i.buyer_company_id, v_i.transfer_id, v_i.order_id, v_i.id,
          v_day, v_day, private.ic_company_snapshot(v_i.seller_company_id), private.ic_company_snapshot(v_i.buyer_company_id),
          v_i.vat_rate, 0, 0, 0, trim(p_reason), v_uid)
  returning id into v_cn;
  for il in select * from public.ic_invoice_lines where invoice_id = p_invoice_id order by line_no loop
    v_open := il.qty - coalesce((select sum(c.qty) from public.ic_invoice_lines c join public.ic_invoices ci on ci.id = c.invoice_id
                                  where ci.original_invoice_id = p_invoice_id and c.source_line_id = il.id), 0);
    if p_lines is null then v_q := v_open;
    else
      select (x ->> 'qty')::numeric into v_q from jsonb_array_elements(p_lines) x where (x ->> 'invoice_line_id')::uuid = il.id;
      v_q := coalesce(v_q, 0);
    end if;
    if v_q < 0 or v_q > v_open then
      perform private.fail('CS422', format('Line %s: you can credit at most %s', il.line_no, trim(to_char(v_open, 'FM999999990.####'))));
    end if;
    if v_q = 0 then continue; end if;
    n := n + 1;
    insert into public.ic_invoice_lines (invoice_id, line_no, product_id, description, qty, uom_code, unit_price, line_total, source_line_id)
    values (v_cn, n, il.product_id, il.description, v_q, il.uom_code, il.unit_price, round(v_q * il.unit_price, 2), il.id);
  end loop;
  if n = 0 then perform private.fail('CS422', 'Nothing to credit — enter a quantity on at least one line'); end if;
  select sum(line_total) into v_sub from public.ic_invoice_lines where invoice_id = v_cn;
  v_vat := round(v_sub * v_i.vat_rate / 100, 2);
  perform set_config('cswms.ic_totals', v_cn::text, true);
  update public.ic_invoices set subtotal = v_sub, vat_amount = v_vat, total = v_sub + v_vat where id = v_cn;
  perform set_config('cswms.ic_totals', '', true);
  select sum(l.qty) - coalesce((select sum(c.qty) from public.ic_invoice_lines c join public.ic_invoices ci on ci.id = c.invoice_id
                                 where ci.original_invoice_id = p_invoice_id), 0)
    into v_left from public.ic_invoice_lines l where l.invoice_id = p_invoice_id;
  update public.ic_invoices set status = case when v_left <= 0 then 'credited'
                                              when status = 'paid' then 'paid' else 'partly_credited' end
   where id = p_invoice_id;
  perform private.log_action('IC_CREDIT_NOTE', 'ic_invoices', v_cn::text, jsonb_build_object('invoice', v_i.invoice_no, 'reason', p_reason));
  return private.idem_finish(p_request_id, 'credit_ic_invoice', v_payload,
    jsonb_build_object('ok', true, 'credit_note_id', v_cn, 'credit_note_no', (select invoice_no from public.ic_invoices where id = v_cn),
                       'total', v_sub + v_vat));
end $$;

-- ---------------------------------------------------------------- reading
create or replace function private.ic_order_visible(o public.ic_orders) returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select o.buyer_company_id = any(private.my_companies('intercompany.order') || private.my_companies('invoice.view'))
      or o.seller_company_id = any(private.my_companies('intercompany.approve') || private.my_companies('invoice.view'))
      or o.from_warehouse_id = any(private.my_warehouses('stock.transfer.dispatch'))
      or o.to_warehouse_id = any(private.my_warehouses('stock.transfer.receive'))
      or o.requested_by = auth.uid()
$$;

create or replace function public.ic_orders_list(p_status text default null, p_limit int default 300)
returns setof jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('id', o.id, 'order_no', o.order_no, 'origin', o.origin, 'status', o.status,
           'buyer', b.code, 'seller', s.code, 'from_warehouse', fw.code, 'to_warehouse', tw.code, 'needed_by', o.needed_by,
           'reference', o.reference, 'requested_at', o.requested_at, 'requested_by_name', u.full_name,
           'transfer_id', o.transfer_id, 'transfer_no', t.transfer_no,
           'lines', (select count(*) from public.ic_order_lines where order_id = o.id),
           'value', case when private.has_perm('cost.view') or private.has_perm('invoice.view')
                         then (select round(sum(qty_base * unit_price), 2) from public.ic_order_lines where order_id = o.id) end,
           'can_approve', o.status = 'submitted' and private.has_wh_perm('intercompany.approve', o.from_warehouse_id) and o.requested_by <> auth.uid(),
           'can_dispatch', o.status = 'approved' and o.transfer_id is null and private.has_wh_perm('stock.transfer.dispatch', o.from_warehouse_id))
    from public.ic_orders o join public.companies b on b.id = o.buyer_company_id join public.companies s on s.id = o.seller_company_id
    join public.warehouses fw on fw.id = o.from_warehouse_id join public.warehouses tw on tw.id = o.to_warehouse_id
    left join public.app_users u on u.id = o.requested_by left join public.transfers t on t.id = o.transfer_id
   where private.ic_order_visible(o) and (p_status is null or o.status = p_status)
   order by o.requested_at desc limit least(coalesce(p_limit, 300), 1000)
$$;

create or replace function public.ic_order_detail(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare o public.ic_orders; v_price boolean := private.has_perm('cost.view') or private.has_perm('invoice.view');
begin
  select * into o from public.ic_orders where id = p_order_id;
  if not found or not private.ic_order_visible(o) then perform private.fail('CS422', 'Order not found'); end if;
  return (select jsonb_build_object('id', o.id, 'order_no', o.order_no, 'origin', o.origin, 'status', o.status,
      'buyer', private.ic_company_snapshot(o.buyer_company_id), 'seller', private.ic_company_snapshot(o.seller_company_id),
      'from_warehouse', (select jsonb_build_object('id', id, 'code', code, 'name', name) from public.warehouses where id = o.from_warehouse_id),
      'to_warehouse', (select jsonb_build_object('id', id, 'code', code, 'name', name) from public.warehouses where id = o.to_warehouse_id),
      'needed_by', o.needed_by, 'reference', o.reference, 'notes', o.notes,
      'requested_at', o.requested_at, 'requested_by_name', (select full_name from public.app_users where id = o.requested_by),
      'decided_at', o.decided_at, 'decided_by_name', (select full_name from public.app_users where id = o.decided_by), 'decision_note', o.decision_note,
      'transfer', (select jsonb_build_object('id', id, 'transfer_no', transfer_no, 'status', status) from public.transfers where id = o.transfer_id),
      'show_prices', v_price,
      'can_approve', o.status = 'submitted' and private.has_wh_perm('intercompany.approve', o.from_warehouse_id) and o.requested_by <> auth.uid(),
      'can_set_prices', o.status = 'submitted' and private.has_wh_perm('intercompany.approve', o.from_warehouse_id) and private.has_perm('cost.view'),
      'can_dispatch', o.status = 'approved' and o.transfer_id is null and private.has_wh_perm('stock.transfer.dispatch', o.from_warehouse_id),
      'can_cancel', o.status in ('submitted','approved') and o.transfer_id is null
                    and (private.has_wh_perm('intercompany.order', o.to_warehouse_id) or private.has_wh_perm('intercompany.approve', o.from_warehouse_id)),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'line_no', l.line_no, 'product_id', l.product_id, 'sku', p.sku,
                   'description', p.description, 'entered_qty', l.entered_qty, 'entered_uom', eu.code, 'qty_base', l.qty_base, 'base_uom', bu.code,
                   'unit_price', case when v_price then l.unit_price end, 'line_value', case when v_price then round(l.qty_base * l.unit_price, 2) end,
                   'qty_received', (select coalesce(sum(tl.qty_received + tl.qty_damaged), 0) from public.transfer_lines tl
                                     where tl.transfer_id = o.transfer_id and tl.product_id = l.product_id and tl.owner_company_id = o.seller_company_id),
                   'available_at_seller', (select coalesce(sum(b.qty), 0) from public.stock_balances b where b.product_id = l.product_id
                                            and b.warehouse_id = o.from_warehouse_id and b.status = 'available' and b.owner_company_id = o.seller_company_id))
                   order by l.line_no), '[]')
                from public.ic_order_lines l join public.products p on p.id = l.product_id
                join public.uoms eu on eu.id = l.entered_uom_id join public.uoms bu on bu.id = p.base_uom_id where l.order_id = o.id),
      'value', case when v_price then (select round(sum(qty_base * unit_price), 2) from public.ic_order_lines where order_id = o.id) end,
      'invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'invoice_no', i.invoice_no, 'kind', i.kind, 'status', i.status,
                     'total', i.total, 'issue_date', i.issue_date) order by i.created_at), '[]')
                   from public.ic_invoices i where (i.order_id = o.id or (o.transfer_id is not null and i.transfer_id = o.transfer_id
                         and i.seller_company_id = o.seller_company_id))
                     and (i.seller_company_id = any(private.my_companies('invoice.view')) or i.buyer_company_id = any(private.my_companies('invoice.view'))))));
end $$;

create or replace function private.ic_invoice_visible(i public.ic_invoices) returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select i.seller_company_id = any(private.my_companies('invoice.view')) or i.buyer_company_id = any(private.my_companies('invoice.view'))
$$;

create or replace function public.ic_invoices_list(p_status text default null, p_company uuid default null, p_from date default null, p_to date default null)
returns setof jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('id', i.id, 'invoice_no', i.invoice_no, 'kind', i.kind, 'status', i.status,
           'seller', s.code, 'buyer', b.code, 'issue_date', i.issue_date, 'due_date', i.due_date,
           'is_overdue', i.kind = 'invoice' and i.status in ('issued','partly_credited') and i.due_date < (now() at time zone 'Africa/Johannesburg')::date,
           'subtotal', i.subtotal, 'vat_amount', i.vat_amount, 'total', i.total, 'transfer_no', t.transfer_no, 'transfer_id', i.transfer_id,
           'original_invoice_no', oi.invoice_no, 'paid_on', i.paid_on,
           'side', case when i.seller_company_id = any(private.my_companies('invoice.view')) then 'sales' else 'purchases' end)
    from public.ic_invoices i join public.companies s on s.id = i.seller_company_id join public.companies b on b.id = i.buyer_company_id
    left join public.transfers t on t.id = i.transfer_id left join public.ic_invoices oi on oi.id = i.original_invoice_id
   where private.ic_invoice_visible(i)
     and (p_status is null or i.status = p_status or (p_status = 'overdue' and i.kind = 'invoice' and i.status in ('issued','partly_credited')
                                                      and i.due_date < (now() at time zone 'Africa/Johannesburg')::date))
     and (p_company is null or p_company in (i.seller_company_id, i.buyer_company_id))
     and (p_from is null or i.issue_date >= p_from) and (p_to is null or i.issue_date <= p_to)
   order by i.issue_date desc, i.invoice_no desc limit 1000
$$;

create or replace function public.ic_invoice_detail(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare i public.ic_invoices;
begin
  select * into i from public.ic_invoices where id = p_invoice_id;
  if not found or not private.ic_invoice_visible(i) then perform private.fail('CS422', 'Invoice not found'); end if;
  return to_jsonb(i) - array['issued_by','paid_recorded_by'] || jsonb_build_object(
    'title', case when i.kind = 'credit_note' then case when i.vat_rate > 0 then 'TAX CREDIT NOTE' else 'CREDIT NOTE' end
                  else case when i.vat_rate > 0 then 'TAX INVOICE' else 'INVOICE' end end,
    'transfer', (select jsonb_build_object('id', t.id, 'transfer_no', t.transfer_no, 'from', fw.code || ' — ' || fw.name, 'to', tw.code || ' — ' || tw.name,
                   'dispatched_at', t.dispatched_at) from public.transfers t join public.warehouses fw on fw.id = t.from_warehouse_id
                   join public.warehouses tw on tw.id = t.to_warehouse_id where t.id = i.transfer_id),
    'receipt_txn_no', (select txn_no from public.stock_transactions where id = i.receipt_txn_id),
    'order_no', (select order_no from public.ic_orders where id = i.order_id),
    'original_invoice_no', (select invoice_no from public.ic_invoices where id = i.original_invoice_id),
    'issued_by_name', (select full_name from public.app_users where id = i.issued_by),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'line_no', l.line_no, 'description', l.description, 'qty', l.qty,
                 'uom', l.uom_code, 'unit_price', l.unit_price, 'line_total', l.line_total,
                 'credited', (select coalesce(sum(c.qty), 0) from public.ic_invoice_lines c where c.source_line_id = l.id)) order by l.line_no), '[]')
              from public.ic_invoice_lines l where l.invoice_id = i.id),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'invoice_no', c.invoice_no, 'total', c.total, 'issue_date', c.issue_date)
                       order by c.created_at), '[]') from public.ic_invoices c where c.original_invoice_id = i.id),
    'can_manage', i.seller_company_id = any(private.my_companies('invoice.manage')));
end $$;

create or replace function public.ic_documents_for_transfer(p_transfer_id uuid)
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object(
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'order_no', o.order_no, 'status', o.status, 'origin', o.origin)
                 order by o.requested_at), '[]') from public.ic_orders o where o.transfer_id = p_transfer_id and private.ic_order_visible(o)),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'invoice_no', i.invoice_no, 'kind', i.kind, 'status', i.status,
                   'total', i.total, 'issue_date', i.issue_date) order by i.created_at), '[]')
                 from public.ic_invoices i where i.transfer_id = p_transfer_id and private.ic_invoice_visible(i)))
$$;

-- accounting export of inter-company invoices for one company: its sales (as seller) and purchases (as buyer)
create or replace function public.ic_invoice_export(p_company uuid, p_from date, p_to date)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
begin
  if p_company is null or not (p_company = any(private.my_companies('invoice.view'))) then
    perform private.fail('CS401', 'You may not view the invoices of this company (invoice.view)');
  end if;
  if p_from is null or p_to is null or p_to < p_from then perform private.fail('CS422', 'Choose a valid date range'); end if;
  return query
  select jsonb_build_object('side', case when i.seller_company_id = p_company then 'sales' else 'purchases' end,
           'contact', case when i.seller_company_id = p_company then i.buyer_snapshot ->> 'legal_name' else i.seller_snapshot ->> 'legal_name' end,
           'invoice_no', i.invoice_no, 'kind', i.kind, 'reference', coalesce((select transfer_no from public.transfers where id = i.transfer_id), ''),
           'issue_date', i.issue_date, 'due_date', i.due_date, 'description', l.description,
           'qty', case when i.kind = 'credit_note' then -l.qty else l.qty end, 'unit_price', l.unit_price,
           'line_total', case when i.kind = 'credit_note' then -l.line_total else l.line_total end,
           'vat_rate', i.vat_rate,
           'account', case when i.seller_company_id = p_company then private.setting_text('accounting.ic_sales_account', '205')
                           else private.setting_text('accounting.ic_purchases_account', '310') end,
           'tax_type', case when i.vat_rate = 0 then 'No VAT'
                            when i.seller_company_id = p_company then private.setting_text('accounting.vat_sales_type', 'Standard Rate Sales')
                            else private.setting_text('accounting.vat_purchases_type', 'Standard Rate Purchases') end)
    from public.ic_invoices i join public.ic_invoice_lines l on l.invoice_id = i.id
   where p_company in (i.seller_company_id, i.buyer_company_id) and i.issue_date between p_from and p_to
   order by i.issue_date, i.invoice_no, l.line_no;
end $$;

-- ---------------------------------------------------------------- protection & access
alter table public.ic_orders enable row level security;
alter table public.ic_order_lines enable row level security;
alter table public.ic_invoices enable row level security;
alter table public.ic_invoice_lines enable row level security;
revoke all on public.ic_orders, public.ic_order_lines, public.ic_invoices, public.ic_invoice_lines from anon, authenticated;
create trigger ic_orders_no_delete before delete on public.ic_orders for each row execute function private.block_modification();
create trigger ic_order_lines_no_delete before delete on public.ic_order_lines for each row execute function private.block_modification();
