'use client';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowDownToLine, ArrowUpFromLine, ClipboardCheck, ScanLine, Search } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { IntegrityLamp, type IntegrityStatus } from '@/components/integrity-lamp';
import { Badge, Input, PageHeader, Panel, Spinner, Stat, Table, Td, Th } from '@/components/ui';
import { callRpc } from '@/hooks/use-transaction';
import { supabaseBrowser } from '@/lib/supabase/client';
import { fmtDateTime, fmtQty } from '@/lib/format';

type Dash = {
  scope_warehouses: number; active_products: number; products_in_stock: number;
  by_company: { code: string; name: string; products: number; locations: number; qty_by_uom: Record<string, number> | null }[];
  by_province: { province: string; products: number; warehouses: number }[];
  by_branch: { branch: string; name: string; company: string; products: number }[];
  by_warehouse: { warehouse: string; name: string; branch: string; products: number; damaged_lines: number; in_transit_lines: number }[];
  low_stock: number; out_of_stock: number; outstanding_transfers: number; overdue_transfers: number;
  pending_approvals: number; my_pending_requests: number;
  recent_withdrawals: { txn_id: string; txn_no: string; at: string; warehouse: string; reference: string | null; by: string; unusual: boolean; items: string }[];
  stocktake: { period: string; total: number; finalised: number; in_progress: number; not_started: number; overdue: number; warehouses_without_stocktake: number };
  stocktake_discrepancies: number;
  integrity: IntegrityStatus | null;
  open_alerts: Record<string, number>;
};

export default function DashboardPage() {
  const { me, can } = useApp();
  const router = useRouter();
  const [d, setD] = useState<Dash | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [q, setQ] = useState('');

  useEffect(() => {
    callRpc<Dash>('dashboard_summary').then(({ data, error }) => { if (error) setErr(error.message); else setD(data); });
  }, []);

  const quick = [
    can('stock.receive') && { href: '/receive', label: 'Receive stock', Icon: ArrowDownToLine },
    can('stock.withdraw') && { href: '/withdraw', label: 'Withdraw stock', Icon: ArrowUpFromLine },
    can('stock.view') && { href: '/scan', label: 'Look up an item', Icon: ScanLine },
    (can('stocktake.count') || can('stocktake.manage')) && { href: '/stocktake', label: 'Stocktake counting', Icon: ClipboardCheck },
  ].filter(Boolean) as { href: string; label: string; Icon: typeof ScanLine }[];

  return (
    <>
      <PageHeader title={`Good day, ${me?.user?.full_name?.split(' ')[0] ?? ''}`} description="What needs attention across the warehouses you are responsible for." />

      {quick.length > 0 && (
        <div className="mb-6 grid grid-cols-2 gap-3 md:grid-cols-4">
          {quick.map(({ href, label, Icon }) => (
            <Link key={href} href={href} className="flex items-center gap-3 rounded-lg border border-steel-200 bg-white p-4 font-medium text-navy-900 hover:border-signal-400 hover:bg-signal-50">
              <span className="grid size-10 place-items-center rounded-md bg-signal-400 text-navy-950"><Icon className="size-5" /></span>{label}
            </Link>
          ))}
        </div>
      )}

      {can('stock.view') && (
        <form className="mb-6 flex gap-2" onSubmit={(e) => { e.preventDefault(); router.push('/stock?q=' + encodeURIComponent(q)); }}>
          <div className="relative flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-steel-400" />
            <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Where is it? Search any product by code, description or category" className="h-12 pl-9 text-base" />
          </div>
        </form>
      )}

      {err && <p className="text-bad-600">{err}</p>}
      {!d && !err && <Spinner />}
      {d && (
        <div className="space-y-6">
          {d.integrity && <IntegrityLamp s={d.integrity} />}

          <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
            <Stat label="Active products" value={fmtQty(d.active_products)} sub={`${fmtQty(d.products_in_stock)} in stock in your scope`} href="/stock" />
            <Stat label="Low stock" value={d.low_stock} tone={d.low_stock ? 'warn' : undefined} href="/alerts" />
            <Stat label="Out of stock" value={d.out_of_stock} tone={d.out_of_stock ? 'bad' : undefined} href="/alerts" />
            <Stat label="Transfers in transit" value={d.outstanding_transfers} tone={d.overdue_transfers ? 'warn' : undefined} sub={d.overdue_transfers ? `${d.overdue_transfers} overdue` : 'none overdue'} href="/transfers" />
            <Stat label="Waiting for your approval" value={d.pending_approvals} tone={d.pending_approvals ? 'warn' : undefined} sub={d.my_pending_requests ? `${d.my_pending_requests} of your requests pending` : undefined} href="/approvals" />
            <Stat label={`Stocktakes ${d.stocktake.period}`} value={`${d.stocktake.finalised}/${d.stocktake.total}`} tone={d.stocktake.overdue ? 'bad' : d.stocktake.warehouses_without_stocktake ? 'warn' : undefined}
              sub={d.stocktake.overdue ? `${d.stocktake.overdue} overdue` : d.stocktake.warehouses_without_stocktake ? `${d.stocktake.warehouses_without_stocktake} warehouse(s) not scheduled` : `${d.stocktake_discrepancies} discrepancy lines in review`} href="/stocktake" />
          </div>

          <OpsStats />

          <div className="grid gap-6 xl:grid-cols-2">
            <Panel title="Stock by company (owner)" padded={false}>
              <Table className="rounded-none border-0">
                <thead><tr><Th>Company</Th><Th right>Products</Th><Th right>Locations</Th><Th>Available quantity per unit</Th></tr></thead>
                <tbody>
                  {d.by_company.map((c) => (
                    <tr key={c.code}><Td><b>{c.code}</b> <span className="text-steel-600">{c.name}</span></Td><Td right>{c.products}</Td><Td right>{c.locations}</Td>
                      <Td><div className="flex flex-wrap gap-1">{Object.entries(c.qty_by_uom ?? {}).map(([u, q]) => <Badge key={u} tone="info">{fmtQty(q)} {u}</Badge>)}</div></Td></tr>
                  ))}
                  {d.by_company.length === 0 && <tr><Td className="text-steel-600">No stock recorded yet.</Td></tr>}
                </tbody>
              </Table>
              <p className="px-4 py-2 text-xs text-steel-600">Quantities in different units are never added together.</p>
            </Panel>

            <Panel title="Recent withdrawals" padded={false}>
              <ul className="divide-y divide-steel-100">
                {d.recent_withdrawals.map((w) => (
                  <li key={w.txn_id} className="px-4 py-2 text-sm">
                    <Link href={`/transactions/${w.txn_id}`} className="flex flex-wrap items-baseline justify-between gap-2 hover:underline">
                      <span><span className="font-mono text-[13px]">{w.txn_no}</span> · {w.items}</span>
                      <span className="text-xs text-steel-600">{w.warehouse} · {w.by} · {fmtDateTime(w.at)} {w.unusual && <Badge tone="warn">unusual</Badge>}</span>
                    </Link>
                    {w.reference && <div className="text-xs text-steel-600">For: {w.reference}</div>}
                  </li>
                ))}
                {d.recent_withdrawals.length === 0 && <li className="px-4 py-3 text-sm text-steel-600">No withdrawals yet.</li>}
              </ul>
            </Panel>

            <Panel title="Stock by province" padded={false}>
              <Table className="rounded-none border-0">
                <thead><tr><Th>Province</Th><Th right>Warehouses</Th><Th right>Products in stock</Th></tr></thead>
                <tbody>{d.by_province.map((p) => <tr key={p.province}><Td>{p.province}</Td><Td right>{p.warehouses}</Td><Td right>{p.products}</Td></tr>)}</tbody>
              </Table>
            </Panel>

            <Panel title="Stock by branch and warehouse" padded={false}>
              <Table className="rounded-none border-0">
                <thead><tr><Th>Warehouse</Th><Th>Branch</Th><Th right>Products</Th><Th right>Damaged lines</Th><Th right>Incoming (in transit)</Th></tr></thead>
                <tbody>{d.by_warehouse.map((w) => (
                  <tr key={w.warehouse}><Td><Link className="hover:underline" href={`/stock?warehouse=${w.warehouse}`}><b>{w.warehouse}</b> {w.name}</Link></Td><Td>{w.branch}</Td><Td right>{w.products}</Td><Td right>{w.damaged_lines}</Td><Td right>{w.in_transit_lines}</Td></tr>
                ))}</tbody>
              </Table>
            </Panel>
          </div>
        </div>
      )}
    </>
  );
}

