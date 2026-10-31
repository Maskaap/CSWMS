// CSWMS Phase 4 database tests: the floor experience — offline counting, scan-to-count, empty bins,
// cycle counts, My tasks, quick self-correction (undo), photo evidence, personal settings, WhatsApp
// alerts, training warehouse, accounting journal and the weekly summary.
//   node run-phase4-tests.mjs
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { pool, rpc, rpcAll, rpcFails, su, as, id, U, uuid, test, results, assert, eq, balance } from './lib.mjs';

const HERE = new URL('.', import.meta.url).pathname;
const PGH = process.env.PGHOST || '/tmp';
console.log('Preparing fresh test database…');
execSync(`${HERE}reset.sh cswms_test`, { stdio: 'pipe' });
execSync(`psql -h ${PGH} -U postgres -d cswms_test -v ON_ERROR_STOP=1 -q -f ${HERE}fixtures.sql`, { stdio: 'pipe' });

const WH1 = await id(`select id from warehouses where code='CPT-MAIN'`);
const CA = await id(`select id from companies where code='CSA'`);
const BR1 = await id(`select id from branches where code='CPT'`);
const A01 = await id(`select id from storage_locations where warehouse_id=$1 and code='A-01'`, [WH1]);
const A02 = await id(`select id from storage_locations where warehouse_id=$1 and code='A-02'`, [WH1]);
const EA = await id(`select id from uoms where code='EA'`);
const BOX = await id(`select id from uoms where code='BOX'`);
const mk = async (sku, price) => {
  const p = await id(`insert into products (sku, description, base_uom_id) values ($1,$2,$3) returning id`, [sku, 'Phase 4 ' + sku, EA]);
  await su(`insert into barcodes (code, product_id, is_primary) values ($1,$2,true)`, [sku, p]);
  if (price) await su(`insert into product_costs (product_id, purchase_price) values ($1,$2)`, [p, price]);
  return p;
};
const P = {};
for (const [s, c] of [['HI', 50], ['MID', 10], ['LO', 1], ['IDLE', 5], ['BIN2', 2]]) P[s] = await mk('P4-' + s, c);
await su(`insert into product_uoms (product_id, uom_id, factor_to_base) values ($1,$2,12)`, [P.MID, BOX]);
await su(`insert into barcodes (code, product_id, uom_id) values ('P4-MID-BOX12',$1,$2)`, [P.MID, BOX]);

const recv = (p, qty, loc = A01, user = U.ctrl1) => rpc(user, 'receive_stock', { p_request_id: uuid(), p_warehouse_id: WH1, p_reference: 'DN-P4',
  p_lines: [{ product_id: p, location_id: loc, qty }] });
const wd = (p, qty, ref = 'JOB-P4', user = U.ctrl1) => rpc(user, 'withdraw_stock', { p_request_id: uuid(), p_warehouse_id: WH1,
  p_reason_code: 'PRODUCTION', p_reference: ref, p_lines: [{ product_id: p, location_id: A01, qty }], p_confirm_unusual: true });
await recv(P.HI, 100); await recv(P.MID, 100); await recv(P.LO, 100); await recv(P.IDLE, 40); await recv(P.BIN2, 30, A02);
for (let i = 0; i < 4; i++) { await wd(P.HI, 10); await wd(P.MID, 3); await wd(P.LO, 2); }
const hours = (h) => new Date(Date.now() - h * 3600e3).toISOString();

