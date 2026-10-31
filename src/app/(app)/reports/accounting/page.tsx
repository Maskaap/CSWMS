'use client';
import { useState } from 'react';
import { Download, Landmark } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Button, Field, Input, Notice, PageHeader, Panel, Select, Spinner, Table, Td, Th } from '@/components/ui';
import { useCompanies } from '@/hooks/use-ref-data';
import { callRpc } from '@/hooks/use-transaction';
import { exportCSV, exportXLSX, type Col } from '@/lib/export';
import { fmtDate, fmtZAR, todayISO } from '@/lib/format';

type J = { date: string; reference: string; group: string; description: string; account: string; debit: number; credit: number; amount: number; tax_rate: string };
const ddmmyyyy = (iso: string) => { const [y, m, d] = iso.slice(0, 10).split('-'); return `${d}/${m}/${y}`; };
const firstOfMonth = () => todayISO().slice(0, 8) + '01';

export default function AccountingExportPage() {
  const { can } = useApp();
  const { data: companies } = useCompanies();
  const [company, setCompany] = useState('');
  const [from, setFrom] = useState(firstOfMonth());
  const [to, setTo] = useState(todayISO());
  const [rows, setRows] = useState<J[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  if ((!can('cost.view') || !can('reports.view')) && !can('invoice.view')) return <Notice tone="bad">The accounting export needs permission to run reports and view prices.</Notice>;
  const co = companies.find((c) => c.id === company);
  const run = async () => {
    setBusy(true); setErr(null);
    const { data, error } = await callRpc<J[]>('accounting_journal', { p_from: from, p_to: to, p_company: company || null });
    setBusy(false);
    if (error) { setErr(error.message); setRows(null); return; }
    setRows((data ?? []).map((r) => ({ ...r, debit: Number(r.debit), credit: Number(r.credit), amount: Number(r.amount) })));
  };
  const dr = rows?.reduce((s, r) => s + r.debit, 0) ?? 0; const cr = rows?.reduce((s, r) => s + r.credit, 0) ?? 0;
  const title = `Stock journal ${co?.code ?? ''} ${from} to ${to}`;

  // Xero "Manual journal" import: one journal per narration + date; positive = debit, negative = credit
  const xero: Col<J>[] = [
    { key: 'n', label: '*Narration', get: (r) => r.reference }, { key: 'd', label: '*Date', get: (r) => ddmmyyyy(r.date) },
    { key: 'description', label: 'Description' }, { key: 'account', label: '*AccountCode' }, { key: 'tax_rate', label: '*TaxRate' },
    { key: 'amount', label: '*Amount', get: (r) => r.amount.toFixed(2) },
  ];
  // Sage Business Cloud Accounting journal import (debit / credit columns)
  const sage: Col<J>[] = [
    { key: 'd', label: 'Date', get: (r) => ddmmyyyy(r.date) }, { key: 'reference', label: 'Reference' }, { key: 'account', label: 'Account' },
    { key: 'description', label: 'Description' }, { key: 'debit', label: 'Debit', get: (r) => (r.debit ? r.debit.toFixed(2) : '') },
    { key: 'credit', label: 'Credit', get: (r) => (r.credit ? r.credit.toFixed(2) : '') },
  ];
  const full: Col<J>[] = [{ key: 'date', label: 'Date', get: (r) => fmtDate(r.date) }, { key: 'reference', label: 'Reference' }, { key: 'group', label: 'Type' },
    { key: 'description', label: 'Description' }, { key: 'account', label: 'Account' }, { key: 'debit', label: 'Debit', num: true }, { key: 'credit', label: 'Credit', num: true }];

  return (
    <>
      <PageHeader title="Accounting export (Xero / Sage)" description="A balanced daily journal of stock movements at weighted-average cost, ready to import into your accounting system. Account codes are set under System Administration → Settings → accounting." />
      <Panel className="mb-6">
        <div className="flex flex-wrap items-end gap-3">
          <Field label="Company (each company has its own books)" required>
            <Select value={company} onChange={(e) => setCompany(e.target.value)} className="w-72"><option value="">— choose —</option>{companies.map((c) => <option key={c.id} value={c.id}>{c.code} — {c.name}</option>)}</Select>
          </Field>
          <Field label="From"><Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
          <Field label="To"><Input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
          <Button variant="navy" busy={busy} disabled={!company} onClick={run}><Landmark className="size-4" />Prepare journal</Button>
        </div>
      </Panel>
      {err && <Notice tone="bad" className="mb-4">{err}</Notice>}
      {busy && <Spinner />}
      {rows && (
        <Panel title={`${rows.length} journal lines · debits ${fmtZAR(dr)} · credits ${fmtZAR(cr)}`} padded={false}
          actions={<div className="flex flex-wrap gap-2">
            <Button size="sm" variant="primary" disabled={!rows.length} onClick={() => exportCSV(`Xero ${title}`, xero, rows)}><Download className="size-4" />Xero CSV</Button>
            <Button size="sm" variant="primary" disabled={!rows.length} onClick={() => exportCSV(`Sage ${title}`, sage, rows)}><Download className="size-4" />Sage CSV</Button>
            <Button size="sm" disabled={!rows.length} onClick={() => exportXLSX(title, full, rows, `${co?.name ?? ''} · ${fmtDate(from)} – ${fmtDate(to)}`)}><Download className="size-4" />Excel</Button>
          </div>}>
          {Math.abs(dr - cr) > 0.005 && <Notice tone="bad" className="m-3">The journal does not balance — do not import it. Report this to the system administrator.</Notice>}
          <Table className="rounded-none border-0">
            <thead><tr><Th>Date</Th><Th>Reference</Th><Th>Description</Th><Th>Account</Th><Th right>Debit</Th><Th right>Credit</Th></tr></thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={i}><Td>{fmtDate(r.date)}</Td><Td mono>{r.reference}</Td><Td>{r.description}</Td><Td mono>{r.account}</Td>
                  <Td right>{r.debit ? fmtZAR(r.debit) : ''}</Td><Td right>{r.credit ? fmtZAR(r.credit) : ''}</Td></tr>
              ))}
              {rows.length === 0 && <tr><Td className="text-steel-600">No valued stock movements for this company in this period.</Td></tr>}
            </tbody>
          </Table>
        </Panel>
      )}
      {can('invoice.view') && <IcInvoiceExport company={company} from={from} to={to} companyCode={co?.code ?? ''} />}
      <p className="mt-4 text-xs text-steel-600">How it works: every day&apos;s movements are grouped (received, issued net of returns, between companies, adjustments and stocktake variances, opening balances).
        Each group debits or credits the stock-on-hand account against its own account, valued at the weighted-average purchase cost. Items without a purchase price are valued at R0.
        Check the account codes with your accountant before the first import. In Xero use <i>Accounting → Manual journals → Import</i>; in Sage use the journal import (map the columns if your edition asks).</p>
    </>
  );
}

