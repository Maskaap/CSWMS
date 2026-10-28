# CSWMS — Backups and Recovery

## Backup layers

| Layer | What | Retention | Where configured |
|---|---|---|---|
| 1. Supabase daily backups | Full database, automatic | 7 days on Pro (longer on higher plans) | Supabase → Database → Backups |
| 2. Point-in-Time Recovery (recommended add-on) | Restore to any second | As purchased | Supabase → Database → Backups → PITR |
| 3. Independent weekly dump | Encrypted `pg_dump` (schemas `public`, `private`, `integrity`, `auth`) stored outside Supabase | 90 days (workflow artifacts) | `.github/workflows/db-backup.yml` |
| 4. Source code | Full history | Permanent | GitHub (business organisation) |

Optionally copy the weekly encrypted artifact to company storage (e.g. a SharePoint/OneDrive or S3 bucket) for longer retention.

## Why the ledger matters for recovery

Every balance can be rebuilt from the append-only ledger, and the Daily Stock Integrity Monitor checks after any restore that balances, ledger, hashes and sequences are consistent. A restore is **only accepted when an integrity check on the restored database is GREEN**.

## Restore drill (quarterly, on a separate project — never on production)

1. Create a temporary Supabase project (or use staging) with the same Postgres major version.
2. Download the latest *Weekly database backup* artifact and decrypt it:
   ```bash
   gpg --decrypt cswms_YYYY-MM-DD_HHMM.dump.gpg > cswms.dump
   sha256sum -c cswms_YYYY-MM-DD_HHMM.sha256   # run against the .gpg file
   ```
3. Restore into the empty project (schemas and data):
   ```bash
   pg_restore --no-owner --no-privileges --clean --if-exists -d "<staging connection string>" cswms.dump
   ```
   Then re-run the last migration file (`20261023000900_final_lockdown.sql`) so grants are exactly as intended, and re-create the pg_cron job (`docs/DEPLOYMENT.md` §2.3) if it is not present.
4. Point a staging deployment at it, sign in, open **Stock Integrity → Run check now**.
5. Record the result (date, backup file, GREEN/other, who) in the IT log. Investigate anything that is not GREEN before trusting the backup.

The automated test suite performs the same check locally on every run: `pg_dump` → restore into a new database → full integrity check passes.

## Production recovery

Restoring production discards transactions recorded after the backup. Follow this order:

1. **Decide**: a restore needs Head Office approval. Prefer correcting individual records through approved adjustments if the problem is limited.
2. **Stop activity**: tell branches to pause transactions; record the time.
3. **Choose the point**: PITR to just before the incident if available; otherwise the most recent good daily backup.
4. **Restore** via Supabase → Database → Backups (or PITR). For a lost project, restore the weekly dump into a new project (steps above) and change the Vercel environment variables to the new project.
5. **Verify**: run *Stock Integrity → Run check now*. Must be GREEN.
6. **Re-capture**: transactions made between the restore point and the incident must be re-captured from delivery notes, job cards and transfer documents; the employee activity report from before the incident (if available) helps.
7. **Document**: record what happened, the restore point, the integrity result and the re-captured transactions.

## What is not in a database backup

* User passwords and MFA factors live in Supabase Auth (included in layers 1–2; the weekly dump includes the `auth` schema).
* Environment variables and secrets — kept in Vercel and the password manager.
* Printed labels — reprint from *Print labels*.
