'use client';
import { Suspense, useEffect, useMemo, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { useApp } from '@/components/app-context';
import { ProductPicker } from '@/components/product-picker';
import { UnitQty, baseQty, newLine, qtyError, stockAt, type TxnLine } from '@/components/txn-lines';
import { TxnOutcome } from '@/components/txn-outcome';
import { Button, Field, Input, Notice, OfflineNotice, PageHeader, Panel, Select, Spinner, Textarea } from '@/components/ui';
import { Tabs } from '@/components/widgets';
import { useLocations, useReasons } from '@/hooks/use-ref-data';
import { useOnline } from '@/hooks/use-online';
import { useRows } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtDateTime, fmtQty, STATUS_LABELS } from '@/lib/format';
import type { ProductLookup } from '@/lib/types';

type Tab = 'return' | 'move' | 'status' | 'adjust' | 'reverse';
const num = (s: string) => s.replace(/\s/g, '').replace(',', '.');

function ProductHeader({ p, onClear }: { p: ProductLookup; onClear: () => void }) {
  return (
    <div className="flex items-start justify-between gap-3 rounded-md bg-steel-50 p-3">
      <div><div className="font-mono text-sm font-semibold">{p.product.sku}</div><div className="font-medium text-navy-900">{p.product.description}</div>
        <div className="text-xs text-steel-600">Available in this warehouse: {fmtQty(p.warehouse_available)} {p.product.base_uom.code}</div></div>
      <button type="button" className="text-sm underline" onClick={onClear}>Change</button>
    </div>
  );
}

function ReturnForm() {
  const { warehouseId, can } = useApp();
  const online = useOnline();
  const { data: reasons } = useReasons('return');
  const { data: locs } = useLocations(warehouseId);
  const txn = useTransaction('return_stock');
  const recent = useRows<{ id: string; txn_no: string; reference: string | null; created_at: string; created_by_name: string }>(warehouseId ? 'rw' + warehouseId : null,
    (sb) => sb.from('v_transactions').select('id, txn_no, reference, created_at, created_by_name').eq('warehouse_id', warehouseId!).eq('txn_type', 'withdrawal').eq('status', 'posted').order('created_at', { ascending: false }).limit(60));
  const [line, setLine] = useState<TxnLine | null>(null);
  const [orig, setOrig] = useState('');
  const [reason, setReason] = useState('UNUSED');
  const [cond, setCond] = useState<'good' | 'damaged'>('good');
  const [notes, setNotes] = useState('');
  const locked = txn.state.phase === 'saving' || txn.state.phase === 'unconfirmed';
  const defLoc = locs.find((l) => l.is_default)?.id ?? '';
  const err = line && line.qty !== '' ? qtyError(line) : null;
  const ready = online && can('stock.return', warehouseId) && !!line && line.qty !== '' && !err && !!line.location_id && !!reason;

  return (
    <div className="space-y-4">
      {!line ? <ProductPicker warehouseId={warehouseId} onProduct={(p) => { txn.reset(); setLine(newLine(p, { location_id: p.balances[0]?.location_id ?? defLoc })); }} disabled={locked} /> : <ProductHeader p={line.product} onClear={() => setLine(null)} />}
      <TxnOutcome allowUndo state={txn.state} onRetry={txn.retry} savedText={() => cond === 'good' ? 'Returned to available stock.' : 'Returned and recorded as damaged (not available for use).'} />
      {line && (
        <Panel>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Original withdrawal" hint="Link the return so it can never exceed what was taken.">
              <Select value={orig} onChange={(e) => setOrig(e.target.value)} disabled={locked}>
                <option value="">Not linked</option>
                {recent.rows.map((r) => <option key={r.id} value={r.id}>{r.txn_no} · {fmtDateTime(r.created_at)} · {r.created_by_name}{r.reference ? ` · ${r.reference}` : ''}</option>)}
              </Select>
            </Field>
            <Field label="Return to location" required>
              <Select value={line.location_id} onChange={(e) => setLine({ ...line, location_id: e.target.value })} disabled={locked}>
                <option value="">— choose —</option>{locs.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}
              </Select>
            </Field>
            <Field label="Quantity returned" required><UnitQty line={line} onChange={(p) => setLine({ ...line, ...p })} disabled={locked} /></Field>
            <Field label="Condition" required>
              <div className="flex gap-2">
                {(['good', 'damaged'] as const).map((c) => <Button key={c} type="button" variant={cond === c ? 'navy' : 'secondary'} onClick={() => setCond(c)} disabled={locked}>{c === 'good' ? 'Usable' : 'Damaged'}</Button>)}
              </div>
            </Field>
            <Field label="Reason" required><Select value={reason} onChange={(e) => setReason(e.target.value)} disabled={locked}>{reasons.map((r) => <option key={r.code} value={r.code}>{r.label}</option>)}</Select></Field>
            <Field label="Notes"><Input value={notes} onChange={(e) => setNotes(e.target.value)} disabled={locked} /></Field>
          </div>
          <Button className="mt-4" variant="primary" size="lg" disabled={!ready || locked} busy={txn.state.phase === 'saving'} onClick={async () => {
            if (await txn.run({ p_warehouse_id: warehouseId, p_reason_code: reason, p_original_txn_id: orig || null, p_notes: notes || null,
              p_lines: [{ product_id: line.product.product.id, location_id: line.location_id, qty: num(line.qty), uom_id: line.uom_id, condition: cond }] })) { setLine(null); setNotes(''); setOrig(''); }
          }}>Confirm return</Button>
        </Panel>
      )}
    </div>
  );
}

