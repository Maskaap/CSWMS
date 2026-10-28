-- =============================================================================
-- CSWMS — create the FIRST Super Administrator (run once, after the migrations).
--
-- 1. Supabase dashboard > Authentication > Users > "Add user" > "Send invitation"
--    (or "Create new user") with the owner's work e-mail.
-- 2. Replace the two values below and run this script in the SQL Editor.
-- 3. Sign in to CSWMS; you will be asked to set up two-step verification (MFA).
-- All further users are added from the app (Users & Permissions).
-- =============================================================================
do $$
declare
  v_email text := 'owner@yourcompany.co.za';   -- <-- change
  v_name  text := 'System Owner';              -- <-- change
  v_id uuid;
begin
  select id into v_id from auth.users where lower(email) = lower(v_email);
  if v_id is null then
    raise exception 'No auth user with e-mail %. Create it under Authentication > Users first.', v_email;
  end if;
  insert into public.app_users (id, email, full_name, is_active)
  values (v_id, lower(v_email), v_name, true)
  on conflict (id) do update set full_name = excluded.full_name, is_active = true;
  insert into public.user_role_assignments (user_id, role_id, scope_type, scope_id)
  select v_id, r.id, 'group', null from public.roles r where r.code = 'SUPER_ADMIN'
  on conflict do nothing;
  raise notice 'Super Administrator ready: % (%)', v_name, v_email;
end $$;
