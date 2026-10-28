'use client';
import Link from 'next/link';
import { Suspense, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { Check, CheckCheck } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, Notice, PageHeader, Panel, Select, Spinner, StatusBadge, Table, Td, Th } from '@/components/ui';
import { ActionResult, ExportButtons, LoadError, Tabs, useConfirm } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useRows, useRpc } from '@/hooks/use-rows';
import { fmtDateTime, fmtQty } from '@/lib/format';

type Alert = { id: string; alert_type: string; severity: string; title: string; message: string; qty: number | null; status: string; escalated: boolean; occurrences: number;
  first_raised_at: string; last_raised_at: string; ref_type: string | null; ref_id: string | null; resolution_note: string | null;
  products: { sku: string; description: string } | null; warehouses: { code: string; name: string } | null; companies: { code: string } | null; storage_locations: { code: string } | null };
type Low = { product_id: string; sku: string; description: string; uom: string; warehouse_code: string; branch_name: string; company_code: string; available: number; free_to_use: number; reserved: number; in_transit: number; min_qty: number; reorder_qty: number; stock_level: string };

const TYPE_LABEL: Record<string, string> = {
  low_stock: 'Low stock', out_of_stock: 'Out of stock', reorder: 'Reorder', transfer_overdue: 'Transfer delayed', stocktake_due: 'Stocktake reminder',
  stocktake_overdue: 'Stocktake overdue', stocktake_discrepancy: 'Stocktake discrepancy', unusual_withdrawal: 'Unusual withdrawal', approval_pending: 'Approval pending',
  integrity: 'Integrity', integrity_monitor: 'Monitoring', system: 'System',
  po_overdue: 'Purchase order overdue', asset_overdue: 'Tool / equipment overdue', approval_overdue: 'Approval overdue', stockout_risk: 'Likely to run out',
};
const AUTO_CLOSE = ['integrity', 'integrity_monitor', 'low_stock', 'out_of_stock', 'approval_pending', 'approval_overdue', 'stockout_risk'];

function link(a: Alert) {
  if (a.ref_type === 'transfer' && a.ref_id) return `/transfers/${a.ref_id}`;
  if (a.ref_type === 'stocktake' && a.ref_id) return `/stocktake/${a.ref_id}`;
  if (a.ref_type === 'txn' && a.ref_id) return `/transactions/${a.ref_id}`;
  if (a.ref_type === 'finding' && a.ref_id) return `/integrity/${a.ref_id}`;
  if (a.alert_type.startsWith('integrity')) return '/integrity';
  if (a.ref_type === 'purchase_order' && a.ref_id) return `/purchasing/${a.ref_id}`;
  if (a.ref_type === 'asset' && a.ref_id) return `/assets/${a.ref_id}`;
  if (a.ref_type === 'forecast') return '/analytics?tab=forecast';
  if (a.alert_type === 'approval_pending' || a.ref_type === 'approval') return '/approvals';
  return null;
}

