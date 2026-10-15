# Hypothesis Validation Framework

> For each user flow, this document lists common failure hypotheses with required evidence, verification queries (ORM + SQL), and expected results that confirm or refute each hypothesis.
> All queries are **read-only** (`SELECT` only) and accept `{user_id}` (`source_identifier_id` / `partner_id`) as input.

**Cross-references**:
- Playbooks: [`06-playbooks/`](06-playbooks/)
- Decision Logic: [`04-decision-logic.md`](04-decision-logic.md)
- User Flows: [`02-user-flows/`](02-user-flows/)
- Runtime Data: [`03-runtime-data.md`](03-runtime-data.md)

---

## Table of Contents

1. [Credit Eligibility Hypotheses](#1-credit-eligibility)
2. [Credit Limit Calculation Hypotheses](#2-credit-limit-calculation)
3. [Approval Workflow Hypotheses](#3-approval-workflow)
4. [Repayment Workflow Hypotheses](#4-repayment-workflow)
5. [Risk Evaluation Hypotheses](#5-risk-evaluation)

---

## 1. Credit Eligibility

**Flow**: [`02-user-flows/credit-eligibility.md`](02-user-flows/credit-eligibility.md)
**Playbook**: [`06-playbooks/credit-eligibility-playbook.md`](06-playbooks/credit-eligibility-playbook.md)

### Hypothesis 1.1: Credit Globally Blocked (`is_credit_allowed = False`)

**Description**: The customer's `is_credit_allowed` flag is `False`, blocking all credit operations regardless of credit line status.

**Required Evidence**:
- `Customer.is_credit_allowed` value
- History of `is_credit_allowed` changes (who changed it and when)

**Verification Query**:

**ORM**:
```python
from credit_line.model import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'is_credit_allowed', 'external_lender_supported',
    'lender_supported_status'
)
```

**SQL**:
```sql
SELECT c.id, c.is_credit_allowed, c.external_lender_supported,
       c.lender_supported_status
FROM credit_line_customer c
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Unique index on `credit_line_customer.source_identifier_id`. Expected < 10ms.

**Confirms**: `is_credit_allowed = False`. Credit is blocked at the customer level. Verify who changed it:
```sql
SELECT h.history_date, h.is_credit_allowed, au.username
FROM credit_line_historicalcustomer h
LEFT JOIN auth_user au ON h.history_user_id = au.id
WHERE h.source_identifier_id = '{user_id}'
  AND h.history_date >= NOW() - INTERVAL '30 days'
ORDER BY h.history_date DESC LIMIT 10;
```

**Refutes**: `is_credit_allowed = True`. The flag is not the cause; investigate credit line status or limits.

---

### Hypothesis 1.2: Credit Line Inactive or On Hold

**Description**: The customer's credit line has `status = ONHOLD` or `DORMANT`, preventing new credit operations.

**Required Evidence**:
- `CustomerCreditLine.status` and `sub_status` for all credit lines
- `business_override` flag (if `True`, automated holds are bypassed)

**Verification Query**:

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'sub_status', 'business_override',
    'lender_status', 'lender_stress_case',
    'credit_product__credit_product_name',
    'credit_product__belongs_to_gapl'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.status, ccl.sub_status, ccl.business_override,
       ccl.lender_status, ccl.lender_stress_case,
       cp.credit_product_name, cp.belongs_to_gapl
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 20ms.

**Confirms**: Any credit line with `status IN ('ONHOLD', 'DORMANT')`. Check `sub_status` for the reason:
- `AGED OUTSTANDING` → overdue threshold breach (see [Hypothesis 5.1](#hypothesis-51-aged-outstanding-threshold-breach))
- `REPAYMENT FREQUENCY` → repayment frequency breach (see [Hypothesis 5.2](#hypothesis-52-repayment-frequency-breach))
- `ONBOARDING POD` → manual hold during onboarding
- `MISCELLANEOUS` → manual hold by operations
- `OUTSTANDING REMAINING` → dormant with remaining balance
- `CLOSED` → fully closed

**Refutes**: All credit lines have `status = ACTIVE` and `sub_status = ACTIVE`.

---

### Hypothesis 1.3: Credit Product Mismatch or Missing

**Description**: No credit line exists for the expected credit product, or the product is misconfigured.

**Required Evidence**:
- List of credit lines with their credit product names
- Whether a GAPL line exists (`belongs_to_gapl = True`)
- Whether a lender line exists when `external_lender_supported = True`

**Verification Query**:

**ORM**:
```python
from credit_line.model import Customer, CustomerCreditLine

customer = Customer.objects.filter(
    source_identifier_id='{user_id}'
).values('external_lender_supported', 'customer_type__name').first()

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'credit_product__credit_product_name',
    'credit_product__belongs_to_gapl',
    'credit_product__lender__name',
    'status', 'effective_from', 'effective_to'
)
```

**SQL**:
```sql
SELECT c.external_lender_supported, ct.name AS customer_type
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';

SELECT ccl.id, cp.credit_product_name, cp.belongs_to_gapl,
       l.name AS lender_name, ccl.status,
       ccl.effective_from, ccl.effective_to
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
JOIN credit_line_lender l ON ccl.lender_id = l.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Expected < 10ms each.

**Confirms**: No GAPL line exists, or `external_lender_supported = True` but no lender line (`belongs_to_gapl = False`) is present.

**Refutes**: Both GAPL and lender lines exist as expected for the customer type.

---

### Hypothesis 1.4: Lender Limit Exhausted

**Description**: The lender's available credit limit is 0 or negative, preventing new loan sharing to the lender.

**Required Evidence**:
- `lender_available_credit_limit` on the lender credit line
- `lender_status` (ACTIVE, INACTIVE, OVERDUE)
- Last Saraloan sync timestamp

**Verification Query**:

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}',
    credit_product__belongs_to_gapl=False
).values(
    'id', 'credit_limit', 'lender_available_credit_limit',
    'lender_outstanding_amount', 'lender_advance_payment',
    'lender_status', 'principal_outstanding',
    'credit_product__credit_product_name', 'updated_at'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.credit_limit, ccl.lender_available_credit_limit,
       ccl.lender_outstanding_amount, ccl.lender_advance_payment,
       ccl.lender_status, ccl.principal_outstanding,
       cp.credit_product_name, ccl.updated_at
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = false;
```

**Performance**: Index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 10ms.

**Confirms**: `lender_available_credit_limit <= 0` or `lender_status IN ('INACTIVE', 'OVERDUE')`.

**Refutes**: `lender_available_credit_limit > 0` and `lender_status = 'ACTIVE'`.

---

### Hypothesis 1.5: Operational Limit Capped Too Low

**Description**: The `operational_limit` is set to 0 or a very low value, effectively blocking credit even though `credit_limit` is adequate.

**Required Evidence**:
- `operational_limit` vs `credit_limit` comparison
- History of operational limit changes

**Verification Query**:

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'credit_limit', 'operational_limit',
    'available_credit_limit',
    'credit_product__credit_product_name'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.credit_limit, ccl.operational_limit,
       ccl.available_credit_limit, cp.credit_product_name,
       CASE WHEN ccl.operational_limit < ccl.credit_limit * 0.1
            THEN 'ANOMALY: operational_limit < 10% of credit_limit'
            WHEN ccl.operational_limit = 0
            THEN 'ANOMALY: operational_limit is zero'
            ELSE 'OK'
       END AS check_result
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Expected < 10ms.

**Confirms**: `operational_limit` is 0 or significantly lower than `credit_limit`. Verify via history:
```sql
SELECT h.history_date, h.operational_limit, h.credit_limit, au.username
FROM credit_line_historicalcustomercreditline h
LEFT JOIN auth_user au ON h.history_user_id = au.id
WHERE h.customer_id = (
    SELECT id FROM credit_line_customer WHERE source_identifier_id = '{user_id}'
)
ORDER BY h.history_date DESC LIMIT 20;
```

**Refutes**: `operational_limit` is close to or equal to `credit_limit`.

---

### Hypothesis 1.6: External Lender Not Supported

**Description**: `Customer.external_lender_supported` is `False` when a lender credit line is expected, preventing lender-side operations.

**Required Evidence**:
- `Customer.external_lender_supported` value
- `Customer.lender_supported_status` for onboarding state

**Verification Query**:

**ORM**:
```python
from credit_line.model import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'external_lender_supported', 'lender_supported_status',
    'customer_type__name'
)
```

**SQL**:
```sql
SELECT c.id, c.external_lender_supported, c.lender_supported_status,
       ct.name AS customer_type
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Expected < 10ms.

**Confirms**: `external_lender_supported = False` when the customer is expected to have lender financing.

**Refutes**: `external_lender_supported = True`.

---

## 2. Credit Limit Calculation

**Flow**: [`02-user-flows/credit-limit-calculation.md`](02-user-flows/credit-limit-calculation.md)
**Playbook**: [`06-playbooks/credit-eligibility-playbook.md`](06-playbooks/credit-eligibility-playbook.md) (Steps 5–6)


### Hypothesis 2.1: Saraloan Sync Failed to Update Credit Limit

**Description**: The daily Saraloan sync (`sync_credit_lines_info_from_saraloan`, 22:00) failed or did not run, leaving `credit_limit` and `lender_available_credit_limit` stale.

**Required Evidence**:
- `CustomerCreditLine.updated_at` timestamp (is it recent?)
- Celery task results for sync tasks
- `CustomerLenderMap` existence with valid `business_id` and `loan_account_id`

**Verification Query**:

**ORM**:
```python
from credit_line.model import CustomerCreditLine, CustomerLenderMap
from django_celery_results.models import TaskResult

# Check staleness
CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}',
    credit_product__belongs_to_gapl=False
).values('id', 'credit_limit', 'lender_available_credit_limit', 'updated_at')

# Check lender map
CustomerLenderMap.objects.filter(
    customer__source_identifier_id='{user_id}'
).values('id', 'business_id', 'loan_account_id', 'application_id')

# Check task results
TaskResult.objects.filter(
    task_name__in=[
        'credit_line.tasks.sync_credit_line_info_from_saraloan',
        'credit_line.tasks.fetch_and_update_credit_line_info',
    ],
    task_args__contains='{user_id}'
).values('task_name', 'status', 'date_done', 'traceback').order_by('-date_done')[:5]
```

**SQL**:
```sql
-- Check credit line freshness
SELECT ccl.id, ccl.credit_limit, ccl.lender_available_credit_limit,
       ccl.updated_at, cp.credit_product_name
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = false;

-- Check lender map
SELECT clm.id, clm.business_id, clm.loan_account_id, clm.application_id
FROM credit_line_customerlendermap clm
JOIN credit_line_customer c ON clm.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';

-- Check sync task results
SELECT task_name, status, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'credit_line.tasks.sync_credit_line_info_from_saraloan',
    'credit_line.tasks.fetch_and_update_credit_line_info'
)
AND task_args LIKE '%{user_id}%'
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC LIMIT 5;
```

**Performance**: Expected < 10ms for credit line queries. Celery query: < 100ms with date filter. **Warning**: `task_args LIKE` may be slow; always include date filter.

**Confirms**: `updated_at` is older than 48 hours, AND sync task status is `FAILURE` or no task results found, OR `CustomerLenderMap.business_id` / `loan_account_id` is `NULL`.

**Refutes**: `updated_at` is within the last 24 hours and sync task completed with `SUCCESS`.

---

### Hypothesis 2.2: Operational Limit Not Capped Correctly

**Description**: The `operational_limit` exceeds `credit_limit` due to a signal failure, or was set to `NULL` and not initialized.

**Required Evidence**:
- `operational_limit` vs `credit_limit` comparison
- Whether the `pre_save` signal (`credit_line/signals.py:update_operational_limit`) is functioning

**Verification Query**:

**SQL**:
```sql
SELECT ccl.id, c.source_identifier_id,
       ccl.credit_limit, ccl.operational_limit,
       cp.credit_product_name,
       CASE WHEN ccl.operational_limit IS NULL
            THEN 'ANOMALY: operational_limit is NULL'
            WHEN ccl.operational_limit > ccl.credit_limit
            THEN 'ANOMALY: operational_limit > credit_limit'
            ELSE 'OK'
       END AS check_result
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Expected < 10ms.

**Confirms**: `operational_limit IS NULL` or `operational_limit > credit_limit`.

**Refutes**: `operational_limit <= credit_limit` and is not `NULL`.

---

### Hypothesis 2.3: Buffer Limit Expired and Credit Limit Reset to Minimum

**Description**: The GAPL credit line had a `buffer_limit_end_date` that expired, causing `credit_limit` to be reset to `CREDIT_LIMIT_MIN_VALUE` by the `buffer_date_actions` task (daily 16:30).

**Required Evidence**:
- `buffer_limit_end_date` value
- `previous_credit_limit` (stored before reset)
- Current `credit_limit` (should be at minimum)

**Verification Query**:

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}',
    credit_product__belongs_to_gapl=True
).values(
    'id', 'credit_limit', 'previous_credit_limit',
    'buffer_limit_end_date', 'updated_at'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.credit_limit, ccl.previous_credit_limit,
       ccl.buffer_limit_end_date, ccl.updated_at
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = true;
```

**Performance**: Expected < 10ms.

**Confirms**: `buffer_limit_end_date` is in the past AND `credit_limit` equals the system minimum AND `previous_credit_limit` is significantly higher.

**Refutes**: `buffer_limit_end_date` is `NULL` or in the future, or `credit_limit` is at a normal value.

---

### Hypothesis 2.4: Limit Enhancement Not Applied

**Description**: A limit enhancement was configured but not reflected in the credit limit, either because the Lead status is stuck or the Saraloan sync hasn't picked it up.

**Required Evidence**:
- `Customer.limit_enhancement_amount` value
- Lead record status for limit enhancement
- Whether Saraloan sync detected the new limit

**Verification Query**:

**ORM**:
```python
from credit_line.model import Customer
from lead.models import Lead

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values('limit_enhancement_amount', 'external_lender_supported')

Lead.objects.filter(
    partner_id='{user_id}',
    ib_ticket_status='limit_enhancement'
).values(
    'id', 'limit_enhancement_status', 'application_status',
    'updated_at'
).order_by('-updated_at')
```

**SQL**:
```sql
SELECT c.limit_enhancement_amount, c.external_lender_supported
FROM credit_line_customer c
WHERE c.source_identifier_id = '{user_id}';

SELECT id, limit_enhancement_status, application_status, updated_at
FROM lead_lead
WHERE partner_id = '{user_id}'
  AND ib_ticket_status = 'limit_enhancement'
ORDER BY updated_at DESC;
```

**Performance**: Expected < 10ms each.

**Confirms**: `limit_enhancement_amount` is set (non-null, > 0) but the Lead `limit_enhancement_status` is not `LIMIT_ENHANCED`, or no Lead record exists.

**Refutes**: `limit_enhancement_amount` is `NULL` or 0 (no enhancement configured), or Lead status is `LIMIT_ENHANCED` (enhancement was applied).

---

## 3. Approval Workflow

**Flow**: [`02-user-flows/approval-workflow.md`](02-user-flows/approval-workflow.md)
**Playbook**: [`06-playbooks/loan-lifecycle-playbook.md`](06-playbooks/loan-lifecycle-playbook.md)

### Hypothesis 3.1: Loan Stuck in DRAFT Status

**Description**: A loan was created via the API (`LoanViewSet.post()`) but never transitioned from `DRAFT` to `YET_TO_BE_DISBURSED`. The `InvoiceLoanMap` creation or post-save signal may have failed.

**Required Evidence**:
- Loan record with `status = DRAFT`
- Whether `InvoiceLoanMap` records exist for the loan
- Celery task results for loan creation

**Verification Query**:

**ORM**:
```python
from loan.model import Loan, InvoiceLoanMap

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    status='DRAFT'
).values(
    'id', 'loan_id', 'loan_amount', 'transaction_date',
    'creation_reason', 'comment', 'created_at'
)

InvoiceLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}',
    loan__status='DRAFT'
).values('id', 'loan__loan_id', 'invoice_id', 'invoice_amount')
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.transaction_date, ll.creation_reason, ll.comment, ll.created_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status = 'DRAFT';

SELECT ilm.id, ll.loan_id, ilm.invoice_id, ilm.invoice_amount
FROM loan_invoiceloanmap ilm
JOIN loan_loan ll ON ilm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status = 'DRAFT';
```

**Performance**: Index on `loan_loan(customer_credit_line_id)`. Expected < 20ms.

**Confirms**: Loans exist with `status = DRAFT` that are older than expected (e.g., > 1 hour). If `InvoiceLoanMap` is missing, the creation process failed mid-way.

**Refutes**: No loans in `DRAFT` status, or `DRAFT` loans are very recent (still being processed).

---

### Hypothesis 3.2: Loan Stuck in YET_TO_BE_DISBURSED (Not Shared to Lender)

**Description**: A loan is in `YET_TO_BE_DISBURSED` but has no `LenderLoanMap`, meaning it was never prepared for lender sharing. The `share_oldest_loan_to_lender` task may not have picked it up.

**Required Evidence**:
- Loan in `YET_TO_BE_DISBURSED` on a non-GAPL credit line
- Absence of `LenderLoanMap` for the loan
- Whether the partner is eligible for loan sharing

**Verification Query**:

**ORM**:
```python
from loan.model import Loan, LenderLoanMap

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    status='YET_TO_BE_DISBURSED',
    customer_credit_line__credit_product__belongs_to_gapl=False
).values('id', 'loan_id', 'loan_amount', 'created_at')

LenderLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}'
).values('id', 'loan__loan_id', 'invoice_upload_status', 'created_at')
```

**SQL**:
```sql
-- Loans awaiting lender sharing
SELECT ll.id, ll.loan_id, ll.loan_amount, ll.created_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
LEFT JOIN loan_lenderloanmap llm ON llm.loan_id = ll.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status = 'YET_TO_BE_DISBURSED'
  AND cp.belongs_to_gapl = false
  AND llm.id IS NULL;
```

**Performance**: Expected < 20ms.

**Confirms**: Loans in `YET_TO_BE_DISBURSED` with no `LenderLoanMap` entry, especially if older than 24 hours.

**Refutes**: All `YET_TO_BE_DISBURSED` loans have a corresponding `LenderLoanMap` entry.

---

### Hypothesis 3.3: Invoice Upload Failed at Saraloan/BlackSoil

**Description**: The loan-to-lender pipeline stalled at one of the upload stages: application lookup, tranche creation, or invoice upload. The `LenderLoanMap.invoice_upload_status` indicates the failure point.

**Required Evidence**:
- `LenderLoanMap.invoice_upload_status` and `invoice_upload_status_desc`
- Celery task results for upload tasks
- `CustomerLenderMap.application_id` availability

**Verification Query**:

**ORM**:
```python
from loan.model import LenderLoanMap

LenderLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'loan__loan_id', 'invoice_upload_status',
    'invoice_upload_status_desc', 'lender_application_id',
    'lender_invoice_transaction_id', 'lender_invoice_id',
    'invoice_status_at_lender', 'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT llm.id, ll.loan_id, llm.invoice_upload_status,
       llm.invoice_upload_status_desc, llm.lender_application_id,
       llm.lender_invoice_transaction_id, llm.lender_invoice_id,
       llm.invoice_status_at_lender, llm.created_at, llm.updated_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY llm.created_at DESC;
```

**Performance**: Index on `loan_lenderloanmap(loan_id)`. Expected < 20ms.

**Confirms**: `invoice_upload_status` is one of: `APPLICATION_NOT_FOUND`, `PARTNER_NOT_FOUND`, `TRANSACTION_CREATION_FAILED`, `INVOICE_UPLOAD_FAILED`, `MANUAL_UPDATE_REQUIRED`, `SUBVENTION_UPDATE_FAILED`. Check `invoice_upload_status_desc` for the API error message.

**Refutes**: `invoice_upload_status = INVOICE_UPLOADED` (upload succeeded; issue is downstream in disbursal).

---

### Hypothesis 3.4: Disbursal Webhook Not Received

**Description**: The invoice was uploaded to the lender (`INVOICE_UPLOADED`) but the disbursal webhook from Saraloan was never received or processed. The loan remains in `YET_TO_BE_DISBURSED`.

**Required Evidence**:
- `LenderLoanMap` with `invoice_upload_status = INVOICE_UPLOADED`
- `invoice_status_at_lender` value
- Webhook entries in `external_externalwebhook`
- Celery task results for `process_saraloan_loan_webhook`

**Verification Query**:

**SQL**:
```sql
-- Check uploaded invoices awaiting disbursal
SELECT llm.id, ll.loan_id, llm.lender_invoice_id,
       llm.invoice_status_at_lender, llm.invoice_upload_date,
       llm.updated_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND llm.invoice_upload_status = 'INVOICE_UPLOADED'
  AND ll.status = 'YET_TO_BE_DISBURSED';

-- Check webhook events
SELECT id, event, created_at
FROM external_externalwebhook
WHERE data::jsonb -> 'identifiers' ->> 'partner_lead_id' = '{user_id}'
  AND created_at >= NOW() - INTERVAL '7 days'
ORDER BY created_at DESC LIMIT 20;

-- Check webhook processing task
SELECT task_name, status, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name = 'credit_line.tasks.process_saraloan_loan_webhook'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC LIMIT 10;
```

**Performance**: LenderLoanMap query: < 20ms. Webhook query: **Warning** — JSON field query without index, may be slow; always include date filter. Celery query: < 100ms with date filter.

**Confirms**: `invoice_upload_status = INVOICE_UPLOADED` with `invoice_status_at_lender = 'Pending'` for more than 24 hours, AND no webhook events found for this user, OR webhook task status is `FAILURE`.

**Refutes**: Webhook was received and `process_saraloan_loan_webhook` completed with `SUCCESS`.

---

### Hypothesis 3.5: Partial Disbursement by Lender

**Description**: The lender disbursed less than the requested loan amount. For DC customers, this triggers a partial disbursal flow that rejects the original loan and creates new loans. For Farmer customers, partial disbursal is not supported and returns `False`.

**Required Evidence**:
- Loan with `REJECTED` status and comment containing "Partial Disbursal"
- New loan created with `disbursed_amount < original loan_amount`
- Customer type (DC vs Farmer)

**Verification Query**:

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.disbursed_amount, ll.approved_amt, ll.rejected_amt,
       ll.comment, ll.created_at,
       cp.credit_product_name, ct.name AS customer_type
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}'
  AND (ll.status = 'REJECTED' OR ll.disbursed_amount < ll.loan_amount)
ORDER BY ll.created_at DESC;
```

**Performance**: Index on `loan_loan(customer_credit_line_id)`. Expected < 30ms.

**Confirms**: A `REJECTED` loan with `comment` containing "Partial Disbursal by Lender", accompanied by a new loan with the disbursed amount. For Farmer customers: no partial disbursal processing occurred (the system does not support it).

**Refutes**: No rejected loans with partial disbursal comments; `disbursed_amount` equals `loan_amount` on all disbursed loans.

---

### Hypothesis 3.6: Loan Status Transition Failure (FSM)

**Description**: An invalid FSM transition was attempted on a loan (e.g., trying to disburse a `DRAFT` loan directly, or marking a `CANCELLED` loan as `PAID`). The `django-fsm` library rejects invalid transitions with `TransitionNotAllowed`.

**Required Evidence**:
- Current loan status
- Expected transition (what operation was attempted)
- Celery task traceback showing `TransitionNotAllowed`

**Verification Query**:

**ORM**:
```python
from loan.model import Loan
from django_celery_results.models import TaskResult

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values('id', 'loan_id', 'status', 'updated_at').order_by('-updated_at')

TaskResult.objects.filter(
    task_args__contains='{user_id}',
    traceback__contains='TransitionNotAllowed'
).values('task_name', 'status', 'traceback', 'date_done').order_by('-date_done')[:5]
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY ll.updated_at DESC;

SELECT task_name, status, traceback, date_done
FROM django_celery_results_taskresult
WHERE task_args LIKE '%{user_id}%'
  AND traceback LIKE '%TransitionNotAllowed%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC LIMIT 5;
```

**Performance**: Loan query: < 20ms. Celery query: < 100ms with date filter. **Warning**: Double `LIKE` on `task_args` and `traceback` may be slow.

**Confirms**: Celery task traceback contains `TransitionNotAllowed`, indicating the loan was in a state that doesn't allow the attempted transition.

**Refutes**: No `TransitionNotAllowed` errors found; loan status transitions are valid.

---

## 4. Repayment Workflow

**Flow**: [`02-user-flows/repayment-workflow.md`](02-user-flows/repayment-workflow.md)
**Playbook**: [`06-playbooks/repayment-playbook.md`](06-playbooks/repayment-playbook.md) | [`06-playbooks/payment-reconciliation-playbook.md`](06-playbooks/payment-reconciliation-playbook.md)


### Hypothesis 4.1: Repayment Not Applied to Loan (Reconciliation Not Triggered)

**Description**: A payment was created and posted but the loan status was not updated. The reconciliation task either didn't run, failed, or was blocked.

**Required Evidence**:
- Payment records with `status = POSTED` and `sub_status = UNRECONCILED`
- Loan records still in `DISBURSED` despite payments existing
- Reconciliation task execution history
- `Customer.locus_recon_last_ran_at` timestamp

**Verification Query**:

**SQL**:
```sql
-- Unreconciled payments
SELECT p.id, p.payment_amount, p.status, p.sub_status,
       p.reconcilable_amount, p.payment_date, p.created_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = true
  AND p.status = 'POSTED'
  AND p.sub_status IN ('UNRECONCILED', 'PARTIALLY_RECONCILED')
ORDER BY p.payment_date DESC;

-- Outstanding loans that should have been reconciled
SELECT ll.id, ll.loan_id, ll.status, ll.remaining_amount, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status IN ('DISBURSED', 'PARTIALLY_PAID', 'OVERDUE')
ORDER BY ll.created_at;

-- Last reconciliation run
SELECT locus_recon_last_ran_at
FROM credit_line_customer
WHERE source_identifier_id = '{user_id}';

-- Reconciliation task results
SELECT task_name, status, result, date_done
FROM django_celery_results_taskresult
WHERE task_name IN (
    'loan.tasks.check_and_run_reconciliation_for_all_customers',
    'loan.tasks.run_reconciliation_for_customers'
)
AND task_args LIKE '%{user_id}%'
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC LIMIT 10;
```

**Performance**: Payment/loan queries: < 50ms each. Celery query: < 100ms with date filter.

**Confirms**: Unreconciled payments exist alongside outstanding loans, AND `locus_recon_last_ran_at` is `NULL` or stale, AND reconciliation task either didn't run or returned `FAILURE`.

**Refutes**: No unreconciled payments, or `locus_recon_last_ran_at` is recent and reconciliation task completed with `SUCCESS`.

---

### Hypothesis 4.2: Payment-Ledger Amount Mismatch

**Description**: The `Payment.payment_amount` differs from the corresponding `LedgerEntry.amount`, causing incorrect outstanding calculations.

**Required Evidence**:
- Payment records with their corresponding ledger entries
- Comparison of amounts between the two

**Verification Query**:

**SQL**:
```sql
SELECT p.id AS payment_id, p.lender_payment_id,
       p.payment_amount, p.status AS payment_status,
       p.settlement_date,
       le.id AS ledger_id, le.amount AS ledger_amount,
       le.date AS ledger_date, le.active, le.visible,
       le.unrealized_payment,
       ABS(p.payment_amount - COALESCE(le.amount, 0)) AS discrepancy
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
LEFT JOIN ledger_ledgerentry le ON le.locus_id = CAST(p.id AS TEXT) AND le.type = 'PAYMENT'
WHERE c.source_identifier_id = '{user_id}'
ORDER BY p.created_at DESC;
```

**Performance**: Uses indexes on `payment_payment(customer_credit_line_id)` and `ledger_ledgerentry(locus_id, type)`. Expected < 50ms.

**Confirms**: Rows where `discrepancy > 0` (payment amount differs from ledger amount), or rows where `ledger_id IS NULL` (missing ledger entry entirely).

**Refutes**: All payments have matching ledger entries with `discrepancy = 0`.

---

### Hypothesis 4.3: Ledger Entry Missing for Payment

**Description**: A `Payment` record exists but no corresponding `LedgerEntry` with `type = PAYMENT` was created. The `create_or_update_ledger_entry()` call in `payment/utils.py:631` failed or was never reached.

**Required Evidence**:
- Payment records without corresponding ledger entries
- Celery task results for payment processing tasks

**Verification Query**:

**SQL**:
```sql
SELECT p.id AS payment_id, p.lender_payment_id,
       p.payment_amount, p.status, p.created_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
LEFT JOIN ledger_ledgerentry le ON le.locus_id = CAST(p.id AS TEXT) AND le.type = 'PAYMENT'
WHERE c.source_identifier_id = '{user_id}'
  AND le.id IS NULL
  AND p.status != 'CANCELLED';
```

**Performance**: Expected < 50ms.

**Confirms**: Rows returned — payments exist without ledger entries.

**Refutes**: No rows returned — every non-cancelled payment has a corresponding ledger entry.

---

### Hypothesis 4.4: Demand Sheet Discrepancy

**Description**: Demand sheet amounts (outstanding, repaid, overdue) don't match actual payment and loan data. Demand sheets are point-in-time snapshots and may be stale.

**Required Evidence**:
- Demand sheet records for the user
- Comparison of demand `repaid_amount` with actual payment sum in the period

**Verification Query**:

**SQL**:
```sql
SELECT ds.id, ds.from_date, ds.to_date,
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

**Confirms**: `discrepancy != 0` — the demand sheet's `repaid_amount` doesn't match actual posted payments in the period.

**Refutes**: `discrepancy = 0` for all demand sheet periods.

---

### Hypothesis 4.5: Payment Sync Failure from Saraloan

**Description**: The daily repayment sync (`sync_repayment_info_for_all_dc`, 19:30) or webhook processing (`process_repayment_data`) failed, so lender payments were not created or updated locally.

**Required Evidence**:
- Celery task results for sync and webhook tasks
- `CustomerLenderMap.loan_account_id` (required for cron sync)
- Webhook events in `external_externalwebhook`

**Verification Query**:

**SQL**:
```sql
-- Check sync task results
SELECT task_name, status, result, traceback, date_done
FROM django_celery_results_taskresult
WHERE task_name IN (
    'payment.tasks.sync_repayment_info_for_all_dc',
    'payment.tasks.fetch_and_update_repayments_info',
    'payment.tasks.process_repayment_data'
)
AND task_args LIKE '%{user_id}%'
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC LIMIT 10;

-- Check lender map for loan_account_id
SELECT clm.loan_account_id, clm.business_id
FROM credit_line_customerlendermap clm
JOIN credit_line_customer c ON clm.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';

-- Check webhook events
SELECT id, event, created_at
FROM external_externalwebhook
WHERE data::jsonb -> 'identifiers' ->> 'partner_lead_id' = '{user_id}'
  AND event IN ('repayment_done', 'repayment_captured', 'repayment_bounced')
  AND created_at >= NOW() - INTERVAL '7 days'
ORDER BY created_at DESC LIMIT 10;
```

**Performance**: Celery query: < 100ms with date filter. Lender map: < 10ms. Webhook: **Warning** — JSON query without index; always include date filter.

**Confirms**: Sync task status is `FAILURE`, OR `loan_account_id` is `NULL` (cron sync cannot run), OR no webhook events found and no sync task results for this user.

**Refutes**: Sync tasks completed with `SUCCESS` and payments are present locally.

---

### Hypothesis 4.6: Payment Bounced but Ledger Not Cancelled

**Description**: A repayment was bounced by the lender (`repayment_bounced` event) but the corresponding ledger entry was not cancelled (`active` and `visible` still `True`).

**Required Evidence**:
- Payment with `status = BOUNCED` or bounced event
- Corresponding ledger entry still active

**Verification Query**:

**SQL**:
```sql
SELECT p.id AS payment_id, p.lender_payment_id,
       p.payment_amount, p.status AS payment_status,
       le.id AS ledger_id, le.amount AS ledger_amount,
       le.active AS ledger_active, le.visible AS ledger_visible
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
LEFT JOIN ledger_ledgerentry le ON le.locus_id = CAST(p.id AS TEXT) AND le.type = 'PAYMENT'
WHERE c.source_identifier_id = '{user_id}'
  AND p.status = 'BOUNCED';
```

**Performance**: Expected < 30ms.

**Confirms**: Payment is `BOUNCED` but ledger entry has `active = True` or `visible = True`.

**Refutes**: All bounced payments have ledger entries with `active = False` and `visible = False`.

---

### Hypothesis 4.7: Aggregated Payment Transfer Stuck

**Description**: Payments were marked `TRANSFER_TO_LENDER` during reconciliation but the `AggregatedPaymentTransfer` is stuck in `YET_TO_TRANSFER` or `ERROR` status. The transfer tasks (`aggregate_payment_transfer` at 10:30, `transfer_all_agg_payments` at 10:35) may have failed.

**Required Evidence**:
- `AggregatedPaymentTransfer` records with non-terminal status
- Mapped payments in `TRANSFER_TO_LENDER` or `TRANSFER_INITIATED`
- `recon_consistent` flag on credit line

**Verification Query**:

**SQL**:
```sql
SELECT apt.id, apt.amount, apt.status, apt.failure_reason,
       apt.transfer_try_count, apt.bank_generated_utr,
       apt.erp_upload_status, apt.created_at, apt.updated_at
FROM payment_aggregatedpaymenttransfer apt
JOIN credit_line_customer c ON apt.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND apt.status NOT IN ('TRANSFERRED', 'FAILED', 'REVERSED')
ORDER BY apt.created_at DESC;

-- Check recon_consistent flag
SELECT ccl.id, ccl.recon_consistent, cp.credit_product_name
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Expected < 30ms each.

**Confirms**: `AggregatedPaymentTransfer` records with `status IN ('YET_TO_TRANSFER', 'ERROR', 'STARTED')`, especially if `transfer_try_count > 0` and `failure_reason` is populated. Also confirmed if `recon_consistent = False` (blocks aggregation).

**Refutes**: All transfers have `status = TRANSFERRED` or no pending transfers exist.

---

## 5. Risk Evaluation

**Flow**: [`02-user-flows/risk-evaluation.md`](02-user-flows/risk-evaluation.md)
**Playbook**: [`06-playbooks/credit-eligibility-playbook.md`](06-playbooks/credit-eligibility-playbook.md) (Step 7)

### Hypothesis 5.1: Aged Outstanding Threshold Breach

**Description**: The daily `update_credit_lines_status` task (02:00) placed the credit line on `ONHOLD / AGED OUTSTANDING` because `total_overdue_amount - overdue_credit_limit > overdue_threshold_limit` and `business_override = False`.

**Required Evidence**:
- Credit line `status = ONHOLD`, `sub_status = AGED OUTSTANDING`
- Customer's `overdue_credit_limit` and `overdue_threshold_limit`
- Overdue loans contributing to the overdue amount
- `business_override` flag

**Verification Query**:

**ORM**:
```python
from credit_line.model import Customer, CustomerCreditLine
from loan.model import Loan

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values('overdue_credit_limit', 'overdue_threshold_limit')

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'sub_status', 'business_override',
    'overdue_amount', 'aged_outstanding_amount',
    'credit_product__credit_product_name'
)

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    overdue_date__lte=timezone.now()
).exclude(
    status__in=['REJECTED', 'CANCELLED', 'MOVED_TO_LENDER', 'DRAFT', 'PAID']
).values('id', 'loan_id', 'remaining_amount', 'overdue_date')
```

**SQL**:
```sql
-- Customer overdue configuration
SELECT c.overdue_credit_limit, c.overdue_threshold_limit,
       c.overdue_threshold_limit_end_date
