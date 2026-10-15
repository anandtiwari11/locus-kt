# Playbook: Repayment Processing Investigation

> Step-by-step debugging procedure for investigating repayment processing issues — from collection/deposit creation through lender sync, payment creation, ledger updates, and demand sheet reconciliation.
> All queries are **read-only** (`SELECT` only) and accept `{user_id}` (`source_identifier_id` / `partner_id`) as input.

**Cross-references**:
- Flow: [`02-user-flows/repayment-workflow.md`](../02-user-flows/repayment-workflow.md)
- Decision Logic: [`04-decision-logic.md`](../04-decision-logic.md)
- Celery Workflows: [`05-celery-workflows.md`](../05-celery-workflows.md) — Repayment Sync
- Runtime Data: [`03-runtime-data.md`](../03-runtime-data.md)

---

## Common Hypotheses

| # | Hypothesis | Summary | Jump To |
|---|-----------|---------|---------|
| H1 | Repayment not applied to loan | Payment created but loan status not updated; reconciliation not triggered | [Step 5](#step-5-check-payment-to-loan-reconciliation) |
| H2 | Transaction mismatch (amount discrepancy) | Payment amount at lender differs from local `Payment` or `LedgerEntry` amount | [Step 4](#step-4-cross-reference-payments-with-ledger-entries) |
| H3 | Ledger entry missing | `Payment` record exists but no corresponding `LedgerEntry` with `type=PAYMENT` | [Step 4](#step-4-cross-reference-payments-with-ledger-entries) |
| H4 | Demand sheet discrepancy | Demand sheet amounts don't match actual repayment/outstanding figures | [Step 6](#step-6-verify-demand-sheet-data) |
| H5 | Payment sync failure from Saraloan | `fetch_and_update_repayments_info` or `process_repayment_data` failed | [Step 7](#step-7-investigate-payment-sync-failures) |
| H6 | Repayment stuck in processing | Transaction created but deposit/collection chain incomplete or webhook not received | [Step 8](#step-8-investigate-stuck-repayment-transactions) |

---

## Payment Status Reference

Valid payment statuses and transitions (from `payment/model/payment.py` and `payment/utils.py`):

| Source Status | Target Status | Trigger | Notes |
|--------------|--------------|---------|-------|
| — | `POSTED` | `process_repayment_data()` (event: `repayment_done`) | New payment from lender confirmation |
| — | `UNREALIZED` | `process_repayment_data()` (PG mode) | PG payment pending realization |
| `UNREALIZED` | `POSTED` | `validate_and_create_or_update_payment()` | Payment realized; ledger date updated to `settlement_date` |
| `POSTED` | `CANCELLED` | `validate_and_create_or_update_payment()` | Full refund (`payment_amount == refund_amount`) |
| Any | `BOUNCED` | `validate_and_create_or_update_payment()` (event: `repayment_bounced`) | Ledger entry cancelled (`active=False`, `visible=False`) |
| Any | `MOVED_TO_LENDER` | `map_payment_to_loan_on_transfer()` signal | Payment transferred to lender |

---

## Step 1: Verify Customer and Credit Line Exist

**Goal**: Confirm the customer exists and has an active credit line before investigating repayment issues.

**ORM**:
```python
from credit_line.model import Customer, CustomerCreditLine

customer = Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'source_identifier_id', 'name',
    'is_credit_allowed', 'external_lender_supported',
    'customer_type__name'
).first()

credit_lines = CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'sub_status',
    'credit_limit', 'operational_limit',
    'available_credit_limit', 'lender_available_credit_limit',
    'credit_product__credit_product_name',
    'credit_product__belongs_to_gapl',
    'created_at', 'updated_at'
)
```

**SQL**:
```sql
SELECT c.id, c.source_identifier_id, c.name,
       c.is_credit_allowed, c.external_lender_supported,
       ct.name AS customer_type
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';

SELECT ccl.id, ccl.status, ccl.sub_status,
       ccl.credit_limit, ccl.operational_limit,
       ccl.available_credit_limit, ccl.lender_available_credit_limit,
       cp.credit_product_name, cp.belongs_to_gapl,
       ccl.created_at, ccl.updated_at
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Unique index on `credit_line_customer.source_identifier_id`. Expected < 10ms each.

**What to Check**:
- Does the customer exist?
- Is `customer_type` = `DC` or `FARMER`? (Determines credit product: `ME_BLACKSOIL` vs `FARMER_BLACKSOIL`)
- Is `external_lender_supported = True`? (Required for DC repayment sync)
- Does at least one credit line exist with `status = ACTIVE`?

**Decision**:
- **Customer not found** → No repayments possible. Investigate onboarding.
- **No active credit lines** → See [`credit-eligibility-playbook.md`](credit-eligibility-playbook.md) Step 3.
- **DC with `external_lender_supported = False`** → `process_repayment_data()` returns `False` for DCs without external lender support (`payment/tasks.py:868`). Repayment webhooks are silently dropped.
- **Customer and credit lines exist** → Proceed to [Step 2](#step-2-retrieve-repayment-transactions).

---

## Step 2: Retrieve Repayment Transactions

**Goal**: Get all repayment transactions (collections and deposits) for the user to identify the problematic transaction(s).

**ORM**:
```python
from repayment.models import Transaction

Transaction.objects.filter(
    payer='{user_id}',
    payer_type='FARMER',
    active=True
).values(
    'id', 'transaction_id', 'transaction_type', 'transaction_channel',
    'amount', 'payee', 'payee_type', 'payment_id',
    'related_transaction_id', 'related_collection_id',
    'secondary', 'meta', 'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT id, transaction_id, transaction_type, transaction_channel,
       amount, payee, payee_type, payment_id,
       related_transaction_id, related_collection_id,
       secondary, meta, created_at, updated_at
FROM repayment_transaction
WHERE payer = '{user_id}'
  AND payer_type = 'FARMER'
  AND active = true
ORDER BY created_at DESC;
```

**Performance**: Uses index on `repayment_transaction(transaction_type, active)`. Expected < 50ms.

**What to Check**:
- Are there `Collection` records for the user? Collections are created when a farmer pays to a GL/FSFE.
- Are there `Deposit` records? Deposits are created when GL/FSFE deposits collected cash.
- Is `related_transaction_id` populated on collections? This links a collection to its deposit.
- Is `payment_id` populated? This links a transaction to a `Payment` record (set by signal `handle_payment_to_vpa_transactions_mapping` or `handle_payment_to_transactions_mapping`).
- Check `transaction_channel`: `Cash`, `VPA`, `PG`, `CSC`, `Bank`, `UPIAutoPay`, `CMS`.
- Check `secondary` flag: `True` means this is a secondary FSFE collection entry created by `__handle_deposit_to_fsfe()`.

**Decision**:
- **No transactions found** → No repayment activity recorded. If user claims they paid, check if the payment came via lender sync (webhook/cron). Go to [Step 3](#step-3-retrieve-lender-payments).
- **Collections exist but no deposits** → Cash collected but not deposited. The collection→deposit chain is incomplete. Go to [Step 8](#step-8-investigate-stuck-repayment-transactions).
- **Transactions exist with `payment_id = NULL`** → Transaction not linked to a `Payment` record. The signal mapping may have failed. Go to [Step 8](#step-8-investigate-stuck-repayment-transactions).
- **Transactions exist with `payment_id` populated** → Proceed to [Step 3](#step-3-retrieve-lender-payments) to verify the payment record.
- **Inactive transactions (`active = False`) found** → Transactions were corrected or cancelled. Query with `active=False` to see correction history in `meta` field (look for `old_recorded_amount` entries).

---

## Step 3: Retrieve Lender Payments

**Goal**: Get all `Payment` records synced from the lender (Saraloan) for this user's credit line. These represent the lender's view of repayments.

**ORM**:
```python
from payment.model import Payment

Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'lender_payment_id', 'lender_payment_ref_number',
    'payment_amount', 'payment_amount_settled', 'advance_amount',
    'reconcilable_amount', 'transfer_to_lender_amount',
    'payment_date', 'settlement_date', 'payment_mode',
    'status', 'sub_status',
    'interest', 'principal', 'penal_interest', 'overdue_interest',
    'refund_amount', 'refund_utr',
    'payment_transfer_number', 'parent_payment_id',
    'la_entry_created', 'la_entry_status',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT p.id, p.lender_payment_id, p.lender_payment_ref_number,
       p.payment_amount, p.payment_amount_settled, p.advance_amount,
       p.reconcilable_amount, p.transfer_to_lender_amount,
       p.payment_date, p.settlement_date, p.payment_mode,
       p.status, p.sub_status,
       p.interest, p.principal, p.penal_interest, p.overdue_interest,
       p.refund_amount, p.refund_utr,
       p.payment_transfer_number, p.parent_payment_id,
       p.la_entry_created, p.la_entry_status,
       p.created_at, p.updated_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY p.created_at DESC;
```

**Performance**: Uses index on `payment_payment(customer_credit_line_id)`. Expected < 50ms.

**What to Check**:
- `status`: Is the payment `POSTED`, `UNREALIZED`, `CANCELLED`, `BOUNCED`, or `MOVED_TO_LENDER`?
- `payment_amount` vs `payment_amount_settled`: Do they match? A mismatch may indicate partial settlement.
- `refund_amount > 0`: Was a refund issued? If `refund_amount == payment_amount`, the payment was fully refunded and status should be `CANCELLED` with `sub_status = REFUNDED`.
- `settlement_date`: Is it populated? For `UNREALIZED` → `POSTED` transitions, the ledger date updates to `settlement_date`.
- `parent_payment_id`: If set, this is a child payment (split from a parent). Check the parent payment too.
- `lender_payment_id`: Starts with `SLR` for Saraloan payments. Used for deduplication via unique constraint `(customer_credit_line, lender_payment_ref_number, lender_payment_id)`.

**Decision**:
- **No payments found** → Lender has not synced any repayments. Go to [Step 7](#step-7-investigate-payment-sync-failures) to check sync task execution.
- **Payment in `UNREALIZED`** → Payment received via PG but not yet realized. Check if `settlement_date` is set. If the payment has been `UNREALIZED` for too long, the realization webhook may not have arrived.
- **Payment in `BOUNCED`** → Repayment was bounced by lender. Ledger entry should be cancelled. Go to [Step 4](#step-4-cross-reference-payments-with-ledger-entries) to verify.
- **Payment in `CANCELLED` with `sub_status = REFUNDED`** → Full refund processed. Verify `refund_amount == payment_amount`.
- **Payment in `POSTED`** → Normal state. Proceed to [Step 4](#step-4-cross-reference-payments-with-ledger-entries) to verify ledger entry.
- **Amount discrepancy suspected** → Compare `payment_amount` with the lender's records. Go to [Step 4](#step-4-cross-reference-payments-with-ledger-entries).

---

## Step 4: Cross-Reference Payments with Ledger Entries

**Goal**: Verify that every `Payment` record has a corresponding `LedgerEntry` with matching amount. Detect missing ledger entries (H3) and amount discrepancies (H2).

**ORM**:
```python
from payment.model import Payment
from ledger.model.ledger_entry import LedgerEntry

# Get all payments and their corresponding ledger entries
payments = Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values_list('id', 'payment_amount', 'status', 'settlement_date', 'lender_payment_id')

for pid, amt, st, sd, lpid in payments:
    entry = LedgerEntry.objects.filter(locus_id=str(pid), type='PAYMENT').first()
    if not entry:
        print(f"MISSING LEDGER: Payment {pid} lender_id={lpid} amount={amt} status={st}")
    elif entry.amount != amt:
        print(f"AMOUNT MISMATCH: Payment {pid} pay_amt={amt} ledger_amt={entry.amount}")
    elif not entry.active:
        print(f"INACTIVE LEDGER: Payment {pid} ledger_id={entry.id} active=False visible={entry.visible}")
```

**SQL**:
```sql
SELECT p.id AS payment_id, p.lender_payment_id,
       p.payment_amount, p.status AS payment_status,
       p.settlement_date, p.refund_amount,
       le.id AS ledger_id, le.amount AS ledger_amount,
       le.date AS ledger_date,
       le.active AS ledger_active, le.visible AS ledger_visible,
       le.unrealized_payment, le.belongs_to_gapl,
       le.source_no
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
LEFT JOIN ledger_ledgerentry le ON le.locus_id = CAST(p.id AS TEXT) AND le.type = 'PAYMENT'
WHERE c.source_identifier_id = '{user_id}'
ORDER BY p.created_at DESC;
```

**Performance**: Uses indexes on `payment_payment(customer_credit_line_id)` and `ledger_ledgerentry(type, locus_id)` (unique constraint). Expected < 50ms.

**What to Check**:
- **`ledger_id IS NULL`**: Payment exists but no ledger entry → **H3 confirmed**. The `create_or_update_ledger_entry()` call in `payment/utils.py:631` failed or was never reached.
- **`payment_amount ≠ ledger_amount`**: → **H2 confirmed**. Amount mismatch between payment and ledger.
- **`ledger_active = False`**: Ledger entry was cancelled (e.g., bounced payment via `cancel_ledger_entry()`).
- **`ledger_visible = False`**: Entry hidden — could be a GAPL payment that was moved to lender (`belongs_to_gapl = True`).
- **`unrealized_payment = True`**: Payment is still unrealized (PG mode). Ledger date will update to `settlement_date` when realized.
- **`source_no`**: Should match `lender_payment_id` on the payment. If different, the ledger entry may be linked to the wrong payment.

**Decision**:
- **Missing ledger entry (H3)** → Check Celery task logs for `process_repayment_data` or `fetch_and_update_repayments_info` errors. The `create_or_update_ledger_entry()` function may have thrown an exception. Go to [Step 7](#step-7-investigate-payment-sync-failures).
- **Amount mismatch (H2)** → Check if the payment was updated after ledger creation. The `validate_and_create_or_update_payment()` function (`payment/utils.py:437`) updates the ledger entry when amount changes, but only if the new amount differs. Check `Payment.updated_at` vs `LedgerEntry.updated_at` timestamps.
- **Bounced payment with active ledger** → The `cancel_ledger_entry()` call (`payment/utils.py:472`) may have failed. It sets `active=False` and `visible=False` on the ledger entry when `repayment_bounced` event is received with a newer `lender_updated_at`.
- **All payments have matching ledger entries** → Ledger is consistent. If the issue is about loan status, go to [Step 5](#step-5-check-payment-to-loan-reconciliation). If about demand sheet, go to [Step 6](#step-6-verify-demand-sheet-data).

---

## Step 5: Check Payment-to-Loan Reconciliation

**Goal**: Verify that payments have been reconciled against loans. Reconciliation maps `Payment` records to `Loan` records and updates loan statuses (e.g., `DISBURSED` → `PARTIALLY_PAID` → `PAID`). This addresses **H1: Repayment not applied to loan**.

> Reconciliation logic: `loan/utility.py:run_reconciliation_for_customer_main()` and `run_reconciliation_for_customer()`.
> Triggered by: `loan/tasks.py:check_and_run_reconciliation_for_all_customers()` (daily cron at 04:00) and `fire_loan_reconciliation_event()`.

### Step 5a: Check Loan Statuses

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'loan_id', 'status', 'loan_amount',
    'disbursed_amount', 'remaining_amount',
    'customer_credit_line__credit_product__credit_product_name',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.disbursed_amount, ll.remaining_amount,
       cp.credit_product_name,
       ll.created_at, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY ll.created_at DESC;
```

**Performance**: Index on `loan_loan(customer_credit_line_id)`. Expected < 50ms.

### Step 5b: Check Payment-Loan Mapping

**ORM**:
```python
from loan.model import Loan
from payment.model import Payment

# Check if payments are mapped to loans via PaymentLoanMap
from loan.models import PaymentLoanMap

PaymentLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'payment__id', 'payment__payment_amount', 'payment__status',
    'loan__loan_id', 'loan__status', 'loan__loan_amount',
    'amount', 'created_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT plm.id, plm.amount,
       p.id AS payment_id, p.payment_amount, p.status AS payment_status,
       ll.loan_id, ll.status AS loan_status, ll.loan_amount,
       plm.created_at
FROM loan_paymentloanmap plm
JOIN payment_payment p ON plm.payment_id = p.id
JOIN loan_loan ll ON plm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY plm.created_at DESC;
```

**Performance**: Expected < 50ms with join indexes.

### Step 5c: Check Reconciliation Task Execution

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'loan.tasks.check_and_run_reconciliation_for_all_customers',
        'loan.tasks.run_reconciliation_for_customers',
        'loan.tasks.fire_loan_reconciliation_event',
    ],
    task_args__contains='{user_id}'
).values(
    'task_name', 'status', 'result', 'traceback',
    'date_created', 'date_done'
).order_by('-date_done')[:20]
```

**SQL**:
```sql
SELECT task_name, status, result, traceback,
       date_created, date_done
FROM django_celery_results_taskresult
WHERE task_name IN (
    'loan.tasks.check_and_run_reconciliation_for_all_customers',
    'loan.tasks.run_reconciliation_for_customers',
    'loan.tasks.fire_loan_reconciliation_event'
)
AND task_args LIKE '%{user_id}%'
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: Index on `django_celery_results_taskresult(task_name)`. Expected < 100ms. **Warning**: `task_args LIKE` may be slow; always include date filter.

**What to Check**:
- Are loans still in `DISBURSED` despite payments existing? → Reconciliation hasn't run or failed.
- Does `PaymentLoanMap` have entries? If empty, reconciliation never mapped payments to loans.
- Is `remaining_amount` on loans being updated? Reconciliation updates this field.
- Check `is_reconciliation_restricted(partner_id)` — a Redis-based flag in `loan/utility.py:400` that can block reconciliation for all partners.
- Check if `RESTRICT_RECONCILIATION_FOR_ALL_PARTNERS` app constant is set to `"true"` (blocks all reconciliation).

**Decision**:
- **Loans in `DISBURSED` with payments present but no `PaymentLoanMap` entries** → **H1 confirmed**. Reconciliation hasn't run. Check if the daily cron ran (`check_and_run_reconciliation_for_all_customers`). Check if reconciliation is restricted via Redis or app constant.
- **Reconciliation task `FAILURE`** → Check traceback. Common issues: Redis lock contention (`check_or_add_redis_cache_for_reconciliation`), database errors during atomic transaction.
- **`PaymentLoanMap` entries exist but loan status unchanged** → The reconciliation ran but the FSM transition may have failed. See [`loan-lifecycle-playbook.md`](loan-lifecycle-playbook.md) Step 8 for FSM diagnosis.
- **Payments are `MOVED_TO_LENDER`** → These payments were transferred to the lender and are no longer reconcilable locally. This is expected for BlackSoil ME payments with `SLR` prefix.
- **All looks correct** → Reconciliation is working. If the issue is about demand sheet figures, go to [Step 6](#step-6-verify-demand-sheet-data).

---

## Step 6: Verify Demand Sheet Data

**Goal**: Check demand sheet records for the user and verify they align with actual repayment and outstanding figures. This addresses **H4: Demand sheet discrepancy**.

> Demand sheets are uploaded via `repayment/tasks.py:insert_demand_sheet_details()` and updated via `update_previous_demand_details()`. They represent the lender's view of EMI demands.

**ORM**:
```python
from repayment.models import DemandSheet

DemandSheet.objects.filter(
    user_id='{user_id}'
).values(
    'id', 'from_date', 'to_date', 'due_date', 'dpd', 'dpd_days',
    'sanctioned_limit_amount', 'disbursement_amount',
    'repaid_amount', 'advance_paid_amount',
    'outstanding_amount', 'cumulative_emi_amount',
    'principal_repayment_amount', 'interest_repayment_amount',
    'processing_fee_repayment_amount', 'overdue_amount',
    'late_fee_amount', 'net_demand_amount',
    'active', 'created_at', 'updated_at'
).order_by('-to_date')
```

**SQL**:
```sql
SELECT id, from_date, to_date, due_date, dpd, dpd_days,
       sanctioned_limit_amount, disbursement_amount,
       repaid_amount, advance_paid_amount,
       outstanding_amount, cumulative_emi_amount,
       principal_repayment_amount, interest_repayment_amount,
       processing_fee_repayment_amount, overdue_amount,
       late_fee_amount, net_demand_amount,
       active, created_at, updated_at
FROM repayment_demandsheet
WHERE user_id = '{user_id}'
ORDER BY to_date DESC;
```

**Performance**: Uses index on `repayment_demandsheet(user_id)`. Expected < 30ms.

**What to Check**:
- Is there a current demand sheet (`from_date <= today <= to_date`)?
- `net_demand_amount`: The total EMI demand for the period. Compare with actual payments received.
- `outstanding_amount`: Should decrease as repayments are made. Compare with credit line `available_credit_limit`.
- `repaid_amount`: Total repaid. Cross-reference with sum of `Payment.payment_amount` for the period.
- `overdue_amount`: If non-zero, the user has overdue payments.
- `dpd_days`: Days past due. If high, check if overdue notifications were sent.
- `active`: Inactive demand sheets were superseded by updates.

### Step 6a: Cross-Reference Demand with Actual Payments

**SQL**:
```sql
-- Compare demand sheet repaid_amount with actual payment sum
SELECT ds.id AS demand_id, ds.from_date, ds.to_date,
       ds.repaid_amount AS demand_repaid,
       ds.outstanding_amount AS demand_outstanding,
       ds.net_demand_amount,
       COALESCE(SUM(p.payment_amount), 0) AS actual_payment_sum,
       ds.repaid_amount - COALESCE(SUM(p.payment_amount), 0) AS discrepancy
FROM repayment_demandsheet ds
LEFT JOIN credit_line_customer c ON c.source_identifier_id = CAST(ds.user_id AS TEXT)
LEFT JOIN credit_line_customercreditline ccl ON ccl.customer_id = c.id
LEFT JOIN payment_payment p ON p.customer_credit_line_id = ccl.id
    AND p.status = 'POSTED'
    AND p.payment_date BETWEEN ds.from_date AND ds.to_date
WHERE ds.user_id = '{user_id}'
GROUP BY ds.id, ds.from_date, ds.to_date, ds.repaid_amount,
         ds.outstanding_amount, ds.net_demand_amount
ORDER BY ds.to_date DESC;
```

**Performance**: Expected < 100ms. **Warning**: Cross-table join with aggregation; use date filters to limit scope.

**Decision**:
- **No demand sheet found** → Demand sheet was never uploaded for this user. Check if the bulk upload task ran (`insert_demand_sheet_details`).
- **`net_demand_amount` is 0 but user has outstanding loans** → **H4 confirmed**. Demand sheet data is stale or incorrect. Check when the demand sheet was last updated (`updated_at`).
- **`discrepancy ≠ 0`** → **H4 confirmed**. The demand sheet's `repaid_amount` doesn't match actual payments in the period. This can happen if: (a) demand sheet was uploaded before payments were synced, (b) payments were bounced/refunded after demand sheet upload, (c) demand sheet was manually updated with incorrect data.
- **`overdue_amount > 0` but user has paid** → Check if the payment was applied after the demand sheet was generated. Demand sheets are point-in-time snapshots and may not reflect real-time payment status.
- **Demand sheet looks correct** → Issue may be elsewhere. Go to [Step 7](#step-7-investigate-payment-sync-failures) if sync is suspected, or [Step 8](#step-8-investigate-stuck-repayment-transactions) if transactions are stuck.

---

## Step 7: Investigate Payment Sync Failures

**Goal**: Determine why repayment data from Saraloan was not synced or processed. This addresses **H5: Payment sync failure from Saraloan**.

> Two sync paths exist:
> 1. **Cron sync**: `payment/tasks.py:sync_repayment_info_for_all_dc()` (daily 19:30) → `fetch_and_update_repayments_info()` → `process_records()` → `validate_and_create_or_update_payment()`
> 2. **Webhook sync**: `external/views.py:SaraloanWebhookView.post()` → `payment/tasks.py:process_saraloan_repayment_webhook()` → `process_repayment_data()`

### Step 7a: Check Celery Task Results for Sync Tasks

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'payment.tasks.sync_repayment_info_for_all_dc',
        'payment.tasks.fetch_and_update_repayments_info',
        'payment.tasks.process_repayment_data',
    ],
    task_args__contains='{user_id}'
).values(
    'task_id', 'task_name', 'status', 'result', 'traceback',
    'date_created', 'date_done'
).order_by('-date_done')[:20]
```

**SQL**:
```sql
SELECT task_id, task_name, status, result, traceback,
       date_created, date_done
FROM django_celery_results_taskresult
WHERE task_name IN (
    'payment.tasks.sync_repayment_info_for_all_dc',
    'payment.tasks.fetch_and_update_repayments_info',
    'payment.tasks.process_repayment_data'
)
AND task_args LIKE '%{user_id}%'
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: Index on `django_celery_results_taskresult(task_name)`. Expected < 100ms. **Warning**: `task_args LIKE` may be slow on large tables; always include date filter.

### Step 7b: Check CustomerLenderMap (Required for Cron Sync)

**ORM**:
```python
from credit_line.model.customer_lender_map import CustomerLenderMap

CustomerLenderMap.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'customer__source_identifier_id',
    'credit_product__credit_product_name',
    'business_id', 'loan_account_id', 'application_id',
    'created_at', 'updated_at'
)
```

**SQL**:
```sql
SELECT clm.id, c.source_identifier_id,
       cp.credit_product_name,
       clm.business_id, clm.loan_account_id, clm.application_id,
       clm.created_at, clm.updated_at
FROM credit_line_customerlendermap clm
JOIN credit_line_customer c ON clm.customer_id = c.id
JOIN credit_line_creditproduct cp ON clm.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Expected < 10ms.

### Step 7c: Check Webhook Events

**ORM**:
```python
from external.models import ExternalWebhook

ExternalWebhook.objects.filter(
    data__identifiers__partner_lead_id='{user_id}',
    event__in=['repayment_done', 'repayment_captured', 'repayment_bounced']
).values(
    'id', 'event', 'data', 'created_at'
).order_by('-created_at')[:20]
```

**SQL**:
```sql
SELECT id, event, data, created_at
FROM external_externalwebhook
WHERE data::jsonb -> 'identifiers' ->> 'partner_lead_id' = '{user_id}'
  AND event IN ('repayment_done', 'repayment_captured', 'repayment_bounced')
  AND created_at >= NOW() - INTERVAL '7 days'
ORDER BY created_at DESC
LIMIT 20;
```

**Performance**: **Warning** — JSON field query without dedicated index. May be slow on large tables. Always include date range filter.

**What to Check**:
- **Cron sync path**: Did `sync_repayment_info_for_all_dc` run? Did it dispatch `fetch_and_update_repayments_info` for this user's credit line?
- **`CustomerLenderMap.loan_account_id`**: Must be populated for the cron sync to work. If `NULL`, the sync skips this user (`payment/tasks.py:637`).
- **`CustomerLenderMap.business_id`**: Must be populated. If missing, `sync_partner_ids_from_saraloan()` is called to fetch it, which may fail.
- **Webhook path**: Were any repayment webhooks received for this user? Check `external_externalwebhook` table.
- **Task status**: `FAILURE` → check `traceback`. Common errors:
  - `PAYMENT_SYNC_FAILURE_EVENT` email sent → exception in `fetch_and_update_repayments_info()` (`payment/tasks.py:745`)
  - `REPAYMENT_WEBHOOK_FAILURE_EVENT` email sent → exception in `process_repayment_data()` (`payment/tasks.py:929`)
  - Interest discrepancy → `fetch_account_detail_and_validate_interest_component()` returned discrepancy, processing stopped.

**Decision**:
- **`loan_account_id` is NULL** → **H5 confirmed**. Cron sync cannot run without a loan account ID. The `sync_partner_ids_from_saraloan()` fallback also failed. Check Saraloan onboarding for this customer.
- **Sync task `FAILURE` with traceback** → **H5 confirmed**. Read the traceback to identify the root cause. Common: Saraloan API timeout, serialization error, database constraint violation.
- **Sync task `SUCCESS` but no payments created** → The Saraloan API returned empty results, or all payments already existed (deduplication via `lender_payment_id` unique constraint).
- **No webhook events found** → Lender hasn't sent a repayment notification. If the user claims they paid, the payment may not have been processed at the lender yet.
- **Webhook received but task `FAILURE`** → The `process_repayment_data` task failed. Check if it was retried (task has `autoretry_for=(Exception,)`, `max_retries=3`, `retry_backoff=180`). If all retries exhausted, manual intervention needed.
- **Interest discrepancy blocked processing** → `fetch_account_detail_and_validate_interest_component()` detected a mismatch between local and Saraloan interest data. The function returns early without creating the payment. This is a safety check — investigate the interest data.

---

## Step 8: Investigate Stuck Repayment Transactions

**Goal**: Diagnose why a repayment transaction is stuck — collection not linked to deposit, deposit not processed, or VPA/PG payment not mapped. This addresses **H6: Repayment stuck in processing**.

### Step 8a: Check Collection-to-Deposit Chain

**ORM**:
```python
from repayment.models import Transaction

# Find collections without deposits (related_transaction_id is NULL)
orphan_collections = Transaction.objects.filter(
    payer='{user_id}',
    payer_type='FARMER',
    transaction_type='Collection',
    active=True,
    related_transaction_id__isnull=True
).values(
    'id', 'transaction_id', 'amount', 'payee', 'payee_type',
    'transaction_channel', 'created_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT id, transaction_id, amount, payee, payee_type,
       transaction_channel, created_at
FROM repayment_transaction
WHERE payer = '{user_id}'
  AND payer_type = 'FARMER'
  AND transaction_type = 'Collection'
  AND active = true
  AND related_transaction_id IS NULL
ORDER BY created_at DESC;
```

**Performance**: Uses index on `repayment_transaction(transaction_type, active)`. Expected < 50ms.

### Step 8b: Check Aggregated Deposits

**ORM**:
```python
from repayment.models import AggregatedTransactionDepositMapping, Transaction

deposit_txns = Transaction.objects.filter(
    payer='{user_id}',
    transaction_type='Deposit',
    active=True
).values_list('id', flat=True)

AggregatedTransactionDepositMapping.objects.filter(
    transaction_id__in=deposit_txns
).select_related('aggregated_deposit', 'transaction').values(
    'aggregated_deposit__id', 'aggregated_deposit__aggregated_amount',
    'aggregated_deposit__ref_num', 'aggregated_deposit__created_at',
    'transaction__id', 'transaction__amount',
    'transaction__transaction_channel', 'transaction__created_at'
)
```

**SQL**:
```sql
SELECT ad.id AS agg_deposit_id, ad.aggregated_amount, ad.ref_num,
       ad.created_at AS agg_created_at,
       t.id AS txn_id, t.amount, t.transaction_channel,
       t.created_at AS txn_created_at
FROM repayment_aggregated_transaction_deposit_mapping atdm
JOIN repayment_aggregated_deposit ad ON atdm.aggregated_deposit_id = ad.id
JOIN repayment_transaction t ON atdm.transaction_id = t.id
WHERE t.payer = '{user_id}'
  AND t.transaction_type = 'Deposit'
  AND t.active = true
ORDER BY ad.created_at DESC;
```

**Performance**: Uses index on `repayment_transaction(transaction_type, active)`. Expected < 50ms.

### Step 8c: Check Virtual Account Info (VPA Payments)

**ORM**:
```python
from repayment.models import CustomerVirtualAccount

CustomerVirtualAccount.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'virtual_account_number', 'virtual_account_bank_name',
    'virtual_account_ifsc_code', 'virtual_account_upi_id',
    'lender_customer_id',
    'credit_product__credit_product_name',
    'created_at', 'updated_at'
)
```

**SQL**:
```sql
SELECT cva.id, cva.virtual_account_number, cva.virtual_account_bank_name,
       cva.virtual_account_ifsc_code, cva.virtual_account_upi_id,
       cva.lender_customer_id,
       cp.credit_product_name,
       cva.created_at, cva.updated_at
FROM repayment_customervirtualaccount cva
JOIN credit_line_customer c ON cva.customer_id = c.id
JOIN credit_line_creditproduct cp ON cva.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Uses unique constraint on `(customer_id, credit_product_id)`. Expected < 10ms.

### Step 8d: Check Transaction Reference Info (PG/UPI Payments)

**ORM**:
```python
from payment.model.payment import TransactionReferenceInfo, TransactionReferenceGroupInfo

# Check transaction references for the user
TransactionReferenceGroupInfo.objects.filter(
    entity_id='{user_id}'
).values(
    'id', 'entity_id', 'entity_type', 'status',
    'total_amount', 'meta', 'created_at', 'updated_at'
).order_by('-created_at')[:20]
```

**SQL**:
```sql
SELECT id, entity_id, entity_type, status,
       total_amount, meta, created_at, updated_at
FROM payment_transactionreferencegroupinfo
WHERE entity_id = '{user_id}'
ORDER BY created_at DESC
LIMIT 20;
```

**Performance**: Expected < 50ms.

**What to Check**:
- **Orphan collections** (Step 8a): Collections with `related_transaction_id = NULL` have not been linked to a deposit. The GL/FSFE hasn't deposited the collected cash yet.
- **Aggregated deposits** (Step 8b): For group deposits, check if the `AggregatedDeposit` was created and all transactions are mapped.
- **Virtual account** (Step 8c): For VPA payments, verify the virtual account exists. If missing, `update_virtual_account_details()` task may have failed.
- **Transaction references** (Step 8d): For PG/UPI payments, check `TransactionReferenceGroupInfo.status`:
  - `Draft` → Payment initiated but not completed. If stale (> 1 day), `update_failure_for_stale_transaction_references()` should mark it as `PSP_FAILURE`.
  - `Success` → Payment completed. Check if the deposit transaction was created.
  - `PSP_FAILURE` → Payment service provider reported failure.

**Decision**:
- **Orphan collections found** → **H6 confirmed** (variant). Cash was collected from the farmer but the GL/FSFE hasn't deposited it yet. This is an operational issue, not a system bug.
- **VPA virtual account missing** → **H6 confirmed** (variant). The `update_virtual_account_details` task (`repayment/tasks.py:548`) failed. Check Celery task results for this task. The task fetches VPA details from Saraloan and requires a valid `CustomerLenderMap.loan_account_id`.
- **Transaction reference in `Draft` for > 1 day** → **H6 confirmed**. The PG payment was initiated but never completed. The daily cleanup task `update_failure_for_stale_transaction_references()` should have marked it as `PSP_FAILURE`. Check if this task ran.
- **Transaction reference `Success` but no deposit** → The `DepositView.__update_deposits()` callback may have failed. Check for errors in the deposit creation flow.
- **All chains complete** → Transactions are properly linked. If the issue persists, return to [Step 3](#step-3-retrieve-lender-payments) to verify lender-side payments.

---

## Step 9: Check Repayment Reminder and Communication Status

**Goal**: If the investigation is about missing repayment reminders or notifications, verify the demand sheet communication records and reminder task execution.

> Reminders are triggered by `repayment/tasks.py:initiate_repayment_reminder()` (daily cron at 02:30). The task iterates active demand sheets and sends SMS/IVR/WhatsApp based on configurable rules.

**ORM**:
```python
from repayment.models import DemandSheetCommunication

DemandSheetCommunication.objects.filter(
    demand_sheet__user_id='{user_id}'
).values(
    'id', 'demand_sheet__id', 'demand_sheet__due_date',
    'communication_type', 'reminder_state',
    'created_at', 'updated_at'
).order_by('-created_at')[:20]
```

**SQL**:
```sql
SELECT dsc.id, dsc.demand_sheet_id, ds.due_date,
       dsc.communication_type, dsc.reminder_state,
       dsc.created_at, dsc.updated_at
FROM repayment_demandsheetcommunication dsc
JOIN repayment_demandsheet ds ON dsc.demand_sheet_id = ds.id
WHERE ds.user_id = '{user_id}'
ORDER BY dsc.created_at DESC
LIMIT 20;
```

**Performance**: Expected < 30ms with join on indexed `demand_sheet_id`.

**What to Check**:
- `communication_type`: `IVR`, `SMS`, or `WA` (WhatsApp).
- `reminder_state`: Which reminder stage was triggered (e.g., from_date+4, due_date+1).
- Were communications sent for the current demand period?
- Check if the `initiate_repayment_reminder` task ran successfully.

**Decision**:
- **No communication records** → Reminder task didn't process this user. Check if the demand sheet is active (`to_date >= today`, `from_date <= today`, `active = True`). Also check if the `get_from_date_rule_info()` cache returned a valid response.
- **Communication records exist but user didn't receive** → The SMS/IVR/WhatsApp delivery may have failed at the provider level. Check `send_sms` task results.
- **Reminder task not running** → Check Celery Beat schedule for `initiate_repayment_reminder` (daily 02:30).

---

## Hypothesis Validation Summary

### H1: Repayment Not Applied to Loan

| Evidence | Query | Confirms | Refutes |
|----------|-------|----------|---------|
| Payments exist with `status=POSTED` | [Step 3](#step-3-retrieve-lender-payments) | Payments are present | No payments found |
| No `PaymentLoanMap` entries | [Step 5b](#step-5b-check-payment-loan-mapping) | Reconciliation hasn't mapped payments to loans | Mapping exists |
| Loans still in `DISBURSED` | [Step 5a](#step-5a-check-loan-statuses) | Loan status not updated | Loan in `PARTIALLY_PAID` or `PAID` |
| Reconciliation task `FAILURE` | [Step 5c](#step-5c-check-reconciliation-task-execution) | Reconciliation failed | Task `SUCCESS` |

### H2: Transaction Mismatch (Amount Discrepancy)

| Evidence | Query | Confirms | Refutes |
|----------|-------|----------|---------|
| `payment_amount ≠ ledger_amount` | [Step 4](#step-4-cross-reference-payments-with-ledger-entries) | Amounts differ | Amounts match |
| Payment `updated_at` > Ledger `updated_at` | [Step 4](#step-4-cross-reference-payments-with-ledger-entries) | Payment updated after ledger was created | Timestamps aligned |
| `refund_amount > 0` on payment | [Step 3](#step-3-retrieve-lender-payments) | Partial refund reduced amount | No refund |

### H3: Ledger Entry Missing

| Evidence | Query | Confirms | Refutes |
|----------|-------|----------|---------|
| `LEFT JOIN` returns `ledger_id IS NULL` | [Step 4](#step-4-cross-reference-payments-with-ledger-entries) | No ledger entry for payment | Ledger entry exists |
| Sync task `FAILURE` with traceback | [Step 7a](#step-7a-check-celery-task-results-for-sync-tasks) | `create_or_update_ledger_entry()` threw exception | Task succeeded |

### H4: Demand Sheet Discrepancy

| Evidence | Query | Confirms | Refutes |
|----------|-------|----------|---------|
| `demand_repaid ≠ actual_payment_sum` | [Step 6a](#step-6a-cross-reference-demand-with-actual-payments) | Demand sheet out of sync with payments | Amounts match |
| Demand sheet `updated_at` is old | [Step 6](#step-6-verify-demand-sheet-data) | Stale data | Recently updated |
| No demand sheet for current period | [Step 6](#step-6-verify-demand-sheet-data) | Demand sheet not uploaded | Current demand exists |

### H5: Payment Sync Failure from Saraloan

| Evidence | Query | Confirms | Refutes |
|----------|-------|----------|---------|
| `loan_account_id IS NULL` on `CustomerLenderMap` | [Step 7b](#step-7b-check-customerlendermap-required-for-cron-sync) | Cron sync cannot run | `loan_account_id` populated |
| Sync task `FAILURE` | [Step 7a](#step-7a-check-celery-task-results-for-sync-tasks) | Sync failed with error | Task `SUCCESS` |
| No webhook events for user | [Step 7c](#step-7c-check-webhook-events) | Lender hasn't sent notification | Webhook received |
| `REPAYMENT_WEBHOOK_FAILURE_EVENT` email sent | Check email logs | `process_repayment_data` threw exception | No failure email |

### H6: Repayment Stuck in Processing

| Evidence | Query | Confirms | Refutes |
|----------|-------|----------|---------|
| Collections with `related_transaction_id IS NULL` | [Step 8a](#step-8a-check-collection-to-deposit-chain) | Cash collected but not deposited | All collections linked |
| `TransactionReferenceGroupInfo.status = Draft` (stale) | [Step 8d](#step-8d-check-transaction-reference-info-pgupi-payments) | PG payment initiated but not completed | Status is `Success` |
| Virtual account missing | [Step 8c](#step-8c-check-virtual-account-info-vpa-payments) | VPA setup failed | Virtual account exists |
| Transaction `payment_id IS NULL` | [Step 2](#step-2-retrieve-repayment-transactions) | Transaction not linked to Payment | `payment_id` populated |
