'use client';
import { useMemo, useState } from 'react';
import { KeyRound, Plus, Trash2, UserPlus } from 'lucide-react';
import { useApp } from '@/components/app-context';
import { Badge, Button, Dialog, Field, Input, Notice, PageHeader, Select, Spinner, Table, Td, Th } from '@/components/ui';
import { ActionResult, LoadError, Tabs } from '@/components/widgets';
import { useAction } from '@/hooks/use-action';
import { useAllWarehouses, useCompanies } from '@/hooks/use-ref-data';
import { useRows } from '@/hooks/use-rows';
import { supabaseBrowser } from '@/lib/supabase/client';
import { fmtDateTime } from '@/lib/format';

type User = { id: string; email: string; full_name: string; employee_number: string | null; phone: string | null; is_active: boolean; last_seen_at: string | null;
  user_role_assignments: { id: string; scope_type: string; scope_id: string | null; roles: { id: string; code: string; name: string } }[] };
type Role = { id: string; code: string; name: string; description: string; permissions: string[]; requires_mfa: boolean; is_system: boolean };
type Assign = { role_id: string; scope_type: string; scope_id: string | null };

export default function UsersPage() {
  const { can, me } = useApp();
  const [tab, setTab] = useState<'users' | 'roles'>('users');
  const [q, setQ] = useState('');
  const users = useRows<User>('users', (sb) => sb.from('app_users').select('id, email, full_name, employee_number, phone, is_active, last_seen_at, user_role_assignments!user_role_assignments_user_id_fkey(id, scope_type, scope_id, roles(id, code, name))').order('full_name'));
  const roles = useRows<Role>('roles', (sb) => sb.from('roles').select('*').order('name'));
  const { data: companies } = useCompanies();
  const { data: whs } = useAllWarehouses();
  const [edit, setEdit] = useState<User | null>(null);
  const [invite, setInvite] = useState(false);
  const scopeName = useMemo(() => {
    const m = new Map<string, string>();
    companies.forEach((c) => m.set(c.id, `${c.code} (company)`));
    whs.forEach((w) => { m.set(w.warehouse_id, `${w.warehouse_code} (warehouse)`); m.set(w.branch_id, `${w.branch_code} — ${w.branch_name} (branch)`); });
    return (t: string, id: string | null) => (t === 'group' ? 'All companies' : (id && m.get(id)) || t);
  }, [companies, whs]);
  const shown = users.rows.filter((u) => !q || `${u.full_name} ${u.email} ${u.employee_number ?? ''}`.toLowerCase().includes(q.toLowerCase()));

  if (!can('users.manage')) return <PageHeader title="Users & permissions" description="You do not have permission to manage users." />;
  return (
    <>
      <PageHeader title="Users & permissions" description="Every employee has an individual account. Access is granted by role and scope (group, company, branch or warehouse) and enforced in the database."
        actions={<Button variant="primary" onClick={() => setInvite(true)}><UserPlus className="size-4" />Add employee</Button>} />
      <Tabs value={tab} onChange={setTab} tabs={[{ id: 'users', label: `Employees (${users.rows.length})` }, { id: 'roles', label: 'Roles' }]} />
      <LoadError error={users.error} />
      {tab === 'users' && (users.loading ? <Spinner /> : (
        <>
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search name, e-mail or employee number" className="mb-3 max-w-md" />
          <Table>
            <thead><tr><Th>Employee</Th><Th>Roles and scope</Th><Th>Status</Th><Th>Last active</Th><Th /></tr></thead>
            <tbody>{shown.map((u) => (
              <tr key={u.id} className={u.is_active ? '' : 'opacity-60'}>
                <Td><div className="font-medium text-navy-900">{u.full_name}{u.id === me?.user?.id && ' (you)'}</div><div className="text-xs text-steel-600">{u.email}{u.employee_number && ` · ${u.employee_number}`}</div></Td>
                <Td><div className="flex flex-wrap gap-1">{u.user_role_assignments.map((a) => <Badge key={a.id} tone="info">{a.roles.name} · {scopeName(a.scope_type, a.scope_id)}</Badge>)}{u.user_role_assignments.length === 0 && <span className="text-xs text-warn-600">No role — cannot use the system</span>}</div></Td>
                <Td><Badge tone={u.is_active ? 'ok' : 'idle'}>{u.is_active ? 'active' : 'deactivated'}</Badge></Td>
                <Td className="text-xs">{fmtDateTime(u.last_seen_at)}</Td>
                <Td><Button size="sm" onClick={() => setEdit(u)}>Edit</Button></Td>
              </tr>
            ))}</tbody>
          </Table>
        </>
      ))}
      {tab === 'roles' && (
        <Table>
          <thead><tr><Th>Role</Th><Th>Description</Th><Th>Permissions</Th><Th>MFA</Th></tr></thead>
          <tbody>{roles.rows.map((r) => (
            <tr key={r.id}><Td className="font-medium">{r.name}<div className="font-mono text-xs text-steel-600">{r.code}</div></Td><Td className="text-sm">{r.description}</Td>
              <Td><div className="flex max-w-xl flex-wrap gap-1">{r.permissions.map((p) => <Badge key={p}>{p}</Badge>)}</div></Td><Td>{r.requires_mfa ? <Badge tone="warn">required</Badge> : '—'}</Td></tr>
          ))}</tbody>
        </Table>
      )}
      {invite && <InviteDialog onClose={() => setInvite(false)} onDone={(id) => { setInvite(false); users.reload(); setTimeout(() => setEdit({ id, email: '', full_name: '', employee_number: null, phone: null, is_active: true, last_seen_at: null, user_role_assignments: [] }), 0); }} />}
      {edit && <EditDialog user={users.rows.find((u) => u.id === edit.id) ?? edit} roles={roles.rows} scopeName={scopeName} companies={companies} whs={whs} onClose={() => setEdit(null)} onSaved={() => users.reload()} />}
    </>
  );
}

