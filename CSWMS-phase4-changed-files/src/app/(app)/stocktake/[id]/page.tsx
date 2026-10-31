'use client';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { useMemo, useState } from 'react';
import { MapPin, Play, Send, Square, Undo2, UserPlus } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { ProductPicker } from '@/components/product-picker';
import { TxnOutcome } from '@/components/txn-outcome';
import { Photos } from '@/components/photos';
import { Badge, Button, Field, Input, Notice, OfflineNotice, PageHeader, Panel, Select, Spinner, StatusBadge, Table, Td, Th, cx } from '@/components/ui';
import { ActionResult, ExportButtons, KV, LoadError, Tabs, useConfirm } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useLocations } from '@/hooks/use-ref-data';
import { useOnline } from '@/hooks/use-online';
import { useRows } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtDate, fmtDateTime, fmtQty, parseQty } from '@/lib/format';
import type { ProductLookup } from '@/lib/types';

type Sheet = { line_id: string; product_id: string; sku: string; description: string; uom: string; location_id: string; location_code: string; counted_qty: number | null;
  line_status: string; current_round: number; expected_qty: number | null; is_unexpected: boolean };
type MLine = { id: string; product_id: string; location_id: string; expected_qty: number; adjusted_expected: number | null; movement_since_cutoff: number | null; counted_qty: number | null;
  first_count_qty: number | null; variance: number | null; line_status: string; flags: string[]; is_unexpected: boolean; current_round: number; recount_reason: string | null;
  products: { sku: string; description: string; uoms: { code: string } }; storage_locations: { code: string } };

const FLAG_LABEL: Record<string, string> = {
  missing: 'Missing', additional: 'Additional', not_counted: 'Not counted', unexpected_product: 'Unexpected item', possible_wrong_location: 'Possibly wrong location',
  possible_duplicate_entry: 'Possible duplicate entry', unusual_variance: 'Unusual variance', recounted: 'Recounted',
};

