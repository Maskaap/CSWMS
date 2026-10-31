'use client';
import Link from 'next/link';
import { Suspense, useEffect, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { FilePlus2 } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, Field, PageHeader, Select, Spinner, StatusBadge, Stat, Table, Td, Th } from '@/components/ui';
import { ExportButtons, LoadError, Tabs } from '@/components/widgets';
import { callRpc } from '@/hooks/use-transaction';
import { fmtDate, fmtDateTime, fmtZAR } from '@/lib/format';

type Order = { id: string; order_no: string; origin: string; status: string; buyer: string; seller: string; from_warehouse: string; to_warehouse: string;
  needed_by: string | null; reference: string | null; requested_at: string; requested_by_name: string | null; transfer_id: string | null; transfer_no: string | null;
  lines: number; value: number | null; can_approve: boolean; can_dispatch: boolean };
type Invoice = { id: string; invoice_no: string; kind: string; status: string; seller: string; buyer: string; issue_date: string; due_date: string; is_overdue: boolean;
  subtotal: number; vat_amount: number; total: number; transfer_no: string | null; original_invoice_no: string | null; paid_on: string | null; side: 'sales' | 'purchases' };

const ORDER_STATUS = ['submitted', 'approved', 'in_transit', 'completed', 'rejected', 'cancelled'];