FROM credit_line_customer c
WHERE c.source_identifier_id = '{user_id}';

-- Credit line status and overdue data
SELECT ccl.id, ccl.status, ccl.sub_status, ccl.business_override,
       ccl.overdue_amount, ccl.aged_outstanding_amount,
       cp.credit_product_name
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';

-- Overdue loans
SELECT ll.id, ll.loan_id, ll.remaining_amount, ll.overdue_date,
       ll.status, cp.credit_product_name
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.overdue_date <= NOW()
  AND ll.status NOT IN ('REJECTED', 'CANCELLED', 'MOVED_TO_LENDER', 'DRAFT', 'PAID')
ORDER BY ll.overdue_date;
```

**Performance**: Expected < 50ms total.

**Confirms**: `status = ONHOLD`, `sub_status = AGED OUTSTANDING`, AND `SUM(overdue loan remaining_amount) - overdue_credit_limit > overdue_threshold_limit`, AND `business_override = False`.

**Refutes**: `sub_status` is not `AGED OUTSTANDING`, OR `business_override = True` (automated holds bypassed), OR overdue amount is within threshold.

---

### Hypothesis 5.2: Repayment Frequency Breach

**Description**: The credit line was placed on `ONHOLD / REPAYMENT FREQUENCY` because the customer's repayment ratio is below the required threshold. The `repayment_unblock_amount` exceeds 1.

**Required Evidence**:
- Credit line `status = ONHOLD`, `sub_status = REPAYMENT FREQUENCY`
- `repayment_unblock_amount` and `repayment_date_outstanding_amount`
- Credit product's `repayment_duration`, `repayment_frequency_outstanding_cutoff`, `repayment_frequency_ratio`
- Ledger entries for outstanding and payment calculations

**Verification Query**:

**SQL**:
```sql
-- Credit line repayment frequency data
SELECT ccl.id, ccl.status, ccl.sub_status,
       ccl.repayment_unblock_amount,
       ccl.repayment_date_outstanding_amount,
       ccl.business_override,
       cp.repayment_duration,
       cp.repayment_frequency_outstanding_cutoff,
       cp.repayment_frequency_ratio,
       cp.credit_product_name
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = false;

