'use client';
import Link from 'next/link';
import { useMemo, useState, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { ShoppingCart } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { BarList, Columns, LineChart, ORDINAL, PartsBar, SERIES, Sparkline, compact } from '@/components/charts';
import { Badge, Button, Field, Input, Notice, Panel, Select, Spinner, Stat, Table, Td, Th } from '@/components/ui';
import { ExportButtons, LoadError } from '@/components/widgets';
import { useRpc } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { TxnOutcome } from '@/components/txn-outcome';
import type { Col } from '@/lib/export';
import { fmtDate, fmtDateTime, fmtQty, fmtZAR } from '@/lib/format';

export type Filters = { from: string; to: string; wh: string; company: string; category: string; product: string };
type R = Record<string, any>;

const days = (f: Filters) => Math.max(1, Math.round((Date.parse(f.to) - Date.parse(f.from)) / 864e5) + 1);
const scope = (f: Filters) => ({ p_warehouse: f.wh || null, p_company: f.company || null, p_category: f.category || null });
function useA<T = R[]>(fn: string, args: Record<string, unknown> | null) {
  return useRpc<T>(args ? fn + JSON.stringify(args) : null, fn, args ?? undefined);
}
const zar = (n: number) => fmtZAR(n);
const zarAxis = (n: number) => 'R ' + compact(n);
const num = (v: unknown) => Number(v ?? 0);

/** Holds the previous render (dimmed) while a new slice loads — no layout jump. */
function Loaded({ q, children }: { q: { loading: boolean; error: string | null; data: unknown }; children: ReactNode }) {
  if (q.error) return <LoadError error={q.error} />;
  if (!q.data) return <Spinner />;
  return <div className={q.loading ? 'opacity-50 transition-opacity' : 'transition-opacity'}>{children}</div>;
}

const CLASS_LABEL: Record<string, string> = { fast: 'Fast', medium: 'Medium', slow: 'Slow', non_moving: 'Not moving', dead: 'Dead' };
const CLASSES = ['fast', 'medium', 'slow', 'non_moving', 'dead'];
const RISK: Record<string, { label: string; tone: 'bad' | 'warn' | 'ok' | 'info' | undefined }> = {
  critical: { label: 'Will run out', tone: 'bad' }, warning: { label: 'Below reorder point', tone: 'warn' }, ok: { label: 'OK', tone: 'ok' },
  excess: { label: 'Excess', tone: 'info' }, no_demand: { label: 'No demand', tone: undefined },
};

// ======================================================================= Overview
export function OverviewTab({ f, go }: { f: Filters; go: (t: any) => void }) {
  const { can, me, warehouseId } = useApp();
  const router = useRouter();
  const cost = can('cost.view');
  const fwh = f.wh || ((me?.warehouses ?? []).find((w) => w.id === warehouseId && w.perms.includes('reports.view'))?.id ?? (me?.warehouses ?? []).find((w) => w.perms.includes('reports.view'))?.id ?? '');
  const mv = useA('analytics_movements', { p_from: f.from, p_to: f.to, p_bucket: days(f) > 120 ? 'month' : 'week', ...scope(f) });
  const vel = useA('analytics_velocity', { p_days: Math.max(7, Math.min(730, days(f))), ...scope(f) });
  const age = useA('analytics_ageing', scope(f));
  const fc = useA('analytics_forecast', fwh ? { p_warehouse: fwh, p_horizon: 30, p_category: f.category || null } : null);
  const vt = useA('analytics_valuation_trend', cost ? { p_months: 12, p_warehouse: f.wh || null, p_company: f.company || null } : null);
  const cons = useA('analytics_consumption', { p_from: f.from, p_to: f.to, p_group: 'client', ...scope(f) });
  const v = vel.data ?? [], a = age.data ?? [], fr = fc.data ?? [];
  const dead = v.filter((r) => r.movement_class === 'dead');
  const old = a.reduce((s, r) => s + num(r.value_181_365) + num(r.value_365p), 0);
  const atRisk = fr.filter((r) => r.risk === 'critical');
  const stock = (vt.data ?? []).at(-1)?.value;
  const wcode = (me?.warehouses ?? []).find((w) => w.id === fwh)?.code;
  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-5">
        {cost && <Stat label="Stock value today" value={stock != null ? zar(stock) : '…'} sub="weighted-average cost" />}
        <Stat label="Dead stock" value={vel.data ? (cost ? zar(dead.reduce((s, r) => s + num(r.value_on_hand), 0)) : `${dead.length} items`) : '…'} tone={dead.length ? 'warn' : undefined}
          sub={vel.data ? `${dead.length} item(s) not issued or received for a long time` : undefined} href="/analytics?tab=velocity" />
        {cost && <Stat label="Stock older than 180 days" value={age.data ? zar(old) : '…'} tone={old > 0 ? 'warn' : undefined} href="/analytics?tab=ageing" />}
        <Stat label={`Likely to run out${wcode ? ` (${wcode})` : ''}`} value={fc.data ? atRisk.length : '…'} tone={atRisk.length ? 'bad' : undefined}
          sub="before a reorder could arrive" href="/analytics?tab=forecast" />
        <Stat label="Fast-moving items" value={vel.data ? v.filter((r) => r.movement_class === 'fast').length : '…'} sub={`issued ${'≥'} 8× a month`} href="/analytics?tab=velocity" />
      </div>
      <div className="grid gap-6 xl:grid-cols-2 [&>*]:min-w-0">
        <Panel title="Stock in and consumption">
          <Loaded q={mv}><MovementChart rows={mv.data ?? []} /></Loaded>
        </Panel>
        {cost ? (
          <Panel title="Stock value, last 12 month-ends">
            <Loaded q={vt}><LineChart title="Stock value by month" data={vt.data ?? []} x={(d) => new Date(d.month).toLocaleDateString('en-ZA', { month: 'short', year: '2-digit' })}
              series={[{ key: 'value', label: 'Stock value', color: SERIES[0] }]} format={zar} area /></Loaded>
          </Panel>
        ) : (
          <Panel title="Items likely to run out">
            <Loaded q={fc}><BarList rows={atRisk.map((r) => ({ key: r.product_id, label: `${r.sku} ${r.description}`, value: num(r.days_cover) }))} format={(n) => `${fmtQty(n)} days left`} /></Loaded>
          </Panel>
        )}
        <Panel title="Top jobs / clients by consumption">
          <Loaded q={cons}><BarList rows={(cons.data ?? []).map((r) => ({ key: r.key, label: r.label, value: cost ? num(r.net_value) : num(r.issue_lines) }))}
            format={cost ? zar : (n) => `${n} lines`} max={8} onClick={(k) => router.push(`/analytics/job?ref=${encodeURIComponent(k)}`)} /></Loaded>
        </Panel>
        <Panel title="Movement classes">
          <Loaded q={vel}><PartsBar format={(n) => (cost ? zar(n) : `${n}`)}
            parts={CLASSES.map((c, i) => ({ label: CLASS_LABEL[c], color: ORDINAL[4 - i], value: v.filter((r) => r.movement_class === c).reduce((s, r) => s + (cost ? num(r.value_on_hand) : 1), 0) }))} />
            <p className="mt-3 text-xs text-steel-600">{cost ? 'Value of stock on hand' : 'Number of items'} in each class, based on the selected period. <button className="underline" onClick={() => go('velocity')}>Details</button></p>
          </Loaded>
        </Panel>
      </div>
    </div>
  );
}

