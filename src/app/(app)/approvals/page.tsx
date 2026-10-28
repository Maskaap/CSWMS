'use client';
import Link from 'next/link';
import { useState } from 'react';
import { CheckCircle2, XCircle } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, PageHeader, Spinner, StatusBadge, Table, Td, Th } from '@/components/ui';
import { ActionResult, ExportButtons, LoadError, Tabs, useConfirm } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useRows, useRpc } from '@/hooks/use-rows';
import { fmtDateTime, fmtZAR } from '@/lib/format';

type A = { id: string; kind: string; status: string; required_perm: string; warehouse_id: string | null; txn_id: string | null; transfer_id: string | null; stocktake_id: string | null;
  import_batch_id: string | null; summary: string; details: Record<string, unknown> | null; requested_by: string; requested_at: string; requested_by_name: string;
  decided_by_name: string | null; decided_at: string | null; decision_note: string | null; warehouse_code: string | null; branch_code: string | null; company_code: string | null; txn_no: string | null;
  value_zar: number | null; step_levels: string[]; steps_done: number; purchase_order_id: string | null; po_no: string | null;
  decisions: { step: number; level: string; by: string; approved: boolean; note: string | null; at: string }[] | null };

const KIND: Record<string, string> = { adjustment: 'Stock adjustment', reversal: 'Reversal', transfer_writeoff: 'Transfer shortage write-off', stocktake: 'Stocktake variances', opening_balance: 'Opening balances', purchase_order: 'Purchase order' };
const LEVEL: Record<string, string> = { any: 'Approver', branch: 'Branch', company: 'Company', group: 'Head office' };

function target(a: A) {
  if (a.purchase_order_id) return { href: `/purchasing/${a.purchase_order_id}`, label: `Open ${a.po_no ?? 'purchase order'}` };
  if (a.stocktake_id) return { href: `/stocktake/${a.stocktake_id}`, label: 'Open stocktake' };
  if (a.transfer_id) return { href: `/transfers/${a.transfer_id}`, label: 'Open transfer' };
  if (a.import_batch_id) return { href: `/setup/import?batch=${a.import_batch_id}`, label: 'Review import' };
  if (a.txn_id) return { href: `/transactions/${a.txn_id}`, label: `Review ${a.txn_no ?? 'transaction'}` };
  return null;
}

