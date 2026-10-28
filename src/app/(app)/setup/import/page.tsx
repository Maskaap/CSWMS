'use client';
import Link from 'next/link';
import { Suspense, useMemo, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { Download, FileUp, Plus, Send, Trash2 } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, Dialog, Field, Input, Notice, PageHeader, Panel, Select, Spinner, StatusBadge, Table, Td, Th, cx } from '@/components/ui';
import { ActionResult, LoadError, Tabs, useConfirm } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useRows } from '@/hooks/use-rows';
import { exportXLSX } from '@/lib/export';
import { fmtDateTime } from '@/lib/format';

const FIELDS = [
  { key: 'sku', label: 'Stock code / SKU', required: true, aliases: ['sku', 'stock code', 'stockcode', 'item code', 'code', 'product code', 'part number', 'part no'] },
  { key: 'description', label: 'Description', required: true, aliases: ['description', 'product description', 'item', 'item description', 'name', 'product'] },
  { key: 'category', label: 'Category', aliases: ['category', 'group', 'product group'] },
  { key: 'subcategory', label: 'Subcategory', aliases: ['subcategory', 'sub category', 'sub-category'] },
  { key: 'uom', label: 'Unit of measure', required: true, aliases: ['uom', 'unit', 'unit of measure', 'units'] },
  { key: 'qty', label: 'Opening quantity', required: true, aliases: ['qty', 'quantity', 'opening qty', 'opening quantity', 'on hand', 'stock', 'balance', 'count'] },
  { key: 'warehouse', label: 'Warehouse code', required: true, aliases: ['warehouse', 'warehouse code', 'store', 'depot'] },
  { key: 'location', label: 'Storage location', aliases: ['location', 'bin', 'shelf', 'storage location', 'bin location'] },
  { key: 'company', label: 'Owning company code', aliases: ['company', 'owner', 'owning company', 'company code'] },
  { key: 'branch', label: 'Branch code', aliases: ['branch', 'branch code', 'site'] },
  { key: 'barcode', label: 'Barcode', aliases: ['barcode', 'ean', 'qr', 'bar code'] },
  { key: 'pack_uom', label: 'Pack unit', aliases: ['pack uom', 'pack unit', 'pack', 'case unit'] },
  { key: 'pack_factor', label: 'Units per pack', aliases: ['pack factor', 'pack size', 'units per pack', 'per pack', 'conversion'] },
  { key: 'min_qty', label: 'Minimum quantity', aliases: ['min', 'min qty', 'minimum', 'minimum qty', 'minimum stock'] },
  { key: 'reorder_qty', label: 'Reorder quantity', aliases: ['reorder', 'reorder qty', 'reorder quantity'] },
  { key: 'supplier', label: 'Supplier', aliases: ['supplier', 'vendor'] },
  { key: 'purchase_price', label: 'Purchase price (ZAR)', aliases: ['price', 'cost', 'purchase price', 'unit cost', 'unit price'] },
  { key: 'is_asset', label: 'Reusable asset (yes/no)', aliases: ['asset', 'is asset', 'reusable', 'tool'] },
] as const;
type Key = (typeof FIELDS)[number]['key'];
type Row = Partial<Record<Key, string>> & { _row?: number };
type IRow = { id: string; row_no: number; excluded: boolean; errors: string[]; warnings: string[] } & Record<Key, string | null>;
type Batch = { id: string; batch_no: string; source: string; file_name: string | null; status: string; row_count: number; error_count: number; warning_count: number; created_at: string; created_by: string; decision_note: string | null; approval_id: string | null };

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

function parseCSV(text: string): string[][] {
  const out: string[][] = []; let row: string[] = []; let cur = ''; let q = false;
  const delim = (text.split('\n')[0].match(/;/g)?.length ?? 0) > (text.split('\n')[0].match(/,/g)?.length ?? 0) ? ';' : ',';
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"' && text[i + 1] === '"') { cur += '"'; i++; } else if (c === '"') q = false; else cur += c; }
    else if (c === '"') q = true;
    else if (c === delim) { row.push(cur); cur = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cur); out.push(row); row = []; cur = ''; }
    else cur += c;
  }
  if (cur !== '' || row.length) { row.push(cur); out.push(row); }
  return out.filter((r) => r.some((x) => x.trim() !== ''));
}