-- Ledger entries for repayment frequency calculation
SELECT type, SUM(amount) AS total_amount, COUNT(*) AS entry_count
FROM ledger_ledgerentry
WHERE partner_id = '{user_id}'
  AND active = true AND visible = true
  AND type != 'REFUNDED'
GROUP BY type
ORDER BY type;
```

**Performance**: Credit line query: < 10ms. Ledger aggregation: < 100ms. **Warning**: For high-volume partners, add date range filter to ledger query.

**Confirms**: `sub_status = REPAYMENT FREQUENCY` AND `repayment_unblock_amount > 1` AND `business_override = False`.

**Refutes**: `sub_status` is not `REPAYMENT FREQUENCY`, OR `repayment_unblock_amount <= 1`, OR `business_override = True`.

---

### Hypothesis 5.3: Overdue Threshold Limit Expired

**Description**: The customer's `overdue_threshold_limit_end_date` has passed, causing the `overdue_threshold_limit` to be reset to 0 by the `overdue_threshold_limit_end_date_actions` task. This makes the customer more susceptible to aged outstanding holds.

**Required Evidence**:
- `overdue_threshold_limit` value (should be 0 after expiry)
- `overdue_threshold_limit_end_date` value (should be `NULL` after reset)
- History of threshold changes

**Verification Query**:

**ORM**:
```python
from credit_line.model import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'overdue_threshold_limit', 'overdue_threshold_limit_end_date',
    'overdue_credit_limit'
)
```

**SQL**:
```sql
SELECT c.overdue_threshold_limit, c.overdue_threshold_limit_end_date,
       c.overdue_credit_limit
