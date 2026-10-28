'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useApp } from '@/components/app-context';
import { Badge, Button, Input, Notice, PageHeader, Spinner, Table, Td, Th } from '@/components/ui';
import { LoadError } from '@/components/widgets';
import { useRows } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { TxnOutcome } from '@/components/txn-outcome';
import { fmtQty, fmtZAR, parseQty } from '@/lib/format';

type S = { product_id: string; sku: string; description: string; uom: string; free: number; min_qty: number; reorder_qty: number; on_order: number;
  stock_level: string; suggested_qty: number; supplier_id: string | null; supplier: string | null; last_price: number | null; covered: boolean };

export default function SuggestionsPage() {
  const router = useRouter();
  const { warehouse, warehouseId, can } = useApp();
  const list = useRows<S>(warehouseId ? 'sug' + warehouseId : null, (sb) => sb.rpc('purchase_suggestions', { p_warehouse_id: warehouseId }));
  const [sel, setSel] = useState<Record<string, string>>({});
  const txn = useTransaction('create_po_from_suggestions');
  useEffect(() => {
    setSel(Object.fromEntries(list.rows.filter((r) => !r.covered && r.supplier_id && Number(r.suggested_qty) > 0).map((r) => [r.product_id, String(Number(r.suggested_qty))])));
  }, [list.rows]);
  const chosen = list.rows.filter((r) => sel[r.product_id] !== undefined);
  const bad = chosen.some((r) => { const q = parseQty(sel[r.product_id]); return q === null || isNaN(q) || q <= 0 || !r.supplier_id; });
  const suppliers = new Set(chosen.map((r) => r.supplier_id)).size;

  if (!warehouse) return <PageHeader title="Reorder suggestions" />;
  return (
    <>
      <PageHeader title="Reorder suggestions" description={`Items at or below their minimum in ${warehouse.code}, after counting stock already on order. Choose quantities and create one draft purchase order per supplier.`} />
      <LoadError error={list.error} />
      {list.loading ? <Spinner /> : list.rows.length === 0 ? <Notice tone="ok" title="Nothing to reorder">Every item with a minimum is above it, or already on order.</Notice> : (
        <>
          <Table>
            <thead><tr><Th /><Th>Product</Th><Th right>Free now</Th><Th right>On order</Th><Th right>Minimum / reorder</Th><Th>Supplier</Th><Th right>Last price</Th><Th>Order qty</Th></tr></thead>
            <tbody>{list.rows.map((r) => (
              <tr key={r.product_id} className={r.covered ? 'opacity-60' : ''}>
                <Td><input type="checkbox" aria-label={`Order ${r.sku}`} checked={sel[r.product_id] !== undefined} disabled={!r.supplier_id}
                  onChange={(e) => { const n = { ...sel }; if (e.target.checked) n[r.product_id] = String(Number(r.suggested_qty) || Number(r.reorder_qty) || 1); else delete n[r.product_id]; setSel(n); }} /></Td>
                <Td><span className="font-mono text-[13px] font-semibold">{r.sku}</span> {r.description}<div><Badge tone={r.stock_level === 'out' ? 'bad' : 'warn'}>{r.stock_level === 'out' ? 'out of stock' : 'low'}</Badge>{r.covered && <Badge className="ml-1">covered by open orders</Badge>}</div></Td>
                <Td right>{fmtQty(r.free)} {r.uom}</Td><Td right>{fmtQty(r.on_order)}</Td><Td right>{fmtQty(r.min_qty)} / {fmtQty(r.reorder_qty)}</Td>
                <Td>{r.supplier ?? <span className="text-xs text-bad-600">No default supplier — set one on the product</span>}</Td>
                <Td right>{r.last_price != null ? fmtZAR(r.last_price) : '—'}</Td>
                <Td><Input inputMode="decimal" className="w-24 text-right" disabled={sel[r.product_id] === undefined} value={sel[r.product_id] ?? ''} onChange={(e) => setSel({ ...sel, [r.product_id]: e.target.value })} /></Td>
              </tr>
            ))}</tbody>
          </Table>
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <Button variant="primary" size="lg" disabled={!can('purchase.manage', warehouseId) || chosen.length === 0 || bad} busy={txn.state.phase === 'saving'}
              onClick={async () => {
                const r = await txn.run({ p_warehouse_id: warehouseId, p_items: chosen.map((c) => ({ product_id: c.product_id, qty: parseQty(sel[c.product_id]), supplier_id: c.supplier_id })) });
                if (r && Number(r.created) === 1) router.push(`/purchasing/${(r.purchase_orders as { po_id: string }[])[0].po_id}`);
              }}>Create {suppliers} draft order{suppliers === 1 ? '' : 's'} ({chosen.length} items)</Button>
            <TxnOutcome state={txn.state} onRetry={txn.retry} savedText={(r) => <>Created {String(r.created)} draft purchase orders. <a className="underline" href="/purchasing?tab=draft">Review the drafts</a> and submit them for approval.</>} />
          </div>
        </>
      )}
    </>
  );
}
