-- =============================================================================
-- CSWMS Migration 0200: Inventory core
--   Transaction headers & lines, the immutable movement LEDGER (authoritative),
--   reconciled stored BALANCES, balance change log, approvals, alerts,
--   notifications and the atomic / idempotent posting engine.
--
--   Golden rules implemented here:
--   * Balances are NEVER edited directly. Only private.post_movements() changes
--     them, and it always writes the matching ledger rows in the same database
--     transaction.
--   * Ledger rows are append-only and carry a SHA-256 content hash.
--   * Every mutating API call is idempotent (client request id) and atomic.
--   * Balance rows are locked in a deterministic order -> no overdraw under
--     concurrency, no deadlocks between postings.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Idempotency registry
-- -----------------------------------------------------------------------------
create table private.idempotency_keys (
  request_id   uuid primary key,
  user_id      uuid,
  operation    text not null,
  request_hash text not null,
  response     jsonb not null,
  created_at   timestamptz not null default now()
);

-- Serialises concurrent calls carrying the same request id and returns the stored
-- response for a retry. A different payload with a reused id is rejected.
create or replace function private.idem_begin(p_request_id uuid, p_operation text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = private, public, pg_temp as $$
declare v_row private.idempotency_keys; v_hash text := md5(coalesce(p_payload::text, ''));
begin
  if p_request_id is null then
    perform private.fail('CS422', 'A request id is required (protects against duplicate submissions)');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 42));
  select * into v_row from private.idempotency_keys where request_id = p_request_id;
  if found then
    if v_row.operation <> p_operation or v_row.request_hash <> v_hash then
      perform private.fail('CS410', 'This request id was already used for a different request');
    end if;
    return v_row.response || jsonb_build_object('duplicate', true);
  end if;
  return null;
end $$;

create or replace function private.idem_finish(p_request_id uuid, p_operation text, p_payload jsonb, p_response jsonb)
returns jsonb language plpgsql security definer set search_path = private, public, pg_temp as $$
begin
  insert into private.idempotency_keys (request_id, user_id, operation, request_hash, response)
  values (p_request_id, auth.uid(), p_operation, md5(coalesce(p_payload::text, '')), p_response);
  return p_response || jsonb_build_object('duplicate', false);
end $$;

-- -----------------------------------------------------------------------------
-- Transaction headers and requested lines
-- -----------------------------------------------------------------------------
create table public.stock_transactions (
  id                  uuid primary key default gen_random_uuid(),
  txn_no              text not null unique,
  txn_type            public.txn_type not null,
  status              public.txn_status not null,
  warehouse_id        uuid references public.warehouses(id),
  reason_code_id      uuid references public.reason_codes(id),
  reference           text,                 -- client / job / department / delivery note
  supplier_id         uuid references public.suppliers(id),
  notes               text,
  related_txn_id      uuid references public.stock_transactions(id),   -- original withdrawal (returns) / reversed txn
  transfer_id         uuid,
  stocktake_id        uuid,
  import_batch_id     uuid,
  client_request_id   uuid not null unique,
  is_unusual          boolean not null default false,
  unusual_info        jsonb,
  created_by          uuid not null,
  created_at          timestamptz not null default clock_timestamp(),
  posted_by           uuid,                 -- approver (or creator for direct postings)
  posted_at           timestamptz,
  header_hash         text,
  check ((status = 'posted') = (posted_at is not null))
);
create index on public.stock_transactions (warehouse_id, created_at desc);
create index on public.stock_transactions (txn_type, created_at desc);
create index on public.stock_transactions (created_by, created_at desc);
create index on public.stock_transactions (related_txn_id);
create index on public.stock_transactions (transfer_id);
create index on public.stock_transactions (stocktake_id);
create unique index stock_transactions_one_reversal
  on public.stock_transactions (related_txn_id)
  where txn_type = 'reversal' and status in ('pending_approval','posted');

create table public.stock_transaction_lines (
  id                uuid primary key default gen_random_uuid(),
  txn_id            uuid not null references public.stock_transactions(id),
  line_no           int  not null,
  product_id        uuid not null references public.products(id),
  location_id       uuid not null references public.storage_locations(id),
  to_location_id    uuid references public.storage_locations(id),
  owner_company_id  uuid not null references public.companies(id),
  status            public.stock_status not null default 'available',
  to_status         public.stock_status,
  qty_base          numeric(18,4) not null,      -- signed for adjustments, positive otherwise
  entered_qty       numeric(18,4) not null,
  entered_uom_id    uuid not null references public.uoms(id),
  factor            numeric(18,6) not null,
  extra             jsonb,
  unique (txn_id, line_no)
);
create index on public.stock_transaction_lines (product_id);

-- optional receipt / opening unit costs (ZAR per entered unit) — restricted to cost.view
create table public.txn_line_costs (
  txn_id     uuid not null references public.stock_transactions(id),
  line_no    int not null,
  unit_cost  numeric(14,2) not null check (unit_cost >= 0),
  primary key (txn_id, line_no)
);

-- -----------------------------------------------------------------------------
-- LEDGER — the authoritative, append-only record of every stock movement
-- -----------------------------------------------------------------------------
create table public.stock_ledger (
  id                bigint generated always as identity primary key,
  txn_id            uuid not null references public.stock_transactions(id),
  line_no           int not null,
  txn_type          public.txn_type not null,
  product_id        uuid not null references public.products(id),
  warehouse_id      uuid not null references public.warehouses(id),
  location_id       uuid not null references public.storage_locations(id),
  owner_company_id  uuid not null references public.companies(id),
  status            public.stock_status not null,
  qty_delta         numeric(18,4) not null check (qty_delta <> 0),
  entered_qty       numeric(18,4) not null,
  entered_uom_id    uuid not null references public.uoms(id),
  factor            numeric(18,6) not null check (factor > 0),
  balance_after     numeric(18,4) not null,
  posted_by         uuid not null,
  posted_at         timestamptz not null default clock_timestamp(),
  row_hash          text not null
);
create index stock_ledger_key on public.stock_ledger (product_id, location_id, owner_company_id, status);
create index stock_ledger_txn on public.stock_ledger (txn_id);
create index stock_ledger_wh_time on public.stock_ledger (warehouse_id, posted_at desc);
create index stock_ledger_product_time on public.stock_ledger (product_id, posted_at desc);
create index stock_ledger_time on public.stock_ledger (posted_at);

