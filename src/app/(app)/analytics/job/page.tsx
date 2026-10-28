'use client';
import Link from 'next/link';
import { Suspense, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { Search } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Button, Input, Notice, PageHeader, Panel, Spinner, Stat, Table, Td, Th } from '@/components/ui';
import { ExportButtons, LoadError } from '@/components/widgets';
import { useRpc } from '@/hooks/use-rows';
import { fmtDateTime, fmtQty, fmtZAR, TXN_LABELS } from '@/lib/format';

type Job = {
  reference: string; material_value: number | null; has_uncosted_items: boolean; tool_days: number; first_at: string | null; last_at: string | null;
  materials: { product_id: string; sku: string; description: string; uom: string; issued: number; returned: number; net: number; unit_cost: number | null; value: number | null }[];
  transactions: { txn_id: string; txn_no: string; txn_type: string; posted_at: string; warehouse_code: string; by: string; reference: string }[];
  tools: { asset_id: string; asset_tag: string; description: string; holder: string; out_at: string; back_at: string | null; days: number }[];
  reservations: { sku: string; description: string; uom: string; outstanding: number; warehouse_code: string; expires_at: string | null }[];
};

function JobInner() {
  const sp = useSearchParams();
  const router = useRouter();
  const { can } = useApp();
  const cost = can('cost.view');
  const ref = sp.get('ref') ?? '';
  const [q, setQ] = useState(ref);
  const job = useRpc<Job>(ref ? 'job' + ref : null, 'analytics_job', { p_reference: ref });
  const j = job.data;
  return (
    <>
      <PageHeader title={ref ? `Job costing — ${ref.toUpperCase()}` : 'Job costing'}
        description={<>Everything issued to a job or client reference (net of returns), the tools used on it and stock still reserved for it. <Link className="underline" href="/analytics?tab=consumption">All jobs</Link></>}
        actions={j && <ExportButtons title={`Job ${j.reference}`} rows={j.materials} cols={[
          { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'uom', label: 'Unit' }, { key: 'issued', label: 'Issued', num: true },
          { key: 'returned', label: 'Returned', num: true }, { key: 'net', label: 'Net used', num: true },
          ...(cost ? [{ key: 'unit_cost', label: 'Unit cost (ZAR)', num: true }, { key: 'value', label: 'Value (ZAR)', num: true }] : [])]} />} />
      <form className="mb-6 flex max-w-xl gap-2" onSubmit={(e) => { e.preventDefault(); if (q.trim()) router.push(`/analytics/job?ref=${encodeURIComponent(q.trim())}`); }}>
        <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Job / client reference, e.g. JOB-7781" aria-label="Job reference" />
        <Button type="submit" variant="navy"><Search className="size-4" />Open</Button>
      </form>
      {ref && job.error && <LoadError error={job.error} />}
      {ref && !j && !job.error && <Spinner />}
      {j && (
        <div className="space-y-6">
          {j.materials.length === 0 && j.tools.length === 0 && <Notice tone="info">Nothing has been issued to “{j.reference}” in the warehouses you can report on. References are matched ignoring case and spaces at the ends.</Notice>}
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            {cost && <Stat label="Materials used" value={fmtZAR(j.material_value)} sub={j.has_uncosted_items ? 'some items have no price' : 'weighted-average cost'} />}
            <Stat label="Different items" value={j.materials.length} />
            <Stat label="Tool-days" value={fmtQty(j.tool_days)} sub={`${j.tools.length} check-out(s)`} />
            <Stat label="Period" value={j.first_at ? `${new Date(j.first_at).toLocaleDateString('en-ZA')} – ${new Date(j.last_at!).toLocaleDateString('en-ZA')}` : '—'} />
          </div>
          <Panel title="Materials" padded={false}>
            <Table className="rounded-none border-0">
              <thead><tr><Th>Item</Th><Th right>Issued</Th><Th right>Returned</Th><Th right>Net used</Th>{cost && <Th right>Unit cost</Th>}{cost && <Th right>Value</Th>}</tr></thead>
              <tbody>{j.materials.map((m) => (
                <tr key={m.product_id}><Td><span className="font-mono text-[13px] font-semibold">{m.sku}</span> {m.description}</Td>
                  <Td right>{fmtQty(m.issued)} {m.uom}</Td><Td right>{fmtQty(m.returned)}</Td><Td right className="font-semibold">{fmtQty(m.net)}</Td>
                  {cost && <Td right>{m.unit_cost != null ? fmtZAR(m.unit_cost) : 'no price'}</Td>}{cost && <Td right>{fmtZAR(m.value)}</Td>}</tr>))}
                {j.materials.length === 0 && <tr><Td className="text-steel-600">No materials.</Td></tr>}</tbody>
              {cost && j.materials.length > 0 && <tfoot><tr><Td className="font-semibold">Total</Td><Td /><Td /><Td />{<Td />}<Td right className="font-semibold">{fmtZAR(j.material_value)}</Td></tr></tfoot>}
            </Table>
          </Panel>
          <div className="grid gap-6 xl:grid-cols-2">
            <Panel title="Tools & equipment used" padded={false}>
              <Table className="rounded-none border-0">
                <thead><tr><Th>Tool</Th><Th>Held by</Th><Th>Out</Th><Th>Back</Th><Th right>Days</Th></tr></thead>
                <tbody>{j.tools.map((t, i) => (
                  <tr key={i}><Td><Link className="font-mono text-[13px] hover:underline" href={`/assets/${t.asset_id}`}>{t.asset_tag}</Link> {t.description}</Td><Td>{t.holder}</Td>
                    <Td className="text-xs">{fmtDateTime(t.out_at)}</Td><Td className="text-xs">{t.back_at ? fmtDateTime(t.back_at) : 'still out'}</Td><Td right>{fmtQty(t.days)}</Td></tr>))}
                  {j.tools.length === 0 && <tr><Td className="text-steel-600">No tools checked out to this job.</Td></tr>}</tbody>
              </Table>
            </Panel>
            <Panel title="Still reserved for this job" padded={false}>
              <Table className="rounded-none border-0">
                <thead><tr><Th>Item</Th><Th>Warehouse</Th><Th right>Outstanding</Th></tr></thead>
                <tbody>{j.reservations.map((r, i) => (
                  <tr key={i}><Td><span className="font-mono text-[13px]">{r.sku}</span> {r.description}</Td><Td>{r.warehouse_code}</Td><Td right>{fmtQty(r.outstanding)} {r.uom}</Td></tr>))}
                  {j.reservations.length === 0 && <tr><Td className="text-steel-600">No open reservations.</Td></tr>}</tbody>
              </Table>
            </Panel>
          </div>
          <Panel title="Transactions" padded={false}>
            <Table className="rounded-none border-0">
              <thead><tr><Th>When</Th><Th>Transaction</Th><Th>Type</Th><Th>Warehouse</Th><Th>By</Th></tr></thead>
              <tbody>{j.transactions.map((t) => (
                <tr key={t.txn_id}><Td className="text-xs">{fmtDateTime(t.posted_at)}</Td><Td><Link className="font-mono text-[13px] hover:underline" href={`/transactions/${t.txn_id}`}>{t.txn_no}</Link></Td>
                  <Td>{TXN_LABELS[t.txn_type] ?? t.txn_type}</Td><Td>{t.warehouse_code}</Td><Td>{t.by}</Td></tr>))}</tbody>
            </Table>
          </Panel>
        </div>
      )}
    </>
  );
}

export default function JobPage() {
  return <Suspense fallback={<Spinner />}><JobInner /></Suspense>;
}
