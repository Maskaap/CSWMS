'use client';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { useState } from 'react';
import { Check, FileDown, Truck, X } from 'lucide-react';
import { TxnOutcome } from '@/components/txn-outcome';
import { Badge, Button, Input, Notice, PageHeader, Panel, Spinner, StatusBadge, Table, Td, Th } from '@/components/ui';
import { ActionResult, KV, LoadError, useConfirm } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useRpc } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtDate, fmtDateTime, fmtQty, fmtZAR, parseQty } from '@/lib/format';
import { downloadIcOrderPdf, type OrderDoc } from '@/lib/ic-pdf';

type Line = OrderDoc['lines'][number] & { id: string; product_id: string; qty_received: number; available_at_seller: number };
type Detail = Omit<OrderDoc, 'lines'> & { id: string; origin: string; decision_note: string | null; lines: Line[];
  transfer: { id: string; transfer_no: string; status: string } | null; can_approve: boolean; can_set_prices: boolean; can_dispatch: boolean; can_cancel: boolean;
  invoices: { id: string; invoice_no: string; kind: string; status: string; total: number; issue_date: string }[] };

export default function IcOrderPage() {
  const { id } = useParams<{ id: string }>();
  const { data: o, loading, error, reload } = useRpc<Detail>('ico' + id, 'ic_order_detail', { p_order_id: id });
  const act = useAction();
  const confirm = useConfirm();
  const dispatch = useTransaction('create_transfer_from_ic_order');
  const [prices, setPrices] = useState<Record<string, string>>({});

  if (loading) return <Spinner />;
  if (!o) return <><LoadError error={error} /><PageHeader title="Order not found" /></>;
  const short = o.lines.filter((l) => Number(l.available_at_seller) < Number(l.qty_base));
  const priceOf = (l: Line) => (prices[l.id] !== undefined ? parseQty(prices[l.id]) : Number(l.unit_price ?? 0));
  const changed = Object.entries(prices).filter(([, v]) => v !== '').map(([line_id, v]) => ({ line_id, unit_price: parseQty(v) }));
  const pricesOk = changed.every((c) => c.unit_price !== null && !isNaN(c.unit_price) && c.unit_price >= 0);

  return (
    <>
      {confirm.node}
      <PageHeader title={`Inter-company order ${o.order_no}`}
        description={<><StatusBadge status={o.status} /> · {o.buyer.code} orders from {o.seller.code}{o.origin === 'transfer' && <Badge tone="info" className="ml-2">recorded from a transfer</Badge>}</>}
        actions={<Button size="sm" onClick={() => downloadIcOrderPdf(o)}><FileDown className="size-4" />PDF</Button>} />
      <ActionResult error={act.error} ok={act.ok} />
      <div className="space-y-6">
        <Panel>
          <KV items={[
            ['Buyer', `${o.buyer.code} — ${o.buyer.legal_name}`], ['Seller', `${o.seller.code} — ${o.seller.legal_name}`],
            ['Supply from', `${o.from_warehouse.code} — ${o.from_warehouse.name}`], ['Deliver to', `${o.to_warehouse.code} — ${o.to_warehouse.name}`],
            ['Ordered', `${o.requested_by_name ?? ''} · ${fmtDateTime(o.requested_at)}`], ['Needed by', fmtDate(o.needed_by)], ['Reference', o.reference], ['Notes', o.notes],
            ['Decision', o.decided_at ? `${o.decided_by_name ?? ''} · ${fmtDateTime(o.decided_at)}${o.decision_note ? ' — ' + o.decision_note : ''}` : null],
            ['Transfer', o.transfer ? <Link className="underline" href={`/transfers/${o.transfer.id}`}>{o.transfer.transfer_no} ({o.transfer.status.replace(/_/g, ' ')})</Link> : null],
          ]} />
        </Panel>

        <Panel title="Lines" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>#</Th><Th>Product</Th><Th right>Ordered</Th><Th right>Base units</Th><Th right>Seller has</Th><Th right>Received</Th>
              {o.show_prices && <><Th right>Price / base unit</Th><Th right>Amount</Th></>}</tr></thead>
            <tbody>{o.lines.map((l) => (
              <tr key={l.id}>
                <Td>{l.line_no}</Td><Td><span className="font-mono text-[13px]">{l.sku}</span> {l.description}</Td>
                <Td right>{fmtQty(l.entered_qty)} {l.entered_uom}</Td><Td right>{fmtQty(l.qty_base)} {l.base_uom}</Td>
                <Td right className={Number(l.available_at_seller) < Number(l.qty_base) && o.status !== 'completed' ? 'text-bad-600' : ''}>{fmtQty(l.available_at_seller)}</Td>
                <Td right>{fmtQty(l.qty_received)}</Td>
                {o.show_prices && <>
                  <Td right>{o.can_set_prices
                    ? <Input inputMode="decimal" className="ml-auto w-28 text-right" placeholder={String(Number(l.unit_price ?? 0))} value={prices[l.id] ?? ''}
                        onChange={(e) => setPrices((p) => ({ ...p, [l.id]: e.target.value }))} aria-label={`Price of ${l.sku}`} />
                    : fmtZAR(l.unit_price)}</Td>
                  <Td right>{fmtZAR(Number(l.qty_base) * Number(priceOf(l) ?? 0))}</Td></>}
              </tr>))}</tbody>
            {o.show_prices && <tfoot><tr><Td /><Td>Total excl. VAT</Td><Td /><Td /><Td /><Td /><Td />
              <Td right className="font-semibold">{fmtZAR(o.lines.reduce((s, l) => s + Number(l.qty_base) * Number(priceOf(l) ?? 0), 0))}</Td></tr></tfoot>}
          </Table>
        </Panel>

        {o.can_approve && (
          <Panel title="Approve as the supplying company">
            {short.length > 0 && <Notice tone="warn" className="mb-3">Not enough stock of {o.seller.code} at {o.from_warehouse.code} for: {short.map((l) => l.sku).join(', ')}. You can approve and dispatch once it is in stock.</Notice>}
            {o.can_set_prices && <p className="mb-3 text-sm text-steel-600">Prices default to weighted-average cost plus the group mark-up. Type a price to agree a different one; it is used on the invoice.</p>}
            <div className="flex flex-wrap gap-2">
              <Button variant="primary" busy={act.busy} disabled={!pricesOk} onClick={async () => {
                const c = await confirm.ask({ title: `Approve ${o.order_no}?`, body: 'The order can then be dispatched as a transfer. The invoice is issued automatically when the buyer receives the stock.', noteLabel: 'Note to the buyer (optional)' });
                if (c && await act.run('decide_ic_order', { p_order_id: o.id, p_approve: true, p_note: c.note || null, p_prices: changed.length ? changed : null }, 'Order approved.')) { setPrices({}); reload(); }
              }}><Check className="size-4" />Approve</Button>
              <Button variant="danger" busy={act.busy} onClick={async () => {
                const c = await confirm.ask({ title: `Reject ${o.order_no}?`, body: 'The buyer is told why.', noteLabel: 'Reason', noteRequired: true, danger: true });
                if (c && await act.run('decide_ic_order', { p_order_id: o.id, p_approve: false, p_note: c.note }, 'Order rejected.')) reload();
              }}><X className="size-4" />Reject</Button>
            </div>
          </Panel>
        )}

        {o.can_dispatch && (
          <Panel title="Dispatch">
            <p className="mb-3 text-sm text-steel-600">Creates the transfer to {o.to_warehouse.code} and dispatches it now. The stock is taken from {o.seller.code}&apos;s own stock at {o.from_warehouse.code}, fullest bins first. Ownership passes to {o.buyer.code} on receipt.</p>
            <TxnOutcome state={dispatch.state} onRetry={dispatch.retry} savedText={(r) => <>Dispatched as <Link className="underline" href={`/transfers/${String(r.transfer_id)}`}>{String(r.transfer_no)}</Link>.</>} />
            <Button className="mt-3" variant="navy" busy={dispatch.state.phase === 'saving'} disabled={short.length > 0}
              onClick={async () => { if (await dispatch.run({ p_order_id: o.id })) reload(); }}><Truck className="size-4" />Create transfer and dispatch</Button>
          </Panel>
        )}

        {o.invoices.length > 0 && (
          <Panel title="Invoices" padded={false}>
            <Table className="rounded-none border-0">
              <thead><tr><Th>Number</Th><Th>Date</Th><Th right>Total incl. VAT</Th><Th>Status</Th></tr></thead>
              <tbody>{o.invoices.map((i) => (
                <tr key={i.id}><Td><Link className="font-mono text-[13px] underline" href={`/intercompany/invoices/${i.id}`}>{i.invoice_no}</Link>{i.kind === 'credit_note' && ' (credit note)'}</Td>
                  <Td>{fmtDate(i.issue_date)}</Td><Td right>{fmtZAR(i.total)}</Td><Td><StatusBadge status={i.status} /></Td></tr>))}</tbody>
            </Table>
          </Panel>
        )}

        {o.can_cancel && (
          <div><Button variant="ghost" onClick={async () => {
            const c = await confirm.ask({ title: `Cancel ${o.order_no}?`, body: 'Nothing has been dispatched yet.', noteLabel: 'Reason', noteRequired: true, danger: true });
            if (c && await act.run('cancel_ic_order', { p_order_id: o.id, p_reason: c.note }, 'Order cancelled.')) reload();
          }}>Cancel order</Button></div>
        )}
      </div>
    </>
  );
}
