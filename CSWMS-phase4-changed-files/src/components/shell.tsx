'use client';
import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { useEffect, useState, type ReactNode } from 'react';
import {
  ArrowDownToLine, ArrowLeftRight, ArrowUpFromLine, Bell, BookmarkCheck, Boxes, Building2, ShoppingCart, Wrench, ClipboardCheck, FileBarChart, LayoutDashboard, TrendingUp,
  ListTodo, LogOut, Menu, RotateCcw, ScanLine, Settings, ShieldCheck, Stamp, UserCog, Users, WifiOff, X,
} from 'lucide-react';
import type { Key } from '@/lib/i18n';
import { supabaseBrowser } from '@/lib/supabase/client';
import { useOnline } from '@/hooks/use-online';
import { CTX_KEY, useApp } from './app-context';
import { Button, Select, Spinner, cx } from './ui';

type NavItem = { href: string; label: string; icon: typeof LayoutDashboard; show: (can: (p: string) => boolean) => boolean; tk?: Key };

// Main menu — order as specified for CSWMS
const NAV: NavItem[] = [
  { href: '/tasks', label: 'My tasks', icon: ListTodo, show: () => true },
  { href: '/', label: 'Dashboard', icon: LayoutDashboard, show: () => true },
  { href: '/stock', label: 'All Stock', icon: Boxes, show: (c) => c('stock.view') },
  { href: '/receive', label: 'Receive Stock', icon: ArrowDownToLine, show: (c) => c('stock.receive') },
  { href: '/withdraw', label: 'Withdraw Stock', icon: ArrowUpFromLine, show: (c) => c('stock.withdraw') },
  { href: '/transfers', label: 'Transfer Stock', icon: ArrowLeftRight, show: (c) => c('stock.transfer.dispatch') || c('stock.transfer.receive') },
  { href: '/corrections', label: 'Returns & Corrections', icon: RotateCcw, show: (c) => c('stock.return') || c('stock.adjust') || c('stock.move') },
  { href: '/purchasing', label: 'Purchasing', icon: ShoppingCart, show: (c) => c('purchase.manage') || c('purchase.approve') },
  { href: '/assets', label: 'Tools & Equipment', icon: Wrench, show: (c) => c('asset.checkout') || c('asset.manage') },
  { href: '/reservations', label: 'Reservations', icon: BookmarkCheck, show: (c) => c('stock.withdraw') },
  { href: '/stocktake', label: 'Monthly Stocktake', icon: ClipboardCheck, show: (c) => c('stocktake.manage') || c('stocktake.count') || c('stocktake.approve') },
  { href: '/alerts', label: 'Low Stock & Alerts', icon: Bell, show: (c) => c('stock.view') },
  { href: '/integrity', label: 'Stock Integrity', icon: ShieldCheck, show: (c) => c('integrity.view') },
  { href: '/analytics', label: 'Analytics', icon: TrendingUp, show: (c) => c('reports.view') },
  { href: '/reports', label: 'Reports', icon: FileBarChart, show: (c) => c('reports.view') },
  { href: '/approvals', label: 'Approvals', icon: Stamp, show: (c) => c('stock.approve') || c('stocktake.approve') || c('import.approve') || c('stock.adjust') || c('purchase.approve') || c('purchase.manage') },
  { href: '/users', label: 'Users & Permissions', icon: Users, show: (c) => c('users.manage') },
  { href: '/setup', label: 'Company & Warehouse Setup', icon: Building2, show: (c) => c('setup.manage') || c('product.manage') || c('import.manage') },
  { href: '/admin', label: 'System Administration', icon: Settings, show: (c) => c('settings.manage') || c('integrity.admin') },
];

// Large worker actions shown at the bottom of phones / tablets
const WORKER: NavItem[] = [
  { href: '/tasks', label: 'Today', tk: 'today', icon: ListTodo, show: () => true },
  { href: '/receive', label: 'Receive', tk: 'receive', icon: ArrowDownToLine, show: (c) => c('stock.receive') },
  { href: '/withdraw', label: 'Withdraw', tk: 'withdraw', icon: ArrowUpFromLine, show: (c) => c('stock.withdraw') },
  { href: '/scan', label: 'Look up', tk: 'look_up', icon: ScanLine, show: (c) => c('stock.view') },
  { href: '/stocktake', label: 'Count', tk: 'count', icon: ClipboardCheck, show: (c) => c('stocktake.count') || c('stocktake.manage') },
  { href: '/assets', label: 'Tools', tk: 'tools', icon: Wrench, show: (c) => c('asset.checkout') },
];

