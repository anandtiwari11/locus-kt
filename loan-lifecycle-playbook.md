# Playbook: Loan Lifecycle Investigation

> Step-by-step debugging procedure for investigating loan creation, approval, disbursement, and status transition issues.
> All queries are **read-only** (`SELECT` only) and accept `{user_id}` (`source_identifier_id` / `partner_id`) as input.

**Cross-references**:
- Flow: [`02-user-flows/approval-workflow.md`](../02-user-flows/approval-workflow.md)
- Decision Logic: [`04-decision-logic.md`](../04-decision-logic.md) — Branches 3.1–3.9 (Loan Status Transitions)
- Celery Workflows: [`05-celery-workflows.md`](../05-celery-workflows.md) — Loan-to-Lender Pipeline
- Runtime Data: [`03-runtime-data.md`](../03-runtime-data.md) — Section 3

---

## Common Hypotheses

| # | Hypothesis | Summary | Jump To |
|---|-----------|---------|---------|
| H1 | Loan stuck in DRAFT | Loan created via API but never transitioned to `YET_TO_BE_DISBURSED` | [Step 3](#step-3-inspect-loan-status-and-lenderloanmap) |
| H2 | Loan stuck in YET_TO_BE_DISBURSED | Loan not shared to lender or lender upload failed | [Step 4](#step-4-check-lenderloanmap-upload-status) |
| H3 | Disbursement failed (full) | Lender rejected or disbursal webhook never arrived | [Step 6](#step-6-check-disbursal-webhook-events) |
| H4 | Disbursement failed (partial) | Lender disbursed less than requested amount | [Step 7](#step-7-investigate-partial-disbursement) |
| H5 | Lender rejection | Invoice/tranche rejected by Saraloan/BlackSoil | [Step 5](#step-5-check-lender-api-failures) |
| H6 | Status transition failure (FSM) | Invalid FSM transition attempted | [Step 8](#step-8-diagnose-fsm-status-transition-failure) |
| H7 | Invoice upload failure to Saraloan/BlackSoil | Tranche or invoice creation failed at external API | [Step 5](#step-5-check-lender-api-failures) |
| H8 | Tranche creation failure | `create_tranche_in_blacksoil` returned non-201 | [Step 5](#step-5-check-lender-api-failures) |

---

## Loan Status FSM Reference

Valid transitions (source → target) defined in `loan/model/loans.py`:

| FSM Method | Source Status(es) | Target Status |
|-----------|-------------------|---------------|
| `update_status_to_yet_to_disbursed` | `DRAFT` | `YET_TO_BE_DISBURSED` |
| `update_status_to_cancelled` | `CANCELLED`, `DRAFT`, `YET_TO_BE_DISBURSED` | `CANCELLED` |
| `update_status_to_disbursed` | `YET_TO_BE_DISBURSED`, `DISBURSED` | `DISBURSED` |
| `update_status_to_rejected` | `REJECTED`, `YET_TO_BE_DISBURSED` | `REJECTED` |
| `update_loan_status_to_overdue` | `PARTIALLY_PAID`, `DISBURSED`, `OVERDUE` | `OVERDUE` |
| `update_status_to_partially_paid` | `DISBURSED`, `PARTIALLY_PAID` | `PARTIALLY_PAID` |
| `update_status_to_paid` | `PAID`, `PARTIALLY_PAID`, `OVERDUE`, `DISBURSED`, `OVERDUE_AND_PARTIALLY_PAID` | `PAID` |
| `update_status_to_overdue_and_partially_paid` | `DISBURSED`, `PARTIALLY_PAID`, `OVERDUE`, `OVERDUE_AND_PARTIALLY_PAID` | `OVERDUE_AND_PARTIALLY_PAID` |
| `update_status_to_moved_to_lender` | `OVERDUE`, `YET_TO_BE_DISBURSED`, `DISBURSED`, `MOVED_TO_LENDER`, `PARTIALLY_PAID` | `MOVED_TO_LENDER` |

---

## Step 1: Verify Customer and Credit Lines Exist

**Goal**: Confirm the customer exists and has active credit lines before investigating loan issues.

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
    'credit_limit', 'operational_limit', 'available_credit_limit',
    'lender_available_credit_limit',
    'credit_product__credit_product_name',
    'credit_product__belongs_to_gapl'
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
       cp.credit_product_name, cp.belongs_to_gapl
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Unique index on `credit_line_customer.source_identifier_id`. Expected < 10ms each.

**What to Check**:
- Does the customer exist?
- Is `is_credit_allowed = True`?
- Does at least one credit line exist with `status = ACTIVE`?
- Is there a GAPL line (`belongs_to_gapl = True`) and/or a lender line (`belongs_to_gapl = False`)?

**Decision**:
- **Customer not found** → No loans possible. Investigate onboarding.
- **`is_credit_allowed = False`** → Credit blocked. See [`credit-eligibility-playbook.md`](credit-eligibility-playbook.md) Step 2.
- **No active credit lines** → See [`credit-eligibility-playbook.md`](credit-eligibility-playbook.md) Step 3.
- **Customer and credit lines exist** → Proceed to [Step 2](#step-2-retrieve-loans-for-user).

---

## Step 2: Retrieve Loans for User

**Goal**: Get all loans for the user to identify the problematic loan(s) and their current status.

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'loan_id', 'status', 'loan_amount', 'disbursed_amount',
    'remaining_amount', 'transaction_date', 'disbursement_date',
    'invoice_overdue_date', 'creation_reason', 'comment',
    'customer_credit_line__credit_product__credit_product_name',
    'customer_credit_line__credit_product__belongs_to_gapl',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.disbursed_amount, ll.remaining_amount,
       ll.transaction_date, ll.disbursement_date,
       ll.invoice_overdue_date, ll.creation_reason, ll.comment,
       cp.credit_product_name, cp.belongs_to_gapl,
       ll.created_at, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY ll.created_at DESC;
```

**Performance**: Index on `loan_loan(customer_credit_line_id)`. Expected < 50ms.

**What to Check**:
- Which loans are in unexpected statuses (`DRAFT`, `YET_TO_BE_DISBURSED` for too long)?
- Are there `REJECTED` or `CANCELLED` loans that shouldn't be?
- Check `creation_reason`: `OVER_LIMIT` (split due to limit), `SHARE_OLDEST_LOAN_TO_LENDER` (created by move-to-lender), `INVOICE_DELETED`.
- Check `comment` for context (e.g., "Created from CRTX-xxx by Move-To-Lender").

**Decision**:
- **Loan in `DRAFT`** → Loan was created via API but not transitioned. Go to [Step 3](#step-3-inspect-loan-status-and-lenderloanmap).
- **Loan in `YET_TO_BE_DISBURSED`** → Loan not yet shared or upload pending. Go to [Step 4](#step-4-check-lenderloanmap-upload-status).
- **Loan in `REJECTED`** → Lender rejected. Go to [Step 5](#step-5-check-lender-api-failures).
- **Loan in `DISBURSED` but `disbursed_amount` is NULL or 0** → Disbursal data missing. Go to [Step 6](#step-6-check-disbursal-webhook-events).
- **Loan in `DISBURSED` but `disbursed_amount < loan_amount`** → Partial disbursement. Go to [Step 7](#step-7-investigate-partial-disbursement).
- **Unexpected status** → FSM transition issue. Go to [Step 8](#step-8-diagnose-fsm-status-transition-failure).
- **No loans found** → Loan creation failed. Go to [Step 9](#step-9-investigate-loan-creation-failure).

---

## Step 3: Inspect Loan Status and LenderLoanMap

**Goal**: For a loan stuck in `DRAFT` or `YET_TO_BE_DISBURSED`, check whether a `LenderLoanMap` was created and its upload status.

**ORM**:
```python
from loan.model import Loan, LenderLoanMap, InvoiceLoanMap

# Get the specific loan (replace {loan_id} with the CRTX-* id from Step 2)
loan = Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    loan_id='{loan_id}'
).values(
    'id', 'loan_id', 'status', 'loan_amount',
    'customer_credit_line__credit_product__credit_product_name',
    'customer_credit_line__credit_product__belongs_to_gapl',
    'created_at', 'updated_at'
).first()

# Check LenderLoanMap
lender_map = LenderLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}',
    loan__loan_id='{loan_id}'
).values(
    'id', 'invoice_upload_status', 'invoice_upload_status_desc',
    'lender_application_id', 'lender_invoice_transaction_id',
    'lender_invoice_id', 'lender_invoice_doc_id',
    'invoice_upload_date', 'invoice_status_at_lender',
    'created_at', 'updated_at'
).first()

# Check InvoiceLoanMap
invoices = InvoiceLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}',
    loan__loan_id='{loan_id}'
).values(
    'id', 'invoice_id', 'invoice_internal_id', 'invoice_id_at_lender',
    'invoice_amount', 'disbursement_amount', 'delivery_date', 'source'
)
```

**SQL**:
```sql
-- Loan details
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       cp.credit_product_name, cp.belongs_to_gapl,
       ll.created_at, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.loan_id = '{loan_id}';

-- LenderLoanMap
SELECT llm.id, llm.invoice_upload_status, llm.invoice_upload_status_desc,
       llm.lender_application_id, llm.lender_invoice_transaction_id,
       llm.lender_invoice_id, llm.lender_invoice_doc_id,
       llm.invoice_upload_date, llm.invoice_status_at_lender,
       llm.created_at, llm.updated_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.loan_id = '{loan_id}';

-- InvoiceLoanMap
SELECT ilm.id, ilm.invoice_id, ilm.invoice_internal_id,
       ilm.invoice_id_at_lender, ilm.invoice_amount,
       ilm.disbursement_amount, ilm.delivery_date, ilm.source
FROM loan_invoiceloanmap ilm
JOIN loan_loan ll ON ilm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.loan_id = '{loan_id}';
```

**Performance**: Index on `loan_lenderloanmap(loan_id)`, `loan_invoiceloanmap(loan_id)`. Expected < 10ms each.

**What to Check**:
- **Loan in `DRAFT`**: Was the loan created via API (`loan/utility.py:create_loan`)? API-created loans start as `DRAFT`. The `post_save` signal should trigger subvention/overdue date computation. If stuck, the `InvoiceLoanMap` creation or signal may have failed.
- **No `LenderLoanMap`**: The loan has not been prepared for lender sharing. Either `prepare_loan_to_send_to_saraloan()` was never called, or the loan is on a GAPL line (GAPL loans don't need `LenderLoanMap` until shared).
- **`LenderLoanMap` exists**: Check `invoice_upload_status` — this is the key field.

**Decision**:
- **Loan is `DRAFT`, no `InvoiceLoanMap`** → Invoice-loan mapping failed during creation. Check Celery task logs for `create_loan_in_bulk` errors. Go to [Step 9](#step-9-investigate-loan-creation-failure).
- **Loan is `DRAFT`, `InvoiceLoanMap` exists** → FSM transition from `DRAFT` → `YET_TO_BE_DISBURSED` was never called. This happens via `update_status_to_yet_to_disbursed()`. Check if bulk upload used correct status.
- **No `LenderLoanMap`** → Loan not yet shared to lender. Go to [Step 4](#step-4-check-lenderloanmap-upload-status).
- **`LenderLoanMap` exists** → Go to [Step 4](#step-4-check-lenderloanmap-upload-status) to check upload status.

---

## Step 4: Check LenderLoanMap Upload Status

**Goal**: Determine where the loan-to-lender pipeline stalled by inspecting the `invoice_upload_status` on `LenderLoanMap`.

> The upload pipeline is: `YET_TO_UPLOAD` → `PARTNER_FOUND` → `TRANSACTION_CREATED` → `INVOICE_UPLOADED`
> Failure statuses: `PARTNER_NOT_FOUND`, `APPLICATION_NOT_FOUND`, `TRANSACTION_CREATION_FAILED`, `INVOICE_UPLOAD_FAILED`, `MANUAL_UPDATE_REQUIRED`, `SUBVENTION_UPDATE_FAILED`

**ORM**:
```python
from loan.model import LenderLoanMap

LenderLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'loan__loan_id', 'invoice_upload_status',
    'invoice_upload_status_desc', 'lender_application_id',
    'lender_invoice_transaction_id', 'lender_invoice_id',
    'invoice_status_at_lender', 'invoice_upload_date',
    'is_invoice_subvented', 'subvention_days_shared',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT llm.id, ll.loan_id, llm.invoice_upload_status,
       llm.invoice_upload_status_desc, llm.lender_application_id,
       llm.lender_invoice_transaction_id, llm.lender_invoice_id,
       llm.invoice_status_at_lender, llm.invoice_upload_date,
       llm.is_invoice_subvented, llm.subvention_days_shared,
       llm.created_at, llm.updated_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY llm.created_at DESC;
```

**Performance**: Index on `loan_lenderloanmap(invoice_upload_status)`. Expected < 20ms.

**What to Check**:
- `invoice_upload_status` — which stage did the pipeline reach?
- `invoice_upload_status_desc` — error message from the lender API.
- `lender_application_id` — was the Saraloan application resolved?
- `lender_invoice_transaction_id` — was the tranche created?
- `lender_invoice_id` — was the invoice uploaded?

**Decision by `invoice_upload_status`**:

| Status | Meaning | Next Step |
|--------|---------|-----------|
| `YET_TO_UPLOAD` | `prepare_loan_to_send_to_saraloan` created the map but `send_invoice_to_saraloan` hasn't run | Check Celery task queue. Go to [Step 5a](#step-5a-check-celery-task-execution). |
| `PARTNER_FOUND` | Application ID resolved, waiting for tranche creation | `create_tranche_in_blacksoil` hasn't completed. Go to [Step 5](#step-5-check-lender-api-failures). |
| `TRANSACTION_CREATED` | Tranche created, waiting for invoice upload | `create_invoice_in_blacksoil` hasn't completed. Go to [Step 5](#step-5-check-lender-api-failures). |
| `INVOICE_UPLOADED` | Successfully uploaded to lender. Waiting for lender approval/disbursal webhook. | Go to [Step 6](#step-6-check-disbursal-webhook-events). |
| `PARTNER_NOT_FOUND` | **H7**: `send_invoice_to_saraloan` failed — exception during partner lookup | Go to [Step 5](#step-5-check-lender-api-failures). |
| `APPLICATION_NOT_FOUND` | **H7**: No Saraloan application ID for this customer/product | Go to [Step 5](#step-5-check-lender-api-failures). |
| `TRANSACTION_CREATION_FAILED` | **H8**: `create_tranche_in_blacksoil` got non-201 from Saraloan API | Go to [Step 5](#step-5-check-lender-api-failures). |
| `INVOICE_UPLOAD_FAILED` | **H7**: `create_invoice_in_blacksoil` failed at Saraloan API | Go to [Step 5](#step-5-check-lender-api-failures). |
| `MANUAL_UPDATE_REQUIRED` | Saraloan returned HTTP 400 — needs manual intervention | Check `invoice_upload_status_desc` for details. |
| `SUBVENTION_UPDATE_FAILED` | `update_subvention_details_in_saraloan` failed | Go to [Step 5](#step-5-check-lender-api-failures). |
| `CANCELLED` | Upload was cancelled | Check if loan was also cancelled. |

---

## Step 5: Check Lender API Failures

**Goal**: Investigate why the invoice upload to Saraloan/BlackSoil failed. Check `CustomerLenderMap` for application ID, and review Celery task results for the upload tasks.

### Step 5a: Check Celery Task Execution

**ORM**:
```python
from django_celery_results.models import TaskResult

# Check send_invoice_to_saraloan tasks
TaskResult.objects.filter(
    task_name__in=[
        'loan.tasks.send_invoice_to_saraloan',
        'loan.tasks.create_tranche_in_blacksoil',
        'loan.tasks.create_invoice_in_blacksoil',
        'loan.tasks.prepare_loan_to_send_to_saraloan',
        'loan.tasks.update_subvention_details_in_saraloan',
        'loan.tasks.share_oldest_loan_to_lender',
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
    'loan.tasks.send_invoice_to_saraloan',
    'loan.tasks.create_tranche_in_blacksoil',
    'loan.tasks.create_invoice_in_blacksoil',
    'loan.tasks.prepare_loan_to_send_to_saraloan',
    'loan.tasks.update_subvention_details_in_saraloan',
    'loan.tasks.share_oldest_loan_to_lender'
)
AND task_args LIKE '%{user_id}%'
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: Index on `django_celery_results_taskresult(task_name)`. Expected < 100ms. **Warning**: `task_args LIKE` may be slow on large tables; always include date filter.

**What to Check**:
- Did the task run at all? If no results, the task was never dispatched.
- Task `status`: `SUCCESS`, `FAILURE`, `PENDING`, `STARTED`, `RETRY`.
- If `FAILURE`: check `traceback` for the exception.
- If `SUCCESS` but upload still failed: check `result` for error messages like "Application id not found" or "Invoice Upload failed".

### Step 5b: Check CustomerLenderMap (Application ID)

**ORM**:
```python
from credit_line.model import CustomerLenderMap

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

**What to Check**:
- Does a `CustomerLenderMap` entry exist for the lender credit product?
- Is `application_id` populated? This is required by `send_invoice_to_saraloan()` (`loan/tasks.py:465`). If missing, the task sets `invoice_upload_status = APPLICATION_NOT_FOUND`.
- Is `business_id` populated? Required for Saraloan API calls.

### Step 5c: Check External Webhook Logs

**ORM**:
```python
from external.models import ExternalWebhook

ExternalWebhook.objects.filter(
    created_at__gte='{start_date}'
).order_by('-created_at')[:20]
```

**SQL**:
```sql
SELECT id, created_at, request_body, response_body
FROM external_externalwebhook
WHERE created_at >= NOW() - INTERVAL '7 days'
ORDER BY created_at DESC
LIMIT 20;
```

**Performance**: Expected < 50ms with date filter. **Warning**: No user_id index on this table; filter by date range.

**Decision**:
- **`APPLICATION_NOT_FOUND`** → **H7 confirmed**. `CustomerLenderMap.application_id` is missing. The `sync_partner_ids_from_saraloan()` call also failed. Check Saraloan onboarding for this customer.
- **`PARTNER_NOT_FOUND`** → **H7 confirmed**. Exception during `send_invoice_to_saraloan`. Check Celery task traceback.
- **`TRANSACTION_CREATION_FAILED`** → **H8 confirmed**. `Saraloan.create_invoice_tranche()` returned non-201. Check `invoice_upload_status_desc` for the API error message.
- **`INVOICE_UPLOAD_FAILED`** → **H7 confirmed**. `Saraloan.send_invoice()` failed. Check `invoice_upload_status_desc`. Common causes: invoice copy fetch failed from ERP, Saraloan API error.
- **`MANUAL_UPDATE_REQUIRED`** → Saraloan returned HTTP 400. Requires manual fix in Saraloan portal.
- **`SUBVENTION_UPDATE_FAILED`** → `update_subvention_details_in_saraloan` failed. Check if customer is eligible for subvention (`interest_subvention_enabled` on credit product, `is_customer_eligible_for_subvention()`).
- **Task never ran** → Check if `share_oldest_loan_to_lender` was dispatched. Verify the partner is in the eligible list (`get_loan_sharable_partner_ids()`). Go to [Step 5d](#step-5d-check-share-eligibility).

### Step 5d: Check Share Eligibility

**ORM**:
```python
from credit_line.model import CustomerCreditLine

# Check if partner has an active lender line
lender_line = CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}',
    credit_product__belongs_to_gapl=False,
    customer__external_lender_supported=True
).values(
    'id', 'status', 'lender_advance_payment',
    'credit_product__credit_product_name',
    'customer__customer_type__name'
).first()
```

**SQL**:
```sql
SELECT ccl.id, ccl.status, ccl.lender_advance_payment,
       cp.credit_product_name, ct.name AS customer_type
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = false
  AND c.external_lender_supported = true;
```

**Performance**: Expected < 10ms.

**What to Check**:
- The `share_oldest_loan_to_lender` task (`loan/tasks.py:1671`) requires:
  - A lender credit line with `belongs_to_gapl = False`
  - `customer.external_lender_supported = True`
  - For FARMER: status `ACTIVE` or `ONHOLD`
  - For DC: status `ACTIVE`, or `ONHOLD` with `lender_advance_payment > 0`
- Also checks `is_invoice_share_restricted(partner_id)` — a Redis-based restriction flag.

**Decision**:
- **No lender line found** → Partner cannot share loans to lender. Loans stay on GAPL line.
- **Lender line exists but status is `DORMANT`** → Lender line is closed. No sharing possible.
- **All conditions met** → The task should have run. Check if the daily cron `share_oldest_loan_to_lender_for_all_partners` (03:00) included this partner. Verify via Celery task results.

---

## Step 6: Check Disbursal Webhook Events

**Goal**: For loans with `invoice_upload_status = INVOICE_UPLOADED` but still in `YET_TO_BE_DISBURSED`, verify whether the lender disbursal webhook was received and processed.

> The disbursal webhook is processed by `credit_line/tasks.py:process_saraloan_loan_webhook()` which calls `process_disbursal_event()`.

**ORM**:
```python
from loan.model import LenderLoanMap

# Get the lender_invoice_id (topup_id) for webhook correlation
LenderLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}',
    invoice_upload_status='INVOICE_UPLOADED'
).values(
    'id', 'loan__loan_id', 'lender_invoice_id',
    'lender_invoice_transaction_id', 'invoice_status_at_lender',
    'invoice_upload_date', 'updated_at'
)
```

**SQL**:
```sql
-- Get uploaded invoices awaiting disbursal
SELECT llm.id, ll.loan_id, llm.lender_invoice_id,
       llm.lender_invoice_transaction_id,
       llm.invoice_status_at_lender,
       llm.invoice_upload_date, llm.updated_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND llm.invoice_upload_status = 'INVOICE_UPLOADED';

-- Check webhook processing tasks
SELECT task_name, status, result, traceback,
       date_created, date_done
FROM django_celery_results_taskresult
WHERE task_name = 'credit_line.tasks.process_saraloan_loan_webhook'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 10;
```

**Performance**: Index on `loan_lenderloanmap(invoice_upload_status)`. Expected < 20ms. Celery query: < 100ms with date filter.

**What to Check**:
- `invoice_status_at_lender`: Was it updated from `Pending` to another value?
- `invoice_upload_date`: How long ago was the invoice uploaded? Lender approval typically takes minutes to hours.
- Did `process_saraloan_loan_webhook` run? Check Celery task results.
- The webhook matches on `topup_id` = `lender_invoice_id` (`credit_line/tasks.py:1268`).

**Decision**:
- **`invoice_status_at_lender` is still `Pending`** → **H3 confirmed** (variant). Lender hasn't processed the invoice yet. If it's been more than 24 hours, escalate to lender operations.
- **Webhook task ran with `FAILURE`** → **H3 confirmed**. Check traceback. Common issues: `interest_discrepancy` detected in `fetch_account_detail_and_validate_interest_component()`, or Saraloan API error in `get_withdrawal_requests_for_invoice_id()`.
- **Webhook task ran with `SUCCESS` but loan still `YET_TO_BE_DISBURSED`** → The `process_loan_saraloan()` call may have failed silently. Check if `process_full_disbursal()` or `process_partial_disbursal()` was called. Go to [Step 7](#step-7-investigate-partial-disbursement).
- **No webhook task found** → Webhook was never received from lender. Check `external_externalwebhook` table for recent webhook entries. Escalate to lender.

---

## Step 7: Investigate Partial Disbursement

**Goal**: When the lender disburses less than the requested loan amount, the system processes a partial disbursement. This creates a new loan for the disbursed amount and rejects the original.

> Partial disbursement logic: `credit_line/tasks.py:process_disbursal_event()` at line 1541.
> Condition: `disbursement_amount < invoice_requested_amount (loan_amount)`

**ORM**:
```python
from loan.model import Loan

# Find all loans for the user, including rejected ones from partial disbursal
Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).filter(
    status__in=['REJECTED', 'DISBURSED', 'YET_TO_BE_DISBURSED']
).values(
    'id', 'loan_id', 'status', 'loan_amount', 'disbursed_amount',
    'approved_amt', 'rejected_amt', 'remaining_amount',
    'lender_reference_loan_number', 'comment',
    'disbursement_date', 'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.disbursed_amount, ll.approved_amt, ll.rejected_amt,
       ll.remaining_amount, ll.lender_reference_loan_number,
       ll.comment, ll.disbursement_date,
       ll.created_at, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status IN ('REJECTED', 'DISBURSED', 'YET_TO_BE_DISBURSED')
ORDER BY ll.created_at DESC;
```

**Performance**: Index on `loan_loan(customer_credit_line_id, status)`. Expected < 20ms.

**What to Check**:
- Look for a `REJECTED` loan with `comment` containing "Rejected because of Partial Disbursal by Lender".
- A new loan should have been created with `loan_amount = disbursement_amount` and `comment` like "Created against CRTX-xxx".
- For DC customers: partial disbursal creates a new loan + rejects original. For non-DC (FARMER): partial disbursal returns `False` without processing (see `process_disbursal_event()` line 1595).

**Decision**:
- **`REJECTED` loan with partial disbursal comment found** → **H4 confirmed**. Partial disbursement was processed. Check if the new loan was created correctly.
- **FARMER customer with partial disbursal** → **H4 confirmed** (variant). The system does not process partial disbursals for farmers. The disbursal event returns `False`. Manual intervention required.
- **No partial disbursal evidence** → The disbursal amount matched the loan amount. If loan is still not `DISBURSED`, check `process_full_disbursal()` execution. Go to [Step 6](#step-6-check-disbursal-webhook-events).
- **Redis lock blocked processing** → `check_or_add_redis_cache_common(BLACKSOIL_DISBURSAL, lender_loan_id)` may have returned `True` (lock already held). Check if a concurrent disbursal event was being processed.

---

## Step 8: Diagnose FSM Status Transition Failure

**Goal**: When a loan status transition fails, it's because the FSM (`django-fsm`) rejected the transition. The valid transitions are defined in `loan/model/loans.py`.

> Status transitions are validated by `loan/utility.py:check_for_valid_status_transition()` which calls the appropriate FSM method. Invalid transitions raise `TransitionNotAllowed`.

**ORM**:
```python
from loan.model import Loan

# Get current loan status
loan = Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    loan_id='{loan_id}'
).values(
    'id', 'loan_id', 'status', 'updated_at'
).first()
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.loan_id = '{loan_id}';
```

**Performance**: Expected < 10ms.

**What to Check**:
- Current `status` of the loan.
- What transition was attempted? Check Celery task logs or API error responses.
- Cross-reference with the [FSM Reference table](#loan-status-fsm-reference) above.

**Common Invalid Transitions**:

| Attempted Transition | Current Status | Why It Fails |
|---------------------|---------------|--------------|
| `DRAFT` → `DISBURSED` | `DRAFT` | Must go through `YET_TO_BE_DISBURSED` first |
| `CANCELLED` → `DISBURSED` | `CANCELLED` | `CANCELLED` can only transition to `CANCELLED` (idempotent) |
| `REJECTED` → `DISBURSED` | `REJECTED` | `REJECTED` can only transition to `REJECTED` (idempotent) |
| `PAID` → `OVERDUE` | `PAID` | `PAID` is a terminal state for overdue transitions |
| `DRAFT` → `DISBURSED` | `DRAFT` | Skips `YET_TO_BE_DISBURSED` |

**Check Loan History** (if `django-simple-history` is enabled):

```sql
SELECT h.history_date, h.status, h.history_type,
       au.username AS changed_by