function Inner() {
  const sp = useSearchParams();
  const { can } = useApp();
  const [tab, setTab] = useState<'orders' | 'invoices'>(sp.get('tab') === 'invoices' ? 'invoices' : 'orders');
  const [status, setStatus] = useState('');
  const [orders, setOrders] = useState<Order[] | null>(null);
  const [invoices, setInvoices] = useState<Invoice[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const canInvoices = can('invoice.view');

  useEffect(() => {
    setError(null);
    if (tab === 'orders') { setOrders(null); callRpc<Order[]>('ic_orders_list', { p_status: status || null }).then(({ data, error }) => { setOrders(data ?? []); setError(error?.message ?? null); }); }
    else { setInvoices(null); callRpc<Invoice[]>('ic_invoices_list', { p_status: status || null }).then(({ data, error }) => { setInvoices(data ?? []); setError(error?.message ?? null); }); }
  }, [tab, status]);

  const waiting = orders?.filter((o) => o.can_approve).length ?? 0;
  const toDispatch = orders?.filter((o) => o.can_dispatch).length ?? 0;
  const owedToUs = invoices?.filter((i) => i.side === 'sales' && i.kind === 'invoice' && ['issued', 'partly_credited'].includes(i.status)).reduce((s, i) => s + Number(i.total), 0) ?? 0;
  const weOwe = invoices?.filter((i) => i.side === 'purchases' && i.kind === 'invoice' && ['issued', 'partly_credited'].includes(i.status)).reduce((s, i) => s + Number(i.total), 0) ?? 0;

  return (
    <>
      <PageHeader title="Inter-company orders & invoices"
        description="Stock one company supplies to another: the buyer orders, the seller approves and dispatches it as a transfer, and an invoice is issued automatically for what arrives."
        actions={can('intercompany.order') && <Link href="/intercompany/new"><Button variant="primary"><FilePlus2 className="size-4" />New order</Button></Link>} />
      <Tabs value={tab} onChange={(t) => { setTab(t); setStatus(''); }} tabs={[{ id: 'orders', label: 'Orders' }, { id: 'invoices', label: 'Invoices & credit notes', hidden: !canInvoices }]} />
      <LoadError error={error} />

      {tab === 'orders' && (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4">
            <Stat label="Waiting for your approval" value={waiting} tone={waiting ? 'warn' : undefined} />
            <Stat label="Approved, to dispatch" value={toDispatch} tone={toDispatch ? 'warn' : undefined} />
            <Stat label="In transit" value={orders?.filter((o) => o.status === 'in_transit').length ?? 0} />
            <Stat label="Orders listed" value={orders?.length ?? 0} />
          </div>
          <div className="mb-3 flex flex-wrap items-end gap-3">
            <Field label="Status"><Select value={status} onChange={(e) => setStatus(e.target.value)} className="w-48"><option value="">All</option>{ORDER_STATUS.map((s) => <option key={s} value={s}>{s.replace('_', ' ')}</option>)}</Select></Field>
            <div className="ml-auto"><ExportButtons title="Inter-company orders" rows={orders ?? []} cols={[
              { key: 'order_no', label: 'Order' }, { key: 'requested_at', label: 'Date', get: (r) => fmtDate(r.requested_at) }, { key: 'buyer', label: 'Buyer' }, { key: 'seller', label: 'Seller' },
              { key: 'from_warehouse', label: 'From' }, { key: 'to_warehouse', label: 'To' }, { key: 'status', label: 'Status' }, { key: 'lines', label: 'Lines', num: true },
              { key: 'value', label: 'Value excl. VAT', num: true }, { key: 'transfer_no', label: 'Transfer' }, { key: 'reference', label: 'Reference' }]} /></div>
          </div>
          {!orders ? <Spinner /> : (
            <Table>
              <thead><tr><Th>Order</Th><Th>Buyer ← Seller</Th><Th>Route</Th><Th>Status</Th><Th>Needed by</Th><Th right>Value excl. VAT</Th><Th>Transfer</Th></tr></thead>
              <tbody>
                {orders.map((o) => (
                  <tr key={o.id} className="hover:bg-steel-50">
                    <Td><Link href={`/intercompany/orders/${o.id}`} className="font-mono text-[13px] font-semibold hover:underline">{o.order_no}</Link>
                      <div className="text-xs text-steel-600">{fmtDateTime(o.requested_at)}{o.origin === 'transfer' ? ' · from transfer' : ''}</div></Td>
                    <Td><b>{o.buyer}</b> ← {o.seller}</Td>
                    <Td mono>{o.from_warehouse} → {o.to_warehouse}</Td>
                    <Td><StatusBadge status={o.status} />{o.can_approve && <Badge tone="warn" className="ml-1">your approval</Badge>}{o.can_dispatch && <Badge tone="info" className="ml-1">dispatch</Badge>}</Td>
                    <Td>{fmtDate(o.needed_by)}</Td>
                    <Td right>{o.value == null ? '—' : fmtZAR(o.value)}</Td>
                    <Td>{o.transfer_id ? <Link className="font-mono text-[13px] underline" href={`/transfers/${o.transfer_id}`}>{o.transfer_no}</Link> : '—'}</Td>
                  </tr>
                ))}
                {orders.length === 0 && <tr><Td className="text-steel-600">No orders.</Td></tr>}
              </tbody>
            </Table>
          )}
        </>
      )}

      {tab === 'invoices' && canInvoices && (
        <>
          <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4">
            <Stat label="Owed to my companies" value={fmtZAR(owedToUs)} />
            <Stat label="My companies owe" value={fmtZAR(weOwe)} />
            <Stat label="Overdue" value={invoices?.filter((i) => i.is_overdue).length ?? 0} tone={invoices?.some((i) => i.is_overdue) ? 'bad' : undefined} />
            <Stat label="Documents listed" value={invoices?.length ?? 0} />
          </div>
          <div className="mb-3 flex flex-wrap items-end gap-3">
            <Field label="Status"><Select value={status} onChange={(e) => setStatus(e.target.value)} className="w-48">
              <option value="">All</option><option value="issued">Unpaid</option><option value="overdue">Overdue</option><option value="paid">Paid</option>
              <option value="partly_credited">Partly credited</option><option value="credited">Credited</option></Select></Field>
            <Link href="/reports/accounting" className="mb-2 text-sm underline">Export to Xero / Sage</Link>
            <div className="ml-auto"><ExportButtons title="Inter-company invoices" rows={invoices ?? []} cols={[
              { key: 'invoice_no', label: 'Number' }, { key: 'kind', label: 'Type' }, { key: 'issue_date', label: 'Date', get: (r) => fmtDate(r.issue_date) },
              { key: 'due_date', label: 'Due', get: (r) => (r.kind === 'invoice' ? fmtDate(r.due_date) : '') }, { key: 'seller', label: 'Seller' }, { key: 'buyer', label: 'Buyer' },
              { key: 'subtotal', label: 'Excl. VAT', num: true }, { key: 'vat_amount', label: 'VAT', num: true }, { key: 'total', label: 'Total', num: true },
              { key: 'status', label: 'Status' }, { key: 'paid_on', label: 'Paid', get: (r) => fmtDate(r.paid_on) }, { key: 'transfer_no', label: 'Transfer' }]} /></div>
          </div>
          {!invoices ? <Spinner /> : (
            <Table>
              <thead><tr><Th>Number</Th><Th>Seller → Buyer</Th><Th>Date</Th><Th>Due</Th><Th right>Total incl. VAT</Th><Th>Status</Th><Th>Transfer</Th></tr></thead>
              <tbody>
                {invoices.map((i) => (
                  <tr key={i.id} className="hover:bg-steel-50">
                    <Td><Link href={`/intercompany/invoices/${i.id}`} className="font-mono text-[13px] font-semibold hover:underline">{i.invoice_no}</Link>
                      <div className="text-xs text-steel-600">{i.kind === 'credit_note' ? `Credit note on ${i.original_invoice_no}` : 'Invoice'} · {i.side === 'sales' ? 'we sold' : 'we bought'}</div></Td>
                    <Td>{i.seller} → {i.buyer}</Td>
                    <Td>{fmtDate(i.issue_date)}</Td>
                    <Td className={i.is_overdue ? 'font-semibold text-bad-600' : ''}>{i.kind === 'invoice' ? fmtDate(i.due_date) : '—'}</Td>
                    <Td right className={i.kind === 'credit_note' ? 'text-bad-600' : ''}>{i.kind === 'credit_note' ? '−' : ''}{fmtZAR(i.total)}</Td>
                    <Td><StatusBadge status={i.is_overdue ? 'overdue' : i.status} /></Td>
                    <Td mono>{i.transfer_no ?? '—'}</Td>
                  </tr>
                ))}
                {invoices.length === 0 && <tr><Td className="text-steel-600">No invoices.</Td></tr>}
              </tbody>
            </Table>
          )}
        </>
      )}
    </>
  );
}

export default function IntercompanyPage() {
  return <Suspense fallback={<Spinner />}><Inner /></Suspense>;
}
