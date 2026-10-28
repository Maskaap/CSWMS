# CSWMS — Test Report (Phases 1–3)

Generated from the recorded test runs on **26/10/2026**. Both suites were run from a freshly created database. Re-run at any time — see *How to re-run* at the end.

## Summary

| Suite | What it exercises | Passed | Failed |
|---|---|---|---|
| Database (`tests/db`) | Every stock rule, permission and the Daily Stock Integrity Monitor, executed exactly as Supabase executes them (role `authenticated`, JWT claims, one transaction per call) on PostgreSQL 16 | **68** | 0 |
| Database — Phase 2 (`tests/db/run-phase2-tests.mjs`) | Purchasing, multi-level approvals, tools & equipment, reservations, notification preferences, digests, scheduled housekeeping — on its own fresh database | **27** | 0 |
| Database — Phase 3 (`tests/db/run-phase3-tests.mjs`) | Analytics and predictive management on 14 months of history (85 real transactions, posted then backdated with hashes recomputed); every expected answer computed independently | **15** | 0 |
| End-to-end (`tests/e2e`) | Production build of the app in a real browser (Chromium), real PostgREST on the test database, eight roles, every screen (Phases 1–3), complete workflows | **127** | 0 |

**Result: all automated tests pass (237 / 237).** The Phase 1 and Phase 2 suites were re-run after the Phase 3 migrations: no regressions. Items that cannot be proven in an automated sandbox are listed under *Outstanding — verify on staging* and must be signed off before go-live.

## 1. Database suite — passed