create or replace function private.ledger_row_hash(l public.stock_ledger) returns text
language sql immutable as $$
  select encode(sha256(convert_to(concat_ws('|',
    l.id, l.txn_id, l.line_no, l.txn_type, l.product_id, l.warehouse_id, l.location_id, l.owner_company_id,
    l.status, l.qty_delta::text, l.entered_qty::text, l.entered_uom_id, l.factor::text,
    l.balance_after::text, l.posted_by, to_char(l.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US')), 'UTF8')), 'hex')
$$;

create or replace function private.ledger_before_insert() returns trigger
language plpgsql as $$
begin
  new.row_hash := private.ledger_row_hash(new);
  return new;
end $$;
create trigger stock_ledger_hash before insert on public.stock_ledger
  for each row execute function private.ledger_before_insert();
create trigger stock_ledger_immutable before update or delete on public.stock_ledger
  for each row execute function private.block_modification();
create trigger stock_ledger_no_truncate before truncate on public.stock_ledger
  for each statement execute function private.block_modification();

-- -----------------------------------------------------------------------------
-- Stored balances (fast everyday reads; reconciled daily against the ledger)
-- -----------------------------------------------------------------------------
create table public.stock_balances (
  product_id        uuid not null references public.products(id),
  location_id       uuid not null references public.storage_locations(id),
  owner_company_id  uuid not null references public.companies(id),
  status            public.stock_status not null,
  warehouse_id      uuid not null references public.warehouses(id),
  qty               numeric(18,4) not null default 0,
  last_txn_id       uuid,
  last_ledger_id    bigint,
  version           bigint not null default 0,
  updated_at        timestamptz not null default clock_timestamp(),
  primary key (product_id, location_id, owner_company_id, status),
  constraint stock_balances_no_negative check (qty >= 0)
);
create index stock_balances_wh on public.stock_balances (warehouse_id, product_id);
create index stock_balances_owner on public.stock_balances (owner_company_id);

-- Every change to a balance is logged together with the posting transaction that
-- caused it.  A change without a posting transaction is "unexplained" and is
-- reported by the integrity monitor.
create table private.balance_change_log (
  id                bigint generated always as identity primary key,
  at                timestamptz not null default clock_timestamp(),
  op                text not null,
  product_id        uuid,
  location_id       uuid,
  owner_company_id  uuid,
  status            public.stock_status,
  old_qty           numeric(18,4),
  new_qty           numeric(18,4),
  posting_txn_id    uuid,
  db_user           text not null default current_user,
  app_user          uuid default auth.uid()
);
create index on private.balance_change_log (at);
create trigger balance_change_log_immutable before update or delete on private.balance_change_log
  for each row execute function private.block_modification();

create or replace function private.log_balance_change() returns trigger
language plpgsql security definer set search_path = private, public, pg_temp as $$
declare v_txn uuid := nullif(current_setting('cswms.posting_txn', true), '')::uuid;
begin
  if tg_op = 'UPDATE' and new.qty = old.qty and new.product_id = old.product_id
     and new.location_id = old.location_id and new.owner_company_id = old.owner_company_id
     and new.status = old.status and new.warehouse_id = old.warehouse_id then
    return new;   -- metadata-only touch
  end if;
  insert into private.balance_change_log (op, product_id, location_id, owner_company_id, status, old_qty, new_qty, posting_txn_id)
  values (tg_op,
          coalesce(new.product_id, old.product_id), coalesce(new.location_id, old.location_id),
          coalesce(new.owner_company_id, old.owner_company_id), coalesce(new.status, old.status),
          case when tg_op <> 'INSERT' then old.qty end,
          case when tg_op <> 'DELETE' then new.qty end,
          v_txn);
  return coalesce(new, old);
end $$;
create trigger stock_balances_log after insert or update or delete on public.stock_balances
  for each row execute function private.log_balance_change();

-- Transaction header / line protection: posted / rejected / cancelled records are frozen.
create or replace function private.protect_txn() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    perform private.fail('CS423', 'Stock transactions cannot be deleted; post a reversal or adjustment instead');
  end if;
  if old.status <> 'pending_approval' then
    perform private.fail('CS423', 'Transaction ' || old.txn_no || ' is ' || old.status || ' and can no longer be changed');
  end if;
  if new.id <> old.id or new.txn_no <> old.txn_no or new.txn_type <> old.txn_type
     or new.created_by <> old.created_by or new.created_at <> old.created_at
     or new.client_request_id <> old.client_request_id then
    perform private.fail('CS423', 'Core transaction fields cannot be changed');
  end if;
  if new.status = 'posted' then
    new.header_hash := private.txn_header_hash(new);
  end if;
  return new;
end $$;
create trigger stock_transactions_protect before update or delete on public.stock_transactions
  for each row execute function private.protect_txn();

create or replace function private.protect_txn_lines() returns trigger
language plpgsql as $$
declare v_status public.txn_status;
begin
  select status into v_status from public.stock_transactions where id = coalesce(old.txn_id, new.txn_id);
  if tg_op = 'DELETE' or v_status <> 'pending_approval' then
    perform private.fail('CS423', 'Transaction lines are frozen once a transaction is posted, rejected or cancelled');
  end if;
  return new;
end $$;
create trigger stock_transaction_lines_protect before update or delete on public.stock_transaction_lines
  for each row execute function private.protect_txn_lines();

create or replace function private.txn_header_hash(t public.stock_transactions) returns text
language sql immutable as $$
  select encode(sha256(convert_to(concat_ws('|', t.id, t.txn_no, t.txn_type, t.warehouse_id, t.reason_code_id,
     coalesce(t.reference,''), coalesce(t.related_txn_id::text,''), coalesce(t.transfer_id::text,''),
     coalesce(t.stocktake_id::text,''), t.created_by, t.posted_by,
     to_char(t.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US')), 'UTF8')), 'hex')
$$;

-- The base unit of a product cannot change once any movement exists
create or replace function private.protect_base_uom() returns trigger
language plpgsql as $$
begin
  if new.base_uom_id <> old.base_uom_id and exists (select 1 from public.stock_ledger where product_id = old.id) then
    perform private.fail('CS422', 'The base unit cannot be changed after stock movements exist for this product');
  end if;
  return new;
end $$;
create trigger products_protect_base_uom before update of base_uom_id on public.products
  for each row execute function private.protect_base_uom();

create or replace function private.protect_conversion() returns trigger
language plpgsql as $$
begin
  if (tg_op = 'DELETE' or new.factor_to_base <> old.factor_to_base)
     and exists (select 1 from public.stock_ledger where product_id = old.product_id and entered_uom_id = old.uom_id) then
    perform private.fail('CS422', 'A unit conversion that has been used in transactions cannot be changed or removed. Add a new unit instead.');
  end if;
  return coalesce(new, old);
end $$;
create trigger product_uoms_protect before update or delete on public.product_uoms
  for each row execute function private.protect_conversion();

-- -----------------------------------------------------------------------------
-- Reservations (stock allocated to a job / client, not yet withdrawn)
-- -----------------------------------------------------------------------------
create table public.stock_reservations (
  id                uuid primary key default gen_random_uuid(),
  product_id        uuid not null references public.products(id),
  warehouse_id      uuid not null references public.warehouses(id),
  owner_company_id  uuid not null references public.companies(id),
  qty_reserved      numeric(18,4) not null check (qty_reserved > 0),
  qty_fulfilled     numeric(18,4) not null default 0 check (qty_fulfilled >= 0),
  reference         text not null,
  notes             text,
  status            text not null default 'active' check (status in ('active','fulfilled','released')),
  expires_at        timestamptz,
  created_by        uuid not null,
  created_at        timestamptz not null default now(),
  closed_at         timestamptz,
  check (qty_fulfilled <= qty_reserved)
);
create index on public.stock_reservations (product_id, warehouse_id) where status = 'active';

-- -----------------------------------------------------------------------------
-- Transfers
-- -----------------------------------------------------------------------------
create table public.transfers (
  id                   uuid primary key default gen_random_uuid(),
  transfer_no          text not null unique,
  from_warehouse_id    uuid not null references public.warehouses(id),
  to_warehouse_id      uuid not null references public.warehouses(id),
  to_owner_company_id  uuid references public.companies(id),   -- set when ownership changes (intercompany)
  status               text not null default 'draft'
                       check (status in ('draft','dispatched','partially_received','received','closed_with_discrepancy','cancelled')),
  reference            text,
  notes                text,
  expected_arrival_at  timestamptz,
  client_request_id    uuid not null unique,
  created_by           uuid not null,
  created_at           timestamptz not null default now(),
  dispatched_by        uuid,
  dispatched_at        timestamptz,
  dispatch_txn_id      uuid references public.stock_transactions(id),
  completed_at         timestamptz,
  cancelled_by         uuid,
  cancelled_at         timestamptz
);
create index on public.transfers (status);
create index on public.transfers (from_warehouse_id);
create index on public.transfers (to_warehouse_id);

create table public.transfer_lines (
  id                 uuid primary key default gen_random_uuid(),
  transfer_id        uuid not null references public.transfers(id),
  line_no            int not null,
  product_id         uuid not null references public.products(id),
  from_location_id   uuid not null references public.storage_locations(id),
  to_location_id     uuid not null references public.storage_locations(id),  -- planned destination (in-transit is held here)
  owner_company_id   uuid not null references public.companies(id),          -- owner while in transit
  entered_qty        numeric(18,4) not null check (entered_qty > 0),
  entered_uom_id     uuid not null references public.uoms(id),
  factor             numeric(18,6) not null,
  qty_dispatched     numeric(18,4) not null check (qty_dispatched > 0),       -- base units
  qty_received       numeric(18,4) not null default 0 check (qty_received >= 0),
  qty_damaged        numeric(18,4) not null default 0 check (qty_damaged >= 0),
  qty_written_off    numeric(18,4) not null default 0 check (qty_written_off >= 0),
  unique (transfer_id, line_no),
  check (qty_received + qty_damaged + qty_written_off <= qty_dispatched)
);

alter table public.stock_transactions
  add constraint stock_transactions_transfer_fk foreign key (transfer_id) references public.transfers(id);

-- -----------------------------------------------------------------------------
-- Approvals
-- -----------------------------------------------------------------------------
create table public.approval_requests (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in ('adjustment','reversal','transfer_writeoff','stocktake','opening_balance')),
  status          text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  required_perm   text not null references public.permissions(code),
  warehouse_id    uuid references public.warehouses(id),
  txn_id          uuid references public.stock_transactions(id),
  transfer_id     uuid references public.transfers(id),
  stocktake_id    uuid,
  import_batch_id uuid,
  summary         text not null,
  details         jsonb,
  requested_by    uuid not null,
  requested_at    timestamptz not null default now(),
  decided_by      uuid,
  decided_at      timestamptz,
  decision_note   text,
  check (decided_by is null or decided_by <> requested_by)   -- nobody approves their own request
);
create index on public.approval_requests (status, requested_at desc);
create unique index approval_one_pending_per_txn on public.approval_requests (txn_id) where status = 'pending' and txn_id is not null;
create trigger approval_requests_audit after insert or update on public.approval_requests
  for each row execute function private.audit_row();

-- -----------------------------------------------------------------------------
-- Alerts, notifications, e-mail outbox
-- -----------------------------------------------------------------------------
create table public.alerts (
  id               uuid primary key default gen_random_uuid(),
  alert_type       text not null check (alert_type in (
                     'low_stock','out_of_stock','reorder','transfer_overdue','stocktake_due','stocktake_overdue',
                     'stocktake_discrepancy','unusual_withdrawal','approval_pending','integrity','integrity_monitor','system')),
  severity         text not null check (severity in ('info','warning','critical')),
  title            text not null,
  message          text not null,
  product_id       uuid references public.products(id),
  warehouse_id     uuid references public.warehouses(id),
  company_id       uuid references public.companies(id),
  location_id      uuid references public.storage_locations(id),
  qty              numeric(18,4),
  ref_type         text,
  ref_id           text,
  dedupe_key       text not null,
  status           text not null default 'open' check (status in ('open','acknowledged','resolved')),
  escalated        boolean not null default false,
  occurrences      int not null default 1,
  first_raised_at  timestamptz not null default now(),
  last_raised_at   timestamptz not null default now(),
  acknowledged_by  uuid,
  acknowledged_at  timestamptz,
  resolved_by      uuid,
  resolved_at      timestamptz,
  resolution_note  text
);
create unique index alerts_open_dedupe on public.alerts (dedupe_key) where status <> 'resolved';
create index on public.alerts (status, alert_type);
create index on public.alerts (warehouse_id) where status <> 'resolved';

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.app_users(id) on delete cascade,
  alert_id    uuid references public.alerts(id),
  title       text not null,
  body        text not null,
  link        text,
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index on public.notifications (user_id, created_at desc);
create unique index notifications_once_per_alert on public.notifications (user_id, alert_id) where alert_id is not null and read_at is null;

create table private.email_outbox (
  id           uuid primary key default gen_random_uuid(),
  to_email     text not null,
  subject      text not null,
  body_text    text not null,
  status       text not null default 'pending' check (status in ('pending','sending','sent','failed')),
  attempts     int not null default 0,
  last_error   text,
  created_at   timestamptz not null default now(),
  sent_at      timestamptz,
  dedupe_key   text
);
create unique index email_outbox_dedupe on private.email_outbox (dedupe_key, to_email) where dedupe_key is not null;
create index on private.email_outbox (status, created_at);

-- Recipients: active users holding the permission for the warehouse (or group-level when no warehouse)
create or replace function private.alert_recipients(p_warehouse uuid, p_company uuid, p_escalate boolean)
returns table (user_id uuid, email text)
language sql stable security definer set search_path = public, private, pg_temp as $$
  select distinct u.id, u.email
  from public.app_users u
  join public.user_role_assignments a on a.user_id = u.id
  join public.roles r on r.id = a.role_id
  left join private.warehouse_tree t on t.warehouse_id = p_warehouse
  where u.is_active
    and (
      ( 'alerts.receive' = any(r.permissions) and (
           a.scope_type = 'group'
        or (p_warehouse is not null and (
                (a.scope_type = 'company' and a.scope_id = t.company_id)
             or (a.scope_type = 'branch' and a.scope_id = t.branch_id)
             or (a.scope_type = 'warehouse' and a.scope_id = p_warehouse)))
        or (p_warehouse is null and p_company is not null and a.scope_type = 'company' and a.scope_id = p_company)))
      or (p_escalate and 'alerts.escalation' = any(r.permissions) and a.scope_type = 'group')
    )
$$;

create or replace function private.raise_alert(
  p_type text, p_severity text, p_title text, p_message text, p_dedupe_key text,
  p_product uuid default null, p_warehouse uuid default null, p_company uuid default null,
  p_location uuid default null, p_qty numeric default null, p_ref_type text default null,
  p_ref_id text default null, p_escalate boolean default false, p_link text default null)
returns uuid language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_alert public.alerts;
  v_notify boolean := false;
  v_company uuid := p_company;
  r record;
  sev_rank constant jsonb := '{"info":1,"warning":2,"critical":3}';
begin
  if v_company is null and p_warehouse is not null then
    select company_id into v_company from private.warehouse_tree where warehouse_id = p_warehouse;
  end if;

  select * into v_alert from public.alerts where dedupe_key = p_dedupe_key and status <> 'resolved' for update;
  if found then
    -- same unresolved issue: update, do not spam. Re-notify only if it became more severe or newly escalated.
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
      insert into public.notifications (user_id, alert_id, title, body, link)
      values (r.user_id, v_alert.id, p_title, p_message, p_link)
      on conflict do nothing;
      if private.setting_bool('alerts.email_enabled', false) and p_severity in ('warning','critical') then
        insert into private.email_outbox (to_email, subject, body_text, dedupe_key)
        values (r.email, '[CSWMS ' || upper(p_severity) || '] ' || p_title, p_message,
                v_alert.id::text || ':' || v_alert.occurrences)
        on conflict do nothing;
      end if;
    end loop;
  end if;
  return v_alert.id;
end $$;

create or replace function private.resolve_alert(p_dedupe_key text, p_note text default null)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.alerts set status = 'resolved', resolved_at = now(), resolved_by = auth.uid(),
         resolution_note = coalesce(p_note, resolution_note)
  where dedupe_key = p_dedupe_key and status <> 'resolved'
$$;

-- -----------------------------------------------------------------------------
-- Line resolution & validation helpers
-- -----------------------------------------------------------------------------
create type private.resolved_line as (
  product_id       uuid,
  location_id      uuid,
  warehouse_id     uuid,
  owner_company_id uuid,
  entered_qty      numeric,
  entered_uom_id   uuid,
  factor           numeric,
  qty_base         numeric
);

-- Converts an entered quantity in a unit into base units, validating decimals and conversions.
create or replace function private.to_base(p_product uuid, p_uom uuid, p_qty numeric, p_allow_negative boolean default false)
returns table (uom_id uuid, factor numeric, qty_base numeric)
language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_prod public.products;
  v_uom uuid;
  v_factor numeric;
  v_entered_dec int;
  v_base_dec int;
  v_base numeric;
begin
  select * into v_prod from public.products where id = p_product;
  if not found then perform private.fail('CS422', 'Unknown product'); end if;
  if v_prod.status <> 'active' then
    perform private.fail('CS422', 'Product ' || v_prod.sku || ' is not active');
  end if;
  if p_qty is null or p_qty = 'NaN'::numeric then perform private.fail('CS422', 'Quantity is required'); end if;
  if not p_allow_negative and p_qty <= 0 then
    perform private.fail('CS422', 'Quantity must be greater than zero', jsonb_build_object('sku', v_prod.sku));
  end if;
  if p_allow_negative and p_qty = 0 then perform private.fail('CS422', 'Quantity cannot be zero'); end if;
  if abs(p_qty) > 1000000000 then perform private.fail('CS422', 'Quantity is unrealistically large'); end if;

  v_uom := coalesce(p_uom, v_prod.base_uom_id);
  select pu.factor_to_base into v_factor from public.product_uoms pu where pu.product_id = p_product and pu.uom_id = v_uom;
  if v_factor is null then
    perform private.fail('CS422', 'The selected unit is not set up for product ' || v_prod.sku);
  end if;

  select decimals into v_entered_dec from public.uoms where id = v_uom;
  if scale(p_qty) > v_entered_dec and trunc(p_qty, v_entered_dec) <> p_qty then
    perform private.fail('CS422', format('Unit %s only allows %s decimal place(s)',
      (select code from public.uoms where id = v_uom), v_entered_dec), jsonb_build_object('sku', v_prod.sku));
  end if;

  v_base := round(p_qty * v_factor, 4);
  select decimals into v_base_dec from public.uoms where id = v_prod.base_uom_id;
  if trunc(v_base, v_base_dec) <> v_base then
    perform private.fail('CS422', format('This conversion gives %s base units, but the base unit %s only allows %s decimal place(s)',
      v_base, (select code from public.uoms where id = v_prod.base_uom_id), v_base_dec), jsonb_build_object('sku', v_prod.sku));
  end if;
  return query select v_uom, v_factor, v_base;
end $$;

create or replace function private.location_warehouse(p_location uuid, p_expected_wh uuid default null)
returns uuid language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_loc public.storage_locations; v_wh_status public.record_status;
begin
  select * into v_loc from public.storage_locations where id = p_location;
  if not found then perform private.fail('CS422', 'Unknown storage location'); end if;
  if v_loc.status <> 'active' then perform private.fail('CS422', 'Storage location ' || v_loc.code || ' is not active'); end if;
  select status into v_wh_status from public.warehouses where id = v_loc.warehouse_id;
  if v_wh_status <> 'active' then perform private.fail('CS422', 'The warehouse is not active'); end if;
  if p_expected_wh is not null and v_loc.warehouse_id <> p_expected_wh then
    perform private.fail('CS422', 'Location ' || v_loc.code || ' does not belong to the selected warehouse (wrong-location protection)');
  end if;
  return v_loc.warehouse_id;
end $$;

create or replace function private.warehouse_company(p_warehouse uuid) returns uuid
language sql stable security definer set search_path = public, private, pg_temp as $$
  select company_id from private.warehouse_tree where warehouse_id = p_warehouse
$$;

create or replace function private.default_location(p_warehouse uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from public.storage_locations where warehouse_id = p_warehouse and is_default
$$;

create or replace function private.reason_id(p_kind text, p_code text, p_reference text default null) returns uuid
language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_r public.reason_codes;
begin
  select * into v_r from public.reason_codes where kind = p_kind and code = upper(p_code) and status = 'active';
  if not found then perform private.fail('CS422', 'A valid reason must be selected'); end if;
  if v_r.requires_reference and coalesce(trim(p_reference), '') = '' then
    perform private.fail('CS422', 'The reason "' || v_r.label || '" requires a reference (client, job, department or document number)');
  end if;
  return v_r.id;
end $$;

create or replace function private.require_lines(p_lines jsonb) returns void
language plpgsql immutable as $$
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    perform private.fail('CS422', 'At least one line is required');
  end if;
  if jsonb_array_length(p_lines) > 500 then perform private.fail('CS422', 'A maximum of 500 lines per transaction is allowed'); end if;
end $$;

create or replace function private.new_txn(
  p_type public.txn_type, p_status public.txn_status, p_warehouse uuid, p_request_id uuid,
  p_reason uuid default null, p_reference text default null, p_notes text default null,
  p_supplier uuid default null, p_related uuid default null, p_transfer uuid default null,
  p_stocktake uuid default null, p_import uuid default null)
returns public.stock_transactions language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v public.stock_transactions; v_prefix text;
begin
  v_prefix := case p_type
    when 'opening' then 'OPN' when 'receipt' then 'RCV' when 'withdrawal' then 'WDR' when 'return' then 'RTN'
    when 'move' then 'MOV' when 'transfer_dispatch' then 'TDS' when 'transfer_receipt' then 'TRC'
    when 'transfer_writeoff' then 'TWO' when 'adjustment' then 'ADJ' when 'stocktake_adjustment' then 'STA'
    when 'status_change' then 'STC' when 'reversal' then 'REV' end;
  insert into public.stock_transactions (txn_no, txn_type, status, warehouse_id, reason_code_id, reference, notes,
       supplier_id, related_txn_id, transfer_id, stocktake_id, import_batch_id, client_request_id, created_by)
  values (private.next_doc_no(v_prefix), p_type, p_status, p_warehouse, p_reason, nullif(trim(p_reference), ''),
       nullif(trim(p_notes), ''), p_supplier, p_related, p_transfer, p_stocktake, p_import, p_request_id,
       coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'))
  returning * into v;
  return v;
end $$;

-- -----------------------------------------------------------------------------
-- THE POSTING ENGINE
-- p_moves: [{line_no, product_id, location_id, owner_company_id, status, qty_delta,
--            entered_qty, entered_uom_id, factor, unit_cost}]
-- Locks every affected balance in a deterministic order, verifies that no
-- prohibited negative balance results, updates balances and writes ledger rows.
-- Either everything is applied or nothing (raises).
-- -----------------------------------------------------------------------------
create or replace function private.post_movements(p_txn_id uuid, p_moves jsonb, p_posted_by uuid default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  m record;
  v_bal public.stock_balances;
  v_new numeric;
  v_wh uuid;
  v_txn public.stock_transactions;
  v_by uuid := coalesce(p_posted_by, auth.uid(), '00000000-0000-0000-0000-000000000000');
  v_ledger_id bigint;
  v_result jsonb := '[]'::jsonb;
  v_sku text;
begin
  select * into v_txn from public.stock_transactions where id = p_txn_id for update;
  if v_txn.status <> 'pending_approval' then
    perform private.fail('CS423', 'Transaction ' || v_txn.txn_no || ' has already been ' || v_txn.status);
  end if;

  perform set_config('cswms.posting_txn', p_txn_id::text, true);

  for m in
    select (x ->> 'line_no')::int as line_no,
           (x ->> 'product_id')::uuid as product_id,
           (x ->> 'location_id')::uuid as location_id,
           (x ->> 'owner_company_id')::uuid as owner_company_id,
           (x ->> 'status')::public.stock_status as status,
           (x ->> 'qty_delta')::numeric as qty_delta,
           (x ->> 'entered_qty')::numeric as entered_qty,
           (x ->> 'entered_uom_id')::uuid as entered_uom_id,
           (x ->> 'factor')::numeric as factor,
           ord
    from jsonb_array_elements(p_moves) with ordinality as e(x, ord)
    -- deterministic lock order prevents deadlocks between concurrent postings
    order by (x ->> 'product_id'), (x ->> 'location_id'), (x ->> 'owner_company_id'), (x ->> 'status'), ord
  loop
    if m.qty_delta is null or m.qty_delta = 0 then
      perform private.fail('CS422', 'Internal error: zero movement');
    end if;
    select warehouse_id into v_wh from public.storage_locations where id = m.location_id;
    if v_wh is null then perform private.fail('CS422', 'Unknown location in movement'); end if;

    insert into public.stock_balances (product_id, location_id, owner_company_id, status, warehouse_id, qty)
    values (m.product_id, m.location_id, m.owner_company_id, m.status, v_wh, 0)
    on conflict do nothing;

    select * into v_bal from public.stock_balances
    where product_id = m.product_id and location_id = m.location_id
      and owner_company_id = m.owner_company_id and status = m.status
    for update;

    v_new := v_bal.qty + m.qty_delta;
    if v_new < 0 then
      select sku into v_sku from public.products where id = m.product_id;
      perform private.fail('CS409',
        format('Insufficient stock for %s: %s available at this location, %s requested', v_sku,
               trim(to_char(v_bal.qty, 'FM999999999990.####')), trim(to_char(-m.qty_delta, 'FM999999999990.####'))),
        jsonb_build_object('product_id', m.product_id, 'location_id', m.location_id, 'available', v_bal.qty,
                           'requested', -m.qty_delta, 'status', m.status));
    end if;

    insert into public.stock_ledger (txn_id, line_no, txn_type, product_id, warehouse_id, location_id, owner_company_id,
           status, qty_delta, entered_qty, entered_uom_id, factor, balance_after, posted_by)
    values (p_txn_id, m.line_no, v_txn.txn_type, m.product_id, v_wh, m.location_id, m.owner_company_id,
           m.status, m.qty_delta, m.entered_qty, m.entered_uom_id, m.factor, v_new, v_by)
    returning id into v_ledger_id;

    update public.stock_balances
       set qty = v_new, last_txn_id = p_txn_id, last_ledger_id = v_ledger_id,
           version = version + 1, updated_at = clock_timestamp()
     where product_id = m.product_id and location_id = m.location_id
       and owner_company_id = m.owner_company_id and status = m.status;

    v_result := v_result || jsonb_build_object('product_id', m.product_id, 'location_id', m.location_id,
                  'owner_company_id', m.owner_company_id, 'status', m.status, 'qty_delta', m.qty_delta,
                  'balance_after', v_new);
  end loop;

  -- the header hash is computed by the protect trigger at the moment of posting
  update public.stock_transactions
     set status = 'posted', posted_at = clock_timestamp(), posted_by = v_by
   where id = p_txn_id;

  perform set_config('cswms.posting_txn', '', true);

  -- low stock evaluation for every affected product / warehouse
  perform private.evaluate_low_stock(x.product_id, x.warehouse_id)
  from (select distinct (e ->> 'product_id')::uuid as product_id, sl.warehouse_id
        from jsonb_array_elements(p_moves) e
        join public.storage_locations sl on sl.id = (e ->> 'location_id')::uuid) x;

  return v_result;
end $$;

-- -----------------------------------------------------------------------------
-- Low-stock evaluation
-- -----------------------------------------------------------------------------
create or replace function private.threshold_for(p_product uuid, p_warehouse uuid)
returns table (min_qty numeric, reorder_qty numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select min_qty, reorder_qty from public.stock_thresholds
  where product_id = p_product and (warehouse_id = p_warehouse or warehouse_id is null)
  order by warehouse_id nulls last limit 1
$$;

create or replace function private.evaluate_low_stock(p_product uuid, p_warehouse uuid)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_qty numeric; v_min numeric; v_reorder numeric; v_sku text; v_desc text; v_uom text; v_wh text; v_key text;
begin
  select t.min_qty, t.reorder_qty into v_min, v_reorder from private.threshold_for(p_product, p_warehouse) t;
  v_key := 'stock:' || p_product || ':' || p_warehouse;
  if v_min is null or v_min <= 0 then
    perform private.resolve_alert('low:' || v_key, 'Threshold removed');
    perform private.resolve_alert('out:' || v_key, 'Threshold removed');
    return;
  end if;

  select coalesce(sum(qty), 0) into v_qty from public.stock_balances
  where product_id = p_product and warehouse_id = p_warehouse and status = 'available';

  select p.sku, p.description, u.code into v_sku, v_desc, v_uom
  from public.products p join public.uoms u on u.id = p.base_uom_id where p.id = p_product;
  select w.code || ' — ' || w.name into v_wh from public.warehouses w where w.id = p_warehouse;

  if v_qty <= 0 then
    perform private.resolve_alert('low:' || v_key, 'Now out of stock');
    perform private.raise_alert('out_of_stock', 'critical',
      'Out of stock: ' || v_sku,
      format('%s (%s) is out of stock at %s. Minimum %s %s. Suggested reorder: %s %s.', v_desc, v_sku, v_wh,
             trim(to_char(v_min,'FM999999990.####')), v_uom, trim(to_char(greatest(v_reorder, v_min),'FM999999990.####')), v_uom),
      'out:' || v_key, p_product, p_warehouse, null, null, 0, 'product', p_product::text, false,
      '/stock/' || p_product);
  elsif v_qty <= v_min then
    perform private.resolve_alert('out:' || v_key, 'Stock replenished');
    perform private.raise_alert('low_stock', 'warning',
      'Low stock: ' || v_sku,
      format('%s (%s) at %s: %s %s available, minimum %s %s. Suggested reorder: %s %s.', v_desc, v_sku, v_wh,
             trim(to_char(v_qty,'FM999999990.####')), v_uom, trim(to_char(v_min,'FM999999990.####')), v_uom,
             trim(to_char(greatest(v_reorder, v_min - v_qty),'FM999999990.####')), v_uom),
      'low:' || v_key, p_product, p_warehouse, null, null, v_qty, 'product', p_product::text, false,
      '/stock/' || p_product);
  else
    perform private.resolve_alert('low:' || v_key, 'Stock above minimum');
    perform private.resolve_alert('out:' || v_key, 'Stock above minimum');
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Owner resolution: explicit owner, or the only owner holding stock at the location,
-- or (for incoming stock) the company operating the warehouse.
-- -----------------------------------------------------------------------------
create or replace function private.resolve_owner(p_line jsonb, p_product uuid, p_location uuid, p_status public.stock_status, p_incoming boolean)
returns uuid language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_owner uuid; v_count int;
begin
  v_owner := nullif(p_line ->> 'owner_company_id', '')::uuid;
  if v_owner is not null then
    if not exists (select 1 from public.companies where id = v_owner and status = 'active') then
      perform private.fail('CS422', 'Unknown or inactive owner company');
    end if;
    return v_owner;
  end if;
  if p_incoming then
    return private.warehouse_company((select warehouse_id from public.storage_locations where id = p_location));
  end if;
  select count(*), min(owner_company_id::text)::uuid into v_count, v_owner
  from public.stock_balances where product_id = p_product and location_id = p_location and status = p_status and qty > 0;
  if v_count = 0 then
    return private.warehouse_company((select warehouse_id from public.storage_locations where id = p_location));
  elsif v_count > 1 then
    perform private.fail('CS422', 'Stock of this product at this location belongs to more than one company — select the owner',
      jsonb_build_object('product_id', p_product, 'location_id', p_location));
  end if;
  return v_owner;
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: RECEIVE STOCK
-- p_lines: [{product_id, location_id?, owner_company_id?, qty, uom_id?, unit_cost?}]
-- -----------------------------------------------------------------------------
create or replace function public.receive_stock(
  p_request_id uuid, p_warehouse_id uuid, p_reference text, p_lines jsonb,
  p_supplier_id uuid default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_txn public.stock_transactions;
  l jsonb; i int := 0; v_loc uuid; v_owner uuid; c record; v_moves jsonb := '[]'; v_res jsonb;
begin
  v_payload := jsonb_build_object('wh', p_warehouse_id, 'ref', p_reference, 'lines', p_lines, 'sup', p_supplier_id, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'receive_stock', v_payload);
  if v_prev is not null then return v_prev; end if;

  v_uid := private.require_perm('stock.receive', p_warehouse_id);
  perform private.require_lines(p_lines);
  if coalesce(trim(p_reference), '') = '' then
    perform private.fail('CS422', 'A supplier delivery note / reference is required when receiving stock');
  end if;
  if p_supplier_id is not null and not exists (select 1 from public.suppliers where id = p_supplier_id) then
    perform private.fail('CS422', 'Unknown supplier');
  end if;

  v_txn := private.new_txn('receipt', 'pending_approval', p_warehouse_id, p_request_id, null, p_reference, p_notes, p_supplier_id);

  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_loc := coalesce(nullif(l ->> 'location_id','')::uuid, private.default_location(p_warehouse_id));
    perform private.location_warehouse(v_loc, p_warehouse_id);
    select * into c from private.to_base((l ->> 'product_id')::uuid, nullif(l ->> 'uom_id','')::uuid, (l ->> 'qty')::numeric);
    v_owner := private.resolve_owner(l, (l ->> 'product_id')::uuid, v_loc, 'available', true);
    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status,
         qty_base, entered_qty, entered_uom_id, factor)
    values (v_txn.id, i, (l ->> 'product_id')::uuid, v_loc, v_owner, 'available', c.qty_base, (l ->> 'qty')::numeric,
         c.uom_id, c.factor);
    if nullif(l ->> 'unit_cost','') is not null then
      if (l ->> 'unit_cost')::numeric < 0 then perform private.fail('CS422', 'Unit cost cannot be negative'); end if;
      insert into public.txn_line_costs (txn_id, line_no, unit_cost) values (v_txn.id, i, (l ->> 'unit_cost')::numeric);
    end if;
    v_moves := v_moves || jsonb_build_object('line_no', i, 'product_id', l ->> 'product_id', 'location_id', v_loc,
       'owner_company_id', v_owner, 'status', 'available', 'qty_delta', c.qty_base, 'entered_qty', l ->> 'qty',
       'entered_uom_id', c.uom_id, 'factor', c.factor);
  end loop;

  v_res := private.post_movements(v_txn.id, v_moves, v_uid);
  return private.idem_finish(p_request_id, 'receive_stock', v_payload,
    jsonb_build_object('ok', true, 'status', 'posted', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no, 'movements', v_res));
end $$;

-- -----------------------------------------------------------------------------
-- Unusual withdrawal detection (warn & require reconfirmation — never guess)
-- -----------------------------------------------------------------------------
create or replace function private.withdrawal_profile(p_product uuid, p_warehouse uuid)
returns table (n bigint, avg_qty numeric, max_qty numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*), avg(-q), max(-q) from (
    select sum(l.qty_delta) as q
    from public.stock_ledger l
    where l.product_id = p_product and l.warehouse_id = p_warehouse and l.txn_type = 'withdrawal'
      and l.posted_at > now() - interval '90 days'
    group by l.txn_id) s
$$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: WITHDRAW STOCK
-- p_lines: [{product_id, location_id, owner_company_id?, qty, uom_id?, status? (default available)}]
-- -----------------------------------------------------------------------------
create or replace function public.withdraw_stock(
  p_request_id uuid, p_warehouse_id uuid, p_reason_code text, p_lines jsonb,
  p_reference text default null, p_notes text default null, p_confirm_unusual boolean default false)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_txn public.stock_transactions; v_reason uuid;
  l jsonb; i int := 0; v_loc uuid; v_owner uuid; v_status public.stock_status; c record; prof record;
  v_moves jsonb := '[]'; v_res jsonb; v_unusual jsonb := '[]'; v_factor numeric; v_nohist numeric; v_limit numeric;
  v_sku text; v_reserved numeric; v_wh_avail numeric; v_product uuid; v_line_unusual boolean;
begin
  v_payload := jsonb_build_object('wh', p_warehouse_id, 'reason', p_reason_code, 'lines', p_lines, 'ref', p_reference,
                                  'notes', p_notes, 'confirm', p_confirm_unusual);
  v_prev := private.idem_begin(p_request_id, 'withdraw_stock', v_payload);
  if v_prev is not null then return v_prev; end if;

  v_uid := private.require_perm('stock.withdraw', p_warehouse_id);
  perform private.require_lines(p_lines);
  v_reason := private.reason_id('withdrawal', p_reason_code, p_reference);
  v_factor := private.setting_num('withdraw.unusual_factor', 5);
  v_nohist := private.setting_num('withdraw.unusual_no_history_qty', 0);

  -- pass 1: validate and detect unusual quantities BEFORE anything is written
  for l in select * from jsonb_array_elements(p_lines) loop
    v_product := (l ->> 'product_id')::uuid;
    select * into c from private.to_base(v_product, nullif(l ->> 'uom_id','')::uuid, (l ->> 'qty')::numeric);
    select * into prof from private.withdrawal_profile(v_product, p_warehouse_id);
    select sku, unusual_withdrawal_qty into v_sku, v_limit from public.products where id = v_product;
    v_line_unusual := false;
    if v_limit is not null and c.qty_base > v_limit then
      v_line_unusual := true;
    elsif prof.n >= private.setting_num('withdraw.unusual_min_history', 3) and c.qty_base > v_factor * prof.avg_qty then
      v_line_unusual := true;
    elsif prof.n < private.setting_num('withdraw.unusual_min_history', 3) and v_nohist > 0 and c.qty_base > v_nohist then
      v_line_unusual := true;
    end if;
    if v_line_unusual then
      v_unusual := v_unusual || jsonb_build_object('product_id', v_product, 'sku', v_sku, 'qty_base', c.qty_base,
                     'usual_avg', round(coalesce(prof.avg_qty, 0), 4), 'usual_max', coalesce(prof.max_qty, 0),
                     'history_count', prof.n, 'product_limit', v_limit);
    end if;
  end loop;

  if jsonb_array_length(v_unusual) > 0 and not coalesce(p_confirm_unusual, false) then
    perform private.fail('CS428', 'Unusually large withdrawal quantity — please verify the quantity and confirm',
                         jsonb_build_object('unusual', v_unusual));
  end if;

  v_txn := private.new_txn('withdrawal', 'pending_approval', p_warehouse_id, p_request_id, v_reason, p_reference, p_notes);
  if jsonb_array_length(v_unusual) > 0 then
    update public.stock_transactions set is_unusual = true, unusual_info = jsonb_build_object('lines', v_unusual)
    where id = v_txn.id;
  end if;

  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_product := (l ->> 'product_id')::uuid;
    v_loc := nullif(l ->> 'location_id','')::uuid;
    if v_loc is null then perform private.fail('CS422', 'Select the location the stock is taken from'); end if;
    perform private.location_warehouse(v_loc, p_warehouse_id);
    v_status := coalesce(nullif(l ->> 'status',''), 'available')::public.stock_status;
    if v_status = 'in_transit' then perform private.fail('CS422', 'Stock in transit cannot be withdrawn'); end if;
    select * into c from private.to_base(v_product, nullif(l ->> 'uom_id','')::uuid, (l ->> 'qty')::numeric);
    v_owner := private.resolve_owner(l, v_product, v_loc, v_status, false);

    -- reserved stock protection (available stock only)
    if v_status = 'available' then
      select coalesce(sum(qty_reserved - qty_fulfilled), 0) into v_reserved
      from public.stock_reservations
      where product_id = v_product and warehouse_id = p_warehouse_id and owner_company_id = v_owner and status = 'active'
        and (expires_at is null or expires_at > now())
        and reference is distinct from nullif(trim(p_reference), '');
      if v_reserved > 0 then
        select coalesce(sum(qty), 0) into v_wh_avail from public.stock_balances
        where product_id = v_product and warehouse_id = p_warehouse_id and owner_company_id = v_owner and status = 'available';
        if v_wh_avail - c.qty_base < v_reserved then
          perform private.fail('CS409', format('Only %s can be withdrawn: %s is reserved for other jobs/clients',
                               greatest(v_wh_avail - v_reserved, 0), v_reserved),
                               jsonb_build_object('product_id', v_product, 'reserved', v_reserved, 'available', v_wh_avail));
        end if;
      end if;
      -- consume a matching reservation
      update public.stock_reservations
         set qty_fulfilled = least(qty_reserved, qty_fulfilled + c.qty_base),
             status = case when qty_fulfilled + c.qty_base >= qty_reserved then 'fulfilled' else status end,
             closed_at = case when qty_fulfilled + c.qty_base >= qty_reserved then now() else closed_at end
       where id = (select id from public.stock_reservations
                   where product_id = v_product and warehouse_id = p_warehouse_id and owner_company_id = v_owner
                     and status = 'active' and reference = nullif(trim(p_reference), '')
                   order by created_at limit 1);
    end if;

    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status,
         qty_base, entered_qty, entered_uom_id, factor)
    values (v_txn.id, i, v_product, v_loc, v_owner, v_status, c.qty_base, (l ->> 'qty')::numeric, c.uom_id, c.factor);
    v_moves := v_moves || jsonb_build_object('line_no', i, 'product_id', v_product, 'location_id', v_loc,
       'owner_company_id', v_owner, 'status', v_status, 'qty_delta', -c.qty_base, 'entered_qty', l ->> 'qty',
       'entered_uom_id', c.uom_id, 'factor', c.factor);
  end loop;

  v_res := private.post_movements(v_txn.id, v_moves, v_uid);

  if jsonb_array_length(v_unusual) > 0 then
    perform private.raise_alert('unusual_withdrawal', 'warning',
      'Unusual withdrawal ' || v_txn.txn_no,
      format('Withdrawal %s by %s contained unusually large quantities (confirmed by the user): %s',
             v_txn.txn_no, (select full_name from public.app_users where id = v_uid),
             (select string_agg((x ->> 'sku') || ' ' || (x ->> 'qty_base') || ' (usual avg ' || (x ->> 'usual_avg') || ')', '; ')
              from jsonb_array_elements(v_unusual) x)),
      'unusual:' || v_txn.id, null, p_warehouse_id, null, null, null, 'txn', v_txn.id::text, false,
      '/transactions/' || v_txn.id);
  end if;

  return private.idem_finish(p_request_id, 'withdraw_stock', v_payload,
    jsonb_build_object('ok', true, 'status', 'posted', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no,
                       'unusual', jsonb_array_length(v_unusual) > 0, 'movements', v_res));
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: RETURN STOCK
-- p_lines: [{product_id, location_id?, owner_company_id?, qty, uom_id?, condition: 'good'|'damaged'}]
-- -----------------------------------------------------------------------------
create or replace function public.return_stock(
  p_request_id uuid, p_warehouse_id uuid, p_reason_code text, p_lines jsonb,
  p_original_txn_id uuid default null, p_reference text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_txn public.stock_transactions; v_reason uuid; v_orig public.stock_transactions;
  l jsonb; i int := 0; v_loc uuid; v_owner uuid; v_status public.stock_status; c record; v_moves jsonb := '[]'; v_res jsonb;
  v_product uuid; v_withdrawn numeric; v_returned numeric; v_this numeric;
begin
  v_payload := jsonb_build_object('wh', p_warehouse_id, 'reason', p_reason_code, 'lines', p_lines,
                                  'orig', p_original_txn_id, 'ref', p_reference, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'return_stock', v_payload);
  if v_prev is not null then return v_prev; end if;

  v_uid := private.require_perm('stock.return', p_warehouse_id);
  perform private.require_lines(p_lines);
  v_reason := private.reason_id('return', p_reason_code, p_reference);

  if p_original_txn_id is not null then
    select * into v_orig from public.stock_transactions where id = p_original_txn_id;
    if not found or v_orig.txn_type <> 'withdrawal' or v_orig.status <> 'posted' then
      perform private.fail('CS422', 'The linked original transaction must be a posted withdrawal');
    end if;
  end if;

  v_txn := private.new_txn('return', 'pending_approval', p_warehouse_id, p_request_id, v_reason,
                           coalesce(p_reference, v_orig.reference), p_notes, null, p_original_txn_id);

  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_product := (l ->> 'product_id')::uuid;
    v_loc := coalesce(nullif(l ->> 'location_id','')::uuid, private.default_location(p_warehouse_id));
    perform private.location_warehouse(v_loc, p_warehouse_id);
    v_status := case coalesce(l ->> 'condition', 'good')
                  when 'good' then 'available'::public.stock_status
                  when 'damaged' then 'damaged'::public.stock_status
                  else null end;
    if v_status is null then perform private.fail('CS422', 'Condition must be "good" or "damaged"'); end if;
    select * into c from private.to_base(v_product, nullif(l ->> 'uom_id','')::uuid, (l ->> 'qty')::numeric);

    if p_original_txn_id is not null then
      select coalesce(-sum(qty_delta), 0), min(owner_company_id::text)::uuid into v_withdrawn, v_owner
      from public.stock_ledger where txn_id = p_original_txn_id and product_id = v_product;
      if v_withdrawn = 0 then
        perform private.fail('CS422', 'This product was not part of the original withdrawal ' || v_orig.txn_no);
      end if;
      select coalesce(sum(sl.qty_delta), 0) into v_returned
      from public.stock_ledger sl join public.stock_transactions t on t.id = sl.txn_id
      where t.related_txn_id = p_original_txn_id and t.txn_type = 'return' and sl.product_id = v_product;
      select coalesce(sum(qty_base), 0) into v_this from public.stock_transaction_lines
      where txn_id = v_txn.id and product_id = v_product;
      if v_returned + v_this + c.qty_base > v_withdrawn then
        perform private.fail('CS422', format('Cannot return more than was withdrawn on %s (withdrawn %s, already returned %s)',
                             v_orig.txn_no, v_withdrawn, v_returned));
      end if;
      if nullif(l ->> 'owner_company_id','') is not null and (l ->> 'owner_company_id')::uuid <> v_owner then
        perform private.fail('CS422', 'Returned stock must be returned to the company that owned the withdrawn stock');
      end if;
    else
      v_owner := private.resolve_owner(l, v_product, v_loc, v_status, true);
    end if;

    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status,
         qty_base, entered_qty, entered_uom_id, factor, extra)
    values (v_txn.id, i, v_product, v_loc, v_owner, v_status, c.qty_base, (l ->> 'qty')::numeric, c.uom_id, c.factor,
            jsonb_build_object('condition', coalesce(l ->> 'condition','good')));
    v_moves := v_moves || jsonb_build_object('line_no', i, 'product_id', v_product, 'location_id', v_loc,
       'owner_company_id', v_owner, 'status', v_status, 'qty_delta', c.qty_base, 'entered_qty', l ->> 'qty',
       'entered_uom_id', c.uom_id, 'factor', c.factor);
  end loop;

  v_res := private.post_movements(v_txn.id, v_moves, v_uid);
  return private.idem_finish(p_request_id, 'return_stock', v_payload,
    jsonb_build_object('ok', true, 'status', 'posted', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no, 'movements', v_res));
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: MOVE STOCK (shelf / bin / area moves inside ONE warehouse, same owner)
-- p_lines: [{product_id, from_location_id, to_location_id, owner_company_id?, qty, uom_id?, status?}]
-- -----------------------------------------------------------------------------
create or replace function public.move_stock(
  p_request_id uuid, p_warehouse_id uuid, p_lines jsonb, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_txn public.stock_transactions;
  l jsonb; i int := 0; v_from uuid; v_to uuid; v_owner uuid; v_status public.stock_status; c record;
  v_moves jsonb := '[]'; v_res jsonb; v_product uuid;
begin
  v_payload := jsonb_build_object('wh', p_warehouse_id, 'lines', p_lines, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'move_stock', v_payload);
  if v_prev is not null then return v_prev; end if;

  v_uid := private.require_perm('stock.move', p_warehouse_id);
  perform private.require_lines(p_lines);
  v_txn := private.new_txn('move', 'pending_approval', p_warehouse_id, p_request_id, null, null, p_notes);

  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_product := (l ->> 'product_id')::uuid;
    v_from := (l ->> 'from_location_id')::uuid;
    v_to := (l ->> 'to_location_id')::uuid;
    if v_from is null or v_to is null then perform private.fail('CS422', 'From and to locations are required'); end if;
    if v_from = v_to then perform private.fail('CS422', 'From and to locations must be different'); end if;
    perform private.location_warehouse(v_from, p_warehouse_id);
    perform private.location_warehouse(v_to, p_warehouse_id);
    v_status := coalesce(nullif(l ->> 'status',''), 'available')::public.stock_status;
    if v_status = 'in_transit' then perform private.fail('CS422', 'Stock in transit cannot be moved'); end if;
    select * into c from private.to_base(v_product, nullif(l ->> 'uom_id','')::uuid, (l ->> 'qty')::numeric);
    v_owner := private.resolve_owner(l, v_product, v_from, v_status, false);

    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, to_location_id, owner_company_id,
         status, qty_base, entered_qty, entered_uom_id, factor)
    values (v_txn.id, i, v_product, v_from, v_to, v_owner, v_status, c.qty_base, (l ->> 'qty')::numeric, c.uom_id, c.factor);
    v_moves := v_moves
      || jsonb_build_object('line_no', i, 'product_id', v_product, 'location_id', v_from, 'owner_company_id', v_owner,
           'status', v_status, 'qty_delta', -c.qty_base, 'entered_qty', l ->> 'qty', 'entered_uom_id', c.uom_id, 'factor', c.factor)
      || jsonb_build_object('line_no', i, 'product_id', v_product, 'location_id', v_to, 'owner_company_id', v_owner,
           'status', v_status, 'qty_delta', c.qty_base, 'entered_qty', l ->> 'qty', 'entered_uom_id', c.uom_id, 'factor', c.factor);
  end loop;

  v_res := private.post_movements(v_txn.id, v_moves, v_uid);
  return private.idem_finish(p_request_id, 'move_stock', v_payload,
    jsonb_build_object('ok', true, 'status', 'posted', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no, 'movements', v_res));
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: STATUS CHANGE (available <-> damaged / quarantine)
-- p_lines: [{product_id, location_id, owner_company_id?, qty, uom_id?, from_status, to_status}]
-- Releasing stock back to "available" requires stock.approve.
-- -----------------------------------------------------------------------------
create or replace function public.change_stock_status(
  p_request_id uuid, p_warehouse_id uuid, p_reason_code text, p_lines jsonb, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_txn public.stock_transactions; v_reason uuid;
  l jsonb; i int := 0; v_loc uuid; v_owner uuid; v_from public.stock_status; v_to public.stock_status; c record;
  v_moves jsonb := '[]'; v_res jsonb; v_product uuid;
begin
  v_payload := jsonb_build_object('wh', p_warehouse_id, 'reason', p_reason_code, 'lines', p_lines, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'change_stock_status', v_payload);
  if v_prev is not null then return v_prev; end if;

  v_uid := private.require_perm('stock.adjust', p_warehouse_id);
  perform private.require_lines(p_lines);
  v_reason := private.reason_id('status_change', p_reason_code, null);
  v_txn := private.new_txn('status_change', 'pending_approval', p_warehouse_id, p_request_id, v_reason, null, p_notes);

  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_product := (l ->> 'product_id')::uuid;
    v_loc := (l ->> 'location_id')::uuid;
    perform private.location_warehouse(v_loc, p_warehouse_id);
    v_from := (l ->> 'from_status')::public.stock_status;
    v_to := (l ->> 'to_status')::public.stock_status;
    if v_from = v_to or 'in_transit' in (v_from, v_to) then
      perform private.fail('CS422', 'Invalid status change');
    end if;
    if v_to = 'available' then perform private.require_perm('stock.approve', p_warehouse_id); end if;
    select * into c from private.to_base(v_product, nullif(l ->> 'uom_id','')::uuid, (l ->> 'qty')::numeric);
    v_owner := private.resolve_owner(l, v_product, v_loc, v_from, false);
    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status, to_status,
         qty_base, entered_qty, entered_uom_id, factor)
    values (v_txn.id, i, v_product, v_loc, v_owner, v_from, v_to, c.qty_base, (l ->> 'qty')::numeric, c.uom_id, c.factor);
    v_moves := v_moves
      || jsonb_build_object('line_no', i, 'product_id', v_product, 'location_id', v_loc, 'owner_company_id', v_owner,
           'status', v_from, 'qty_delta', -c.qty_base, 'entered_qty', l ->> 'qty', 'entered_uom_id', c.uom_id, 'factor', c.factor)
      || jsonb_build_object('line_no', i, 'product_id', v_product, 'location_id', v_loc, 'owner_company_id', v_owner,
           'status', v_to, 'qty_delta', c.qty_base, 'entered_qty', l ->> 'qty', 'entered_uom_id', c.uom_id, 'factor', c.factor);
  end loop;

  v_res := private.post_movements(v_txn.id, v_moves, v_uid);
  return private.idem_finish(p_request_id, 'change_stock_status', v_payload,
    jsonb_build_object('ok', true, 'status', 'posted', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no, 'movements', v_res));
end $$;

-- -----------------------------------------------------------------------------
-- Approval request helper
-- -----------------------------------------------------------------------------
create or replace function private.create_approval(
  p_kind text, p_perm text, p_warehouse uuid, p_summary text, p_details jsonb,
  p_txn uuid default null, p_transfer uuid default null, p_stocktake uuid default null, p_import uuid default null)
returns uuid language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_id uuid;
begin
  insert into public.approval_requests (kind, required_perm, warehouse_id, txn_id, transfer_id, stocktake_id, import_batch_id,
                                        summary, details, requested_by)
  values (p_kind, p_perm, p_warehouse, p_txn, p_transfer, p_stocktake, p_import, p_summary, p_details,
          coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'))
  returning id into v_id;
  perform private.raise_alert('approval_pending', 'info', 'Approval required: ' || p_summary,
    p_summary || ' — requested by ' || coalesce((select full_name from public.app_users where id = auth.uid()), 'system'),
    'approval:' || v_id, null, p_warehouse, null, null, null, 'approval', v_id::text, false, '/approvals');
  return v_id;
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: ADJUST STOCK (reason + permission always; approval when large/unusual)
-- p_lines: [{product_id, location_id, owner_company_id?, status?, qty (signed), uom_id?}]
-- -----------------------------------------------------------------------------
create or replace function public.request_adjustment(
  p_request_id uuid, p_warehouse_id uuid, p_reason_code text, p_lines jsonb,
  p_reference text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_txn public.stock_transactions; v_reason uuid;
  l jsonb; i int := 0; v_loc uuid; v_owner uuid; v_status public.stock_status; c record; v_moves jsonb := '[]'; v_res jsonb;
  v_product uuid; v_needs boolean := false; v_why text[] := '{}'; v_cur numeric; v_price numeric; v_approval uuid;
  v_qty_t numeric := private.setting_num('adjust.approval_qty_threshold', 20);
  v_pct_t numeric := private.setting_num('adjust.approval_pct_threshold', 10);
  v_val_t numeric := private.setting_num('adjust.approval_value_threshold', 2000);
  v_sku text;
begin
  v_payload := jsonb_build_object('wh', p_warehouse_id, 'reason', p_reason_code, 'lines', p_lines, 'ref', p_reference, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'request_adjustment', v_payload);
  if v_prev is not null then return v_prev; end if;

  v_uid := private.require_perm('stock.adjust', p_warehouse_id);
  perform private.require_lines(p_lines);
  v_reason := private.reason_id('adjustment', p_reason_code, p_reference);
  if coalesce(trim(p_notes), '') = '' then
    perform private.fail('CS422', 'An explanation is required for every stock adjustment');
  end if;

  v_txn := private.new_txn('adjustment', 'pending_approval', p_warehouse_id, p_request_id, v_reason, p_reference, p_notes);
  if private.setting_bool('adjust.always_require_approval', false) then
    v_needs := true; v_why := v_why || 'all adjustments require approval'::text;
  end if;

  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_product := (l ->> 'product_id')::uuid;
    v_loc := (l ->> 'location_id')::uuid;
    if v_loc is null then perform private.fail('CS422', 'A location is required for each adjustment line'); end if;
    perform private.location_warehouse(v_loc, p_warehouse_id);
    v_status := coalesce(nullif(l ->> 'status',''), 'available')::public.stock_status;
    if v_status = 'in_transit' then perform private.fail('CS422', 'In-transit stock is corrected through the transfer process'); end if;
    select * into c from private.to_base(v_product, nullif(l ->> 'uom_id','')::uuid, (l ->> 'qty')::numeric, true);
    v_owner := private.resolve_owner(l, v_product, v_loc, v_status, (l ->> 'qty')::numeric > 0);

    select coalesce(qty, 0) into v_cur from public.stock_balances
    where product_id = v_product and location_id = v_loc and owner_company_id = v_owner and status = v_status;
    v_cur := coalesce(v_cur, 0);
    if v_cur + c.qty_base < 0 then
      select sku into v_sku from public.products where id = v_product;
      perform private.fail('CS409', format('Adjustment would make %s negative (current %s)', v_sku, v_cur));
    end if;
    select pc.purchase_price, p.sku into v_price, v_sku
    from public.products p left join public.product_costs pc on pc.product_id = p.id where p.id = v_product;
    if abs(c.qty_base) > v_qty_t then v_needs := true; v_why := v_why || format('%s: quantity %s exceeds %s', v_sku, abs(c.qty_base), v_qty_t); end if;
    if v_cur > 0 and abs(c.qty_base) / v_cur * 100 > v_pct_t then
      v_needs := true; v_why := v_why || format('%s: changes balance by %s%%', v_sku, round(abs(c.qty_base) / v_cur * 100, 1));
    end if;
    if v_cur = 0 and c.qty_base > 0 and v_pct_t < 100 then
      v_needs := true; v_why := v_why || format('%s: creates stock where the balance was zero', v_sku);
    end if;
    if v_price is not null and abs(c.qty_base) * v_price > v_val_t then
      v_needs := true; v_why := v_why || format('%s: value R %s exceeds R %s', v_sku, round(abs(c.qty_base) * v_price, 2), v_val_t);
    end if;

    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status,
         qty_base, entered_qty, entered_uom_id, factor, extra)
    values (v_txn.id, i, v_product, v_loc, v_owner, v_status, c.qty_base, (l ->> 'qty')::numeric, c.uom_id, c.factor,
            jsonb_build_object('balance_at_request', v_cur));
    v_moves := v_moves || jsonb_build_object('line_no', i, 'product_id', v_product, 'location_id', v_loc,
       'owner_company_id', v_owner, 'status', v_status, 'qty_delta', c.qty_base, 'entered_qty', l ->> 'qty',
       'entered_uom_id', c.uom_id, 'factor', c.factor);
  end loop;

  if v_needs then
    v_approval := private.create_approval('adjustment', 'stock.approve', p_warehouse_id,
      'Stock adjustment ' || v_txn.txn_no, jsonb_build_object('reasons', to_jsonb(v_why)), v_txn.id);
    return private.idem_finish(p_request_id, 'request_adjustment', v_payload,
      jsonb_build_object('ok', true, 'status', 'pending_approval', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no,
                         'approval_id', v_approval, 'approval_reasons', to_jsonb(v_why)));
  end if;

  v_res := private.post_movements(v_txn.id, v_moves, v_uid);
  return private.idem_finish(p_request_id, 'request_adjustment', v_payload,
    jsonb_build_object('ok', true, 'status', 'posted', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no, 'movements', v_res));
end $$;

-- builds the movement list for a pending adjustment / reversal / write-off from its stored lines
create or replace function private.moves_from_lines(p_txn uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('line_no', line_no, 'product_id', product_id, 'location_id', location_id,
     'owner_company_id', owner_company_id, 'status', status, 'qty_delta', qty_base, 'entered_qty', entered_qty,
     'entered_uom_id', entered_uom_id, 'factor', factor) order by line_no), '[]')
  from public.stock_transaction_lines where txn_id = p_txn
$$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: REVERSAL REQUEST (always requires approval)
-- -----------------------------------------------------------------------------
create or replace function public.request_reversal(p_request_id uuid, p_txn_id uuid, p_notes text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_orig public.stock_transactions; v_txn public.stock_transactions; v_approval uuid;
  r record; i int := 0;
begin
  v_payload := jsonb_build_object('txn', p_txn_id, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'request_reversal', v_payload);
  if v_prev is not null then return v_prev; end if;

  select * into v_orig from public.stock_transactions where id = p_txn_id;
  if not found then perform private.fail('CS422', 'Transaction not found'); end if;
  v_uid := private.require_perm('stock.reverse', v_orig.warehouse_id);
  if v_orig.status <> 'posted' then perform private.fail('CS423', 'Only posted transactions can be reversed'); end if;
  if v_orig.txn_type not in ('receipt','withdrawal','return','move','adjustment','status_change') then
    perform private.fail('CS422', 'Transactions of type ' || v_orig.txn_type || ' cannot be reversed; use an adjustment');
  end if;
  if coalesce(trim(p_notes), '') = '' then perform private.fail('CS422', 'A reason for the reversal is required'); end if;
  if exists (select 1 from public.stock_transactions where related_txn_id = p_txn_id and txn_type = 'reversal'
             and status in ('pending_approval','posted')) then
    perform private.fail('CS423', 'This transaction has already been reversed or has a pending reversal');
  end if;

  v_txn := private.new_txn('reversal', 'pending_approval', v_orig.warehouse_id, p_request_id, null,
                           'Reversal of ' || v_orig.txn_no, p_notes, null, p_txn_id);
  for r in select * from public.stock_ledger where txn_id = p_txn_id order by id loop
    i := i + 1;
    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status,
         qty_base, entered_qty, entered_uom_id, factor, extra)
    values (v_txn.id, i, r.product_id, r.location_id, r.owner_company_id, r.status, -r.qty_delta,
            -sign(r.qty_delta) * r.entered_qty, r.entered_uom_id, r.factor, jsonb_build_object('reverses_ledger_id', r.id));
  end loop;

  v_approval := private.create_approval('reversal', 'stock.approve', v_orig.warehouse_id,
    'Reversal of ' || v_orig.txn_no || ' (' || v_txn.txn_no || ')', jsonb_build_object('original', v_orig.txn_no), v_txn.id);
  return private.idem_finish(p_request_id, 'request_reversal', v_payload,
    jsonb_build_object('ok', true, 'status', 'pending_approval', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no, 'approval_id', v_approval));
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: TRANSFERS
-- -----------------------------------------------------------------------------
-- p_lines: [{product_id, from_location_id, to_location_id?, owner_company_id?, qty, uom_id?}]
create or replace function public.create_transfer(
  p_request_id uuid, p_from_warehouse_id uuid, p_to_warehouse_id uuid, p_lines jsonb,
  p_to_owner_company_id uuid default null, p_expected_arrival_at timestamptz default null,
  p_reference text default null, p_notes text default null, p_dispatch_now boolean default false)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_tr public.transfers; l jsonb; i int := 0; c record;
  v_from uuid; v_to uuid; v_owner uuid; v_product uuid; v_res jsonb;
begin
  v_payload := jsonb_build_object('from', p_from_warehouse_id, 'to', p_to_warehouse_id, 'lines', p_lines,
     'owner', p_to_owner_company_id, 'eta', p_expected_arrival_at, 'ref', p_reference, 'notes', p_notes, 'now', p_dispatch_now);
  v_prev := private.idem_begin(p_request_id, 'create_transfer', v_payload);
  if v_prev is not null then return v_prev; end if;

  v_uid := private.require_perm('stock.transfer.dispatch', p_from_warehouse_id);
  perform private.require_lines(p_lines);
  if p_from_warehouse_id = p_to_warehouse_id then
    perform private.fail('CS422', 'For moves inside one warehouse use "Move stock". A transfer needs a different destination warehouse.');
  end if;
  if not exists (select 1 from public.warehouses where id = p_to_warehouse_id and status = 'active') then
    perform private.fail('CS422', 'Destination warehouse is not active');
  end if;
  if p_to_owner_company_id is not null and not exists (select 1 from public.companies where id = p_to_owner_company_id and status = 'active') then
    perform private.fail('CS422', 'Unknown destination owner company');
  end if;

  insert into public.transfers (transfer_no, from_warehouse_id, to_warehouse_id, to_owner_company_id, reference, notes,
                                expected_arrival_at, client_request_id, created_by)
  values (private.next_doc_no('TRF'), p_from_warehouse_id, p_to_warehouse_id, p_to_owner_company_id, nullif(trim(p_reference),''),
          nullif(trim(p_notes),''),
          coalesce(p_expected_arrival_at, now() + make_interval(days => private.setting_num('transfer.default_transit_days', 3)::int)),
          p_request_id, v_uid)
  returning * into v_tr;

  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    v_product := (l ->> 'product_id')::uuid;
    v_from := (l ->> 'from_location_id')::uuid;
    if v_from is null then perform private.fail('CS422', 'The origin location is required for every transfer line'); end if;
    perform private.location_warehouse(v_from, p_from_warehouse_id);
    v_to := coalesce(nullif(l ->> 'to_location_id','')::uuid, private.default_location(p_to_warehouse_id));
    perform private.location_warehouse(v_to, p_to_warehouse_id);
    select * into c from private.to_base(v_product, nullif(l ->> 'uom_id','')::uuid, (l ->> 'qty')::numeric);
    v_owner := private.resolve_owner(l, v_product, v_from, 'available', false);
    insert into public.transfer_lines (transfer_id, line_no, product_id, from_location_id, to_location_id, owner_company_id,
           entered_qty, entered_uom_id, factor, qty_dispatched)
    values (v_tr.id, i, v_product, v_from, v_to, v_owner, (l ->> 'qty')::numeric, c.uom_id, c.factor, c.qty_base);
  end loop;
  perform private.log_action('TRANSFER_CREATED', 'transfers', v_tr.id::text, jsonb_build_object('transfer_no', v_tr.transfer_no));

  if p_dispatch_now then
    v_res := private.dispatch_transfer_internal(v_tr.id, v_uid, gen_random_uuid());
  end if;

  return private.idem_finish(p_request_id, 'create_transfer', v_payload,
    jsonb_build_object('ok', true, 'transfer_id', v_tr.id, 'transfer_no', v_tr.transfer_no,
                       'status', case when p_dispatch_now then 'dispatched' else 'draft' end, 'dispatch', v_res));
end $$;

create or replace function private.dispatch_transfer_internal(p_transfer_id uuid, p_uid uuid, p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_tr public.transfers; v_txn public.stock_transactions; r record; v_moves jsonb := '[]'; v_res jsonb;
begin
  select * into v_tr from public.transfers where id = p_transfer_id for update;
  if v_tr.status <> 'draft' then perform private.fail('CS423', 'Transfer ' || v_tr.transfer_no || ' is already ' || v_tr.status); end if;

  v_txn := private.new_txn('transfer_dispatch', 'pending_approval', v_tr.from_warehouse_id, p_request_id, null,
                           v_tr.transfer_no, v_tr.notes, null, null, v_tr.id);
  for r in select * from public.transfer_lines where transfer_id = p_transfer_id order by line_no loop
    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, to_location_id, owner_company_id,
           status, to_status, qty_base, entered_qty, entered_uom_id, factor)
    values (v_txn.id, r.line_no, r.product_id, r.from_location_id, r.to_location_id, r.owner_company_id, 'available',
            'in_transit', r.qty_dispatched, r.entered_qty, r.entered_uom_id, r.factor);
    v_moves := v_moves
      || jsonb_build_object('line_no', r.line_no, 'product_id', r.product_id, 'location_id', r.from_location_id,
           'owner_company_id', r.owner_company_id, 'status', 'available', 'qty_delta', -r.qty_dispatched,
           'entered_qty', r.entered_qty, 'entered_uom_id', r.entered_uom_id, 'factor', r.factor)
      || jsonb_build_object('line_no', r.line_no, 'product_id', r.product_id, 'location_id', r.to_location_id,
           'owner_company_id', r.owner_company_id, 'status', 'in_transit', 'qty_delta', r.qty_dispatched,
           'entered_qty', r.entered_qty, 'entered_uom_id', r.entered_uom_id, 'factor', r.factor);
  end loop;
  v_res := private.post_movements(v_txn.id, v_moves, p_uid);
  update public.transfers set status = 'dispatched', dispatched_by = p_uid, dispatched_at = now(), dispatch_txn_id = v_txn.id
  where id = p_transfer_id;
  return jsonb_build_object('txn_id', v_txn.id, 'txn_no', v_txn.txn_no);
end $$;

create or replace function public.dispatch_transfer(p_request_id uuid, p_transfer_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_payload jsonb; v_wh uuid; v_res jsonb;
begin
  v_payload := jsonb_build_object('transfer', p_transfer_id);
  v_prev := private.idem_begin(p_request_id, 'dispatch_transfer', v_payload);
  if v_prev is not null then return v_prev; end if;
  select from_warehouse_id into v_wh from public.transfers where id = p_transfer_id;
  if v_wh is null then perform private.fail('CS422', 'Transfer not found'); end if;
  v_uid := private.require_perm('stock.transfer.dispatch', v_wh);
  v_res := private.dispatch_transfer_internal(p_transfer_id, v_uid, p_request_id);
  return private.idem_finish(p_request_id, 'dispatch_transfer', v_payload,
    jsonb_build_object('ok', true, 'status', 'dispatched') || v_res);
end $$;

create or replace function public.cancel_transfer(p_transfer_id uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_tr public.transfers; v_uid uuid;
begin
  select * into v_tr from public.transfers where id = p_transfer_id for update;
  if not found then perform private.fail('CS422', 'Transfer not found'); end if;
  v_uid := private.require_perm('stock.transfer.dispatch', v_tr.from_warehouse_id);
  if v_tr.status <> 'draft' then
    perform private.fail('CS423', 'Only draft transfers can be cancelled. Dispatched stock must be received or written off.');
  end if;
  update public.transfers set status = 'cancelled', cancelled_by = v_uid, cancelled_at = now(),
         notes = concat_ws(E'\n', notes, 'Cancelled: ' || coalesce(p_notes, '')) where id = p_transfer_id;
  perform private.log_action('TRANSFER_CANCELLED', 'transfers', p_transfer_id::text, jsonb_build_object('notes', p_notes));
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

-- p_lines: [{transfer_line_id, qty_received (good, base units), qty_damaged (base units), location_id?}]
create or replace function public.receive_transfer(p_request_id uuid, p_transfer_id uuid, p_lines jsonb, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_tr public.transfers; v_txn public.stock_transactions;
  l jsonb; tl public.transfer_lines; v_good numeric; v_dmg numeric; v_loc uuid; v_new_owner uuid; v_moves jsonb := '[]';
  v_res jsonb; v_outstanding numeric; v_any boolean := false; v_all_done boolean;
begin
  v_payload := jsonb_build_object('transfer', p_transfer_id, 'lines', p_lines, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'receive_transfer', v_payload);
  if v_prev is not null then return v_prev; end if;

  select * into v_tr from public.transfers where id = p_transfer_id for update;
  if not found then perform private.fail('CS422', 'Transfer not found'); end if;
  v_uid := private.require_perm('stock.transfer.receive', v_tr.to_warehouse_id);
  if v_tr.status not in ('dispatched','partially_received') then
    perform private.fail('CS423', 'Transfer ' || v_tr.transfer_no || ' is ' || v_tr.status || ' and cannot be received');
  end if;
  perform private.require_lines(p_lines);

  v_txn := private.new_txn('transfer_receipt', 'pending_approval', v_tr.to_warehouse_id, p_request_id, null,
                           v_tr.transfer_no, p_notes, null, v_tr.dispatch_txn_id, v_tr.id);

  for l in select * from jsonb_array_elements(p_lines) loop
    select * into tl from public.transfer_lines where id = (l ->> 'transfer_line_id')::uuid and transfer_id = p_transfer_id for update;
    if not found then perform private.fail('CS422', 'Line does not belong to this transfer'); end if;
    v_good := coalesce(nullif(l ->> 'qty_received','')::numeric, 0);
    v_dmg := coalesce(nullif(l ->> 'qty_damaged','')::numeric, 0);
    if v_good < 0 or v_dmg < 0 then perform private.fail('CS422', 'Received quantities cannot be negative'); end if;
    if v_good = 0 and v_dmg = 0 then continue; end if;
    v_outstanding := tl.qty_dispatched - tl.qty_received - tl.qty_damaged - tl.qty_written_off;
    if v_good + v_dmg > v_outstanding then
      perform private.fail('CS422', format('Line %s: receiving %s but only %s is still in transit (over-receipt is not allowed — record extra stock as a receipt)',
                           tl.line_no, v_good + v_dmg, v_outstanding));
    end if;
    v_loc := coalesce(nullif(l ->> 'location_id','')::uuid, tl.to_location_id);
    perform private.location_warehouse(v_loc, v_tr.to_warehouse_id);
    v_new_owner := coalesce(v_tr.to_owner_company_id, tl.owner_company_id);
    v_any := true;

    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, to_location_id, owner_company_id,
           status, to_status, qty_base, entered_qty, entered_uom_id, factor, extra)
    values (v_txn.id, tl.line_no, tl.product_id, tl.to_location_id, v_loc, tl.owner_company_id, 'in_transit', 'available',
            v_good + v_dmg, v_good + v_dmg, (select base_uom_id from public.products where id = tl.product_id), 1,
            jsonb_build_object('good', v_good, 'damaged', v_dmg, 'new_owner', v_new_owner, 'transfer_line_id', tl.id));

    v_moves := v_moves || jsonb_build_object('line_no', tl.line_no, 'product_id', tl.product_id, 'location_id', tl.to_location_id,
         'owner_company_id', tl.owner_company_id, 'status', 'in_transit', 'qty_delta', -(v_good + v_dmg),
         'entered_qty', v_good + v_dmg, 'entered_uom_id', (select base_uom_id from public.products where id = tl.product_id), 'factor', 1);
    if v_good > 0 then
      v_moves := v_moves || jsonb_build_object('line_no', tl.line_no, 'product_id', tl.product_id, 'location_id', v_loc,
           'owner_company_id', v_new_owner, 'status', 'available', 'qty_delta', v_good,
           'entered_qty', v_good, 'entered_uom_id', (select base_uom_id from public.products where id = tl.product_id), 'factor', 1);
    end if;
    if v_dmg > 0 then
      v_moves := v_moves || jsonb_build_object('line_no', tl.line_no, 'product_id', tl.product_id, 'location_id', v_loc,
           'owner_company_id', v_new_owner, 'status', 'damaged', 'qty_delta', v_dmg,
           'entered_qty', v_dmg, 'entered_uom_id', (select base_uom_id from public.products where id = tl.product_id), 'factor', 1);
    end if;
    update public.transfer_lines set qty_received = qty_received + v_good, qty_damaged = qty_damaged + v_dmg where id = tl.id;
  end loop;

  if not v_any then perform private.fail('CS422', 'Enter the quantity received for at least one line'); end if;
  v_res := private.post_movements(v_txn.id, v_moves, v_uid);

  select bool_and(qty_received + qty_damaged + qty_written_off = qty_dispatched) into v_all_done
  from public.transfer_lines where transfer_id = p_transfer_id;
  update public.transfers set
    status = case when v_all_done then
                    case when exists (select 1 from public.transfer_lines where transfer_id = p_transfer_id and (qty_damaged > 0 or qty_written_off > 0))
                         then 'closed_with_discrepancy' else 'received' end
                  else 'partially_received' end,
    completed_at = case when v_all_done then now() end
  where id = p_transfer_id;
  if v_all_done then perform private.resolve_alert('transfer_overdue:' || p_transfer_id, 'Transfer received'); end if;

  return private.idem_finish(p_request_id, 'receive_transfer', v_payload,
    jsonb_build_object('ok', true, 'status', 'posted', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no,
       'transfer_status', (select status from public.transfers where id = p_transfer_id), 'movements', v_res));
end $$;

-- Shortage that will never arrive -> write-off request (approval required)
create or replace function public.request_transfer_writeoff(p_request_id uuid, p_transfer_id uuid, p_reason_code text, p_notes text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_tr public.transfers; v_txn public.stock_transactions; v_reason uuid;
  tl record; v_out numeric; i int := 0; v_approval uuid;
begin
  v_payload := jsonb_build_object('transfer', p_transfer_id, 'reason', p_reason_code, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'request_transfer_writeoff', v_payload);
  if v_prev is not null then return v_prev; end if;
  select * into v_tr from public.transfers where id = p_transfer_id for update;
  if not found then perform private.fail('CS422', 'Transfer not found'); end if;
  v_uid := private.require_perm('stock.transfer.receive', v_tr.to_warehouse_id);
  if v_tr.status not in ('dispatched','partially_received') then
    perform private.fail('CS423', 'Only transfers with stock still in transit can be written off');
  end if;
  if coalesce(trim(p_notes),'') = '' then perform private.fail('CS422', 'An explanation is required'); end if;
  if exists (select 1 from public.stock_transactions where transfer_id = p_transfer_id and txn_type = 'transfer_writeoff' and status = 'pending_approval') then
    perform private.fail('CS423', 'A write-off for this transfer is already awaiting approval');
  end if;
  v_reason := private.reason_id('transfer_writeoff', p_reason_code, null);
  v_txn := private.new_txn('transfer_writeoff', 'pending_approval', v_tr.to_warehouse_id, p_request_id, v_reason,
                           v_tr.transfer_no, p_notes, null, v_tr.dispatch_txn_id, v_tr.id);
  for tl in select * from public.transfer_lines where transfer_id = p_transfer_id order by line_no loop
    v_out := tl.qty_dispatched - tl.qty_received - tl.qty_damaged - tl.qty_written_off;
    if v_out > 0 then
      i := i + 1;
      insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status,
             qty_base, entered_qty, entered_uom_id, factor, extra)
      values (v_txn.id, tl.line_no, tl.product_id, tl.to_location_id, tl.owner_company_id, 'in_transit', -v_out, -v_out,
              (select base_uom_id from public.products where id = tl.product_id), 1, jsonb_build_object('transfer_line_id', tl.id));
    end if;
  end loop;
  if i = 0 then perform private.fail('CS422', 'Nothing is outstanding on this transfer'); end if;
  v_approval := private.create_approval('transfer_writeoff', 'stock.approve', v_tr.to_warehouse_id,
     'Write-off of in-transit shortage on ' || v_tr.transfer_no, jsonb_build_object('transfer_no', v_tr.transfer_no), v_txn.id, v_tr.id);
  return private.idem_finish(p_request_id, 'request_transfer_writeoff', v_payload,
    jsonb_build_object('ok', true, 'status', 'pending_approval', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no, 'approval_id', v_approval));
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: APPROVAL DECISIONS
-- (stocktake and opening-balance approvals are handled by their modules, which
--  register handlers in private.approval_handlers below)
-- -----------------------------------------------------------------------------
create or replace function public.decide_approval(p_approval_id uuid, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_a public.approval_requests; v_uid uuid; v_txn public.stock_transactions; v_res jsonb; tl record;
begin
  select * into v_a from public.approval_requests where id = p_approval_id for update;
  if not found then perform private.fail('CS422', 'Approval request not found'); end if;
  if v_a.status <> 'pending' then perform private.fail('CS423', 'This request has already been ' || v_a.status); end if;
  v_uid := private.require_perm(v_a.required_perm, v_a.warehouse_id);
  if v_uid = v_a.requested_by then
    perform private.fail('CS401', 'You cannot approve or reject your own request (segregation of duties)');
  end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then
    perform private.fail('CS422', 'Please give a reason for rejecting the request');
  end if;

  update public.approval_requests set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = v_uid, decided_at = now(), decision_note = p_note
  where id = p_approval_id;

  if v_a.kind in ('adjustment','reversal','transfer_writeoff') then
    select * into v_txn from public.stock_transactions where id = v_a.txn_id for update;
    if p_approve then
      v_res := private.post_movements(v_txn.id, private.moves_from_lines(v_txn.id), v_uid);
      if v_a.kind = 'transfer_writeoff' then
        for tl in select (extra ->> 'transfer_line_id')::uuid as tlid, -qty_base as q
                  from public.stock_transaction_lines where txn_id = v_txn.id loop
          update public.transfer_lines set qty_written_off = qty_written_off + tl.q where id = tl.tlid;
        end loop;
        update public.transfers set status = 'closed_with_discrepancy', completed_at = now()
        where id = v_a.transfer_id
          and not exists (select 1 from public.transfer_lines where transfer_id = v_a.transfer_id
                          and qty_received + qty_damaged + qty_written_off < qty_dispatched);
        perform private.resolve_alert('transfer_overdue:' || v_a.transfer_id, 'Shortage written off');
      end if;
    else
      update public.stock_transactions set status = 'rejected' where id = v_txn.id;
    end if;
  elsif v_a.kind = 'stocktake' then
    v_res := private.stocktake_decision(v_a.stocktake_id, p_approve, v_uid, p_note);
  elsif v_a.kind = 'opening_balance' then
    v_res := private.import_decision(v_a.import_batch_id, p_approve, v_uid, p_note);
  end if;

  perform private.resolve_alert('approval:' || p_approval_id, case when p_approve then 'Approved' else 'Rejected' end);
  perform private.log_action(case when p_approve then 'APPROVE' else 'REJECT' end, 'approval_requests', p_approval_id::text,
                             jsonb_build_object('kind', v_a.kind, 'note', p_note));
  return jsonb_build_object('ok', true, 'status', case when p_approve then 'approved' else 'rejected' end, 'result', v_res);
end $$;

-- Requester may withdraw a pending request
create or replace function public.cancel_approval(p_approval_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_a public.approval_requests;
begin
  select * into v_a from public.approval_requests where id = p_approval_id for update;
  if not found or v_a.status <> 'pending' then perform private.fail('CS423', 'Only pending requests can be cancelled'); end if;
  if v_a.requested_by <> auth.uid() then perform private.fail('CS401', 'Only the requester can cancel this request'); end if;
  update public.approval_requests set status = 'cancelled', decided_at = now(), decision_note = p_note where id = p_approval_id;
  if v_a.txn_id is not null then update public.stock_transactions set status = 'cancelled' where id = v_a.txn_id; end if;
  if v_a.kind = 'stocktake' then perform private.stocktake_decision(v_a.stocktake_id, null, auth.uid(), p_note); end if;
  if v_a.kind = 'opening_balance' then perform private.import_decision(v_a.import_batch_id, null, auth.uid(), p_note); end if;
  perform private.resolve_alert('approval:' || p_approval_id, 'Cancelled by requester');
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API: RESERVATIONS
-- -----------------------------------------------------------------------------
create or replace function public.create_reservation(
  p_product_id uuid, p_warehouse_id uuid, p_qty numeric, p_reference text,
  p_owner_company_id uuid default null, p_uom_id uuid default null, p_expires_at timestamptz default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; c record; v_owner uuid; v_avail numeric; v_res numeric; v_id uuid;
begin
  v_uid := private.require_perm('stock.withdraw', p_warehouse_id);
  if coalesce(trim(p_reference),'') = '' then perform private.fail('CS422', 'A job / client reference is required'); end if;
  select * into c from private.to_base(p_product_id, p_uom_id, p_qty);
  v_owner := coalesce(p_owner_company_id, private.warehouse_company(p_warehouse_id));
  -- lock the product/warehouse balances so two reservations cannot over-allocate
  perform 1 from public.stock_balances where product_id = p_product_id and warehouse_id = p_warehouse_id
    and owner_company_id = v_owner and status = 'available' for update;
  select coalesce(sum(qty), 0) into v_avail from public.stock_balances
  where product_id = p_product_id and warehouse_id = p_warehouse_id and owner_company_id = v_owner and status = 'available';
  select coalesce(sum(qty_reserved - qty_fulfilled), 0) into v_res from public.stock_reservations
  where product_id = p_product_id and warehouse_id = p_warehouse_id and owner_company_id = v_owner and status = 'active'
    and (expires_at is null or expires_at > now());
  if c.qty_base > v_avail - v_res then
    perform private.fail('CS409', format('Only %s is unreserved and available', greatest(v_avail - v_res, 0)));
  end if;
  insert into public.stock_reservations (product_id, warehouse_id, owner_company_id, qty_reserved, reference, notes, expires_at, created_by)
  values (p_product_id, p_warehouse_id, v_owner, c.qty_base, trim(p_reference), p_notes, p_expires_at, v_uid)
  returning id into v_id;
  perform private.log_action('RESERVE', 'stock_reservations', v_id::text, jsonb_build_object('qty', c.qty_base));
  return jsonb_build_object('ok', true, 'reservation_id', v_id);
end $$;

create or replace function public.release_reservation(p_reservation_id uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_r public.stock_reservations;
begin
  select * into v_r from public.stock_reservations where id = p_reservation_id for update;
  if not found or v_r.status <> 'active' then perform private.fail('CS423', 'Reservation is not active'); end if;
  perform private.require_perm('stock.withdraw', v_r.warehouse_id);
  update public.stock_reservations set status = 'released', closed_at = now(),
         notes = concat_ws(E'\n', notes, 'Released: ' || coalesce(p_notes,'')) where id = p_reservation_id;
  perform private.log_action('RELEASE', 'stock_reservations', p_reservation_id::text, null);
  return jsonb_build_object('ok', true);
end $$;
