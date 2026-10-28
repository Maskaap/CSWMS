'use client';
import { useCallback, useRef, useState } from 'react';
import { supabaseBrowser } from '@/lib/supabase/client';
import { toAppError, type AppError } from '@/lib/errors';

export type TxnState =
  | { phase: 'idle' }
  | { phase: 'saving' }
  | { phase: 'saved'; result: Record<string, unknown> }
  | { phase: 'failed'; error: AppError }
  /** the request may or may not have reached the database — never shown as saved */
  | { phase: 'unconfirmed'; error: AppError };

const newId = () => crypto.randomUUID();

/**
 * Safe stock-transaction submission:
 *  - one request id per transaction attempt; retries reuse it, so the database
 *    posts the transaction at most once (idempotency),
 *  - ignores double clicks while a request is in flight,
 *  - only reports "saved" after the database has confirmed the commit,
 *  - when the connection fails the state is "unconfirmed" and the user can retry safely.
 */
export function useTransaction(fn: string) {
  const [state, setState] = useState<TxnState>({ phase: 'idle' });
  const requestId = useRef<string>(newId());
  const inFlight = useRef(false);
  const lastArgs = useRef<Record<string, unknown> | null>(null);

  const run = useCallback(async (args: Record<string, unknown>, opts?: { retry?: boolean }) => {
    if (inFlight.current) return null;              // double-click protection
    if (!opts?.retry) {
      // a changed payload is a new transaction -> new id (unless we are retrying an unconfirmed one)
      if (JSON.stringify(args) !== JSON.stringify(lastArgs.current)) requestId.current = newId();
    }
    lastArgs.current = args;
    inFlight.current = true;
    setState({ phase: 'saving' });
    try {
      if (typeof navigator !== 'undefined' && !navigator.onLine) {
        throw new TypeError('offline');
      }
      const { data, error } = await supabaseBrowser().rpc(fn, { p_request_id: requestId.current, ...args });
      if (error) {
        const e = toAppError(error);
        setState(e.kind === 'network' ? { phase: 'unconfirmed', error: e } : { phase: 'failed', error: e });
        return null;
      }
      const result = data as Record<string, unknown>;
      if (!result || result.ok !== true) {
        setState({ phase: 'unconfirmed', error: { kind: 'unknown', message: 'The server did not confirm the transaction.' } });
        return null;
      }
      setState({ phase: 'saved', result });
      requestId.current = newId();                   // next transaction gets a fresh id
      lastArgs.current = null;
      return result;
    } catch (e) {
      setState({ phase: 'unconfirmed', error: toAppError(e) });
      return null;
    } finally {
      inFlight.current = false;
    }
  }, [fn]);

  const retry = useCallback(async () => {
    if (!lastArgs.current) return null;
    return run(lastArgs.current, { retry: true });
  }, [run]);

  const reset = useCallback(() => {
    setState({ phase: 'idle' });
    requestId.current = newId();
    lastArgs.current = null;
  }, []);

  return { state, run, retry, reset, requestId: requestId.current };
}

/** Plain RPC call for non-idempotent-sensitive actions (reads, approvals, settings). */
export async function callRpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<{ data: T | null; error: AppError | null }> {
  try {
    const { data, error } = await supabaseBrowser().rpc(fn, args ?? {});
    if (error) return { data: null, error: toAppError(error) };
    return { data: data as T, error: null };
  } catch (e) {
    return { data: null, error: toAppError(e) };
  }
}