| Area | Test | Evidence |
|---|---|---|
| Opening import | ✅ Validation detects every error type before anything is posted | 13 rows with errors, 2 with warnings |
| Opening import | ✅ Submission is blocked while errors exist |  |
| Opening import | ✅ Rows can be corrected or excluded; preview re-validates |  |
| Opening import | ✅ Opening balances need approval by someone else (no self-approval) |  |
| Opening import | ✅ Approved opening balances create auditable OPENING transactions |  |
| Duplicate import protection | ✅ The same file cannot be imported twice |  |
| Duplicate import protection | ✅ A renamed/edited copy cannot double-load items that already have stock |  |
| Receiving | ✅ Receiving in a unit without a conversion is rejected (unit-of-measure validation) |  |
| Receiving | ✅ Receipt in packs converts to base units and posts ledger + balance atomically | RCV-2026-000001 |
| Receiving | ✅ Supplier / delivery reference is mandatory |  |
| Duplicate prevention | ✅ A retried request (same request id) returns the original result without posting twice |  |
| Duplicate prevention | ✅ Reusing a request id for a different payload is rejected |  |
| Duplicate prevention | ✅ Double-click: two simultaneous submissions with the same request id post once |  |
| Lost connection | ✅ Connection lost after commit: retry is safe and returns the committed result |  |
| Lost connection | ✅ Connection lost before commit: nothing is saved and the retry posts exactly once |  |
| Atomicity | ✅ A multi-line transaction with one failing line changes nothing |  |
| Withdrawals | ✅ Withdrawal decreases stock and records who, where, when and why |  |
| Incorrect quantities | ✅ Normally 5 rolls, entering 50 triggers a warning and requires reconfirmation (no silent correction) |  |
| Incorrect quantities | ✅ Zero, negative, wrong decimals and wrong-warehouse locations are rejected |  |
| Incorrect quantities | ✅ Reasons that need a client/job reference cannot be posted without one |  |
| Insufficient stock | ✅ Withdrawing more than is available fails and changes nothing |  |
| Insufficient stock | ✅ Stock reserved for another job cannot be withdrawn |  |
| Concurrency | ✅ 40 simultaneous withdrawals by two users can never overdraw the balance | 14 succeeded, 26 refused |
| Concurrency | ✅ Simultaneous multi-line postings in opposite order do not deadlock |  |
| Returns | ✅ Return linked to the original withdrawal; damaged stock tracked separately; cannot over-return |  |
| Moves | ✅ Shelf-to-shelf move inside a warehouse keeps the warehouse total unchanged |  |
| Transfers | ✅ Branch-to-branch transfer: dispatch moves stock to "in transit", not available anywhere |  |
| Transfers | ✅ Only users authorised at the destination can receive |  |
| Transfers | ✅ Partial receipt with damage; over-receipt blocked; transfer stays open until complete |  |
| Transfers | ✅ Shortage write-off needs approval; then the transfer closes with a discrepancy |  |
| Transfers | ✅ Intercompany transfer changes legal ownership on receipt |  |
| Stock in transit | ✅ A company can store stock in another company's warehouse while keeping ownership |  |
| Transfers | ✅ Overdue transfer is detected and alerted | TRF-2026-000003 (verified by the integrity run below) |
| Approvals | ✅ Small adjustment with reason posts directly; explanation is mandatory |  |
| Approvals | ✅ Large adjustment waits for management approval; balance unchanged until approved |  |
| Approvals | ✅ Rejected adjustment never touches stock |  |
| Approvals | ✅ Reversal of a posted transaction requires approval and keeps the original record |  |
| Audit | ✅ Posted transactions and ledger rows cannot be edited or deleted (even by the database owner) |  |
| Permissions | ✅ Users cannot transact outside their warehouses or roles |  |
| Permissions | ✅ Row-level security: users only see stock they are authorised for |  |
| Permissions | ✅ Direct writes to balances, ledger or transactions are refused for application users |  |
| Permissions | ✅ Anonymous users have no access; integrity tables are not reachable |  |
| Permissions | ✅ Administrative roles require multi-factor authentication (aal2) |  |
| Permissions | ✅ Privilege escalation is blocked when assigning roles |  |
| Barcodes | ✅ Scanning a product barcode, pack barcode, SKU or location label resolves correctly |  |
| Barcodes | ✅ Generated barcodes are unique and duplicate barcodes are impossible |  |
| Low stock | ✅ Crossing the minimum raises one alert, notifies managers, and resolves on replenishment |  |
| Stocktake | ✅ Schedule by branch creates one stocktake per warehouse; assign counter |  |
| Stocktake | ✅ Start takes a consistent cut-off snapshot | 7 lines |
| Stocktake | ✅ Blind count: counter cannot see expected quantities |  |
| Stocktake | ✅ Counting with legitimate movements after the cut-off, zero vs not counted, unexpected items, duplicates |  |
| Stocktake | ✅ Compare flags missing, additional, wrong location, not counted and accounts for movements | {"ok":true,"lines":8,"counted":5,"missing":2,"additional":2,"not_counted":3,"discrepancies":4,"recount_requested":0} |
| Stocktake | ✅ Supervisor orders a recount; second count replaces the first |  |
| Stocktake | ✅ Approval by another manager posts traceable adjustments and finalises |  |
| Integrity: reconciliation | ✅ Clean data: every balance reconciles with the ledger → GREEN | 17 keys, 105 ledger rows checked; 55 warning findings |
| Integrity: reconciliation | ✅ Status is GREEN only when all checks passed and nothing is unresolved |  |
| Integrity: protection | ✅ Ordinary employees cannot run, read or modify the monitor |  |
| Integrity: deliberate errors | ✅ Deliberately corrupt the database in 6 different ways (test DB only) | balance edit, ledger edit, unapproved adjustment, orphan header, phantom in-transit, repeated withdrawal |
| Integrity: deliberate errors | ✅ The monitor detects every deliberately introduced inconsistency | 38 findings: INCOMPLETE_TRANSACTION, LEDGER_BALANCE_MISMATCH, LEDGER_SEQUENCE_BREAK, HISTORICAL_RECORD_CHANGED, UNEXPLAINED_BALANCE_CHANGE, UNAPPROVED_ADJUSTMENT, INVALID_UNIT_CONVERSION, TRANSFER_ACCOUNTING, POSSIBLE_REPEAT_WITHDRAWAL |
| Integrity: never silently correct | ✅ The monitor changed no balance and no ledger record (original records preserved) |  |
| Integrity: alerts | ✅ RED status, immediate alerts, escalation to head office, permanent log | 38 open integrity alerts; head office notifications: 93 |
| Integrity: alerts | ✅ Re-running the check does not send duplicate alerts for the same unresolved issue |  |
| Integrity: investigation | ✅ Assign, investigate, correct through an approved adjustment, then resolve |  |
| Integrity: failed checks | ✅ A failing check is recorded as failed, alerts, and status becomes GREY (never GREEN) |  |
| Integrity: failed checks | ✅ No successful check (never ran / stale / missed) → GREY plus a monitoring alert |  |
| Dashboard | ✅ Management dashboard summarises the user's scope without mixing units | HO: 2 companies, 0 open transfers, integrity RED |
| Reporting | ✅ Report views return correct, permission-filtered data |  |
| Backup & restore | ✅ pg_dump backup restores into a new database that passes a full integrity check | restored 110 ledger rows, 19 balances, 76 transactions |