export function Shell({ children }: { children: ReactNode }) {
  const { me, loading, error, warehouses, warehouseId, warehouse, setWarehouseId, can, t } = useApp();
  const online = useOnline();
  const path = usePathname();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [mfaOk, setMfaOk] = useState<boolean | null>(null);

  useEffect(() => setOpen(false), [path]);

  // Administrative roles: require an aal2 (MFA) session before showing the app
  useEffect(() => {
    if (!me?.registered) return;
    if (!me.requires_mfa) { setMfaOk(true); return; }
    supabaseBrowser().auth.mfa.getAuthenticatorAssuranceLevel().then(({ data }) => {
      if (data?.currentLevel === 'aal2') setMfaOk(true);
      else { setMfaOk(false); router.replace('/mfa'); }
    });
  }, [me, router]);

  const signOut = async () => {
    try { localStorage.removeItem(CTX_KEY); } catch { /* ignore */ }
    await supabaseBrowser().auth.signOut(); router.replace('/login');
  };

  if (loading) return <Spinner label="Loading your workspace…" />;
  if (error) return <div className="p-6"><p className="text-bad-600">Could not load your account: {error}</p><Button className="mt-3" onClick={signOut}>Sign out</Button></div>;
  if (!me?.registered || me.active === false) {
    return (
      <main className="grid min-h-dvh place-items-center p-6">
        <div className="max-w-md rounded-lg border border-steel-200 bg-white p-6">
          <h1 className="text-lg font-semibold text-navy-900">{me?.registered ? 'Account deactivated' : 'Account not set up'}</h1>
          <p className="mt-2 text-sm text-steel-600">{me?.registered ? 'Your CSWMS account has been deactivated. Contact your branch manager.' : 'You are signed in, but no CSWMS profile and role has been assigned to you yet. Ask your administrator to add you under Users & Permissions.'}</p>
          <Button className="mt-4" onClick={signOut}><LogOut className="size-4" />Sign out</Button>
        </div>
      </main>
    );
  }
  if (mfaOk !== true) return <Spinner label="Checking two-step verification…" />;

  const c = (p: string) => can(p);
  const items = NAV.filter((n) => n.show(c));
  const worker = WORKER.filter((n) => n.show(c)).slice(0, 5);
  const active = (href: string) => (href === '/' ? path === '/' : path === href || path.startsWith(href + '/'));

  const nav = (
    <nav className="flex flex-col gap-0.5 p-2" aria-label="Main menu">
      {items.map((n) => (
        <Link key={n.href} href={n.href}
          className={cx('flex items-center gap-3 rounded-md px-3 py-2 text-sm',
            active(n.href) ? 'bg-signal-400 font-semibold text-navy-950' : 'text-navy-100 hover:bg-navy-800 hover:text-white')}>
          <n.icon className="size-4 shrink-0" aria-hidden />{n.label}
        </Link>
      ))}
    </nav>
  );

  return (
    <div className="min-h-dvh lg:grid lg:grid-cols-[17rem_1fr]">
      {/* sidebar (desktop) */}
      <aside className="no-print hidden bg-navy-900 lg:flex lg:min-h-dvh lg:flex-col">
        <div className="px-5 py-5">
          <Link href="/" className="block text-xl font-bold tracking-tight text-white">CSWMS</Link>
          <div className="text-xs text-navy-100">Central Stock &amp; Warehouse Management</div>
        </div>
        <div className="flex-1 overflow-y-auto">{nav}</div>
        <div className="border-t border-navy-800 p-4 text-sm text-navy-100">
          <div className="font-medium text-white">{me.user?.full_name}</div>
          <div className="truncate text-xs">{me.roles?.map((r) => r.name).join(', ')}</div>
          <Link href="/me" className="mt-2 mr-3 inline-flex items-center gap-1 text-xs underline"><UserCog className="size-3" />My settings</Link>
          <button onClick={signOut} className="mt-2 inline-flex items-center gap-1 text-xs underline"><LogOut className="size-3" />Sign out</button>
        </div>
      </aside>

      {/* mobile drawer */}
      {open && (
        <div className="fixed inset-0 z-40 lg:hidden">
          <div className="absolute inset-0 bg-navy-950/60" onClick={() => setOpen(false)} />
          <aside className="absolute inset-y-0 left-0 w-72 overflow-y-auto bg-navy-900">
            <div className="flex items-center justify-between px-4 py-4 text-white">
              <span className="text-lg font-bold">CSWMS</span>
              <button onClick={() => setOpen(false)} aria-label="Close menu"><X className="size-5" /></button>
            </div>
            {nav}
            <div className="border-t border-navy-800 p-4 text-sm text-navy-100">
              <div className="text-white">{me.user?.full_name}</div>
              <Link href="/me" className="mt-2 mr-3 inline-flex items-center gap-1 underline"><UserCog className="size-3" />{t('settings')}</Link>
              <button onClick={signOut} className="mt-2 inline-flex items-center gap-1 underline"><LogOut className="size-3" />Sign out</button>
            </div>
          </aside>
        </div>
      )}

      <div className="flex min-h-dvh flex-col pb-20 lg:pb-0">
        {/* top bar */}
        <header className="no-print sticky top-0 z-30 flex items-center gap-3 border-b border-steel-200 bg-white/95 px-4 py-2 backdrop-blur">
          <button className="lg:hidden" onClick={() => setOpen(true)} aria-label="Open menu"><Menu className="size-6 text-navy-900" /></button>
          <span className="font-bold text-navy-900 lg:hidden">CSWMS</span>
          <div className="ml-auto flex items-center gap-3">
            {warehouses.length > 0 && (
              <label className="flex items-center gap-2 text-sm">
                <span className="hidden text-steel-600 sm:inline">Working in</span>
                <Select value={warehouseId ?? ''} onChange={(e) => setWarehouseId(e.target.value)} className="h-9 w-auto min-w-40 max-w-64" aria-label="Working warehouse">
                  {warehouses.map((w) => <option key={w.id} value={w.id}>{w.code} — {w.name}</option>)}
                </Select>
              </label>
            )}
            <Link href="/alerts?tab=notifications" className="relative rounded-md p-2 hover:bg-steel-100" aria-label="Notifications">
              <Bell className="size-5 text-navy-900" />
              {(me.unread_notifications ?? 0) > 0 && (
                <span className="absolute -right-0.5 -top-0.5 min-w-5 rounded-full bg-bad-600 px-1 text-center text-[11px] font-semibold text-white">{me.unread_notifications}</span>
              )}
            </Link>
          </div>
        </header>
        {!online && (
          <div className="flex items-center gap-2 bg-bad-600 px-4 py-2 text-sm font-medium text-white" role="alert">
            <WifiOff className="size-4" />Offline — receiving, issuing and other stock transactions are paused until the connection returns. Stocktake counting keeps working and sends itself later.
          </div>
        )}
        {warehouse?.is_training && (
          <div className="training-stripes px-4 py-1" role="note">
            <div className="mx-auto w-fit rounded bg-navy-950 px-3 py-1 text-center text-sm font-bold text-signal-300">{t('training_banner')}</div>
          </div>
        )}
        <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-6">{children}</main>
      </div>

      {/* worker bar (phones / tablets) */}
      {worker.length > 0 && (
        <nav className="no-print fixed inset-x-0 bottom-0 z-30 grid border-t border-navy-800 bg-navy-900 lg:hidden" style={{ gridTemplateColumns: `repeat(${worker.length}, minmax(0, 1fr))` }} aria-label="Quick actions">
          {worker.map((w) => (
            <Link key={w.href} href={w.href} className={cx('flex flex-col items-center gap-1 py-2.5 text-xs font-medium', active(w.href) ? 'text-signal-400' : 'text-white')}>
              <w.icon className="size-6" />{w.tk ? t(w.tk) : w.label}
            </Link>
          ))}
        </nav>
      )}
    </div>
  );
}
