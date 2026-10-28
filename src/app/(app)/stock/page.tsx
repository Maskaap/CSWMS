'use client';
import Link from 'next/link';
import { Suspense, useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { Search } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Input, PageHeader, Select, Spinner, Table, Td, Th } from '@/components/ui';
import { ExportButtons, Filters, LoadError, Tabs } from '@/components/widgets';
import { useRows } from '@/hooks/use-rows';
import { useAllWarehouses, useCompanies } from '@/hooks/use-ref-data';
import { cleanSearch as clean, fmtDateTime, fmtQty, STATUS_LABELS } from '@/lib/format';
import type { Col } from '@/lib/export';

type ByWh = {
  product_id: string; sku: string; description: string; uom: string; warehouse_id: string; warehouse_code: string; warehouse_name: string;
  branch_code: string; company_code: string; province_name: string; available: number; damaged: number; quarantine: number; in_transit: number;
  reserved: number; free_to_use: number; min_qty: number | null; reorder_qty: number | null; stock_level: string;
};
type ByLoc = {
  product_id: string; sku: string; description: string; uom: string; location_code: string; location_name: string; warehouse_code: string;
  branch_code: string; company_code: string; owner_company_code: string; stored_for_other_company: boolean; status: string; qty: number; updated_at: string;
};

