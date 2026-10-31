# CSWMS — Staff Operating Instructions

For warehouse staff, stock controllers, counters and supervisors. Keep this guide near each scanning station.

## The five rules

1. **Use your own login.** Never share passwords or use someone else's session — every movement is recorded under your name.
2. **Scan, don't type,** whenever there is a label. Scanning picks the exact product and unit.
3. **Only "Saved" means saved.** Wait for the green **Saved — number** message. If you see **NOT CONFIRMED**, press **Retry safely** (it can never post twice). Never re-enter the transaction by hand.
4. **If the system warns that a quantity is unusual, count again.** Only confirm if you have physically checked.
5. **Never "fix" stock by doing a fake receipt or withdrawal.** Ask your supervisor for an adjustment or reversal.

## Signing in

* Go to the CSWMS web address (save it to your phone's home screen: browser menu → *Add to Home screen*).
* Sign in with your work e-mail and password. Administrators also enter the 6-digit code from their authenticator app.
* At the top of the screen, check **Working in** shows the warehouse you are standing in.
* Forgot your password? Use *Forgot password?* on the sign-in screen.

## Scanning

* **USB / Bluetooth scanner:** click (or tap) the yellow-bordered **Scan** box, then scan. The scanner types the code and presses Enter.
* **Phone / tablet camera:** tap **Camera**, allow camera access the first time, and point at the barcode or QR code.
* **No label?** Type the stock code, or search by description below the scan box.
* Scanning a **shelf / bin label** selects that location.

## Receive stock (delivery arrives)

1. **Receive Stock** (or the *Receive* button at the bottom on phones).
2. Scan each item. Scanning the same item again adds one; or type the quantity. Choose the unit (e.g. BOX of 12) if it was scanned from a pack.
3. Check the **location** where you will put it away (scan the shelf label to change it).
4. Enter the **delivery note number** (required) and the supplier.
5. **Review receipt** → check the lines → **Confirm receipt** → wait for **Saved**.

## Withdraw stock (issue materials)

1. **Withdraw Stock** → scan the item. The description, locations and available quantity appear.
2. Pick the location you are taking it from.
3. Enter the **quantity**, choose the **reason**, and enter the **client, job, department or reference** where asked.
4. Check **Balance after this withdrawal**, then **Confirm withdrawal** → **Saved**.
5. If you get *Unusually large quantity — please verify*: count again. Only tick the confirmation box if the quantity is truly correct; your manager is notified.
6. If it says *Not enough stock*, nothing was saved. Check the location or tell your supervisor — do not withdraw from a different item.

**Reserved stock:** if part of the stock is reserved for a job, a yellow box lists the jobs (e.g. *JOB-7781 · 5 EA*). If you are issuing for that job, tap it — the reference is filled in and the reservation is drawn down. Otherwise you can only take the unreserved stock.

## Reserve stock for a job

**Reservations** → scan the item → quantity, **job / client reference**, optionally a *hold until* date → **Reserve**. To issue it later, withdraw with the same reference. **Release** a reservation that is no longer needed.

## Tools & equipment (drills, grinders, testers…)

* **Check out:** **Tools** → scan the tool's tag → choose the employee (or type a contractor's name), the job and the due-back date → **Check out**.
* **Check in:** scan the tag → where you put it and its condition → **Check in**. If it is *damaged*, describe the damage — your manager is told and it cannot be issued until repaired.
* **With me** shows what you are holding. You get one reminder a day for overdue items.

## Purchase orders (supervisors)

* **Purchasing → New purchase order**, scan the items, quantities and prices, choose the supplier → **Save draft** → **Submit for approval**. Or use **Reorder suggestions** to build drafts from low stock.
* When the delivery arrives: open the order → delivery note number → enter what arrived (or tap *all*) → **Confirm receipt**. You cannot receive more than ordered.

## Return unused material

**Returns & Corrections → Return.** Scan the item, choose the original withdrawal if you know it (the system will not allow returning more than was taken), choose the location, quantity and condition:
* **Usable** goes back into available stock.
* **Damaged** is kept separately and cannot be issued.

## Move stock between shelves (same warehouse)

**Returns & Corrections → Move between locations.** Scan the item, choose *From* and *To*, quantity, confirm. Warehouse totals do not change.

## Transfers to another warehouse or branch

* **Sending:** *Transfer Stock → New transfer*. Choose the destination, scan items, choose the source location and quantity, **Dispatch transfer**. Stock is now *in transit* and cannot be used anywhere until it is received.
* **Receiving:** *Transfer Stock → Incoming*. Open the transfer, count what arrived, enter **good** and **damaged** quantities (or tap *all* if everything arrived in good condition), choose where it is put away, **Confirm receipt**.
* If items are missing, receive what arrived; the rest stays outstanding. If it will never arrive, your supervisor requests a **shortage write-off** (needs management approval).

