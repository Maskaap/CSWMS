'use client';
import Link from 'next/link';
import { RotateCcw } from 'lucide-react';
import type { TxnState } from '@/hooks/use-transaction';
import { Button, Notice } from './ui';

/** Shows the definitive result of a stock transaction. "Saved" only after database confirmation. */
export function TxnOutcome({ state, onRetry, onNew, savedText }: {
  state: TxnState; onRetry: () => void; onNew?: () => void; savedText?: (r: Record<string, unknown>) => React.ReactNode;
}) {
  if (state.phase === 'idle') return null;
  if (state.phase === 'saving') return <Notice tone="info" title="Saving…">Waiting for the database to confirm. Do not close this page.</Notice>;
  if (state.phase === 'saved') {
    const r = state.result;
    return (
      <Notice tone="ok" title={`Saved — ${String(r.txn_no ?? r.transfer_no ?? '')}`.replace(/ — $/, '')}>
        <div>{savedText ? savedText(r) : r.status === 'pending_approval' ? 'Submitted for management approval. Stock will change only after approval.' : 'Stock has been updated.'}</div>
        {r.duplicate === true && <div className="mt-1 text-xs">This was a repeat of a request that had already been saved — it was not posted twice.</div>}
        <div className="mt-2 flex flex-wrap gap-2">
          {typeof r.txn_id === 'string' && <Link className="text-sm font-medium text-navy-800 underline" href={`/transactions/${r.txn_id}`}>View transaction</Link>}
          {typeof r.transfer_id === 'string' && <Link className="text-sm font-medium text-navy-800 underline" href={`/transfers/${r.transfer_id}`}>View transfer</Link>}
          {onNew && <button type="button" onClick={onNew} className="text-sm font-medium text-navy-800 underline">Start a new one</button>}
        </div>
      </Notice>
    );
  }
  if (state.phase === 'unconfirmed') {
    return (
      <Notice tone="bad" title="NOT CONFIRMED — check before re-entering">
        <p>{state.error.message} It is unknown whether the transaction reached the database.</p>
        <p className="mt-1">Press <b>Retry safely</b>: if it was already saved it will not be posted again.</p>
        <Button className="mt-2" variant="navy" size="sm" onClick={onRetry}><RotateCcw className="size-4" />Retry safely</Button>
      </Notice>
    );
  }
  const e = state.error;
  return (
    <Notice tone="bad" title={e.kind === 'insufficient' ? 'Not enough stock — nothing was saved' : e.kind === 'permission' ? 'Not permitted — nothing was saved' : 'Not saved'}>
      {e.message}
    </Notice>
  );
}