// ======================================================================================
console.log('\n1. Counting on the floor');
let st;
await test('Offline counting', 'A counter downloads everything needed to count offline (blind: no expected quantities)', async () => {
  const r = await rpc(U.sup1, 'schedule_stocktakes', { p_scope_type: 'warehouse', p_scope_id: WH1, p_period: '2026-10', p_due_date: '2030-01-01' });
  st = r.stocktake_ids[0];
  await rpc(U.sup1, 'assign_stocktake', { p_stocktake_id: st, p_user_id: U.counter });
  await su(`update storage_locations set walk_order = case code when 'A-02' then 1 when 'A-01' then 2 end where warehouse_id=$1`, [WH1]);
  await rpc(U.sup1, 'start_stocktake', { p_stocktake_id: st });
  const pack = await rpc(U.counter, 'stocktake_offline_pack', { p_stocktake_id: st });
  assert(pack.lines.length >= 5, 'lines');
  assert(pack.lines.every((l) => l.expected_qty === null), 'blind count hides expected quantities');
  eq(pack.locations[0].code, 'A-02', 'walk order first');
  const mid = pack.products.find((p) => p.sku === 'P4-MID');
  assert(mid.barcodes.some((b) => b.code === 'P4-MID-BOX12' && b.uom_id === BOX), 'pack barcode with unit');
  eq(Number(mid.units.find((u) => u.code === 'BOX').factor), 12, 'unit factor');
  const mgr = await rpc(U.sup1, 'stocktake_offline_pack', { p_stocktake_id: st });
  assert(mgr.lines.some((l) => l.expected_qty !== null), 'manager sees expected');
  await rpcFails('CS401', U.ctrlB, 'stocktake_offline_pack', { p_stocktake_id: st });
});

await test('Offline counting', 'Counts made offline sync later with the phone\'s time; the same count sent twice is stored once', async () => {
  await su(`update stocktakes set cutoff_at = now() - interval '2 hours' where id=$1`, [st]);   // counting began two hours ago
  const req = uuid();
  const r = await rpc(U.counter, 'record_count', { p_request_id: req, p_stocktake_id: st, p_product_id: P.HI, p_location_id: A01, p_qty: 30,
    p_counted_at: hours(0.5), p_offline: true });
  const again = await rpc(U.counter, 'record_count', { p_request_id: req, p_stocktake_id: st, p_product_id: P.HI, p_location_id: A01, p_qty: 30,
    p_counted_at: hours(0.5), p_offline: true });
  eq(again.duplicate, true, 'retry recognised'); eq(Number(again.line_total), 30, 'retry returns total');
  const c = await su(`select entered_offline, counted_at, received_at from stocktake_counts where client_request_id=$1`, [req]);
  eq(c.length, 1, 'stored once'); eq(c[0].entered_offline, true, 'offline flag');
  assert(new Date(c[0].received_at) - new Date(c[0].counted_at) > 20 * 60e3, 'counted_at keeps the phone time');
  // a count claiming to be before the cut-off is clamped to the cut-off; one from the future to now
  const f = await rpc(U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: st, p_product_id: P.LO, p_location_id: A01, p_qty: 1,
    p_counted_at: new Date(Date.now() + 3600e3).toISOString(), p_offline: true });
  assert(new Date(f.counted_at) <= new Date(), 'future time clamped');
  const e = await rpcFails('CS422', U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: st, p_product_id: P.LO, p_location_id: A01,
    p_qty: 1, p_counted_at: hours(80), p_offline: true });
  assert(/72 hours/.test(e.message), e.message);
});

await test('Scan to count', 'Each scan adds one (a box barcode adds 12); scans are not flagged as double entries', async () => {
  for (let i = 0; i < 5; i++) await rpc(U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: st, p_product_id: P.MID, p_location_id: A01, p_qty: 1, p_method: 'scan' });
  const r = await rpc(U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: st, p_product_id: P.MID, p_location_id: A01, p_qty: 1,
    p_uom_id: BOX, p_method: 'scan' });
  eq(Number(r.line_total), 17, '5 singles + 1 box of 12');
  eq(r.possible_duplicate_entry, false, 'no duplicate flag on scans');
  const t = await rpc(U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: st, p_product_id: P.LO, p_location_id: A01, p_qty: 4 });
  const t2 = await rpc(U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: st, p_product_id: P.LO, p_location_id: A01, p_qty: 4 });
  eq(t2.possible_duplicate_entry, true, 'typed duplicates still flagged');
  await rpcFails('CS422', U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: st, p_product_id: P.LO, p_location_id: A01, p_qty: 1, p_method: 'guess' });
});

