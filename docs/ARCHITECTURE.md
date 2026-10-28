# CSWMS — Architecture and Database Design (Phases 1–3)

## 1. System overview

```
 Phones / tablets / PCs / scanners  ──HTTPS──►  Next.js app on Vercel (PWA, UI + 3 server routes)
            │                                         │  /api/admin/users  (invite user, secret key server-side only)
            │  supabase-js (user's JWT)               │  /api/cron         (dispatcher + alert e-mails, CRON_SECRET)
            ▼                                         │  /api/health       (uptime probe)
   Supabase API (PostgREST + Auth)  ◄─────────────────┘
            │  role "authenticated" + JWT claims
            ▼
   PostgreSQL (Supabase)
     public     tables, views, permission-checked RPC functions (the API)
     private    posting engine, permission helpers, idempotency keys, balance change log, e-mail outbox
     integrity  Daily Stock Integrity Monitor: runs, findings, investigation events
     pg_cron    every 15 min → integrity.dispatch()
```

* **One central database** for the whole group. Every branch sees current balances immediately; there is no local copy to synchronise.
* **The database is the authority.** All business rules (permissions, quantities, approvals, stock availability) are enforced in PostgreSQL functions and Row Level Security. The browser cannot bypass them, even with a modified client.
* **The UI never stores transactions offline.** The service worker only makes the app installable and shows an offline page; a transaction is "saved" only after the database commits it.

## 2. Organisation model

```
Head office (group) → Company (legal owner) → Branch (physical site, own code, province)
                    → Warehouse → Storage area → Shelf → Bin
```

* Companies and branches have **separate identifiers**; a branch is operated by a company.
* **Ownership is recorded on every balance** (`owner_company_id`), independent of where stock is stored — a company can hold stock at another company's branch and keep legal ownership. Intercompany transfers change ownership only on receipt.
* Provinces, companies, branches, warehouses and locations are data, so expansion needs no software change.

## 3. Inventory data model

| Table | Purpose |
|---|---|
| `stock_transactions` | One row per business transaction (receipt, withdrawal, return, move, transfer dispatch/receipt/write-off, adjustment, stocktake adjustment, status change, reversal, opening). Who, where, when, why, reference, approval. Tamper-evident content hash. |
| `stock_transaction_lines` | What was entered: product, location, owner, status, entered quantity and unit, conversion factor. |
| `stock_ledger` | **Authoritative, append-only movement ledger** in base units, one row per balance change, with running `balance_after` and a per-row hash chained in sequence. Cannot be updated or deleted. |
| `stock_balances` | Stored balance per product × location × owner × status (available / damaged / quarantine / in transit) for fast everyday use. Written **only** by the posting engine inside the same database transaction as the ledger. Every change is also written to `private.balance_change_log`. |
| `stock_reservations` | Allocations that reduce "free to use" without moving stock. |
| `transfers`, `transfer_lines` | Dispatch → in transit → received / partially received / closed with discrepancy / cancelled. |
| `approval_requests` | Second-person approval for adjustments, reversals, transfer write-offs, stocktakes and opening balances (requester ≠ approver enforced by a constraint). |
| `stocktakes`, `stocktake_assignments`, `stocktake_lines`, `stocktake_counts` | Monthly stocktake with cut-off snapshot, blind counting, rounds, recounts, flags and variances. |
| `import_batches`, `import_rows` | Staged opening-balance imports with per-row errors/warnings, file fingerprint (no repeat import) and approval. |
| `alerts`, `notifications`, `private.email_outbox` | De-duplicated alerts (one per unresolved condition), in-app notifications, e-mail delivery queue. |
| `integrity.runs`, `integrity.findings`, `integrity.finding_events` | Monitor evidence, findings with severity/classification, investigation history. |
| `audit_log`, `system_events` | Permanent audit of master-data, role and settings changes; job and error events. |
| Master data | `companies`, `branches`, `warehouses`, `storage_locations`, `provinces`, `categories` (unlimited, nested), `products`, `uoms`, `product_uoms` (pack conversions), `barcodes`, `stock_thresholds` (per product per warehouse), `suppliers`, `product_costs`, `reason_codes`, `roles`, `permissions`, `app_users`, `user_role_assignments`, `app_settings`. |

Reporting views (`v_stock_balances`, `v_stock_by_warehouse`, `v_movements`, `v_transactions`, `v_transfers`, `v_stocktake_summary`, `v_approvals`, `v_warehouse_tree`) run with the caller's permissions, so every report is automatically limited to what the user may see. Quantities are always reported **per unit of measure** — incompatible units are never added together.

## 4. How a stock transaction is posted

