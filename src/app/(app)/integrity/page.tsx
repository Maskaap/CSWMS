'use client';
import Link from 'next/link';
import { useMemo, useState } from 'react';
import { PlayCircle } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { IntegrityLamp, type IntegrityStatus } from '@/components/integrity-lamp';
import { Badge, Button, Notice, PageHeader, Panel, Select, Spinner, Stat, StatusBadge, Table, Td, Th } from '@/components/ui';
import { ActionResult, ExportButtons, LoadError, Tabs, useConfirm } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useRows, useRpc } from '@/hooks/use-rows';
import { fmtDateTime, fmtQty } from '@/lib/format';
import { CHECK_LABELS } from '@/lib/integrity';

type Finding = {
  id: string; finding_no: string; check_code: string; severity: 'critical' | 'warning' | 'info'; classification: string; title: string; description: string; status: string;
  possible_cause: string | null; product_sku: string | null; product_description: string | null; warehouse_code: string | null; location_code: string | null; company_code: string | null;
  owner_company_code: string | null; expected_qty: number | null; recorded_qty: number | null; difference: number | null; occurrences: number; still_present: boolean; escalated: boolean;
  first_detected_at: string; last_detected_at: string; assigned_to_name: string | null; resolved_at: string | null; resolution: string | null;
};
type Run = { id: string; run_no: string; trigger: string; status: string; result: string | null; started_at: string; finished_at: string | null; keys_checked: number | null;
  products_checked: number | null; locations_checked: number | null; companies_checked: number | null; warehouses_checked: number | null; mismatches: number | null;
  findings_detected: number | null; findings_new: number | null; error_message: string | null; ledger_rows_checked?: number | null; business_date: string };

