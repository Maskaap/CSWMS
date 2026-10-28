'use client';
import Link from 'next/link';
import { useState } from 'react';
import { Plus } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, PageHeader, Spinner, StatusBadge, Table, Td, Th } from '@/components/ui';
import { ExportButtons, LoadError, Tabs } from '@/components/widgets';
import { useRows } from '@/hooks/use-rows';
import { fmtDateTime, fmtQty } from '@/lib/format';

type Tr = {
  id: string; transfer_no: string; status: string; from_warehouse_id: string; to_warehouse_id: string; from_warehouse_code: string; to_warehouse_code: string;
  from_branch_code: string; to_branch_code: string; to_owner_company_code: string | null; reference: string | null; created_at: string; created_by_name: string;
  dispatched_at: string | null; expected_arrival_at: string | null; line_count: number; outstanding_qty: number; is_overdue: boolean; completed_at: string | null;
};

export default function TransfersPage() {
  const { warehouse, warehouseId, can } = useApp();
  const [tab, setTab] = useState<'incoming' | 'outgoing' | 'open' | 'all'>('incoming');
  const list = useRows<Tr>(`tr|${tab}|${warehouseId}`, (sb) => {
    let q = sb.from('v_transfers').select('*').order('created_at', { ascending: false }).limit(300);
    if (tab === 'incoming' && warehouseId) q = q.eq('to_warehouse_id', warehouseId).in('status', ['dispatched', 'partially_received']);
    if (tab === 'outgoing' && warehouseId) q = q.eq('from_warehouse_id', warehouseId);
    if (tab === 'open') q = q.in('status', ['draft', 'dispatched', 'partially_received']);
    return q;
  });

  return (
    <>
      <PageHeader title="Transfer stock" description="Between shelves, warehouses, branches and companies. Dispatched stock is held as “in transit” until the receiving site confirms it — it is never available in two places."
        actions={<>
          {can('stock.transfer.dispatch', warehouseId) && <Link href="/transfers/new"><Button variant="primary"><Plus className="size-4" />New transfer</Button></Link>}
          <ExportButtons title="Stock transfers" rows={list.rows} cols={[
            { key: 'transfer_no', label: 'Transfer' }, { key: 'from_warehouse_code', label: 'From' }, { key: 'to_warehouse_code', label: 'To' },
            { key: 'status', label: 'Status' }, { key: 'reference', label: 'Reference' }, { key: 'dispatched_at', label: 'Dispatched', get: (r) => fmtDateTime(r.dispatched_at) },
            { key: 'expected_arrival_at', label: 'Expected', get: (r) => fmtDateTime(r.expected_arrival_at) }, { key: 'line_count', label: 'Lines', num: true },
            { key: 'outstanding_qty', label: 'Outstanding qty', num: true }, { key: 'is_overdue', label: 'Overdue', get: (r) => (r.is_overdue ? 'Yes' : '') }]} />
        </>} />
      <Tabs value={tab} onChange={setTab} tabs={[
        { id: 'incoming', label: `Incoming to ${warehouse?.code ?? '—'}` }, { id: 'outgoing', label: `Sent from ${warehouse?.code ?? '—'}` },
        { id: 'open', label: 'All open' }, { id: 'all', label: 'All' }]} />
      <LoadError error={list.error} />
      {list.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>Transfer</Th><Th>From → To</Th><Th>Status</Th><Th>Dispatched</Th><Th>Expected</Th><Th right>Lines</Th><Th right>Outstanding</Th><Th>Reference</Th></tr></thead>
          <tbody>
            {list.rows.map((t) => (
              <tr key={t.id} className="hover:bg-steel-50">
                <Td><Link href={`/transfers/${t.id}`} className="font-mono text-[13px] font-semibold underline-offset-2 hover:underline">{t.transfer_no}</Link></Td>
                <Td><b>{t.from_warehouse_code}</b> → <b>{t.to_warehouse_code}</b><div className="text-xs text-steel-600">{t.from_branch_code} → {t.to_branch_code}{t.to_owner_company_code ? ` · ownership to ${t.to_owner_company_code}` : ''}</div></Td>
                <Td><StatusBadge status={t.status} />{t.is_overdue && <Badge tone="bad" className="ml-1">overdue</Badge>}</Td>
                <Td className="text-xs">{fmtDateTime(t.dispatched_at)}</Td><Td className="text-xs">{fmtDateTime(t.expected_arrival_at)}</Td>
                <Td right>{t.line_count}</Td><Td right>{Number(t.outstanding_qty) ? fmtQty(t.outstanding_qty) : '—'}</Td><Td>{t.reference}</Td>
              </tr>
            ))}
            {list.rows.length === 0 && <tr><Td className="text-steel-600">No transfers.</Td></tr>}
          </tbody>
        </Table>
      )}
    </>
  );
}