type IcRow = { side: 'sales' | 'purchases'; contact: string; invoice_no: string; kind: string; reference: string; issue_date: string; due_date: string;
  description: string; qty: number; unit_price: number; line_total: number; vat_rate: number; account: string; tax_type: string };

/** Inter-company invoices and credit notes of one company, as Xero sales invoices / bills or a Sage import */
function IcInvoiceExport({ company, from, to, companyCode }: { company: string; from: string; to: string; companyCode: string }) {
  const [rows, setRows] = useState<IcRow[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const load = async () => {
    setBusy(true); setErr(null);
    const { data, error } = await callRpc<IcRow[]>('ic_invoice_export', { p_company: company || null, p_from: from, p_to: to });
    setBusy(false);
    if (error) { setErr(error.message); setRows(null); return; }
    setRows((data ?? []).map((r) => ({ ...r, qty: Number(r.qty), unit_price: Number(r.unit_price), line_total: Number(r.line_total) })));
  };
  const xero: Col<IcRow>[] = [
    { key: 'contact', label: '*ContactName' }, { key: 'invoice_no', label: '*InvoiceNumber' }, { key: 'reference', label: 'Reference' },
    { key: 'd', label: '*InvoiceDate', get: (r) => ddmmyyyy(r.issue_date) }, { key: 'due', label: '*DueDate', get: (r) => ddmmyyyy(r.due_date) },
    { key: 'description', label: '*Description' }, { key: 'qty', label: '*Quantity' }, { key: 'unit_price', label: '*UnitAmount', get: (r) => r.unit_price.toFixed(4) },
    { key: 'account', label: '*AccountCode' }, { key: 'tax_type', label: '*TaxType' },
  ];
  const sage = (side: 'sales' | 'purchases'): Col<IcRow>[] => [
    { key: 'd', label: 'Date', get: (r) => ddmmyyyy(r.issue_date) }, { key: 'invoice_no', label: 'Document No' }, { key: 'kind', label: 'Type', get: (r) => (r.kind === 'credit_note' ? 'Credit Note' : 'Invoice') },
    { key: 'contact', label: side === 'sales' ? 'Customer' : 'Supplier' }, { key: 'description', label: 'Description' }, { key: 'qty', label: 'Quantity' },
    { key: 'unit_price', label: 'Unit Price Excl', get: (r) => r.unit_price.toFixed(4) }, { key: 'vat_rate', label: 'VAT %' },
    { key: 'line_total', label: 'Amount Excl', get: (r) => r.line_total.toFixed(2) }, { key: 'account', label: 'Account' },
  ];
  const sales = rows?.filter((r) => r.side === 'sales') ?? []; const purchases = rows?.filter((r) => r.side === 'purchases') ?? [];
  const sum = (a: IcRow[]) => a.reduce((s, r) => s + r.line_total, 0);
  return (
    <Panel className="mt-6" title="Inter-company invoices (sales and purchases between group companies)"
      actions={<Button size="sm" variant="navy" busy={busy} disabled={!company} onClick={load}>Prepare</Button>}>
      <p className="text-sm text-steel-600">For the company and period above. Sales invoices import into Xero under <i>Sales → Import</i>, purchases under <i>Bills to pay → Import</i>; credit notes have negative quantities. Accounts and tax types: Settings → accounting.</p>
      {err && <Notice tone="bad" className="mt-3">{err}</Notice>}
      {rows && (
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          {([['Sales (we supplied)', sales, 'Xero sales invoices', 'sales'], ['Purchases (we received)', purchases, 'Xero bills', 'purchases']] as const).map(([label, list, xname, side]) => (
            <div key={label} className="rounded-md border border-steel-200 p-3">
              <div className="font-semibold text-navy-900">{label}</div>
              <div className="text-sm text-steel-600">{list.length} lines · {fmtZAR(sum(list))} excl. VAT</div>
              <div className="mt-2 flex flex-wrap gap-2">
                <Button size="sm" disabled={!list.length} onClick={() => exportCSV(`${xname} ${companyCode} ${from} to ${to}`, xero, list)}><Download className="size-4" />{xname} CSV</Button>
                <Button size="sm" disabled={!list.length} onClick={() => exportCSV(`Sage ${label.split(' ')[0]} ${companyCode} ${from} to ${to}`, sage(side), list)}><Download className="size-4" />Sage CSV</Button>
              </div>
            </div>
          ))}
        </div>
      )}
    </Panel>
  );
}
