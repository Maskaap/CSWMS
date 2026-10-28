'use client';
import { useEffect, useState } from 'react';
import { supabaseBrowser } from '@/lib/supabase/client';

export type Location = { id: string; warehouse_id: string; code: string; name: string; kind: string; parent_id: string | null; label_code: string; is_default: boolean; status: string };
export type Company = { id: string; code: string; name: string; status: string };
export type Reason = { id: string; kind: string; code: string; label: string; requires_reference: boolean };
export type Supplier = { id: string; code: string | null; name: string };
export type Warehouse = { warehouse_id: string; warehouse_code: string; warehouse_name: string; warehouse_status: string; branch_id: string; branch_code: string; branch_name: string; company_id: string; company_code: string; company_name: string; province_id: string; province_name: string };

function useQuery<T>(key: string | null, fetcher: () => PromiseLike<{ data: T[] | null; error: unknown }>): { data: T[]; loading: boolean; reload: () => void } {
  const [data, setData] = useState<T[]>([]);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (key === null) { setData([]); setLoading(false); return; }
    let live = true;
    setLoading(true);
    fetcher().then(({ data }) => { if (live) { setData(data ?? []); setLoading(false); } });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, tick]);
  return { data, loading, reload: () => setTick((t) => t + 1) };
}

export function useLocations(warehouseId: string | null) {
  return useQuery<Location>(warehouseId ? 'loc:' + warehouseId : null, () =>
    supabaseBrowser().from('storage_locations').select('*').eq('warehouse_id', warehouseId!).eq('status', 'active').order('code'));
}
export function useCompanies() {
  return useQuery<Company>('companies', () => supabaseBrowser().from('companies').select('id, code, name, status').order('code'));
}
export function useReasons(kind: string) {
  return useQuery<Reason>('reasons:' + kind, () => supabaseBrowser().from('reason_codes').select('*').eq('kind', kind).eq('status', 'active').order('label'));
}
export function useSuppliers() {
  return useQuery<Supplier>('suppliers', () => supabaseBrowser().from('suppliers').select('id, code, name').eq('status', 'active').order('name'));
}
export function useAllWarehouses() {
  return useQuery<Warehouse>('warehouses', () => supabaseBrowser().from('v_warehouse_tree').select('*').eq('warehouse_status', 'active').order('warehouse_code'));
}
