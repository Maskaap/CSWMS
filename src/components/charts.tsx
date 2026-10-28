'use client';
/**
 * Lightweight, dependency-free charts for the analytics screens.
 * Rules (see docs/ARCHITECTURE.md § Analytics): one y-axis, thin marks, hairline solid grid,
 * legend for ≥2 series, tooltips that never gate (every chart sits next to a table view),
 * text in text colours (never the series colour). Palette validated for CVD on a light surface.
 */
import { useEffect, useRef, useState, type ReactNode } from 'react';

export const SERIES = ['#2a78d6', '#eb6834', '#1baf7a'] as const;          // categorical slots 1–3, fixed order
export const ORDINAL = ['#86b6ef', '#5598e7', '#2a78d6', '#1c5cab', '#104281']; // blue ramp 250→650 (ordered buckets)
const GRID = '#e6e9ef';
const MUTED = '#5b6474';

export function compact(n: number): string {
  const a = Math.abs(n);
  if (a >= 1e9) return (n / 1e9).toFixed(a >= 1e10 ? 0 : 1).replace(/\.0$/, '') + 'B';
  if (a >= 1e6) return (n / 1e6).toFixed(a >= 1e7 ? 0 : 1).replace(/\.0$/, '') + 'M';
  if (a >= 1e3) return (n / 1e3).toFixed(a >= 1e4 ? 0 : 1).replace(/\.0$/, '') + 'K';
  return String(Math.round(n * 100) / 100);
}
function niceMax(v: number): number {
  if (v <= 0) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  const f = v / p;
  return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * p;
}
function useWidth<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  const [w, setW] = useState(300);
  useEffect(() => {
    if (!ref.current) return;
    const ro = new ResizeObserver((e) => setW(Math.max(260, Math.floor(e[0].contentRect.width))));
    ro.observe(ref.current);
    return () => ro.disconnect();
  }, []);
  return { ref, w };
}

export function Legend({ items, kind = 'line' }: { items: { label: string; color: string; dashed?: boolean }[]; kind?: 'line' | 'rect' }) {
  return (
    <ul className="mb-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-steel-600" aria-hidden>
      {items.map((i) => (
        <li key={i.label} className="flex items-center gap-1.5">
          {kind === 'line'
            ? <svg width="16" height="8"><line x1="1" y1="4" x2="15" y2="4" stroke={i.color} strokeWidth="2" strokeLinecap="round" strokeDasharray={i.dashed ? '3 3' : undefined} /></svg>
            : <span className="inline-block size-2.5 rounded-sm" style={{ background: i.color }} />}
          {i.label}
        </li>
      ))}
    </ul>
  );
}

type Series = { key: string; label: string; color: string; dashed?: boolean };

