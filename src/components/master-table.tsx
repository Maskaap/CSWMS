'use client';
import { useState, type ReactNode } from 'react';
import { Pencil, Plus } from 'lucide-react';
import { supabaseBrowser } from '@/lib/supabase/client';
import { toAppError } from '@/lib/errors';
import { Badge, Button, Dialog, Field, Input, Notice, Select, Spinner, Table, Td, Th, Textarea } from './ui';

export type FieldDef = {
  key: string; label: string; type?: 'text' | 'number' | 'select' | 'checkbox' | 'textarea' | 'status';
  options?: { value: string; label: string }[]; required?: boolean; upper?: boolean; immutable?: boolean; hint?: string;
  show?: (row: Record<string, any>) => ReactNode; hideInTable?: boolean; placeholder?: string; defaultValue?: unknown;
};

const STATUS_OPTS = [{ value: 'active', label: 'Active' }, { value: 'inactive', label: 'Inactive' }, { value: 'archived', label: 'Archived' }];

/**
 * Simple create / edit table for master data. Writes go straight to the table
 * through the user's session; RLS decides whether the user may write, the
 * database validates codes and records every change in the audit log.
 * Records are deactivated, never deleted.
 */
export function MasterTable({ table, rows, loading, fields, onChanged, canEdit, title, extraActions, defaults }: {
  table: string; rows: Record<string, any>[]; loading: boolean; fields: FieldDef[]; onChanged: () => void; canEdit: boolean; title: string;
  extraActions?: (row: Record<string, any>) => ReactNode; defaults?: Record<string, unknown>;
}) {
  const [edit, setEdit] = useState<Record<string, any> | null>(null);
  const cols = fields.filter((f) => !f.hideInTable);
  return (
    <>
      <div className="mb-3 flex justify-between gap-2">
        <h2 className="text-base font-semibold text-navy-900">{title} <span className="text-sm font-normal text-steel-600">({rows.length})</span></h2>
        {canEdit && <Button size="sm" variant="primary" onClick={() => setEdit({ ...Object.fromEntries(fields.filter((f) => f.defaultValue !== undefined).map((f) => [f.key, f.defaultValue])), status: 'active', ...defaults })}><Plus className="size-4" />Add</Button>}
      </div>
      {loading ? <Spinner /> : (
        <Table>
          <thead><tr>{cols.map((f) => <Th key={f.key}>{f.label}</Th>)}<Th /></tr></thead>
          <tbody>{rows.map((r) => (
            <tr key={r.id} className={r.status && r.status !== 'active' ? 'opacity-60' : ''}>
              {cols.map((f) => (
                <Td key={f.key} mono={f.upper}>
                  {f.show ? f.show(r) : f.type === 'status' ? <Badge tone={r.status === 'active' ? 'ok' : 'idle'}>{r.status}</Badge>
                    : f.type === 'checkbox' ? (r[f.key] ? 'Yes' : '') : f.type === 'select' ? (f.options?.find((o) => o.value === r[f.key])?.label ?? '—') : String(r[f.key] ?? '')}
                </Td>
              ))}
              <Td className="whitespace-nowrap">{canEdit && <Button size="sm" variant="ghost" onClick={() => setEdit(r)}><Pencil className="size-4" />Edit</Button>}{extraActions?.(r)}</Td>
            </tr>
          ))}
            {rows.length === 0 && <tr><Td className="text-steel-600">Nothing set up yet.</Td></tr>}</tbody>
        </Table>
      )}
      {edit && <EditDialog table={table} row={edit} fields={fields} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); onChanged(); }} />}
    </>
  );
}

function EditDialog({ table, row, fields, onClose, onSaved }: { table: string; row: Record<string, any>; fields: FieldDef[]; onClose: () => void; onSaved: () => void }) {
  const isNew = !row.id;
  const [v, setV] = useState<Record<string, any>>(row);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const save = async () => {
    for (const f of fields) if (f.required && (v[f.key] === undefined || v[f.key] === null || String(v[f.key]).trim() === '')) { setErr(`${f.label} is required`); return; }
    setBusy(true); setErr(null);
    const payload: Record<string, unknown> = {};
    for (const f of fields) {
      if (!isNew && f.immutable) continue;
      let x = v[f.key];
      if (typeof x === 'string') { x = x.trim(); if (f.upper) x = (x as string).toUpperCase(); if (x === '') x = null; }
      if (f.type === 'number' && x !== null && x !== undefined) x = Number(x);
      if (f.type === 'checkbox') x = !!x;
      payload[f.key] = x;
    }
    const sb = supabaseBrowser();
    const { error } = isNew ? await sb.from(table).insert(payload) : await sb.from(table).update(payload).eq('id', row.id);
    setBusy(false);
    if (error) {
      const e = toAppError(error);
      setErr(/duplicate key/.test(e.message) ? 'That code already exists.' : /check constraint/.test(e.message) ? 'A value is not in the required format (codes: capitals, digits, - and _ only).' : /row-level security/.test(e.message) ? 'You do not have permission to change this.' : e.message);
      return;
    }
    onSaved();
  };
  return (
    <Dialog open onClose={onClose} title={isNew ? 'Add' : 'Edit'} footer={<><Button onClick={onClose}>Cancel</Button><Button variant="primary" busy={busy} onClick={save}>Save</Button></>}>
      <div className="space-y-3">
        {fields.map((f) => {
          const dis = !isNew && f.immutable;
          const val = v[f.key] ?? '';
          const set = (x: unknown) => setV({ ...v, [f.key]: x });
          return (
            <Field key={f.key} label={f.label} required={f.required} hint={dis ? 'Cannot be changed after creation (it is printed on labels and used in history).' : f.hint}>
              {f.type === 'select' ? <Select value={val} onChange={(e) => set(e.target.value || null)} disabled={dis}><option value="">—</option>{f.options?.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</Select>
                : f.type === 'status' ? <Select value={val || 'active'} onChange={(e) => set(e.target.value)}>{STATUS_OPTS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</Select>
                : f.type === 'checkbox' ? <input type="checkbox" checked={!!v[f.key]} onChange={(e) => set(e.target.checked)} disabled={dis} />
                : f.type === 'textarea' ? <Textarea value={val} onChange={(e) => set(e.target.value)} disabled={dis} rows={2} />
                : <Input value={val} type={f.type === 'number' ? 'number' : 'text'} onChange={(e) => set(e.target.value)} disabled={dis} placeholder={f.placeholder} className={f.upper ? 'font-mono uppercase' : ''} />}
            </Field>
          );
        })}
        {err && <Notice tone="bad">{err}</Notice>}
      </div>
    </Dialog>
  );
}
