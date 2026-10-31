# CSWMS — Deployment Guide (GitHub · Supabase · Vercel)

Everything below is done once, by your IT administrator, using **accounts owned by the business** (not personal accounts). Keep all passwords and keys in the company password manager.

Recommended environments: **staging** (a separate Supabase project + Vercel preview) for training and testing, and **production**.

---

## 1. Source code — GitHub

1. Create a GitHub **organisation** for the business (e.g. `cswms-group`) and a **private** repository `cswms`.
2. Push this code:
   ```bash
   git remote add origin git@github.com:cswms-group/cswms.git
   git push -u origin main
   ```
3. Settings → Branches: protect `main` (require pull request + the **CI** workflow to pass). CI runs the 68 database tests and a production build on every change.
4. Add at least two organisation owners so access never depends on one person.

## 2. Database — Supabase

1. Create a Supabase organisation for the business; create project **cswms-prod** (and **cswms-staging**).
   * **Plan:** Pro or higher (daily backups retained 7 days, optional Point-in-Time Recovery, no project pausing).
   * **Region:** Supabase currently has **no African region**. Choose **EU West (London) `eu-west-2`** — usually the lowest latency from South Africa. Data will therefore be stored outside South Africa: confirm this is acceptable under your POPIA obligations (stock data is mostly non-personal; employee names and e-mails are personal information).
   * Generate a strong database password and store it.
2. Database → Extensions: enable **pg_cron** (the migration also tries to enable it).
3. Apply the migrations **in filename order** — either:
   * Supabase CLI: `npx supabase login && npx supabase link --project-ref <ref> && npx supabase db push`, or
   * SQL Editor: paste and run each file in `supabase/migrations/` in filename order (Phase 1: `20261023000100` → `20261023000900`, then Phase 2: `20261026001000` → `20261026009000`, then Phase 3: `20261027001000`, `20261027009000`).
   Watch for the notice `pg_cron job cswms-integrity-dispatch scheduled`. If it says pg_cron is unavailable, enable the extension and run:
   ```sql
   select cron.schedule('cswms-integrity-dispatch', '*/15 * * * *', 'select integrity.dispatch()');
   ```
4. **Authentication settings** (Authentication → Sign In / Providers, URL Configuration):
   * Email provider **on**; **"Allow new users to sign up" OFF** — only administrators create accounts.
   * Minimum password length 10; enable leaked-password protection if available on your plan.
   * Multi-factor: **TOTP enabled**.
   * Site URL: `https://stock.yourdomain.co.za`; Redirect URLs: `https://stock.yourdomain.co.za/auth/callback`, `https://stock.yourdomain.co.za/auth/confirm`.
   * Email templates — make the links go through the app's `/auth/confirm` route:
     * **Invite user:** `<a href="{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=invite">Accept the invitation and choose your password</a>`
     * **Reset password:** `<a href="{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=recovery">Choose a new password</a>`
   * SMTP: configure your own SMTP sender (e.g. Resend SMTP) — Supabase's built-in sender is rate-limited and not for production.
