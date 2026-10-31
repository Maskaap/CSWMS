'use client';
import Link from 'next/link';
import { useMemo, useState } from 'react';
import { CalendarPlus, RefreshCcw } from 'lucide-react';
import { callRpc } from '@/hooks/use-transaction';
import { Notice } from '@/components/ui';
import { useApp } from '@/components/app-context';
import { Badge, Button, Field, Input, PageHeader, Panel, Select, Spinner, Stat, StatusBadge, Table, Td, Th } from '@/components/ui';
import { ActionResult, ExportButtons, LoadError, Tabs } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useAllWarehouses, useCompanies } from '@/hooks/use-ref-data';
import { useRows } from '@/hooks/use-rows';
import { currentPeriod, fmtDate, fmtDateTime, todayISO } from '@/lib/format';

type St = {
  id: string; stocktake_no: string; name: string; period: string; status: string; blind: boolean; due_date: string; cutoff_at: string | null; finalised_at: string | null;
  warehouse_id: string; warehouse_code: string; warehouse_name: string; branch_code: string; branch_name: string; company_code: string; province_name: string;
  is_overdue: boolean; lines: number; counted: number; discrepancies: number; missing: number; additional: number; not_counted: number; recounts: number; pct_counted: number;
};

export default function StocktakePage() {
  const { can, me } = useApp();
  const [period, setPeriod] = useState(currentPeriod());
  const [tab, setTab] = useState<'period' | 'mine' | 'history'>('period');
  const manage = can('stocktake.manage') || can('stocktake.approve');
  const list = useRows<St>(`st|${tab}|${period}`, (sb) => {
    let q = sb.from('v_stocktake_summary').select('*').order('period', { ascending: false }).order('warehouse_code').limit(500);
    if (tab === 'period') q = q.eq('period', period);
    if (tab === 'mine') q = q.in('status', ['counting', 'review']);
    return q;
  });
  const mine = useRows<{ stocktake_id: string }>(tab === 'mine' ? 'mine' : null, (sb) => sb.from('stocktake_assignments').select('stocktake_id').eq('user_id', me?.user?.id ?? ''));
  const rows = tab === 'mine' ? list.rows.filter((r) => mine.rows.some((m) => m.stocktake_id === r.id)) : list.rows;

  const stats = useMemo(() => {
    const r = list.rows.filter((x) => x.status !== 'cancelled');
    return {
      total: r.length, done: r.filter((x) => x.status === 'finalised').length, outstanding: r.filter((x) => x.status !== 'finalised').length,
      pct: r.length ? Math.round(r.reduce((s, x) => s + Number(x.pct_counted || 0), 0) / r.length) : 0,
      disc: r.reduce((s, x) => s + Number(x.discrepancies || 0), 0), missing: r.reduce((s, x) => s + Number(x.missing || 0), 0),
      extra: r.reduce((s, x) => s + Number(x.additional || 0), 0), pending: r.filter((x) => x.status === 'pending_approval').length, overdue: r.filter((x) => x.is_overdue).length,
    };
  }, [list.rows]);

  return (
    <>
      <PageHeader title="Monthly stocktake" description="Physical counts per warehouse, compared against the system at a fixed cut-off, with recounts and management approval before any adjustment is posted."
        actions={<ExportButtons title={`Stocktakes ${period}`} rows={rows} cols={[
          { key: 'stocktake_no', label: 'Stocktake' }, { key: 'period', label: 'Period' }, { key: 'warehouse_code', label: 'Warehouse' }, { key: 'branch_name', label: 'Branch' },
          { key: 'company_code', label: 'Company' }, { key: 'province_name', label: 'Province' }, { key: 'status', label: 'Status' }, { key: 'due_date', label: 'Due', get: (r) => fmtDate(r.due_date) },
          { key: 'lines', label: 'Lines', num: true }, { key: 'pct_counted', label: '% counted', num: true }, { key: 'discrepancies', label: 'Discrepancies', num: true },
          { key: 'missing', label: 'Missing', num: true }, { key: 'additional', label: 'Additional', num: true }, { key: 'not_counted', label: 'Not counted', num: true },
          { key: 'is_overdue', label: 'Overdue', get: (r) => (r.is_overdue ? 'Yes' : '') }]} />} />
      <Tabs value={tab} onChange={setTab} tabs={[{ id: 'period', label: 'Monthly overview' }, { id: 'mine', label: 'My counting tasks' }, { id: 'history', label: 'History' }]} />

      {tab === 'period' && (
        <>
          <div className="mb-4 flex items-end gap-3">
            <Field label="Period"><Input type="month" value={period} onChange={(e) => setPeriod(e.target.value)} className="w-44" /></Field>
          </div>
          <div className="mb-6 grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-8">
            <Stat label="Completed" value={`${stats.done}/${stats.total}`} tone={stats.total && stats.done === stats.total ? 'ok' : undefined} />
            <Stat label="Outstanding" value={stats.outstanding} tone={stats.outstanding ? 'warn' : undefined} />
            <Stat label="Avg. % counted" value={`${stats.pct}%`} />
            <Stat label="Discrepancies" value={stats.disc} tone={stats.disc ? 'warn' : undefined} />
            <Stat label="Missing lines" value={stats.missing} tone={stats.missing ? 'bad' : undefined} />
            <Stat label="Additional lines" value={stats.extra} />
            <Stat label="Pending approval" value={stats.pending} tone={stats.pending ? 'warn' : undefined} href="/approvals" />
            <Stat label="Overdue" value={stats.overdue} tone={stats.overdue ? 'bad' : undefined} />
          </div>
          {can('stocktake.manage') && <ScheduleForm period={period} onDone={list.reload} />}
          {can('stocktake.manage') && <CycleCountForm onDone={list.reload} />}
        </>
      )}

      <LoadError error={list.error} />
      {list.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>Stocktake</Th><Th>Warehouse</Th><Th>Status</Th><Th>Due</Th><Th right>Counted</Th><Th right>Discrepancies</Th><Th right>Missing / extra</Th><Th>Cut-off</Th></tr></thead>
          <tbody>
            {rows.map((s) => (
              <tr key={s.id} className="hover:bg-steel-50">
                <Td><Link href={`/stocktake/${s.id}`} className="font-mono text-[13px] font-semibold hover:underline">{s.stocktake_no}</Link><div className="text-xs text-steel-600">{s.period}{s.blind ? ' · blind' : ''}</div></Td>
                <Td><b>{s.warehouse_code}</b> {s.warehouse_name}<div className="text-xs text-steel-600">{s.branch_name} · {s.company_code} · {s.province_name}</div></Td>
                <Td><StatusBadge status={s.status} />{s.is_overdue && <Badge tone="bad" className="ml-1">overdue</Badge>}</Td>
                <Td>{fmtDate(s.due_date)}</Td>
                <Td right>{s.counted}/{s.lines} <span className="text-xs text-steel-600">({Math.round(Number(s.pct_counted || 0))}%)</span></Td>
                <Td right>{s.discrepancies || '—'}</Td><Td right>{s.missing || 0} / {s.additional || 0}</Td>
                <Td className="text-xs">{fmtDateTime(s.cutoff_at)}</Td>
              </tr>
            ))}
            {rows.length === 0 && <tr><Td className="text-steel-600">{tab === 'mine' ? 'No open counting tasks are assigned to you.' : 'No stocktakes for this view.'}</Td></tr>}
          </tbody>
        </Table>
      )}
    </>
  );
}

