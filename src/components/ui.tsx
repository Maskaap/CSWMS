'use client';
import { forwardRef, useEffect, useRef, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode, type SelectHTMLAttributes, type TextareaHTMLAttributes } from 'react';
import { AlertTriangle, CheckCircle2, Info, Loader2, WifiOff, XCircle } from 'lucide-react';

export function cx(...c: (string | false | null | undefined | 0)[]) { return c.filter(Boolean).join(' '); }

// ---------------------------------------------------------------- buttons
type BtnVariant = 'primary' | 'secondary' | 'danger' | 'ghost' | 'navy';
const btnBase = 'inline-flex items-center justify-center gap-2 rounded-md font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed select-none';
const btnVariants: Record<BtnVariant, string> = {
  primary: 'bg-signal-400 text-navy-950 hover:bg-signal-500 border border-signal-500',
  navy: 'bg-navy-900 text-white hover:bg-navy-800 border border-navy-900',
  secondary: 'bg-white text-navy-900 border border-steel-200 hover:bg-steel-50',
  danger: 'bg-bad-600 text-white hover:bg-red-800 border border-bad-600',
  ghost: 'text-navy-900 hover:bg-steel-100',
};
const btnSizes = { sm: 'h-8 px-3 text-sm', md: 'h-10 px-4 text-sm', lg: 'h-14 px-6 text-base' };

export const Button = forwardRef<HTMLButtonElement, ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: BtnVariant; size?: keyof typeof btnSizes; busy?: boolean;
}>(function Button({ variant = 'secondary', size = 'md', busy, className, children, disabled, ...rest }, ref) {
  return (
    <button ref={ref} className={cx(btnBase, btnVariants[variant], btnSizes[size], className)} disabled={disabled || busy} {...rest}>
      {busy && <Loader2 className="size-4 animate-spin" aria-hidden />}
      {children}
    </button>
  );
});

// ---------------------------------------------------------------- form controls
const inputCls = 'w-full rounded-md border border-steel-200 bg-white px-3 h-10 text-sm text-steel-800 placeholder:text-steel-400 focus:border-navy-700 focus:outline-none disabled:bg-steel-50 disabled:text-steel-400';

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function Input({ className, ...rest }, ref) {
  return <input ref={ref} className={cx(inputCls, className)} {...rest} />;
});

export const Select = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement>>(function Select({ className, children, ...rest }, ref) {
  return <select ref={ref} className={cx(inputCls, 'pr-8', className)} {...rest}>{children}</select>;
});

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement>>(function Textarea({ className, ...rest }, ref) {
  return <textarea ref={ref} className={cx(inputCls, 'h-auto min-h-20 py-2', className)} {...rest} />;
});

export function Field({ label, hint, error, children, required, className }: {
  label: string; hint?: ReactNode; error?: string | null; children: ReactNode; required?: boolean; className?: string;
}) {
  return (
    <label className={cx('block', className)}>
      <span className="mb-1 block text-sm font-medium text-navy-900">{label}{required && <span className="text-bad-600"> *</span>}</span>
      {children}
      {hint && !error && <span className="mt-1 block text-xs text-steel-600">{hint}</span>}
      {error && <span className="mt-1 block text-xs text-bad-600">{error}</span>}
    </label>
  );
}

// ---------------------------------------------------------------- layout
export function PageHeader({ title, description, actions }: { title: string; description?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-navy-900">{title}</h1>
        {description && <p className="mt-1 max-w-3xl text-sm text-steel-600">{description}</p>}
      </div>
      {actions && <div className="flex flex-wrap gap-2">{actions}</div>}
    </div>
  );
}

export function Panel({ title, actions, children, className, padded = true }: {
  title?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string; padded?: boolean;
}) {
  return (
    <section className={cx('rounded-lg border border-steel-200 bg-white', className)}>
      {(title || actions) && (
        <header className="flex items-center justify-between gap-3 border-b border-steel-100 px-4 py-3">
          {title && <h2 className="text-sm font-semibold text-navy-900">{title}</h2>}
          {actions}
        </header>
      )}
      <div className={padded ? 'p-4' : ''}>{children}</div>
    </section>
  );
}

export function Stat({ label, value, tone, sub, href }: { label: string; value: ReactNode; tone?: Tone; sub?: ReactNode; href?: string }) {
  const body = (
    <div className={cx('rounded-lg border bg-white p-4', tone ? toneBorder[tone] : 'border-steel-200')}>
      <div className="text-sm text-steel-600">{label}</div>
      <div className={cx('mt-1 text-2xl font-semibold tabular-nums', tone ? toneText[tone] : 'text-navy-900')}>{value}</div>
      {sub && <div className="mt-1 text-xs text-steel-600">{sub}</div>}
    </div>
  );
  return href ? <a href={href} className="block hover:opacity-90">{body}</a> : body;
}