FROM credit_line_customer c
WHERE c.source_identifier_id = '{user_id}';

-- Check history for threshold changes
SELECT h.history_date, h.overdue_threshold_limit,
       h.overdue_threshold_limit_end_date, au.username
FROM credit_line_historicalcustomer h
LEFT JOIN auth_user au ON h.history_user_id = au.id
WHERE h.source_identifier_id = '{user_id}'
  AND h.history_date >= NOW() - INTERVAL '30 days'
ORDER BY h.history_date DESC LIMIT 10;
```

**Performance**: Expected < 10ms for current values. History query: < 50ms with date filter.

**Confirms**: `overdue_threshold_limit = 0` AND `overdue_threshold_limit_end_date IS NULL`, AND history shows a recent change from a non-zero value.

**Refutes**: `overdue_threshold_limit > 0` (threshold is still active), or `overdue_threshold_limit_end_date` is in the future.

---

### Hypothesis 5.4: FinBox Data Collection Failed

**Description**: The daily FinBox data collection (`collect_user_profile_data_from_finbox`, 17:00) failed for this customer — either due to missing consent, API errors, or rate limiting.

**Required Evidence**:
- `Customer.data_permissions_consent` (all 4 consent flags must be `True`)
- `FinBoxData` record existence and freshness
- Celery task results for `get_finbox_data`

**Verification Query**:

**SQL**:
```sql
-- Check consent
SELECT c.data_permissions_consent
FROM credit_line_customer c
WHERE c.source_identifier_id = '{user_id}';

