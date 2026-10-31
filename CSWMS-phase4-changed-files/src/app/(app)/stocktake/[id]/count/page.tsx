'use client';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowLeft, ArrowRight, Check, CheckCircle2, ChevronLeft, CloudOff, CloudUpload, MapPin, PackageOpen, Trash2, Volume2, VolumeX, Wifi } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { ScanInput } from '@/components/scanner';
import { Badge, Button, Notice, Select, Spinner, cx } from '@/components/ui';
import { useConfirm } from '@/components/widgets';
import { useOnline } from '@/hooks/use-online';
import {
  discard, enqueue, fetchPack, loadPack, onQueueChange, onSent, queued, startBackgroundSync, sync, type Pack, type QueuedCount,
} from '@/lib/count-queue';
import { feedback, setSoundOn, soundOn } from '@/lib/feedback';
import { fmtQty, fmtTime, parseQty } from '@/lib/format';
import type { Key } from '@/lib/i18n';

type PLoc = { id: string; code: string; name: string; label_code: string; walk_order: number | null };
type PLine = { line_id: string; product_id: string; location_id: string; counted_qty: number | null; line_status: string; expected_qty: number | null; is_unexpected: boolean };
type PUnit = { uom_id: string; code: string; factor: number; decimals: number };
type PProd = { id: string; sku: string; description: string; base_uom_id: string; base_uom: string; decimals: number; units: PUnit[]; barcodes: { code: string; uom_id: string | null }[] };
type PStock = { id: string; stocktake_no: string; name: string; status: string; kind: string; blind: boolean; warehouse_code: string; product_scoped?: boolean };
type TPack = Pack & { stocktake: PStock; locations: PLoc[]; lines: PLine[]; products: PProd[] };

const key = (p: string, l: string) => `${p}|${l}`;
const DONE_KEY = (id: string) => `cswms.count.done.${id}`;