function StockInner() {
  const sp = useSearchParams();
  const { can } = useApp();
  const [view, setView] = useState<'warehouse' | 'location'>('warehouse');
  const [q, setQ] = useState(sp.get('q') ?? '');
  const [dq, setDq] = useState(q);
  const [wh, setWh] = useState('');
  const [company, setCompany] = useState('');
  const [level, setLevel] = useState('');
  const [category, setCategory] = useState('');
  const { data: warehouses } = useAllWarehouses();
  const { data: companies } = useCompanies();
  const cats = useRows<{ id: string; name: string; parent_id: string | null }>('cats', (sb) => sb.from('categories').select('id, name, parent_id').eq('status', 'active').order('name'));

  useEffect(() => { const w = sp.get('warehouse'); if (w && warehouses.length) setWh(warehouses.find((x) => x.warehouse_code === w)?.warehouse_id ?? ''); }, [sp, warehouses]);
  useEffect(() => { const t = setTimeout(() => setDq(q), 300); return () => clearTimeout(t); }, [q]);

  const term = clean(dq);
  const key = `${view}|${term}|${wh}|${company}|${level}|${category}`;
  const byWh = useRows<ByWh>(view === 'warehouse' ? key : null, (sb) => {
    let x = sb.from('v_stock_by_warehouse').select('*', { count: 'exact' }).order('sku').order('warehouse_code').limit(500);
    if (term) x = x.or(`sku.ilike.%${term}%,description.ilike.%${term}%`);
    if (wh) x = x.eq('warehouse_id', wh);
    if (company) x = x.eq('company_id', company);
    if (level) x = x.eq('stock_level', level);
    if (category) x = x.eq('category_id', category);
    return x;
  });
  const byLoc = useRows<ByLoc>(view === 'location' ? key : null, (sb) => {
    let x = sb.from('v_stock_balances').select('*', { count: 'exact' }).neq('qty', 0).order('sku').order('warehouse_code').order('location_code').limit(1000);
    if (term) x = x.or(`sku.ilike.%${term}%,description.ilike.%${term}%`);
    if (wh) x = x.eq('warehouse_id', wh);
    if (company) x = x.eq('owner_company_id', company);
    if (category) x = x.eq('category_id', category);
    return x;
  });

  const whCols: Col<ByWh>[] = useMemo(() => [
    { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'warehouse_code', label: 'Warehouse' },
    { key: 'branch_code', label: 'Branch' }, { key: 'company_code', label: 'Company' }, { key: 'uom', label: 'Unit' },
    { key: 'available', label: 'Available', num: true }, { key: 'reserved', label: 'Reserved', num: true }, { key: 'free_to_use', label: 'Free', num: true },
    { key: 'damaged', label: 'Damaged', num: true }, { key: 'quarantine', label: 'Quarantine', num: true }, { key: 'in_transit', label: 'In transit', num: true },
    { key: 'min_qty', label: 'Minimum', num: true }, { key: 'stock_level', label: 'Level' },
  ], []);
  const locCols: Col<ByLoc>[] = useMemo(() => [
    { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'warehouse_code', label: 'Warehouse' },
    { key: 'location_code', label: 'Location' }, { key: 'owner_company_code', label: 'Owner' }, { key: 'status', label: 'Status' },
    { key: 'qty', label: 'Quantity', num: true }, { key: 'uom', label: 'Unit' }, { key: 'updated_at', label: 'Last movement', get: (r) => fmtDateTime(r.updated_at) },
  ], []);

  if (!can('stock.view')) return <PageHeader title="All stock" description="You do not have permission to view stock." />;
  const active = view === 'warehouse' ? byWh : byLoc;

  return (
    <>
      <PageHeader title="All stock" description="Live balances from the central ledger. Search any product to see exactly where it is and how much is free to use."
        actions={view === 'warehouse' ? <ExportButtons title="Current stock by warehouse" cols={whCols} rows={byWh.rows} /> : <ExportButtons title="Current stock by location" cols={locCols} rows={byLoc.rows} />} />
      <div className="relative mb-4">
        <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-steel-400" />
        <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search by stock code or description" className="h-12 pl-9 text-base" autoFocus aria-label="Search stock" />
      </div>
      <Filters>
        <Select value={wh} onChange={(e) => setWh(e.target.value)} aria-label="Warehouse">
          <option value="">All warehouses</option>
          {warehouses.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.warehouse_code} — {w.warehouse_name} ({w.province_name})</option>)}
        </Select>
        <Select value={company} onChange={(e) => setCompany(e.target.value)} aria-label="Company">
          <option value="">{view === 'warehouse' ? 'All operating companies' : 'All owning companies'}</option>
          {companies.map((c) => <option key={c.id} value={c.id}>{c.code} — {c.name}</option>)}
        </Select>
        <Select value={category} onChange={(e) => setCategory(e.target.value)} aria-label="Category">
          <option value="">All categories</option>
          {cats.rows.map((c) => <option key={c.id} value={c.id}>{c.parent_id ? '— ' : ''}{c.name}</option>)}
        </Select>
        {view === 'warehouse' && (
          <Select value={level} onChange={(e) => setLevel(e.target.value)} aria-label="Stock level">
            <option value="">Any stock level</option><option value="out">Out of stock</option><option value="low">Low stock</option><option value="ok">OK</option>
          </Select>
        )}
      </Filters>
      <Tabs value={view} onChange={setView} tabs={[{ id: 'warehouse', label: 'By warehouse' }, { id: 'location', label: 'By shelf / bin and owner' }]} />
      <LoadError error={active.error} />
      {active.loading ? <Spinner /> : view === 'warehouse' ? (
        <Table>
          <thead><tr><Th>Product</Th><Th>Warehouse</Th><Th right>Available</Th><Th right>Reserved</Th><Th right>Free to use</Th><Th right>Damaged / quar.</Th><Th right>In transit out</Th><Th right>Minimum</Th><Th>Level</Th></tr></thead>
          <tbody>
            {byWh.rows.map((r) => (
              <tr key={r.product_id + r.warehouse_id} className="hover:bg-steel-50">
                <Td><Link href={`/stock/${r.product_id}`} className="hover:underline"><span className="font-mono text-[13px] font-semibold">{r.sku}</span><div className="text-steel-800">{r.description}</div></Link></Td>
                <Td><b>{r.warehouse_code}</b><div className="text-xs text-steel-600">{r.branch_code} · {r.company_code} · {r.province_name}</div></Td>
                <Td right>{fmtQty(r.available)} <span className="text-xs text-steel-600">{r.uom}</span></Td>
                <Td right>{Number(r.reserved) ? fmtQty(r.reserved) : '—'}</Td>
                <Td right className="font-semibold text-navy-900">{fmtQty(r.free_to_use)}</Td>
                <Td right>{Number(r.damaged) + Number(r.quarantine) ? `${fmtQty(r.damaged)} / ${fmtQty(r.quarantine)}` : '—'}</Td>
                <Td right>{Number(r.in_transit) ? fmtQty(r.in_transit) : '—'}</Td>
                <Td right>{r.min_qty != null ? fmtQty(r.min_qty) : '—'}</Td>
                <Td><Badge tone={r.stock_level === 'out' ? 'bad' : r.stock_level === 'low' ? 'warn' : 'ok'}>{r.stock_level === 'out' ? 'Out' : r.stock_level === 'low' ? 'Low' : 'OK'}</Badge></Td>
              </tr>
            ))}
            {byWh.rows.length === 0 && <tr><Td className="text-steel-600">No stock matches.</Td></tr>}
          </tbody>
        </Table>
      ) : (
        <Table>
          <thead><tr><Th>Product</Th><Th>Warehouse</Th><Th>Location</Th><Th>Owner</Th><Th>Status</Th><Th right>Quantity</Th><Th>Last movement</Th></tr></thead>
          <tbody>
            {byLoc.rows.map((r, i) => (
              <tr key={i} className="hover:bg-steel-50">
                <Td><Link href={`/stock/${r.product_id}`} className="hover:underline"><span className="font-mono text-[13px] font-semibold">{r.sku}</span><div className="text-steel-800">{r.description}</div></Link></Td>
                <Td>{r.warehouse_code}<div className="text-xs text-steel-600">{r.branch_code} · {r.company_code}</div></Td>
                <Td mono>{r.location_code}</Td>
                <Td>{r.owner_company_code}{r.stored_for_other_company && <Badge tone="info" className="ml-1">stored for owner</Badge>}</Td>
                <Td><Badge tone={r.status === 'available' ? 'ok' : r.status === 'in_transit' ? 'info' : 'warn'}>{STATUS_LABELS[r.status] ?? r.status}</Badge></Td>
                <Td right className="font-semibold">{fmtQty(r.qty)} <span className="text-xs font-normal text-steel-600">{r.uom}</span></Td>
                <Td className="text-xs text-steel-600">{fmtDateTime(r.updated_at)}</Td>
              </tr>
            ))}
            {byLoc.rows.length === 0 && <tr><Td className="text-steel-600">No stock matches.</Td></tr>}
          </tbody>
        </Table>
      )}
      {active.count != null && active.count > active.rows.length && <p className="mt-2 text-xs text-steel-600">Showing {active.rows.length} of {active.count} rows — refine the search to narrow down.</p>}
    </>
  );
}

export default function StockPage() {
  return <Suspense fallback={<Spinner />}><StockInner /></Suspense>;
}
