'use client';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { useState } from 'react';
import { Undo2 } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, Field, PageHeader, Panel, Spinner, StatusBadge, Table, Td, Textarea, Th } from '@/components/ui';
import { ActionResult, KV, LoadError, TxnLink } from '@/components/widgets';
import { useRpc } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtDateTime, fmtQty, STATUS_LABELS, TXN_LABELS } from '@/lib/format';
import { TxnOutcome } from '@/components/txn-outcome';

type Detail = {
  id: string; txn_no: string; txn_type: string; status: string; warehouse_id: string; warehouse_code: string; warehouse_name: string; branch_code: string; company_code: string;
  reference: string | null; notes: string | null; reason_label: string | null; supplier_name: string | null; created_at: string; created_by_name: string;
  posted_at: string | null; posted_by_name: string | null; is_unusual: boolean; unusual_info: unknown; related_txn_id: string | null; related_txn_no: string | null;
  transfer_id: string | null; stocktake_id: string | null; reversed_by: { id: string; txn_no: string } | null;
  approval: { id: string; status: string; summary: string; requested_by_name?: string; decided_by_name?: string; decision_note?: string; decided_at?: string } | null;
  lines: { line_no: number; sku: string; description: string; location: string; to_location: string | null; owner: string; status: string; to_status: string | null; entered_qty: number; entered_uom: string; qty_base: number; base_uom: string }[];
  movements: { id: number; sku: string; location: string; owner: string; status: string; qty_delta: number; balance_after: number; posted_at: string }[];
  returns: { id: string; txn_no: string }[];
};

export default function TransactionPage() {
  const { id } = useParams<{ id: string }>();
  const { can } = useApp();
  const { data: t, loading, error, reload } = useRpc<Detail>('t' + id, 'transaction_detail', { p_txn_id: id });
  const rev = useTransaction('request_reversal');
  const [showRev, setShowRev] = useState(false);
  const [note, setNote] = useState('');

  if (loading) return <Spinner />;
  if (!t) return <><LoadError error={error} /><PageHeader title="Transaction not found" /></>;
  const reversible = t.status === 'posted' && !t.reversed_by && !['reversal', 'opening', 'transfer_dispatch', 'transfer_receipt', 'stocktake_adjustment'].includes(t.txn_type) && can('stock.reverse', t.warehouse_id);

  return (
    <>
      <PageHeader title={`${TXN_LABELS[t.txn_type] ?? t.txn_type} ${t.txn_no}`}
        description={<><StatusBadge status={t.status} /> · {t.warehouse_code} — {t.warehouse_name} ({t.branch_code}, {t.company_code}){t.is_unusual && <Badge tone="warn" className="ml-2">unusual quantity confirmed</Badge>}</>}
        actions={reversible && <Button size="sm" onClick={() => setShowRev(true)}><Undo2 className="size-4" />Request reversal</Button>} />
      <div className="space-y-6">
        <Panel>
          <KV items={[
            ['Captured by', `${t.created_by_name} · ${fmtDateTime(t.created_at)}`],
            ['Posted', t.posted_at ? `${t.posted_by_name ?? ''} · ${fmtDateTime(t.posted_at)}` : 'Not posted'],
            ['Reason', t.reason_label], ['Reference', t.reference], ['Supplier', t.supplier_name], ['Notes', t.notes],
            ['Related transaction', t.related_txn_id ? <TxnLink id={t.related_txn_id} no={t.related_txn_no} /> : null],
            ['Reversed by', t.reversed_by ? <TxnLink id={t.reversed_by.id} no={t.reversed_by.txn_no} /> : null],
            ['Transfer', t.transfer_id ? <Link className="underline" href={`/transfers/${t.transfer_id}`}>Open transfer</Link> : null],
            ['Stocktake', t.stocktake_id ? <Link className="underline" href={`/stocktake/${t.stocktake_id}`}>Open stocktake</Link> : null],
            ['Returns against this', t.returns?.length ? t.returns.map((r) => r.txn_no).join(', ') : null],
          ]} />
        </Panel>
        {t.approval && (
          <Panel title="Approval">
            <KV items={[['Status', <StatusBadge status={t.approval.status} />], ['Request', t.approval.summary], ['Requested by', t.approval.requested_by_name],
              ['Decided by', t.approval.decided_by_name], ['Decision note', t.approval.decision_note], ['Decided at', fmtDateTime(t.approval.decided_at)]]} />
          </Panel>
        )}
        <Panel title="Lines (as entered)" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>#</Th><Th>Product</Th><Th>Location</Th><Th>Owner</Th><Th>Status</Th><Th right>Entered</Th><Th right>Base quantity</Th></tr></thead>
            <tbody>{t.lines.map((l) => (
              <tr key={l.line_no}><Td>{l.line_no}</Td><Td><span className="font-mono text-[13px]">{l.sku}</span> {l.description}</Td>
                <Td mono>{l.location}{l.to_location ? ` → ${l.to_location}` : ''}</Td><Td>{l.owner}</Td>
                <Td>{STATUS_LABELS[l.status] ?? l.status}{l.to_status ? ` → ${STATUS_LABELS[l.to_status] ?? l.to_status}` : ''}</Td>
                <Td right>{fmtQty(l.entered_qty)} {l.entered_uom}</Td><Td right>{fmtQty(l.qty_base)} {l.base_uom}</Td></tr>
            ))}</tbody>
          </Table>
        </Panel>
        <Panel title="Ledger movements (authoritative)" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>Ledger #</Th><Th>Product</Th><Th>Location</Th><Th>Owner</Th><Th>Status</Th><Th right>Change</Th><Th right>Balance after</Th></tr></thead>
            <tbody>{t.movements.map((m) => (
              <tr key={m.id}><Td mono>{m.id}</Td><Td mono>{m.sku}</Td><Td mono>{m.location}</Td><Td>{m.owner}</Td><Td>{STATUS_LABELS[m.status] ?? m.status}</Td>
                <Td right className={Number(m.qty_delta) < 0 ? 'text-bad-600' : 'text-ok-600'}>{Number(m.qty_delta) > 0 ? '+' : ''}{fmtQty(m.qty_delta)}</Td><Td right>{fmtQty(m.balance_after)}</Td></tr>
            ))}
              {t.movements.length === 0 && <tr><Td className="text-steel-600">No ledger movements (not posted).</Td></tr>}</tbody>
          </Table>
        </Panel>
        {showRev && (
          <Panel title="Request a reversal">
            <p className="mb-3 text-sm text-steel-600">A reversal posts an equal and opposite transaction after management approval. The original record is kept unchanged.</p>
            <Field label="Why must this be reversed?" required><Textarea value={note} onChange={(e) => setNote(e.target.value)} rows={3} /></Field>
            <div className="mt-3 flex gap-2">
              <Button onClick={() => setShowRev(false)}>Cancel</Button>
              <Button variant="navy" disabled={note.trim().length < 5} busy={rev.state.phase === 'saving'} onClick={async () => { if (await rev.run({ p_txn_id: t.id, p_notes: note.trim() })) { setShowRev(false); reload(); } }}>Submit for approval</Button>
            </div>
          </Panel>
        )}
        <TxnOutcome state={rev.state} onRetry={rev.retry} savedText={() => 'Reversal requested. It will be posted once a manager approves it.'} />
        <ActionResult error={null} />
      </div>
    </>
  );
}