-- Check FinBox data freshness
SELECT fd.id, fd.profile_data_updated_at, c.source_identifier_id
FROM credit_line_finboxdata fd
JOIN credit_line_customer c ON fd.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';

-- Check task results
SELECT task_name, status, result, traceback, date_done
FROM django_celery_results_taskresult
WHERE task_name = 'credit_line.tasks.get_finbox_data'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC LIMIT 5;
```

**Performance**: Consent/FinBox queries: < 10ms each. Celery query: < 100ms with date filter.

**Confirms**: Any of: (a) `data_permissions_consent` has any consent flag as `False`, (b) no `FinBoxData` record exists or `profile_data_updated_at` is stale, (c) `get_finbox_data` task status is `FAILURE` with API error in traceback.

**Refutes**: All consent flags are `True`, `FinBoxData` record exists with recent `profile_data_updated_at`, and task completed with `SUCCESS`.

---

### Hypothesis 5.5: Business Override Preventing Automated Status Changes

**Description**: The `business_override` flag is `True` on the credit line, which prevents the automated `update_credit_lines_status` task from changing the status to `ONHOLD`. The credit line remains `ACTIVE` even though overdue thresholds are breached.

**Required Evidence**:
- `business_override = True` on the credit line
- Overdue amounts that would normally trigger a hold

**Verification Query**:

**SQL**:
```sql
SELECT ccl.id, ccl.status, ccl.sub_status, ccl.business_override,
       ccl.overdue_amount, ccl.aged_outstanding_amount,
       c.overdue_credit_limit, c.overdue_threshold_limit,
       cp.credit_product_name,
       CASE WHEN ccl.overdue_amount - c.overdue_credit_limit > c.overdue_threshold_limit
            THEN 'WOULD_BE_ONHOLD (but business_override=True)'
            ELSE 'WITHIN_THRESHOLD'
       END AS override_impact
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Expected < 10ms.

