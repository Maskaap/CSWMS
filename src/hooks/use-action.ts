'use client';
import { useCallback, useRef, useState } from 'react';
import { callRpc } from './use-transaction';
import type { AppError } from '@/lib/errors';

/**
 * For management actions that are not stock postings (approvals, assignments,
 * settings). Prevents double submission and exposes a clear result message.
 */
export function useAction() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<AppError | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const inFlight = useRef(false);

  const run = useCallback(async <T = Record<string, unknown>>(fn: string, args: Record<string, unknown>, success?: string): Promise<T | null> => {
    if (inFlight.current) return null;
    inFlight.current = true;
    setBusy(true); setError(null); setOk(null);
    const { data, error } = await callRpc<T>(fn, args);
    inFlight.current = false;
    setBusy(false);
    if (error) { setError(error); return null; }
    if (success) setOk(success);
    return data;
  }, []);

  const clear = useCallback(() => { setError(null); setOk(null); }, []);
  return { busy, error, ok, run, clear, setError, setOk };
}
