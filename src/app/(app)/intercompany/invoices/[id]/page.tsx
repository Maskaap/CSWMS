'use client';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { useState } from 'react';
import { BadgeCheck, FileDown, ReceiptText } from 'lucide-react';
import { TxnOutcome } from '@/components/txn-outcome';
import { Button, Field, Input, Notice, PageHeader, Panel, Spinner, StatusBadge, Table, Td, Th } from '@/components/ui';
import { ActionResult, KV, LoadError } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useRpc } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtDate, fmtQty, fmtZAR, parseQty, todayISO } from '@/lib/format';
import { downloadIcInvoicePdf, type InvoiceDoc } from '@/lib/ic-pdf';

type Line = InvoiceDoc['lines'][number] & { id: string; credited: number };
type Detail = Omit<InvoiceDoc, 'lines' | 'transfer'> & { id: string; lines: Line[]; transfer: (InvoiceDoc['transfer'] & { id: string }) | null; can_manage: boolean;
  credit_notes: { id: string; invoice_no: string; total: number; issue_date: string }[]; original_invoice_id: string | null; issued_by_name: string | null };

export default function IcInvoicePage() {
  const { id } = useParams<{ id: string }>();
  const { data: i, loading, error, reload } = useRpc<Detail>('ici' + id, 'ic_invoice_detail', { p_invoice_id: id });
  const pay = useAction();
  const credit = useTransaction('credit_ic_invoice');
  const [paidOn, setPaidOn] = useState(todayISO());
  const [payRef, setPayRef] = useState('');
  const [showCredit, setShowCredit] = useState(false);
  const [reason, setReason] = useState('');
  const [qty, setQty] = useState<Record<string, string>>({});

  if (loading) return <Spinner />;
  if (!i) return <><LoadError error={error} /><PageHeader title="Invoice not found" /></>;
  const isInv = i.kind === 'invoice';
  const open = (l: Line) => Number(l.qty) - Number(l.credited);
  const creditLines = i.lines.map((l) => ({ invoice_line_id: l.id, qty: parseQty(qty[l.id] ?? '') ?? 0 })).filter((x) => x.qty > 0);
  const creditBad = i.lines.some((l) => { const q = parseQty(qty[l.id] ?? ''); return q !== null && (isNaN(q) || q < 0 || q > open(l)); });
  const creditValue = i.lines.reduce((s, l) => s + (parseQty(qty[l.id] ?? '') || 0) * Number(l.unit_price), 0) * (1 + Number(i.vat_rate) / 100);

  return (
    <>
      <PageHeader title={`${i.title} ${i.invoice_no}`}
        description={<><StatusBadge status={i.status} /> · {i.seller_snapshot.code} → {i.buyer_snapshot.code} · {fmtDate(i.issue_date)}</>}
        actions={<Button size="sm" variant="primary" onClick={() => downloadIcInvoicePdf(i)}><FileDown className="size-4" />PDF</Button>} />
      <div className="space-y-6">
        <div className="grid gap-4 md:grid-cols-2">
          {[['From (supplier)', i.seller_snapshot], ['To (recipient)', i.buyer_snapshot]].map(([label, p]) => {
            const x = p as InvoiceDoc['seller_snapshot'];
            return (
              <Panel key={label as string} title={label as string}>
                <div className="text-sm"><div className="font-semibold text-navy-900">{x.legal_name}</div>
                  {x.address && <div className="whitespace-pre-line text-steel-600">{x.address}</div>}
                  {x.vat_number && <div>VAT no. {x.vat_number}</div>}{x.registration_number && <div>Reg. no. {x.registration_number}</div>}</div>
              </Panel>
            );
          })}
        </div>
        {!i.seller_snapshot.vat_number && isInv && <Notice tone="info">The selling company has no VAT number on record, so this is an invoice without VAT. Add the VAT number under Company setup for future invoices.</Notice>}
        <Panel>
          <KV items={[
            ['Invoice date', fmtDate(i.issue_date)], ['Due date', isInv ? fmtDate(i.due_date) : null],
            ['Credit against', i.original_invoice_id ? <Link className="underline" href={`/intercompany/invoices/${i.original_invoice_id}`}>{i.original_invoice_no}</Link> : null],
            ['Reason', i.reason], ['Order', i.order_no],
            ['Transfer', i.transfer ? <Link className="underline" href={`/transfers/${i.transfer.id}`}>{i.transfer.transfer_no}: {i.transfer.from} → {i.transfer.to}</Link> : null],
            ['Goods received', i.receipt_txn_no], ['Paid', i.paid_on ? `${fmtDate(i.paid_on)} · ${i.paid_reference}` : null],
            ['Credit notes', i.credit_notes.length ? i.credit_notes.map((c, n) => <span key={c.id}>{n ? ', ' : ''}<Link className="underline" href={`/intercompany/invoices/${c.id}`}>{c.invoice_no}</Link> ({fmtZAR(c.total)})</span>) : null],
          ]} />
        </Panel>
        <Panel title="Lines" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>#</Th><Th>Description</Th><Th right>Qty</Th><Th>Unit</Th><Th right>Unit price excl. VAT</Th><Th right>Amount excl. VAT</Th>{isInv && i.credit_notes.length > 0 && <Th right>Credited</Th>}</tr></thead>
            <tbody>{i.lines.map((l) => (
              <tr key={l.id}><Td>{l.line_no}</Td><Td>{l.description}</Td><Td right>{fmtQty(l.qty)}</Td><Td>{l.uom}</Td><Td right>{fmtZAR(l.unit_price)}</Td><Td right>{fmtZAR(l.line_total)}</Td>
                {isInv && i.credit_notes.length > 0 && <Td right>{fmtQty(l.credited)}</Td>}</tr>))}</tbody>
            <tfoot>
              <tr><Td /><Td /><Td /><Td /><Td right>Total excl. VAT</Td><Td right>{fmtZAR(i.subtotal)}</Td></tr>
              <tr><Td /><Td /><Td /><Td /><Td right>VAT {fmtQty(i.vat_rate)} %</Td><Td right>{fmtZAR(i.vat_amount)}</Td></tr>
              <tr><Td /><Td /><Td /><Td /><Td right className="font-semibold">{isInv ? 'Total incl. VAT' : 'Total credited'}</Td><Td right className="font-semibold">{fmtZAR(i.total)}</Td></tr>
            </tfoot>
          </Table>
        </Panel>

        {i.can_manage && isInv && i.status !== 'paid' && i.status !== 'credited' && (
          <Panel title={<span className="flex items-center gap-2"><BadgeCheck className="size-4" />Record payment received</span>}>
            <div className="flex flex-wrap items-end gap-3">
              <Field label="Paid on"><Input type="date" max={todayISO()} min={i.issue_date} value={paidOn} onChange={(e) => setPaidOn(e.target.value)} /></Field>
              <Field label="Payment reference"><Input value={payRef} onChange={(e) => setPayRef(e.target.value)} placeholder="e.g. EFT 12345" /></Field>
              <Button variant="navy" busy={pay.busy} disabled={!payRef.trim()} onClick={async () => {
                if (await pay.run('record_ic_payment', { p_invoice_id: i.id, p_paid_on: paidOn, p_reference: payRef }, 'Payment recorded.')) reload();
              }}>Mark as paid</Button>
            </div>
            <ActionResult error={pay.error} ok={pay.ok} />
          </Panel>
        )}

        {i.can_manage && isInv && i.status !== 'credited' && (
          <Panel title={<span className="flex items-center gap-2"><ReceiptText className="size-4" />Credit note</span>}>
            {!showCredit ? <Button onClick={() => setShowCredit(true)}>Issue a credit note…</Button> : (
              <div className="space-y-3">
                <p className="text-sm text-steel-600">Enter the quantity to credit per line (e.g. stock damaged in transit or returned). The invoice itself is never changed.</p>
                <Table>
                  <thead><tr><Th>Description</Th><Th right>Still open</Th><Th right>Credit qty</Th></tr></thead>
                  <tbody>{i.lines.map((l) => (
                    <tr key={l.id}><Td>{l.description}</Td><Td right>{fmtQty(open(l))} {l.uom}</Td>
                      <Td right><Input inputMode="decimal" className="ml-auto w-24 text-right" value={qty[l.id] ?? ''} disabled={open(l) <= 0}
                        onChange={(e) => setQty((q) => ({ ...q, [l.id]: e.target.value }))} aria-label={`Credit quantity line ${l.line_no}`} /></Td></tr>))}</tbody>
                </Table>
                <div className="flex flex-wrap gap-2 text-sm">
                  <button type="button" className="underline" onClick={() => setQty(Object.fromEntries(i.lines.map((l) => [l.id, String(open(l))])))}>Credit everything still open</button>
                  <span className="text-steel-600">· Credit value incl. VAT: <b>{fmtZAR(creditValue)}</b></span>
                </div>
                <Field label="Reason" required><Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. 1 drum damaged in transit" /></Field>
                <TxnOutcome state={credit.state} onRetry={credit.retry} savedText={(r) => <>Credit note <Link className="underline" href={`/intercompany/invoices/${String(r.credit_note_id)}`}>{String(r.credit_note_no)}</Link> issued for {fmtZAR(r.total as number)}.</>} />
                <Button variant="danger" disabled={!reason.trim() || creditBad || creditLines.length === 0} busy={credit.state.phase === 'saving'}
                  onClick={async () => { if (await credit.run({ p_invoice_id: i.id, p_reason: reason.trim(), p_lines: creditLines })) { setQty({}); reload(); } }}>Issue credit note</Button>
              </div>
            )}
          </Panel>
        )}
      </div>
    </>
  );
}
