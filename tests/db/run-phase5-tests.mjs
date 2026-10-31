// CSWMS Phase 5 database tests: inter-company orders, tax invoices, credit notes and payments
// for stock that moves between companies.
//   node run-phase5-tests.mjs
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { pool, rpc, rpcAll, rpcFails, su, as, id, U, uuid, test, results, assert, eq, balance } from './lib.mjs';

const HERE = new URL('.', import.meta.url).pathname;
const PGH = process.env.PGHOST || '/tmp';
console.log('Preparing fresh test database…');
execSync(`${HERE}reset.sh cswms_test`, { stdio: 'pipe' });
execSync(`psql -h ${PGH} -U postgres -d cswms_test -v ON_ERROR_STOP=1 -q -f ${HERE}fixtures.sql`, { stdio: 'pipe' });

const WH1 = await id(`select id from warehouses where code='CPT-MAIN'`);   // CSA
const WH2 = await id(`select id from warehouses where code='PE-MAIN'`);    // CSB
const CA = await id(`select id from companies where code='CSA'`);
const CB = await id(`select id from companies where code='CSB'`);
const A01 = await id(`select id from storage_locations where warehouse_id=$1 and code='A-01'`, [WH1]);
const A02 = await id(`select id from storage_locations where warehouse_id=$1 and code='A-02'`, [WH1]);
const PEA = await id(`select id from storage_locations where warehouse_id=$1 and code='A'`, [WH2]);
const EA = await id(`select id from uoms where code='EA'`);
const BOX = await id(`select id from uoms where code='BOX'`);
const MGRB = '00000000-0000-0000-0000-00000000a011';
await su(`insert into auth.users (id, email) values ($1, 'mgrb@cswms.test')`, [MGRB]);
await su(`insert into app_users (id, email, full_name) values ($1, 'mgrb@cswms.test', 'Mgrb')`, [MGRB]);
await su(`insert into user_role_assignments (user_id, role_id, scope_type, scope_id) select $1, id, 'company', $2 from roles where code='COMPANY_MANAGER'`, [MGRB, CB]);
await su(`update companies set vat_number='4123456789', legal_name='CS Alpha (Pty) Ltd', address='1 Dock Road, Cape Town, 8001' where id=$1`, [CA]);
await su(`update companies set legal_name='CS Beta (Pty) Ltd', address='9 Harbour St, Gqeberha, 6001' where id=$1`, [CB]);

const mk = async (sku, price) => {
  const p = await id(`insert into products (sku, description, base_uom_id) values ($1,$2,$3) returning id`, [sku, 'Phase 5 ' + sku, EA]);
  await su(`insert into product_costs (product_id, purchase_price) values ($1,$2)`, [p, price]);
  return p;
};
const BOLT = await mk('P5-BOLT', 2.5);
const OIL = await mk('P5-OIL', 400);
await su(`insert into product_uoms (product_id, uom_id, factor_to_base) values ($1,$2,50)`, [BOLT, BOX]);
const recv = (p, qty, loc) => rpc(U.ctrl1, 'receive_stock', { p_request_id: uuid(), p_warehouse_id: WH1, p_reference: 'DN-P5',
  p_lines: [{ product_id: p, location_id: loc, qty }] });
await recv(BOLT, 300, A01); await recv(BOLT, 200, A02); await recv(OIL, 10, A01);
await su(`update app_settings set value='10' where key='intercompany.markup_pct'`);
const q = async (sql, p = []) => (await su(sql, p))[0];
const TODAY = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Johannesburg' }).format(new Date());

