'use client';
import { useState } from 'react';
import { BookmarkPlus, X } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { ProductPicker } from '@/components/product-picker';
import { TxnOutcome } from '@/components/txn-outcome';
import { Badge, Button, Field, Input, Notice, PageHeader, Panel, Select, Spinner, StatusBadge, Table, Td, Textarea, Th } from '@/components/ui';
import { ExportButtons, LoadError, Tabs, useConfirm } from '@/components/widgets';
import { useRows } from '@/hooks/use-rows';
import { callRpc, useTransaction } from '@/hooks/use-transaction';
import { toAppError } from '@/lib/errors';
import { fmtDate, fmtDateTime, fmtQty, parseQty } from '@/lib/format';
import type { ProductLookup } from '@/lib/types';

type R = { id: string; sku: string; description: string; uom_code: string; warehouse_id: string; warehouse_code: string; owner_company_code: string; reference: string;
  qty_reserved: number; qty_fulfilled: number; qty_outstanding: number; status: string; expires_at: string | null; is_expired: boolean; notes: string | null;
  created_by_name: string; created_at: string; closed_at: string | null };

/**
 * Reservations hold available stock for a job / client. A withdrawal that quotes the same reference
 * draws down the reservation automatically; everyone else can only withdraw the unreserved balance.
 */
export default function ReservationsPage() {
  const { can, warehouseId, warehouse } = useApp();
  const [tab, setTab] = useState<'active' | 'closed'>('active');
  const [msg, setMsg] = useState<{ tone: 'ok' | 'bad'; text: string } | null>(null);
  const { ask, node: dialog } = useConfirm();
  const list = useRows<R>(warehouseId ? `res|${tab}|${warehouseId}` : null, (sb) => {
    const q = sb.from('v_reservations').select('*').eq('warehouse_id', warehouseId!).order('created_at', { ascending: false }).limit(1000);
    return tab === 'active' ? q.eq('status', 'active') : q.neq('status', 'active');
  });
  const allowed = can('stock.withdraw', warehouseId);
  const release = async (r: R) => {
    const ok = await ask({ title: `Release ${fmtQty(r.qty_outstanding)} ${r.uom_code} of ${r.sku}?`, body: `Reserved for ${r.reference}. The stock becomes free for anyone to withdraw.`, noteLabel: 'Reason (optional)' });
    if (!ok) return;
    const { error } = await callRpc('release_reservation', { p_reservation_id: r.id, p_notes: ok.note || null });
    setMsg(error ? { tone: 'bad', text: toAppError(error).message } : { tone: 'ok', text: `Released the reservation for ${r.reference}.` });
    list.reload();
  };
  if (!warehouse) return <PageHeader title="Reservations" />;
  return (
    <>
      <PageHeader title="Reservations" description={`Stock set aside in ${warehouse.code} for a job or client. To issue it, withdraw with the same reference — the reservation is drawn down automatically.`}
        actions={<ExportButtons title="Reservations" rows={list.rows} cols={[
          { key: 'reference', label: 'Job / client' }, { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'owner_company_code', label: 'Owner' },
          { key: 'qty_reserved', label: 'Reserved', num: true }, { key: 'qty_fulfilled', label: 'Issued', num: true }, { key: 'qty_outstanding', label: 'Outstanding', num: true },
          { key: 'uom_code', label: 'Unit' }, { key: 'status', label: 'Status' }, { key: 'expires_at', label: 'Expires', get: (r) => fmtDate(r.expires_at) },
          { key: 'created_by_name', label: 'By' }, { key: 'created_at', label: 'Created', get: (r) => fmtDateTime(r.created_at) }]} />} />
      {allowed && <NewReservation onDone={list.reload} />}
      {msg && <Notice tone={msg.tone} className="mb-4">{msg.text}</Notice>}
      <Tabs value={tab} onChange={setTab} tabs={[{ id: 'active', label: 'Active' }, { id: 'closed', label: 'Issued / released' }]} />
      <LoadError error={list.error} />
      {list.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>Job / client</Th><Th>Item</Th><Th right>Reserved</Th><Th right>Issued</Th><Th right>Outstanding</Th><Th>Status</Th><Th>Expires</Th><Th>By</Th><Th /></tr></thead>
          <tbody>{list.rows.map((r) => (
            <tr key={r.id}>
              <Td className="font-semibold">{r.reference}{r.notes && <div className="whitespace-pre-line text-xs font-normal text-steel-600">{r.notes}</div>}</Td>
              <Td><span className="font-mono text-[13px] font-semibold">{r.sku}</span> {r.description}<div className="text-xs text-steel-600">{r.owner_company_code}</div></Td>
              <Td right>{fmtQty(r.qty_reserved)} {r.uom_code}</Td><Td right>{fmtQty(r.qty_fulfilled)}</Td><Td right className="font-semibold">{fmtQty(r.qty_outstanding)}</Td>
              <Td><StatusBadge status={r.status} />{r.is_expired && <Badge tone="warn" className="ml-1">expired</Badge>}</Td>
              <Td>{fmtDate(r.expires_at)}</Td>
              <Td className="text-xs">{r.created_by_name}<div>{fmtDateTime(r.created_at)}</div></Td>
              <Td>{r.status === 'active' && allowed && <Button size="sm" onClick={() => release(r)}><X className="size-4" />Release</Button>}</Td>
            </tr>
          ))}
            {list.rows.length === 0 && <tr><Td className="text-steel-600">No reservations.</Td></tr>}</tbody>
        </Table>
      )}
      {dialog}
    </>
  );
}

