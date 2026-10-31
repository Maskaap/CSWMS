'use client';
// Offline counting.
// Every count is first written to this phone (IndexedDB) and then sent to the database.
// Each count carries its own request id, so sending it twice (bad signal, page reload,
// two tabs) still stores it once. Only stocktake COUNTS are queued — receipts, withdrawals
// and every other stock transaction still need a live connection.
import { supabaseBrowser } from '@/lib/supabase/client';
import { toAppError } from '@/lib/errors';

export type QueuedCount = {
  request_id: string;
  stocktake_id: string;
  product_id: string;
  location_id: string;
  qty: number;
  uom_id: string | null;
  factor: number;               // base units per entered unit (for the on-screen running total)
  method: 'typed' | 'scan' | 'empty_bin';
  counted_at: string;           // phone time
  captured_offline: boolean;
  status: 'pending' | 'failed';
  error?: string;
  attempts: number;
  label: string;                // SKU · bin, for the list on screen
};
export type Pack = Record<string, unknown> & { generated_at: string };

const DB_NAME = 'cswms-counting';
const VERSION = 1;
let dbp: Promise<IDBDatabase> | null = null;

function db(): Promise<IDBDatabase> {
  dbp ??= new Promise((resolve, reject) => {
    const r = indexedDB.open(DB_NAME, VERSION);
    r.onupgradeneeded = () => {
      const d = r.result;
      if (!d.objectStoreNames.contains('packs')) d.createObjectStore('packs');
      if (!d.objectStoreNames.contains('counts')) d.createObjectStore('counts', { keyPath: 'request_id' }).createIndex('stocktake', 'stocktake_id');
    };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => { dbp = null; reject(r.error); };
  });
  return dbp;
}

function tx<T>(store: string, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return db().then((d) => new Promise<T>((resolve, reject) => {
    const t = d.transaction(store, mode);
    const req = fn(t.objectStore(store));
    t.oncomplete = () => resolve(req.result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
  }));
}

// ---- change notifications (all open screens update together) ----
const listeners = new Set<() => void>();
export function onQueueChange(fn: () => void) { listeners.add(fn); return () => { listeners.delete(fn); }; }
const emit = () => listeners.forEach((f) => f());

// ---- the count list kept on the phone ----
export async function savePack(stocktakeId: string, pack: Pack) {
  await tx('packs', 'readwrite', (s) => s.put(pack, stocktakeId));
}
export async function loadPack(stocktakeId: string): Promise<Pack | undefined> {
  return tx<Pack | undefined>('packs', 'readonly', (s) => s.get(stocktakeId) as IDBRequest<Pack | undefined>);
}
export async function fetchPack(stocktakeId: string): Promise<Pack> {
  const { data, error } = await supabaseBrowser().rpc('stocktake_offline_pack', { p_stocktake_id: stocktakeId });
  if (error) throw toAppError(error);
  const pack = data as Pack;
  await savePack(stocktakeId, pack);
  return pack;
}

// ---- queued counts ----
export async function queued(stocktakeId?: string): Promise<QueuedCount[]> {
  const all = await tx<QueuedCount[]>('counts', 'readonly', (s) => s.getAll() as IDBRequest<QueuedCount[]>);
  return all.filter((c) => !stocktakeId || c.stocktake_id === stocktakeId).sort((a, b) => a.counted_at.localeCompare(b.counted_at));
}

export async function enqueue(c: Omit<QueuedCount, 'request_id' | 'counted_at' | 'captured_offline' | 'status' | 'attempts'>) {
  const item: QueuedCount = {
    ...c, request_id: crypto.randomUUID(), counted_at: new Date().toISOString(),
    captured_offline: typeof navigator !== 'undefined' && !navigator.onLine, status: 'pending', attempts: 0,
  };
  await tx('counts', 'readwrite', (s) => s.put(item));
  emit();
  void sync();
  return item;
}

/** remove a count that has not been sent yet (a wrong scan) */
export async function discard(requestId: string) {
  await tx('counts', 'readwrite', (s) => s.delete(requestId));
  emit();
}

export type SentResult = { request_id: string; stocktake_id: string; product_id: string; location_id: string; line_total: number; late?: boolean };
const sentListeners = new Set<(r: SentResult) => void>();
export function onSent(fn: (r: SentResult) => void) { sentListeners.add(fn); return () => { sentListeners.delete(fn); }; }

let syncing: Promise<void> | null = null;
let again = false;      // a count was added while a run was busy
/** send every waiting count, oldest first; safe to call any time and from several places */
export function sync(): Promise<void> {
  if (syncing) { again = true; return syncing; }
  again = false;
  const run = (async () => {
    try {
      await Promise.resolve();
      if (typeof navigator !== 'undefined' && !navigator.onLine) return;
      const list = (await queued()).filter((c) => c.status === 'pending');
      for (const c of list) {
        const ageSec = (Date.now() - Date.parse(c.counted_at)) / 1000;
        let res;
        try {
          // never wait for ever on a bad connection: give up after 15 s and try again later (same request id)
          const timeout = new Promise<never>((_, reject) => setTimeout(() => reject(new TypeError('timeout')), 15000));
          res = await Promise.race([timeout, supabaseBrowser().rpc('record_count', {
            p_request_id: c.request_id, p_stocktake_id: c.stocktake_id, p_product_id: c.product_id, p_location_id: c.location_id,
            p_qty: c.qty, p_uom_id: c.uom_id, p_counted_at: c.counted_at, p_offline: c.captured_offline || ageSec > 30, p_method: c.method,
          }).then((r) => r)]);
        } catch (e) {
          console.debug('[count-sync] waiting for the connection', e);
          return;                                       // network gone: keep everything, try again later
        }
        if (res.error) {
          const e = toAppError(res.error);
          console.debug('[count-sync] error', e);
          if (e.kind === 'network') return;             // unknown outcome — retry later with the same request id
          await tx('counts', 'readwrite', (s) => s.put({ ...c, status: 'failed', error: e.message, attempts: c.attempts + 1 }));
          emit();
          continue;
        }
        await tx('counts', 'readwrite', (s) => s.delete(c.request_id));
        const d = res.data as { line_total?: number; late?: boolean };
        sentListeners.forEach((f) => f({ request_id: c.request_id, stocktake_id: c.stocktake_id, product_id: c.product_id,
          location_id: c.location_id, line_total: Number(d?.line_total ?? 0), late: d?.late }));
        emit();
      }
    } catch (e) {
      console.debug('[count-sync]', e);
    }
  })();
  // cleared only after the run has finished (a run that ends at once must not leave a stale lock behind)
  syncing = run;
  void run.finally(() => {
    if (syncing === run) syncing = null;
    if (again && (typeof navigator === 'undefined' || navigator.onLine)) void sync();
  });
  return run;
}

// keep trying in the background while a counting screen is open
let started = false;
export function startBackgroundSync() {
  if (started || typeof window === 'undefined') return;
  started = true;
  window.addEventListener('online', () => void sync());
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') void sync(); });
  setInterval(() => void sync(), 20000);
  (window as unknown as { __cswmsCountSync?: () => Promise<void> }).__cswmsCountSync = sync;   // support / tests
}