function ScheduleForm({ period, onDone }: { period: string; onDone: () => void }) {
  const { me } = useApp();
  const { data: whs } = useAllWarehouses();
  const { data: companies } = useCompanies();
  const cats = useRows<{ id: string; name: string; parent_id: string | null }>('cats', (sb) => sb.from('categories').select('id, name, parent_id').eq('status', 'active').order('name'));
  const act = useAction();
  const [open, setOpen] = useState(false);
  const [scope, setScope] = useState<'warehouse' | 'branch' | 'company' | 'group'>('warehouse');
  const [scopeId, setScopeId] = useState('');
  const [due, setDue] = useState(() => { const d = new Date(); d.setDate(d.getDate() + 7); return d.toISOString().slice(0, 10); });
  const [blind, setBlind] = useState(true);
  const [cat, setCat] = useState('');
  const [name, setName] = useState('');
  const branches = useMemo(() => [...new Map(whs.map((w) => [w.branch_id, { id: w.branch_id, label: `${w.branch_code} — ${w.branch_name} (${w.province_name})` }])).values()], [whs]);
  const canGroup = !!me?.group_permissions?.includes('stocktake.manage');

  if (!open) return <div className="mb-4"><Button variant="primary" onClick={() => setOpen(true)}><CalendarPlus className="size-4" />Schedule stocktakes for {period}</Button></div>;
  return (
    <Panel title={`Schedule stocktakes — ${period}`} className="mb-6">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <Field label="Scope">
          <Select value={scope} onChange={(e) => { setScope(e.target.value as typeof scope); setScopeId(''); }}>
            <option value="warehouse">One warehouse</option><option value="branch">Every warehouse in a branch</option>
            <option value="company">Every warehouse of a company</option>{canGroup && <option value="group">Entire group</option>}
          </Select>
        </Field>
        {scope !== 'group' && (
          <Field label={scope === 'warehouse' ? 'Warehouse' : scope === 'branch' ? 'Branch' : 'Company'} required>
            <Select value={scopeId} onChange={(e) => setScopeId(e.target.value)}>
              <option value="">— choose —</option>
              {scope === 'warehouse' && whs.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.warehouse_code} — {w.warehouse_name}</option>)}
              {scope === 'branch' && branches.map((b) => <option key={b.id} value={b.id}>{b.label}</option>)}
              {scope === 'company' && companies.map((c) => <option key={c.id} value={c.id}>{c.code} — {c.name}</option>)}
            </Select>
          </Field>
        )}
        <Field label="Due date" required><Input type="date" value={due} min={todayISO()} onChange={(e) => setDue(e.target.value)} /></Field>
        <Field label="Limit to category (optional)">
          <Select value={cat} onChange={(e) => setCat(e.target.value)}><option value="">All categories</option>{cats.rows.map((c) => <option key={c.id} value={c.id}>{c.parent_id ? '— ' : ''}{c.name}</option>)}</Select>
        </Field>
        <Field label="Name (optional)"><Input value={name} onChange={(e) => setName(e.target.value)} placeholder={`Monthly stocktake ${period}`} /></Field>
        <label className="mt-6 flex items-center gap-2 text-sm"><input type="checkbox" checked={blind} onChange={(e) => setBlind(e.target.checked)} />Blind count (counters cannot see expected quantities)</label>
      </div>
      <div className="mt-3"><ActionResult error={act.error} ok={act.ok} /></div>
      <div className="mt-3 flex gap-2">
        <Button onClick={() => setOpen(false)}>Close</Button>
        <Button variant="navy" busy={act.busy} disabled={scope !== 'group' && !scopeId}
          onClick={async () => {
            const r = await act.run<{ created?: number; stocktake_ids?: string[] }>('schedule_stocktakes', { p_scope_type: scope, p_scope_id: scope === 'group' ? null : scopeId, p_period: period, p_due_date: due,
              p_blind: blind, p_category_ids: cat ? [cat] : null, p_name: name.trim() || null });
            if (r) { act.setOk(`Scheduled ${r.created ?? r.stocktake_ids?.length ?? ''} stocktake(s).`); onDone(); }
          }}>Schedule</Button>
      </div>
    </Panel>
  );
}