// ======================================================================================
console.log('\n1. Ordering from another company');
let ord;
await test('Orders', 'The buying company orders stock from the selling company; prices default to cost + 10 % mark-up; the seller is told', async () => {
  await rpcFails('CS401', U.ctrl1, 'create_ic_order', { p_request_id: uuid(), p_from_warehouse_id: WH1, p_to_warehouse_id: WH2,
    p_lines: [{ product_id: BOLT, qty: 1 }] });
  const e = await rpcFails('CS422', U.mgrA, 'create_ic_order', { p_request_id: uuid(), p_from_warehouse_id: WH1,
    p_to_warehouse_id: await id(`select id from warehouses where code='CPT-YARD'`), p_lines: [{ product_id: BOLT, qty: 1 }] });
  assert(/same company/.test(e.message), e.message);
  const req = uuid();
  const r = await rpc(MGRB, 'create_ic_order', { p_request_id: req, p_from_warehouse_id: WH1, p_to_warehouse_id: WH2,
    p_lines: [{ product_id: BOLT, qty: 8, uom_id: BOX }, { product_id: OIL, qty: 4 }], p_reference: 'PE-JOB-1' });
  ord = r.order_id; assert(r.order_no.startsWith('ICO-'), r.order_no);
  eq((await rpc(MGRB, 'create_ic_order', { p_request_id: req, p_from_warehouse_id: WH1, p_to_warehouse_id: WH2,
    p_lines: [{ product_id: BOLT, qty: 8, uom_id: BOX }, { product_id: OIL, qty: 4 }], p_reference: 'PE-JOB-1' })).order_id, ord, 'retry-safe');
  const d = await rpc(MGRB, 'ic_order_detail', { p_order_id: ord });
  eq(d.buyer.code, 'CSB', 'buyer'); eq(d.seller.code, 'CSA', 'seller'); eq(d.status, 'submitted', 'status');
  eq(Number(d.lines[0].qty_base), 400, '8 boxes = 400 bolts');
  eq(Number(d.lines[0].unit_price), 2.75, 'bolt 2.50 + 10 %'); eq(Number(d.lines[1].unit_price), 440, 'oil 400 + 10 %');
  eq(Number(d.value), 2860, 'order value 400×2.75 + 4×440');
  assert((await su(`select 1 from notifications where user_id=$1 and link=$2`, [U.mgrA, '/intercompany/orders/' + ord])).length === 1, 'seller manager told');
});

await test('Orders', 'Only the selling side approves (not the requester); prices can be agreed on approval; buyer is told', async () => {
  await rpcFails('CS401', MGRB, 'decide_ic_order', { p_order_id: ord, p_approve: true });          // buyer has no approve right on CPT
  await rpcFails('CS401', U.ctrl1, 'decide_ic_order', { p_order_id: ord, p_approve: true });
  await rpcFails('CS422', U.mgrA, 'decide_ic_order', { p_order_id: ord, p_approve: false, p_note: ' ' });
  const lines = (await rpc(U.mgrA, 'ic_order_detail', { p_order_id: ord })).lines;
  await rpc(U.mgrA, 'decide_ic_order', { p_order_id: ord, p_approve: true, p_note: 'Agreed', p_prices: [{ line_id: lines[1].id, unit_price: 420 }] });
  const d = await rpc(MGRB, 'ic_order_detail', { p_order_id: ord });
  eq(d.status, 'approved', 'approved'); eq(Number(d.lines[1].unit_price), 420, 'agreed price kept');
  await rpcFails('CS423', U.mgrA, 'decide_ic_order', { p_order_id: ord, p_approve: true });
  assert((await su(`select 1 from notifications where user_id=$1 and title like '%approved'`, [MGRB])).length === 1, 'buyer told');
});

