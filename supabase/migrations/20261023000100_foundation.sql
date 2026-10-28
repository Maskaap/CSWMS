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