function MoveForm() {
  const { warehouseId, can } = useApp();
  const online = useOnline();
  const { data: locs } = useLocations(warehouseId);
  const txn = useTransaction('move_stock');
  const [line, setLine] = useState<TxnLine | null>(null);
  const [notes, setNotes] = useState('');
  const locked = txn.state.phase === 'saving' || txn.state.phase === 'unconfirmed';
  const srcs = line ? line.product.balances.filter((b) => Number(b.qty) > 0 && b.status !== 'in_transit') : [];
  const have = line ? stockAt(line.product, line.location_id, line.status ?? 'available', line.owner_company_id) : 0;
  const err = line && line.qty !== '' ? (qtyError(line) ?? ((baseQty(line) ?? 0) > have ? `Only ${fmtQty(have)} at the source` : null)) : null;
  const ready = online && can('stock.move', warehouseId) && !!line && !!line.location_id && !!line.to_location_id && line.to_location_id !== line.location_id && line.qty !== '' && !err;
  return (
    <div className="space-y-4">
      {!line ? <ProductPicker warehouseId={warehouseId} onProduct={(p) => { txn.reset(); const s = p.balances.find((b) => Number(b.qty) > 0 && b.status === 'available'); setLine(newLine(p, { location_id: s?.location_id ?? '', owner_company_id: s?.owner_company_id, status: 'available', to_location_id: '' })); }} disabled={locked} />
        : <ProductHeader p={line.product} onClear={() => setLine(null)} />}
      <TxnOutcome allowUndo state={txn.state} onRetry={txn.retry} savedText={() => 'Moved. Warehouse total is unchanged.'} />
      {line && (
        <Panel>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="From" required>
              <Select value={`${line.location_id}|${line.owner_company_id}|${line.status}`} onChange={(e) => { const [a, b, c] = e.target.value.split('|'); setLine({ ...line, location_id: a, owner_company_id: b, status: c }); }} disabled={locked}>
                {srcs.map((s) => <option key={s.location_id + s.owner_company_id + s.status} value={`${s.location_id}|${s.owner_company_id}|${s.status}`}>{s.location_code} · {fmtQty(s.qty)} {STATUS_LABELS[s.status]} ({s.owner_company_code})</option>)}
              </Select>
            </Field>
            <Field label="To location" required>
              <Select value={line.to_location_id} onChange={(e) => setLine({ ...line, to_location_id: e.target.value })} disabled={locked}>
                <option value="">— choose —</option>{locs.filter((l) => l.id !== line.location_id).map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}
              </Select>
            </Field>
            <Field label="Quantity" required error={err && !err.startsWith('Enter') ? err : null}><UnitQty line={line} onChange={(p) => setLine({ ...line, ...p })} disabled={locked} /></Field>
            <Field label="Notes"><Input value={notes} onChange={(e) => setNotes(e.target.value)} disabled={locked} /></Field>
          </div>
          <Button className="mt-4" variant="primary" size="lg" disabled={!ready || locked} busy={txn.state.phase === 'saving'} onClick={async () => {
            if (await txn.run({ p_warehouse_id: warehouseId, p_notes: notes || null, p_lines: [{ product_id: line.product.product.id, from_location_id: line.location_id, to_location_id: line.to_location_id,
              owner_company_id: line.owner_company_id, status: line.status, qty: num(line.qty), uom_id: line.uom_id }] })) { setLine(null); setNotes(''); }
          }}>Confirm move</Button>
        </Panel>
      )}
    </div>
  );
}

