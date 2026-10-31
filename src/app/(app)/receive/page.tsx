'use client';
import { useMemo, useState } from 'react';
import { MapPin } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { ProductPicker } from '@/components/product-picker';
import { ProductCell, RemoveLine, UnitQty, baseQty, newLine, qtyError, type TxnLine } from '@/components/txn-lines';
import { TxnOutcome } from '@/components/txn-outcome';
import { Badge, Button, Field, Input, Notice, OfflineNotice, PageHeader, Panel, Select, Textarea } from '@/components/ui';
import { useCompanies, useLocations, useSuppliers } from '@/hooks/use-ref-data';
import { useOnline } from '@/hooks/use-online';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtQty } from '@/lib/format';

export default function ReceivePage() {
  const { warehouse, warehouseId, can } = useApp();
  const online = useOnline();
  const { data: locations } = useLocations(warehouseId);
  const { data: suppliers } = useSuppliers();
  const { data: companies } = useCompanies();
  const txn = useTransaction('receive_stock');

  const [lines, setLines] = useState<TxnLine[]>([]);
  const [supplierId, setSupplierId] = useState('');
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [putaway, setPutaway] = useState<string>('');
  const [otherOwner, setOtherOwner] = useState(false);
  const [reviewing, setReviewing] = useState(false);

  const defaultLoc = useMemo(() => locations.find((l) => l.is_default)?.id ?? locations[0]?.id ?? '', [locations]);
  const locked = txn.state.phase === 'saving' || txn.state.phase === 'unconfirmed';
  const allowed = can('stock.receive', warehouseId);
  const showCost = can('cost.view');

  const addProduct = (p: Parameters<typeof newLine>[0]) => {
    if (locked) return;
    if (txn.state.phase === 'saved' || txn.state.phase === 'failed') txn.reset();
    setReviewing(false);
    setLines((cur) => {
      const loc = putaway || defaultLoc;
      const same = cur.find((l) => l.product.product.id === p.product.id && l.uom_id === p.scanned_uom_id && l.location_id === loc);
      if (same) {   // rapid consecutive scanning: the same item again adds one unit
        return cur.map((l) => (l === same ? { ...l, qty: String((Number(l.qty.replace(',', '.')) || 0) + 1), flash: Date.now() } : l));
      }
      return [...cur, newLine(p, { location_id: loc, owner_company_id: warehouse?.company_id })];
    });
  };

  const patch = (key: string, p: Partial<TxnLine>) => { setReviewing(false); setLines((cur) => cur.map((l) => (l.key === key ? { ...l, ...p } : l))); };
  const errors = lines.map((l) => qtyError(l) ?? (!l.location_id ? 'Choose a location' : null));
  const canReview = allowed && online && lines.length > 0 && errors.every((e) => !e) && reference.trim() !== '';

  const submit = async () => {
    const r = await txn.run({
      p_warehouse_id: warehouseId,
      p_reference: reference.trim(),
      p_supplier_id: supplierId || null,
      p_notes: notes || null,
      p_lines: lines.map((l) => ({
        product_id: l.product.product.id, location_id: l.location_id, qty: l.qty.replace(/\s/g, '').replace(',', '.'), uom_id: l.uom_id,
        owner_company_id: otherOwner ? l.owner_company_id : undefined,
        unit_cost: l.unit_cost ? l.unit_cost.replace(',', '.') : undefined,
      })),
    });
    if (r) { setLines([]); setReference(''); setNotes(''); setSupplierId(''); setReviewing(false); }
  };

  if (!warehouse) return <PageHeader title="Receive stock" description="You are not assigned to any warehouse." />;

  return (
    <>
      <PageHeader title="Receive stock" description={`Into ${warehouse.code} — ${warehouse.name}. Stock increases only after the database confirms the receipt.`} />
      {!online && <OfflineNotice />}
      {!allowed && <Notice tone="warn" title="You cannot receive stock in this warehouse">Choose another warehouse at the top of the page or ask your manager for access.</Notice>}

      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        <div className="space-y-4">
          <ProductPicker warehouseId={warehouseId} onProduct={addProduct} disabled={!allowed || locked} big
            onLocation={(loc) => { setPutaway(loc.id); setLines((cur) => cur.length ? cur.map((l, i) => (i === cur.length - 1 ? { ...l, location_id: loc.id } : l)) : cur); }} />
          {putaway && (
            <div className="flex items-center gap-2 text-sm text-navy-900"><MapPin className="size-4" />Put-away location for new lines:
              <Badge tone="info">{locations.find((l) => l.id === putaway)?.code}</Badge>
              <button className="text-xs underline" onClick={() => setPutaway('')}>clear</button>
            </div>
          )}

          <Panel title={`Items (${lines.length})`} padded={false}>
            {lines.length === 0 && <p className="p-4 text-sm text-steel-600">Scan the first item on the delivery. Scanning a shelf label sets where the next items are put away.</p>}
            <ul className="divide-y divide-steel-100">
              {lines.map((l, i) => (
                <li key={l.key} className="grid gap-3 p-4 md:grid-cols-[1fr_auto_12rem_auto] md:items-start">
                  <ProductCell line={l} />
                  <UnitQty line={l} onChange={(p) => patch(l.key, p)} disabled={locked} autoFocus={i === lines.length - 1} />
                  <div className="space-y-2">
                    <Select value={l.location_id} onChange={(e) => patch(l.key, { location_id: e.target.value })} disabled={locked} aria-label="Location">
                      {locations.map((loc) => <option key={loc.id} value={loc.id}>{loc.code} — {loc.name}</option>)}
                    </Select>
                    {otherOwner && (
                      <Select value={l.owner_company_id} onChange={(e) => patch(l.key, { owner_company_id: e.target.value })} disabled={locked} aria-label="Owner company">
                        {companies.map((c) => <option key={c.id} value={c.id}>Owned by {c.code}</option>)}
                      </Select>
                    )}
                    {showCost && <Input value={l.unit_cost ?? ''} onChange={(e) => patch(l.key, { unit_cost: e.target.value })} placeholder="Unit cost (R), optional" inputMode="decimal" disabled={locked} />}
                    {errors[i] === 'Choose a location' && <div className="text-xs text-bad-600">Choose a location</div>}
                  </div>
                  <RemoveLine onClick={() => setLines((cur) => cur.filter((x) => x.key !== l.key))} disabled={locked} />
                </li>
              ))}
            </ul>
          </Panel>
        </div>

        <div className="space-y-4">
          <Panel title="Delivery details">
            <div className="space-y-3">
              <Field label="Supplier delivery note / reference" required><Input value={reference} onChange={(e) => { setReference(e.target.value); setReviewing(false); }} disabled={locked} placeholder="e.g. DN 40213" /></Field>
              <Field label="Supplier">
                <Select value={supplierId} onChange={(e) => setSupplierId(e.target.value)} disabled={locked}>
                  <option value="">— Not specified —</option>
                  {suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                </Select>
              </Field>
              <Field label="Notes"><Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={locked} /></Field>
              <label className="flex items-start gap-2 text-sm">
                <input type="checkbox" checked={otherOwner} onChange={(e) => setOtherOwner(e.target.checked)} disabled={locked} className="mt-1" />
                <span>Some stock belongs to another company (stored here on its behalf)</span>
              </label>
            </div>
          </Panel>

          {!reviewing ? (
            <Button variant="primary" size="lg" className="w-full" disabled={!canReview || locked} onClick={() => setReviewing(true)}>Review receipt</Button>
          ) : (
            <Panel title="Confirm receipt">
              <ul className="mb-3 space-y-1 text-sm">
                {lines.map((l) => (
                  <li key={l.key} className="flex justify-between gap-2">
                    <span className="font-mono text-[13px]">{l.product.product.sku}</span>
                    <span className="tabular-nums">+{fmtQty(baseQty(l))} {l.product.product.base_uom.code} → {locations.find((x) => x.id === l.location_id)?.code}</span>
                  </li>
                ))}
              </ul>
              <div className="flex gap-2">
                <Button variant="secondary" onClick={() => setReviewing(false)} disabled={locked}>Back</Button>
                <Button variant="primary" className="flex-1" onClick={submit} busy={txn.state.phase === 'saving'} disabled={!canReview || locked}>Confirm receipt</Button>
              </div>
            </Panel>
          )}
          <TxnOutcome allowUndo state={txn.state} onRetry={txn.retry} onNew={txn.reset} />
        </div>
      </div>
    </>
  );
}
