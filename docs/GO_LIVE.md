# CSWMS — Go-live sheet (your projects)

Created for you on 27/10/2026. Full background is in `DEPLOYMENT.md`; this sheet is the short path.

| | |
|---|---|
| Supabase project | ref `xiaxxlsyocfymiezegwt` (your project) · run the install on it while it is empty |
| Supabase URL | `https://xiaxxlsyocfymiezegwt.supabase.co` |
| Vercel project | **cswms** (Hobby plan) · functions in London (`lhr1`) · not deployed yet |
| Already set in Vercel | `NEXT_PUBLIC_SUPABASE_URL` (new project), `CRON_SECRET` (generated), `ALERT_EMAIL_FROM` (placeholder). **Replace** `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` — it still holds the old project's key |
| First Super Administrator | martinhiskia@outlook.com |

## 1. Database (Supabase) — about 10 minutes

1. Supabase → your project (`xiaxxlsyocfymiezegwt`) → *Database → Extensions* → enable **pg_cron**.
2. *SQL Editor* → New query → paste the whole of `supabase/install/cswms_full_install.sql` → **Run**. (It is all 15 migrations in order and runs as one script. Alternatively, from the repo: `npx supabase link --project-ref xiaxxlsyocfymiezegwt` then `npx supabase db push`.)
   Check: `select count(*) from cron.job;` returns 1 (the 15-minute integrity scheduler).
3. *Authentication → Sign In / Providers*: Email on, **Allow new users to sign up: OFF**; Multi-factor: **TOTP on**.
4. *Authentication → Users → Add user → Send invitation* to **martinhiskia@outlook.com**.
5. SQL Editor → run (change the name if you like):
   ```sql
   do $$
   declare v_id uuid;
   begin
     select id into v_id from auth.users where lower(email) = 'martinhiskia@outlook.com';
     if v_id is null then raise exception 'Invite the user under Authentication > Users first'; end if;
     insert into public.app_users (id, email, full_name, is_active)
     values (v_id, 'martinhiskia@outlook.com', 'Martin Hiskia', true)
     on conflict (id) do update set is_active = true;
     insert into public.user_role_assignments (user_id, role_id, scope_type, scope_id)
     select v_id, id, 'group', null from public.roles where code = 'SUPER_ADMIN' on conflict do nothing;
   end $$;
   ```

## 2. Application (Vercel) — about 10 minutes

1. Put the code from `cswms-phase3.zip` (or the updated zip) in a **private GitHub repository**.
2. Vercel → project **cswms** → *Settings → Git* → **Connect** that repository. Vercel builds and deploys on every push to `main`.
3. *Settings → Environment Variables* → edit `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` to the new project's **publishable key** (Supabase → *Project Settings → API Keys*), then add (Production + Preview):
   * `SUPABASE_SECRET_KEY` — Supabase → *Project Settings → API Keys* → **secret key** (needed for inviting users from the app and for the e-mail job). Keep it secret.
   * `NEXT_PUBLIC_SITE_URL` — the production address Vercel gives you (e.g. `https://cswms.vercel.app`, or your own domain).
   * Optional e-mail alerts: `RESEND_API_KEY` and a real `ALERT_EMAIL_FROM` (see DEPLOYMENT.md § 4).
   Then **Redeploy** so the new variables take effect.
4. Supabase → *Authentication → URL Configuration*: Site URL = your app address; add `<app>/auth/callback` and `<app>/auth/confirm` to Redirect URLs. Set the *Invite* and *Reset password* e-mail templates as in DEPLOYMENT.md § 2.4.

## 3. First sign-in and checks

1. Open the invitation e-mail as martinhiskia@outlook.com → choose a password → sign in → set up the authenticator app (MFA).
2. `https://<app>/api/health` shows `{"ok":true}`.
3. Work through the go-live checklist in DEPLOYMENT.md § 7 (setup, users, opening stock on a test warehouse first, role check, next-morning GREEN integrity status).

## Notes for the Hobby plan

* Vercel Hobby allows a once-a-day cron, so `vercel.json` runs `/api/cron` daily (04:00 UTC); it delivers queued alert e-mails. The **integrity check, reminders, purchasing/tool housekeeping and stock-out predictions run every 15 minutes inside the database (pg_cron)** and do not depend on Vercel. On a Vercel Pro team, change the cron back to `*/15 * * * *` for near-immediate e-mails.
* New Vercel projects have *Deployment Protection* on for preview URLs; the production address is open. If staff see a Vercel login page, check *Settings → Deployment Protection*.
* Supabase free-tier projects pause after a week of inactivity and have no daily backups — use the **Pro** plan for production (DEPLOYMENT.md § 2).
