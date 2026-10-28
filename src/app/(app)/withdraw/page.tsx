'use client';
import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, PackageMinus } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { ProductPicker } from '@/components/product-picker';
import { UnitQty, baseQty, newLine, qtyError, type TxnLine } from '@/components/txn-lines';
import { TxnOutcome } from '@/components/txn-outcome';
import { Badge, Button, Field, Input, Notice, OfflineNotice, PageHeader, Panel, Select, Textarea, cx } from '@/components/ui';
import { useReasons } from '@/hooks/use-ref-data';
import { useOnline } from '@/hooks/use-online';
import { useRows } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtQty } from '@/lib/format';
import type { ProductLookup } from '@/lib/types';

type Unusual = { sku: string; qty_base: number; usual_avg: number; usual_max: number; history_count: number; product_limit: number | null };

/**
 * Withdraw stock — designed for warehouse staff on a phone or scanner:
 * scan → item appears → quantity → reason → reference → see remaining balance → confirm.
 */
export default function WithdrawPage() {
  const { warehouse, warehouseId, can } = useApp();
  const online = useOnline();
  const { data: reasons } = useReasons('withdrawal');
  const txn = useTransaction('withdraw_stock');

  const [line, setLine] = useState<TxnLine | null>(null);
  const [reasonCode, setReasonCode] = useState('');
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [unusual, setUnusual] = useState<Unusual[] | null>(null);
  const [confirmUnusual, setConfirmUnusual] = useState(false);

  const allowed = can('stock.withdraw', warehouseId);
  const locked = txn.state.phase === 'saving' || txn.state.phase === 'unconfirmed';
  const reason = reasons.find((r) => r.code === reasonCode);

  // keep reason & reference between items (common: several items for the same job)
  const pick = (p: ProductLookup) => {
    if (locked) return;
    if (txn.state.phase !== 'idle') txn.reset();
    setUnusual(null); setConfirmUnusual(false);
    const sources = p.balances.filter((b) => b.status === 'available' && Number(b.qty) > 0);
    // default: the location holding the most stock
    const best = [...sources].sort((a, b) => Number(b.qty) - Number(a.qty))[0];
    const issueUnit = p.units.find((u) => u.is_default_issue)?.uom_id;
    setLine(newLine(p, { location_id: best?.location_id ?? '', owner_company_id: best?.owner_company_id, uom_id: p.scanned_uom_id !== p.product.base_uom.id ? p.scanned_uom_id : (issueUnit ?? p.product.base_uom.id) }));
  };

  const sources = useMemo(() => (line ? line.product.balances.filter((b) => b.status === 'available' && Number(b.qty) > 0) : []), [line]);
  const src = sources.find((b) => b.location_id === line?.location_id && b.owner_company_id === line?.owner_company_id);
  const want = line ? baseQty(line) : null;
  const remaining = src && want !== null ? Number(src.qty) - want : null;
  const qErr = line && line.qty !== '' ? qtyError(line) : null;
  const tooMuch = remaining !== null && remaining < 0;
  const refMissing = !!reason?.requires_reference && reference.trim() === '';
  const ready = !!line && allowed && online && !!src && line.qty !== '' && !qErr && !tooMuch && !!reasonCode && !refMissing;

  // the database asked for reconfirmation of an unusual quantity
  useEffect(() => {
    if (txn.state.phase === 'failed' && txn.state.error.kind === 'confirm') {
      setUnusual((txn.state.error.detail?.unusual as Unusual[]) ?? []);
    }
  }, [txn.state]);

  const submit = async (confirm = false) => {
    if (!line || !src) return;
    const r = await txn.run({
      p_warehouse_id: warehouseId,
      p_reason_code: reasonCode,
      p_reference: reference.trim() || null,
      p_notes: notes.trim() || null,
      p_confirm_unusual: confirm,
      p_lines: [{ product_id: line.product.product.id, location_id: line.location_id, owner_company_id: line.owner_company_id, qty: line.qty.replace(/\s/g, '').replace(',', '.'), uom_id: line.uom_id }],
    });
    if (r) { setLine(null); setNotes(''); setUnusual(null); setConfirmUnusual(false); }
  };

  if (!warehouse) return <PageHeader title="Withdraw stock" description="You are not assigned to any warehouse." />;
  const base = line?.product.product.base_uom.code;

  return (
    <div className="mx-auto max-w-2xl">
      <PageHeader title="Withdraw stock" description={`From ${warehouse.code} — ${warehouse.name}`} />
      {!online && <OfflineNotice />}
      {!allowed && <Notice tone="warn" title="You cannot withdraw stock in this warehouse" />}

      <div className="space-y-4">
        <ProductPicker warehouseId={warehouseId} onProduct={pick} disabled={!allowed || locked} big
          onLocation={(loc) => line && setLine({ ...line, location_id: loc.id, owner_company_id: sources.find((s) => s.location_id === loc.id)?.owner_company_id })} />

        {txn.state.phase === 'saved' && <TxnOutcome state={txn.state} onRetry={txn.retry}
          savedText={(r) => {
            const m = (r.movements as { balance_after: number }[] | undefined)?.[0];
            return <>Withdrawal saved. Remaining at that location: <b>{fmtQty(m?.balance_after)}</b>. Scan the next item.</>;
          }} />}

        {line && (
          <Panel>
            <div className="flex items-start gap-3">
              <span className="grid size-12 shrink-0 place-items-center rounded-md bg-navy-900 text-signal-400"><PackageMinus className="size-6" /></span>
              <div className="min-w-0">
                <div className="font-mono text-sm font-semibold text-navy-900">{line.product.product.sku}</div>
                <div className="text-lg font-semibold leading-snug text-navy-900">{line.product.product.description}</div>
                <div className="text-sm text-steel-600">Available in this warehouse: <b className="text-navy-900">{fmtQty(line.product.warehouse_available)} {base}</b>
                  {Number(line.product.reserved) > 0 && <> · {fmtQty(line.product.reserved)} reserved</>}</div>
              </div>
            </div>

            {sources.length === 0 ? (
              <Notice tone="bad" className="mt-4" title="No available stock of this item in this warehouse">Nothing can be withdrawn. Check the warehouse selected at the top of the page.</Notice>
            ) : (
              <div className="mt-4 space-y-4">
                <Field label="Take from">
                  <div className="grid gap-2 sm:grid-cols-2">
                    {sources.map((s) => (
                      <button key={s.location_id + s.owner_company_id} type="button" disabled={locked}
                        onClick={() => setLine({ ...line, location_id: s.location_id, owner_company_id: s.owner_company_id })}
                        className={cx('rounded-md border-2 px-3 py-2 text-left text-sm', s.location_id === line.location_id && s.owner_company_id === line.owner_company_id ? 'border-navy-900 bg-navy-100' : 'border-steel-200 bg-white')}>
                        <div className="font-mono font-semibold">{s.location_code}</div>
                        <div className="text-steel-600">{fmtQty(s.qty)} {base} {sources.some((x) => x.owner_company_id !== s.owner_company_id) && <Badge>{s.owner_company_code}</Badge>}</div>
                      </button>
                    ))}
                  </div>
                </Field>

                <Field label="Quantity to withdraw" required>
                  <UnitQty line={line} onChange={(p) => { setLine({ ...line, ...p }); setUnusual(null); setConfirmUnusual(false); }} disabled={locked} autoFocus big />
                </Field>

                <div className="grid gap-4 sm:grid-cols-2">
                  <Field label="Reason" required>
                    <Select value={reasonCode} onChange={(e) => setReasonCode(e.target.value)} disabled={locked} className="h-12">
                      <option value="">— Select —</option>
                      {reasons.map((r) => <option key={r.code} value={r.code}>{r.label}</option>)}
                    </Select>
                  </Field>
                  <Field label={reason?.requires_reference ? 'Client / job / department' : 'Reference (optional)'} required={reason?.requires_reference}
                    error={refMissing && reasonCode ? 'Required for this reason' : null}>
                    <Input value={reference} onChange={(e) => setReference(e.target.value)} disabled={locked} className="h-12" placeholder="e.g. JOB-7781" />
                  </Field>
                </div>
                <ReservedFor productId={line.product.product.id} warehouseId={warehouseId} current={reference} disabled={locked} onPick={setReference} />
                <Field label="Notes"><Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={locked} rows={2} /></Field>

                {src && want !== null && !qErr && (
                  <div className={cx('rounded-md border-2 p-3 text-center', tooMuch ? 'border-bad-600 bg-bad-50' : 'border-navy-900 bg-steel-50')}>
                    {tooMuch ? (
                      <div className="font-semibold text-bad-600">Only {fmtQty(src.qty)} {base} at {src.location_code}. Reduce the quantity.</div>
                    ) : (
                      <>
                        <div className="text-sm text-steel-600">Balance at {src.location_code} after this withdrawal</div>
                        <div className="text-3xl font-bold tabular-nums text-navy-900">{fmtQty(remaining)} <span className="text-lg font-medium">{base}</span></div>
                        <div className="text-xs text-steel-600">{fmtQty(src.qty)} − {fmtQty(want)}</div>
                      </>
                    )}
                  </div>
                )}

                {unusual && unusual.length > 0 && (
                  <Notice tone="warn" title="Unusually large quantity — please verify">
                    {unusual.map((u) => (
                      <p key={u.sku}>You entered <b>{fmtQty(u.qty_base)} {base}</b>. Normal withdrawals of {u.sku} here are about <b>{fmtQty(u.usual_avg)}</b> (largest {fmtQty(u.usual_max)}).
                        {u.product_limit ? ` The review limit for this item is ${fmtQty(u.product_limit)}.` : ''}</p>
                    ))}
                    <label className="mt-2 flex items-start gap-2 font-medium">
                      <input type="checkbox" className="mt-1" checked={confirmUnusual} onChange={(e) => setConfirmUnusual(e.target.checked)} />
                      I have physically checked: {line.qty} {line.product.units.find((u) => u.uom_id === line.uom_id)?.code} is correct.
                    </label>
                    <p className="mt-1 text-xs">Your manager will be notified of this withdrawal.</p>
                  </Notice>
                )}

                {txn.state.phase !== 'saved' && <TxnOutcome state={txn.state.phase === 'failed' && txn.state.error.kind === 'confirm' ? { phase: 'idle' } : txn.state} onRetry={txn.retry} />}

                <div className="flex gap-2">
                  <Button variant="secondary" size="lg" onClick={() => { setLine(null); txn.reset(); }} disabled={locked}>Cancel</Button>
                  {unusual && unusual.length > 0 ? (
                    <Button variant="danger" size="lg" className="flex-1" disabled={!ready || !confirmUnusual} busy={txn.state.phase === 'saving'} onClick={() => submit(true)}>
                      <AlertTriangle className="size-5" />Confirm unusual withdrawal
                    </Button>
                  ) : (
                    <Button variant="primary" size="lg" className="flex-1" disabled={!ready || locked} busy={txn.state.phase === 'saving'} onClick={() => submit(false)}>
                      Confirm withdrawal{want !== null && !qErr ? ` of ${fmtQty(want)} ${base}` : ''}
                    </Button>
                  )}
                </div>
              </div>
            )}
          </Panel>
        )}
      </div>
    </div>
  );
}

