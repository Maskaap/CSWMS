'use client';
import { Trash2 } from 'lucide-react';
import type { ProductLookup } from '@/lib/types';
import { fmtQty, parseQty } from '@/lib/format';
import { Input, Select, cx } from './ui';

export type TxnLine = {
  key: string;
  product: ProductLookup;
  uom_id: string;
  qty: string;
  location_id: string;
  to_location_id?: string;
  owner_company_id?: string;
  status?: string;
  condition?: 'good' | 'damaged';
  unit_cost?: string;
  flash?: number;
};

export function newLine(p: ProductLookup, extra: Partial<TxnLine> = {}): TxnLine {
  return {
    key: crypto.randomUUID(),
    product: p,
    uom_id: p.scanned_uom_id ?? p.product.base_uom.id,
    qty: '',
    location_id: '',
    ...extra,
  };
}

export function unitOf(l: TxnLine) {
  return l.product.units.find((u) => u.uom_id === l.uom_id) ?? { uom_id: l.uom_id, code: l.product.product.base_uom.code, factor: 1, decimals: l.product.product.base_uom.decimals, name: '', is_default_issue: false };
}

/** quantity in base units, or null when invalid */
export function baseQty(l: TxnLine): number | null {
  const q = parseQty(l.qty);
  if (q === null || isNaN(q)) return null;
  return Math.round(q * unitOf(l).factor * 10000) / 10000;
}

/** client-side validation (the database validates again and is the authority) */
export function qtyError(l: TxnLine, { allowNegative = false, allowZero = false } = {}): string | null {
  const q = parseQty(l.qty);
  if (q === null) return 'Enter a quantity';
  if (isNaN(q)) return 'Not a valid number';
  if (!allowZero && q === 0) return 'Quantity cannot be zero';
  if (!allowNegative && q < 0) return 'Quantity cannot be negative';
  const u = unitOf(l);
  const decimals = (l.qty.replace(/\s/g, '').split(/[.,]/)[1] ?? '').length;
  if (decimals > u.decimals) return `${u.code} allows ${u.decimals} decimal place(s)`;
  const base = baseQty(l)!;
  const bd = l.product.product.base_uom.decimals;
  if (Math.round(base * 10 ** bd) / 10 ** bd !== base) return `Gives ${base} ${l.product.product.base_uom.code}, which needs whole units`;
  return null;
}

export function UnitQty({ line, onChange, disabled, allowNegative, autoFocus, big }: {
  line: TxnLine; onChange: (patch: Partial<TxnLine>) => void; disabled?: boolean; allowNegative?: boolean; autoFocus?: boolean; big?: boolean;
}) {
  const u = unitOf(line);
  const err = line.qty !== '' ? qtyError(line, { allowNegative }) : null;
  const base = baseQty(line);
  return (
    <div>
      <div className="flex gap-2">
        <Input
          aria-label={`Quantity of ${line.product.product.sku}`}
          inputMode={allowNegative ? 'text' : 'decimal'}
          value={line.qty}
          disabled={disabled}
          autoFocus={autoFocus}
          onChange={(e) => onChange({ qty: e.target.value })}
          className={cx('w-32 text-right font-semibold tabular-nums', big && 'h-12 text-lg', err && 'border-bad-600', line.flash && 'ring-4 ring-signal-300')}
          placeholder="Qty"
        />
        <Select value={line.uom_id} onChange={(e) => onChange({ uom_id: e.target.value })} disabled={disabled} className={cx('w-28', big && 'h-12')} aria-label="Unit">
          {line.product.units.map((x) => <option key={x.uom_id} value={x.uom_id}>{x.code}{x.factor !== 1 ? ` (${fmtQty(x.factor)})` : ''}</option>)}
        </Select>
      </div>
      {err && <div className="mt-1 text-xs text-bad-600">{err}</div>}
      {!err && base !== null && u.factor !== 1 && <div className="mt-1 text-xs text-steel-600">= {fmtQty(base)} {line.product.product.base_uom.code}</div>}
    </div>
  );
}

export function ProductCell({ line }: { line: TxnLine }) {
  return (
    <div className="min-w-0">
      <div className="font-mono text-[13px] font-semibold text-navy-900">{line.product.product.sku}</div>
      <div className="text-sm text-steel-800">{line.product.product.description}</div>
    </div>
  );
}

export function RemoveLine({ onClick, disabled }: { onClick: () => void; disabled?: boolean }) {
  return (
    <button type="button" onClick={onClick} disabled={disabled} className="rounded p-2 text-steel-600 hover:bg-bad-50 hover:text-bad-600" aria-label="Remove line">
      <Trash2 className="size-4" />
    </button>
  );
}

/** available stock per location for a product line (status available unless given) */
export function stockAt(p: ProductLookup, locationId: string, status = 'available', owner?: string) {
  return p.balances.filter((b) => b.location_id === locationId && b.status === status && (!owner || b.owner_company_id === owner))
    .reduce((s, b) => s + Number(b.qty), 0);
}