**Confirms**: `business_override = True` AND `override_impact = 'WOULD_BE_ONHOLD'` — the credit line would be on hold if not for the override.

**Refutes**: `business_override = False`, or overdue amounts are within threshold regardless.

---

### Hypothesis 5.6: Risk Evaluation Task Did Not Run

**Description**: The `update_credit_lines_status` task (daily 02:00) or `get_aged_outstanding_status_info` per-partner task did not execute for this customer, leaving the credit line status stale.

**Required Evidence**:
- Celery task results for risk evaluation tasks
- Whether the customer meets the filter criteria (DC, `external_lender_supported = True`)

**Verification Query**:

**SQL**:
```sql
-- Check if customer is eligible for risk evaluation
SELECT c.id, ct.name AS customer_type, c.external_lender_supported
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';

-- Check task execution
SELECT task_name, status, date_done, result
FROM django_celery_results_taskresult
WHERE task_name IN (
    'credit_line.tasks.update_credit_lines_status',
    'credit_line.tasks.get_aged_outstanding_status_info'
)
AND task_args LIKE '%{user_id}%'
AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC LIMIT 10;
```

**Performance**: Customer query: < 10ms. Celery query: < 100ms with date filter.

**Confirms**: Customer is DC with `external_lender_supported = True` (eligible), but no `get_aged_outstanding_status_info` task results found for this user in the last 7 days, OR task status is `FAILURE`.

**Refutes**: Task results show recent `SUCCESS` execution for this user.