function MovementChart({ rows, product }: { rows: R[]; product?: boolean }) {
  const m = rows[0]?.measure ?? 'value';
  const fmt = m === 'value' ? zar : m === 'qty' ? (n: number) => fmtQty(n) : (n: number) => `${n} lines`;
  const daily = rows.length > 1 && Date.parse(rows[1].bucket) - Date.parse(rows[0].bucket) < 2 * 864e5;
  const monthly = rows.length > 1 && Date.parse(rows[1].bucket) - Date.parse(rows[0].bucket) > 20 * 864e5;
  return (
    <>
      <LineChart title="Stock received and consumed" data={rows}
        x={(d) => new Date(d.bucket).toLocaleDateString('en-ZA', monthly ? { month: 'short', year: '2-digit' } : { day: '2-digit', month: 'short' })}
        series={[{ key: 'received', label: 'Received', color: SERIES[0] }, { key: 'net_consumption', label: 'Consumed (issued − returned)', color: SERIES[1] }]}
        format={fmt} />
      <p className="mt-1 text-xs text-steel-600">{m === 'value' ? 'Rand at weighted-average cost' : m === 'qty' ? 'Quantity of the selected product' : 'Number of transaction lines (values hidden for your role)'}{daily ? ', per day' : monthly ? ', per month' : ', per week'}.</p>
    </>
  );
}

// ======================================================================= Movements
export function MovementsTab({ f }: { f: Filters }) {
  const [bucket, setBucket] = useState(days(f) > 200 ? 'month' : 'week');
  const b = bucket === 'day' && days(f) > 180 ? 'week' : bucket;
  const q = useA('analytics_movements', { p_from: f.from, p_to: f.to, p_bucket: b, ...scope(f), p_product: f.product || null });
  const rows = q.data ?? [];
  const m = rows[0]?.measure;
  const cols: Col<R>[] = [{ key: 'bucket', label: b === 'month' ? 'Month' : b === 'week' ? 'Week from' : 'Day', get: (r) => fmtDate(r.bucket) },
    ...['received', 'issued', 'returned', 'net_consumption', 'transfer_in', 'transfer_out', 'adjusted'].map((k) => ({ key: k, label: k.replace('_', ' ').replace(/^./, (c) => c.toUpperCase()) + (m === 'value' ? ' (ZAR)' : m === 'lines' ? ' (lines)' : ''), num: true }))];
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <Field label="Group by" className="w-40"><Select value={bucket} onChange={(e) => setBucket(e.target.value)}><option value="day" disabled={days(f) > 180}>Day</option><option value="week">Week</option><option value="month">Month</option></Select></Field>
        <ExportButtons title="Stock movement trends" rows={rows} cols={cols} />
      </div>
      {f.product && <Notice tone="info">Showing one product (quantities in its base unit).</Notice>}
      <Panel><Loaded q={q}><MovementChart rows={rows} /></Loaded></Panel>
      <Loaded q={q}><DataTable rows={rows} cols={cols} /></Loaded>
    </div>
  );
}