## Stock for another company (inter-company)

If another company of the group needs stock from your warehouse, it arrives as an **inter-company order** under **Inter-company**. Once your manager has approved it, open it and press **Create transfer and dispatch** — CSWMS picks your company's stock and creates the transfer. Receiving it at the other side works like any transfer. The invoice is made automatically; you do not need to do anything for it.

## Damaged or quarantined stock

**Returns & Corrections → Damaged / quarantine.** Moves stock between *available*, *damaged* and *quarantine*. Total stock is unchanged; only available stock can be issued.

## My tasks — start here

**Today** (first button on the bottom bar) shows everything waiting for you: counts to do (with progress), tools you are holding and when they are due back, transfers to receive, approvals and messages, and anything you can still **undo**. Counters open straight into this screen.

## Counting — the guided count (recommended)

1. **Today → Start counting** (or open the stocktake → **Guided count — bin by bin**).
2. The screen shows **one bin at a time**, in the walking order set up for your warehouse. Scan the **bin label** to jump to a bin, or use the arrows.
3. **Scan each item.** Every scan adds **1**. A box/carton barcode adds the whole box (e.g. 12). You hear a beep, the phone vibrates and the screen flashes:
   * **green** — counted;
   * **yellow** (two beeps) — this item was not expected in this bin; it is counted as an extra item, that is fine;
   * **red** (low tone) — code not found. Scan again or type the product code.
4. **Many of the same item?** Tap the item in the list (or scan it once), type the quantity and press **Add** — choose the unit (each / box) if there is more than one.
5. **Bin is empty** records 0 for everything not yet counted in that bin. **Done with this bin** moves you to the next one.
6. A wrong scan that has not been sent yet can be removed with the bin icon in *waiting to send*. Once sent, ask your supervisor (or use void in the classic count screen).
7. When every bin is done you see **All bins done — thank you!** Tell your supervisor.

**No signal? Keep counting.** Counts are kept on the phone and sent automatically when the signal returns (the chip at the top shows how many are waiting). Each count is sent once, even if the phone resends it. Open the count from **Today** once while you still have signal — it then shows *Ready to count without signal*. Counts older than 72 hours can no longer be sent; anything that could not be sent is shown in red — tell your supervisor the item and quantity.

Only **counting** works offline. Receiving, issuing, transfers and corrections always need a connection.

**Classic count screen** (still available under the stocktake): choose the location, scan the item, type the quantity, **Record count**. Each entry is **added** to the item's total for that location. Enter **0** if the item is not there. Lines marked **RECOUNT** must be counted again from scratch. In a **blind count** you do not see the expected quantities.

**Cycle counts.** Instead of one big count a month, your warehouse may count a few items every working day (about 10 minutes). They appear in **Today** as *Cycle count* and only lead you to the bins where those items are.

## Oops — undo your own mistake (within 10 minutes)

Straight after a receipt, withdrawal, return, move or status change you see **Undo** with a countdown. Press it, say what was wrong (e.g. *wrong item scanned*) and press **Undo**. The stock goes back exactly as it was. The undo is recorded under your name with your reason — it is not hidden.

* Only your **own** transactions, only within the time shown (normally 10 minutes), and only once.
* Receipts against a purchase order, adjustments, transfers and stocktakes cannot be undone this way — ask your supervisor.
* Recent transactions you can still undo are also listed on **Today**.

## Photos

On a transaction (e.g. damaged stock), a tool, or a stocktake you can press **Add photo**. The phone camera opens; the photo is made smaller automatically and stored privately. Photos cannot be deleted (they are evidence) — add a corrected one if needed.

## Language, text size and sound

**My settings** (menu → your name): choose **English, Afrikaans, isiZulu or isiXhosa** for the floor screens (Today, counting, undo, bottom bar), **large text**, the scan **sound** on this phone, and **WhatsApp alerts** if your role receives alerts.

## Look up an item or shelf

*Look up* (bottom bar on phones): scan a product to see where it is and how much is free; scan a shelf label to see what should be on it.

## When something goes wrong

| Message | What to do |
|---|---|
| **NOT CONFIRMED — check before re-entering** | Press **Retry safely**. If it keeps failing, write down what you were doing and tell your supervisor. Do not re-enter it. |
| **Offline** (red bar) | Receiving, issuing and other transactions wait for the connection — nothing is saved offline. **Counting continues** and sends itself later. |
| **Not enough stock — nothing was saved** | Check the location and item. Tell your supervisor if the shelf has stock the system doesn't show. |
| **Not permitted** | You do not have rights for this warehouse/action. Check *Working in*, or ask your manager. |
| **No product or location found** | The label is not registered. Search by description; tell your supervisor to add the barcode. |
