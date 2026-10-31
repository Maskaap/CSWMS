// End-to-end smoke test: real browser, real Next.js build, real PostgREST on the
// test database (via gateway.mjs). Signs in as several roles, opens every screen,
// and fails on any page error, console error or failed API call. Then performs
// real stock transactions through the UI.
import { createRequire } from 'node:module';
// Playwright may be installed globally (CI image) or locally.
const req = createRequire(import.meta.url);
let pw; try { pw = req('playwright'); } catch { pw = req(process.env.PLAYWRIGHT_PATH || '/opt/npm-tools/node_modules/playwright'); }
const { chromium } = pw;
import pg from 'pg';
import fs from 'node:fs';

const BASE = process.env.APP_URL || 'http://localhost:3000';
const PASSWORD = process.env.E2E_PASSWORD || 'Test-pass-123';
const SHOTS = process.env.SHOTS_DIR || null;
const db = new pg.Pool({ host: process.env.PGHOST || '/tmp', user: 'postgres', database: process.env.TEST_DB || 'cswms_test', max: 2 });
const one = async (sql) => (await db.query(sql)).rows[0] ?? {};
const su0 = (sql) => db.query(sql);   // test-data setup only

const ids = {
  product: (await one(`select product_id id from stock_balances where qty > 0 limit 1`)).id,
  transfer: (await one(`select id from transfers order by created_at desc limit 1`)).id,
  stocktake: (await one(`select id from stocktakes order by created_at limit 1`)).id,
  txn: (await one(`select id from stock_transactions where status = 'posted' order by created_at desc limit 1`)).id,
  finding: (await one(`select id from integrity.findings order by first_detected_at desc limit 1`)).id,
  batch: (await one(`select id from import_batches limit 1`)).id,
};

const ANALYTICS = ['overview', 'movements', 'velocity', 'ageing', 'consumption', 'valuation', 'forecast', 'performance'].map((t) => `/analytics?tab=${t}`);
const PAGES = [
  '/', '/stock', `/stock/${ids.product}`, '/scan', '/receive', '/withdraw', '/transfers', '/transfers/new', `/transfers/${ids.transfer}`,
  '/corrections', '/corrections?tab=move', '/corrections?tab=status', '/corrections?tab=adjust', `/transactions/${ids.txn}`,
  '/stocktake', `/stocktake/${ids.stocktake}`, '/alerts', '/alerts?tab=notifications', '/integrity', `/integrity/${ids.finding}`,
  '/reports', '/approvals', '/users', '/setup', '/setup?tab=locations', '/setup/products', `/setup/products/${ids.product}`, '/setup/import', `/setup/import?batch=${ids.batch}`,
  '/setup/labels', '/admin',
  // Phase 2
  '/purchasing', '/purchasing/new', '/purchasing/suggestions', '/assets', '/reservations', '/alerts?tab=prefs',
  // Phase 3
  ...ANALYTICS, '/analytics/job?ref=JOB-REPEAT',
  // Phase 4
  '/tasks', '/me', '/setup/wizard', '/reports/accounting',
];
const USERS = [
  { email: 'admin@cswms.test', pages: PAGES },
  { email: 'ho@cswms.test', pages: ['/', '/stock', '/integrity', `/integrity/${ids.finding}`, '/reports', '/approvals', '/stocktake'] },
  { email: 'ctrl1@cswms.test', pages: ['/', '/stock', '/receive', '/withdraw', '/transfers', '/corrections', '/alerts', '/scan'] },
  { email: 'counter@cswms.test', pages: ['/', '/stocktake', `/stocktake/${ids.stocktake}`] },
  { email: 'auditor@cswms.test', pages: ['/', '/stock', '/reports', '/integrity', '/admin'] },
  { email: 'mgra@cswms.test', pages: ['/', '/stock', '/approvals', '/users', '/setup', '/reports'] },
  { email: 'sup1@cswms.test', pages: ['/', '/purchasing', '/purchasing/new', '/purchasing/suggestions', '/assets', '/reservations', '/approvals', '/alerts?tab=prefs'] },
  { email: 'brmgr@cswms.test', pages: ['/', '/approvals', '/purchasing', '/assets', '/reports'] },
  { email: 'ctrl1@cswms.test', pages: ['/assets', '/reservations', '/withdraw', '/analytics'] },
  { email: 'ho@cswms.test', pages: [...ANALYTICS, '/analytics/job?ref=JOB-REPEAT'] },
  { email: 'auditor@cswms.test', pages: ['/analytics', '/analytics?tab=valuation', '/analytics?tab=performance'] },
  { email: 'sup1@cswms.test', pages: [...ANALYTICS] },   // no price access: line counts, no rand
  { email: 'counter@cswms.test', pages: ['/tasks', '/me'] },
  { email: 'ctrl1@cswms.test', pages: ['/tasks', '/me'] },
];

