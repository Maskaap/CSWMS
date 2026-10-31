'use client';
import { Photos } from '@/components/photos';
import { useParams } from 'next/navigation';
import { useState } from 'react';
import { ArrowDownToLine, ArrowUpFromLine, Printer, ScanSearch } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { BarcodeSVG } from '@/components/barcode';
import { TxnOutcome } from '@/components/txn-outcome';
import { Badge, Button, Field, Input, Notice, PageHeader, Panel, Select, Spinner, StatusBadge, Table, Td, Textarea, Th } from '@/components/ui';
import { KV, LoadError, Tabs } from '@/components/widgets';
import { useAllWarehouses, useLocations } from '@/hooks/use-ref-data';
import { useRows } from '@/hooks/use-rows';
import { useTransaction } from '@/hooks/use-transaction';
import { fmtDate, fmtDateTime, fmtZAR } from '@/lib/format';

const MOVE: Record<string, string> = { register: 'Registered', check_out: 'Checked out', check_in: 'Returned', transfer: 'Moved', send_repair: 'Sent for repair',
  return_repair: 'Back from repair', mark_lost: 'Reported lost', found: 'Found', retire: 'Retired', verify: 'Verified' };

const plusDays = (n: number) => { const d = new Date(Date.now() + n * 864e5); return d.toISOString().slice(0, 10); };

export default function AssetPage() {
  const { id } = useParams<{ id: string }>();
  const { can, me } = useApp();
  const a = useRows<Record<string, any>>('as' + id, (sb) => sb.from('v_assets').select('*').eq('id', id).maybeSingle());
  const hist = useRows<Record<string, any>>('ah' + id, (sb) => sb.from('v_asset_movements').select('*').eq('asset_id', id).order('id', { ascending: false }));
  const x = a.rows[0];
  const reload = () => { a.reload(); hist.reload(); };
  if (a.loading && !x) return <Spinner />;
  if (!x) return <><LoadError error={a.error} /><PageHeader title="Item not found" /></>;
  const checkout = can('asset.checkout', x.warehouse_id);
  const manage = can('asset.manage', x.warehouse_id);
  return (
    <>
      <PageHeader title={`${x.asset_tag} — ${x.product_description}`}
        description={<><StatusBadge status={x.status} />{x.condition !== 'good' && <Badge tone={x.condition === 'damaged' ? 'bad' : 'warn'} className="ml-1">{x.condition}</Badge>}{x.is_overdue && <Badge tone="bad" className="ml-1">overdue</Badge>}</>}
        actions={<Button size="sm" onClick={() => window.print()}><Printer className="size-4" />Print tag</Button>} />
      <div className="grid gap-6 lg:grid-cols-[1fr_20rem]">
        <div className="space-y-6">
          <Panel>
            <KV items={[
              ['Product', `${x.sku} — ${x.product_description}`], ['Serial number', x.serial_number], ['Owner', x.owner_company_code],
              ['Home warehouse', x.home_warehouse_code], ['Now at', x.status === 'checked_out' ? '—' : `${x.warehouse_code}${x.location_code ? ' / ' + x.location_code : ''}`],
              ['Held by', x.holder ? `${x.holder}${x.holder_employee_number ? ' (' + x.holder_employee_number + ')' : ''}` : null], ['Job / reference', x.job_reference],
              ['Checked out', fmtDateTime(x.checked_out_at)], ['Due back', x.due_back_at ? <span className={x.is_overdue ? 'text-bad-600' : ''}>{fmtDateTime(x.due_back_at)}</span> : null],
              ['Purchased', x.purchase_date ? `${fmtDate(x.purchase_date)}${x.purchase_cost != null ? ' · ' + fmtZAR(x.purchase_cost) : ''}` : null],
              ['Last verified', fmtDateTime(x.last_verified_at)], ['Notes', x.notes],
            ]} />
          </Panel>
          <div className="no-print"><Actions x={x} checkout={checkout} manage={manage} meId={me?.user?.id} onDone={reload} /></div>
          <div className="no-print"><Photos entityType="asset" entityId={x.id} title="Condition photos" /></div>
          <Panel title="History (permanent)" padded={false}>
            <Table className="rounded-none border-0">
              <thead><tr><Th>When</Th><Th>What</Th><Th>Where / who</Th><Th>Condition</Th><Th>By</Th><Th>Notes</Th></tr></thead>
              <tbody>{hist.rows.map((m) => (
                <tr key={m.id}><Td className="whitespace-nowrap text-xs">{fmtDateTime(m.created_at)}</Td><Td>{MOVE[m.movement] ?? m.movement}</Td>
                  <Td>{m.movement === 'check_out' ? <>{m.holder}{m.job_reference && <span className="text-xs text-steel-600"> · {m.job_reference}</span>}</> : <>{m.warehouse_code}{m.location_code && <span className="font-mono text-[12px]"> / {m.location_code}</span>}</>}</Td>
                  <Td>{m.condition}</Td><Td>{m.created_by_name}</Td><Td className="text-xs">{m.notes}</Td></tr>
              ))}</tbody>
            </Table>
          </Panel>
        </div>
        <Panel title="Tag label">
          <div className="flex flex-col items-center gap-2 text-center">
            <BarcodeSVG value={x.asset_tag} kind="code128" height={12} className="[&>svg]:h-auto [&>svg]:max-w-full" />
            <BarcodeSVG value={x.asset_tag} kind="qrcode" text={false} className="[&>svg]:h-28 [&>svg]:w-auto" />
            <div className="text-xs text-black">{x.product_description}<br />Property of {x.owner_company_code} — return to {x.home_warehouse_code}</div>
          </div>
        </Panel>
      </div>
    </>
  );
}

