# CSWMS — Central Stock & Warehouse Management System

A secure, web-based inventory system for a multi-company group operating across several South African provinces. One central database; every branch, warehouse, shelf and bin; barcode/QR scanning on phones and scanners; monthly stocktakes; and an independent **Daily Stock Integrity Monitor** that proves every day that the records are internally consistent.

**Stack:** Next.js 16 (React 19, TypeScript, PWA) · Supabase (PostgreSQL, Auth, RLS, pg_cron) · Vercel.
**Settings:** ZAR · Africa/Johannesburg · DD/MM/YYYY.

## What is in the box

| Area | Where |
|---|---|
| Database schema, business rules, integrity monitor (8 Phase 1 + 5 Phase 2 + 2 Phase 3 migrations) | `supabase/migrations/` |
| First administrator bootstrap | `supabase/bootstrap_first_admin.sql` |
| Web application | `src/` |
| Database test suites (68 Phase 1 + 27 Phase 2 + 15 Phase 3 tests) | `tests/db/` |
| End-to-end browser tests | `tests/e2e/` |
| CI and weekly encrypted backup | `.github/workflows/` |
| Architecture & data model | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| Deployment (Supabase, Vercel, GitHub) | [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) · short path for your projects: [`docs/GO_LIVE.md`](docs/GO_LIVE.md) |
| One-file database install (all migrations) | `supabase/install/cswms_full_install.sql` |
| Staff operating instructions | [`docs/STAFF_GUIDE.md`](docs/STAFF_GUIDE.md) |
| Administrator operating instructions | [`docs/ADMIN_GUIDE.md`](docs/ADMIN_GUIDE.md) |
| Backups and recovery | [`docs/BACKUP_AND_RECOVERY.md`](docs/BACKUP_AND_RECOVERY.md) |
| Test report (passed / failed / outstanding) | [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md) |

## Feature status — Phase 1

| # | Feature | Status |
|---|---|---|
| 1 | Database architecture (immutable ledger + reconciled balances, audit) | ✅ Complete, tested |
| 2 | Authentication, roles, company/branch/warehouse scoping, admin MFA | ✅ Complete, tested (e-mail & MFA delivery: verify on staging) |
| 3 | Company / branch / warehouse / location setup | ✅ Complete |
| 4 | Categories, products, barcodes, pack conversions, thresholds | ✅ Complete |
| 5 | Opening stock import (Excel/CSV and manual) with validation + approval | ✅ Complete, tested end to end |
| 6 | Live stock inventory (by warehouse, shelf/bin, owner, status) | ✅ Complete |
| 7 | Receiving and withdrawal (unusual-quantity reconfirmation) | ✅ Complete, tested end to end |
| 8 | Returns, moves, status changes, adjustments, reversals, transfers | ✅ Complete, tested |
| 9 | Barcode & QR scanning (camera, USB, Bluetooth, typed) + label printing | ✅ Complete (physical devices: verify on staging) |
| 10 | Monthly stocktake (blind count, cut-off, recount, approval) | ✅ Complete, tested end to end |
| 11 | Low-stock and operational alerts, in-app notifications, e-mail | ✅ Complete (e-mail delivery: verify on staging) |
| 12 | Daily Stock Integrity Monitor + Stock Integrity & System Health dashboard | ✅ Complete, tested with 6 kinds of deliberate corruption |
| 13 | Management dashboard | ✅ Complete |
| 14 | Reporting with Excel / CSV / PDF export (14 reports) | ✅ Complete |
| 15 | Audit trails | ✅ Complete |
| 16 | Backups and operational monitoring | ✅ Complete (restore drill: perform on Supabase) |

## Feature status — Phase 2

| # | Feature | Status |
|---|---|---|
| 17 | Purchasing: purchase orders (draft → approval → sent → receive against PO → closed), PO PDF, over-receipt control, overdue alerts | ✅ Complete, tested end to end |
| 18 | Reorder suggestions (net of stock on order) turned into draft POs per supplier | ✅ Complete, tested |
| 19 | Advanced approvals: value-based multi-level rules (e.g. ≥ R50 000 → local approver, then head office), different person per level, reminders and escalation | ✅ Complete, tested |
| 20 | Tools & equipment: individual tags, check-out/in to employees or contractors per job, due dates, condition, repair / lost / retire, verification audits, overdue alerts, tag labels | ✅ Complete, tested end to end |
| 21 | Stock reservations screen; withdrawals pick the job from reserved chips and draw the reservation down | ✅ Complete, tested end to end |
| 22 | Notifications: per-person preferences (mute types, e-mail on/off, minimum severity), daily digest e-mail | ✅ Complete, tested (e-mail delivery: verify on staging) |
| 23 | Phase 2 reports: purchase orders, outstanding order lines, asset register, tool movements | ✅ Complete |

