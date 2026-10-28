export type Uuid = string;

export type WarehouseCtx = {
  id: Uuid; code: string; name: string; branch_code: string; company_code: string; company_id: Uuid; perms: string[];
};

export type MyContext = {
  registered: boolean;
  active?: boolean;
  user?: { id: Uuid; email: string; full_name: string; employee_number: string | null };
  requires_mfa?: boolean;
  roles?: { role: string; name: string; scope_type: string; scope_id: Uuid | null; scope_label: string }[];
  permissions?: string[];
  group_permissions?: string[];
  warehouses?: WarehouseCtx[];
  unread_notifications?: number;
  settings?: Record<string, unknown>;
};

export type LookupResult =
  | { kind: 'none'; code?: string }
  | { kind: 'location'; location: { id: Uuid; code: string; name: string; warehouse_id: Uuid; warehouse_code: string; status: string; in_selected_warehouse: boolean } }
  | {
      kind: 'product';
      product: { id: Uuid; sku: string; description: string; status: string; is_asset: boolean; image_path: string | null;
                 base_uom: { id: Uuid; code: string; decimals: number }; category: string | null };
      scanned_uom_id: Uuid;
      units: { uom_id: Uuid; code: string; name: string; factor: number; decimals: number; is_default_issue: boolean }[];
      balances: { location_id: Uuid; location_code: string; location_name: string; owner_company_id: Uuid; owner_company_code: string; status: string; qty: number }[];
      warehouse_available: number;
      reserved: number;
      threshold: { min_qty: number; reorder_qty: number } | null;
    };

export type ProductLookup = Extract<LookupResult, { kind: 'product' }>;
