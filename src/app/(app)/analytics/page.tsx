'use client';
import { Suspense, useMemo, useState } from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import { useApp } from '@/components/app-context';
import { Field, Input, PageHeader, Select, Spinner } from '@/components/ui';
import { Tabs } from '@/components/widgets';
import { useCompanies } from '@/hooks/use-ref-data';
import { useRows, useRpc } from '@/hooks/use-rows';
import { fmtDate } from '@/lib/format';
import { AgeingTab, ConsumptionTab, ForecastTab, MovementsTab, OverviewTab, PerformanceTab, ValuationTab, VelocityTab, type Filters } from './tabs';

const TABS = [
  { id: 'overview', label: 'Overview' }, { id: 'movements', label: 'Movement trends' }, { id: 'velocity', label: 'Fast, slow & dead' },
  { id: 'ageing', label: 'Stock ageing' }, { id: 'consumption', label: 'Consumption' }, { id: 'valuation', label: 'Valuation' },
  { id: 'forecast', label: 'Forecast & predictions' }, { id: 'performance', label: 'Performance' },
] as const;
type TabId = (typeof TABS)[number]['id'];

const iso = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Johannesburg' }).format(d);
const daysAgo = (n: number) => iso(new Date(Date.now() - n * 864e5));
const PRESETS = [30, 90, 180, 365] as const;

function AnalyticsInner() {
  const sp = useSearchParams();
  const router = useRouter();
  const path = usePathname();
  const { can, me } = useApp();
  const tab = (TABS.some((t) => t.id === sp.get('tab')) ? sp.get('tab') : 'overview') as TabId;
  const setTab = (t: TabId) => { const q = new URLSearchParams(sp.toString()); q.set('tab', t); router.replace(`${path}?${q.toString()}`, { scroll: false }); };
  const [preset, setPreset] = useState<string>('90');
  const [f, setF] = useState<Filters>({ from: daysAgo(89), to: daysAgo(0), wh: '', company: '', category: '', product: sp.get('product') ?? '' });
  const whs = useMemo(() => (me?.warehouses ?? []).filter((w) => w.perms.includes('reports.view')), [me]);
  const { data: companies } = useCompanies();
  const cats = useRows<{ id: string; name: string }>('cats', (sb) => sb.from('categories').select('id, name').order('name'));
  const pred = useRpc<{ run_date: string; finished_at: string | null; at_risk: number | null; error: string | null } | null>('predstat', 'analytics_prediction_status');

  if (!can('reports.view')) return <PageHeader title="Analytics" description="You do not have access to analytics. Ask your manager for reporting rights." />;
  const choose = (p: string) => {
    setPreset(p);
    if (p !== 'custom') setF({ ...f, from: daysAgo(Number(p) - 1), to: daysAgo(0) });
  };
  return (
    <>
      <PageHeader title="Analytics" description={<>Trends, ageing, consumption, valuation, forecasts and performance, read straight from the stock ledger. {can('cost.view') ? 'Values are in rand at weighted-average purchase cost.' : 'Rand values are hidden for your role; totals are shown as line counts.'}
        {pred.data && <span className="block text-xs">Stock-out prediction last ran {fmtDate(pred.data.run_date)}{pred.data.error ? ' — with an error (see System health)' : pred.data.at_risk != null ? ` · ${pred.data.at_risk} item(s) at risk` : ''}.</span>}</>} />

      {/* one filter row scopes every chart and table below */}
      <div className="mb-4 flex flex-wrap items-end gap-3 rounded-lg border border-steel-200 bg-white p-3">
        <Field label="Period" className="w-40">
          <Select value={preset} onChange={(e) => choose(e.target.value)}>
            {PRESETS.map((p) => <option key={p} value={String(p)}>Last {p} days</option>)}<option value="custom">Custom range</option>
          </Select>
        </Field>
        {preset === 'custom' && <>
          <Field label="From" className="w-40"><Input type="date" value={f.from} max={f.to} onChange={(e) => setF({ ...f, from: e.target.value })} /></Field>
          <Field label="To" className="w-40"><Input type="date" value={f.to} min={f.from} max={daysAgo(0)} onChange={(e) => setF({ ...f, to: e.target.value })} /></Field>
        </>}
        <Field label="Warehouse" className="w-56">
          <Select value={f.wh} onChange={(e) => setF({ ...f, wh: e.target.value })}>
            <option value="">All my warehouses ({whs.length})</option>{whs.map((w) => <option key={w.id} value={w.id}>{w.code} — {w.name}</option>)}
          </Select>
        </Field>
        <Field label="Owning company" className="w-48">
          <Select value={f.company} onChange={(e) => setF({ ...f, company: e.target.value })}><option value="">All</option>{companies.map((c) => <option key={c.id} value={c.id}>{c.code} — {c.name}</option>)}</Select>
        </Field>
        <Field label="Category" className="w-48">
          <Select value={f.category} onChange={(e) => setF({ ...f, category: e.target.value })}><option value="">All</option>{cats.rows.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>
        </Field>
        {f.product && <button type="button" className="mb-2 text-xs underline" onClick={() => setF({ ...f, product: '' })}>Clear product filter</button>}
      </div>

      <Tabs value={tab} onChange={setTab} tabs={[...TABS]} />
      {tab === 'overview' && <OverviewTab f={f} go={setTab} />}
      {tab === 'movements' && <MovementsTab f={f} />}
      {tab === 'velocity' && <VelocityTab f={f} onProduct={(id) => { setF({ ...f, product: id }); setTab('movements'); }} />}
      {tab === 'ageing' && <AgeingTab f={f} />}
      {tab === 'consumption' && <ConsumptionTab f={f} />}
      {tab === 'valuation' && <ValuationTab f={f} />}
      {tab === 'forecast' && <ForecastTab f={f} />}
      {tab === 'performance' && <PerformanceTab f={f} />}
    </>
  );
}

export default function AnalyticsPage() {
  return <Suspense fallback={<Spinner />}><AnalyticsInner /></Suspense>;
}