function Actions({ x, checkout, manage, meId, onDone }: { x: Record<string, any>; checkout: boolean; manage: boolean; meId?: string; onDone: () => void }) {
  const users = useRows<{ id: string; full_name: string; employee_number: string | null }>('users', (sb) => sb.from('app_users').select('id, full_name, employee_number').eq('is_active', true).order('full_name'));
  const { data: locs } = useLocations(x.warehouse_id);
  const { data: whs } = useAllWarehouses();
  const [toWh, setToWh] = useState('');
  const { data: toLocs } = useLocations(toWh || null);
  const out = useTransaction('checkout_asset');
  const back = useTransaction('checkin_asset');
  const status = useTransaction('set_asset_status');
  const move = useTransaction('transfer_asset');
  const verify = useTransaction('verify_asset');
  const [f, setF] = useState({ holder: '', name: '', job: '', due: plusDays(7), notes: '', loc: '', cond: 'good', status: 'in_repair' });
  const [tab, setTab] = useState<string>(x.status === 'checked_out' ? 'in' : x.status === 'in_store' ? 'out' : 'status');
  const after = (r: unknown) => { if (r) { onDone(); setF({ ...f, notes: '', job: '', holder: '', name: '' }); } };
  const tabs = [
    { id: 'out', label: 'Check out', hidden: !(checkout && x.status === 'in_store') },
    { id: 'in', label: 'Check in', hidden: !(x.status === 'checked_out' && checkout) },
    { id: 'verify', label: 'Verify location', hidden: !(checkout && x.status === 'in_store') },
    { id: 'move', label: 'Move', hidden: !(manage && x.status === 'in_store') },
    { id: 'status', label: 'Repair / lost / retire', hidden: !(manage && x.status !== 'retired') },
  ];
  if (tabs.every((t) => t.hidden)) return x.status === 'retired' ? <Notice tone="info">Retired — kept for history only.</Notice> : null;
  const current = tabs.find((t) => t.id === tab && !t.hidden) ? tab : tabs.find((t) => !t.hidden)!.id;
  return (
    <Panel>
      <Tabs value={current} onChange={setTab} tabs={tabs} />
      {current === 'out' && (
        <div className="grid gap-3 sm:grid-cols-2">
          {x.condition === 'damaged' && <Notice tone="bad" className="sm:col-span-2">Damaged — send for repair before issuing.</Notice>}
          <Field label="Employee"><Select value={f.holder} onChange={(e) => setF({ ...f, holder: e.target.value })}><option value="">— choose —</option>{meId && <option value={meId}>Me</option>}{users.rows.map((u) => <option key={u.id} value={u.id}>{u.full_name}{u.employee_number ? ` (${u.employee_number})` : ''}</option>)}</Select></Field>
          <Field label="…or name (contractor / visitor)"><Input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} disabled={!!f.holder} /></Field>
          <Field label="Job / reference"><Input value={f.job} onChange={(e) => setF({ ...f, job: e.target.value })} placeholder="e.g. JOB-7781" /></Field>
          <Field label="Due back" required><Input type="date" value={f.due} min={plusDays(0)} onChange={(e) => setF({ ...f, due: e.target.value })} /></Field>
          <Field label="Notes" className="sm:col-span-2"><Input value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
          <div className="sm:col-span-2"><TxnOutcome state={out.state} onRetry={out.retry} savedText={() => 'Checked out.'} />
            <Button className="mt-2" variant="primary" size="lg" disabled={(!f.holder && !f.name.trim()) || !f.due || x.condition === 'damaged'} busy={out.state.phase === 'saving'}
              onClick={async () => after(await out.run({ p_asset_id: x.id, p_holder_user_id: f.holder || null, p_holder_name: f.holder ? null : f.name.trim(), p_job_reference: f.job || null,
                p_due_back_at: new Date(f.due + 'T17:00:00+02:00').toISOString(), p_notes: f.notes || null }))}><ArrowUpFromLine className="size-5" />Check out</Button></div>
        </div>
      )}
      {current === 'in' && (
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Returned to" required><Select value={f.loc} onChange={(e) => setF({ ...f, loc: e.target.value })}><option value="">— choose —</option>{locs.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}</Select></Field>
          <Field label="Condition"><Select value={f.cond} onChange={(e) => setF({ ...f, cond: e.target.value })}><option value="good">Good</option><option value="fair">Fair</option><option value="damaged">Damaged</option></Select></Field>
          <Field label={f.cond === 'damaged' ? 'Describe the damage' : 'Notes'} required={f.cond === 'damaged'} className="sm:col-span-2"><Textarea rows={2} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
          <div className="sm:col-span-2"><TxnOutcome state={back.state} onRetry={back.retry} savedText={() => 'Returned.'} />
            <Button className="mt-2" variant="primary" size="lg" disabled={!f.loc || (f.cond === 'damaged' && !f.notes.trim())} busy={back.state.phase === 'saving'}
              onClick={async () => after(await back.run({ p_asset_id: x.id, p_location_id: f.loc, p_condition: f.cond, p_notes: f.notes || null }))}><ArrowDownToLine className="size-5" />Check in</Button></div>
        </div>
      )}
      {current === 'verify' && (
        <div className="space-y-3">
          <p className="text-sm text-steel-600">Asset audit: confirm where the item physically is right now.</p>
          <Field label="Found at"><Select value={f.loc} onChange={(e) => setF({ ...f, loc: e.target.value })}><option value="">— choose —</option>{locs.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}</Select></Field>
          <TxnOutcome state={verify.state} onRetry={verify.retry} savedText={(r) => (r.moved ? String(r.note) : 'Verified at its recorded location.')} />
          <Button variant="navy" disabled={!f.loc} busy={verify.state.phase === 'saving'} onClick={async () => after(await verify.run({ p_asset_id: x.id, p_location_id: f.loc }))}><ScanSearch className="size-4" />Confirm verified</Button>
        </div>
      )}
      {current === 'move' && (
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="To warehouse"><Select value={toWh} onChange={(e) => { setToWh(e.target.value); setF({ ...f, loc: '' }); }}><option value="">— choose —</option>{whs.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.warehouse_code} — {w.warehouse_name}</option>)}</Select></Field>
          <Field label="Location"><Select value={f.loc} onChange={(e) => setF({ ...f, loc: e.target.value })} disabled={!toWh}><option value="">— choose —</option>{toLocs.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}</Select></Field>
          <Field label="Notes" className="sm:col-span-2"><Input value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
          <div className="sm:col-span-2"><TxnOutcome state={move.state} onRetry={move.retry} savedText={() => 'Moved.'} />
            <Button className="mt-2" variant="navy" disabled={!f.loc} busy={move.state.phase === 'saving'} onClick={async () => after(await move.run({ p_asset_id: x.id, p_to_location_id: f.loc, p_notes: f.notes || null }))}>Move item</Button></div>
        </div>
      )}
      {current === 'status' && (
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="New status"><Select value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>
            {x.status === 'in_store' && <option value="in_repair">Send for repair</option>}
            {['in_repair', 'lost'].includes(x.status) && <option value="in_store">{x.status === 'lost' ? 'Found — back in store' : 'Back from repair'}</option>}
            {x.status !== 'lost' && <option value="lost">Lost</option>}
            {x.status !== 'checked_out' && <option value="retired">Retire (scrap / sold)</option>}
          </Select></Field>
          {f.status === 'in_store' && <Field label="Now stored at" required><Select value={f.loc} onChange={(e) => setF({ ...f, loc: e.target.value })}><option value="">— choose —</option>{locs.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}</Select></Field>}
          <Field label="Reason / details" required className="sm:col-span-2"><Textarea rows={2} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
          <div className="sm:col-span-2"><TxnOutcome state={status.state} onRetry={status.retry} savedText={() => 'Status updated.'} />
            <Button className="mt-2" variant={f.status === 'retired' || f.status === 'lost' ? 'danger' : 'navy'} disabled={!f.notes.trim() || (f.status === 'in_store' && !f.loc)} busy={status.state.phase === 'saving'}
              onClick={async () => after(await status.run({ p_asset_id: x.id, p_status: f.status, p_notes: f.notes.trim(), p_location_id: f.loc || null }))}>Save</Button></div>
        </div>
      )}
    </Panel>
  );
}