function NewReservation({ onDone }: { onDone: () => void }) {
  const { warehouseId } = useApp();
  const [p, setP] = useState<ProductLookup | null>(null);
  const [v, setV] = useState({ qty: '', uom: '', ref: '', expires: '', notes: '' });
  const txn = useTransaction('create_reservation');
  const [done, setDone] = useState<string | null>(null);
  const qty = parseQty(v.qty);
  const unit = p?.units.find((u) => u.uom_id === (v.uom || p.product.base_uom.id));
  const free = p ? Number(p.warehouse_available) - Number(p.reserved) : 0;
  const base = qty !== null && !isNaN(qty) && unit ? qty * Number(unit.factor) : null;
  const over = base !== null && base > free;
  return (
    <Panel title="Reserve stock" className="mb-6">
      <div className="grid gap-4 lg:grid-cols-[1fr_1.4fr]">
        <ProductPicker warehouseId={warehouseId} onProduct={(x) => { txn.reset(); setDone(null); setP(x); setV({ ...v, qty: '', uom: x.scanned_uom_id }); }} />
        {p ? (
          <div className="space-y-3">
            <div className="text-sm"><b className="font-mono">{p.product.sku}</b> {p.product.description}
              <div className="text-steel-600">Free to reserve: <b>{fmtQty(free)} {p.product.base_uom.code}</b> ({fmtQty(p.warehouse_available)} available, {fmtQty(p.reserved)} already reserved)</div></div>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Quantity" required error={over ? 'More than is free to reserve' : null}>
                <div className="flex gap-2"><Input inputMode="decimal" value={v.qty} onChange={(e) => setV({ ...v, qty: e.target.value })} />
                  <Select value={v.uom} onChange={(e) => setV({ ...v, uom: e.target.value })} className="w-28">{p.units.map((u) => <option key={u.uom_id} value={u.uom_id}>{u.code}</option>)}</Select></div>
              </Field>
              <Field label="Job / client reference" required><Input value={v.ref} onChange={(e) => setV({ ...v, ref: e.target.value })} placeholder="e.g. JOB-7781" /></Field>
              <Field label="Hold until" hint="Leave empty to hold until released"><Input type="date" value={v.expires} onChange={(e) => setV({ ...v, expires: e.target.value })} /></Field>
              <Field label="Notes"><Textarea rows={1} value={v.notes} onChange={(e) => setV({ ...v, notes: e.target.value })} /></Field>
            </div>
            <Button variant="primary" disabled={!v.ref.trim() || qty === null || isNaN(qty) || qty <= 0 || over} busy={txn.state.phase === 'saving'}
              onClick={async () => {
                const r = await txn.run({ p_product_id: p.product.id, p_warehouse_id: warehouseId, p_qty: qty, p_uom_id: v.uom || null, p_reference: v.ref.trim(),
                  p_expires_at: v.expires ? new Date(v.expires + 'T23:59:59+02:00').toISOString() : null, p_notes: v.notes || null });
                if (r) { setDone(`Reserved ${v.qty} ${unit?.code ?? ''} of ${p.product.sku} for ${v.ref.trim()}.`); onDone(); setP(null); setV({ qty: '', uom: '', ref: v.ref, expires: '', notes: '' }); }
              }}><BookmarkPlus className="size-4" />Reserve</Button>
          </div>
        ) : <p className="self-center text-sm text-steel-600">Scan or search for the item to reserve.</p>}
      </div>
      {done ? <Notice tone="ok" className="mt-3">{done}</Notice> : <div className="mt-3"><TxnOutcome state={txn.state} onRetry={txn.retry} /></div>}
    </Panel>
  );
}