// ======================================================================= Velocity
export function VelocityTab({ f, onProduct }: { f: Filters; onProduct: (id: string) => void }) {
  const { can } = useApp();
  const cost = can('cost.view');
  const d = Math.max(7, Math.min(730, days(f)));
  const q = useA('analytics_velocity', { p_days: d, ...scope(f) });
  const [cls, setCls] = useState('');
  const rows = (q.data ?? []).filter((r) => !cls || r.movement_class === cls || r.abc_class === cls);
  const cols: Col<R>[] = [{ key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'category', label: 'Category' }, { key: 'movement_class', label: 'Class', get: (r) => CLASS_LABEL[r.movement_class] },
    { key: 'abc_class', label: 'ABC' }, { key: 'on_hand', label: 'On hand', num: true }, { key: 'uom', label: 'Unit' }, { key: 'net_issued', label: `Issued (${d} d)`, num: true },
    { key: 'issues_per_month', label: 'Issues / month', num: true }, { key: 'days_cover', label: 'Days of cover', num: true }, { key: 'days_since_issue', label: 'Days since issue', num: true },
    ...(cost ? [{ key: 'value_on_hand', label: 'Value on hand (ZAR)', num: true }, { key: 'issued_value', label: 'Issued value (ZAR)', num: true }] : [])];
  const counts = (k: string, v: string) => (q.data ?? []).filter((r) => r[k] === v).length;
  return (
    <div className="space-y-4">
      <p className="text-sm text-steel-600">Based on issues in the last {d} days. <b>Fast</b> ≥ 8 issues a month, <b>medium</b> ≥ 2, <b>slow</b> fewer; <b>not moving</b> = no issues in the period;
        <b> dead</b> = no issue and no receipt for 180 days (settings <code>analytics.*</code>). <b>A</b> items make up the first 80% of consumption {cost ? 'value' : 'activity'}, <b>B</b> the next 15%, <b>C</b> the rest.</p>
      <div className="flex flex-wrap items-center gap-2">
        {['', ...CLASSES, 'A', 'B', 'C'].map((c) => (
          <button key={c || 'all'} type="button" onClick={() => setCls(c)} className={`rounded-full border px-3 py-1 text-sm ${cls === c ? 'border-navy-900 bg-navy-900 text-white' : 'border-steel-300 bg-white hover:bg-steel-50'}`}>
            {c === '' ? `All (${q.data?.length ?? 0})` : CLASS_LABEL[c] ? `${CLASS_LABEL[c]} (${counts('movement_class', c)})` : `${c} (${counts('abc_class', c)})`}
          </button>))}
        <span className="ml-auto"><ExportButtons title="Fast, slow and dead stock" rows={rows} cols={cols} /></span>
      </div>
      <Loaded q={q}>
        <Table>
          <thead><tr><Th>Item</Th><Th>Class</Th><Th right>On hand</Th><Th right>Issued</Th><Th right>Issues / month</Th><Th right>Days of cover</Th><Th right>Since last issue</Th>{cost && <Th right>Value on hand</Th>}</tr></thead>
          <tbody>{rows.slice(0, 500).map((r) => (
            <tr key={r.product_id} className="hover:bg-steel-50">
              <Td><button type="button" className="text-left hover:underline" onClick={() => onProduct(r.product_id)} title="Show this item's movement trend"><span className="font-mono text-[13px] font-semibold">{r.sku}</span> {r.description}</button>{r.category && <div className="text-xs text-steel-600">{r.category}</div>}</Td>
              <Td><Badge tone={r.movement_class === 'dead' ? 'bad' : r.movement_class === 'non_moving' || r.movement_class === 'slow' ? 'warn' : r.movement_class === 'fast' ? 'ok' : undefined}>{CLASS_LABEL[r.movement_class]}</Badge> <Badge>{r.abc_class}</Badge></Td>
              <Td right>{fmtQty(r.on_hand)} {r.uom}</Td><Td right>{fmtQty(r.net_issued)}</Td><Td right>{fmtQty(r.issues_per_month)}</Td>
              <Td right>{r.days_cover != null ? fmtQty(r.days_cover) : '—'}</Td><Td right>{r.days_since_issue != null ? `${r.days_since_issue} d` : 'never'}</Td>
              {cost && <Td right>{fmtZAR(r.value_on_hand)}</Td>}
            </tr>))}
            {rows.length === 0 && <tr><Td className="text-steel-600">No items in this selection.</Td></tr>}</tbody>
        </Table>
        {rows.length > 500 && <p className="mt-2 text-xs text-steel-600">Showing 500 of {rows.length}; export for the full list.</p>}
      </Loaded>
    </div>
  );
}

