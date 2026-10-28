'use client';
import { useParams } from 'next/navigation';
import { useEffect, useState } from 'react';
import { useApp } from '@/components/app-context';
import { TxnOutcome } from '@/components/txn-outcome';
import { Badge, Button, Field, Input, Notice, OfflineNotice, PageHeader, Panel, Select, Spinner, StatusBadge, Table, Td, Textarea, Th } from '@/components/ui';
import { ActionResult, KV, LoadError, TxnLink, useConfirm } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useLocations, useReasons } from '@/hooks/use-ref-data';
import { useOnline } from '@/hooks/use-online';
import { useRows } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtDateTime, fmtQty, parseQty } from '@/lib/format';

type T = Record<string, any>;
type Line = { id: string; line_no: number; product_id: string; qty_dispatched: number; qty_received: number; qty_damaged: number; qty_written_off: number;
  entered_qty: number; products: { sku: string; description: string; uoms: { code: string; decimals: number } }; from: { code: string } | null; to: { code: string } | null; to_location_id: string | null };

export default function TransferDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { can } = useApp();
  const online = useOnline();
  const head = useRows<T>('th' + id, (sb) => sb.from('v_transfers').select('*').eq('id', id).maybeSingle());
  const lines = useRows<Line>('tl' + id, (sb) => sb.from('transfer_lines')
    .select('id, line_no, product_id, qty_dispatched, qty_received, qty_damaged, qty_written_off, entered_qty, to_location_id, products(sku, description, uoms(code, decimals)), from:storage_locations!transfer_lines_from_location_id_fkey(code), to:storage_locations!transfer_lines_to_location_id_fkey(code)')
    .eq('transfer_id', id).order('line_no'));
  const t = head.rows[0];
  const { data: destLocs } = useLocations(t?.to_warehouse_id ?? null);
  const { data: woReasons } = useReasons('transfer_writeoff');
  const rcv = useTransaction('receive_transfer');
  const dsp = useTransaction('dispatch_transfer');
  const wo = useTransaction('request_transfer_writeoff');
  const act = useAction();
  const confirm = useConfirm();
  const [recv, setRecv] = useState<Record<string, { ok: string; dmg: string; loc: string }>>({});
  const [woReason, setWoReason] = useState('');
  const [woNotes, setWoNotes] = useState('');
  const [notes, setNotes] = useState('');

  const reload = () => { head.reload(); lines.reload(); };
  useEffect(() => { if (rcv.state.phase === 'saved' || dsp.state.phase === 'saved' || wo.state.phase === 'saved') reload(); // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rcv.state.phase, dsp.state.phase, wo.state.phase]);

  if (head.loading) return <Spinner />;
  if (!t) return <><LoadError error={head.error} /><PageHeader title="Transfer not found" /></>;

  const outstanding = (l: Line) => Number(l.qty_dispatched) - Number(l.qty_received) - Number(l.qty_damaged) - Number(l.qty_written_off);
  const open = ['dispatched', 'partially_received'].includes(t.status);
  const canReceive = open && can('stock.transfer.receive', t.to_warehouse_id);
  const canDispatch = t.status === 'draft' && can('stock.transfer.dispatch', t.from_warehouse_id);
  const receiveRows = lines.rows.filter((l) => outstanding(l) > 0).map((l) => {
    const r = recv[l.id] ?? { ok: '', dmg: '', loc: '' };
    const ok = parseQty(r.ok) ?? 0; const dmg = parseQty(r.dmg) ?? 0;
    const err = isNaN(ok) || isNaN(dmg) ? 'Not a number' : ok < 0 || dmg < 0 ? 'Cannot be negative' : ok + dmg > outstanding(l) ? `More than the ${fmtQty(outstanding(l))} outstanding` : null;
    return { l, r, ok, dmg, err };
  });
  const anyQty = receiveRows.some((x) => x.ok + x.dmg > 0);
  const recvReady = online && anyQty && receiveRows.every((x) => !x.err);
  const shortLeft = open && lines.rows.some((l) => outstanding(l) > 0);

  return (
    <>
      {confirm.node}
      <PageHeader title={`Transfer ${t.transfer_no}`} description={<><StatusBadge status={t.status} />{t.is_overdue && <Badge tone="bad" className="ml-1">overdue</Badge>} · {t.from_warehouse_code} → {t.to_warehouse_code}</>}
        actions={<>
          {canDispatch && <Button variant="primary" busy={dsp.state.phase === 'saving'} onClick={() => dsp.run({ p_transfer_id: t.id })}>Dispatch now</Button>}
          {(t.status === 'draft' || t.status === 'dispatched') && can('stock.transfer.dispatch', t.from_warehouse_id) && (
            <Button variant="danger" busy={act.busy} onClick={async () => {
              const c = await confirm.ask({ title: 'Cancel this transfer?', body: t.status === 'dispatched' ? 'In-transit stock returns to its original location.' : 'The draft will be cancelled.', noteLabel: 'Reason', noteRequired: true, danger: true });
              if (c && await act.run('cancel_transfer', { p_transfer_id: t.id, p_notes: c.note }, 'Transfer cancelled.')) reload();
            }}>Cancel transfer</Button>
          )}
        </>} />
      {!online && <OfflineNotice />}
      <div className="space-y-6">
        <ActionResult error={act.error} ok={act.ok} />
        <TxnOutcome state={dsp.state} onRetry={dsp.retry} savedText={() => 'Dispatched. The stock is now in transit.'} />
        {rcv.state.phase === 'saved' && <TxnOutcome state={rcv.state} onRetry={rcv.retry} savedText={() => 'Receipt confirmed. Stock is now available at the destination.'} />}
        {wo.state.phase === 'saved' && <TxnOutcome state={wo.state} onRetry={wo.retry} savedText={() => 'Write-off requested. It is posted only after management approval.'} />}
        <Panel>
          <KV items={[
            ['From', `${t.from_warehouse_code} — ${t.from_warehouse_name} (${t.from_branch_code}, ${t.from_company_code})`],
            ['To', `${t.to_warehouse_code} — ${t.to_warehouse_name} (${t.to_branch_code}, ${t.to_company_code})`],
            ['Ownership on receipt', t.to_owner_company_code ? `Transferred to ${t.to_owner_company_code}` : 'Unchanged'],
            ['Created', `${t.created_by_name} · ${fmtDateTime(t.created_at)}`], ['Dispatched', t.dispatched_at ? `${t.dispatched_by_name ?? ''} · ${fmtDateTime(t.dispatched_at)}` : 'Not yet'],
            ['Expected arrival', fmtDateTime(t.expected_arrival_at)], ['Completed', fmtDateTime(t.completed_at)], ['Reference', t.reference], ['Notes', t.notes],
            ['Dispatch transaction', t.dispatch_txn_id ? <TxnLink id={t.dispatch_txn_id} no="view" /> : null],
          ]} />
        </Panel>

        <Panel title="Lines" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>#</Th><Th>Product</Th><Th>From → To</Th><Th right>Dispatched</Th><Th right>Received</Th><Th right>Damaged</Th><Th right>Written off</Th><Th right>Outstanding</Th></tr></thead>
            <tbody>{lines.rows.map((l) => (
              <tr key={l.id}><Td>{l.line_no}</Td><Td><span className="font-mono text-[13px]">{l.products.sku}</span> {l.products.description}</Td>
                <Td mono>{l.from?.code ?? '—'} → {l.to?.code ?? 'RECEIVING'}</Td>
                <Td right>{fmtQty(l.qty_dispatched)} {l.products.uoms.code}</Td><Td right>{fmtQty(l.qty_received)}</Td><Td right>{fmtQty(l.qty_damaged)}</Td>
                <Td right>{fmtQty(l.qty_written_off)}</Td><Td right className={outstanding(l) > 0 ? 'font-semibold text-warn-600' : ''}>{fmtQty(outstanding(l))}</Td></tr>
            ))}</tbody>
          </Table>
        </Panel>

        {canReceive && receiveRows.length > 0 && (
          <Panel title="Receive this transfer">
            <p className="mb-3 text-sm text-steel-600">Count what physically arrived. Enter good and damaged quantities separately. Anything not received stays outstanding until it arrives or a shortage write-off is approved.</p>
            <Table>
              <thead><tr><Th>Product</Th><Th right>Outstanding</Th><Th>Received in good condition</Th><Th>Damaged</Th><Th>Put away at</Th></tr></thead>
              <tbody>{receiveRows.map(({ l, r, err }) => (
                <tr key={l.id}>
                  <Td><span className="font-mono text-[13px]">{l.products.sku}</span> {l.products.description}</Td>
                  <Td right>{fmtQty(outstanding(l))} {l.products.uoms.code}</Td>
                  <Td><Input inputMode="decimal" className="w-28 text-right" value={r.ok} onChange={(e) => setRecv({ ...recv, [l.id]: { ...r, ok: e.target.value } })} />
                    <button type="button" className="ml-2 text-xs underline" onClick={() => setRecv({ ...recv, [l.id]: { ...r, ok: String(outstanding(l)), dmg: '' } })}>all</button>
                    {err && <div className="text-xs text-bad-600">{err}</div>}</Td>
                  <Td><Input inputMode="decimal" className="w-24 text-right" value={r.dmg} onChange={(e) => setRecv({ ...recv, [l.id]: { ...r, dmg: e.target.value } })} /></Td>
                  <Td><Select value={r.loc} onChange={(e) => setRecv({ ...recv, [l.id]: { ...r, loc: e.target.value } })}>
                    <option value="">{l.to?.code ?? 'Receiving (default)'}</option>
                    {destLocs.map((x) => <option key={x.id} value={x.id}>{x.code} — {x.name}</option>)}
                  </Select></Td>
                </tr>
              ))}</tbody>
            </Table>
            <Field label="Receiving notes" className="mt-3"><Textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} /></Field>
            {rcv.state.phase !== 'saved' && <div className="mt-3"><TxnOutcome state={rcv.state} onRetry={rcv.retry} /></div>}
            <Button className="mt-3" variant="primary" size="lg" disabled={!recvReady || rcv.state.phase === 'saving'} busy={rcv.state.phase === 'saving'}
              onClick={async () => {
                const r = await rcv.run({ p_transfer_id: t.id, p_notes: notes.trim() || null,
                  p_lines: receiveRows.filter((x) => x.ok + x.dmg > 0).map((x) => ({ transfer_line_id: x.l.id, qty_received: x.ok, qty_damaged: x.dmg, location_id: x.r.loc || undefined })) });
                if (r) { setRecv({}); setNotes(''); }
              }}>Confirm receipt</Button>
          </Panel>
        )}

        {shortLeft && (can('stock.transfer.receive', t.to_warehouse_id) || can('stock.transfer.dispatch', t.from_warehouse_id)) && (
          <Panel title="Stock did not arrive? Request a shortage write-off">
            <p className="mb-3 text-sm text-steel-600">Writes off everything still outstanding after management approval and closes the transfer with a discrepancy. Investigate with the dispatching site first.</p>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Reason" required><Select value={woReason} onChange={(e) => setWoReason(e.target.value)}><option value="">— choose —</option>{woReasons.map((r) => <option key={r.code} value={r.code}>{r.label}</option>)}</Select></Field>
              <Field label="Explanation" required><Input value={woNotes} onChange={(e) => setWoNotes(e.target.value)} placeholder="e.g. driver confirms 6 rolls missing" /></Field>
            </div>
            {wo.state.phase !== 'saved' && <div className="mt-3"><TxnOutcome state={wo.state} onRetry={wo.retry} /></div>}
            <Button className="mt-3" variant="danger" disabled={!woReason || woNotes.trim().length < 5 || !online} busy={wo.state.phase === 'saving'}
              onClick={() => wo.run({ p_transfer_id: t.id, p_reason_code: woReason, p_notes: woNotes.trim() })}>Request write-off approval</Button>
          </Panel>
        )}
        {!open && t.status !== 'draft' && <Notice tone={t.status === 'closed_with_discrepancy' ? 'warn' : 'ok'} title={t.status === 'closed_with_discrepancy' ? 'Closed with a discrepancy' : 'Transfer complete'} />}
      </div>
    </>
  );
}
