# CSWMS — Administrator Operating Instructions

For Super Administrators, Head Office, Company and Branch Managers and Warehouse Supervisors.

## 1. Initial setup (in this order)

1. **Organisation & settings** — *System Administration → Settings*: organisation name, working hours, approval thresholds, unusual-quantity factor, integrity run time (default 02:00), e-mail alerts.
2. **Provinces** — the nine provinces are pre-loaded; add more any time (*Company & Warehouse Setup → Provinces*).
3. **Companies** — one per legal entity that owns stock. Codes (e.g. `CSA`) cannot be changed later.
4. **Branches** — each physical site with its own code, operating company and province.
5. **Warehouses** — per branch. Each automatically gets a default receiving location.
6. **Storage locations** — storage areas → shelves → bins (choose *Inside* to nest). Print the location labels (*Print labels → Location labels*) and fix them to the shelves.
7. **Units of measure, categories, suppliers** — categories are unlimited and can have subcategories.
8. **Reason codes** — withdrawal, return, adjustment, status-change and transfer write-off reasons; mark those that require a client/job reference.
9. **Users** — *Users & Permissions → Add employee* sends an invitation e-mail. Then assign roles with the right **scope** (whole group, a company, a branch or one warehouse). Give each person only what they need.
10. **Opening stock** — see §3.

## 2. Roles

| Role | Typical person | Can |
|---|---|---|
| Super Administrator | IT / system owner | Everything. MFA required. Keep to 2 people. |
| Head Office Management | Group management | See all stock, approve, investigate integrity issues, escalations. MFA required. |
| Company Manager | Company MD / ops manager | Their company's stock and approvals, setup, users within their company. |
| Branch Manager | Branch manager | Their branch: all stock operations, approvals, stocktakes. |
| Warehouse Supervisor | Senior storeman | Warehouse operations, smaller approvals, stocktake management. |
| Stock Controller | Storeman / clerk | Receive, withdraw, return, move, transfer within permitted locations. |
| Stocktake Counter | Temporary counter | Only the counting tasks assigned to them; blind counts hide expected quantities. |
| Auditor / Viewer | Internal or external auditor | Read-only reports, stock, integrity, audit history. |

Phase 2 adds four permissions: **purchase.manage** (create/submit/receive purchase orders — supervisors and managers), **purchase.approve** (approve orders — branch/company managers and head office), **asset.manage** (register tools, repair/lost/retire, move) and **asset.checkout** (issue and return tools — stock controllers and up).

Roles are lists of permissions and can be adjusted (System roles cannot be deleted). A person can hold several roles at different scopes. The system blocks granting rights you do not hold yourself and never allows removing the last Super Administrator. **Deactivate** leavers immediately — history is kept.

## 3. Loading opening stock