FROM loan_historicalloan h
LEFT JOIN auth_user au ON h.history_user_id = au.id
WHERE h.loan_id = '{loan_id}'
ORDER BY h.history_date DESC
LIMIT 20;
```

**Performance**: Expected < 50ms. **Warning**: History tables can be large; always use `LIMIT`.

**Decision**:
- **Invalid transition attempted** → **H6 confirmed**. The code path attempted a transition not allowed by the FSM. Check which task/view triggered it.
- **Status was changed by admin upload** → Check `history_user` for manual changes. The `UPDATE_TRANSACTION` upload action can set loan status directly.
- **Concurrent status change** → Two processes may have changed the status simultaneously. Check timestamps in history for rapid successive changes.

---

## Step 9: Investigate Loan Creation Failure

**Goal**: When no loans exist for a user (or expected loans are missing), investigate why loan creation failed.

### Step 9a: Check API-Based Loan Creation

**ORM**:
```python
from django_celery_results.models import TaskResult

# Check if create_loan_in_bulk was called
TaskResult.objects.filter(
    task_name='loan.tasks.create_loan_in_bulk',
    task_args__contains='{user_id}'
).values(
    'task_name', 'status', 'result', 'traceback',
    'date_created', 'date_done'
).order_by('-date_done')[:10]
```

**SQL**:
```sql
SELECT task_name, status, result, traceback,
       date_created, date_done
