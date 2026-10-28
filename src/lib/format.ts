// South African display conventions: Africa/Johannesburg, DD/MM/YYYY, ZAR.
const TZ = 'Africa/Johannesburg';

const dateFmt = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric' });
const timeFmt = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false });

export function fmtDate(v?: string | Date | null): string {
  if (!v) return '—';
  const d = typeof v === 'string' ? new Date(v.length === 10 ? v + 'T12:00:00' : v) : v;
  return isNaN(d.getTime()) ? '—' : dateFmt.format(d);
}

export function fmtDateTime(v?: string | Date | null): string {
  if (!v) return '—';
  const d = typeof v === 'string' ? new Date(v) : v;
  return isNaN(d.getTime()) ? '—' : `${dateFmt.format(d)} ${timeFmt.format(d)}`;
}

export function fmtTime(v?: string | Date | null): string {
  if (!v) return '—';
  const d = typeof v === 'string' ? new Date(v) : v;
  return isNaN(d.getTime()) ? '—' : timeFmt.format(d);
}

const qtyFmt = new Intl.NumberFormat('en-ZA', { maximumFractionDigits: 4 });
export function fmtQty(v: number | string | null | undefined): string {
  if (v === null || v === undefined || v === '') return '—';
  const n = typeof v === 'string' ? Number(v) : v;
  return isNaN(n) ? '—' : qtyFmt.format(n);
}

export function fmtSigned(v: number | string | null | undefined): string {
  if (v === null || v === undefined) return '—';
  const n = Number(v);
  return (n > 0 ? '+' : '') + fmtQty(n);
}

const zar = new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR' });
export function fmtZAR(v: number | string | null | undefined): string {
  if (v === null || v === undefined || v === '') return '—';
  return zar.format(Number(v));
}

/** Parses a typed quantity: accepts "1 234,5", "1234.5", "1,234.5" is ambiguous so only one separator is allowed. */
export function parseQty(input: string): number | null {
  const s = input.replace(/\s/g, '');
  if (s === '') return null;
  if (!/^-?\d+([.,]\d+)?$/.test(s)) return NaN;
  return Number(s.replace(',', '.'));
}

/** today's date in Johannesburg as YYYY-MM-DD */
export function todayISO(): string {
  const p = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return p;
}
export function currentPeriod(): string {
  return todayISO().slice(0, 7);
}

export const TXN_LABELS: Record<string, string> = {
  opening: 'Opening balance',
  receipt: 'Receipt',
  withdrawal: 'Withdrawal',
  return: 'Return',
  move: 'Location move',
  transfer_dispatch: 'Transfer dispatched',
  transfer_receipt: 'Transfer received',
  transfer_writeoff: 'Transfer write-off',
  adjustment: 'Adjustment',
  stocktake_adjustment: 'Stocktake adjustment',
  status_change: 'Status change',
  reversal: 'Reversal',
};

export const STATUS_LABELS: Record<string, string> = {
  available: 'Available',
  damaged: 'Damaged',
  quarantine: 'Quarantine',
  in_transit: 'In transit',
};

/** strips characters that have meaning in PostgREST filter syntax */
export const cleanSearch = (s: string) => s.replace(/[,()%*\\:"']/g, ' ').trim();