let trf;
await test('Dispatch', 'The seller dispatches the order: stock is picked from the seller\'s bins (split over bins) into a transfer owned by the buyer on arrival', async () => {
  await rpcFails('CS401', MGRB, 'create_transfer_from_ic_order', { p_request_id: uuid(), p_order_id: ord });
  const before = (await balance(BOLT, A01)) + (await balance(BOLT, A02));
  const req = uuid();
  const r = await rpc(U.ctrl1, 'create_transfer_from_ic_order', { p_request_id: req, p_order_id: ord });
  trf = r.transfer_id; eq(r.status, 'dispatched', 'dispatched at once');
  eq((await rpc(U.ctrl1, 'create_transfer_from_ic_order', { p_request_id: req, p_order_id: ord })).transfer_id, trf, 'retry-safe');
  const tl = await su(`select l.product_id, l.qty_dispatched, sl.code from transfer_lines l join storage_locations sl on sl.id=l.from_location_id where transfer_id=$1 order by line_no`, [trf]);
  eq(tl.filter((x) => x.product_id === BOLT).map((x) => [x.code, Number(x.qty_dispatched)]), [['A-01', 300], ['A-02', 100]], 'largest bin first, then split');
  eq((await balance(BOLT, A01)) + (await balance(BOLT, A02)), before - 400, 'stock left the seller');
  const t = await q(`select to_owner_company_id, reference from transfers where id=$1`, [trf]);
  eq(t.to_owner_company_id, CB, 'buyer will own it'); assert(/^ICO-/.test(t.reference), 'order number on transfer');
  eq((await q(`select status from ic_orders where id=$1`, [ord])).status, 'in_transit', 'order in transit');
  eq((await q(`select count(*)::int n from ic_orders where transfer_id=$1`, [trf])).n, 1, 'no second (automatic) order');
  await rpcFails('CS423', U.mgrA, 'cancel_ic_order', { p_order_id: ord, p_reason: 'too late' });
});

await test('Dispatch', 'An order larger than the seller\'s stock cannot be dispatched (nothing moves)', async () => {
  const r = await rpc(MGRB, 'create_ic_order', { p_request_id: uuid(), p_from_warehouse_id: WH1, p_to_warehouse_id: WH2, p_lines: [{ product_id: OIL, qty: 999 }] });
  await rpc(U.mgrA, 'decide_ic_order', { p_order_id: r.order_id, p_approve: true });
  const e = await rpcFails('CS409', U.ctrl1, 'create_transfer_from_ic_order', { p_request_id: uuid(), p_order_id: r.order_id });
  assert(/P5-OIL short by 993/.test(e.message), e.message);
  eq((await q(`select status, transfer_id from ic_orders where id=$1`, [r.order_id])).status, 'approved', 'unchanged');
  await rpc(MGRB, 'cancel_ic_order', { p_order_id: r.order_id, p_reason: 'ordered too many' });
  eq((await q(`select status from ic_orders where id=$1`, [r.order_id])).status, 'cancelled', 'cancelled');
});

// ======================================================================================
console.log('\n2. Invoices');
let inv1, inv2;
await test('Invoices', 'Receiving issues a tax invoice from seller to buyer for what arrived, at the agreed prices, with 15 % VAT', async () => {
  const lines = await su(`select id, product_id, qty_dispatched from transfer_lines where transfer_id=$1 order by line_no`, [trf]);
  const boltLines = lines.filter((l) => l.product_id === BOLT); const oil = lines.find((l) => l.product_id === OIL);
  await rpc(U.ctrlB, 'receive_transfer', { p_request_id: uuid(), p_transfer_id: trf, p_lines: [
    { transfer_line_id: boltLines[0].id, qty_received: 300 }, { transfer_line_id: oil.id, qty_received: 3, qty_damaged: 1 }] });
  const inv = await su(`select * from ic_invoices where transfer_id=$1`, [trf]);
  eq(inv.length, 1, 'one invoice'); inv1 = inv[0];
  eq([inv1.seller_company_id, inv1.buyer_company_id, inv1.kind, inv1.order_id], [CA, CB, 'invoice', ord], 'parties & order');
  assert(inv1.invoice_no.startsWith('ICI-'), inv1.invoice_no);
  eq(Number(inv1.subtotal), 300 * 2.75 + 4 * 420, 'good + damaged in transit at agreed prices');
  eq(Number(inv1.vat_rate), 15, 'VAT'); eq(Number(inv1.vat_amount), 375.75, 'VAT amount'); eq(Number(inv1.total), 2880.75, 'total');
  eq(inv1.seller_snapshot.vat_number, '4123456789', 'seller VAT number on invoice');
  eq(inv1.buyer_snapshot.address, '9 Harbour St, Gqeberha, 6001', 'buyer address on invoice');
  const due = new Date(inv1.due_date) - new Date(inv1.issue_date);
  eq(Math.round(due / 864e5), 30, 'due in 30 days');
  const d = await rpc(MGRB, 'ic_invoice_detail', { p_invoice_id: inv1.id });
  eq(d.title, 'TAX INVOICE', 'title'); eq(d.lines.length, 2, 'lines'); eq(d.can_manage, false, 'buyer cannot manage');
  eq((await rpc(U.mgrA, 'ic_invoice_detail', { p_invoice_id: inv1.id })).can_manage, true, 'seller manages');
  eq((await q(`select status from ic_orders where id=$1`, [ord])).status, 'in_transit', 'partly received');
});