## Feature status — Phase 3 (advanced analytics)

| # | Feature | Status |
|---|---|---|
| 24 | Stock movement charts: received vs consumed by day / week / month, per warehouse, company, category or product | ✅ Complete, tested |
| 25 | Fast / medium / slow / not-moving / dead stock identification with ABC classification | ✅ Complete, tested |
| 26 | Stock ageing (first-in-first-out age bands 0–30 … over 1 year) | ✅ Complete, tested |
| 27 | Consumption by company, job / client, branch, warehouse, category, product and reason; job costing (materials net of returns, tools used, open reservations) | ✅ Complete, tested end to end |
| 28 | Inventory valuation at any date (weighted-average purchase cost) and month-end value trend | ✅ Complete, tested |
| 29 | Demand forecasting (damped-trend smoothing), stock-out prediction, suggested minimum and order quantities, draft POs from the forecast | ✅ Complete, tested |
| 30 | Predictive alerts: a daily "likely to run out" alert that clears itself when an order covers the gap | ✅ Complete, tested |
| 31 | Performance reporting: warehouse KPIs (turnover, days of stock, count accuracy, correction rate, PO on-time, approval speed) and supplier scorecard | ✅ Complete, tested |
| — | Production integration; e-mailing POs to suppliers | 🔶 Not in scope of the three phases — candidates for a later phase |

## Feature status — Phase 4 (floor experience)

| # | Feature | Status |
|---|---|---|
| 32 | Offline counting: counts kept on the phone (IndexedDB) and synced once each when the signal returns; late counts handled; counting screens available without signal | ✅ Complete, tested end to end (offline → online) |
| 33 | Guided count: bin by bin in walking order, scan = +1 (pack barcodes add the pack), typed bulk quantities, "bin empty", beep / vibration / colour flash | ✅ Complete, tested end to end |
| 34 | Cycle counting by A/B/C class (manual or automatic every working day), alongside the monthly stocktake | ✅ Complete, tested |
| 35 | "My tasks" home: counts with progress, tools held, transfers to receive, approvals, messages, recent undoable transactions | ✅ Complete, tested |
| 36 | Languages for floor screens (English, Afrikaans, isiZulu, isiXhosa) and large-text mode | ✅ Complete, tested · translations to be read by a first-language speaker |
| 37 | WhatsApp alerts (Cloud API, opt-in per person, chosen severity) | ✅ Complete, tested to the outbox · live sending needs a Meta template |
| 38 | Setup guide (step status, bulk bin generator, counting route) and training warehouse with practice stock | ✅ Complete, tested |
| 39 | Quick self-correction: undo your own transaction within 10 minutes, fully audited | ✅ Complete, tested end to end |
| 40 | Photo evidence on transactions, tools and stocktakes (private storage, short-lived links) | ✅ Complete, tested in the database · upload path to verify on Supabase Storage |
| 41 | Accounting journal export for Xero and Sage; weekly management summary e-mail | ✅ Complete, tested (journal balances) |

## Quick start (developers)

```bash
npm ci
cp .env.example .env.local        # fill in your Supabase URL + keys
npm run dev                        # http://localhost:3000
```

Database tests (PostgreSQL 16 locally):

```bash
tests/db/reset.sh && (cd tests/db && npm ci && node run-tests.mjs)
```

## Golden rules built into the system

1. **Stock only changes through a transaction.** The ledger is append-only; balances can only be written by the posting engine, in the same database transaction.
2. **Nothing is "saved" until the database confirms it.** Every submission carries a request ID: retries after a dropped connection can never post twice.
3. **No silent corrections.** Wrong or unusual input is rejected or must be re-confirmed; corrections are new, approved transactions.
4. **The integrity monitor never changes stock.** It detects, alerts and tracks investigations.
5. **A second person approves** purchase orders, large adjustments, reversals, write-offs, stocktake variances and opening balances — and high-value requests need further levels, each decided by a different person.