const results = [];
const browser = await chromium.launch();

async function login(page, email) {
  await page.goto(BASE + '/login');
  await page.getByLabel(/e-mail/i).fill(email);
  await page.getByLabel(/password/i).fill(PASSWORD);
  await page.getByRole('button', { name: /sign in/i }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/login'), { timeout: 15000 });
}

function watch(page, sink) {
  page.on('pageerror', (e) => sink.push(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) sink.push(`console: ${m.text().slice(0, 300)}`); });
  page.on('response', async (r) => {
    const u = r.url();
    if (r.status() >= 400 && u.includes(':54321')) {
      let body = ''; try { body = (await r.text()).slice(0, 300); } catch { /* ignore */ }
      sink.push(`HTTP ${r.status()} ${r.request().method()} ${u.replace(/^.*\/(rest|auth)\/v1/, '/$1')} ${body}`);
    }
  });
}

async function settle(page) {
  await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(300);
}

for (const u of USERS) {
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page = await ctx.newPage();
  const errs = [];
  watch(page, errs);
  try { await login(page, u.email); } catch (e) { results.push({ user: u.email, page: 'login', ok: false, errors: [String(e)] }); await ctx.close(); continue; }
  for (const p of u.pages) {
    errs.length = 0;
    await page.goto(BASE + p);
    await settle(page);
    const shown = await page.locator('text=/Could not load|Could not load your account|Not done/').count();
    const ok = errs.length === 0 && shown === 0;
    results.push({ user: u.email, page: p, ok, errors: [...errs, ...(shown ? ['visible error banner on page'] : [])] });
    if (SHOTS && u.email.startsWith('admin') && ['/', '/integrity', '/stock', '/reports', '/stocktake'].includes(p)) {
      await page.screenshot({ path: `${SHOTS}/admin${p.replace(/\W+/g, '_') || '_home'}.png`, fullPage: false });
    }
  }
  await ctx.close();
}

// ---- functional flows through the UI (stock controller, Cape Town main) ----
async function flow(name, fn) {
  const ctx = await browser.newContext({ viewport: { width: 420, height: 900 }, isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  const errs = [];
  watch(page, errs);
  try {
    await login(page, 'ctrl1@cswms.test');
    await fn(page);
    results.push({ user: 'ctrl1@cswms.test', page: name, ok: errs.length === 0, errors: errs });
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/flow_${name.replace(/\W+/g, '_')}.png`, fullPage: true });
  } catch (e) {
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/flow_${name.replace(/\W+/g, '_')}_FAILED.png`, fullPage: true }).catch(() => {});
    results.push({ user: 'ctrl1@cswms.test', page: name, ok: false, errors: [String(e).slice(0, 500), ...errs] });
  }
  await ctx.close();
}

const before = Number((await one(`select coalesce(sum(qty),0) q from stock_balances b join products p on p.id=b.product_id join warehouses w on w.id=b.warehouse_id where p.sku='TAPE-48' and w.code='CPT-MAIN' and b.status='available'`)).q);

await flow('withdraw TAPE-48 via scan (mobile)', async (page) => {
  await page.goto(BASE + '/withdraw');
  await settle(page);
  const scan = page.getByRole('textbox', { name: 'Scan product' });
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await page.getByText('Packaging tape 48mm').first().waitFor();
  await page.getByLabel(/Quantity of TAPE-48/).fill('1');
  await page.locator('select').filter({ hasText: 'Select' }).first().selectOption('PRODUCTION');
  await page.getByPlaceholder('e.g. JOB-7781').fill('E2E-JOB-1');
  await page.getByRole('button', { name: /Confirm withdrawal/ }).click();
  await page.getByText(/^Saved/).first().waitFor({ timeout: 15000 });
});
await flow('receive TAPE-48 via scan', async (page) => {
  await page.goto(BASE + '/receive');
  await settle(page);
  const scan = page.getByRole('textbox', { name: 'Scan product' });
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await page.getByText('Packaging tape 48mm').first().waitFor();
  await page.getByLabel(/Quantity of TAPE-48/).fill('2');
  await page.getByPlaceholder(/Delivery note|DN|reference/i).first().fill('E2E-DN-1');
  const review = page.getByRole('button', { name: /Review|Check/ });
  if (await review.count()) await review.first().click();
  await page.getByRole('button', { name: /Confirm receipt|Post receipt|Save receipt|Confirm/ }).last().click();
  await page.getByText(/^Saved/).first().waitFor({ timeout: 15000 });
});

