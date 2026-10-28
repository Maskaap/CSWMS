'use client';
import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useApp } from '@/components/app-context';
import { ProductPicker } from '@/components/product-picker';
import { ProductCell, RemoveLine, UnitQty, baseQty, newLine, qtyError, stockAt, type TxnLine } from '@/components/txn-lines';
import { TxnOutcome } from '@/components/txn-outcome';
import { Button, Field, Input, Notice, OfflineNotice, PageHeader, Panel, Select, Table, Td, Textarea, Th } from '@/components/ui';
import { useAllWarehouses, useCompanies, useLocations } from '@/hooks/use-ref-data';
import { useOnline } from '@/hooks/use-online';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtQty } from '@/lib/format';
import type { ProductLookup } from '@/lib/types';

export default function NewTransferPage() {
  const router = useRouter();
  const { warehouse, warehouseId, can } = useApp();
  const online = useOnline();
  const { data: allWh } = useAllWarehouses();
  const { data: companies } = useCompanies();
  const [toWh, setToWh] = useState('');
  const { data: toLocs } = useLocations(toWh || null);
  const txn = useTransaction('create_transfer');
  const [lines, setLines] = useState<TxnLine[]>([]);
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [expected, setExpected] = useState('');
  const [ownerChange, setOwnerChange] = useState('');
  const [dispatchNow, setDispatchNow] = useState(true);

  const destinations = useMemo(() => allWh.filter((w) => w.warehouse_id !== warehouseId), [allWh, warehouseId]);
  const dest = allWh.find((w) => w.warehouse_id === toWh);
  const locked = txn.state.phase === 'saving' || txn.state.phase === 'unconfirmed';
  const allowed = can('stock.transfer.dispatch', warehouseId);

  const add = (p: ProductLookup) => {
    if (locked) return;
    const src = p.balances.filter((b) => b.status === 'available' && Number(b.qty) > 0).sort((a, b) => Number(b.qty) - Number(a.qty))[0];
    setLines((cur) => [...cur, newLine(p, { location_id: src?.location_id ?? '', owner_company_id: src?.owner_company_id, to_location_id: '' })]);
  };
  const patch = (k: string, p: Partial<TxnLine>) => setLines((cur) => cur.map((l) => (l.key === k ? { ...l, ...p } : l)));
  const lineErr = (l: TxnLine) => {
    const e = qtyError(l); if (e) return e;
    if (!l.location_id) return 'Choose the source location';
    const have = stockAt(l.product, l.location_id, 'available', l.owner_company_id);
    if ((baseQty(l) ?? 0) > have) return `Only ${fmtQty(have)} available at that location`;
    return null;
  };
  const ok = allowed && online && !!toWh && lines.length > 0 && lines.every((l) => !lineErr(l));

  const submit = async () => {
    const r = await txn.run({
      p_from_warehouse_id: warehouseId, p_to_warehouse_id: toWh, p_to_owner_company_id: ownerChange || null,
      p_expected_arrival_at: expected ? new Date(expected + 'T17:00:00+02:00').toISOString() : null,
      p_reference: reference.trim() || null, p_notes: notes.trim() || null, p_dispatch_now: dispatchNow,
      p_lines: lines.map((l) => ({ product_id: l.product.product.id, from_location_id: l.location_id, owner_company_id: l.owner_company_id,
        to_location_id: l.to_location_id || undefined, qty: l.qty.replace(/\s/g, '').replace(',', '.'), uom_id: l.uom_id })),
    });
    if (r && typeof r.transfer_id === 'string') router.push(`/transfers/${r.transfer_id}`);
  };

  if (!warehouse) return <PageHeader title="New transfer" description="You are not assigned to a warehouse." />;
  return (
    <>
      <PageHeader title="New transfer" description={`From ${warehouse.code} — ${warehouse.name}. For moving stock between shelves inside one warehouse, use Returns & Corrections → Move.`} />
      {!online && <OfflineNotice />}
      {!allowed && <Notice tone="warn" title="You cannot dispatch transfers from this warehouse" />}
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        <div className="space-y-4">
          <ProductPicker warehouseId={warehouseId} onProduct={add} disabled={!allowed || locked} />
          {lines.length > 0 && (
            <Table>
              <thead><tr><Th>Product</Th><Th>From location</Th><Th>Quantity</Th><Th>Destination location</Th><Th /></tr></thead>
              <tbody>
                {lines.map((l) => {
                  const srcs = l.product.balances.filter((b) => b.status === 'available' && Number(b.qty) > 0);
                  const err = l.qty !== '' ? lineErr(l) : null;
                  return (
                    <tr key={l.key}>
                      <Td><ProductCell line={l} /></Td>
                      <Td>
                        <Select value={`${l.location_id}|${l.owner_company_id ?? ''}`} disabled={locked} onChange={(e) => { const [loc, own] = e.target.value.split('|'); patch(l.key, { location_id: loc, owner_company_id: own || undefined }); }}>
                          <option value="|">— choose —</option>
                          {srcs.map((s) => <option key={s.location_id + s.owner_company_id} value={`${s.location_id}|${s.owner_company_id}`}>{s.location_code} · {fmtQty(s.qty)} ({s.owner_company_code})</option>)}
                        </Select>
                      </Td>
                      <Td><UnitQty line={l} onChange={(p) => patch(l.key, p)} disabled={locked} />{err && !err.startsWith('Enter') && <div className="text-xs text-bad-600">{err}</div>}</Td>
                      <Td>
                        <Select value={l.to_location_id ?? ''} onChange={(e) => patch(l.key, { to_location_id: e.target.value })} disabled={locked || !toWh}>
                          <option value="">Receiving area (default)</option>
                          {toLocs.map((x) => <option key={x.id} value={x.id}>{x.code} — {x.name}</option>)}
                        </Select>
                      </Td>
                      <Td><RemoveLine onClick={() => setLines((c) => c.filter((x) => x.key !== l.key))} disabled={locked} /></Td>
                    </tr>
                  );
                })}
              </tbody>
            </Table>
          )}
        </div>
        <Panel title="Transfer details">
          <div className="space-y-3">
            <Field label="Destination warehouse" required>
              <Select value={toWh} onChange={(e) => setToWh(e.target.value)} disabled={locked}>
                <option value="">— choose —</option>
                {destinations.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.warehouse_code} — {w.warehouse_name} ({w.branch_code}, {w.company_code})</option>)}
              </Select>
            </Field>
            {dest && warehouse.company_id !== dest.company_id && <Notice tone="info">Destination is operated by {dest.company_code}. Stock keeps its current owner unless you change ownership below.</Notice>}
            <Field label="Change legal ownership on receipt (intercompany)" hint="Leave blank to keep the current owner. Requires supervisor or manager rights.">
              <Select value={ownerChange} onChange={(e) => setOwnerChange(e.target.value)} disabled={locked}>
                <option value="">Keep current owner</option>
                {companies.map((c) => <option key={c.id} value={c.id}>{c.code} — {c.name}</option>)}
              </Select>
            </Field>
            <Field label="Expected arrival"><Input type="date" value={expected} onChange={(e) => setExpected(e.target.value)} disabled={locked} /></Field>
            <Field label="Reference"><Input value={reference} onChange={(e) => setReference(e.target.value)} disabled={locked} placeholder="Waybill / request no." /></Field>
            <Field label="Notes"><Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={locked} rows={2} /></Field>
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={dispatchNow} onChange={(e) => setDispatchNow(e.target.checked)} disabled={locked} />Dispatch immediately (stock moves to “in transit” now)</label>
            <TxnOutcome state={txn.state} onRetry={txn.retry} />
            <Button variant="primary" size="lg" className="w-full" disabled={!ok || locked} busy={txn.state.phase === 'saving'} onClick={submit}>
              {dispatchNow ? 'Dispatch transfer' : 'Save as draft'}
            </Button>
          </div>
        </Panel>
      </div>
    </>
  );
}