await test('Empty bin', '"Bin empty" records 0 for every uncounted item in the bin, once', async () => {
  const req = uuid();
  const r = await rpc(U.counter, 'record_empty_location', { p_request_id: req, p_stocktake_id: st, p_location_id: A02 });
  eq(r.lines_zeroed, 1, 'one line zeroed');
  const again = await rpc(U.counter, 'record_empty_location', { p_request_id: req, p_stocktake_id: st, p_location_id: A02 });
  eq(again.lines_zeroed, 0, 'retry adds nothing');
  const l = await su(`select counted_qty from stocktake_lines where stocktake_id=$1 and location_id=$2`, [st, A02]);
  assert(l.every((x) => Number(x.counted_qty) === 0), 'all zero');
  eq((await su(`select count(*)::int n from stocktake_counts where stocktake_id=$1 and method='empty_bin'`, [st]))[0].n, 1, 'one count row');
});

await test('Offline counting', 'A count made before counting closed but synced after is accepted as late and the comparison refreshed', async () => {
  const countedAt = new Date(Date.now() - 60e3).toISOString();
  await rpc(U.sup1, 'close_stocktake_counting', { p_stocktake_id: st });
  const r = await rpc(U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: st, p_product_id: P.IDLE, p_location_id: A01, p_qty: 40,
    p_counted_at: countedAt, p_offline: true });
  eq(r.late, true, 'late');
  const l = await su(`select counted_qty, variance from stocktake_lines where stocktake_id=$1 and product_id=$2`, [st, P.IDLE]);
  eq(Number(l[0].variance), 0, 'variance recomputed');
  assert((await su(`select 1 from alerts where dedupe_key=$1`, ['late_count:' + st])).length === 1, 'supervisor told');
  await rpcFails('CS423', U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: st, p_product_id: P.IDLE, p_location_id: A01, p_qty: 1 });
  await su(`update stocktakes set status='cancelled' where id=$1`, [st]);
});

// ======================================================================================
console.log('\n2. Cycle counts and My tasks');
let cyc;
await test('Cycle counts', 'A cycle count picks the most important items first (A class) and starts immediately', async () => {
  await su(`insert into app_settings (key, value) values ('cycle.items_per_day','2') on conflict (key) do update set value='2'`);
  await rpcFails('CS401', U.counter, 'create_cycle_count', { p_warehouse_id: WH1 });
  const r = await rpc(U.sup1, 'create_cycle_count', { p_warehouse_id: WH1 });
  eq(r.created, true, 'created'); eq(r.items, 2, 'two items'); cyc = r.stocktake_id;
  const s = (await su(`select kind, status, blind, product_ids, stocktake_no from stocktakes where id=$1`, [cyc]))[0];
  eq(s.kind, 'cycle', 'kind'); eq(s.status, 'counting', 'started'); eq(s.blind, true, 'blind');
  assert(s.stocktake_no.startsWith('CYC'), 'doc no');
  assert(s.product_ids.includes(P.HI), 'highest-value mover (A) included: ' + s.product_ids);
  const lines = await su(`select product_id from stocktake_lines where stocktake_id=$1`, [cyc]);
  assert(lines.every((l) => s.product_ids.includes(l.product_id)), 'only those items');
  const n = await su(`select count(*)::int n from notifications where user_id=$1 and link='/tasks'`, [U.counter]);
  eq(n[0].n, 1, 'counter notified');
  // the next one does not repeat items that are still open
  const r2 = await rpc(U.sup1, 'create_cycle_count', { p_warehouse_id: WH1, p_items: 10 });
  const ids2 = (await su(`select product_ids from stocktakes where id=$1`, [r2.stocktake_id]))[0].product_ids;
  assert(!ids2.some((x) => s.product_ids.includes(x)), 'no overlap with the open cycle count');
  await su(`update stocktakes set status='cancelled' where id=$1`, [r2.stocktake_id]);
});