1. *Company & Warehouse Setup → Opening stock import → Download template*. One row per product **per location**.
2. Fill it from your current spreadsheets: stock code, description, category, unit, quantity, warehouse code, location code, owning company (blank = the branch's company), barcode, pack unit and size, minimum/reorder quantity, supplier, price.
3. **Upload** the `.xlsx` or `.csv`. Match columns if the headings differ. The system validates every row: duplicate codes, conflicting barcodes, missing descriptions, invalid or negative quantities, unknown units/warehouses/locations, possible duplicate products, and opening balances already loaded.
4. Fix rows on screen (**Edit**) or **Exclude** them for a later batch. **Re-validate**.
5. **Submit for approval.** A *different* authorised person reviews it under **Approvals** and approves. Only then are auditable *Opening balance* transactions posted.
6. The same file can never be loaded twice. Manual entry (*Method A*) follows the same validation and approval.

Tip: load one warehouse at a time, and agree the totals per warehouse with the old records before approving.

## 4. Approvals

*Approvals → Waiting for a decision* lists everything that needs a second person: large adjustments (above the quantity, % or Rand thresholds), reversals, transfer shortage write-offs, stocktake variances and opening balances. Open the linked record, verify, then **Approve** (with a note of what you checked) or **Reject** (with reason). You cannot approve your own request. Requests above the head-office threshold must be approved by Head Office.

**Approval rules (Phase 2).** *System administration → Approval rules* sets, per request type, which levels are needed from which value. Seeded rules:

| Request type | From | Levels |
|---|---|---|
| Purchase order | R0 | any authorised approver |
| Purchase order | R50 000 | approver → head office |
| Adjustment, reversal, transfer write-off | R50 000 | approver → head office |
| Stocktake variances | R100 000 | approver → head office |

Levels are *Any authorised approver*, *Branch manager or higher*, *Company manager or higher* and *Head office*. Each level must be decided by a **different person**, and nobody may decide their own request. The approvals screen shows the chain (✓ Approver (name) → ○ Head office) and only offers *Approve* to people who can decide the current level. Rule changes apply to new requests only. Requests left waiting get a reminder after `approvals.reminder_hours` (24) and are escalated to head office after `approvals.escalate_hours` (72).

## 4a. Purchasing

1. Give each product a **default supplier** and keep last purchase prices current (*Products*). Receiving against a PO updates the last price automatically.
2. *Purchasing → Reorder suggestions* lists items at or below minimum **after** counting stock already on order. Tick, adjust quantities and *Create draft orders* — one draft per supplier.
3. Open a draft, check prices, **Submit for approval**. Approved orders: download the **PDF**, e-mail it to the supplier, then **Mark as sent**.
4. When the delivery arrives, staff open the order and **Receive delivery against this order**. More than ordered is refused (tolerance: `purchase.over_receipt_pct`, default 0%); extra stock is received separately.
5. If the supplier cannot deliver the rest, **Close short** with a reason. Orders can be **cancelled** only before anything is received.
6. Orders past their expected date plus `purchase.overdue_grace_days` raise one *Purchase order overdue* alert, which clears when received.

## 4b. Tools & equipment

1. Tick **Reusable tool / equipment** on the product (e.g. *Cordless drill 18V*).
2. *Tools & equipment → Register item* for each physical unit: serial number, where it is stored, purchase date and cost. The system gives it a tag (`AST-2026-000001`); print the tag from the item page and stick it on.
3. Staff scan the tag to **check out** (to an employee or a named contractor, with job and due-back date) and **check in** (location and condition). *Damaged* returns need a description and alert managers; damaged items cannot be issued until back from repair.
4. Overdue items alert managers and remind the holder once a day. Use **Verify location** for periodic tool audits; **Repair / lost / retire** keeps a permanent history.

## 5. Monthly stocktake

1. *Monthly Stocktake → Schedule stocktakes for <month>* — one warehouse, all warehouses in a branch or company, or the whole group. Choose a due date, optionally limit to a category, and keep **blind count** on.
2. Open each stocktake → **Counters** tab → assign people (whole warehouse or specific locations).
3. **Start counting** when counting begins — this records the **cut-off**. Movements after the cut-off are taken into account automatically; you do not need to stop work.
4. Track progress on the stocktake dashboard (completed, outstanding, % counted, discrepancies, missing/additional items, overdue).
5. **Close counting** → **Compare & discrepancies**: missing, additional, not counted, unexpected items, possibly wrong locations, duplicate entries, unusual variances.
6. Select lines and **Order recount** where needed. Exclude lines only with a documented reason.
7. **Submit for approval.** A manager who did not count approves under **Approvals**; the variances are then posted as traceable *stocktake adjustments* and the stocktake is finalised.
8. Download the stocktake and variance reports (*Reports → Stocktake*).

The daily scheduler raises a *stocktake due soon* reminder three days before a scheduled stocktake's due date and an *overdue* alert once it is late. The dashboard shows how many warehouses have no stocktake scheduled for the current month.

## 6. Stock Integrity & System Health — daily routine

The monitor runs automatically every night (default 02:00). Every morning, a responsible manager should open **Stock Integrity**:

| Status | Meaning | Action |
|---|---|---|
| **GREEN** | Last scheduled check passed; nothing unresolved | None |
| **AMBER** | Warnings (e.g. possible repeat withdrawal, overdue transfer, unusual adjustment) or open investigations | Review and close each |
| **RED** | Confirmed integrity problem (e.g. stored balance ≠ ledger, altered history, unapproved adjustment) | Assign and investigate **today** |
| **GREY** | The check failed, did not run, or is stale — integrity cannot be verified | Check *Check runs* and *System Administration → System health*; run a check manually; contact IT |

**Investigating an issue:**
1. Open the issue: product, company/location, recorded vs calculated balance, difference, related transactions, employees involved, times. The *possible cause* is labelled **not verified**.
2. **Assign** it to an investigator; add **notes** as you go.
3. If stock must be corrected: post an **adjustment** with reason *Integrity investigation outcome* and the issue number as reference; it goes through normal approval.
4. After the next check (or *Run check now*) confirms the mismatch is gone, **close** the issue as *Resolved* with the verified cause and link the correcting transaction. Mismatches that are still present cannot be closed as resolved. *Dismissed* (false positive) is reserved for integrity administrators.

The monitor **never changes stock by itself**, and it checks electronic consistency only — physical losses are found by stocktakes.

## 7. Alerts

*Low Stock & Alerts* shows one alert per unresolved condition (repeats increase the count instead of sending duplicates): low / out of stock with reorder recommendations, overdue transfers, stocktake reminders and discrepancies, unusual withdrawals, pending approvals and integrity alerts. Phase 2 adds *Purchase order overdue*, *Tool / equipment overdue* and *Approval overdue*; Phase 3 adds *Likely to run out* (predicted stock-outs). Low-stock, integrity and approval alerts close themselves when the condition is fixed.

Each person sets their own delivery under *Low Stock & Alerts → Notification settings*: e-mail on/off, minimum severity, muted alert types and an optional **daily summary e-mail** (sent once each morning at `notifications.digest_time`). Integrity alerts and critical alerts cannot be muted. E-mail requires the system setting `alerts.email_enabled`. Set minimum and reorder quantities per product per warehouse (*Products → product → Minimum and reorder quantities*).

## 8. Reports

*Reports* contains current stock, company / branch / warehouse inventory, received, withdrawn, returns, transfers, adjustments, monthly stocktake, variance, low stock, employee activity, daily integrity, integrity investigation, purchase order, outstanding order lines, asset register and tool movement reports — filter by company, warehouse, category, dates, employee and product, and export to **Excel, CSV or PDF**. Reports only include data the viewer is authorised to see.

## 8a. Analytics (Phase 3)

*Analytics* (everyone with report access; rand values only with price access) has one filter row — period, warehouse, owning company, category — that applies to every tab:

* **Overview** — stock value, dead stock, stock older than 180 days, items likely to run out, received vs consumed, month-end value, top jobs.
* **Movement trends** — received vs consumed per day, week or month; click an item on *Fast, slow & dead* to see its own trend in quantities.
* **Fast, slow & dead** — act on **dead** stock (use it up, transfer it to where it moves, or write it off through an approved adjustment) and review minimums on **A** items first.
* **Stock ageing** — what has been on the shelf longest.
* **Consumption** — by job/client, company, branch, warehouse, category, product or reason; click a job for its **job costing** page.
* **Valuation** — stock value today or at any past date (e.g. month-end for the accountant), with a 12-month trend. Items with no purchase price are listed so you can add one.
* **Forecast & predictions** — per warehouse: expected demand, when each item runs out, suggested minimum (compare with the current one) and how much to order now. Tick items and **Create draft purchase orders**.
* **Performance** — warehouse KPIs and the supplier scorecard.

Every tab exports to Excel, CSV and PDF; the same analyses are also under *Reports → Analytics*. Each morning (after 05:00) the system raises a **Likely to run out** alert for items that will run out before a reorder could arrive; it closes itself once an order covers the gap. Tune the rules under *Settings → analytics* (dead-stock days, fast/slow thresholds, default lead time, service level, prediction time, alerts on/off). Forecasts improve as purchase orders build up real lead times.

## 8b. Floor experience (Phase 4)

**Setup guide** (*Company & Warehouse Setup → Setup guide*) shows each start-up step with its status and adds three tools:
* **Create many bins at once** — prefix, aisles, bays per aisle, levels (e.g. `A1-01` … `A3-10-2`). Bins are created in a snake walking route (up one aisle, down the next) with matching label codes (`LOC-<warehouse>-<bin>`). Existing bins are skipped.
* **Counting route** — move bins up/down and **Save route**; the guided count leads counters through the bins in this order.
* **Training warehouse** — creates `TRAIN-n` with six practice bins and eight practice items. Give trainees a role on that warehouse only; a striped banner shows whenever it is selected. Exclude `TRAIN-*` warehouses from management reports.

**Cycle counting.** *Monthly Stocktake → Cycle count* creates a blind count of the items most due, by A/B/C class (A = top 80 % of 90-day usage value, counted every `cycle.a_days` = 30 days; B every 60; C every 120). Set `cycle.items_per_day` (e.g. 15) to let the system create one automatically each working day after `cycle.create_time` for every active warehouse with stock; counters are told and see it in **Today**. Cycle counts are reviewed, approved and posted exactly like a monthly stocktake and can run alongside it.

**Offline counting.** Only stocktake counts can be captured offline. Each count keeps the phone's time (never earlier than the cut-off, never in the future) and is refused if older than `counting.offline_max_hours` (72). A count made before counting was closed but arriving afterwards is accepted as **late**, the comparison is refreshed and supervisors get an information alert. Once submitted for approval no more counts are accepted.

**Quick undo.** Staff may undo their own receipt (not against a PO), withdrawal, return, move or status change within `undo.minutes` (10; 0 = off). It posts a linked reversal and an approval record marked *approved automatically — self-correction rule*, with the person's reason; the integrity monitor treats it as an approved reversal. Find them in the audit log (`SELF_UNDO`) and the adjustment report (type Reversal).

**Photos** are stored in the private Supabase Storage bucket `evidence` (created by the migration). The app server uploads and opens them only after the database has checked the user's warehouse access; links expire after 5 minutes. Up to 10 photos per record, 8 MB each; photos cannot be deleted.

**Languages.** Floor screens are available in English, Afrikaans, isiZulu and isiXhosa (*My settings*). Have a first-language speaker read the Afrikaans, isiZulu and isiXhosa wording once on site (file `src/lib/i18n.ts`) — corrections are a one-line change.

**WhatsApp alerts.** Set up the WhatsApp Cloud API (DEPLOYMENT.md § 4a), then `alerts.whatsapp_enabled = Yes`. People who add their mobile number and opt in under *My settings* receive the alerts their role already receives, at the severity they choose.

**Weekly summary.** Every Monday after 07:00 everyone whose role can run reports and receives alerts gets a plain-text e-mail: last week's receipts and withdrawals, consumption value (price viewers only), low / out / likely-to-run-out counts, waiting approvals, overdue tools, the latest integrity status and the top five jobs. Switch off with `reports.weekly_summary` (needs `alerts.email_enabled`).

**Accounting export.** *Reports → Accounting export (Xero / Sage)*: choose the company and period; CSWMS prepares a balanced daily journal at weighted-average cost (stock received, issued net of returns, moved between companies, adjustments/variances, opening balances) and downloads it as a Xero manual-journal CSV, a Sage journal CSV or Excel. Set the account codes in *Settings → accounting* with your accountant before the first import.

## 9. System administration

* **Settings** — all business rules (thresholds, working hours, integrity run time and stale limit, transfer transit days, e-mail alerts, approval reminder/escalation hours, PO over-receipt tolerance and overdue grace days, default tool loan days, digest time). Changes are audited.
* **Approval rules** — value-based approval levels (section 4).
* **System health & jobs** — scheduler, e-mail and client error events; failures are highlighted.
* **Audit history** — permanent record of setup, user/role and settings changes (cannot be edited).
* **Backups & recovery** — see `docs/BACKUP_AND_RECOVERY.md`. Perform a restore drill every quarter.

## 10. Security housekeeping

* Review users and roles monthly; deactivate leavers the same day.
* Keep at least two Super Administrators with MFA; never share accounts.
* Rotate `CRON_SECRET` and the Supabase secret key if anyone with access leaves.
* Investigate every RED integrity issue and every *Unapproved adjustment* or *Historical record changed* finding immediately — these indicate bypassed controls.