await test('Invoices', 'The rest arrives: a second invoice; the order is completed; owners changed exactly by what was invoiced', async () => {
  const bl = (await su(`select id from transfer_lines where transfer_id=$1 and product_id=$2 order by line_no`, [trf, BOLT]))[1];
  await rpc(U.ctrlB, 'receive_transfer', { p_request_id: uuid(), p_transfer_id: trf, p_lines: [{ transfer_line_id: bl.id, qty_received: 100 }] });
  const inv = await su(`select * from ic_invoices where transfer_id=$1 order by created_at`, [trf]);
  eq(inv.length, 2, 'second invoice'); inv2 = inv[1];
  eq(Number(inv2.subtotal), 275, '100 × 2.75'); eq(Number(inv2.total), 316.25, 'with VAT');
  eq((await q(`select status from ic_orders where id=$1`, [ord])).status, 'completed', 'order completed');
  const owned = await q(`select coalesce(sum(qty),0) q from stock_balances where warehouse_id=$1 and owner_company_id=$2 and product_id=$3`, [WH2, CB, BOLT]);
  eq(Number(owned.q), 400, 'buyer owns the 400 bolts it was invoiced for');
});

await test('Invoices', 'A transfer between companies without an order gets an automatic order; a written-off shortage is not invoiced', async () => {
  const r = await rpc(U.ctrl1, 'create_transfer', { p_request_id: uuid(), p_from_warehouse_id: WH1, p_to_warehouse_id: WH2,
    p_lines: [{ product_id: OIL, from_location_id: A01, qty: 5 }], p_to_owner_company_id: CB, p_dispatch_now: true });
  const o = await su(`select * from ic_orders where transfer_id=$1`, [r.transfer_id]);
  eq(o.length, 1, 'automatic order'); eq([o[0].origin, o[0].status, o[0].seller_company_id, o[0].buyer_company_id], ['transfer', 'in_transit', CA, CB], 'order');
  const l = await q(`select id from transfer_lines where transfer_id=$1`, [r.transfer_id]);
  await rpc(U.ctrlB, 'receive_transfer', { p_request_id: uuid(), p_transfer_id: r.transfer_id, p_lines: [{ transfer_line_id: l.id, qty_received: 3 }] });
  await rpc(U.ctrlB, 'request_transfer_writeoff', { p_request_id: uuid(), p_transfer_id: r.transfer_id, p_reason_code: 'LOST', p_notes: '2 drums missing' }).catch(async (e) => {
    const code = (await q(`select code from reason_codes where kind='transfer_writeoff' limit 1`)).code;
    await rpc(U.ctrlB, 'request_transfer_writeoff', { p_request_id: uuid(), p_transfer_id: r.transfer_id, p_reason_code: code, p_notes: '2 drums missing' });
  });
  const inv = await su(`select subtotal from ic_invoices where transfer_id=$1`, [r.transfer_id]);
  eq(inv.length, 1, 'invoiced once'); eq(Number(inv[0].subtotal), 3 * 440, 'only the 3 received, at cost + 10 %');
  // a same-company transfer creates no documents
  const yard = await id(`select id from warehouses where code='CPT-YARD'`);
  const s = await rpc(U.admin, 'create_transfer', { p_request_id: uuid(), p_from_warehouse_id: WH1, p_to_warehouse_id: yard,
    p_lines: [{ product_id: BOLT, from_location_id: A02, qty: 1 }], p_dispatch_now: true });
  eq((await q(`select count(*)::int n from ic_orders where transfer_id=$1`, [s.transfer_id])).n, 0, 'no order inside one company');
});