## 2. End-to-end suite — passed

Every screen was opened by each role and checked for page errors, console errors, failed API calls and visible error banners.

| Role (test user) | Screens opened without errors |
|---|---|
| Super Administrator | 31 — /, /admin, /alerts, /approvals, /corrections, /integrity, /integrity/[id], /receive, /reports, /scan, /setup, /setup/[id], /setup/import, /setup/labels, /setup/products, /setup/products/[id], /stock, /stock/[id], /stocktake, /stocktake/[id], /transactions/[id], /transfers, /transfers/[id], /transfers/new, /users, /withdraw |
| Head Office Management | 7 — /, /approvals, /integrity, /integrity/[id], /reports, /stock, /stocktake |
| Stock Controller | 8 — /, /alerts, /corrections, /receive, /scan, /stock, /transfers, /withdraw |
| Stocktake Counter | 3 — /, /stocktake, /stocktake/[id] |
| Auditor / Viewer | 5 — /, /admin, /integrity, /reports, /stock |
| Company Manager | 6 — /, /approvals, /reports, /setup, /stock, /users |

**Complete workflows performed through the user interface**

- ✅ withdraw TAPE-48 via scan (mobile) — *ctrl1@cswms.test*
- ✅ receive TAPE-48 via scan — *ctrl1@cswms.test*
- ✅ transfer CPT-MAIN -> PE-MAIN: dispatch (ctrl1) then receive (ctrlB) — *ctrl1@cswms.test*
- ✅ stocktake STK-2026-000002: schedule → start → count → close → submit → approve (status finalised) — *admin+ho*
- ✅ opening stock .xlsx import → approval → posted (E2E-MVOGW2ML-A balance 12.0000) — *admin+ho*
- ✅ export Excel (Current-stock-report-2026-10-26.xlsx, 8354 bytes) — *ho@cswms.test*
- ✅ export PDF (Current-stock-report-2026-10-26.pdf, 52810 bytes) — *ho@cswms.test*
- ✅ export CSV (Current-stock-report-2026-10-26.csv, 2185 bytes) — *ho@cswms.test*
- ✅ CPT-MAIN TAPE-48 balance: 62 − 1 withdrawn + 2 received − 1 transferred = 62 — *db*

## 2a. Phase 2 — database suite (27 passed)

| Area | Test | Evidence |
|---|---|---|
| Purchasing | A supervisor creates a draft purchase order; totals are computed from the lines | PO-2026-000001, R 2 500 |
| Purchasing | Invalid orders are refused: no permission, inactive product, bad numbers, duplicates, past dates | |
| Purchasing | A retried "create" (same request id) does not create a second order | |
| Purchasing | Submitting needs prices; the requester cannot approve; an authorised manager approves | |
| Purchasing | Rejection returns the order to draft with the reason; it can be corrected and resubmitted | |
| Advanced approvals | An order over R50 000 needs two levels — local approver, then head office — by different people; only the right people are offered each level | levels: any → group |
| Advanced approvals | Approval decisions are permanent (cannot be edited or deleted) | |
| Advanced approvals | Large stock adjustments also follow the rules: two levels before stock changes | |
| Advanced approvals | Only group-level administrators maintain approval rules; invalid rules are refused | |
| Purchasing | Receiving against an approved PO posts a normal receipt, updates the order and the last purchase price | |
| Purchasing | Over-receipt beyond the tolerance is refused; the rest of the order can be received | |
| Purchasing | Two people receiving the last quantity at the same moment cannot both succeed | one ok, one CS423 |
| Purchasing | Cancel only before anything is received; a partly received order is closed short with a reason | |
| Purchasing | Overdue orders raise ONE alert (repeat runs do not spam) and it clears when received | 5 managers notified |
| Purchasing | Reorder suggestions net off stock already on order and become draft POs per supplier | |
| Purchasing | Users only see purchase orders for their own warehouses | |
| Tools & equipment | Register a reusable tool: tag generated, serial numbers unique, consumables refused | AST-2026-000001 |
| Tools & equipment | Check out to an employee for a job; cannot be issued twice; retries are safe | |
| Tools & equipment | Overdue tools alert managers and remind the holder once; returning clears the alert | |
| Tools & equipment | Repair, lost / found and retirement follow allowed transitions only | |
| Tools & equipment | Verification records where a tool was actually found; movements are permanent | 8 movement types |
| Reservations | Reserved stock is held for its job (retry-safe); others cannot take it; the job reference draws it down; other regions cannot see it | |
| Notifications | Personal preferences: muted types, e-mail on/off and minimum severity respected; integrity alerts cannot be muted | |
| Notifications | Daily digest e-mail is sent once per day to people who asked for it | |
| Approvals | Requests left waiting are reminded, then escalated to head office; the reminder clears on decision | |
| Scheduler | The dispatcher runs Phase 2 housekeeping; a housekeeping failure is logged and never blocks the integrity check | |
| Integrity | Phase 2 activity keeps the ledger and balances fully consistent | integrity check clean |