// ---------------------------------------------------------------- tones / badges
export type Tone = 'ok' | 'warn' | 'bad' | 'idle' | 'info';
const toneBg: Record<Tone, string> = { ok: 'bg-ok-50 text-ok-600', warn: 'bg-warn-50 text-warn-600', bad: 'bg-bad-50 text-bad-600', idle: 'bg-idle-50 text-idle-600', info: 'bg-navy-100 text-navy-800' };
const toneBorder: Record<Tone, string> = { ok: 'border-ok-600/40', warn: 'border-warn-600/40', bad: 'border-bad-600/50', idle: 'border-steel-200', info: 'border-navy-700/30' };
const toneText: Record<Tone, string> = { ok: 'text-ok-600', warn: 'text-warn-600', bad: 'text-bad-600', idle: 'text-idle-600', info: 'text-navy-800' };

export function Badge({ tone = 'idle', children, className }: { tone?: Tone; children: ReactNode; className?: string }) {
  return <span className={cx('inline-flex items-center gap-1 rounded px-2 py-0.5 text-xs font-medium whitespace-nowrap', toneBg[tone], className)}>{children}</span>;
}

export function statusTone(s: string): Tone {
  if (['posted', 'approved', 'finalised', 'received', 'completed', 'passed', 'resolved', 'active', 'GREEN', 'ok', 'sent', 'paid'].includes(s)) return 'ok';
  if (['pending', 'pending_approval', 'partially_received', 'dispatched', 'counting', 'review', 'investigating', 'warnings', 'warning', 'low', 'AMBER', 'acknowledged', 'scheduled', 'draft', 'submitted', 'in_transit', 'issued', 'partly_credited', 'overdue'].includes(s)) return 'warn';
  if (['rejected', 'failed', 'critical', 'discrepancies', 'out', 'RED', 'open', 'closed_with_discrepancy'].includes(s)) return 'bad';
  return 'idle';
}

export function StatusBadge({ status, label }: { status: string; label?: string }) {
  return <Badge tone={statusTone(status)}>{label ?? status.replace(/_/g, ' ')}</Badge>;
}

// ---------------------------------------------------------------- messages
export function Notice({ tone = 'info', title, children, className }: { tone?: Tone; title?: ReactNode; children?: ReactNode; className?: string }) {
  const Icon = tone === 'ok' ? CheckCircle2 : tone === 'bad' ? XCircle : tone === 'warn' ? AlertTriangle : Info;
  return (
    <div role={tone === 'bad' ? 'alert' : 'status'} className={cx('flex gap-3 rounded-md border p-3 text-sm', toneBg[tone], toneBorder[tone], className)}>
      <Icon className="mt-0.5 size-5 shrink-0" aria-hidden />
      <div className="min-w-0">
        {title && <div className="font-semibold">{title}</div>}
        {children && <div className="text-steel-800">{children}</div>}
      </div>
    </div>
  );
}

export function OfflineNotice() {
  return (
    <Notice tone="bad" title="No internet connection">
      <span className="inline-flex items-center gap-1"><WifiOff className="size-4" /> Transactions are disabled until the connection is restored. Nothing is saved offline.</span>
    </Notice>
  );
}

export function Spinner({ label = 'Loading…' }: { label?: string }) {
  return <div className="flex items-center gap-2 p-6 text-sm text-steel-600"><Loader2 className="size-4 animate-spin" />{label}</div>;
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="rounded-lg border border-dashed border-steel-200 bg-white p-8 text-center">
      <div className="font-medium text-navy-900">{title}</div>
      {children && <div className="mt-1 text-sm text-steel-600">{children}</div>}
    </div>
  );
}

// ---------------------------------------------------------------- table
export function Table({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cx('overflow-x-auto rounded-lg border border-steel-200 bg-white', className)}>
      <table className="w-full border-collapse text-sm">{children}</table>
    </div>
  );
}
export function Th({ children, className, right }: { children?: ReactNode; className?: string; right?: boolean }) {
  return <th className={cx('border-b border-steel-200 bg-steel-50 px-3 py-2 text-left text-xs font-semibold text-steel-600', right && 'text-right', className)}>{children}</th>;
}
export function Td({ children, className, right, mono }: { children?: ReactNode; className?: string; right?: boolean; mono?: boolean }) {
  return <td className={cx('border-b border-steel-100 px-3 py-2 align-top', right && 'text-right tabular-nums', mono && 'font-mono text-[13px]', className)}>{children}</td>;
}

// ---------------------------------------------------------------- dialog
export function Dialog({ open, onClose, title, children, footer, wide }: {
  open: boolean; onClose: () => void; title: string; children: ReactNode; footer?: ReactNode; wide?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current; if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);
  return (
    <dialog ref={ref} onClose={onClose} onCancel={(e) => { e.preventDefault(); onClose(); }}
      className={cx('m-auto w-[calc(100%-2rem)] rounded-lg border border-steel-200 p-0 backdrop:bg-navy-950/50', wide ? 'max-w-4xl' : 'max-w-lg')}>
      <div className="border-b border-steel-100 px-5 py-4"><h2 className="text-lg font-semibold text-navy-900">{title}</h2></div>
      <div className="max-h-[70vh] overflow-y-auto px-5 py-4">{children}</div>
      {footer && <div className="flex flex-wrap justify-end gap-2 border-t border-steel-100 px-5 py-3">{footer}</div>}
    </dialog>
  );
}

export function Code({ children }: { children: ReactNode }) {
  return <span className="font-mono text-[13px] text-navy-900">{children}</span>;
}