function StatusForm() {
  const { warehouseId, can } = useApp();
  const online = useOnline();
  const { data: reasons } = useReasons('status_change');
  const txn = useTransaction('change_stock_status');
  const [line, setLine] = useState<TxnLine | null>(null);
  const [to, setTo] = useState('damaged');
  const [reason, setReason] = useState('');
  const [notes, setNotes] = useState('');
  const locked = txn.state.phase === 'saving' || txn.state.phase === 'unconfirmed';
  const srcs = line ? line.product.balances.filter((b) => Number(b.qty) > 0 && b.status !== 'in_transit') : [];
  const have = line ? stockAt(line.product, line.location_id, line.status ?? 'available', line.owner_company_id) : 0;
  const err = line && line.qty !== '' ? (qtyError(line) ?? ((baseQty(line) ?? 0) > have ? `Only ${fmtQty(have)} in that status` : null)) : null;
  const ready = online && can('stock.adjust', warehouseId) && !!line && !!line.location_id && to !== line.status && !!reason && line.qty !== '' && !err;
  return (
    <div className="space-y-4">
      {!line ? <ProductPicker warehouseId={warehouseId} onProduct={(p) => { txn.reset(); const s = p.balances.find((b) => Number(b.qty) > 0 && b.status !== 'in_transit'); setLine(newLine(p, { location_id: s?.location_id ?? '', owner_company_id: s?.owner_company_id, status: s?.status ?? 'available' })); }} disabled={locked} />
        : <ProductHeader p={line.product} onClear={() => setLine(null)} />}
      <TxnOutcome allowUndo state={txn.state} onRetry={txn.retry} savedText={() => 'Status changed. Total stock is unchanged; available stock reflects the new status.'} />
      {line && (
        <Panel>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Stock to change" required>
              <Select value={`${line.location_id}|${line.owner_company_id}|${line.status}`} onChange={(e) => { const [a, b, c] = e.target.value.split('|'); setLine({ ...line, location_id: a, owner_company_id: b, status: c }); }} disabled={locked}>
                {srcs.map((s) => <option key={s.location_id + s.owner_company_id + s.status} value={`${s.location_id}|${s.owner_company_id}|${s.status}`}>{s.location_code} · {fmtQty(s.qty)} {STATUS_LABELS[s.status]} ({s.owner_company_code})</option>)}
              </Select>
            </Field>
            <Field label="New status" required>
              <Select value={to} onChange={(e) => setTo(e.target.value)} disabled={locked}>
                {['available', 'damaged', 'quarantine'].filter((s) => s !== line.status).map((s) => <option key={s} value={s}>{STATUS_LABELS[s]}</option>)}
              </Select>
            </Field>
            <Field label="Quantity" required error={err && !err.startsWith('Enter') ? err : null}><UnitQty line={line} onChange={(p) => setLine({ ...line, ...p })} disabled={locked} /></Field>
            <Field label="Reason" required><Select value={reason} onChange={(e) => setReason(e.target.value)} disabled={locked}><option value="">— choose —</option>{reasons.map((r) => <option key={r.code} value={r.code}>{r.label}</option>)}</Select></Field>
            <Field label="Notes" className="sm:col-span-2"><Input value={notes} onChange={(e) => setNotes(e.target.value)} disabled={locked} /></Field>
          </div>
          <Button className="mt-4" variant="primary" size="lg" disabled={!ready || locked} busy={txn.state.phase === 'saving'} onClick={async () => {
            if (await txn.run({ p_warehouse_id: warehouseId, p_reason_code: reason, p_notes: notes || null, p_lines: [{ product_id: line.product.product.id, location_id: line.location_id,
              owner_company_id: line.owner_company_id, from_status: line.status, to_status: to, qty: num(line.qty), uom_id: line.uom_id }] })) { setLine(null); setNotes(''); }
          }}>Confirm status change</Button>
        </Panel>
      )}
    </div>
  );
}