## 2b. Phase 2 — end-to-end additions

| Role (test user) | Phase 2 screens opened without errors |
|---|---|
| Super Administrator | /purchasing, /purchasing/new, /purchasing/suggestions, /assets, /reservations, notification settings |
| Warehouse Supervisor | /, /purchasing, /purchasing/new, /purchasing/suggestions, /assets, /reservations, /approvals, notification settings |
| Branch Manager | /, /approvals, /purchasing, /assets, /reports |
| Stock Controller | /assets, /reservations, /withdraw |

Workflows through the user interface:

- ✅ Purchase order: created by the supervisor (scan, qty, price, supplier) → submitted → approved by the branch manager on *Approvals* → received in full against the PO → status *received*
- ✅ Tool: registered → found by scanning its tag → checked out to "Me" for a job → checked in to a shelf (3 movements recorded)
- ✅ Reservation: 2 reserved for E2E-RES-1 → on *Withdraw* the reserved-job chip fills the reference → withdrawal posted → reservation *fulfilled*
- ✅ Admin: approval rules tab; notification settings saved and stored
- ✅ Stock check: CPT-MAIN TAPE-48 = 62 − 1 withdrawn + 2 received − 1 transferred + 10 received on PO − 2 issued to reservation = **70**

## 2c. Phase 3 — database suite (15 passed)

Test data: nine products with designed demand patterns (rising, steady, slow, dead, new, ageing layers, two purchase prices, a purchase order with a known 10-day lead time) plus a job with issues, a return, a tool check-out and a reservation.

| Area | Test | Evidence |
|---|---|---|
| Movement trends | Monthly chart totals equal the ledger (issued R 4 850, returned R 20); single product in quantities | 14 monthly buckets |
| Movement trends | Without price access: line counts, no rand; stock controller refused; invalid ranges refused | |
| Fast / slow / dead | Fast, medium, slow, not-moving and dead all classified as designed; ABC (FAST = A, LEAD = C) | dead stock R 2 000 |
| Stock ageing | 80 on hand split FIFO: 20 in 0–30 d, 30 in 31–90 d, 30 in 181–365 d; dead stock > 1 year | |
| Consumption | By job: JOB-A net 43 EA = R 430 after a 2-unit return; by company = all issues − returns | |
| Job costing | Reference matched ignoring case/spaces; materials, value, transactions, tool used, open reservation | 13 transactions, R 430 |
| Valuation | Weighted average: 10 @ R10 + 10 @ R20 → R 300 today, R 100 at a date between the receipts; company = status = product totals; 12-month trend ends at today's value; refused without price access | R 11 735 |
| Forecasting | Steady 1/day, 5 free, 14-day default lead: reorder point 14, order now 39, runs out in 5 days | |
| Forecasting | Rising demand detected (next 30 days ≈ 36.8 vs average 24.8); lead time 10 days learnt from the item's purchase order | |
| Predictive alerts | One "likely to run out" alert after two runs, with the suggestion in the text; cleared when an approved order covers the gap; dispatcher includes the step | |
| Predictive alerts | Runs once a day; a failure is logged in System health and the integrity check still runs | |
| Performance | Warehouse consumption = consumption report; turnover; PO 100 % on time, 10-day lead; supplier scorecard (2 orders, 1 delivered, 100 % fill) | |
| Security | Branch manager refused another branch's forecast; stock controller and anonymous refused; supervisor sees only own warehouse; auditor sees all | |
| Read-only | Running every analytic changes no ledger row, balance or transaction | |
| Integrity | The backdated history passes a full integrity check (no mismatches, no critical findings) | |

