'use client';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { ArrowLeftRight, Bell, ClipboardCheck, Stamp, Undo2, Wrench } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, Notice, Spinner, cx } from '@/components/ui';
import { UndoButton } from '@/components/undo';
import { LoadError } from '@/components/widgets';
import { callRpc } from '@/hooks/use-transaction';
import { useOnline } from '@/hooks/use-online';
import { fmtDate, fmtDateTime, TXN_LABELS } from '@/lib/format';
import { greeting } from '@/lib/i18n';
import { fetchPack } from '@/lib/count-queue';

type Count = { id: string; stocktake_no: string; name: string; kind: string; status: string; due_date: string | null; warehouse_code: string;
  is_overdue: boolean; lines: number; counted: number; recounts: number; assigned: boolean };
type Tasks = {
  counts: Count[];
  tools: { id: string; asset_tag: string; description: string; due_back_at: string | null; is_overdue: boolean; job_reference: string | null }[];
  transfers: { id: string; transfer_no: string; from: string; to: string; expected_arrival_at: string | null; is_overdue: boolean }[];
  approvals: number; unread: number;
};
type Undoable = { id: string; txn_no: string; txn_type: string; posted_at: string; reference: string | null; warehouse_code: string; items: string | null; seconds_left: number };
const CACHE = 'cswms.tasks';