export default function GuidedCountPage() {
  const { id } = useParams<{ id: string }>();
  const { t } = useApp();
  const online = useOnline();
  const confirm = useConfirm();
  const [pack, setPack] = useState<TPack | null>(null);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [queue, setQueue] = useState<QueuedCount[]>([]);
  const [server, setServer] = useState<Record<string, number | null>>({});   // line totals confirmed by the database
  const [extra, setExtra] = useState<Record<string, true>>({});              // items found where not expected
  const [idx, setIdx] = useState(0);
  const [done, setDone] = useState<string[]>([]);
  const [current, setCurrent] = useState<string | null>(null);                // product being counted
  const [qtyText, setQtyText] = useState('');
  const [unit, setUnit] = useState<string>('');
  const [msg, setMsg] = useState<{ tone: 'ok' | 'warn' | 'bad'; text: string } | null>(null);
  const [sound, setSound] = useState(true);
  const qtyRef = useRef<HTMLInputElement>(null);

  // ---- load: fresh list when online, the copy on this phone otherwise ----
  const applyPack = useCallback((p: TPack) => {
    setPack(p);
    setServer(Object.fromEntries(p.lines.map((l) => [key(l.product_id, l.location_id), l.counted_qty])));
  }, []);
  useEffect(() => {
    setSound(soundOn());
    try { setDone(JSON.parse(localStorage.getItem(DONE_KEY(id)) ?? '[]')); } catch { /* ignore */ }
    startBackgroundSync();
    (async () => {
      try {
        applyPack(await fetchPack(id) as TPack);
      } catch (e) {
        const cached = await loadPack(id).catch(() => undefined);
        if (cached) applyPack(cached as TPack);
        else setLoadErr((e as { message?: string })?.message ?? t('download_failed'));
      }
    })();
  }, [id, applyPack, t]);

  // ---- queue state ----
  const refreshQueue = useCallback(() => { queued(id).then(setQueue).catch(() => {}); }, [id]);
  useEffect(() => {
    refreshQueue();
    const off1 = onQueueChange(refreshQueue);
    const off2 = onSent((r) => { if (r.stocktake_id === id) setServer((s) => ({ ...s, [key(r.product_id, r.location_id)]: r.line_total })); });
    return () => { off1(); off2(); };
  }, [id, refreshQueue]);
  useEffect(() => { if (online) void sync(); }, [online]);

  // ---- lookups built from the list on this phone (work offline) ----
  const idx2 = useMemo(() => {
    const prod = new Map<string, PProd>(); const code = new Map<string, { p: PProd; uom: string | null }>(); const loc = new Map<string, number>();
    const linesByLoc = new Map<string, PLine[]>();
    if (!pack) return { prod, code, loc, linesByLoc, route: [] as PLoc[] };
    for (const p of pack.products) {
      prod.set(p.id, p);
      code.set(p.sku.toUpperCase(), { p, uom: null });
      for (const b of p.barcodes) code.set(b.code.toUpperCase(), { p, uom: b.uom_id });
    }
    for (const l of pack.lines) { const a = linesByLoc.get(l.location_id) ?? []; a.push(l); linesByLoc.set(l.location_id, a); }
    // a cycle count (a few items) only visits the bins where those items are; a full count visits every bin
    const route = pack.stocktake.product_scoped && linesByLoc.size > 0 ? pack.locations.filter((l) => linesByLoc.has(l.id)) : pack.locations;
    route.forEach((l, i) => { loc.set(l.label_code.toUpperCase(), i); loc.set(l.code.toUpperCase(), i); });
    return { prod, code, loc, linesByLoc, route };
  }, [pack]);

  if (loadErr) return <div className="mx-auto max-w-lg space-y-4"><BackLink id={id} /><Notice tone="bad" title={t('download_failed')}>{loadErr}</Notice></div>;
  if (!pack) return <Spinner />;

  const locs = idx2.route;
  const bin = locs[Math.min(idx, locs.length - 1)];
  const st = pack.stocktake;
  const closed = !['counting', 'review'].includes(st.status);

  const pendingFor = (p: string, l: string) => queue.filter((q) => q.status === 'pending' && q.product_id === p && q.location_id === l)
    .reduce((s, q) => s + q.qty * q.factor, 0);
  const hasPending = (p: string, l: string) => queue.some((q) => q.status === 'pending' && q.product_id === p && q.location_id === l);
  const total = (p: string, l: string) => {
    const sv = server[key(p, l)];
    if (sv == null && !hasPending(p, l)) return null;
    return Number(sv ?? 0) + pendingFor(p, l);
  };

  const binLines = (bin ? idx2.linesByLoc.get(bin.id) ?? [] : []);
  const extraHere = bin ? Object.keys(extra).filter((k) => k.endsWith('|' + bin.id)).map((k) => k.split('|')[0])
    .filter((pid) => !binLines.some((l) => l.product_id === pid)) : [];
  const rows = [...binLines.map((l) => l.product_id), ...extraHere];
  const countedHere = rows.filter((p) => total(p, bin.id) != null).length;
  const allLines = pack.lines.length;
  const allCounted = pack.lines.filter((l) => total(l.product_id, l.location_id) != null).length;
  const pending = queue.filter((q) => q.status === 'pending');
  const failed = queue.filter((q) => q.status === 'failed');

  const markDone = (locId: string) => {
    const next = Array.from(new Set([...done, locId]));
    setDone(next);
    try { localStorage.setItem(DONE_KEY(id), JSON.stringify(next)); } catch { /* ignore */ }
  };
  const goto = (i: number) => { setIdx(Math.max(0, Math.min(locs.length - 1, i))); setCurrent(null); setQtyText(''); setMsg(null); };

  const add = async (p: PProd, qty: number, uomId: string | null, method: 'scan' | 'typed') => {
    const u = uomId ? p.units.find((x) => x.uom_id === uomId) : null;
    const factor = u ? Number(u.factor) : 1;
    const expected = binLines.some((l) => l.product_id === p.id);
    if (!expected) setExtra((e) => ({ ...e, [key(p.id, bin.id)]: true }));
    await enqueue({ stocktake_id: id, product_id: p.id, location_id: bin.id, qty, uom_id: uomId, factor, method,
      label: `${p.sku} · ${bin.code} · ${fmtQty(qty)} ${u?.code ?? p.base_uom}` });
    setCurrent(p.id);
    feedback(expected ? 'ok' : 'extra');
    setMsg(expected ? { tone: 'ok', text: `${p.sku} +${fmtQty(qty * factor)} ${p.base_uom}` } : { tone: 'warn', text: `${p.sku}: ${t('not_in_bin')}` });
  };

  const onScan = (raw: string) => {
    const c = raw.trim().toUpperCase();
    const li = idx2.loc.get(c);
    if (li !== undefined) { goto(li); feedback('ok'); setMsg({ tone: 'ok', text: `${t('bin')} ${locs[li].code}` }); return; }
    const hit = idx2.code.get(c);
    if (!hit) { feedback('bad'); setMsg({ tone: 'bad', text: t('unknown_code') }); return; }
    void add(hit.p, 1, hit.uom, 'scan');
  };

  const cur = current ? idx2.prod.get(current) : null;
  const addTyped = () => {
    if (!cur) return;
    const q = parseQty(qtyText);
    if (q == null || q < 0) { feedback('bad'); setMsg({ tone: 'bad', text: t('type_qty') }); return; }
    void add(cur, q, unit && unit !== cur.base_uom_id ? unit : null, 'typed');
    setQtyText('');
  };

  const binEmpty = async () => {
    const ok = await confirm.ask({ title: `${t('bin_empty')} — ${bin.code}`, body: t('bin_empty_confirm') });
    if (!ok) return;
    for (const l of binLines) {
      if (total(l.product_id, bin.id) == null) {
        const p = idx2.prod.get(l.product_id);
        await enqueue({ stocktake_id: id, product_id: l.product_id, location_id: bin.id, qty: 0, uom_id: null, factor: 1, method: 'empty_bin',
          label: `${p?.sku ?? ''} · ${bin.code} · 0` });
      }
    }
    feedback('ok');
    markDone(bin.id);
    if (idx < locs.length - 1) goto(idx + 1);
  };
  const doneWithBin = () => { markDone(bin.id); feedback('ok'); if (idx < locs.length - 1) goto(idx + 1); else setMsg({ tone: 'ok', text: t('finished') }); };
  const finished = locs.length > 0 && locs.every((l) => done.includes(l.id));

  return (
    <div className="mx-auto max-w-2xl space-y-4">
      {confirm.node}
      {/* header */}
      <div className="flex items-center gap-2">
        <BackLink id={id} />
        <div className="min-w-0 flex-1">
          <div className="truncate font-semibold text-navy-900">{st.stocktake_no} · {st.warehouse_code}</div>
          <div className="text-xs text-steel-600">{st.kind === 'cycle' ? t('cycle_count') : t('full_count')} · {t('progress')}: {allCounted}/{allLines}</div>
        </div>
        <button type="button" className="rounded-md p-2 hover:bg-steel-100" aria-label={t('sound')}
          onClick={() => { setSoundOn(!sound); setSound(!sound); }}>
          {sound ? <Volume2 className="size-5" /> : <VolumeX className="size-5" />}
        </button>
        <SyncChip online={online} pending={pending.length} failed={failed.length} t={t} />
      </div>
      <div className="h-2 overflow-hidden rounded-full bg-steel-200" role="progressbar" aria-valuemin={0} aria-valuemax={allLines} aria-valuenow={allCounted}>
        <div className="h-full bg-ok-600 transition-all" style={{ width: `${allLines ? (100 * allCounted) / allLines : 0}%` }} />
      </div>

      {!online && <Notice tone="warn" title={<span className="inline-flex items-center gap-2"><CloudOff className="size-4" />{t('ready_offline')}</span>}>{t('offline_counting')}</Notice>}
      {closed && <Notice tone="bad">{t('counting_closed')}</Notice>}
      {failed.length > 0 && (
        <Notice tone="bad" title={t('not_sent')}>
          <ul className="space-y-1">{failed.map((f) => (
            <li key={f.request_id} className="flex items-center justify-between gap-2 text-sm">
              <span><b className="font-mono">{f.label}</b> — {f.error}</span>
              <button type="button" className="underline" onClick={() => discard(f.request_id)}>{t('remove')}</button>
            </li>))}</ul>
          <p className="mt-1 text-xs">{t('not_sent_help')}</p>
        </Notice>
      )}

      {finished ? (
        <div className="rounded-lg border-2 border-ok-600 bg-ok-50 p-6 text-center">
          <CheckCircle2 className="mx-auto size-12 text-ok-600" />
          <div className="mt-2 text-xl font-semibold text-navy-900">{t('finished')}</div>
          <p className="mt-1 text-steel-600">{pending.length > 0 ? `${pending.length} ${t('waiting_to_send')}` : t('all_sent')} · {t('tell_supervisor')}</p>
          <Button className="mt-4" onClick={() => { setDone([]); try { localStorage.removeItem(DONE_KEY(id)); } catch { /* */ } }}>{t('count_sheet')}</Button>
        </div>
      ) : bin ? (
        <>
          {/* the bin */}
          <section className="bin-label rounded-lg px-4 pb-4 pt-5" aria-label={t('bin')}>
            <div className="flex items-center justify-between gap-2">
              <Button variant="ghost" size="sm" onClick={() => goto(idx - 1)} disabled={idx === 0} aria-label={t('prev_bin')}><ArrowLeft className="size-5" /></Button>
              <div className="text-center">
                <div className="text-xs uppercase tracking-wide text-steel-600">{t('bin')} {idx + 1} / {locs.length}</div>
                <div className="font-mono text-3xl font-bold text-navy-950">{bin.code}</div>
                <div className="text-sm text-steel-600">{bin.name}</div>
              </div>
              <Button variant="ghost" size="sm" onClick={() => goto(idx + 1)} disabled={idx >= locs.length - 1} aria-label={t('next_bin')}><ArrowRight className="size-5" /></Button>
            </div>
            <div className="mt-2 text-center text-sm">
              {done.includes(bin.id) ? <Badge tone="ok">{t('done_with_bin')}</Badge> : <span className="text-steel-600">{countedHere}/{rows.length} {t('items_counted')}</span>}
            </div>
          </section>

          <ScanInput big continuous onScan={onScan} disabled={closed} label={t('scan_item')} placeholder={t('scan_or_type')} cameraHint={t('each_scan_adds')} />
          {msg && (
            <div role="status" className={cx('rounded-md px-4 py-3 text-base font-semibold',
              msg.tone === 'ok' ? 'bg-ok-50 text-ok-600' : msg.tone === 'warn' ? 'bg-warn-50 text-warn-600' : 'bg-bad-50 text-bad-600')}>{msg.text}</div>
          )}

          {/* the item being counted: running total and typed quantity for bulk */}
          {cur && (
            <section className="rounded-lg border border-steel-200 bg-white p-4">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0"><div className="font-mono text-sm text-steel-600">{cur.sku}</div><div className="font-medium text-navy-900">{cur.description}</div></div>
                <div className="text-right"><div className="text-xs text-steel-600">{t('total')} {t('in_bin')}</div>
                  <div className="font-mono text-3xl font-bold text-navy-950">{fmtQty(total(cur.id, bin.id) ?? 0)}<span className="ml-1 text-base font-normal text-steel-600">{cur.base_uom}</span></div></div>
              </div>
              <div className="mt-3 flex gap-2">
                <input ref={qtyRef} value={qtyText} onChange={(e) => setQtyText(e.target.value)} inputMode="decimal" placeholder={t('type_qty')}
                  onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); addTyped(); } }}
                  className="h-14 w-full min-w-0 rounded-md border-2 border-navy-900 px-3 text-lg focus:outline-none focus:ring-4 focus:ring-signal-300" aria-label={t('type_qty')} />
                {cur.units.length > 1 && (
                  <Select value={unit || cur.base_uom_id} onChange={(e) => setUnit(e.target.value)} className="h-14 w-28 text-base" aria-label="Unit">
                    {cur.units.map((u) => <option key={u.uom_id} value={u.uom_id}>{u.code}{Number(u.factor) !== 1 ? ` ×${fmtQty(u.factor)}` : ''}</option>)}
                  </Select>
                )}
                <Button variant="primary" size="lg" onClick={addTyped} disabled={closed}>{t('add')}</Button>
              </div>
              <p className="mt-2 text-xs text-steel-600">{t('each_scan_adds')}</p>
            </section>
          )}

          {/* what is in this bin */}
          <section className="rounded-lg border border-steel-200 bg-white">
            <ul className="divide-y divide-steel-100">
              {rows.map((pid) => {
                const p = idx2.prod.get(pid); const line = binLines.find((l) => l.product_id === pid); const tot = total(pid, bin.id);
                if (!p) return null;
                return (
                  <li key={pid}>
                    <button type="button" onClick={() => { setCurrent(pid); setUnit(''); setTimeout(() => qtyRef.current?.focus(), 30); }}
                      className={cx('flex w-full items-center gap-3 px-4 py-3 text-left hover:bg-steel-50', current === pid && 'bg-signal-50')}>
                      {tot != null ? <Check className="size-5 shrink-0 text-ok-600" /> : <span className="size-5 shrink-0 rounded-full border-2 border-steel-200" />}
                      <span className="min-w-0 flex-1"><span className="block font-mono text-sm">{p.sku}</span><span className="block truncate text-sm text-steel-600">{p.description}</span></span>
                      {!line && <Badge tone="warn">+</Badge>}
                      {line?.expected_qty != null && <span className="text-xs text-steel-400">/{fmtQty(line.expected_qty)}</span>}
                      <span className={cx('w-16 text-right font-mono text-lg', tot == null ? 'text-steel-400' : 'font-semibold text-navy-950')}>{tot == null ? '—' : fmtQty(tot)}</span>
                    </button>
                  </li>
                );
              })}
              {rows.length === 0 && <li className="px-4 py-6 text-center text-sm text-steel-600"><PackageOpen className="mx-auto mb-1 size-6" />{t('scan_item')}</li>}
            </ul>
          </section>

          <div className="grid grid-cols-2 gap-3">
            <Button size="lg" onClick={binEmpty} disabled={closed}><PackageOpen className="size-5" />{t('bin_empty')}</Button>
            <Button size="lg" variant="navy" onClick={doneWithBin} disabled={closed}><Check className="size-5" />{t('done_with_bin')}</Button>
          </div>

          {/* counts on this phone not yet confirmed */}
          {pending.length > 0 && (
            <section className="rounded-lg border border-steel-200 bg-white p-3">
              <div className="mb-2 text-sm font-semibold text-navy-900">{pending.length} {t('waiting_to_send')}</div>
              <ul className="space-y-1 text-sm">{pending.slice(-6).reverse().map((q) => (
                <li key={q.request_id} className="flex items-center justify-between gap-2">
                  <span className="font-mono">{q.label} <span className="text-steel-400">{fmtTime(q.counted_at)}</span></span>
                  <button type="button" onClick={() => discard(q.request_id)} aria-label={t('remove')} className="rounded p-1 text-bad-600 hover:bg-bad-50"><Trash2 className="size-4" /></button>
                </li>))}</ul>
            </section>
          )}

          {/* all bins, in walking order */}
          <details className="rounded-lg border border-steel-200 bg-white">
            <summary className="cursor-pointer px-4 py-3 text-sm font-medium text-navy-900"><MapPin className="mr-1 inline size-4" />{locs.length} {t('bins')}</summary>
            <ul className="grid grid-cols-3 gap-2 p-3 sm:grid-cols-4">{locs.map((l, i) => (
              <li key={l.id}><button type="button" onClick={() => goto(i)}
                className={cx('w-full rounded-md border px-2 py-2 font-mono text-sm', i === idx ? 'border-navy-900 bg-navy-900 text-white' : done.includes(l.id) ? 'border-ok-600 bg-ok-50 text-ok-600' : 'border-steel-200')}>{l.code}</button></li>
            ))}</ul>
          </details>
        </>
      ) : <Notice tone="info">{t('nothing_today')}</Notice>}
    </div>
  );
}

function BackLink({ id }: { id: string }) {
  return <Link href={`/stocktake/${id}`} className="rounded-md p-2 hover:bg-steel-100" aria-label="Back"><ChevronLeft className="size-5" /></Link>;
}

function SyncChip({ online, pending, failed, t }: { online: boolean; pending: number; failed: number; t: (k: Key) => string }) {
  const tt = t;
  if (failed) return <Badge tone="bad">{failed} !</Badge>;
  if (!online) return <Badge tone="warn"><CloudOff className="mr-1 inline size-3" />{pending}</Badge>;
  if (pending) return <Badge tone="info"><CloudUpload className="mr-1 inline size-3" />{tt('sending')}</Badge>;
  return <Badge tone="ok"><Wifi className="mr-1 inline size-3" />{tt('all_sent')}</Badge>;
}