1. The app generates a **request ID** for the attempt and keeps it until the database confirms. Double clicks are ignored while a request is in flight.
2. The RPC (e.g. `withdraw_stock`) checks the user, the permission **for that warehouse**, the reason/reference rules, units and conversions, quantity format, location-in-warehouse and product status.
3. **Idempotency:** if the request ID was already processed with the same payload, the original result is returned (nothing is posted twice); the same ID with a different payload is refused.
4. **Unusual quantity:** if the quantity is far above this item's normal withdrawals (configurable factor, or a per-product limit), the database refuses with a "confirm" response; the user must physically check and re-confirm, and the transaction is flagged and managers notified. Values are never guessed or corrected.
5. **Posting engine:** locks the affected balance rows in a fixed order (`SELECT … FOR UPDATE` — no deadlocks), checks availability (including reservations), writes header, lines, ledger rows and balances **in one database transaction**. Two people withdrawing at once can never overdraw the same stock.
6. Low-stock thresholds are re-evaluated and alerts raised or cleared.
7. Only after commit does the app show **Saved — WDR-2026-000123**. If the connection drops, the app shows **NOT CONFIRMED** with *Retry safely*, which re-sends the same request ID.

Corrections are never edits: they are new adjustments or reversals (equal and opposite), approved by a second person when above configurable thresholds (quantity, % of balance, value in ZAR; above a higher threshold, head office).

## 5. Security model

* Individual accounts (Supabase Auth). Administrative roles (Super Administrator, Head Office) **must** use MFA — the database refuses their privileged calls without an `aal2` session, and the app forces enrolment.
* Roles: Super Administrator, Head Office Management, Company Manager, Branch Manager, Warehouse Supervisor, Stock Controller, Stocktake Counter, Auditor/Viewer — each a configurable list of permissions, assigned **per scope** (group, company, branch or warehouse).
* **Row Level Security** on every table: users only see stock of warehouses they are assigned to (and stock their company owns elsewhere). Anonymous access is denied everywhere.
* Client roles have **no direct write access** to transactions, ledger or balances — only permission-checked functions. Master data writes are RLS-checked and audited. Users cannot grant roles beyond their own scope/permissions; the last Super Administrator cannot be removed.
* The secret Supabase key is used only in two server routes (user invitation, cron) and never reaches the browser. Secrets live in environment variables, never in source code.
* Security headers (HSTS, frame denial, no sniffing, camera limited to the app) are set in `next.config.ts`.

## 6. Daily Stock Integrity Monitor

Runs **independently** of receiving/withdrawal workflows:

* **Scheduling:** pg_cron calls `integrity.dispatch()` every 15 minutes. The dispatcher starts the daily check once the configured local time (default 02:00 Africa/Johannesburg) has passed and no successful check exists for the day; retries failures (max attempts configurable); and runs a **watchdog** that raises a critical alert and turns the status GREY when checks are missing or stale. Vercel Cron calls the same dispatcher as a second, independent trigger.
* **Consistency:** the ledger-vs-balance reconciliation is a single SQL statement, i.e. one consistent snapshot. Candidate mismatches are re-validated; changes that legitimately happened between snapshot and validation are classified *transient*, not discrepancies.
* **Checks:** ledger ≠ stored balance (by company, branch, warehouse, location, owner, product, status); negative stock; historical records changed (row/transaction hashes, sealed checkpoints); ledger sequence breaks (deleted/inserted rows); unexplained balance changes (balance change log entries without a posting); orphaned/incomplete transactions; invalid quantities and unit conversions; invalid company/warehouse references; incorrect transfer accounting; transfers overdue; duplicate/conflicting transactions; possible repeat withdrawals; unusual and unapproved adjustments; suspicious after-hours activity; monitoring failures.
* **Never changes stock:** while a check runs, any attempt to change a balance raises an error; there is no code path from the monitor to balances or the ledger. Findings are investigated and corrected through normal approved transactions.
* **Status:** GREEN (all checks passed, nothing unresolved) · AMBER (warnings / open investigations) · RED (confirmed problems or critical failures) · GREY (check failed, incomplete, never ran or stale). Never GREEN unless the latest check completed successfully.
* **Alerts:** one alert per issue (no duplicates on re-run), branch/company managers notified, significant issues escalated to head office, daily summary, e-mail where configured, permanent log, assignment and resolution tracking.
* The monitor verifies **electronic consistency**. Physical losses and counting errors are found by the monthly stocktake.

## 7. Phase 2 additions