function InviteDialog({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const [v, setV] = useState({ email: '', full_name: '', employee_number: '', phone: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const submit = async () => {
    setBusy(true); setErr(null);
    try {
      const r = await fetch('/api/admin/users', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(v) });
      const j = await r.json();
      if (!r.ok) setErr(j.error ?? 'Failed'); else onDone(j.user_id);
    } catch { setErr('The server could not be reached.'); }
    setBusy(false);
  };
  return (
    <Dialog open onClose={onClose} title="Add an employee" footer={<><Button onClick={onClose}>Cancel</Button><Button variant="primary" busy={busy} disabled={!v.email || !v.full_name} onClick={submit}>Send invitation</Button></>}>
      <div className="space-y-3">
        <Field label="Full name" required><Input value={v.full_name} onChange={(e) => setV({ ...v, full_name: e.target.value })} /></Field>
        <Field label="Work e-mail" required hint="They receive an e-mail to choose their own password."><Input type="email" value={v.email} onChange={(e) => setV({ ...v, email: e.target.value })} /></Field>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Employee number"><Input value={v.employee_number} onChange={(e) => setV({ ...v, employee_number: e.target.value })} /></Field>
          <Field label="Phone"><Input value={v.phone} onChange={(e) => setV({ ...v, phone: e.target.value })} /></Field>
        </div>
        {err && <Notice tone="bad">{err}</Notice>}
        <p className="text-xs text-steel-600">After the invitation you will assign roles. Never share accounts — every transaction is recorded against the signed-in person.</p>
      </div>
    </Dialog>
  );
}

function EditDialog({ user, roles, scopeName, companies, whs, onClose, onSaved }: {
  user: User; roles: Role[]; scopeName: (t: string, id: string | null) => string; companies: { id: string; code: string; name: string }[];
  whs: { warehouse_id: string; warehouse_code: string; warehouse_name: string; branch_id: string; branch_code: string; branch_name: string }[]; onClose: () => void; onSaved: () => void;
}) {
  const act = useAction();
  const [p, setP] = useState({ full_name: user.full_name, employee_number: user.employee_number ?? '', phone: user.phone ?? '', is_active: user.is_active });
  const [as, setAs] = useState<Assign[]>(user.user_role_assignments.map((a) => ({ role_id: a.roles.id, scope_type: a.scope_type, scope_id: a.scope_id })));
  const [nr, setNr] = useState<Assign>({ role_id: '', scope_type: 'warehouse', scope_id: '' });
  const branches = [...new Map(whs.map((w) => [w.branch_id, w])).values()];
  const [resetMsg, setResetMsg] = useState<string | null>(null);
  const save = async () => {
    const a = await act.run('admin_upsert_user', { p_user_id: user.id, p_email: user.email, p_full_name: p.full_name, p_employee_number: p.employee_number || null, p_phone: p.phone || null, p_is_active: p.is_active });
    if (!a) return;
    if (await act.run('admin_set_user_roles', { p_user_id: user.id, p_assignments: as }, 'Saved.')) onSaved();
  };
  return (
    <Dialog open wide onClose={onClose} title={`Edit ${user.full_name || user.email}`} footer={<><Button onClick={onClose}>Close</Button><Button variant="primary" busy={act.busy} onClick={save}>Save</Button></>}>
      <div className="space-y-4">
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="Full name"><Input value={p.full_name} onChange={(e) => setP({ ...p, full_name: e.target.value })} /></Field>
          <Field label="Employee number"><Input value={p.employee_number} onChange={(e) => setP({ ...p, employee_number: e.target.value })} /></Field>
          <Field label="Phone"><Input value={p.phone} onChange={(e) => setP({ ...p, phone: e.target.value })} /></Field>
        </div>
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={p.is_active} onChange={(e) => setP({ ...p, is_active: e.target.checked })} />Account active (deactivate instead of deleting — history is kept)</label>
        <div>
          <h3 className="mb-2 text-sm font-semibold text-navy-900">Roles</h3>
          <ul className="mb-3 space-y-1">{as.map((a, i) => (
            <li key={i} className="flex items-center justify-between rounded border border-steel-200 px-3 py-1.5 text-sm">
              <span>{roles.find((r) => r.id === a.role_id)?.name} · {scopeName(a.scope_type, a.scope_id)}</span>
              <button onClick={() => setAs(as.filter((_, j) => j !== i))} aria-label="Remove role" className="text-bad-600"><Trash2 className="size-4" /></button>
            </li>
          ))}{as.length === 0 && <li className="text-sm text-warn-600">No roles — the user cannot use CSWMS.</li>}</ul>
          <div className="grid gap-2 sm:grid-cols-[1fr_10rem_1fr_auto]">
            <Select value={nr.role_id} onChange={(e) => setNr({ ...nr, role_id: e.target.value })}><option value="">— role —</option>{roles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</Select>
            <Select value={nr.scope_type} onChange={(e) => setNr({ ...nr, scope_type: e.target.value, scope_id: '' })}><option value="group">Group</option><option value="company">Company</option><option value="branch">Branch</option><option value="warehouse">Warehouse</option></Select>
            <Select value={nr.scope_id ?? ''} onChange={(e) => setNr({ ...nr, scope_id: e.target.value })} disabled={nr.scope_type === 'group'}>
              <option value="">{nr.scope_type === 'group' ? 'All companies' : '— choose —'}</option>
              {nr.scope_type === 'company' && companies.map((c) => <option key={c.id} value={c.id}>{c.code} — {c.name}</option>)}
              {nr.scope_type === 'branch' && branches.map((b) => <option key={b.branch_id} value={b.branch_id}>{b.branch_code} — {b.branch_name}</option>)}
              {nr.scope_type === 'warehouse' && whs.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.warehouse_code} — {w.warehouse_name}</option>)}
            </Select>
            <Button disabled={!nr.role_id || (nr.scope_type !== 'group' && !nr.scope_id)} onClick={() => { setAs([...as, { ...nr, scope_id: nr.scope_type === 'group' ? null : nr.scope_id }]); setNr({ role_id: '', scope_type: 'warehouse', scope_id: '' }); }}><Plus className="size-4" />Add</Button>
          </div>
          {as.some((a) => roles.find((r) => r.id === a.role_id)?.requires_mfa) && <p className="mt-2 text-xs text-warn-600">This user will have to set up two-step verification (authenticator app) at next sign-in.</p>}
        </div>
        {user.email && <div><Button size="sm" onClick={async () => {
          const { error } = await supabaseBrowser().auth.resetPasswordForEmail(user.email, { redirectTo: `${window.location.origin}/auth/callback?next=/reset-password` });
          setResetMsg(error ? error.message : 'Password reset e-mail sent.');
        }}><KeyRound className="size-4" />Send password reset e-mail</Button>{resetMsg && <span className="ml-2 text-sm">{resetMsg}</span>}</div>}
        <ActionResult error={act.error} ok={act.ok} />
      </div>
    </Dialog>
  );
}