// ======================================================================= Ageing
export function AgeingTab({ f }: { f: Filters }) {
  const { can } = useApp();
  const cost = can('cost.view');
  const q = useA('analytics_ageing', scope(f));
  const rows = q.data ?? [];
  const B = [['d0_30', 'value_0_30', '0–30 d'], ['d31_90', 'value_31_90', '31–90 d'], ['d91_180', 'value_91_180', '91–180 d'], ['d181_365', 'value_181_365', '181–365 d'], ['d365p', 'value_365p', '> 1 year']];
  const totals = B.map(([qk, vk, label]) => ({ label, value: cost ? rows.reduce((s, r) => s + num(r[vk]), 0) : rows.filter((r) => num(r[qk]) > 0).length }));
  const cols: Col<R>[] = [{ key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'warehouse_code', label: 'Warehouse' }, { key: 'uom', label: 'Unit' },
    { key: 'on_hand', label: 'On hand', num: true }, ...B.map(([k, , l]) => ({ key: k, label: l, num: true })), { key: 'avg_age_days', label: 'Average age (days)', num: true },
    { key: 'oldest_days', label: 'Oldest (days)', num: true }, ...(cost ? [{ key: 'value', label: 'Value (ZAR)', num: true }, { key: 'value_365p', label: 'Value > 1 year (ZAR)', num: true }] : [])];
  return (
    <div className="space-y-4">
      <p className="text-sm text-steel-600">Age of the stock on hand since it arrived at the warehouse, assuming first-in-first-out (the oldest stock is used first). Stock that keeps getting older is a candidate for using up, transferring or writing off.</p>
      <Panel title={cost ? 'Stock value by age' : 'Items holding stock in each age band'}>
        <Loaded q={q}><Columns cols={totals} format={cost ? (n) => 'R ' + compact(n) : (n) => String(n)} /></Loaded>
      </Panel>
      <div className="flex justify-end"><ExportButtons title="Stock ageing" rows={rows} cols={cols} /></div>
      <Loaded q={q}><DataTable rows={rows} cols={cols} limit={500} /></Loaded>
    </div>
  );
}