export default function MyTasksPage() {
  const { me, t } = useApp();
  const online = useOnline();
  const [data, setData] = useState<Tasks | null>(null);
  const [undo, setUndo] = useState<Undoable[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [offlineReady, setOfflineReady] = useState<Record<string, boolean>>({});

  const load = async () => {
    const [a, b] = await Promise.all([callRpc<Tasks>('my_tasks'), callRpc<Undoable[]>('my_undoable_transactions')]);
    if (a.data) {
      setData(a.data); setError(null);
      try { localStorage.setItem(CACHE, JSON.stringify(a.data)); } catch { /* ignore */ }
      // keep today's count lists on the phone so counting works without signal
      for (const c of a.data.counts) {
        fetchPack(c.id).then(() => setOfflineReady((r) => ({ ...r, [c.id]: true }))).catch(() => {});
      }
    } else {
      try { const c = localStorage.getItem(CACHE); if (c) setData(JSON.parse(c)); } catch { /* ignore */ }
      setError(a.error?.message ?? null);
    }
    setUndo(b.data ?? []);
    setLoading(false);
  };
  useEffect(() => { void load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  if (loading) return <Spinner />;
  const first = me?.user?.full_name?.split(' ')[0] ?? '';
  const empty = data && !data.counts.length && !data.tools.length && !data.transfers.length && !data.approvals && !undo.length;

  return (
    <div className="mx-auto max-w-3xl space-y-5">
      <div>
        <h1 className="text-2xl font-semibold text-navy-900">{greeting(t)}{first ? `, ${first}` : ''}</h1>
        <p className="text-steel-600">{t('my_tasks')} · {fmtDate(new Date())}</p>
      </div>
      {error && online && <LoadError error={error} />}
      {empty && <Notice tone="ok">{t('nothing_today')}</Notice>}

      {/* counts */}
      {data && data.counts.length > 0 && (
        <section aria-labelledby="h-counts">
          <h2 id="h-counts" className="mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-steel-600"><ClipboardCheck className="size-4" />{t('counts_to_do')}</h2>
          <ul className="space-y-3">
            {data.counts.map((c) => {
              const pct = c.lines ? Math.round((100 * c.counted) / c.lines) : 0;
              return (
                <li key={c.id} className={cx('rounded-lg border bg-white p-4', c.is_overdue ? 'border-bad-600' : 'border-steel-200')}>
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <div>
                      <div className="font-semibold text-navy-900">{c.kind === 'cycle' ? t('cycle_count') : t('full_count')} · {c.warehouse_code}</div>
                      <div className="text-sm text-steel-600">{c.stocktake_no} · {c.name}</div>
                    </div>
                    <div className="flex flex-wrap gap-1">
                      {c.is_overdue ? <Badge tone="bad">{t('overdue')}</Badge> : c.due_date && <Badge tone="idle">{t('due')} {fmtDate(c.due_date)}</Badge>}
                      {c.recounts > 0 && <Badge tone="warn">{c.recounts} {t('recounts')}</Badge>}
                      {offlineReady[c.id] && <Badge tone="ok">{t('ready_offline')}</Badge>}
                    </div>
                  </div>
                  <div className="mt-3 flex items-center gap-3">
                    <div className="h-2 flex-1 overflow-hidden rounded-full bg-steel-200"><div className="h-full bg-ok-600" style={{ width: `${pct}%` }} /></div>
                    <span className="font-mono text-sm text-steel-600">{c.counted}/{c.lines}</span>
                  </div>
                  <Link href={`/stocktake/${c.id}/count`} className="mt-3 flex h-14 items-center justify-center rounded-md bg-signal-400 text-base font-semibold text-navy-950 hover:bg-signal-500">
                    {c.counted ? t('continue_counting') : t('start_counting')}
                  </Link>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      {/* undo */}
      {undo.length > 0 && (
        <section aria-labelledby="h-undo">
          <h2 id="h-undo" className="mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-steel-600"><Undo2 className="size-4" />{t('undo_recent')}</h2>
          <ul className="divide-y divide-steel-100 rounded-lg border border-steel-200 bg-white">
            {undo.map((u) => (
              <li key={u.id} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
                <div className="min-w-0">
                  <Link href={`/transactions/${u.id}`} className="font-medium text-navy-900 underline">{TXN_LABELS[u.txn_type] ?? u.txn_type} {u.txn_no}</Link>
                  <div className="truncate text-sm text-steel-600">{u.items}{u.reference ? ` · ${u.reference}` : ''} · {fmtDateTime(u.posted_at)}</div>
                </div>
                <UndoButton txnId={u.id} txnNo={u.txn_no} postedAt={u.posted_at} onDone={load} />
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* tools */}
      {data && data.tools.length > 0 && (
        <section aria-labelledby="h-tools">
          <h2 id="h-tools" className="mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-steel-600"><Wrench className="size-4" />{t('tools_held')}</h2>
          <ul className="divide-y divide-steel-100 rounded-lg border border-steel-200 bg-white">
            {data.tools.map((a) => (
              <li key={a.id}><Link href={`/assets/${a.id}`} className="flex items-center justify-between gap-3 px-4 py-3 hover:bg-steel-50">
                <span><span className="font-mono text-sm">{a.asset_tag}</span> {a.description}{a.job_reference ? <span className="text-steel-600"> · {a.job_reference}</span> : null}</span>
                {a.due_back_at && <Badge tone={a.is_overdue ? 'bad' : 'idle'}>{a.is_overdue ? t('overdue') : t('due_back')} {fmtDate(a.due_back_at)}</Badge>}
              </Link></li>
            ))}
          </ul>
        </section>
      )}

      {/* transfers */}
      {data && data.transfers.length > 0 && (
        <section aria-labelledby="h-tr">
          <h2 id="h-tr" className="mb-2 flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-steel-600"><ArrowLeftRight className="size-4" />{t('transfers_in')}</h2>
          <ul className="divide-y divide-steel-100 rounded-lg border border-steel-200 bg-white">
            {data.transfers.map((x) => (
              <li key={x.id}><Link href={`/transfers/${x.id}`} className="flex items-center justify-between gap-3 px-4 py-3 hover:bg-steel-50">
                <span className="font-medium">{x.transfer_no} <span className="font-normal text-steel-600">{x.from} → {x.to}</span></span>
                {x.expected_arrival_at && <Badge tone={x.is_overdue ? 'bad' : 'idle'}>{fmtDate(x.expected_arrival_at)}</Badge>}
              </Link></li>
            ))}
          </ul>
        </section>
      )}

      <div className="grid gap-3 sm:grid-cols-2">
        {data && data.approvals > 0 && (
          <Link href="/approvals" className="flex items-center gap-3 rounded-lg border border-steel-200 bg-white p-4 hover:bg-steel-50">
            <Stamp className="size-6 text-navy-900" /><span><b className="text-xl">{data.approvals}</b> {t('approvals_waiting')}</span>
          </Link>
        )}
        {data && data.unread > 0 && (
          <Link href="/alerts?tab=notifications" className="flex items-center gap-3 rounded-lg border border-steel-200 bg-white p-4 hover:bg-steel-50">
            <Bell className="size-6 text-navy-900" /><span><b className="text-xl">{data.unread}</b> {t('unread')}</span>
          </Link>
        )}
      </div>
      <div className="text-center"><Button variant="ghost" size="sm" onClick={() => { setLoading(true); void load(); }}>↻</Button></div>
    </div>
  );
}