FROM django_celery_results_taskresult
WHERE task_name = 'loan.tasks.create_loan_in_bulk'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 10;
```

**Performance**: Index on `task_name`. Expected < 100ms with date filter.

### Step 9b: Check for Duplicate Invoice Guard

The `create_loan()` function (`loan/utility.py:2205`) checks for existing loans on the same invoices before creating new ones.

**ORM**:
```python
from loan.model import InvoiceLoanMap

# Check if invoices already have loans
InvoiceLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}'
).exclude(
    loan__status__in=['REJECTED', 'CANCELLED']
).values(
    'invoice_id', 'invoice_internal_id', 'loan__loan_id',
    'loan__status', 'loan__loan_amount'
).order_by('-loan__created_at')
```

**SQL**:
```sql
SELECT ilm.invoice_id, ilm.invoice_internal_id,
       ll.loan_id, ll.status, ll.loan_amount
FROM loan_invoiceloanmap ilm
JOIN loan_loan ll ON ilm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status NOT IN ('REJECTED', 'CANCELLED')
ORDER BY ll.created_at DESC;
```

**Performance**: Expected < 50ms.

### Step 9c: Check Credit Line Available Limit

Loan creation via API calls `generate_loan_breakup_for_customer()` which splits the loan across credit lines. If no breakup is possible (no available limit), the function returns `False`.

**SQL**:
```sql
SELECT ccl.id, ccl.available_credit_limit, ccl.operational_limit,
       ccl.credit_limit, ccl.outstanding_amount,
       cp.credit_product_name, cp.belongs_to_gapl
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND ccl.status = 'ACTIVE';
```

**Performance**: Expected < 10ms.

**What to Check**:
- Is `available_credit_limit > 0` on any active credit line?
- Does the sum of available limits cover the requested loan amount?

**Decision**:
- **Celery task `create_loan_in_bulk` failed** → Check traceback. Common errors: `fetch_cust_cl_by_source_n_product` returned `None` (no credit line for product), `check_for_existing_invoices` raised (duplicate invoices), serializer validation error.
- **Duplicate invoice guard triggered** → Loans already exist for these invoices. The `check_if_loan_exist_for_invoices()` or `check_if_loan_creation_from_invoice_already_running()` (Redis lock) blocked creation.
- **No available credit limit** → `generate_loan_breakup_for_customer()` returned `False`. See [`credit-eligibility-playbook.md`](credit-eligibility-playbook.md) for limit investigation.
- **API returned error** → Check Django request logs for the `POST /loan/` endpoint. The `CreateLoanRequestSerializer` may have rejected the payload.

---

## Step 10: Verify Loan-to-Lender Pipeline End-to-End

**Goal**: For a complete end-to-end check of the loan sharing pipeline, verify all stages from GAPL loan through lender upload.

**SQL** (comprehensive pipeline status query):
```sql
SELECT ll.loan_id, ll.status AS loan_status, ll.loan_amount,
       ll.disbursed_amount, ll.creation_reason, ll.comment,
       cp.credit_product_name, cp.belongs_to_gapl,
       llm.id AS llm_id, llm.invoice_upload_status,
       llm.invoice_upload_status_desc,
       llm.lender_application_id,
       llm.lender_invoice_id,
       llm.invoice_status_at_lender,
       llm.invoice_upload_date,
       llm.created_at AS llm_created_at,
       llm.updated_at AS llm_updated_at,
       ll.created_at AS loan_created_at,
       ll.updated_at AS loan_updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
