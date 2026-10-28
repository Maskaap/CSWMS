'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { supabaseBrowser } from '@/lib/supabase/client';
import { toAppError } from '@/lib/errors';
import type { SupabaseClient } from '@supabase/supabase-js';

// Row shapes are declared by the caller (no generated DB types), so the query result is untyped here.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Result = PromiseLike<{ data: any; error: unknown; count?: number | null }>;

/**
 * Loads rows through the signed-in user's session (RLS applies).
 * `deps` re-run the query; pass `null` as key to skip.
 */
export function useRows<T = Record<string, unknown>>(
  key: string | null,
  query: (sb: SupabaseClient) => Result,
): { rows: T[]; loading: boolean; error: string | null; count: number | null; reload: () => void } {
  const [rows, setRows] = useState<T[]>([]);
  const [loading, setLoading] = useState(key !== null);
  const [error, setError] = useState<string | null>(null);
  const [count, setCount] = useState<number | null>(null);
  const [tick, setTick] = useState(0);
  const q = useRef(query);
  q.current = query;

  const lastKey = useRef<string | null>(null);

  useEffect(() => {
    if (key === null) { setRows([]); setLoading(false); lastKey.current = null; return; }
    let live = true;
    // Show "loading" only for a new query. A reload of the same query refreshes in
    // the background so screens (and the state of their child panels) stay mounted.
    if (lastKey.current !== key) setLoading(true);
    lastKey.current = key;
    Promise.resolve(q.current(supabaseBrowser())).then(
      (res) => {
        if (!live) return;
        if (res.error) { setError(toAppError(res.error).message); setRows([]); }
        else {
          setError(null);
          const d = res.data;
          setRows(Array.isArray(d) ? d : d == null ? [] : [d as T]);
          setCount(res.count ?? null);
        }
        setLoading(false);
      },
      (e) => { if (live) { setError(toAppError(e).message); setLoading(false); } },
    );
    return () => { live = false; };
  }, [key, tick]);

  const reload = useCallback(() => setTick((t) => t + 1), []);
  return { rows, loading, error, count, reload };
}

/** Single RPC result (e.g. a jsonb summary) that can be reloaded. */
export function useRpc<T = unknown>(key: string | null, fn: string, args?: Record<string, unknown>) {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(key !== null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const lastKey = useRef<string | null>(null);
  const a = useRef(args);
  a.current = args;
  useEffect(() => {
    if (key === null) { setLoading(false); return; }
    let live = true;
    if (lastKey.current !== key) setLoading(true);
    lastKey.current = key;
    supabaseBrowser().rpc(fn, a.current ?? {}).then(({ data, error }) => {
      if (!live) return;
      if (error) setError(toAppError(error).message); else { setError(null); setData(data as T); }
      setLoading(false);
    }, (e) => { if (live) { setError(toAppError(e).message); setLoading(false); } });
    return () => { live = false; };
  }, [key, fn, tick]);
  return { data, loading, error, reload: useCallback(() => setTick((t) => t + 1), []) };
}