/** Multi-series line chart with a snapping crosshair + tooltip (keyboard: focus, then ← →). */
export function LineChart({ data, x, series, format, height = 220, area = false, title }: {
  data: Record<string, any>[]; x: (d: any) => string; series: Series[]; format: (n: number) => string; height?: number; area?: boolean; title: string;
}) {
  const { ref, w } = useWidth<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const padL = 48, padR = 12, padT = 8, axisH = 24;
  const plotH = height - axisH - padT, plotW = w - padL - padR;
  const max = niceMax(Math.max(0, ...data.flatMap((d) => series.map((s) => Number(d[s.key]) || 0))));
  const min = Math.min(0, ...data.flatMap((d) => series.map((s) => Number(d[s.key]) || 0)));
  const lo = min < 0 ? -niceMax(-min) : 0;
  const n = data.length;
  const xs = (i: number) => padL + (n <= 1 ? plotW / 2 : (i / (n - 1)) * plotW);
  const ys = (v: number) => padT + plotH - ((v - lo) / (max - lo)) * plotH;
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((t) => lo + t * (max - lo));
  const every = Math.max(1, Math.ceil(n / Math.max(2, Math.floor(plotW / 70))));
  const pick = (clientX: number, el: Element) => {
    const r = el.getBoundingClientRect();
    const i = Math.round(((clientX - r.left - padL) / plotW) * (n - 1));
    setHover(Math.min(n - 1, Math.max(0, i)));
  };
  if (n === 0) return <p className="text-sm text-steel-600">No data for this selection.</p>;
  return (
    <div ref={ref} className="relative w-full min-w-0 overflow-hidden">
      {series.length > 1 && <Legend items={series} />}
      <svg width={w} height={height} role="img" aria-label={title} tabIndex={0} className="block outline-none focus-visible:ring-2 focus-visible:ring-signal-400"
        onPointerMove={(e) => pick(e.clientX, e.currentTarget)} onPointerLeave={() => setHover(null)} onBlur={() => setHover(null)}
        onKeyDown={(e) => { if (e.key === 'ArrowRight') setHover((h) => Math.min(n - 1, (h ?? -1) + 1)); if (e.key === 'ArrowLeft') setHover((h) => Math.max(0, (h ?? n) - 1)); }}
        onFocus={() => setHover(n - 1)}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={padL} x2={w - padR} y1={ys(t)} y2={ys(t)} stroke={GRID} strokeWidth={1} />
            <text x={padL - 6} y={ys(t)} dy="0.32em" textAnchor="end" fontSize="11" fill={MUTED} style={{ fontVariantNumeric: 'tabular-nums' }}>{compact(t)}</text>
          </g>
        ))}
        {data.map((d, i) => ((i % every === 0 && (i === 0 || xs(n - 1) - xs(i) >= 64)) || i === n - 1) && (
          <text key={i} x={xs(i)} y={height - 6} textAnchor={i === 0 ? 'start' : i === n - 1 ? 'end' : 'middle'} fontSize="11" fill={MUTED}>{x(d)}</text>
        ))}
        {series.map((s) => {
          const pts = data.map((d, i) => `${xs(i)},${ys(Number(d[s.key]) || 0)}`);
          return (
            <g key={s.key}>
              {area && <path d={`M${xs(0)},${ys(0)} L${pts.join(' L')} L${xs(n - 1)},${ys(0)} Z`} fill={s.color} opacity={0.1} />}
              <polyline points={pts.join(' ')} fill="none" stroke={s.color} strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" strokeDasharray={s.dashed ? '4 4' : undefined} />
              <circle cx={xs(n - 1)} cy={ys(Number(data[n - 1][s.key]) || 0)} r={4} fill={s.color} stroke="#fff" strokeWidth={2} />
            </g>
          );
        })}
        {hover !== null && (
          <g>
            <line x1={xs(hover)} x2={xs(hover)} y1={padT} y2={padT + plotH} stroke={MUTED} strokeWidth={1} />
            {series.map((s) => <circle key={s.key} cx={xs(hover)} cy={ys(Number(data[hover][s.key]) || 0)} r={4} fill={s.color} stroke="#fff" strokeWidth={2} />)}
          </g>
        )}
      </svg>
      {hover !== null && (
        <div className="pointer-events-none absolute z-10 rounded-md border border-steel-200 bg-white px-3 py-2 text-xs shadow-lg"
          style={{ left: Math.min(xs(hover) + 12, w - 190), top: 24 }}>
          <div className="mb-1 font-medium text-navy-900">{x(data[hover])}</div>
          {series.map((s) => (
            <div key={s.key} className="flex items-center gap-2">
              <svg width="12" height="6"><line x1="1" y1="3" x2="11" y2="3" stroke={s.color} strokeWidth="2" strokeDasharray={s.dashed ? '3 2' : undefined} /></svg>
              <b className="tabular-nums text-navy-900">{format(Number(data[hover][s.key]) || 0)}</b><span className="text-steel-600">{s.label}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

/** Horizontal bars, one series (slot 1), value at the tip. */
export function BarList({ rows, format, max: maxRows = 10, onClick }: {
  rows: { key: string; label: ReactNode; value: number; title?: string }[]; format: (n: number) => string; max?: number; onClick?: (key: string) => void;
}) {
  const top = rows.slice(0, maxRows);
  const max = Math.max(1e-9, ...top.map((r) => Math.abs(r.value)));
  if (top.length === 0) return <p className="text-sm text-steel-600">No data for this selection.</p>;
  return (
    <ul className="space-y-1.5">
      {top.map((r) => (
        <li key={r.key} title={r.title ?? `${typeof r.label === 'string' ? r.label : ''}: ${format(r.value)}`}>
          <button type="button" disabled={!onClick} onClick={() => onClick?.(r.key)} className="grid w-full grid-cols-[minmax(0,11rem)_1fr] items-center gap-3 rounded text-left text-sm enabled:hover:bg-steel-50 sm:grid-cols-[minmax(0,15rem)_1fr]">
            <span className="truncate text-steel-800">{r.label}</span>
            <span className="flex items-center gap-2">
              <span className="h-4 rounded-r" style={{ width: `${Math.max(1, (Math.abs(r.value) / max) * 78)}%`, background: SERIES[0] }} />
              <span className="whitespace-nowrap text-xs font-medium tabular-nums text-navy-900">{format(r.value)}</span>
            </span>
          </button>
        </li>
      ))}
      {rows.length > maxRows && <li className="text-xs text-steel-600">+ {rows.length - maxRows} more in the table</li>}
    </ul>
  );
}

/** Columns for ordered buckets (e.g. age bands), blue ordinal ramp, value on the cap. */
export function Columns({ cols, format, height = 160 }: { cols: { label: string; value: number }[]; format: (n: number) => string; height?: number }) {
  const max = Math.max(1e-9, ...cols.map((c) => c.value));
  return (
    <div className="flex items-end gap-3" style={{ height: height + 36 }} role="img" aria-label={cols.map((c) => `${c.label}: ${format(c.value)}`).join('; ')}>
      {cols.map((c, i) => (
        <div key={c.label} className="flex flex-1 flex-col items-center justify-end gap-1" title={`${c.label}: ${format(c.value)}`}>
          <span className="text-xs font-medium tabular-nums text-navy-900">{format(c.value)}</span>
          <span className="w-full max-w-6 rounded-t" style={{ height: Math.max(1, (c.value / max) * height), background: ORDINAL[Math.min(i, ORDINAL.length - 1)] }} />
          <span className="whitespace-nowrap text-[11px] text-steel-600">{c.label}</span>
        </div>
      ))}
    </div>
  );
}

/** Tiny history + forecast line: solid = actual, dashed = projection. */
export function Sparkline({ history, forecast, width = 120, height = 28 }: { history: number[]; forecast?: number[]; width?: number; height?: number }) {
  const all = [...history, ...(forecast ?? [])];
  if (all.length < 2) return null;
  const max = Math.max(1e-9, ...all);
  const xs = (i: number) => 2 + (i / (all.length - 1)) * (width - 4);
  const ys = (v: number) => height - 3 - (v / max) * (height - 6);
  const h = history.map((v, i) => `${xs(i)},${ys(v)}`).join(' ');
  const f = forecast?.length ? [history.length - 1, ...forecast.map((_, j) => history.length + j)]
    .map((i) => `${xs(i)},${ys(all[i])}`).join(' ') : '';
  return (
    <svg width={width} height={height} aria-hidden>
      <polyline points={h} fill="none" stroke={SERIES[0]} strokeWidth={1.5} strokeLinejoin="round" />
      {f && <polyline points={f} fill="none" stroke={SERIES[1]} strokeWidth={1.5} strokeDasharray="3 2" />}
    </svg>
  );
}

/** Proportion bar for a few parts (e.g. A/B/C or movement classes), 2px surface gaps, legend below. */
export function PartsBar({ parts, format }: { parts: { label: string; value: number; color: string }[]; format: (n: number) => string }) {
  const tot = parts.reduce((s, p) => s + Math.max(0, p.value), 0);
  if (tot <= 0) return <p className="text-sm text-steel-600">No data for this selection.</p>;
  return (
    <div>
      <div className="flex h-4 w-full gap-[2px] overflow-hidden rounded">
        {parts.filter((p) => p.value > 0).map((p) => <span key={p.label} title={`${p.label}: ${format(p.value)}`} style={{ width: `${(p.value / tot) * 100}%`, background: p.color }} />)}
      </div>
      <ul className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-steel-600">
        {parts.map((p) => <li key={p.label} className="flex items-center gap-1.5"><span className="inline-block size-2.5 rounded-sm" style={{ background: p.color }} />{p.label} <b className="tabular-nums text-navy-900">{format(p.value)}</b></li>)}
      </ul>
    </div>
  );
}
