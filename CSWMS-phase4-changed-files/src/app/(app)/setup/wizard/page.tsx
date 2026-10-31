'use client';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { ArrowDown, ArrowUp, Building2, CheckCircle2, Circle, FileUp, GraduationCap, LayoutGrid, Package, Printer, Route, Users, BellRing } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Button, Field, Input, Notice, PageHeader, Panel, Select, Spinner, cx } from '@/components/ui';
import { useRows } from '@/hooks/use-rows';
import { callRpc } from '@/hooks/use-transaction';

type Loc = { id: string; code: string; name: string; walk_order: number | null; status: string; kind: string };

/**
 * First-time setup in order, with the status of each step. The heavy lifting stays on the
 * existing screens; this page adds the bin generator, the counting route and the training warehouse.
 */
export default function SetupWizardPage() {
  const { can, refresh } = useApp();
  const n = (table: string) => useRows<{ id: string }>('wz-' + table, (sb) => sb.from(table).select('id', { count: 'exact', head: true }));
  const companies = n('companies'); const branches = n('branches'); const warehouses = n('warehouses');
  const locations = n('storage_locations'); const products = n('products'); const users = n('app_users');
  const whs = useRows<{ id: string; code: string; name: string; is_training: boolean; branch_id: string }>('wz-wh', (sb) => sb.from('warehouses').select('id, code, name, is_training, branch_id').eq('status', 'active').order('code'));
  const brs = useRows<{ id: string; code: string; name: string }>('wz-br', (sb) => sb.from('branches').select('id, code, name').eq('status', 'active').order('code'));
  const opening = useRows<{ id: string }>('wz-open', (sb) => sb.from('stock_transactions').select('id', { count: 'exact', head: true }).eq('txn_type', 'opening'));

  if (!can('setup.manage')) return <Notice tone="bad">Only setup managers can use the setup guide.</Notice>;
  if (companies.loading) return <Spinner />;
  const real = whs.rows.filter((w) => !w.is_training);
  const steps: { done: boolean; icon: typeof Building2; title: string; body: React.ReactNode }[] = [
    { done: (companies.count ?? 0) > 0 && (branches.count ?? 0) > 0 && real.length > 0, icon: Building2, title: '1. Companies, branches and warehouses',
      body: <>You have <b>{companies.count ?? 0}</b> companies, <b>{branches.count ?? 0}</b> branches and <b>{real.length}</b> warehouses. Each company owns its own stock; a branch is a physical site.
        <div className="mt-2"><Link href="/setup?tab=companies"><Button size="sm">Open company setup</Button></Link></div></> },
    { done: (locations.count ?? 0) > real.length, icon: LayoutGrid, title: '2. Bins and the counting route',
      body: <BinTools warehouses={real} onChanged={locations.reload} /> },
    { done: (products.count ?? 0) > 0, icon: Package, title: '3. Products',
      body: <>{products.count ?? 0} products. Add them one by one or let the opening-stock import create them from your spreadsheet.
        <div className="mt-2 flex gap-2"><Link href="/setup/products"><Button size="sm">Products</Button></Link></div></> },
    { done: (opening.count ?? 0) > 0, icon: FileUp, title: '4. Opening stock',
      body: <>Load what is on the shelves today from Excel or CSV. A second manager approves it before it counts.
        <div className="mt-2"><Link href="/setup/import"><Button size="sm" variant="primary">Opening stock import</Button></Link></div></> },
    { done: false, icon: Printer, title: '5. Labels', body: <>Print bin labels (the counting screen jumps to a bin when its label is scanned) and product labels for items without a barcode.
        <div className="mt-2"><Link href="/setup/labels"><Button size="sm">Print labels</Button></Link></div></> },
    { done: (users.count ?? 0) > 1, icon: Users, title: '6. People and roles', body: <>{users.count ?? 0} people. Give each person only the role they need, per warehouse.
        <div className="mt-2"><Link href="/users"><Button size="sm">Users &amp; permissions</Button></Link></div></> },
    { done: whs.rows.some((w) => w.is_training), icon: GraduationCap, title: '7. Practice first (training warehouse)',
      body: <TrainingTools branches={brs.rows} existing={whs.rows.filter((w) => w.is_training)} onDone={() => { whs.reload(); void refresh(); }} /> },
    { done: false, icon: BellRing, title: '8. Alerts, WhatsApp and cycle counts',
      body: <>Switch on alert e-mails, WhatsApp and the automatic daily cycle count (<b>cycle.items_per_day</b>) under System Administration → Settings. Each person chooses language, text size and WhatsApp under <Link className="underline" href="/me">My settings</Link>.
        <div className="mt-2"><Link href="/admin"><Button size="sm">System administration</Button></Link></div></> },
  ];
  const doneCount = steps.filter((s) => s.done).length;

  return (
    <div className="mx-auto max-w-4xl">
      <PageHeader title="Setup guide" description={`Everything needed to start, in order. ${doneCount} of ${steps.length} steps look complete.`} />
      <ol className="space-y-4">
        {steps.map((s) => (
          <li key={s.title} className={cx('rounded-lg border bg-white p-5', s.done ? 'border-ok-600' : 'border-steel-200')}>
            <div className="mb-2 flex items-center gap-3">
              {s.done ? <CheckCircle2 className="size-6 text-ok-600" /> : <Circle className="size-6 text-steel-400" />}
              <s.icon className="size-5 text-navy-900" /><h2 className="text-lg font-semibold text-navy-900">{s.title}</h2>
            </div>
            <div className="pl-9 text-sm text-steel-800">{s.body}</div>
          </li>
        ))}
      </ol>
    </div>
  );
}