await flow('transfer CPT-MAIN -> PE-MAIN: dispatch (ctrl1) then receive (ctrlB)', async (page) => {
  await page.goto(BASE + '/transfers/new');
  await settle(page);
  const scan = page.getByRole('textbox', { name: 'Scan product' });
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await page.getByText('Packaging tape 48mm').first().waitFor();
  await page.getByLabel(/Quantity of TAPE-48/).fill('1');
  const dest = page.locator('label', { hasText: 'Destination warehouse' }).locator('select');
  await dest.selectOption({ label: await dest.locator('option', { hasText: 'PE-MAIN' }).first().innerText() });
  await page.getByRole('button', { name: 'Dispatch transfer' }).click();
  await page.waitForURL(/\/transfers\/[0-9a-f-]{36}$/, { timeout: 15000 });
  await page.getByText('dispatched').first().waitFor();
  const url = page.url();
  // receiving user at the destination
  await page.context().clearCookies();
  await page.evaluate(() => localStorage.clear());
  await login(page, 'ctrlb@cswms.test');
  await page.goto(url);
  await settle(page);
  await page.getByRole('button', { name: 'all' }).first().click();
  await page.getByRole('button', { name: 'Confirm receipt' }).click();
  await page.getByText(/Receipt confirmed/).waitFor({ timeout: 15000 });
});


// Full stocktake cycle through the UI: schedule -> start -> count -> close -> submit (admin), approve (head office)
{
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page = await ctx.newPage();
  const errs = []; watch(page, errs);
  const confirmDialog = async () => { await page.locator('dialog[open]').getByRole('button', { name: 'Confirm' }).click(); };
  try {
    await login(page, 'admin@cswms.test');
    await page.goto(BASE + '/stocktake'); await settle(page);
    await page.getByRole('button', { name: /Schedule stocktakes for/ }).click();
    const whSel = page.locator('label', { hasText: /^Warehouse/ }).locator('select');
    await whSel.selectOption({ label: await whSel.locator('option', { hasText: 'CPT-YARD' }).first().innerText() });
    await page.getByRole('button', { name: 'Schedule', exact: true }).click();
    await page.getByText(/Scheduled 1 stocktake/).waitFor({ timeout: 15000 });
    const st = (await one(`select s.id, s.stocktake_no from stocktakes s join warehouses w on w.id = s.warehouse_id where w.code = 'CPT-YARD' order by s.created_at desc limit 1`));
    await page.goto(BASE + '/stocktake/' + st.id); await settle(page);
    await page.getByRole('button', { name: 'Start counting' }).click(); await confirmDialog();
    await page.getByText(/Counting started/).waitFor({ timeout: 15000 });
    const loc = page.locator('select').filter({ hasText: 'scan a location label or choose' });
    await loc.selectOption({ index: 1 });
    const scan = page.getByRole('textbox', { name: 'Scan product' });
    await scan.fill('TAPE-48'); await scan.press('Enter');
    await page.getByLabel('Quantity counted').fill('3');
    await page.getByRole('button', { name: 'Record count' }).click();
    await page.getByText(/Count recorded/).waitFor({ timeout: 15000 });
    await page.getByRole('button', { name: 'Close counting' }).click(); await confirmDialog();
    await page.getByText(/Counting closed/).waitFor({ timeout: 15000 });
    await page.getByRole('button', { name: 'Submit for approval' }).click(); await confirmDialog();
    await page.getByText(/Submitted for management approval/).waitFor({ timeout: 15000 });
    // approval by a different person
    await page.context().clearCookies(); await page.evaluate(() => localStorage.clear());
    await login(page, 'ho@cswms.test');
    await page.goto(BASE + '/approvals'); await settle(page);
    const row = page.locator('tr', { hasText: st.stocktake_no });
    await row.getByRole('button', { name: 'Approve' }).click();
    await page.locator('dialog[open] textarea').fill('Checked against count sheets (E2E)');
    await confirmDialog();
    await page.getByText(/Approved and posted/).waitFor({ timeout: 15000 });
    const fin = await one(`select status, adjustment_txn_id from stocktakes where id = '${st.id}'`);
    results.push({ user: 'admin+ho', page: `stocktake ${st.stocktake_no}: schedule → start → count → close → submit → approve (status ${fin.status})`, ok: fin.status === 'finalised' && errs.length === 0, errors: fin.status === 'finalised' ? errs : [`status ${fin.status}`, ...errs] });
  } catch (e) {
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/flow_stocktake_FAILED.png`, fullPage: true }).catch(() => {});
    results.push({ user: 'admin+ho', page: 'stocktake cycle', ok: false, errors: [String(e).slice(0, 500), ...errs] });
  }
  await ctx.close();
}


// Opening stock import from a real .xlsx file through the upload wizard, approved by a second person.
{
  const ExcelJS = req('/home/claude/cswms/node_modules/exceljs');
  const wb = new ExcelJS.Workbook(); const ws = wb.addWorksheet('Stock');
  ws.addRow(['Stock code', 'Description', 'Category', 'Unit', 'Opening quantity', 'Warehouse', 'Location', 'Min qty']);
  const tag = Date.now().toString(36).toUpperCase();
  ws.addRow([`E2E-${tag}-A`, 'E2E safety boots size 9', 'PPE', 'PAIR', 12, 'CPT-YARD', 'Y1', 4]);
  ws.addRow([`E2E-${tag}-B`, 'E2E cable ties 300mm', 'Consumables', 'PACK', 30, 'CPT-YARD', '', '']);
  const file = `/tmp/e2e-opening-${tag}.xlsx`;
  await wb.xlsx.writeFile(file);
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page = await ctx.newPage();
  const errs = []; watch(page, errs);
  const confirmDialog = async () => { await page.locator('dialog[open]').getByRole('button', { name: 'Confirm' }).click(); };
  try {
    await login(page, 'admin@cswms.test');
    await page.goto(BASE + '/setup/import'); await settle(page);
    await page.locator('input[type=file]').setInputFiles(file);
    await page.getByRole('button', { name: /Upload and validate 2 rows/ }).click();
    await page.waitForURL(/batch=/, { timeout: 15000 }); await settle(page);
    await page.getByText(/0 with errors/).waitFor({ timeout: 15000 });
    await page.getByRole('button', { name: 'Submit for approval' }).click(); await confirmDialog();
    await page.getByText(/Submitted for approval/).first().waitFor({ timeout: 15000 });
    await page.context().clearCookies(); await page.evaluate(() => localStorage.clear());
    await login(page, 'ho@cswms.test');
    await page.goto(BASE + '/approvals'); await settle(page);
    const row = page.locator('tr', { hasText: 'Opening balances' }).filter({ has: page.getByRole('button', { name: 'Approve' }) }).first();
    await row.getByRole('button', { name: 'Approve' }).click();
    await page.locator('dialog[open] textarea').fill('Matches signed stock sheets (E2E)');
    await confirmDialog();
    await page.getByText(/Approved and posted/).waitFor({ timeout: 15000 });
    const q = await one(`select coalesce(sum(b.qty),0) q from stock_balances b join products p on p.id = b.product_id where p.sku = 'E2E-${tag}-A'`);
    const t = await one(`select count(*) n from stock_transactions where txn_type = 'opening' and status = 'posted' and import_batch_id is not null and created_at > now() - interval '5 minutes'`);
    results.push({ user: 'admin+ho', page: `opening stock .xlsx import → approval → posted (E2E-${tag}-A balance ${q.q})`, ok: Number(q.q) === 12 && Number(t.n) > 0 && errs.length === 0, errors: Number(q.q) === 12 ? errs : [`balance ${q.q}`, ...errs] });
  } catch (e) {
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/flow_import_FAILED.png`, fullPage: true }).catch(() => {});
    results.push({ user: 'admin+ho', page: 'opening stock import', ok: false, errors: [String(e).slice(0, 500), ...errs] });
  }
  await ctx.close();
}