export default function ApprovalsPage() {
  const { me } = useApp();
  const [tab, setTab] = useState<'waiting' | 'mine' | 'history'>('waiting');
  const list = useRows<A>(`ap|${tab}`, (sb) => {
    let q = sb.from('v_approvals').select('*').order('requested_at', { ascending: tab !== 'history' }).limit(300);
    if (tab === 'waiting') q = q.eq('status', 'pending').neq('requested_by', me?.user?.id ?? '');
    if (tab === 'mine') q = q.eq('requested_by', me?.user?.id ?? '');
    if (tab === 'history') q = q.neq('status', 'pending');
    return q;
  });
  const decidable = useRpc<string[]>(`apdec|${tab}`, 'approvals_i_can_decide');
  const act = useAction();
  const confirm = useConfirm();
  const mine = new Set(decidable.data ?? []);
  const mayDecide = (a: A) => a.status === 'pending' && mine.has(a.id);
  const reload = () => { list.reload(); decidable.reload(); };

  const decide = async (a: A, approve: boolean) => {
    const c = await confirm.ask({
      title: approve ? `Approve: ${KIND[a.kind] ?? a.kind}` : `Reject: ${KIND[a.kind] ?? a.kind}`,
      body: <><p className="font-medium">{a.summary}</p><p className="mt-2 text-steel-600">{!approve ? 'Nothing will be posted.' : a.steps_done + 1 < (a.step_levels?.length ?? 1)
        ? `This is level ${a.steps_done + 1} of ${a.step_levels.length}. A different person must approve the next level (${LEVEL[a.step_levels[a.steps_done + 1]]}) before anything happens.`
        : a.kind === 'purchase_order' ? 'The order becomes approved and can be sent to the supplier.' : 'Stock is changed only now, as a new traceable transaction. You cannot approve your own request.'}</p></>,
      noteLabel: approve ? 'Verification note (what did you check?)' : 'Reason for rejecting', noteRequired: true, danger: !approve,
    });
    if (c && await act.run('decide_approval', { p_approval_id: a.id, p_approve: approve, p_note: c.note }, !approve ? 'Rejected.' : a.steps_done + 1 < (a.step_levels?.length ?? 1) ? `Level ${a.steps_done + 1} approved — now waiting for ${LEVEL[a.step_levels[a.steps_done + 1]]}.`
      : a.kind === 'purchase_order' ? 'Approved — the order can now be sent to the supplier.' : 'Approved and posted.')) reload();
  };

  return (
    <>
      {confirm.node}
      <PageHeader title="Approvals" description="Purchase orders, large or unusual corrections, reversals, transfer write-offs, stocktake variances and opening balances wait here. High-value requests need more than one level, each decided by a different person."
        actions={<ExportButtons title="Approvals" rows={list.rows} cols={[{ key: 'kind', label: 'Type', get: (a) => KIND[a.kind] ?? a.kind }, { key: 'summary', label: 'Summary' }, { key: 'company_code', label: 'Company' },
          { key: 'warehouse_code', label: 'Warehouse' }, { key: 'value_zar', label: 'Value (ZAR)', num: true }, { key: 'step_levels', label: 'Levels', get: (a) => (a.step_levels ?? []).map((l) => LEVEL[l] ?? l).join(' → ') },
          { key: 'decisions', label: 'Decisions', get: (a) => (a.decisions ?? []).map((d) => `L${d.step} ${d.approved ? 'approved' : 'rejected'} by ${d.by}`).join('; ') }, { key: 'requested_by_name', label: 'Requested by' }, { key: 'requested_at', label: 'Requested', get: (a) => fmtDateTime(a.requested_at) },
          { key: 'status', label: 'Status' }, { key: 'decided_by_name', label: 'Decided by' }, { key: 'decided_at', label: 'Decided', get: (a) => fmtDateTime(a.decided_at) }, { key: 'decision_note', label: 'Note' }]} />} />
      <Tabs value={tab} onChange={setTab} tabs={[{ id: 'waiting', label: 'Waiting for a decision' }, { id: 'mine', label: 'My requests' }, { id: 'history', label: 'History' }]} />
      <ActionResult error={act.error} ok={act.ok} />
      <LoadError error={list.error} />
      {list.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>Type</Th><Th>Request</Th><Th>Where</Th><Th>Requested</Th><Th>Status</Th><Th /></tr></thead>
          <tbody>{list.rows.map((a) => {
            const t = target(a);
            return (
              <tr key={a.id}>
                <Td><Badge tone="info">{KIND[a.kind] ?? a.kind}</Badge></Td>
                <Td><div className="font-medium text-navy-900">{a.summary}</div>{t && <Link className="text-xs underline" href={t.href}>{t.label}</Link>}
                  {a.details && Object.keys(a.details).length > 0 && <div className="mt-1 text-xs text-steel-600">{Object.entries(a.details).filter(([, v]) => typeof v !== 'object').map(([k, v]) => `${k.replace(/_/g, ' ')}: ${v}`).join(' · ')}</div>}</Td>
                <Td>{a.company_code ?? 'Group'}{a.warehouse_code && ` / ${a.warehouse_code}`}{a.value_zar != null && Number(a.value_zar) > 0 && <div className="text-xs font-semibold">{fmtZAR(a.value_zar)}</div>}</Td>
                <Td className="text-xs">{a.requested_by_name}<div>{fmtDateTime(a.requested_at)}</div></Td>
                <Td><StatusBadge status={a.status} />{a.decided_by_name && <div className="text-xs text-steel-600">{a.decided_by_name} · {fmtDateTime(a.decided_at)}</div>}{a.decision_note && <div className="text-xs">{a.decision_note}</div>}
                  <Levels a={a} /></Td>
                <Td className="whitespace-nowrap">
                  {mayDecide(a) && <><Button size="sm" variant="primary" busy={act.busy} onClick={() => decide(a, true)}><CheckCircle2 className="size-4" />Approve</Button>{' '}
                    <Button size="sm" variant="danger" busy={act.busy} onClick={() => decide(a, false)}><XCircle className="size-4" />Reject</Button></>}
                  {a.status === 'pending' && a.requested_by === me?.user?.id && <Button size="sm" onClick={async () => {
                    const c = await confirm.ask({ title: 'Withdraw your request?', body: a.summary, noteLabel: 'Reason' });
                    if (c && await act.run('cancel_approval', { p_approval_id: a.id, p_note: c.note || null }, 'Request withdrawn.')) reload();
                  }}>Withdraw</Button>}
                </Td>
              </tr>
            );
          })}
            {list.rows.length === 0 && <tr><Td className="text-steel-600">{tab === 'waiting' ? 'Nothing is waiting for your decision.' : 'No requests.'}</Td></tr>}</tbody>
        </Table>
      )}
    </>
  );
}

/** Approval chain, e.g. ✓ Approver (J. Dlamini) → ○ Head office */
function Levels({ a }: { a: A }) {
  const levels = a.step_levels ?? ['any'];
  if (levels.length < 2 && !(a.decisions?.length)) return null;
  return (
    <ol className="mt-1 flex flex-wrap items-center gap-1 text-xs" aria-label="Approval levels">
      {levels.map((l, i) => {
        const d = a.decisions?.find((x) => x.step === i + 1);
        const current = a.status === 'pending' && i === a.steps_done;
        return (
          <li key={i} className="flex items-center gap-1">
            {i > 0 && <span className="text-steel-400">→</span>}
            <span title={d ? `${d.by} · ${fmtDateTime(d.at)}${d.note ? ' · ' + d.note : ''}` : undefined}
              className={`rounded px-1.5 py-0.5 ${d ? (d.approved ? 'bg-ok-50 text-ok-600' : 'bg-bad-50 text-bad-600') : current ? 'bg-signal-50 font-semibold text-navy-900 ring-1 ring-signal-400' : 'bg-steel-100 text-steel-600'}`}>
              {d ? (d.approved ? '✓ ' : '✗ ') : ''}{LEVEL[l] ?? l}{d ? ` (${d.by})` : ''}
            </span>
          </li>
        );
      })}
    </ol>
  );
}
