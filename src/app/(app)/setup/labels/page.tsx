'use client';
import { Suspense, useEffect, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { Printer } from 'lucide-react';
import { BarcodeSVG } from '@/components/barcode';
import { ProductPicker } from '@/components/product-picker';
import { useApp } from '@/components/app-context';
import { Button, Field, Input, PageHeader, Select, Spinner } from '@/components/ui';
import { Tabs } from '@/components/widgets';
import { useAllWarehouses } from '@/hooks/use-ref-data';
import { useRows } from '@/hooks/use-rows';

type PL = { id: string; sku: string; description: string; code: string | null; uom: string };
type LL = { id: string; code: string; name: string; label_code: string; kind: string; warehouse_code: string };

function LabelsInner() {
  const sp = useSearchParams();
  const { warehouseId } = useApp();
  const [tab, setTab] = useState<'products' | 'locations'>(sp.get('warehouse') ? 'locations' : 'products');
  const [ids, setIds] = useState<string[]>(sp.get('products')?.split(',').filter(Boolean) ?? []);
  const [wh, setWh] = useState(sp.get('warehouse') ?? warehouseId ?? '');
  const [kind, setKind] = useState<'code128' | 'qrcode'>('code128');
  const [copies, setCopies] = useState(1);
  const [size, setSize] = useState<'small' | 'large'>('small');
  const { data: whs } = useAllWarehouses();
  const prods = useRows<{ id: string; sku: string; description: string; uoms: { code: string }; barcodes: { code: string; is_primary: boolean; uom_id: string | null }[] }>(ids.length ? 'lp' + ids.join(',') : null,
    (sb) => sb.from('products').select('id, sku, description, uoms(code), barcodes(code, is_primary, uom_id)').in('id', ids));
  const locs = useRows<{ id: string; code: string; name: string; label_code: string; kind: string; warehouses: { code: string } }>(tab === 'locations' && wh ? 'll' + wh : null,
    (sb) => sb.from('storage_locations').select('id, code, name, label_code, kind, warehouses(code)').eq('warehouse_id', wh).eq('status', 'active').order('code'));
  const [sel, setSel] = useState<Set<string>>(new Set());
  useEffect(() => setSel(new Set(locs.rows.map((l) => l.id))), [locs.rows]);

  const pLabels: PL[] = prods.rows.map((p) => {
    const b = p.barcodes.find((x) => x.is_primary) ?? p.barcodes.find((x) => !x.uom_id) ?? p.barcodes[0];
    return { id: p.id, sku: p.sku, description: p.description, code: b?.code ?? p.sku, uom: p.uoms?.code };
  });
  const lLabels: LL[] = locs.rows.filter((l) => sel.has(l.id)).map((l) => ({ id: l.id, code: l.code, name: l.name, label_code: l.label_code, kind: l.kind, warehouse_code: l.warehouses?.code }));
  const cell = size === 'small' ? 'w-[62mm] h-[29mm]' : 'w-[100mm] h-[50mm]';

  return (
    <>
      <div className="no-print">
        <PageHeader title="Print labels" description="Product and storage-location labels with CODE128 barcodes or QR codes. They scan with phones, USB and Bluetooth scanners." actions={<Button variant="primary" onClick={() => window.print()}><Printer className="size-4" />Print</Button>} />
        <Tabs value={tab} onChange={setTab} tabs={[{ id: 'products', label: 'Product labels' }, { id: 'locations', label: 'Location labels' }]} />
        <div className="mb-4 grid gap-3 rounded-lg border border-steel-200 bg-white p-3 sm:grid-cols-4">
          <Field label="Symbol"><Select value={kind} onChange={(e) => setKind(e.target.value as typeof kind)}><option value="code128">Barcode (CODE128)</option><option value="qrcode">QR code</option></Select></Field>
          <Field label="Label size"><Select value={size} onChange={(e) => setSize(e.target.value as typeof size)}><option value="small">62 × 29 mm</option><option value="large">100 × 50 mm</option></Select></Field>
          <Field label="Copies of each"><Input type="number" min={1} max={50} value={copies} onChange={(e) => setCopies(Math.min(50, Math.max(1, Number(e.target.value) || 1)))} /></Field>
          {tab === 'locations' && <Field label="Warehouse"><Select value={wh} onChange={(e) => setWh(e.target.value)}><option value="">—</option>{whs.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.warehouse_code} — {w.warehouse_name}</option>)}</Select></Field>}
        </div>
        {tab === 'products' && <div className="mb-4 max-w-xl"><ProductPicker warehouseId={warehouseId} onProduct={(p) => setIds((c) => (c.includes(p.product.id) ? c : [...c, p.product.id]))} />
          {ids.length > 0 && <button className="mt-2 text-sm underline" onClick={() => setIds([])}>Clear selection</button>}</div>}
        {tab === 'locations' && locs.rows.length > 0 && (
          <div className="mb-4 flex flex-wrap gap-2 text-sm">
            <button className="underline" onClick={() => setSel(new Set(locs.rows.map((l) => l.id)))}>All</button><button className="underline" onClick={() => setSel(new Set())}>None</button>
            {locs.rows.map((l) => <label key={l.id} className="flex items-center gap-1 rounded border border-steel-200 bg-white px-2 py-1"><input type="checkbox" checked={sel.has(l.id)} onChange={(e) => { const n = new Set(sel); if (e.target.checked) n.add(l.id); else n.delete(l.id); setSel(n); }} />{l.code}</label>)}
          </div>
        )}
      </div>
      {(prods.loading || locs.loading) && <Spinner />}
      <div className="print-sheet flex flex-wrap gap-[2mm] bg-white p-2">
        {tab === 'products' && pLabels.flatMap((l) => Array.from({ length: copies }, (_, i) => (
          <div key={l.id + i} className={`${cell} flex flex-col items-center justify-center overflow-hidden border border-dashed border-steel-200 p-[2mm] text-center print:border-steel-400`} style={{ breakInside: 'avoid' }}>
            <div className="font-mono text-[11px] font-bold leading-tight text-black">{l.sku}</div>
            <div className="line-clamp-2 text-[9px] leading-tight text-black">{l.description} ({l.uom})</div>
            <BarcodeSVG value={l.code ?? l.sku} kind={kind} height={size === 'small' ? 8 : 14} className={kind === 'qrcode' ? (size === 'small' ? '[&>svg]:h-[16mm] [&>svg]:w-auto' : '[&>svg]:h-[30mm] [&>svg]:w-auto') : '[&>svg]:h-auto [&>svg]:max-w-full'} />
          </div>
        )))}
        {tab === 'locations' && lLabels.flatMap((l) => Array.from({ length: copies }, (_, i) => (
          <div key={l.id + i} className={`${cell} flex items-center justify-center gap-[3mm] overflow-hidden border border-dashed border-steel-200 p-[2mm] print:border-steel-400`} style={{ breakInside: 'avoid' }}>
            <BarcodeSVG value={l.label_code} kind={kind} text={false} height={size === 'small' ? 10 : 16} className={kind === 'qrcode' ? (size === 'small' ? '[&>svg]:h-[22mm] [&>svg]:w-auto' : '[&>svg]:h-[38mm] [&>svg]:w-auto') : '[&>svg]:h-auto [&>svg]:max-w-[34mm]'} />
            <div className="text-left text-black"><div className="text-[9px]">{l.warehouse_code} · {l.kind}</div><div className="font-mono text-[18px] font-bold leading-none">{l.code}</div><div className="text-[9px]">{l.name}</div></div>
          </div>
        )))}
      </div>
    </>
  );
}

export default function LabelsPage() {
  return <Suspense fallback={<Spinner />}><LabelsInner /></Suspense>;
}