LEFT JOIN loan_lenderloanmap llm ON llm.loan_id = ll.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY ll.created_at DESC;
```

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).select_related(
    'customer_credit_line__credit_product',
    'partner_lender_invoice_map'
).values(
    'loan_id', 'status', 'loan_amount', 'disbursed_amount',
    'creation_reason', 'comment',
    'customer_credit_line__credit_product__credit_product_name',
    'customer_credit_line__credit_product__belongs_to_gapl',
    'partner_lender_invoice_map__id',
    'partner_lender_invoice_map__invoice_upload_status',
    'partner_lender_invoice_map__invoice_upload_status_desc',
    'partner_lender_invoice_map__lender_application_id',
    'partner_lender_invoice_map__lender_invoice_id',
    'partner_lender_invoice_map__invoice_status_at_lender',
    'partner_lender_invoice_map__invoice_upload_date',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**Performance**: LEFT JOIN on `loan_lenderloanmap(loan_id)`. Expected < 50ms.

**What to Check**:
- For each loan, trace the pipeline:
  1. Loan created on GAPL line (`belongs_to_gapl = True`) → status should progress from `DRAFT`/`YET_TO_BE_DISBURSED` → `DISBURSED` (on GAPL) or `MOVED_TO_LENDER`/`CANCELLED` (if shared).
  2. Loan on lender line (`belongs_to_gapl = False`) → should have a `LenderLoanMap` entry.
  3. `LenderLoanMap` should progress: `YET_TO_UPLOAD` → `PARTNER_FOUND` → `TRANSACTION_CREATED` → `INVOICE_UPLOADED`.
  4. After lender approval: loan status → `DISBURSED`.
- Look for orphaned `LenderLoanMap` entries (upload started but loan status unchanged).
- Look for loans with `creation_reason = SHARE_OLDEST_LOAN_TO_LENDER` — these were created by the move-to-lender pipeline.

---

## Quick Reference: LenderLoanMap Upload Status Pipeline

```
YET_TO_UPLOAD ──→ PARTNER_FOUND ──→ TRANSACTION_CREATED ──→ INVOICE_UPLOADED
     │                  │                    │                      │
     │                  │                    │                      └─→ (await lender webhook)
     │                  │                    │
     │                  │                    └─→ SUBVENTION_UPDATED ──→ INVOICE_UPLOADED
     │                  │                              │
     │                  │                              └─→ SUBVENTION_UPDATE_FAILED
     │                  │
     │                  └─→ TRANSACTION_CREATION_FAILED
     │
     ├─→ PARTNER_NOT_FOUND
     ├─→ APPLICATION_NOT_FOUND
     └─→ INVOICE_UPLOAD_FAILED / MANUAL_UPDATE_REQUIRED