export default function IntegrityPage() {
  const { can } = useApp();
  const status = useRpc<IntegrityStatus & Record<string, unknown>>('ist', 'integrity_status');
  const [tab, setTab] = useState<'issues' | 'runs' | 'resolved'>('issues');
  const [sev, setSev] = useState('');
  const findings = useRows<Finding>(`f|${tab}`, (sb) => sb.rpc('integrity_findings', { p_status: tab === 'resolved' ? 'all' : 'active', p_limit: 500 }));
  const runs = useRows<Run>(tab === 'runs' ? 'runs' : null, (sb) => sb.rpc('integrity_runs', { p_limit: 60 }));
  const act = useAction();
  const confirm = useConfirm();
  const s = status.data;

  const list = useMemo(() => findings.rows
    .filter((f) => (tab === 'resolved' ? ['resolved', 'dismissed'].includes(f.status) : true))
    .filter((f) => !sev || f.severity === sev)
    .sort((a, b) => (a.severity === b.severity ? b.last_detected_at.localeCompare(a.last_detected_at) : a.severity === 'critical' ? -1 : 1)), [findings.rows, tab, sev]);
  const affected = useMemo(() => {
    const act = findings.rows.filter((f) => !['resolved', 'dismissed'].includes(f.status));
    return { companies: new Set(act.map((f) => f.company_code).filter(Boolean)).size, warehouses: new Set(act.map((f) => f.warehouse_code).filter(Boolean)).size, products: new Set(act.map((f) => f.product_sku).filter(Boolean)).size };
  }, [findings.rows]);

  return (
    <>
      {confirm.node}
      <PageHeader title="Stock Integrity & System Health"
        description="An independent daily reconciliation recalculates every balance from the transaction ledger and checks for errors. It never changes stock — every discrepancy is investigated and corrected through an authorised transaction. It does not replace physical stocktakes."
        actions={can('integrity.admin') && <Button variant="navy" busy={act.busy} onClick={async () => {
          const c = await confirm.ask({ title: 'Run an integrity check now?', body: 'The check reads a consistent snapshot and does not block stock transactions. It does not change any balance.' });
          if (c && await act.run('integrity_run_now', {}, 'Integrity check completed.')) { status.reload(); findings.reload(); runs.reload(); }
        }}><PlayCircle className="size-4" />Run check now</Button>} />
      <ActionResult error={act.error} ok={act.ok} />
      <LoadError error={status.error} />
      {!s ? <Spinner /> : (
        <div className="mb-6 space-y-4">
          <IntegrityLamp s={s} />
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-8">
            <Stat label="Last successful check" value={<span className="text-base">{s.last_success_at ? fmtDateTime(s.last_success_at) : 'Never'}</span>} tone={s.status === 'GREY' ? 'idle' : undefined} />
            <Stat label="Balances verified" value={fmtQty(s.keys_checked)} />
            <Stat label="Items / locations" value={`${fmtQty(s.products_checked)} / ${fmtQty(s.locations_checked)}`} />
            <Stat label="Reconciliations passed" value={fmtQty(s.reconciliations_passed)} tone="ok" />
            <Stat label="Ledger mismatches" value={fmtQty(s.mismatches)} tone={Number(s.mismatches) ? 'bad' : 'ok'} />
            <Stat label="Open critical" value={s.open_critical} tone={s.open_critical ? 'bad' : undefined} />
            <Stat label="Open warnings" value={s.open_warnings} tone={s.open_warnings ? 'warn' : undefined} />
            <Stat label="Affected companies / warehouses / products" value={<span className="text-lg">{affected.companies} / {affected.warehouses} / {affected.products}</span>} />
          </div>
          {Number(s.monitor_problems) > 0 && <Notice tone="bad" title="Monitoring problem">The scheduled check failed, was skipped or is overdue. See the run history.</Notice>}
        </div>
      )}

      <div className="flex flex-wrap items-center justify-between gap-3">
        <Tabs value={tab} onChange={setTab} tabs={[{ id: 'issues', label: 'Open issues' }, { id: 'resolved', label: 'Resolution history' }, { id: 'runs', label: 'Check runs' }]} />
        {tab !== 'runs' && (
          <div className="mb-4 flex gap-2">
            <Select value={sev} onChange={(e) => setSev(e.target.value)} className="w-40" aria-label="Severity"><option value="">All severities</option><option value="critical">Critical</option><option value="warning">Warning</option></Select>
            <ExportButtons title="Integrity investigation report" rows={list} cols={[
              { key: 'finding_no', label: 'Issue' }, { key: 'severity', label: 'Severity' }, { key: 'classification', label: 'Classification' }, { key: 'check_code', label: 'Check', get: (f) => CHECK_LABELS[f.check_code] ?? f.check_code },
              { key: 'title', label: 'Title' }, { key: 'company_code', label: 'Company' }, { key: 'warehouse_code', label: 'Warehouse' }, { key: 'location_code', label: 'Location' },
              { key: 'product_sku', label: 'Product' }, { key: 'expected_qty', label: 'Expected', num: true }, { key: 'recorded_qty', label: 'Recorded', num: true }, { key: 'difference', label: 'Difference', num: true },
              { key: 'status', label: 'Status' }, { key: 'assigned_to_name', label: 'Investigator' }, { key: 'first_detected_at', label: 'First detected', get: (f) => fmtDateTime(f.first_detected_at) },
              { key: 'occurrences', label: 'Times detected', num: true }, { key: 'resolution', label: 'Resolution' }]} />
          </div>
        )}
      </div>
      <LoadError error={findings.error ?? runs.error} />
      {tab !== 'runs' ? (findings.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>Issue</Th><Th>Severity</Th><Th>What</Th><Th>Where</Th><Th right>Expected</Th><Th right>Recorded</Th><Th right>Difference</Th><Th>Investigation</Th><Th>Detected</Th></tr></thead>
          <tbody>{list.map((f) => (
            <tr key={f.id} className="hover:bg-steel-50">
              <Td><Link href={`/integrity/${f.id}`} className="font-mono text-[13px] font-semibold hover:underline">{f.finding_no}</Link></Td>
              <Td><Badge tone={f.severity === 'critical' ? 'bad' : 'warn'}>{f.severity}</Badge>{f.classification !== 'confirmed' && <div className="mt-1 text-xs text-steel-600">{f.classification}</div>}{f.escalated && <div className="mt-1 text-xs text-bad-600">escalated</div>}</Td>
              <Td><div className="font-medium text-navy-900">{f.title}</div><div className="text-xs text-steel-600">{CHECK_LABELS[f.check_code] ?? f.check_code}{f.product_sku ? ` · ${f.product_sku}` : ''}</div></Td>
              <Td>{f.company_code ?? '—'}{f.warehouse_code && ` / ${f.warehouse_code}`}{f.location_code && <span className="font-mono text-[12px]"> / {f.location_code}</span>}</Td>
              <Td right>{fmtQty(f.expected_qty)}</Td><Td right>{fmtQty(f.recorded_qty)}</Td>
              <Td right className={f.difference ? 'font-semibold text-bad-600' : ''}>{f.difference != null ? (Number(f.difference) > 0 ? '+' : '') + fmtQty(f.difference) : '—'}</Td>
              <Td><StatusBadge status={f.status} />{f.assigned_to_name && <div className="text-xs text-steel-600">{f.assigned_to_name}</div>}{!f.still_present && !['resolved', 'dismissed'].includes(f.status) && <div className="text-xs text-ok-600">no longer detected</div>}</Td>
              <Td className="text-xs">{fmtDateTime(f.last_detected_at)}{f.occurrences > 1 && <div className="text-steel-600">{f.occurrences}× (first {fmtDateTime(f.first_detected_at)})</div>}</Td>
            </tr>
          ))}
            {list.length === 0 && <tr><Td className="text-steel-600">{tab === 'issues' ? 'No open integrity issues.' : 'Nothing resolved yet.'}</Td></tr>}</tbody>
        </Table>
      )) : (runs.loading ? <Spinner /> : (
        <Panel padded={false} actions={<ExportButtons title="Daily integrity report" rows={runs.rows} cols={[
          { key: 'run_no', label: 'Run' }, { key: 'business_date', label: 'Business date' }, { key: 'trigger', label: 'Trigger' }, { key: 'status', label: 'Status' }, { key: 'result', label: 'Result' },
          { key: 'started_at', label: 'Started', get: (r) => fmtDateTime(r.started_at) }, { key: 'finished_at', label: 'Finished', get: (r) => fmtDateTime(r.finished_at) },
          { key: 'keys_checked', label: 'Balances checked', num: true }, { key: 'products_checked', label: 'Products', num: true }, { key: 'locations_checked', label: 'Locations', num: true },
          { key: 'mismatches', label: 'Mismatches', num: true }, { key: 'findings_detected', label: 'Findings', num: true }, { key: 'error_message', label: 'Error' }]} />} title="Check runs (evidence of reconciliation)">
          <Table className="rounded-none border-0">
            <thead><tr><Th>Run</Th><Th>Trigger</Th><Th>Status / result</Th><Th>Started</Th><Th>Duration</Th><Th right>Balances</Th><Th right>Items</Th><Th right>Locations</Th><Th right>Mismatches</Th><Th right>Findings (new)</Th></tr></thead>
            <tbody>{runs.rows.map((r) => (
              <tr key={r.id}><Td mono>{r.run_no}</Td><Td>{r.trigger}</Td>
                <Td><StatusBadge status={r.status === 'completed' ? (r.result ?? 'completed') : r.status} />{r.error_message && <div className="max-w-xs text-xs text-bad-600">{r.error_message}</div>}</Td>
                <Td className="text-xs">{fmtDateTime(r.started_at)}</Td>
                <Td className="text-xs">{r.finished_at ? `${Math.max(0, Math.round((new Date(r.finished_at).getTime() - new Date(r.started_at).getTime()) / 100) / 10)} s` : '—'}</Td>
                <Td right>{fmtQty(r.keys_checked)}</Td><Td right>{fmtQty(r.products_checked)}</Td><Td right>{fmtQty(r.locations_checked)}</Td>
                <Td right className={r.mismatches ? 'font-semibold text-bad-600' : ''}>{fmtQty(r.mismatches)}</Td><Td right>{fmtQty(r.findings_detected)} ({fmtQty(r.findings_new)})</Td></tr>
            ))}
              {runs.rows.length === 0 && <tr><Td className="text-steel-600">No runs recorded yet.</Td></tr>}</tbody>
          </Table>
        </Panel>
      ))}
    </>
  );
}
