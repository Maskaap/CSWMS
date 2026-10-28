'use client';
import Link from 'next/link';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Plus } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { ScanInput } from '@/components/scanner';
import { Badge, Button, Dialog, Field, Input, Notice, PageHeader, Select, Spinner, StatusBadge, Table, Td, Textarea, Th } from '@/components/ui';
import { ExportButtons, LoadError, Tabs } from '@/components/widgets';
import { useLocations } from '@/hooks/use-ref-data';
import { useRows } from '@/hooks/use-rows';
import { callRpc, useTransaction } from '@/hooks/use-transaction';
import { TxnOutcome } from '@/components/txn-outcome';
import { fmtDateTime, fmtZAR, parseQty } from '@/lib/format';

type A = { id: string; asset_tag: string; serial_number: string | null; sku: string; product_description: string; status: string; condition: string;
  warehouse_code: string; location_code: string | null; holder: string | null; job_reference: string | null; due_back_at: string | null; is_overdue: boolean;
  days_out: number | null; last_verified_at: string | null; purchase_cost: number | null; owner_company_code: string; home_warehouse_code: string };

export default function AssetsPage() {
  const router = useRouter();
  const { can, warehouseId, me } = useApp();
  const [tab, setTab] = useState<'all' | 'out' | 'overdue' | 'mine' | 'repair'>('all');
  const [msg, setMsg] = useState<string | null>(null);
  const [reg, setReg] = useState(false);
  const list = useRows<A>('assets|' + tab, (sb) => {
    let q = sb.from('v_assets').select('*').order('asset_tag').limit(2000);
    if (tab === 'all') q = q.neq('status', 'retired');
    if (tab === 'out') q = q.eq('status', 'checked_out');
    if (tab === 'overdue') q = q.eq('is_overdue', true);
    if (tab === 'mine') q = q.eq('holder_user_id', me?.user?.id ?? '');
    if (tab === 'repair') q = q.in('status', ['in_repair', 'lost']);
    return q;
  });
  const find = async (code: string) => {
    setMsg(null);
    const { data, error } = await callRpc<{ kind: string; id?: string }>('asset_lookup', { p_code: code });
    if (error) setMsg(error.message); else if (data?.kind === 'asset' && data.id) router.push(`/assets/${data.id}`); else setMsg(`No tool or equipment found for "${code}".`);
  };
  return (
    <>
      <PageHeader title="Tools & equipment" description="Reusable tools and equipment tracked individually by tag: who has what, for which job, and when it is due back."
        actions={<>
          {can('asset.manage', warehouseId) && <Button variant="primary" onClick={() => setReg(true)}><Plus className="size-4" />Register item</Button>}
          <ExportButtons title="Asset register" rows={list.rows} cols={[
            { key: 'asset_tag', label: 'Tag' }, { key: 'sku', label: 'Product' }, { key: 'product_description', label: 'Description' }, { key: 'serial_number', label: 'Serial' },
            { key: 'status', label: 'Status' }, { key: 'condition', label: 'Condition' }, { key: 'owner_company_code', label: 'Owner' }, { key: 'warehouse_code', label: 'Warehouse' },
            { key: 'location_code', label: 'Location' }, { key: 'holder', label: 'Held by' }, { key: 'job_reference', label: 'Job' },
            { key: 'due_back_at', label: 'Due back', get: (r) => fmtDateTime(r.due_back_at) }, { key: 'is_overdue', label: 'Overdue', get: (r) => (r.is_overdue ? 'Yes' : '') },
            { key: 'last_verified_at', label: 'Last verified', get: (r) => fmtDateTime(r.last_verified_at) }, { key: 'purchase_cost', label: 'Cost (ZAR)', num: true }]} />
        </>} />
      <div className="mb-4 max-w-xl"><ScanInput label="Scan a tool tag or serial number" onScan={find} /></div>
      {msg && <Notice tone="warn" className="mb-4">{msg}</Notice>}
      <Tabs value={tab} onChange={setTab} tabs={[{ id: 'all', label: 'All' }, { id: 'out', label: 'Checked out' }, { id: 'overdue', label: 'Overdue' }, { id: 'mine', label: 'With me' }, { id: 'repair', label: 'Repair / lost' }]} />
      <LoadError error={list.error} />
      {list.loading ? <Spinner /> : (
        <Table>
          <thead><tr><Th>Tag</Th><Th>Item</Th><Th>Status</Th><Th>Where / who</Th><Th>Due back</Th><Th>Last verified</Th></tr></thead>
          <tbody>{list.rows.map((a) => (
            <tr key={a.id} className="hover:bg-steel-50">
              <Td><Link className="font-mono text-[13px] font-semibold hover:underline" href={`/assets/${a.id}`}>{a.asset_tag}</Link>{a.serial_number && <div className="text-xs text-steel-600">S/N {a.serial_number}</div>}</Td>
              <Td>{a.product_description}<div className="font-mono text-xs text-steel-600">{a.sku}</div></Td>
              <Td><StatusBadge status={a.status} />{a.condition !== 'good' && <Badge tone={a.condition === 'damaged' ? 'bad' : 'warn'} className="ml-1">{a.condition}</Badge>}</Td>
              <Td>{a.status === 'checked_out' ? <><b>{a.holder}</b>{a.job_reference && <div className="text-xs text-steel-600">Job {a.job_reference}</div>}</> : <>{a.warehouse_code}{a.location_code && <span className="font-mono text-[12px]"> / {a.location_code}</span>}</>}</Td>
              <Td className={a.is_overdue ? 'font-semibold text-bad-600' : ''}>{a.due_back_at ? fmtDateTime(a.due_back_at) : '—'}{a.is_overdue && <div className="text-xs">overdue</div>}</Td>
              <Td className="text-xs">{fmtDateTime(a.last_verified_at)}</Td>
            </tr>
          ))}
            {list.rows.length === 0 && <tr><Td className="text-steel-600">Nothing here.</Td></tr>}</tbody>
        </Table>
      )}
      {reg && <RegisterDialog onClose={() => setReg(false)} onDone={(id) => router.push(`/assets/${id}`)} />}
    </>
  );
}

