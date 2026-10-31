'use client';
import { useEffect, useState } from 'react';
import { Undo2 } from 'lucide-react';
import { useApp } from './app-context';
import { TxnOutcome } from './txn-outcome';
import { Button, Dialog, Field, Input } from './ui';
import { useTransaction } from '@/hooks/use-transaction';

/**
 * "Oops" button: undo your own receipt / withdrawal / return / move / status change within
 * the undo window (setting undo.minutes, default 10). The database checks the window, the
 * owner and the type, posts a linked reversal and records it as approved under the
 * self-correction rule — so it is fully visible in the audit trail.
 */
export function UndoButton({ txnId, txnNo, postedAt, onDone, size = 'sm' }: {
  txnId: string; txnNo: string; postedAt?: string | null; onDone?: () => void; size?: 'sm' | 'md';
}) {
  const { t, me } = useApp();
  const minutes = Number((me?.settings as Record<string, unknown> | undefined)?.['undo.minutes'] ?? 10);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [left, setLeft] = useState<number | null>(null);
  const undo = useTransaction('undo_my_transaction');
  const [start] = useState(() => postedAt ?? new Date().toISOString());

  useEffect(() => {
    if (minutes <= 0) return;
    const end = Date.parse(start) + minutes * 60e3;
    const tick = () => setLeft(Math.max(0, Math.round((end - Date.now()) / 1000)));
    tick();
    const h = setInterval(tick, 1000);
    return () => clearInterval(h);
  }, [start, minutes]);

  if (minutes <= 0 || (left !== null && left <= 0 && undo.state.phase !== 'saved')) return null;
  const mmss = left == null ? '' : `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;

  return (
    <>
      <Button size={size} onClick={() => setOpen(true)} disabled={undo.state.phase === 'saved'}>
        <Undo2 className="size-4" />{undo.state.phase === 'saved' ? t('undo_done') : `${t('undo')} ${txnNo}`}{mmss && undo.state.phase !== 'saved' && <span className="font-mono text-xs text-steel-600">({mmss} {t('seconds_left')})</span>}
      </Button>
      <Dialog open={open} onClose={() => setOpen(false)} title={`${t('undo')} ${txnNo}`}
        footer={undo.state.phase === 'saved'
          ? <Button onClick={() => { setOpen(false); onDone?.(); }}>OK</Button>
          : <><Button onClick={() => setOpen(false)}>{t('back')}</Button>
             <Button variant="danger" busy={undo.state.phase === 'saving'} disabled={!reason.trim()}
               onClick={() => undo.run({ p_txn_id: txnId, p_reason: reason.trim() })}><Undo2 className="size-4" />{t('undo')}</Button></>}>
        {undo.state.phase !== 'saved' && (
          <Field label={t('undo_reason')} hint={t('undo_reason_hint')} required>
            <Input value={reason} onChange={(e) => setReason(e.target.value)} autoFocus maxLength={200} />
          </Field>
        )}
        <div className="mt-3"><TxnOutcome state={undo.state} onRetry={undo.retry} savedText={() => t('undo_done')} /></div>
      </Dialog>
    </>
  );
}
