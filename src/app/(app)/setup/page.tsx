'use client';
import Link from 'next/link';
import { Suspense, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { FileUp, Package, Printer } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { MasterTable } from '@/components/master-table';
import { Button, PageHeader, Select, Spinner } from '@/components/ui';
import { LoadError, Tabs } from '@/components/widgets';
import { useRows } from '@/hooks/use-rows';

type Tab = 'companies' | 'branches' | 'warehouses' | 'locations' | 'categories' | 'uoms' | 'suppliers' | 'provinces';

function SetupInner() {
  const sp = useSearchParams();
  const { can, canGroup, warehouseId } = useApp();
  const [tab, setTab] = useState<Tab>((sp.get('tab') as Tab) || 'companies');
  const setup = can('setup.manage');
  const prod = can('product.manage');
  const companies = useRows<Record<string, any>>('co', (sb) => sb.from('companies').select('*').order('code'));
  const provinces = useRows<Record<string, any>>('pv', (sb) => sb.from('provinces').select('*').order('name'));
  const branches = useRows<Record<string, any>>('br', (sb) => sb.from('branches').select('*').order('code'));
  const warehouses = useRows<Record<string, any>>('wh', (sb) => sb.from('warehouses').select('*').order('code'));
  const [locWh, setLocWh] = useState<string>(warehouseId ?? '');
  const locations = useRows<Record<string, any>>(tab === 'locations' && locWh ? 'loc' + locWh : null, (sb) => sb.from('storage_locations').select('*').eq('warehouse_id', locWh).order('code'));
  const categories = useRows<Record<string, any>>(tab === 'categories' ? 'cat' : null, (sb) => sb.from('categories').select('*').order('name'));
  const uoms = useRows<Record<string, any>>(tab === 'uoms' ? 'uom' : null, (sb) => sb.from('uoms').select('*').order('code'));
  const suppliers = useRows<Record<string, any>>(tab === 'suppliers' ? 'sup' : null, (sb) => sb.from('suppliers').select('*').order('name'));
  const opt = (rows: Record<string, any>[], label: (r: Record<string, any>) => string) => rows.map((r) => ({ value: r.id, label: label(r) }));

  return (
    <>
      <PageHeader title="Company & warehouse setup" description="Head office → company → branch → warehouse → storage area → shelf / bin. Add companies, provinces and locations at any time — no software change needed."
        actions={<>
          {prod && <Link href="/setup/products"><Button><Package className="size-4" />Products</Button></Link>}
          {(can('import.manage') || can('import.approve')) && <Link href="/setup/import"><Button variant="primary"><FileUp className="size-4" />Opening stock import</Button></Link>}
          <Link href="/setup/labels"><Button><Printer className="size-4" />Print labels</Button></Link>
        </>} />
      <Tabs value={tab} onChange={setTab} tabs={[
        { id: 'companies', label: 'Companies' }, { id: 'branches', label: 'Branches' }, { id: 'warehouses', label: 'Warehouses' }, { id: 'locations', label: 'Storage locations' },
        { id: 'categories', label: 'Categories' }, { id: 'uoms', label: 'Units of measure' }, { id: 'suppliers', label: 'Suppliers' }, { id: 'provinces', label: 'Provinces' }]} />
      <LoadError error={companies.error} />
      {tab === 'companies' && <MasterTable title="Companies (legal owners of stock)" table="companies" rows={companies.rows} loading={companies.loading} onChanged={companies.reload} canEdit={setup && canGroup('setup.manage')}
        fields={[{ key: 'code', label: 'Code', required: true, upper: true, immutable: true, placeholder: 'e.g. CSA' }, { key: 'name', label: 'Trading name', required: true },
          { key: 'legal_name', label: 'Registered name' }, { key: 'registration_number', label: 'Registration no.' }, { key: 'vat_number', label: 'VAT no.' }, { key: 'status', label: 'Status', type: 'status' }]} />}
      {tab === 'branches' && <MasterTable title="Branches (physical sites)" table="branches" rows={branches.rows} loading={branches.loading} onChanged={branches.reload} canEdit={setup}
        fields={[{ key: 'code', label: 'Branch code', required: true, upper: true, immutable: true, hint: 'Separate from the company code' },
          { key: 'name', label: 'Name', required: true }, { key: 'company_id', label: 'Operating company', type: 'select', required: true, options: opt(companies.rows, (r) => `${r.code} — ${r.name}`) },
          { key: 'province_id', label: 'Province', type: 'select', required: true, options: opt(provinces.rows, (r) => r.name) }, { key: 'town', label: 'Town' },
          { key: 'address', label: 'Address', type: 'textarea', hideInTable: true }, { key: 'status', label: 'Status', type: 'status' }]} />}
      {tab === 'warehouses' && <MasterTable title="Warehouses" table="warehouses" rows={warehouses.rows} loading={warehouses.loading} onChanged={warehouses.reload} canEdit={setup}
        fields={[{ key: 'code', label: 'Warehouse code', required: true, upper: true, immutable: true }, { key: 'name', label: 'Name', required: true },
          { key: 'branch_id', label: 'Branch', type: 'select', required: true, immutable: true, options: opt(branches.rows, (r) => `${r.code} — ${r.name}`) }, { key: 'status', label: 'Status', type: 'status' }]} />}
      {tab === 'locations' && (
        <>
          <div className="mb-3 flex items-center gap-3"><span className="text-sm">Warehouse</span>
            <Select value={locWh} onChange={(e) => setLocWh(e.target.value)} className="w-80"><option value="">— choose —</option>{warehouses.rows.map((w) => <option key={w.id} value={w.id}>{w.code} — {w.name}</option>)}</Select>
            {locWh && <Link href={`/setup/labels?warehouse=${locWh}`} className="text-sm underline">Print location labels</Link>}
          </div>
          {locWh ? <MasterTable title="Storage areas, shelves and bins" table="storage_locations" rows={locations.rows} loading={locations.loading} onChanged={locations.reload} canEdit={can('setup.manage', locWh)} defaults={{ warehouse_id: locWh }}
            fields={[{ key: 'warehouse_id', label: 'Warehouse', type: 'select', immutable: true, hideInTable: true, options: opt(warehouses.rows, (r) => r.code) },
              { key: 'code', label: 'Code', required: true, upper: true, immutable: true, placeholder: 'e.g. A-01-03' }, { key: 'name', label: 'Name', required: true },
              { key: 'kind', label: 'Type', type: 'select', required: true, options: [{ value: 'area', label: 'Storage area' }, { value: 'shelf', label: 'Shelf' }, { value: 'bin', label: 'Bin' }], defaultValue: 'bin' },
              { key: 'parent_id', label: 'Inside', type: 'select', options: opt(locations.rows, (r) => `${r.code} — ${r.name}`) },
              { key: 'label_code', label: 'Label barcode', immutable: true, hint: 'Generated automatically when left blank', show: (r) => <span className="font-mono text-xs">{r.label_code}</span> },
              { key: 'is_default', label: 'Default receiving location', type: 'checkbox' }, { key: 'status', label: 'Status', type: 'status' }]} /> : <p className="text-sm text-steel-600">Choose a warehouse.</p>}
        </>
      )}
      {tab === 'categories' && <MasterTable title="Stock categories and subcategories" table="categories" rows={categories.rows} loading={categories.loading} onChanged={categories.reload} canEdit={prod}
        fields={[{ key: 'code', label: 'Code', required: true, upper: true, immutable: true }, { key: 'name', label: 'Name', required: true },
          { key: 'parent_id', label: 'Parent category (for a subcategory)', type: 'select', options: opt(categories.rows.filter((c) => !c.parent_id), (r) => r.name) }, { key: 'status', label: 'Status', type: 'status' }]} />}
      {tab === 'uoms' && <MasterTable title="Units of measure" table="uoms" rows={uoms.rows} loading={uoms.loading} onChanged={uoms.reload} canEdit={can('settings.manage')}
        fields={[{ key: 'code', label: 'Code', required: true, upper: true, immutable: true }, { key: 'name', label: 'Name', required: true },
          { key: 'decimals', label: 'Decimal places allowed', type: 'number', required: true, hint: '0 for countable items (each, roll, box); up to 4 for kg, litre, metre', defaultValue: 0 }, { key: 'status', label: 'Status', type: 'status' }]} />}
      {tab === 'suppliers' && <MasterTable title="Suppliers" table="suppliers" rows={suppliers.rows} loading={suppliers.loading} onChanged={suppliers.reload} canEdit={prod}
        fields={[{ key: 'code', label: 'Code', upper: true }, { key: 'name', label: 'Name', required: true }, { key: 'contact', label: 'Contact person' }, { key: 'phone', label: 'Phone' }, { key: 'email', label: 'E-mail' }, { key: 'status', label: 'Status', type: 'status' }]} />}
      {tab === 'provinces' && <MasterTable title="Provinces" table="provinces" rows={provinces.rows} loading={provinces.loading} onChanged={provinces.reload} canEdit={canGroup('setup.manage')}
        fields={[{ key: 'code', label: 'Code', required: true, upper: true, immutable: true }, { key: 'name', label: 'Name', required: true }, { key: 'status', label: 'Status', type: 'status' }]} />}
    </>
  );
}

export default function SetupPage() {
  return <Suspense fallback={<Spinner />}><SetupInner /></Suspense>;
}