/** Cycle counting: a short, blind count of the items that matter most, picked by A/B/C class. */
function CycleCountForm({ onDone }: { onDone: () => void }) {
  const { warehouses, warehouseId, can } = useApp();
  const mine = warehouses.filter((w) => can('stocktake.manage', w.id));
  const [wh, setWh] = useState(mine.find((w) => w.id === warehouseId)?.id ?? mine[0]?.id ?? '');
  const [items, setItems] = useState('15');
  const [busy, setBusy] = useState(false);
  const [res, setRes] = useState<{ tone: 'ok' | 'bad' | 'info'; text: React.ReactNode } | null>(null);
  if (!mine.length) return null;
  const go = async () => {
    setBusy(true); setRes(null);
    const { data, error } = await callRpc<{ created: boolean; stocktake_id?: string; stocktake_no?: string; items?: number; message?: string }>(
      'create_cycle_count', { p_warehouse_id: wh, p_items: Number(items) || null });
    setBusy(false);
    if (error) { setRes({ tone: 'bad', text: error.message }); return; }
    if (!data?.created) { setRes({ tone: 'info', text: data?.message ?? 'Nothing is due.' }); return; }
    setRes({ tone: 'ok', text: <>Created <Link className="underline" href={`/stocktake/${data.stocktake_id}`}>{data.stocktake_no}</Link> with {data.items} items — counting has started and the counters were told.</> });
    onDone();
  };
  return (
    <Panel className="mb-6" title={<span className="flex items-center gap-2"><RefreshCcw className="size-4" />Cycle count (a few items, every working day)</span>}>
      <p className="mb-3 text-sm text-steel-600">Instead of one big count a month, count a handful of items daily. Fast movers and high-value items (class A) are counted every 30 days,
        B every 60, C every 120 (System Administration → stocktake settings). Switch on the automatic daily cycle count with the setting <b>cycle.items_per_day</b>.</p>
      <div className="flex flex-wrap items-end gap-3">
        <Field label="Cycle-count warehouse"><Select value={wh} onChange={(e) => setWh(e.target.value)} className="w-64">{mine.map((w) => <option key={w.id} value={w.id}>{w.code} — {w.name}</option>)}</Select></Field>
        <Field label="Items"><Input type="number" min={1} max={500} value={items} onChange={(e) => setItems(e.target.value)} className="w-24" /></Field>
        <Button variant="navy" busy={busy} onClick={go} disabled={!wh}><RefreshCcw className="size-4" />Create cycle count now</Button>
      </div>
      {res && <Notice tone={res.tone} className="mt-3">{res.text}</Notice>}
    </Panel>
  );
}