await test('Invoices', 'An issued invoice can never be changed or deleted, even by the database owner', async () => {
  await su(`update ic_invoices set total = 1 where id=$1`, [inv1.id]).then(() => { throw new Error('changed'); }, (e) => assert(/cannot be changed/.test(e.message), e.message));
  await su(`delete from ic_invoices where id=$1`, [inv1.id]).then(() => { throw new Error('deleted'); }, () => {});
  await su(`update ic_invoice_lines set unit_price = 0 where invoice_id=$1`, [inv1.id]).then(() => { throw new Error('line changed'); }, () => {});
  await as(U.mgrA, `select * from ic_invoices`).then(() => { throw new Error('direct read'); }, (e) => eq(e.code, '42501', 'no direct table access'));
});

await test('Credit & payment', 'Seller issues a partial credit note (damaged drum), then records payment; buyer cannot', async () => {
  const d = await rpc(U.mgrA, 'ic_invoice_detail', { p_invoice_id: inv1.id });
  const oilLine = d.lines.find((l) => /P5-OIL/.test(l.description));
  await rpcFails('CS401', MGRB, 'credit_ic_invoice', { p_request_id: uuid(), p_invoice_id: inv1.id, p_reason: 'x' });
  await rpcFails('CS422', U.mgrA, 'credit_ic_invoice', { p_request_id: uuid(), p_invoice_id: inv1.id, p_reason: 'too many',
    p_lines: [{ invoice_line_id: oilLine.id, qty: 5 }] });
  const req = uuid();
  const c = await rpc(U.mgrA, 'credit_ic_invoice', { p_request_id: req, p_invoice_id: inv1.id, p_reason: 'Drum damaged in transit',
    p_lines: [{ invoice_line_id: oilLine.id, qty: 1 }] });
  assert(c.credit_note_no.startsWith('ICC-'), c.credit_note_no); eq(Number(c.total), 483, '420 + 15 % VAT');
  eq((await rpc(U.mgrA, 'credit_ic_invoice', { p_request_id: req, p_invoice_id: inv1.id, p_reason: 'Drum damaged in transit',
    p_lines: [{ invoice_line_id: oilLine.id, qty: 1 }] })).credit_note_id, c.credit_note_id, 'retry-safe');
  eq((await q(`select status from ic_invoices where id=$1`, [inv1.id])).status, 'partly_credited', 'partly credited');
  eq((await rpc(MGRB, 'ic_invoice_detail', { p_invoice_id: c.credit_note_id })).title, 'TAX CREDIT NOTE', 'credit note title');
  await rpcFails('CS401', MGRB, 'record_ic_payment', { p_invoice_id: inv2.id, p_paid_on: TODAY, p_reference: 'EFT' });
  await rpcFails('CS422', U.mgrA, 'record_ic_payment', { p_invoice_id: inv2.id, p_paid_on: '2020-01-01', p_reference: 'EFT' });
  await rpc(U.mgrA, 'record_ic_payment', { p_invoice_id: inv2.id, p_paid_on: TODAY, p_reference: 'EFT 12345' });
  eq((await q(`select status, paid_reference from ic_invoices where id=$1`, [inv2.id])).paid_reference, 'EFT 12345', 'paid');
  await rpcFails('CS423', U.mgrA, 'record_ic_payment', { p_invoice_id: inv2.id, p_paid_on: TODAY, p_reference: 'again' });
  const full = await rpc(U.mgrA, 'credit_ic_invoice', { p_request_id: uuid(), p_invoice_id: inv1.id, p_reason: 'Returned' });
  eq(Number(full.total), 2880.75 - 483, 'the rest');
  eq((await q(`select status from ic_invoices where id=$1`, [inv1.id])).status, 'credited', 'fully credited');
  await rpcFails('CS423', U.mgrA, 'credit_ic_invoice', { p_request_id: uuid(), p_invoice_id: inv1.id, p_reason: 'again' });
});