await test('Cycle counts', 'A full stocktake can run alongside a cycle count; the daily job makes one per warehouse on weekdays', async () => {
  const r = await rpc(U.sup1, 'schedule_stocktakes', { p_scope_type: 'warehouse', p_scope_id: WH1, p_period: '2026-11', p_due_date: '2030-01-01' });
  eq(r.created, 1, 'full stocktake allowed');
  await su(`update stocktakes set status='cancelled' where id=$1`, [r.stocktake_ids[0]]);
  const j = (await su(`select private.ops_cycle_counts() r`))[0].r;
  const dow = Number(new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Johannesburg', weekday: 'short' }).format(new Date()) === 'Sat' ||
    new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Johannesburg', weekday: 'short' }).format(new Date()) === 'Sun');
  assert(dow ? j.skipped === 'weekend' : ('created' in j || j.skipped === 'too early'), JSON.stringify(j));
  const d = (await su(`select integrity.dispatch() r`))[0].r;
  assert('cycle_counts' in d && 'weekly_summary' in d, 'scheduler runs the new jobs');
});

await test('My tasks', 'My tasks shows the counter today\'s count with progress, tools held and unread messages', async () => {
  await rpc(U.counter, 'record_count', { p_request_id: uuid(), p_stocktake_id: cyc, p_product_id: P.HI, p_location_id: A01, p_qty: 60, p_method: 'typed' });
  const t = await rpc(U.counter, 'my_tasks');
  const c = t.counts.find((x) => x.id === cyc);
  assert(c, 'cycle count listed'); eq(c.kind, 'cycle', 'kind'); eq(c.counted, 1, 'progress');
  assert(t.unread >= 1, 'unread');
  const other = await rpc(U.ctrlB, 'my_tasks');
  assert(!other.counts.some((x) => x.id === cyc), 'not shown to staff of other warehouses');
  await rpcFails('42501', 'anon', 'my_tasks');
});

// ======================================================================================
console.log('\n3. Quick self-correction');
await test('Undo', 'Staff can undo their own withdrawal within 10 minutes; stock is restored and the integrity check stays green', async () => {
  const before = await balance(P.LO, A01);
  const w = await wd(P.LO, 7, 'JOB-OOPS');
  const list = await rpcAll(U.ctrl1, 'my_undoable_transactions');
  assert(list.some((x) => x.id === w.txn_id && x.seconds_left > 500), 'offered for undo');
  await rpcFails('CS422', U.ctrl1, 'undo_my_transaction', { p_request_id: uuid(), p_txn_id: w.txn_id, p_reason: ' ' });
  await rpcFails('CS401', U.ctrl2, 'undo_my_transaction', { p_request_id: uuid(), p_txn_id: w.txn_id, p_reason: 'not mine' });
  const req = uuid();
  const u = await rpc(U.ctrl1, 'undo_my_transaction', { p_request_id: req, p_txn_id: w.txn_id, p_reason: 'wrong item scanned' });
  eq(u.status, 'posted', 'posted'); eq(await balance(P.LO, A01), before, 'stock restored');
  const again = await rpc(U.ctrl1, 'undo_my_transaction', { p_request_id: req, p_txn_id: w.txn_id, p_reason: 'wrong item scanned' });
  eq(again.txn_id, u.txn_id, 'retry-safe');
  await rpcFails('CS423', U.ctrl1, 'undo_my_transaction', { p_request_id: uuid(), p_txn_id: w.txn_id, p_reason: 'again' });
  const a = await su(`select status, decided_by, details->>'rule' rule from approval_requests where txn_id=$1`, [u.txn_id]);
  eq(a[0].status, 'approved', 'recorded as approved'); eq(a[0].rule, 'self_correction', 'by rule');
  assert((await su(`select 1 from audit_log where action='SELF_UNDO'`)).length === 1, 'audited');
});

await test('Undo', 'Undo is refused after the window, for other types and when switched off', async () => {
  const w = await wd(P.LO, 1, 'JOB-LATE');
  await su(`set session_replication_role = replica; update stock_transactions set posted_at = now() - interval '11 minutes' where id='${w.txn_id}'; set session_replication_role = origin;`);
  const e = await rpcFails('CS423', U.ctrl1, 'undo_my_transaction', { p_request_id: uuid(), p_txn_id: w.txn_id, p_reason: 'late' });
  assert(/10-minute/.test(e.message), e.message);
  const w2 = await wd(P.LO, 1, 'JOB-OFF');
  await su(`insert into app_settings (key, value) values ('undo.minutes','0') on conflict (key) do update set value='0'`);
  await rpcFails('CS423', U.ctrl1, 'undo_my_transaction', { p_request_id: uuid(), p_txn_id: w2.txn_id, p_reason: 'x' });
  await su(`update app_settings set value='10' where key='undo.minutes'`);
  const op = await su(`select id from stock_transactions where txn_type='reversal' limit 1`);
  await rpcFails('CS422', U.ctrl1, 'undo_my_transaction', { p_request_id: uuid(), p_txn_id: op[0].id, p_reason: 'x' });
  // the original withdrawal is restored by the earlier undo; the backdated one stays. Put the timestamp back for the integrity check.
  await su(`set session_replication_role = replica; update stock_transactions set posted_at = (select max(posted_at) from stock_ledger where txn_id='${w.txn_id}') where id='${w.txn_id}'; update stock_transactions t set header_hash = private.txn_header_hash(t) where id='${w.txn_id}'; set session_replication_role = origin;`);
});

// ======================================================================================
console.log('\n4. Photos, personal settings, WhatsApp');
let rcvTxn;
await test('Photos', 'A photo can be attached to a damage record by the person who made it; other warehouses cannot see it', async () => {
  rcvTxn = (await recv(P.LO, 2)).txn_id;
  const r = await rpc(U.ctrl1, 'register_attachment', { p_entity_type: 'txn', p_entity_id: rcvTxn, p_mime: 'image/jpeg', p_bytes: 120000, p_caption: 'Crushed box' });
  assert(r.storage_path.startsWith(WH1 + '/txn/' + rcvTxn + '/') && r.storage_path.endsWith('.jpg'), r.storage_path);
  eq(await rpc(U.sup1, 'attachment_path', { p_id: r.id }), r.storage_path, 'supervisor can open');
  eq(await rpc(U.ctrlB, 'attachment_path', { p_id: r.id }), null, 'other warehouse cannot');
  await rpcFails('CS401', U.ctrlB, 'register_attachment', { p_entity_type: 'txn', p_entity_id: rcvTxn, p_mime: 'image/jpeg', p_bytes: 100 });
  await rpcFails(null, U.ctrl1, 'register_attachment', { p_entity_type: 'txn', p_entity_id: rcvTxn, p_mime: 'application/pdf', p_bytes: 100 });
  await rpcFails(null, U.ctrl1, 'register_attachment', { p_entity_type: 'txn', p_entity_id: rcvTxn, p_mime: 'image/png', p_bytes: 9e6 });
  const l = await rpcAll(U.sup1, 'list_attachments', { p_entity_type: 'txn', p_entity_id: rcvTxn });
  eq(l.length, 1, 'listed'); eq(l[0].caption, 'Crushed box', 'caption');
  await as(U.ctrl1, `select * from attachments`).then(() => { throw new Error('direct table read allowed'); }, () => {});
  await su(`delete from attachments`).then(() => { throw new Error('delete allowed'); }, () => {});
});

await test('Settings', 'Each person picks a language and text size; SA mobile numbers are normalised', async () => {
  const r = await rpc(U.counter, 'set_my_preferences', { p_language: 'zu', p_text_size: 'large', p_phone: '082 123 4567' });
  eq(r.language, 'zu', 'language'); eq(r.text_size, 'large', 'size'); eq(r.phone, '+27821234567', 'normalised');
  await rpcFails('CS422', U.counter, 'set_my_preferences', { p_language: 'fr' });
  await rpcFails('CS422', U.counter, 'set_my_preferences', { p_phone: '12345' });
  await rpcFails('CS422', U.ctrl2, 'set_my_preferences', { p_whatsapp_opt_in: true });   // no number
  eq((await rpc(U.counter, 'my_preferences')).language, 'zu', 'stored');
});

await test('WhatsApp', 'Alerts go to WhatsApp only for people who opted in, when switched on, at their chosen severity', async () => {
  await rpc(U.sup1, 'set_my_preferences', { p_phone: '+27 83 555 0101', p_whatsapp_opt_in: true, p_whatsapp_min_severity: 'critical' });
  await rpc(U.mgrA, 'set_my_preferences', { p_phone: '0845550102', p_whatsapp_opt_in: true, p_whatsapp_min_severity: 'warning' });
  await su(`select private.raise_alert('low_stock','warning','Off test','m','wa-off', null, $1)`, [WH1]);
  eq((await su(`select count(*)::int n from private.message_outbox`))[0].n, 0, 'nothing while switched off');
  await su(`update app_settings set value='true' where key='alerts.whatsapp_enabled'`);
  await su(`select private.raise_alert('low_stock','warning','Low: tape','Tape is low','wa-1', null, $1)`, [WH1]);
  const q = await su(`select to_phone from private.message_outbox order by to_phone`);
  assert(q.some((x) => x.to_phone === '+27845550102'), 'company manager (warning) gets it');
  assert(!q.some((x) => x.to_phone === '+27835550101'), 'supervisor (critical only) does not');
  await su(`select private.raise_alert('low_stock','critical','Out: tape','Tape is out','wa-1', null, $1)`, [WH1]);
  assert((await su(`select 1 from private.message_outbox where to_phone='+27835550101'`)).length === 1, 'escalation to critical reaches the supervisor');
  await as(U.ctrl1, `select * from public.message_outbox_claim(5)`).then(() => { throw new Error('users can claim'); }, (e) => eq(e.code, '42501', 'server only'));
  const claimed = await su(`select * from public.message_outbox_claim(10)`);
  assert(claimed.length >= 2, 'server claims'); await su(`select public.message_outbox_result($1, true)`, [claimed[0].id]);
  eq((await su(`select status from private.message_outbox where id=$1`, [claimed[0].id]))[0].status, 'sent', 'marked sent');
  await su(`update app_settings set value='false' where key='alerts.whatsapp_enabled'`);
});

// ======================================================================================
console.log('\n5. Training, accounting, weekly summary');
await test('Training', 'A training warehouse comes with practice bins and stock, clearly marked, and only setup managers can create it', async () => {
  await rpcFails('CS401', U.ctrl1, 'create_training_warehouse', { p_branch_id: BR1 });
  const r = await rpc(U.admin, 'create_training_warehouse', { p_branch_id: BR1 });
  eq(r.code, 'TRAIN-1', 'code'); eq(r.items, 8, 'items');
  const w = (await su(`select is_training, name from warehouses where id=$1`, [r.warehouse_id]))[0];
  eq(w.is_training, true, 'flag'); assert(/practice only/.test(w.name), 'name');
  const s = await su(`select sum(qty)::int q, count(distinct location_id)::int l from stock_balances where warehouse_id=$1`, [r.warehouse_id]);
  eq(s[0].q, 1042, 'practice stock'); eq(s[0].l, 6, 'spread over bins');
  const r2 = await rpc(U.admin, 'create_training_warehouse', { p_branch_id: BR1 });
  eq(r2.code, 'TRAIN-2', 'a second one reuses the training items');
});

await test('Accounting', 'The accounting journal balances (debits = credits) and matches stock value movements', async () => {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Johannesburg' }).format(new Date());
  await rpcFails('CS401', U.ctrl1, 'accounting_journal', { p_from: today, p_to: today, p_company: CA });
  await rpcFails('CS422', U.admin, 'accounting_journal', { p_from: today, p_to: today, p_company: null });
  const j = await rpcAll(U.admin, 'accounting_journal', { p_from: today, p_to: today, p_company: CA });
  assert(j.length >= 4, 'lines');
  const dr = j.reduce((s, x) => s + Number(x.debit), 0), cr = j.reduce((s, x) => s + Number(x.credit), 0);
  assert(Math.abs(dr - cr) < 0.005, `balanced ${dr} vs ${cr}`);
  const inv = j.filter((x) => x.account === '630').reduce((s, x) => s + Number(x.amount), 0);
  const val = (await su(`select round(sum(l.qty_delta * c.unit_cost), 2) v from stock_ledger l join private.an_unit_costs(now() + interval '1 day') c
                          on c.product_id = l.product_id join warehouses w on w.id = l.warehouse_id join branches b on b.id = w.branch_id where b.company_id = $1`, [CA]))[0].v;
  assert(Math.abs(inv - Number(val)) < 0.05, `inventory account ${inv} = stock value change ${val}`);
  assert(j.some((x) => x.group === 'consumption' && x.account === '310' && Number(x.debit) > 0), 'consumption debited to 310');
});

await test('Weekly summary', 'The Monday summary e-mail goes once per person with report access, with rand values only for price viewers', async () => {
  await su(`update app_settings set value='true' where key='alerts.email_enabled'`);
  const dow = new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Johannesburg', weekday: 'short', hour: 'numeric', hour12: false }).formatToParts(new Date());
  const isMonMorning = dow.find((p) => p.type === 'weekday').value === 'Mon' && Number(dow.find((p) => p.type === 'hour').value) >= 7;
  const r = (await su(`select private.ops_weekly_summary() r`))[0].r;
  if (!isMonMorning) eq(r.skipped, 'not Monday morning', 'only on Monday');
  // exercise the body regardless of the weekday: temporarily treat today as Monday
  const body = (await su(`select pg_get_functiondef('private.ops_weekly_summary()'::regprocedure) d`))[0].d
    .replace("extract(isodow from v_local) <> 1 or v_local::time < time '07:00'", 'false');
  await su(body);
  const r2 = (await su(`select private.ops_weekly_summary() r`))[0].r;
  assert(r2.queued >= 2, 'queued ' + JSON.stringify(r2));
  const r3 = (await su(`select private.ops_weekly_summary() r`))[0].r;
  eq(r3.queued, 0, 'not twice in one week');
  const m = await su(`select to_email, body_text from private.email_outbox where dedupe_key like 'weekly:%'`);
  const adm = m.find((x) => x.to_email === 'admin@cswms.test');
  assert(adm && /Consumption value: R/.test(adm.body_text) && /Top jobs/.test(adm.body_text), 'admin gets values and top jobs');
  const sup = m.find((x) => x.to_email === 'sup1@cswms.test');
  assert(!sup || !/Consumption value/.test(sup.body_text), 'no rand values without cost.view');
  assert(!m.some((x) => x.to_email === 'counter@cswms.test'), 'counters do not get it');
  await su(`update app_settings set value='false' where key='alerts.email_enabled'`);
});

await test('Setup', 'Bins can be created in bulk in walking order (snake route), and the route can be changed', async () => {
  await rpcFails('CS401', U.sup1, 'generate_locations', { p_warehouse_id: WH1, p_prefix: 'R', p_aisles: 2, p_bays: 3 });
  const r = await rpc(U.admin, 'generate_locations', { p_warehouse_id: WH1, p_prefix: 'R', p_aisles: 2, p_bays: 3, p_levels: 1 });
  eq(r.created, 6, 'six bins');
  const again = await rpc(U.admin, 'generate_locations', { p_warehouse_id: WH1, p_prefix: 'r', p_aisles: 2, p_bays: 3, p_levels: 1 });
  eq(again.created, 0, 'no duplicates'); eq(again.skipped_existing, 6, 'skipped');
  const order = (await su(`select code from storage_locations where warehouse_id=$1 and code like 'R%' order by walk_order`, [WH1])).map((x) => x.code);
  eq(order, ['R1-01', 'R1-02', 'R1-03', 'R2-03', 'R2-02', 'R2-01'], 'up one aisle, down the next');
  await rpcFails('CS422', U.admin, 'generate_locations', { p_warehouse_id: WH1, p_prefix: 'bad prefix!', p_aisles: 1, p_bays: 1 });
  const ids = (await su(`select id from storage_locations where warehouse_id=$1 and code in ('A-01','A-02') order by code desc`, [WH1])).map((x) => x.id);
  await rpc(U.admin, 'set_walk_order', { p_warehouse_id: WH1, p_location_ids: ids });
  const w = await su(`select code, walk_order from storage_locations where warehouse_id=$1 and walk_order is not null order by walk_order`, [WH1]);
  eq(w.map((x) => x.code), ['A-02', 'A-01'], 'route saved, others cleared');
  const other = await id(`select id from storage_locations where warehouse_id <> $1 limit 1`, [WH1]);
  await rpcFails('CS422', U.admin, 'set_walk_order', { p_warehouse_id: WH1, p_location_ids: [other] });
  const ctx = await rpc(U.admin, 'my_context');
  assert(ctx.warehouses.some((x) => x.is_training === true), 'training flag in my_context'); eq(ctx.user.text_size, 'normal', 'text size in my_context');
});

// ======================================================================================
console.log('\n6. Security and integrity');
await test('Security', 'Anonymous callers can reach none of the new functions or tables', async () => {
  for (const fn of ['my_tasks', 'my_preferences', 'my_undoable_transactions']) {
    await as('anon', `select public.${fn}()`).then(() => { throw new Error(fn + ' open to anon'); }, (e) => eq(e.code, '42501', fn));
  }
  const bad = await su(`select p.oid::regprocedure::text f from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','private','integrity') and has_function_privilege('anon', p.oid, 'execute')`);
  eq(bad.length, 0, 'anon functions: ' + bad.map((b) => b.f).join());
  const priv = await su(`select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.proname in ('ops_cycle_counts','create_cycle_count','ops_weekly_summary','start_stocktake_internal')
      and has_function_privilege('authenticated', p.oid, 'execute')`);
  eq(priv.length, 0, 'jobs are server-only');
});

await test('Integrity', 'After all Phase 4 activity the integrity check finds no critical problems', async () => {
  const r = (await su(`select integrity.run_check('test', null) r`))[0].r;
  const crit = await su(`select check_code, title, description from integrity.findings where severity='critical' and status in ('open','investigating')`);
  eq(r.status, 'completed', 'completed');
  eq(crit.length, 0, 'critical: ' + crit.map((c) => c.check_code + ' ' + c.description).join(' | '));
  return `${r.keys_checked} balances verified`;
});

await pool.end();
const failed = results.filter((r) => r.status !== 'PASS');
console.log(`\n${results.length - failed.length} passed, ${failed.length} failed`);
writeFileSync(new URL('./results-phase4.json', import.meta.url), JSON.stringify({ at: new Date().toISOString(), results }, null, 2));
process.exit(failed.length ? 1 : 0);