## 2d. Phase 3 — end-to-end additions

All eight analytics tabs plus a job-costing page opened without errors by the Super Administrator, Head Office (all tabs), Auditor and Warehouse Supervisor (all tabs, no price access); the stock controller sees "no access".

- ✅ Consumption → click a job → job costing page with its materials; chart tooltip reached by keyboard (focus the chart, the crosshair and values appear); *Reports → Analytics → Fast, slow and dead stock* exported to Excel
- ✅ Supervisor without price access: no rand amount anywhere on the analytics pages; valuation explains it is restricted; stock controller refused
- ✅ Screens checked visually with 14 months of data on desktop and at phone width (390 px): axis labels, tooltips, no sideways scrolling

## 3. Mapping to the brief's testing requirements (section 18)

| Requirement | Status | Where |
|---|---|---|
| Opening stock imports | ✅ Passed | DB: Opening import (7 tests); E2E: real `.xlsx` upload → approval → posted |
| Duplicate import protection | ✅ Passed | DB: same file twice; renamed copy cannot double-load |
| Stock receiving | ✅ Passed | DB: receipts in packs/base units; E2E: scan-and-receive |
| Stock withdrawals | ✅ Passed | DB: who/where/when/why recorded; E2E: mobile scan withdrawal |
| Incorrect quantity entries | ✅ Passed | DB: zero, negative, wrong decimals, wrong location rejected; 5→50 unusual-quantity reconfirmation |
| Insufficient stock withdrawals | ✅ Passed | DB: fails and changes nothing; reserved stock protected |
| Simultaneous transactions | ✅ Passed | DB: 40 simultaneous withdrawals by two users never overdraw; no deadlocks |
| Duplicate transaction prevention | ✅ Passed | DB: idempotent retry, double-click, reused request id rejected |
| Lost internet connections | ✅ Passed (database level) | DB: connection lost before/after commit — retry is safe. UI shows "NOT CONFIRMED — retry safely" and never shows success without database confirmation |
| Interbranch transfers / stock in transit | ✅ Passed | DB: in transit not available anywhere, partial receipt, shortage write-off, intercompany; E2E: Cape Town → Gqeberha dispatch and receipt by a different user |
| Monthly physical stocktakes | ✅ Passed | DB: 6 tests (cut-off, blind, movements during count, recount, approval); E2E: full cycle |
| Approval workflows | ✅ Passed | DB: adjustments, reversals, write-offs, opening balances, stocktakes; no self-approval |
| Incorrect user permissions | ✅ Passed | DB: RLS scoping, no direct writes, anonymous denied, privilege escalation blocked, MFA (aal2) for admin roles |
| Barcode scanning | ✅ Passed | DB: product, pack, SKU and location label resolution; E2E: scanner-style input (USB/Bluetooth scanners type + Enter) |
| Low-stock notifications | ✅ Passed | DB: one alert per condition, managers notified, auto-resolves on replenishment |
| Daily automatic reconciliation | ✅ Passed | DB: clean data → GREEN |
| Deliberately introduced inconsistencies | ✅ Passed | DB: database corrupted 6 different ways in a separate test database — every one detected |
| Monitor does not change balances | ✅ Passed | DB: no balance or ledger record changed by the monitor; originals preserved |
| Failed scheduled integrity checks | ✅ Passed | DB: failed check → recorded, alerted, GREY (never GREEN); never ran / stale / missed → GREY + alert |
| Integrity alert escalation | ✅ Passed | DB: RED, immediate alerts, escalation to head office, no duplicate alerts on re-run |
| Backup restoration | ✅ Passed (locally) | DB: `pg_dump` restores into a new database that passes a full integrity check |

## 4. Outstanding — verify on staging before go-live

These depend on hosted services or physical devices that are not available in an automated sandbox. The end-to-end suite used a local stand-in for Supabase Auth (sign-in sessions are real JWTs verified by PostgREST, but e-mails and MFA codes are not sent).