await test('Visibility', 'Each side sees its own documents; others see nothing; anonymous callers are refused', async () => {
  const mine = await rpcAll(MGRB, 'ic_invoices_list', {});
  assert(mine.length >= 4 && mine.every((x) => x.side === 'purchases'), 'buyer sees its purchases');
  assert((await rpcAll(U.mgrA, 'ic_invoices_list', {})).every((x) => x.side === 'sales'), 'seller sees sales');
  eq((await rpcAll(U.counter, 'ic_invoices_list', {})).length, 0, 'counter sees none');
  eq((await rpcAll(U.counter, 'ic_orders_list', {})).length, 0, 'no orders for a counter');
  await rpcFails('CS422', U.counter, 'ic_invoice_detail', { p_invoice_id: inv1.id });
  await as('anon', `select public.ic_orders_list()`).then(() => { throw new Error('anon'); }, (e) => eq(e.code, '42501', 'anon refused'));
  const docs = await rpc(U.ctrlB, 'ic_documents_for_transfer', { p_transfer_id: trf });
  eq(docs.orders.length, 1, 'receiving controller sees the order'); eq(docs.invoices.length, 0, 'but not invoices (no invoice.view)');
  const o = (await rpcAll(U.ctrlB, 'ic_orders_list', {})).find((x) => x.id === ord);
  eq(o.value, null, 'no prices without cost.view / invoice.view');
});

await test('Accounting', 'Invoice export: seller sees sales lines, buyer purchase lines, credit notes negative; totals agree', async () => {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Johannesburg' }).format(new Date());
  const s = await rpcAll(U.mgrA, 'ic_invoice_export', { p_company: CA, p_from: '2020-01-01', p_to: today });
  const b = await rpcAll(MGRB, 'ic_invoice_export', { p_company: CB, p_from: '2020-01-01', p_to: today });
  assert(s.every((x) => x.side === 'sales' && x.account === '205' && x.tax_type === 'Standard Rate Sales'), 'sales');
  assert(b.every((x) => x.side === 'purchases' && x.account === '310'), 'purchases');
  const sum = (a) => Math.round(a.reduce((t, x) => t + Number(x.line_total), 0) * 100) / 100;
  eq(sum(s), sum(b), 'both sides agree');
  const db = (await q(`select sum(case kind when 'credit_note' then -subtotal else subtotal end) v from ic_invoices`)).v;
  eq(sum(s), Number(db), 'export = invoices');
  await rpcFails('CS401', U.mgrA, 'ic_invoice_export', { p_company: CB, p_from: '2020-01-01', p_to: today });
});

await test('Integrity', 'Stock integrity stays clean after inter-company trading; anonymous access sanity holds', async () => {
  const r = (await su(`select integrity.run_check('test', null) r`))[0].r;
  const crit = await su(`select check_code, description from integrity.findings where severity='critical' and status in ('open','investigating')`);
  eq(r.status, 'completed', 'completed');
  eq(crit.length, 0, 'critical: ' + crit.map((c) => c.check_code + ' ' + c.description).join(' | '));
  const bad = await su(`select p.oid::regprocedure::text f from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('public','private','integrity') and has_function_privilege('anon', p.oid, 'execute')`);
  eq(bad.length, 0, 'anon');
});

await pool.end();
const failed = results.filter((r) => r.status !== 'PASS');
console.log(`\n${results.length - failed.length} passed, ${failed.length} failed`);
writeFileSync(new URL('./results-phase5.json', import.meta.url), JSON.stringify({ at: new Date().toISOString(), results }, null, 2));
process.exit(failed.length ? 1 : 0);
