'use client';
import { useMemo, useState } from 'react';
import { useApp } from '@/components/app-context';
import { MasterTable } from '@/components/master-table';
import { Badge, Button, Input, Notice, PageHeader, Panel, Select, Spinner, Table, Td, Th } from '@/components/ui';
import { ActionResult, ExportButtons, LoadError, Tabs } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useRows } from '@/hooks/use-rows';
import { supabaseBrowser } from '@/lib/supabase/client';
import { fmtDateTime } from '@/lib/format';

type Setting = { key: string; value: unknown; description: string; category: string; updated_at: string };

export default function AdminPage() {
  const { can, canGroup } = useApp();
  const [tab, setTab] = useState<'settings' | 'rules' | 'reasons' | 'events' | 'audit' | 'backup'>('settings');
  if (!can('settings.manage') && !can('integrity.admin') && !can('audit.view')) return <PageHeader title="System administration" description="Administrators only." />;
  return (
    <>
      <PageHeader title="System administration" description="Business settings, approval rules, reason codes, scheduled-job health, the permanent audit history and backup procedures." />
      <Tabs value={tab} onChange={setTab} tabs={[{ id: 'settings', label: 'Settings' }, { id: 'rules', label: 'Approval rules' }, { id: 'reasons', label: 'Reason codes', hidden: !canGroup('settings.manage') },
        { id: 'events', label: 'System health & jobs' }, { id: 'audit', label: 'Audit history', hidden: !can('audit.view') }, { id: 'backup', label: 'Backups & recovery' }]} />
      {tab === 'settings' && <Settings />}
      {tab === 'rules' && <ApprovalRules canEdit={canGroup('settings.manage')} />}
      {tab === 'reasons' && <Reasons />}
      {tab === 'events' && <Events />}
      {tab === 'audit' && <Audit />}
      {tab === 'backup' && <Backup />}
    </>
  );
}

function Settings() {
  const { refresh } = useApp();
  const s = useRows<Setting>('settings', (sb) => sb.from('app_settings').select('*').order('category').order('key'));
  const org = useRows<{ name: string; logo_url: string | null }>('org', (sb) => sb.from('organisation').select('*').maybeSingle());
  const act = useAction();
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [orgName, setOrgName] = useState<string | null>(null);
  const groups = useMemo(() => [...new Set(s.rows.map((r) => r.category))], [s.rows]);
  const asText = (v: unknown) => (typeof v === 'string' ? v : JSON.stringify(v));
  const parse = (old: unknown, txt: string): unknown => (typeof old === 'number' ? Number(txt.replace(',', '.')) : typeof old === 'boolean' ? txt === 'true' : typeof old === 'string' ? txt : JSON.parse(txt));
  return (
    <div className="space-y-6">
      <ActionResult error={act.error} ok={act.ok} />
      <Panel title="Organisation">
        <div className="flex items-end gap-2"><Input value={orgName ?? org.rows[0]?.name ?? ''} onChange={(e) => setOrgName(e.target.value)} className="max-w-md" aria-label="Organisation name" />
          <Button disabled={orgName === null} onClick={async () => { const { error } = await supabaseBrowser().from('organisation').update({ name: orgName }).eq('id', true); if (error) act.setError({ kind: 'unknown', message: error.message }); else { act.setOk('Saved.'); org.reload(); } }}>Save</Button></div>
        <p className="mt-2 text-xs text-steel-600">CSWMS uses placeholder branding until the official logo is supplied.</p>
      </Panel>
      {s.loading ? <Spinner /> : groups.map((g) => (
        <Panel key={g} title={g} padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>Setting</Th><Th>Value</Th><Th>Updated</Th><Th /></tr></thead>
            <tbody>{s.rows.filter((r) => r.category === g).map((r) => {
              const d = draft[r.key];
              return (
                <tr key={r.key}><Td><div className="font-medium text-navy-900">{r.description}</div><div className="font-mono text-xs text-steel-600">{r.key}</div></Td>
                  <Td>{typeof r.value === 'boolean'
                    ? <Select value={d ?? String(r.value)} onChange={(e) => setDraft({ ...draft, [r.key]: e.target.value })} className="w-28"><option value="true">Yes</option><option value="false">No</option></Select>
                    : <Input value={d ?? asText(r.value)} onChange={(e) => setDraft({ ...draft, [r.key]: e.target.value })} className="w-48" />}</Td>
                  <Td className="text-xs">{fmtDateTime(r.updated_at)}</Td>
                  <Td>{d !== undefined && d !== asText(r.value) && <Button size="sm" variant="primary" busy={act.busy} onClick={async () => {
                    let v: unknown; try { v = parse(r.value, d); } catch { act.setError({ kind: 'validation', message: 'Invalid value' }); return; }
                    if (await act.run('update_setting', { p_key: r.key, p_value: v }, 'Setting saved.')) { const n = { ...draft }; delete n[r.key]; setDraft(n); s.reload(); refresh(); }
                  }}>Save</Button>}</Td></tr>
              );
            })}</tbody>
          </Table>
        </Panel>
      ))}
    </div>
  );
}

