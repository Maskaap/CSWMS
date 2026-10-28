'use client';
import Link from 'next/link';
import { useState } from 'react';
import { Lightbulb, Plus } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, PageHeader, Spinner, StatusBadge, Table, Td, Th } from '@/components/ui';
import { ExportButtons, LoadError, Tabs } from '@/components/widgets';
import { useRows } from '@/hooks/use-rows';
import { fmtDate, fmtDateTime, fmtZAR } from '@/lib/format';

type PO = {
  id: string; po_no: string; status: string; supplier_id: string; supplier_name: string; supplier_email: string | null; warehouse_id: string; warehouse_code: string;
  warehouse_name: string; branch_code: string; company_code: string; owner_company_code: string; expected_date: string | null; supplier_reference: string | null;
  notes: string | null; created_at: string; created_by_name: string; approved_by_name: string | null; approved_at: string | null; sent_at: string | null;
  closed_at: string | null; close_reason: string | null; approval_id: string | null; line_count: number; total_value: number; received_value: number; is_overdue: boolean;
};

const TABS = {
  open: ['draft', 'pending_approval', 'approved', 'sent', 'partially_received'],
  draft: ['draft'], approval: ['pending_approval'], receiving: ['approved', 'sent', 'partially_received'],
  done: ['received', 'closed', 'cancelled'],
} as const;

export default function PurchasingPage() {
  const { can, warehouseId } = useApp();
  const [tab, setTab] = useState<keyof typeof TABS>('open');
  const list = useRows<PO>('po|' + tab, (sb) => sb.from('v_purchase_orders').select('*').in('status', [...TABS[tab]]).order('created_at', { ascending: false }).limit(500));
  return (
    <>
      <PageHeader title="Purchasing" description="Purchase orders from draft to approval, sending, and receiving against the order. Receipts against an order post the same audited stock receipt as Receive Stock."
        actions={<>
          {can('purchase.manage', warehouseId) && <Link href="/purchasing/suggestions"><Button><Lightbulb className="size-4" />Reorder suggestions</Button></Link>}
          {can('purchase.manage', warehouseId) && <Link href="/purchasing/new"><Button variant="primary"><Plus className="size-4" />New purchase order</Button></Link>}
          <ExportButtons title="Purchase orders" rows={list.rows} cols={[
            { key: 'po_no', label: 'PO' }, { key: 'status', label: 'Status' }, { key: 'supplier_name', label: 'Supplier' }, { key: 'company_code', label: 'Company' },
            { key: 'warehouse_code', label: 'Deliver to' }, { key: 'expected_date', label: 'Expected', get: (r) => fmtDate(r.expected_date) },
            { key: 'total_value', label: 'Value (ZAR)', num: true }, { key: 'received_value', label: 'Received (ZAR)', num: true },
            { key: 'is_overdue', label: 'Overdue', get: (r) => (r.is_overdue ? 'Yes' : '') }, { key: 'created_by_name', label: 'Created by' },
            { key: 'approved_by_name', label: 'Approved by' }, { key: 'supplier_reference', label: 'Supplier ref' }]} />
        </>} />
      <Tabs value={tab} onChange={setTab} tabs={[{ id: 'open', label: 'All open' }, { id: 'draft', label: 'Drafts' }, { id: 'approval', label: 'Awaiting approval' },
        { id: 'receiving', label: 'To receive' }, { id: 'done', label: 'Completed / cancelled' }]} />
      <LoadError error={list.error} />
      {list.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>Order</Th><Th>Supplier</Th><Th>Deliver to</Th><Th>Status</Th><Th>Expected</Th><Th right>Value</Th><Th right>Received</Th><Th>Created</Th></tr></thead>
          <tbody>{list.rows.map((p) => (
            <tr key={p.id} className="hover:bg-steel-50">
              <Td><Link href={`/purchasing/${p.id}`} className="font-mono text-[13px] font-semibold hover:underline">{p.po_no}</Link><div className="text-xs text-steel-600">{p.line_count} line(s)</div></Td>
              <Td>{p.supplier_name}{p.supplier_reference && <div className="text-xs text-steel-600">Ref {p.supplier_reference}</div>}</Td>
              <Td><b>{p.warehouse_code}</b><div className="text-xs text-steel-600">{p.branch_code} · {p.owner_company_code}</div></Td>
              <Td><StatusBadge status={p.status} />{p.is_overdue && <Badge tone="bad" className="ml-1">overdue</Badge>}</Td>
              <Td>{fmtDate(p.expected_date)}</Td>
              <Td right>{fmtZAR(p.total_value)}</Td>
              <Td right>{Number(p.received_value) ? `${Math.round((Number(p.received_value) / Number(p.total_value || 1)) * 100)}%` : '—'}</Td>
              <Td className="text-xs">{p.created_by_name}<div>{fmtDateTime(p.created_at)}</div></Td>
            </tr>
          ))}
            {list.rows.length === 0 && <tr><Td className="text-steel-600">No purchase orders here.</Td></tr>}</tbody>
        </Table>
      )}
    </>
  );
}