| Area | Tables / views | Key functions | Notes |
|---|---|---|---|
| Purchasing | `purchase_orders`, `purchase_order_lines`, `v_purchase_orders`, `v_purchase_order_lines` | `create/update/submit/send/close/cancel_purchase_order`, `receive_purchase_order`, `purchase_suggestions`, `create_po_from_suggestions` | Receipts against a PO go through the normal posting engine (`receipt` transaction, line `extra` = PO / line ids), so the ledger, balances and integrity monitor treat them exactly like other receipts. Over-receipt and concurrent receipts are blocked under row locks. |
| Advanced approvals | `approval_rules`, `approval_decisions` (immutable), new columns on `approval_requests` (`value_zar`, `step_levels`, `steps_done`, `purchase_order_id`) | `decide_approval` (multi-level), `save_approval_rule`, `approvals_i_can_decide`, `private.has_perm_at_level` | A BEFORE INSERT trigger values each request and copies the highest matching rule's levels onto it, so later rule changes never alter a request in flight. Stock or PO state changes only when the last level approves. |
| Tools & equipment | `assets`, `asset_movements` (immutable), `v_assets`, `v_asset_movements` | `register_asset`, `checkout_asset`, `checkin_asset`, `set_asset_status`, `transfer_asset`, `verify_asset`, `asset_lookup` | Assets are individually tagged and tracked by custody, not by stock quantity; every action is idempotent (request id) and appended to the movement history. |
| Reservations | `v_reservations` over `stock_reservations` | `create_reservation`, `release_reservation` | Withdrawals quoting the reservation's reference draw it down; others can only take unreserved stock. |
| Notifications | `notification_preferences` | `my_notification_preferences`, `set_notification_preferences`, `private.raise_alert` (honours preferences) | Critical and integrity alerts bypass mutes. |
| Housekeeping | — | `private.ops_housekeeping` (called by `integrity.dispatch`) | Overdue POs and tools, approval reminders/escalation, daily digests. A failure is logged to `system_events` and never blocks the integrity check. |

All new tables have RLS enabled and forced with select-only policies scoped to the user's warehouses (tools also visible to their holder); all writes go through permission-checked functions. The final lockdown migration (`20261026009000`) re-applies the Phase 1 privilege lockdown over the new objects.

## 8. Phase 3 — analytics

All analytics are **read-only, permission-checked functions over the immutable ledger** (migration `20261027001000`); no new client-readable tables. Scope = warehouses where the user holds `reports.view`; rand values only with `cost.view` (otherwise value fields are null and charts count transaction lines). The filter "owning company" applies to the legal owner of the stock.

| Function | What it computes | Method |
|---|---|---|
| `analytics_movements` | Received, issued, returned, transfers in/out, adjustments per day/week/month | Ledger rows by type; in-transit legs excluded so transfers are not double counted |
| `analytics_velocity` | Fast / medium / slow / not moving / dead + ABC | Issues per month vs `analytics.fast_issues_per_month` (8) and `slow_issues_per_month` (2); dead = stock on hand with no issue and no receipt for `analytics.dead_days` (180); ABC = cumulative 80 / 95 % of consumption value |
| `analytics_ageing` | On-hand quantity and value in age bands | FIFO: the stock on hand is the most recent arrivals into that warehouse (receipts, opening, returns, transfer receipts, positive corrections) |
| `analytics_consumption` | Net consumption by company, job/client, branch, warehouse, category, product, reason | Withdrawals − returns; job/client = transaction reference, matched ignoring case and surrounding spaces |
| `analytics_job` | Job costing | Materials net of returns × cost, the transactions, tools checked out to the job (tool-days), open reservations |
| `analytics_valuation`, `_trend` | Stock value at any date / month-ends | Quantity from the ledger up to the date × **weighted-average cost** of all costed receipts and opening balances up to that date; fallback last purchase price; else "no price" |
| `analytics_forecast` | Demand, stock-out date, safety stock, reorder point, suggested minimum and order | Twelve 30-day periods of net issues; Holt's damped-trend smoothing (α 0.5, β 0.3, φ 0.9); lead time learnt from this item's (else its supplier's) purchase orders, else `analytics.default_lead_days`; safety stock = z·σ·√L (z = `analytics.service_level_z`, 1.65 ≈ 95 %); "will run out" = free + on order < demand during the lead time |
| `analytics_performance` | Warehouse KPIs | Annualised turnover = consumption ÷ average stock value; count accuracy from finalised stocktakes; PO on-time and lead time; approval turnaround; alerts and integrity findings |
| `analytics_supplier_performance` | Supplier scorecard | On-time first delivery, fill rate of completed orders, average lead time |

**Predictive alerts.** `private.ops_predictive()` runs once a day after `analytics.prediction_time` (05:00) from the same 15-minute scheduler as the integrity check, in its own error block: a failure is logged to *System health* and never blocks the integrity check. It raises one `stockout_risk` alert per item and warehouse predicted to run out before a reorder could arrive, and resolves it when that is no longer true (e.g. an order was approved). Runs are recorded in `private.analytics_runs`.

Units are never added together across products: cross-product totals are in rand (or line counts) and quantity totals are shown per unit of measure.

## 9. Designed for later phases

Production integration (bills of materials, issuing to production orders, receiving finished goods) can build on the same posting engine: a production order would withdraw components and receive finished goods as two linked transactions, and job costing already aggregates by reference.
