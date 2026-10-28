'use client';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { useEffect, useState } from 'react';
import { FileDown, Pencil, Send, Truck } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { TxnOutcome } from '@/components/txn-outcome';
import { Badge, Button, Field, Input, Notice, OfflineNotice, PageHeader, Panel, Select, Spinner, StatusBadge, Table, Td, Th } from '@/components/ui';
import { ActionResult, KV, LoadError, useConfirm } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useLocations } from '@/hooks/use-ref-data';
import { useOnline } from '@/hooks/use-online';
import { useRows } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtDate, fmtDateTime, fmtQty, fmtZAR, parseQty } from '@/lib/format';
import { downloadPoPdf } from '@/lib/po-pdf';

type L = { id: string; line_no: number; product_id: string; sku: string; description: string; uom_id: string; uom_code: string; base_uom_code: string; factor: number;
  qty_ordered: number; qty_ordered_base: number; qty_received_base: number; unit_price: number; line_value: number; outstanding_base: number };
type Ap = { id: string; status: string; step_levels: string[]; steps_done: number; value_zar: number; decisions: { step: number; level: string; by: string; approved: boolean; note: string | null; at: string }[] | null };

const LEVEL: Record<string, string> = { any: 'Authorised approver', branch: 'Branch level or higher', company: 'Company level or higher', group: 'Head office' };

