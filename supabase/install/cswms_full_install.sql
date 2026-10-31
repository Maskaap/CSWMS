-- CSWMS complete database install (Phases 1-5): all migrations in order.
-- Paste into the Supabase SQL Editor of an EMPTY project and run once.


-- ===== 20261023000100_foundation.sql =====
-- =============================================================================
-- CSWMS — Central Stock & Warehouse Management System
-- Migration 0100: Foundation
--   schemas, enums, settings, organisation hierarchy, products, units,
--   users / roles / permissions, audit history, document numbering.
-- =============================================================================

create schema if not exists private;    -- internal helpers, never exposed via the API
create schema if not exists integrity;  -- Daily Stock Integrity Monitor (protected)

revoke all on schema private from public;
revoke all on schema integrity from public;

-- -----------------------------------------------------------------------------
-- Enumerations
-- -----------------------------------------------------------------------------
create type public.stock_status as enum ('available', 'damaged', 'quarantine', 'in_transit');

create type public.txn_type as enum (
  'opening',               -- approved opening balance
  'receipt',               -- stock received from supplier / other source
  'withdrawal',            -- stock issued / consumed
  'return',                -- unused stock returned
  'move',                  -- immediate move between locations inside one warehouse (same owner)
  'transfer_dispatch',     -- stock leaves origin -> in transit
  'transfer_receipt',      -- stock arrives at destination
  'transfer_writeoff',     -- approved write-off of transfer shortage
  'adjustment',            -- authorised correction
  'stocktake_adjustment',  -- approved stocktake variance
  'status_change',         -- e.g. available -> damaged / quarantine
  'reversal'               -- documented reversal of an earlier transaction
);

create type public.txn_status as enum ('pending_approval', 'posted', 'rejected', 'cancelled');
create type public.location_kind as enum ('area', 'shelf', 'bin');
create type public.scope_type as enum ('group', 'company', 'branch', 'warehouse');
create type public.record_status as enum ('active', 'inactive', 'archived');

-- -----------------------------------------------------------------------------
-- Shared helpers
-- -----------------------------------------------------------------------------
create or replace function private.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Standard error helper so the application gets predictable error codes.
--   CS401 permission | CS409 insufficient stock | CS410 idempotency conflict
--   CS422 validation | CS423 invalid state     | CS428 confirmation required
create or replace function private.fail(p_code text, p_message text, p_detail jsonb default null)
returns void language plpgsql as $$
begin
  raise exception using errcode = p_code, message = p_message, detail = coalesce(p_detail::text, '');
end $$;

-- -----------------------------------------------------------------------------
-- Configurable business settings
-- -----------------------------------------------------------------------------
create table public.app_settings (
  key          text primary key,
  value        jsonb not null,
  description  text not null default '',
  category     text not null default 'general',
  updated_by   uuid,
  updated_at   timestamptz not null default now()
);

create or replace function private.setting(p_key text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select value from public.app_settings where key = p_key
$$;
create or replace function private.setting_num(p_key text, p_default numeric) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select (value #>> '{}')::numeric from public.app_settings where key = p_key), p_default)
$$;
create or replace function private.setting_text(p_key text, p_default text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select value #>> '{}' from public.app_settings where key = p_key), p_default)
$$;
create or replace function private.setting_bool(p_key text, p_default boolean) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select (value #>> '{}')::boolean from public.app_settings where key = p_key), p_default)
$$;

insert into public.app_settings (key, value, category, description) values
  ('business.currency',                    '"ZAR"',   'business',  'Currency for optional purchase prices'),
  ('business.timezone',                    '"Africa/Johannesburg"', 'business', 'Business time zone'),
  ('business.date_format',                 '"DD/MM/YYYY"', 'business', 'Display date format'),
  ('business.working_hours_start',         '"06:00"', 'business',  'Start of normal working hours (used to flag after-hours activity)'),
  ('business.working_hours_end',           '"19:00"', 'business',  'End of normal working hours'),
  ('withdraw.unusual_factor',              '5',       'controls',  'A withdrawal larger than this multiple of the 90-day average for the product at the warehouse requires reconfirmation'),
  ('withdraw.unusual_min_history',         '3',       'controls',  'Minimum number of previous withdrawals before the average is used'),
  ('withdraw.unusual_no_history_qty',      '0',       'controls',  'If set (>0): withdrawals above this base quantity require reconfirmation when there is no history. 0 = disabled'),
  ('adjust.approval_qty_threshold',        '20',      'controls',  'Adjustments with an absolute base quantity above this need management approval'),
  ('adjust.approval_pct_threshold',        '10',      'controls',  'Adjustments changing the balance by more than this percentage need management approval'),
  ('adjust.approval_value_threshold',      '2000',    'controls',  'Adjustments with a value (ZAR, uses purchase price) above this need management approval'),
  ('adjust.always_require_approval',       'false',   'controls',  'If true every manual adjustment requires approval'),
  ('stocktake.recount_variance_pct',       '10',      'stocktake', 'Lines with a variance above this percentage are flagged as unusual and recommended for recount'),
  ('transfer.default_transit_days',        '3',       'transfers', 'Default expected transit time for branch/warehouse transfers'),
  ('transfer.overdue_grace_hours',         '24',      'transfers', 'Hours after the expected arrival before a transfer is reported as overdue'),
  ('integrity.daily_run_time',             '"02:00"', 'integrity', 'Daily reconciliation time (Africa/Johannesburg, HH:MM)'),
  ('integrity.stale_after_hours',          '26',      'integrity', 'If no successful check within this many hours the status becomes GREY'),
  ('integrity.max_attempts_per_day',       '3',       'integrity', 'Automatic retries if the daily check fails'),
  ('integrity.repeat_window_minutes',      '5',       'integrity', 'Identical withdrawals by the same user within this window are reported as possible repeats'),
  ('integrity.unusual_adjustment_qty',     '100',     'integrity', 'Adjustments larger than this base quantity are reported as unusual'),
  ('integrity.after_hours_txn_threshold',  '10',      'integrity', 'Number of after-hours transactions by one user in a day that is reported as unusual activity'),
  ('integrity.escalate_abs_qty',           '50',      'integrity', 'Mismatches of at least this base quantity escalate to head office'),
  ('alerts.email_enabled',                 'false',   'alerts',    'Send alert e-mails through the outbox (requires e-mail provider configuration)'),
  ('alerts.daily_summary_enabled',         'true',    'alerts',    'Send a daily integrity summary to management'),
  ('auth.require_mfa_for_admins',          'true',    'security',  'Require multi-factor authentication for administrative roles');

-- -----------------------------------------------------------------------------
-- Organisation hierarchy:  Head Office -> Company -> Branch -> Warehouse -> Storage location (area/shelf/bin)
-- -----------------------------------------------------------------------------
create table public.organisation (
  id          boolean primary key default true check (id),   -- single row (Head Office)
  name        text not null,
  logo_url    text,
  updated_at  timestamptz not null default now()
);
insert into public.organisation (name) values ('CSWMS Group Head Office');

create table public.provinces (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null unique,
  status      public.record_status not null default 'active',
  created_at  timestamptz not null default now()
);
insert into public.provinces (code, name) values
  ('WC','Western Cape'), ('EC','Eastern Cape'), ('MP','Mpumalanga'), ('LP','Limpopo'), ('NC','Northern Cape'),
  ('GP','Gauteng'), ('KZN','KwaZulu-Natal'), ('FS','Free State'), ('NW','North West');

create table public.companies (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique check (code ~ '^[A-Z0-9][A-Z0-9_-]{1,19}$'),
  name                text not null,
  legal_name          text,
  registration_number text,
  vat_number          text,
  status              public.record_status not null default 'active',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table public.branches (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id),
  province_id  uuid not null references public.provinces(id),
  code         text not null unique check (code ~ '^[A-Z0-9][A-Z0-9_-]{1,19}$'),
  name         text not null,
  town         text,
  address      text,
  status       public.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index on public.branches(company_id);

create table public.warehouses (
  id          uuid primary key default gen_random_uuid(),
  branch_id   uuid not null references public.branches(id),
  code        text not null unique check (code ~ '^[A-Z0-9][A-Z0-9_-]{1,19}$'),
  name        text not null,
  status      public.record_status not null default 'active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on public.warehouses(branch_id);

create table public.storage_locations (
  id            uuid primary key default gen_random_uuid(),
  warehouse_id  uuid not null references public.warehouses(id),
  parent_id     uuid references public.storage_locations(id),
  kind          public.location_kind not null default 'area',
  code          text not null check (code ~ '^[A-Z0-9][A-Z0-9_.-]{0,29}$'),
  name          text not null,
  label_code    text not null unique,         -- printed on location barcode/QR labels
  is_default    boolean not null default false,
  status        public.record_status not null default 'active',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (warehouse_id, code)
);
create index on public.storage_locations(warehouse_id);
create unique index storage_locations_one_default on public.storage_locations(warehouse_id) where is_default;

-- parent must be in the same warehouse
create or replace function private.check_location_parent() returns trigger
language plpgsql as $$
declare v_wh uuid;
begin
  if new.parent_id is not null then
    select warehouse_id into v_wh from public.storage_locations where id = new.parent_id;
    if v_wh is distinct from new.warehouse_id then
      perform private.fail('CS422', 'A storage location''s parent must be in the same warehouse');
    end if;
    if new.parent_id = new.id then perform private.fail('CS422', 'A location cannot be its own parent'); end if;
  end if;
  if tg_op = 'UPDATE' and new.warehouse_id <> old.warehouse_id then
    perform private.fail('CS422', 'A storage location cannot be moved to another warehouse; create a new location instead');
  end if;
  return new;
end $$;
create trigger storage_locations_parent before insert or update on public.storage_locations
  for each row execute function private.check_location_parent();

-- every new warehouse gets a default receiving area so stock can always be placed somewhere
create or replace function private.create_default_location() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.storage_locations (warehouse_id, kind, code, name, label_code, is_default)
  values (new.id, 'area', 'GENERAL', 'General / Receiving area', 'LOC-' || new.code || '-GENERAL', true);
  return new;
end $$;
create trigger warehouses_default_location after insert on public.warehouses
  for each row execute function private.create_default_location();

-- warehouse/branch/company codes are permanent identifiers (they appear on labels and documents)
create or replace function private.protect_codes() returns trigger
language plpgsql as $$
begin
  if new.code <> old.code then
    perform private.fail('CS422', 'Codes are permanent identifiers and cannot be changed (' || tg_table_name || ')');
  end if;
  return new;
end $$;
create trigger companies_protect_code before update on public.companies for each row execute function private.protect_codes();
create trigger branches_protect_code  before update on public.branches  for each row execute function private.protect_codes();
create trigger warehouses_protect_code before update on public.warehouses for each row execute function private.protect_codes();
create trigger locations_protect_code before update on public.storage_locations for each row execute function private.protect_codes();

create or replace function private.protect_branch_company() returns trigger
language plpgsql as $$
begin
  if new.company_id <> old.company_id then
    perform private.fail('CS422', 'A branch cannot be moved to another company; stock ownership is tracked separately via transfers');
  end if;
  return new;
end $$;
create trigger branches_protect_company before update on public.branches for each row execute function private.protect_branch_company();

create or replace function private.protect_warehouse_branch() returns trigger
language plpgsql as $$
begin
  if new.branch_id <> old.branch_id then
    perform private.fail('CS422', 'A warehouse cannot be moved to another branch');
  end if;
  return new;
end $$;
create trigger warehouses_protect_branch before update on public.warehouses for each row execute function private.protect_warehouse_branch();

-- -----------------------------------------------------------------------------
-- Units of measurement, categories, suppliers, products
-- -----------------------------------------------------------------------------
create table public.uoms (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-Z0-9_]{1,12}$'),
  name        text not null,
  decimals    smallint not null default 0 check (decimals between 0 and 4),  -- allowed decimal places
  status      public.record_status not null default 'active',
  created_at  timestamptz not null default now()
);
insert into public.uoms (code, name, decimals) values
  ('EA','Each',0), ('ROLL','Roll',0), ('BOX','Box',0), ('PACK','Pack',0), ('CTN','Carton',0), ('PLT','Pallet',0),
  ('PAIR','Pair',0), ('SET','Set',0), ('BAG','Bag',0), ('DRUM','Drum',0), ('SHEET','Sheet',0),
  ('KG','Kilogram',3), ('G','Gram',1), ('T','Tonne',3), ('L','Litre',3), ('ML','Millilitre',0),
  ('M','Metre',2), ('M2','Square metre',2), ('M3','Cubic metre',3);

create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  parent_id   uuid references public.categories(id),
  code        text not null unique check (code ~ '^[A-Z0-9][A-Z0-9_-]{0,29}$'),
  name        text not null,
  status      public.record_status not null default 'active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on public.categories(parent_id);
insert into public.categories (code, name) values
  ('RAW','Raw materials'), ('CONS','Consumables'), ('PROD','Production materials'), ('PKG','Packaging'),
  ('FG','Finished goods'), ('SPARE','Spare parts'), ('EQUIP','Reusable tools & equipment');

create table public.suppliers (
  id          uuid primary key default gen_random_uuid(),
  code        text unique,
  name        text not null,
  contact     text,
  phone       text,
  email       text,
  status      public.record_status not null default 'active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.products (
  id                     uuid primary key default gen_random_uuid(),
  sku                    text not null check (sku ~ '^[A-Za-z0-9][A-Za-z0-9_./-]{0,39}$'),
  description            text not null check (length(trim(description)) >= 2),
  category_id            uuid references public.categories(id),
  base_uom_id            uuid not null references public.uoms(id),
  default_supplier_id    uuid references public.suppliers(id),
  image_path             text,
  is_asset               boolean not null default false,   -- reusable tools / equipment (asset check-out tracking)
  unusual_withdrawal_qty numeric(18,4) check (unusual_withdrawal_qty is null or unusual_withdrawal_qty > 0),
  notes                  text,
  status                 public.record_status not null default 'active',
  last_stocktake_at      timestamptz,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create unique index products_sku_unique on public.products (upper(sku));
create index products_desc_trgm_fallback on public.products (lower(description));
create index on public.products(category_id);

-- Purchase prices are kept apart from products so that row-level security can
-- restrict them to users holding cost.view (ZAR per base unit, optional).
create table public.product_costs (
  product_id      uuid primary key references public.products(id) on delete cascade,
  purchase_price  numeric(14,2) not null check (purchase_price >= 0),
  currency        text not null default 'ZAR',
  updated_by      uuid,
  updated_at      timestamptz not null default now()
);

-- The base unit cannot be changed once stock exists (it would silently change every quantity)
-- Enforced in migration 0200 once the ledger exists.

-- Pack / unit conversions:  1 <uom> = factor_to_base x <base uom>
create table public.product_uoms (
  id               uuid primary key default gen_random_uuid(),
  product_id       uuid not null references public.products(id) on delete cascade,
  uom_id           uuid not null references public.uoms(id),
  factor_to_base   numeric(18,6) not null check (factor_to_base > 0),
  is_default_issue boolean not null default false,
  created_at       timestamptz not null default now(),
  unique (product_id, uom_id)
);

create or replace function private.check_product_uom() returns trigger
language plpgsql as $$
declare v_base uuid;
begin
  select base_uom_id into v_base from public.products where id = new.product_id;
  if new.uom_id = v_base and new.factor_to_base <> 1 then
    perform private.fail('CS422', 'The conversion factor for the base unit must be 1');
  end if;
  return new;
end $$;
create trigger product_uoms_check before insert or update on public.product_uoms
  for each row execute function private.check_product_uom();

-- base-unit conversion row is maintained automatically
create or replace function private.ensure_base_uom_row() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.product_uoms (product_id, uom_id, factor_to_base)
  values (new.id, new.base_uom_id, 1)
  on conflict (product_id, uom_id) do nothing;
  return new;
end $$;
create trigger products_base_uom after insert or update of base_uom_id on public.products
  for each row execute function private.ensure_base_uom_row();

create table public.barcodes (
  id           uuid primary key default gen_random_uuid(),
  code         text not null check (length(code) between 3 and 64 and code !~ '\s'),
  product_id   uuid not null references public.products(id) on delete cascade,
  uom_id       uuid references public.uoms(id),  -- pack barcode (null = base unit)
  symbology    text not null default 'CODE128' check (symbology in ('CODE128','EAN13','EAN8','UPCA','QR','CODE39','ITF','DATAMATRIX','OTHER')),
  is_generated boolean not null default false,
  is_primary   boolean not null default false,
  created_at   timestamptz not null default now()
);
create unique index barcodes_code_unique on public.barcodes (code);  -- one barcode can only ever identify one product/pack
create unique index barcodes_one_primary on public.barcodes (product_id) where is_primary;
create index on public.barcodes(product_id);

create or replace function private.check_barcode_uom() returns trigger
language plpgsql as $$
begin
  if new.uom_id is not null and not exists (
       select 1 from public.product_uoms where product_id = new.product_id and uom_id = new.uom_id) then
    perform private.fail('CS422', 'A pack barcode must use a unit that has a conversion defined for the product');
  end if;
  if exists (select 1 from public.storage_locations where label_code = new.code) then
    perform private.fail('CS422', 'This code is already used as a storage-location label');
  end if;
  return new;
end $$;
create trigger barcodes_check before insert or update on public.barcodes
  for each row execute function private.check_barcode_uom();

-- Minimum / reorder quantities: per product, optionally per warehouse (warehouse row overrides the product default)
create table public.stock_thresholds (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products(id) on delete cascade,
  warehouse_id  uuid references public.warehouses(id),
  min_qty       numeric(18,4) not null default 0 check (min_qty >= 0),
  reorder_qty   numeric(18,4) not null default 0 check (reorder_qty >= 0),
  updated_at    timestamptz not null default now()
);
create unique index stock_thresholds_unique on public.stock_thresholds (product_id, coalesce(warehouse_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- Reason codes for withdrawals, adjustments, returns, status changes
create table public.reason_codes (
  id                  uuid primary key default gen_random_uuid(),
  kind                text not null check (kind in ('withdrawal','adjustment','return','status_change','transfer_writeoff')),
  code                text not null,
  label               text not null,
  requires_reference  boolean not null default false,
  status              public.record_status not null default 'active',
  unique (kind, code)
);
insert into public.reason_codes (kind, code, label, requires_reference) values
  ('withdrawal','PRODUCTION','Production job', true),
  ('withdrawal','CLIENT','Client / customer order', true),
  ('withdrawal','DEPARTMENT','Internal department use', true),
  ('withdrawal','MAINTENANCE','Maintenance / repairs', true),
  ('withdrawal','SAMPLE','Samples', false),
  ('withdrawal','DISPOSAL','Disposal / scrapping', false),
  ('withdrawal','OTHER','Other (explain in notes)', true),
  ('adjustment','COUNT_CORRECTION','Counting correction', false),
  ('adjustment','DAMAGE','Damaged / broken', false),
  ('adjustment','EXPIRED','Expired', false),
  ('adjustment','THEFT_LOSS','Theft / loss', false),
  ('adjustment','FOUND','Stock found', false),
  ('adjustment','DATA_ENTRY','Data entry error correction', true),
  ('adjustment','INTEGRITY','Integrity investigation outcome', true),
  ('return','UNUSED','Unused material returned', false),
  ('return','EXCESS','Excess issued', false),
  ('return','JOB_CANCELLED','Job cancelled', false),
  ('status_change','DAMAGED','Found damaged', false),
  ('status_change','QUARANTINE','Quarantine / inspection', false),
  ('status_change','RELEASED','Released back to available', false),
  ('transfer_writeoff','LOST_IN_TRANSIT','Lost in transit', false),
  ('transfer_writeoff','SHORT_SHIPPED','Short shipped by origin', false);

-- -----------------------------------------------------------------------------
-- Users, roles and permissions
-- -----------------------------------------------------------------------------
create table public.permissions (
  code         text primary key,
  description  text not null
);
insert into public.permissions (code, description) values
  ('stock.view',               'View stock balances and movements'),
  ('stock.receive',            'Receive stock'),
  ('stock.withdraw',           'Withdraw / issue stock'),
  ('stock.return',             'Return stock'),
  ('stock.move',               'Move stock between locations in a warehouse'),
  ('stock.transfer.dispatch',  'Create and dispatch transfers'),
  ('stock.transfer.receive',   'Receive incoming transfers'),
  ('stock.adjust',             'Request stock adjustments and status changes'),
  ('stock.approve',            'Approve adjustments, write-offs and other controlled stock changes'),
  ('stock.reverse',            'Reverse posted transactions (requires approval)'),
  ('stocktake.manage',         'Schedule, assign and manage stocktakes'),
  ('stocktake.count',          'Count stock in assigned stocktakes'),
  ('stocktake.approve',        'Approve and finalise stocktake variances'),
  ('product.manage',           'Create and edit products, categories, barcodes and thresholds'),
  ('setup.manage',             'Manage companies, branches, warehouses and locations'),
  ('import.manage',            'Prepare opening-stock imports'),
  ('import.approve',           'Approve opening balances'),
  ('users.manage',             'Manage users and role assignments'),
  ('reports.view',             'Run and export reports'),
  ('cost.view',                'View purchase prices and values'),
  ('integrity.view',           'View the Stock Integrity dashboard and findings'),
  ('integrity.investigate',    'Be assigned and update integrity investigations'),
  ('integrity.admin',          'Run integrity checks manually and manage monitor settings'),
  ('audit.view',               'View audit history'),
  ('settings.manage',          'Change business settings and thresholds'),
  ('alerts.receive',           'Receive operational alerts for the assigned scope'),
  ('alerts.escalation',        'Receive escalated (head office) alerts');

create table public.roles (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  name         text not null,
  description  text not null default '',
  permissions  text[] not null default '{}',
  requires_mfa boolean not null default false,
  is_system    boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create or replace function private.check_role_permissions() returns trigger
language plpgsql as $$
declare v_bad text;
begin
  select p into v_bad from unnest(new.permissions) p where p not in (select code from public.permissions) limit 1;
  if v_bad is not null then perform private.fail('CS422', 'Unknown permission: ' || v_bad); end if;
  return new;
end $$;
create trigger roles_check_permissions before insert or update on public.roles
  for each row execute function private.check_role_permissions();

insert into public.roles (code, name, description, permissions, requires_mfa, is_system) values
 ('SUPER_ADMIN', 'Super Administrator', 'Full system administration',
   array(select code from public.permissions), true, true),
 ('HEAD_OFFICE', 'Head Office Management', 'Group-wide stock visibility and approval access',
   array['stock.view','stock.approve','stock.reverse','stocktake.manage','stocktake.approve','import.approve','reports.view','cost.view',
         'integrity.view','integrity.investigate','integrity.admin','audit.view','alerts.receive','alerts.escalation','stock.adjust'], true, true),
 ('COMPANY_MANAGER', 'Company Manager', 'Manages an assigned company',
   array['stock.view','stock.receive','stock.withdraw','stock.return','stock.move','stock.transfer.dispatch','stock.transfer.receive',
         'stock.adjust','stock.approve','stock.reverse','stocktake.manage','stocktake.approve','product.manage','import.manage','import.approve',
         'reports.view','cost.view','integrity.view','integrity.investigate','audit.view','alerts.receive'], true, true),
 ('BRANCH_MANAGER', 'Branch Manager', 'Manages an assigned branch',
   array['stock.view','stock.receive','stock.withdraw','stock.return','stock.move','stock.transfer.dispatch','stock.transfer.receive',
         'stock.adjust','stock.approve','stocktake.manage','stocktake.approve','reports.view','cost.view','integrity.view',
         'integrity.investigate','audit.view','alerts.receive'], false, true),
 ('WAREHOUSE_SUPERVISOR', 'Warehouse Supervisor', 'Warehouse operations and approvals',
   array['stock.view','stock.receive','stock.withdraw','stock.return','stock.move','stock.transfer.dispatch','stock.transfer.receive',
         'stock.adjust','stock.approve','stocktake.manage','stocktake.count','reports.view','integrity.view','alerts.receive'], false, true),
 ('STOCK_CONTROLLER', 'Stock Controller', 'Receiving, withdrawing and transfers within permitted locations',
   array['stock.view','stock.receive','stock.withdraw','stock.return','stock.move','stock.transfer.dispatch','stock.transfer.receive','stock.adjust'], false, true),
 ('STOCKTAKE_COUNTER', 'Stocktake Counter', 'Counts stock in assigned stocktakes',
   array['stocktake.count'], false, true),
 ('AUDITOR', 'Auditor / Viewer', 'Authorised read-only reporting',
   array['stock.view','reports.view','cost.view','integrity.view','audit.view'], false, true);

create table public.app_users (
  id              uuid primary key,             -- = auth.users.id
  email           text not null,
  full_name       text not null,
  employee_number text unique,
  phone           text,
  is_active       boolean not null default true,
  last_seen_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index app_users_email on public.app_users (lower(email));

create table public.user_role_assignments (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.app_users(id) on delete cascade,
  role_id     uuid not null references public.roles(id),
  scope_type  public.scope_type not null,
  scope_id    uuid,                         -- null only for 'group'
  created_by  uuid,
  created_at  timestamptz not null default now(),
  check ((scope_type = 'group') = (scope_id is null))
);
create unique index ura_unique on public.user_role_assignments (user_id, role_id, scope_type, coalesce(scope_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index on public.user_role_assignments(user_id);

create or replace function private.check_scope_ref() returns trigger
language plpgsql as $$
begin
  if (new.scope_type = 'company'   and not exists (select 1 from public.companies  where id = new.scope_id))
  or (new.scope_type = 'branch'    and not exists (select 1 from public.branches   where id = new.scope_id))
  or (new.scope_type = 'warehouse' and not exists (select 1 from public.warehouses where id = new.scope_id)) then
    perform private.fail('CS422', 'Role scope does not reference an existing ' || new.scope_type);
  end if;
  return new;
end $$;
create trigger ura_check_scope before insert or update on public.user_role_assignments
  for each row execute function private.check_scope_ref();

-- Warehouse -> branch -> company lookup used by access checks
create or replace view private.warehouse_tree as
  select w.id as warehouse_id, w.code as warehouse_code, w.name as warehouse_name,
         b.id as branch_id, b.code as branch_code, b.name as branch_name,
         c.id as company_id, c.code as company_code, c.name as company_name,
         p.id as province_id, p.name as province_name
  from public.warehouses w
  join public.branches b on b.id = w.branch_id
  join public.companies c on c.id = b.company_id
  join public.provinces p on p.id = b.province_id;

-- ---- access helpers -------------------------------------------------------
create or replace function private.current_user_id() returns uuid
language sql stable as $$ select auth.uid() $$;

create or replace function private.is_active_user(p_user uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.app_users where id = p_user and is_active)
$$;

-- warehouses where the current user holds the permission
create or replace function private.my_warehouses(p_perm text) returns uuid[]
language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce(array_agg(distinct t.warehouse_id), '{}')
  from public.user_role_assignments a
  join public.roles r on r.id = a.role_id and p_perm = any(r.permissions)
  join public.app_users u on u.id = a.user_id and u.is_active
  join private.warehouse_tree t on
       a.scope_type = 'group'
    or (a.scope_type = 'company'   and t.company_id  = a.scope_id)
    or (a.scope_type = 'branch'    and t.branch_id   = a.scope_id)
    or (a.scope_type = 'warehouse' and t.warehouse_id = a.scope_id)
  where a.user_id = auth.uid()
$$;

-- companies where the current user holds the permission at company or group level
-- (used to see a company's stock that is stored in another company's warehouse)
create or replace function private.my_owner_companies(p_perm text) returns uuid[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(distinct c.id), '{}')
  from public.user_role_assignments a
  join public.roles r on r.id = a.role_id and p_perm = any(r.permissions)
  join public.app_users u on u.id = a.user_id and u.is_active
  join public.companies c on a.scope_type = 'group' or (a.scope_type = 'company' and c.id = a.scope_id)
  where a.user_id = auth.uid()
$$;

create or replace function private.has_perm(p_perm text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.user_role_assignments a
    join public.roles r on r.id = a.role_id and p_perm = any(r.permissions)
    join public.app_users u on u.id = a.user_id and u.is_active
    where a.user_id = auth.uid())
$$;

create or replace function private.has_group_perm(p_perm text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.user_role_assignments a
    join public.roles r on r.id = a.role_id and p_perm = any(r.permissions)
    join public.app_users u on u.id = a.user_id and u.is_active
    where a.user_id = auth.uid() and a.scope_type = 'group')
$$;

create or replace function private.has_wh_perm(p_perm text, p_warehouse uuid) returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select p_warehouse = any(private.my_warehouses(p_perm))
$$;

-- MFA: administrative roles require an aal2 session (Supabase MFA) when enabled
create or replace function private.mfa_satisfied() returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select case
    when not private.setting_bool('auth.require_mfa_for_admins', true) then true
    when not exists (
      select 1 from public.user_role_assignments a join public.roles r on r.id = a.role_id
      where a.user_id = auth.uid() and r.requires_mfa) then true
    else coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
  end
$$;

create or replace function private.require_perm(p_perm text, p_warehouse uuid default null) returns uuid
language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('CS401', 'Not signed in'); end if;
  if not private.is_active_user(v_uid) then perform private.fail('CS401', 'Your account is not active'); end if;
  if not private.mfa_satisfied() then perform private.fail('CS401', 'Multi-factor authentication is required for your role'); end if;
  if p_warehouse is null then
    if not private.has_perm(p_perm) then perform private.fail('CS401', 'You do not have permission: ' || p_perm); end if;
  else
    if not private.has_wh_perm(p_perm, p_warehouse) then
      perform private.fail('CS401', 'You do not have permission "' || p_perm || '" for this warehouse');
    end if;
  end if;
  return v_uid;
end $$;

-- -----------------------------------------------------------------------------
-- Permanent audit history (append-only)
-- -----------------------------------------------------------------------------
create table public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default clock_timestamp(),
  actor_id    uuid,
  action      text not null,          -- INSERT / UPDATE / DELETE / or business action e.g. LOGIN, APPROVE
  entity      text not null,
  entity_id   text,
  before      jsonb,
  after       jsonb,
  context     jsonb
);
create index audit_log_entity on public.audit_log (entity, entity_id);
create index audit_log_actor on public.audit_log (actor_id, at desc);
create index audit_log_at on public.audit_log (at desc);

create or replace function private.block_modification() returns trigger
language plpgsql as $$
begin
  raise exception using errcode = 'CS423',
    message = format('%s.%s is append-only: records cannot be changed or deleted', tg_table_schema, tg_table_name);
end $$;
create trigger audit_log_immutable before update or delete on public.audit_log
  for each row execute function private.block_modification();
create trigger audit_log_no_truncate before truncate on public.audit_log
  for each statement execute function private.block_modification();

create or replace function private.audit_row() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id text;
begin
  v_id := coalesce(
    case when tg_op = 'DELETE' then to_jsonb(old) ->> 'id' else to_jsonb(new) ->> 'id' end,
    case when tg_op = 'DELETE' then to_jsonb(old) ->> 'key' else to_jsonb(new) ->> 'key' end);
  insert into public.audit_log (actor_id, action, entity, entity_id, before, after)
  values (auth.uid(), tg_op, tg_table_name, v_id,
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create or replace function private.log_action(p_action text, p_entity text, p_entity_id text, p_context jsonb default null)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.audit_log (actor_id, action, entity, entity_id, context)
  values (auth.uid(), p_action, p_entity, p_entity_id, p_context)
$$;

do $$
declare t text;
begin
  foreach t in array array['app_settings','organisation','provinces','companies','branches','warehouses','storage_locations',
                           'uoms','categories','suppliers','products','product_costs','product_uoms','barcodes','stock_thresholds',
                           'reason_codes','roles','app_users','user_role_assignments']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function private.audit_row()',
                   t || '_audit', t);
  end loop;
  foreach t in array array['companies','branches','warehouses','storage_locations','categories','suppliers','products','roles','app_users']
  loop
    execute format('create trigger %I before update on public.%I for each row execute function private.touch_updated_at()',
                   t || '_touch', t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Human-readable document numbers (RCV-2026-000001, WDR-..., TRF-..., ...)
-- -----------------------------------------------------------------------------
create table private.doc_sequences (
  prefix  text not null,
  year    int  not null,
  last_no bigint not null default 0,
  primary key (prefix, year)
);

create or replace function private.next_doc_no(p_prefix text) returns text
language plpgsql security definer set search_path = private, pg_temp as $$
declare v_year int := extract(year from (now() at time zone 'Africa/Johannesburg'))::int; v_no bigint;
begin
  insert into private.doc_sequences as s (prefix, year, last_no) values (p_prefix, v_year, 1)
  on conflict (prefix, year) do update set last_no = s.last_no + 1
  returning last_no into v_no;
  return p_prefix || '-' || v_year || '-' || lpad(v_no::text, 6, '0');
end $$;


-- ===== 20261023000200_inventory_core.sql =====
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


-- ===== 20261023000300_opening_import.sql =====
-- =============================================================================
-- CSWMS Migration 0300: Initial inventory setup (opening stock import)
--   Method A (manual entry grid) and Method B (Excel/CSV) both create an import
--   batch.  Rows are validated server-side, can be corrected, are previewed,
--   submitted for approval and only then posted as auditable OPENING
--   transactions.  Re-importing the same file is blocked.
-- =============================================================================

create table public.import_batches (
  id              uuid primary key default gen_random_uuid(),
  batch_no        text not null unique,
  source          text not null check (source in ('file','manual')),
  file_name       text,
  file_sha256     text,
  status          text not null default 'draft'
                  check (status in ('draft','pending_approval','posted','rejected','cancelled')),
  row_count       int not null default 0,
  error_count     int not null default 0,
  warning_count   int not null default 0,
  validated_at    timestamptz,
  created_by      uuid not null,
  created_at      timestamptz not null default now(),
  submitted_at    timestamptz,
  decided_by      uuid,
  decided_at      timestamptz,
  decision_note   text,
  approval_id     uuid references public.approval_requests(id),
  posted_txn_ids  uuid[] not null default '{}'
);
-- the same file can never be posted (or be pending) twice
create unique index import_batches_file_once on public.import_batches (file_sha256)
  where file_sha256 is not null and status in ('pending_approval','posted');
create trigger import_batches_audit after insert or update on public.import_batches
  for each row execute function private.audit_row();

create table public.import_rows (
  id                uuid primary key default gen_random_uuid(),
  batch_id          uuid not null references public.import_batches(id) on delete cascade,
  row_no            int not null,
  excluded          boolean not null default false,
  raw               jsonb not null,
  sku               text,
  description       text,
  category          text,
  subcategory       text,
  barcode           text,
  uom               text,
  pack_uom          text,
  pack_factor       text,
  owner_company     text,
  branch            text,
  warehouse         text,
  location          text,
  qty               text,
  min_qty           text,
  reorder_qty       text,
  supplier          text,
  purchase_price    text,
  is_asset          text,
  -- resolved during validation
  product_id        uuid,
  warehouse_id      uuid,
  location_id       uuid,
  owner_company_id  uuid,
  uom_id            uuid,
  qty_num           numeric(18,4),
  errors            text[] not null default '{}',
  warnings          text[] not null default '{}',
  unique (batch_id, row_no)
);

create or replace function private.norm(p text) returns text
language sql immutable as $$ select nullif(trim(regexp_replace(coalesce(p,''), '\s+', ' ', 'g')), '') $$;

create or replace function private.norm_key(p text) returns text
language sql immutable as $$ select nullif(regexp_replace(lower(coalesce(p,'')), '[^a-z0-9]', '', 'g'), '') $$;

create or replace function private.try_numeric(p text) returns numeric
language plpgsql immutable as $$
begin
  if p is null or trim(p) = '' then return null; end if;
  return replace(replace(trim(p), ' ', ''), ',', '.')::numeric;   -- accepts 1 234,5 style
exception when others then
  return 'NaN'::numeric;
end $$;

create or replace function private.import_row_from_json(p_batch uuid, p_row_no int, j jsonb) returns void
language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  insert into public.import_rows (batch_id, row_no, raw, sku, description, category, subcategory, barcode, uom, pack_uom,
     pack_factor, owner_company, branch, warehouse, location, qty, min_qty, reorder_qty, supplier, purchase_price, is_asset)
  values (p_batch, p_row_no, j,
     private.norm(j ->> 'sku'), private.norm(j ->> 'description'), private.norm(j ->> 'category'),
     private.norm(j ->> 'subcategory'), private.norm(j ->> 'barcode'), upper(private.norm(j ->> 'uom')),
     upper(private.norm(j ->> 'pack_uom')), private.norm(j ->> 'pack_factor'), upper(private.norm(j ->> 'company')),
     upper(private.norm(j ->> 'branch')), upper(private.norm(j ->> 'warehouse')), upper(private.norm(j ->> 'location')),
     private.norm(j ->> 'qty'), private.norm(j ->> 'min_qty'), private.norm(j ->> 'reorder_qty'),
     private.norm(j ->> 'supplier'), private.norm(j ->> 'purchase_price'), lower(private.norm(j ->> 'is_asset')));
end $$;

-- -----------------------------------------------------------------------------
-- Validation (re-runnable; never writes stock)
-- -----------------------------------------------------------------------------
create or replace function private.import_validate(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  r public.import_rows; e text[]; w text[];
  v_prod public.products; v_uom public.uoms; v_qty numeric; v_n numeric; v_wh public.warehouses; v_br_code text;
  v_loc uuid; v_owner uuid; v_pack uuid; v_errs int; v_warns int; v_bar_prod uuid;
begin
  for r in select * from public.import_rows where batch_id = p_batch and not excluded order by row_no loop
    e := '{}'; w := '{}';
    v_prod := null; v_wh := null; v_loc := null; v_owner := null; v_qty := null; v_uom := null;

    -- product identity ----------------------------------------------------------------
    if r.sku is null then e := e || 'Stock code / SKU is missing'::text;
    elsif r.sku !~ '^[A-Za-z0-9][A-Za-z0-9_./-]{0,39}$' then
      e := e || 'Stock code contains invalid characters (use letters, digits, - _ . /; max 40)'::text;
    else
      select * into v_prod from public.products where upper(sku) = upper(r.sku);
    end if;
    if r.description is null and v_prod.id is null then e := e || 'Product description is missing'::text; end if;
    if v_prod.id is not null then
      if r.description is not null and private.norm_key(r.description) <> private.norm_key(v_prod.description) then
        w := w || format('SKU already exists as "%s" — the existing product will be used', v_prod.description);
      end if;
      if v_prod.status <> 'active' then e := e || 'Existing product with this SKU is not active'::text; end if;
    end if;

    -- unit of measurement ---------------------------------------------------------------
    if v_prod.id is not null then
      select * into v_uom from public.uoms where id = v_prod.base_uom_id;
      if r.uom is not null and r.uom <> v_uom.code then
        e := e || format('Unit %s differs from the existing product''s base unit %s', r.uom, v_uom.code);
      end if;
    elsif r.uom is null then e := e || 'Unit of measurement is missing'::text;
    else
      select * into v_uom from public.uoms where code = r.uom or upper(name) = r.uom;
      if v_uom.id is null then e := e || format('Unknown unit of measurement "%s"', r.uom); end if;
    end if;

    if r.pack_uom is not null or r.pack_factor is not null then
      select id into v_pack from public.uoms where code = r.pack_uom or upper(name) = r.pack_uom;
      v_n := private.try_numeric(r.pack_factor);
      if v_pack is null then e := e || format('Unknown pack unit "%s"', coalesce(r.pack_uom, ''));
      elsif v_n is null or v_n = 'NaN' or v_n <= 0 then e := e || 'Pack conversion factor must be a number greater than zero'::text;
      elsif v_pack = v_uom.id and v_n <> 1 then e := e || 'Pack unit equals the base unit but the factor is not 1'::text;
      elsif v_prod.id is not null and exists (select 1 from public.product_uoms where product_id = v_prod.id and uom_id = v_pack and factor_to_base <> v_n) then
        e := e || 'Pack conversion conflicts with the existing conversion for this product'::text;
      end if;
    end if;

    -- location -----------------------------------------------------------------------------
    if r.warehouse is null then e := e || 'Warehouse code is missing'::text;
    else
      select * into v_wh from public.warehouses where code = r.warehouse;
      if v_wh.id is null then e := e || format('Unknown warehouse "%s"', r.warehouse);
      elsif v_wh.status <> 'active' then e := e || format('Warehouse %s is not active', r.warehouse);
      else
        if r.branch is not null then
          select code into v_br_code from public.branches where id = v_wh.branch_id;
          if v_br_code <> r.branch then e := e || format('Warehouse %s does not belong to branch %s', r.warehouse, r.branch); end if;
        end if;
        if r.location is null then v_loc := private.default_location(v_wh.id);
        else
          select id into v_loc from public.storage_locations where warehouse_id = v_wh.id and (code = r.location or label_code = r.location) and status = 'active';
          if v_loc is null then e := e || format('Unknown storage location "%s" in warehouse %s (create it under Company & Warehouse Setup)', r.location, r.warehouse); end if;
        end if;
      end if;
    end if;

    if r.owner_company is null then
      if v_wh.id is not null then v_owner := private.warehouse_company(v_wh.id); end if;
    else
      select id into v_owner from public.companies where code = r.owner_company and status = 'active';
      if v_owner is null then e := e || format('Unknown owner company "%s"', r.owner_company); end if;
    end if;

    -- quantities ---------------------------------------------------------------------------
    v_qty := private.try_numeric(r.qty);
    if v_qty is null then e := e || 'Opening quantity is missing (enter 0 if there is no stock)'::text;
    elsif v_qty = 'NaN' then e := e || format('Opening quantity "%s" is not a number', r.qty);
    elsif v_qty < 0 then e := e || 'Negative opening balances are not allowed'::text; v_qty := null;
    elsif v_uom.id is not null and trunc(v_qty, v_uom.decimals) <> v_qty then
      e := e || format('Unit %s only allows %s decimal place(s)', v_uom.code, v_uom.decimals); v_qty := null;
    elsif v_qty = 0 then w := w || 'Quantity is zero — the product will be set up without stock'::text;
    elsif v_qty > 100000000 then e := e || 'Opening quantity is unrealistically large'::text;
    end if;
    if v_qty = 'NaN' then v_qty := null; end if;

    v_n := private.try_numeric(r.min_qty);
    if v_n = 'NaN' or v_n < 0 then e := e || 'Minimum quantity must be zero or a positive number'::text; end if;
    v_n := private.try_numeric(r.reorder_qty);
    if v_n = 'NaN' or v_n < 0 then e := e || 'Reorder quantity must be zero or a positive number'::text; end if;
    v_n := private.try_numeric(r.purchase_price);
    if v_n = 'NaN' or v_n < 0 then e := e || 'Purchase price must be zero or a positive number'::text; end if;
    if r.is_asset is not null and r.is_asset not in ('yes','no','y','n','true','false','1','0') then
      e := e || 'Asset flag must be Yes or No'::text;
    end if;

    -- barcode ------------------------------------------------------------------------------
    if r.barcode is not null then
      if r.barcode ~ '\s' or length(r.barcode) < 3 or length(r.barcode) > 64 then
        e := e || 'Barcode must be 3–64 characters without spaces'::text;
      else
        select product_id into v_bar_prod from public.barcodes where code = r.barcode;
        if v_bar_prod is not null and v_bar_prod is distinct from v_prod.id then
          e := e || format('Barcode %s is already assigned to another product (%s)', r.barcode,
                           (select sku from public.products where id = v_bar_prod));
        end if;
        if exists (select 1 from public.storage_locations where label_code = r.barcode) then
          e := e || 'Barcode is already used as a storage-location label'::text;
        end if;
      end if;
    end if;

    -- existing stock: opening balances only for keys with no history ----------------------
    if v_prod.id is not null and v_loc is not null and v_owner is not null and coalesce(v_qty, 0) > 0
       and exists (select 1 from public.stock_ledger where product_id = v_prod.id and location_id = v_loc and owner_company_id = v_owner) then
      e := e || 'Stock movements already exist for this product at this location — use Receive Stock or an adjustment instead'::text;
    end if;

    -- category -------------------------------------------------------------------------------
    if r.category is not null and not exists (select 1 from public.categories where upper(code) = upper(r.category) or lower(name) = lower(r.category)) then
      w := w || format('Category "%s" does not exist and will be created', r.category);
    end if;
    if r.subcategory is not null and r.category is null then e := e || 'A subcategory needs a category'::text; end if;

    if r.supplier is not null and not exists (select 1 from public.suppliers where lower(name) = lower(r.supplier) or upper(code) = upper(r.supplier)) then
      w := w || format('Supplier "%s" does not exist and will be created', r.supplier);
    end if;

    -- possible duplicate product: same description as an existing product with another SKU
    if r.description is not null and v_prod.id is null and exists (
         select 1 from public.products p where private.norm_key(p.description) = private.norm_key(r.description)) then
      w := w || format('Possible duplicate product: an existing product (%s) has the same description',
                       (select string_agg(sku, ', ') from public.products p where private.norm_key(p.description) = private.norm_key(r.description)));
    end if;

    update public.import_rows set errors = e, warnings = w, product_id = v_prod.id, warehouse_id = v_wh.id,
           location_id = v_loc, owner_company_id = v_owner, uom_id = v_uom.id, qty_num = v_qty
    where id = r.id;
  end loop;

  -- cross-row checks --------------------------------------------------------------------------
  -- same product counted twice at the same location/owner -> double counting
  update public.import_rows ir set errors = ir.errors || format('Duplicate row: SKU %s at this location already appears on row(s) %s', ir.sku, d.others)
  from (select a.id, string_agg(b.row_no::text, ', ' order by b.row_no) as others
        from public.import_rows a join public.import_rows b
          on b.batch_id = a.batch_id and b.id <> a.id and not b.excluded
         and upper(b.sku) = upper(a.sku) and b.location_id = a.location_id and b.owner_company_id = a.owner_company_id
        where a.batch_id = p_batch and not a.excluded group by a.id) d
  where ir.id = d.id;

  -- conflicting descriptions for one new SKU
  update public.import_rows ir set errors = ir.errors || 'The same SKU has different descriptions on other rows'::text
  where ir.batch_id = p_batch and not ir.excluded and ir.product_id is null and exists (
    select 1 from public.import_rows b where b.batch_id = p_batch and not b.excluded and b.id <> ir.id
      and upper(b.sku) = upper(ir.sku) and b.description is not null and ir.description is not null
      and private.norm_key(b.description) <> private.norm_key(ir.description));

  -- conflicting units for one new SKU
  update public.import_rows ir set errors = ir.errors || 'The same SKU has different units on other rows'::text
  where ir.batch_id = p_batch and not ir.excluded and exists (
    select 1 from public.import_rows b where b.batch_id = p_batch and not b.excluded and b.id <> ir.id
      and upper(b.sku) = upper(ir.sku) and b.uom is distinct from ir.uom and b.uom is not null and ir.uom is not null);

  -- the same barcode on different SKUs
  update public.import_rows ir set errors = ir.errors || format('Barcode %s is used for different SKUs in this file', ir.barcode)
  where ir.batch_id = p_batch and not ir.excluded and ir.barcode is not null and exists (
    select 1 from public.import_rows b where b.batch_id = p_batch and not b.excluded and b.barcode = ir.barcode
      and upper(b.sku) <> upper(ir.sku));

  -- two new SKUs with the same description -> possible duplicate products
  update public.import_rows ir set warnings = ir.warnings || format('Possible duplicate product: same description as SKU %s', d.other_sku)
  from (select distinct on (a.id) a.id, b.sku as other_sku
        from public.import_rows a join public.import_rows b on b.batch_id = a.batch_id and not b.excluded
         and upper(b.sku) <> upper(a.sku) and private.norm_key(b.description) = private.norm_key(a.description)
        where a.batch_id = p_batch and not a.excluded) d
  where ir.id = d.id;

  -- the same key already pending in another batch awaiting approval
  update public.import_rows ir set errors = ir.errors || format('This item/location is already in import batch %s awaiting approval', ob.batch_no)
  from public.import_rows o join public.import_batches ob on ob.id = o.batch_id and ob.status = 'pending_approval'
  where ir.batch_id = p_batch and not ir.excluded and o.batch_id <> p_batch and not o.excluded
    and upper(o.sku) = upper(ir.sku) and o.location_id = ir.location_id and o.owner_company_id = ir.owner_company_id;

  select count(*) filter (where cardinality(errors) > 0), count(*) filter (where cardinality(warnings) > 0)
    into v_errs, v_warns from public.import_rows where batch_id = p_batch and not excluded;
  update public.import_batches set error_count = v_errs, warning_count = v_warns, validated_at = now(),
         row_count = (select count(*) from public.import_rows where batch_id = p_batch and not excluded)
  where id = p_batch;
  return jsonb_build_object('errors', v_errs, 'warnings', v_warns,
                            'rows', (select count(*) from public.import_rows where batch_id = p_batch and not excluded));
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API
-- -----------------------------------------------------------------------------
create or replace function public.import_create_batch(p_source text, p_rows jsonb, p_file_name text default null, p_file_sha256 text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_id uuid; v_no text; j jsonb; i int := 0; v_prev text; v_summary jsonb;
begin
  v_uid := private.require_perm('import.manage');
  if p_source not in ('file','manual') then perform private.fail('CS422', 'Invalid source'); end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    perform private.fail('CS422', 'The import contains no rows');
  end if;
  if jsonb_array_length(p_rows) > 20000 then perform private.fail('CS422', 'Maximum 20 000 rows per batch — split the file'); end if;
  if p_file_sha256 is not null then
    select batch_no || ' (' || status || ')' into v_prev from public.import_batches
    where file_sha256 = p_file_sha256 and status in ('pending_approval','posted') limit 1;
    if v_prev is not null then
      perform private.fail('CS423', 'This exact file has already been imported: batch ' || v_prev || '. Repeat imports are blocked.');
    end if;
  end if;

  v_no := private.next_doc_no('IMP');
  insert into public.import_batches (batch_no, source, file_name, file_sha256, created_by)
  values (v_no, p_source, p_file_name, p_file_sha256, v_uid) returning id into v_id;
  for j in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    perform private.import_row_from_json(v_id, coalesce((j ->> '_row')::int, i + 1), j);
  end loop;
  v_summary := private.import_validate(v_id);
  return jsonb_build_object('ok', true, 'batch_id', v_id, 'batch_no', v_no) || v_summary;
end $$;

create or replace function private.import_editable(p_batch uuid) returns uuid
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_b public.import_batches; v_uid uuid;
begin
  v_uid := private.require_perm('import.manage');
  select * into v_b from public.import_batches where id = p_batch for update;
  if not found then perform private.fail('CS422', 'Import batch not found'); end if;
  if v_b.status <> 'draft' then perform private.fail('CS423', 'Batch ' || v_b.batch_no || ' is ' || v_b.status || ' and can no longer be edited'); end if;
  return v_uid;
end $$;

create or replace function public.import_update_row(p_batch_id uuid, p_row_id uuid, p_values jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_row public.import_rows; v_merged jsonb;
begin
  perform private.import_editable(p_batch_id);
  select * into v_row from public.import_rows where id = p_row_id and batch_id = p_batch_id;
  if not found then perform private.fail('CS422', 'Row not found'); end if;
  v_merged := v_row.raw || p_values;
  delete from public.import_rows where id = p_row_id;
  perform private.import_row_from_json(p_batch_id, v_row.row_no, v_merged);
  return private.import_validate(p_batch_id);
end $$;

create or replace function public.import_set_excluded(p_batch_id uuid, p_row_id uuid, p_excluded boolean)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  perform private.import_editable(p_batch_id);
  update public.import_rows set excluded = p_excluded where id = p_row_id and batch_id = p_batch_id;
  return private.import_validate(p_batch_id);
end $$;

create or replace function public.import_add_rows(p_batch_id uuid, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare j jsonb; v_max int;
begin
  perform private.import_editable(p_batch_id);
  select coalesce(max(row_no), 1) into v_max from public.import_rows where batch_id = p_batch_id;
  for j in select * from jsonb_array_elements(p_rows) loop
    v_max := v_max + 1;
    perform private.import_row_from_json(p_batch_id, v_max, j);
  end loop;
  return private.import_validate(p_batch_id);
end $$;

create or replace function public.import_revalidate(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  perform private.import_editable(p_batch_id);
  return private.import_validate(p_batch_id);
end $$;

create or replace function public.import_submit(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_sum jsonb; v_b public.import_batches; v_appr uuid; v_qty numeric;
begin
  v_uid := private.import_editable(p_batch_id);
  v_sum := private.import_validate(p_batch_id);
  if (v_sum ->> 'errors')::int > 0 then
    perform private.fail('CS422', 'Correct all errors before submitting (' || (v_sum ->> 'errors') || ' row(s) with errors)');
  end if;
  if (v_sum ->> 'rows')::int = 0 then perform private.fail('CS422', 'Nothing to submit'); end if;
  select * into v_b from public.import_batches where id = p_batch_id;
  select coalesce(sum(qty_num), 0) into v_qty from public.import_rows where batch_id = p_batch_id and not excluded;
  begin
    update public.import_batches set status = 'pending_approval', submitted_at = now() where id = p_batch_id;
  exception when unique_violation then
    perform private.fail('CS423', 'This exact file has already been submitted or imported');
  end;
  v_appr := private.create_approval('opening_balance', 'import.approve', null,
     format('Opening balances %s — %s rows', v_b.batch_no, v_sum ->> 'rows'),
     jsonb_build_object('batch_no', v_b.batch_no, 'rows', v_sum -> 'rows', 'warnings', v_sum -> 'warnings'),
     null, null, null, p_batch_id);
  update public.import_batches set approval_id = v_appr where id = p_batch_id;
  return jsonb_build_object('ok', true, 'status', 'pending_approval', 'approval_id', v_appr);
end $$;

create or replace function public.import_cancel(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  perform private.import_editable(p_batch_id);
  update public.import_batches set status = 'cancelled', decided_at = now(), decided_by = auth.uid() where id = p_batch_id;
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

create or replace function private.category_for_import(p_cat text, p_sub text) returns uuid
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_cat uuid; v_sub uuid; v_code text;
begin
  if p_cat is null then return null; end if;
  select id into v_cat from public.categories where parent_id is null and (upper(code) = upper(p_cat) or lower(name) = lower(p_cat)) limit 1;
  if v_cat is null then
    v_code := left(upper(regexp_replace(p_cat, '[^A-Za-z0-9]+', '-', 'g')), 24);
    v_code := trim(both '-' from v_code);
    if v_code = '' or v_code !~ '^[A-Z0-9]' then v_code := 'CAT' || v_code; end if;
    while exists (select 1 from public.categories where code = v_code) loop v_code := left(v_code, 24) || '-' || floor(random()*1000)::int; end loop;
    insert into public.categories (code, name) values (v_code, p_cat) returning id into v_cat;
  end if;
  if p_sub is null then return v_cat; end if;
  select id into v_sub from public.categories where parent_id = v_cat and (upper(code) = upper(p_sub) or lower(name) = lower(p_sub)) limit 1;
  if v_sub is null then
    v_code := left(upper(regexp_replace(p_sub, '[^A-Za-z0-9]+', '-', 'g')), 20);
    v_code := trim(both '-' from v_code);
    v_code := (select code from public.categories where id = v_cat) || '-' || coalesce(nullif(v_code, ''), 'SUB');
    v_code := left(v_code, 30);
    while exists (select 1 from public.categories where code = v_code) loop v_code := left(v_code, 25) || '-' || floor(random()*1000)::int; end loop;
    insert into public.categories (parent_id, code, name) values (v_cat, v_code, p_sub) returning id into v_sub;
  end if;
  return v_sub;
end $$;

-- approve (true) / reject (false) / cancel (null)
create or replace function private.import_decision(p_batch uuid, p_approve boolean, p_uid uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_b public.import_batches; v_sum jsonb; r public.import_rows; v_prod uuid; v_sup uuid; v_pack uuid; v_txn public.stock_transactions;
  v_wh uuid; v_moves jsonb; i int; v_txns uuid[] := '{}'; v_n numeric;
begin
  select * into v_b from public.import_batches where id = p_batch for update;
  if v_b.status <> 'pending_approval' then perform private.fail('CS423', 'Batch is not awaiting approval'); end if;

  if p_approve is null or not p_approve then
    update public.import_batches set status = case when p_approve is null then 'cancelled' else 'rejected' end,
           decided_by = p_uid, decided_at = now(), decision_note = p_note where id = p_batch;
    return jsonb_build_object('batch_status', case when p_approve is null then 'cancelled' else 'rejected' end);
  end if;

  -- the approver must hold import.approve for every warehouse in the batch
  if exists (select 1 from public.import_rows where batch_id = p_batch and not excluded
             and not (warehouse_id = any(private.my_warehouses('import.approve')))) then
    perform private.fail('CS401', 'This batch contains warehouses you are not authorised to approve opening balances for');
  end if;

  -- re-validate at the moment of approval (stock may have been posted in the meantime)
  update public.import_batches set status = 'draft' where id = p_batch;   -- temporarily, so the pending-duplicate check ignores itself
  v_sum := private.import_validate(p_batch);
  update public.import_batches set status = 'pending_approval' where id = p_batch;
  if (v_sum ->> 'errors')::int > 0 then
    perform private.fail('CS422', 'The batch no longer validates (' || (v_sum ->> 'errors') || ' error rows). Reject it and re-import.');
  end if;

  -- 1. master data
  for r in select * from public.import_rows where batch_id = p_batch and not excluded order by row_no loop
    v_prod := r.product_id;
    if v_prod is null then
      select id into v_prod from public.products where upper(sku) = upper(r.sku);
    end if;
    if r.supplier is not null then
      select id into v_sup from public.suppliers where lower(name) = lower(r.supplier) or upper(code) = upper(r.supplier) limit 1;
      if v_sup is null then insert into public.suppliers (name) values (r.supplier) returning id into v_sup; end if;
    else v_sup := null; end if;
    if v_prod is null then
      insert into public.products (sku, description, category_id, base_uom_id, default_supplier_id, is_asset, created_by)
      values (r.sku, r.description, private.category_for_import(r.category, r.subcategory), r.uom_id, v_sup,
              coalesce(r.is_asset in ('yes','y','true','1'), false), p_uid)
      returning id into v_prod;
    end if;
    if private.try_numeric(r.purchase_price) is not null then
      insert into public.product_costs (product_id, purchase_price, updated_by)
      values (v_prod, private.try_numeric(r.purchase_price), p_uid)
      on conflict (product_id) do nothing;
    end if;
    update public.import_rows set product_id = v_prod where id = r.id;
    if r.pack_uom is not null then
      select id into v_pack from public.uoms where code = r.pack_uom or upper(name) = r.pack_uom;
      insert into public.product_uoms (product_id, uom_id, factor_to_base) values (v_prod, v_pack, private.try_numeric(r.pack_factor))
      on conflict (product_id, uom_id) do nothing;
    end if;
    if r.barcode is not null then
      insert into public.barcodes (code, product_id, is_primary)
      values (r.barcode, v_prod, not exists (select 1 from public.barcodes where product_id = v_prod and is_primary))
      on conflict (code) do nothing;
    end if;
    v_n := private.try_numeric(r.min_qty);
    if v_n is not null or private.try_numeric(r.reorder_qty) is not null then
      insert into public.stock_thresholds (product_id, warehouse_id, min_qty, reorder_qty)
      values (v_prod, r.warehouse_id, coalesce(v_n, 0), coalesce(private.try_numeric(r.reorder_qty), 0))
      on conflict (product_id, coalesce(warehouse_id, '00000000-0000-0000-0000-000000000000'::uuid))
      do update set min_qty = excluded.min_qty, reorder_qty = excluded.reorder_qty, updated_at = now();
    end if;
  end loop;

  -- 2. one OPENING transaction per warehouse
  for v_wh in select distinct warehouse_id from public.import_rows where batch_id = p_batch and not excluded and qty_num > 0 loop
    v_txn := private.new_txn('opening', 'pending_approval', v_wh, gen_random_uuid(), null, v_b.batch_no,
                             'Opening balances approved from import ' || v_b.batch_no, null, null, null, null, p_batch);
    v_moves := '[]'; i := 0;
    for r in select * from public.import_rows where batch_id = p_batch and not excluded and warehouse_id = v_wh and qty_num > 0 order by row_no loop
      i := i + 1;
      insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status, qty_base,
             entered_qty, entered_uom_id, factor, extra)
      values (v_txn.id, i, r.product_id, r.location_id, r.owner_company_id, 'available', r.qty_num, r.qty_num, r.uom_id, 1,
              jsonb_build_object('import_row', r.row_no));
      if private.try_numeric(r.purchase_price) is not null then
        insert into public.txn_line_costs (txn_id, line_no, unit_cost) values (v_txn.id, i, private.try_numeric(r.purchase_price));
      end if;
      v_moves := v_moves || jsonb_build_object('line_no', i, 'product_id', r.product_id, 'location_id', r.location_id,
         'owner_company_id', r.owner_company_id, 'status', 'available', 'qty_delta', r.qty_num, 'entered_qty', r.qty_num,
         'entered_uom_id', r.uom_id, 'factor', 1);
    end loop;
    perform private.post_movements(v_txn.id, v_moves, p_uid);
    v_txns := v_txns || v_txn.id;
  end loop;

  update public.import_batches set status = 'posted', decided_by = p_uid, decided_at = now(), decision_note = p_note,
         posted_txn_ids = v_txns where id = p_batch;
  return jsonb_build_object('batch_status', 'posted', 'transactions', to_jsonb(v_txns));
end $$;


-- ===== 20261023000400_stocktake.sql =====
-- =============================================================================
-- CSWMS Migration 0400: Monthly physical stocktake
--   schedule -> assign -> start (cut-off snapshot) -> count (blind) -> close &
--   compare -> flag discrepancies -> recount -> submit -> approve -> finalise
--
--   Expected quantities are the physical on-hand (available + damaged +
--   quarantine) per product and location at the cut-off.  Legitimate
--   movements between the cut-off and the time a line was counted are added,
--   so normal operations can continue during counting.
-- =============================================================================

create table public.stocktakes (
  id               uuid primary key default gen_random_uuid(),
  stocktake_no     text not null unique,
  name             text not null,
  period           text not null check (period ~ '^\d{4}-(0[1-9]|1[0-2])$'),   -- YYYY-MM (monthly)
  warehouse_id     uuid not null references public.warehouses(id),
  category_ids     uuid[],        -- optional scope filter (includes sub-categories)
  location_ids     uuid[],        -- optional scope filter (includes child locations)
  blind            boolean not null default true,
  due_date         date not null,
  status           text not null default 'scheduled'
                   check (status in ('scheduled','counting','review','pending_approval','finalised','cancelled')),
  cutoff_at        timestamptz,
  started_by       uuid,
  counting_closed_at timestamptz,
  submitted_at     timestamptz,
  approval_id      uuid references public.approval_requests(id),
  finalised_at     timestamptz,
  finalised_by     uuid,
  adjustment_txn_id uuid references public.stock_transactions(id),
  notes            text,
  created_by       uuid not null,
  created_at       timestamptz not null default now()
);
create index on public.stocktakes (period);
create index on public.stocktakes (warehouse_id, status);
create unique index stocktakes_one_active_full on public.stocktakes (warehouse_id)
  where status in ('counting','review','pending_approval') and category_ids is null and location_ids is null;

alter table public.stock_transactions add constraint stock_transactions_stocktake_fk foreign key (stocktake_id) references public.stocktakes(id);
alter table public.approval_requests add constraint approval_requests_stocktake_fk foreign key (stocktake_id) references public.stocktakes(id);
alter table public.approval_requests add constraint approval_requests_import_fk foreign key (import_batch_id) references public.import_batches(id);

create table public.stocktake_assignments (
  id            uuid primary key default gen_random_uuid(),
  stocktake_id  uuid not null references public.stocktakes(id) on delete cascade,
  user_id       uuid not null references public.app_users(id),
  location_ids  uuid[],
  assigned_by   uuid not null,
  assigned_at   timestamptz not null default now(),
  unique (stocktake_id, user_id)
);

create table public.stocktake_lines (
  id                   uuid primary key default gen_random_uuid(),
  stocktake_id         uuid not null references public.stocktakes(id),
  product_id           uuid not null references public.products(id),
  location_id          uuid not null references public.storage_locations(id),
  expected_qty         numeric(18,4) not null default 0,      -- at cut-off
  is_unexpected        boolean not null default false,        -- counted but not in the cut-off snapshot
  current_round        int not null default 1,
  counted_qty          numeric(18,4),                          -- null = NOT COUNTED (0 = counted zero)
  counted_at           timestamptz,
  first_count_qty      numeric(18,4),
  movement_since_cutoff numeric(18,4) not null default 0,
  adjusted_expected    numeric(18,4),
  variance             numeric(18,4),
  line_status          text not null default 'pending'
                       check (line_status in ('pending','counted','recount_requested','recounted','not_counted')),
  flags                text[] not null default '{}',
  recount_reason       text,
  unique (stocktake_id, product_id, location_id)
);
create index on public.stocktake_lines (stocktake_id, line_status);

create table public.stocktake_counts (
  id                 uuid primary key default gen_random_uuid(),
  stocktake_id       uuid not null references public.stocktakes(id),
  line_id            uuid not null references public.stocktake_lines(id),
  round              int not null,
  qty_base           numeric(18,4) not null check (qty_base >= 0),
  entered_qty        numeric(18,4) not null,
  entered_uom_id     uuid not null references public.uoms(id),
  counted_by         uuid not null,
  counted_at         timestamptz not null default clock_timestamp(),
  client_request_id  uuid not null unique,
  voided             boolean not null default false,
  voided_by          uuid,
  voided_at          timestamptz,
  void_reason        text
);
create index on public.stocktake_counts (line_id, round);

-- count entries are append-only except for a single, explained void
create or replace function private.protect_counts() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then perform private.fail('CS423', 'Count entries cannot be deleted; void them with a reason'); end if;
  if old.voided or (to_jsonb(new) - array['voided','voided_by','voided_at','void_reason']) <> (to_jsonb(old) - array['voided','voided_by','voided_at','void_reason'])
     or not new.voided or coalesce(trim(new.void_reason),'') = '' then
    perform private.fail('CS423', 'Count entries can only be voided once, with a reason');
  end if;
  return new;
end $$;
create trigger stocktake_counts_protect before update or delete on public.stocktake_counts
  for each row execute function private.protect_counts();

create trigger stocktakes_audit after insert or update on public.stocktakes for each row execute function private.audit_row();
create trigger stocktake_assignments_audit after insert or update or delete on public.stocktake_assignments for each row execute function private.audit_row();

-- -----------------------------------------------------------------------------
-- helpers
-- -----------------------------------------------------------------------------
create or replace function private.category_tree(p_ids uuid[]) returns uuid[]
language sql stable security definer set search_path = public, pg_temp as $$
  with recursive t(id) as (
    select id from public.categories where id = any(p_ids)
    union select c.id from public.categories c join t on c.parent_id = t.id)
  select coalesce(array_agg(id), '{}') from t
$$;

create or replace function private.location_tree(p_ids uuid[]) returns uuid[]
language sql stable security definer set search_path = public, pg_temp as $$
  with recursive t(id) as (
    select id from public.storage_locations where id = any(p_ids)
    union select l.id from public.storage_locations l join t on l.parent_id = t.id)
  select coalesce(array_agg(id), '{}') from t
$$;

create or replace function private.stocktake_in_scope(p_st public.stocktakes, p_product uuid, p_location uuid) returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select (p_st.category_ids is null or (select category_id from public.products where id = p_product) = any(private.category_tree(p_st.category_ids)))
     and (p_st.location_ids is null or p_location = any(private.location_tree(p_st.location_ids)))
     and exists (select 1 from public.storage_locations where id = p_location and warehouse_id = p_st.warehouse_id)
$$;

-- physical on-hand from the ledger as at a moment (available + damaged + quarantine)
create or replace function private.physical_qty_at(p_product uuid, p_location uuid, p_at timestamptz) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(qty_delta), 0) from public.stock_ledger
  where product_id = p_product and location_id = p_location and status <> 'in_transit' and posted_at <= p_at
$$;

create or replace function private.physical_movement_between(p_product uuid, p_location uuid, p_from timestamptz, p_to timestamptz)
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(qty_delta), 0) from public.stock_ledger
  where product_id = p_product and location_id = p_location and status <> 'in_transit'
    and posted_at > p_from and posted_at <= p_to
    and txn_type <> 'stocktake_adjustment'
$$;

create or replace function private.can_count(p_st public.stocktakes, p_location uuid) returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select private.has_wh_perm('stocktake.manage', p_st.warehouse_id)
      or (private.has_wh_perm('stocktake.count', p_st.warehouse_id)
          and (not exists (select 1 from public.stocktake_assignments where stocktake_id = p_st.id)
               or exists (select 1 from public.stocktake_assignments a where a.stocktake_id = p_st.id and a.user_id = auth.uid()
                          and (a.location_ids is null or p_location = any(private.location_tree(a.location_ids))))))
      or exists (select 1 from public.stocktake_assignments a
                 join public.user_role_assignments ura on ura.user_id = a.user_id
                 join public.roles r on r.id = ura.role_id and 'stocktake.count' = any(r.permissions)
                 where a.stocktake_id = p_st.id and a.user_id = auth.uid()
                   and (a.location_ids is null or p_location = any(private.location_tree(a.location_ids))))
$$;

-- -----------------------------------------------------------------------------
-- PUBLIC API
-- -----------------------------------------------------------------------------
-- Schedules one stocktake per warehouse in the chosen scope
create or replace function public.schedule_stocktakes(
  p_scope_type text, p_scope_id uuid, p_period text, p_due_date date,
  p_blind boolean default true, p_category_ids uuid[] default null, p_location_ids uuid[] default null,
  p_name text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; w record; v_ids uuid[] := '{}'; v_id uuid; v_count int := 0;
begin
  v_uid := private.require_perm('stocktake.manage');
  if p_due_date is null then perform private.fail('CS422', 'A due date is required'); end if;
  if p_location_ids is not null and p_scope_type <> 'warehouse' then
    perform private.fail('CS422', 'Location filters can only be used when scheduling a single warehouse');
  end if;
  for w in select t.* from private.warehouse_tree t join public.warehouses wh on wh.id = t.warehouse_id and wh.status = 'active'
           where (p_scope_type = 'group')
              or (p_scope_type = 'company' and t.company_id = p_scope_id)
              or (p_scope_type = 'branch' and t.branch_id = p_scope_id)
              or (p_scope_type = 'warehouse' and t.warehouse_id = p_scope_id) loop
    if not private.has_wh_perm('stocktake.manage', w.warehouse_id) then
      perform private.fail('CS401', 'You cannot schedule stocktakes for warehouse ' || w.warehouse_code);
    end if;
    insert into public.stocktakes (stocktake_no, name, period, warehouse_id, category_ids, location_ids, blind, due_date, notes, created_by)
    values (private.next_doc_no('STK'),
            coalesce(nullif(trim(p_name),''), 'Monthly stocktake ' || p_period) || ' — ' || w.warehouse_code,
            p_period, w.warehouse_id, p_category_ids, p_location_ids, coalesce(p_blind, true), p_due_date, p_notes, v_uid)
    returning id into v_id;
    v_ids := v_ids || v_id; v_count := v_count + 1;
  end loop;
  if v_count = 0 then perform private.fail('CS422', 'No active warehouses in the selected scope'); end if;
  return jsonb_build_object('ok', true, 'created', v_count, 'stocktake_ids', to_jsonb(v_ids));
end $$;

create or replace function public.assign_stocktake(p_stocktake_id uuid, p_user_id uuid, p_location_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes; v_uid uuid;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id;
  if not found then perform private.fail('CS422', 'Stocktake not found'); end if;
  v_uid := private.require_perm('stocktake.manage', v_st.warehouse_id);
  if v_st.status in ('finalised','cancelled') then perform private.fail('CS423', 'Stocktake is closed'); end if;
  if not exists (select 1 from public.app_users where id = p_user_id and is_active) then perform private.fail('CS422', 'Unknown or inactive user'); end if;
  insert into public.stocktake_assignments (stocktake_id, user_id, location_ids, assigned_by)
  values (p_stocktake_id, p_user_id, p_location_ids, v_uid)
  on conflict (stocktake_id, user_id) do update set location_ids = excluded.location_ids, assigned_by = excluded.assigned_by, assigned_at = now();
  insert into public.notifications (user_id, title, body, link)
  values (p_user_id, 'Stocktake assigned: ' || v_st.stocktake_no, 'You have been assigned to count ' || v_st.name || ' (due ' || to_char(v_st.due_date, 'DD/MM/YYYY') || ')',
          '/stocktake/' || p_stocktake_id || '/count');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.unassign_stocktake(p_stocktake_id uuid, p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id;
  perform private.require_perm('stocktake.manage', v_st.warehouse_id);
  delete from public.stocktake_assignments where stocktake_id = p_stocktake_id and user_id = p_user_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.start_stocktake(p_stocktake_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes; v_uid uuid; v_cut timestamptz; v_lines int;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id for update;
  if not found then perform private.fail('CS422', 'Stocktake not found'); end if;
  v_uid := private.require_perm('stocktake.manage', v_st.warehouse_id);
  if v_st.status <> 'scheduled' then perform private.fail('CS423', 'Stocktake has already been started'); end if;

  -- Consistent cut-off: wait for in-flight postings to commit, then snapshot.
  -- Every ledger row inserted after this lock is released has posted_at > cut-off.
  lock table public.stock_balances in share mode;
  v_cut := clock_timestamp();

  insert into public.stocktake_lines (stocktake_id, product_id, location_id, expected_qty)
  select v_st.id, b.product_id, b.location_id, sum(b.qty)
  from public.stock_balances b
  where b.warehouse_id = v_st.warehouse_id and b.status <> 'in_transit'
    and private.stocktake_in_scope(v_st, b.product_id, b.location_id)
  group by b.product_id, b.location_id
  having sum(b.qty) <> 0 or exists (select 1 from public.stock_ledger l where l.product_id = b.product_id and l.location_id = b.location_id);
  get diagnostics v_lines = row_count;

  update public.stocktakes set status = 'counting', cutoff_at = v_cut, started_by = v_uid where id = p_stocktake_id;
  perform private.resolve_alert('stocktake_due:' || p_stocktake_id, 'Started');
  return jsonb_build_object('ok', true, 'cutoff_at', v_cut, 'lines', v_lines);
end $$;

-- Count entry: scan / select product + location, enter the quantity counted.
-- Several entries for the same line in the same round are added together.
create or replace function public.record_count(
  p_request_id uuid, p_stocktake_id uuid, p_product_id uuid, p_location_id uuid, p_qty numeric, p_uom_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_st public.stocktakes; v_line public.stocktake_lines; v_uid uuid := auth.uid(); c record; v_round int; v_total numeric;
  v_existing public.stocktake_counts; v_dup boolean;
begin
  select * into v_existing from public.stocktake_counts where client_request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'count_id', v_existing.id);
  end if;
  if v_uid is null or not private.is_active_user(v_uid) then perform private.fail('CS401', 'Not signed in'); end if;
  select * into v_st from public.stocktakes where id = p_stocktake_id;
  if not found then perform private.fail('CS422', 'Stocktake not found'); end if;
  if not private.can_count(v_st, p_location_id) then
    perform private.fail('CS401', 'You are not assigned to count this stocktake / location');
  end if;
  if v_st.status not in ('counting','review') then
    perform private.fail('CS423', 'Counting is not open for this stocktake (' || v_st.status || ')');
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
    if v_st.status <> 'counting' then perform private.fail('CS423', 'New items can only be added while counting is open'); end if;
    insert into public.stocktake_lines (stocktake_id, product_id, location_id, expected_qty, is_unexpected)
    values (p_stocktake_id, p_product_id, p_location_id, private.physical_qty_at(p_product_id, p_location_id, v_st.cutoff_at), true)
    on conflict (stocktake_id, product_id, location_id) do nothing;
    select * into v_line from public.stocktake_lines
    where stocktake_id = p_stocktake_id and product_id = p_product_id and location_id = p_location_id for update;
  end if;
  if v_st.status = 'review' and v_line.line_status <> 'recount_requested' then
    perform private.fail('CS423', 'Counting is closed. Only lines with a requested recount can be counted.');
  end if;
  v_round := v_line.current_round;

  -- possible duplicate entry: same user, same quantity, same line, within 60 seconds
  select exists (select 1 from public.stocktake_counts where line_id = v_line.id and round = v_round and not voided
                 and counted_by = v_uid and qty_base = c.qty_base and counted_at > clock_timestamp() - interval '60 seconds')
    into v_dup;

  insert into public.stocktake_counts (stocktake_id, line_id, round, qty_base, entered_qty, entered_uom_id, counted_by, client_request_id)
  values (p_stocktake_id, v_line.id, v_round, c.qty_base, p_qty, c.uom_id, v_uid, p_request_id);

  select sum(qty_base) into v_total from public.stocktake_counts where line_id = v_line.id and round = v_round and not voided;
  update public.stocktake_lines set counted_qty = v_total, counted_at = clock_timestamp(),
         first_count_qty = case when v_round = 1 then v_total else first_count_qty end,
         line_status = case when v_round = 1 then 'counted' else 'recounted' end,
         flags = case when v_dup and not ('possible_duplicate_entry' = any(flags)) then flags || 'possible_duplicate_entry'::text else flags end
  where id = v_line.id;

  return jsonb_build_object('ok', true, 'duplicate', false, 'line_id', v_line.id, 'line_total', v_total, 'round', v_round,
                            'possible_duplicate_entry', v_dup, 'unexpected', v_line.is_unexpected);
end $$;

create or replace function public.void_count(p_count_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_c public.stocktake_counts; v_st public.stocktakes; v_total numeric; v_line public.stocktake_lines;
begin
  select * into v_c from public.stocktake_counts where id = p_count_id;
  if not found then perform private.fail('CS422', 'Count entry not found'); end if;
  select * into v_st from public.stocktakes where id = v_c.stocktake_id;
  if v_c.counted_by <> auth.uid() and not private.has_wh_perm('stocktake.manage', v_st.warehouse_id) then
    perform private.fail('CS401', 'Only the counter or a stocktake manager can void a count entry');
  end if;
  if v_st.status not in ('counting','review') then perform private.fail('CS423', 'Stocktake is closed'); end if;
  if coalesce(trim(p_reason),'') = '' then perform private.fail('CS422', 'A reason is required'); end if;
  update public.stocktake_counts set voided = true, voided_by = auth.uid(), voided_at = now(), void_reason = p_reason where id = p_count_id;
  select * into v_line from public.stocktake_lines where id = v_c.line_id for update;
  select sum(qty_base) into v_total from public.stocktake_counts where line_id = v_c.line_id and round = v_line.current_round and not voided;
  update public.stocktake_lines set counted_qty = v_total,
         line_status = case when v_total is null then (case when current_round = 1 then 'pending' else 'recount_requested' end) else line_status end
  where id = v_c.line_id;
  return jsonb_build_object('ok', true, 'line_total', v_total);
end $$;

-- Count sheet for counters: expected quantities are hidden for blind counts
create or replace function public.stocktake_count_sheet(p_stocktake_id uuid)
returns table (line_id uuid, product_id uuid, sku text, description text, uom text, location_id uuid, location_code text,
               counted_qty numeric, line_status text, current_round int, expected_qty numeric, is_unexpected boolean)
language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes; v_show boolean;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id;
  if not found then perform private.fail('CS422', 'Stocktake not found'); end if;
  if not (private.can_count(v_st, private.default_location(v_st.warehouse_id))
          or private.has_wh_perm('stocktake.approve', v_st.warehouse_id)
          or exists (select 1 from public.stocktake_assignments where stocktake_id = p_stocktake_id and user_id = auth.uid())) then
    perform private.fail('CS401', 'You are not assigned to this stocktake');
  end if;
  v_show := not v_st.blind or private.has_wh_perm('stocktake.manage', v_st.warehouse_id)
            or private.has_wh_perm('stocktake.approve', v_st.warehouse_id);
  return query
  select l.id, l.product_id, p.sku, p.description, u.code, l.location_id, sl.code, l.counted_qty, l.line_status, l.current_round,
         case when v_show then l.expected_qty end, l.is_unexpected
  from public.stocktake_lines l
  join public.products p on p.id = l.product_id
  join public.uoms u on u.id = p.base_uom_id
  join public.storage_locations sl on sl.id = l.location_id
  where l.stocktake_id = p_stocktake_id
    and (exists (select 1 from public.stocktake_assignments a where a.stocktake_id = p_stocktake_id and a.user_id = auth.uid()
                 and a.location_ids is not null) is false
         or l.location_id = any(private.location_tree((select location_ids from public.stocktake_assignments
                                                         where stocktake_id = p_stocktake_id and user_id = auth.uid()))))
  order by sl.code, p.sku;
end $$;

-- Recompute comparison and discrepancy flags (used when closing counting and after recounts)
create or replace function private.stocktake_compare(p_stocktake_id uuid) returns jsonb
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes; l record; v_mov numeric; v_flags text[]; v_pct numeric := private.setting_num('stocktake.recount_variance_pct', 10);
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id;
  for l in select * from public.stocktake_lines where stocktake_id = p_stocktake_id for update loop
    v_flags := array(select f from unnest(l.flags) f where f in ('possible_duplicate_entry'));
    if l.counted_qty is null then
      update public.stocktake_lines set line_status = case when line_status in ('pending') then 'not_counted' else line_status end,
             movement_since_cutoff = 0, adjusted_expected = null, variance = null, flags = v_flags || 'not_counted'::text
      where id = l.id;
      continue;
    end if;
    v_mov := private.physical_movement_between(l.product_id, l.location_id, v_st.cutoff_at, l.counted_at);
    if l.counted_qty - (l.expected_qty + v_mov) < 0 then v_flags := v_flags || 'missing'::text; end if;
    if l.counted_qty - (l.expected_qty + v_mov) > 0 then v_flags := v_flags || 'additional'::text; end if;
    if l.is_unexpected then v_flags := v_flags || 'unexpected_product'::text; end if;
    if l.counted_qty <> l.expected_qty + v_mov and
       abs(l.counted_qty - (l.expected_qty + v_mov)) / greatest(l.expected_qty + v_mov, 1) * 100 > v_pct then
      v_flags := v_flags || 'unusual_variance'::text;
    end if;
    update public.stocktake_lines set movement_since_cutoff = v_mov, adjusted_expected = expected_qty + v_mov,
           variance = counted_qty - (expected_qty + v_mov), flags = v_flags
    where id = l.id;
  end loop;

  -- stock at the wrong location: shortage at one location and surplus at another for the same product
  update public.stocktake_lines a set flags = a.flags || 'possible_wrong_location'::text
  where a.stocktake_id = p_stocktake_id and a.variance <> 0
    and exists (select 1 from public.stocktake_lines b where b.stocktake_id = a.stocktake_id and b.product_id = a.product_id
                and b.location_id <> a.location_id and b.variance is not null and sign(b.variance) = -sign(a.variance));

  return (select jsonb_build_object(
     'lines', count(*), 'counted', count(*) filter (where counted_qty is not null),
     'not_counted', count(*) filter (where counted_qty is null),
     'discrepancies', count(*) filter (where variance <> 0),
     'missing', count(*) filter (where variance < 0), 'additional', count(*) filter (where variance > 0),
     'recount_requested', count(*) filter (where line_status = 'recount_requested'))
   from public.stocktake_lines where stocktake_id = p_stocktake_id);
end $$;

create or replace function public.close_stocktake_counting(p_stocktake_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes; v_res jsonb;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id for update;
  if not found then perform private.fail('CS422', 'Stocktake not found'); end if;
  perform private.require_perm('stocktake.manage', v_st.warehouse_id);
  if v_st.status <> 'counting' then perform private.fail('CS423', 'Stocktake is not in counting'); end if;
  update public.stocktakes set status = 'review', counting_closed_at = now() where id = p_stocktake_id;
  v_res := private.stocktake_compare(p_stocktake_id);
  return jsonb_build_object('ok', true) || v_res;
end $$;

create or replace function public.request_recount(p_stocktake_id uuid, p_line_ids uuid[], p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes; v_n int;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id for update;
  perform private.require_perm('stocktake.manage', v_st.warehouse_id);
  if v_st.status <> 'review' then perform private.fail('CS423', 'Recounts can be requested while the stocktake is under review'); end if;
  update public.stocktake_lines set line_status = 'recount_requested', current_round = current_round + 1,
         counted_qty = null, counted_at = null, recount_reason = p_reason
  where stocktake_id = p_stocktake_id and id = any(p_line_ids);
  get diagnostics v_n = row_count;
  perform private.log_action('RECOUNT_REQUESTED', 'stocktakes', p_stocktake_id::text, jsonb_build_object('lines', v_n, 'reason', p_reason));
  return jsonb_build_object('ok', true, 'lines', v_n);
end $$;

create or replace function public.refresh_stocktake_comparison(p_stocktake_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id;
  perform private.require_perm('stocktake.manage', v_st.warehouse_id);
  if v_st.status <> 'review' then perform private.fail('CS423', 'Stocktake is not under review'); end if;
  return private.stocktake_compare(p_stocktake_id);
end $$;

create or replace function public.submit_stocktake(p_stocktake_id uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes; v_sum jsonb; v_appr uuid;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id for update;
  perform private.require_perm('stocktake.manage', v_st.warehouse_id);
  if v_st.status <> 'review' then perform private.fail('CS423', 'Only stocktakes under review can be submitted'); end if;
  v_sum := private.stocktake_compare(p_stocktake_id);
  if (v_sum ->> 'recount_requested')::int > 0 then
    perform private.fail('CS423', 'Recounts are still outstanding (' || (v_sum ->> 'recount_requested') || ' lines)');
  end if;
  update public.stocktakes set status = 'pending_approval', submitted_at = now(),
         notes = coalesce(nullif(trim(p_notes),''), notes) where id = p_stocktake_id;
  v_appr := private.create_approval('stocktake', 'stocktake.approve', v_st.warehouse_id,
     format('Stocktake %s — %s discrepancies, %s not counted', v_st.stocktake_no, v_sum ->> 'discrepancies', v_sum ->> 'not_counted'),
     v_sum, null, null, p_stocktake_id);
  update public.stocktakes set approval_id = v_appr where id = p_stocktake_id;
  if (v_sum ->> 'discrepancies')::int > 0 then
    perform private.raise_alert('stocktake_discrepancy', 'warning', 'Stocktake discrepancies: ' || v_st.stocktake_no,
       format('%s line(s) differ from the system (%s missing, %s additional). Awaiting approval.',
              v_sum ->> 'discrepancies', v_sum ->> 'missing', v_sum ->> 'additional'),
       'stocktake_discrepancy:' || p_stocktake_id, null, v_st.warehouse_id, null, null, null, 'stocktake', p_stocktake_id::text,
       false, '/stocktake/' || p_stocktake_id);
  end if;
  return jsonb_build_object('ok', true, 'status', 'pending_approval', 'approval_id', v_appr) || v_sum;
end $$;

-- approve (true) / reject (false: back to review) / cancel (null: back to review)
create or replace function private.stocktake_decision(p_stocktake_id uuid, p_approve boolean, p_uid uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_st public.stocktakes; l record; b record; v_txn public.stocktake_lines; v_t public.stock_transactions;
  v_moves jsonb := '[]'; v_remaining numeric; v_take numeric; i int := 0; v_primary uuid; v_sum jsonb;
  v_unit uuid;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id for update;
  if v_st.status <> 'pending_approval' then perform private.fail('CS423', 'Stocktake is not awaiting approval'); end if;
  if p_approve is null or not p_approve then
    update public.stocktakes set status = 'review', approval_id = null,
           notes = concat_ws(E'\n', notes, case when p_approve is null then 'Submission cancelled: ' else 'Rejected: ' end || coalesce(p_note,''))
    where id = p_stocktake_id;
    return jsonb_build_object('stocktake_status', 'review');
  end if;

  v_t := private.new_txn('stocktake_adjustment', 'pending_approval', v_st.warehouse_id, gen_random_uuid(), null,
                         v_st.stocktake_no, 'Approved stocktake variances ' || v_st.stocktake_no || coalesce(' — ' || p_note, ''),
                         null, null, null, p_stocktake_id);

  for l in select * from public.stocktake_lines where stocktake_id = p_stocktake_id and variance is not null and variance <> 0
           order by product_id, location_id loop
    select base_uom_id into v_unit from public.products where id = l.product_id;
    if l.variance > 0 then
      -- surplus goes to available stock of the owner holding most stock here (else the warehouse's company)
      select owner_company_id into v_primary from public.stock_balances
      where product_id = l.product_id and location_id = l.location_id and status <> 'in_transit'
      order by qty desc, (owner_company_id = private.warehouse_company(v_st.warehouse_id)) desc limit 1;
      v_primary := coalesce(v_primary, private.warehouse_company(v_st.warehouse_id));
      i := i + 1;
      insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status, qty_base,
             entered_qty, entered_uom_id, factor, extra)
      values (v_t.id, i, l.product_id, l.location_id, v_primary, 'available', l.variance, l.variance, v_unit, 1,
              jsonb_build_object('stocktake_line_id', l.id));
      v_moves := v_moves || jsonb_build_object('line_no', i, 'product_id', l.product_id, 'location_id', l.location_id,
          'owner_company_id', v_primary, 'status', 'available', 'qty_delta', l.variance, 'entered_qty', l.variance,
          'entered_uom_id', v_unit, 'factor', 1);
    else
      -- shortage is taken from available first, then damaged, then quarantine; warehouse company's stock first
      v_remaining := -l.variance;
      for b in select * from public.stock_balances
               where product_id = l.product_id and location_id = l.location_id and status <> 'in_transit' and qty > 0
               order by case status when 'available' then 1 when 'damaged' then 2 else 3 end,
                        (owner_company_id = private.warehouse_company(v_st.warehouse_id)) desc, qty desc loop
        exit when v_remaining <= 0;
        v_take := least(b.qty, v_remaining);
        v_remaining := v_remaining - v_take;
        i := i + 1;
        insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status, qty_base,
               entered_qty, entered_uom_id, factor, extra)
        values (v_t.id, i, l.product_id, l.location_id, b.owner_company_id, b.status, -v_take, -v_take, v_unit, 1,
                jsonb_build_object('stocktake_line_id', l.id));
        v_moves := v_moves || jsonb_build_object('line_no', i, 'product_id', l.product_id, 'location_id', l.location_id,
            'owner_company_id', b.owner_company_id, 'status', b.status, 'qty_delta', -v_take, 'entered_qty', -v_take,
            'entered_uom_id', v_unit, 'factor', 1);
      end loop;
      if v_remaining > 0 then
        perform private.fail('CS409', format('Cannot post the shortage for %s: the current balance is lower than the variance. Refresh the comparison and recount.',
                             (select sku from public.products where id = l.product_id)));
      end if;
    end if;
  end loop;

  if i > 0 then
    perform private.post_movements(v_t.id, v_moves, p_uid);
  else
    update public.stock_transactions set status = 'cancelled', notes = 'No variances to post' where id = v_t.id;
  end if;

  update public.products set last_stocktake_at = now()
  where id in (select product_id from public.stocktake_lines where stocktake_id = p_stocktake_id and counted_qty is not null);
  update public.stocktakes set status = 'finalised', finalised_at = now(), finalised_by = p_uid,
         adjustment_txn_id = case when i > 0 then v_t.id end where id = p_stocktake_id;
  perform private.resolve_alert('stocktake_discrepancy:' || p_stocktake_id, 'Finalised');
  perform private.resolve_alert('stocktake_overdue:' || p_stocktake_id, 'Finalised');
  return jsonb_build_object('stocktake_status', 'finalised', 'adjustment_txn_id', case when i > 0 then v_t.id end, 'adjusted_lines', i);
end $$;

create or replace function public.cancel_stocktake(p_stocktake_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_st public.stocktakes;
begin
  select * into v_st from public.stocktakes where id = p_stocktake_id for update;
  perform private.require_perm('stocktake.manage', v_st.warehouse_id);
  if v_st.status in ('finalised','cancelled','pending_approval') then
    perform private.fail('CS423', 'This stocktake cannot be cancelled in status ' || v_st.status);
  end if;
  if coalesce(trim(p_reason),'') = '' then perform private.fail('CS422', 'A reason is required'); end if;
  update public.stocktakes set status = 'cancelled', notes = concat_ws(E'\n', notes, 'Cancelled: ' || p_reason) where id = p_stocktake_id;
  perform private.resolve_alert('stocktake_due:' || p_stocktake_id, 'Cancelled');
  perform private.resolve_alert('stocktake_overdue:' || p_stocktake_id, 'Cancelled');
  return jsonb_build_object('ok', true);
end $$;

-- daily: reminders & overdue alerts
create or replace function private.stocktake_reminders() returns void
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare s record; v_today date := (now() at time zone 'Africa/Johannesburg')::date;
begin
  for s in select * from public.stocktakes where status in ('scheduled','counting','review','pending_approval') loop
    if s.due_date < v_today then
      perform private.raise_alert('stocktake_overdue', 'warning', 'Stocktake overdue: ' || s.stocktake_no,
        format('%s was due on %s and is still %s.', s.name, to_char(s.due_date, 'DD/MM/YYYY'), replace(s.status, '_', ' ')),
        'stocktake_overdue:' || s.id, null, s.warehouse_id, null, null, null, 'stocktake', s.id::text, false, '/stocktake/' || s.id);
    elsif s.status = 'scheduled' and s.due_date <= v_today + 3 then
      perform private.raise_alert('stocktake_due', 'info', 'Stocktake due soon: ' || s.stocktake_no,
        format('%s is due on %s and has not been started.', s.name, to_char(s.due_date, 'DD/MM/YYYY')),
        'stocktake_due:' || s.id, null, s.warehouse_id, null, null, null, 'stocktake', s.id::text, false, '/stocktake/' || s.id);
    end if;
  end loop;
end $$;


-- ===== 20261023000500_integrity_monitor.sql =====
-- =============================================================================
-- CSWMS Migration 0500: DAILY STOCK INTEGRITY MONITOR
--
--   An independent, scheduled process that re-derives every stock balance from
--   the immutable ledger and verifies the stored balances, transactions,
--   transfers, hashes and checkpoints.  It produces findings, alerts and an
--   evidence trail.
--
--   IT NEVER CHANGES STOCK.  While a check is running, any attempt to change a
--   balance raises an error (see private.log_balance_change guard below), and
--   the monitor has no code path that writes to balances or the ledger.
--   Corrections are made by people, through authorised, auditable adjustments.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Guard: the monitor can never modify balances
-- -----------------------------------------------------------------------------
create or replace function private.log_balance_change() returns trigger
language plpgsql security definer set search_path = private, public, pg_temp as $$
declare v_txn uuid := nullif(current_setting('cswms.posting_txn', true), '')::uuid;
begin
  if current_setting('cswms.integrity_running', true) = '1' then
    raise exception using errcode = 'CS423', message = 'The integrity monitor is not permitted to change stock balances';
  end if;
  if tg_op = 'UPDATE' and new.qty = old.qty and new.product_id = old.product_id
     and new.location_id = old.location_id and new.owner_company_id = old.owner_company_id
     and new.status = old.status and new.warehouse_id = old.warehouse_id then
    return new;
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

-- the same guard for the ledger insert path
create or replace function private.ledger_before_insert() returns trigger
language plpgsql as $$
begin
  if current_setting('cswms.integrity_running', true) = '1' then
    raise exception using errcode = 'CS423', message = 'The integrity monitor is not permitted to write ledger entries';
  end if;
  new.row_hash := private.ledger_row_hash(new);
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- Tables (schema "integrity" is not exposed through the API)
-- -----------------------------------------------------------------------------
create table integrity.runs (
  id                     uuid primary key default gen_random_uuid(),
  run_no                 text not null unique,
  trigger                text not null check (trigger in ('scheduled','retry','manual','test')),
  business_date          date not null,
  status                 text not null check (status in ('running','completed','failed')),
  result                 text check (result in ('passed','warnings','discrepancies')),
  started_at             timestamptz not null default clock_timestamp(),
  finished_at            timestamptz,
  started_by             uuid,
  keys_checked           bigint not null default 0,
  products_checked       bigint not null default 0,
  locations_checked      bigint not null default 0,
  warehouses_checked     bigint not null default 0,
  companies_checked      bigint not null default 0,
  ledger_rows_checked    bigint not null default 0,
  transactions_checked   bigint not null default 0,
  reconciliations_passed bigint not null default 0,
  mismatches             bigint not null default 0,
  transient_mismatches   bigint not null default 0,
  findings_new           int not null default 0,
  findings_detected      int not null default 0,
  error_message          text,
  checkpoint_at          timestamptz,
  checkpoint_count       bigint,
  checkpoint_qty         numeric,
  checkpoint_xor         bigint,
  balance_log_max_id     bigint,
  evidence               jsonb not null default '[]'
);
create index on integrity.runs (business_date, status);
create index on integrity.runs (started_at desc);

create table integrity.findings (
  id                  uuid primary key default gen_random_uuid(),
  finding_no          text not null unique,
  fingerprint         text not null,
  check_code          text not null,
  severity            text not null check (severity in ('info','warning','critical')),
  classification      text not null check (classification in ('confirmed','suspected','monitoring')),
  title               text not null,
  description         text not null,
  product_id          uuid references public.products(id),
  warehouse_id        uuid references public.warehouses(id),
  location_id         uuid references public.storage_locations(id),
  owner_company_id    uuid references public.companies(id),
  stock_status        public.stock_status,
  expected_qty        numeric(18,4),     -- calculated from the ledger
  recorded_qty        numeric(18,4),     -- stored balance
  difference          numeric(18,4),     -- recorded - expected
  txn_ids             uuid[] not null default '{}',
  user_ids            uuid[] not null default '{}',
  details             jsonb,
  possible_cause      text,              -- always labelled "Unverified" until an investigator confirms it
  first_run_id        uuid references integrity.runs(id),
  last_run_id         uuid references integrity.runs(id),
  first_detected_at   timestamptz not null default now(),
  last_detected_at    timestamptz not null default now(),
  occurrences         int not null default 1,
  still_present       boolean not null default true,
  status              text not null default 'open' check (status in ('open','investigating','resolved','dismissed')),
  assigned_to         uuid references public.app_users(id),
  assigned_at         timestamptz,
  resolved_by         uuid,
  resolved_at         timestamptz,
  resolution          text,
  resolution_txn_id   uuid references public.stock_transactions(id),
  escalated           boolean not null default false
);
create unique index findings_open_fingerprint on integrity.findings (fingerprint) where status in ('open','investigating');
create index on integrity.findings (status, severity);
create index on integrity.findings (warehouse_id);

create table integrity.finding_events (
  id          bigint generated always as identity primary key,
  finding_id  uuid not null references integrity.findings(id),
  at          timestamptz not null default clock_timestamp(),
  actor_id    uuid,
  event       text not null,
  note        text,
  data        jsonb
);
create index on integrity.finding_events (finding_id, at);
create trigger finding_events_immutable before update or delete on integrity.finding_events
  for each row execute function private.block_modification();

-- findings are never deleted
create trigger findings_no_delete before delete on integrity.findings
  for each row execute function private.block_modification();
-- runs are evidence: never deleted, frozen once finished
create or replace function integrity.protect_runs() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' or old.status <> 'running' then
    raise exception using errcode = 'CS423', message = 'Integrity run records are permanent evidence and cannot be changed';
  end if;
  return new;
end $$;
create trigger runs_protect before update or delete on integrity.runs
  for each row execute function integrity.protect_runs();

-- candidate keys during a run
create unlogged table integrity.work_candidates (
  run_id           uuid not null,
  product_id       uuid not null,
  location_id      uuid not null,
  owner_company_id uuid not null,
  status           public.stock_status not null,
  ledger_qty       numeric,
  balance_qty      numeric,
  balance_exists   boolean,
  ledger_rows      bigint
);

-- -----------------------------------------------------------------------------
-- Finding upsert (dedupe by fingerprint; append event)
-- -----------------------------------------------------------------------------
create or replace function integrity.record_finding(
  p_run uuid, p_fingerprint text, p_check text, p_severity text, p_class text, p_title text, p_description text,
  p_product uuid default null, p_warehouse uuid default null, p_location uuid default null, p_owner uuid default null,
  p_status public.stock_status default null, p_expected numeric default null, p_recorded numeric default null,
  p_txn_ids uuid[] default '{}', p_user_ids uuid[] default '{}', p_details jsonb default null,
  p_cause text default null, p_escalate boolean default false)
returns uuid language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare v_f integrity.findings; v_new boolean := false;
begin
  select * into v_f from integrity.findings where fingerprint = p_fingerprint and status in ('open','investigating') for update;
  -- A "suspected" event (e.g. a possible repeat withdrawal) that an investigator already reviewed and
  -- closed is not raised again for the same records. Confirmed accounting problems always re-open.
  if not found and p_class = 'suspected' and exists (
       select 1 from integrity.findings where fingerprint = p_fingerprint and status in ('resolved','dismissed')) then
    return null;
  end if;
  if found then
    if not v_f.still_present then
      insert into integrity.finding_events (finding_id, event, note, data)
      values (v_f.id, 'redetected', p_description, jsonb_build_object('run_id', p_run));
    end if;
    update integrity.findings set last_run_id = p_run, last_detected_at = now(), occurrences = occurrences + 1,
           still_present = true, expected_qty = p_expected, recorded_qty = p_recorded,
           difference = case when p_expected is not null or p_recorded is not null then coalesce(p_recorded,0) - coalesce(p_expected,0) end,
           description = p_description, details = coalesce(p_details, details),
           txn_ids = (select array(select distinct unnest(txn_ids || coalesce(p_txn_ids, '{}')))),
           user_ids = (select array(select distinct unnest(user_ids || coalesce(p_user_ids, '{}')))),
           severity = case when p_severity = 'critical' or severity = 'critical' then 'critical'
                           when p_severity = 'warning' or severity = 'warning' then 'warning' else 'info' end,
           escalated = escalated or p_escalate
    where id = v_f.id returning * into v_f;
  else
    insert into integrity.findings (finding_no, fingerprint, check_code, severity, classification, title, description,
       product_id, warehouse_id, location_id, owner_company_id, stock_status, expected_qty, recorded_qty, difference,
       txn_ids, user_ids, details, possible_cause, first_run_id, last_run_id, escalated)
    values (private.next_doc_no('INT'), p_fingerprint, p_check, p_severity, p_class, p_title, p_description,
       p_product, p_warehouse, p_location, p_owner, p_status, p_expected, p_recorded,
       case when p_expected is not null or p_recorded is not null then coalesce(p_recorded,0) - coalesce(p_expected,0) end,
       coalesce(p_txn_ids, '{}'), coalesce(p_user_ids, '{}'), p_details,
       case when p_cause is null then null when p_cause ilike 'unverified%' then p_cause else 'Unverified — ' || p_cause end,
       p_run, p_run, p_escalate)
    returning * into v_f;
    v_new := true;
    insert into integrity.finding_events (finding_id, event, note, data)
    values (v_f.id, 'detected', p_description, jsonb_build_object('run_id', p_run, 'expected', p_expected, 'recorded', p_recorded));
  end if;
  -- remember which findings this run saw
  insert into integrity.run_seen (run_id, finding_id, is_new) values (p_run, v_f.id, v_new) on conflict do nothing;
  return v_f.id;
end $$;

create table integrity.run_seen (
  run_id     uuid not null references integrity.runs(id),
  finding_id uuid not null references integrity.findings(id),
  is_new     boolean not null,
  primary key (run_id, finding_id)
);

create or replace function integrity.add_evidence(p_run uuid, p_step text, p_started timestamptz, p_data jsonb)
returns void language sql security definer set search_path = integrity, pg_temp as $$
  update integrity.runs set evidence = evidence || jsonb_build_array(jsonb_build_object(
     'step', p_step, 'ms', round(extract(epoch from clock_timestamp() - p_started) * 1000), 'data', p_data))
  where id = p_run
$$;

-- users associated with a balance key (recent postings + direct balance changes)
create or replace function integrity.key_users(p_product uuid, p_location uuid, p_owner uuid, p_status public.stock_status)
returns uuid[] language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce(array_agg(distinct u), '{}') from (
    (select posted_by as u from public.stock_ledger
     where product_id = p_product and location_id = p_location and owner_company_id = p_owner and status = p_status
     order by id desc limit 20)
    union
    (select app_user from private.balance_change_log
     where product_id = p_product and location_id = p_location and owner_company_id = p_owner and status = p_status
       and app_user is not null order by id desc limit 20)) s
  where u is not null and u <> '00000000-0000-0000-0000-000000000000'
$$;

create or replace function integrity.key_txns(p_product uuid, p_location uuid, p_owner uuid, p_status public.stock_status)
returns uuid[] language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(txn_id), '{}') from (
    select distinct txn_id, max(id) as m from public.stock_ledger
    where product_id = p_product and location_id = p_location and owner_company_id = p_owner and status = p_status
    group by txn_id order by m desc limit 10) s
$$;

-- -----------------------------------------------------------------------------
-- THE DAILY CHECK
-- -----------------------------------------------------------------------------
create or replace function integrity.run_check(p_trigger text default 'scheduled', p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare
  v_run integrity.runs;
  v_t timestamptz;
  v_prev integrity.runs;
  c record;
  v_n bigint; v_n2 bigint;
  v_cnt bigint; v_qty numeric; v_xor bigint;
  v_cut timestamptz;
  v_win int := private.setting_num('integrity.repeat_window_minutes', 5)::int;
  v_since timestamptz;
  v_escalate_qty numeric := private.setting_num('integrity.escalate_abs_qty', 50);
  v_unusual_adj numeric := private.setting_num('integrity.unusual_adjustment_qty', 100);
  v_err text; v_detail text;
  v_result text; v_log_max bigint; v_cause text; v_bal numeric; v_led numeric;
  v_wh_start time := private.setting_text('business.working_hours_start', '06:00')::time;
  v_wh_end time := private.setting_text('business.working_hours_end', '19:00')::time;
begin
  if not pg_try_advisory_xact_lock(hashtext('cswms.integrity.run')) then
    raise exception using errcode = 'CS423', message = 'An integrity check is already running';
  end if;

  insert into integrity.runs (run_no, trigger, business_date, status, started_by)
  values (private.next_doc_no('IRUN'), p_trigger, (now() at time zone 'Africa/Johannesburg')::date, 'running', p_actor)
  returning * into v_run;

  -- previous successful run (for incremental checks and checkpoint verification)
  select * into v_prev from integrity.runs where status = 'completed' order by started_at desc limit 1;
  v_since := coalesce(v_prev.started_at - interval '1 day', '-infinity'::timestamptz);

  begin
    perform set_config('cswms.integrity_running', '1', true);

    ---------------------------------------------------------------------------
    -- 1. LEDGER vs BALANCE reconciliation — ONE statement = ONE consistent snapshot.
    --    Every posting writes ledger and balance in the same transaction, so a
    --    single snapshot always sees both or neither.
    ---------------------------------------------------------------------------
    v_t := clock_timestamp();
    delete from integrity.work_candidates where run_id = v_run.id;
    create temp table if not exists _recon (
      product_id uuid, location_id uuid, owner_company_id uuid, status public.stock_status,
      ledger_qty numeric, ledger_rows bigint, balance_qty numeric, balance_exists boolean,
      bal_wh uuid, loc_wh uuid
    ) on commit drop;
    truncate _recon;
    insert into _recon
    select coalesce(l.product_id, b.product_id), coalesce(l.location_id, b.location_id),
           coalesce(l.owner_company_id, b.owner_company_id), coalesce(l.status, b.status),
           coalesce(l.q, 0), coalesce(l.n, 0), coalesce(b.qty, 0), b.product_id is not null, b.warehouse_id,
           (select warehouse_id from public.storage_locations sl where sl.id = coalesce(l.location_id, b.location_id))
    from (select product_id, location_id, owner_company_id, status, sum(qty_delta) as q, count(*) as n
          from public.stock_ledger group by 1,2,3,4) l
    full outer join public.stock_balances b
      on b.product_id = l.product_id and b.location_id = l.location_id
     and b.owner_company_id = l.owner_company_id and b.status = l.status;

    select count(*), count(distinct product_id), count(distinct location_id), sum(ledger_rows),
           count(*) filter (where ledger_qty = balance_qty)
      into v_run.keys_checked, v_run.products_checked, v_run.locations_checked, v_run.ledger_rows_checked, v_run.reconciliations_passed
    from _recon;
    select count(distinct sl.warehouse_id), count(distinct owner_company_id)
      into v_run.warehouses_checked, v_run.companies_checked
    from _recon r join public.storage_locations sl on sl.id = r.location_id;
    select count(*) into v_run.transactions_checked from public.stock_transactions;

    insert into integrity.work_candidates
    select v_run.id, product_id, location_id, owner_company_id, status, ledger_qty, balance_qty, balance_exists, ledger_rows
    from _recon where ledger_qty <> balance_qty;
    get diagnostics v_n = row_count;
    perform integrity.add_evidence(v_run.id, 'reconcile_ledger_to_balances', v_t,
      jsonb_build_object('keys', v_run.keys_checked, 'passed', v_run.reconciliations_passed, 'candidates', v_n));

    ---------------------------------------------------------------------------
    -- 2. VALIDATE each candidate before classifying it as confirmed:
    --    lock the balance (waits for any in-flight posting), re-read both sides.
    ---------------------------------------------------------------------------
    v_t := clock_timestamp(); v_n := 0; v_n2 := 0;
    for c in select * from integrity.work_candidates where run_id = v_run.id loop
      select qty into v_bal from public.stock_balances
      where product_id = c.product_id and location_id = c.location_id and owner_company_id = c.owner_company_id and status = c.status
      for share;
      v_bal := coalesce(v_bal, 0);
      select coalesce(sum(qty_delta), 0) into v_led from public.stock_ledger
      where product_id = c.product_id and location_id = c.location_id and owner_company_id = c.owner_company_id and status = c.status;
      if v_bal = v_led then
        v_n2 := v_n2 + 1;   -- transient (changed between snapshot and validation): not a discrepancy
        continue;
      end if;
      v_n := v_n + 1;
      if exists (select 1 from private.balance_change_log where product_id = c.product_id and location_id = c.location_id
                 and owner_company_id = c.owner_company_id and status = c.status and posting_txn_id is null) then
        v_cause := 'the stored balance was changed outside the posting engine (a balance change without a stock transaction was logged)';
      elsif not c.balance_exists then
        v_cause := 'the stored balance record is missing although ledger movements exist';
      elsif c.ledger_rows = 0 then
        v_cause := 'a stored balance exists without any ledger movements (created outside the posting engine)';
      else
        v_cause := 'ledger rows may have been added, altered or removed outside the posting engine';
      end if;
      perform integrity.record_finding(v_run.id,
        'mismatch:' || c.product_id || ':' || c.location_id || ':' || c.owner_company_id || ':' || c.status,
        'LEDGER_BALANCE_MISMATCH', 'critical', 'confirmed',
        'Balance does not match ledger: ' || (select sku from public.products where id = c.product_id),
        format('Recorded balance %s, calculated from ledger %s (difference %s) for %s at %s (%s, owner %s).',
               v_bal, v_led, v_bal - v_led, (select sku from public.products where id = c.product_id),
               (select code from public.storage_locations where id = c.location_id), c.status,
               (select code from public.companies where id = c.owner_company_id)),
        c.product_id, (select warehouse_id from public.storage_locations where id = c.location_id), c.location_id,
        c.owner_company_id, c.status, v_led, v_bal,
        integrity.key_txns(c.product_id, c.location_id, c.owner_company_id, c.status),
        integrity.key_users(c.product_id, c.location_id, c.owner_company_id, c.status),
        jsonb_build_object('validated_at', clock_timestamp(), 'snapshot_ledger', c.ledger_qty, 'snapshot_balance', c.balance_qty),
        v_cause, true);
    end loop;
    v_run.mismatches := v_n; v_run.transient_mismatches := v_n2;
    perform integrity.add_evidence(v_run.id, 'validate_candidates', v_t, jsonb_build_object('confirmed', v_n, 'transient', v_n2));

    ---------------------------------------------------------------------------
    -- 3. Negative stock (prohibited everywhere)
    ---------------------------------------------------------------------------
    v_t := clock_timestamp(); v_n := 0;
    for c in select * from public.stock_balances where qty < 0 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'negative:' || c.product_id || ':' || c.location_id || ':' || c.owner_company_id || ':' || c.status,
        'NEGATIVE_STOCK', 'critical', 'confirmed', 'Negative stock balance',
        format('Balance of %s is %s at location %s.', (select sku from public.products where id = c.product_id), c.qty,
               (select code from public.storage_locations where id = c.location_id)),
        c.product_id, c.warehouse_id, c.location_id, c.owner_company_id, c.status, null, c.qty,
        '{}', '{}', null, 'the no-negative database constraint may have been removed or bypassed', true);
    end loop;
    for c in select * from public.stock_ledger where balance_after < 0 and posted_at > v_since loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'negative_ledger:' || c.id, 'NEGATIVE_STOCK', 'critical', 'confirmed',
        'Ledger shows a negative running balance',
        format('Ledger entry %s left a negative balance (%s).', c.id, c.balance_after),
        c.product_id, c.warehouse_id, c.location_id, c.owner_company_id, c.status, null, c.balance_after,
        array[c.txn_id], array[c.posted_by], jsonb_build_object('ledger_id', c.id), 'ledger row written outside the posting engine', true);
    end loop;
    perform integrity.add_evidence(v_run.id, 'negative_stock', v_t, jsonb_build_object('findings', v_n));

    ---------------------------------------------------------------------------
    -- 4. Running-balance sequence (balance_after must equal the running sum)
    --    for every key that had activity since the previous check
    ---------------------------------------------------------------------------
    v_t := clock_timestamp(); v_n := 0;
    for c in
      with keys as (select distinct product_id, location_id, owner_company_id, status
                    from public.stock_ledger where posted_at > v_since),
      seq as (select l.*, sum(l.qty_delta) over (partition by l.product_id, l.location_id, l.owner_company_id, l.status order by l.id) as running
              from public.stock_ledger l join keys k using (product_id, location_id, owner_company_id, status))
      select * from seq where running <> balance_after order by id limit 500
    loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'sequence:' || c.id, 'LEDGER_SEQUENCE_BREAK', 'critical', 'confirmed',
        'Ledger running balance is inconsistent',
        format('Ledger entry %s records balance %s but the running total of all earlier entries is %s.', c.id, c.balance_after, c.running),
        c.product_id, c.warehouse_id, c.location_id, c.owner_company_id, c.status, c.running, c.balance_after,
        array[c.txn_id], array[c.posted_by], jsonb_build_object('ledger_id', c.id),
        'an earlier ledger row for this item was removed, altered or inserted out of sequence', true);
    end loop;
    perform integrity.add_evidence(v_run.id, 'ledger_sequence', v_t, jsonb_build_object('findings', v_n));

    ---------------------------------------------------------------------------
    -- 5. Unexpected changes to historical records: row hashes, header hashes, checkpoint
    ---------------------------------------------------------------------------
    v_t := clock_timestamp(); v_n := 0;
    for c in select l.* from public.stock_ledger l where l.row_hash <> private.ledger_row_hash(l) limit 500 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'ledger_hash:' || c.id, 'HISTORICAL_RECORD_CHANGED', 'critical', 'confirmed',
        'A historical ledger entry was changed',
        format('Ledger entry %s no longer matches its original content hash.', c.id),
        c.product_id, c.warehouse_id, c.location_id, c.owner_company_id, c.status, null, null,
        array[c.txn_id], array[c.posted_by], jsonb_build_object('ledger_id', c.id, 'stored_hash', c.row_hash),
        'direct database modification by a privileged account', true);
    end loop;
    for c in select t.* from public.stock_transactions t where t.status = 'posted'
             and t.header_hash is distinct from private.txn_header_hash(t) limit 500 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'txn_hash:' || c.id, 'HISTORICAL_RECORD_CHANGED', 'critical', 'confirmed',
        'A posted transaction header was changed',
        format('Transaction %s no longer matches its content hash recorded at posting.', c.txn_no),
        null, c.warehouse_id, null, null, null, null, null, array[c.id], array[c.created_by], null,
        'direct database modification by a privileged account', true);
    end loop;

    -- checkpoint: aggregate fingerprint of all ledger rows up to the previous checkpoint must not change
    if v_prev.checkpoint_at is not null then
      select count(*), coalesce(sum(qty_delta), 0),
             coalesce(bit_xor(('x' || left(row_hash, 16))::bit(64)::bigint), 0)
        into v_cnt, v_qty, v_xor
      from public.stock_ledger where posted_at <= v_prev.checkpoint_at;
      if v_cnt <> v_prev.checkpoint_count or v_qty <> v_prev.checkpoint_qty or v_xor <> v_prev.checkpoint_xor then
        v_n := v_n + 1;
        perform integrity.record_finding(v_run.id, 'checkpoint:' || v_prev.id, 'HISTORICAL_RECORD_CHANGED', 'critical', 'confirmed',
          'Historical ledger differs from the previous verified checkpoint',
          format('At checkpoint %s there were %s ledger rows (net qty %s); there are now %s rows (net qty %s) up to that moment.',
                 to_char(v_prev.checkpoint_at at time zone 'Africa/Johannesburg', 'DD/MM/YYYY HH24:MI'),
                 v_prev.checkpoint_count, v_prev.checkpoint_qty, v_cnt, v_qty),
          null, null, null, null, null, v_prev.checkpoint_count, v_cnt, '{}', '{}',
          jsonb_build_object('previous_run', v_prev.run_no, 'checkpoint_at', v_prev.checkpoint_at,
                             'expected_xor', v_prev.checkpoint_xor, 'actual_xor', v_xor),
          'ledger rows were deleted, back-dated or altered outside the application', true);
      end if;
    end if;
    -- new checkpoint (one hour margin so in-flight postings are never on the boundary)
    v_cut := date_trunc('minute', clock_timestamp() - interval '1 hour');
    select count(*), coalesce(sum(qty_delta), 0), coalesce(bit_xor(('x' || left(row_hash, 16))::bit(64)::bigint), 0)
      into v_run.checkpoint_count, v_run.checkpoint_qty, v_run.checkpoint_xor
    from public.stock_ledger where posted_at <= v_cut;
    v_run.checkpoint_at := v_cut;
    perform integrity.add_evidence(v_run.id, 'historical_records', v_t,
      jsonb_build_object('findings', v_n, 'checkpoint_at', v_cut, 'checkpoint_rows', v_run.checkpoint_count));

    ---------------------------------------------------------------------------
    -- 6. Unexplained balance changes (balance changed without a posting transaction)
    ---------------------------------------------------------------------------
    v_t := clock_timestamp(); v_n := 0;
    select coalesce(max(id), 0) into v_log_max from private.balance_change_log;
    for c in select product_id, location_id, owner_company_id, status, count(*) as n, min(at) as first_at, max(at) as last_at,
                    array_agg(distinct db_user) as db_users, array_agg(distinct app_user) filter (where app_user is not null) as app_users,
                    sum(coalesce(new_qty,0) - coalesce(old_qty,0)) as net
             from private.balance_change_log
             where id > coalesce(v_prev.balance_log_max_id, 0) and id <= v_log_max and posting_txn_id is null
             group by 1,2,3,4 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id,
        'unexplained:' || c.product_id || ':' || c.location_id || ':' || c.owner_company_id || ':' || c.status,
        'UNEXPLAINED_BALANCE_CHANGE', 'critical', 'confirmed', 'Balance changed without a stock transaction',
        format('%s change(s) to the stored balance of %s at %s (net %s) were made outside the posting engine by database account(s) %s between %s and %s.',
               c.n, (select sku from public.products where id = c.product_id), (select code from public.storage_locations where id = c.location_id),
               c.net, array_to_string(c.db_users, ', '),
               to_char(c.first_at at time zone 'Africa/Johannesburg', 'DD/MM/YYYY HH24:MI'),
               to_char(c.last_at at time zone 'Africa/Johannesburg', 'DD/MM/YYYY HH24:MI')),
        c.product_id, (select warehouse_id from public.storage_locations where id = c.location_id), c.location_id,
        c.owner_company_id, c.status, null, null, '{}', coalesce(c.app_users, '{}'),
        jsonb_build_object('db_users', c.db_users, 'net_change', c.net),
        'manual database edit, faulty script or integration writing directly to balances', true);
    end loop;
    -- changes that name a posting transaction which has no ledger row for that key
    for c in select g.posting_txn_id, g.product_id, g.location_id, g.owner_company_id, g.status
             from private.balance_change_log g
             where g.id > coalesce(v_prev.balance_log_max_id, 0) and g.id <= v_log_max and g.posting_txn_id is not null
               and g.op <> 'INSERT'
               and not exists (select 1 from public.stock_ledger l where l.txn_id = g.posting_txn_id and l.product_id = g.product_id
                               and l.location_id = g.location_id and l.owner_company_id = g.owner_company_id and l.status = g.status)
             group by 1,2,3,4,5 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'unexplained_txn:' || c.posting_txn_id || ':' || c.product_id || ':' || c.location_id,
        'UNEXPLAINED_BALANCE_CHANGE', 'critical', 'confirmed', 'Balance change not backed by a ledger entry',
        format('A balance change claims transaction %s, but that transaction has no ledger entry for this item and location.',
               coalesce((select txn_no from public.stock_transactions where id = c.posting_txn_id), c.posting_txn_id::text)),
        c.product_id, (select warehouse_id from public.storage_locations where id = c.location_id), c.location_id,
        c.owner_company_id, c.status, null, null, array[c.posting_txn_id], '{}', null,
        'a script imitated the posting engine', true);
    end loop;
    v_run.balance_log_max_id := v_log_max;
    perform integrity.add_evidence(v_run.id, 'unexplained_changes', v_t, jsonb_build_object('findings', v_n, 'log_upto', v_log_max));

    ---------------------------------------------------------------------------
    -- 7. Transaction completeness: orphaned / incomplete / unapproved
    ---------------------------------------------------------------------------
    v_t := clock_timestamp(); v_n := 0;
    -- posted header without ledger rows
    for c in select t.* from public.stock_transactions t
             where t.status = 'posted' and not exists (select 1 from public.stock_ledger l where l.txn_id = t.id) loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'txn_no_ledger:' || c.id, 'INCOMPLETE_TRANSACTION', 'critical', 'confirmed',
        'Posted transaction without stock movements', format('Transaction %s (%s) is marked posted but has no ledger entries.', c.txn_no, c.txn_type),
        null, c.warehouse_id, null, null, null, null, null, array[c.id], array[c.created_by], null,
        'ledger rows were deleted or the transaction status was edited directly', true);
    end loop;
    -- ledger rows of transactions that are not posted (pending, rejected, cancelled) -> unapproved changes affecting balances
    for c in select t.id, t.txn_no, t.txn_type, t.status, t.warehouse_id, t.created_by, count(*) as n
             from public.stock_ledger l join public.stock_transactions t on t.id = l.txn_id
             where t.status <> 'posted' group by 1,2,3,4,5,6 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'ledger_unposted:' || c.id,
        case when c.txn_type in ('adjustment','stocktake_adjustment','reversal','transfer_writeoff') then 'UNAPPROVED_ADJUSTMENT' else 'ORPHANED_LEDGER' end,
        'critical', 'confirmed', 'Stock movements belong to a transaction that is ' || c.status,
        format('%s ledger entries belong to %s (%s), which is %s.', c.n, c.txn_no, c.txn_type, c.status),
        null, c.warehouse_id, null, null, null, null, null, array[c.id], array[c.created_by], null,
        'movements were posted before approval or the approval status was changed afterwards', true);
    end loop;
    -- controlled transactions posted without an approved approval request
    for c in select t.* from public.stock_transactions t
             where t.status = 'posted' and t.posted_at > v_since and (
                  (t.txn_type in ('reversal','transfer_writeoff')
                     and not exists (select 1 from public.approval_requests a where a.txn_id = t.id and a.status = 'approved'))
               or (t.txn_type = 'adjustment' and exists (select 1 from public.approval_requests a where a.txn_id = t.id)
                     and not exists (select 1 from public.approval_requests a where a.txn_id = t.id and a.status = 'approved'))
               or (t.txn_type = 'stocktake_adjustment' and not exists (
                     select 1 from public.stocktakes s join public.approval_requests a on a.id = s.approval_id and a.status = 'approved'
                     where s.id = t.stocktake_id))
               or (t.txn_type = 'opening' and not exists (
                     select 1 from public.import_batches b join public.approval_requests a on a.id = b.approval_id and a.status = 'approved'
                     where b.id = t.import_batch_id))) loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'unapproved:' || c.id, 'UNAPPROVED_ADJUSTMENT', 'critical', 'confirmed',
        'Controlled stock change posted without approval',
        format('%s (%s) changed stock but no matching approved approval request exists.', c.txn_no, c.txn_type),
        null, c.warehouse_id, null, null, null, null, null, array[c.id], array[c.created_by, c.posted_by], null,
        'the approval workflow was bypassed', true);
    end loop;
    -- ledger content must agree with the transaction lines
    for c in
      with lines as (
        select txn_id, product_id, sum(qty_base) as q from public.stock_transaction_lines group by 1,2),
      led as (
        select txn_id, product_id, sum(qty_delta) as net, sum(qty_delta) filter (where qty_delta > 0) as gross_in
        from public.stock_ledger where posted_at > v_since group by 1,2)
      select t.id, t.txn_no, t.txn_type, t.warehouse_id, t.created_by, led.product_id, led.net, led.gross_in, lines.q
      from led join public.stock_transactions t on t.id = led.txn_id
      left join lines on lines.txn_id = led.txn_id and lines.product_id = led.product_id
      where case
        when t.txn_type in ('receipt','opening','return','adjustment','stocktake_adjustment','reversal','transfer_writeoff')
          then led.net is distinct from lines.q
        when t.txn_type = 'withdrawal' then led.net is distinct from -lines.q
        when t.txn_type in ('move','status_change','transfer_dispatch','transfer_receipt')
          then led.net <> 0 or coalesce(led.gross_in, 0) is distinct from lines.q
        else false end
    loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'txn_lines:' || c.id || ':' || c.product_id, 'INCOMPLETE_TRANSACTION', 'critical', 'confirmed',
        'Ledger does not match transaction lines',
        format('%s (%s): the ledger net movement %s does not agree with the transaction lines (%s).', c.txn_no, c.txn_type, c.net, c.q),
        c.product_id, c.warehouse_id, null, null, null, c.q, c.net, array[c.id], array[c.created_by], null,
        'ledger rows of this transaction were added or removed', true);
    end loop;
    perform integrity.add_evidence(v_run.id, 'transaction_completeness', v_t, jsonb_build_object('findings', v_n));

    ---------------------------------------------------------------------------
    -- 8. Quantities, unit conversions and references
    ---------------------------------------------------------------------------
    v_t := clock_timestamp(); v_n := 0;
    for c in select l.*, p.sku, u.decimals as base_dec, pu.factor_to_base as current_factor
             from public.stock_ledger l
             join public.products p on p.id = l.product_id
             join public.uoms u on u.id = p.base_uom_id
             left join public.product_uoms pu on pu.product_id = l.product_id and pu.uom_id = l.entered_uom_id
             where l.posted_at > v_since and (
                   round(abs(l.entered_qty) * l.factor, 4) <> abs(l.qty_delta)
                or trunc(l.qty_delta, u.decimals) <> l.qty_delta
                or pu.factor_to_base is null or pu.factor_to_base <> l.factor)
             limit 500 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'conversion:' || c.id,
        case when trunc(c.qty_delta, c.base_dec) <> c.qty_delta then 'INVALID_QUANTITY' else 'INVALID_UNIT_CONVERSION' end,
        'warning', 'suspected', 'Invalid quantity or unit conversion: ' || c.sku,
        format('Ledger entry %s: entered %s x factor %s = %s, recorded %s base units (current factor %s, base unit decimals %s).',
               c.id, c.entered_qty, c.factor, round(abs(c.entered_qty) * c.factor, 4), c.qty_delta, c.current_factor, c.base_dec),
        c.product_id, c.warehouse_id, c.location_id, c.owner_company_id, c.status, null, null, array[c.txn_id], array[c.posted_by],
        jsonb_build_object('ledger_id', c.id), 'unit conversion changed after posting, or the entry was created outside the posting engine', false);
    end loop;
    -- denormalised warehouse references must agree with the location
    for c in select b.*, sl.warehouse_id as loc_wh from public.stock_balances b join public.storage_locations sl on sl.id = b.location_id
             where b.warehouse_id <> sl.warehouse_id loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'ref_balance_wh:' || c.product_id || ':' || c.location_id || ':' || c.owner_company_id || ':' || c.status,
        'INVALID_REFERENCE', 'critical', 'confirmed', 'Balance references the wrong warehouse',
        'A stored balance names a warehouse that does not contain its storage location.',
        c.product_id, c.loc_wh, c.location_id, c.owner_company_id, c.status, null, c.qty, '{}', '{}', null,
        'direct database modification', true);
    end loop;
    for c in select l.id, l.txn_id, l.product_id, l.location_id, l.owner_company_id, l.status, l.posted_by, sl.warehouse_id as loc_wh
             from public.stock_ledger l join public.storage_locations sl on sl.id = l.location_id
             where l.warehouse_id <> sl.warehouse_id limit 500 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'ref_ledger_wh:' || c.id, 'INVALID_REFERENCE', 'critical', 'confirmed',
        'Ledger entry references the wrong warehouse', format('Ledger entry %s names a warehouse that does not contain its location.', c.id),
        c.product_id, c.loc_wh, c.location_id, c.owner_company_id, c.status, null, null, array[c.txn_id], array[c.posted_by], null,
        'direct database modification', true);
    end loop;
    -- stock held at inactive warehouses / locations / companies or for inactive products
    for c in select b.warehouse_id, b.location_id, b.product_id, b.owner_company_id, b.status, b.qty,
                    concat_ws(', ',
                      case when w.status <> 'active' then 'warehouse ' || w.code || ' is ' || w.status end,
                      case when sl.status <> 'active' then 'location ' || sl.code || ' is ' || sl.status end,
                      case when co.status <> 'active' then 'owner company ' || co.code || ' is ' || co.status end,
                      case when p.status <> 'active' then 'product ' || p.sku || ' is ' || p.status end) as why
             from public.stock_balances b
             join public.warehouses w on w.id = b.warehouse_id
             join public.storage_locations sl on sl.id = b.location_id
             join public.companies co on co.id = b.owner_company_id
             join public.products p on p.id = b.product_id
             where b.qty <> 0 and (w.status <> 'active' or sl.status <> 'active' or co.status <> 'active' or p.status <> 'active') loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'inactive_ref:' || c.product_id || ':' || c.location_id || ':' || c.owner_company_id || ':' || c.status,
        'INVALID_REFERENCE', 'warning', 'suspected', 'Stock held against an inactive record',
        format('%s units are recorded although %s.', c.qty, c.why),
        c.product_id, c.warehouse_id, c.location_id, c.owner_company_id, c.status, null, c.qty, '{}', '{}', null,
        'a warehouse, location, company or product was deactivated before its stock was moved', false);
    end loop;
    perform integrity.add_evidence(v_run.id, 'quantities_conversions_references', v_t, jsonb_build_object('findings', v_n));

    ---------------------------------------------------------------------------
    -- 9. Transfers: in-transit accounting, status consistency, overdue
    ---------------------------------------------------------------------------
    v_t := clock_timestamp(); v_n := 0;
    -- in-transit balances must equal the outstanding quantities of open transfers
    for c in
      with outstanding as (
        select tl.product_id, tl.to_location_id as location_id, tl.owner_company_id,
               sum(tl.qty_dispatched - tl.qty_received - tl.qty_damaged - tl.qty_written_off) as q
        from public.transfer_lines tl join public.transfers t on t.id = tl.transfer_id
        where t.status in ('dispatched','partially_received','received','closed_with_discrepancy')
        group by 1,2,3),
      transit as (select product_id, location_id, owner_company_id, qty from public.stock_balances where status = 'in_transit')
      select coalesce(o.product_id, b.product_id) as product_id, coalesce(o.location_id, b.location_id) as location_id,
             coalesce(o.owner_company_id, b.owner_company_id) as owner_company_id, coalesce(o.q, 0) as expected, coalesce(b.qty, 0) as recorded
      from outstanding o full outer join transit b using (product_id, location_id, owner_company_id)
      where coalesce(o.q, 0) <> coalesce(b.qty, 0)
    loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'transit:' || c.product_id || ':' || c.location_id || ':' || c.owner_company_id,
        'TRANSFER_ACCOUNTING', 'critical', 'confirmed', 'In-transit stock does not match open transfers',
        format('In-transit balance %s, outstanding on transfers %s for %s.', c.recorded, c.expected,
               (select sku from public.products where id = c.product_id)),
        c.product_id, (select warehouse_id from public.storage_locations where id = c.location_id), c.location_id,
        c.owner_company_id, 'in_transit', c.expected, c.recorded, '{}', '{}', null,
        'a transfer line or in-transit movement was changed outside the transfer process', true);
    end loop;
    -- status consistency
    for c in select t.*, (select coalesce(sum(qty_dispatched - qty_received - qty_damaged - qty_written_off), 0)
                          from public.transfer_lines where transfer_id = t.id) as outstanding
             from public.transfers t loop
      if (c.status in ('received','closed_with_discrepancy') and c.outstanding <> 0)
         or (c.status in ('dispatched','partially_received','received','closed_with_discrepancy') and c.dispatch_txn_id is null)
         or (c.status = 'draft' and c.dispatch_txn_id is not null) then
        v_n := v_n + 1;
        perform integrity.record_finding(v_run.id, 'transfer_status:' || c.id, 'TRANSFER_ACCOUNTING', 'critical', 'confirmed',
          'Transfer status is inconsistent: ' || c.transfer_no,
          format('Transfer %s is "%s" with %s outstanding and dispatch transaction %s.', c.transfer_no, c.status, c.outstanding,
                 coalesce(c.dispatch_txn_id::text, 'missing')),
          null, c.to_warehouse_id, null, null, null, null, null, array_remove(array[c.dispatch_txn_id], null), array[c.created_by], null,
          'the transfer record was edited directly', true);
      end if;
      -- overdue
      if c.status in ('dispatched','partially_received')
         and now() > c.expected_arrival_at + make_interval(hours => private.setting_num('transfer.overdue_grace_hours', 24)::int) then
        v_n := v_n + 1;
        perform integrity.record_finding(v_run.id, 'transfer_overdue:' || c.id, 'TRANSFER_OVERDUE', 'warning', 'suspected',
          'Transfer not received in time: ' || c.transfer_no,
          format('%s was dispatched on %s and expected by %s; %s base units are still in transit.', c.transfer_no,
                 to_char(c.dispatched_at at time zone 'Africa/Johannesburg', 'DD/MM/YYYY'),
                 to_char(c.expected_arrival_at at time zone 'Africa/Johannesburg', 'DD/MM/YYYY'), c.outstanding),
          null, c.to_warehouse_id, null, null, 'in_transit', null, c.outstanding, array_remove(array[c.dispatch_txn_id], null),
          array_remove(array[c.dispatched_by], null), null, 'delivery delayed, not captured at destination, or lost in transit', false);
        perform private.raise_alert('transfer_overdue', 'warning', 'Transfer overdue: ' || c.transfer_no,
          format('%s has not been fully received (expected by %s).', c.transfer_no,
                 to_char(c.expected_arrival_at at time zone 'Africa/Johannesburg', 'DD/MM/YYYY')),
          'transfer_overdue:' || c.id, null, c.to_warehouse_id, null, null, c.outstanding, 'transfer', c.id::text, false,
          '/transfers/' || c.id);
      end if;
    end loop;
    perform integrity.add_evidence(v_run.id, 'transfers', v_t, jsonb_build_object('findings', v_n));

    ---------------------------------------------------------------------------
    -- 10. Duplicates, repeat withdrawals, unusual adjustments, suspicious activity
    ---------------------------------------------------------------------------
    v_t := clock_timestamp(); v_n := 0;
    -- possible repeat withdrawals: same user, product, location and quantity within the window
    for c in select a.txn_id as t1, b.txn_id as t2, a.product_id, a.location_id, a.owner_company_id, a.qty_delta, a.posted_by, a.warehouse_id
             from public.stock_ledger a join public.stock_ledger b
               on b.product_id = a.product_id and b.location_id = a.location_id and b.qty_delta = a.qty_delta
              and b.posted_by = a.posted_by and b.txn_id <> a.txn_id and b.id > a.id
              and b.posted_at between a.posted_at and a.posted_at + make_interval(mins => v_win)
             where a.txn_type = 'withdrawal' and b.txn_type = 'withdrawal' and a.posted_at > v_since limit 500 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'repeat_withdrawal:' || c.t1 || ':' || c.t2 || ':' || c.product_id,
        'POSSIBLE_REPEAT_WITHDRAWAL', 'warning', 'suspected', 'Possible repeated withdrawal',
        format('%s and %s withdrew the same quantity (%s) of %s from the same location by the same user within %s minutes.',
               (select txn_no from public.stock_transactions where id = c.t1), (select txn_no from public.stock_transactions where id = c.t2),
               -c.qty_delta, (select sku from public.products where id = c.product_id), v_win),
        c.product_id, c.warehouse_id, c.location_id, c.owner_company_id, 'available', null, null, array[c.t1, c.t2], array[c.posted_by],
        null, 'the same withdrawal may have been captured twice (verify with the user before correcting)', false);
    end loop;
    -- the same delivery note received twice in a warehouse
    for c in select a.id as t1, b.id as t2, a.reference, a.warehouse_id, a.created_by as u1, b.created_by as u2
             from public.stock_transactions a join public.stock_transactions b
               on b.txn_type = 'receipt' and b.status = 'posted' and b.warehouse_id = a.warehouse_id
              and lower(b.reference) = lower(a.reference) and b.id <> a.id and b.created_at > a.created_at
             where a.txn_type = 'receipt' and a.status = 'posted' and a.reference is not null and b.created_at > v_since
               and not exists (select 1 from public.stock_transactions r where r.related_txn_id in (a.id, b.id) and r.txn_type = 'reversal' and r.status = 'posted')
             limit 500 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'duplicate_receipt:' || c.t1 || ':' || c.t2, 'DUPLICATE_TRANSACTION', 'warning', 'suspected',
        'Delivery reference received more than once: ' || c.reference,
        format('Receipts %s and %s both use delivery reference "%s" in the same warehouse.',
               (select txn_no from public.stock_transactions where id = c.t1), (select txn_no from public.stock_transactions where id = c.t2), c.reference),
        null, c.warehouse_id, null, null, null, null, null, array[c.t1, c.t2], array[c.u1, c.u2], null,
        'the same delivery may have been captured twice (it may also be a legitimate split delivery)', false);
    end loop;
    -- unusually large adjustments
    for c in select t.id, t.txn_no, t.txn_type, t.warehouse_id, t.created_by, t.posted_by, sum(abs(l.qty_delta)) as q
             from public.stock_transactions t join public.stock_ledger l on l.txn_id = t.id
             where t.txn_type in ('adjustment','stocktake_adjustment','transfer_writeoff') and t.posted_at > v_since
             group by 1,2,3,4,5,6 having sum(abs(l.qty_delta)) > v_unusual_adj loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'unusual_adjustment:' || c.id, 'UNUSUAL_ADJUSTMENT', 'warning', 'suspected',
        'Unusually large adjustment: ' || c.txn_no, format('%s (%s) moved %s base units in total.', c.txn_no, c.txn_type, c.q),
        null, c.warehouse_id, null, null, null, null, c.q, array[c.id], array_remove(array[c.created_by, c.posted_by], null), null,
        'large correction — confirm it is supported by documentation', false);
    end loop;
    -- after-hours activity
    for c in select l.posted_by, l.warehouse_id, count(distinct l.txn_id) as n, array_agg(distinct l.txn_id) as txns
             from public.stock_ledger l
             where l.posted_at > now() - interval '1 day'
               and ((l.posted_at at time zone 'Africa/Johannesburg')::time not between v_wh_start and v_wh_end)
               and l.txn_type in ('withdrawal','adjustment','move','status_change')
             group by 1,2 having count(distinct l.txn_id) >= private.setting_num('integrity.after_hours_txn_threshold', 10) loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'after_hours:' || c.posted_by || ':' || c.warehouse_id || ':' || v_run.business_date,
        'SUSPICIOUS_ACTIVITY', 'warning', 'suspected', 'High after-hours stock activity',
        format('%s posted %s stock transactions outside working hours in the last 24 hours.',
               coalesce((select full_name from public.app_users where id = c.posted_by), c.posted_by::text), c.n),
        null, c.warehouse_id, null, null, null, null, null, c.txns[1:20], array[c.posted_by], null,
        'may be legitimate shift work — verify with the branch manager', false);
    end loop;
    -- postings by deactivated users
    for c in select l.posted_by, count(distinct l.txn_id) as n, array_agg(distinct l.txn_id) as txns
             from public.stock_ledger l join public.app_users u on u.id = l.posted_by and not u.is_active
             where l.posted_at > v_since and l.posted_at > u.updated_at group by 1 loop
      v_n := v_n + 1;
      perform integrity.record_finding(v_run.id, 'inactive_user:' || c.posted_by || ':' || v_run.business_date,
        'SUSPICIOUS_ACTIVITY', 'warning', 'suspected', 'Stock posted by a deactivated user',
        format('%s transactions were posted by a deactivated account after it was deactivated.', c.n),
        null, null, null, null, null, null, null, c.txns[1:20], array[c.posted_by], null, 'session still active after deactivation', false);
    end loop;
    perform integrity.add_evidence(v_run.id, 'duplicates_and_unusual_activity', v_t, jsonb_build_object('findings', v_n));

    ---------------------------------------------------------------------------
    -- 11. Close: findings not seen in this run are marked "no longer detected"
    --     (they stay open until a person resolves them)
    ---------------------------------------------------------------------------
    update integrity.findings f set still_present = false
    where f.status in ('open','investigating') and f.classification <> 'monitoring' and f.still_present
      and not exists (select 1 from integrity.run_seen s where s.run_id = v_run.id and s.finding_id = f.id);
    insert into integrity.finding_events (finding_id, event, note, data)
    select f.id, 'no_longer_detected', 'Not detected by run ' || v_run.run_no || ' — remains open until resolved by an investigator',
           jsonb_build_object('run_id', v_run.id)
    from integrity.findings f
    where f.status in ('open','investigating') and not f.still_present and f.classification <> 'monitoring'
      and not exists (select 1 from integrity.finding_events e where e.finding_id = f.id and e.event = 'no_longer_detected'
                      and e.data ->> 'run_id' = v_run.id::text)
      and f.last_run_id is distinct from v_run.id;

    -- a successful run means the monitor itself is healthy again
    update integrity.findings set status = 'resolved', resolved_at = now(), still_present = false,
           resolution = 'Automatically closed: integrity check ' || v_run.run_no || ' completed successfully'
    where classification = 'monitoring' and status in ('open','investigating');

    select count(*), count(*) filter (where is_new) into v_n, v_n2 from integrity.run_seen where run_id = v_run.id;
    v_run.findings_detected := v_n; v_run.findings_new := v_n2;
    v_result := case
      when exists (select 1 from integrity.run_seen s join integrity.findings f on f.id = s.finding_id
                   where s.run_id = v_run.id and f.severity = 'critical') then 'discrepancies'
      when v_n > 0 then 'warnings' else 'passed' end;

    perform set_config('cswms.integrity_running', '', true);

    update integrity.runs set status = 'completed', result = v_result, finished_at = clock_timestamp(),
      keys_checked = v_run.keys_checked, products_checked = v_run.products_checked, locations_checked = v_run.locations_checked,
      warehouses_checked = v_run.warehouses_checked, companies_checked = v_run.companies_checked,
      ledger_rows_checked = coalesce(v_run.ledger_rows_checked, 0), transactions_checked = v_run.transactions_checked,
      reconciliations_passed = v_run.reconciliations_passed, mismatches = v_run.mismatches,
      transient_mismatches = v_run.transient_mismatches, findings_new = v_run.findings_new, findings_detected = v_run.findings_detected,
      checkpoint_at = v_run.checkpoint_at, checkpoint_count = v_run.checkpoint_count, checkpoint_qty = v_run.checkpoint_qty,
      checkpoint_xor = v_run.checkpoint_xor, balance_log_max_id = v_run.balance_log_max_id
    where id = v_run.id;
    delete from integrity.work_candidates where run_id = v_run.id;

  exception when others then
    get stacked diagnostics v_err = message_text, v_detail = pg_exception_context;
    -- everything done inside the block was rolled back; the run record itself survives
    perform set_config('cswms.integrity_running', '', true);
    update integrity.runs set status = 'failed', finished_at = clock_timestamp(),
           error_message = left(v_err || E'\n' || coalesce(v_detail, ''), 4000)
    where id = v_run.id;
    perform integrity.record_monitor_problem('monitor_failed:' || v_run.id, 'Integrity check failed',
      format('Integrity check %s failed: %s. Stock integrity cannot be verified until a check completes.', v_run.run_no, v_err), v_run.id);
    return jsonb_build_object('ok', false, 'run_id', v_run.id, 'run_no', v_run.run_no, 'status', 'failed', 'error', v_err);
  end;

  -- alerts for this run's findings (deduplicated per finding)
  perform integrity.alert_findings(v_run.id);
  perform integrity.send_daily_summary(v_run.id);

  return jsonb_build_object('ok', true, 'run_id', v_run.id, 'run_no', v_run.run_no, 'status', 'completed', 'result', v_result,
                            'keys_checked', v_run.keys_checked, 'mismatches', v_run.mismatches, 'findings', v_run.findings_detected,
                            'new_findings', v_run.findings_new);
end $$;

-- -----------------------------------------------------------------------------
-- Monitoring failures (failed / missed / stale checks)
-- -----------------------------------------------------------------------------
create or replace function integrity.record_monitor_problem(p_fingerprint text, p_title text, p_description text, p_run uuid default null)
returns void language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare v_id uuid;
begin
  select id into v_id from integrity.findings where fingerprint = p_fingerprint and status in ('open','investigating');
  if v_id is null then
    insert into integrity.findings (finding_no, fingerprint, check_code, severity, classification, title, description,
                                    possible_cause, first_run_id, last_run_id, escalated)
    values (private.next_doc_no('INT'), p_fingerprint, 'MONITOR_FAILURE', 'critical', 'monitoring', p_title, p_description,
            'Unverified — database timeout, scheduler outage or an error in a check', p_run, p_run, true)
    returning id into v_id;
    insert into integrity.finding_events (finding_id, event, note) values (v_id, 'detected', p_description);
  else
    update integrity.findings set last_detected_at = now(), occurrences = occurrences + 1, description = p_description where id = v_id;
  end if;
  perform private.raise_alert('integrity_monitor', 'critical', p_title, p_description, 'integrity:' || p_fingerprint,
    null, null, null, null, null, 'integrity_finding', v_id::text, true, '/integrity');
end $$;

create or replace function integrity.watchdog() returns jsonb
language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare
  v_local timestamp := now() at time zone 'Africa/Johannesburg';
  v_sched time := private.setting_text('integrity.daily_run_time', '02:00')::time;
  v_last_ok timestamptz; v_stale numeric := private.setting_num('integrity.stale_after_hours', 26);
  v_issues text[] := '{}';
begin
  select max(finished_at) into v_last_ok from integrity.runs where status = 'completed';
  if v_last_ok is null or now() - v_last_ok > make_interval(hours => v_stale::int) then
    perform integrity.record_monitor_problem('monitor_stale:' || v_local::date,
      'Integrity checks are stale',
      case when v_last_ok is null then 'No integrity check has ever completed successfully.'
           else format('The last successful integrity check finished at %s (more than %s hours ago).',
                       to_char(v_last_ok at time zone 'Africa/Johannesburg', 'DD/MM/YYYY HH24:MI'), v_stale) end);
    v_issues := v_issues || 'stale'::text;
  end if;
  -- today's scheduled run missing two hours after the scheduled time
  if v_local::time > v_sched + interval '2 hours'
     and not exists (select 1 from integrity.runs where business_date = v_local::date and status = 'completed') then
    perform integrity.record_monitor_problem('monitor_missed:' || v_local::date, 'Daily integrity check did not run',
      format('No completed integrity check for %s (scheduled %s).', to_char(v_local::date, 'DD/MM/YYYY'), to_char(v_sched, 'HH24:MI')));
    v_issues := v_issues || 'missed'::text;
  end if;
  return jsonb_build_object('issues', to_jsonb(v_issues));
end $$;

-- -----------------------------------------------------------------------------
-- Alerts & daily summary
-- -----------------------------------------------------------------------------
create or replace function integrity.alert_findings(p_run uuid) returns void
language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare f record; v_escalate boolean;
begin
  for f in select fi.* from integrity.run_seen s join integrity.findings fi on fi.id = s.finding_id where s.run_id = p_run loop
    v_escalate := f.severity = 'critical' and (f.escalated or abs(coalesce(f.difference, 0)) >= private.setting_num('integrity.escalate_abs_qty', 50)
                                                or f.check_code in ('HISTORICAL_RECORD_CHANGED','UNEXPLAINED_BALANCE_CHANGE','UNAPPROVED_ADJUSTMENT'));
    perform private.raise_alert('integrity', f.severity, '[' || f.finding_no || '] ' || f.title, f.description,
      'integrity:' || f.fingerprint, f.product_id, f.warehouse_id, null, f.location_id, f.difference,
      'integrity_finding', f.id::text, v_escalate, '/integrity/findings/' || f.id);
  end loop;
end $$;

create or replace function integrity.current_status() returns jsonb
language plpgsql stable security definer set search_path = integrity, public, private, pg_temp as $$
declare
  v_last_ok integrity.runs; v_last integrity.runs; v_stale numeric := private.setting_num('integrity.stale_after_hours', 26);
  v_crit int; v_warn int; v_inv int; v_status text; v_reason text; v_mon int;
begin
  select * into v_last_ok from integrity.runs where status = 'completed' order by finished_at desc limit 1;
  select * into v_last from integrity.runs order by started_at desc limit 1;
  select count(*) filter (where severity = 'critical' and classification = 'confirmed'),
         count(*) filter (where severity <> 'critical' or classification = 'suspected'),
         count(*) filter (where status = 'investigating'),
         count(*) filter (where classification = 'monitoring')
    into v_crit, v_warn, v_inv, v_mon
  from integrity.findings where status in ('open','investigating');

  if v_crit > 0 then
    v_status := 'RED'; v_reason := v_crit || ' confirmed inventory integrity problem(s) unresolved';
  elsif v_last_ok.id is null then
    v_status := 'GREY'; v_reason := 'No integrity check has completed yet — integrity cannot be verified';
  elsif now() - v_last_ok.finished_at > make_interval(hours => v_stale::int) then
    v_status := 'GREY'; v_reason := 'The last successful check is older than ' || v_stale || ' hours — integrity cannot currently be verified';
  elsif v_last.status = 'failed' then
    v_status := 'GREY'; v_reason := 'The most recent check (' || v_last.run_no || ') failed — integrity cannot currently be verified';
  elsif v_last.status = 'running' then
    v_status := 'GREY'; v_reason := 'A check is running';
  elsif v_mon > 0 then
    v_status := 'RED'; v_reason := 'Monitoring failure requires attention';
  elsif v_warn > 0 or v_inv > 0 then
    v_status := 'AMBER'; v_reason := (v_warn + v_inv) || ' warning(s) or investigation(s) need attention';
  else
    v_status := 'GREEN'; v_reason := 'All scheduled integrity checks passed; no unresolved discrepancies';
  end if;

  return jsonb_build_object('status', v_status, 'reason', v_reason,
    'last_success_at', v_last_ok.finished_at, 'last_success_run_no', v_last_ok.run_no,
    'last_run_at', v_last.started_at, 'last_run_status', v_last.status, 'last_run_result', v_last.result, 'last_run_no', v_last.run_no,
    'keys_checked', v_last_ok.keys_checked, 'locations_checked', v_last_ok.locations_checked, 'products_checked', v_last_ok.products_checked,
    'reconciliations_passed', v_last_ok.reconciliations_passed, 'mismatches', v_last_ok.mismatches,
    'open_critical', v_crit, 'open_warnings', v_warn, 'investigating', v_inv, 'monitor_problems', v_mon,
    'stale_after_hours', v_stale, 'evaluated_at', now());
end $$;

create or replace function integrity.send_daily_summary(p_run uuid) returns void
language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare v_run integrity.runs; v_status jsonb; r record; v_body text; v_title text;
begin
  if not private.setting_bool('alerts.daily_summary_enabled', true) then return; end if;
  select * into v_run from integrity.runs where id = p_run;
  if v_run.trigger not in ('scheduled','retry') then return; end if;
  v_status := integrity.current_status();
  v_title := format('Daily integrity summary %s — %s', to_char(v_run.business_date, 'DD/MM/YYYY'), v_status ->> 'status');
  v_body := format(E'Check %s %s at %s.\nItems/locations verified: %s keys, %s products, %s locations.\nReconciliations passed: %s. Confirmed mismatches: %s.\nFindings this run: %s (%s new). Open critical: %s, warnings: %s.\nStatus: %s — %s',
    v_run.run_no, v_run.result, to_char(v_run.finished_at at time zone 'Africa/Johannesburg', 'HH24:MI'),
    v_run.keys_checked, v_run.products_checked, v_run.locations_checked, v_run.reconciliations_passed, v_run.mismatches,
    v_run.findings_detected, v_run.findings_new, v_status ->> 'open_critical', v_status ->> 'open_warnings',
    v_status ->> 'status', v_status ->> 'reason');
  for r in select distinct u.id, u.email from public.app_users u
           join public.user_role_assignments a on a.user_id = u.id join public.roles ro on ro.id = a.role_id
           where u.is_active and 'integrity.view' = any(ro.permissions) and 'alerts.receive' = any(ro.permissions)
             and a.scope_type in ('group','company') loop
    insert into public.notifications (user_id, title, body, link) values (r.id, v_title, v_body, '/integrity');
    if private.setting_bool('alerts.email_enabled', false) then
      insert into private.email_outbox (to_email, subject, body_text, dedupe_key)
      values (r.email, '[CSWMS] ' || v_title, v_body, 'integrity_summary:' || v_run.business_date)
      on conflict do nothing;
    end if;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Scheduler entry point: called every 15 minutes by pg_cron.
-- Runs the daily check once the configured local time has passed, retries a
-- failed check (up to the configured maximum) and runs the watchdog.
-- -----------------------------------------------------------------------------
create or replace function integrity.dispatch() returns jsonb
language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare
  v_local timestamp := now() at time zone 'Africa/Johannesburg';
  v_sched time := private.setting_text('integrity.daily_run_time', '02:00')::time;
  v_attempts int; v_res jsonb := '{}'; v_done boolean;
begin
  select count(*), bool_or(status = 'completed') into v_attempts, v_done
  from integrity.runs where business_date = v_local::date and trigger in ('scheduled','retry');
  if v_local::time >= v_sched and not coalesce(v_done, false)
     and v_attempts < private.setting_num('integrity.max_attempts_per_day', 3) then
    v_res := integrity.run_check(case when v_attempts = 0 then 'scheduled' else 'retry' end, null);
    -- once per day housekeeping after the first scheduled attempt
    if v_attempts = 0 then
      perform private.stocktake_reminders();
    end if;
  end if;
  return jsonb_build_object('check', v_res, 'watchdog', integrity.watchdog());
end $$;

-- -----------------------------------------------------------------------------
-- PUBLIC API (read + investigation). The monitor tables are not directly
-- accessible to users; everything goes through these permission-checked functions.
-- -----------------------------------------------------------------------------
create or replace function private.finding_visible(f integrity.findings) returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select private.has_group_perm('integrity.view')
      or (f.warehouse_id is not null and f.warehouse_id = any(private.my_warehouses('integrity.view')))
$$;

create or replace function public.integrity_status() returns jsonb
language plpgsql stable security definer set search_path = public, private, integrity, pg_temp as $$
begin
  perform private.require_perm('integrity.view');
  return integrity.current_status();
end $$;

create or replace function public.integrity_findings(p_status text default 'active', p_limit int default 200)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, integrity, pg_temp as $$
begin
  perform private.require_perm('integrity.view');
  return query
  select to_jsonb(f) || jsonb_build_object(
           'product_sku', p.sku, 'product_description', p.description,
           'warehouse_code', w.code, 'warehouse_name', w.name, 'location_code', sl.code,
           'owner_company_code', co.code, 'company_code', wt.company_code, 'company_name', wt.company_name,
           'branch_code', wt.branch_code, 'assigned_to_name', au.full_name)
  from integrity.findings f
  left join public.products p on p.id = f.product_id
  left join public.warehouses w on w.id = f.warehouse_id
  left join private.warehouse_tree wt on wt.warehouse_id = f.warehouse_id
  left join public.storage_locations sl on sl.id = f.location_id
  left join public.companies co on co.id = f.owner_company_id
  left join public.app_users au on au.id = f.assigned_to
  where private.finding_visible(f)
    and (p_status = 'all' or (p_status = 'active' and f.status in ('open','investigating')) or f.status = p_status)
  order by case f.severity when 'critical' then 1 when 'warning' then 2 else 3 end, f.last_detected_at desc
  limit least(coalesce(p_limit, 200), 2000);
end $$;

create or replace function public.integrity_finding_detail(p_finding_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private, integrity, pg_temp as $$
declare f integrity.findings;
begin
  perform private.require_perm('integrity.view');
  select * into f from integrity.findings where id = p_finding_id;
  if not found or not private.finding_visible(f) then perform private.fail('CS401', 'Finding not found or not visible'); end if;
  return (select to_jsonb(f) || jsonb_build_object(
    'product', (select jsonb_build_object('sku', sku, 'description', description) from public.products where id = f.product_id),
    'location', (select jsonb_build_object('code', sl.code, 'name', sl.name, 'warehouse', w.code || ' — ' || w.name,
                                           'branch', wt.branch_code || ' — ' || wt.branch_name, 'company', wt.company_code || ' — ' || wt.company_name)
                 from public.storage_locations sl join public.warehouses w on w.id = sl.warehouse_id
                 join private.warehouse_tree wt on wt.warehouse_id = w.id where sl.id = f.location_id),
    'warehouse', (select jsonb_build_object('code', wt.warehouse_code, 'name', wt.warehouse_name, 'branch', wt.branch_code,
                                            'company', wt.company_code || ' — ' || wt.company_name)
                  from private.warehouse_tree wt where wt.warehouse_id = f.warehouse_id),
    'owner_company', (select code || ' — ' || name from public.companies where id = f.owner_company_id),
    'transactions', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'txn_no', t.txn_no, 'type', t.txn_type, 'status', t.status,
                       'created_at', t.created_at, 'posted_at', t.posted_at, 'reference', t.reference,
                       'created_by', (select full_name from public.app_users where id = t.created_by),
                       'posted_by', (select full_name from public.app_users where id = t.posted_by)) order by t.created_at desc), '[]')
                     from public.stock_transactions t where t.id = any(f.txn_ids)),
    'employees', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', full_name, 'employee_number', employee_number)), '[]')
                  from public.app_users where id = any(f.user_ids)),
    'recent_ledger', (select coalesce(jsonb_agg(x order by (x ->> 'id')::bigint desc), '[]') from (
                       select jsonb_build_object('id', l.id, 'txn_no', t.txn_no, 'type', l.txn_type, 'qty_delta', l.qty_delta,
                              'balance_after', l.balance_after, 'posted_at', l.posted_at,
                              'posted_by', (select full_name from public.app_users where id = l.posted_by)) as x
                       from public.stock_ledger l join public.stock_transactions t on t.id = l.txn_id
                       where f.product_id is not null and l.product_id = f.product_id
                         and (f.location_id is null or l.location_id = f.location_id)
                         and (f.owner_company_id is null or l.owner_company_id = f.owner_company_id)
                         and (f.stock_status is null or l.status = f.stock_status)
                       order by l.id desc limit 25) s),
    'unexplained_changes', (select coalesce(jsonb_agg(jsonb_build_object('at', g.at, 'op', g.op, 'old_qty', g.old_qty, 'new_qty', g.new_qty,
                               'db_user', g.db_user) order by g.id desc), '[]')
                            from (select * from private.balance_change_log g
                                  where f.product_id is not null and g.product_id = f.product_id and g.location_id = f.location_id
                                    and g.owner_company_id = f.owner_company_id and g.status = f.stock_status and g.posting_txn_id is null
                                  order by id desc limit 25) g),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('at', e.at, 'event', e.event, 'note', e.note,
                     'actor', (select full_name from public.app_users where id = e.actor_id)) order by e.at), '[]')
               from integrity.finding_events e where e.finding_id = f.id),
    'assigned_to_name', (select full_name from public.app_users where id = f.assigned_to),
    'resolved_by_name', (select full_name from public.app_users where id = f.resolved_by),
    'resolution_txn_no', (select txn_no from public.stock_transactions where id = f.resolution_txn_id),
    'first_run_no', (select run_no from integrity.runs where id = f.first_run_id),
    'last_run_no', (select run_no from integrity.runs where id = f.last_run_id)));
end $$;

create or replace function public.integrity_runs(p_limit int default 30) returns setof jsonb
language plpgsql stable security definer set search_path = public, private, integrity, pg_temp as $$
begin
  perform private.require_perm('integrity.view');
  return query select to_jsonb(r) - 'checkpoint_xor' from integrity.runs r order by started_at desc limit least(coalesce(p_limit, 30), 500);
end $$;

create or replace function private.finding_for_update(p_finding_id uuid) returns integrity.findings
language plpgsql security definer set search_path = public, private, integrity, pg_temp as $$
declare f integrity.findings;
begin
  perform private.require_perm('integrity.investigate');
  select * into f from integrity.findings where id = p_finding_id for update;
  if not found or not private.finding_visible(f) then perform private.fail('CS401', 'Finding not found or not visible'); end if;
  return f;
end $$;

create or replace function public.integrity_assign(p_finding_id uuid, p_user_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, private, integrity, pg_temp as $$
declare f integrity.findings;
begin
  f := private.finding_for_update(p_finding_id);
  if f.status in ('resolved','dismissed') then perform private.fail('CS423', 'Finding is closed'); end if;
  if not exists (select 1 from public.app_users u join public.user_role_assignments a on a.user_id = u.id
                 join public.roles r on r.id = a.role_id where u.id = p_user_id and u.is_active and 'integrity.investigate' = any(r.permissions)) then
    perform private.fail('CS422', 'The selected user cannot investigate integrity findings');
  end if;
  update integrity.findings set assigned_to = p_user_id, assigned_at = now(), status = 'investigating' where id = p_finding_id;
  insert into integrity.finding_events (finding_id, actor_id, event, note, data)
  values (p_finding_id, auth.uid(), 'assigned', p_note, jsonb_build_object('assigned_to', p_user_id));
  insert into public.notifications (user_id, title, body, link)
  values (p_user_id, 'Integrity investigation assigned: ' || f.finding_no, f.title || ' — ' || f.description, '/integrity/findings/' || f.id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.integrity_add_note(p_finding_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public, private, integrity, pg_temp as $$
begin
  perform private.finding_for_update(p_finding_id);
  if coalesce(trim(p_note),'') = '' then perform private.fail('CS422', 'Note is empty'); end if;
  insert into integrity.finding_events (finding_id, actor_id, event, note) values (p_finding_id, auth.uid(), 'note', p_note);
  return jsonb_build_object('ok', true);
end $$;

-- p_status: 'resolved' (with resolution text and optionally the correcting adjustment) or 'dismissed'
-- (not a real discrepancy — requires integrity.admin) or 'open' to re-open.
create or replace function public.integrity_set_status(p_finding_id uuid, p_status text, p_resolution text, p_resolution_txn_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, private, integrity, pg_temp as $$
declare f integrity.findings; v_uid uuid := auth.uid();
begin
  f := private.finding_for_update(p_finding_id);
  if p_status not in ('resolved','dismissed','open') then perform private.fail('CS422', 'Invalid status'); end if;
  if coalesce(trim(p_resolution),'') = '' then perform private.fail('CS422', 'Explain the outcome of the investigation'); end if;
  if p_status = 'dismissed' then perform private.require_perm('integrity.admin'); end if;
  if p_status = 'resolved' and f.check_code = 'LEDGER_BALANCE_MISMATCH' and f.still_present then
    perform private.fail('CS423', 'This mismatch is still present. Correct it with an approved adjustment (or restore the record) and wait for the next check, or run a manual check, before resolving.');
  end if;
  if p_resolution_txn_id is not null and not exists (select 1 from public.stock_transactions where id = p_resolution_txn_id and status = 'posted') then
    perform private.fail('CS422', 'The resolution transaction must be a posted transaction');
  end if;
  update integrity.findings set status = p_status,
    resolved_by = case when p_status = 'open' then null else v_uid end,
    resolved_at = case when p_status = 'open' then null else now() end,
    resolution = case when p_status = 'open' then resolution else p_resolution end,
    resolution_txn_id = coalesce(p_resolution_txn_id, resolution_txn_id)
  where id = p_finding_id;
  insert into integrity.finding_events (finding_id, actor_id, event, note, data)
  values (p_finding_id, v_uid, 'status_' || p_status, p_resolution, jsonb_build_object('resolution_txn_id', p_resolution_txn_id));
  if p_status in ('resolved','dismissed') then
    perform private.resolve_alert('integrity:' || f.fingerprint, p_resolution);
  end if;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;

create or replace function public.integrity_run_now() returns jsonb
language plpgsql security definer set search_path = public, private, integrity, pg_temp as $$
declare v_uid uuid;
begin
  v_uid := private.require_perm('integrity.admin');
  perform private.log_action('INTEGRITY_RUN_MANUAL', 'integrity.runs', null, null);
  return integrity.run_check('manual', v_uid);
end $$;


-- ===== 20261023000600_security_views_api.sql =====
-- =============================================================================
-- CSWMS Migration 0600: Security (grants + row-level security), reporting
-- views, scan lookup, dashboard and administration API.
--
--   * anon has no access to anything.
--   * authenticated users READ through RLS-protected tables/views and WRITE
--     stock only through SECURITY DEFINER functions that check permissions.
--   * private and integrity schemas are not reachable except via the
--     specific helper functions used inside RLS policies.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Function execute privileges
-- -----------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on all functions in schema integrity from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon;
alter default privileges in schema private revoke execute on functions from public;
alter default privileges in schema integrity revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from public;

grant usage on schema private to authenticated;   -- needed to call the RLS helpers below; nothing else is granted
grant execute on function private.my_warehouses(text) to authenticated;
grant execute on function private.my_owner_companies(text) to authenticated;
grant execute on function private.has_perm(text) to authenticated;
grant execute on function private.has_group_perm(text) to authenticated;
grant execute on function private.has_wh_perm(text, uuid) to authenticated;

-- service_role (server-side only) may run the scheduler entry points
grant usage on schema integrity to service_role;
grant execute on function integrity.dispatch() to service_role;
grant execute on function integrity.watchdog() to service_role;

-- -----------------------------------------------------------------------------
-- Table privileges: start from nothing
-- -----------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;

-- Enable RLS on every public table
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

-- Reference data readable by every signed-in, active user -------------------
do $$
declare t text;
begin
  foreach t in array array['organisation','provinces','companies','branches','warehouses','storage_locations','uoms','categories',
                           'suppliers','products','product_uoms','barcodes','stock_thresholds','reason_codes','permissions','roles',
                           'app_settings','app_users']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (private.has_perm(''stock.view'') or private.has_perm(''stocktake.count'') or private.has_perm(''reports.view'') or private.has_perm(''users.manage'') or private.has_perm(''setup.manage''))',
                   t || '_read', t);
  end loop;
end $$;

-- Master data maintenance through the API (audited by triggers) --------------
grant insert, update on public.companies, public.branches, public.warehouses, public.storage_locations to authenticated;
create policy companies_write on public.companies for insert to authenticated with check (private.has_group_perm('setup.manage'));
create policy companies_update on public.companies for update to authenticated
  using (private.has_group_perm('setup.manage')) with check (private.has_group_perm('setup.manage'));
create policy branches_write on public.branches for insert to authenticated with check (company_id = any(private.my_owner_companies('setup.manage')));
create policy branches_update on public.branches for update to authenticated
  using (company_id = any(private.my_owner_companies('setup.manage'))) with check (company_id = any(private.my_owner_companies('setup.manage')));
create policy warehouses_write on public.warehouses for insert to authenticated
  with check ((select company_id from public.branches b where b.id = branch_id) = any(private.my_owner_companies('setup.manage')));
create policy warehouses_update on public.warehouses for update to authenticated
  using (id = any(private.my_warehouses('setup.manage'))) with check (id = any(private.my_warehouses('setup.manage')));
create policy locations_write on public.storage_locations for insert to authenticated
  with check (warehouse_id = any(private.my_warehouses('setup.manage')));
create policy locations_update on public.storage_locations for update to authenticated
  using (warehouse_id = any(private.my_warehouses('setup.manage'))) with check (warehouse_id = any(private.my_warehouses('setup.manage')));

grant insert, update on public.products, public.categories, public.suppliers, public.product_uoms, public.barcodes, public.stock_thresholds to authenticated;
grant delete on public.barcodes, public.stock_thresholds, public.product_uoms to authenticated;
do $$
declare t text;
begin
  foreach t in array array['products','categories','suppliers','product_uoms','barcodes','stock_thresholds'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check (private.has_perm(''product.manage''))', t || '_ins', t);
    execute format('create policy %I on public.%I for update to authenticated using (private.has_perm(''product.manage'')) with check (private.has_perm(''product.manage''))', t || '_upd', t);
  end loop;
  foreach t in array array['barcodes','stock_thresholds','product_uoms'] loop
    execute format('create policy %I on public.%I for delete to authenticated using (private.has_perm(''product.manage''))', t || '_del', t);
  end loop;
end $$;

grant insert, update on public.uoms, public.reason_codes, public.provinces to authenticated;
do $$
declare t text;
begin
  foreach t in array array['uoms','reason_codes','provinces'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check (private.has_group_perm(''settings.manage''))', t || '_ins', t);
    execute format('create policy %I on public.%I for update to authenticated using (private.has_group_perm(''settings.manage'')) with check (private.has_group_perm(''settings.manage''))', t || '_upd', t);
  end loop;
end $$;
grant update (name, logo_url) on public.organisation to authenticated;
create policy organisation_upd on public.organisation for update to authenticated
  using (private.has_group_perm('settings.manage')) with check (private.has_group_perm('settings.manage'));

grant insert, update on public.roles to authenticated;
create policy roles_ins on public.roles for insert to authenticated with check (private.has_group_perm('users.manage') and not is_system);
create policy roles_upd on public.roles for update to authenticated
  using (private.has_group_perm('users.manage')) with check (private.has_group_perm('users.manage'));
-- system role codes are fixed (permissions on them may be tuned by a super administrator)
create or replace function private.protect_system_roles() returns trigger language plpgsql as $$
begin
  if old.is_system and (new.code <> old.code or not new.is_system) then
    perform private.fail('CS422', 'System role codes cannot be changed');
  end if;
  if old.code = 'SUPER_ADMIN' and not (new.permissions @> array(select code from public.permissions)) then
    perform private.fail('CS422', 'The Super Administrator role must keep all permissions');
  end if;
  return new;
end $$;
create trigger roles_protect_system before update on public.roles for each row execute function private.protect_system_roles();

-- Costs (cost.view only) ----------------------------------------------------
grant select on public.product_costs, public.txn_line_costs to authenticated;
grant insert, update on public.product_costs to authenticated;
create policy product_costs_read on public.product_costs for select to authenticated using (private.has_perm('cost.view'));
create policy product_costs_ins on public.product_costs for insert to authenticated with check (private.has_perm('product.manage') and private.has_perm('cost.view'));
create policy product_costs_upd on public.product_costs for update to authenticated
  using (private.has_perm('product.manage') and private.has_perm('cost.view')) with check (private.has_perm('product.manage') and private.has_perm('cost.view'));
create policy txn_line_costs_read on public.txn_line_costs for select to authenticated
  using (private.has_perm('cost.view') and exists (select 1 from public.stock_transactions t where t.id = txn_id));

-- Stock (read only) -----------------------------------------------------------
grant select on public.stock_balances, public.stock_ledger, public.stock_transactions, public.stock_transaction_lines,
                public.stock_reservations, public.transfers, public.transfer_lines to authenticated;

create policy balances_read on public.stock_balances for select to authenticated using (
  warehouse_id = any(private.my_warehouses('stock.view')) or owner_company_id = any(private.my_owner_companies('stock.view')));
create policy ledger_read on public.stock_ledger for select to authenticated using (
  warehouse_id = any(private.my_warehouses('stock.view')) or owner_company_id = any(private.my_owner_companies('stock.view')));
create policy txn_read on public.stock_transactions for select to authenticated using (
  created_by = auth.uid() or warehouse_id = any(private.my_warehouses('stock.view'))
  or exists (select 1 from public.stock_ledger l where l.txn_id = stock_transactions.id and l.owner_company_id = any(private.my_owner_companies('stock.view'))));
create policy txn_lines_read on public.stock_transaction_lines for select to authenticated using (
  exists (select 1 from public.stock_transactions t where t.id = txn_id));
create policy reservations_read on public.stock_reservations for select to authenticated using (
  warehouse_id = any(private.my_warehouses('stock.view')));
create policy transfers_read on public.transfers for select to authenticated using (
  from_warehouse_id = any(private.my_warehouses('stock.view')) or to_warehouse_id = any(private.my_warehouses('stock.view'))
  or to_warehouse_id = any(private.my_warehouses('stock.transfer.receive')));
create policy transfer_lines_read on public.transfer_lines for select to authenticated using (
  exists (select 1 from public.transfers t where t.id = transfer_id));

-- Approvals, alerts, notifications -------------------------------------------
grant select on public.approval_requests, public.alerts, public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
create policy approvals_read on public.approval_requests for select to authenticated using (
  requested_by = auth.uid()
  or (warehouse_id is not null and warehouse_id = any(private.my_warehouses(required_perm)))
  or (warehouse_id is null and private.has_perm(required_perm))
  or private.has_perm('audit.view'));
create policy alerts_read on public.alerts for select to authenticated using (
  (alert_type not in ('integrity','integrity_monitor') or private.has_perm('integrity.view'))
  and ((warehouse_id is not null and warehouse_id = any(private.my_warehouses('stock.view')))
    or (warehouse_id is null and company_id is not null and company_id = any(private.my_owner_companies('stock.view')))
    or (warehouse_id is null and company_id is null and (private.has_group_perm('stock.view') or private.has_group_perm('integrity.view')))
    or exists (select 1 from public.notifications n where n.alert_id = alerts.id and n.user_id = auth.uid())));
create policy notifications_read on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_update on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Import ----------------------------------------------------------------------
grant select on public.import_batches, public.import_rows to authenticated;
create policy import_batches_read on public.import_batches for select to authenticated using (
  private.has_perm('import.manage') or private.has_perm('import.approve') or private.has_perm('audit.view'));
create policy import_rows_read on public.import_rows for select to authenticated using (
  exists (select 1 from public.import_batches b where b.id = batch_id));

-- Stocktakes (expected quantities hidden from counters while counting) --------
grant select on public.stocktakes, public.stocktake_assignments, public.stocktake_lines, public.stocktake_counts to authenticated;
-- helpers bypass RLS so the stocktake <-> assignment policies do not reference each other recursively
create or replace function private.is_stocktake_assignee(p_stocktake uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.stocktake_assignments where stocktake_id = p_stocktake and user_id = auth.uid())
$$;
create or replace function private.stocktake_warehouse(p_stocktake uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select warehouse_id from public.stocktakes where id = p_stocktake
$$;
grant execute on function private.is_stocktake_assignee(uuid) to authenticated;
grant execute on function private.stocktake_warehouse(uuid) to authenticated;

create policy stocktakes_read on public.stocktakes for select to authenticated using (
  warehouse_id = any(private.my_warehouses('stock.view')) or warehouse_id = any(private.my_warehouses('stocktake.manage'))
  or warehouse_id = any(private.my_warehouses('stocktake.approve')) or private.is_stocktake_assignee(id));
create policy stocktake_assignments_read on public.stocktake_assignments for select to authenticated using (
  user_id = auth.uid() or private.stocktake_warehouse(stocktake_id) = any(private.my_warehouses('stocktake.manage'))
  or private.stocktake_warehouse(stocktake_id) = any(private.my_warehouses('stocktake.approve')));
create policy stocktake_lines_read on public.stocktake_lines for select to authenticated using (
  exists (select 1 from public.stocktakes s where s.id = stocktake_id and (
     s.warehouse_id = any(private.my_warehouses('stocktake.manage')) or s.warehouse_id = any(private.my_warehouses('stocktake.approve'))
     or (s.status in ('review','pending_approval','finalised','cancelled') and s.warehouse_id = any(private.my_warehouses('stock.view')))
     or (not s.blind and s.warehouse_id = any(private.my_warehouses('stock.view'))))));
create policy stocktake_counts_read on public.stocktake_counts for select to authenticated using (
  counted_by = auth.uid() or exists (select 1 from public.stocktake_lines l where l.id = line_id));

-- Users & audit -----------------------------------------------------------------
grant select on public.user_role_assignments, public.audit_log to authenticated;
create policy ura_read on public.user_role_assignments for select to authenticated using (
  user_id = auth.uid() or private.has_perm('users.manage') or private.has_perm('audit.view'));
create policy audit_read on public.audit_log for select to authenticated using (private.has_perm('audit.view'));

-- service_role (server only) bypasses RLS; give it read access for server-side reports & jobs
grant select on all tables in schema public to service_role;
grant usage on schema private to service_role;
grant select, update on private.email_outbox to service_role;

-- -----------------------------------------------------------------------------
-- Convenience views (security_invoker: the caller's RLS applies)
-- -----------------------------------------------------------------------------
create view public.v_warehouse_tree with (security_invoker = true) as
  select w.id as warehouse_id, w.code as warehouse_code, w.name as warehouse_name, w.status as warehouse_status,
         b.id as branch_id, b.code as branch_code, b.name as branch_name,
         c.id as company_id, c.code as company_code, c.name as company_name,
         p.id as province_id, p.name as province_name
  from public.warehouses w
  join public.branches b on b.id = w.branch_id
  join public.companies c on c.id = b.company_id
  join public.provinces p on p.id = b.province_id;

create view public.v_stock_balances with (security_invoker = true) as
  select b.product_id, p.sku, p.description, p.category_id, cat.name as category_name, pc.name as parent_category_name,
         u.code as uom, u.decimals as uom_decimals,
         b.location_id, sl.code as location_code, sl.name as location_name, sl.kind as location_kind,
         b.warehouse_id, t.warehouse_code, t.warehouse_name, t.branch_id, t.branch_code, t.branch_name,
         t.company_id, t.company_code, t.company_name, t.province_id, t.province_name,
         b.owner_company_id, oc.code as owner_company_code, oc.name as owner_company_name,
         (b.owner_company_id <> t.company_id) as stored_for_other_company,
         b.status, b.qty, b.updated_at, p.status as product_status
  from public.stock_balances b
  join public.products p on p.id = b.product_id
  join public.uoms u on u.id = p.base_uom_id
  left join public.categories cat on cat.id = p.category_id
  left join public.categories pc on pc.id = cat.parent_id
  join public.storage_locations sl on sl.id = b.location_id
  join public.v_warehouse_tree t on t.warehouse_id = b.warehouse_id
  join public.companies oc on oc.id = b.owner_company_id;

-- per product & warehouse: on-hand by status, reserved, available-to-use, thresholds
create view public.v_stock_by_warehouse with (security_invoker = true) as
  with agg as (
    select product_id, warehouse_id,
           sum(qty) filter (where status = 'available') as available,
           sum(qty) filter (where status = 'damaged') as damaged,
           sum(qty) filter (where status = 'quarantine') as quarantine,
           sum(qty) filter (where status = 'in_transit') as in_transit
    from public.stock_balances group by 1, 2),
  res as (
    select product_id, warehouse_id, sum(qty_reserved - qty_fulfilled) as reserved
    from public.stock_reservations where status = 'active' and (expires_at is null or expires_at > now()) group by 1, 2)
  select a.product_id, p.sku, p.description, p.category_id, u.code as uom,
         a.warehouse_id, t.warehouse_code, t.warehouse_name, t.branch_id, t.branch_code, t.branch_name,
         t.company_id, t.company_code, t.company_name, t.province_id, t.province_name,
         coalesce(a.available, 0) as available, coalesce(a.damaged, 0) as damaged, coalesce(a.quarantine, 0) as quarantine,
         coalesce(a.in_transit, 0) as in_transit, coalesce(r.reserved, 0) as reserved,
         greatest(coalesce(a.available, 0) - coalesce(r.reserved, 0), 0) as free_to_use,
         th.min_qty, th.reorder_qty,
         case when th.min_qty is null or th.min_qty <= 0 then 'ok'
              when coalesce(a.available, 0) <= 0 then 'out'
              when coalesce(a.available, 0) <= th.min_qty then 'low' else 'ok' end as stock_level
  from agg a
  join public.products p on p.id = a.product_id
  join public.uoms u on u.id = p.base_uom_id
  join public.v_warehouse_tree t on t.warehouse_id = a.warehouse_id
  left join res r on r.product_id = a.product_id and r.warehouse_id = a.warehouse_id
  left join lateral (select st.min_qty, st.reorder_qty from public.stock_thresholds st
                     where st.product_id = a.product_id and (st.warehouse_id = a.warehouse_id or st.warehouse_id is null)
                     order by st.warehouse_id nulls last limit 1) th on true;

create view public.v_transactions with (security_invoker = true) as
  select t.id, t.txn_no, t.txn_type, t.status, t.warehouse_id, wt.warehouse_code, wt.warehouse_name, wt.branch_code, wt.company_code,
         t.reference, t.notes, rc.code as reason_code, rc.label as reason_label, s.name as supplier_name,
         t.related_txn_id, rt.txn_no as related_txn_no, t.transfer_id, t.stocktake_id, t.import_batch_id,
         t.is_unusual, t.unusual_info, t.created_by, cu.full_name as created_by_name, t.created_at,
         t.posted_by, pu.full_name as posted_by_name, t.posted_at,
         (select count(*) from public.stock_transaction_lines l where l.txn_id = t.id) as line_count
  from public.stock_transactions t
  left join public.v_warehouse_tree wt on wt.warehouse_id = t.warehouse_id
  left join public.reason_codes rc on rc.id = t.reason_code_id
  left join public.suppliers s on s.id = t.supplier_id
  left join public.stock_transactions rt on rt.id = t.related_txn_id
  left join public.app_users cu on cu.id = t.created_by
  left join public.app_users pu on pu.id = t.posted_by;

create view public.v_movements with (security_invoker = true) as
  select l.id, l.txn_id, t.txn_no, l.txn_type, t.reference, rc.label as reason_label, l.product_id, p.sku, p.description,
         p.category_id, u.code as uom, l.warehouse_id, wt.warehouse_code, wt.branch_code, wt.company_code, wt.company_id, wt.branch_id,
         l.location_id, sl.code as location_code, l.owner_company_id, oc.code as owner_company_code, l.status, l.qty_delta,
         l.entered_qty, eu.code as entered_uom, l.factor, l.balance_after, l.posted_by, au.full_name as posted_by_name, l.posted_at,
         t.created_by, cu.full_name as created_by_name, t.notes, t.is_unusual
  from public.stock_ledger l
  join public.stock_transactions t on t.id = l.txn_id
  join public.products p on p.id = l.product_id
  join public.uoms u on u.id = p.base_uom_id
  join public.uoms eu on eu.id = l.entered_uom_id
  join public.v_warehouse_tree wt on wt.warehouse_id = l.warehouse_id
  join public.storage_locations sl on sl.id = l.location_id
  join public.companies oc on oc.id = l.owner_company_id
  left join public.reason_codes rc on rc.id = t.reason_code_id
  left join public.app_users au on au.id = l.posted_by
  left join public.app_users cu on cu.id = t.created_by;

create view public.v_transfers with (security_invoker = true) as
  select tr.*, fw.warehouse_code as from_warehouse_code, fw.warehouse_name as from_warehouse_name, fw.branch_code as from_branch_code,
         fw.company_code as from_company_code, tw.warehouse_code as to_warehouse_code, tw.warehouse_name as to_warehouse_name,
         tw.branch_code as to_branch_code, tw.company_code as to_company_code, oc.code as to_owner_company_code,
         cu.full_name as created_by_name, du.full_name as dispatched_by_name,
         (select count(*) from public.transfer_lines l where l.transfer_id = tr.id) as line_count,
         (select coalesce(sum(qty_dispatched - qty_received - qty_damaged - qty_written_off), 0) from public.transfer_lines l where l.transfer_id = tr.id) as outstanding_qty,
         (tr.status in ('dispatched','partially_received') and now() > tr.expected_arrival_at
            + make_interval(hours => private.setting_num('transfer.overdue_grace_hours', 24)::int)) as is_overdue
  from public.transfers tr
  join public.v_warehouse_tree fw on fw.warehouse_id = tr.from_warehouse_id
  join public.v_warehouse_tree tw on tw.warehouse_id = tr.to_warehouse_id
  left join public.companies oc on oc.id = tr.to_owner_company_id
  left join public.app_users cu on cu.id = tr.created_by
  left join public.app_users du on du.id = tr.dispatched_by;

create view public.v_stocktake_summary with (security_invoker = true) as
  select s.id, s.stocktake_no, s.name, s.period, s.status, s.blind, s.due_date, s.cutoff_at, s.submitted_at, s.finalised_at,
         s.warehouse_id, wt.warehouse_code, wt.warehouse_name, wt.branch_id, wt.branch_code, wt.branch_name,
         wt.company_id, wt.company_code, wt.company_name, wt.province_name,
         (s.status not in ('finalised','cancelled') and s.due_date < (now() at time zone 'Africa/Johannesburg')::date) as is_overdue,
         x.lines, x.counted, x.discrepancies, x.missing, x.additional, x.not_counted, x.recounts,
         case when x.lines > 0 then round(100.0 * x.counted / x.lines, 1) else 0 end as pct_counted
  from public.stocktakes s
  join public.v_warehouse_tree wt on wt.warehouse_id = s.warehouse_id
  left join lateral (
    select count(*) as lines, count(*) filter (where counted_qty is not null) as counted,
           count(*) filter (where variance <> 0) as discrepancies, count(*) filter (where variance < 0) as missing,
           count(*) filter (where variance > 0) as additional, count(*) filter (where counted_qty is null) as not_counted,
           count(*) filter (where current_round > 1) as recounts
    from public.stocktake_lines l where l.stocktake_id = s.id) x on true;

create view public.v_approvals with (security_invoker = true) as
  select a.*, ru.full_name as requested_by_name, du.full_name as decided_by_name, wt.warehouse_code, wt.branch_code, wt.company_code,
         t.txn_no, t.txn_type
  from public.approval_requests a
  left join public.app_users ru on ru.id = a.requested_by
  left join public.app_users du on du.id = a.decided_by
  left join public.v_warehouse_tree wt on wt.warehouse_id = a.warehouse_id
  left join public.stock_transactions t on t.id = a.txn_id;

grant select on public.v_warehouse_tree, public.v_stock_balances, public.v_stock_by_warehouse, public.v_transactions, public.v_movements,
                public.v_transfers, public.v_stocktake_summary, public.v_approvals to authenticated;
grant execute on function private.setting_num(text, numeric) to authenticated;

-- -----------------------------------------------------------------------------
-- Scan / lookup API
-- -----------------------------------------------------------------------------
create or replace function public.lookup_code(p_code text, p_warehouse_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_code text := trim(p_code); v_bar public.barcodes; v_prod public.products; v_loc public.storage_locations; v_uom uuid;
        v_whs uuid[];
begin
  if auth.uid() is null or not private.is_active_user() then perform private.fail('CS401', 'Not signed in'); end if;
  if v_code is null or v_code = '' then return jsonb_build_object('kind', 'none'); end if;
  v_whs := private.my_warehouses('stock.view') || private.my_warehouses('stocktake.count');

  select * into v_bar from public.barcodes where code = v_code;
  if found then
    select * into v_prod from public.products where id = v_bar.product_id;
    v_uom := v_bar.uom_id;
  else
    select * into v_prod from public.products where upper(sku) = upper(v_code);
  end if;

  if v_prod.id is null then
    select * into v_loc from public.storage_locations where label_code = v_code or (p_warehouse_id is not null and warehouse_id = p_warehouse_id and code = upper(v_code));
    if v_loc.id is not null then
      return jsonb_build_object('kind', 'location', 'location', jsonb_build_object(
        'id', v_loc.id, 'code', v_loc.code, 'name', v_loc.name, 'warehouse_id', v_loc.warehouse_id, 'status', v_loc.status,
        'warehouse_code', (select code from public.warehouses where id = v_loc.warehouse_id),
        'in_selected_warehouse', p_warehouse_id is null or v_loc.warehouse_id = p_warehouse_id));
    end if;
    return jsonb_build_object('kind', 'none', 'code', v_code);
  end if;

  return jsonb_build_object('kind', 'product',
    'product', jsonb_build_object('id', v_prod.id, 'sku', v_prod.sku, 'description', v_prod.description, 'status', v_prod.status,
       'is_asset', v_prod.is_asset, 'image_path', v_prod.image_path,
       'base_uom', (select jsonb_build_object('id', id, 'code', code, 'decimals', decimals) from public.uoms where id = v_prod.base_uom_id),
       'category', (select name from public.categories where id = v_prod.category_id)),
    'scanned_uom_id', coalesce(v_uom, v_prod.base_uom_id),
    'units', (select jsonb_agg(jsonb_build_object('uom_id', pu.uom_id, 'code', u.code, 'name', u.name, 'factor', pu.factor_to_base,
                                                  'decimals', u.decimals, 'is_default_issue', pu.is_default_issue) order by pu.factor_to_base)
              from public.product_uoms pu join public.uoms u on u.id = pu.uom_id where pu.product_id = v_prod.id),
    'balances', (select coalesce(jsonb_agg(jsonb_build_object('location_id', b.location_id, 'location_code', sl.code, 'location_name', sl.name,
                    'owner_company_id', b.owner_company_id, 'owner_company_code', c.code, 'status', b.status, 'qty', b.qty)
                    order by b.status, sl.code), '[]')
                 from public.stock_balances b join public.storage_locations sl on sl.id = b.location_id
                 join public.companies c on c.id = b.owner_company_id
                 where b.product_id = v_prod.id and b.qty <> 0 and b.warehouse_id = any(v_whs)
                   and (p_warehouse_id is null or b.warehouse_id = p_warehouse_id)),
    'warehouse_available', (select coalesce(sum(qty), 0) from public.stock_balances
                            where product_id = v_prod.id and status = 'available' and warehouse_id = p_warehouse_id
                              and warehouse_id = any(v_whs)),
    'reserved', (select coalesce(sum(qty_reserved - qty_fulfilled), 0) from public.stock_reservations
                 where product_id = v_prod.id and warehouse_id = p_warehouse_id and status = 'active'
                   and (expires_at is null or expires_at > now())),
    'threshold', (select jsonb_build_object('min_qty', min_qty, 'reorder_qty', reorder_qty) from private.threshold_for(v_prod.id, p_warehouse_id)));
end $$;

create or replace function public.search_products(p_query text, p_warehouse_id uuid default null, p_limit int default 25)
returns table (id uuid, sku text, description text, uom text, category text, status public.record_status, available numeric)
language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_whs uuid[];
begin
  if auth.uid() is null or not private.is_active_user() then perform private.fail('CS401', 'Not signed in'); end if;
  v_whs := private.my_warehouses('stock.view') || private.my_warehouses('stocktake.count');
  return query
  select p.id, p.sku, p.description, u.code, c.name, p.status,
         (select coalesce(sum(b.qty), 0) from public.stock_balances b where b.product_id = p.id and b.status = 'available'
            and b.warehouse_id = any(v_whs) and (p_warehouse_id is null or b.warehouse_id = p_warehouse_id))
  from public.products p join public.uoms u on u.id = p.base_uom_id left join public.categories c on c.id = p.category_id
  where coalesce(trim(p_query), '') <> ''
    and (p.sku ilike '%' || trim(p_query) || '%' or p.description ilike '%' || trim(p_query) || '%'
         or exists (select 1 from public.barcodes bc where bc.product_id = p.id and bc.code = trim(p_query)))
  order by (upper(p.sku) = upper(trim(p_query))) desc, (p.status = 'active') desc, p.sku
  limit least(coalesce(p_limit, 25), 100);
end $$;

-- -----------------------------------------------------------------------------
-- Dashboard
-- -----------------------------------------------------------------------------
create or replace function public.dashboard_summary() returns jsonb
language plpgsql stable security definer set search_path = public, private, integrity, pg_temp as $$
declare v_whs uuid[]; v_owner uuid[]; v_period text := to_char(now() at time zone 'Africa/Johannesburg', 'YYYY-MM'); v jsonb;
begin
  if auth.uid() is null or not private.is_active_user() then perform private.fail('CS401', 'Not signed in'); end if;
  v_whs := private.my_warehouses('stock.view');
  v_owner := private.my_owner_companies('stock.view');

  with bal as (
    select b.*, t.company_id, t.company_code, t.company_name, t.branch_code, t.branch_name, t.province_name,
           t.warehouse_code, t.warehouse_name, u.code as uom
    from public.stock_balances b join private.warehouse_tree t on t.warehouse_id = b.warehouse_id
    join public.products p on p.id = b.product_id join public.uoms u on u.id = p.base_uom_id
    where (b.warehouse_id = any(v_whs) or b.owner_company_id = any(v_owner)) and b.qty <> 0),
  lvl as (
    select product_id, warehouse_id, sum(qty) filter (where status = 'available') as avail from bal group by 1, 2)
  select jsonb_build_object(
    'scope_warehouses', cardinality(v_whs),
    'active_products', (select count(*) from public.products where status = 'active'),
    'products_in_stock', (select count(distinct product_id) from bal where status = 'available'),
    'by_company', (select coalesce(jsonb_agg(x order by x ->> 'code'), '[]') from (
        select jsonb_build_object('code', oc.code, 'name', oc.name, 'products', count(distinct b.product_id),
               'locations', count(distinct b.location_id),
               'qty_by_uom', (select jsonb_object_agg(uom, q) from (select b2.uom, sum(b2.qty) q from bal b2
                               where b2.owner_company_id = oc.id and b2.status = 'available' group by 1) z)) as x
        from bal b join public.companies oc on oc.id = b.owner_company_id where b.status = 'available' group by oc.id, oc.code, oc.name) s),
    'by_province', (select coalesce(jsonb_agg(jsonb_build_object('province', province_name, 'products', n, 'warehouses', w) order by province_name), '[]')
                    from (select province_name, count(distinct product_id) n, count(distinct warehouse_id) w from bal where status = 'available' group by 1) s),
    'by_branch', (select coalesce(jsonb_agg(jsonb_build_object('branch', branch_code, 'name', branch_name, 'company', company_code, 'products', n) order by branch_code), '[]')
                  from (select branch_code, branch_name, company_code, count(distinct product_id) n from bal where status = 'available' group by 1,2,3) s),
    'by_warehouse', (select coalesce(jsonb_agg(jsonb_build_object('warehouse', warehouse_code, 'name', warehouse_name, 'branch', branch_code,
                         'products', n, 'damaged_lines', d, 'in_transit_lines', it) order by warehouse_code), '[]')
                     from (select warehouse_code, warehouse_name, branch_code, count(distinct product_id) filter (where status = 'available') n,
                                  count(*) filter (where status = 'damaged') d, count(*) filter (where status = 'in_transit') it
                           from bal group by 1,2,3) s),
    'low_stock', (select count(*) from public.alerts a where a.alert_type = 'low_stock' and a.status <> 'resolved' and a.warehouse_id = any(v_whs)),
    'out_of_stock', (select count(*) from public.alerts a where a.alert_type = 'out_of_stock' and a.status <> 'resolved' and a.warehouse_id = any(v_whs)),
    'outstanding_transfers', (select count(*) from public.transfers t where t.status in ('dispatched','partially_received')
                              and (t.from_warehouse_id = any(v_whs) or t.to_warehouse_id = any(v_whs))),
    'overdue_transfers', (select count(*) from public.transfers t where t.status in ('dispatched','partially_received')
                          and (t.from_warehouse_id = any(v_whs) or t.to_warehouse_id = any(v_whs))
                          and now() > t.expected_arrival_at + make_interval(hours => private.setting_num('transfer.overdue_grace_hours', 24)::int)),
    'pending_approvals', (select count(*) from public.approval_requests a where a.status = 'pending' and a.requested_by <> auth.uid()
                          and ((a.warehouse_id is not null and a.warehouse_id = any(private.my_warehouses(a.required_perm)))
                               or (a.warehouse_id is null and private.has_perm(a.required_perm)))),
    'my_pending_requests', (select count(*) from public.approval_requests a where a.status = 'pending' and a.requested_by = auth.uid()),
    'recent_withdrawals', (select coalesce(jsonb_agg(x), '[]') from (
        select jsonb_build_object('txn_id', t.id, 'txn_no', t.txn_no, 'at', t.posted_at, 'warehouse', w.code, 'reference', t.reference,
               'by', u.full_name, 'unusual', t.is_unusual,
               'items', (select string_agg(p.sku || ' ×' || trim(to_char(l.entered_qty, 'FM999999990.####')) || ' ' || eu.code, ', ')
                         from public.stock_transaction_lines l join public.products p on p.id = l.product_id join public.uoms eu on eu.id = l.entered_uom_id
                         where l.txn_id = t.id)) as x
        from public.stock_transactions t join public.warehouses w on w.id = t.warehouse_id left join public.app_users u on u.id = t.created_by
        where t.txn_type = 'withdrawal' and t.status = 'posted' and t.warehouse_id = any(v_whs)
        order by t.posted_at desc limit 8) s),
    'stocktake', (select jsonb_build_object('period', v_period, 'total', count(*), 'finalised', count(*) filter (where status = 'finalised'),
                    'in_progress', count(*) filter (where status in ('counting','review','pending_approval')),
                    'not_started', count(*) filter (where status = 'scheduled'),
                    'overdue', count(*) filter (where status not in ('finalised','cancelled') and due_date < (now() at time zone 'Africa/Johannesburg')::date),
                    'warehouses_without_stocktake', (select count(*) from public.warehouses w where w.status = 'active' and w.id = any(v_whs)
                        and not exists (select 1 from public.stocktakes s2 where s2.warehouse_id = w.id and s2.period = v_period and s2.status <> 'cancelled')))
                  from public.stocktakes where period = v_period and status <> 'cancelled' and warehouse_id = any(v_whs)),
    'stocktake_discrepancies', (select count(*) from public.stocktake_lines l join public.stocktakes s on s.id = l.stocktake_id
                                where s.status in ('review','pending_approval') and l.variance <> 0 and s.warehouse_id = any(v_whs)),
    'integrity', case when private.has_perm('integrity.view') then integrity.current_status() end,
    'open_alerts', (select coalesce(jsonb_object_agg(alert_type, n), '{}') from (
                     select alert_type, count(*) n from public.alerts a where a.status <> 'resolved'
                       and (a.warehouse_id = any(v_whs) or (a.warehouse_id is null and private.has_group_perm('stock.view')))
                       and (a.alert_type not in ('integrity','integrity_monitor') or private.has_perm('integrity.view'))
                     group by 1) s)
  ) into v;
  return v;
end $$;

-- Who am I: profile, roles, permission set and accessible warehouses (for the UI)
create or replace function public.my_context() returns jsonb
language plpgsql volatile security definer set search_path = public, private, pg_temp as $$
declare v_u public.app_users;
begin
  select * into v_u from public.app_users where id = auth.uid();
  if not found then return jsonb_build_object('registered', false); end if;
  update public.app_users set last_seen_at = now() where id = v_u.id and (last_seen_at is null or last_seen_at < now() - interval '5 minutes');
  return jsonb_build_object('registered', true, 'active', v_u.is_active,
    'user', jsonb_build_object('id', v_u.id, 'email', v_u.email, 'full_name', v_u.full_name, 'employee_number', v_u.employee_number),
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
                      'branch_code', t.branch_code, 'company_code', t.company_code, 'company_id', t.company_id,
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
-- Alerts & notifications
-- -----------------------------------------------------------------------------
create or replace function public.acknowledge_alert(p_alert_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_a public.alerts;
begin
  select * into v_a from public.alerts where id = p_alert_id for update;
  if not found then perform private.fail('CS422', 'Alert not found'); end if;
  if not ((v_a.warehouse_id is not null and private.has_wh_perm('stock.view', v_a.warehouse_id)) or private.has_group_perm('stock.view')
          or exists (select 1 from public.notifications where alert_id = p_alert_id and user_id = auth.uid())) then
    perform private.fail('CS401', 'Not permitted');
  end if;
  update public.alerts set status = 'acknowledged', acknowledged_by = auth.uid(), acknowledged_at = now(),
         resolution_note = coalesce(p_note, resolution_note) where id = p_alert_id and status = 'open';
  update public.notifications set read_at = now() where alert_id = p_alert_id and user_id = auth.uid() and read_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- Operational alerts may be closed manually; integrity alerts close only through their findings,
-- and stock-level alerts close automatically when stock is replenished.
create or replace function public.resolve_alert(p_alert_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_a public.alerts;
begin
  select * into v_a from public.alerts where id = p_alert_id for update;
  if not found then perform private.fail('CS422', 'Alert not found'); end if;
  if v_a.alert_type in ('integrity','integrity_monitor','low_stock','out_of_stock','approval_pending') then
    perform private.fail('CS423', 'This alert closes automatically when the underlying issue is resolved');
  end if;
  if not ((v_a.warehouse_id is not null and private.has_wh_perm('stock.approve', v_a.warehouse_id)) or private.has_group_perm('stock.approve')) then
    perform private.fail('CS401', 'Only managers can close this alert');
  end if;
  if coalesce(trim(p_note),'') = '' then perform private.fail('CS422', 'A note is required'); end if;
  update public.alerts set status = 'resolved', resolved_by = auth.uid(), resolved_at = now(), resolution_note = p_note where id = p_alert_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns jsonb language sql security definer set search_path = public, pg_temp as $$
  with u as (update public.notifications set read_at = now()
             where user_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids)) returning 1)
  select jsonb_build_object('ok', true, 'updated', (select count(*) from u))
$$;

-- -----------------------------------------------------------------------------
-- Barcodes & labels
-- -----------------------------------------------------------------------------
create sequence private.generated_barcode_seq start 100000;
create or replace function public.generate_barcode(p_product_id uuid, p_uom_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_code text; v_id uuid;
begin
  perform private.require_perm('product.manage');
  if not exists (select 1 from public.products where id = p_product_id) then perform private.fail('CS422', 'Unknown product'); end if;
  loop
    v_code := 'CS' || lpad(nextval('private.generated_barcode_seq')::text, 10, '0');
    exit when not exists (select 1 from public.barcodes where code = v_code) and not exists (select 1 from public.storage_locations where label_code = v_code);
  end loop;
  insert into public.barcodes (code, product_id, uom_id, symbology, is_generated, is_primary)
  values (v_code, p_product_id, p_uom_id, 'CODE128', true,
          p_uom_id is null and not exists (select 1 from public.barcodes where product_id = p_product_id and is_primary))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'barcode_id', v_id, 'code', v_code);
end $$;

-- storage-location label codes default to LOC-<warehouse>-<location>
create or replace function private.default_label_code() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.label_code is null or trim(new.label_code) = '' then
    new.label_code := 'LOC-' || (select code from public.warehouses where id = new.warehouse_id) || '-' || new.code;
  end if;
  if exists (select 1 from public.barcodes where code = new.label_code) then
    raise exception using errcode = 'CS422', message = 'Location label code is already used as a product barcode';
  end if;
  return new;
end $$;
create trigger storage_locations_label before insert on public.storage_locations
  for each row execute function private.default_label_code();
alter table public.storage_locations alter column label_code drop not null;
alter table public.storage_locations add constraint storage_locations_label_required check (label_code is not null);

-- -----------------------------------------------------------------------------
-- Settings
-- -----------------------------------------------------------------------------
create or replace function public.update_setting(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_old jsonb; v_t time;
begin
  select value into v_old from public.app_settings where key = p_key;
  if not found then perform private.fail('CS422', 'Unknown setting'); end if;
  if p_key like 'integrity.%' then perform private.require_perm('integrity.admin');
  elsif p_key like 'auth.%' then
    perform private.require_perm('users.manage');
    if not private.has_group_perm('users.manage') then perform private.fail('CS401', 'Group-level user administration is required'); end if;
  else
    perform private.require_perm('settings.manage');
    if not private.has_group_perm('settings.manage') then perform private.fail('CS401', 'Group-level settings permission is required'); end if;
  end if;
  if jsonb_typeof(p_value) <> jsonb_typeof(v_old) then perform private.fail('CS422', 'Value has the wrong type'); end if;
  if jsonb_typeof(p_value) = 'number' and (p_value #>> '{}')::numeric < 0 then perform private.fail('CS422', 'Value cannot be negative'); end if;
  if p_key in ('integrity.daily_run_time','business.working_hours_start','business.working_hours_end') then
    begin v_t := (p_value #>> '{}')::time; exception when others then perform private.fail('CS422', 'Use HH:MM'); end;
  end if;
  if p_key = 'integrity.stale_after_hours' and (p_value #>> '{}')::numeric < 24 then
    perform private.fail('CS422', 'Must be at least 24 hours for a daily check');
  end if;
  update public.app_settings set value = p_value, updated_by = auth.uid(), updated_at = now() where key = p_key;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- User administration (auth users are created server-side with the service key;
-- these functions maintain the profile and role assignments)
-- -----------------------------------------------------------------------------
create or replace function private.can_manage_user_scope(p_scope_type public.scope_type, p_scope_id uuid) returns boolean
language sql stable security definer set search_path = public, private, pg_temp as $$
  select private.has_group_perm('users.manage')
      or (p_scope_type = 'company' and p_scope_id = any(private.my_owner_companies('users.manage')))
      or (p_scope_type = 'branch' and (select company_id from public.branches where id = p_scope_id) = any(private.my_owner_companies('users.manage')))
      or (p_scope_type = 'warehouse' and p_scope_id = any(private.my_warehouses('users.manage'))
          and (select t.company_id from private.warehouse_tree t where t.warehouse_id = p_scope_id) = any(private.my_owner_companies('users.manage')))
$$;

create or replace function public.admin_upsert_user(
  p_user_id uuid, p_email text, p_full_name text, p_employee_number text default null, p_phone text default null, p_is_active boolean default true)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid;
begin
  v_uid := private.require_perm('users.manage');
  if coalesce(trim(p_full_name),'') = '' or coalesce(trim(p_email),'') = '' then perform private.fail('CS422', 'Name and e-mail are required'); end if;
  if p_user_id = v_uid and not p_is_active then perform private.fail('CS422', 'You cannot deactivate your own account'); end if;
  if exists (select 1 from public.app_users where id = p_user_id) and not private.has_group_perm('users.manage')
     and exists (select 1 from public.user_role_assignments a where a.user_id = p_user_id and not private.can_manage_user_scope(a.scope_type, a.scope_id)) then
    perform private.fail('CS401', 'This user has roles outside your administration scope');
  end if;
  insert into public.app_users (id, email, full_name, employee_number, phone, is_active)
  values (p_user_id, lower(trim(p_email)), trim(p_full_name), nullif(trim(p_employee_number),''), nullif(trim(p_phone),''), coalesce(p_is_active, true))
  on conflict (id) do update set email = excluded.email, full_name = excluded.full_name, employee_number = excluded.employee_number,
     phone = excluded.phone, is_active = excluded.is_active;
  return jsonb_build_object('ok', true);
end $$;

-- p_assignments: [{role_id, scope_type, scope_id}] — replaces the user's assignments within the caller's scope
create or replace function public.admin_set_user_roles(p_user_id uuid, p_assignments jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; a jsonb; v_role public.roles; v_scope public.scope_type; v_scope_id uuid; v_mine text[];
begin
  v_uid := private.require_perm('users.manage');
  if not exists (select 1 from public.app_users where id = p_user_id) then perform private.fail('CS422', 'Unknown user'); end if;
  select coalesce(array_agg(distinct p), '{}') into v_mine from public.user_role_assignments ua join public.roles r on r.id = ua.role_id,
         unnest(r.permissions) p where ua.user_id = v_uid;
  -- the caller may only remove assignments they could have granted
  delete from public.user_role_assignments ua where ua.user_id = p_user_id and private.can_manage_user_scope(ua.scope_type, ua.scope_id);
  for a in select * from jsonb_array_elements(coalesce(p_assignments, '[]')) loop
    select * into v_role from public.roles where id = (a ->> 'role_id')::uuid;
    if not found then perform private.fail('CS422', 'Unknown role'); end if;
    v_scope := (a ->> 'scope_type')::public.scope_type;
    v_scope_id := nullif(a ->> 'scope_id','')::uuid;
    if not private.can_manage_user_scope(v_scope, v_scope_id) then
      perform private.fail('CS401', 'You cannot assign roles at this scope');
    end if;
    if not private.has_group_perm('users.manage') and not (v_role.permissions <@ v_mine) then
      perform private.fail('CS401', 'You cannot grant a role with permissions you do not hold yourself: ' || v_role.name);
    end if;
    if p_user_id = v_uid and v_role.code = 'SUPER_ADMIN' and v_scope <> 'group' then
      perform private.fail('CS422', 'Super Administrator must be assigned at group level');
    end if;
    insert into public.user_role_assignments (user_id, role_id, scope_type, scope_id, created_by)
    values (p_user_id, v_role.id, v_scope, v_scope_id, v_uid) on conflict do nothing;
  end loop;
  -- never lock the group out: at least one active super administrator must remain
  if not exists (select 1 from public.user_role_assignments ua join public.roles r on r.id = ua.role_id and r.code = 'SUPER_ADMIN'
                 join public.app_users u on u.id = ua.user_id and u.is_active where ua.scope_type = 'group') then
    perform private.fail('CS422', 'At least one active Super Administrator must remain');
  end if;
  perform private.log_action('SET_ROLES', 'app_users', p_user_id::text, p_assignments);
  return jsonb_build_object('ok', true);
end $$;

-- One-time bootstrap: run in the Supabase SQL editor after the first user has been invited / signed up.
--   select private.bootstrap_super_admin('owner@example.co.za', 'Full Name');
create or replace function private.bootstrap_super_admin(p_email text, p_full_name text) returns text
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_id uuid;
begin
  if exists (select 1 from public.user_role_assignments ua join public.roles r on r.id = ua.role_id and r.code = 'SUPER_ADMIN') then
    raise exception 'A Super Administrator already exists — use Users & Permissions in the application';
  end if;
  select id into v_id from auth.users where lower(email) = lower(p_email);
  if v_id is null then raise exception 'No auth user with e-mail % — invite the user in Supabase Auth first', p_email; end if;
  insert into public.app_users (id, email, full_name) values (v_id, lower(p_email), p_full_name)
  on conflict (id) do update set full_name = excluded.full_name, is_active = true;
  insert into public.user_role_assignments (user_id, role_id, scope_type)
  select v_id, id, 'group' from public.roles where code = 'SUPER_ADMIN' on conflict do nothing;
  return 'Super Administrator created for ' || p_email;
end $$;

-- -----------------------------------------------------------------------------
-- Transaction detail (for the transaction page / receipts)
-- -----------------------------------------------------------------------------
create or replace function public.transaction_detail(p_txn_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare t public.stock_transactions;
begin
  select * into t from public.stock_transactions where id = p_txn_id;
  if not found then perform private.fail('CS422', 'Transaction not found'); end if;
  if not (t.created_by = auth.uid() or private.has_wh_perm('stock.view', t.warehouse_id) or private.has_perm('audit.view')) then
    perform private.fail('CS401', 'Not permitted');
  end if;
  return (select to_jsonb(v) from public.v_transactions v where v.id = p_txn_id) || jsonb_build_object(
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_no', l.line_no, 'sku', p.sku, 'description', p.description,
                 'location', sl.code, 'to_location', tl.code, 'owner', oc.code, 'status', l.status, 'to_status', l.to_status,
                 'qty_base', l.qty_base, 'base_uom', bu.code, 'entered_qty', l.entered_qty, 'entered_uom', eu.code, 'extra', l.extra,
                 'unit_cost', case when private.has_perm('cost.view') then (select unit_cost from public.txn_line_costs c where c.txn_id = l.txn_id and c.line_no = l.line_no) end)
                 order by l.line_no), '[]')
              from public.stock_transaction_lines l join public.products p on p.id = l.product_id
              join public.uoms bu on bu.id = p.base_uom_id join public.uoms eu on eu.id = l.entered_uom_id
              join public.storage_locations sl on sl.id = l.location_id left join public.storage_locations tl on tl.id = l.to_location_id
              join public.companies oc on oc.id = l.owner_company_id where l.txn_id = p_txn_id),
    'movements', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'sku', p.sku, 'location', sl.code, 'owner', oc.code, 'status', l.status,
                     'qty_delta', l.qty_delta, 'balance_after', l.balance_after, 'posted_at', l.posted_at) order by l.id), '[]')
                  from public.stock_ledger l join public.products p on p.id = l.product_id join public.storage_locations sl on sl.id = l.location_id
                  join public.companies oc on oc.id = l.owner_company_id where l.txn_id = p_txn_id),
    'approval', (select to_jsonb(a) from public.v_approvals a where a.txn_id = p_txn_id order by requested_at desc limit 1),
    'reversed_by', (select jsonb_build_object('id', id, 'txn_no', txn_no, 'status', status) from public.stock_transactions
                    where related_txn_id = p_txn_id and txn_type = 'reversal' and status in ('pending_approval','posted') limit 1),
    'returns', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'txn_no', txn_no)), '[]') from public.stock_transactions
                where related_txn_id = p_txn_id and txn_type = 'return' and status = 'posted'));
end $$;

-- -----------------------------------------------------------------------------
-- Execute grants for the public API
-- -----------------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;


-- ===== 20261023000700_scheduling_jobs.sql =====
-- =============================================================================
-- CSWMS Migration 0700: Scheduled jobs and server-only job API
--
--   Primary scheduler: pg_cron inside the database runs integrity.dispatch()
--   every 15 minutes. dispatch() decides (in Africa/Johannesburg time) whether
--   the daily check is due, retries failures and runs the watchdog.
--   Secondary (optional): the web app's cron route can call public.cron_dispatch()
--   with the service-role key. Both are safe to run together (idempotent).
-- =============================================================================

-- Server-only wrappers (service_role). Not granted to authenticated users.
create or replace function public.cron_dispatch() returns jsonb
language plpgsql security definer set search_path = public, integrity, pg_temp as $$
begin
  return integrity.dispatch();
end $$;

create or replace function public.email_outbox_claim(p_limit int default 20)
returns table (id uuid, to_email text, subject text, body_text text)
language sql security definer set search_path = private, pg_temp as $$
  update private.email_outbox o set status = 'sending', attempts = attempts + 1
  where o.id in (select id from private.email_outbox
                 where status = 'pending' or (status = 'failed' and attempts < 5)
                    or (status = 'sending' and created_at < now() - interval '30 minutes' and attempts < 5)
                 order by created_at limit p_limit for update skip locked)
  returning o.id, o.to_email, o.subject, o.body_text
$$;

create or replace function public.email_outbox_result(p_id uuid, p_ok boolean, p_error text default null)
returns void language sql security definer set search_path = private, pg_temp as $$
  update private.email_outbox set status = case when p_ok then 'sent' else 'failed' end,
         sent_at = case when p_ok then now() end, last_error = p_error
  where id = p_id
$$;

-- Records that the external cron reached the app (system health evidence)
create table public.system_events (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  source     text not null,
  event      text not null,
  ok         boolean not null,
  detail     jsonb
);
alter table public.system_events enable row level security;
alter table public.system_events force row level security;
grant select on public.system_events to authenticated;
create policy system_events_read on public.system_events for select to authenticated using (private.has_perm('integrity.admin'));
create index on public.system_events (at desc);

create or replace function public.log_system_event(p_source text, p_event text, p_ok boolean, p_detail jsonb default null)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.system_events (source, event, ok, detail) values (left(p_source, 50), left(p_event, 100), p_ok, p_detail)
$$;

-- client-side failures (e.g. scanner / network errors) reported by signed-in users
create or replace function public.report_client_error(p_event text, p_detail jsonb default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if auth.uid() is null then return; end if;
  if (select count(*) from public.system_events where source = 'client' and at > now() - interval '1 minute'
      and detail ->> 'user_id' = auth.uid()::text) > 30 then return; end if;   -- rate limit
  insert into public.system_events (source, event, ok, detail)
  values ('client', left(p_event, 100), false, coalesce(p_detail, '{}') || jsonb_build_object('user_id', auth.uid()));
end $$;

revoke execute on function public.cron_dispatch() from public, anon, authenticated;
revoke execute on function public.email_outbox_claim(int) from public, anon, authenticated;
revoke execute on function public.email_outbox_result(uuid, boolean, text) from public, anon, authenticated;
revoke execute on function public.log_system_event(text, text, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.cron_dispatch() to service_role;
grant execute on function public.email_outbox_claim(int) to service_role;
grant execute on function public.email_outbox_result(uuid, boolean, text) to service_role;
grant execute on function public.log_system_event(text, text, boolean, jsonb) to service_role;
grant execute on function public.report_client_error(text, jsonb) to authenticated;

-- pg_cron (available on Supabase; enable "pg_cron" under Database > Extensions if this notice appears)
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron;
      perform cron.unschedule(jobid) from cron.job where jobname = 'cswms-integrity-dispatch';
      perform cron.schedule('cswms-integrity-dispatch', '*/15 * * * *', 'select integrity.dispatch()');
      raise notice 'pg_cron job cswms-integrity-dispatch scheduled (every 15 minutes)';
    exception when others then
      raise notice 'pg_cron could not be configured automatically (%). Enable pg_cron and run: select cron.schedule(''cswms-integrity-dispatch'', ''*/15 * * * *'', ''select integrity.dispatch()'');', sqlerrm;
    end;
  else
    raise notice 'pg_cron is not available on this server. Schedule integrity.dispatch() every 15 minutes externally (see docs/DEPLOYMENT.md).';
  end if;
end $$;


-- ===== 20261023000900_final_lockdown.sql =====
-- =============================================================================
-- CSWMS Migration 0900: FINAL PRIVILEGE LOCKDOWN — keep this the LAST migration.
--
-- PostgreSQL gives PUBLIC execute on every new function, and Supabase also adds
-- default grants for anon/authenticated. This migration re-establishes the
-- intended privilege model after all objects exist. Any future migration that
-- adds functions or tables must be followed by re-running this file's content
-- (or a copy of it as the newest migration).
-- =============================================================================

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
    if f.proname in ('cron_dispatch','email_outbox_claim','email_outbox_result','log_system_event') then
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


-- ===== 20261026001000_phase2_approvals_notifications.sql =====
-- =============================================================================
-- CSWMS Phase 2 — Migration 1000: ADVANCED APPROVALS and IMPROVED NOTIFICATIONS
--
-- * Configurable approval rules: by request type and value (ZAR), a request may
--   need several approval levels (e.g. any authorised approver, then head office).
--   Every level must be decided by a different person, never the requester.
-- * Every decision is kept in approval_decisions (immutable).
-- * Personal notification preferences (e-mail on/off, minimum severity, muted
--   alert types, daily digest), respected by private.raise_alert.
-- =============================================================================

-- ---------------------------------------------------------------- new permissions & settings
insert into public.permissions (code, description) values
  ('purchase.manage',  'Create, edit, submit, send and close purchase orders'),
  ('purchase.approve', 'Approve purchase orders'),
  ('asset.manage',     'Register reusable tools / equipment and change their status'),
  ('asset.checkout',   'Check tools / equipment out and in')
on conflict (code) do nothing;

-- System roles: the Super Administrator must hold every permission.
update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['purchase.manage','purchase.approve','asset.manage','asset.checkout']) p)
 where code = 'SUPER_ADMIN';
update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['purchase.approve']) p)
 where code = 'HEAD_OFFICE';
update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['purchase.manage','purchase.approve','asset.manage','asset.checkout']) p)
 where code in ('COMPANY_MANAGER', 'BRANCH_MANAGER');
update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['purchase.manage','asset.manage','asset.checkout']) p)
 where code = 'WAREHOUSE_SUPERVISOR';
update public.roles set permissions = (select array_agg(distinct p order by p) from unnest(permissions || array['asset.checkout']) p)
 where code = 'STOCK_CONTROLLER';

insert into public.app_settings (key, value, category, description) values
  ('approvals.reminder_hours',   '24',      'approvals', 'Remind approvers when a request has waited this many hours'),
  ('approvals.escalate_hours',   '72',      'approvals', 'Escalate a waiting request to head office after this many hours'),
  ('purchase.over_receipt_pct',  '0',       'purchasing', 'Percentage a purchase-order line may be over-received (0 = never)'),
  ('purchase.overdue_grace_days','2',       'purchasing', 'Days after the expected delivery date before a purchase order is reported overdue'),
  ('assets.default_loan_days',   '7',       'assets',    'Default number of days a checked-out tool may be kept'),
  ('notifications.digest_time',  '"07:00"', 'alerts',    'Local time at which daily digest e-mails are prepared')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- approval rules
alter table public.approval_requests drop constraint approval_requests_kind_check;
alter table public.approval_requests add constraint approval_requests_kind_check
  check (kind = any (array['adjustment','reversal','transfer_writeoff','stocktake','opening_balance','purchase_order']));
alter table public.approval_requests
  add column value_zar numeric(16,2),
  add column step_levels text[] not null default '{any}',
  add column steps_done int not null default 0,
  add column purchase_order_id uuid;

create table public.approval_rules (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind = any (array['adjustment','reversal','transfer_writeoff','stocktake','opening_balance','purchase_order'])),
  name          text not null,
  min_value_zar numeric(16,2) not null default 0 check (min_value_zar >= 0),
  levels        text[] not null check (cardinality(levels) between 1 and 4
                  and levels <@ array['any','branch','company','group']),
  is_active     boolean not null default true,
  updated_by    uuid,
  updated_at    timestamptz not null default now(),
  unique (kind, min_value_zar)
);
comment on table public.approval_rules is
  'Approval levels by request type and value. The rule with the highest min_value_zar <= request value applies. '
  'Levels: any = anyone holding the approval permission for that warehouse; branch/company/group = must hold it at that scope or higher.';

insert into public.approval_rules (kind, name, min_value_zar, levels) values
  ('purchase_order',    'Purchase orders',                       0,      '{any}'),
  ('purchase_order',    'Large purchase orders',                 50000,  '{any,group}'),
  ('adjustment',        'Very large adjustments',                50000,  '{any,group}'),
  ('reversal',          'Very large reversals',                  50000,  '{any,group}'),
  ('transfer_writeoff', 'Very large transfer write-offs',        50000,  '{any,group}'),
  ('stocktake',         'Stocktakes with large variances',       100000, '{any,group}');

create table public.approval_decisions (
  id          bigserial primary key,
  approval_id uuid not null references public.approval_requests(id),
  step_no     int not null,
  level       text not null,
  decided_by  uuid not null references public.app_users(id),
  approved    boolean not null,
  note        text,
  decided_at  timestamptz not null default now(),
  unique (approval_id, step_no)
);
create trigger approval_decisions_immutable before update or delete on public.approval_decisions
  for each row execute function private.block_modification();

-- value of a request in ZAR (purchase price), used to pick the rule
create or replace function private.approval_value(p public.approval_requests)
returns numeric language plpgsql stable security definer set search_path = public, private, pg_temp as $$
begin
  return round(coalesce(case
    when p.kind in ('adjustment','reversal','transfer_writeoff') then
      (select sum(abs(l.qty_base) * coalesce(c.purchase_price, 0)) from public.stock_transaction_lines l
         left join public.product_costs c on c.product_id = l.product_id where l.txn_id = p.txn_id)
    when p.kind = 'stocktake' then
      (select sum(abs(coalesce(l.variance, 0)) * coalesce(c.purchase_price, 0)) from public.stocktake_lines l
         left join public.product_costs c on c.product_id = l.product_id where l.stocktake_id = p.stocktake_id)
    when p.kind = 'opening_balance' then
      (select sum(coalesce(r.qty_num, 0) * coalesce(nullif(private.try_numeric(r.purchase_price), 'NaN'), c.purchase_price, 0))
         from public.import_rows r left join public.product_costs c on c.product_id = r.product_id
        where r.batch_id = p.import_batch_id and not r.excluded)
    when p.kind = 'purchase_order' then
      (select sum(l.qty_ordered * l.unit_price) from public.purchase_order_lines l where l.po_id = p.purchase_order_id)
  end, 0), 2);
end $$;

create or replace function private.approval_apply_rule()
returns trigger language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_rule public.approval_rules;
begin
  new.value_zar := private.approval_value(new);
  select * into v_rule from public.approval_rules
   where kind = new.kind and is_active and min_value_zar <= coalesce(new.value_zar, 0)
   order by min_value_zar desc limit 1;
  new.step_levels := coalesce(v_rule.levels, '{any}');
  new.steps_done := 0;
  new.details := coalesce(new.details, '{}') || jsonb_build_object('value_zar', new.value_zar, 'levels', to_jsonb(new.step_levels));
  return new;
end $$;
create trigger approval_apply_rule before insert on public.approval_requests
  for each row execute function private.approval_apply_rule();

-- Does the current user hold p_perm at the given level for this warehouse?
create or replace function private.has_perm_at_level(p_perm text, p_warehouse uuid, p_level text)
returns boolean language sql stable security definer set search_path = public, private, pg_temp as $$
  select case p_level
    when 'any' then case when p_warehouse is null then private.has_perm(p_perm) else private.has_wh_perm(p_perm, p_warehouse) end
    when 'group' then private.has_group_perm(p_perm)
    else exists (
      select 1 from public.user_role_assignments a
      join public.roles r on r.id = a.role_id and p_perm = any(r.permissions)
      join public.app_users u on u.id = a.user_id and u.is_active
      left join private.warehouse_tree t on t.warehouse_id = p_warehouse
      where a.user_id = auth.uid()
        and (a.scope_type = 'group'
          or (a.scope_type = 'company' and a.scope_id = t.company_id)
          or (p_level = 'branch' and a.scope_type = 'branch' and a.scope_id = t.branch_id)))
  end
$$;

create or replace function private.level_label(p_level text)
returns text language sql immutable as $$
  select case p_level when 'any' then 'an authorised approver' when 'branch' then 'a branch-level (or higher) approver'
                      when 'company' then 'a company-level (or higher) approver' when 'group' then 'head office' end
$$;

-- The Phase 1 decision logic, unchanged, now called once the final level approves (or any level rejects).
create or replace function private.apply_approval_decision(p_approval_id uuid, p_approve boolean, p_note text, v_uid uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_a public.approval_requests; v_txn public.stock_transactions; v_res jsonb; tl record;
begin
  select * into v_a from public.approval_requests where id = p_approval_id;
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
  elsif v_a.kind = 'purchase_order' then
    v_res := private.po_decision(v_a.purchase_order_id, p_approve, v_uid, p_note);
  end if;

  perform private.resolve_alert('approval:' || p_approval_id, case when p_approve then 'Approved' else 'Rejected' end);
  perform private.resolve_alert('approval_overdue:' || p_approval_id, case when p_approve then 'Approved' else 'Rejected' end);
  perform private.log_action(case when p_approve then 'APPROVE' else 'REJECT' end, 'approval_requests', p_approval_id::text,
                             jsonb_build_object('kind', v_a.kind, 'note', p_note));
  return jsonb_build_object('ok', true, 'status', case when p_approve then 'approved' else 'rejected' end, 'result', v_res);
end $$;

-- Multi-level decision entry point (same signature as Phase 1).
create or replace function public.decide_approval(p_approval_id uuid, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_a public.approval_requests; v_uid uuid; v_step int; v_level text; v_total int;
begin
  select * into v_a from public.approval_requests where id = p_approval_id for update;
  if not found then perform private.fail('CS422', 'Approval request not found'); end if;
  if v_a.status <> 'pending' then perform private.fail('CS423', 'This request has already been ' || v_a.status); end if;
  v_uid := private.require_perm(v_a.required_perm, v_a.warehouse_id);
  if v_uid = v_a.requested_by then
    perform private.fail('CS401', 'You cannot approve or reject your own request (segregation of duties)');
  end if;
  if exists (select 1 from public.approval_decisions where approval_id = p_approval_id and decided_by = v_uid) then
    perform private.fail('CS401', 'You already approved an earlier level of this request — a different person must decide this level');
  end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then
    perform private.fail('CS422', 'Please give a reason for rejecting the request');
  end if;
  v_total := cardinality(v_a.step_levels);
  v_step := v_a.steps_done + 1;
  v_level := v_a.step_levels[v_step];
  if not private.has_perm_at_level(v_a.required_perm, v_a.warehouse_id, v_level) then
    perform private.fail('CS401', format('Level %s of %s must be decided by %s', v_step, v_total, private.level_label(v_level)));
  end if;

  insert into public.approval_decisions (approval_id, step_no, level, decided_by, approved, note)
  values (p_approval_id, v_step, v_level, v_uid, p_approve, p_note);

  if p_approve and v_step < v_total then
    update public.approval_requests set steps_done = v_step where id = p_approval_id;
    perform private.log_action('APPROVE_LEVEL', 'approval_requests', p_approval_id::text,
      jsonb_build_object('kind', v_a.kind, 'level', v_step, 'of', v_total, 'note', p_note));
    perform private.raise_alert('approval_pending', 'warning',
      format('Approval level %s of %s required: %s', v_step + 1, v_total, v_a.summary),
      format('%s — level %s approved by %s. Now needs %s.', v_a.summary, v_step,
             (select full_name from public.app_users where id = v_uid), private.level_label(v_a.step_levels[v_step + 1])),
      'approval:' || p_approval_id, null, v_a.warehouse_id, null, null, v_a.value_zar, 'approval', p_approval_id::text,
      v_a.step_levels[v_step + 1] = 'group', '/approvals');
    return jsonb_build_object('ok', true, 'status', 'pending', 'level_approved', v_step, 'levels', v_total,
                              'next_level', v_a.step_levels[v_step + 1]);
  end if;

  update public.approval_requests set steps_done = case when p_approve then v_total else steps_done end where id = p_approval_id;
  return private.apply_approval_decision(p_approval_id, p_approve, p_note, v_uid);
end $$;

-- Which pending requests may the signed-in user decide right now (drives the Approve / Reject buttons;
-- decide_approval re-checks everything).
create or replace function public.approvals_i_can_decide()
returns uuid[] language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce(array_agg(a.id), '{}') from public.approval_requests a
   where a.status = 'pending' and a.requested_by <> auth.uid()
     and not exists (select 1 from public.approval_decisions d where d.approval_id = a.id and d.decided_by = auth.uid())
     and (case when a.warehouse_id is null then private.has_perm(a.required_perm) else private.has_wh_perm(a.required_perm, a.warehouse_id) end)
     and private.has_perm_at_level(a.required_perm, a.warehouse_id, a.step_levels[a.steps_done + 1])
$$;

-- Rule administration
create or replace function public.save_approval_rule(p_id uuid, p_kind text, p_name text, p_min_value numeric, p_levels text[], p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_id uuid;
begin
  v_uid := private.require_perm('settings.manage');
  if not private.has_group_perm('settings.manage') then perform private.fail('CS401', 'Group-level settings permission is required'); end if;
  if coalesce(trim(p_name), '') = '' then perform private.fail('CS422', 'Give the rule a name'); end if;
  if p_levels is null or cardinality(p_levels) = 0 then perform private.fail('CS422', 'At least one approval level is required'); end if;
  if not (p_levels <@ array['any','branch','company','group']) then perform private.fail('CS422', 'Invalid approval level'); end if;
  if p_min_value is null or p_min_value < 0 then perform private.fail('CS422', 'The minimum value cannot be negative'); end if;
  if p_id is null then
    insert into public.approval_rules (kind, name, min_value_zar, levels, is_active, updated_by)
    values (p_kind, trim(p_name), p_min_value, p_levels, coalesce(p_active, true), v_uid) returning id into v_id;
  else
    update public.approval_rules set kind = p_kind, name = trim(p_name), min_value_zar = p_min_value, levels = p_levels,
           is_active = coalesce(p_active, true), updated_by = v_uid, updated_at = now() where id = p_id returning id into v_id;
    if v_id is null then perform private.fail('CS422', 'Rule not found'); end if;
  end if;
  perform private.log_action('SAVE_APPROVAL_RULE', 'approval_rules', v_id::text,
    jsonb_build_object('kind', p_kind, 'min_value', p_min_value, 'levels', p_levels, 'active', p_active));
  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  perform private.fail('CS422', 'A rule with this type and minimum value already exists');
end $$;

-- ---------------------------------------------------------------- notification preferences
create table public.notification_preferences (
  user_id            uuid primary key references public.app_users(id),
  email_enabled      boolean not null default true,
  email_min_severity text not null default 'warning' check (email_min_severity in ('info','warning','critical')),
  muted_types        text[] not null default '{}',
  daily_digest       boolean not null default false,
  updated_at         timestamptz not null default now()
);

create or replace function public.my_notification_preferences()
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v jsonb;
begin
  if auth.uid() is null then perform private.fail('CS401', 'Not signed in'); end if;
  select to_jsonb(p) into v from public.notification_preferences p where user_id = auth.uid();
  return coalesce(v, jsonb_build_object('user_id', auth.uid(), 'email_enabled', true, 'email_min_severity', 'warning',
                                         'muted_types', '[]'::jsonb, 'daily_digest', false))
         || jsonb_build_object('email_system_enabled', private.setting_bool('alerts.email_enabled', false));
end $$;

create or replace function public.set_notification_preferences(p_email_enabled boolean, p_email_min_severity text, p_muted_types text[], p_daily_digest boolean)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not private.is_active_user(v_uid) then perform private.fail('CS401', 'Not signed in'); end if;
  if p_email_min_severity not in ('info','warning','critical') then perform private.fail('CS422', 'Invalid severity'); end if;
  -- critical integrity / monitoring alerts cannot be muted
  if p_muted_types && array['integrity','integrity_monitor'] then
    perform private.fail('CS422', 'Integrity alerts cannot be muted');
  end if;
  insert into public.notification_preferences (user_id, email_enabled, email_min_severity, muted_types, daily_digest)
  values (v_uid, coalesce(p_email_enabled, true), p_email_min_severity, coalesce(p_muted_types, '{}'), coalesce(p_daily_digest, false))
  on conflict (user_id) do update set email_enabled = excluded.email_enabled, email_min_severity = excluded.email_min_severity,
     muted_types = excluded.muted_types, daily_digest = excluded.daily_digest, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- raise_alert: identical de-duplication and escalation behaviour, now honouring preferences.
-- Muting never applies to critical alerts.
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
    end loop;
  end if;
  return v_alert.id;
end $$;

-- new alert types for Phase 2
alter table public.alerts drop constraint alerts_alert_type_check;
alter table public.alerts add constraint alerts_alert_type_check check (alert_type = any (array[
  'low_stock','out_of_stock','reorder','transfer_overdue','stocktake_due','stocktake_overdue','stocktake_discrepancy',
  'unusual_withdrawal','approval_pending','integrity','integrity_monitor','system',
  'po_overdue','asset_overdue','approval_overdue']));


-- ===== 20261026001100_phase2_purchasing.sql =====
-- =============================================================================
-- CSWMS Phase 2 — Migration 1100: PURCHASING
--
-- Purchase orders: draft -> pending_approval -> approved -> sent ->
-- partially_received -> received / closed (short) / cancelled.
-- * Approval through the multi-level approval rules (kind 'purchase_order').
-- * Receiving against a PO posts a normal, auditable RECEIPT through the same
--   posting engine (ledger + balances, atomic, idempotent) and updates the PO.
--   Over-receipt is refused beyond a configurable tolerance.
-- * Reorder suggestions from low / out-of-stock items, net of stock already on
--   order, can be turned into draft POs per supplier in one step.
-- =============================================================================

create table public.purchase_orders (
  id                 uuid primary key default gen_random_uuid(),
  po_no              text not null unique,
  supplier_id        uuid not null references public.suppliers(id),
  warehouse_id       uuid not null references public.warehouses(id),
  owner_company_id   uuid not null references public.companies(id),
  status             text not null default 'draft' check (status in
                       ('draft','pending_approval','approved','sent','partially_received','received','closed','cancelled')),
  expected_date      date,
  supplier_reference text,
  notes              text,
  approval_id        uuid references public.approval_requests(id),
  approved_by        uuid references public.app_users(id),
  approved_at        timestamptz,
  sent_by            uuid references public.app_users(id),
  sent_at            timestamptz,
  closed_by          uuid references public.app_users(id),
  closed_at          timestamptz,
  close_reason       text,
  client_request_id  uuid unique,
  created_by         uuid not null references public.app_users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index on public.purchase_orders (warehouse_id, status);
create index on public.purchase_orders (supplier_id);

create table public.purchase_order_lines (
  id                uuid primary key default gen_random_uuid(),
  po_id             uuid not null references public.purchase_orders(id) on delete cascade,
  line_no           int not null,
  product_id        uuid not null references public.products(id),
  uom_id            uuid not null references public.uoms(id),
  factor            numeric not null check (factor > 0),
  qty_ordered       numeric not null check (qty_ordered > 0),        -- in uom_id
  qty_ordered_base  numeric not null check (qty_ordered_base > 0),   -- in the product's base unit
  unit_price        numeric(16,4) not null default 0 check (unit_price >= 0),  -- ZAR excl. VAT per uom_id
  qty_received_base numeric not null default 0 check (qty_received_base >= 0),
  notes             text,
  unique (po_id, line_no)
);
create index on public.purchase_order_lines (product_id);

alter table public.approval_requests
  add constraint approval_requests_po_fk foreign key (purchase_order_id) references public.purchase_orders(id);

create trigger purchase_orders_touch before update on public.purchase_orders for each row execute function private.touch_updated_at();
create trigger purchase_orders_audit after insert or update or delete on public.purchase_orders for each row execute function private.audit_row();
create trigger purchase_order_lines_audit after insert or update or delete on public.purchase_order_lines for each row execute function private.audit_row();

-- ---------------------------------------------------------------- helpers
create or replace function private.po_for_update(p_po_id uuid)
returns public.purchase_orders language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v public.purchase_orders;
begin
  select * into v from public.purchase_orders where id = p_po_id for update;
  if not found then perform private.fail('CS422', 'Purchase order not found'); end if;
  return v;
end $$;

-- Replaces the lines of a draft PO after validating every line.
create or replace function private.po_set_lines(p_po public.purchase_orders, p_lines jsonb)
returns numeric language plpgsql security definer set search_path = public, private, pg_temp as $$
declare l jsonb; i int := 0; c record; v_prod public.products; v_total numeric := 0; v_price numeric;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    perform private.fail('CS422', 'Add at least one product to the purchase order');
  end if;
  if jsonb_array_length(p_lines) > 300 then perform private.fail('CS422', 'A purchase order can have at most 300 lines'); end if;
  if (select count(*) from jsonb_array_elements(p_lines) x) <>
     (select count(distinct (x ->> 'product_id') || '|' || coalesce(x ->> 'uom_id', '')) from jsonb_array_elements(p_lines) x) then
    perform private.fail('CS422', 'The same product and unit appears twice — combine the lines');
  end if;
  delete from public.purchase_order_lines where po_id = p_po.id;
  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    select * into v_prod from public.products where id = nullif(l ->> 'product_id', '')::uuid;
    if not found then perform private.fail('CS422', format('Line %s: unknown product', i)); end if;
    if v_prod.status <> 'active' then perform private.fail('CS422', format('Line %s: %s is %s and cannot be ordered', i, v_prod.sku, v_prod.status)); end if;
    select * into c from private.to_base(v_prod.id, nullif(l ->> 'uom_id', '')::uuid, (l ->> 'qty')::numeric);
    v_price := coalesce(nullif(l ->> 'unit_price', '')::numeric, 0);
    if v_price < 0 then perform private.fail('CS422', format('Line %s: the price cannot be negative', i)); end if;
    insert into public.purchase_order_lines (po_id, line_no, product_id, uom_id, factor, qty_ordered, qty_ordered_base, unit_price, notes)
    values (p_po.id, i, v_prod.id, c.uom_id, c.factor, (l ->> 'qty')::numeric, c.qty_base, v_price, nullif(trim(l ->> 'notes'), ''));
    v_total := v_total + (l ->> 'qty')::numeric * v_price;
  end loop;
  return v_total;
exception when invalid_text_representation or numeric_value_out_of_range then
  perform private.fail('CS422', 'A quantity or price is not a valid number');
end $$;

-- ---------------------------------------------------------------- create / edit
create or replace function public.create_purchase_order(
  p_request_id uuid, p_supplier_id uuid, p_warehouse_id uuid, p_lines jsonb, p_expected_date date default null,
  p_supplier_reference text default null, p_notes text default null, p_owner_company_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_payload jsonb; v_po public.purchase_orders; v_total numeric;
begin
  v_payload := jsonb_build_object('s', p_supplier_id, 'w', p_warehouse_id, 'l', p_lines, 'd', p_expected_date, 'r', p_supplier_reference, 'n', p_notes, 'o', p_owner_company_id);
  v_prev := private.idem_begin(p_request_id, 'create_purchase_order', v_payload);
  if v_prev is not null then return v_prev; end if;
  v_uid := private.require_perm('purchase.manage', p_warehouse_id);
  if not exists (select 1 from public.suppliers where id = p_supplier_id and status = 'active') then
    perform private.fail('CS422', 'Choose an active supplier');
  end if;
  if p_expected_date is not null and p_expected_date < (now() at time zone 'Africa/Johannesburg')::date then
    perform private.fail('CS422', 'The expected delivery date is in the past');
  end if;
  if p_owner_company_id is not null and not exists (select 1 from public.companies where id = p_owner_company_id and status = 'active') then
    perform private.fail('CS422', 'Unknown buying company');
  end if;
  insert into public.purchase_orders (po_no, supplier_id, warehouse_id, owner_company_id, expected_date, supplier_reference, notes, client_request_id, created_by)
  values (private.next_doc_no('PO'), p_supplier_id, p_warehouse_id, coalesce(p_owner_company_id, private.warehouse_company(p_warehouse_id)),
          p_expected_date, nullif(trim(p_supplier_reference), ''), nullif(trim(p_notes), ''), p_request_id, v_uid)
  returning * into v_po;
  v_total := private.po_set_lines(v_po, p_lines);
  return private.idem_finish(p_request_id, 'create_purchase_order', v_payload,
    jsonb_build_object('ok', true, 'po_id', v_po.id, 'po_no', v_po.po_no, 'status', 'draft', 'total', v_total));
end $$;

create or replace function public.update_purchase_order(
  p_po_id uuid, p_supplier_id uuid, p_lines jsonb, p_expected_date date default null,
  p_supplier_reference text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_po public.purchase_orders; v_total numeric;
begin
  v_po := private.po_for_update(p_po_id);
  perform private.require_perm('purchase.manage', v_po.warehouse_id);
  if v_po.status <> 'draft' then perform private.fail('CS423', 'Only a draft purchase order can be changed (it is ' || replace(v_po.status, '_', ' ') || ')'); end if;
  if not exists (select 1 from public.suppliers where id = p_supplier_id and status = 'active') then
    perform private.fail('CS422', 'Choose an active supplier');
  end if;
  update public.purchase_orders set supplier_id = p_supplier_id, expected_date = p_expected_date,
         supplier_reference = nullif(trim(p_supplier_reference), ''), notes = nullif(trim(p_notes), '')
   where id = p_po_id returning * into v_po;
  v_total := private.po_set_lines(v_po, p_lines);
  return jsonb_build_object('ok', true, 'po_id', v_po.id, 'total', v_total);
end $$;

-- ---------------------------------------------------------------- approval
create or replace function public.submit_purchase_order(p_po_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_po public.purchase_orders; v_uid uuid; v_appr uuid; v_total numeric; v_sup text; v_lines int;
begin
  v_po := private.po_for_update(p_po_id);
  v_uid := private.require_perm('purchase.manage', v_po.warehouse_id);
  if v_po.status <> 'draft' then perform private.fail('CS423', 'Only a draft purchase order can be submitted'); end if;
  select count(*), coalesce(sum(qty_ordered * unit_price), 0) into v_lines, v_total from public.purchase_order_lines where po_id = p_po_id;
  if v_lines = 0 then perform private.fail('CS422', 'The purchase order has no lines'); end if;
  if exists (select 1 from public.purchase_order_lines where po_id = p_po_id and unit_price = 0) then
    perform private.fail('CS422', 'Enter a unit price on every line before submitting (needed for approval limits)');
  end if;
  select name into v_sup from public.suppliers where id = v_po.supplier_id;
  insert into public.approval_requests (kind, required_perm, warehouse_id, purchase_order_id, summary, details, requested_by)
  values ('purchase_order', 'purchase.approve', v_po.warehouse_id, v_po.id,
          format('Purchase order %s — %s — R %s', v_po.po_no, v_sup, to_char(v_total, 'FM999G999G990D00')),
          jsonb_build_object('po_no', v_po.po_no, 'supplier', v_sup, 'lines', v_lines), v_uid)
  returning id into v_appr;
  perform private.raise_alert('approval_pending', 'info', 'Approval required: purchase order ' || v_po.po_no,
    format('%s from %s for R %s — requested by %s', v_po.po_no, v_sup, to_char(v_total, 'FM999G999G990D00'),
           (select full_name from public.app_users where id = v_uid)),
    'approval:' || v_appr, null, v_po.warehouse_id, null, null, v_total, 'approval', v_appr::text, false, '/approvals');
  update public.purchase_orders set status = 'pending_approval', approval_id = v_appr where id = p_po_id;
  return jsonb_build_object('ok', true, 'status', 'pending_approval', 'approval_id', v_appr, 'total', v_total,
    'levels', (select step_levels from public.approval_requests where id = v_appr));
end $$;

create or replace function private.po_decision(p_po_id uuid, p_approve boolean, p_uid uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if p_approve then
    update public.purchase_orders set status = 'approved', approved_by = p_uid, approved_at = now() where id = p_po_id and status = 'pending_approval';
    return jsonb_build_object('po_status', 'approved');
  end if;
  -- rejected or withdrawn: back to draft so it can be corrected and resubmitted
  update public.purchase_orders set status = 'draft', approval_id = null,
         notes = concat_ws(E'\n', notes, 'Returned ' || to_char(now() at time zone 'Africa/Johannesburg', 'DD/MM/YYYY HH24:MI') || ': ' || coalesce(p_note, ''))
   where id = p_po_id and status = 'pending_approval';
  return jsonb_build_object('po_status', 'draft');
end $$;

-- the requester withdrawing the approval request returns the PO to draft
create or replace function private.po_approval_cancelled()
returns trigger language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if new.kind = 'purchase_order' and new.status = 'cancelled' and old.status = 'pending' then
    perform private.po_decision(new.purchase_order_id, false, auth.uid(), coalesce(new.decision_note, 'Approval request withdrawn'));
  end if;
  return new;
end $$;
create trigger approval_po_cancelled after update of status on public.approval_requests
  for each row execute function private.po_approval_cancelled();

-- ---------------------------------------------------------------- send / close / cancel
create or replace function public.send_purchase_order(p_po_id uuid, p_supplier_reference text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_po public.purchase_orders; v_uid uuid;
begin
  v_po := private.po_for_update(p_po_id);
  v_uid := private.require_perm('purchase.manage', v_po.warehouse_id);
  if v_po.status <> 'approved' then perform private.fail('CS423', 'Only an approved purchase order can be marked as sent'); end if;
  update public.purchase_orders set status = 'sent', sent_by = v_uid, sent_at = now(),
         supplier_reference = coalesce(nullif(trim(p_supplier_reference), ''), supplier_reference) where id = p_po_id;
  return jsonb_build_object('ok', true, 'status', 'sent');
end $$;

create or replace function public.close_purchase_order(p_po_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_po public.purchase_orders; v_uid uuid;
begin
  v_po := private.po_for_update(p_po_id);
  v_uid := private.require_perm('purchase.manage', v_po.warehouse_id);
  if v_po.status not in ('approved','sent','partially_received') then
    perform private.fail('CS423', 'Only an approved, sent or partly received purchase order can be closed');
  end if;
  if coalesce(trim(p_reason), '') = '' then perform private.fail('CS422', 'Give a reason for closing the order short'); end if;
  if v_po.status <> 'partially_received' then
    perform private.fail('CS423', 'Nothing has been received on this order — cancel it instead');
  end if;
  update public.purchase_orders set status = 'closed', closed_by = v_uid, closed_at = now(), close_reason = trim(p_reason) where id = p_po_id;
  perform private.resolve_alert('po_overdue:' || p_po_id, 'Purchase order closed');
  return jsonb_build_object('ok', true, 'status', 'closed');
end $$;

create or replace function public.cancel_purchase_order(p_po_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_po public.purchase_orders; v_uid uuid;
begin
  v_po := private.po_for_update(p_po_id);
  v_uid := private.require_perm('purchase.manage', v_po.warehouse_id);
  if v_po.status not in ('draft','pending_approval','approved','sent') then
    perform private.fail('CS423', 'This purchase order can no longer be cancelled (stock has been received — close it instead)');
  end if;
  if coalesce(trim(p_reason), '') = '' then perform private.fail('CS422', 'Give a reason for cancelling'); end if;
  if v_po.status = 'pending_approval' then
    update public.approval_requests set status = 'cancelled', decided_at = now(), decision_note = 'Purchase order cancelled: ' || trim(p_reason)
     where id = v_po.approval_id and status = 'pending';
    perform private.resolve_alert('approval:' || v_po.approval_id, 'Purchase order cancelled');
  end if;
  update public.purchase_orders set status = 'cancelled', closed_by = v_uid, closed_at = now(), close_reason = trim(p_reason) where id = p_po_id;
  perform private.resolve_alert('po_overdue:' || p_po_id, 'Purchase order cancelled');
  return jsonb_build_object('ok', true, 'status', 'cancelled');
end $$;

-- ---------------------------------------------------------------- receive against a PO
create or replace function public.receive_purchase_order(
  p_request_id uuid, p_po_id uuid, p_reference text, p_lines jsonb, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_uid uuid; v_prev jsonb; v_payload jsonb; v_po public.purchase_orders; v_txn public.stock_transactions;
  l jsonb; pl public.purchase_order_lines; i int := 0; c record; v_loc uuid; v_moves jsonb := '[]'; v_res jsonb;
  v_tol numeric := private.setting_num('purchase.over_receipt_pct', 0); v_allowed numeric; v_status text; v_cost numeric;
begin
  v_payload := jsonb_build_object('po', p_po_id, 'ref', p_reference, 'lines', p_lines, 'notes', p_notes);
  v_prev := private.idem_begin(p_request_id, 'receive_purchase_order', v_payload);
  if v_prev is not null then return v_prev; end if;
  v_po := private.po_for_update(p_po_id);
  v_uid := private.require_perm('stock.receive', v_po.warehouse_id);
  if v_po.status not in ('approved','sent','partially_received') then
    perform private.fail('CS423', 'Stock can only be received on an approved purchase order (this one is ' || replace(v_po.status, '_', ' ') || ')');
  end if;
  perform private.require_lines(p_lines);
  if coalesce(trim(p_reference), '') = '' then
    perform private.fail('CS422', 'A supplier delivery note / reference is required when receiving stock');
  end if;

  v_txn := private.new_txn('receipt', 'pending_approval', v_po.warehouse_id, p_request_id, null, p_reference,
             concat_ws(' — ', 'Received against ' || v_po.po_no, nullif(trim(p_notes), '')), v_po.supplier_id);

  for l in select * from jsonb_array_elements(p_lines) loop
    select * into pl from public.purchase_order_lines where id = nullif(l ->> 'po_line_id', '')::uuid and po_id = p_po_id for update;
    if not found then perform private.fail('CS422', 'A line does not belong to this purchase order'); end if;
    if coalesce((l ->> 'qty')::numeric, 0) = 0 then continue; end if;
    i := i + 1;
    select * into c from private.to_base(pl.product_id, coalesce(nullif(l ->> 'uom_id', '')::uuid, pl.uom_id), (l ->> 'qty')::numeric);
    v_allowed := pl.qty_ordered_base * (1 + v_tol / 100) - pl.qty_received_base;
    if c.qty_base > v_allowed then
      perform private.fail('CS422', format('PO line %s: receiving %s would exceed the order. Outstanding: %s (base units). Receive the extra separately or ask purchasing to amend the order.',
        pl.line_no, c.qty_base, greatest(pl.qty_ordered_base - pl.qty_received_base, 0)));
    end if;
    v_loc := coalesce(nullif(l ->> 'location_id', '')::uuid, private.default_location(v_po.warehouse_id));
    perform private.location_warehouse(v_loc, v_po.warehouse_id);
    insert into public.stock_transaction_lines (txn_id, line_no, product_id, location_id, owner_company_id, status,
         qty_base, entered_qty, entered_uom_id, factor, extra)
    values (v_txn.id, i, pl.product_id, v_loc, v_po.owner_company_id, 'available', c.qty_base, (l ->> 'qty')::numeric,
         c.uom_id, c.factor, jsonb_build_object('po_id', v_po.id, 'po_no', v_po.po_no, 'po_line_id', pl.id));
    v_cost := round(pl.unit_price / pl.factor * c.factor, 4);           -- price per entered unit
    insert into public.txn_line_costs (txn_id, line_no, unit_cost) values (v_txn.id, i, v_cost);
    insert into public.product_costs (product_id, purchase_price, currency, updated_by)
    values (pl.product_id, round(pl.unit_price / pl.factor, 4), 'ZAR', v_uid)
    on conflict (product_id) do update set purchase_price = excluded.purchase_price, updated_by = excluded.updated_by, updated_at = now();
    update public.purchase_order_lines set qty_received_base = qty_received_base + c.qty_base where id = pl.id;
    v_moves := v_moves || jsonb_build_object('line_no', i, 'product_id', pl.product_id, 'location_id', v_loc,
       'owner_company_id', v_po.owner_company_id, 'status', 'available', 'qty_delta', c.qty_base, 'entered_qty', l ->> 'qty',
       'entered_uom_id', c.uom_id, 'factor', c.factor);
  end loop;
  if i = 0 then perform private.fail('CS422', 'Enter the quantity received on at least one line'); end if;

  v_res := private.post_movements(v_txn.id, v_moves, v_uid);
  v_status := case when exists (select 1 from public.purchase_order_lines where po_id = p_po_id and qty_received_base < qty_ordered_base)
                   then 'partially_received' else 'received' end;
  update public.purchase_orders set status = v_status where id = p_po_id;
  if v_status = 'received' then perform private.resolve_alert('po_overdue:' || p_po_id, 'Purchase order received in full'); end if;
  return private.idem_finish(p_request_id, 'receive_purchase_order', v_payload,
    jsonb_build_object('ok', true, 'status', 'posted', 'txn_id', v_txn.id, 'txn_no', v_txn.txn_no, 'po_status', v_status, 'movements', v_res));
exception when invalid_text_representation then
  perform private.fail('CS422', 'A quantity is not a valid number');
end $$;

-- ---------------------------------------------------------------- reorder suggestions
create or replace function public.purchase_suggestions(p_warehouse_id uuid)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
begin
  if not (private.has_wh_perm('purchase.manage', p_warehouse_id) or private.has_wh_perm('stock.view', p_warehouse_id)) then
    perform private.fail('CS401', 'You do not have access to this warehouse');
  end if;
  return query
  with oo as (
    select l.product_id, sum(l.qty_ordered_base - l.qty_received_base) as on_order
    from public.purchase_order_lines l join public.purchase_orders o on o.id = l.po_id
    where o.warehouse_id = p_warehouse_id and o.status in ('draft','pending_approval','approved','sent','partially_received')
    group by l.product_id)
  select jsonb_build_object('product_id', s.product_id, 'sku', s.sku, 'description', s.description, 'uom', s.uom,
           'free', s.free_to_use, 'min_qty', s.min_qty, 'reorder_qty', s.reorder_qty, 'on_order', coalesce(oo.on_order, 0),
           'stock_level', s.stock_level,
           'suggested_qty', greatest(coalesce(s.reorder_qty, 0), coalesce(s.min_qty, 0) - s.free_to_use - coalesce(oo.on_order, 0), 0),
           'supplier_id', p.default_supplier_id, 'supplier', sup.name, 'last_price', pc.purchase_price,
           'covered', s.free_to_use + coalesce(oo.on_order, 0) > coalesce(s.min_qty, 0))
  from public.v_stock_by_warehouse s
  join public.products p on p.id = s.product_id
  left join public.suppliers sup on sup.id = p.default_supplier_id
  left join public.product_costs pc on pc.product_id = p.id
  left join oo on oo.product_id = s.product_id
  where s.warehouse_id = p_warehouse_id and s.stock_level in ('low','out') and p.status = 'active'
  order by (s.free_to_use + coalesce(oo.on_order, 0) > coalesce(s.min_qty, 0)), s.stock_level desc, s.sku;
end $$;

-- Creates one draft PO per supplier from chosen suggestions: [{product_id, qty, supplier_id?, unit_price?}]
create or replace function public.create_po_from_suggestions(p_request_id uuid, p_warehouse_id uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_payload jsonb; s record; v_po public.purchase_orders; v_out jsonb := '[]'; v_lines jsonb;
begin
  v_payload := jsonb_build_object('w', p_warehouse_id, 'i', p_items);
  v_prev := private.idem_begin(p_request_id, 'create_po_from_suggestions', v_payload);
  if v_prev is not null then return v_prev; end if;
  v_uid := private.require_perm('purchase.manage', p_warehouse_id);
  perform private.require_lines(p_items);
  if exists (select 1 from jsonb_array_elements(p_items) x join public.products p on p.id = (x ->> 'product_id')::uuid
             where coalesce(nullif(x ->> 'supplier_id', '')::uuid, p.default_supplier_id) is null) then
    perform private.fail('CS422', 'Some items have no supplier. Choose a supplier or set a default supplier on the product.');
  end if;
  for s in select coalesce(nullif(x ->> 'supplier_id', '')::uuid, p.default_supplier_id) as supplier_id,
                  jsonb_agg(jsonb_build_object('product_id', p.id, 'qty', x ->> 'qty', 'uom_id', p.base_uom_id,
                     'unit_price', coalesce(nullif(x ->> 'unit_price', '')::numeric, pc.purchase_price, 0))) as lines
           from jsonb_array_elements(p_items) x join public.products p on p.id = (x ->> 'product_id')::uuid
           left join public.product_costs pc on pc.product_id = p.id
           group by 1 loop
    insert into public.purchase_orders (po_no, supplier_id, warehouse_id, owner_company_id, notes, created_by)
    values (private.next_doc_no('PO'), s.supplier_id, p_warehouse_id, private.warehouse_company(p_warehouse_id),
            'Created from reorder suggestions', v_uid)
    returning * into v_po;
    perform private.po_set_lines(v_po, s.lines);
    v_out := v_out || jsonb_build_object('po_id', v_po.id, 'po_no', v_po.po_no, 'supplier_id', s.supplier_id);
  end loop;
  return private.idem_finish(p_request_id, 'create_po_from_suggestions', v_payload,
    jsonb_build_object('ok', true, 'created', jsonb_array_length(v_out), 'purchase_orders', v_out));
end $$;

-- ---------------------------------------------------------------- reporting views
create view public.v_purchase_orders with (security_invoker = true) as
select o.*, s.name as supplier_name, s.email as supplier_email, s.phone as supplier_phone,
       wt.warehouse_code, wt.warehouse_name, wt.branch_code, wt.company_code, oc.code as owner_company_code,
       cu.full_name as created_by_name, au.full_name as approved_by_name,
       (select count(*) from public.purchase_order_lines l where l.po_id = o.id) as line_count,
       (select coalesce(sum(l.qty_ordered * l.unit_price), 0) from public.purchase_order_lines l where l.po_id = o.id) as total_value,
       (select coalesce(sum(least(l.qty_received_base, l.qty_ordered_base) / l.qty_ordered_base * l.qty_ordered * l.unit_price), 0)
          from public.purchase_order_lines l where l.po_id = o.id) as received_value,
       (o.status in ('approved','sent','partially_received') and o.expected_date is not null
          and o.expected_date + (private.setting_num('purchase.overdue_grace_days', 2))::int < (now() at time zone 'Africa/Johannesburg')::date) as is_overdue
from public.purchase_orders o
join public.suppliers s on s.id = o.supplier_id
join public.v_warehouse_tree wt on wt.warehouse_id = o.warehouse_id
join public.companies oc on oc.id = o.owner_company_id
left join public.app_users cu on cu.id = o.created_by
left join public.app_users au on au.id = o.approved_by;

create view public.v_purchase_order_lines with (security_invoker = true) as
select l.*, p.sku, p.description, u.code as uom_code, bu.code as base_uom_code,
       l.qty_ordered * l.unit_price as line_value,
       greatest(l.qty_ordered_base - l.qty_received_base, 0) as outstanding_base
from public.purchase_order_lines l
join public.products p on p.id = l.product_id
join public.uoms u on u.id = l.uom_id
join public.uoms bu on bu.id = p.base_uom_id;

-- approvals view gains the multi-level and purchasing columns (appended)
create or replace view public.v_approvals with (security_invoker = true) as
 select a.id, a.kind, a.status, a.required_perm, a.warehouse_id, a.txn_id, a.transfer_id, a.stocktake_id, a.import_batch_id,
    a.summary, a.details, a.requested_by, a.requested_at, a.decided_by, a.decided_at, a.decision_note,
    ru.full_name as requested_by_name, du.full_name as decided_by_name,
    wt.warehouse_code, wt.branch_code, wt.company_code, t.txn_no, t.txn_type,
    a.value_zar, a.step_levels, a.steps_done, a.purchase_order_id, po.po_no,
    (select jsonb_agg(jsonb_build_object('step', d.step_no, 'level', d.level, 'by', u.full_name, 'approved', d.approved, 'note', d.note, 'at', d.decided_at) order by d.step_no)
       from public.approval_decisions d join public.app_users u on u.id = d.decided_by where d.approval_id = a.id) as decisions
   from public.approval_requests a
     left join public.app_users ru on ru.id = a.requested_by
     left join public.app_users du on du.id = a.decided_by
     left join public.v_warehouse_tree wt on wt.warehouse_id = a.warehouse_id
     left join public.stock_transactions t on t.id = a.txn_id
     left join public.purchase_orders po on po.id = a.purchase_order_id;


-- ===== 20261026001200_phase2_assets.sql =====
-- =============================================================================
-- CSWMS Phase 2 — Migration 1200: ASSET (TOOL & EQUIPMENT) TRACKING
--
-- Individually tagged reusable tools / equipment (products flagged "reusable
-- asset"). Each asset has a tag (printed as a barcode), a home warehouse, a
-- current status and holder. Every change is an immutable asset movement:
-- register, check_out, check_in, transfer, send_repair, return_repair,
-- mark_lost, found, retire, verify. Overdue check-outs raise alerts.
-- The asset register is separate from consumable stock balances: assets are
-- not "used up", they are lent out and returned.
-- =============================================================================

create table public.assets (
  id                uuid primary key default gen_random_uuid(),
  asset_tag         text not null unique,
  product_id        uuid not null references public.products(id),
  serial_number     text,
  description       text,
  owner_company_id  uuid not null references public.companies(id),
  home_warehouse_id uuid not null references public.warehouses(id),
  warehouse_id      uuid not null references public.warehouses(id),      -- current custody
  location_id       uuid references public.storage_locations(id),       -- when in store
  status            text not null default 'in_store' check (status in ('in_store','checked_out','in_repair','lost','retired')),
  condition         text not null default 'good' check (condition in ('good','fair','damaged')),
  holder_user_id    uuid references public.app_users(id),
  holder_name       text,
  job_reference     text,
  checked_out_at    timestamptz,
  due_back_at       timestamptz,
  purchase_date     date,
  purchase_cost     numeric(16,2) check (purchase_cost is null or purchase_cost >= 0),
  last_verified_at  timestamptz,
  notes             text,
  created_by        uuid not null references public.app_users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (status <> 'checked_out' or (holder_user_id is not null or coalesce(holder_name, '') <> ''))
);
create unique index assets_serial_unique on public.assets (product_id, lower(serial_number)) where serial_number is not null;
create index on public.assets (warehouse_id, status);
create index on public.assets (holder_user_id) where status = 'checked_out';

create table public.asset_movements (
  id                bigserial primary key,
  asset_id          uuid not null references public.assets(id),
  movement          text not null check (movement in ('register','check_out','check_in','transfer','send_repair','return_repair','mark_lost','found','retire','verify')),
  from_status       text,
  to_status         text not null,
  warehouse_id      uuid references public.warehouses(id),
  location_id       uuid references public.storage_locations(id),
  holder_user_id    uuid references public.app_users(id),
  holder_name       text,
  job_reference     text,
  due_back_at       timestamptz,
  condition         text,
  notes             text,
  client_request_id uuid unique,
  created_by        uuid not null references public.app_users(id),
  created_at        timestamptz not null default now()
);
create index on public.asset_movements (asset_id, created_at desc);
create trigger asset_movements_immutable before update or delete on public.asset_movements
  for each row execute function private.block_modification();
create trigger assets_touch before update on public.assets for each row execute function private.touch_updated_at();
create trigger assets_audit after insert or update or delete on public.assets for each row execute function private.audit_row();

-- ---------------------------------------------------------------- helpers
create or replace function private.asset_for_update(p_asset_id uuid)
returns public.assets language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v public.assets;
begin
  select * into v from public.assets where id = p_asset_id for update;
  if not found then perform private.fail('CS422', 'Asset not found'); end if;
  return v;
end $$;

create or replace function private.asset_log(p_asset public.assets, p_movement text, p_from text, p_request uuid, p_notes text)
returns void language sql security definer set search_path = public, private, pg_temp as $$
  insert into public.asset_movements (asset_id, movement, from_status, to_status, warehouse_id, location_id, holder_user_id,
         holder_name, job_reference, due_back_at, condition, notes, client_request_id, created_by)
  values (p_asset.id, p_movement, p_from, p_asset.status, p_asset.warehouse_id, p_asset.location_id, p_asset.holder_user_id,
          p_asset.holder_name, p_asset.job_reference, p_asset.due_back_at, p_asset.condition, nullif(trim(p_notes), ''), p_request,
          coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'))
$$;

-- Retry-safe: the same request id returns the asset's current state instead of acting twice.
create or replace function private.asset_replay(p_request uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v jsonb;
begin
  if p_request is null then
    perform private.fail('CS422', 'A request id is required (protects against duplicate submissions)');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text, 42));   -- concurrent retries wait for each other
  select jsonb_build_object('ok', true, 'duplicate', true, 'asset_id', m.asset_id, 'asset_tag', a.asset_tag, 'status', a.status)
    into v from public.asset_movements m join public.assets a on a.id = m.asset_id where m.client_request_id = p_request;
  return v;
end $$;

create or replace function private.asset_result(p_id uuid)
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('ok', true, 'asset_id', a.id, 'asset_tag', a.asset_tag, 'status', a.status, 'condition', a.condition,
                            'due_back_at', a.due_back_at, 'holder', coalesce(u.full_name, a.holder_name))
  from public.assets a left join public.app_users u on u.id = a.holder_user_id where a.id = p_id
$$;

-- ---------------------------------------------------------------- register
create or replace function public.register_asset(
  p_request_id uuid, p_product_id uuid, p_warehouse_id uuid, p_location_id uuid default null, p_serial_number text default null,
  p_owner_company_id uuid default null, p_purchase_date date default null, p_purchase_cost numeric default null,
  p_condition text default 'good', p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_prod public.products; v_tag text; v_a public.assets; v_loc uuid;
begin
  v_prev := private.asset_replay(p_request_id);
  if v_prev is not null then return v_prev; end if;
  v_uid := private.require_perm('asset.manage', p_warehouse_id);
  select * into v_prod from public.products where id = p_product_id;
  if not found then perform private.fail('CS422', 'Unknown product'); end if;
  if not v_prod.is_asset then perform private.fail('CS422', v_prod.sku || ' is not marked as a reusable tool / equipment item (edit the product first)'); end if;
  if v_prod.status <> 'active' then perform private.fail('CS422', v_prod.sku || ' is not active'); end if;
  if p_condition not in ('good','fair','damaged') then perform private.fail('CS422', 'Invalid condition'); end if;
  if p_purchase_cost is not null and p_purchase_cost < 0 then perform private.fail('CS422', 'Cost cannot be negative'); end if;
  v_loc := coalesce(p_location_id, private.default_location(p_warehouse_id));
  perform private.location_warehouse(v_loc, p_warehouse_id);
  loop
    v_tag := private.next_doc_no('AST');
    exit when not exists (select 1 from public.barcodes where code = v_tag)
          and not exists (select 1 from public.storage_locations where label_code = v_tag);
  end loop;
  insert into public.assets (asset_tag, product_id, serial_number, owner_company_id, home_warehouse_id, warehouse_id, location_id,
                             condition, purchase_date, purchase_cost, notes, created_by)
  values (v_tag, p_product_id, nullif(trim(p_serial_number), ''), coalesce(p_owner_company_id, private.warehouse_company(p_warehouse_id)),
          p_warehouse_id, p_warehouse_id, v_loc, p_condition, p_purchase_date, p_purchase_cost, nullif(trim(p_notes), ''), v_uid)
  returning * into v_a;
  perform private.asset_log(v_a, 'register', null, p_request_id, p_notes);
  return private.asset_result(v_a.id);
exception when unique_violation then
  perform private.fail('CS422', 'An asset with this serial number is already registered for this product');
end $$;

-- ---------------------------------------------------------------- check out / in
create or replace function public.checkout_asset(
  p_request_id uuid, p_asset_id uuid, p_holder_user_id uuid default null, p_holder_name text default null,
  p_job_reference text default null, p_due_back_at timestamptz default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_a public.assets; v_due timestamptz;
begin
  v_prev := private.asset_replay(p_request_id);
  if v_prev is not null then return v_prev; end if;
  v_a := private.asset_for_update(p_asset_id);
  v_uid := private.require_perm('asset.checkout', v_a.warehouse_id);
  if v_a.status <> 'in_store' then
    perform private.fail('CS423', format('%s cannot be checked out — it is %s%s', v_a.asset_tag, replace(v_a.status, '_', ' '),
      case when v_a.status = 'checked_out' then ' to ' || coalesce((select full_name from public.app_users where id = v_a.holder_user_id), v_a.holder_name) else '' end));
  end if;
  if v_a.condition = 'damaged' then perform private.fail('CS423', 'Damaged equipment cannot be issued — send it for repair first'); end if;
  if p_holder_user_id is null and coalesce(trim(p_holder_name), '') = '' then
    perform private.fail('CS422', 'Choose the employee (or enter the name of the person) taking the item');
  end if;
  if p_holder_user_id is not null and not private.is_active_user(p_holder_user_id) then perform private.fail('CS422', 'That employee account is not active'); end if;
  v_due := coalesce(p_due_back_at, now() + make_interval(days => private.setting_num('assets.default_loan_days', 7)::int));
  if v_due <= now() then perform private.fail('CS422', 'The return date must be in the future'); end if;
  update public.assets set status = 'checked_out', holder_user_id = p_holder_user_id, holder_name = nullif(trim(p_holder_name), ''),
         job_reference = nullif(trim(p_job_reference), ''), checked_out_at = now(), due_back_at = v_due, location_id = null
   where id = p_asset_id returning * into v_a;
  perform private.asset_log(v_a, 'check_out', 'in_store', p_request_id, p_notes);
  return private.asset_result(v_a.id);
end $$;

create or replace function public.checkin_asset(
  p_request_id uuid, p_asset_id uuid, p_location_id uuid, p_condition text default 'good', p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_a public.assets; v_wh uuid;
begin
  v_prev := private.asset_replay(p_request_id);
  if v_prev is not null then return v_prev; end if;
  v_a := private.asset_for_update(p_asset_id);
  select warehouse_id into v_wh from public.storage_locations where id = p_location_id and status = 'active';
  if v_wh is null then perform private.fail('CS422', 'Choose an active storage location to return the item to'); end if;
  v_uid := private.require_perm('asset.checkout', v_wh);
  if v_a.status <> 'checked_out' then perform private.fail('CS423', v_a.asset_tag || ' is not checked out'); end if;
  if p_condition not in ('good','fair','damaged') then perform private.fail('CS422', 'Invalid condition'); end if;
  if p_condition = 'damaged' and coalesce(trim(p_notes), '') = '' then perform private.fail('CS422', 'Describe the damage'); end if;
  update public.assets set status = 'in_store', condition = p_condition, warehouse_id = v_wh, location_id = p_location_id,
         holder_user_id = null, holder_name = null, job_reference = null, checked_out_at = null, due_back_at = null
   where id = p_asset_id returning * into v_a;
  perform private.asset_log(v_a, 'check_in', 'checked_out', p_request_id, p_notes);
  perform private.resolve_alert('asset_overdue:' || p_asset_id, 'Returned');
  if p_condition = 'damaged' then
    perform private.raise_alert('system', 'warning', 'Equipment returned damaged: ' || v_a.asset_tag, coalesce(trim(p_notes), ''),
      'asset_damaged:' || v_a.id || ':' || now()::date, v_a.product_id, v_wh, null, p_location_id, null, 'asset', v_a.id::text, false, '/assets/' || v_a.id);
  end if;
  return private.asset_result(v_a.id);
end $$;

-- ---------------------------------------------------------------- status changes
create or replace function public.set_asset_status(
  p_request_id uuid, p_asset_id uuid, p_status text, p_notes text, p_location_id uuid default null, p_condition text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_a public.assets; v_from text; v_mv text; v_wh uuid;
begin
  v_prev := private.asset_replay(p_request_id);
  if v_prev is not null then return v_prev; end if;
  v_a := private.asset_for_update(p_asset_id);
  v_uid := private.require_perm('asset.manage', v_a.warehouse_id);
  if coalesce(trim(p_notes), '') = '' then perform private.fail('CS422', 'A note is required'); end if;
  v_from := v_a.status;
  v_mv := case
    when v_from = 'in_store' and p_status = 'in_repair' then 'send_repair'
    when v_from = 'in_repair' and p_status = 'in_store' then 'return_repair'
    when v_from in ('in_store','checked_out','in_repair') and p_status = 'lost' then 'mark_lost'
    when v_from = 'lost' and p_status = 'in_store' then 'found'
    when v_from in ('in_store','in_repair','lost') and p_status = 'retired' then 'retire'
  end;
  if v_mv is null then
    perform private.fail('CS423', format('Cannot change %s from %s to %s', v_a.asset_tag, replace(v_from, '_', ' '), replace(p_status, '_', ' ')));
  end if;
  if p_status = 'in_store' then
    select warehouse_id into v_wh from public.storage_locations where id = p_location_id and status = 'active';
    if v_wh is null then perform private.fail('CS422', 'Choose the storage location where the item now is'); end if;
    if not private.has_wh_perm('asset.manage', v_wh) then perform private.fail('CS401', 'You cannot place assets in that warehouse'); end if;
  end if;
  update public.assets set status = p_status,
         condition = coalesce(p_condition, case when v_mv = 'return_repair' then 'good' else condition end),
         warehouse_id = coalesce(v_wh, warehouse_id),
         location_id = case when p_status = 'in_store' then p_location_id when p_status in ('lost','retired','in_repair') then null else location_id end,
         holder_user_id = case when p_status = 'lost' then holder_user_id else null end,
         holder_name = case when p_status = 'lost' then holder_name else null end,
         due_back_at = null
   where id = p_asset_id returning * into v_a;
  perform private.asset_log(v_a, v_mv, v_from, p_request_id, p_notes);
  perform private.resolve_alert('asset_overdue:' || p_asset_id, 'Status changed to ' || replace(p_status, '_', ' '));
  if p_status = 'lost' then
    perform private.raise_alert('system', 'warning', 'Equipment reported lost: ' || v_a.asset_tag, p_notes,
      'asset_lost:' || v_a.id, v_a.product_id, v_a.warehouse_id, null, null, null, 'asset', v_a.id::text, false, '/assets/' || v_a.id);
  elsif v_from = 'lost' then
    perform private.resolve_alert('asset_lost:' || v_a.id, 'Found');
  end if;
  return private.asset_result(v_a.id);
end $$;

create or replace function public.transfer_asset(p_request_id uuid, p_asset_id uuid, p_to_location_id uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_a public.assets; v_wh uuid;
begin
  v_prev := private.asset_replay(p_request_id);
  if v_prev is not null then return v_prev; end if;
  v_a := private.asset_for_update(p_asset_id);
  v_uid := private.require_perm('asset.manage', v_a.warehouse_id);
  if v_a.status <> 'in_store' then perform private.fail('CS423', 'Only equipment in store can be moved'); end if;
  select warehouse_id into v_wh from public.storage_locations where id = p_to_location_id and status = 'active';
  if v_wh is null then perform private.fail('CS422', 'Choose an active destination location'); end if;
  if v_wh = v_a.warehouse_id and p_to_location_id = v_a.location_id then perform private.fail('CS422', 'The item is already there'); end if;
  update public.assets set warehouse_id = v_wh, location_id = p_to_location_id where id = p_asset_id returning * into v_a;
  perform private.asset_log(v_a, 'transfer', 'in_store', p_request_id, p_notes);
  return private.asset_result(v_a.id);
end $$;

-- Physical verification (asset audit): scan the tag where it is found.
create or replace function public.verify_asset(p_request_id uuid, p_asset_id uuid, p_location_id uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; v_prev jsonb; v_a public.assets; v_wh uuid; v_note text;
begin
  v_prev := private.asset_replay(p_request_id);
  if v_prev is not null then return v_prev; end if;
  v_a := private.asset_for_update(p_asset_id);
  select warehouse_id into v_wh from public.storage_locations where id = p_location_id;
  if v_wh is null then perform private.fail('CS422', 'Unknown location'); end if;
  v_uid := private.require_perm('asset.checkout', v_wh);
  if v_a.status <> 'in_store' then
    perform private.fail('CS423', format('%s is recorded as %s — check it in or record that it was found before verifying it', v_a.asset_tag, replace(v_a.status, '_', ' ')));
  end if;
  if v_a.location_id is distinct from p_location_id then
    v_note := format('Found at %s (recorded at %s)', (select code from public.storage_locations where id = p_location_id),
                     coalesce((select code from public.storage_locations where id = v_a.location_id), 'unknown'));
  end if;
  update public.assets set last_verified_at = now(), warehouse_id = v_wh, location_id = p_location_id where id = p_asset_id returning * into v_a;
  perform private.asset_log(v_a, 'verify', 'in_store', p_request_id, v_note);
  return private.asset_result(v_a.id) || jsonb_build_object('moved', v_note is not null, 'note', v_note);
end $$;

-- Scan lookup by tag or serial number
create or replace function public.asset_lookup(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v jsonb; v_wh uuid;
begin
  if auth.uid() is null then perform private.fail('CS401', 'Not signed in'); end if;
  select a.warehouse_id, jsonb_build_object('kind', 'asset', 'id', a.id, 'asset_tag', a.asset_tag, 'serial_number', a.serial_number,
           'sku', p.sku, 'description', p.description, 'status', a.status, 'condition', a.condition,
           'warehouse_id', a.warehouse_id, 'warehouse_code', w.code, 'location_id', a.location_id, 'location_code', l.code,
           'holder', coalesce(u.full_name, a.holder_name), 'holder_user_id', a.holder_user_id, 'job_reference', a.job_reference,
           'due_back_at', a.due_back_at, 'overdue', a.status = 'checked_out' and a.due_back_at < now())
    into v_wh, v
  from public.assets a join public.products p on p.id = a.product_id join public.warehouses w on w.id = a.warehouse_id
  left join public.storage_locations l on l.id = a.location_id left join public.app_users u on u.id = a.holder_user_id
  where upper(a.asset_tag) = upper(trim(p_code)) or lower(a.serial_number) = lower(trim(p_code))
  order by (upper(a.asset_tag) = upper(trim(p_code))) desc limit 1;
  if v is null then return jsonb_build_object('kind', 'none'); end if;
  if not (private.has_wh_perm('asset.checkout', v_wh) or private.has_wh_perm('stock.view', v_wh) or private.has_wh_perm('asset.manage', v_wh)) then
    return jsonb_build_object('kind', 'none');
  end if;
  return v;
end $$;

create view public.v_assets with (security_invoker = true) as
select a.*, p.sku, p.description as product_description, wt.warehouse_code, wt.warehouse_name, wt.branch_code, wt.company_code,
       hw.code as home_warehouse_code, l.code as location_code, oc.code as owner_company_code,
       coalesce(u.full_name, a.holder_name) as holder, u.employee_number as holder_employee_number,
       (a.status = 'checked_out' and a.due_back_at < now()) as is_overdue,
       case when a.status = 'checked_out' then floor(extract(epoch from now() - a.checked_out_at) / 86400) end as days_out
from public.assets a
join public.products p on p.id = a.product_id
join public.v_warehouse_tree wt on wt.warehouse_id = a.warehouse_id
join public.warehouses hw on hw.id = a.home_warehouse_id
join public.companies oc on oc.id = a.owner_company_id
left join public.storage_locations l on l.id = a.location_id
left join public.app_users u on u.id = a.holder_user_id;

create view public.v_asset_movements with (security_invoker = true) as
select m.*, a.asset_tag, p.sku, p.description, w.code as warehouse_code, l.code as location_code,
       coalesce(hu.full_name, m.holder_name) as holder, cu.full_name as created_by_name
from public.asset_movements m
join public.assets a on a.id = m.asset_id
join public.products p on p.id = a.product_id
left join public.warehouses w on w.id = m.warehouse_id
left join public.storage_locations l on l.id = m.location_id
left join public.app_users hu on hu.id = m.holder_user_id
left join public.app_users cu on cu.id = m.created_by;


-- ===== 20261026001300_phase2_housekeeping.sql =====
-- =============================================================================
-- CSWMS Phase 2 — Migration 1300: OPERATIONAL HOUSEKEEPING
-- Runs with every scheduler tick (pg_cron every 15 min, plus /api/cron):
--  * overdue purchase orders  -> 'po_overdue' alerts
--  * overdue tool check-outs  -> 'asset_overdue' alerts (to managers + the holder)
--  * approvals waiting too long -> reminder, then escalation to head office
--  * daily digest e-mails for users who asked for one
-- Every alert is de-duplicated, so repeated ticks never spam. A failure here is
-- logged and can never prevent the Daily Stock Integrity check from running.
-- =============================================================================

-- warehouses where a given user holds a permission (for digests sent on their behalf)
create or replace function private.user_warehouses(p_user uuid, p_perm text)
returns uuid[] language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce(array_agg(distinct t.warehouse_id), '{}')
  from public.user_role_assignments a
  join public.roles r on r.id = a.role_id and p_perm = any(r.permissions)
  join private.warehouse_tree t on a.scope_type = 'group'
       or (a.scope_type = 'company' and t.company_id = a.scope_id)
       or (a.scope_type = 'branch' and t.branch_id = a.scope_id)
       or (a.scope_type = 'warehouse' and t.warehouse_id = a.scope_id)
  where a.user_id = p_user
$$;

create or replace function private.ops_housekeeping()
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_local timestamp := now() at time zone 'Africa/Johannesburg';
  r record; v_po int := 0; v_as int := 0; v_ap int := 0; v_dg int := 0;
  v_grace int := private.setting_num('purchase.overdue_grace_days', 2)::int;
  v_rem numeric := private.setting_num('approvals.reminder_hours', 24);
  v_esc numeric := private.setting_num('approvals.escalate_hours', 72);
  v_digest time := private.setting_text('notifications.digest_time', '07:00')::time;
  v_body text;
begin
  -- 1. overdue purchase orders
  for r in select o.*, s.name as supplier from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id
           where o.status in ('approved','sent','partially_received') and o.expected_date is not null
             and o.expected_date + v_grace < v_local::date loop
    perform private.raise_alert('po_overdue', 'warning', 'Purchase order overdue: ' || r.po_no,
      format('%s from %s was expected on %s and is not fully received.', r.po_no, r.supplier, to_char(r.expected_date, 'DD/MM/YYYY')),
      'po_overdue:' || r.id, null, r.warehouse_id, r.owner_company_id, null, null, 'purchase_order', r.id::text,
      r.expected_date + v_grace + 7 < v_local::date, '/purchasing/' || r.id);
    v_po := v_po + 1;
  end loop;

  -- 2. overdue tool / equipment check-outs (managers via alert, holder via a personal notification)
  for r in select a.*, p.description, coalesce(u.full_name, a.holder_name) as holder
           from public.assets a join public.products p on p.id = a.product_id left join public.app_users u on u.id = a.holder_user_id
           where a.status = 'checked_out' and a.due_back_at < now() loop
    perform private.raise_alert('asset_overdue', 'warning', 'Equipment not returned: ' || r.asset_tag,
      format('%s (%s) checked out to %s%s was due back %s.', r.asset_tag, r.description, r.holder,
             coalesce(' for ' || r.job_reference, ''), to_char(r.due_back_at at time zone 'Africa/Johannesburg', 'DD/MM/YYYY HH24:MI')),
      'asset_overdue:' || r.id, r.product_id, r.warehouse_id, r.owner_company_id, null, null, 'asset', r.id::text,
      r.due_back_at < now() - interval '7 days', '/assets/' || r.id);
    if r.holder_user_id is not null then
      insert into public.notifications (user_id, title, body, link)
      select r.holder_user_id, 'Please return ' || r.asset_tag, format('%s was due back %s.', r.description,
             to_char(r.due_back_at at time zone 'Africa/Johannesburg', 'DD/MM/YYYY HH24:MI')), '/assets/' || r.id
      where not exists (select 1 from public.notifications n where n.user_id = r.holder_user_id and n.link = '/assets/' || r.id
                        and n.created_at > now() - interval '20 hours');
    end if;
    v_as := v_as + 1;
  end loop;

  -- 3. approvals waiting too long
  for r in select * from public.approval_requests where status = 'pending' and requested_at < now() - make_interval(hours => v_rem::int) loop
    perform private.raise_alert('approval_overdue', case when r.requested_at < now() - make_interval(hours => v_esc::int) then 'warning' else 'info' end,
      'Approval waiting: ' || r.summary,
      format('Requested %s and still waiting for a decision%s.', to_char(r.requested_at at time zone 'Africa/Johannesburg', 'DD/MM/YYYY HH24:MI'),
             case when cardinality(r.step_levels) > 1 then format(' (level %s of %s)', r.steps_done + 1, cardinality(r.step_levels)) else '' end),
      'approval_overdue:' || r.id, null, r.warehouse_id, null, null, r.value_zar, 'approval', r.id::text,
      r.requested_at < now() - make_interval(hours => v_esc::int), '/approvals');
    v_ap := v_ap + 1;
  end loop;

  -- 4. daily digest e-mails (once a day after the configured time)
  if v_local::time >= v_digest and private.setting_bool('alerts.email_enabled', false) then
    for r in select u.id, u.email, u.full_name from public.notification_preferences np
             join public.app_users u on u.id = np.user_id and u.is_active
             where np.daily_digest and np.email_enabled and u.email is not null
               and not exists (select 1 from private.email_outbox e where e.dedupe_key = 'digest:' || v_local::date and e.to_email = u.email) loop
      select string_agg(format('- %s %s: %s', upper(a.severity), replace(a.alert_type, '_', ' '), a.title), E'\n' order by
               case a.severity when 'critical' then 1 when 'warning' then 2 else 3 end, a.last_raised_at desc)
        into v_body
      from (select * from public.alerts a
            where a.status <> 'resolved'
              and (a.warehouse_id = any(private.user_warehouses(r.id, 'alerts.receive'))
                   or (a.warehouse_id is null and exists (select 1 from public.user_role_assignments x join public.roles y on y.id = x.role_id
                        where x.user_id = r.id and x.scope_type = 'group' and 'alerts.receive' = any(y.permissions))))
            order by a.last_raised_at desc limit 40) a;
      insert into private.email_outbox (to_email, subject, body_text, dedupe_key)
      values (r.email, '[CSWMS] Daily digest ' || to_char(v_local, 'DD/MM/YYYY'),
              format(E'Good morning %s,\n\nOpen alerts in your area:\n%s\n\nApprovals waiting: %s\nEquipment you still have out: %s\n\nOpen CSWMS to act on these.',
                     r.full_name, coalesce(v_body, '- none'),
                     (select count(*) from public.approval_requests ap where ap.status = 'pending' and ap.requested_by <> r.id
                        and (ap.warehouse_id = any(private.user_warehouses(r.id, ap.required_perm)) or ap.warehouse_id is null)),
                     (select count(*) from public.assets x where x.status = 'checked_out' and x.holder_user_id = r.id)),
              'digest:' || v_local::date)
      on conflict do nothing;
      v_dg := v_dg + 1;
    end loop;
  end if;

  return jsonb_build_object('po_overdue', v_po, 'assets_overdue', v_as, 'approvals_waiting', v_ap, 'digests', v_dg);
end $$;

-- The dispatcher: the Phase 1 logic is unchanged; housekeeping runs afterwards
-- in its own sub-transaction so it can never break the integrity check.
create or replace function integrity.dispatch()
returns jsonb language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare
  v_local timestamp := now() at time zone 'Africa/Johannesburg';
  v_sched time := private.setting_text('integrity.daily_run_time', '02:00')::time;
  v_attempts int; v_res jsonb := '{}'; v_done boolean; v_ops jsonb;
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
  return jsonb_build_object('check', v_res, 'watchdog', integrity.watchdog(), 'operations', v_ops);
end $$;

-- -----------------------------------------------------------------------------
-- Reservations screen
-- -----------------------------------------------------------------------------
create view public.v_reservations with (security_invoker = true) as
select r.*, p.sku, p.description, bu.code as uom_code, wt.warehouse_code, wt.branch_code, wt.company_code,
       oc.code as owner_company_code, u.full_name as created_by_name,
       r.qty_reserved - r.qty_fulfilled as qty_outstanding,
       (r.status = 'active' and r.expires_at is not null and r.expires_at <= now()) as is_expired
from public.stock_reservations r
join public.products p on p.id = r.product_id
join public.uoms bu on bu.id = p.base_uom_id
join public.v_warehouse_tree wt on wt.warehouse_id = r.warehouse_id
join public.companies oc on oc.id = r.owner_company_id
left join public.app_users u on u.id = r.created_by;

-- Reservations become retry-safe like every other write: a request id is now required, so a
-- dropped connection followed by "Retry safely" can never reserve the same stock twice.
drop function public.create_reservation(uuid, uuid, numeric, text, uuid, uuid, timestamptz, text);
create function public.create_reservation(
  p_request_id uuid, p_product_id uuid, p_warehouse_id uuid, p_qty numeric, p_reference text,
  p_owner_company_id uuid default null, p_uom_id uuid default null, p_expires_at timestamptz default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare v_uid uuid; c record; v_owner uuid; v_avail numeric; v_res numeric; v_id uuid; v_prev jsonb; v_payload jsonb;
begin
  v_payload := jsonb_build_object('p', p_product_id, 'w', p_warehouse_id, 'q', p_qty, 'r', p_reference, 'o', p_owner_company_id,
                                  'u', p_uom_id, 'e', p_expires_at, 'n', p_notes);
  v_prev := private.idem_begin(p_request_id, 'create_reservation', v_payload);
  if v_prev is not null then return v_prev; end if;
  v_uid := private.require_perm('stock.withdraw', p_warehouse_id);
  if coalesce(trim(p_reference),'') = '' then perform private.fail('CS422', 'A job / client reference is required'); end if;
  if p_expires_at is not null and p_expires_at <= now() then perform private.fail('CS422', 'The hold-until date must be in the future'); end if;
  select * into c from private.to_base(p_product_id, p_uom_id, p_qty);
  v_owner := coalesce(p_owner_company_id, private.warehouse_company(p_warehouse_id));
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
  return private.idem_finish(p_request_id, 'create_reservation', v_payload, jsonb_build_object('ok', true, 'reservation_id', v_id));
end $$;


-- ===== 20261026009000_phase2_security_lockdown.sql =====
-- =============================================================================
-- CSWMS Phase 2 — Migration 9000: SECURITY for Phase 2 objects, then the
-- privilege lockdown re-applied (keep this the LAST migration).
-- New tables are read-only for client roles; every write goes through the
-- permission-checked functions in migrations 1000–1300.
-- =============================================================================

do $$
declare t text;
begin
  foreach t in array array['purchase_orders','purchase_order_lines','approval_rules','approval_decisions',
                           'notification_preferences','assets','asset_movements'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;

create policy purchase_orders_read on public.purchase_orders for select to authenticated using (
  warehouse_id = any(private.my_warehouses('stock.view'))
  or warehouse_id = any(private.my_warehouses('purchase.manage'))
  or warehouse_id = any(private.my_warehouses('purchase.approve')));
create policy purchase_order_lines_read on public.purchase_order_lines for select to authenticated using (
  exists (select 1 from public.purchase_orders o where o.id = po_id));
create policy approval_rules_read on public.approval_rules for select to authenticated using (auth.uid() is not null);
create policy approval_decisions_read on public.approval_decisions for select to authenticated using (
  exists (select 1 from public.approval_requests a where a.id = approval_id));
create policy notification_preferences_read on public.notification_preferences for select to authenticated using (user_id = auth.uid());
create policy assets_read on public.assets for select to authenticated using (
  warehouse_id = any(private.my_warehouses('stock.view'))
  or warehouse_id = any(private.my_warehouses('asset.checkout'))
  or home_warehouse_id = any(private.my_warehouses('asset.manage'))
  or holder_user_id = auth.uid());
create policy asset_movements_read on public.asset_movements for select to authenticated using (
  exists (select 1 from public.assets a where a.id = asset_id));

revoke all on public.v_purchase_orders, public.v_purchase_order_lines, public.v_assets, public.v_asset_movements, public.v_approvals, public.v_reservations from anon;
grant select on public.v_purchase_orders, public.v_purchase_order_lines, public.v_assets, public.v_asset_movements, public.v_approvals, public.v_reservations to authenticated;

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
    if f.proname in ('cron_dispatch','email_outbox_claim','email_outbox_result','log_system_event') then
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


-- ===== 20261027001000_phase3_analytics.sql =====
-- =============================================================================
-- CSWMS Phase 3 — Advanced analytics and predictive management
--
-- Everything here READS the immutable ledger; nothing changes stock.
--   * analytics_movements      stock movement trends (day / week / month)
--   * analytics_velocity       fast / medium / slow / non-moving / dead stock + ABC class
--   * analytics_ageing         FIFO ageing of the stock on hand (0-30 … 365+ days)
--   * analytics_consumption    consumption by company, client/job, warehouse, branch, category, product, reason
--   * analytics_job            job costing: materials (net of returns), tools used, reservations
--   * analytics_valuation      inventory valuation at any date (weighted-average purchase cost)
--   * analytics_valuation_trend month-end valuation for the last N months
--   * analytics_forecast       demand forecast, stock-out prediction, suggested min / reorder
--   * analytics_performance    warehouse KPIs (turnover, stocktake accuracy, PO on-time, approvals …)
--   * analytics_supplier_performance  on-time delivery, fill rate and lead times per supplier
--   * predictive alerts        daily "likely to run out" alerts (type stockout_risk)
--
-- Rules
--   * Scope = warehouses where the user holds reports.view; p_company filters the OWNING company.
--   * Rand values only for users holding cost.view; otherwise value fields are null.
--   * Quantities of different units are never added together: cross-product totals are in rand
--     (or line counts), and quantity totals are given per unit of measure.
-- =============================================================================

insert into public.app_settings (key, value, category, description) values
  ('analytics.dead_days',              '180',  'analytics', 'Stock on hand with no issue and no receipt for this many days is reported as dead stock'),
  ('analytics.fast_issues_per_month',  '8',    'analytics', 'Items issued at least this many times a month are fast-moving'),
  ('analytics.slow_issues_per_month',  '2',    'analytics', 'Items issued fewer times a month than this are slow-moving'),
  ('analytics.default_lead_days',      '14',   'analytics', 'Supplier lead time (days) used when there is no purchase-order history'),
  ('analytics.service_level_z',        '1.65', 'analytics', 'Safety-stock factor (1.65 ≈ 95% service level, 2.05 ≈ 98%)'),
  ('analytics.order_cover_days',       '30',   'analytics', 'Days of demand a suggested reorder should cover'),
  ('analytics.excess_cover_days',      '180',  'analytics', 'More than this many days of cover (incl. open orders) is reported as excess'),
  ('analytics.stockout_alerts',        'true', 'analytics', 'Raise a daily "likely to run out" alert for items predicted to run out before a reorder can arrive'),
  ('analytics.prediction_time',        '"05:00"', 'analytics', 'Local time after which the daily stock-out prediction runs')
on conflict (key) do nothing;

alter table public.alerts drop constraint alerts_alert_type_check;
alter table public.alerts add constraint alerts_alert_type_check check (alert_type = any (array[
  'low_stock','out_of_stock','reorder','transfer_overdue','stocktake_due','stocktake_overdue','stocktake_discrepancy',
  'unusual_withdrawal','approval_pending','integrity','integrity_monitor','system',
  'po_overdue','asset_overdue','approval_overdue','stockout_risk']));

-- job / client lookups
create index if not exists stock_transactions_reference_norm on public.stock_transactions (upper(btrim(reference))) where reference is not null;
create index if not exists asset_movements_job_norm on public.asset_movements (upper(btrim(job_reference))) where job_reference is not null;
create index if not exists stock_ledger_type_time on public.stock_ledger (txn_type, posted_at);

-- daily prediction bookkeeping
create table private.analytics_runs (
  run_date     date primary key,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  warehouses   int,
  at_risk      int,
  error        text
);

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
-- warehouses the caller may analyse (optionally one of them)
create or replace function private.an_scope(p_warehouse uuid)
returns uuid[] language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v uuid[];
begin
  if auth.uid() is null then perform private.fail('CS401', 'Not signed in'); end if;
  v := private.my_warehouses('reports.view');
  if p_warehouse is not null then
    if not p_warehouse = any(v) then perform private.fail('CS401', 'You may not view analytics for this warehouse'); end if;
    return array[p_warehouse];
  end if;
  if cardinality(v) = 0 then perform private.fail('CS401', 'You do not have permission to view analytics'); end if;
  return v;
end $$;

-- end of a business day (Africa/Johannesburg) as a timestamp; null = now
create or replace function private.an_asof(p_date date)
returns timestamptz language sql stable as $$
  select case when p_date is null or p_date >= (now() at time zone 'Africa/Johannesburg')::date then now()
              else ((p_date + 1)::timestamp at time zone 'Africa/Johannesburg') end
$$;

-- Weighted-average purchase cost per BASE unit as at a moment:
--   all costed receipts / opening balances up to that moment; fallback = last purchase price; else none.
create or replace function private.an_unit_costs(p_as_of timestamptz)
returns table (product_id uuid, unit_cost numeric, source text)
language sql stable security definer set search_path = public, private, pg_temp as $$
  with r as (
    select l.product_id, sum(l.qty_delta) as q, sum(l.qty_delta * c.unit_cost / l.factor) as v
      from public.stock_ledger l
      join public.txn_line_costs c on c.txn_id = l.txn_id and c.line_no = l.line_no
     where l.txn_type in ('receipt','opening') and l.qty_delta > 0 and l.posted_at <= p_as_of
     group by 1)
  select p.id,
         coalesce(case when r.q > 0 then round(r.v / r.q, 4) end, pc.purchase_price),
         case when r.q > 0 then 'weighted_average' when pc.purchase_price is not null then 'last_price' else 'none' end
    from public.products p
    left join r on r.product_id = p.id
    left join public.product_costs pc on pc.product_id = p.id
$$;

-- -----------------------------------------------------------------------------
-- 1. Movement trends
-- -----------------------------------------------------------------------------
create or replace function public.analytics_movements(
  p_from date, p_to date, p_bucket text default 'month', p_warehouse uuid default null,
  p_company uuid default null, p_category uuid default null, p_product uuid default null)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_whs uuid[] := private.an_scope(p_warehouse); v_measure text; v_cost boolean := private.has_perm('cost.view');
begin
  if p_bucket not in ('day','week','month') then perform private.fail('CS422', 'Bucket must be day, week or month'); end if;
  if p_from is null or p_to is null or p_to < p_from then perform private.fail('CS422', 'Choose a valid date range'); end if;
  if p_to - p_from > 1100 then perform private.fail('CS422', 'The range may be at most three years'); end if;
  if p_bucket = 'day' and p_to - p_from > 190 then perform private.fail('CS422', 'Daily buckets are limited to six months — use weeks or months'); end if;
  v_measure := case when p_product is not null then 'qty' when v_cost then 'value' else 'lines' end;
  return query
  with b as (
    select g::date as bucket
      from generate_series(date_trunc(p_bucket, p_from::timestamp), date_trunc(p_bucket, p_to::timestamp), ('1 ' || p_bucket)::interval) g),
  c as (select * from private.an_unit_costs(now())),
  m as (
    select date_trunc(p_bucket, l.posted_at at time zone 'Africa/Johannesburg')::date as bucket,
           case when l.txn_type in ('receipt','opening') then 'received'
                when l.txn_type = 'withdrawal' then 'issued'
                when l.txn_type = 'return' then 'returned'
                when l.txn_type = 'transfer_receipt' then 'transfer_in'
                when l.txn_type = 'transfer_dispatch' then 'transfer_out'
                when l.txn_type in ('adjustment','stocktake_adjustment','transfer_writeoff','reversal') then 'adjusted' end as flow,
           case v_measure when 'qty' then l.qty_delta when 'value' then l.qty_delta * coalesce(c.unit_cost, 0) else sign(l.qty_delta) end as x
      from public.stock_ledger l
      join public.products p on p.id = l.product_id
      left join c on c.product_id = l.product_id
     where l.warehouse_id = any(v_whs)
       and l.posted_at >= (p_from::timestamp at time zone 'Africa/Johannesburg')
       and l.posted_at <  ((p_to + 1)::timestamp at time zone 'Africa/Johannesburg')
       and (l.status <> 'in_transit' or l.txn_type = 'transfer_writeoff')
       and (p_company is null or l.owner_company_id = p_company)
       and (p_category is null or p.category_id = p_category)
       and (p_product is null or l.product_id = p_product)),
  agg as (
    select bucket,
           coalesce(sum(x) filter (where flow = 'received'), 0)      as received,
           coalesce(-sum(x) filter (where flow = 'issued'), 0)       as issued,
           coalesce(sum(x) filter (where flow = 'returned'), 0)      as returned,
           coalesce(sum(x) filter (where flow = 'transfer_in'), 0)   as transfer_in,
           coalesce(-sum(x) filter (where flow = 'transfer_out'), 0) as transfer_out,
           coalesce(sum(x) filter (where flow = 'adjusted'), 0)      as adjusted
      from m where flow is not null group by 1)
  select jsonb_build_object('bucket', b.bucket, 'measure', v_measure,
           'received', round(coalesce(a.received, 0), 2), 'issued', round(coalesce(a.issued, 0), 2),
           'returned', round(coalesce(a.returned, 0), 2), 'transfer_in', round(coalesce(a.transfer_in, 0), 2),
           'transfer_out', round(coalesce(a.transfer_out, 0), 2), 'adjusted', round(coalesce(a.adjusted, 0), 2),
           'net_consumption', round(coalesce(a.issued, 0) - coalesce(a.returned, 0), 2))
    from b left join agg a on a.bucket = b.bucket
   order by b.bucket;
end $$;

-- -----------------------------------------------------------------------------
-- 2. Velocity: fast / medium / slow / non-moving / dead + ABC
-- -----------------------------------------------------------------------------
create or replace function public.analytics_velocity(
  p_days int default 90, p_warehouse uuid default null, p_company uuid default null,
  p_category uuid default null, p_as_of date default null)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_whs uuid[] := private.an_scope(p_warehouse);
  v_asof timestamptz := private.an_asof(p_as_of);
  v_start timestamptz;
  v_cost boolean := private.has_perm('cost.view');
  v_dead int := private.setting_num('analytics.dead_days', 180);
  v_fast numeric := private.setting_num('analytics.fast_issues_per_month', 8);
  v_slow numeric := private.setting_num('analytics.slow_issues_per_month', 2);
begin
  if p_days is null or p_days < 7 or p_days > 730 then perform private.fail('CS422', 'Analysis period must be 7 to 730 days'); end if;
  v_start := v_asof - make_interval(days => p_days);
  return query
  with l as (
    select l.* from public.stock_ledger l
     where l.warehouse_id = any(v_whs) and l.posted_at <= v_asof and l.status <> 'in_transit'
       and (p_company is null or l.owner_company_id = p_company)),
  s as (
    select l.product_id,
           sum(l.qty_delta) as on_hand,
           -coalesce(sum(l.qty_delta) filter (where l.txn_type in ('withdrawal','return') and l.posted_at > v_start), 0) as net_issued,
           count(distinct l.txn_id) filter (where l.txn_type = 'withdrawal' and l.posted_at > v_start) as issue_count,
           max(l.posted_at) filter (where l.txn_type = 'withdrawal') as last_issue_at,
           max(l.posted_at) filter (where l.txn_type in ('receipt','opening','transfer_receipt') and l.qty_delta > 0) as last_receipt_at,
           max(l.posted_at) filter (where l.txn_type not in ('move','status_change')) as last_movement_at
      from l group by 1),
  c as (select * from private.an_unit_costs(v_asof)),
  r as (
    select s.*, p.sku, p.description, p.category_id, cat.name as category, u.code as uom, c.unit_cost,
           s.net_issued / p_days as avg_daily,
           s.issue_count / (p_days / 30.0) as issues_per_month,
           s.on_hand * c.unit_cost as value_on_hand,
           s.net_issued * c.unit_cost as issued_value
      from s
      join public.products p on p.id = s.product_id
      join public.uoms u on u.id = p.base_uom_id
      left join public.categories cat on cat.id = p.category_id
      left join c on c.product_id = s.product_id
     where (s.on_hand > 0 or s.issue_count > 0)
       and (p_category is null or p.category_id = p_category)),
  k as (
    select r.*,
           case
             when r.on_hand > 0 and coalesce(r.last_issue_at, '-infinity') < v_asof - make_interval(days => v_dead)
                  and coalesce(r.last_receipt_at, '-infinity') < v_asof - make_interval(days => v_dead) then 'dead'
             when r.issue_count = 0 then 'non_moving'
             when r.issues_per_month >= v_fast then 'fast'
             when r.issues_per_month >= v_slow then 'medium'
             else 'slow' end as movement_class,
           -- ABC on consumption value (or issue frequency when prices are not visible / not known)
           case when v_cost then coalesce(r.issued_value, 0) else r.issue_count end as abc_basis
      from r),
  a as (
    select k.*,
           sum(abc_basis) over (order by abc_basis desc, sku rows unbounded preceding) as cum,
           sum(abc_basis) over () as tot
      from k)
  select jsonb_build_object(
           'product_id', a.product_id, 'sku', a.sku, 'description', a.description, 'category', a.category, 'uom', a.uom,
           'on_hand', round(a.on_hand, 4), 'net_issued', round(a.net_issued, 4), 'issue_count', a.issue_count,
           'issues_per_month', round(a.issues_per_month, 2), 'avg_daily', round(a.avg_daily, 4),
           'days_cover', case when a.avg_daily > 0 then round(greatest(a.on_hand, 0) / a.avg_daily, 1) end,
           'last_issue_at', a.last_issue_at, 'last_receipt_at', a.last_receipt_at,
           'days_since_issue', case when a.last_issue_at is not null then extract(day from v_asof - a.last_issue_at)::int end,
           'days_since_movement', case when a.last_movement_at is not null then extract(day from v_asof - a.last_movement_at)::int end,
           'movement_class', a.movement_class,
           'abc_class', case when a.tot = 0 or a.abc_basis = 0 then 'C' when a.cum - a.abc_basis < 0.80 * a.tot then 'A'
                             when a.cum - a.abc_basis < 0.95 * a.tot then 'B' else 'C' end,
           'unit_cost', case when v_cost then a.unit_cost end,
           'value_on_hand', case when v_cost then round(a.value_on_hand, 2) end,
           'issued_value', case when v_cost then round(a.issued_value, 2) end)
    from a
   order by case a.movement_class when 'dead' then 1 when 'non_moving' then 2 when 'slow' then 3 when 'medium' then 4 else 5 end,
            a.value_on_hand desc nulls last, a.sku;
end $$;

-- -----------------------------------------------------------------------------
-- 3. Stock ageing (FIFO: the stock on hand is assumed to be the most recently arrived)
-- -----------------------------------------------------------------------------
create or replace function public.analytics_ageing(
  p_warehouse uuid default null, p_company uuid default null, p_category uuid default null, p_as_of date default null)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_whs uuid[] := private.an_scope(p_warehouse);
  v_asof timestamptz := private.an_asof(p_as_of);
  v_day date := (private.an_asof(p_as_of) at time zone 'Africa/Johannesburg')::date;
  v_cost boolean := private.has_perm('cost.view');
begin
  return query
  with l as (
    select l.* from public.stock_ledger l
     where l.warehouse_id = any(v_whs) and l.posted_at <= v_asof and l.status <> 'in_transit'
       and (p_company is null or l.owner_company_id = p_company)),
  oh as (select product_id, warehouse_id, sum(qty_delta) as q from l group by 1, 2 having sum(qty_delta) > 0),
  inb as (
    select l.product_id, l.warehouse_id, l.id, l.posted_at, l.qty_delta as q
      from l join oh using (product_id, warehouse_id)
     where l.qty_delta > 0
       and l.txn_type in ('opening','receipt','return','transfer_receipt','adjustment','stocktake_adjustment','reversal')),
  cum as (
    select i.*, sum(i.q) over (partition by i.product_id, i.warehouse_id order by i.posted_at desc, i.id desc) as running from inb i),
  alloc as (
    select c.product_id, c.warehouse_id, v_day - (c.posted_at at time zone 'Africa/Johannesburg')::date as age,
           least(c.q, greatest(oh.q - (c.running - c.q), 0)) as aq
      from cum c join oh using (product_id, warehouse_id)),
  b as (
    select product_id, warehouse_id,
           coalesce(sum(aq) filter (where age <= 30), 0)                 as d0_30,
           coalesce(sum(aq) filter (where age between 31 and 90), 0)     as d31_90,
           coalesce(sum(aq) filter (where age between 91 and 180), 0)    as d91_180,
           coalesce(sum(aq) filter (where age between 181 and 365), 0)   as d181_365,
           coalesce(sum(aq) filter (where age > 365), 0)                 as d365p,
           sum(aq * age) / nullif(sum(aq), 0)                            as avg_age,
           max(age) filter (where aq > 0)                                as oldest,
           sum(aq)                                                       as allocated
      from alloc where aq > 0 group by 1, 2),
  c as (select * from private.an_unit_costs(v_asof))
  select jsonb_build_object(
           'product_id', oh.product_id, 'warehouse_id', oh.warehouse_id, 'sku', p.sku, 'description', p.description,
           'category', cat.name, 'uom', u.code, 'warehouse_code', wt.warehouse_code,
           'on_hand', round(oh.q, 4),
           'd0_30', round(coalesce(b.d0_30, 0), 4), 'd31_90', round(coalesce(b.d31_90, 0), 4), 'd91_180', round(coalesce(b.d91_180, 0), 4),
           'd181_365', round(coalesce(b.d181_365, 0), 4), 'd365p', round(coalesce(b.d365p, 0), 4),
           'unknown_age', round(oh.q - coalesce(b.allocated, 0), 4),
           'avg_age_days', round(b.avg_age, 0), 'oldest_days', b.oldest,
           'unit_cost', case when v_cost then c.unit_cost end,
           'value', case when v_cost then round(oh.q * c.unit_cost, 2) end,
           'value_0_30', case when v_cost then round(coalesce(b.d0_30, 0) * c.unit_cost, 2) end,
           'value_31_90', case when v_cost then round(coalesce(b.d31_90, 0) * c.unit_cost, 2) end,
           'value_91_180', case when v_cost then round(coalesce(b.d91_180, 0) * c.unit_cost, 2) end,
           'value_181_365', case when v_cost then round(coalesce(b.d181_365, 0) * c.unit_cost, 2) end,
           'value_365p', case when v_cost then round(coalesce(b.d365p, 0) * c.unit_cost, 2) end)
    from oh
    join public.products p on p.id = oh.product_id
    join public.uoms u on u.id = p.base_uom_id
    join private.warehouse_tree wt on wt.warehouse_id = oh.warehouse_id
    left join public.categories cat on cat.id = p.category_id
    left join b on b.product_id = oh.product_id and b.warehouse_id = oh.warehouse_id
    left join c on c.product_id = oh.product_id
   where p_category is null or p.category_id = p_category
   order by b.avg_age desc nulls last, p.sku, wt.warehouse_code;
end $$;

-- -----------------------------------------------------------------------------
-- 4. Consumption (withdrawals net of returns)
-- -----------------------------------------------------------------------------
create or replace function public.analytics_consumption(
  p_from date, p_to date, p_group text default 'company', p_warehouse uuid default null,
  p_company uuid default null, p_category uuid default null)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_whs uuid[] := private.an_scope(p_warehouse); v_cost boolean := private.has_perm('cost.view');
begin
  if p_group not in ('company','client','warehouse','branch','category','product','reason') then
    perform private.fail('CS422', 'Group by company, client, warehouse, branch, category, product or reason');
  end if;
  if p_from is null or p_to is null or p_to < p_from then perform private.fail('CS422', 'Choose a valid date range'); end if;
  return query
  with c as (select * from private.an_unit_costs(now())),
  m as (
    select case p_group
             when 'company'  then oc.id::text
             when 'client'   then coalesce(nullif(upper(btrim(t.reference)), ''), '(NO REFERENCE)')
             when 'warehouse' then l.warehouse_id::text
             when 'branch'   then wt.branch_id::text
             when 'category' then coalesce(p.category_id::text, '-')
             when 'product'  then p.id::text
             when 'reason'   then coalesce(rc.code, '-') end as key,
           case p_group
             when 'company'  then oc.code || ' — ' || oc.name
             when 'client'   then coalesce(nullif(upper(btrim(t.reference)), ''), '(no reference)')
             when 'warehouse' then wt.warehouse_code || ' — ' || wt.warehouse_name
             when 'branch'   then wt.branch_code || ' — ' || wt.branch_name
             when 'category' then coalesce(cat.name, '(uncategorised)')
             when 'product'  then p.sku || ' — ' || p.description
             when 'reason'   then coalesce(rc.label, '(none)') end as label,
           l.txn_type, l.txn_id, l.product_id, u.code as uom, -l.qty_delta as net_q,
           -l.qty_delta * c.unit_cost as net_v, l.posted_at
      from public.stock_ledger l
      join public.stock_transactions t on t.id = l.txn_id
      join public.products p on p.id = l.product_id
      join public.uoms u on u.id = p.base_uom_id
      join public.companies oc on oc.id = l.owner_company_id
      join private.warehouse_tree wt on wt.warehouse_id = l.warehouse_id
      left join public.categories cat on cat.id = p.category_id
      left join public.reason_codes rc on rc.id = t.reason_code_id
      left join c on c.product_id = l.product_id
     where l.txn_type in ('withdrawal','return') and l.status <> 'in_transit'
       and l.warehouse_id = any(v_whs)
       and l.posted_at >= (p_from::timestamp at time zone 'Africa/Johannesburg')
       and l.posted_at <  ((p_to + 1)::timestamp at time zone 'Africa/Johannesburg')
       and (p_company is null or l.owner_company_id = p_company)
       and (p_category is null or p.category_id = p_category)),
  q as (select key, uom, sum(net_q) as q from m group by 1, 2),
  g as (
    select key, min(label) as label,
           count(*) filter (where txn_type = 'withdrawal') as issue_lines,
           count(distinct txn_id) filter (where txn_type = 'withdrawal') as issues,
           count(*) filter (where txn_type = 'return') as return_lines,
           count(distinct product_id) as products,
           sum(net_v) filter (where txn_type = 'withdrawal') as issued_value,
           -sum(net_v) filter (where txn_type = 'return') as returned_value,
           sum(net_v) as net_value,
           bool_or(net_v is null) as has_uncosted,
           min(posted_at) as first_at, max(posted_at) as last_at
      from m group by 1)
  select jsonb_build_object(
           'key', g.key, 'label', g.label, 'issues', g.issues, 'issue_lines', g.issue_lines, 'return_lines', g.return_lines,
           'products', g.products,
           'qty_by_uom', (select jsonb_object_agg(q.uom, round(q.q, 4)) from q where q.key = g.key and q.q <> 0),
           'issued_value', case when v_cost then round(coalesce(g.issued_value, 0), 2) end,
           'returned_value', case when v_cost then round(coalesce(g.returned_value, 0), 2) end,
           'net_value', case when v_cost then round(coalesce(g.net_value, 0), 2) end,
           'has_uncosted_items', g.has_uncosted,
           'first_at', g.first_at, 'last_at', g.last_at)
    from g
   order by g.net_value desc nulls last, g.issue_lines desc, g.label;
end $$;

-- -----------------------------------------------------------------------------
-- 5. Job costing
-- -----------------------------------------------------------------------------
create or replace function public.analytics_job(p_reference text)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_whs uuid[] := private.an_scope(null);
  v_ref text := upper(btrim(p_reference));
  v_cost boolean := private.has_perm('cost.view');
  v_mat jsonb; v_txn jsonb; v_tools jsonb; v_res jsonb; v_value numeric; v_uncosted boolean;
begin
  if coalesce(v_ref, '') = '' then perform private.fail('CS422', 'Enter a job / client reference'); end if;
  with c as (select * from private.an_unit_costs(now())),
  m as (
    select l.product_id, p.sku, p.description, u.code as uom, l.txn_type, -l.qty_delta as net_q, c.unit_cost
      from public.stock_ledger l
      join public.stock_transactions t on t.id = l.txn_id
      join public.products p on p.id = l.product_id
      join public.uoms u on u.id = p.base_uom_id
      left join c on c.product_id = l.product_id
     where upper(btrim(t.reference)) = v_ref and l.txn_type in ('withdrawal','return')
       and l.status <> 'in_transit' and l.warehouse_id = any(v_whs)),
  g as (
    select product_id, sku, description, uom, min(unit_cost) as unit_cost,
           sum(net_q) filter (where txn_type = 'withdrawal') as issued,
           -coalesce(sum(net_q) filter (where txn_type = 'return'), 0) as returned,
           sum(net_q) as net
      from m group by 1, 2, 3, 4)
  select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'sku', sku, 'description', description, 'uom', uom,
           'issued', round(coalesce(issued, 0), 4), 'returned', round(returned, 4), 'net', round(net, 4),
           'unit_cost', case when v_cost then unit_cost end,
           'value', case when v_cost then round(net * unit_cost, 2) end) order by net * coalesce(unit_cost, 0) desc, sku), '[]'),
         sum(net * unit_cost), bool_or(unit_cost is null)
    into v_mat, v_value, v_uncosted
    from g;

  select coalesce(jsonb_agg(jsonb_build_object('txn_id', t.id, 'txn_no', t.txn_no, 'txn_type', t.txn_type, 'posted_at', t.posted_at,
           'warehouse_code', wt.warehouse_code, 'by', u.full_name, 'reference', t.reference) order by t.posted_at), '[]')
    into v_txn
    from public.stock_transactions t
    join private.warehouse_tree wt on wt.warehouse_id = t.warehouse_id
    left join public.app_users u on u.id = t.created_by
   where upper(btrim(t.reference)) = v_ref and t.status = 'posted' and t.txn_type in ('withdrawal','return')
     and t.warehouse_id = any(v_whs);

  -- tools: each check-out for this job and when it came back
  with o as (
    select m.id, m.asset_id, m.created_at as out_at, coalesce(hu.full_name, m.holder_name) as holder,
           (select min(i.created_at) from public.asset_movements i
             where i.asset_id = m.asset_id and i.movement in ('check_in','mark_lost') and i.created_at > m.created_at) as back_at
      from public.asset_movements m
      left join public.app_users hu on hu.id = m.holder_user_id
     where m.movement = 'check_out' and upper(btrim(m.job_reference)) = v_ref and m.warehouse_id = any(v_whs))
  select coalesce(jsonb_agg(jsonb_build_object('asset_id', a.id, 'asset_tag', a.asset_tag, 'description', p.description,
           'holder', o.holder, 'out_at', o.out_at, 'back_at', o.back_at,
           'days', round((extract(epoch from coalesce(o.back_at, now()) - o.out_at) / 86400)::numeric, 1)) order by o.out_at), '[]')
    into v_tools
    from o join public.assets a on a.id = o.asset_id join public.products p on p.id = a.product_id;

  select coalesce(jsonb_agg(jsonb_build_object('sku', p.sku, 'description', p.description, 'uom', u.code,
           'outstanding', r.qty_reserved - r.qty_fulfilled, 'warehouse_code', wt.warehouse_code, 'expires_at', r.expires_at)), '[]')
    into v_res
    from public.stock_reservations r
    join public.products p on p.id = r.product_id
    join public.uoms u on u.id = p.base_uom_id
    join private.warehouse_tree wt on wt.warehouse_id = r.warehouse_id
   where upper(btrim(r.reference)) = v_ref and r.status = 'active' and r.warehouse_id = any(v_whs);

  return jsonb_build_object('reference', v_ref, 'materials', v_mat, 'transactions', v_txn, 'tools', v_tools, 'reservations', v_res,
    'material_value', case when v_cost then round(coalesce(v_value, 0), 2) end,
    'has_uncosted_items', coalesce(v_uncosted, false),
    'tool_days', (select coalesce(sum((x ->> 'days')::numeric), 0) from jsonb_array_elements(v_tools) x),
    'first_at', (select min((x ->> 'posted_at')::timestamptz) from jsonb_array_elements(v_txn) x),
    'last_at', (select max((x ->> 'posted_at')::timestamptz) from jsonb_array_elements(v_txn) x));
end $$;

-- -----------------------------------------------------------------------------
-- 6. Valuation
-- -----------------------------------------------------------------------------
create or replace function public.analytics_valuation(
  p_as_of date default null, p_group text default 'company', p_warehouse uuid default null, p_company uuid default null)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_whs uuid[] := private.an_scope(p_warehouse); v_asof timestamptz := private.an_asof(p_as_of);
begin
  if not private.has_perm('cost.view') then perform private.fail('CS401', 'Inventory valuation needs permission to view prices (cost.view)'); end if;
  if p_group not in ('company','warehouse','branch','category','product','status') then
    perform private.fail('CS422', 'Group by company, warehouse, branch, category, product or status');
  end if;
  return query
  with oh as (
    select l.product_id, l.warehouse_id, l.owner_company_id, l.status, sum(l.qty_delta) as q
      from public.stock_ledger l
     where l.warehouse_id = any(v_whs) and l.posted_at <= v_asof and (p_company is null or l.owner_company_id = p_company)
     group by 1, 2, 3, 4 having sum(l.qty_delta) <> 0),
  c as (select * from private.an_unit_costs(v_asof)),
  m as (
    select case p_group when 'company' then oc.id::text when 'warehouse' then oh.warehouse_id::text when 'branch' then wt.branch_id::text
                        when 'category' then coalesce(p.category_id::text, '-') when 'product' then p.id::text else oh.status::text end as key,
           case p_group when 'company' then oc.code || ' — ' || oc.name when 'warehouse' then wt.warehouse_code || ' — ' || wt.warehouse_name
                        when 'branch' then wt.branch_code || ' — ' || wt.branch_name when 'category' then coalesce(cat.name, '(uncategorised)')
                        when 'product' then p.sku || ' — ' || p.description else oh.status::text end as label,
           oh.product_id, u.code as uom, oh.q, c.unit_cost, c.source
      from oh
      join public.products p on p.id = oh.product_id
      join public.uoms u on u.id = p.base_uom_id
      join public.companies oc on oc.id = oh.owner_company_id
      join private.warehouse_tree wt on wt.warehouse_id = oh.warehouse_id
      left join public.categories cat on cat.id = p.category_id
      left join c on c.product_id = oh.product_id),
  q as (select key, uom, sum(q) as q from m group by 1, 2),
  g as (
    select key, min(label) as label, sum(q * unit_cost) as value, count(distinct product_id) as products,
           count(distinct product_id) filter (where source = 'none') as uncosted,
           count(distinct product_id) filter (where source = 'last_price') as at_last_price
      from m group by 1)
  select jsonb_build_object('key', g.key, 'label', g.label, 'value', round(coalesce(g.value, 0), 2), 'products', g.products,
           'uncosted_products', g.uncosted, 'products_at_last_price', g.at_last_price,
           'qty_by_uom', (select jsonb_object_agg(q.uom, round(q.q, 4)) from q where q.key = g.key and q.q <> 0),
           'as_of', v_asof)
    from g order by g.value desc nulls last, g.label;
end $$;

create or replace function public.analytics_valuation_trend(p_months int default 12, p_warehouse uuid default null, p_company uuid default null)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v_whs uuid[] := private.an_scope(p_warehouse);
begin
  if not private.has_perm('cost.view') then perform private.fail('CS401', 'Inventory valuation needs permission to view prices (cost.view)'); end if;
  if p_months is null or p_months < 1 or p_months > 36 then perform private.fail('CS422', 'Choose 1 to 36 months'); end if;
  return query
  with mo as (
    select g::date as month,
           least(((g + interval '1 month')::timestamp at time zone 'Africa/Johannesburg'), now()) as asof
      from generate_series(date_trunc('month', (now() at time zone 'Africa/Johannesburg')) - make_interval(months => p_months - 1),
                           date_trunc('month', (now() at time zone 'Africa/Johannesburg')), interval '1 month') g),
  mc as (select mo.month, uc.product_id, uc.unit_cost from mo cross join lateral private.an_unit_costs(mo.asof) uc)
  select jsonb_build_object('month', mo.month, 'as_of', mo.asof,
           'value', round(coalesce(sum(x.q * c.unit_cost), 0), 2),
           'in_transit_value', round(coalesce(sum(x.q * c.unit_cost) filter (where x.status = 'in_transit'), 0), 2),
           'damaged_value', round(coalesce(sum(x.q * c.unit_cost) filter (where x.status in ('damaged','quarantine')), 0), 2))
    from mo
    left join lateral (
      select l.product_id, l.status, sum(l.qty_delta) as q from public.stock_ledger l
       where l.warehouse_id = any(v_whs) and l.posted_at <= mo.asof and (p_company is null or l.owner_company_id = p_company)
       group by 1, 2) x on true
    left join mc c on c.month = mo.month and c.product_id = x.product_id
   group by mo.month, mo.asof order by mo.month;
end $$;

-- -----------------------------------------------------------------------------
-- 7. Demand forecasting and stock-out prediction (one warehouse)
--    History: twelve 30-day periods ending at the as-of moment (net issues = withdrawals − returns),
--    only periods after the item first appeared in the warehouse.
--    Model: Holt's linear exponential smoothing with a damped trend (α 0.5, β 0.3, φ 0.9).
--    Safety stock = z · σ(daily) · √lead time;  reorder point = daily demand · lead time + safety stock.
-- -----------------------------------------------------------------------------
create or replace function private.an_forecast(p_warehouse uuid, p_as_of timestamptz, p_horizon int, p_product uuid default null)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  r record; y numeric[]; n int; i int;
  a constant numeric := 0.5; b constant numeric := 0.3; phi constant numeric := 0.9;
  lvl numeric; trd numeric; prev numeric; sd numeric; d numeric; fc numeric; fper numeric[]; k int; phisum numeric;
  v_lead numeric; v_ss numeric; v_rop numeric; v_free numeric; v_onorder numeric; v_res numeric; v_risk text;
  v_z numeric := private.setting_num('analytics.service_level_z', 1.65);
  v_deflead numeric := private.setting_num('analytics.default_lead_days', 14);
  v_cover numeric := private.setting_num('analytics.order_cover_days', 30);
  v_excess numeric := private.setting_num('analytics.excess_cover_days', 180);
  v_lead_src text; v_suggest numeric; v_th record;
begin
  for r in
    with base as (
      select l.product_id, min(l.posted_at) as first_seen,
             sum(l.qty_delta) filter (where l.status = 'available') as available
        from public.stock_ledger l
       where l.warehouse_id = p_warehouse and l.posted_at <= p_as_of and (p_product is null or l.product_id = p_product)
       group by 1),
    per as (
      select l.product_id, 12 - floor(extract(epoch from p_as_of - l.posted_at) / (30 * 86400))::int as k, -sum(l.qty_delta) as q
        from public.stock_ledger l
       where l.warehouse_id = p_warehouse and l.txn_type in ('withdrawal','return') and l.status <> 'in_transit'
         and l.posted_at > p_as_of - interval '360 days' and l.posted_at <= p_as_of
         and (p_product is null or l.product_id = p_product)
       group by 1, 2)
    select b.product_id, b.first_seen, coalesce(b.available, 0) as available, p.sku, p.description, u.code as uom,
           p.default_supplier_id,
           (select array_agg(coalesce(per.q, 0) order by g)
              from generate_series(greatest(1, 12 - floor(extract(epoch from p_as_of - b.first_seen) / (30 * 86400))::int), 12) g
              left join per on per.product_id = b.product_id and per.k = g) as hist
      from base b
      join public.products p on p.id = b.product_id and p.status = 'active' and not p.is_asset
      join public.uoms u on u.id = p.base_uom_id
     where exists (select 1 from per where per.product_id = b.product_id)
        or exists (select 1 from public.stock_thresholds t where t.product_id = b.product_id
                    and (t.warehouse_id = p_warehouse or t.warehouse_id is null) and t.min_qty > 0)
  loop
    y := coalesce(r.hist, array[0]::numeric[]);
    n := cardinality(y);
    -- Holt's damped trend
    lvl := y[1]; trd := case when n >= 2 then y[2] - y[1] else 0 end;
    for i in 2..n loop
      prev := lvl;
      lvl := a * y[i] + (1 - a) * (lvl + phi * trd);
      trd := b * (lvl - prev) + (1 - b) * phi * trd;
    end loop;
    if n >= 3 then
      select stddev_samp(v) into sd from unnest(y) v;
    else
      sd := 0;
    end if;
    -- next periods
    fper := array[]::numeric[]; phisum := 0;
    for k in 1..greatest(3, ceil(p_horizon / 30.0)::int) loop
      phisum := phisum + power(phi, k);
      fper := fper || greatest(round(lvl + phisum * trd, 4), 0);
    end loop;
    -- forecast over the horizon (pro-rata on the last partial period)
    fc := 0;
    for k in 1..ceil(p_horizon / 30.0)::int loop
      fc := fc + fper[k] * least(1, (p_horizon - (k - 1) * 30) / 30.0);
    end loop;
    d := fper[1] / 30.0;                       -- daily demand for the coming period

    -- lead time: this item at this warehouse, else its default supplier, else the setting
    select avg(extract(epoch from rt.first_receipt - coalesce(po.sent_at, po.approved_at)) / 86400), 'item history'
      into v_lead, v_lead_src
      from public.purchase_orders po
      join public.purchase_order_lines pl on pl.po_id = po.id and pl.product_id = r.product_id
      cross join lateral (
        select min(t.posted_at) as first_receipt from public.stock_transaction_lines tl
          join public.stock_transactions t on t.id = tl.txn_id and t.status = 'posted'
         where tl.extra ->> 'po_id' = po.id::text) rt
     where po.warehouse_id = p_warehouse and rt.first_receipt is not null and coalesce(po.sent_at, po.approved_at) is not null
       and rt.first_receipt > p_as_of - interval '365 days';
    if v_lead is null and r.default_supplier_id is not null then
      select avg(extract(epoch from rt.first_receipt - coalesce(po.sent_at, po.approved_at)) / 86400), 'supplier history'
        into v_lead, v_lead_src
        from public.purchase_orders po
        cross join lateral (
          select min(t.posted_at) as first_receipt from public.stock_transaction_lines tl
            join public.stock_transactions t on t.id = tl.txn_id and t.status = 'posted'
           where tl.extra ->> 'po_id' = po.id::text) rt
       where po.supplier_id = r.default_supplier_id and rt.first_receipt is not null and coalesce(po.sent_at, po.approved_at) is not null
         and rt.first_receipt > p_as_of - interval '365 days';
    end if;
    if v_lead is null then v_lead := v_deflead; v_lead_src := 'default setting'; end if;
    v_lead := greatest(round(v_lead, 1), 1);

    v_ss := v_z * (coalesce(sd, 0) / sqrt(30.0)) * sqrt(v_lead);
    v_rop := d * v_lead + v_ss;
    select coalesce(sum(qty_reserved - qty_fulfilled), 0) into v_res from public.stock_reservations
     where product_id = r.product_id and warehouse_id = p_warehouse and status = 'active' and (expires_at is null or expires_at > p_as_of);
    v_free := greatest(r.available - v_res, 0);
    select coalesce(sum(greatest(pl.qty_ordered_base - pl.qty_received_base, 0)), 0) into v_onorder
      from public.purchase_order_lines pl join public.purchase_orders po on po.id = pl.po_id
     where pl.product_id = r.product_id and po.warehouse_id = p_warehouse and po.status in ('approved','sent','partially_received');
    select min_qty, reorder_qty into v_th from public.stock_thresholds
     where product_id = r.product_id and (warehouse_id = p_warehouse or warehouse_id is null)
     order by warehouse_id nulls last limit 1;

    v_risk := case
      when d <= 0 then 'no_demand'
      when v_free + v_onorder < d * v_lead then 'critical'
      when v_free + v_onorder < v_rop then 'warning'
      when (v_free + v_onorder) / d > v_excess then 'excess'
      else 'ok' end;
    v_suggest := case when v_risk in ('critical','warning') then ceil(v_rop + d * v_cover - v_free - v_onorder) else 0 end;

    return next jsonb_build_object(
      'product_id', r.product_id, 'sku', r.sku, 'description', r.description, 'uom', r.uom,
      'history', to_jsonb(y), 'history_periods', n, 'forecast_periods', to_jsonb(fper[1:3]),
      'avg_period_demand', round((select avg(v) from unnest(y) v), 4),
      'daily_demand', round(d, 4), 'forecast_qty', round(fc, 2), 'horizon_days', p_horizon,
      -- rising / falling = the projected change is more than 2% of the current level per 30-day period
      'trend', case when phi * trd > 0.02 * greatest(lvl, 0.0001) then 'rising' when phi * trd < -0.02 * greatest(lvl, 0.0001) then 'falling' else 'steady' end,
      'demand_sd_period', round(coalesce(sd, 0), 4),
      'available', round(r.available, 4), 'reserved', round(v_res, 4), 'free', round(v_free, 4), 'on_order', round(v_onorder, 4),
      'lead_time_days', v_lead, 'lead_time_source', v_lead_src,
      'safety_stock', ceil(v_ss), 'reorder_point', ceil(v_rop),
      'days_cover', case when d > 0 then round(v_free / d, 1) end,
      'days_cover_with_orders', case when d > 0 then round((v_free + v_onorder) / d, 1) end,
      'stockout_date', case when d > 0 then ((p_as_of + make_interval(secs => (v_free / d) * 86400)) at time zone 'Africa/Johannesburg')::date end,
      'current_min', v_th.min_qty, 'current_reorder', v_th.reorder_qty,
      'suggested_min', ceil(v_rop), 'suggested_reorder_qty', ceil(d * v_cover),
      'suggested_order_now', greatest(v_suggest, 0),
      'risk', v_risk);
  end loop;
end $$;

create or replace function public.analytics_forecast(p_warehouse uuid, p_horizon int default 30, p_category uuid default null, p_product uuid default null)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare v jsonb;
begin
  perform private.an_scope(p_warehouse);
  if p_warehouse is null then perform private.fail('CS422', 'Choose a warehouse — forecasts are per warehouse'); end if;
  if p_horizon is null or p_horizon < 7 or p_horizon > 365 then perform private.fail('CS422', 'Forecast horizon must be 7 to 365 days'); end if;
  for v in select f from private.an_forecast(p_warehouse, now(), p_horizon, p_product) f
            join public.products p on p.id = (f ->> 'product_id')::uuid
           where p_category is null or p.category_id = p_category
           order by case f ->> 'risk' when 'critical' then 1 when 'warning' then 2 when 'excess' then 4 when 'ok' then 3 else 5 end,
                    (f ->> 'days_cover')::numeric nulls last loop
    return next v;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 8. Performance
-- -----------------------------------------------------------------------------
create or replace function public.analytics_performance(p_from date, p_to date, p_company uuid default null)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_whs uuid[] := private.an_scope(null);
  v_f timestamptz := (p_from::timestamp at time zone 'Africa/Johannesburg');
  v_t timestamptz := least(((p_to + 1)::timestamp at time zone 'Africa/Johannesburg'), now());
  v_cost boolean := private.has_perm('cost.view');
  v_days numeric;
  v_grace int := private.setting_num('purchase.overdue_grace_days', 2);
begin
  if p_from is null or p_to is null or p_to < p_from then perform private.fail('CS422', 'Choose a valid date range'); end if;
  v_days := greatest(extract(epoch from v_t - v_f) / 86400, 1);
  return query
  with w as (select wt.* from private.warehouse_tree wt where wt.warehouse_id = any(v_whs) and (p_company is null or wt.company_id = p_company)),
  c_now as (select * from private.an_unit_costs(v_t)),
  c_start as (select * from private.an_unit_costs(v_f)),
  tx as (
    select t.warehouse_id, count(*) as txns,
           count(*) filter (where t.txn_type = 'withdrawal') as withdrawals,
           count(*) filter (where t.txn_type in ('receipt','opening')) as receipts,
           count(*) filter (where t.txn_type in ('adjustment','stocktake_adjustment','reversal','transfer_writeoff')) as corrections,
           count(*) filter (where t.is_unusual) as unusual
      from public.stock_transactions t
     where t.status = 'posted' and t.posted_at >= v_f and t.posted_at < v_t group by 1),
  iss as (
    select l.warehouse_id, -sum(l.qty_delta * c.unit_cost) as issued_value
      from public.stock_ledger l left join c_now c on c.product_id = l.product_id
     where l.txn_type in ('withdrawal','return') and l.status <> 'in_transit' and l.posted_at >= v_f and l.posted_at < v_t group by 1),
  val_end as (
    select l.warehouse_id, sum(l.qty_delta * c.unit_cost) as v from public.stock_ledger l left join c_now c on c.product_id = l.product_id
     where l.posted_at < v_t group by 1),
  val_start as (
    select l.warehouse_id, sum(l.qty_delta * c.unit_cost) as v from public.stock_ledger l left join c_start c on c.product_id = l.product_id
     where l.posted_at < v_f group by 1),
  st as (
    select s.warehouse_id, count(distinct s.id) as stocktakes,
           count(*) filter (where sl.counted_qty is not null) as counted_lines,
           count(*) filter (where sl.counted_qty is not null and coalesce(sl.variance, 0) = 0) as exact_lines,
           sum(abs(coalesce(sl.variance, 0)) * c.unit_cost) as variance_value
      from public.stocktakes s join public.stocktake_lines sl on sl.stocktake_id = s.id
      left join c_now c on c.product_id = sl.product_id
     where s.status = 'finalised' and s.finalised_at >= v_f and s.finalised_at < v_t group by 1),
  po as (
    select po.warehouse_id, count(*) as orders,
           count(*) filter (where rt.first_receipt is not null) as delivered,
           count(*) filter (where rt.first_receipt is not null and po.expected_date is not null
                              and (rt.first_receipt at time zone 'Africa/Johannesburg')::date <= po.expected_date + v_grace) as on_time,
           avg(extract(epoch from rt.first_receipt - coalesce(po.sent_at, po.approved_at)) / 86400) as lead_days
      from public.purchase_orders po
      cross join lateral (select min(t.posted_at) as first_receipt from public.stock_transaction_lines tl
                            join public.stock_transactions t on t.id = tl.txn_id and t.status = 'posted'
                           where tl.extra ->> 'po_id' = po.id::text) rt
     where po.approved_at >= v_f and po.approved_at < v_t group by 1),
  ap as (
    select a.warehouse_id, count(*) as decided, avg(extract(epoch from a.decided_at - a.requested_at) / 3600) as hours
      from public.approval_requests a where a.decided_at >= v_f and a.decided_at < v_t and a.status in ('approved','rejected') group by 1),
  al as (
    select a.warehouse_id, count(*) filter (where a.alert_type = 'out_of_stock') as stockouts,
           count(*) filter (where a.alert_type = 'low_stock') as low_stock_alerts
      from public.alerts a where a.first_raised_at >= v_f and a.first_raised_at < v_t group by 1),
  fi as (
    select f.warehouse_id, count(*) as findings, count(*) filter (where f.severity = 'critical') as critical
      from integrity.findings f where f.first_detected_at >= v_f and f.first_detected_at < v_t group by 1)
  select jsonb_build_object(
           'warehouse_id', w.warehouse_id, 'warehouse_code', w.warehouse_code, 'warehouse_name', w.warehouse_name,
           'branch_code', w.branch_code, 'company_code', w.company_code,
           'transactions', coalesce(tx.txns, 0), 'withdrawals', coalesce(tx.withdrawals, 0), 'receipts', coalesce(tx.receipts, 0),
           'corrections', coalesce(tx.corrections, 0), 'unusual_withdrawals', coalesce(tx.unusual, 0),
           'correction_rate_pct', case when coalesce(tx.txns, 0) > 0 then round(100.0 * coalesce(tx.corrections, 0) / tx.txns, 1) end,
           'issued_value', case when v_cost then round(coalesce(iss.issued_value, 0), 2) end,
           'stock_value_start', case when v_cost then round(coalesce(vs.v, 0), 2) end,
           'stock_value_end', case when v_cost then round(coalesce(ve.v, 0), 2) end,
           'turnover_annualised', case when v_cost and coalesce(vs.v, 0) + coalesce(ve.v, 0) > 0
                                       then round(coalesce(iss.issued_value, 0) / ((coalesce(vs.v, 0) + coalesce(ve.v, 0)) / 2) * (365 / v_days), 2) end,
           'days_of_stock', case when v_cost and coalesce(iss.issued_value, 0) > 0 then round(coalesce(ve.v, 0) / (iss.issued_value / v_days), 0) end,
           'stocktakes', coalesce(st.stocktakes, 0), 'counted_lines', coalesce(st.counted_lines, 0),
           'count_accuracy_pct', case when coalesce(st.counted_lines, 0) > 0 then round(100.0 * st.exact_lines / st.counted_lines, 1) end,
           'variance_value', case when v_cost then round(coalesce(st.variance_value, 0), 2) end,
           'purchase_orders', coalesce(po.orders, 0), 'po_delivered', coalesce(po.delivered, 0),
           'po_on_time_pct', case when coalesce(po.delivered, 0) > 0 then round(100.0 * po.on_time / po.delivered, 1) end,
           'avg_lead_days', round(po.lead_days, 1),
           'approvals_decided', coalesce(ap.decided, 0), 'avg_approval_hours', round(ap.hours, 1),
           'stockout_alerts', coalesce(al.stockouts, 0), 'low_stock_alerts', coalesce(al.low_stock_alerts, 0),
           'integrity_findings', coalesce(fi.findings, 0), 'critical_findings', coalesce(fi.critical, 0))
    from w
    left join tx on tx.warehouse_id = w.warehouse_id
    left join iss on iss.warehouse_id = w.warehouse_id
    left join val_end ve on ve.warehouse_id = w.warehouse_id
    left join val_start vs on vs.warehouse_id = w.warehouse_id
    left join st on st.warehouse_id = w.warehouse_id
    left join po on po.warehouse_id = w.warehouse_id
    left join ap on ap.warehouse_id = w.warehouse_id
    left join al on al.warehouse_id = w.warehouse_id
    left join fi on fi.warehouse_id = w.warehouse_id
   order by w.company_code, w.warehouse_code;
end $$;

create or replace function public.analytics_supplier_performance(p_from date, p_to date)
returns setof jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_whs uuid[] := private.an_scope(null);
  v_f timestamptz := (p_from::timestamp at time zone 'Africa/Johannesburg');
  v_t timestamptz := ((p_to + 1)::timestamp at time zone 'Africa/Johannesburg');
  v_cost boolean := private.has_perm('cost.view');
  v_grace int := private.setting_num('purchase.overdue_grace_days', 2);
begin
  if p_from is null or p_to is null or p_to < p_from then perform private.fail('CS422', 'Choose a valid date range'); end if;
  return query
  with o as (
    select po.*, rt.first_receipt, rt.last_receipt,
           (select sum(least(pl.qty_received_base, pl.qty_ordered_base)) / nullif(sum(pl.qty_ordered_base), 0)
              from public.purchase_order_lines pl where pl.po_id = po.id) as fill,
           (select sum(pl.qty_ordered * pl.unit_price) from public.purchase_order_lines pl where pl.po_id = po.id) as value
      from public.purchase_orders po
      cross join lateral (select min(t.posted_at) as first_receipt, max(t.posted_at) as last_receipt
                            from public.stock_transaction_lines tl join public.stock_transactions t on t.id = tl.txn_id and t.status = 'posted'
                           where tl.extra ->> 'po_id' = po.id::text) rt
     where po.warehouse_id = any(v_whs) and po.approved_at >= v_f and po.approved_at < v_t)
  select jsonb_build_object(
           'supplier_id', s.id, 'supplier', s.name, 'orders', count(o.id),
           'delivered', count(o.id) filter (where o.first_receipt is not null),
           'complete', count(o.id) filter (where o.status = 'received'),
           'closed_short', count(o.id) filter (where o.status = 'closed'),
           'cancelled', count(o.id) filter (where o.status = 'cancelled'),
           'on_time_pct', round(100.0 * count(o.id) filter (where o.first_receipt is not null and o.expected_date is not null
                                   and (o.first_receipt at time zone 'Africa/Johannesburg')::date <= o.expected_date + v_grace)
                                / nullif(count(o.id) filter (where o.first_receipt is not null and o.expected_date is not null), 0), 1),
           'fill_rate_pct', round(100.0 * avg(o.fill) filter (where o.status in ('received','closed')), 1),
           'avg_lead_days', round(avg(extract(epoch from o.first_receipt - coalesce(o.sent_at, o.approved_at)) / 86400), 1),
           'value', case when v_cost then round(coalesce(sum(o.value), 0), 2) end,
           'last_order_at', max(o.approved_at))
    from public.suppliers s join o on o.supplier_id = s.id
   group by s.id, s.name
   order by count(o.id) desc, s.name;
end $$;

-- -----------------------------------------------------------------------------
-- 9. Predictive management: daily "likely to run out" alerts
-- -----------------------------------------------------------------------------
create or replace function private.ops_predictive(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  v_local timestamp := now() at time zone 'Africa/Johannesburg';
  v_w record; f jsonb; v_whs int := 0; v_risk int := 0; v_keys text[];
begin
  if not private.setting_bool('analytics.stockout_alerts', true) then return jsonb_build_object('skipped', 'disabled'); end if;
  if not p_force then
    if v_local::time < private.setting_text('analytics.prediction_time', '05:00')::time then return jsonb_build_object('skipped', 'too early'); end if;
    if exists (select 1 from private.analytics_runs where run_date = v_local::date) then return jsonb_build_object('skipped', 'already ran'); end if;
  end if;
  insert into private.analytics_runs (run_date) values (v_local::date)
    on conflict (run_date) do update set started_at = now(), finished_at = null, error = null;
  for v_w in select w.id, w.code from public.warehouses w where w.status = 'active' loop
    v_whs := v_whs + 1; v_keys := array[]::text[];
    for f in select x from private.an_forecast(v_w.id, now(), 30) x where x ->> 'risk' = 'critical' loop
      v_risk := v_risk + 1;
      v_keys := v_keys || ('stockout_risk:' || v_w.id || ':' || (f ->> 'product_id'));
      perform private.raise_alert('stockout_risk', 'warning',
        format('Likely to run out: %s at %s', f ->> 'sku', v_w.code),
        format('%s — %s. Free stock %s %s lasts about %s days at current demand (%s/day); expected out of stock on %s. '
               'Replenishment takes about %s days (%s) and only %s is on order. Suggested order now: %s %s.',
               f ->> 'sku', f ->> 'description', f ->> 'free', f ->> 'uom', coalesce(f ->> 'days_cover', '?'), f ->> 'daily_demand',
               to_char((f ->> 'stockout_date')::date, 'DD/MM/YYYY'), f ->> 'lead_time_days', f ->> 'lead_time_source',
               f ->> 'on_order', f ->> 'suggested_order_now', f ->> 'uom'),
        'stockout_risk:' || v_w.id || ':' || (f ->> 'product_id'),
        (f ->> 'product_id')::uuid, v_w.id, null, null, (f ->> 'free')::numeric, 'forecast', f ->> 'product_id', false,
        '/analytics?tab=forecast');
    end loop;
    -- clear predictions that no longer apply
    perform private.resolve_alert(a.dedupe_key, 'No longer predicted to run out before replenishment')
       from public.alerts a
      where a.alert_type = 'stockout_risk' and a.warehouse_id = v_w.id and a.status <> 'resolved'
        and not a.dedupe_key = any(v_keys);
  end loop;
  update private.analytics_runs set finished_at = now(), warehouses = v_whs, at_risk = v_risk where run_date = v_local::date;
  return jsonb_build_object('warehouses', v_whs, 'at_risk', v_risk);
end $$;

-- the scheduler entry point: Phase 1 check + Phase 2 housekeeping + Phase 3 prediction (each isolated)
create or replace function integrity.dispatch()
returns jsonb language plpgsql security definer set search_path = integrity, public, private, pg_temp as $$
declare
  v_local timestamp := now() at time zone 'Africa/Johannesburg';
  v_sched time := private.setting_text('integrity.daily_run_time', '02:00')::time;
  v_attempts int; v_res jsonb := '{}'; v_done boolean; v_ops jsonb; v_pred jsonb;
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
  return jsonb_build_object('check', v_res, 'watchdog', integrity.watchdog(), 'operations', v_ops, 'prediction', v_pred);
end $$;

-- latest prediction run (for the analytics page header)
create or replace function public.analytics_prediction_status()
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select case when cardinality(private.my_warehouses('reports.view')) = 0 then null else
    (select jsonb_build_object('run_date', run_date, 'finished_at', finished_at, 'warehouses', warehouses, 'at_risk', at_risk, 'error', error)
       from private.analytics_runs order by run_date desc limit 1) end
$$;


-- ===== 20261027009000_phase3_security_lockdown.sql =====
-- =============================================================================
-- CSWMS Phase 3 — Migration 9000: privilege lockdown re-applied over the
-- analytics functions (keep this the LAST migration).
-- Phase 3 adds no client-readable tables: every analytic is a permission-checked,
-- read-only function (scope = reports.view warehouses; rand values need cost.view).
-- private.analytics_runs is server-only.
-- =============================================================================
revoke all on private.analytics_runs from public, anon, authenticated;

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
    if f.proname in ('cron_dispatch','email_outbox_claim','email_outbox_result','log_system_event') then
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


-- ===== 20261101001000_phase5_intercompany.sql =====
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


-- ===== 20261101009000_phase5_security_lockdown.sql =====
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
