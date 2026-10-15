# Playbook: Payment Reconciliation Investigation

> Step-by-step debugging procedure for investigating payment reconciliation issues — from verifying customer/credit line setup through payment status, reconciliation execution, credit note handling, aggregated payment transfers, and SAP/ERP posting.
> All queries are **read-only** (`SELECT` only) and accept `{user_id}` (`source_identifier_id` / `partner_id`) as input.

**Cross-references**:
- Flow: [`02-user-flows/repayment-workflow.md`](../02-user-flows/repayment-workflow.md)
- Decision Logic: [`04-decision-logic.md`](../04-decision-logic.md)
- Celery Workflows: [`05-celery-workflows.md`](../05-celery-workflows.md) — Reconciliation, Payment Transfer
- Runtime Data: [`03-runtime-data.md`](../03-runtime-data.md)
- Related Playbook: [`repayment-playbook.md`](repayment-playbook.md)

---

## Common Hypotheses

| # | Hypothesis | Summary | Jump To |
|---|-----------|---------|---------|
| H1 | Payment not reconciled against loan | Payments exist in `POSTED`/`UNRECONCILED` but loans remain `DISBURSED`; reconciliation not triggered or failed | [Step 4](#step-4-check-reconciliation-entries) |
| H2 | Credit note mismatch | Credit note amount doesn't match expected value, or CN payment was not created/linked correctly | [Step 5](#step-5-investigate-credit-note-mismatch) |
| H3 | Aggregated payment transfer failure | Payments marked `TRANSFER_TO_LENDER` but `AggregatedPaymentTransfer` stuck in `ERROR`/`YET_TO_TRANSFER` | [Step 6](#step-6-investigate-aggregated-payment-transfer-failure) |
| H4 | Payment transfer to lender failed | Individual payment transfer to lender failed; payment stuck in `TRANSFER_INITIATED` or `TRANSFER_TO_LENDER` | [Step 7](#step-7-investigate-payment-transfer-to-lender-failure) |
| H5 | Reconciliation blocked by Redis lock or app constant | Reconciliation restricted via `RESTRICT_RECONCILIATION_FOR_ALL_PARTNERS`, blacklist, or Redis lock contention | [Step 8](#step-8-check-reconciliation-restrictions) |
| H6 | SAP/ERP posting failure | Payment moved to lender but LA entry not created in SAP; `la_entry_created = False` | [Step 9](#step-9-investigate-sap-erp-posting-failure) |

---

## Payment & Reconciliation Status Reference

### Payment Status Lifecycle (`payment/constants.py:PaymentStatus`)

| Status | Meaning | Reconciliation Relevance |
|--------|---------|--------------------------|
| `POSTED` | Payment confirmed and active | Eligible for reconciliation if `sub_status` is `UNRECONCILED` or `PARTIALLY_RECONCILED` |
| `UNREALIZED` | PG payment pending realization | Not eligible for reconciliation |
| `TRANSFER_TO_LENDER` | Marked for transfer to external lender | Created by reconciliation; awaiting aggregation |
| `TRANSFER_INITIATED` | Aggregated and transfer started | Part of an `AggregatedPaymentTransfer` batch |
| `MOVED_TO_LENDER` | Successfully transferred to lender | Terminal state for lender payments |
| `CANCELLED` | Payment cancelled/refunded | Not eligible for reconciliation |

### Payment Sub-Status (`payment/constants.py:PaymentSubStatus`)

| Sub-Status | Meaning |
|------------|---------|
| `UNRECONCILED` | Payment not yet matched to any loan/debit note |
| `PARTIALLY_RECONCILED` | Part of payment amount matched; `reconcilable_amount > 0` remains |
| `RECONCILED` | Fully matched; `reconcilable_amount = 0` |
| `REFUNDED` | Payment refunded |

### Aggregated Payment Transfer Status (`payment/constants.py:PaymentTransferStatus`)

| Status | Meaning |
|--------|---------|
| `YET_TO_TRANSFER` | Aggregated but not yet sent to bank |
| `STARTED` | Transfer attempt in progress |
| `INITIATED` | Bank accepted the transfer request |
| `TRANSFERRED` | Bank confirmed transfer complete |
| `ERROR` | Transfer attempt failed (retryable) |
| `FAILED` | Transfer permanently failed |
| `REVERSED` | Transfer reversed |

### ERP Upload Status (`payment/constants.py:ErpAggregatedPaymentUploadStatus`)

| Code | Status | Meaning |
|------|--------|---------|
| 1 | `DRAFT_UPLOADED` | SAP draft payment created |
| 2 | `DRAFT_UPLOAD_FAILED` | SAP draft creation failed |
| 3 | `POSTING_INITIATED` | SAP posting started |
| 4 | `POSTED` | SAP posting confirmed |
| 5 | `POSTING_FAILED` | SAP posting failed |

---

## Step 1: Verify Customer and Credit Lines

**Goal**: Confirm the customer exists, is a DC type, and has both GAPL and lender credit lines (if financed).

**ORM**:
```python
from credit_line.model import Customer, CustomerCreditLine

customer = Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'source_identifier_id', 'name',
    'is_credit_allowed', 'external_lender_supported',
    'customer_type__name', 'locus_recon_last_ran_at'
).first()

credit_lines = CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).select_related('credit_product', 'lender').values(
    'id', 'status', 'credit_limit', 'operational_limit',
    'credit_product__credit_product_name',
    'credit_product__belongs_to_gapl',
    'credit_product__loan_cutoff_days',
    'credit_product__advance_transfer',
    'lender__name',
    'recon_consistent',
    'created_at', 'updated_at'
)
```

**SQL**:
```sql
SELECT c.id, c.source_identifier_id, c.name,
       c.is_credit_allowed, c.external_lender_supported,
       ct.name AS customer_type,
       c.locus_recon_last_ran_at
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';

SELECT ccl.id, ccl.status, ccl.credit_limit, ccl.operational_limit,
       cp.credit_product_name, cp.belongs_to_gapl,
       cp.loan_cutoff_days, cp.advance_transfer,
       l.name AS lender_name,
       ccl.recon_consistent,
       ccl.created_at, ccl.updated_at
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
JOIN credit_line_lender l ON ccl.lender_id = l.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Unique index on `credit_line_customer.source_identifier_id`. Expected < 10ms each.

**What to Check**:
- Is `customer_type` = `DC`? Reconciliation only runs for DC partners (`loan/utility.py:700`).
- Is there a GAPL credit line (`belongs_to_gapl = True`)? Required for reconciliation (`loan/utility.py:718`).
- If `external_lender_supported = True`, is there an active/onhold lender credit line (`belongs_to_gapl = False`, `status IN (ACTIVE, ONHOLD)`)? Required for financed partners (`loan/utility.py:726`).
- `locus_recon_last_ran_at`: When did reconciliation last run? If `NULL`, it has never completed successfully.
- `loan_cutoff_days`: The aging period used to classify loans as aged vs remaining during reconciliation.
- `advance_transfer`: If `True` on the lender credit product, remaining GAPL payments are auto-transferred to lender post-reconciliation (`loan/utility.py:1218`).
- `recon_consistent`: If `False`, aggregated payment transfer will be blocked (`payment/tasks.py:2155`).

**Decision**:
- **Customer not found** → No reconciliation possible. Investigate onboarding.
- **Not a DC partner** → Reconciliation returns `"Not a DC Partner"` (`loan/utility.py:700`). Not applicable.
- **No GAPL credit line** → Reconciliation returns `"GAPL Credit Line doesn't exist for DC Partner"` (`loan/utility.py:720`). Check credit line setup.
- **Financed partner without lender credit line** → Reconciliation returns `"External Lender Credit Line doesn't exist for Financed DC Partner"` (`loan/utility.py:727`). Check lender onboarding.
- **All credit lines present** → Proceed to [Step 2](#step-2-retrieve-payments-and-their-reconciliation-status).

---

## Step 2: Retrieve Payments and Their Reconciliation Status

**Goal**: Get all GAPL payments for this user and assess their reconciliation state. Identify payments that should have been reconciled but weren't.

**ORM**:
```python
from payment.model import Payment

# GAPL payments eligible for or already through reconciliation
gapl_payments = Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    customer_credit_line__credit_product__belongs_to_gapl=True
).values(
    'id', 'lender_payment_ref_number', 'payment_amount',
    'reconcilable_amount', 'transfer_to_lender_amount',
    'hold_amount', 'refund_amount',
    'payment_date', 'payment_mode',
    'status', 'sub_status',
    'parent_payment_id', 'payment_transfer_number',
    'la_entry_created', 'la_entry_status',
    'created_at', 'updated_at'
).order_by('-payment_date', '-created_at')
```

**SQL**:
```sql
SELECT p.id, p.lender_payment_ref_number, p.payment_amount,
       p.reconcilable_amount, p.transfer_to_lender_amount,
       p.hold_amount, p.refund_amount,
       p.payment_date, p.payment_mode,
       p.status, p.sub_status,
       p.parent_payment_id, p.payment_transfer_number,
       p.la_entry_created, p.la_entry_status,
       p.created_at, p.updated_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = true
ORDER BY p.payment_date DESC, p.created_at DESC;
```

**Performance**: Index on `payment_payment(customer_credit_line_id)`. Expected < 50ms.

**What to Check**:
- Are there payments with `status = POSTED` and `sub_status = UNRECONCILED`? These are candidates for reconciliation.
- `reconcilable_amount`: Should equal `payment_amount - hold_amount - refund_amount` for unreconciled payments. If `0` but `sub_status = UNRECONCILED`, the `update_reconcilable_amount_in_payments()` pre-step may not have run (`loan/utility.py:424`).
- `transfer_to_lender_amount > 0`: Part of this payment was allocated to lender transfer during reconciliation.
- `payment_mode`: `CREDIT_NOTE` or `LENDER_CREDIT_NOTE` payments are skipped during post-reconciliation event publishing (`loan/utility.py:1200`).
- `parent_payment_id`: If set, this is a child `TRANSFER_TO_LENDER` payment created from a parent GAPL payment during reconciliation.
- Count of payments by status/sub_status to get an overview.

**Decision**:
- **No GAPL payments exist** → Reconciliation returns `"No Payments to Reconcile"` (`loan/utility.py:756`). Check if payments were synced. See [`repayment-playbook.md`](repayment-playbook.md) Step 7.
- **All payments `RECONCILED`** → Reconciliation already completed. If the issue is about loan status, go to [Step 3](#step-3-check-outstanding-loans-and-debit-notes).
- **Payments `UNRECONCILED` with `reconcilable_amount = 0`** → The `reconcilable_amount` was not set. Check if `update_reconcilable_amount_in_payments()` ran. This is called at the start of `run_reconciliation_for_customer()` (`loan/utility.py:748`).
- **Payments in `TRANSFER_TO_LENDER` or `TRANSFER_INITIATED`** → These were created by reconciliation for lender transfer. Go to [Step 6](#step-6-investigate-aggregated-payment-transfer-failure) to check transfer status.
- **Mix of reconciled and unreconciled** → Proceed to [Step 3](#step-3-check-outstanding-loans-and-debit-notes) to see what outstanding entities remain.

---

## Step 3: Check Outstanding Loans and Debit Notes

**Goal**: Identify loans and debit notes that should be reconciled against payments. Reconciliation matches payments to outstanding entities in priority order.

### Step 3a: GAPL Loans

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    customer_credit_line__credit_product__belongs_to_gapl=True
).values(
    'id', 'loan_id', 'status', 'loan_amount',
    'disbursed_amount', 'remaining_amount',
    'transaction_date', 'origin_overdue_credit_date',
    'interest_free_period_end_date',
    'created_at', 'updated_at'
).order_by('origin_overdue_credit_date', 'created_at')
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.disbursed_amount, ll.remaining_amount,
       ll.transaction_date, ll.origin_overdue_credit_date,
       ll.interest_free_period_end_date,
       ll.created_at, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = true
ORDER BY ll.origin_overdue_credit_date, ll.created_at;
```

### Step 3b: Lender Loans (for financed partners)

**ORM**:
```python
Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    customer_credit_line__credit_product__belongs_to_gapl=False,
    status__in=['YET_TO_BE_DISBURSED', 'DISBURSED', 'OVERDUE', 'PARTIALLY_PAID', 'OVERDUE_AND_PARTIALLY_PAID']
).values(
    'id', 'loan_id', 'status', 'loan_amount',
    'disbursed_amount', 'remaining_amount',
    'transaction_date', 'interest_free_period_end_date',
    'created_at', 'updated_at'
).order_by('transaction_date', 'created_at')
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.disbursed_amount, ll.remaining_amount,
       ll.transaction_date, ll.interest_free_period_end_date,
       ll.created_at, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = false
  AND ll.status IN ('YET_TO_BE_DISBURSED', 'DISBURSED', 'OVERDUE', 'PARTIALLY_PAID', 'OVERDUE_AND_PARTIALLY_PAID')
ORDER BY ll.transaction_date, ll.created_at;
```

### Step 3c: Debit Notes

**ORM**:
```python
from payment.model.debit_note import DebitNote

DebitNote.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    customer_credit_line__credit_product__belongs_to_gapl=True,
    status='POSTED',
    sub_status__in=['UNRECONCILED', 'PARTIALLY_RECONCILED']
).select_related('reason').values(
    'id', 'type', 'amount', 'reconcilable_amount',
    'date', 'status', 'sub_status',
    'reason__name', 'reason__aging_days',
    'prepaid_amount_settled',
    'created_at', 'updated_at'
).order_by('date', 'created_at')
```

**SQL**:
```sql
SELECT dn.id, dn.type, dn.amount, dn.reconcilable_amount,
       dn.date, dn.status, dn.sub_status,
       dnr.name AS reason_name, dnr.aging_days,
       dn.prepaid_amount_settled,
       dn.created_at, dn.updated_at
FROM payment_debitnote dn
JOIN credit_line_customercreditline ccl ON dn.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
LEFT JOIN payment_debitnotereason dnr ON dn.reason_id = dnr.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = true
  AND dn.status = 'POSTED'
  AND dn.sub_status IN ('UNRECONCILED', 'PARTIALLY_RECONCILED')
ORDER BY dn.date, dn.created_at;
```

**Performance**: Index on `loan_loan(customer_credit_line_id)`, `payment_debitnote(customer_credit_line_id)`. Expected < 50ms each.

**What to Check**:
- Are there GAPL loans in `DISBURSED` or `PARTIALLY_PAID`? These are reconciliation targets.
- `YET_TO_BE_DISBURSED` GAPL loans are auto-marked as `DISBURSED` at the start of reconciliation (`loan/utility.py:mark_gapl_loan_as_disbursed()`).
- For financed partners: lender loans in overdue state (older than `loan_cutoff_days`) get higher reconciliation priority.
- Debit notes with `type = DH` (debit holds) get highest priority in reconciliation order.
- Debit notes in `PRIORITY_DEBIT_NOTES` app constant list get second-highest priority.
- Reconciliation priority order: `top_priority_debit_notes` → `debit_holds` → `aged_entities` → `lender_loans_in_overdue_state` → `remaining_outstanding_entities` (`loan/utility.py:1070–1080`).

**Decision**:
- **No outstanding loans or debit notes** → Nothing to reconcile against. Payments remain `UNRECONCILED`. If `advance_transfer = True` on lender credit product, remaining payments should still be transferred to lender post-reconciliation.
- **Outstanding entities exist with unreconciled payments** → Reconciliation should have matched them. Go to [Step 4](#step-4-check-reconciliation-entries) to see if it ran.
- **All loans already `PAID`** → Reconciliation already completed for loans. Check debit notes or lender loans.

---

## Step 4: Check Reconciliation Entries

**Goal**: Verify whether reconciliation has run and what payment-to-entity mappings were created. This addresses **H1: Payment not reconciled against loan**.

> Reconciliation logic: `loan/utility.py:run_reconciliation_for_customer()` called via `run_reconciliation_for_customer_main()`.
> Triggered by: `loan/tasks.py:check_and_run_reconciliation_for_all_customers()` (daily cron at 04:00) or `run_reconciliation_for_customers()` (manual/periodic).

### Step 4a: Check ReconciliationEntry Records

**ORM**:
```python
from loan.model.reconciliation_entry import ReconciliationEntry

ReconciliationEntry.objects.filter(
    partner_id='{user_id}'
).values(
    'id', 'partner_id',
    'outstanding_entity_id', 'outstanding_entity_type',
    'payment_id', 'payment_amount_used',
    'comment', 'created_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT id, partner_id,
       outstanding_entity_id, outstanding_entity_type,
       payment_id, payment_amount_used,
       comment, created_at
FROM loan_reconciliationentry
WHERE partner_id = '{user_id}'
ORDER BY created_at DESC;
```

**Performance**: Index on `loan_reconciliationentry(partner_id)`. Expected < 30ms.

### Step 4b: Check PaymentLoanMap Records

**ORM**:
```python
from loan.model import PaymentLoanMap

PaymentLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'loan__loan_id', 'loan__status',
    'payment__id', 'payment__payment_amount', 'payment__status',
    'payment_amount_used', 'status',
    'created_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT plm.id,
       ll.loan_id, ll.status AS loan_status,
       p.id AS payment_id, p.payment_amount, p.status AS payment_status,
       plm.payment_amount_used, plm.status AS map_status,
       plm.created_at
FROM loan_paymentloanmap plm
JOIN loan_loan ll ON plm.loan_id = ll.id
JOIN payment_payment p ON plm.payment_id = p.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY plm.created_at DESC;
```

### Step 4c: Check Reconciliation Celery Task Results

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'loan.tasks.check_and_run_reconciliation_for_all_customers',
        'loan.tasks.run_reconciliation_for_customers',
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
    'loan.tasks.check_and_run_reconciliation_for_all_customers',
    'loan.tasks.run_reconciliation_for_customers'
)
AND task_args LIKE '%{user_id}%'
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: Index on `django_celery_results_taskresult(task_name)`. Expected < 100ms. **Warning**: `task_args LIKE` scan; always include date filter.

**What to Check**:
- **`ReconciliationEntry` records**: Do they exist? Each entry maps a payment to an outstanding entity (`GAPL_LOAN`, `LENDER_LOAN`, or `DEBIT_NOTE`).
- **`outstanding_entity_type`**: `GAPL_LOAN` = payment reconciled against GAPL loan, `LENDER_LOAN` = payment allocated for lender transfer, `DEBIT_NOTE` = payment reconciled against debit note.
- **`PaymentLoanMap` records**: `status = COMPLETED` for GAPL loan reconciliation, `status = PENDING` for lender loan reconciliation (transfer pending).
- **Sum of `payment_amount_used`**: Should match the total reconciled amount. Compare with payment amounts.
- **Celery task status**: `SUCCESS` with result `True` = reconciliation completed. `FAILURE` = check traceback.
- **`locus_recon_last_ran_at`** on Customer (from Step 1): Updated on successful reconciliation completion (`loan/utility.py:498`).

**Decision**:
- **No `ReconciliationEntry` records and no `PaymentLoanMap` records** → **H1 confirmed**. Reconciliation has never run for this partner. Go to [Step 8](#step-8-check-reconciliation-restrictions) to check if it's blocked.
- **Reconciliation task `FAILURE`** → Check traceback. Common errors: Redis lock contention, database constraint violation, `ValidationError` during loan status transition. Go to [Step 8](#step-8-check-reconciliation-restrictions).
- **Reconciliation task `SUCCESS` but result is a string message** → The function returned early. Common messages:
  - `"Locus Reconciliation is restricted for partner - {user_id}"` → Go to [Step 8](#step-8-check-reconciliation-restrictions).
  - `"Locus Reconciliation already running for partner - {user_id}"` → Redis lock contention. Go to [Step 8](#step-8-check-reconciliation-restrictions).
  - `"No Payments to Reconcile"` → No eligible payments at the time. Go to [Step 2](#step-2-retrieve-payments-and-their-reconciliation-status).
  - `"Not a DC Partner"` / `"GAPL Credit Line doesn't exist..."` → Go to [Step 1](#step-1-verify-customer-and-credit-lines).
- **`ReconciliationEntry` records exist but loans still `DISBURSED`** → The FSM transition may have failed. Check `check_for_valid_status_transition()` in `loan/utility.py:214`. See [`loan-lifecycle-playbook.md`](loan-lifecycle-playbook.md) for FSM diagnosis.
- **Records exist and look correct** → Reconciliation ran. If the issue is about credit notes, go to [Step 5](#step-5-investigate-credit-note-mismatch). If about payment transfer, go to [Step 6](#step-6-investigate-aggregated-payment-transfer-failure).

---

## Step 5: Investigate Credit Note Mismatch

**Goal**: Check credit notes for this user and verify they are correctly linked to payments. This addresses **H2: Credit note mismatch**.

> Credit notes generate payments via signal `payment/signals.py:create_payment_for_cn()`. The CN payment is created with `payment_mode = CREDIT_NOTE` or `LENDER_CREDIT_NOTE`.
> During reconciliation, CN payments are included in the GAPL payments pool but skipped during post-reconciliation event publishing (`loan/utility.py:1200`).

### Step 5a: Retrieve Credit Notes

**ORM**:
```python
from payment.model.credit_note import CreditNote

CreditNote.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'name', 'internal_id', 'type__name',
    'linked_invoice', 'date', 'amount', 'actual_amount',
    'status', 'cancelled_in_sap',
    'amount_used', 'credit_amount', 'prepaid_amount',
    'is_instant_discount_cn',
    'customer_credit_line__credit_product__credit_product_name',
    'invoice__id',
    'created_at', 'updated_at'
).order_by('-date', '-created_at')
```

**SQL**:
```sql
SELECT cn.id, cn.name, cn.internal_id,
       cnt.name AS type_name,
       cn.linked_invoice, cn.date, cn.amount, cn.actual_amount,
       cn.status, cn.cancelled_in_sap,
       cn.amount_used, cn.credit_amount, cn.prepaid_amount,
       cn.is_instant_discount_cn,
       cp.credit_product_name,
       cn.invoice_id,
       cn.created_at, cn.updated_at
FROM payment_creditnote cn
JOIN credit_line_customercreditline ccl ON cn.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
JOIN payment_creditnotetype cnt ON cn.type_id = cnt.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY cn.date DESC, cn.created_at DESC;
```

### Step 5b: Check CN-Generated Payments

**ORM**:
```python
from payment.model import Payment

Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    payment_mode__in=['CREDIT_NOTE', 'LENDER_CREDIT_NOTE']
).values(
    'id', 'lender_payment_ref_number', 'payment_amount',
    'reconcilable_amount', 'payment_mode',
    'status', 'sub_status',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT p.id, p.lender_payment_ref_number, p.payment_amount,
       p.reconcilable_amount, p.payment_mode,
       p.status, p.sub_status,
       p.created_at, p.updated_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND p.payment_mode IN ('CREDIT_NOTE', 'LENDER_CREDIT_NOTE')
ORDER BY p.created_at DESC;
```

**Performance**: Index on `payment_payment(customer_credit_line_id)`, `payment_creditnote(status)`. Expected < 50ms each.

**What to Check**:
- Does every `POSTED` credit note have a corresponding payment with `payment_mode = CREDIT_NOTE`?
- `cn.amount` vs `payment.payment_amount`: Should match. If different, the CN payment was created with wrong amount.
- `cn.status`: `POSTED` = active, `CANCELLED` = cancelled. Cancelled CNs should have `cancelled_in_sap = True` if SAP posting was done.
- `cn.amount_used`: How much of the CN has been consumed. If `amount_used < amount`, the CN is partially used.
- `linked_invoice`: The invoice this CN is linked to. If `NULL`, the CN may not be properly linked.
- CN payments participate in reconciliation like regular payments. If a CN payment is `UNRECONCILED`, it will be matched to loans/debit notes during the next reconciliation run.

**Decision**:
- **Credit note exists but no corresponding payment** → **H2 confirmed**. The `create_payment_for_cn` signal (`payment/signals.py`) may have failed. Check if the signal is connected and if there were errors during CN creation.
- **CN payment amount ≠ CN amount** → **H2 confirmed**. The payment was created with incorrect amount. Check `create_payments_for_cns()` in `payment/tasks.py:577`.
- **CN `CANCELLED` but payment still `POSTED`** → Inconsistency. The CN cancellation should have cancelled the payment too.
- **CN payment `RECONCILED` but CN `amount_used` not updated** → The `settle_cn_payments_with_linked_invoices()` function (`loan/utility.py:3583`) may not have run. This is called at the start of reconciliation.
- **All CN data looks correct** → Credit notes are fine. Go to [Step 6](#step-6-investigate-aggregated-payment-transfer-failure) if investigating transfer issues, or [Step 8](#step-8-check-reconciliation-restrictions) if reconciliation didn't run.

---

## Step 6: Investigate Aggregated Payment Transfer Failure

**Goal**: Check if payments marked `TRANSFER_TO_LENDER` were properly aggregated and transferred to the external lender. This addresses **H3: Aggregated payment transfer failure**.

> Aggregation flow: `payment/tasks.py:aggregate_payment_transfer()` (weekdays 10:30) → `aggregate_ccl_payment_transfer()` → `transfer_agg_payment()`.
> Transfer flow: `payment/tasks.py:transfer_all_agg_payments()` (weekdays 10:35) retries `YET_TO_TRANSFER` and `ERROR` status transfers.

### Step 6a: Check AggregatedPaymentTransfer Records

**ORM**:
```python
from payment.model.aggregated_payment_transfer import (
    AggregatedPaymentTransfer, AggregatedPaymentTransferMap
)

agg_transfers = AggregatedPaymentTransfer.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'request_id', 'payment_ref_num',
    'transfer_to__name', 'amount',
    'status', 'unique_txn_ref_number',
    'failure_reason', 'transfer_try_count',
    'erp_upload_status', 'erp_document_number',
    'bank_generated_utr',
    'created_at', 'updated_at'
).order_by('-created_at')

# For a specific aggregated transfer, check mapped payments
agg_maps = AggregatedPaymentTransferMap.objects.filter(
    aggregated_payment_transfer__customer__source_identifier_id='{user_id}'
).values(
    'id', 'payment__id', 'payment__payment_amount',
    'payment__status', 'payment__lender_payment_ref_number',
    'aggregated_payment_transfer__id',
    'aggregated_payment_transfer__status',
    'aggregated_payment_transfer__amount'
).order_by('-aggregated_payment_transfer__created_at')
```

**SQL**:
```sql
SELECT apt.id, apt.request_id, apt.payment_ref_num,
       l.name AS transfer_to_lender,
       apt.amount, apt.status,
       apt.unique_txn_ref_number,
       apt.failure_reason, apt.transfer_try_count,
       apt.erp_upload_status, apt.erp_document_number,
       apt.bank_generated_utr,
       apt.created_at, apt.updated_at
FROM payment_aggregatedpaymenttransfer apt
JOIN credit_line_customer c ON apt.customer_id = c.id
JOIN credit_line_lender l ON apt.transfer_to_id = l.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY apt.created_at DESC;

-- Mapped payments for each aggregated transfer
SELECT aptm.id,
       p.id AS payment_id, p.payment_amount, p.status AS payment_status,
       p.lender_payment_ref_number,
       apt.id AS agg_transfer_id, apt.status AS agg_status, apt.amount AS agg_amount
FROM payment_aggregatedpaymenttransfermap aptm
JOIN payment_payment p ON aptm.payment_id = p.id
JOIN payment_aggregatedpaymenttransfer apt ON aptm.aggregated_payment_transfer_id = apt.id
JOIN credit_line_customer c ON apt.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY apt.created_at DESC;
```

**Performance**: Expected < 50ms. Index on `payment_aggregatedpaymenttransfer(status)`.

### Step 6b: Check Aggregation Task Results

**SQL**:
```sql
SELECT task_id, task_name, status, result, traceback,
       date_created, date_done
FROM django_celery_results_taskresult
WHERE task_name IN (
    'payment.tasks.aggregate_payment_transfer',
    'payment.tasks.aggregate_ccl_payment_transfer',
    'payment.tasks.transfer_agg_payment',
    'payment.tasks.transfer_all_agg_payments'
)
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 30;
```

**Performance**: Index on `django_celery_results_taskresult(task_name)`. Expected < 100ms.

**What to Check**:
- **`status = YET_TO_TRANSFER`**: Aggregated but transfer not attempted. Check if `transfer_all_agg_payments()` ran.
- **`status = ERROR`**: Transfer failed. Check `failure_reason` for details. `transfer_try_count` shows how many attempts were made. Max retries: `AGGREGATED_PAYMENT_TRANSFER_MAX_COUNT` (`payment/tasks.py:2278`).
- **`status = STARTED`**: Transfer in progress. May be stuck if `updated_at` is old.
- **`status = INITIATED`**: Bank accepted the request. Awaiting confirmation. `sync_all_aggregated_payments()` syncs status for transfers older than 50 minutes (`payment/tasks.py:2387`).
- **`status = TRANSFERRED`**: Successfully transferred. Check `erp_upload_status` for SAP posting.
- **`erp_upload_status = 2` (DRAFT_UPLOAD_FAILED)**: SAP draft creation failed during transfer (`payment/tasks.py:2242`).
- **`recon_consistent = False`** on credit line (from Step 1): `aggregate_ccl_payment_transfer()` checks reconciliation consistency before aggregating (`payment/tasks.py:2155`). If inconsistent, returns `"Returning! recon for partner is not consistent"`.
- **No active BlackSoil credit line**: `aggregate_ccl_payment_transfer()` requires an active/onhold BlackSoil line (`payment/tasks.py:2175`).
- **Aggregated amount < 1 rupee**: Transfer skipped (`payment/tasks.py:2181`).
- **`ALLOW_PAYMENT_TRANSFER_FOR_ALL_PARTNER` app constant**: If `"False"`, only partners in `ALLOWED_PAYMENT_TRANSFER_PARTNER_IDS` list are eligible (`payment/tasks.py:2073`).

**Decision**:
- **No `AggregatedPaymentTransfer` records** → Aggregation never ran for this partner. Check if `aggregate_payment_transfer()` cron ran. Check if `ALLOW_PAYMENT_TRANSFER_FOR_ALL_PARTNER` is `"False"` and partner is not in the allowed list.
- **`status = ERROR` with `transfer_try_count >= max`** → **H3 confirmed**. Transfer exhausted retries. Check `failure_reason`. Common: bank API timeout, invalid account details, insufficient funds.
- **`status = ERROR` with `transfer_try_count < max`** → Transfer will be retried by `transfer_all_agg_payments()` (weekdays 10:35). Wait for next retry or trigger manually.
- **`recon_consistent = False`** → **H3 confirmed**. Aggregation blocked due to reconciliation inconsistency. The `verify_recon_consistency()` check failed. Check `SKIP_RECON_CONSISTENCY_CHECK_IN_PAYMENT_TRANSFER` app constant for override.
- **`status = INITIATED` for > 1 hour** → Transfer may be stuck. `sync_all_aggregated_payments()` should pick it up after 50 minutes. Check if sync task ran.
- **`status = TRANSFERRED`** → Transfer succeeded. If SAP posting is the issue, go to [Step 9](#step-9-investigate-sap-erp-posting-failure).

---

## Step 7: Investigate Payment Transfer to Lender Failure

**Goal**: Check individual `TRANSFER_TO_LENDER` payments created during reconciliation. This addresses **H4: Payment transfer to lender failed**.

> During reconciliation, when a payment is matched against a lender loan, a child payment with `status = TRANSFER_TO_LENDER` is created via `create_transfer_to_lender_payment_from_payment()`.
> These child payments have `parent_payment_id` set to the original GAPL payment.

**ORM**:
```python
from payment.model import Payment

# Transfer-to-lender payments (child payments created during reconciliation)
Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    status__in=['TRANSFER_TO_LENDER', 'TRANSFER_INITIATED', 'MOVED_TO_LENDER']
).values(
    'id', 'lender_payment_ref_number', 'payment_amount',
    'status', 'sub_status',
    'parent_payment_id', 'payment_transfer_number',
    'la_entry_created', 'la_entry_status',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT p.id, p.lender_payment_ref_number, p.payment_amount,
       p.status, p.sub_status,
       p.parent_payment_id, p.payment_transfer_number,
       p.la_entry_created, p.la_entry_status,
       p.created_at, p.updated_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND p.status IN ('TRANSFER_TO_LENDER', 'TRANSFER_INITIATED', 'MOVED_TO_LENDER')
ORDER BY p.created_at DESC;
```

**Performance**: Index on `payment_payment(customer_credit_line_id, status)`. Expected < 50ms.

**What to Check**:
- **`status = TRANSFER_TO_LENDER`**: Payment created by reconciliation but not yet aggregated. Should be picked up by `aggregate_payment_transfer()`.
- **`status = TRANSFER_INITIATED`**: Payment is part of an aggregated batch. Check the corresponding `AggregatedPaymentTransfer` in [Step 6](#step-6-investigate-aggregated-payment-transfer-failure).
- **`status = MOVED_TO_LENDER`**: Successfully transferred. Terminal state.
- **`parent_payment_id`**: Links back to the original GAPL payment. Verify the parent payment's `transfer_to_lender_amount` matches the sum of child payment amounts.
- **`payment_transfer_number`**: The UTR/reference number from the bank transfer. Set when the aggregated transfer is confirmed.

**Decision**:
- **Payments stuck in `TRANSFER_TO_LENDER` for > 1 day** → **H4 confirmed**. Aggregation hasn't picked them up. Go to [Step 6](#step-6-investigate-aggregated-payment-transfer-failure).
- **Payments in `TRANSFER_INITIATED` for > 1 day** → The aggregated transfer may have failed. Go to [Step 6](#step-6-investigate-aggregated-payment-transfer-failure).
- **Parent payment `transfer_to_lender_amount` ≠ sum of child payments** → Data inconsistency. The `run_unreconciliation_for_customer()` function validates this (`loan/utility.py:1395`).
- **All payments `MOVED_TO_LENDER`** → Transfer complete. If SAP posting is the issue, go to [Step 9](#step-9-investigate-sap-erp-posting-failure).

---

## Step 8: Check Reconciliation Restrictions

**Goal**: Determine if reconciliation is blocked by app constants, blacklists, or Redis locks. This addresses **H5: Reconciliation blocked by Redis lock or app constant**.

> Restriction logic: `loan/utility.py:is_reconciliation_restricted()` (line 400).
> Redis lock: `credit_line/utility/invoice_share_utils.py:check_or_add_redis_cache_for_reconciliation()`.

### Step 8a: Check App Constants

The following app constants control reconciliation eligibility. These are typically stored in a database-backed configuration table.

**ORM**:
```python
from base.utility import retrieve_app_constant

# 1. Global restriction flag
restrict_all = retrieve_app_constant(
    "RESTRICT_RECONCILIATION_FOR_ALL_PARTNERS", default="true", type=str
)
# If "true" → only partners in PARTNER_LIST_FOR_RECONCILIATION are allowed

# 2. Allowed partner list (only used when restrict_all == "true")
allowed_partners = retrieve_app_constant(
    "PARTNER_LIST_FOR_RECONCILIATION", default="", type=str, is_list=True
)
# Check if '{user_id}' is in this list

# 3. Blacklisted partners (always checked)
blacklisted = retrieve_app_constant(
    "BLACKLIST_RECONCILIATION_FOR_PARTNERS", default="", type=str, is_list=True
)
# Check if '{user_id}' is in this list

# 4. Payment transfer control
transfer_allowed_for_all = retrieve_app_constant(
    "ALLOW_PAYMENT_TRANSFER_FOR_ALL_PARTNER", default="False", type=str
)
transfer_allowed_partners = retrieve_app_constant(
    "ALLOWED_PAYMENT_TRANSFER_PARTNER_IDS", default=[], type=int, is_list=True
)

# 5. Recon consistency skip list
skip_recon_check = retrieve_app_constant(
    "SKIP_RECON_CONSISTENCY_CHECK_IN_PAYMENT_TRANSFER", default=[], type=str, is_list=True
)
```

**SQL** (if app constants are stored in a config table):
```sql
-- Check the app constants table (table name may vary by implementation)
SELECT key, value
FROM base_appconstant
WHERE key IN (
    'RESTRICT_RECONCILIATION_FOR_ALL_PARTNERS',
    'PARTNER_LIST_FOR_RECONCILIATION',
    'BLACKLIST_RECONCILIATION_FOR_PARTNERS',
    'ALLOW_PAYMENT_TRANSFER_FOR_ALL_PARTNER',
    'ALLOWED_PAYMENT_TRANSFER_PARTNER_IDS',
    'SKIP_RECON_CONSISTENCY_CHECK_IN_PAYMENT_TRANSFER'
);
```

**Performance**: Expected < 10ms (small config table).

### Step 8b: Check Redis Lock State

The reconciliation process uses a Redis lock to prevent concurrent execution for the same partner. The lock is set by `check_or_add_redis_cache_for_reconciliation()` and removed by `remove_redis_constant_for_reconciliation()`.

```python
# Check Redis for active reconciliation lock
# Key pattern: typically includes partner_id
# This requires Redis CLI access:
# redis-cli GET "reconciliation_lock_{user_id}"
```

**What to Check**:
- **`RESTRICT_RECONCILIATION_FOR_ALL_PARTNERS = "true"`** and `{user_id}` NOT in `PARTNER_LIST_FOR_RECONCILIATION` → Partner is restricted. Reconciliation returns early (`loan/utility.py:413`).
- **`{user_id}` in `BLACKLIST_RECONCILIATION_FOR_PARTNERS`** → Partner is explicitly blacklisted (`loan/utility.py:410`).
- **Redis lock active** → A previous reconciliation run may have crashed without releasing the lock. The `run_reconciliation_for_customer_main()` wrapper releases the lock on exception (`loan/utility.py:493`), but if the process was killed (e.g., Celery worker OOM), the lock may persist.
- **`ALLOW_PAYMENT_TRANSFER_FOR_ALL_PARTNER = "False"`** and `{user_id}` NOT in `ALLOWED_PAYMENT_TRANSFER_PARTNER_IDS` → Payment aggregation/transfer is disabled for this partner.

**Decision**:
- **Partner restricted by app constant** → **H5 confirmed**. Add partner to `PARTNER_LIST_FOR_RECONCILIATION` or set `RESTRICT_RECONCILIATION_FOR_ALL_PARTNERS` to `"false"`.
- **Partner blacklisted** → **H5 confirmed**. Remove from `BLACKLIST_RECONCILIATION_FOR_PARTNERS`.
- **Redis lock stuck** → **H5 confirmed**. Manually delete the Redis key. The lock should auto-expire based on TTL, but if TTL is not set or very long, manual intervention is needed.
- **Payment transfer disabled for partner** → Add partner to `ALLOWED_PAYMENT_TRANSFER_PARTNER_IDS` or set `ALLOW_PAYMENT_TRANSFER_FOR_ALL_PARTNER` to `"True"`.
- **No restrictions found** → Reconciliation should be able to run. If it still didn't, check if the daily cron `check_and_run_reconciliation_for_all_customers` ran (Celery Beat at 04:00). The cron checks eligibility: partner must have unreconciled GAPL payments AND (outstanding GAPL loans/debit notes OR financed with advance_transfer) (`loan/tasks.py:2126`).

---

## Step 9: Investigate SAP/ERP Posting Failure

**Goal**: Check if payments that were moved to lender had their LA (Ledger Account) entries created in SAP. This addresses **H6: SAP/ERP posting failure**.

> SAP posting: `payment/tasks.py:create_la_entry_in_sap()` creates a journal entry in SAP with vendor (lender) debit and customer credit.
> Triggered by: `payment/tasks.py:check_and_create_la_entries_in_sap()` which finds all `MOVED_TO_LENDER` payments with `la_entry_created = False`.

### Step 9a: Check Payments Pending SAP Posting

**ORM**:
```python
from payment.model import Payment

Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    status='MOVED_TO_LENDER',
    la_entry_created=False
).values(
    'id', 'lender_payment_ref_number', 'payment_amount',
    'payment_transfer_number',
    'la_entry_created', 'la_entry_status',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT p.id, p.lender_payment_ref_number, p.payment_amount,
       p.payment_transfer_number,
       p.la_entry_created, p.la_entry_status,
       p.created_at, p.updated_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND p.status = 'MOVED_TO_LENDER'
  AND p.la_entry_created = false
ORDER BY p.created_at DESC;
```

### Step 9b: Check AggregatedPaymentTransfer ERP Status

**ORM**:
```python
from payment.model.aggregated_payment_transfer import AggregatedPaymentTransfer

AggregatedPaymentTransfer.objects.filter(
    customer__source_identifier_id='{user_id}',
    erp_upload_status__in=[2, 5, 8]  # DRAFT_UPLOAD_FAILED, POSTING_FAILED, DELETION_FAILED
).values(
    'id', 'payment_ref_num', 'amount',
    'status', 'erp_upload_status', 'erp_document_number',
    'failure_reason',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT apt.id, apt.payment_ref_num, apt.amount,
       apt.status, apt.erp_upload_status, apt.erp_document_number,
       apt.failure_reason,
       apt.created_at, apt.updated_at
FROM payment_aggregatedpaymenttransfer apt
JOIN credit_line_customer c ON apt.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND apt.erp_upload_status IN (2, 5, 8)
ORDER BY apt.created_at DESC;
```

### Step 9c: Check SAP Posting Task Results

**SQL**:
```sql
SELECT task_id, task_name, status, result, traceback,
       date_created, date_done
FROM django_celery_results_taskresult
WHERE task_name IN (
    'payment.tasks.create_la_entry_in_sap',
    'payment.tasks.check_and_create_la_entries_in_sap'
)
AND task_args LIKE '%{user_id}%'
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: Expected < 100ms with date filter. **Warning**: `task_args LIKE` scan on large tables.

**What to Check**:
- **`la_entry_created = False`** on `MOVED_TO_LENDER` payments → SAP posting hasn't completed.
- **`payment_transfer_number` is NULL** → `create_la_entry_in_sap()` returns `"Not a Valid UTR."` if `payment_transfer_number` is not set (`payment/tasks.py:1631`). The UTR is set during aggregated transfer confirmation.
- **`erp_upload_status = 2` (DRAFT_UPLOAD_FAILED)** → SAP draft payment creation failed during `create_transfer_to_lender_payment_in_draft_mode()` (`payment/tasks.py:2242`).
- **`erp_upload_status = 5` (POSTING_FAILED)** → SAP posting of the draft failed. Check `failure_reason`.
- **No matching lender credit line** → `create_la_entry_in_sap()` validates that the lender payment's credit line belongs to the partner (`payment/tasks.py:1649`). Raises `ValidationError` if not.
- **SAP API errors** → Check traceback for `InputBackend().create_la_entry_in_sap()` failures. Common: SAP timeout, invalid vendor/customer SAP ID, fiscal year mismatch.

**Decision**:
- **`la_entry_created = False` with `payment_transfer_number` set** → **H6 confirmed**. SAP posting failed or hasn't been attempted. Check `check_and_create_la_entries_in_sap()` task results.
- **`payment_transfer_number` is NULL** → The aggregated transfer hasn't completed yet. Go to [Step 6](#step-6-investigate-aggregated-payment-transfer-failure).
- **`erp_upload_status` in failed states** → **H6 confirmed**. Check `failure_reason` on the `AggregatedPaymentTransfer`. Retry via `retry_posting_or_deletion_of_transfer_to_lender_payments()` (`payment/tasks.py:2519`).
- **SAP task `FAILURE`** → Check traceback. Common issues: SAP service unavailable, invalid SAP partner ID (OdooDB lookup failed), fiscal year boundary issues.
- **All SAP postings successful** → No ERP issue. If the problem persists, review the full reconciliation flow from [Step 1](#step-1-verify-customer-and-credit-lines).

---

## Quick Diagnosis Flowchart

```
Start: Payment reconciliation issue reported for {user_id}
  │
  ├─ Step 1: Customer/credit lines exist?
  │   ├─ No → Fix onboarding / credit line setup
  │   └─ Yes → Step 2
  │
  ├─ Step 2: Unreconciled GAPL payments exist?
  │   ├─ No payments at all → Check repayment sync (repayment-playbook.md Step 7)
  │   ├─ All RECONCILED → Step 3 (check if loans updated)
  │   └─ UNRECONCILED payments exist → Step 3
  │
  ├─ Step 3: Outstanding loans/debit notes exist?
  │   ├─ No → Nothing to reconcile (expected UNRECONCILED)
  │   └─ Yes → Step 4
  │
  ├─ Step 4: ReconciliationEntry records exist?
  │   ├─ No → Step 8 (check restrictions/locks)
  │   ├─ Task FAILURE → Step 8 (check restrictions/locks)
  │   └─ Yes → Reconciliation ran. Check specific hypothesis:
  │       ├─ Credit note issue → Step 5
  │       ├─ Transfer issue → Step 6 / Step 7
  │       └─ SAP issue → Step 9
  │
  ├─ Step 8: Reconciliation restricted?
  │   ├─ App constant block → Update config
  │   ├─ Blacklisted → Remove from blacklist
  │   ├─ Redis lock stuck → Clear Redis key
  │   └─ Not restricted → Check cron schedule / eligibility
  │
  └─ Step 6/7 → Step 9: SAP posting issue?
      ├─ la_entry_created = False → Check SAP task / API
      └─ All posted → Issue resolved
```
