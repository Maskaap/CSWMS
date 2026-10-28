'use client';
import Link from 'next/link';
import { useState, type ReactNode } from 'react';
import { Download, FileSpreadsheet, FileText } from 'lucide-react';
import type { AppError } from '@/lib/errors';
import { exportCSV, exportPDF, exportXLSX, type Col } from '@/lib/export';
import { Button, Notice, cx } from './ui';

export function Tabs<T extends string>({ tabs, value, onChange }: { tabs: { id: T; label: ReactNode; hidden?: boolean }[]; value: T; onChange: (v: T) => void }) {
  return (
    <div className="mb-4 flex gap-1 overflow-x-auto border-b border-steel-200" role="tablist">
      {tabs.filter((t) => !t.hidden).map((t) => (
        <button key={t.id} role="tab" aria-selected={value === t.id} onClick={() => onChange(t.id)}
          className={cx('-mb-px whitespace-nowrap border-b-2 px-3 py-2 text-sm font-medium',
            value === t.id ? 'border-signal-400 text-navy-900' : 'border-transparent text-steel-600 hover:text-navy-900')}>
          {t.label}
        </button>
      ))}
    </div>
  );
}

export function ExportButtons<T>({ title, cols, rows, disabled }: { title: string; cols: Col<T>[]; rows: T[]; disabled?: boolean }) {
  const [busy, setBusy] = useState<string | null>(null);
  const go = async (kind: 'csv' | 'xlsx' | 'pdf') => {
    setBusy(kind);
    try {
      if (kind === 'csv') exportCSV(title, cols, rows);
      else if (kind === 'xlsx') await exportXLSX(title, cols, rows);
      else await exportPDF(title, cols, rows);
    } finally { setBusy(null); }
  };
  const off = disabled || rows.length === 0;
  return (
    <div className="flex flex-wrap gap-2">
      <Button size="sm" onClick={() => go('xlsx')} disabled={off} busy={busy === 'xlsx'}><FileSpreadsheet className="size-4" />Excel</Button>
      <Button size="sm" onClick={() => go('csv')} disabled={off} busy={busy === 'csv'}><Download className="size-4" />CSV</Button>
      <Button size="sm" onClick={() => go('pdf')} disabled={off} busy={busy === 'pdf'}><FileText className="size-4" />PDF</Button>
    </div>
  );
}

export function ActionResult({ error, ok }: { error: AppError | null; ok?: string | null }) {
  if (error) return <Notice tone="bad" title="Not done">{error.message}</Notice>;
  if (ok) return <Notice tone="ok">{ok}</Notice>;
  return null;
}

export function LoadError({ error }: { error: string | null }) {
  return error ? <Notice tone="bad" title="Could not load">{error}</Notice> : null;
}

export function TxnLink({ id, no }: { id: string | null | undefined; no: string | null | undefined }) {
  if (!id) return <span>—</span>;
  return <Link href={`/transactions/${id}`} className="font-mono text-[13px] text-navy-800 underline-offset-2 hover:underline">{no ?? 'view'}</Link>;
}

export function KV({ items }: { items: [ReactNode, ReactNode][] }) {
  return (
    <dl className="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
      {items.map(([k, v], i) => (
        <div key={i} className="min-w-0">
          <dt className="text-xs text-steel-600">{k}</dt>
          <dd className="break-words font-medium text-navy-900">{v ?? '—'}</dd>
        </div>
      ))}
    </dl>
  );
}

export function Filters({ children }: { children: ReactNode }) {
  return <div className="mb-4 grid gap-3 rounded-lg border border-steel-200 bg-white p-3 sm:grid-cols-2 lg:grid-cols-4">{children}</div>;
}

/** Confirmation dialog for high-risk actions — the user must type a note when required. */
export function useConfirm() {
  const [state, setState] = useState<{ title: string; body: ReactNode; noteLabel?: string; noteRequired?: boolean; danger?: boolean; resolve: (v: { note: string } | null) => void } | null>(null);
  const ask = (o: { title: string; body: ReactNode; noteLabel?: string; noteRequired?: boolean; danger?: boolean }) =>
    new Promise<{ note: string } | null>((resolve) => setState({ ...o, resolve }));
  const node = state ? <ConfirmDialog {...state} onDone={(v) => { state.resolve(v); setState(null); }} /> : null;
  return { ask, node };
}

import { Dialog, Field, Textarea } from './ui';
function ConfirmDialog({ title, body, noteLabel, noteRequired, danger, onDone }: {
  title: string; body: ReactNode; noteLabel?: string; noteRequired?: boolean; danger?: boolean; onDone: (v: { note: string } | null) => void;
}) {
  const [note, setNote] = useState('');
  return (
    <Dialog open onClose={() => onDone(null)} title={title}
      footer={<>
        <Button onClick={() => onDone(null)}>Cancel</Button>
        <Button variant={danger ? 'danger' : 'navy'} disabled={!!noteRequired && note.trim() === ''} onClick={() => onDone({ note: note.trim() })}>Confirm</Button>
      </>}>
      <div className="space-y-3 text-sm">
        <div>{body}</div>
        {noteLabel && <Field label={noteLabel} required={noteRequired}><Textarea value={note} onChange={(e) => setNote(e.target.value)} rows={3} autoFocus /></Field>}
      </div>
    </Dialog>
  );
}
