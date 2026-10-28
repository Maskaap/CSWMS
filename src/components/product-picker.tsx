'use client';
import { useEffect, useRef, useState } from 'react';
import { Search } from 'lucide-react';
import { callRpc } from '@/hooks/use-transaction';
import type { LookupResult, ProductLookup } from '@/lib/types';
import { fmtQty } from '@/lib/format';
import { ScanInput } from './scanner';
import { Input, Notice, cx } from './ui';

type SearchRow = { id: string; sku: string; description: string; uom: string; category: string | null; status: string; available: number };

/**
 * Scan or search for a product. Resolves barcodes, pack barcodes and SKUs via lookup_code,
 * and reports location labels separately (onLocation) so a scanned shelf label can pick the location.
 */
export function ProductPicker({ warehouseId, onProduct, onLocation, disabled, big }: {
  warehouseId: string | null; onProduct: (p: ProductLookup) => void; onLocation?: (loc: Extract<LookupResult, { kind: 'location' }>['location']) => void;
  disabled?: boolean; big?: boolean;
}) {
  const [msg, setMsg] = useState<string | null>(null);
  const [q, setQ] = useState('');
  const [rows, setRows] = useState<SearchRow[]>([]);
  const busy = useRef(false);

  const resolve = async (code: string) => {
    if (busy.current) return;
    busy.current = true;
    setMsg(null);
    const { data, error } = await callRpc<LookupResult>('lookup_code', { p_code: code, p_warehouse_id: warehouseId });
    busy.current = false;
    if (error) { setMsg(error.message); return; }
    if (!data || data.kind === 'none') { setMsg(`No product or location found for "${code}". Check the label or search by description.`); return; }
    if (data.kind === 'location') {
      if (onLocation) {
        if (!data.location.in_selected_warehouse) { setMsg(`Location ${data.location.code} belongs to warehouse ${data.location.warehouse_code}, not the selected warehouse.`); return; }
        onLocation(data.location);
      } else setMsg(`"${code}" is a location label. Scan the product barcode.`);
      return;
    }
    if (data.product.status !== 'active') { setMsg(`${data.product.sku} is ${data.product.status} and cannot be used.`); return; }
    setQ(''); setRows([]);
    onProduct(data);
  };

  useEffect(() => {
    if (q.trim().length < 2) { setRows([]); return; }
    const t = setTimeout(async () => {
      const { data } = await callRpc<SearchRow[]>('search_products', { p_query: q, p_warehouse_id: warehouseId, p_limit: 12 });
      setRows(data ?? []);
    }, 250);
    return () => clearTimeout(t);
  }, [q, warehouseId]);

  return (
    <div className="space-y-2">
      <ScanInput onScan={resolve} disabled={disabled} big={big} label="Scan product" />
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-steel-400" />
        <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="…or search by description / SKU" className="pl-9" disabled={disabled} aria-label="Search products" />
        {rows.length > 0 && (
          <ul className="absolute z-20 mt-1 max-h-80 w-full overflow-y-auto rounded-md border border-steel-200 bg-white shadow-lg">
            {rows.map((r) => (
              <li key={r.id}>
                <button type="button" onClick={() => resolve(r.sku)} disabled={r.status !== 'active'}
                  className={cx('flex w-full items-center justify-between gap-3 px-3 py-2 text-left text-sm hover:bg-steel-50', r.status !== 'active' && 'opacity-50')}>
                  <span><span className="font-mono text-[13px] text-navy-900">{r.sku}</span> <span className="text-steel-800">{r.description}</span></span>
                  <span className="whitespace-nowrap text-xs text-steel-600">{fmtQty(r.available)} {r.uom}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
      {msg && <Notice tone="warn">{msg}</Notice>}
    </div>
  );
}