function AdjustForm() {
  const { warehouseId, can, me } = useApp();
  const online = useOnline();
  const { data: reasons } = useReasons('adjustment');
  const { data: locs } = useLocations(warehouseId);
  const txn = useTransaction('request_adjustment');
  const [line, setLine] = useState<TxnLine | null>(null);
  const [dir, setDir] = useState<'-' | '+'>('-');
  const [reason, setReason] = useState('');
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const locked = txn.state.phase === 'saving' || txn.state.phase === 'unconfirmed';
  const r = reasons.find((x) => x.code === reason);
  const have = line ? stockAt(line.product, line.location_id, line.status ?? 'available', line.owner_company_id) : 0;
  const err = line && line.qty !== '' ? (qtyError(line) ?? (dir === '-' && (baseQty(line) ?? 0) > have ? `Only ${fmtQty(have)} recorded there` : null)) : null;
  const ready = online && can('stock.adjust', warehouseId) && !!line && !!line.location_id && line.qty !== '' && !err && !!reason && notes.trim().length >= 5 && (!r?.requires_reference || reference.trim() !== '');
  const s = me?.settings ?? {};
  return (
    <div className="space-y-4">
      <Notice tone="info">Every adjustment needs a reason and an explanation. Adjustments above {String(s['adjust.approval_qty_threshold'] ?? '—')} units, {String(s['adjust.approval_pct_threshold'] ?? '—')}% of the balance or R {String(s['adjust.approval_value_threshold'] ?? '—')} wait for management approval before stock changes.</Notice>
      {!line ? <ProductPicker warehouseId={warehouseId} onProduct={(p) => { txn.reset(); const b = p.balances.find((x) => x.status === 'available'); setLine(newLine(p, { location_id: b?.location_id ?? '', owner_company_id: b?.owner_company_id, status: 'available' })); }} disabled={locked} />
        : <ProductHeader p={line.product} onClear={() => setLine(null)} />}
      <TxnOutcome state={txn.state} onRetry={txn.retry} />
      {line && (
        <Panel>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Location" required hint={`Recorded here: ${fmtQty(have)} ${line.product.product.base_uom.code}`}>
              <Select value={line.location_id} onChange={(e) => setLine({ ...line, location_id: e.target.value, owner_company_id: line.product.balances.find((b) => b.location_id === e.target.value)?.owner_company_id })} disabled={locked}>
                <option value="">— choose —</option>{locs.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}
              </Select>
            </Field>
            <Field label="Stock status">
              <Select value={line.status} onChange={(e) => setLine({ ...line, status: e.target.value })} disabled={locked}>
                {['available', 'damaged', 'quarantine'].map((s) => <option key={s} value={s}>{STATUS_LABELS[s]}</option>)}
              </Select>
            </Field>
            <Field label="Direction" required>
              <div className="flex gap-2">
                <Button type="button" variant={dir === '-' ? 'danger' : 'secondary'} onClick={() => setDir('-')} disabled={locked}>Decrease (−)</Button>
                <Button type="button" variant={dir === '+' ? 'navy' : 'secondary'} onClick={() => setDir('+')} disabled={locked}>Increase (+)</Button>
              </div>
            </Field>
            <Field label="Quantity" required error={err && !err.startsWith('Enter') ? err : null}><UnitQty line={line} onChange={(p) => setLine({ ...line, ...p })} disabled={locked} /></Field>
            <Field label="Reason" required><Select value={reason} onChange={(e) => setReason(e.target.value)} disabled={locked}><option value="">— choose —</option>{reasons.map((x) => <option key={x.code} value={x.code}>{x.label}</option>)}</Select></Field>
            <Field label={r?.requires_reference ? 'Reference (required)' : 'Reference'} required={r?.requires_reference}><Input value={reference} onChange={(e) => setReference(e.target.value)} disabled={locked} placeholder="e.g. integrity issue no., report no." /></Field>
            <Field label="Explanation" required className="sm:col-span-2"><Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={locked} rows={2} placeholder="What happened and how it was verified" /></Field>
          </div>
          <Button className="mt-4" variant={dir === '-' ? 'danger' : 'navy'} size="lg" disabled={!ready || locked} busy={txn.state.phase === 'saving'} onClick={async () => {
            if (await txn.run({ p_warehouse_id: warehouseId, p_reason_code: reason, p_reference: reference || null, p_notes: notes.trim(),
              p_lines: [{ product_id: line.product.product.id, location_id: line.location_id, owner_company_id: line.owner_company_id, status: line.status, qty: (dir === '-' ? '-' : '') + num(line.qty), uom_id: line.uom_id }] })) { setLine(null); setNotes(''); setReference(''); }
          }}>Submit adjustment ({dir}{line.qty || '0'})</Button>
        </Panel>
      )}
    </div>
  );
}

