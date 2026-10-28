'use client';
import { Suspense, useEffect, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { useApp } from '@/components/app-context';
import { ProductPicker } from '@/components/product-picker';
import { RemoveLine } from '@/components/txn-lines';
import { Button, Field, Input, Notice, OfflineNotice, PageHeader, Panel, Select, Spinner, Table, Td, Textarea, Th, cx } from '@/components/ui';
import { ActionResult } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useOnline } from '@/hooks/use-online';
import { useSuppliers } from '@/hooks/use-ref-data';
import { useTransaction, callRpc } from '@/hooks/use-transaction';
import { supabaseBrowser } from '@/lib/supabase/client';
import { fmtQty, fmtZAR, parseQty, todayISO } from '@/lib/format';
import type { LookupResult, ProductLookup } from '@/lib/types';
import { TxnOutcome } from '@/components/txn-outcome';

type Line = { key: string; p: ProductLookup; uom_id: string; qty: string; price: string };

function PoEditor() {
  const sp = useSearchParams();
  const editId = sp.get('edit');
  const router = useRouter();
  const { warehouse, warehouseId, can } = useApp();
  const online = useOnline();
  const { data: suppliers } = useSuppliers();
  const txn = useTransaction('create_purchase_order');
  const act = useAction();
  const [lines, setLines] = useState<Line[]>([]);
  const [supplier, setSupplier] = useState('');
  const [expected, setExpected] = useState('');
  const [supRef, setSupRef] = useState('');
  const [notes, setNotes] = useState('');
  const [loading, setLoading] = useState(!!editId);
  const [whId, setWhId] = useState<string | null>(warehouseId);

  // Load an existing draft for editing
  useEffect(() => {
    if (!editId) return;
    (async () => {
      const sb = supabaseBrowser();
      const { data: po } = await sb.from('purchase_orders').select('*').eq('id', editId).maybeSingle();
      const { data: ls } = await sb.from('v_purchase_order_lines').select('*').eq('po_id', editId).order('line_no');
      if (po) { setSupplier(po.supplier_id); setExpected(po.expected_date ?? ''); setSupRef(po.supplier_reference ?? ''); setNotes(po.notes ?? ''); setWhId(po.warehouse_id); }
      const out: Line[] = [];
      for (const l of ls ?? []) {
        const { data } = await callRpc<LookupResult>('lookup_code', { p_code: l.sku, p_warehouse_id: po?.warehouse_id });
        if (data && data.kind === 'product') out.push({ key: l.id, p: data, uom_id: l.uom_id, qty: String(Number(l.qty_ordered)), price: String(Number(l.unit_price)) });
      }
      setLines(out); setLoading(false);
    })();
  }, [editId]);

  const add = (p: ProductLookup) => {
    if (lines.some((l) => l.p.product.id === p.product.id && l.uom_id === (p.scanned_uom_id ?? p.product.base_uom.id))) return;
    setLines((c) => [...c, { key: crypto.randomUUID(), p, uom_id: p.scanned_uom_id ?? p.product.base_uom.id, qty: '', price: '' }]);
  };
  const patch = (k: string, v: Partial<Line>) => setLines((c) => c.map((l) => (l.key === k ? { ...l, ...v } : l)));
  const lineErr = (l: Line) => {
    const q = parseQty(l.qty); const pr = parseQty(l.price || '0');
    if (q === null || isNaN(q) || q <= 0) return 'Quantity?';
    if (pr === null || isNaN(pr) || pr < 0) return 'Price?';
    return null;
  };
  const total = lines.reduce((s, l) => s + (Number(parseQty(l.qty)) || 0) * (Number(parseQty(l.price || '0')) || 0), 0);
  const ready = online && !!supplier && lines.length > 0 && lines.every((l) => !lineErr(l));
  const payload = () => lines.map((l) => ({ product_id: l.p.product.id, uom_id: l.uom_id, qty: parseQty(l.qty), unit_price: parseQty(l.price || '0') }));

  const save = async () => {
    if (editId) {
      const r = await act.run('update_purchase_order', { p_po_id: editId, p_supplier_id: supplier, p_lines: payload(), p_expected_date: expected || null, p_supplier_reference: supRef || null, p_notes: notes || null });
      if (r) router.push(`/purchasing/${editId}`);
      return;
    }
    const r = await txn.run({ p_supplier_id: supplier, p_warehouse_id: warehouseId, p_lines: payload(), p_expected_date: expected || null, p_supplier_reference: supRef || null, p_notes: notes || null });
    if (r && typeof r.po_id === 'string') router.push(`/purchasing/${r.po_id}`);
  };

  if (!warehouse) return <PageHeader title="Purchase order" description="You are not assigned to a warehouse." />;
  if (loading) return <Spinner />;
  if (!can('purchase.manage', whId)) return <PageHeader title="Purchase order" description="You may not create purchase orders for this warehouse." />;
  return (
    <>
      <PageHeader title={editId ? 'Edit draft purchase order' : 'New purchase order'} description={`Deliver to ${warehouse.code} — ${warehouse.name}. Prices are in ZAR excluding VAT, per the unit chosen on each line.`} />
      {!online && <OfflineNotice />}
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        <div className="space-y-4">
          <ProductPicker warehouseId={whId} onProduct={add} />
          {lines.length > 0 && (
            <Table>
              <thead><tr><Th>Product</Th><Th>Quantity</Th><Th>Unit</Th><Th>Unit price (R)</Th><Th right>Line total</Th><Th /></tr></thead>
              <tbody>{lines.map((l) => {
                const e = (l.qty !== '' || l.price !== '') ? lineErr(l) : null;
                return (
                  <tr key={l.key}>
                    <Td><span className="font-mono text-[13px] font-semibold">{l.p.product.sku}</span><div className="text-sm">{l.p.product.description}</div>
                      <div className="text-xs text-steel-600">In stock here: {fmtQty(l.p.warehouse_available)} {l.p.product.base_uom.code}{l.p.threshold ? ` · min ${fmtQty(l.p.threshold.min_qty)}` : ''}</div></Td>
                    <Td><Input inputMode="decimal" className={cx('w-24 text-right', e === 'Quantity?' && 'border-bad-600')} value={l.qty} onChange={(ev) => patch(l.key, { qty: ev.target.value })} aria-label={`Quantity of ${l.p.product.sku}`} /></Td>
                    <Td><Select className="w-28" value={l.uom_id} onChange={(ev) => patch(l.key, { uom_id: ev.target.value })}>{l.p.units.map((u) => <option key={u.uom_id} value={u.uom_id}>{u.code}{u.factor !== 1 ? ` (${fmtQty(u.factor)})` : ''}</option>)}</Select></Td>
                    <Td><Input inputMode="decimal" className={cx('w-28 text-right', e === 'Price?' && 'border-bad-600')} value={l.price} onChange={(ev) => patch(l.key, { price: ev.target.value })} aria-label={`Price of ${l.p.product.sku}`} /></Td>
                    <Td right>{fmtZAR((Number(parseQty(l.qty)) || 0) * (Number(parseQty(l.price || '0')) || 0))}</Td>
                    <Td><RemoveLine onClick={() => setLines((c) => c.filter((x) => x.key !== l.key))} /></Td>
                  </tr>
                );
              })}</tbody>
            </Table>
          )}
          {lines.length === 0 && <Notice tone="info">Scan or search for the products to order. Tip: <a className="underline" href="/purchasing/suggestions">Reorder suggestions</a> builds orders from low-stock items automatically.</Notice>}
        </div>
        <Panel title="Order details">
          <div className="space-y-3">
            <Field label="Supplier" required><Select value={supplier} onChange={(e) => setSupplier(e.target.value)}><option value="">— choose —</option>{suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
            <Field label="Expected delivery"><Input type="date" min={todayISO()} value={expected} onChange={(e) => setExpected(e.target.value)} /></Field>
            <Field label="Supplier quote / reference"><Input value={supRef} onChange={(e) => setSupRef(e.target.value)} /></Field>
            <Field label="Notes for the supplier / approver"><Textarea rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
            <div className="flex justify-between border-t border-steel-100 pt-3 text-sm"><span>Total (excl. VAT)</span><b className="text-lg">{fmtZAR(total)}</b></div>
            <TxnOutcome state={txn.state} onRetry={txn.retry} />
            <ActionResult error={act.error} />
            <Button variant="primary" size="lg" className="w-full" disabled={!ready} busy={txn.state.phase === 'saving' || act.busy} onClick={save}>{editId ? 'Save changes' : 'Save draft'}</Button>
            <p className="text-xs text-steel-600">A draft can still be changed. Submit it for approval from the order page.</p>
          </div>
        </Panel>
      </div>
    </>
  );
}

export default function NewPoPage() {
  return <Suspense fallback={<Spinner />}><PoEditor /></Suspense>;
}