// ======================================================================= Consumption
export function ConsumptionTab({ f }: { f: Filters }) {
  const { can } = useApp();
  const router = useRouter();
  const cost = can('cost.view');
  const [group, setGroup] = useState('client');
  const q = useA('analytics_consumption', { p_from: f.from, p_to: f.to, p_group: group, ...scope(f) });
  const rows = q.data ?? [];
  const qty = (r: R) => Object.entries(r.qty_by_uom ?? {}).map(([u, v]) => `${fmtQty(v as number)} ${u}`).join(' · ');
  const cols: Col<R>[] = [{ key: 'label', label: GROUPS[group] }, { key: 'issues', label: 'Issues', num: true }, { key: 'issue_lines', label: 'Lines', num: true },
    { key: 'return_lines', label: 'Return lines', num: true }, { key: 'products', label: 'Products', num: true }, { key: 'qty', label: 'Net quantity per unit', get: qty },
    ...(cost ? [{ key: 'issued_value', label: 'Issued (ZAR)', num: true }, { key: 'returned_value', label: 'Returned (ZAR)', num: true }, { key: 'net_value', label: 'Net consumption (ZAR)', num: true }] : []),
    { key: 'last_at', label: 'Last issue', get: (r) => fmtDateTime(r.last_at) }];
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <Field label="Consumption by" className="w-52"><Select value={group} onChange={(e) => setGroup(e.target.value)}>{Object.entries(GROUPS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        <ExportButtons title={`Consumption by ${GROUPS[group].toLowerCase()}`} rows={rows} cols={cols} />
      </div>
      <Panel title={`Top 10 by ${cost ? 'net consumption value' : 'number of issue lines'}`}>
        <Loaded q={q}><BarList rows={rows.map((r) => ({ key: r.key, label: r.label, value: cost ? num(r.net_value) : num(r.issue_lines) }))} format={cost ? zar : (n) => `${n} lines`}
          onClick={group === 'client' ? (k) => router.push(`/analytics/job?ref=${encodeURIComponent(k)}`) : undefined} /></Loaded>
        {group === 'client' && <p className="mt-2 text-xs text-steel-600">Click a job or client to open its job costing.</p>}
      </Panel>
      <Loaded q={q}>
        <Table>
          <thead><tr><Th>{GROUPS[group]}</Th><Th right>Issues</Th><Th>Net quantity</Th>{cost && <Th right>Issued</Th>}{cost && <Th right>Returned</Th>}{cost && <Th right>Net</Th>}<Th>Last issue</Th></tr></thead>
          <tbody>{rows.slice(0, 500).map((r) => (
            <tr key={r.key}>
              <Td>{group === 'client' && r.key !== '(NO REFERENCE)' ? <Link className="font-medium hover:underline" href={`/analytics/job?ref=${encodeURIComponent(r.key)}`}>{r.label}</Link> : r.label}{r.has_uncosted_items && cost && <div className="text-xs text-warn-600">includes items with no purchase price</div>}</Td>
              <Td right>{r.issues}</Td><Td className="text-xs">{qty(r)}</Td>
              {cost && <Td right>{fmtZAR(r.issued_value)}</Td>}{cost && <Td right>{fmtZAR(r.returned_value)}</Td>}{cost && <Td right className="font-semibold">{fmtZAR(r.net_value)}</Td>}
              <Td className="text-xs">{fmtDateTime(r.last_at)}</Td>
            </tr>))}
            {rows.length === 0 && <tr><Td className="text-steel-600">No issues in this period.</Td></tr>}</tbody>
        </Table>
      </Loaded>
    </div>
  );
}
const GROUPS: Record<string, string> = { client: 'Job / client', company: 'Owning company', branch: 'Branch', warehouse: 'Warehouse', category: 'Category', product: 'Product', reason: 'Reason' };

// ======================================================================= Valuation
export function ValuationTab({ f }: { f: Filters }) {
  const { can } = useApp();
  const [group, setGroup] = useState('company');
  const [asOf, setAsOf] = useState('');
  const ok = can('cost.view');
  const q = useA('analytics_valuation', ok ? { p_as_of: asOf || null, p_group: group, p_warehouse: f.wh || null, p_company: f.company || null } : null);
  const t = useA('analytics_valuation_trend', ok ? { p_months: 12, p_warehouse: f.wh || null, p_company: f.company || null } : null);
  if (!ok) return <Notice tone="info">Inventory valuation is only available to roles that may see purchase prices.</Notice>;
  const rows = q.data ?? [];
  const total = rows.reduce((s, r) => s + num(r.value), 0);
  const uncosted = rows.reduce((s, r) => s + num(r.uncosted_products), 0);
  const cols: Col<R>[] = [{ key: 'label', label: VGROUPS[group] }, { key: 'products', label: 'Products', num: true }, { key: 'qty', label: 'Quantity per unit', get: (r) => Object.entries(r.qty_by_uom ?? {}).map(([u, v]) => `${fmtQty(v as number)} ${u}`).join(' · ') },
    { key: 'value', label: 'Value (ZAR)', num: true }, { key: 'products_at_last_price', label: 'Valued at last price', num: true }, { key: 'uncosted_products', label: 'No price', num: true }];
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <Field label="Value by" className="w-48"><Select value={group} onChange={(e) => setGroup(e.target.value)}>{Object.entries(VGROUPS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        <Field label="As at (end of day)" className="w-44"><Input type="date" value={asOf} max={new Date().toISOString().slice(0, 10)} onChange={(e) => setAsOf(e.target.value)} /></Field>
        <span className="ml-auto"><ExportButtons title={`Inventory valuation ${asOf ? 'at ' + fmtDate(asOf) : 'today'}`} rows={rows} cols={cols} /></span>
      </div>
      <div className="grid gap-3 sm:grid-cols-3">
        <Stat label={asOf ? `Stock value at ${fmtDate(asOf)}` : 'Stock value today'} value={q.data ? zar(total) : '…'} sub="weighted-average purchase cost" />
        <Stat label="Products without a price" value={q.data ? uncosted : '…'} tone={uncosted ? 'warn' : undefined} sub="valued at R0 — add prices under Products" />
      </div>
      <div className="grid gap-6 xl:grid-cols-2 [&>*]:min-w-0">
        <Panel title="Month-end stock value"><Loaded q={t}><LineChart title="Month-end stock value" data={t.data ?? []} area
          x={(d) => new Date(d.month).toLocaleDateString('en-ZA', { month: 'short', year: '2-digit' })} format={zar}
          series={[{ key: 'value', label: 'Stock value', color: SERIES[0] }]} /></Loaded></Panel>
        <Panel title={`Value by ${VGROUPS[group].toLowerCase()}`}><Loaded q={q}><BarList rows={rows.map((r) => ({ key: r.key, label: r.label, value: num(r.value) }))} format={zar} /></Loaded></Panel>
      </div>
      <Loaded q={q}><DataTable rows={rows} cols={cols} limit={500} /></Loaded>
      <p className="text-xs text-steel-600">Method: each product is valued at the weighted-average cost of all its costed receipts and opening balances up to the date; products never received with a price use their last purchase price; products with neither show as “no price”. Damaged, quarantined and in-transit stock are included (use “Value by → Stock status” to separate them).</p>
    </div>
  );
}
const VGROUPS: Record<string, string> = { company: 'Owning company', branch: 'Branch', warehouse: 'Warehouse', category: 'Category', product: 'Product', status: 'Stock status' };

// ======================================================================= Forecast
export function ForecastTab({ f }: { f: Filters }) {
  const { can, me, warehouseId } = useApp();
  const router = useRouter();
  const mine = (me?.warehouses ?? []).filter((w) => w.perms.includes('reports.view'));
  const [whSel, setWh] = useState('');
  const wh = f.wh || whSel || (mine.find((w) => w.id === warehouseId) ?? mine[0])?.id || '';
  const [h, setH] = useState(30);
  const [risk, setRisk] = useState('');
  const q = useA('analytics_forecast', wh ? { p_warehouse: wh, p_horizon: h, p_category: f.category || null } : null);
  const all = q.data ?? [];
  const rows = all.filter((r) => !risk || r.risk === risk);
  const [sel, setSel] = useState<Record<string, boolean>>({});
  const po = useTransaction('create_po_from_suggestions');
  const canBuy = can('purchase.manage', wh);
  const chosen = all.filter((r) => sel[r.product_id] && num(r.suggested_order_now) > 0);
  const cols: Col<R>[] = [{ key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'uom', label: 'Unit' }, { key: 'risk', label: 'Status', get: (r) => RISK[r.risk]?.label },
    { key: 'trend', label: 'Trend' }, { key: 'daily_demand', label: 'Daily demand', num: true }, { key: 'forecast_qty', label: `Forecast ${h} d`, num: true }, { key: 'free', label: 'Free stock', num: true },
    { key: 'on_order', label: 'On order', num: true }, { key: 'days_cover', label: 'Days of cover', num: true }, { key: 'stockout_date', label: 'Runs out', get: (r) => fmtDate(r.stockout_date) },
    { key: 'lead_time_days', label: 'Lead time (d)', num: true }, { key: 'lead_time_source', label: 'Lead time from' }, { key: 'safety_stock', label: 'Safety stock', num: true },
    { key: 'reorder_point', label: 'Reorder point', num: true }, { key: 'current_min', label: 'Current minimum', num: true }, { key: 'suggested_min', label: 'Suggested minimum', num: true },
    { key: 'suggested_order_now', label: 'Suggested order now', num: true }];
  const counts = (k: string) => all.filter((r) => r.risk === k).length;
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        {!f.wh && <Field label="Warehouse" className="w-56"><Select value={wh} onChange={(e) => setWh(e.target.value)}>{mine.map((w) => <option key={w.id} value={w.id}>{w.code} — {w.name}</option>)}</Select></Field>}
        <Field label="Forecast horizon" className="w-40"><Select value={h} onChange={(e) => setH(Number(e.target.value))}>{[30, 60, 90, 180].map((d) => <option key={d} value={d}>{d} days</option>)}</Select></Field>
        <span className="ml-auto"><ExportButtons title="Demand forecast and stock-out prediction" rows={rows} cols={cols} /></span>
      </div>
      <p className="text-sm text-steel-600">Demand per 30-day period over the last year (issues less returns), projected with damped-trend exponential smoothing. <b>Will run out</b> = free stock plus open orders will not last until a new order could arrive (lead time from this item's or its supplier's purchase orders, else the default lead time set by your administrator). Safety stock covers demand swings at a 95% service level. Items predicted to run out also raise a daily alert.</p>
      <div className="flex flex-wrap gap-2">
        {['', 'critical', 'warning', 'ok', 'excess', 'no_demand'].map((k) => (
          <button key={k || 'all'} type="button" onClick={() => setRisk(k)} className={`rounded-full border px-3 py-1 text-sm ${risk === k ? 'border-navy-900 bg-navy-900 text-white' : 'border-steel-300 bg-white hover:bg-steel-50'}`}>
            {k ? `${RISK[k].label} (${counts(k)})` : `All (${all.length})`}
          </button>))}
      </div>
      <Loaded q={q}>
        <Table>
          <thead><tr>{canBuy && <Th />}<Th>Item</Th><Th>Last 12 periods → next 3</Th><Th right>Daily demand</Th><Th right>Free / on order</Th><Th right>Days of cover</Th><Th>Runs out</Th><Th right>Lead time</Th><Th right>Min: now → suggested</Th><Th right>Order now</Th></tr></thead>
          <tbody>{rows.map((r) => (
            <tr key={r.product_id}>
              {canBuy && <Td>{num(r.suggested_order_now) > 0 && <input type="checkbox" aria-label={`Order ${r.sku}`} checked={!!sel[r.product_id]} onChange={(e) => setSel({ ...sel, [r.product_id]: e.target.checked })} />}</Td>}
              <Td><span className="font-mono text-[13px] font-semibold">{r.sku}</span> {r.description}<div className="mt-0.5"><Badge tone={RISK[r.risk]?.tone}>{RISK[r.risk]?.label}</Badge> <span className="text-xs text-steel-600">{r.trend}</span></div></Td>
              <Td><Sparkline history={(r.history ?? []).map(Number)} forecast={(r.forecast_periods ?? []).map(Number)} /></Td>
              <Td right>{fmtQty(r.daily_demand)} {r.uom}</Td>
              <Td right>{fmtQty(r.free)} / {fmtQty(r.on_order)}</Td>
              <Td right className={r.risk === 'critical' ? 'font-semibold text-bad-600' : ''}>{r.days_cover != null ? fmtQty(r.days_cover) : '—'}</Td>
              <Td>{fmtDate(r.stockout_date)}</Td>
              <Td right>{fmtQty(r.lead_time_days)} d<div className="text-xs text-steel-600">{r.lead_time_source}</div></Td>
              <Td right>{r.current_min != null ? fmtQty(r.current_min) : '—'} → <b>{fmtQty(r.suggested_min)}</b></Td>
              <Td right className="font-semibold">{num(r.suggested_order_now) > 0 ? `${fmtQty(r.suggested_order_now)} ${r.uom}` : '—'}</Td>
            </tr>))}
            {rows.length === 0 && <tr><Td className="text-steel-600">Nothing in this selection.</Td></tr>}</tbody>
        </Table>
      </Loaded>
      {canBuy && (
        <div className="flex flex-wrap items-center gap-3">
          <Button variant="primary" disabled={chosen.length === 0} busy={po.state.phase === 'saving'} onClick={async () => {
            const r = await po.run({ p_warehouse_id: wh, p_items: chosen.map((c) => ({ product_id: c.product_id, qty: num(c.suggested_order_now) })) });
            if (r && Number(r.created) === 1) router.push(`/purchasing/${(r.purchase_orders as { po_id: string }[])[0].po_id}`);
          }}><ShoppingCart className="size-4" />Create draft purchase orders ({chosen.length})</Button>
          <span className="text-xs text-steel-600">Uses each item&apos;s default supplier and last price; drafts still go through approval.</span>
          <TxnOutcome state={po.state} onRetry={po.retry} savedText={(r) => <>Created {String(r.created)} draft purchase order(s). <Link className="underline" href="/purchasing">Review the drafts</Link>.</>} />
        </div>
      )}
    </div>
  );
}

// ======================================================================= Performance
export function PerformanceTab({ f }: { f: Filters }) {
  const { can } = useApp();
  const cost = can('cost.view');
  const q = useA('analytics_performance', { p_from: f.from, p_to: f.to, p_company: f.company || null });
  const s = useA('analytics_supplier_performance', { p_from: f.from, p_to: f.to });
  const rows = useMemo(() => (q.data ?? []).filter((r) => !f.wh || r.warehouse_id === f.wh), [q.data, f.wh]);
  const pct = (v: unknown) => (v == null ? '—' : `${fmtQty(v as number)}%`);
  const cols: Col<R>[] = [{ key: 'warehouse_code', label: 'Warehouse' }, { key: 'branch_code', label: 'Branch' }, { key: 'company_code', label: 'Company' },
    { key: 'transactions', label: 'Transactions', num: true }, { key: 'withdrawals', label: 'Withdrawals', num: true }, { key: 'receipts', label: 'Receipts', num: true },
    { key: 'corrections', label: 'Corrections', num: true }, { key: 'correction_rate_pct', label: 'Correction rate %', num: true }, { key: 'unusual_withdrawals', label: 'Unusual withdrawals', num: true },
    ...(cost ? [{ key: 'issued_value', label: 'Consumed (ZAR)', num: true }, { key: 'stock_value_end', label: 'Stock value end (ZAR)', num: true }, { key: 'turnover_annualised', label: 'Turnover / year', num: true }, { key: 'days_of_stock', label: 'Days of stock', num: true }] : []),
    { key: 'count_accuracy_pct', label: 'Count accuracy %', num: true }, { key: 'counted_lines', label: 'Lines counted', num: true }, ...(cost ? [{ key: 'variance_value', label: 'Count variance (ZAR)', num: true }] : []),
    { key: 'po_on_time_pct', label: 'PO on time %', num: true }, { key: 'avg_lead_days', label: 'Avg lead (days)', num: true }, { key: 'avg_approval_hours', label: 'Avg approval (hours)', num: true },
    { key: 'stockout_alerts', label: 'Out-of-stock alerts', num: true }, { key: 'integrity_findings', label: 'Integrity findings', num: true }];
  const scols: Col<R>[] = [{ key: 'supplier', label: 'Supplier' }, { key: 'orders', label: 'Orders', num: true }, { key: 'delivered', label: 'Delivered', num: true }, { key: 'complete', label: 'Complete', num: true },
    { key: 'closed_short', label: 'Closed short', num: true }, { key: 'cancelled', label: 'Cancelled', num: true }, { key: 'on_time_pct', label: 'On time %', num: true }, { key: 'fill_rate_pct', label: 'Fill rate %', num: true },
    { key: 'avg_lead_days', label: 'Avg lead (days)', num: true }, ...(cost ? [{ key: 'value', label: 'Ordered (ZAR)', num: true }] : []), { key: 'last_order_at', label: 'Last order', get: (r) => fmtDate(r.last_order_at) }];
  return (
    <div className="space-y-6">
      <Panel title="Warehouse performance" padded={false} actions={<ExportButtons title="Warehouse performance" rows={rows} cols={cols} />}>
        <Loaded q={q}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>Warehouse</Th><Th right>Transactions</Th><Th right>Correction rate</Th>{cost && <Th right>Turnover / yr</Th>}{cost && <Th right>Days of stock</Th>}<Th right>Count accuracy</Th><Th right>PO on time</Th><Th right>Avg approval</Th><Th right>Out-of-stock alerts</Th><Th right>Integrity findings</Th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.warehouse_id}><Td><b>{r.warehouse_code}</b> <span className="text-steel-600">{r.warehouse_name}</span><div className="text-xs text-steel-600">{r.branch_code} · {r.company_code}</div></Td>
                <Td right>{r.transactions}</Td><Td right>{pct(r.correction_rate_pct)}</Td>
                {cost && <Td right>{r.turnover_annualised != null ? `${fmtQty(r.turnover_annualised)}×` : '—'}</Td>}{cost && <Td right>{r.days_of_stock ?? '—'}</Td>}
                <Td right>{pct(r.count_accuracy_pct)}</Td><Td right>{pct(r.po_on_time_pct)}</Td><Td right>{r.avg_approval_hours != null ? `${fmtQty(r.avg_approval_hours)} h` : '—'}</Td>
                <Td right>{r.stockout_alerts}</Td><Td right className={r.critical_findings ? 'font-semibold text-bad-600' : ''}>{r.integrity_findings}</Td></tr>))}
            </tbody>
          </Table>
        </Loaded>
      </Panel>
      {cost && <Panel title="Stock turnover per year (higher = stock works harder)"><Loaded q={q}>
        <BarList rows={rows.filter((r) => r.turnover_annualised != null).sort((a, b) => num(b.turnover_annualised) - num(a.turnover_annualised)).map((r) => ({ key: r.warehouse_id, label: r.warehouse_code, value: num(r.turnover_annualised) }))} format={(n) => `${fmtQty(n)}×`} />
      </Loaded></Panel>}
      <Panel title="Supplier scorecard" padded={false} actions={<ExportButtons title="Supplier scorecard" rows={s.data ?? []} cols={scols} />}>
        <Loaded q={s}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>Supplier</Th><Th right>Orders</Th><Th right>On time</Th><Th right>Fill rate</Th><Th right>Avg lead time</Th>{cost && <Th right>Ordered</Th>}<Th>Last order</Th></tr></thead>
            <tbody>{(s.data ?? []).map((r) => (
              <tr key={r.supplier_id}><Td>{r.supplier}</Td><Td right>{r.orders}{r.closed_short ? <div className="text-xs text-warn-600">{r.closed_short} closed short</div> : null}</Td>
                <Td right>{pct(r.on_time_pct)}</Td><Td right>{pct(r.fill_rate_pct)}</Td><Td right>{r.avg_lead_days != null ? `${fmtQty(r.avg_lead_days)} d` : '—'}</Td>
                {cost && <Td right>{fmtZAR(r.value)}</Td>}<Td>{fmtDate(r.last_order_at)}</Td></tr>))}
              {(s.data ?? []).length === 0 && <tr><Td className="text-steel-600">No purchase orders approved in this period.</Td></tr>}</tbody>
          </Table>
        </Loaded>
      </Panel>
      <p className="text-xs text-steel-600">Turnover = consumption value ÷ average stock value, annualised. Count accuracy = counted stocktake lines with no variance. PO on time = first delivery by the expected date plus the grace days. Correction rate = adjustments, reversals and write-offs as a share of all transactions.</p>
    </div>
  );
}

// ----------------------------------------------------------------------- shared table view
function DataTable({ rows, cols, limit = 1000 }: { rows: R[]; cols: Col<R>[]; limit?: number }) {
  return (
    <>
      <Table>
        <thead><tr>{cols.map((c) => <Th key={c.key} right={c.num}>{c.label}</Th>)}</tr></thead>
        <tbody>{rows.slice(0, limit).map((r, i) => (
          <tr key={i}>{cols.map((c) => {
            const v = c.get ? c.get(r) : r[c.key];
            return <Td key={c.key} right={c.num} className={c.num ? 'tabular-nums' : ['sku', 'warehouse_code', 'bucket'].includes(c.key) ? 'whitespace-nowrap font-mono text-[13px]' : ''}>{c.num ? (v == null ? '—' : /ZAR/.test(c.label) ? fmtZAR(v as number) : fmtQty(v as number)) : (v as ReactNode) ?? ''}</Td>;
          })}</tr>))}
          {rows.length === 0 && <tr><Td className="text-steel-600">No data for this selection.</Td></tr>}</tbody>
      </Table>
      {rows.length > limit && <p className="mt-2 text-xs text-steel-600">Showing {limit} of {rows.length}; export for the full list.</p>}
    </>
  );
}