function Reasons() {
  const r = useRows<Record<string, any>>('reasons', (sb) => sb.from('reason_codes').select('*').order('kind').order('label'));
  return <MasterTable title="Reason codes" table="reason_codes" rows={r.rows} loading={r.loading} onChanged={r.reload} canEdit
    fields={[{ key: 'kind', label: 'Used for', type: 'select', required: true, immutable: true, options: ['withdrawal', 'adjustment', 'return', 'status_change', 'transfer_writeoff'].map((x) => ({ value: x, label: x.replace('_', ' ') })) },
      { key: 'code', label: 'Code', required: true, upper: true, immutable: true }, { key: 'label', label: 'Label', required: true },
      { key: 'requires_reference', label: 'Requires client / job / reference', type: 'checkbox' }, { key: 'status', label: 'Status', type: 'status' }]} />;
}

function Events() {
  const [src, setSrc] = useState('');
  const ev = useRows<{ id: number; at: string; source: string; event: string; ok: boolean; detail: unknown }>('ev' + src, (sb) => {
    let q = sb.from('system_events').select('*').order('at', { ascending: false }).limit(300);
    if (src) q = q.eq('source', src);
    return q;
  });
  const failures = ev.rows.filter((e) => !e.ok).length;
  return (
    <div className="space-y-4">
      <Notice tone={failures ? 'warn' : 'ok'} title={failures ? `${failures} failed events in the latest ${ev.rows.length}` : 'No failures recorded in the latest events'}>
        Scheduled jobs: the database scheduler (pg_cron) runs the dispatcher every 15 minutes — it starts the daily integrity check at the configured time, retries failures and raises a monitoring alert if a check is missed. The Vercel cron calls the same dispatcher as a second line of defence and delivers alert e-mails.
      </Notice>
      <div className="flex justify-between gap-2">
        <Select value={src} onChange={(e) => setSrc(e.target.value)} className="w-56" aria-label="Source"><option value="">All sources</option>{['cron', 'email', 'client', 'backup'].map((x) => <option key={x}>{x}</option>)}</Select>
        <ExportButtons title="System events" rows={ev.rows} cols={[{ key: 'at', label: 'When', get: (e) => fmtDateTime(e.at) }, { key: 'source', label: 'Source' }, { key: 'event', label: 'Event' }, { key: 'ok', label: 'OK' }, { key: 'detail', label: 'Detail' }]} />
      </div>
      <LoadError error={ev.error} />
      {ev.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>When</Th><Th>Source</Th><Th>Event</Th><Th>Result</Th><Th>Detail</Th></tr></thead>
          <tbody>{ev.rows.map((e) => (
            <tr key={e.id}><Td className="whitespace-nowrap text-xs">{fmtDateTime(e.at)}</Td><Td>{e.source}</Td><Td mono>{e.event}</Td><Td><Badge tone={e.ok ? 'ok' : 'bad'}>{e.ok ? 'ok' : 'failed'}</Badge></Td>
              <Td><code className="block max-w-xl truncate text-xs">{e.detail ? JSON.stringify(e.detail) : ''}</code></Td></tr>
          ))}
            {ev.rows.length === 0 && <tr><Td className="text-steel-600">No events.</Td></tr>}</tbody>
        </Table>
      )}
    </div>
  );
}

