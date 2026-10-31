'use client';
import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useApp } from '@/components/app-context';
import { ProductPicker } from '@/components/product-picker';
import { RemoveLine } from '@/components/txn-lines';
import { TxnOutcome } from '@/components/txn-outcome';
import { Button, Field, Input, Notice, OfflineNotice, PageHeader, Panel, Select, Table, Td, Textarea, Th, cx } from '@/components/ui';
import { useAllWarehouses } from '@/hooks/use-ref-data';
import { useOnline } from '@/hooks/use-online';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtQty, parseQty, todayISO } from '@/lib/format';
import type { ProductLookup } from '@/lib/types';

type Line = { key: string; p: ProductLookup; uom_id: string; qty: string };

export default function NewIcOrderPage() {
  const router = useRouter();
  const { warehouses, warehouseId, can } = useApp();
  const online = useOnline();
  const { data: all } = useAllWarehouses();
  const mine = warehouses.filter((w) => can('intercompany.order', w.id));
  const [to, setTo] = useState(mine.find((w) => w.id === warehouseId)?.id ?? mine[0]?.id ?? '');
  const buyer = mine.find((w) => w.id === to)?.company_id;
  const sources = useMemo(() => all.filter((w) => w.company_id !== buyer), [all, buyer]);
  const [from, setFrom] = useState('');
  const [lines, setLines] = useState<Line[]>([]);
  const [needed, setNeeded] = useState('');
  const [ref, setRef] = useState('');
  const [notes, setNotes] = useState('');
  const txn = useTransaction('create_ic_order');

  if (!mine.length) return <PageHeader title="New inter-company order" description="You may not order stock from other companies (permission intercompany.order)." />;
  const add = (p: ProductLookup) => {
    const u = p.scanned_uom_id ?? p.product.base_uom.id;
    if (lines.some((l) => l.p.product.id === p.product.id && l.uom_id === u)) return;
    setLines((c) => [...c, { key: crypto.randomUUID(), p, uom_id: u, qty: '' }]);
  };
  const bad = (l: Line) => { const q = parseQty(l.qty); return q === null || isNaN(q) || q <= 0; };
  const ready = online && !!to && !!from && lines.length > 0 && lines.every((l) => !bad(l));

  return (
    <>
      <PageHeader title="New inter-company order" description="Order stock from another company in the group. The supplying company approves it, dispatches it as a transfer, and invoices what arrives." />
      {!online && <OfflineNotice />}
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        <div className="space-y-4">
          {!from ? <Notice tone="info">First choose the warehouse that supplies the stock (right). Then scan or search the products.</Notice>
            : <ProductPicker warehouseId={to} onProduct={add} />}
          {lines.length > 0 && (
            <Table>
              <thead><tr><Th>Product</Th><Th>Quantity</Th><Th>Unit</Th><Th /></tr></thead>
              <tbody>{lines.map((l) => (
                <tr key={l.key}>
                  <Td><span className="font-mono text-[13px] font-semibold">{l.p.product.sku}</span><div className="text-sm">{l.p.product.description}</div>
                    <div className="text-xs text-steel-600">You have {fmtQty(l.p.warehouse_available)} {l.p.product.base_uom.code} here; the supplier&apos;s stock shows on the order</div></Td>
                  <Td><Input inputMode="decimal" className={cx('w-24 text-right', l.qty !== '' && bad(l) && 'border-bad-600')} value={l.qty}
                    onChange={(e) => setLines((c) => c.map((x) => (x.key === l.key ? { ...x, qty: e.target.value } : x)))} aria-label={`Quantity of ${l.p.product.sku}`} /></Td>
                  <Td><Select className="w-28" value={l.uom_id} onChange={(e) => setLines((c) => c.map((x) => (x.key === l.key ? { ...x, uom_id: e.target.value } : x)))}>
                    {l.p.units.map((u) => <option key={u.uom_id} value={u.uom_id}>{u.code}{u.factor !== 1 ? ` (${fmtQty(u.factor)})` : ''}</option>)}</Select></Td>
                  <Td><RemoveLine onClick={() => setLines((c) => c.filter((x) => x.key !== l.key))} /></Td>
                </tr>))}</tbody>
            </Table>
          )}
        </div>
        <Panel title="Order">
          <div className="space-y-3">
            <Field label="Deliver to (my warehouse)" required>
              <Select value={to} onChange={(e) => { setTo(e.target.value); setFrom(''); setLines([]); }}>{mine.map((w) => <option key={w.id} value={w.id}>{w.code} — {w.name} ({w.company_code})</option>)}</Select>
            </Field>
            <Field label="Supplied from (other company)" required>
              <Select value={from} onChange={(e) => { setFrom(e.target.value); setLines([]); }}>
                <option value="">— choose —</option>
                {sources.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.company_code} · {w.warehouse_code} — {w.warehouse_name}</option>)}
              </Select>
            </Field>
            <Field label="Needed by"><Input type="date" min={todayISO()} value={needed} onChange={(e) => setNeeded(e.target.value)} /></Field>
            <Field label="Reference (job, project)"><Input value={ref} onChange={(e) => setRef(e.target.value)} /></Field>
            <Field label="Notes for the supplying company"><Textarea rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
            <TxnOutcome state={txn.state} onRetry={txn.retry} savedText={() => 'Order sent to the supplying company for approval.'} />
            <Button variant="primary" size="lg" className="w-full" disabled={!ready} busy={txn.state.phase === 'saving'}
              onClick={async () => {
                const r = await txn.run({ p_from_warehouse_id: from, p_to_warehouse_id: to, p_needed_by: needed || null, p_reference: ref || null, p_notes: notes || null,
                  p_lines: lines.map((l) => ({ product_id: l.p.product.id, uom_id: l.uom_id, qty: parseQty(l.qty) })) });
                if (r && typeof r.order_id === 'string') router.push(`/intercompany/orders/${r.order_id}`);
              }}>Send order</Button>
            <p className="text-xs text-steel-600">Prices are set by the supplying company (default: cost plus the group mark-up) and shown on the order once you may see prices.</p>
          </div>
        </Panel>
      </div>
    </>
  );
}