5. **First administrator:** Authentication → Users → *Add user* (owner's work e-mail), then run `supabase/bootstrap_first_admin.sql` in the SQL Editor after editing the e-mail and name.
6. Project Settings → API Keys: note the **Project URL**, **publishable key** and **secret key**.

## 3. Application — Vercel

1. Create a Vercel **team** for the business (Pro plan recommended). `vercel.json` ships with a **daily** cron so it also deploys on Hobby; on Pro change it to `*/15 * * * *` for near-immediate alert e-mails. pg_cron in the database remains the primary 15-minute scheduler either way.
2. *Add New → Project →* import the GitHub repository. Framework: Next.js (detected).
3. `vercel.json` runs functions in **`lhr1` (London)** to sit next to the database. If you chose a different Supabase region, change it to the matching Vercel region.
4. Environment variables (Production, and separately for Preview/staging):

   | Name | Value |
   |---|---|
   | `NEXT_PUBLIC_SUPABASE_URL` | Project URL |
   | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | publishable key (or legacy anon key) |
   | `SUPABASE_SECRET_KEY` | secret key (or legacy service_role key) — **server only** |
   | `NEXT_PUBLIC_SITE_URL` | `https://stock.yourdomain.co.za` |
   | `CRON_SECRET` | long random string (`openssl rand -hex 32`) |
   | `RESEND_API_KEY` | Resend API key (for alert e-mails) |
   | `ALERT_EMAIL_FROM` | e.g. `CSWMS Alerts <alerts@yourdomain.co.za>` (verified domain) |
   | `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID` | Optional — WhatsApp alerts (§ 4a). `WHATSAPP_TEMPLATE` / `WHATSAPP_TEMPLATE_LANG` default to `cswms_alert` / `en` |

5. Deploy, then add the custom domain `stock.yourdomain.co.za` (Settings → Domains) and update your DNS as instructed.
6. Never commit `.env*` files; they are git-ignored.

## 4. E-mail alerts — Resend (optional but recommended)

1. Create a Resend account for the business, verify `yourdomain.co.za` (SPF/DKIM DNS records).
2. Create an API key → `RESEND_API_KEY`. The `/api/cron` route delivers queued alert e-mails every run and records failures.
3. In CSWMS: *System Administration → Settings → alerts* set **alerts.email_enabled = Yes**. Warning and critical alerts are then e-mailed to everyone whose role includes *receive alerts* (`alerts.receive`) for the affected warehouse, branch or company; escalated issues also go to head-office roles with `alerts.escalation`. The daily integrity summary is controlled by `alerts.daily_summary_enabled`.

### 4a. WhatsApp alerts (optional)

1. In Meta Business Manager create a WhatsApp Business account and a phone number for the Cloud API; create a **permanent access token** (system user) with `whatsapp_business_messaging`.
2. Create a message template named `cswms_alert` (category *Utility*, language English) with the body
   `CSWMS alert: {{1}} — {{2}}` and wait for approval.
3. Vercel → Environment Variables: `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, optionally `WHATSAPP_TEMPLATE` (default `cswms_alert`) and `WHATSAPP_TEMPLATE_LANG` (default `en`). Redeploy.
4. CSWMS → *System Administration → Settings → alerts*: `alerts.whatsapp_enabled = Yes`. Staff opt in under *My settings*.

### 4b. Prompt delivery on the Vercel Hobby plan

Hobby runs `/api/cron` once a day, so e-mails and WhatsApp messages would wait until 04:00 UTC. Use a free external scheduler (e.g. cron-job.org) to call
`GET https://<your-app>/api/cron` every 10–15 minutes with the header `Authorization: Bearer <CRON_SECRET>`. Calling it more often is harmless — every step is idempotent. (The integrity check and other database jobs already run every 15 minutes inside the database.)

## 5. Independent backups — GitHub Actions

Repository → Settings → Secrets and variables → Actions:
* `SUPABASE_DB_URL` — Supabase → Connect → *Session pooler* connection string (with password).
* `BACKUP_PASSPHRASE` — long random passphrase, also stored in the password manager (without it the backups cannot be restored).

Then Actions → *Weekly database backup* → **Run workflow** once to confirm it works. See `docs/BACKUP_AND_RECOVERY.md`.

## 6. Uptime monitoring

Point an uptime monitor (e.g. UptimeRobot, Better Stack) at `https://stock.yourdomain.co.za/api/health` (expects HTTP 200). It checks the app and the database connection without exposing data.

## 7. Go-live checklist

| ✔ | Check |
|---|---|
| ☐ | `/api/health` returns `{"ok":true}` |
| ☐ | First Super Administrator signs in, enrols MFA, and sees the dashboard |
| ☐ | Setup: companies, provinces, branches, warehouses, storage locations created; location labels printed |
| ☐ | Users invited; each receives the e-mail, sets a password; roles assigned with the right scope |
| ☐ | **Role check:** sign in as a Cape Town stock controller — only Cape Town warehouses are visible; try a Gqeberha warehouse URL — no data |
| ☐ | Opening stock imported to **staging** first, validated, approved by a second person; totals agreed with the old spreadsheets |
| ☐ | A receipt, a withdrawal, a transfer and a return done on staging with real scanners and phones |
| ☐ | Next morning: *Stock Integrity* shows a successful scheduled run (GREEN). SQL: `select * from cron.job_run_details order by start_time desc limit 5;` |
| ☐ | Alert e-mail received for a low-stock test item |
| ☐ | Weekly backup workflow run manually and a restore drill completed on a separate project |
| ☐ | Opening stock imported to **production**; staff trained (`docs/STAFF_GUIDE.md`) |

## 8. Changing the database later

* Add a new migration file with a later timestamp; never edit a migration that is already applied in production.
* After adding functions or tables, re-apply the privilege lockdown (copy `20261023000900_final_lockdown.sql` as the newest migration, adding grants for any new RPC functions) so new objects are not exposed by default.
* Run the database test suite (CI does this automatically) and test on staging before production.

## Upgrading a live Phase 1 system to Phase 2

1. Take a manual backup (*Weekly database backup* → *Run workflow*) and note the integrity status (should be GREEN).
2. Apply the five Phase 2 migrations in order: `20261026001000`, `001100`, `001200`, `001300`, `009000`. They only add tables, columns, functions and permissions; no stock data is changed.
3. Deploy the matching app version (Vercel redeploys on push to `main`).
4. Check: *System administration → Approval rules* lists the seeded rules; *Users & Permissions* roles now include the purchasing and tool permissions; run an integrity check — it must stay GREEN.
5. Note: `create_reservation` now requires `p_request_id` (retry safety). Only matters if you call the API from your own scripts.

## Upgrading to Phase 3

Apply `20261027001000_phase3_analytics.sql` then `20261027009000_phase3_security_lockdown.sql` and deploy the matching app. Nothing in stock is changed: Phase 3 only adds read-only functions, settings in the *analytics* category, a new alert type and the daily prediction step in the existing scheduler. Check: *Analytics* opens for a manager; the next morning *Analytics* shows "Stock-out prediction last ran …".


## Upgrading to Phase 4 (floor experience)

1. Take a backup and check the integrity status is GREEN.
2. Supabase → *SQL Editor* → paste and run `supabase/install/cswms_phase4_upgrade.sql` (the three Phase 4 migrations `20261031001000`, `001100`, `009000` in one transaction — if anything fails nothing is changed). It adds columns, tables and functions, creates the private Storage bucket `evidence` and does not change any stock.
3. Deploy the matching app version. The service worker updates itself (`cswms-v2`).
4. Check: **My tasks** opens; *My settings* saves a language; on a test warehouse do a withdrawal and press **Undo**; *Setup guide* opens; run an integrity check — it must stay GREEN.
5. Optional: WhatsApp (§ 4a), external cron (§ 4b), `cycle.items_per_day`, accounting account codes.
6. API note: `record_count` has three new optional arguments (`p_counted_at`, `p_offline`, `p_method`); existing calls keep working.
