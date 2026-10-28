'use client';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { useState } from 'react';
import { useApp } from '@/components/app-context';
import { Badge, Button, Field, Input, Notice, PageHeader, Panel, Select, Spinner, StatusBadge, Table, Td, Textarea, Th } from '@/components/ui';
import { ActionResult, KV, LoadError, TxnLink } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useRows, useRpc } from '@/hooks/use-rows';
import { fmtDateTime, fmtQty, TXN_LABELS } from '@/lib/format';
import { CHECK_LABELS } from '@/lib/integrity';

type D = Record<string, any> & {
  events: { at: string; note: string | null; actor: string | null; event: string }[];
  employees: { id: string; name: string; employee_number: string | null }[];
  transactions: { id: string; type: string; status: string; txn_no: string; posted_at: string | null; posted_by: string | null; reference: string | null; created_by: string }[];
  recent_ledger: { id: number; txn_id: string; txn_no: string; txn_type: string; qty_delta: number; posted_at: string; posted_by: string }[];
  unexplained_changes: Record<string, unknown>[];
};

export default function FindingPage() {
  const { id } = useParams<{ id: string }>();
  const { can } = useApp();
  const { data: f, loading, error, reload } = useRpc<D>('fd' + id, 'integrity_finding_detail', { p_finding_id: id });
  const users = useRows<{ id: string; full_name: string }>('u', (sb) => sb.from('app_users').select('id, full_name').eq('is_active', true).order('full_name'));
  const act = useAction();
  const [assignee, setAssignee] = useState('');
  const [note, setNote] = useState('');
  const [outcome, setOutcome] = useState('resolved');
  const [resolution, setResolution] = useState('');
  const [txnNo, setTxnNo] = useState('');
  const txn = useRows<{ id: string }>(txnNo.trim().length >= 6 ? 'rt' + txnNo.trim().toUpperCase() : null, (sb) => sb.from('v_transactions').select('id').eq('txn_no', txnNo.trim().toUpperCase()).limit(1));

  if (loading) return <Spinner />;
  if (!f) return <><LoadError error={error} /><PageHeader title="Issue not found" /></>;
  const closed = ['resolved', 'dismissed'].includes(f.status);
  const investigate = can('integrity.investigate');

  return (
    <>
      <PageHeader title={`${f.finding_no}: ${f.title}`}
        description={<><Badge tone={f.severity === 'critical' ? 'bad' : 'warn'}>{f.severity}</Badge> <Badge tone="idle">{f.classification}</Badge> <StatusBadge status={f.status} />
          {f.escalated && <Badge tone="bad" className="ml-1">escalated to head office</Badge>} · {CHECK_LABELS[f.check_code] ?? f.check_code}</>} />
      <div className="space-y-6">
        <Notice tone={f.still_present ? 'bad' : 'ok'} title={f.still_present ? 'Still present in the latest check' : 'Not present in the latest check'}>{f.description}</Notice>
        <Panel title="Details">
          <KV items={[
            ['Product', f.product ? `${f.product.sku} — ${f.product.description}` : null],
            ['Company / warehouse', f.warehouse ? `${f.warehouse.company} · ${f.warehouse.code} — ${f.warehouse.name} (${f.warehouse.branch})` : null],
            ['Location', f.location?.code ?? f.location_code], ['Owning company', f.owner_company?.code ?? f.owner_company_code], ['Stock status', f.stock_status],
            ['Calculated from ledger (expected)', f.expected_qty != null ? fmtQty(f.expected_qty) : null], ['Recorded balance', f.recorded_qty != null ? fmtQty(f.recorded_qty) : null],
            ['Difference', f.difference != null ? <span className="text-bad-600">{(Number(f.difference) > 0 ? '+' : '') + fmtQty(f.difference)}</span> : null],
            ['Possible cause', f.possible_cause ? <span>{f.possible_cause} <span className="text-xs text-warn-600">(not verified)</span></span> : null],
            ['First detected', `${fmtDateTime(f.first_detected_at)} · ${f.first_run_no ?? ''}`], ['Last detected', `${fmtDateTime(f.last_detected_at)} · ${f.last_run_no ?? ''} (${f.occurrences}×)`],
            ['Investigator', f.assigned_to_name], ['Resolution', f.resolution], ['Resolved by', f.resolved_by_name ? `${f.resolved_by_name} · ${fmtDateTime(f.resolved_at)}` : null],
            ['Correcting transaction', f.resolution_txn_id ? <TxnLink id={f.resolution_txn_id} no={f.resolution_txn_no} /> : null],
          ]} />
        </Panel>

        <div className="grid gap-6 xl:grid-cols-2">
          <Panel title="Related transactions" padded={false}>
            <Table className="rounded-none border-0">
              <thead><tr><Th>Transaction</Th><Th>Type</Th><Th>Status</Th><Th>Posted</Th><Th>By</Th></tr></thead>
              <tbody>{(f.transactions ?? []).map((t) => <tr key={t.id}><Td><TxnLink id={t.id} no={t.txn_no} /></Td><Td>{TXN_LABELS[t.type] ?? t.type}</Td><Td><StatusBadge status={t.status} /></Td><Td className="text-xs">{fmtDateTime(t.posted_at)}</Td><Td>{t.posted_by ?? t.created_by}</Td></tr>)}
                {!(f.transactions ?? []).length && <tr><Td className="text-steel-600">None linked.</Td></tr>}</tbody>
            </Table>
          </Panel>
          <Panel title="Employees associated" padded={false}>
            <ul className="divide-y divide-steel-100">{(f.employees ?? []).map((e) => <li key={e.id} className="px-4 py-2 text-sm">{e.name}{e.employee_number && <span className="text-steel-600"> · {e.employee_number}</span>}</li>)}
              {!(f.employees ?? []).length && <li className="px-4 py-2 text-sm text-steel-600">None identified.</li>}</ul>
          </Panel>
        </div>

        {(f.recent_ledger ?? []).length > 0 && (
          <Panel title="Recent ledger movements for this balance" padded={false}>
            <Table className="rounded-none border-0">
              <thead><tr><Th>Ledger #</Th><Th>Transaction</Th><Th>Type</Th><Th right>Change</Th><Th>When</Th><Th>By</Th></tr></thead>
              <tbody>{f.recent_ledger.map((l) => <tr key={l.id}><Td mono>{l.id}</Td><Td><TxnLink id={l.txn_id} no={l.txn_no} /></Td><Td>{TXN_LABELS[l.txn_type] ?? l.txn_type}</Td><Td right>{fmtQty(l.qty_delta)}</Td><Td className="text-xs">{fmtDateTime(l.posted_at)}</Td><Td>{l.posted_by}</Td></tr>)}</tbody>
            </Table>
          </Panel>
        )}
        {(f.unexplained_changes ?? []).length > 0 && (
          <Panel title="Unexplained changes captured by the balance change log"><pre className="max-h-80 overflow-auto rounded bg-steel-50 p-3 text-xs">{JSON.stringify(f.unexplained_changes, null, 2)}</pre></Panel>
        )}

        <Panel title="Investigation history" padded={false}>
          <ul className="divide-y divide-steel-100">{f.events.map((e, i) => (
            <li key={i} className="px-4 py-2 text-sm"><span className="font-medium">{e.event.replace(/_/g, ' ')}</span> · {fmtDateTime(e.at)}{e.actor && ` · ${e.actor}`}{e.note && <div className="text-steel-800">{e.note}</div>}</li>
          ))}</ul>
        </Panel>

        {investigate && (
          <div className="grid gap-6 xl:grid-cols-2">
            <Panel title="Assign & notes">
              <div className="space-y-3">
                {!closed && <div className="flex gap-2"><Select value={assignee} onChange={(e) => setAssignee(e.target.value)}><option value="">— assign to —</option>{users.rows.map((u) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</Select>
                  <Button variant="navy" disabled={!assignee} busy={act.busy} onClick={async () => { if (await act.run('integrity_assign', { p_finding_id: f.id, p_user_id: assignee, p_note: note || null }, 'Assigned.')) { setNote(''); reload(); } }}>Assign</Button></div>}
                <Field label="Investigation note"><Textarea value={note} onChange={(e) => setNote(e.target.value)} rows={3} /></Field>
                <Button disabled={!note.trim()} busy={act.busy} onClick={async () => { if (await act.run('integrity_add_note', { p_finding_id: f.id, p_note: note.trim() }, 'Note added.')) { setNote(''); reload(); } }}>Add note</Button>
              </div>
            </Panel>
            <Panel title={closed ? 'Re-open' : 'Close the issue'}>
              <div className="space-y-3">
                {!closed && <Notice tone="info">The monitor never corrects stock. If a correction is needed, post an <Link className="underline" href="/corrections?tab=adjust">adjustment</Link> with reason “Integrity investigation outcome”, get it approved, then link it here.</Notice>}
                <Field label="Outcome"><Select value={outcome} onChange={(e) => setOutcome(e.target.value)}>
                  {closed ? <option value="open">Re-open</option> : <><option value="resolved">Resolved</option>{can('integrity.admin') && <option value="dismissed">Dismissed (false positive)</option>}</>}
                </Select></Field>
                <Field label="Findings / resolution" required><Textarea value={resolution} onChange={(e) => setResolution(e.target.value)} rows={3} placeholder="Verified cause and what was done" /></Field>
                {!closed && <Field label="Correcting transaction (optional)" hint={txnNo && !txn.loading ? (txn.rows[0] ? 'Found' : 'Not found') : undefined}><Input value={txnNo} onChange={(e) => setTxnNo(e.target.value)} placeholder="e.g. ADJ-2026-000045" /></Field>}
                <Button variant={closed ? 'secondary' : 'primary'} disabled={!resolution.trim() || (!!txnNo.trim() && !txn.rows[0])} busy={act.busy} onClick={async () => {
                  if (await act.run('integrity_set_status', { p_finding_id: f.id, p_status: closed ? 'open' : outcome, p_resolution: resolution.trim(), p_resolution_txn_id: txn.rows[0]?.id ?? null }, 'Saved.')) { setResolution(''); reload(); }
                }}>{closed ? 'Re-open issue' : 'Save outcome'}</Button>
              </div>
            </Panel>
          </div>
        )}
        <ActionResult error={act.error} ok={act.ok} />
      </div>
    </>
  );
}