function Audit() {
  const [entity, setEntity] = useState('');
  const a = useRows<{ id: number; at: string; actor_id: string | null; action: string; entity: string; entity_id: string | null; before: unknown; after: unknown }>('audit' + entity, (sb) => {
    let q = sb.from('audit_log').select('*').order('id', { ascending: false }).limit(300);
    if (entity) q = q.eq('entity', entity);
    return q;
  });
  const users = useRows<{ id: string; full_name: string }>('au', (sb) => sb.from('app_users').select('id, full_name'));
  const name = (id: string | null) => users.rows.find((u) => u.id === id)?.full_name ?? (id ? id.slice(0, 8) : 'system');
  return (
    <div className="space-y-3">
      <p className="text-sm text-steel-600">Permanent record of important actions (master data changes, role changes, settings, approvals). Entries cannot be edited or deleted.</p>
      <div className="flex justify-between gap-2">
        <Input value={entity} onChange={(e) => setEntity(e.target.value.trim())} placeholder="Filter by table, e.g. products" className="max-w-xs" />
        <ExportButtons title="Audit history" rows={a.rows} cols={[{ key: 'at', label: 'When', get: (r) => fmtDateTime(r.at) }, { key: 'actor', label: 'By', get: (r) => name(r.actor_id) }, { key: 'action', label: 'Action' }, { key: 'entity', label: 'Entity' }, { key: 'entity_id', label: 'Record' }, { key: 'before', label: 'Before' }, { key: 'after', label: 'After' }]} />
      </div>
      <LoadError error={a.error} />
      {a.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>When</Th><Th>By</Th><Th>Action</Th><Th>Entity</Th><Th>Change</Th></tr></thead>
          <tbody>{a.rows.map((r) => (
            <tr key={r.id}><Td className="whitespace-nowrap text-xs">{fmtDateTime(r.at)}</Td><Td>{name(r.actor_id)}</Td><Td mono>{r.action}</Td><Td>{r.entity}<div className="font-mono text-[11px] text-steel-600">{r.entity_id}</div></Td>
              <Td><code className="block max-w-xl truncate text-xs" title={JSON.stringify({ before: r.before, after: r.after })}>{r.after ? JSON.stringify(r.after) : JSON.stringify(r.before)}</code></Td></tr>
          ))}</tbody>
        </Table>
      )}
    </div>
  );
}

function Backup() {
  return (
    <Panel title="Backups & recovery">
      <div className="space-y-3 text-sm text-steel-800">
        <p><b>Automatic backups.</b> Supabase takes daily backups of the database (Pro plan: 7 days retained; enable Point-in-Time Recovery for restore to any second). Check them under Supabase → Database → Backups.</p>
        <p><b>Independent weekly copy.</b> The GitHub Action <code>.github/workflows/db-backup.yml</code> runs <code>pg_dump</code> weekly and stores an encrypted dump outside Supabase, so a copy exists even if the Supabase project is lost.</p>
        <p><b>Restore drill.</b> At least quarterly, restore the latest dump into a separate test project, then run <i>Stock Integrity → Run check now</i> there. A restore is only trusted when that check is GREEN. The procedure is in <code>docs/BACKUP_AND_RECOVERY.md</code>; the automated test suite also proves that a dump restores into a new database that passes a full integrity check.</p>
        <p><b>Never restore over live data</b> without head-office approval — restoring discards transactions recorded after the backup. Record every restore in the system log.</p>
      </div>
    </Panel>
  );
}

type Rule = { id: string; kind: string; name: string; min_value_zar: number; levels: string[]; is_active: boolean; updated_at: string };
const RULE_KIND: Record<string, string> = { purchase_order: 'Purchase order', adjustment: 'Stock adjustment', reversal: 'Reversal', transfer_writeoff: 'Transfer write-off', stocktake: 'Stocktake variances', opening_balance: 'Opening balances' };
const RULE_LEVEL: Record<string, string> = { any: 'Any authorised approver', branch: 'Branch manager or higher', company: 'Company manager or higher', group: 'Head office' };