export default function StocktakeDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { can, me } = useApp();
  const online = useOnline();
  const head = useRows<Record<string, any>>('sth' + id, (sb) => sb.from('v_stocktake_summary').select('*').eq('id', id).maybeSingle());
  const s = head.rows[0];
  const manager = !!s && (can('stocktake.manage', s.warehouse_id) || can('stocktake.approve', s.warehouse_id));
  const sheet = useRows<Sheet>(s ? 'sheet' + id : null, (sb) => sb.rpc('stocktake_count_sheet', { p_stocktake_id: id }));
  const lines = useRows<MLine>(s && manager ? 'stl' + id : null, (sb) => sb.from('stocktake_lines')
    .select('id, product_id, location_id, expected_qty, adjusted_expected, movement_since_cutoff, counted_qty, first_count_qty, variance, line_status, flags, is_unexpected, current_round, recount_reason, products(sku, description, uoms(code)), storage_locations(code)')
    .eq('stocktake_id', id).order('location_id'));
  const assignees = useRows<{ user_id: string; location_ids: string[] | null; app_users: { full_name: string } }>(s ? 'asg' + id : null,
    (sb) => sb.from('stocktake_assignments').select('user_id, location_ids, app_users(full_name)').eq('stocktake_id', id));
  const act = useAction();
  const confirm = useConfirm();
  const [tab, setTab] = useState<'count' | 'review' | 'team'>('count');
  const reload = () => { head.reload(); sheet.reload(); lines.reload(); assignees.reload(); };

  if (head.loading) return <Spinner />;
  if (!s) return <><LoadError error={head.error} /><PageHeader title="Stocktake not found" /></>;
  const counting = s.status === 'counting' || s.status === 'review';
  const doAct = async (fn: string, args: Record<string, unknown>, ok: string) => { if (await act.run(fn, args, ok)) reload(); };

  return (
    <>
      {confirm.node}
      <PageHeader title={`${s.stocktake_no} — ${s.warehouse_code}`}
        description={<><StatusBadge status={s.status} /> · {s.name} · due {fmtDate(s.due_date)}{s.blind && <Badge tone="info" className="ml-1">blind count</Badge>}{s.is_overdue && <Badge tone="bad" className="ml-1">overdue</Badge>}</>}
        actions={manager && <>
          {s.status === 'scheduled' && can('stocktake.manage', s.warehouse_id) && <Button variant="primary" busy={act.busy} onClick={async () => {
            const c = await confirm.ask({ title: 'Start counting now?', body: 'The cut-off is taken now: expected quantities are snapshotted and movements after this moment are accounted for automatically.' });
            if (c) doAct('start_stocktake', { p_stocktake_id: s.id }, 'Counting started — cut-off recorded.');
          }}><Play className="size-4" />Start counting</Button>}
          {s.status === 'counting' && can('stocktake.manage', s.warehouse_id) && <Button variant="navy" busy={act.busy} onClick={async () => {
            const c = await confirm.ask({ title: 'Close counting?', body: 'Counts are compared with expected stock and discrepancies are flagged. Recounts can still be ordered.' });
            if (c) { await doAct('close_stocktake_counting', { p_stocktake_id: s.id }, 'Counting closed. Review the discrepancies.'); setTab('review'); }
          }}><Square className="size-4" />Close counting</Button>}
          {s.status === 'review' && can('stocktake.manage', s.warehouse_id) && <Button variant="primary" busy={act.busy} onClick={async () => {
            const c = await confirm.ask({ title: 'Submit for approval?', body: 'A manager who did not count will verify the discrepancies. Approved differences are then posted as traceable stocktake adjustments.', noteLabel: 'Notes for the approver' });
            if (c) doAct('submit_stocktake', { p_stocktake_id: s.id, p_notes: c.note || null }, 'Submitted for management approval.');
          }}><Send className="size-4" />Submit for approval</Button>}
          {!['finalised', 'cancelled', 'pending_approval'].includes(s.status) && can('stocktake.manage', s.warehouse_id) && <Button variant="danger" busy={act.busy} onClick={async () => {
            const c = await confirm.ask({ title: 'Cancel stocktake?', body: 'No adjustments will be posted.', noteLabel: 'Reason', noteRequired: true, danger: true });
            if (c) doAct('cancel_stocktake', { p_stocktake_id: s.id, p_reason: c.note }, 'Stocktake cancelled.');
          }}>Cancel</Button>}
        </>} />
      {!online && <OfflineNotice />}
      <ActionResult error={act.error} ok={act.ok} />
      <Panel className="my-4">
        <KV items={[['Warehouse', `${s.warehouse_code} — ${s.warehouse_name}`], ['Branch / company', `${s.branch_name} · ${s.company_code}`], ['Period', s.period],
          ['Cut-off', s.cutoff_at ? fmtDateTime(s.cutoff_at) : 'Not started'], ['Progress', `${s.counted}/${s.lines} lines counted (${Math.round(Number(s.pct_counted || 0))}%)`],
          ['Discrepancies', `${s.discrepancies} (missing ${s.missing}, additional ${s.additional}, not counted ${s.not_counted})`],
          ['Submitted', fmtDateTime(s.submitted_at)], ['Finalised', fmtDateTime(s.finalised_at)]]} />
        {s.status === 'pending_approval' && <Notice tone="warn" className="mt-3" title="Awaiting management approval"><Link className="underline" href="/approvals">Open approvals</Link></Notice>}
      </Panel>
      <Tabs value={tab} onChange={setTab} tabs={[{ id: 'count', label: 'Count' }, { id: 'review', label: 'Compare & discrepancies', hidden: !manager }, { id: 'team', label: 'Counters', hidden: !manager }]} />
      {tab === 'count' && <CountPanel st={s} sheet={sheet.rows} onCounted={() => { sheet.reload(); if (manager) lines.reload(); head.reload(); }} counting={counting} />}
      {tab === 'review' && manager && <ReviewPanel st={s} lines={lines.rows} loading={lines.loading} reload={reload} />}
      {tab === 'team' && manager && <TeamPanel st={s} assignees={assignees.rows} reload={assignees.reload} myId={me?.user?.id} />}
      <div className="mt-6"><Photos entityType="stocktake" entityId={s.id} title="Photos (damaged stock, empty bins, labels)" canAdd={s.status !== 'finalised' && s.status !== 'cancelled'} /></div>
    </>
  );
}