/** Phase 2: purchasing and tools at a glance (counts respect row-level security). */
function OpsStats() {
  const { can } = useApp();
  const showPo = can('purchase.manage') || can('purchase.approve') || can('stock.receive');
  const showAssets = can('asset.checkout') || can('asset.manage');
  const [c, setC] = useState<Record<string, number | null>>({});
  useEffect(() => {
    const sb = supabaseBrowser();
    const n = async (k: string, q: PromiseLike<{ count: number | null }>) => { const { count } = await q; setC((x) => ({ ...x, [k]: count })); };
    if (showPo) {
      n('toReceive', sb.from('v_purchase_orders').select('id', { count: 'exact', head: true }).in('status', ['approved', 'sent', 'partially_received']));
      n('poOverdue', sb.from('v_purchase_orders').select('id', { count: 'exact', head: true }).eq('is_overdue', true));
      n('drafts', sb.from('purchase_orders').select('id', { count: 'exact', head: true }).eq('status', 'draft'));
    }
    if (showAssets) {
      n('out', sb.from('assets').select('id', { count: 'exact', head: true }).eq('status', 'checked_out'));
      n('assetOverdue', sb.from('v_assets').select('id', { count: 'exact', head: true }).eq('is_overdue', true));
      n('repair', sb.from('assets').select('id', { count: 'exact', head: true }).in('status', ['in_repair', 'lost']));
    }
  }, [showPo, showAssets]);
  if (!showPo && !showAssets) return null;
  const v = (k: string) => c[k] ?? '…';
  return (
    <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
      {showPo && <>
        <Stat label="Orders to receive" value={v('toReceive')} href="/purchasing" />
        <Stat label="Orders overdue" value={v('poOverdue')} tone={c.poOverdue ? 'warn' : undefined} href="/purchasing" />
        <Stat label="Draft orders" value={v('drafts')} sub="not yet submitted" href="/purchasing" />
      </>}
      {showAssets && <>
        <Stat label="Tools checked out" value={v('out')} href="/assets" />
        <Stat label="Tools overdue" value={v('assetOverdue')} tone={c.assetOverdue ? 'bad' : undefined} href="/assets" />
        <Stat label="In repair / lost" value={v('repair')} tone={c.repair ? 'warn' : undefined} href="/assets" />
      </>}
    </div>
  );
}
