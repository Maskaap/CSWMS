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