function CountPanel({ st, sheet, onCounted, counting }: { st: Record<string, any>; sheet: Sheet[]; onCounted: () => void; counting: boolean }) {
  const { me } = useApp();
  const { data: locs } = useLocations(st.warehouse_id);
  const txn = useTransaction('record_count');
  const act = useAction();
  const [locId, setLocId] = useState('');
  const [p, setP] = useState<ProductLookup | null>(null);
  const [qty, setQty] = useState('');
  const [uom, setUom] = useState('');
  const myCounts = useRows<{ id: string; qty_base: number; entered_qty: number; counted_at: string; round: number; voided: boolean; line_id: string }>('mc' + st.id + txn.state.phase,
    (sb) => sb.from('stocktake_counts').select('id, qty_base, entered_qty, counted_at, round, voided, line_id').eq('stocktake_id', st.id).eq('counted_by', me?.user?.id ?? '').order('counted_at', { ascending: false }).limit(30));
  const loc = locs.find((l) => l.id === locId);
  const recountOnly = st.status === 'review';
  const q = parseQty(qty);
  const qErr = qty === '' ? null : q === null || isNaN(q) ? 'Not a number' : q < 0 ? 'Cannot be negative' : null;
  const ready = counting && !!p && !!locId && qty !== '' && !qErr;
  const byLoc = useMemo(() => {
    const m = new Map<string, Sheet[]>();
    for (const r of sheet) { const k = r.location_code; m.set(k, [...(m.get(k) ?? []), r]); }
    return [...m.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [sheet]);
  const lineFor = (pid: string, lid: string) => sheet.find((r) => r.product_id === pid && r.location_id === lid);

  if (!counting) return <Notice tone="info">{st.status === 'scheduled' ? 'Counting has not started yet.' : 'Counting is closed for this stocktake.'}</Notice>;
  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_24rem]">
      <div className="space-y-4">
        <Link href={`/stocktake/${st.id}/count`} className="flex items-center justify-between gap-3 rounded-lg border-2 border-navy-900 bg-signal-400 px-5 py-4 text-navy-950 hover:bg-signal-500">
          <span><span className="block text-lg font-semibold">Guided count — bin by bin</span>
            <span className="block text-sm">Scan to count (+1 per scan), &quot;bin empty&quot;, sound &amp; flash — keeps working without signal.</span></span>
          <Play className="size-6 shrink-0" />
        </Link>
        <p className="text-xs text-steel-600">Or record counts one by one below.</p>
        {recountOnly && <Notice tone="warn" title="Recount only">Only lines marked for recount can be counted now.</Notice>}
        <Panel title={<span className="flex items-center gap-2"><MapPin className="size-4" />1. Location being counted</span>}>
          <Select value={locId} onChange={(e) => setLocId(e.target.value)} className="h-12">
            <option value="">— scan a location label or choose —</option>
            {locs.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}
          </Select>
        </Panel>
        <Panel title="2. Scan or find the item">
          <ProductPicker warehouseId={st.warehouse_id} big onLocation={(l) => setLocId(l.id)}
            onProduct={(x) => { txn.reset(); setP(x); setUom(x.scanned_uom_id ?? x.product.base_uom.id); setQty(''); }} />
        </Panel>
        {txn.state.phase === 'saved' && <TxnOutcome state={txn.state} onRetry={txn.retry} savedText={(r) => <>Count recorded. Total at this location: <b>{fmtQty(r.line_total as number)}</b>{r.possible_duplicate_entry ? ' — flagged as a possible duplicate entry, check it.' : ''}{r.unexpected ? ' (unexpected item)' : ''}. Scan the next item.</>} />}
        {p && (
          <Panel title="3. Quantity counted">
            <div className="mb-3"><div className="font-mono text-sm font-semibold">{p.product.sku}</div><div className="text-lg font-semibold text-navy-900">{p.product.description}</div>
              <div className="text-sm text-steel-600">At {loc?.code ?? '—'}{locId && lineFor(p.product.id, locId) ? <> · counted so far this round: <b>{lineFor(p.product.id, locId)?.counted_qty != null ? fmtQty(lineFor(p.product.id, locId)?.counted_qty) : 'not yet'}</b></> : locId ? <Badge tone="warn" className="ml-1">not expected here — will be recorded as unexpected</Badge> : null}</div></div>
            <div className="flex gap-2">
              <Input inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} className={cx('h-14 w-40 text-right text-xl font-semibold', qErr && 'border-bad-600')} autoFocus placeholder="0" aria-label="Quantity counted" />
              <Select value={uom} onChange={(e) => setUom(e.target.value)} className="h-14 w-32">{p.units.map((u) => <option key={u.uom_id} value={u.uom_id}>{u.code}{u.factor !== 1 ? ` (${fmtQty(u.factor)})` : ''}</option>)}</Select>
            </div>
            {qErr && <p className="mt-1 text-xs text-bad-600">{qErr}</p>}
            <p className="mt-2 text-xs text-steel-600">Each entry is <b>added</b> to this item&apos;s count at this location for the current round (e.g. count each pallet separately). Enter <b>0</b> to confirm the item is not there. Mistakes can be voided below.</p>
            {txn.state.phase !== 'saved' && <div className="mt-3"><TxnOutcome state={txn.state} onRetry={txn.retry} /></div>}
            <Button className="mt-3 w-full" variant="primary" size="lg" disabled={!ready || txn.state.phase === 'saving'} busy={txn.state.phase === 'saving'}
              onClick={async () => { if (await txn.run({ p_stocktake_id: st.id, p_product_id: p.product.id, p_location_id: locId, p_qty: q, p_uom_id: uom })) { setQty(''); setP(null); onCounted(); } }}>
              Record count
            </Button>
          </Panel>
        )}
        <Panel title="My recent entries" padded={false}>
          <ActionResult error={act.error} ok={act.ok} />
          <Table className="rounded-none border-0">
            <thead><tr><Th>When</Th><Th>Item / location</Th><Th right>Qty (base)</Th><Th>Round</Th><Th /></tr></thead>
            <tbody>{myCounts.rows.map((c) => {
              const l = sheet.find((x) => x.line_id === c.line_id);
              return (
                <tr key={c.id} className={c.voided ? 'opacity-50 line-through' : ''}><Td className="text-xs">{fmtDateTime(c.counted_at)}</Td><Td><span className="font-mono text-[13px]">{l?.sku}</span> @ {l?.location_code}</Td>
                  <Td right>{fmtQty(c.qty_base)}</Td><Td>{c.round}</Td>
                  <Td>{!c.voided && <button className="inline-flex items-center gap-1 text-xs text-bad-600 underline" onClick={async () => {
                    const reason = window.prompt('Why is this entry wrong?');
                    if (reason && await act.run('void_count', { p_count_id: c.id, p_reason: reason }, 'Entry voided.')) { myCounts.reload(); onCounted(); }
                  }}><Undo2 className="size-3" />void</button>}</Td></tr>
              );
            })}
              {myCounts.rows.length === 0 && <tr><Td className="text-steel-600">No entries yet.</Td></tr>}</tbody>
          </Table>
        </Panel>
      </div>
      <Panel title="Count sheet" padded={false}>
        <div className="max-h-[70vh] overflow-y-auto">
          {byLoc.map(([code, rows]) => (
            <div key={code}>
              <div className="sticky top-0 bg-steel-100 px-3 py-1 font-mono text-xs font-semibold text-navy-900">{code}</div>
              <ul className="divide-y divide-steel-100">
                {rows.map((r) => (
                  <li key={r.line_id} className={cx('flex items-center justify-between gap-2 px-3 py-2 text-sm', r.line_status === 'recount_requested' && 'bg-warn-50')}>
                    <span className="min-w-0"><span className="font-mono text-[12px]">{r.sku}</span> <span className="text-steel-800">{r.description}</span>{r.is_unexpected && <Badge tone="warn" className="ml-1">unexpected</Badge>}</span>
                    <span className="shrink-0 text-right text-xs">
                      {r.counted_qty != null ? <b className="text-ok-600">{fmtQty(r.counted_qty)} {r.uom}</b> : <span className="text-steel-400">not counted</span>}
                      {r.expected_qty != null && <div className="text-steel-600">exp. {fmtQty(r.expected_qty)}</div>}
                      {r.line_status === 'recount_requested' && <div className="font-semibold text-warn-600">RECOUNT</div>}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          ))}
          {sheet.length === 0 && <p className="p-4 text-sm text-steel-600">No lines assigned to you.</p>}
        </div>
      </Panel>
    </div>
  );
}

function ReviewPanel({ st, lines, loading, reload }: { st: Record<string, any>; lines: MLine[]; loading: boolean; reload: () => void }) {
  const act = useAction();
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [filter, setFilter] = useState<'issues' | 'all'>('issues');
  const [reason, setReason] = useState('');
  const shown = filter === 'all' ? lines : lines.filter((l) => (l.variance != null && Number(l.variance) !== 0) || l.counted_qty == null || (l.flags?.length ?? 0) > 0);
  const canManage = ['counting', 'review'].includes(st.status);
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <Tabs value={filter} onChange={setFilter} tabs={[{ id: 'issues', label: `Needs attention (${lines.filter((l) => (l.variance != null && Number(l.variance) !== 0) || l.counted_qty == null || (l.flags?.length ?? 0) > 0).length})` }, { id: 'all', label: `All lines (${lines.length})` }]} />
        <div className="flex gap-2">
          {canManage && <Button size="sm" busy={act.busy} onClick={async () => { if (await act.run('refresh_stocktake_comparison', { p_stocktake_id: st.id }, 'Comparison refreshed (movements since cut-off re-applied).')) reload(); }}>Refresh comparison</Button>}
          <ExportButtons title={`Stocktake variance ${st.stocktake_no}`} rows={lines} cols={[
            { key: 'sku', label: 'SKU', get: (l) => l.products.sku }, { key: 'description', label: 'Description', get: (l) => l.products.description },
            { key: 'location', label: 'Location', get: (l) => l.storage_locations.code }, { key: 'expected_qty', label: 'Expected at cut-off', num: true },
            { key: 'movement_since_cutoff', label: 'Movements since cut-off', num: true }, { key: 'adjusted_expected', label: 'Expected at count', num: true },
            { key: 'first_count_qty', label: 'First count', num: true }, { key: 'counted_qty', label: 'Final count', num: true }, { key: 'variance', label: 'Variance', num: true },
            { key: 'uom', label: 'Unit', get: (l) => l.products.uoms.code }, { key: 'flags', label: 'Flags', get: (l) => (l.flags ?? []).join(', ') }, { key: 'line_status', label: 'Status' }]} />
        </div>
      </div>
      <ActionResult error={act.error} ok={act.ok} />
      {loading ? <Spinner /> : (
        <Table>
          <thead><tr>{canManage && <Th />}<Th>Item</Th><Th>Location</Th><Th right>Expected at cut-off</Th><Th right>Movements since</Th><Th right>Expected at count</Th><Th right>Counted</Th><Th right>Variance</Th><Th>Flags</Th></tr></thead>
          <tbody>{shown.map((l) => (
            <tr key={l.id} className={cx(l.line_status === 'recount_requested' && 'bg-warn-50')}>
              {canManage && <Td><input type="checkbox" aria-label="Select for recount" checked={sel.has(l.id)} onChange={(e) => { const n = new Set(sel); if (e.target.checked) n.add(l.id); else n.delete(l.id); setSel(n); }} /></Td>}
              <Td><span className="font-mono text-[13px]">{l.products.sku}</span> {l.products.description}</Td><Td mono>{l.storage_locations.code}</Td>
              <Td right>{fmtQty(l.expected_qty)}</Td><Td right>{l.movement_since_cutoff ? fmtQty(l.movement_since_cutoff) : '—'}</Td><Td right>{fmtQty(l.adjusted_expected ?? l.expected_qty)}</Td>
              <Td right>{l.counted_qty != null ? fmtQty(l.counted_qty) : <span className="text-steel-400">not counted</span>}{l.current_round > 1 && <div className="text-xs text-steel-600">1st: {fmtQty(l.first_count_qty)}</div>}</Td>
              <Td right className={cx('font-semibold', Number(l.variance) < 0 ? 'text-bad-600' : Number(l.variance) > 0 ? 'text-warn-600' : 'text-ok-600')}>{l.variance != null ? (Number(l.variance) > 0 ? '+' : '') + fmtQty(l.variance) : '—'} <span className="text-xs font-normal">{l.products.uoms.code}</span></Td>
              <Td><div className="flex flex-wrap gap-1">{(l.flags ?? []).map((f) => <Badge key={f} tone={f === 'missing' ? 'bad' : 'warn'}>{FLAG_LABEL[f] ?? f}</Badge>)}{l.line_status === 'recount_requested' && <Badge tone="info">recount ordered</Badge>}</div></Td>
            </tr>
          ))}
            {shown.length === 0 && <tr><Td className="text-steel-600">Nothing needs attention.</Td></tr>}</tbody>
        </Table>
      )}
      {canManage && sel.size > 0 && (
        <Panel title={`Order a recount of ${sel.size} line(s)`}>
          <div className="flex gap-2"><Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Reason, e.g. large variance on high-value item" />
            <Button variant="navy" busy={act.busy} onClick={async () => { if (await act.run('request_recount', { p_stocktake_id: st.id, p_line_ids: [...sel], p_reason: reason || null }, 'Recount ordered. Counters will see these lines marked RECOUNT.')) { setSel(new Set()); setReason(''); reload(); } }}>Order recount</Button></div>
        </Panel>
      )}
    </div>
  );
}

function TeamPanel({ st, assignees, reload, myId }: { st: Record<string, any>; assignees: { user_id: string; location_ids: string[] | null; app_users: { full_name: string } }[]; reload: () => void; myId?: string }) {
  const users = useRows<{ id: string; full_name: string; employee_number: string | null }>('users', (sb) => sb.from('app_users').select('id, full_name, employee_number').eq('is_active', true).order('full_name'));
  const { data: locs } = useLocations(st.warehouse_id);
  const act = useAction();
  const [user, setUser] = useState('');
  const [loc, setLoc] = useState('');
  const open = ['scheduled', 'counting', 'review'].includes(st.status);
  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <Panel title="Assigned counters" padded={false}>
        <ul className="divide-y divide-steel-100">
          {assignees.map((a) => (
            <li key={a.user_id} className="flex items-center justify-between px-4 py-2 text-sm">
              <span>{a.app_users?.full_name}{a.user_id === myId && ' (you)'}<div className="text-xs text-steel-600">{a.location_ids?.length ? `Locations: ${a.location_ids.map((x) => locs.find((l) => l.id === x)?.code ?? '?').join(', ')}` : 'Whole warehouse'}</div></span>
              {open && <button className="text-xs text-bad-600 underline" onClick={async () => { if (await act.run('unassign_stocktake', { p_stocktake_id: st.id, p_user_id: a.user_id }, 'Removed.')) reload(); }}>remove</button>}
            </li>
          ))}
          {assignees.length === 0 && <li className="px-4 py-3 text-sm text-steel-600">Nobody assigned yet.</li>}
        </ul>
      </Panel>
      {open && (
        <Panel title={<span className="flex items-center gap-2"><UserPlus className="size-4" />Assign a counter</span>}>
          <div className="space-y-3">
            <Field label="Employee"><Select value={user} onChange={(e) => setUser(e.target.value)}><option value="">— choose —</option>{users.rows.map((u) => <option key={u.id} value={u.id}>{u.full_name}{u.employee_number ? ` (${u.employee_number})` : ''}</option>)}</Select></Field>
            <Field label="Location (optional)" hint="Leave blank to let them count the whole warehouse."><Select value={loc} onChange={(e) => setLoc(e.target.value)}><option value="">Whole warehouse</option>{locs.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}</Select></Field>
            <ActionResult error={act.error} ok={act.ok} />
            <Button variant="navy" disabled={!user} busy={act.busy} onClick={async () => { if (await act.run('assign_stocktake', { p_stocktake_id: st.id, p_user_id: user, p_location_ids: loc ? [loc] : null }, 'Counter assigned.')) { setUser(''); setLoc(''); reload(); } }}>Assign</Button>
            <p className="text-xs text-steel-600">Counters must hold the Stocktake Counter role (or higher) for this warehouse. Managers who count cannot approve the same stocktake.</p>
          </div>
        </Panel>
      )}
    </div>
  );
}
