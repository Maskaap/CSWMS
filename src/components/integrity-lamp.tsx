'use client';
import Link from 'next/link';
import { ShieldAlert, ShieldCheck, ShieldOff, ShieldQuestion } from 'lucide-react';
import { fmtDateTime } from '@/lib/format';
import { cx } from './ui';

export type IntegrityStatus = {
  status: 'GREEN' | 'AMBER' | 'RED' | 'GREY'; reason: string; last_success_at: string | null; last_run_status: string | null;
  last_run_no: string | null; keys_checked: number | null; locations_checked: number | null; products_checked: number | null;
  reconciliations_passed: number | null; mismatches: number | null; open_critical: number; open_warnings: number; investigating: number;
};

const STYLE = {
  GREEN: { ring: 'border-ok-600 bg-ok-50', dot: 'bg-ok-600', text: 'text-ok-600', Icon: ShieldCheck, label: 'GREEN — consistent' },
  AMBER: { ring: 'border-warn-600 bg-warn-50', dot: 'bg-warn-600', text: 'text-warn-600', Icon: ShieldAlert, label: 'AMBER — needs attention' },
  RED: { ring: 'border-bad-600 bg-bad-50', dot: 'bg-bad-600', text: 'text-bad-600', Icon: ShieldOff, label: 'RED — integrity problem' },
  GREY: { ring: 'border-idle-600 bg-idle-50', dot: 'bg-idle-600', text: 'text-idle-600', Icon: ShieldQuestion, label: 'GREY — cannot be verified' },
};

export function IntegrityLamp({ s, compact }: { s: IntegrityStatus; compact?: boolean }) {
  const st = STYLE[s.status] ?? STYLE.GREY;
  return (
    <Link href="/integrity" className={cx('flex items-start gap-4 rounded-lg border-2 p-4', st.ring)}>
      <span className="relative mt-1 flex size-5 shrink-0">
        <span className={cx('absolute inline-flex size-full rounded-full opacity-30', st.dot, s.status !== 'GREEN' && 'animate-ping')} />
        <span className={cx('relative inline-flex size-5 rounded-full', st.dot)} />
      </span>
      <div className="min-w-0">
        <div className={cx('flex items-center gap-2 font-semibold', st.text)}><st.Icon className="size-5" />Stock integrity: {st.label}</div>
        <div className="mt-0.5 text-sm text-steel-800">{s.reason}</div>
        {!compact && (
          <div className="mt-1 text-xs text-steel-600">
            Last successful check: {s.last_success_at ? fmtDateTime(s.last_success_at) : 'never'}
            {s.keys_checked != null && <> · {s.keys_checked} balances verified</>}
          </div>
        )}
      </div>
    </Link>
  );
}
