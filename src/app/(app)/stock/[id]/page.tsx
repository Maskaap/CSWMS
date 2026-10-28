'use client';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { Printer } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, PageHeader, Panel, Spinner, Table, Td, Th } from '@/components/ui';
import { KV, LoadError, TxnLink } from '@/components/widgets';
import { useRows } from '@/hooks/use-rows';
import { fmtDateTime, fmtQty, STATUS_LABELS, TXN_LABELS } from '@/lib/format';

type Product = {
  id: string; sku: string; description: string; status: string; is_asset: boolean; notes: string | null; last_stocktake_at: string | null;
  unusual_withdrawal_qty: number | null; created_at: string;
  uoms: { code: string; name: string } | null; categories: { name: string } | null; suppliers: { name: string } | null;
};

export default function ProductDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { can } = useApp();
  const prod = useRows<Product>('p' + id, (sb) => sb.from('products').select('*, uoms!products_base_uom_id_fkey(code, name), categories(name), suppliers(name)').eq('id', id).maybeSingle());
  const codes = useRows<{ code: string; symbology: string; is_primary: boolean; uoms: { code: string } | null }>('b' + id, (sb) => sb.from('barcodes').select('code, symbology, is_primary, uoms(code)').eq('product_id', id));
  const units = useRows<{ factor_to_base: number; is_default_issue: boolean; uoms: { code: string; name: string } }>('u' + id, (sb) => sb.from('product_uoms').select('factor_to_base, is_default_issue, uoms(code, name)').eq('product_id', id));
  const wh = useRows<Record<string, any>>('w' + id, (sb) => sb.from('v_stock_by_warehouse').select('*').eq('product_id', id).order('warehouse_code'));
  const loc = useRows<Record<string, any>>('l' + id, (sb) => sb.from('v_stock_balances').select('*').eq('product_id', id).neq('qty', 0).order('warehouse_code').order('location_code'));
  const mv = useRows<Record<string, any>>('m' + id, (sb) => sb.from('v_movements').select('*').eq('product_id', id).order('id', { ascending: false }).limit(60));

  const p = prod.rows[0];
  if (prod.loading) return <Spinner />;
  if (!p) return <><LoadError error={prod.error} /><PageHeader title="Product not found" /></>;

  return (
    <>
      <PageHeader title={`${p.sku} — ${p.description}`} description={<>{p.categories?.name ?? 'Uncategorised'} · base unit {p.uoms?.code} · <Badge tone={p.status === 'active' ? 'ok' : 'warn'}>{p.status}</Badge>{p.is_asset && <Badge tone="info" className="ml-1">reusable asset</Badge>}</>}
        actions={<>
          {can('product.manage') && <Link href={`/setup/products/${p.id}`}><Button size="sm">Edit product</Button></Link>}
          <Link href={`/setup/labels?products=${p.id}`}><Button size="sm"><Printer className="size-4" />Print label</Button></Link>
        </>} />
      <div className="space-y-6">
        <Panel title="Product">
          <KV items={[
            ['Stock code', <span className="font-mono">{p.sku}</span>], ['Supplier', p.suppliers?.name], ['Last stocktake', p.last_stocktake_at ? fmtDateTime(p.last_stocktake_at) : 'Never'],
            ['Barcodes', codes.rows.length ? codes.rows.map((b) => `${b.code}${b.uoms ? ` (${b.uoms.code})` : ''}`).join(', ') : 'None'],
            ['Pack conversions', units.rows.length ? units.rows.map((u) => `1 ${u.uoms.code} = ${fmtQty(u.factor_to_base)} ${p.uoms?.code}`).join(' · ') : 'None'],
            ['Unusual-withdrawal limit', p.unusual_withdrawal_qty ? `${fmtQty(p.unusual_withdrawal_qty)} ${p.uoms?.code}` : 'Automatic (history)'],
          ]} />
        </Panel>

        <Panel title="Stock per warehouse" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>Warehouse</Th><Th right>Available</Th><Th right>Reserved</Th><Th right>Free</Th><Th right>Damaged</Th><Th right>Quarantine</Th><Th right>In transit out</Th><Th right>Min / reorder</Th><Th>Level</Th></tr></thead>
            <tbody>
              {wh.rows.map((r) => (
                <tr key={r.warehouse_id}><Td><b>{r.warehouse_code}</b> {r.warehouse_name}<div className="text-xs text-steel-600">{r.branch_name} · {r.company_code} · {r.province_name}</div></Td>
                  <Td right>{fmtQty(r.available)}</Td><Td right>{fmtQty(r.reserved)}</Td><Td right className="font-semibold">{fmtQty(r.free_to_use)}</Td>
                  <Td right>{fmtQty(r.damaged)}</Td><Td right>{fmtQty(r.quarantine)}</Td><Td right>{fmtQty(r.in_transit)}</Td>
                  <Td right>{r.min_qty != null ? `${fmtQty(r.min_qty)} / ${fmtQty(r.reorder_qty)}` : '—'}</Td>
                  <Td><Badge tone={r.stock_level === 'out' ? 'bad' : r.stock_level === 'low' ? 'warn' : 'ok'}>{r.stock_level}</Badge></Td></tr>
              ))}
              {wh.rows.length === 0 && <tr><Td className="text-steel-600">No stock in the warehouses you can see.</Td></tr>}
            </tbody>
          </Table>
        </Panel>

        <Panel title="Exactly where it is stored" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>Warehouse</Th><Th>Location</Th><Th>Owner</Th><Th>Status</Th><Th right>Quantity</Th><Th>Last movement</Th></tr></thead>
            <tbody>
              {loc.rows.map((r, i) => (
                <tr key={i}><Td>{r.warehouse_code}</Td><Td mono>{r.location_code} <span className="font-sans text-xs text-steel-600">{r.location_name}</span></Td>
                  <Td>{r.owner_company_code}{r.stored_for_other_company && <Badge tone="info" className="ml-1">stored for owner</Badge>}</Td>
                  <Td>{STATUS_LABELS[r.status] ?? r.status}</Td><Td right className="font-semibold">{fmtQty(r.qty)} {r.uom}</Td><Td className="text-xs text-steel-600">{fmtDateTime(r.updated_at)}</Td></tr>
              ))}
            </tbody>
          </Table>
        </Panel>

        <Panel title="Recent movements" padded={false}>
          <Table className="rounded-none border-0">
            <thead><tr><Th>When</Th><Th>Transaction</Th><Th>Type</Th><Th>Warehouse / location</Th><Th right>Change</Th><Th right>Balance after</Th><Th>By</Th><Th>Reason / reference</Th></tr></thead>
            <tbody>
              {mv.rows.map((m) => (
                <tr key={m.id}><Td className="whitespace-nowrap text-xs">{fmtDateTime(m.posted_at)}</Td><Td><TxnLink id={m.txn_id} no={m.txn_no} /></Td>
                  <Td>{TXN_LABELS[m.txn_type] ?? m.txn_type}{m.status !== 'available' && <span className="text-xs text-steel-600"> ({STATUS_LABELS[m.status]})</span>}{m.is_unusual && <Badge tone="warn" className="ml-1">unusual</Badge>}</Td>
                  <Td>{m.warehouse_code} / <span className="font-mono text-[13px]">{m.location_code}</span></Td>
                  <Td right className={Number(m.qty_delta) < 0 ? 'text-bad-600' : 'text-ok-600'}>{Number(m.qty_delta) > 0 ? '+' : ''}{fmtQty(m.qty_delta)}</Td>
                  <Td right>{fmtQty(m.balance_after)}</Td><Td>{m.created_by_name}</Td>
                  <Td className="text-xs">{m.reason_label}{m.reference && <div className="text-steel-600">{m.reference}</div>}</Td></tr>
              ))}
              {mv.rows.length === 0 && <tr><Td className="text-steel-600">No movements yet.</Td></tr>}
            </tbody>
          </Table>
        </Panel>
      </div>
    </>
  );
}