function RegisterDialog({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const { warehouse, warehouseId } = useApp();
  const prods = useRows<{ id: string; sku: string; description: string }>('assetprods', (sb) => sb.from('products').select('id, sku, description').eq('is_asset', true).eq('status', 'active').order('sku'));
  const { data: locs } = useLocations(warehouseId);
  const txn = useTransaction('register_asset');
  const [v, setV] = useState({ product: '', serial: '', loc: '', date: '', cost: '', condition: 'good', notes: '' });
  const cost = v.cost ? parseQty(v.cost) : null;
  return (
    <Dialog open onClose={onClose} title={`Register tool / equipment in ${warehouse?.code}`} footer={<>
      <Button onClick={onClose}>Close</Button>
      <Button variant="primary" disabled={!v.product || (cost !== null && (isNaN(cost) || cost < 0))} busy={txn.state.phase === 'saving'} onClick={async () => {
        const r = await txn.run({ p_product_id: v.product, p_warehouse_id: warehouseId, p_location_id: v.loc || null, p_serial_number: v.serial || null,
          p_purchase_date: v.date || null, p_purchase_cost: cost, p_condition: v.condition, p_notes: v.notes || null });
        if (r && typeof r.asset_id === 'string') onDone(r.asset_id);
      }}>Register</Button></>}>
      <div className="space-y-3">
        <Field label="Product" required hint={prods.rows.length === 0 ? 'No products are marked as reusable tools / equipment yet (Setup → Products → tick "Reusable tool / equipment").' : undefined}>
          <Select value={v.product} onChange={(e) => setV({ ...v, product: e.target.value })}><option value="">— choose —</option>{prods.rows.map((p) => <option key={p.id} value={p.id}>{p.sku} — {p.description}</option>)}</Select>
        </Field>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Serial number"><Input value={v.serial} onChange={(e) => setV({ ...v, serial: e.target.value })} /></Field>
          <Field label="Stored at"><Select value={v.loc} onChange={(e) => setV({ ...v, loc: e.target.value })}><option value="">Receiving area</option>{locs.map((l) => <option key={l.id} value={l.id}>{l.code} — {l.name}</option>)}</Select></Field>
          <Field label="Purchase date"><Input type="date" value={v.date} onChange={(e) => setV({ ...v, date: e.target.value })} /></Field>
          <Field label="Purchase cost (R)"><Input inputMode="decimal" value={v.cost} onChange={(e) => setV({ ...v, cost: e.target.value })} /></Field>
          <Field label="Condition"><Select value={v.condition} onChange={(e) => setV({ ...v, condition: e.target.value })}><option value="good">Good</option><option value="fair">Fair</option><option value="damaged">Damaged</option></Select></Field>
        </div>
        <Field label="Notes"><Textarea rows={2} value={v.notes} onChange={(e) => setV({ ...v, notes: e.target.value })} /></Field>
        <TxnOutcome state={txn.state} onRetry={txn.retry} />
        {cost !== null && !isNaN(cost) && cost > 0 && <p className="text-xs text-steel-600">Cost {fmtZAR(cost)}</p>}
      </div>
    </Dialog>
  );
}
