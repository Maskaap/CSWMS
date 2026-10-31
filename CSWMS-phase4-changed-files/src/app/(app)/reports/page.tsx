'use client';
import Link from 'next/link';
import { useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { useApp } from '@/components/app-context';
import { Field, Input, PageHeader, Select, Spinner, Table, Td, Th, cx } from '@/components/ui';
import { ExportButtons, LoadError } from '@/components/widgets';
import { useAllWarehouses, useCompanies } from '@/hooks/use-ref-data';
import { useRows } from '@/hooks/use-rows';
import type { Col } from '@/lib/export';
import { cleanSearch, fmtDate, fmtDateTime, fmtQty, STATUS_LABELS, TXN_LABELS, todayISO } from '@/lib/format';
import { CHECK_LABELS } from '@/lib/integrity';

type F = { company: string; warehouse: string; category: string; from: string; to: string; employee: string; product: string; period: string };
type R = Record<string, any>;
type Filter = keyof F;
type Report = { id: string; group: string; title: string; description: string; filters: Filter[]; cols: Col<R>[];
  fetch: (sb: SupabaseClient, f: F) => PromiseLike<{ data: unknown; error: unknown }>; post?: (rows: R[]) => R[] };

const isoDaysAgo = (n: number) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Johannesburg' }).format(new Date(Date.now() - n * 864e5));
const startOf = (d: string) => new Date(d + 'T00:00:00+02:00').toISOString();
const endOf = (d: string) => new Date(new Date(d + 'T00:00:00+02:00').getTime() + 86400000).toISOString();
const sumBy = (rows: R[], key: (r: R) => string, init: (r: R) => R, add: (acc: R, r: R) => void) => {
  const m = new Map<string, R>();
  for (const r of rows) { const k = key(r); if (!m.has(k)) m.set(k, init(r)); add(m.get(k)!, r); }
  return [...m.values()];
};

function movements(types: string[]) {
  return (sb: SupabaseClient, f: F) => {
    let q = sb.from('v_movements').select('*').in('txn_type', types).order('posted_at', { ascending: false }).limit(5000);
    if (f.from) q = q.gte('posted_at', startOf(f.from));
    if (f.to) q = q.lt('posted_at', endOf(f.to));
    if (f.company) q = q.eq('company_id', f.company);
    if (f.warehouse) q = q.eq('warehouse_id', f.warehouse);
    if (f.category) q = q.eq('category_id', f.category);
    if (f.employee) q = q.eq('created_by', f.employee);
    if (f.product) q = q.or(`sku.ilike.%${cleanSearch(f.product)}%,description.ilike.%${cleanSearch(f.product)}%`);
    return q;
  };
}
const MOVE_COLS: Col<R>[] = [
  { key: 'posted_at', label: 'Date', get: (r) => fmtDateTime(r.posted_at) }, { key: 'txn_no', label: 'Transaction' }, { key: 'txn_type', label: 'Type', get: (r) => TXN_LABELS[r.txn_type] ?? r.txn_type },
  { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'company_code', label: 'Company' }, { key: 'warehouse_code', label: 'Warehouse' },
  { key: 'location_code', label: 'Location' }, { key: 'owner_company_code', label: 'Owner' }, { key: 'status', label: 'Status', get: (r) => STATUS_LABELS[r.status] ?? r.status },
  { key: 'qty_delta', label: 'Quantity', num: true }, { key: 'uom', label: 'Unit' }, { key: 'reason_label', label: 'Reason' }, { key: 'reference', label: 'Reference / job' },
  { key: 'created_by_name', label: 'Employee' }, { key: 'notes', label: 'Notes' },
];
const balances = (sb: SupabaseClient, f: F) => {
  let q = sb.from('v_stock_balances').select('*').neq('qty', 0).order('sku').limit(10000);
  if (f.company) q = q.eq('owner_company_id', f.company);
  if (f.warehouse) q = q.eq('warehouse_id', f.warehouse);
  if (f.category) q = q.eq('category_id', f.category);
  if (f.product) q = q.or(`sku.ilike.%${cleanSearch(f.product)}%,description.ilike.%${cleanSearch(f.product)}%`);
  return q;
};
const byWh = (sb: SupabaseClient, f: F) => {
  let q = sb.from('v_stock_by_warehouse').select('*').order('sku').limit(10000);
  if (f.company) q = q.eq('company_id', f.company);
  if (f.warehouse) q = q.eq('warehouse_id', f.warehouse);
  if (f.category) q = q.eq('category_id', f.category);
  if (f.product) q = q.or(`sku.ilike.%${cleanSearch(f.product)}%,description.ilike.%${cleanSearch(f.product)}%`);
  return q;
};
const STATUS_SPLIT = (acc: R, r: R) => { acc[r.status] = (acc[r.status] ?? 0) + Number(r.qty); acc.locations += 1; };

const REPORTS: Report[] = [
  { id: 'current', group: 'Inventory', title: 'Current stock report', description: 'Every non-zero balance by shelf/bin, owner and status.', filters: ['company', 'warehouse', 'category', 'product'], fetch: balances,
    cols: [{ key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'category_name', label: 'Category' }, { key: 'company_code', label: 'Operating company' },
      { key: 'province_name', label: 'Province' }, { key: 'branch_code', label: 'Branch' }, { key: 'warehouse_code', label: 'Warehouse' }, { key: 'location_code', label: 'Location' },
      { key: 'owner_company_code', label: 'Owner' }, { key: 'status', label: 'Status', get: (r) => STATUS_LABELS[r.status] ?? r.status }, { key: 'qty', label: 'Quantity', num: true }, { key: 'uom', label: 'Unit' },
      { key: 'updated_at', label: 'Last movement', get: (r) => fmtDateTime(r.updated_at) }] },
  { id: 'company', group: 'Inventory', title: 'Company inventory report', description: 'Stock legally owned by each company, wherever it is stored (units are never mixed).', filters: ['company', 'category', 'product'], fetch: balances,
    post: (rows) => sumBy(rows, (r) => `${r.owner_company_code}|${r.product_id}`, (r) => ({ owner: r.owner_company_code, owner_name: r.owner_company_name, sku: r.sku, description: r.description, uom: r.uom, available: 0, damaged: 0, quarantine: 0, in_transit: 0, locations: 0, other_sites: 0 }),
      (a, r) => { STATUS_SPLIT(a, r); if (r.stored_for_other_company) a.other_sites += 1; }),
    cols: [{ key: 'owner', label: 'Owner' }, { key: 'owner_name', label: 'Company name' }, { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'uom', label: 'Unit' },
      { key: 'available', label: 'Available', num: true }, { key: 'damaged', label: 'Damaged', num: true }, { key: 'quarantine', label: 'Quarantine', num: true }, { key: 'in_transit', label: 'In transit', num: true },
      { key: 'locations', label: 'Locations', num: true }, { key: 'other_sites', label: 'Held at other companies', num: true }] },
  { id: 'branch', group: 'Inventory', title: 'Branch inventory report', description: 'Stock per branch and product.', filters: ['company', 'category', 'product'], fetch: byWh,
    post: (rows) => sumBy(rows, (r) => `${r.branch_code}|${r.product_id}`, (r) => ({ company: r.company_code, province: r.province_name, branch: r.branch_code, branch_name: r.branch_name, sku: r.sku, description: r.description, uom: r.uom, available: 0, reserved: 0, free: 0, damaged: 0, in_transit: 0 }),
      (a, r) => { a.available += Number(r.available); a.reserved += Number(r.reserved); a.free += Number(r.free_to_use); a.damaged += Number(r.damaged); a.in_transit += Number(r.in_transit); }),
    cols: [{ key: 'company', label: 'Company' }, { key: 'province', label: 'Province' }, { key: 'branch', label: 'Branch' }, { key: 'branch_name', label: 'Branch name' }, { key: 'sku', label: 'SKU' },
      { key: 'description', label: 'Description' }, { key: 'uom', label: 'Unit' }, { key: 'available', label: 'Available', num: true }, { key: 'reserved', label: 'Reserved', num: true },
      { key: 'free', label: 'Free', num: true }, { key: 'damaged', label: 'Damaged', num: true }, { key: 'in_transit', label: 'In transit out', num: true }] },
  { id: 'warehouse', group: 'Inventory', title: 'Warehouse inventory report', description: 'Stock per warehouse and product with thresholds.', filters: ['company', 'warehouse', 'category', 'product'], fetch: byWh,
    cols: [{ key: 'company_code', label: 'Company' }, { key: 'branch_code', label: 'Branch' }, { key: 'warehouse_code', label: 'Warehouse' }, { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' },
      { key: 'uom', label: 'Unit' }, { key: 'available', label: 'Available', num: true }, { key: 'reserved', label: 'Reserved', num: true }, { key: 'free_to_use', label: 'Free', num: true },
      { key: 'damaged', label: 'Damaged', num: true }, { key: 'quarantine', label: 'Quarantine', num: true }, { key: 'in_transit', label: 'In transit out', num: true },
      { key: 'min_qty', label: 'Minimum', num: true }, { key: 'reorder_qty', label: 'Reorder', num: true }, { key: 'stock_level', label: 'Level' }] },
  { id: 'low', group: 'Inventory', title: 'Low stock report', description: 'Items at or below their minimum, with reorder recommendations.', filters: ['company', 'warehouse', 'category', 'product'],
    fetch: (sb, f) => { let q = byWh(sb, f) as ReturnType<typeof byWh>; q = q.in('stock_level', ['low', 'out']); return q; },
    cols: [{ key: 'company_code', label: 'Company' }, { key: 'warehouse_code', label: 'Warehouse' }, { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'uom', label: 'Unit' },
      { key: 'free_to_use', label: 'Free', num: true }, { key: 'in_transit', label: 'In transit', num: true }, { key: 'min_qty', label: 'Minimum', num: true }, { key: 'reorder_qty', label: 'Reorder qty', num: true },
      { key: 'suggested', label: 'Suggested order', num: true, get: (r) => Math.max(Number(r.reorder_qty) || 0, Number(r.min_qty) - Number(r.free_to_use)) }, { key: 'stock_level', label: 'Level' }] },
  { id: 'received', group: 'Movements', title: 'Stock received report', description: 'Receipts from suppliers.', filters: ['company', 'warehouse', 'category', 'from', 'to', 'employee', 'product'], fetch: movements(['receipt']), cols: MOVE_COLS },
  { id: 'withdrawn', group: 'Movements', title: 'Stock withdrawn report', description: 'Who withdrew what, where, when and why.', filters: ['company', 'warehouse', 'category', 'from', 'to', 'employee', 'product'], fetch: movements(['withdrawal']),
    cols: MOVE_COLS.map((c) => (c.key === 'qty_delta' ? { ...c, get: (r: R) => -Number(r.qty_delta), label: 'Quantity withdrawn' } : c)) },
  { id: 'returns', group: 'Movements', title: 'Stock returns report', description: 'Returned materials, usable and damaged.', filters: ['company', 'warehouse', 'category', 'from', 'to', 'employee', 'product'], fetch: movements(['return']), cols: MOVE_COLS },
  { id: 'transfers', group: 'Movements', title: 'Stock transfer report', description: 'Transfers between shelves, warehouses, branches and companies.', filters: ['company', 'warehouse', 'from', 'to'],
    fetch: (sb, f) => {
      let q = sb.from('v_transfers').select('*').order('created_at', { ascending: false }).limit(5000);
      if (f.from) q = q.gte('created_at', startOf(f.from));
      if (f.to) q = q.lt('created_at', endOf(f.to));
      if (f.warehouse) q = q.or(`from_warehouse_id.eq.${f.warehouse},to_warehouse_id.eq.${f.warehouse}`);
      return q;
    },
    post: (rows) => rows,
    cols: [{ key: 'transfer_no', label: 'Transfer' }, { key: 'created_at', label: 'Created', get: (r) => fmtDateTime(r.created_at) }, { key: 'from_company_code', label: 'From company' },
      { key: 'from_warehouse_code', label: 'From' }, { key: 'to_company_code', label: 'To company' }, { key: 'to_warehouse_code', label: 'To' }, { key: 'to_owner_company_code', label: 'Ownership to' },
      { key: 'status', label: 'Status' }, { key: 'dispatched_at', label: 'Dispatched', get: (r) => fmtDateTime(r.dispatched_at) }, { key: 'completed_at', label: 'Completed', get: (r) => fmtDateTime(r.completed_at) },
      { key: 'line_count', label: 'Lines', num: true }, { key: 'outstanding_qty', label: 'Outstanding', num: true }, { key: 'is_overdue', label: 'Overdue', get: (r) => (r.is_overdue ? 'Yes' : '') },
      { key: 'reference', label: 'Reference' }, { key: 'created_by_name', label: 'Created by' }] },
  { id: 'adjustments', group: 'Movements', title: 'Inventory adjustment report', description: 'Adjustments, stocktake adjustments, status changes, reversals and transfer write-offs.', filters: ['company', 'warehouse', 'category', 'from', 'to', 'employee', 'product'],
    fetch: movements(['adjustment', 'stocktake_adjustment', 'status_change', 'reversal', 'transfer_writeoff']), cols: MOVE_COLS },
  { id: 'stocktake', group: 'Stocktake', title: 'Monthly stocktake report', description: 'Completion and discrepancies per warehouse for a period.', filters: ['company', 'warehouse', 'period'],
    fetch: (sb, f) => { let q = sb.from('v_stocktake_summary').select('*').order('warehouse_code').limit(2000); if (f.period) q = q.eq('period', f.period); if (f.company) q = q.eq('company_id', f.company); if (f.warehouse) q = q.eq('warehouse_id', f.warehouse); return q; },
    cols: [{ key: 'stocktake_no', label: 'Stocktake' }, { key: 'period', label: 'Period' }, { key: 'company_code', label: 'Company' }, { key: 'province_name', label: 'Province' }, { key: 'branch_name', label: 'Branch' },
      { key: 'warehouse_code', label: 'Warehouse' }, { key: 'status', label: 'Status' }, { key: 'due_date', label: 'Due', get: (r) => fmtDate(r.due_date) }, { key: 'finalised_at', label: 'Finalised', get: (r) => fmtDateTime(r.finalised_at) },
      { key: 'lines', label: 'Lines', num: true }, { key: 'counted', label: 'Counted', num: true }, { key: 'pct_counted', label: '% counted', num: true }, { key: 'discrepancies', label: 'Discrepancies', num: true },
      { key: 'missing', label: 'Missing', num: true }, { key: 'additional', label: 'Additional', num: true }, { key: 'not_counted', label: 'Not counted', num: true }, { key: 'recounts', label: 'Recounts', num: true },
      { key: 'is_overdue', label: 'Overdue', get: (r) => (r.is_overdue ? 'Yes' : '') }] },
  { id: 'variance', group: 'Stocktake', title: 'Stock variance report', description: 'Every stocktake line with a difference between counted and expected stock.', filters: ['warehouse', 'period', 'product'],
    fetch: (sb, f) => {
      let q = sb.from('stocktake_lines').select('expected_qty, adjusted_expected, first_count_qty, counted_qty, variance, flags, line_status, current_round, products(sku, description, uoms(code)), storage_locations(code), stocktakes!inner(stocktake_no, period, status, warehouse_id, warehouses(code))')
        .not('variance', 'is', null).neq('variance', 0).limit(10000);
      if (f.period) q = q.eq('stocktakes.period', f.period);
      if (f.warehouse) q = q.eq('stocktakes.warehouse_id', f.warehouse);
      return q;
    },
    post: (rows) => rows.map((r) => ({ ...r, sku: r.products?.sku, description: r.products?.description, uom: r.products?.uoms?.code, location: r.storage_locations?.code, stocktake_no: r.stocktakes?.stocktake_no,
      period: r.stocktakes?.period, warehouse: r.stocktakes?.warehouses?.code, st_status: r.stocktakes?.status, flags_text: (r.flags ?? []).join(', ') })),
    cols: [{ key: 'stocktake_no', label: 'Stocktake' }, { key: 'period', label: 'Period' }, { key: 'warehouse', label: 'Warehouse' }, { key: 'location', label: 'Location' }, { key: 'sku', label: 'SKU' },
      { key: 'description', label: 'Description' }, { key: 'uom', label: 'Unit' }, { key: 'expected_qty', label: 'Expected at cut-off', num: true }, { key: 'adjusted_expected', label: 'Expected at count', num: true },
      { key: 'first_count_qty', label: 'First count', num: true }, { key: 'counted_qty', label: 'Final count', num: true }, { key: 'variance', label: 'Variance', num: true },
      { key: 'flags_text', label: 'Flags' }, { key: 'st_status', label: 'Stocktake status' }] },
  { id: 'employee', group: 'Accountability', title: 'Employee activity report', description: 'Transactions per employee and type.', filters: ['company', 'warehouse', 'from', 'to', 'employee'],
    fetch: (sb, f) => {
      let q = sb.from('v_transactions').select('created_by, created_by_name, txn_type, warehouse_code, company_code, status, is_unusual, created_at').order('created_at', { ascending: false }).limit(20000);
      if (f.from) q = q.gte('created_at', startOf(f.from));
      if (f.to) q = q.lt('created_at', endOf(f.to));
      if (f.warehouse) q = q.eq('warehouse_id', f.warehouse);
      if (f.employee) q = q.eq('created_by', f.employee);
      return q;
    },
    post: (rows) => sumBy(rows, (r) => `${r.created_by}|${r.warehouse_code}|${r.txn_type}`, (r) => ({ employee: r.created_by_name, warehouse: r.warehouse_code, company: r.company_code, txn_type: TXN_LABELS[r.txn_type] ?? r.txn_type, count: 0, unusual: 0, first: r.created_at, last: r.created_at }),
      (a, r) => { a.count += 1; if (r.is_unusual) a.unusual += 1; if (r.created_at < a.first) a.first = r.created_at; if (r.created_at > a.last) a.last = r.created_at; }),
    cols: [{ key: 'employee', label: 'Employee' }, { key: 'company', label: 'Company' }, { key: 'warehouse', label: 'Warehouse' }, { key: 'txn_type', label: 'Transaction type' }, { key: 'count', label: 'Transactions', num: true },
      { key: 'unusual', label: 'Unusual confirmed', num: true }, { key: 'first', label: 'First', get: (r) => fmtDateTime(r.first) }, { key: 'last', label: 'Last', get: (r) => fmtDateTime(r.last) }] },
  { id: 'purchase_orders', group: 'Purchasing', title: 'Purchase order report', description: 'Purchase orders with value, approval, delivery and receipt progress.', filters: ['company', 'warehouse', 'from', 'to'],
    fetch: (sb, f) => {
      let q = sb.from('v_purchase_orders').select('*').order('created_at', { ascending: false }).limit(5000);
      if (f.from) q = q.gte('created_at', startOf(f.from));
      if (f.to) q = q.lt('created_at', endOf(f.to));
      if (f.company) q = q.eq('owner_company_id', f.company);
      if (f.warehouse) q = q.eq('warehouse_id', f.warehouse);
      return q;
    },
    cols: [{ key: 'po_no', label: 'PO' }, { key: 'created_at', label: 'Created', get: (r) => fmtDateTime(r.created_at) }, { key: 'status', label: 'Status' }, { key: 'supplier_name', label: 'Supplier' },
      { key: 'owner_company_code', label: 'Company' }, { key: 'warehouse_code', label: 'Deliver to' }, { key: 'expected_date', label: 'Expected', get: (r) => fmtDate(r.expected_date) },
      { key: 'line_count', label: 'Lines', num: true }, { key: 'total_value', label: 'Value (ZAR)', num: true }, { key: 'received_value', label: 'Received (ZAR)', num: true },
      { key: 'is_overdue', label: 'Overdue', get: (r) => (r.is_overdue ? 'Yes' : '') }, { key: 'created_by_name', label: 'Created by' }, { key: 'approved_by_name', label: 'Approved by' },
      { key: 'approved_at', label: 'Approved', get: (r) => fmtDateTime(r.approved_at) }, { key: 'supplier_reference', label: 'Supplier ref' }, { key: 'close_reason', label: 'Closed / cancelled reason' }] },
  { id: 'po_outstanding', group: 'Purchasing', title: 'Outstanding order lines', description: 'Everything ordered but not yet received, per line.', filters: ['warehouse', 'product'],
    fetch: async (sb, f) => {
      let pq = sb.from('v_purchase_orders').select('id, po_no, status, expected_date, supplier_name').in('status', ['approved', 'sent', 'partially_received']).limit(2000);
      if (f.warehouse) pq = pq.eq('warehouse_id', f.warehouse);
      const pos = await pq;
      if (pos.error) return pos;
      const byId = new Map((pos.data ?? []).map((o: R) => [o.id, o]));
      if (byId.size === 0) return { data: [], error: null };
      let q = sb.from('v_purchase_order_lines').select('*').in('po_id', [...byId.keys()]).gt('outstanding_base', 0).limit(10000);
      if (f.product) q = q.or(`sku.ilike.%${cleanSearch(f.product)}%,description.ilike.%${cleanSearch(f.product)}%`);
      const lines = await q;
      if (lines.error) return lines;
      return { data: (lines.data ?? []).map((l: R) => { const o = byId.get(l.po_id) as R; return { ...l, po_no: o.po_no, po_status: o.status, expected: o.expected_date, supplier: o.supplier_name }; }), error: null };
    },
    cols: [{ key: 'po_no', label: 'PO' }, { key: 'supplier', label: 'Supplier' }, { key: 'po_status', label: 'Status' }, { key: 'expected', label: 'Expected', get: (r) => fmtDate(r.expected) },
      { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'qty_ordered_base', label: 'Ordered', num: true }, { key: 'qty_received_base', label: 'Received', num: true },
      { key: 'outstanding_base', label: 'Outstanding', num: true }, { key: 'base_uom_code', label: 'Unit' }] },
  { id: 'asset_register', group: 'Tools & equipment', title: 'Asset register', description: 'Every tool and item of equipment with custody, condition and verification date.', filters: ['company', 'warehouse', 'product'],
    fetch: (sb, f) => {
      let q = sb.from('v_assets').select('*').order('asset_tag').limit(10000);
      if (f.company) q = q.eq('owner_company_id', f.company);
      if (f.warehouse) q = q.eq('warehouse_id', f.warehouse);
      if (f.product) q = q.or(`sku.ilike.%${cleanSearch(f.product)}%,product_description.ilike.%${cleanSearch(f.product)}%,asset_tag.ilike.%${cleanSearch(f.product)}%,serial_number.ilike.%${cleanSearch(f.product)}%`);
      return q;
    },
    cols: [{ key: 'asset_tag', label: 'Tag' }, { key: 'sku', label: 'SKU' }, { key: 'product_description', label: 'Description' }, { key: 'serial_number', label: 'Serial' },
      { key: 'owner_company_code', label: 'Owner' }, { key: 'home_warehouse_code', label: 'Home' }, { key: 'warehouse_code', label: 'Custody' }, { key: 'location_code', label: 'Location' },
      { key: 'status', label: 'Status' }, { key: 'condition', label: 'Condition' }, { key: 'holder', label: 'Held by' }, { key: 'job_reference', label: 'Job' },
      { key: 'due_back_at', label: 'Due back', get: (r) => fmtDateTime(r.due_back_at) }, { key: 'is_overdue', label: 'Overdue', get: (r) => (r.is_overdue ? 'Yes' : '') },
      { key: 'last_verified_at', label: 'Last verified', get: (r) => fmtDateTime(r.last_verified_at) }, { key: 'purchase_date', label: 'Purchased', get: (r) => fmtDate(r.purchase_date) },
      { key: 'purchase_cost', label: 'Cost (ZAR)', num: true }] },
  { id: 'asset_movements', group: 'Tools & equipment', title: 'Tool & equipment movements', description: 'Check-outs, returns, repairs, losses and verifications: who had what, when.', filters: ['warehouse', 'from', 'to', 'employee', 'product'],
    fetch: (sb, f) => {
      let q = sb.from('v_asset_movements').select('*').order('created_at', { ascending: false }).limit(10000);
      if (f.from) q = q.gte('created_at', startOf(f.from));
      if (f.to) q = q.lt('created_at', endOf(f.to));
      if (f.warehouse) q = q.eq('warehouse_id', f.warehouse);
      if (f.employee) q = q.or(`created_by.eq.${f.employee},holder_user_id.eq.${f.employee}`);
      if (f.product) q = q.or(`sku.ilike.%${cleanSearch(f.product)}%,asset_tag.ilike.%${cleanSearch(f.product)}%`);
      return q;
    },
    cols: [{ key: 'created_at', label: 'When', get: (r) => fmtDateTime(r.created_at) }, { key: 'asset_tag', label: 'Tag' }, { key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' },
      { key: 'movement', label: 'Movement' }, { key: 'warehouse_code', label: 'Warehouse' }, { key: 'location_code', label: 'Location' }, { key: 'holder', label: 'Held by' },
      { key: 'job_reference', label: 'Job' }, { key: 'condition', label: 'Condition' }, { key: 'created_by_name', label: 'Recorded by' }, { key: 'notes', label: 'Notes' }] },
  { id: 'an_velocity', group: 'Analytics', title: 'Fast, slow and dead stock', description: 'Movement class, ABC class, days of cover and days since last issue (last 90 days).', filters: ['company', 'warehouse', 'category'],
    fetch: (sb, f) => sb.rpc('analytics_velocity', { p_days: 90, p_warehouse: f.warehouse || null, p_company: f.company || null, p_category: f.category || null }),
    cols: [{ key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'category', label: 'Category' }, { key: 'movement_class', label: 'Class' }, { key: 'abc_class', label: 'ABC' },
      { key: 'on_hand', label: 'On hand', num: true }, { key: 'uom', label: 'Unit' }, { key: 'net_issued', label: 'Issued 90 d', num: true }, { key: 'issues_per_month', label: 'Issues / month', num: true },
      { key: 'days_cover', label: 'Days of cover', num: true }, { key: 'days_since_issue', label: 'Days since issue', num: true }, { key: 'value_on_hand', label: 'Value (ZAR)', num: true }] },
  { id: 'an_ageing', group: 'Analytics', title: 'Stock ageing report', description: 'On-hand stock in age bands since arrival (first-in-first-out).', filters: ['company', 'warehouse', 'category'],
    fetch: (sb, f) => sb.rpc('analytics_ageing', { p_warehouse: f.warehouse || null, p_company: f.company || null, p_category: f.category || null }),
    cols: [{ key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'warehouse_code', label: 'Warehouse' }, { key: 'uom', label: 'Unit' }, { key: 'on_hand', label: 'On hand', num: true },
      { key: 'd0_30', label: '0–30 d', num: true }, { key: 'd31_90', label: '31–90 d', num: true }, { key: 'd91_180', label: '91–180 d', num: true }, { key: 'd181_365', label: '181–365 d', num: true },
      { key: 'd365p', label: '> 1 year', num: true }, { key: 'avg_age_days', label: 'Average age', num: true }, { key: 'value', label: 'Value (ZAR)', num: true }] },
  { id: 'an_consumption', group: 'Analytics', title: 'Consumption by job / client', description: 'Issues net of returns per job or client reference.', filters: ['company', 'warehouse', 'category', 'from', 'to'],
    fetch: (sb, f) => sb.rpc('analytics_consumption', { p_from: f.from || isoDaysAgo(89), p_to: f.to || todayISO(), p_group: 'client', p_warehouse: f.warehouse || null, p_company: f.company || null, p_category: f.category || null }),
    cols: [{ key: 'label', label: 'Job / client' }, { key: 'issues', label: 'Issues', num: true }, { key: 'products', label: 'Products', num: true },
      { key: 'qty', label: 'Net quantity per unit', get: (r) => Object.entries(r.qty_by_uom ?? {}).map(([u, v]) => `${v} ${u}`).join(' · ') },
      { key: 'issued_value', label: 'Issued (ZAR)', num: true }, { key: 'returned_value', label: 'Returned (ZAR)', num: true }, { key: 'net_value', label: 'Net (ZAR)', num: true },
      { key: 'last_at', label: 'Last issue', get: (r) => fmtDateTime(r.last_at) }] },
  { id: 'an_valuation', group: 'Analytics', title: 'Inventory valuation', description: 'Stock value per product at weighted-average purchase cost (needs price access).', filters: ['company', 'warehouse'],
    fetch: (sb, f) => sb.rpc('analytics_valuation', { p_group: 'product', p_warehouse: f.warehouse || null, p_company: f.company || null }),
    cols: [{ key: 'label', label: 'Product' }, { key: 'qty', label: 'Quantity', get: (r) => Object.entries(r.qty_by_uom ?? {}).map(([u, v]) => `${v} ${u}`).join(' · ') },
      { key: 'value', label: 'Value (ZAR)', num: true }, { key: 'products_at_last_price', label: 'At last price', num: true }, { key: 'uncosted_products', label: 'No price', num: true }] },
  { id: 'an_forecast', group: 'Analytics', title: 'Demand forecast & stock-out prediction', description: 'Next 30 days per item for one warehouse: demand, days of cover, run-out date, suggested minimum and order.', filters: ['warehouse', 'category'],
    fetch: (sb, f) => sb.rpc('analytics_forecast', { p_warehouse: f.warehouse || null, p_horizon: 30, p_category: f.category || null }),
    cols: [{ key: 'sku', label: 'SKU' }, { key: 'description', label: 'Description' }, { key: 'risk', label: 'Status' }, { key: 'trend', label: 'Trend' }, { key: 'daily_demand', label: 'Daily demand', num: true },
      { key: 'forecast_qty', label: 'Forecast 30 d', num: true }, { key: 'free', label: 'Free', num: true }, { key: 'on_order', label: 'On order', num: true }, { key: 'days_cover', label: 'Days of cover', num: true },
      { key: 'stockout_date', label: 'Runs out', get: (r) => fmtDate(r.stockout_date) }, { key: 'lead_time_days', label: 'Lead time', num: true }, { key: 'reorder_point', label: 'Reorder point', num: true },
      { key: 'suggested_min', label: 'Suggested minimum', num: true }, { key: 'suggested_order_now', label: 'Order now', num: true }] },
  { id: 'an_suppliers', group: 'Analytics', title: 'Supplier scorecard', description: 'On-time delivery, fill rate and lead time per supplier.', filters: ['from', 'to'],
    fetch: (sb, f) => sb.rpc('analytics_supplier_performance', { p_from: f.from || isoDaysAgo(364), p_to: f.to || todayISO() }),
    cols: [{ key: 'supplier', label: 'Supplier' }, { key: 'orders', label: 'Orders', num: true }, { key: 'delivered', label: 'Delivered', num: true }, { key: 'on_time_pct', label: 'On time %', num: true },
      { key: 'fill_rate_pct', label: 'Fill rate %', num: true }, { key: 'avg_lead_days', label: 'Avg lead days', num: true }, { key: 'value', label: 'Ordered (ZAR)', num: true }] },
  { id: 'integrity_daily', group: 'Integrity', title: 'Daily integrity report', description: 'Every integrity check run with its evidence counts.', filters: [],
    fetch: (sb) => sb.rpc('integrity_runs', { p_limit: 400 }),
    cols: [{ key: 'run_no', label: 'Run' }, { key: 'business_date', label: 'Business date', get: (r) => fmtDate(r.business_date) }, { key: 'trigger', label: 'Trigger' }, { key: 'status', label: 'Status' }, { key: 'result', label: 'Result' },
      { key: 'started_at', label: 'Started', get: (r) => fmtDateTime(r.started_at) }, { key: 'finished_at', label: 'Finished', get: (r) => fmtDateTime(r.finished_at) }, { key: 'keys_checked', label: 'Balances checked', num: true },
      { key: 'reconciliations_passed', label: 'Passed', num: true }, { key: 'products_checked', label: 'Products', num: true }, { key: 'locations_checked', label: 'Locations', num: true },
      { key: 'companies_checked', label: 'Companies', num: true }, { key: 'mismatches', label: 'Mismatches', num: true }, { key: 'findings_detected', label: 'Findings', num: true }, { key: 'error_message', label: 'Error' }] },
  { id: 'integrity_findings', group: 'Integrity', title: 'Integrity investigation report', description: 'All integrity issues with their investigation status and resolution.', filters: [],
    fetch: (sb) => sb.rpc('integrity_findings', { p_status: 'all', p_limit: 5000 }),
    cols: [{ key: 'finding_no', label: 'Issue' }, { key: 'severity', label: 'Severity' }, { key: 'classification', label: 'Classification' }, { key: 'check_code', label: 'Check', get: (r) => CHECK_LABELS[r.check_code] ?? r.check_code },
      { key: 'title', label: 'Title' }, { key: 'company_code', label: 'Company' }, { key: 'warehouse_code', label: 'Warehouse' }, { key: 'location_code', label: 'Location' }, { key: 'product_sku', label: 'Product' },
      { key: 'expected_qty', label: 'Expected', num: true }, { key: 'recorded_qty', label: 'Recorded', num: true }, { key: 'difference', label: 'Difference', num: true }, { key: 'status', label: 'Status' },
      { key: 'assigned_to_name', label: 'Investigator' }, { key: 'first_detected_at', label: 'First detected', get: (r) => fmtDateTime(r.first_detected_at) },
      { key: 'resolved_at', label: 'Resolved', get: (r) => fmtDateTime(r.resolved_at) }, { key: 'resolution', label: 'Resolution' }] },
];

export default function ReportsPage() {
  const { can } = useApp();
  const [id, setId] = useState('current');
  const monthStart = todayISO().slice(0, 8) + '01';
  const [f, setF] = useState<F>({ company: '', warehouse: '', category: '', from: monthStart, to: todayISO(), employee: '', product: '', period: todayISO().slice(0, 7) });
  const { data: companies } = useCompanies();
  const { data: warehouses } = useAllWarehouses();
  const cats = useRows<{ id: string; name: string; parent_id: string | null }>('cats', (sb) => sb.from('categories').select('id, name, parent_id').eq('status', 'active').order('name'));
  const users = useRows<{ id: string; full_name: string }>('users', (sb) => sb.from('app_users').select('id, full_name').order('full_name'));
  const rep = REPORTS.find((r) => r.id === id)!;
  const visible = REPORTS.filter((r) => r.group !== 'Integrity' || can('integrity.view'));
  const data = useRows<R>(`${id}|${JSON.stringify(f)}`, (sb) => rep.fetch(sb, f) as never);
  const rows = useMemo(() => (rep.post ? rep.post(data.rows) : data.rows), [data.rows, rep]);
  const set = (k: Filter) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });

  if (!can('reports.view')) return <PageHeader title="Reports" description="You do not have permission to view reports." />;
  return (
    <>
      <PageHeader title="Reports" description="Built live from the database records you are authorised to see. Export to Excel, CSV or PDF."
        actions={can('cost.view') ? <Link href="/reports/accounting" className="inline-flex h-10 items-center rounded-md border border-navy-900 bg-navy-900 px-4 text-sm font-medium text-white hover:bg-navy-800">Accounting export (Xero / Sage)</Link> : null} />
      <div className="grid gap-6 lg:grid-cols-[16rem_1fr]">
        <nav className="space-y-4" aria-label="Reports">
          {[...new Set(visible.map((r) => r.group))].map((g) => (
            <div key={g}>
              <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-steel-600">{g}</div>
              <ul className="space-y-0.5">{visible.filter((r) => r.group === g).map((r) => (
                <li key={r.id}><button onClick={() => setId(r.id)} className={cx('w-full rounded-md px-3 py-1.5 text-left text-sm', r.id === id ? 'bg-navy-900 font-medium text-white' : 'text-navy-900 hover:bg-steel-100')}>{r.title}</button></li>
              ))}</ul>
            </div>
          ))}
        </nav>
        <div className="min-w-0">
          <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
            <div><h2 className="text-lg font-semibold text-navy-900">{rep.title}</h2><p className="text-sm text-steel-600">{rep.description}</p></div>
            <ExportButtons title={rep.title} cols={rep.cols} rows={rows} />
          </div>
          {rep.filters.length > 0 && (
            <div className="mb-4 grid gap-3 rounded-lg border border-steel-200 bg-white p-3 sm:grid-cols-2 xl:grid-cols-4">
              {rep.filters.includes('company') && <Field label="Company"><Select value={f.company} onChange={set('company')}><option value="">All</option>{companies.map((c) => <option key={c.id} value={c.id}>{c.code} — {c.name}</option>)}</Select></Field>}
              {rep.filters.includes('warehouse') && <Field label="Warehouse"><Select value={f.warehouse} onChange={set('warehouse')}><option value="">All</option>{warehouses.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.warehouse_code} — {w.warehouse_name}</option>)}</Select></Field>}
              {rep.filters.includes('category') && <Field label="Category"><Select value={f.category} onChange={set('category')}><option value="">All</option>{cats.rows.map((c) => <option key={c.id} value={c.id}>{c.parent_id ? '— ' : ''}{c.name}</option>)}</Select></Field>}
              {rep.filters.includes('employee') && <Field label="Employee"><Select value={f.employee} onChange={set('employee')}><option value="">All</option>{users.rows.map((u) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</Select></Field>}
              {rep.filters.includes('from') && <Field label="From"><Input type="date" value={f.from} onChange={set('from')} /></Field>}
              {rep.filters.includes('to') && <Field label="To"><Input type="date" value={f.to} onChange={set('to')} /></Field>}
              {rep.filters.includes('period') && <Field label="Period"><Input type="month" value={f.period} onChange={set('period')} /></Field>}
              {rep.filters.includes('product') && <Field label="Product contains"><Input value={f.product} onChange={set('product')} placeholder="SKU or description" /></Field>}
            </div>
          )}
          <LoadError error={data.error} />
          {data.loading ? <Spinner /> : (
            <>
              <p className="mb-2 text-xs text-steel-600">{rows.length} rows{rows.length >= 5000 ? ' — limit reached, narrow the filters' : ''}</p>
              <Table>
                <thead><tr>{rep.cols.map((c) => <Th key={c.key} right={c.num}>{c.label}</Th>)}</tr></thead>
                <tbody>
                  {rows.slice(0, 500).map((r, i) => (
                    <tr key={i}>{rep.cols.map((c) => { const v = c.get ? c.get(r) : r[c.key]; return <Td key={c.key} right={c.num}>{c.num ? fmtQty(v as number) : v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v)}</Td>; })}</tr>
                  ))}
                  {rows.length === 0 && <tr><Td className="text-steel-600">No data for these filters.</Td></tr>}
                </tbody>
              </Table>
              {rows.length > 500 && <p className="mt-2 text-xs text-steel-600">Showing the first 500 rows on screen; exports contain all {rows.length}.</p>}
            </>
          )}
        </div>
      </div>
    </>
  );
}
