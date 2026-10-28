'use client';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { useEffect, useState } from 'react';
import { Barcode, Printer, Trash2 } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, Field, Input, Notice, PageHeader, Panel, Select, Spinner, Table, Td, Textarea, Th } from '@/components/ui';
import { ActionResult, LoadError } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useAllWarehouses } from '@/hooks/use-ref-data';
import { useRows } from '@/hooks/use-rows';
import { supabaseBrowser } from '@/lib/supabase/client';
import { toAppError } from '@/lib/errors';
import { fmtQty, fmtZAR } from '@/lib/format';

export default function ProductEditPage() {
  const { id } = useParams<{ id: string }>();
  const { can } = useApp();
  const edit = can('product.manage');
  const prod = useRows<Record<string, any>>('pe' + id, (sb) => sb.from('products').select('*, uoms(code, decimals)').eq('id', id).maybeSingle());
  const uoms = useRows<{ id: string; code: string; name: string }>('uoms', (sb) => sb.from('uoms').select('id, code, name').eq('status', 'active').order('code'));
  const cats = useRows<{ id: string; name: string; parent_id: string | null }>('cats', (sb) => sb.from('categories').select('id, name, parent_id').order('name'));
  const sups = useRows<{ id: string; name: string }>('sups', (sb) => sb.from('suppliers').select('id, name').order('name'));
  const codes = useRows<{ id: string; code: string; symbology: string; is_primary: boolean; is_generated: boolean; uom_id: string | null }>('bc' + id, (sb) => sb.from('barcodes').select('*').eq('product_id', id).order('created_at'));
  const packs = useRows<{ id: string; uom_id: string; factor_to_base: number; is_default_issue: boolean }>('pu' + id, (sb) => sb.from('product_uoms').select('*').eq('product_id', id));
  const thr = useRows<{ id: string; warehouse_id: string; min_qty: number; reorder_qty: number }>('th' + id, (sb) => sb.from('stock_thresholds').select('*').eq('product_id', id));
  const cost = useRows<{ purchase_price: number }>(can('cost.view') ? 'cost' + id : null, (sb) => sb.from('product_costs').select('purchase_price').eq('product_id', id).maybeSingle());
  const { data: whs } = useAllWarehouses();
  const act = useAction();
  const [v, setV] = useState<Record<string, any> | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const [bc, setBc] = useState({ code: '', uom_id: '', symbology: 'EAN13' });
  const [pk, setPk] = useState({ uom_id: '', factor: '' });
  const [th, setTh] = useState({ warehouse_id: '', min_qty: '', reorder_qty: '' });
  const [price, setPrice] = useState('');
  useEffect(() => { if (prod.rows[0]) setV(prod.rows[0]); }, [prod.rows]);
  useEffect(() => { if (cost.rows[0]) setPrice(String(cost.rows[0].purchase_price ?? '')); }, [cost.rows]);

  const sb = supabaseBrowser();
  const run = async (p: PromiseLike<{ error: unknown }>, msg: string, after?: () => void) => {
    setErr(null); setOk(null);
    const { error } = await p;
    if (error) { const e = toAppError(error); setErr(/duplicate key/.test(e.message) ? 'That value already exists (barcodes must be unique across all products and location labels).' : e.message); return false; }
    setOk(msg); after?.(); return true;
  };
  if (prod.loading || !v) return prod.loading ? <Spinner /> : <><LoadError error={prod.error} /><PageHeader title="Product not found" /></>;
  const p = prod.rows[0];
  const uomCode = (uid: string | null) => uoms.rows.find((u) => u.id === uid)?.code ?? p.uoms?.code;

  return (
    <>
      <PageHeader title={`${p.sku} — ${p.description}`} description={<>Base unit {p.uoms?.code} · <Badge tone={p.status === 'active' ? 'ok' : 'idle'}>{p.status}</Badge></>}
        actions={<><Link href={`/stock/${p.id}`}><Button size="sm">Stock & movements</Button></Link><Link href={`/setup/labels?products=${p.id}`}><Button size="sm"><Printer className="size-4" />Labels</Button></Link></>} />
      {err && <Notice tone="bad" className="mb-4">{err}</Notice>}
      {ok && <Notice tone="ok" className="mb-4">{ok}</Notice>}
      <ActionResult error={act.error} />
      <div className="space-y-6">
        <Panel title="Product details">
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <Field label="Stock code" hint="Cannot be changed — it is used in history and on labels."><Input value={p.sku} disabled className="font-mono" /></Field>
            <Field label="Description" required><Input value={v.description ?? ''} onChange={(e) => setV({ ...v, description: e.target.value })} disabled={!edit} /></Field>
            <Field label="Base unit" hint="Locked once stock exists."><Select value={v.base_uom_id} onChange={(e) => setV({ ...v, base_uom_id: e.target.value })} disabled={!edit}>{uoms.rows.map((u) => <option key={u.id} value={u.id}>{u.code} — {u.name}</option>)}</Select></Field>
            <Field label="Category"><Select value={v.category_id ?? ''} onChange={(e) => setV({ ...v, category_id: e.target.value || null })} disabled={!edit}><option value="">—</option>{cats.rows.map((c) => <option key={c.id} value={c.id}>{c.parent_id ? '— ' : ''}{c.name}</option>)}</Select></Field>
            <Field label="Supplier"><Select value={v.default_supplier_id ?? ''} onChange={(e) => setV({ ...v, default_supplier_id: e.target.value || null })} disabled={!edit}><option value="">—</option>{sups.rows.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
            <Field label="Status"><Select value={v.status} onChange={(e) => setV({ ...v, status: e.target.value })} disabled={!edit}><option value="active">Active</option><option value="inactive">Inactive (no new receipts)</option><option value="archived">Archived</option></Select></Field>
            <Field label="Unusual-withdrawal limit" hint="Withdrawals above this (base units) always need reconfirmation. Blank = automatic from history."><Input inputMode="decimal" value={v.unusual_withdrawal_qty ?? ''} onChange={(e) => setV({ ...v, unusual_withdrawal_qty: e.target.value })} disabled={!edit} /></Field>
            <label className="mt-6 flex items-center gap-2 text-sm"><input type="checkbox" checked={!!v.is_asset} onChange={(e) => setV({ ...v, is_asset: e.target.checked })} disabled={!edit} />Reusable tool / equipment</label>
            <Field label="Image URL"><Input value={v.image_path ?? ''} onChange={(e) => setV({ ...v, image_path: e.target.value })} disabled={!edit} placeholder="optional" /></Field>
            <Field label="Notes" className="sm:col-span-2 lg:col-span-3"><Textarea value={v.notes ?? ''} onChange={(e) => setV({ ...v, notes: e.target.value })} disabled={!edit} rows={2} /></Field>
          </div>
          {edit && <Button className="mt-3" variant="primary" onClick={() => run(sb.from('products').update({ description: v.description?.trim(), base_uom_id: v.base_uom_id, category_id: v.category_id, default_supplier_id: v.default_supplier_id,
            status: v.status, unusual_withdrawal_qty: v.unusual_withdrawal_qty === '' || v.unusual_withdrawal_qty == null ? null : Number(String(v.unusual_withdrawal_qty).replace(',', '.')),
            is_asset: !!v.is_asset, image_path: v.image_path || null, notes: v.notes || null }).eq('id', id), 'Product saved.', prod.reload)}>Save details</Button>}
        </Panel>

        <div className="grid gap-6 xl:grid-cols-2">
          <Panel title="Barcodes & QR codes" padded={false}>
            <Table className="rounded-none border-0">
              <thead><tr><Th>Code</Th><Th>Type</Th><Th>Means</Th><Th /></tr></thead>
              <tbody>{codes.rows.map((b) => (
                <tr key={b.id}><Td mono>{b.code}{b.is_primary && <Badge tone="info" className="ml-1">primary</Badge>}{b.is_generated && <Badge className="ml-1">generated</Badge>}</Td><Td>{b.symbology}</Td>
                  <Td>1 {uomCode(b.uom_id)}{b.uom_id ? ' (pack)' : ''}</Td>
                  <Td>{edit && <button aria-label="Remove barcode" className="text-bad-600" onClick={() => run(sb.from('barcodes').delete().eq('id', b.id), 'Barcode removed.', codes.reload)}><Trash2 className="size-4" /></button>}</Td></tr>
              ))}
                {codes.rows.length === 0 && <tr><Td className="text-warn-600">No barcode — generate one so the item can be scanned.</Td></tr>}</tbody>
            </Table>
            {edit && (
              <div className="space-y-2 border-t border-steel-100 p-4">
                <div className="grid gap-2 sm:grid-cols-[1fr_8rem_8rem_auto]">
                  <Input value={bc.code} onChange={(e) => setBc({ ...bc, code: e.target.value })} placeholder="Scan or type existing barcode" className="font-mono" />
                  <Select value={bc.symbology} onChange={(e) => setBc({ ...bc, symbology: e.target.value })}>{['EAN13', 'EAN8', 'UPCA', 'CODE128', 'CODE39', 'QR', 'OTHER'].map((s) => <option key={s}>{s}</option>)}</Select>
                  <Select value={bc.uom_id} onChange={(e) => setBc({ ...bc, uom_id: e.target.value })}><option value="">1 {p.uoms?.code}</option>{packs.rows.map((x) => <option key={x.uom_id} value={x.uom_id}>1 {uomCode(x.uom_id)}</option>)}</Select>
                  <Button disabled={bc.code.trim().length < 3} onClick={() => run(sb.from('barcodes').insert({ product_id: id, code: bc.code.trim(), symbology: bc.symbology, uom_id: bc.uom_id || null, is_primary: codes.rows.length === 0 && !bc.uom_id }), 'Barcode added.', () => { setBc({ code: '', uom_id: '', symbology: 'EAN13' }); codes.reload(); })}>Add</Button>
                </div>
                <Button variant="navy" size="sm" busy={act.busy} onClick={async () => { const r = await act.run<{ code: string }>('generate_barcode', { p_product_id: id }); if (r) { setOk(`Generated barcode ${r.code}.`); codes.reload(); } }}><Barcode className="size-4" />Generate a new CODE128 barcode</Button>
              </div>
            )}
          </Panel>

          <Panel title="Pack / unit conversions" padded={false}>
            <Table className="rounded-none border-0">
              <thead><tr><Th>Unit</Th><Th right>Equals</Th><Th>Default for issuing</Th><Th /></tr></thead>
              <tbody>{packs.rows.map((x) => (
                <tr key={x.id}><Td>1 {uomCode(x.uom_id)}</Td><Td right>{fmtQty(x.factor_to_base)} {p.uoms?.code}</Td>
                  <Td>{edit ? <input type="checkbox" checked={x.is_default_issue} onChange={(e) => run(sb.from('product_uoms').update({ is_default_issue: e.target.checked }).eq('id', x.id), 'Saved.', packs.reload)} /> : x.is_default_issue ? 'Yes' : ''}</Td>
                  <Td>{edit && <button aria-label="Remove conversion" className="text-bad-600" onClick={() => run(sb.from('product_uoms').delete().eq('id', x.id), 'Conversion removed.', packs.reload)}><Trash2 className="size-4" /></button>}</Td></tr>
              ))}
                {packs.rows.length === 0 && <tr><Td className="text-steel-600">Only the base unit ({p.uoms?.code}) is used.</Td></tr>}</tbody>
            </Table>
            {edit && (
              <div className="grid gap-2 border-t border-steel-100 p-4 sm:grid-cols-[1fr_1fr_auto]">
                <Select value={pk.uom_id} onChange={(e) => setPk({ ...pk, uom_id: e.target.value })}><option value="">— pack unit —</option>{uoms.rows.filter((u) => u.id !== p.base_uom_id).map((u) => <option key={u.id} value={u.id}>{u.code} — {u.name}</option>)}</Select>
                <Input inputMode="decimal" value={pk.factor} onChange={(e) => setPk({ ...pk, factor: e.target.value })} placeholder={`How many ${p.uoms?.code} in one?`} />
                <Button disabled={!pk.uom_id || !(Number(pk.factor.replace(',', '.')) > 0)} onClick={() => run(sb.from('product_uoms').insert({ product_id: id, uom_id: pk.uom_id, factor_to_base: Number(pk.factor.replace(',', '.')) }), 'Conversion added.', () => { setPk({ uom_id: '', factor: '' }); packs.reload(); })}>Add</Button>
              </div>
            )}
          </Panel>
        </div>

        <Panel title="Minimum and reorder quantities per warehouse" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>Warehouse</Th><Th right>Minimum</Th><Th right>Reorder quantity</Th><Th /></tr></thead>
            <tbody>{thr.rows.map((t) => {
              const w = whs.find((x) => x.warehouse_id === t.warehouse_id);
              return <tr key={t.id}><Td>{w ? `${w.warehouse_code} — ${w.warehouse_name}` : t.warehouse_id}</Td><Td right>{fmtQty(t.min_qty)} {p.uoms?.code}</Td><Td right>{fmtQty(t.reorder_qty)}</Td>
                <Td>{edit && <button aria-label="Remove" className="text-bad-600" onClick={() => run(sb.from('stock_thresholds').delete().eq('id', t.id), 'Removed.', thr.reload)}><Trash2 className="size-4" /></button>}</Td></tr>;
            })}
              {thr.rows.length === 0 && <tr><Td className="text-steel-600">No minimum set — no low-stock alerts for this item.</Td></tr>}</tbody>
          </Table>
          {edit && (
            <div className="grid gap-2 border-t border-steel-100 p-4 sm:grid-cols-[1fr_8rem_8rem_auto]">
              <Select value={th.warehouse_id} onChange={(e) => setTh({ ...th, warehouse_id: e.target.value })}><option value="">— warehouse —</option>{whs.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.warehouse_code} — {w.warehouse_name}</option>)}</Select>
              <Input inputMode="decimal" value={th.min_qty} onChange={(e) => setTh({ ...th, min_qty: e.target.value })} placeholder="Minimum" />
              <Input inputMode="decimal" value={th.reorder_qty} onChange={(e) => setTh({ ...th, reorder_qty: e.target.value })} placeholder="Reorder qty" />
              <Button disabled={!th.warehouse_id || th.min_qty === ''} onClick={() => run(sb.from('stock_thresholds').upsert({ product_id: id, warehouse_id: th.warehouse_id, min_qty: Number(th.min_qty.replace(',', '.')), reorder_qty: Number((th.reorder_qty || '0').replace(',', '.')) }, { onConflict: 'product_id,warehouse_id' }), 'Threshold saved.', () => { setTh({ warehouse_id: '', min_qty: '', reorder_qty: '' }); thr.reload(); })}>Save</Button>
            </div>
          )}
        </Panel>

        {can('cost.view') && (
          <Panel title="Purchase price (optional, for valuation)">
            <div className="flex items-end gap-2">
              <Field label={`Price per ${p.uoms?.code} (ZAR, excl. VAT)`}><Input inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} className="w-40" disabled={!edit} /></Field>
              {edit && <Button disabled={price !== '' && !(Number(price.replace(',', '.')) >= 0)} onClick={() => run(sb.from('product_costs').upsert({ product_id: id, purchase_price: Number(price.replace(',', '.') || 0), currency: 'ZAR' }, { onConflict: 'product_id' }), 'Price saved.', cost.reload)}>Save price</Button>}
              {cost.rows[0] && <span className="pb-2 text-sm text-steel-600">Current: {fmtZAR(cost.rows[0].purchase_price)}</span>}
            </div>
          </Panel>
        )}
      </div>
    </>
  );
}