/** Active reservations for this item: tapping one fills the reference so the withdrawal draws it down. */
function ReservedFor({ productId, warehouseId, current, disabled, onPick }: { productId: string; warehouseId: string | null; current: string; disabled: boolean; onPick: (ref: string) => void }) {
  const res = useRows<{ id: string; reference: string; qty_outstanding: number; uom_code: string; owner_company_code: string }>(
    warehouseId ? `wres|${productId}|${warehouseId}` : null,
    (sb) => sb.from('v_reservations').select('id, reference, qty_outstanding, uom_code, owner_company_code').eq('product_id', productId).eq('warehouse_id', warehouseId!).eq('status', 'active').order('created_at'));
  if (res.rows.length === 0) return null;
  return (
    <div className="rounded-lg border border-warn-600/40 bg-warn-50 p-3 text-sm">
      <div className="mb-2 font-medium">Reserved stock — choose the job you are issuing for:</div>
      <div className="flex flex-wrap gap-2">{res.rows.map((r) => (
        <button key={r.id} type="button" disabled={disabled} onClick={() => onPick(r.reference)}
          className={`rounded-full border px-3 py-1 ${current.trim() === r.reference ? 'border-navy-900 bg-navy-900 text-white' : 'border-steel-300 bg-white hover:bg-steel-50'}`}>
          {r.reference} · {fmtQty(r.qty_outstanding)} {r.uom_code}
        </button>))}</div>
    </div>
  );
}
