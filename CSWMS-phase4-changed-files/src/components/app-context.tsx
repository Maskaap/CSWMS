'use client';
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { supabaseBrowser } from '@/lib/supabase/client';
import type { MyContext, WarehouseCtx } from '@/lib/types';
import { translator, type Key } from '@/lib/i18n';

type Ctx = {
  me: MyContext | null;
  loading: boolean;
  error: string | null;
  warehouses: WarehouseCtx[];
  warehouseId: string | null;
  warehouse: WarehouseCtx | null;
  setWarehouseId: (id: string) => void;
  /** permission anywhere in the user's scope, or for a specific warehouse */
  can: (perm: string, warehouseId?: string | null) => boolean;
  canGroup: (perm: string) => boolean;
  refresh: () => Promise<void>;
  /** floor-screen translation in the user's language */
  t: (k: Key) => string;
  lang: string;
};

const AppCtx = createContext<Ctx | null>(null);
const WH_KEY = 'cswms.warehouse';
export const CTX_KEY = 'cswms.context';

export function AppContextProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<MyContext | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [warehouseId, setWh] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    let ctx: MyContext;
    try {
      const { data, error } = await supabaseBrowser().rpc('my_context');
      if (error) throw error;
      ctx = data as MyContext;
      try { localStorage.setItem(CTX_KEY, JSON.stringify(ctx)); } catch { /* storage unavailable */ }
    } catch (e) {
      // no signal: keep working from the last known profile (counting offline); the server still checks every action
      let cached: MyContext | null = null;
      try { cached = JSON.parse(localStorage.getItem(CTX_KEY) ?? 'null'); } catch { cached = null; }
      if (!cached || (typeof navigator !== 'undefined' && navigator.onLine)) {
        setError((e as { message?: string })?.message ?? 'Could not load your account'); setLoading(false); return;
      }
      ctx = cached;
    }
    setMe(ctx);
    setError(null);
    setLoading(false);
    const whs = ctx.warehouses ?? [];
    let saved: string | null = null;
    try { saved = localStorage.getItem(WH_KEY); } catch { /* storage unavailable */ }
    setWh((cur) => {
      const pick = cur ?? saved;
      if (pick && whs.some((w) => w.id === pick)) return pick;
      return whs[0]?.id ?? null;
    });
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  // personal text size (normal / large / extra large) scales the whole app (rem based)
  useEffect(() => {
    const size = me?.user?.text_size ?? 'normal';
    try { document.documentElement.dataset.text = size; } catch { /* no document */ }
  }, [me?.user?.text_size]);

  const value = useMemo<Ctx>(() => {
    const warehouses = me?.warehouses ?? [];
    const perms = new Set(me?.permissions ?? []);
    const groupPerms = new Set(me?.group_permissions ?? []);
    return {
      me, loading, error, warehouses, warehouseId,
      warehouse: warehouses.find((w) => w.id === warehouseId) ?? null,
      setWarehouseId: (id: string) => {
        setWh(id);
        try { localStorage.setItem(WH_KEY, id); } catch { /* ignore */ }
      },
      can: (perm, wid) => {
        if (wid === undefined) return perms.has(perm);
        if (wid === null) return false;
        return !!warehouses.find((w) => w.id === wid)?.perms?.includes(perm);
      },
      canGroup: (perm) => groupPerms.has(perm),
      refresh,
      t: translator(me?.user?.language),
      lang: me?.user?.language ?? 'en',
    };
  }, [me, loading, error, warehouseId, refresh]);

  return <AppCtx.Provider value={value}>{children}</AppCtx.Provider>;
}

export function useApp(): Ctx {
  const c = useContext(AppCtx);
  if (!c) throw new Error('useApp must be used inside AppContextProvider');
  return c;
}