async function parseFile(file: File): Promise<string[][]> {
  if (/\.csv$/i.test(file.name)) return parseCSV((await file.text()).replace(/^﻿/, ''));
  const ExcelJS = (await import('exceljs')).default;
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(await file.arrayBuffer());
  const ws = wb.worksheets[0];
  const rows: string[][] = [];
  ws.eachRow({ includeEmpty: false }, (r) => {
    const vals = (r.values as unknown[]).slice(1).map((v) => {
      if (v === null || v === undefined) return '';
      if (typeof v === 'object') { const o = v as { text?: string; result?: unknown; richText?: { text: string }[] }; return String(o.result ?? o.text ?? o.richText?.map((t) => t.text).join('') ?? ''); }
      return String(v);
    });
    rows.push(vals);
  });
  return rows;
}

async function sha256(file: File) {
  const buf = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function ImportInner() {
  const sp = useSearchParams();
  const router = useRouter();
  const { can } = useApp();
  const batchId = sp.get('batch');
  const batches = useRows<Batch>('batches' + batchId, (sb) => sb.from('import_batches').select('*').order('created_at', { ascending: false }).limit(50));
  if (!can('import.manage') && !can('import.approve')) return <PageHeader title="Opening stock import" description="You do not have permission to import stock." />;
  return (
    <>
      <PageHeader title="Initial inventory setup" description="Load existing stock as approved, auditable opening-balance transactions — by Excel/CSV upload or manual entry. Nothing is posted until the batch is validated, submitted and approved by a second person." />
      {batchId ? <BatchView id={batchId} onBack={() => router.push('/setup/import')} /> : (
        <div className="space-y-6">
          {can('import.manage') && <NewBatch onCreated={(id) => router.push(`/setup/import?batch=${id}`)} />}
          <Panel title="Import batches" padded={false}>
            <LoadError error={batches.error} />
            <Table className="rounded-none border-0">
              <thead><tr><Th>Batch</Th><Th>Source</Th><Th>Status</Th><Th right>Rows</Th><Th right>Errors</Th><Th right>Warnings</Th><Th>Created</Th></tr></thead>
              <tbody>{batches.rows.map((b) => (
                <tr key={b.id}><Td><Link className="font-mono text-[13px] font-semibold hover:underline" href={`/setup/import?batch=${b.id}`}>{b.batch_no}</Link><div className="text-xs text-steel-600">{b.file_name}</div></Td>
                  <Td>{b.source}</Td><Td><StatusBadge status={b.status} /></Td><Td right>{b.row_count}</Td><Td right className={b.error_count ? 'text-bad-600' : ''}>{b.error_count}</Td><Td right>{b.warning_count}</Td><Td className="text-xs">{fmtDateTime(b.created_at)}</Td></tr>
              ))}
                {batches.rows.length === 0 && <tr><Td className="text-steel-600">No imports yet.</Td></tr>}</tbody>
            </Table>
          </Panel>
        </div>
      )}
    </>
  );
}

function NewBatch({ onCreated }: { onCreated: (id: string) => void }) {
  const [mode, setMode] = useState<'file' | 'manual'>('file');
  const [file, setFile] = useState<File | null>(null);
  const [grid, setGrid] = useState<string[][] | null>(null);
  const [map, setMap] = useState<Record<Key, number | -1>>({} as Record<Key, number>);
  const [manual, setManual] = useState<Row[]>([{}]);
  const [parseErr, setParseErr] = useState<string | null>(null);
  const act = useAction();

  const onFile = async (f: File | null) => {
    setFile(f); setGrid(null); setParseErr(null); act.clear();
    if (!f) return;
    if (f.size > 15 * 1024 * 1024) { setParseErr('File is larger than 15 MB. Split it.'); return; }
    try {
      const g = await parseFile(f);
      if (g.length < 2) { setParseErr('The file needs a header row and at least one data row.'); return; }
      const headers = g[0].map((h) => norm(h));
      const m = {} as Record<Key, number>;
      for (const fd of FIELDS) m[fd.key] = headers.findIndex((h) => (fd.aliases as readonly string[]).includes(h));
      setMap(m); setGrid(g);
    } catch (e) { setParseErr(`The file could not be read: ${(e as Error).message}. Save it as .xlsx or .csv.`); }
  };

  const rows: Row[] = useMemo(() => {
    if (!grid) return [];
    return grid.slice(1).map((r, i) => {
      const o: Row = { _row: i + 2 };
      for (const fd of FIELDS) { const ix = map[fd.key]; if (ix !== undefined && ix >= 0) { const v = (r[ix] ?? '').trim(); if (v !== '') o[fd.key] = v; } }
      return o;
    });
  }, [grid, map]);
  const missingRequired = FIELDS.filter((f) => 'required' in f && f.required && (map[f.key] === undefined || map[f.key] < 0));

  const template = () => exportXLSX('CSWMS opening stock template', FIELDS.map((f) => ({ key: f.key, label: f.label })), [
    { sku: 'TAPE-48', description: 'Packaging tape 48mm', category: 'Packaging', subcategory: '', uom: 'ROLL', qty: '120', warehouse: 'CPT-MAIN', location: 'A-01', company: '', branch: '', barcode: '6001234567890', pack_uom: 'BOX', pack_factor: '36', min_qty: '30', reorder_qty: '100', supplier: 'Tape Co', purchase_price: '18.50', is_asset: 'no' },
  ], 'Fill one row per product per storage location. Delete this example row. Codes must already exist in Setup (warehouse, location, company, unit).');

  return (
    <Panel title="Start a new opening-balance batch">
      <Tabs value={mode} onChange={setMode} tabs={[{ id: 'file', label: 'Method B — Excel / CSV upload' }, { id: 'manual', label: 'Method A — Manual entry' }]} />
      {mode === 'file' ? (
        <div className="space-y-4">
          <div className="flex flex-wrap items-center gap-3">
            <label className="inline-flex cursor-pointer items-center gap-2 rounded-md border-2 border-dashed border-navy-700 bg-steel-50 px-4 py-3 text-sm font-medium text-navy-900">
              <FileUp className="size-5" />{file ? file.name : 'Choose .xlsx or .csv file'}
              <input type="file" accept=".xlsx,.csv" className="sr-only" onChange={(e) => onFile(e.target.files?.[0] ?? null)} />
            </label>
            <Button size="sm" onClick={template}><Download className="size-4" />Download template</Button>
          </div>
          {parseErr && <Notice tone="bad">{parseErr}</Notice>}
          {grid && (
            <>
              <div>
                <h3 className="mb-2 text-sm font-semibold text-navy-900">Match your columns ({rows.length} data rows found)</h3>
                <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
                  {FIELDS.map((f) => (
                    <Field key={f.key} label={f.label} required={'required' in f && f.required}>
                      <Select value={String(map[f.key] ?? -1)} onChange={(e) => setMap({ ...map, [f.key]: Number(e.target.value) })} className={cx('required' in f && f.required && (map[f.key] ?? -1) < 0 && 'border-bad-600')}>
                        <option value="-1">— not in file —</option>{grid[0].map((h, i) => <option key={i} value={i}>{h || `Column ${i + 1}`}</option>)}
                      </Select>
                    </Field>
                  ))}
                </div>
              </div>
              <div>
                <h3 className="mb-2 text-sm font-semibold text-navy-900">First rows as they will be imported</h3>
                <Table><thead><tr><Th>Row</Th>{FIELDS.filter((f) => (map[f.key] ?? -1) >= 0).map((f) => <Th key={f.key}>{f.label}</Th>)}</tr></thead>
                  <tbody>{rows.slice(0, 8).map((r) => <tr key={r._row}><Td>{r._row}</Td>{FIELDS.filter((f) => (map[f.key] ?? -1) >= 0).map((f) => <Td key={f.key}>{r[f.key]}</Td>)}</tr>)}</tbody></Table>
              </div>
              {missingRequired.length > 0 && <Notice tone="warn">Map the required columns: {missingRequired.map((f) => f.label).join(', ')}.</Notice>}
              <ActionResult error={act.error} />
              <Button variant="primary" disabled={!file || missingRequired.length > 0 || rows.length === 0} busy={act.busy} onClick={async () => {
                const hash = await sha256(file!);
                const r = await act.run<{ batch_id: string }>('import_create_batch', { p_source: 'file', p_rows: rows, p_file_name: file!.name, p_file_sha256: hash });
                if (r) onCreated(r.batch_id);
              }}>Upload and validate {rows.length} rows</Button>
              <p className="text-xs text-steel-600">The same file can never be imported twice (it is fingerprinted), and products that already have an opening balance at a location are rejected.</p>
            </>
          )}
        </div>
      ) : (
        <div className="space-y-3">
          <p className="text-sm text-steel-600">Enter one line per product per storage location. Codes must exist under Setup. Rows are validated on the server exactly like an upload.</p>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead><tr>{(['sku', 'description', 'category', 'uom', 'qty', 'warehouse', 'location', 'company', 'barcode', 'min_qty'] as Key[]).map((k) => <th key={k} className="px-1 text-left text-xs text-steel-600">{FIELDS.find((f) => f.key === k)?.label}</th>)}<th /></tr></thead>
              <tbody>{manual.map((r, i) => (
                <tr key={i}>{(['sku', 'description', 'category', 'uom', 'qty', 'warehouse', 'location', 'company', 'barcode', 'min_qty'] as Key[]).map((k) => (
                  <td key={k} className="p-1"><Input value={r[k] ?? ''} onChange={(e) => setManual(manual.map((x, j) => (j === i ? { ...x, [k]: e.target.value } : x)))} className={cx('h-9', ['sku', 'uom', 'warehouse', 'location', 'company'].includes(k) && 'font-mono uppercase', k === 'description' && 'min-w-56')} /></td>
                ))}<td><button aria-label="Remove row" onClick={() => setManual(manual.filter((_, j) => j !== i))} className="p-2 text-bad-600"><Trash2 className="size-4" /></button></td></tr>
              ))}</tbody>
            </table>
          </div>
          <Button size="sm" onClick={() => setManual([...manual, { warehouse: manual.at(-1)?.warehouse, company: manual.at(-1)?.company }])}><Plus className="size-4" />Add row</Button>
          <ActionResult error={act.error} />
          <div><Button variant="primary" busy={act.busy} disabled={!manual.some((r) => r.sku)} onClick={async () => {
            const clean = manual.filter((r) => r.sku?.trim()).map((r, i) => ({ ...Object.fromEntries(Object.entries(r).map(([k, v]) => [k, typeof v === 'string' ? (['sku', 'uom', 'warehouse', 'location', 'company', 'branch'].includes(k) ? v.trim().toUpperCase() : v.trim()) : v])), _row: i + 1 }));
            const r = await act.run<{ batch_id: string }>('import_create_batch', { p_source: 'manual', p_rows: clean, p_file_name: 'Manual entry' });
            if (r) onCreated(r.batch_id);
          }}>Validate {manual.filter((r) => r.sku).length} rows</Button></div>
        </div>
      )}
    </Panel>
  );
}

function BatchView({ id, onBack }: { id: string; onBack: () => void }) {
  const { me } = useApp();
  const batch = useRows<Batch>('b' + id, (sb) => sb.from('import_batches').select('*').eq('id', id).maybeSingle());
  const rows = useRows<IRow>('r' + id, (sb) => sb.from('import_rows').select('*').eq('batch_id', id).order('row_no'));
  const act = useAction();
  const confirm = useConfirm();
  const [filter, setFilter] = useState<'all' | 'errors' | 'warnings'>('errors');
  const [edit, setEdit] = useState<IRow | null>(null);
  const b = batch.rows[0];
  const reload = () => { batch.reload(); rows.reload(); };
  if (batch.loading) return <Spinner />;
  if (!b) return <Notice tone="bad">Import batch not found.</Notice>;
  const editable = b.status === 'draft';
  const active = rows.rows.filter((r) => !r.excluded);
  const errs = active.filter((r) => r.errors?.length).length;
  const shown = rows.rows.filter((r) => filter === 'all' || (filter === 'errors' ? r.errors?.length : r.warnings?.length));

  return (
    <div className="space-y-4">
      {confirm.node}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div><button onClick={onBack} className="text-sm underline">← All batches</button>
          <h2 className="text-lg font-semibold text-navy-900">{b.batch_no} <StatusBadge status={b.status} /></h2>
          <p className="text-sm text-steel-600">{b.file_name} · {active.length} rows included · <span className={errs ? 'text-bad-600' : 'text-ok-600'}>{errs} with errors</span> · {active.filter((r) => r.warnings?.length).length} with warnings</p></div>
        {editable && <div className="flex gap-2">
          <Button busy={act.busy} onClick={async () => { if (await act.run('import_revalidate', { p_batch_id: id }, 'Re-validated against current data.')) reload(); }}>Re-validate</Button>
          <Button variant="danger" busy={act.busy} onClick={async () => { const c = await confirm.ask({ title: 'Cancel this import?', body: 'Nothing will be posted.', danger: true }); if (c && await act.run('import_cancel', { p_batch_id: id }, 'Import cancelled.')) reload(); }}>Cancel import</Button>
          <Button variant="primary" disabled={errs > 0 || active.length === 0} busy={act.busy} onClick={async () => {
            const c = await confirm.ask({ title: 'Submit opening balances for approval?', body: `${active.length} rows will be posted as opening-balance transactions once a different authorised person approves them. Review the warnings first.` });
            if (c && await act.run('import_submit', { p_batch_id: id }, 'Submitted for approval. A second person must approve under Approvals.')) reload();
          }}><Send className="size-4" />Submit for approval</Button>
        </div>}
      </div>
      {b.status === 'pending_approval' && <Notice tone="warn" title="Waiting for approval">{b.created_by === me?.user?.id ? 'Another authorised person must approve it.' : <Link className="underline" href="/approvals">Review and approve under Approvals</Link>}</Notice>}
      {b.status === 'posted' && <Notice tone="ok" title="Posted">Opening balances were posted as auditable transactions.</Notice>}
      {errs > 0 && editable && <Notice tone="bad" title="Correct the errors before submitting">Edit a row to fix it, or exclude it to load it later.</Notice>}
      <ActionResult error={act.error} ok={act.ok} />
      <Tabs value={filter} onChange={setFilter} tabs={[{ id: 'errors', label: `Errors (${rows.rows.filter((r) => r.errors?.length).length})` }, { id: 'warnings', label: `Warnings (${rows.rows.filter((r) => r.warnings?.length).length})` }, { id: 'all', label: `All rows (${rows.rows.length})` }]} />
      {rows.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>Row</Th><Th>SKU</Th><Th>Description</Th><Th>Unit</Th><Th right>Qty</Th><Th>Warehouse / location</Th><Th>Owner</Th><Th>Problems</Th><Th /></tr></thead>
          <tbody>{shown.map((r) => (
            <tr key={r.id} className={cx(r.excluded && 'opacity-50', r.errors?.length && !r.excluded && 'bg-bad-50')}>
              <Td>{r.row_no}</Td><Td mono>{r.sku}</Td><Td>{r.description}</Td><Td>{r.uom}</Td><Td right>{r.qty}</Td><Td>{r.warehouse}{r.location ? ` / ${r.location}` : ''}</Td><Td>{r.company}</Td>
              <Td>{(r.errors ?? []).map((e, i) => <div key={i} className="text-xs text-bad-600">✖ {e}</div>)}{(r.warnings ?? []).map((w, i) => <div key={i} className="text-xs text-warn-600">⚠ {w}</div>)}{r.excluded && <Badge>excluded</Badge>}</Td>
              <Td className="whitespace-nowrap">{editable && <><Button size="sm" variant="ghost" onClick={() => setEdit(r)}>Edit</Button>
                <Button size="sm" variant="ghost" onClick={async () => { if (await act.run('import_set_excluded', { p_batch_id: id, p_row_id: r.id, p_excluded: !r.excluded })) reload(); }}>{r.excluded ? 'Include' : 'Exclude'}</Button></>}</Td>
            </tr>
          ))}
            {shown.length === 0 && <tr><Td className="text-steel-600">Nothing to show.</Td></tr>}</tbody>
        </Table>
      )}
      {edit && <RowDialog row={edit} onClose={() => setEdit(null)} onSave={async (vals) => { if (await act.run('import_update_row', { p_batch_id: id, p_row_id: edit.id, p_values: vals }, `Row ${edit.row_no} updated and re-validated.`)) { setEdit(null); reload(); } }} />}
    </div>
  );
}

function RowDialog({ row, onClose, onSave }: { row: IRow; onClose: () => void; onSave: (v: Record<string, string>) => void }) {
  const [v, setV] = useState<Record<string, string>>(Object.fromEntries(FIELDS.map((f) => [f.key, row[f.key] ?? ''])));
  return (
    <Dialog open wide onClose={onClose} title={`Correct row ${row.row_no}`} footer={<><Button onClick={onClose}>Cancel</Button><Button variant="primary" onClick={() => onSave(v)}>Save & re-validate</Button></>}>
      {(row.errors ?? []).map((e, i) => <p key={i} className="mb-1 text-sm text-bad-600">✖ {e}</p>)}
      <div className="mt-2 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {FIELDS.map((f) => <Field key={f.key} label={f.label}><Input value={v[f.key]} onChange={(e) => setV({ ...v, [f.key]: e.target.value })} /></Field>)}
      </div>
    </Dialog>
  );
}

export default function ImportPage() {
  return <Suspense fallback={<Spinner />}><ImportInner /></Suspense>;
}