function AlertsInner() {
  const sp = useSearchParams();
  const { me, refresh } = useApp();
  const [tab, setTab] = useState<'alerts' | 'low' | 'notifications' | 'closed' | 'prefs'>((sp.get('tab') as 'notifications') || 'alerts');
  const [type, setType] = useState('');
  const sel = 'id, alert_type, severity, title, message, qty, status, escalated, occurrences, first_raised_at, last_raised_at, ref_type, ref_id, resolution_note, products(sku, description), warehouses(code, name), companies(code), storage_locations(code)';
  const alerts = useRows<Alert>(tab === 'alerts' || tab === 'closed' ? `a|${tab}|${type}` : null, (sb) => {
    let q = sb.from('alerts').select(sel).order('last_raised_at', { ascending: false }).limit(500);
    q = tab === 'closed' ? q.eq('status', 'resolved') : q.neq('status', 'resolved');
    if (type) q = q.eq('alert_type', type);
    return q;
  });
  const low = useRows<Low>(tab === 'low' ? 'low' : null, (sb) => sb.from('v_stock_by_warehouse').select('*').in('stock_level', ['low', 'out']).order('stock_level').order('sku').limit(1000));
  const notes = useRows<{ id: string; title: string; body: string; link: string | null; created_at: string; read_at: string | null }>(tab === 'notifications' ? 'n' : null,
    (sb) => sb.from('notifications').select('*').eq('user_id', me?.user?.id ?? '').order('created_at', { ascending: false }).limit(200));
  const act = useAction();
  const confirm = useConfirm();
  const sevOrder = (s: string) => (s === 'critical' ? 0 : s === 'warning' ? 1 : 2);

  return (
    <>
      {confirm.node}
      <PageHeader title="Low stock & alerts" description="Each unresolved condition raises one alert — repeats increase its count instead of sending duplicate notifications." />
      <Tabs value={tab} onChange={setTab} tabs={[{ id: 'alerts', label: 'Open alerts' }, { id: 'low', label: 'Low & out of stock' }, { id: 'notifications', label: `My notifications${me?.unread_notifications ? ` (${me.unread_notifications})` : ''}` }, { id: 'closed', label: 'Resolved' }, { id: 'prefs', label: 'Notification settings' }]} />
      {tab === 'prefs' && <Preferences />}
      <ActionResult error={act.error} ok={act.ok} />
      {(tab === 'alerts' || tab === 'closed') && (
        <>
          <div className="mb-3 flex flex-wrap justify-between gap-2">
            <Select value={type} onChange={(e) => setType(e.target.value)} className="w-56" aria-label="Alert type"><option value="">All alert types</option>{Object.entries(TYPE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>
            <ExportButtons title="Alerts" rows={alerts.rows} cols={[
              { key: 'severity', label: 'Severity' }, { key: 'alert_type', label: 'Type', get: (a) => TYPE_LABEL[a.alert_type] ?? a.alert_type }, { key: 'title', label: 'Title' },
              { key: 'sku', label: 'SKU', get: (a) => a.products?.sku }, { key: 'company', label: 'Company', get: (a) => a.companies?.code }, { key: 'warehouse', label: 'Warehouse', get: (a) => a.warehouses?.code },
              { key: 'location', label: 'Location', get: (a) => a.storage_locations?.code }, { key: 'qty', label: 'Quantity', num: true }, { key: 'status', label: 'Status' },
              { key: 'occurrences', label: 'Occurrences', num: true }, { key: 'last_raised_at', label: 'Last raised', get: (a) => fmtDateTime(a.last_raised_at) }]} />
          </div>
          <LoadError error={alerts.error} />
          {alerts.loading ? <Spinner /> : (
            <Table>
              <thead><tr><Th>Severity</Th><Th>Alert</Th><Th>Product / SKU</Th><Th>Company / location</Th><Th right>Qty</Th><Th>Status</Th><Th>Raised</Th><Th /></tr></thead>
              <tbody>{[...alerts.rows].sort((a, b) => sevOrder(a.severity) - sevOrder(b.severity)).map((a) => {
                const href = link(a);
                return (
                  <tr key={a.id}>
                    <Td><Badge tone={a.severity === 'critical' ? 'bad' : a.severity === 'warning' ? 'warn' : 'info'}>{a.severity}</Badge>{a.escalated && <div className="mt-1 text-xs text-bad-600">escalated</div>}</Td>
                    <Td><div className="text-xs text-steel-600">{TYPE_LABEL[a.alert_type] ?? a.alert_type}</div>{href ? <Link className="font-medium text-navy-900 hover:underline" href={href}>{a.title}</Link> : <span className="font-medium text-navy-900">{a.title}</span>}<div className="text-xs text-steel-800">{a.message}</div></Td>
                    <Td>{a.products ? <><span className="font-mono text-[13px]">{a.products.sku}</span><div className="text-xs">{a.products.description}</div></> : '—'}</Td>
                    <Td>{a.companies?.code ?? '—'}{a.warehouses && ` / ${a.warehouses.code}`}{a.storage_locations && <span className="font-mono text-[12px]"> / {a.storage_locations.code}</span>}</Td>
                    <Td right>{fmtQty(a.qty)}</Td>
                    <Td><StatusBadge status={a.status} />{a.resolution_note && <div className="text-xs text-steel-600">{a.resolution_note}</div>}</Td>
                    <Td className="text-xs">{fmtDateTime(a.last_raised_at)}{a.occurrences > 1 && <div className="text-steel-600">{a.occurrences}× since {fmtDateTime(a.first_raised_at)}</div>}</Td>
                    <Td className="whitespace-nowrap">{a.status === 'open' && <Button size="sm" onClick={async () => { if (await act.run('acknowledge_alert', { p_alert_id: a.id }, 'Acknowledged.')) alerts.reload(); }}><Check className="size-4" />Acknowledge</Button>}
                      {a.status !== 'resolved' && !AUTO_CLOSE.includes(a.alert_type) && <Button size="sm" variant="ghost" onClick={async () => {
                        const c = await confirm.ask({ title: 'Resolve alert', body: a.title, noteLabel: 'What was done?', noteRequired: true });
                        if (c && await act.run('resolve_alert', { p_alert_id: a.id, p_note: c.note }, 'Resolved.')) alerts.reload();
                      }}>Resolve</Button>}</Td>
                  </tr>
                );
              })}
                {alerts.rows.length === 0 && <tr><Td className="text-steel-600">No alerts.</Td></tr>}</tbody>
            </Table>
          )}
        </>
      )}
      {tab === 'low' && (
        <>
          <div className="mb-3 flex justify-end"><ExportButtons title="Low stock report" rows={low.rows} cols={[
            { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'company_code', label: 'Company' }, { key: 'warehouse_code', label: 'Warehouse' },
            { key: 'uom', label: 'Unit' }, { key: 'free_to_use', label: 'Free', num: true }, { key: 'in_transit', label: 'In transit', num: true }, { key: 'min_qty', label: 'Minimum', num: true },
            { key: 'reorder_qty', label: 'Reorder qty', num: true }, { key: 'suggested', label: 'Suggested order', num: true, get: (r) => Math.max(Number(r.reorder_qty) || 0, Number(r.min_qty) - Number(r.free_to_use)) },
            { key: 'stock_level', label: 'Level' }]} /></div>
          <LoadError error={low.error} />
          {low.loading ? <Spinner /> : (
            <Table>
              <thead><tr><Th>Product</Th><Th>Company / warehouse</Th><Th right>Free to use</Th><Th right>Minimum</Th><Th right>Reorder recommendation</Th><Th>Level</Th></tr></thead>
              <tbody>{low.rows.map((r) => (
                <tr key={r.product_id + r.warehouse_code}><Td><Link className="hover:underline" href={`/stock/${r.product_id}`}><span className="font-mono text-[13px]">{r.sku}</span> {r.description}</Link></Td>
                  <Td>{r.company_code} / <b>{r.warehouse_code}</b><div className="text-xs text-steel-600">{r.branch_name}</div></Td>
                  <Td right className="font-semibold">{fmtQty(r.free_to_use)} {r.uom}</Td><Td right>{fmtQty(r.min_qty)}</Td>
                  <Td right>{fmtQty(Math.max(Number(r.reorder_qty) || 0, Number(r.min_qty) - Number(r.free_to_use)))} {r.uom}</Td>
                  <Td><Badge tone={r.stock_level === 'out' ? 'bad' : 'warn'}>{r.stock_level === 'out' ? 'Out of stock' : 'Low'}</Badge></Td></tr>
              ))}
                {low.rows.length === 0 && <tr><Td className="text-steel-600">Everything is above its minimum.</Td></tr>}</tbody>
            </Table>
          )}
        </>
      )}
      {tab === 'notifications' && (
        <>
          <div className="mb-3 flex justify-end"><Button size="sm" onClick={async () => { if (await act.run('mark_notifications_read', { p_ids: null })) { notes.reload(); refresh(); } }}><CheckCheck className="size-4" />Mark all read</Button></div>
          {notes.loading ? <Spinner /> : (
            <ul className="divide-y divide-steel-100 rounded-lg border border-steel-200 bg-white">
              {notes.rows.map((n) => (
                <li key={n.id} className={n.read_at ? 'px-4 py-3' : 'bg-signal-50 px-4 py-3'}>
                  <div className="flex justify-between gap-3"><span className="font-medium text-navy-900">{n.link ? <Link href={n.link} className="hover:underline" onClick={() => callRead(n.id, act.run)}>{n.title}</Link> : n.title}</span><span className="text-xs text-steel-600">{fmtDateTime(n.created_at)}</span></div>
                  <p className="mt-1 whitespace-pre-line text-sm text-steel-800">{n.body}</p>
                </li>
              ))}
              {notes.rows.length === 0 && <li className="px-4 py-3 text-sm text-steel-600">No notifications.</li>}
            </ul>
          )}
        </>
      )}
    </>
  );
}

function callRead(id: string, run: ReturnType<typeof useAction>['run']) { run('mark_notifications_read', { p_ids: [id] }); }

type Prefs = { email_enabled: boolean; email_min_severity: string; muted_types: string[]; daily_digest: boolean; email_system_enabled: boolean };
const MUTABLE = ['low_stock', 'out_of_stock', 'reorder', 'transfer_overdue', 'stocktake_due', 'stocktake_overdue', 'stocktake_discrepancy', 'unusual_withdrawal',
  'approval_pending', 'approval_overdue', 'po_overdue', 'asset_overdue', 'stockout_risk'];

/** Per-person notification preferences. Integrity and critical alerts are always delivered. */
function Preferences() {
  const p = useRpc<Prefs>('prefs', 'my_notification_preferences');
  const act = useAction();
  const [d, setD] = useState<Prefs | null>(null);
  const v = d ?? p.data;
  if (p.loading || !v) return <><LoadError error={p.error} /><Spinner /></>;
  const muted = new Set(v.muted_types ?? []);
  return (
    <Panel title="How I am notified" className="max-w-3xl">
      {!v.email_system_enabled && <Notice tone="warn" className="mb-4">E-mail is switched off for the whole system (System administration → Settings → alerts.email_enabled). In-app notifications still work.</Notice>}
      <div className="space-y-4 text-sm">
        <label className="flex items-center gap-2"><input type="checkbox" checked={v.email_enabled} onChange={(e) => setD({ ...v, email_enabled: e.target.checked })} />Send me alert e-mails</label>
        <label className="flex items-center gap-2">Only e-mail alerts that are at least
          <Select className="w-36" value={v.email_min_severity} disabled={!v.email_enabled} onChange={(e) => setD({ ...v, email_min_severity: e.target.value })}>
            <option value="info">Information</option><option value="warning">Warning</option><option value="critical">Critical</option></Select></label>
        <label className="flex items-center gap-2"><input type="checkbox" checked={v.daily_digest} onChange={(e) => setD({ ...v, daily_digest: e.target.checked })} />Send me a daily summary e-mail each morning (open alerts, approvals waiting, overdue orders and tools)</label>
        <div>
          <div className="mb-2 font-medium">Mute these alert types (no notification or e-mail; critical ones still come through)</div>
          <div className="grid gap-1 sm:grid-cols-2">{MUTABLE.map((t) => (
            <label key={t} className="flex items-center gap-2"><input type="checkbox" checked={muted.has(t)} onChange={(e) => {
              const n = new Set(muted); if (e.target.checked) n.add(t); else n.delete(t); setD({ ...v, muted_types: [...n] });
            }} />{TYPE_LABEL[t] ?? t}</label>))}</div>
          <p className="mt-2 text-xs text-steel-600">Stock integrity and monitoring alerts cannot be muted.</p>
        </div>
        <ActionResult error={act.error} ok={act.ok} />
        <Button variant="primary" disabled={!d} busy={act.busy} onClick={async () => {
          if (await act.run('set_notification_preferences', { p_email_enabled: v.email_enabled, p_email_min_severity: v.email_min_severity,
            p_muted_types: v.muted_types?.length ? v.muted_types : null, p_daily_digest: v.daily_digest }, 'Preferences saved.')) { setD(null); p.reload(); }
        }}>Save preferences</Button>
      </div>
    </Panel>
  );
}

export default function AlertsPage() {
  return <Suspense fallback={<Spinner />}><AlertsInner /></Suspense>;
}
