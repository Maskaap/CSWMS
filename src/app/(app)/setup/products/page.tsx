'use client';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Plus } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, Dialog, Field, Input, Notice, PageHeader, Select, Spinner, Table, Td, Textarea, Th } from '@/components/ui';
import { ExportButtons, LoadError } from '@/components/widgets';
import { useRows } from '@/hooks/use-rows';
import { supabaseBrowser } from '@/lib/supabase/client';
import { toAppError } from '@/lib/errors';
import { cleanSearch } from '@/lib/format';

type P = { id: string; sku: string; description: string; status: string; is_asset: boolean; category_id: string | null; uoms: { code: string } | null; categories: { name: string } | null; suppliers: { name: string } | null; barcodes: { code: string }[] };

export default function ProductsPage() {
  const { can } = useApp();
  const [q, setQ] = useState('');
  const [dq, setDq] = useState('');
  const [adding, setAdding] = useState(false);
  useEffect(() => { const t = setTimeout(() => setDq(cleanSearch(q)), 300); return () => clearTimeout(t); }, [q]);
  const list = useRows<P>('prod' + dq, (sb) => {
    let x = sb.from('products').select('id, sku, description, status, is_asset, category_id, uoms(code), categories(name), suppliers(name), barcodes(code)').order('sku').limit(1000);
    if (dq) x = x.or(`sku.ilike.%${dq}%,description.ilike.%${dq}%`);
    return x;
  });
  return (
    <>
      <PageHeader title="Products" description="Stock items, barcodes, pack conversions and minimum levels. New opening stock is loaded through the Opening stock import (manual or Excel)."
        actions={<>
          <ExportButtons title="Product list" rows={list.rows} cols={[{ key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'category', label: 'Category', get: (r) => r.categories?.name },
            { key: 'uom', label: 'Base unit', get: (r) => r.uoms?.code }, { key: 'supplier', label: 'Supplier', get: (r) => r.suppliers?.name }, { key: 'barcodes', label: 'Barcodes', get: (r) => r.barcodes.map((b) => b.code).join(' ') },
            { key: 'status', label: 'Status' }, { key: 'is_asset', label: 'Asset', get: (r) => (r.is_asset ? 'Yes' : '') }]} />
          {can('product.manage') && <Button variant="primary" onClick={() => setAdding(true)}><Plus className="size-4" />New product</Button>}
        </>} />
      <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search SKU or description" className="mb-3 max-w-md" />
      <LoadError error={list.error} />
      {list.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>SKU</Th><Th>Description</Th><Th>Category</Th><Th>Unit</Th><Th>Barcodes</Th><Th>Status</Th></tr></thead>
          <tbody>{list.rows.map((p) => (
            <tr key={p.id} className="hover:bg-steel-50"><Td mono><Link className="font-semibold hover:underline" href={`/setup/products/${p.id}`}>{p.sku}</Link></Td><Td>{p.description}{p.is_asset && <Badge tone="info" className="ml-1">asset</Badge>}</Td>
              <Td>{p.categories?.name ?? '—'}</Td><Td>{p.uoms?.code}</Td><Td className="font-mono text-xs">{p.barcodes.map((b) => b.code).join(', ') || <span className="font-sans text-warn-600">none</span>}</Td>
              <Td><Badge tone={p.status === 'active' ? 'ok' : 'idle'}>{p.status}</Badge></Td></tr>
          ))}
            {list.rows.length === 0 && <tr><Td className="text-steel-600">No products.</Td></tr>}</tbody>
        </Table>
      )}
      {adding && <NewProduct onClose={() => setAdding(false)} />}
    </>
  );
}

function NewProduct({ onClose }: { onClose: () => void }) {
  const router = useRouter();
  const uoms = useRows<{ id: string; code: string; name: string }>('uoms', (sb) => sb.from('uoms').select('id, code, name').eq('status', 'active').order('code'));
  const cats = useRows<{ id: string; name: string; parent_id: string | null }>('cats', (sb) => sb.from('categories').select('id, name, parent_id').eq('status', 'active').order('name'));
  const sups = useRows<{ id: string; name: string }>('sups', (sb) => sb.from('suppliers').select('id, name').eq('status', 'active').order('name'));
  const [v, setV] = useState({ sku: '', description: '', base_uom_id: '', category_id: '', default_supplier_id: '', is_asset: false, notes: '' });
  const [dupes, setDupes] = useState<{ sku: string; description: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // Duplicate product check while typing
  useEffect(() => {
    const d = cleanSearch(v.description);
    if (d.length < 4) { setDupes([]); return; }
    const t = setTimeout(async () => {
      const { data } = await supabaseBrowser().from('products').select('sku, description').ilike('description', `%${d}%`).limit(5);
      setDupes(data ?? []);
    }, 400);
    return () => clearTimeout(t);
  }, [v.description]);

  const save = async () => {
    setBusy(true); setErr(null);
    const { data, error } = await supabaseBrowser().from('products').insert({
      sku: v.sku.trim().toUpperCase(), description: v.description.trim(), base_uom_id: v.base_uom_id, category_id: v.category_id || null,
      default_supplier_id: v.default_supplier_id || null, is_asset: v.is_asset, notes: v.notes.trim() || null,
    }).select('id').single();
    setBusy(false);
    if (error) { const e = toAppError(error); setErr(/duplicate key/.test(e.message) ? `Stock code ${v.sku.toUpperCase()} already exists.` : /sku_check|check constraint/.test(e.message) ? 'Stock code: letters, digits, . / - _ only (max 40).' : e.message); return; }
    router.push(`/setup/products/${data.id}`);
  };
  return (
    <Dialog open onClose={onClose} title="New product" footer={<><Button onClick={onClose}>Cancel</Button><Button variant="primary" busy={busy} disabled={!v.sku.trim() || v.description.trim().length < 2 || !v.base_uom_id} onClick={save}>Create</Button></>}>
      <div className="space-y-3">
        <Field label="Stock code (SKU)" required><Input value={v.sku} onChange={(e) => setV({ ...v, sku: e.target.value })} className="font-mono uppercase" /></Field>
        <Field label="Description" required><Input value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} /></Field>
        {dupes.length > 0 && <Notice tone="warn" title="Possible duplicate">Similar products exist: {dupes.map((d) => `${d.sku} (${d.description})`).join('; ')}. Check before creating a new one.</Notice>}
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Base unit" required hint="Stock is always held in this unit; packs are converted."><Select value={v.base_uom_id} onChange={(e) => setV({ ...v, base_uom_id: e.target.value })}><option value="">—</option>{uoms.rows.map((u) => <option key={u.id} value={u.id}>{u.code} — {u.name}</option>)}</Select></Field>
          <Field label="Category"><Select value={v.category_id} onChange={(e) => setV({ ...v, category_id: e.target.value })}><option value="">—</option>{cats.rows.map((c) => <option key={c.id} value={c.id}>{c.parent_id ? '— ' : ''}{c.name}</option>)}</Select></Field>
          <Field label="Supplier"><Select value={v.default_supplier_id} onChange={(e) => setV({ ...v, default_supplier_id: e.target.value })}><option value="">—</option>{sups.rows.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
          <label className="mt-6 flex items-center gap-2 text-sm"><input type="checkbox" checked={v.is_asset} onChange={(e) => setV({ ...v, is_asset: e.target.checked })} />Reusable tool / equipment</label>
        </div>
        <Field label="Notes"><Textarea value={v.notes} onChange={(e) => setV({ ...v, notes: e.target.value })} rows={2} /></Field>
        {err && <Notice tone="bad">{err}</Notice>}
      </div>
    </Dialog>
  );
}