```

## Quick Reference: Loan Lifecycle Pipeline

```
API POST /loan/                    Bulk Upload (file)
       │                                  │
       ▼                                  ▼
  create_loan()                  create_loan_in_bulk()
  (status: DRAFT)                (status: YET_TO_BE_DISBURSED)
       │                                  │
       ▼                                  ▼
  InvoiceLoanMap created          InvoiceLoanMap created
       │                                  │
       └──────────┬───────────────────────┘
                  ▼
  share_oldest_loan_to_lender (daily cron 03:00)
                  │
                  ▼
  prepare_loan_to_send_to_saraloan
  (creates LenderLoanMap, status: YET_TO_UPLOAD)
                  │
                  ▼
  send_invoice_to_saraloan
  (resolves application_id, status: PARTNER_FOUND)
                  │
                  ▼
  create_tranche_in_blacksoil
  (creates tranche, status: TRANSACTION_CREATED)
                  │
          ┌───────┴────────┐
          ▼                ▼
  (subvention)    create_invoice_in_blacksoil
          │        (uploads invoice, status: INVOICE_UPLOADED)
          ▼                │
  update_subvention        │
          │                │
          └───────┬────────┘
                  ▼
  Lender processes invoice (external)
                  │
                  ▼
  Webhook: process_saraloan_loan_webhook
                  │
          ┌───────┴────────┐
          ▼                ▼
  Full Disbursal    Partial Disbursal
  (loan → DISBURSED)  (original → REJECTED,
                       new loan → DISBURSED)
```
