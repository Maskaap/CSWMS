'use client';
import Link from 'next/link';
import { useState } from 'react';
import { MapPin } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { ProductPicker } from '@/components/product-picker';
import { Badge, PageHeader, Panel, Table, Td, Th } from '@/components/ui';
import { useRows } from '@/hooks/use-rows';
import { fmtQty, STATUS_LABELS } from '@/lib/format';
import type { LookupResult, ProductLookup } from '@/lib/types';

type Loc = Extract<LookupResult, { kind: 'location' }>['location'];

/** Look up an item or a shelf: scan a product to see where it is, or a location label to see what is on it. */
export default function ScanPage() {
  const { warehouse, warehouseId } = useApp();
  const [p, setP] = useState<ProductLookup | null>(null);
  const [loc, setLoc] = useState<Loc | null>(null);
  const contents = useRows<Record<string, any>>(loc ? 'loc' + loc.id : null, (sb) =>
    sb.from('v_stock_balances').select('*').eq('location_id', loc!.id).neq('qty', 0).order('sku'));
  const elsewhere = useRows<Record<string, any>>(p ? 'else' + p.product.id : null, (sb) =>
    sb.from('v_stock_by_warehouse').select('warehouse_id, warehouse_code, warehouse_name, branch_name, available, free_to_use, uom').eq('product_id', p!.product.id).gt('available', 0).order('warehouse_code'));

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="Look up" description={`Scan a product to see its stock, or a shelf / bin label to see what is stored there. Working in ${warehouse?.code ?? '—'}.`} />
      <ProductPicker warehouseId={warehouseId} big onProduct={(x) => { setP(x); setLoc(null); }} onLocation={(l) => { setLoc(l); setP(null); }} />

      {p && (
        <Panel className="mt-4" title={<span><span className="font-mono">{p.product.sku}</span> — {p.product.description}</span>}
          actions={<Link className="text-sm underline" href={`/stock/${p.product.id}`}>Full details</Link>}>
          <div className="grid gap-3 sm:grid-cols-3">
            <div className="rounded-md bg-steel-50 p-3"><div className="text-xs text-steel-600">Available here</div><div className="text-2xl font-bold tabular-nums">{fmtQty(p.warehouse_available)} <span className="text-base font-medium">{p.product.base_uom.code}</span></div></div>
            <div className="rounded-md bg-steel-50 p-3"><div className="text-xs text-steel-600">Reserved</div><div className="text-2xl font-bold tabular-nums">{fmtQty(p.reserved)}</div></div>
            <div className="rounded-md bg-steel-50 p-3"><div className="text-xs text-steel-600">Minimum / reorder</div><div className="text-2xl font-bold tabular-nums">{p.threshold ? `${fmtQty(p.threshold.min_qty)} / ${fmtQty(p.threshold.reorder_qty)}` : '—'}</div></div>
          </div>
          <h3 className="mt-4 mb-2 text-sm font-semibold text-navy-900">Locations in {warehouse?.code}</h3>
          <Table>
            <thead><tr><Th>Location</Th><Th>Owner</Th><Th>Status</Th><Th right>Quantity</Th></tr></thead>
            <tbody>
              {p.balances.map((b, i) => <tr key={i}><Td mono>{b.location_code}</Td><Td>{b.owner_company_code}</Td><Td>{STATUS_LABELS[b.status] ?? b.status}</Td><Td right className="font-semibold">{fmtQty(b.qty)} {p.product.base_uom.code}</Td></tr>)}
              {p.balances.length === 0 && <tr><Td className="text-steel-600">None in this warehouse.</Td></tr>}
            </tbody>
          </Table>
          {elsewhere.rows.filter((r) => r.warehouse_id !== warehouseId).length > 0 && (
            <>
              <h3 className="mt-4 mb-2 text-sm font-semibold text-navy-900">Other warehouses you can see</h3>
              <ul className="space-y-1 text-sm">
                {elsewhere.rows.filter((r) => r.warehouse_id !== warehouseId).map((r) => (
                  <li key={r.warehouse_id} className="flex justify-between border-b border-steel-100 py-1"><span><b>{r.warehouse_code}</b> {r.warehouse_name} · {r.branch_name}</span><span className="tabular-nums">{fmtQty(r.free_to_use)} free</span></li>
                ))}
              </ul>
            </>
          )}
        </Panel>
      )}

      {loc && (
        <Panel className="mt-4" title={<span className="flex items-center gap-2"><MapPin className="size-4" />{loc.warehouse_code} / <span className="font-mono">{loc.code}</span> — {loc.name}</span>}>
          {!loc.in_selected_warehouse && <p className="mb-2 text-sm text-warn-600">This location is in another warehouse than the one you are working in.</p>}
          <Table>
            <thead><tr><Th>Product</Th><Th>Owner</Th><Th>Status</Th><Th right>Quantity</Th></tr></thead>
            <tbody>
              {contents.rows.map((r, i) => (
                <tr key={i}><Td><Link href={`/stock/${r.product_id}`} className="hover:underline"><span className="font-mono text-[13px]">{r.sku}</span> {r.description}</Link></Td>
                  <Td>{r.owner_company_code}</Td><Td><Badge tone={r.status === 'available' ? 'ok' : 'warn'}>{STATUS_LABELS[r.status] ?? r.status}</Badge></Td>
                  <Td right className="font-semibold">{fmtQty(r.qty)} {r.uom}</Td></tr>
              ))}
              {!contents.loading && contents.rows.length === 0 && <tr><Td className="text-steel-600">Empty — no stock recorded at this location.</Td></tr>}
            </tbody>
          </Table>
        </Panel>
      )}
    </div>
  );
}