function BinTools({ warehouses, onChanged }: { warehouses: { id: string; code: string; name: string }[]; onChanged: () => void }) {
  const [wh, setWh] = useState(warehouses[0]?.id ?? '');
  const [prefix, setPrefix] = useState('A');
  const [aisles, setAisles] = useState('2'); const [bays, setBays] = useState('5'); const [levels, setLevels] = useState('1');
  const [msg, setMsg] = useState<{ tone: 'ok' | 'bad'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const locs = useRows<Loc>(wh ? 'wz-loc' + wh : null, (sb) => sb.from('storage_locations').select('id, code, name, walk_order, status, kind').eq('warehouse_id', wh).eq('status', 'active'));
  const [order, setOrder] = useState<Loc[]>([]);
  useEffect(() => {
    setOrder([...locs.rows].sort((a, b) => (a.walk_order ?? 1e9) - (b.walk_order ?? 1e9) || a.code.localeCompare(b.code)));
  }, [locs.rows]);
  useEffect(() => { if (!wh && warehouses[0]) setWh(warehouses[0].id); }, [warehouses, wh]);
  const total = (Number(aisles) || 0) * (Number(bays) || 0) * (Number(levels) || 1);

  const generate = async () => {
    setBusy(true); setMsg(null);
    const { data, error } = await callRpc<{ created: number; skipped_existing: number }>('generate_locations',
      { p_warehouse_id: wh, p_prefix: prefix, p_aisles: Number(aisles), p_bays: Number(bays), p_levels: Number(levels) || 1 });
    setBusy(false);
    if (error) { setMsg({ tone: 'bad', text: error.message }); return; }
    setMsg({ tone: 'ok', text: `${data?.created} bins created${data?.skipped_existing ? `, ${data.skipped_existing} already existed` : ''}. They are already in walking order.` });
    locs.reload(); onChanged();
  };
  const move = (i: number, d: -1 | 1) => setOrder((o) => { const c = [...o]; const j = i + d; if (j < 0 || j >= c.length) return o; [c[i], c[j]] = [c[j], c[i]]; return c; });
  const saveOrder = async () => {
    setBusy(true); setMsg(null);
    const { error } = await callRpc('set_walk_order', { p_warehouse_id: wh, p_location_ids: order.map((l) => l.id) });
    setBusy(false);
    setMsg(error ? { tone: 'bad', text: error.message } : { tone: 'ok', text: 'Counting route saved. Counters will be led through the bins in this order.' });
    if (!error) locs.reload();
  };
  if (!warehouses.length) return <>Add a warehouse first.</>;

  return (
    <div className="space-y-4">
      <Field label="Warehouse"><Select value={wh} onChange={(e) => setWh(e.target.value)} className="w-72">{warehouses.map((w) => <option key={w.id} value={w.id}>{w.code} — {w.name}</option>)}</Select></Field>
      <Panel title="Create many bins at once">
        <div className="flex flex-wrap items-end gap-3">
          <Field label="Prefix"><Input value={prefix} onChange={(e) => setPrefix(e.target.value.toUpperCase())} className="w-20" maxLength={10} /></Field>
          <Field label="Aisles"><Input type="number" min={1} max={50} value={aisles} onChange={(e) => setAisles(e.target.value)} className="w-20" /></Field>
          <Field label="Bays per aisle"><Input type="number" min={1} max={99} value={bays} onChange={(e) => setBays(e.target.value)} className="w-20" /></Field>
          <Field label="Levels"><Input type="number" min={1} max={9} value={levels} onChange={(e) => setLevels(e.target.value)} className="w-20" /></Field>
          <Button variant="navy" busy={busy} disabled={!wh || total < 1 || total > 2000} onClick={generate}><LayoutGrid className="size-4" />Create {total} bins</Button>
        </div>
        <p className="mt-2 text-xs text-steel-600">Example: {prefix || 'A'}1-01{Number(levels) > 1 ? '-1' : ''} … {prefix || 'A'}{aisles || 1}-{String(bays || 1).padStart(2, '0')}{Number(levels) > 1 ? `-${levels}` : ''}. The route snakes up one aisle and down the next.</p>
      </Panel>
      <Panel title={<span className="flex items-center gap-2"><Route className="size-4" />Counting route ({order.length} locations)</span>}
        actions={<Button size="sm" variant="primary" busy={busy} onClick={saveOrder} disabled={!order.length}>Save route</Button>}>
        {locs.loading ? <Spinner /> : (
          <ol className="max-h-80 space-y-1 overflow-y-auto">
            {order.map((l, i) => (
              <li key={l.id} className="flex items-center gap-2 rounded border border-steel-100 px-2 py-1">
                <span className="w-8 text-right font-mono text-xs text-steel-400">{i + 1}</span>
                <span className="font-mono text-sm">{l.code}</span><span className="flex-1 truncate text-xs text-steel-600">{l.name}</span>
                <button type="button" className="rounded p-1 hover:bg-steel-100" onClick={() => move(i, -1)} aria-label={`Move ${l.code} up`}><ArrowUp className="size-4" /></button>
                <button type="button" className="rounded p-1 hover:bg-steel-100" onClick={() => move(i, 1)} aria-label={`Move ${l.code} down`}><ArrowDown className="size-4" /></button>
              </li>
            ))}
          </ol>
        )}
      </Panel>
      {msg && <Notice tone={msg.tone}>{msg.text}</Notice>}
    </div>
  );
}

function TrainingTools({ branches, existing, onDone }: { branches: { id: string; code: string; name: string }[]; existing: { id: string; code: string }[]; onDone: () => void }) {
  const [br, setBr] = useState(branches[0]?.id ?? '');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: 'ok' | 'bad'; text: string } | null>(null);
  useEffect(() => { if (!br && branches[0]) setBr(branches[0].id); }, [branches, br]);
  const go = async () => {
    setBusy(true); setMsg(null);
    const { data, error } = await callRpc<{ code: string; items: number }>('create_training_warehouse', { p_branch_id: br });
    setBusy(false);
    if (error) { setMsg({ tone: 'bad', text: error.message }); return; }
    setMsg({ tone: 'ok', text: `${data?.code} created with 6 practice bins and ${data?.items} practice items. Give trainees a role on ${data?.code} only, and choose it in "Working in" to practise.` });
    onDone();
  };
  return (
    <div>
      <p>A separate warehouse with practice stock and a striped “training” banner. New staff can receive, issue, count and undo without touching real stock. It is a normal warehouse, so keep it out of real reports by filtering it out (code starts with TRAIN-).</p>
      {existing.length > 0 && <p className="mt-1">Existing: <b>{existing.map((w) => w.code).join(', ')}</b></p>}
      <div className="mt-2 flex flex-wrap items-end gap-3">
        <Field label="Branch"><Select value={br} onChange={(e) => setBr(e.target.value)} className="w-64">{branches.map((b) => <option key={b.id} value={b.id}>{b.code} — {b.name}</option>)}</Select></Field>
        <Button busy={busy} onClick={go} disabled={!br}><GraduationCap className="size-4" />Create training warehouse</Button>
      </div>
      {msg && <Notice tone={msg.tone} className="mt-2">{msg.text}</Notice>}
    </div>
  );
}