| # | Check | How |
|---|---|---|
| 1 | Invitation e-mail, password reset e-mail and links | Invite a test user from *Users & Permissions*; complete the link; use *Forgot password* |
| 2 | MFA enrolment and sign-in with an authenticator app for administrators | Sign in as the first Super Administrator — the app forces enrolment |
| 3 | pg_cron runs the dispatcher every 15 minutes on Supabase | `select * from cron.job_run_details order by start_time desc limit 5;` and *Stock Integrity → Check runs* the next morning |
| 4 | Alert e-mails delivered via Resend | Set a user's e-mail alerts on, trigger a low-stock alert, check */api/cron* output and inbox |
| 5 | Phone camera scanning (Android + iPhone) and your USB/Bluetooth scanner models | Scan a printed product label and a location label on each device type |
| 6 | Label printing on your label printer | Print 62×29 mm and 100×50 mm sheets; scan them back |
| 7 | Row-level security with Supabase's real roles | Run the role checks in `docs/DEPLOYMENT.md` § 8 (log in as a branch user and confirm other branches are invisible) |
| 8 | Backup workflow and restore drill on Supabase | Run *Weekly database backup* manually; restore into a separate project; run an integrity check there |
| 10 | Daily digest and Phase 2 reminder e-mails (overdue POs, tools, approvals) | Tick *daily summary* under *Notification settings*; check the inbox the next morning |
| 11 | Purchase order PDF layout with your logo and supplier details | Open an approved order → *PDF*; check before sending to suppliers |
| 12 | Printed tool tags survive workshop use | Print a tag from a tool's page on durable label stock; scan it after a week in use |
| 13 | Analytics speed on your real data (12+ months, all warehouses) | After importing history, open *Analytics* for "All my warehouses" and "Last 365 days"; each tab should load in a few seconds. Add a nightly summary table if not |
| 14 | Forecast quality | After 2–3 months of live use, compare *Forecast & predictions* with what was actually issued; tune `analytics.service_level_z` and lead times |
| 9 | Performance with your real data volumes | Import the real opening stock into staging; time the integrity check (*Check runs* shows duration) |

## 5. Defects found and fixed during this testing round

| Defect | Impact | Fix |
|---|---|---|
| `my_context()` was declared STABLE but records the user's last-seen time (an UPDATE) | Every page load would have failed for every user | Function made VOLATILE (migration 0600); covered by every E2E page load |
| Transfer receipt confirmation disappeared when the last line was received | Users would not see that the receipt saved | Confirmation moved outside the receive panel |
| Stocktake count confirmation could disappear after a background refresh | Counter might re-enter a count | Data hooks now refresh in the background without unmounting screens |
| Raw database constraint messages shown (e.g. duplicate stocktake) | Confusing message | Friendly messages for duplicate / reference / format errors |
| PWA icon referenced by the service worker was missing | App could not be installed | Placeholder icons generated |
| Health endpoint reported "error" when the database was up | False monitoring alarms | Any non-5xx API answer counts as reachable |
| **Phase 2:** creating a reservation was not retry-safe (no request id), so the new screen's safe-retry call was rejected | A dropped connection plus retry could have reserved stock twice; the screen could not save | `create_reservation` now requires a request id and returns the original result on retry (migration 1300); covered by DB and E2E tests |
| **Phase 3:** "rising" trend label required > 5 % growth per period, so a genuine ~6 %/month rise under a damped trend showed as "steady" | Misleading trend label | Threshold set to 2 % of the level per 30-day period (projection itself unchanged) |
| **Phase 3:** chart axis end labels overlapped; charts overflowed at phone width | Unreadable dates; sideways scrolling | Collision-aware labels; charts measure their container |
| **Phase 2:** a race when two people acted on the same tool at once | Second action could replay on stale state | Per-tool advisory lock in the asset posting helper |

## How to re-run

```bash
# database suite (needs PostgreSQL 16; PGHOST defaults to /tmp)
tests/db/reset.sh && (cd tests/db && npm ci && node run-tests.mjs)
(cd tests/db && node run-phase2-tests.mjs)      # Phase 2, creates its own fresh database
(cd tests/db && node run-phase3-tests.mjs)      # Phase 3 analytics on backdated history, own fresh database

# full end-to-end run on a fresh database (needs a PostgREST binary and Playwright + Chromium)
POSTGREST_BIN=/path/to/postgrest tests/e2e/run-e2e.sh
```

Both database suites also run automatically on every push via GitHub Actions (`.github/workflows/ci.yml`).