function ReverseFinder() {
  const router = useRouter();
  const [no, setNo] = useState('');
  const found = useRows<{ id: string }>(no.trim().length >= 6 ? 'find' + no.trim().toUpperCase() : null, (sb) => sb.from('v_transactions').select('id').eq('txn_no', no.trim().toUpperCase()).limit(1));
  return (
    <Panel>
      <p className="mb-3 text-sm text-steel-600">Posted transactions are never edited. To correct one, open it and request a reversal — an equal and opposite transaction posted after management approval.</p>
      <div className="flex gap-2">
        <Input value={no} onChange={(e) => setNo(e.target.value)} placeholder="Transaction number, e.g. WDR-2026-000123" />
        <Button variant="navy" disabled={!found.rows[0]} onClick={() => router.push(`/transactions/${found.rows[0].id}`)}>Open</Button>
      </div>
      {no.trim().length >= 6 && !found.loading && !found.rows[0] && <p className="mt-2 text-sm text-warn-600">No transaction with that number in your scope.</p>}
    </Panel>
  );
}

function CorrectionsInner() {
  const sp = useSearchParams();
  const { warehouse, can, warehouseId } = useApp();
  const online = useOnline();
  const [tab, setTab] = useState<Tab>((sp.get('tab') as Tab) || 'return');
  const tabs = useMemo(() => [
    { id: 'return' as Tab, label: 'Return', hidden: !can('stock.return', warehouseId) },
    { id: 'move' as Tab, label: 'Move between locations', hidden: !can('stock.move', warehouseId) },
    { id: 'status' as Tab, label: 'Damaged / quarantine', hidden: !can('stock.adjust', warehouseId) },
    { id: 'adjust' as Tab, label: 'Adjustment', hidden: !can('stock.adjust', warehouseId) },
    { id: 'reverse' as Tab, label: 'Reverse a transaction' },
  ], [can, warehouseId]);
  useEffect(() => { const first = tabs.find((t) => !t.hidden); if (first && tabs.find((t) => t.id === tab)?.hidden) setTab(first.id); }, [tabs, tab]);
  if (!warehouse) return <PageHeader title="Returns & corrections" description="You are not assigned to a warehouse." />;
  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="Returns & corrections" description={`${warehouse.code} — ${warehouse.name}. Every correction is a new, traceable transaction; nothing is overwritten.`} />
      {!online && <OfflineNotice />}
      <Tabs value={tab} onChange={setTab} tabs={tabs} />
      {tab === 'return' && <ReturnForm key={warehouseId} />}
      {tab === 'move' && <MoveForm key={warehouseId} />}
      {tab === 'status' && <StatusForm key={warehouseId} />}
      {tab === 'adjust' && <AdjustForm key={warehouseId} />}
      {tab === 'reverse' && <ReverseFinder />}
    </div>
  );
}

export default function CorrectionsPage() {
  return <Suspense fallback={<Spinner />}><CorrectionsInner /></Suspense>;
}