// ---------------------------------------------------------------- Phase 2 flows
async function as2(name, fn) {
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page = await ctx.newPage();
  const errs = []; watch(page, errs);
  const switchUser = async (email) => { await page.context().clearCookies(); await page.evaluate(() => localStorage.clear()); await login(page, email); };
  try {
    const extra = await fn(page, switchUser);
    results.push({ user: 'phase2', page: name + (extra ? ` (${extra})` : ''), ok: errs.length === 0, errors: errs });
  } catch (e) {
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/flow_${name.replace(/\W+/g, '_')}_FAILED.png`, fullPage: true }).catch(() => {});
    results.push({ user: 'phase2', page: name, ok: false, errors: [String(e).slice(0, 500), ...errs] });
  }
  await ctx.close();
}
const confirmIn = (page) => page.locator('dialog[open]').getByRole('button', { name: 'Confirm' }).click();

await as2('purchase order: create (supervisor) → submit → approve (branch manager) → receive against PO', async (page, switchUser) => {
  await login(page, 'sup1@cswms.test');
  await page.goto(BASE + '/purchasing/new'); await settle(page);
  const scan = page.getByRole('textbox', { name: 'Scan product' });
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await page.getByLabel('Quantity of TAPE-48').fill('10');
  await page.getByLabel('Price of TAPE-48').fill('25');
  await page.locator('label', { hasText: 'Supplier' }).first().locator('select').selectOption({ index: 1 });
  await page.getByRole('button', { name: 'Save draft' }).click();
  await page.waitForURL(/\/purchasing\/[0-9a-f-]{36}$/, { timeout: 15000 });
  const poId = page.url().split('/').pop();
  await settle(page);
  await page.getByRole('button', { name: 'Submit for approval' }).click(); await confirmIn(page);
  await page.getByText('Submitted for approval.').waitFor({ timeout: 15000 });
  const { po_no } = await one(`select po_no from purchase_orders where id = '${poId}'`);
  await switchUser('brmgr@cswms.test');
  await page.goto(BASE + '/approvals'); await settle(page);
  await page.locator('tr', { hasText: po_no }).getByRole('button', { name: 'Approve' }).click();
  await page.locator('dialog[open] textarea').fill('Price matches quote (E2E)');
  await confirmIn(page);
  await page.getByText(/Approved — the order can now be sent/).waitFor({ timeout: 15000 });
  await switchUser('sup1@cswms.test');
  await page.goto(BASE + '/purchasing/' + poId); await settle(page);
  await page.getByLabel('Supplier delivery note number').fill('E2E-DN-PO');
  await page.getByRole('button', { name: 'all', exact: true }).first().click();
  await page.getByRole('button', { name: 'Confirm receipt' }).click();
  await page.getByText(/Receipt posted/).waitFor({ timeout: 15000 });
  const st = await one(`select status from purchase_orders where id = '${poId}'`);
  if (st.status !== 'received') throw new Error('PO status ' + st.status);
  return `${po_no} received`;
});

await su0(`insert into products (sku, description, base_uom_id, is_asset) select 'E2E-DRILL', 'E2E cordless drill', id, true from uoms where code = 'EA' on conflict do nothing`);
await as2('tool: register (supervisor) → find by scanning tag → check out → check in', async (page) => {
  await login(page, 'sup1@cswms.test');
  await page.goto(BASE + '/assets'); await settle(page);
  await page.getByRole('button', { name: 'Register item' }).click();
  const dlg = page.locator('dialog[open]');
  const prod = dlg.locator('label', { hasText: 'Product' }).locator('select');
  await prod.selectOption({ label: await prod.locator('option', { hasText: 'E2E-DRILL' }).first().innerText() });
  await dlg.locator('label', { hasText: 'Serial number' }).locator('input').fill('SN-E2E-' + Date.now());
  await dlg.getByRole('button', { name: 'Register' }).click();
  await page.waitForURL(/\/assets\/[0-9a-f-]{36}$/, { timeout: 15000 });
  const assetId = page.url().split('/').pop();
  const { asset_tag } = await one(`select asset_tag from assets where id = '${assetId}'`);
  await page.goto(BASE + '/assets'); await settle(page);
  const sc = page.getByRole('textbox', { name: 'Scan a tool tag or serial number' });
  await sc.fill(asset_tag); await sc.press('Enter');
  await page.waitForURL(new RegExp(assetId), { timeout: 15000 }); await settle(page);
  await page.locator('label', { hasText: 'Employee' }).locator('select').selectOption({ label: 'Me' });
  await page.getByLabel('Job / reference').fill('JOB-E2E-T');
  await page.getByRole('button', { name: 'Check out' }).last().click();
  await page.getByText('Checked out.').waitFor({ timeout: 15000 });
  await page.locator('label', { hasText: 'Returned to' }).locator('select').selectOption({ index: 1 });
  await page.getByRole('button', { name: 'Check in' }).last().click();
  await page.getByText('Returned.').waitFor({ timeout: 15000 });
  const a = await one(`select status, (select count(*) from asset_movements where asset_id = '${assetId}')::int n from assets where id = '${assetId}'`);
  if (a.status !== 'in_store' || a.n !== 3) throw new Error(`status ${a.status}, movements ${a.n}`);
  return `${asset_tag}: register → out → in`;
});

await as2('reservation: reserve 2 for a job → withdraw picks the job from the reserved chips → fulfilled', async (page) => {
  await login(page, 'ctrl1@cswms.test');
  await page.goto(BASE + '/reservations'); await settle(page);
  let scan = page.getByRole('textbox', { name: 'Scan product' });
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await page.getByText('Free to reserve').waitFor();
  await page.locator('label', { hasText: 'Quantity' }).first().locator('input').fill('2');
  await page.getByPlaceholder('e.g. JOB-7781').fill('E2E-RES-1');
  await page.getByRole('button', { name: 'Reserve', exact: true }).click();
  await page.getByText(/Reserved 2 .* for E2E-RES-1/).waitFor({ timeout: 15000 });
  await page.goto(BASE + '/withdraw'); await settle(page);
  scan = page.getByRole('textbox', { name: 'Scan product' });
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await page.getByLabel(/Quantity of TAPE-48/).fill('2');
  await page.locator('select').filter({ hasText: 'Select' }).first().selectOption('PRODUCTION');
  await page.getByRole('button', { name: /E2E-RES-1/ }).click();
  await page.getByRole('button', { name: /Confirm withdrawal/ }).click();
  await page.getByText(/^Saved/).first().waitFor({ timeout: 15000 });
  const r = await one(`select status from stock_reservations where reference = 'E2E-RES-1'`);
  if (r.status !== 'fulfilled') throw new Error('reservation ' + r.status);
  return 'fulfilled by the withdrawal';
});

await as2('admin: approval rules tab, notification settings save', async (page) => {
  await login(page, 'admin@cswms.test');
  await page.goto(BASE + '/admin'); await settle(page);
  await page.getByRole('tab', { name: 'Approval rules' }).click(); await settle(page);
  await page.getByText('Head office').first().waitFor();
  await page.goto(BASE + '/alerts?tab=prefs'); await settle(page);
  await page.getByText('Send me a daily summary').click();
  await page.getByRole('button', { name: 'Save preferences' }).click();
  await page.getByText('Preferences saved.').waitFor({ timeout: 15000 });
  const n = await one(`select daily_digest from notification_preferences np join app_users u on u.id = np.user_id where u.email = 'admin@cswms.test'`);
  if (n.daily_digest !== true) throw new Error('preference not stored');
});

// ---------------------------------------------------------------- Phase 3 flows
await as2('analytics: consumption by job → job costing page; chart tooltip by keyboard; analytics report export', async (page) => {
  await login(page, 'ho@cswms.test');
  await page.goto(BASE + '/analytics?tab=consumption'); await settle(page);
  await page.getByRole('link', { name: 'JOB-REPEAT' }).first().click();
  await page.waitForURL(/\/analytics\/job\?ref=JOB-REPEAT/, { timeout: 15000 }); await settle(page);
  await page.getByRole('heading', { name: /Job costing — JOB-REPEAT/ }).waitFor();
  await page.getByText('Materials used').waitFor();
  const rows = await page.locator('table').first().locator('tbody tr').count();
  if (rows < 1) throw new Error('no materials listed');
  await page.goto(BASE + '/analytics?tab=movements'); await settle(page);
  await page.getByRole('img', { name: 'Stock received and consumed' }).focus();
  await page.getByText('Consumed (issued − returned)').nth(1).waitFor({ timeout: 5000 });   // legend + tooltip row
  await page.goto(BASE + '/reports'); await settle(page);
  await page.getByRole('button', { name: /Fast, slow and dead stock/ }).click(); await settle(page);
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 20000 }), page.getByRole('button', { name: 'Excel' }).first().click()]);
  return `job page with ${rows} material line(s); ${dl.suggestedFilename()}`;
});

await as2('analytics: no price access → no rand anywhere; stock controller is refused', async (page, switchUser) => {
  await login(page, 'sup1@cswms.test');
  await page.goto(BASE + '/analytics'); await settle(page);
  await page.getByText(/Rand values are hidden for your role/).waitFor();
  const text = await page.locator('main').innerText();
  if (/R\s?\d/.test(text.replace(/R\s?0[,.]00/g, ''))) throw new Error('a rand amount is visible to a role without cost.view');
  await page.goto(BASE + '/analytics?tab=valuation'); await settle(page);
  await page.getByText(/only available to roles that may see purchase prices/).waitFor();
  await switchUser('ctrl1@cswms.test');
  await page.goto(BASE + '/analytics'); await settle(page);
  await page.getByText(/You do not have access to analytics/).waitFor();
});

// ---------------------------------------------------------------- Phase 4 flows (floor experience)
async function p4(name, email, fn, { mobile = true, downloads = false } = {}) {
  const ctx = await browser.newContext(mobile ? { viewport: { width: 420, height: 900 }, isMobile: true, hasTouch: true, acceptDownloads: downloads } : { viewport: { width: 1366, height: 900 }, acceptDownloads: downloads });
  const page = await ctx.newPage();
  const errs = []; watch(page, errs);
  try {
    await login(page, email);
    const extra = await fn(page, ctx);
    results.push({ user: 'phase4', page: name + (extra ? ` (${extra})` : ''), ok: errs.filter((e) => !/ERR_INTERNET_DISCONNECTED|Failed to fetch|NetworkError/.test(e)).length === 0, errors: errs });
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/p4_${name.replace(/\W+/g, '_').slice(0, 60)}.png`, fullPage: true });
  } catch (e) {
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/p4_${name.replace(/\W+/g, '_').slice(0, 60)}_FAILED.png`, fullPage: true }).catch(() => {});
    results.push({ user: 'phase4', page: name, ok: false, errors: [String(e).slice(0, 500), ...errs] });
  }
  await ctx.close();
}

// a cycle count of one item (TAPE-48) at CPT-MAIN, counting already started
const cyc = (await one(`with s as (
    insert into stocktakes (stocktake_no, name, period, warehouse_id, product_ids, kind, blind, due_date, created_by)
    select private.next_doc_no('CYC'), 'E2E cycle count', to_char(now(), 'YYYY-MM'), w.id, array[(select id from products where sku='TAPE-48')], 'cycle', true, current_date,
           '00000000-0000-0000-0000-000000000000' from warehouses w where w.code='CPT-MAIN' returning id)
  select id, private.start_stocktake_internal(id) n from s`)).id;

await p4('guided count: My tasks → count screen → scan +1 → offline scan kept on phone → synced once back online', 'counter@cswms.test', async (page, ctx) => {
  await page.goto(BASE + '/tasks'); await settle(page);
  await page.getByText('E2E cycle count').waitFor();
  await page.locator('li', { hasText: 'E2E cycle count' }).getByRole('link', { name: /Start counting|Continue counting/ }).click();
  await page.waitForURL(/\/stocktake\/.+\/count$/); await settle(page);
  const scan = page.getByRole('textbox', { name: 'Scan an item' });
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await page.getByRole('status').filter({ hasText: 'TAPE-48 +1' }).waitFor();
  for (let i = 0; i < 50 && Number((await one(`select count(*) n from stocktake_counts where stocktake_id='${cyc}'`)).n) < 1; i++) await page.waitForTimeout(200);
  await ctx.setOffline(true);
  await page.evaluate(() => window.dispatchEvent(new Event('offline')));
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await page.getByText(/2 waiting to send/).waitFor({ timeout: 10000 });
  const mid = Number((await one(`select count(*) n from stocktake_counts where stocktake_id='${cyc}'`)).n);
  if (mid !== 1) throw new Error(`while offline the database should still have 1 count, has ${mid}`);
  await ctx.setOffline(false);
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  let n = 0;
  for (let i = 0; i < 75 && n < 3; i++) { await page.waitForTimeout(200); n = Number((await one(`select count(*) n from stocktake_counts where stocktake_id='${cyc}'`)).n); }
  const r = await one(`select counted_qty, (select count(*) from stocktake_counts c where c.stocktake_id=l.stocktake_id and c.entered_offline) off
                         from stocktake_lines l where stocktake_id='${cyc}' and product_id=(select id from products where sku='TAPE-48') and counted_qty is not null`);
  if (n !== 3 || Number(r.counted_qty) !== 3) throw new Error(`expected 3 counts / total 3 after sync, got ${n} / ${r.counted_qty}`);
  if (Number(r.off) < 2) throw new Error('offline counts not marked as captured offline');
  await page.getByText(/All counts sent/).waitFor({ timeout: 10000 });
  return '3 counts, 2 captured offline, total 3';
});

await p4('quick undo: withdraw 1 TAPE-48 → Undo with reason → stock restored', 'ctrl1@cswms.test', async (page) => {
  const q0 = Number((await one(`select coalesce(sum(qty),0) q from stock_balances b join products p on p.id=b.product_id join warehouses w on w.id=b.warehouse_id where p.sku='TAPE-48' and w.code='CPT-MAIN' and b.status='available'`)).q);
  const t = await one(`select id from stocktakes where status in ('counting') and kind='full' and warehouse_id=(select id from warehouses where code='CPT-MAIN')`);
  if (t.id) throw new Error('a full stocktake is open');
  await page.goto(BASE + '/withdraw'); await settle(page);
  const scan = page.getByRole('textbox', { name: 'Scan product' });
  await scan.fill('TAPE-48'); await scan.press('Enter');
  await page.getByText('Packaging tape 48mm').first().waitFor();
  await page.getByLabel(/Quantity of TAPE-48/).fill('1');
  await page.locator('select').filter({ hasText: 'Select' }).first().selectOption('PRODUCTION');
  await page.getByPlaceholder('e.g. JOB-7781').fill('JOB-UNDO');
  await page.getByRole('button', { name: /Confirm withdrawal/ }).click();
  await page.getByRole('button', { name: /^Undo WD/ }).waitFor({ timeout: 15000 });
  await page.getByRole('button', { name: /^Undo WD/ }).click();
  await page.locator('dialog[open] input').fill('wrong item scanned (E2E)');
  await page.locator('dialog[open]').getByRole('button', { name: 'Undo' }).click();
  await page.locator('dialog[open]').getByText('Undone. Stock is back as it was.').first().waitFor({ timeout: 15000 });
  const q1 = Number((await one(`select coalesce(sum(qty),0) q from stock_balances b join products p on p.id=b.product_id join warehouses w on w.id=b.warehouse_id where p.sku='TAPE-48' and w.code='CPT-MAIN' and b.status='available'`)).q);
  if (q1 !== q0) throw new Error(`balance ${q0} → ${q1}`);
  const a = await one(`select a.status from approval_requests a join stock_transactions t on t.id=a.txn_id where t.notes like 'Self-correction: wrong item scanned (E2E)%'`);
  if (a.status !== 'approved') throw new Error('self-correction not recorded as approved');
  return `balance unchanged at ${q1}`;
});

await p4('language & large text: counter switches to isiZulu + large text, My tasks follows', 'counter@cswms.test', async (page) => {
  await page.goto(BASE + '/me'); await settle(page);
  await page.getByRole('button', { name: 'isiZulu' }).click();
  await page.getByRole('button', { name: 'large', exact: true }).click();
  await settle(page);
  await page.goto(BASE + '/tasks'); await settle(page);
  await page.getByText(/Imisebenzi yami/).first().waitFor();
  const size = await page.evaluate(() => getComputedStyle(document.documentElement).fontSize);
  if (size !== '18px') throw new Error('text size not applied: ' + size);
  await su0(`update app_users set language='en', text_size='normal' where email='counter@cswms.test'`);
  return 'zu, 18px';
});

await p4('setup guide: generate 6 bins in a snake route', 'admin@cswms.test', async (page) => {
  await page.goto(BASE + '/setup/wizard'); await settle(page);
  await page.getByLabel('Prefix').fill('E');
  await page.getByLabel('Aisles').fill('2'); await page.getByLabel('Bays per aisle').fill('3');
  await page.getByRole('button', { name: 'Create 6 bins' }).click();
  await page.getByText(/6 bins created/).waitFor({ timeout: 15000 });
  const r = await one(`select string_agg(code, ',' order by walk_order) c from storage_locations where code like 'E_-0_' and label_code like 'LOC-%'`);
  if (!/E1-01,E1-02,E1-03,E2-03,E2-02,E2-01/.test(r.c)) throw new Error('route ' + r.c);
}, { mobile: false });

await p4('accounting export: Xero CSV for CSA balances', 'admin@cswms.test', async (page) => {
  await page.goto(BASE + '/reports/accounting'); await settle(page);
  await page.locator('label', { hasText: 'Company' }).locator('select').selectOption({ label: 'CSA — CS Alpha (Pty) Ltd' });
  await page.getByLabel('From').fill('2020-01-01');
  await page.getByRole('button', { name: 'Prepare journal' }).click();
  await page.getByText(/journal lines · debits/).waitFor({ timeout: 20000 });
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 20000 }), page.getByRole('button', { name: 'Xero CSV' }).click()]);
  const text = fs.readFileSync(await dl.path(), 'utf8').replace(/^﻿/, '');
  const [head, ...lines] = text.trim().split(/\r?\n/);
  if (head !== '*Narration,*Date,Description,*AccountCode,*TaxRate,*Amount') throw new Error('header ' + head);
  const sum = lines.reduce((s, l) => s + Number(l.split(',').pop()), 0);
  if (Math.abs(sum) > 0.005) throw new Error('journal does not balance: ' + sum);
  return `${lines.length} lines, balanced`;
}, { mobile: false, downloads: true });

// report downloads (Excel + PDF) as head office
{
  const ctx = await browser.newContext({ acceptDownloads: true });
  const page = await ctx.newPage();
  const errs = []; watch(page, errs);
  try {
    await login(page, 'ho@cswms.test');
    await page.goto(BASE + '/reports'); await settle(page);
    for (const kind of ['Excel', 'PDF', 'CSV']) {
      const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 20000 }), page.getByRole('button', { name: kind }).first().click()]);
      const path = await dl.path(); const size = fs.statSync(path).size;
      const head = fs.readFileSync(path).subarray(0, 4).toString('latin1');
      const okFmt = kind === 'Excel' ? head.startsWith('PK') : kind === 'PDF' ? head.startsWith('%PDF') : size > 50;
      results.push({ user: 'ho@cswms.test', page: `export ${kind} (${dl.suggestedFilename()}, ${size} bytes)`, ok: okFmt && size > 200, errors: okFmt ? [] : ['unexpected file format'] });
    }
  } catch (e) { results.push({ user: 'ho@cswms.test', page: 'exports', ok: false, errors: [String(e).slice(0, 400), ...errs] }); }
  await ctx.close();
}

const after = Number((await one(`select coalesce(sum(qty),0) q from stock_balances b join products p on p.id=b.product_id join warehouses w on w.id=b.warehouse_id where p.sku='TAPE-48' and w.code='CPT-MAIN' and b.status='available'`)).q);
const expected = before + 8;
results.push({ user: 'db', page: `CPT-MAIN TAPE-48 balance: ${before} − 1 withdrawn + 2 received − 1 transferred + 10 received on PO − 2 issued to reservation = ${after}`, ok: after === expected, errors: after === expected ? [] : [`expected ${expected}`] });

await browser.close();
await db.end();
const failed = results.filter((r) => !r.ok);
for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.user.padEnd(20)} ${r.page}${r.ok ? '' : '\n        ' + r.errors.join('\n        ')}`);
console.log(`\n${results.length - failed.length} passed, ${failed.length} failed`);
fs.writeFileSync(new URL('./results.json', import.meta.url), JSON.stringify({ at: new Date().toISOString(), results }, null, 2));
process.exit(failed.length ? 1 : 0);