export default function PurchaseOrderPage() {
  const { id } = useParams<{ id: string }>();
  const { can } = useApp();
  const online = useOnline();
  const head = useRows<Record<string, any>>('poh' + id, (sb) => sb.from('v_purchase_orders').select('*').eq('id', id).maybeSingle());
  const lines = useRows<L>('pol' + id, (sb) => sb.from('v_purchase_order_lines').select('*').eq('po_id', id).order('line_no'));
  const appr = useRows<Ap>('poa' + id, (sb) => sb.from('v_approvals').select('id, status, step_levels, steps_done, value_zar, decisions').eq('purchase_order_id', id).order('requested_at', { ascending: false }).limit(1));
  const org = useRows<{ name: string }>('org', (sb) => sb.from('organisation').select('name').maybeSingle());
  const po = head.rows[0];
  const { data: locs } = useLocations(po?.warehouse_id ?? null);
  const act = useAction();
  const confirm = useConfirm();
  const rcv = useTransaction('receive_purchase_order');
  const [qty, setQty] = useState<Record<string, string>>({});
  const [loc, setLoc] = useState('');
  const [ref, setRef] = useState('');
  const reload = () => { head.reload(); lines.reload(); appr.reload(); };
  useEffect(() => { if (rcv.state.phase === 'saved') { reload(); setQty({}); setRef(''); } // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rcv.state.phase]);

  if (head.loading && !po) return <Spinner />;
  if (!po) return <><LoadError error={head.error} /><PageHeader title="Purchase order not found" /></>;
  const manage = can('purchase.manage', po.warehouse_id);
  const receivable = ['approved', 'sent', 'partially_received'].includes(po.status) && can('stock.receive', po.warehouse_id);
  const a = appr.rows[0];
  const recvLines = lines.rows.filter((l) => Number(l.outstanding_base) > 0).map((l) => {
    const v = qty[l.id] ?? ''; const n = parseQty(v);
    const base = n === null || isNaN(n) ? 0 : n * Number(l.factor);
    const err = v === '' ? null : n === null || isNaN(n) || n < 0 ? 'Not a valid quantity' : base > Number(l.outstanding_base) ? `More than the ${fmtQty(Number(l.outstanding_base) / Number(l.factor))} ${l.uom_code} outstanding` : null;
    return { l, v, n, err };
  });
  const recvReady = online && ref.trim() !== '' && recvLines.some((x) => x.n && x.n > 0) && recvLines.every((x) => !x.err);
  const run = async (fn: string, args: Record<string, unknown>, ok: string) => { if (await act.run(fn, args, ok)) reload(); };

  return (
    <>
      {confirm.node}
      <PageHeader title={`Purchase order ${po.po_no}`}
        description={<><StatusBadge status={po.status} />{po.is_overdue && <Badge tone="bad" className="ml-1">overdue</Badge>} · {po.supplier_name} → {po.warehouse_code} · {fmtZAR(po.total_value)} excl. VAT</>}
        actions={<>
          <Button size="sm" onClick={() => downloadPoPdf(org.rows[0]?.name ?? 'CSWMS', po as never, lines.rows)}><FileDown className="size-4" />PDF</Button>
          {po.status === 'draft' && manage && <Link href={`/purchasing/new?edit=${po.id}`}><Button size="sm"><Pencil className="size-4" />Edit</Button></Link>}
          {po.status === 'draft' && manage && <Button size="sm" variant="primary" busy={act.busy} onClick={async () => {
            const c = await confirm.ask({ title: 'Submit for approval?', body: `${po.po_no} for ${fmtZAR(po.total_value)} will be sent to the approvers. It can no longer be edited unless it is returned.` });
            if (c) run('submit_purchase_order', { p_po_id: po.id }, 'Submitted for approval.');
          }}><Send className="size-4" />Submit for approval</Button>}
          {po.status === 'approved' && manage && <Button size="sm" variant="primary" busy={act.busy} onClick={async () => {
            const c = await confirm.ask({ title: 'Mark as sent to the supplier?', body: 'Download the PDF and e-mail it to the supplier, then confirm here.', noteLabel: 'Supplier order / acknowledgement number (optional)' });
            if (c) run('send_purchase_order', { p_po_id: po.id, p_supplier_reference: c.note || null }, 'Marked as sent.');
          }}><Truck className="size-4" />Mark as sent</Button>}
          {po.status === 'partially_received' && manage && <Button size="sm" busy={act.busy} onClick={async () => {
            const c = await confirm.ask({ title: 'Close this order short?', body: 'The outstanding quantities will no longer be expected.', noteLabel: 'Reason', noteRequired: true });
            if (c) run('close_purchase_order', { p_po_id: po.id, p_reason: c.note }, 'Order closed.');
          }}>Close short</Button>}
          {['draft', 'pending_approval', 'approved', 'sent'].includes(po.status) && manage && <Button size="sm" variant="danger" busy={act.busy} onClick={async () => {
            const c = await confirm.ask({ title: 'Cancel this purchase order?', body: 'It stays on record as cancelled.', noteLabel: 'Reason', noteRequired: true, danger: true });
            if (c) run('cancel_purchase_order', { p_po_id: po.id, p_reason: c.note }, 'Order cancelled.');
          }}>Cancel</Button>}
        </>} />
      {!online && <OfflineNotice />}
      <div className="space-y-6">
        <ActionResult error={act.error} ok={act.ok} />
        {rcv.state.phase === 'saved' && <TxnOutcome state={rcv.state} onRetry={rcv.retry} savedText={(r) => <>Receipt posted. Order is now <b>{String(r.po_status).replace('_', ' ')}</b>.</>} />}
        <Panel>
          <KV items={[
            ['Supplier', `${po.supplier_name}${po.supplier_email ? ' · ' + po.supplier_email : ''}`], ['Deliver to', `${po.warehouse_code} — ${po.warehouse_name} (${po.branch_code})`],
            ['Buying company', po.owner_company_code], ['Expected delivery', fmtDate(po.expected_date)], ['Supplier reference', po.supplier_reference],
            ['Created', `${po.created_by_name} · ${fmtDateTime(po.created_at)}`], ['Approved', po.approved_by_name ? `${po.approved_by_name} · ${fmtDateTime(po.approved_at)}` : null],
            ['Sent', fmtDateTime(po.sent_at)], ['Closed / cancelled', po.closed_at ? `${fmtDateTime(po.closed_at)} — ${po.close_reason ?? ''}` : null],
            ['Notes', po.notes ? <span className="whitespace-pre-line">{po.notes}</span> : null],
          ]} />
        </Panel>

        {a && (
          <Panel title="Approval">
            <div className="flex flex-wrap items-center gap-2">
              {a.step_levels.map((lv, i) => {
                const d = a.decisions?.find((x) => x.step === i + 1);
                return (
                  <div key={i} className="flex items-center gap-2">
                    {i > 0 && <span className="text-steel-400">→</span>}
                    <div className={`rounded-md border px-3 py-2 text-sm ${d ? (d.approved ? 'border-ok-600 bg-ok-50' : 'border-bad-600 bg-bad-50') : i === a.steps_done && a.status === 'pending' ? 'border-warn-600 bg-warn-50' : 'border-steel-200'}`}>
                      <div className="font-medium">Level {i + 1}: {LEVEL[lv] ?? lv}</div>
                      <div className="text-xs text-steel-600">{d ? `${d.approved ? 'Approved' : 'Rejected'} by ${d.by} · ${fmtDateTime(d.at)}` : i === a.steps_done && a.status === 'pending' ? 'Waiting' : '—'}</div>
                      {d?.note && <div className="text-xs">{d.note}</div>}
                    </div>
                  </div>
                );
              })}
              <StatusBadge status={a.status} />
            </div>
            {a.status === 'pending' && <p className="mt-2 text-sm"><Link className="underline" href="/approvals">Open Approvals</Link> to decide.</p>}
          </Panel>
        )}

        <Panel title="Lines" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>#</Th><Th>Product</Th><Th right>Ordered</Th><Th right>Unit price</Th><Th right>Amount</Th><Th right>Received</Th><Th right>Outstanding</Th></tr></thead>
            <tbody>{lines.rows.map((l) => (
              <tr key={l.id}><Td>{l.line_no}</Td><Td><span className="font-mono text-[13px]">{l.sku}</span> {l.description}</Td>
                <Td right>{fmtQty(l.qty_ordered)} {l.uom_code}{Number(l.factor) !== 1 && <div className="text-xs text-steel-600">= {fmtQty(l.qty_ordered_base)} {l.base_uom_code}</div>}</Td>
                <Td right>{fmtZAR(l.unit_price)}</Td><Td right>{fmtZAR(l.line_value)}</Td>
                <Td right>{fmtQty(l.qty_received_base)} {l.base_uom_code}</Td>
                <Td right className={Number(l.outstanding_base) > 0 ? 'font-semibold text-warn-600' : 'text-ok-600'}>{fmtQty(l.outstanding_base)}</Td></tr>
            ))}</tbody>
            <tfoot><tr><Td /><Td className="font-semibold">Total excl. VAT</Td><Td /><Td /><Td right className="font-semibold">{fmtZAR(po.total_value)}</Td><Td /><Td /></tr></tfoot>
          </Table>
        </Panel>

        {receivable && recvLines.length > 0 && (
          <Panel title="Receive delivery against this order">
            <p className="mb-3 text-sm text-steel-600">Count what arrived. Leave a line empty if it did not arrive. You cannot receive more than is outstanding — extra stock must be received separately.</p>
            <div className="mb-3 grid gap-3 sm:grid-cols-2">
              <Field label="Supplier delivery note number" required><Input value={ref} onChange={(e) => setRef(e.target.value)} placeholder="e.g. DN 40213" /></Field>
              <Field label="Put away at"><Select value={loc} onChange={(e) => setLoc(e.target.value)}><option value="">Receiving area (default)</option>{locs.map((x) => <option key={x.id} value={x.id}>{x.code} — {x.name}</option>)}</Select></Field>
            </div>
            <Table>
              <thead><tr><Th>Product</Th><Th right>Outstanding</Th><Th>Received now</Th></tr></thead>
              <tbody>{recvLines.map(({ l, v, err }) => (
                <tr key={l.id}><Td><span className="font-mono text-[13px]">{l.sku}</span> {l.description}</Td>
                  <Td right>{fmtQty(Number(l.outstanding_base) / Number(l.factor))} {l.uom_code}</Td>
                  <Td><div className="flex items-center gap-2"><Input inputMode="decimal" className="w-28 text-right" value={v} onChange={(e) => setQty({ ...qty, [l.id]: e.target.value })} aria-label={`Received ${l.sku}`} />
                    <span className="text-sm">{l.uom_code}</span>
                    <button type="button" className="text-xs underline" onClick={() => setQty({ ...qty, [l.id]: String(Number(l.outstanding_base) / Number(l.factor)) })}>all</button></div>
                    {err && <div className="text-xs text-bad-600">{err}</div>}</Td></tr>
              ))}</tbody>
            </Table>
            {rcv.state.phase !== 'saved' && <div className="mt-3"><TxnOutcome state={rcv.state} onRetry={rcv.retry} /></div>}
            <Button className="mt-3" variant="primary" size="lg" disabled={!recvReady} busy={rcv.state.phase === 'saving'} onClick={() => rcv.run({
              p_po_id: po.id, p_reference: ref.trim(), p_notes: null,
              p_lines: recvLines.filter((x) => x.n && x.n > 0).map((x) => ({ po_line_id: x.l.id, qty: x.n, uom_id: x.l.uom_id, location_id: loc || undefined })),
            })}>Confirm receipt</Button>
          </Panel>
        )}
        {po.status === 'received' && <Notice tone="ok" title="Received in full" />}
      </div>
    </>
  );
}