/** Value-based, multi-level approval rules: the highest active rule whose threshold the request reaches decides its levels. */
function ApprovalRules({ canEdit }: { canEdit: boolean }) {
  const r = useRows<Rule>('rules', (sb) => sb.from('approval_rules').select('*').order('kind').order('min_value_zar'));
  const act = useAction();
  const blank = { id: null as string | null, kind: 'purchase_order', name: '', min: '0', levels: ['any'] as string[], active: true };
  const [ed, setEd] = useState<typeof blank | null>(null);
  const save = async () => {
    if (!ed) return;
    const min = Number(ed.min.replace(/\s/g, '').replace(',', '.'));
    if (isNaN(min) || min < 0) { act.setError({ kind: 'validation', message: 'Threshold must be a number of rand, 0 or more' }); return; }
    if (await act.run('save_approval_rule', { p_id: ed.id, p_kind: ed.kind, p_name: ed.name.trim(), p_min_value: min, p_levels: ed.levels, p_active: ed.active }, 'Rule saved. It applies to new requests.')) { setEd(null); r.reload(); }
  };
  return (
    <div className="space-y-4">
      <Notice tone="info">For each request the highest active rule it reaches is used. Each level must be decided by a different person, and nobody may approve their own request. Changes apply to new requests only.</Notice>
      <ActionResult error={act.error} ok={act.ok} />
      {r.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>Request type</Th><Th>Rule</Th><Th right>From value</Th><Th>Approval levels</Th><Th>Status</Th><Th /></tr></thead>
          <tbody>{r.rows.map((x) => (
            <tr key={x.id}><Td>{RULE_KIND[x.kind] ?? x.kind}</Td><Td>{x.name}</Td><Td right>R {Number(x.min_value_zar).toLocaleString('en-ZA', { minimumFractionDigits: 2 })}</Td>
              <Td>{x.levels.map((l, i) => <span key={i}>{i > 0 && ' → '}<Badge>{RULE_LEVEL[l] ?? l}</Badge></span>)}</Td>
              <Td>{x.is_active ? <Badge tone="ok">active</Badge> : <Badge>inactive</Badge>}</Td>
              <Td>{canEdit && <Button size="sm" onClick={() => setEd({ id: x.id, kind: x.kind, name: x.name, min: String(x.min_value_zar), levels: [...x.levels], active: x.is_active })}>Edit</Button>}</Td></tr>
          ))}</tbody>
        </Table>
      )}
      {canEdit && !ed && <Button variant="primary" onClick={() => setEd(blank)}>Add rule</Button>}
      {ed && (
        <Panel title={ed.id ? 'Edit rule' : 'New rule'}>
          <div className="grid gap-3 sm:grid-cols-3">
            <label className="text-sm">Request type<Select value={ed.kind} disabled={!!ed.id} onChange={(e) => setEd({ ...ed, kind: e.target.value })}>{Object.entries(RULE_KIND).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></label>
            <label className="text-sm">Name<Input value={ed.name} onChange={(e) => setEd({ ...ed, name: e.target.value })} placeholder="e.g. Large orders" /></label>
            <label className="text-sm">Applies from value (R)<Input inputMode="decimal" value={ed.min} onChange={(e) => setEd({ ...ed, min: e.target.value })} /></label>
          </div>
          <div className="mt-4 space-y-2">
            <div className="text-sm font-medium">Levels, in order</div>
            {ed.levels.map((l, i) => (
              <div key={i} className="flex items-center gap-2"><span className="w-16 text-sm text-steel-600">Level {i + 1}</span>
                <Select className="max-w-xs" value={l} onChange={(e) => { const n = [...ed.levels]; n[i] = e.target.value; setEd({ ...ed, levels: n }); }}>{Object.entries(RULE_LEVEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>
                {ed.levels.length > 1 && <Button size="sm" onClick={() => setEd({ ...ed, levels: ed.levels.filter((_, j) => j !== i) })}>Remove</Button>}</div>
            ))}
            {ed.levels.length < 4 && <Button size="sm" onClick={() => setEd({ ...ed, levels: [...ed.levels, 'group'] })}>Add level</Button>}
          </div>
          <label className="mt-4 flex items-center gap-2 text-sm"><input type="checkbox" checked={ed.active} onChange={(e) => setEd({ ...ed, active: e.target.checked })} />Active</label>
          <div className="mt-4 flex gap-2"><Button variant="primary" busy={act.busy} disabled={!ed.name.trim()} onClick={save}>Save rule</Button><Button onClick={() => setEd(null)}>Cancel</Button></div>
        </Panel>
      )}
    </div>
  );
}
