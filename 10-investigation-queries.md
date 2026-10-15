# 10 — Production Investigation Queries

> Central reference of all read-only investigation queries used across the forensic debugging documentation.
> Every query is **read-only** (`SELECT` only), parameterized with `{user_id}` (`source_identifier_id` / `partner_id`), targets indexed columns, and includes performance annotations.

**Cross-references**:
- [01-entry-points.md](01-entry-points.md) · [02-user-flows/](02-user-flows/) · [03-runtime-data.md](03-runtime-data.md)
- [04-decision-logic.md](04-decision-logic.md) · [05-celery-workflows.md](05-celery-workflows.md)
- [06-playbooks/](06-playbooks/) · [07-hypothesis-validation.md](07-hypothesis-validation.md)
- [08-failure-scenarios.md](08-failure-scenarios.md) · [09-log-correlation.md](09-log-correlation.md)

**Conventions**:
- `{user_id}` = `source_identifier_id` or `partner_id` (interchangeable)
- All queries use `SELECT` only — never `UPDATE`, `DELETE`, or `INSERT`
- Date range filters are included where applicable to limit scan scope
- ⚠ marks queries that may be expensive on large tables

---

## Table of Contents

1. [Customer Queries](#1-customer-queries)
2. [Credit Line Queries](#2-credit-line-queries)
3. [Loan Queries](#3-loan-queries)
4. [Payment Queries](#4-payment-queries)
5. [Ledger Queries](#5-ledger-queries)
6. [Repayment / Transaction Queries](#6-repayment--transaction-queries)
7. [Invoice Queries](#7-invoice-queries)
8. [Celery Task Queries](#8-celery-task-queries)
9. [External API / Webhook Queries](#9-external-api--webhook-queries)
10. [History / Audit Queries](#10-history--audit-queries)
11. [Cross-Table Consistency Queries](#11-cross-table-consistency-queries)

---

## 1. Customer Queries

### 1.1 Customer Profile and Credit Eligibility

**Description**: Retrieve customer record with credit eligibility flags, customer type, and risk configuration.

**Source**: [02-user-flows/credit-eligibility.md](02-user-flows/credit-eligibility.md) Q1, [03-runtime-data.md](03-runtime-data.md) §1.1, [06-playbooks/credit-eligibility-playbook.md](06-playbooks/credit-eligibility-playbook.md) Steps 1–2

**ORM**:
```python
from credit_line.model import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'source_identifier_id', 'name', 'is_credit_allowed',
    'external_lender_supported', 'customer_type__name',
    'overdue_credit_limit', 'overdue_threshold_limit',
    'overdue_threshold_limit_end_date',
    'limit_enhancement_amount', 'lender_supported_status',
    'data_permissions_consent'
)
```

**SQL**:
```sql
SELECT c.id, c.source_identifier_id, c.name, c.is_credit_allowed,
       c.external_lender_supported, ct.name AS customer_type,
       c.overdue_credit_limit, c.overdue_threshold_limit,
       c.overdue_threshold_limit_end_date,
       c.limit_enhancement_amount, c.lender_supported_status,
       c.data_permissions_consent
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 10ms. Uses unique index on `credit_line_customer.source_identifier_id`.
**Index**: `credit_line_customer.source_identifier_id` (unique).
**Safety**: Lightweight single-row lookup.

---

### 1.2 Limit Enhancement Lead Status

**Description**: Check limit enhancement status from the Lead model for ELS customers.

**Source**: [02-user-flows/credit-eligibility.md](02-user-flows/credit-eligibility.md) Q8, [02-user-flows/credit-limit-calculation.md](02-user-flows/credit-limit-calculation.md) Q5, [03-runtime-data.md](03-runtime-data.md) §1.7

**ORM**:
```python
from lead.models import Lead

Lead.objects.filter(
    partner_id='{user_id}',
    ib_ticket_status='limit_enhancement'
).values(
    'id', 'limit_enhancement_status', 'application_status',
    'ib_ticket_status', 'created_at', 'updated_at'
).order_by('-updated_at')
```

**SQL**:
```sql
SELECT id, limit_enhancement_status, application_status,
       ib_ticket_status, created_at, updated_at
FROM lead_lead
WHERE partner_id = '{user_id}'
  AND ib_ticket_status = 'limit_enhancement'
ORDER BY updated_at DESC;
```

**Performance**: < 10ms.
**Index**: `lead_lead.partner_id`.
**Safety**: Lightweight.

---

### 1.3 FinBox Data for User

**Description**: Check whether FinBox profile data exists and when it was last updated.

**Source**: [02-user-flows/risk-evaluation.md](02-user-flows/risk-evaluation.md) Query 5, [03-runtime-data.md](03-runtime-data.md) §5

**ORM**:
```python
from credit_line.model.finbox_data import FinBoxData

FinBoxData.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'profile_data_updated_at', 'customer__source_identifier_id'
)
```

**SQL**:
```sql
SELECT fd.id, fd.profile_data_updated_at, c.source_identifier_id
FROM credit_line_finboxdata fd
JOIN credit_line_customer c ON fd.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 10ms. Uses unique constraint on `credit_line_finboxdata.customer_id` (OneToOneField).
**Index**: `credit_line_finboxdata.customer_id` (unique).
**Safety**: Lightweight. To inspect the full `profile_data` JSON, add `fd.profile_data` to SELECT — this field can be large.

---

### 1.4 FinBox Consent Status

**Description**: Check whether the user has granted all four data permissions required for FinBox data collection.

**Source**: [02-user-flows/risk-evaluation.md](02-user-flows/risk-evaluation.md) Query 6

**ORM**:
```python
from credit_line.model.customer import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values('data_permissions_consent')
```

**SQL**:
```sql
SELECT data_permissions_consent
FROM credit_line_customer
WHERE source_identifier_id = '{user_id}';
```

**Performance**: < 5ms. Uses unique index on `source_identifier_id`.
**Index**: `credit_line_customer.source_identifier_id` (unique).
**Safety**: Lightweight. Check that all four keys are `true`: `sms_consent`, `apps_consent`, `device_consent`, `location_consent`.

---

## 2. Credit Line Queries

### 2.1 All Credit Lines with Product and Lender Details

**Description**: Retrieve all credit lines for a user with status, limits, outstanding amounts, and credit product configuration.

**Source**: [02-user-flows/credit-eligibility.md](02-user-flows/credit-eligibility.md) Q2, [02-user-flows/credit-limit-calculation.md](02-user-flows/credit-limit-calculation.md) Q1, [03-runtime-data.md](03-runtime-data.md) §1.2, [06-playbooks/credit-eligibility-playbook.md](06-playbooks/credit-eligibility-playbook.md) Step 3

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).select_related('customer', 'credit_product').values(
    'id', 'status', 'sub_status', 'credit_limit', 'operational_limit',
    'available_credit_limit', 'lender_available_credit_limit',
    'lender_outstanding_amount', 'outstanding_amount',
    'overdue_amount', 'lender_status', 'lender_advance_payment',
    'unrealised_outstanding_payment', 'principal_outstanding',
    'business_override', 'effective_from', 'effective_to',
    'aged_outstanding_amount', 'repayment_unblock_amount',
    'credit_product__credit_product_name', 'credit_product__belongs_to_gapl',
    'credit_product__unrealised_percentage',
    'credit_product__interest_per_day',
    'credit_product__repayment_duration',
    'credit_product__interest_warning_days',
    'credit_product__app_block_days',
    'updated_at'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.status, ccl.sub_status, ccl.credit_limit,
       ccl.operational_limit, ccl.available_credit_limit,
       ccl.lender_available_credit_limit, ccl.lender_outstanding_amount,
       ccl.outstanding_amount, ccl.overdue_amount, ccl.lender_status,
       ccl.lender_advance_payment, ccl.unrealised_outstanding_payment,
       ccl.principal_outstanding, ccl.business_override,
       ccl.effective_from, ccl.effective_to,
       ccl.aged_outstanding_amount, ccl.repayment_unblock_amount,
       cp.credit_product_name, cp.belongs_to_gapl,
       cp.unrealised_percentage, cp.interest_per_day,
       cp.repayment_duration, cp.interest_warning_days, cp.app_block_days,
       ccl.updated_at
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 20ms. Uses index on `credit_line_customercreditline(customer_id, credit_product_id)`.
**Index**: `credit_line_customercreditline(customer_id, credit_product_id)`.
**Safety**: Lightweight — typically 1–3 rows per user.

---

### 2.2 Credit Line Status and Risk Fields

**Description**: Focused view of status, sub_status, business_override, and risk-related fields for risk evaluation investigation.

**Source**: [02-user-flows/risk-evaluation.md](02-user-flows/risk-evaluation.md) Query 2, [06-playbooks/credit-eligibility-playbook.md](06-playbooks/credit-eligibility-playbook.md) Step 7

**ORM**:
```python
from credit_line.model.customer_credit_line import CustomerCreditLine

CustomerCreditLine.objects.select_related(
    'credit_product', 'customer'
).filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'sub_status', 'business_override',
    'aged_outstanding_amount', 'repayment_unblock_amount',
    'repayment_date_outstanding_amount', 'transition_from_onboarding_pod',
    'overdue_days', 'credit_limit', 'operational_limit',
    'credit_product__credit_product_name', 'credit_product__belongs_to_gapl',
    'credit_product__repayment_duration',
    'credit_product__repayment_frequency_outstanding_cutoff',
    'credit_product__repayment_frequency_ratio'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.status, ccl.sub_status, ccl.business_override,
       ccl.aged_outstanding_amount, ccl.repayment_unblock_amount,
       ccl.repayment_date_outstanding_amount, ccl.transition_from_onboarding_pod,
       ccl.overdue_days, ccl.credit_limit, ccl.operational_limit,
       cp.credit_product_name, cp.belongs_to_gapl,
       cp.repayment_duration, cp.repayment_frequency_outstanding_cutoff,
       cp.repayment_frequency_ratio
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 20ms.
**Index**: `credit_line_customercreditline(customer_id, credit_product_id)`.
**Safety**: Lightweight.

---

### 2.3 Lender Credit Line Availability (for Loan Sharing)

**Description**: Check if a non-GAPL lender credit line is active and has available limit for loan sharing.

**Source**: [02-user-flows/approval-workflow.md](02-user-flows/approval-workflow.md) Q8, [03-runtime-data.md](03-runtime-data.md) §3.4, [06-playbooks/loan-lifecycle-playbook.md](06-playbooks/loan-lifecycle-playbook.md)

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}',
    credit_product__belongs_to_gapl=False,
    customer__external_lender_supported=True,
    status__in=['ACTIVE', 'ONHOLD']
).values(
    'id', 'status', 'credit_limit', 'operational_limit',
    'lender_available_credit_limit', 'lender_outstanding_amount',
    'lender_advance_payment',
    'credit_product__credit_product_name'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.status, ccl.credit_limit, ccl.operational_limit,
       ccl.lender_available_credit_limit, ccl.lender_outstanding_amount,
       ccl.lender_advance_payment,
       cp.credit_product_name
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = false
  AND c.external_lender_supported = true
  AND ccl.status IN ('ACTIVE', 'ONHOLD');
```

**Performance**: < 10ms.
**Index**: `credit_line_customercreditline(customer_id, credit_product_id)`.
**Safety**: Lightweight.

---

### 2.4 CustomerLenderMap (Saraloan Sync Context)

**Description**: Retrieve lender mapping with `business_id`, `loan_account_id`, and `application_id` used for Saraloan API calls.

**Source**: [02-user-flows/credit-limit-calculation.md](02-user-flows/credit-limit-calculation.md) Q4, [02-user-flows/approval-workflow.md](02-user-flows/approval-workflow.md) Q4, [03-runtime-data.md](03-runtime-data.md) §2.2

**ORM**:
```python
from credit_line.model import CustomerLenderMap

CustomerLenderMap.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'customer_id', 'credit_product__credit_product_name',
    'business_id', 'loan_account_id', 'application_id',
    'created_at', 'updated_at'
)
```

**SQL**:
```sql
SELECT clm.id, clm.customer_id, cp.credit_product_name,
       clm.business_id, clm.loan_account_id, clm.application_id,
       clm.created_at, clm.updated_at
FROM credit_line_customerlendermap clm
JOIN credit_line_customer c ON clm.customer_id = c.id
JOIN credit_line_creditproduct cp ON clm.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 10ms.
**Index**: `credit_line_customerlendermap(customer_id)`.
**Safety**: Lightweight.

---

### 2.5 Credit Product Configuration

**Description**: Verify credit product settings (interest, repayment duration, GAPL flag, lender) for a user's credit lines.

**Source**: [06-playbooks/credit-eligibility-playbook.md](06-playbooks/credit-eligibility-playbook.md) Step 4

**ORM**:
```python
from credit_line.model import CreditProduct

CreditProduct.objects.filter(
    customer_credit_lines__customer__source_identifier_id='{user_id}'
).values(
    'id', 'credit_product_name', 'belongs_to_gapl', 'lender__name',
    'priority', 'interest_per_day', 'repayment_duration',
    'unrealised_percentage', 'app_block_days',
    'interest_warning_days', 'overdue_warning_days'
)
```

**SQL**:
```sql
SELECT cp.id, cp.credit_product_name, cp.belongs_to_gapl,
       l.name AS lender_name, cp.priority,
       cp.interest_per_day, cp.repayment_duration,
       cp.unrealised_percentage, cp.app_block_days,
       cp.interest_warning_days, cp.overdue_warning_days
FROM credit_line_creditproduct cp
JOIN credit_line_lender l ON cp.lender_id = l.id
JOIN credit_line_customercreditline ccl ON ccl.credit_product_id = cp.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 10ms.
**Index**: Joins through indexed FKs.
**Safety**: Lightweight.

---

### 2.6 Buffer Limit Expiry Status

**Description**: Check GAPL credit line buffer limit configuration and expiry date.

**Source**: [02-user-flows/credit-limit-calculation.md](02-user-flows/credit-limit-calculation.md) Q8, [03-runtime-data.md](03-runtime-data.md) §2.4

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

**Performance**: < 10ms.
**Index**: `credit_line_customercreditline(customer_id, credit_product_id)`.
**Safety**: Lightweight.

---

### 2.7 Operational Limit Anomaly Check

**Description**: Diagnostic query to detect `operational_limit > credit_limit` anomalies.

**Source**: [02-user-flows/credit-limit-calculation.md](02-user-flows/credit-limit-calculation.md) Q7, [06-playbooks/credit-eligibility-playbook.md](06-playbooks/credit-eligibility-playbook.md) Step 6

**SQL**:
```sql
SELECT ccl.id, c.source_identifier_id,
       ccl.credit_limit, ccl.operational_limit,
       cp.credit_product_name,
       CASE WHEN ccl.operational_limit > ccl.credit_limit
            THEN 'ANOMALY: operational_limit > credit_limit'
            ELSE 'OK'
       END AS check_result
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 10ms.
**Index**: `credit_line_customercreditline(customer_id, credit_product_id)`.
**Safety**: Lightweight.

---

### 2.8 Final Credit Line Status Computation Inputs

**Description**: Retrieve all fields used by `fetch_final_status_and_sub_status_of_credit_lines()` to compute the final status.

**Source**: [02-user-flows/credit-eligibility.md](02-user-flows/credit-eligibility.md) Q7

**SQL**:
```sql
SELECT ccl.id AS credit_line_id,
       cp.credit_product_name,
       cp.belongs_to_gapl,
       ccl.status,
       ccl.sub_status,
       ccl.lender_status,
       ccl.repayment_unblock_amount,
       ccl.aged_outstanding_amount,
       c.is_credit_allowed,
       c.external_lender_supported
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 10ms.
**Index**: `credit_line_customercreditline(customer_id, credit_product_id)`.
**Safety**: Lightweight.

---

## 3. Loan Queries

### 3.1 All Loans with Status and Credit Line Details

**Description**: Retrieve all loans for a user with status, amounts, dates, and credit product info.

**Source**: [02-user-flows/approval-workflow.md](02-user-flows/approval-workflow.md) Q1, [02-user-flows/credit-eligibility.md](02-user-flows/credit-eligibility.md) Q3, [03-runtime-data.md](03-runtime-data.md) §1.3, §3.1, [06-playbooks/loan-lifecycle-playbook.md](06-playbooks/loan-lifecycle-playbook.md) Step 3

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).select_related(
    'customer_credit_line__credit_product'
).values(
    'id', 'loan_id', 'status', 'loan_amount', 'disbursed_amount',
    'remaining_amount', 'transaction_date', 'disbursement_date',
    'overdue_date', 'interest_free_period_end_date',
    'total_interest', 'total_penal_interest',
    'remaining_principal', 'remaining_interest',
    'creation_reason', 'comment', 'created_at', 'updated_at',
    'customer_credit_line__credit_product__credit_product_name',
    'customer_credit_line__credit_product__belongs_to_gapl',
).order_by('-created_at')
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount, ll.disbursed_amount,
       ll.remaining_amount, ll.transaction_date, ll.disbursement_date,
       ll.overdue_date, ll.interest_free_period_end_date,
       ll.total_interest, ll.total_penal_interest,
       ll.remaining_principal, ll.remaining_interest,
       ll.creation_reason, ll.comment, ll.created_at, ll.updated_at,
       cp.credit_product_name, cp.belongs_to_gapl
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY ll.created_at DESC;
```

**Performance**: < 50ms for typical user.
**Index**: `loan_loan(customer_credit_line_id)`.
**Safety**: Lightweight for most users. Users with many loans (100+) may take longer.

---

### 3.2 Overdue Loans Contributing to Risk

**Description**: Retrieve loans with overdue dates in the past, excluding terminal statuses. Used for risk evaluation.

**Source**: [02-user-flows/risk-evaluation.md](02-user-flows/risk-evaluation.md) Query 3

**ORM**:
```python
from loan.model.loans import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    overdue_date__lte=timezone.now()
).exclude(
    status__in=['REJECTED', 'CANCELLED', 'MOVED_TO_LENDER', 'DRAFT', 'PAID']
).values(
    'id', 'loan_id', 'status', 'loan_amount', 'remaining_amount',
    'overdue_date', 'transaction_date',
    'customer_credit_line__id',
    'customer_credit_line__credit_product__credit_product_name'
).order_by('overdue_date')
```

**SQL**:
```sql
SELECT l.id, l.loan_id, l.status, l.loan_amount, l.remaining_amount,
       l.overdue_date, l.transaction_date,
       l.customer_credit_line_id,
       cp.credit_product_name
FROM loan_loan l
JOIN credit_line_customercreditline ccl ON l.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND l.overdue_date <= NOW()
  AND l.status NOT IN ('REJECTED', 'CANCELLED', 'MOVED_TO_LENDER', 'DRAFT', 'PAID')
ORDER BY l.overdue_date;
```

**Performance**: < 50ms.
**Index**: `loan_loan(customer_credit_line_id)`.
**Safety**: Lightweight.

---

### 3.3 LenderLoanMap Upload Status

**Description**: Check the invoice upload progression for loans shared to external lenders (Saraloan/BlackSoil).

**Source**: [02-user-flows/approval-workflow.md](02-user-flows/approval-workflow.md) Q2, [03-runtime-data.md](03-runtime-data.md) §3.2, [06-playbooks/loan-lifecycle-playbook.md](06-playbooks/loan-lifecycle-playbook.md) Step 4

**ORM**:
```python
from loan.model import LenderLoanMap

LenderLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'loan__loan_id', 'lender_application_id',
    'lender_invoice_id', 'lender_invoice_transaction_id',
    'invoice_upload_status', 'invoice_upload_status_desc',
    'invoice_upload_date', 'invoice_status_at_lender',
    'is_invoice_subvented', 'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT llm.id, ll.loan_id, llm.lender_application_id,
       llm.lender_invoice_id, llm.lender_invoice_transaction_id,
       llm.invoice_upload_status, llm.invoice_upload_status_desc,
       llm.invoice_upload_date, llm.invoice_status_at_lender,
       llm.is_invoice_subvented, llm.created_at, llm.updated_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY llm.created_at DESC;
```

**Performance**: < 30ms.
**Index**: `loan_lenderloanmap(loan_id)`.
**Safety**: Lightweight.

---

### 3.4 InvoiceLoanMap Entries

**Description**: Retrieve invoice-to-loan mappings showing which invoices are linked to which loans.

**Source**: [02-user-flows/approval-workflow.md](02-user-flows/approval-workflow.md) Q3, [03-runtime-data.md](03-runtime-data.md) §3.3

**ORM**:
```python
from loan.model import InvoiceLoanMap

InvoiceLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'loan__loan_id', 'invoice_id', 'invoice_id_at_lender',
    'invoice_amount', 'disbursement_amount', 'delivery_date',
    'source', 'created_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT ilm.id, ll.loan_id, ilm.invoice_id, ilm.invoice_id_at_lender,
       ilm.invoice_amount, ilm.disbursement_amount, ilm.delivery_date,
       ilm.source, ilm.created_at
FROM loan_invoiceloanmap ilm
JOIN loan_loan ll ON ilm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY ilm.created_at DESC;
```

**Performance**: < 30ms.
**Index**: `loan_invoiceloanmap(loan_id)`.
**Safety**: Lightweight.

---

### 3.5 Loans Stuck in YET_TO_BE_DISBURSED (No LenderLoanMap)

**Description**: Detect non-GAPL loans that were never shared to a lender — they have no `LenderLoanMap` entry.

**Source**: [02-user-flows/approval-workflow.md](02-user-flows/approval-workflow.md) Q7, [03-runtime-data.md](03-runtime-data.md) §3.6, [08-failure-scenarios.md](08-failure-scenarios.md) §5.4

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    status='YET_TO_BE_DISBURSED',
    partner_lender_invoice_map__isnull=True,
    customer_credit_line__credit_product__belongs_to_gapl=False
).values(
    'id', 'loan_id', 'loan_amount', 'transaction_date', 'created_at'
)
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.loan_amount, ll.transaction_date, ll.created_at
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

**Performance**: < 20ms.
**Index**: `loan_loan(customer_credit_line_id, status)`.
**Safety**: Lightweight.

---

### 3.6 Loan Movement History (GAPL → Lender Splits)

**Description**: Trace loan splits and movements by checking loans with non-empty `comment` fields.

**Source**: [02-user-flows/approval-workflow.md](02-user-flows/approval-workflow.md) Q9

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    comment__isnull=False
).exclude(
    comment=''
).values(
    'id', 'loan_id', 'status', 'loan_amount', 'comment',
    'creation_reason', 'created_at',
    'customer_credit_line__credit_product__credit_product_name'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount, ll.comment,
       ll.creation_reason, ll.created_at,
       cp.credit_product_name
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.comment IS NOT NULL
  AND ll.comment != ''
ORDER BY ll.created_at DESC;
```

**Performance**: < 30ms.
**Index**: `loan_loan(customer_credit_line_id)`.
**Safety**: Lightweight.

---

## 4. Payment Queries

### 4.1 All Payments for a User's Credit Lines

**Description**: Retrieve all payment records including lender payment details, amounts, status, and settlement info.

**Source**: [02-user-flows/credit-eligibility.md](02-user-flows/credit-eligibility.md) Q4, [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q2, [03-runtime-data.md](03-runtime-data.md) §1.4, §4.2, [06-playbooks/repayment-playbook.md](06-playbooks/repayment-playbook.md) Step 3

**ORM**:
```python
from payment.models import Payment

Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'lender_payment_id', 'lender_payment_ref_number',
    'payment_amount', 'payment_amount_settled', 'advance_amount',
    'payment_date', 'settlement_date', 'payment_mode', 'status',
    'sub_status', 'interest', 'principal', 'penal_interest',
    'overdue_interest', 'refund_amount', 'refund_utr',
    'transfer_to_lender_amount', 'hold_amount',
    'reconcilable_amount', 'payment_transfer_number',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT p.id, p.lender_payment_id, p.lender_payment_ref_number,
       p.payment_amount, p.payment_amount_settled, p.advance_amount,
       p.payment_date, p.settlement_date, p.payment_mode, p.status,
       p.sub_status, p.interest, p.principal, p.penal_interest,
       p.overdue_interest, p.refund_amount, p.refund_utr,
       p.transfer_to_lender_amount, p.hold_amount,
       p.reconcilable_amount, p.payment_transfer_number,
       p.created_at, p.updated_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY p.created_at DESC;
```

**Performance**: < 50ms.
**Index**: `payment_payment(customer_credit_line_id)`.
**Safety**: Lightweight for most users.

---

### 4.2 Credit Notes for a User

**Description**: Retrieve credit notes linked to a user's credit lines.

**Source**: [06-playbooks/payment-reconciliation-playbook.md](06-playbooks/payment-reconciliation-playbook.md) Step 5

**ORM**:
```python
from payment.models import CreditNote

CreditNote.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'amount', 'prepaid_amount',
    'linked_invoice', 'is_instant_discount_cn',
    'customer_credit_line__credit_product__credit_product_name',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT pc.id, pc.status, pc.amount, pc.prepaid_amount,
       pc.linked_invoice, pc.is_instant_discount_cn,
       cp.credit_product_name,
       pc.created_at, pc.updated_at
FROM payment_creditnote pc
JOIN credit_line_customercreditline ccl ON pc.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY pc.created_at DESC;
```

**Performance**: < 30ms.
**Index**: `payment_creditnote(customer_credit_line_id)`.
**Safety**: Lightweight.

---

### 4.3 Aggregated Payment Transfers for a User

**Description**: Check aggregated payment transfer records and their status (YET_TO_TRANSFER, TRANSFERRED, ERROR).

**Source**: [05-celery-workflows.md](05-celery-workflows.md) Workflow 4, [06-playbooks/payment-reconciliation-playbook.md](06-playbooks/payment-reconciliation-playbook.md) Step 6

**ORM**:
```python
from payment.models import AggregatedPaymentTransfer

AggregatedPaymentTransfer.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'transfer_amount', 'bank_generated_utr',
    'transfer_try_count', 'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT apt.id, apt.status, apt.transfer_amount,
       apt.bank_generated_utr, apt.transfer_try_count,
       apt.created_at, apt.updated_at
FROM payment_aggregatedpaymenttransfer apt
JOIN credit_line_customer c ON apt.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY apt.created_at DESC;
```

**Performance**: < 50ms.
**Index**: `payment_aggregatedpaymenttransfer(customer_id)`.
**Safety**: Lightweight.

---

## 5. Ledger Queries

### 5.1 All Ledger Entries for a User

**Description**: Retrieve all active, visible ledger entries excluding refunded entries.

**Source**: [02-user-flows/credit-eligibility.md](02-user-flows/credit-eligibility.md) Q5, [03-runtime-data.md](03-runtime-data.md) §1.5

**ORM**:
```python
from ledger.models import LedgerEntry

LedgerEntry.objects.filter(
    partner_id='{user_id}',
    active=True,
    visible=True
).exclude(
    type='REFUNDED'
).values(
    'id', 'type', 'amount', 'date', 'source_no',
    'outstanding_amount', 'paid_amount', 'credit_note_reason'
).order_by('-date')
```

**SQL**:
```sql
SELECT id, type, amount, date, source_no,
       outstanding_amount, paid_amount, credit_note_reason
FROM ledger_ledgerentry
WHERE partner_id = '{user_id}'
  AND active = true
  AND visible = true
  AND type != 'REFUNDED'
ORDER BY date DESC;
```

**Performance**: < 100ms.
**Index**: `ledger_ledgerentry(partner_id)`.
⚠ **Safety**: Users with large ledger history may have 1000+ entries. Add date range filter for production:
```sql
AND date >= NOW() - INTERVAL '365 days'
```

---

### 5.2 Ledger Entries — Repayment Type Only

**Description**: Retrieve only PAYMENT-type ledger entries, including visibility and unrealized payment flags.

**Source**: [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q3, [03-runtime-data.md](03-runtime-data.md) §4.3

**ORM**:
```python
from ledger.models import LedgerEntry

LedgerEntry.objects.filter(
    partner_id='{user_id}',
    type='PAYMENT'
).values(
    'id', 'partner_id', 'type', 'source', 'date', 'amount',
    'locus_id', 'payment_mode', 'source_no', 'visible',
    'active', 'unrealized_payment', 'belongs_to_gapl',
    'created_at', 'updated_at'
).order_by('-date')
```

**SQL**:
```sql
SELECT id, partner_id, type, source, date, amount,
       locus_id, payment_mode, source_no, visible,
       active, unrealized_payment, belongs_to_gapl,
       created_at, updated_at
FROM ledger_ledgerentry
WHERE partner_id = '{user_id}'
  AND type = 'PAYMENT'
ORDER BY date DESC;
```

**Performance**: < 30ms.
**Index**: `ledger_ledgerentry(partner_id, type)`.
**Safety**: Lightweight.

---

### 5.3 Ledger Entries for Repayment Frequency Check

**Description**: Retrieve ledger entries before and after a repayment date for repayment frequency evaluation.

**Source**: [02-user-flows/risk-evaluation.md](02-user-flows/risk-evaluation.md) Query 4

**SQL**:
```sql
-- Outstanding before last repayment date
SELECT id, type, amount, date, source_no
FROM ledger_ledgerentry
WHERE partner_id = '{user_id}'
  AND date < '{last_repayment_date}'
  AND active = TRUE AND visible = TRUE
  AND type != 'REFUNDED'
ORDER BY date;

-- Payments after last repayment date
SELECT id, type, amount, date, source_no
FROM ledger_ledgerentry
WHERE partner_id = '{user_id}'
  AND date >= '{last_repayment_date}'
  AND active = TRUE AND visible = TRUE
ORDER BY date;
```

**Performance**: < 100ms.
**Index**: `ledger_ledgerentry(partner_id)`.
⚠ **Safety**: Partners with high transaction volume may have thousands of entries. Add `AND date >= '{start_date}'` to bound the query.

---

## 6. Repayment / Transaction Queries

### 6.1 All Repayment Transactions for a Farmer

**Description**: Retrieve all active repayment transactions (collections and deposits) for a farmer.

**Source**: [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q1, [03-runtime-data.md](03-runtime-data.md) §4.1

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
    'related_transaction_id', 'secondary', 'meta',
    'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT id, transaction_id, transaction_type, transaction_channel,
       amount, payee, payee_type, payment_id,
       related_transaction_id, secondary, meta,
       created_at, updated_at
FROM repayment_transaction
WHERE payer = '{user_id}'
  AND payer_type = 'FARMER'
  AND active = true
ORDER BY created_at DESC;
```

**Performance**: < 50ms.
**Index**: `repayment_transaction(transaction_type, active)`.
**Safety**: Lightweight.

---

### 6.2 Demand Sheets for a Farmer

**Description**: Retrieve demand sheet records showing expected repayment amounts, overdue status, and EMI data.

**Source**: [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q5, [03-runtime-data.md](03-runtime-data.md) §4.5

**ORM**:
```python
from repayment.models import DemandSheet

DemandSheet.objects.filter(
    user_id='{user_id}'
).values(
    'id', 'from_date', 'to_date', 'due_date', 'dpd', 'dpd_days',
    'sanctioned_limit_amount', 'disbursement_amount', 'repaid_amount',
    'outstanding_amount', 'cumulative_emi_amount', 'overdue_amount',
    'net_demand_amount', 'late_fee_amount',
    'created_at', 'updated_at'
).order_by('-to_date')
```

**SQL**:
```sql
SELECT id, from_date, to_date, due_date, dpd, dpd_days,
       sanctioned_limit_amount, disbursement_amount, repaid_amount,
       outstanding_amount, cumulative_emi_amount, overdue_amount,
       net_demand_amount, late_fee_amount,
       created_at, updated_at
FROM repayment_demandsheet
WHERE user_id = '{user_id}'
ORDER BY to_date DESC;
```

**Performance**: < 30ms.
**Index**: `repayment_demandsheet(user_id)`.
**Safety**: Lightweight.

---

### 6.3 Aggregated Deposits and Mapped Transactions

**Description**: Retrieve aggregated deposits and their linked transactions for a user.

**Source**: [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q6

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

**Performance**: < 50ms.
**Index**: `repayment_transaction(transaction_type, active)`.
**Safety**: Lightweight.

---

### 6.4 Virtual Account Info for a User

**Description**: Retrieve virtual account details used for VPA deposits.

**Source**: [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q7, [03-runtime-data.md](03-runtime-data.md) §4.6

**ORM**:
```python
from repayment.models import CustomerVirtualAccount

CustomerVirtualAccount.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'virtual_account_number', 'virtual_account_bank_name',
    'virtual_account_ifsc_code', 'virtual_account_upi_id',
    'credit_product__credit_product_name',
    'created_at', 'updated_at'
)
```

**SQL**:
```sql
SELECT cva.id, cva.virtual_account_number, cva.virtual_account_bank_name,
       cva.virtual_account_ifsc_code, cva.virtual_account_upi_id,
       cp.credit_product_name,
       cva.created_at, cva.updated_at
FROM repayment_customervirtualaccount cva
JOIN credit_line_customer c ON cva.customer_id = c.id
JOIN credit_line_creditproduct cp ON cva.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 10ms.
**Index**: Unique constraint on `(customer_id, credit_product_id)`.
**Safety**: Lightweight.

---

## 7. Invoice Queries

### 7.1 Invoices Under Process (Affecting Available Credit Limit)

**Description**: Retrieve invoices in draft/processing states that reduce available credit limit.

**Source**: [02-user-flows/credit-eligibility.md](02-user-flows/credit-eligibility.md) Q6, [03-runtime-data.md](03-runtime-data.md) §1.6, [06-playbooks/credit-eligibility-playbook.md](06-playbooks/credit-eligibility-playbook.md) Step 8

**ORM**:
```python
from invoice.models import Invoice

Invoice.objects.filter(
    partner_id='{user_id}',
    status__in=['DRAFT', 'YET_TO_PROCESS', 'LOAN_CREATION_FAILED', 'INVOICE_CREATED']
).values(
    'id', 'status', 'amount', 'prepaid_amount',
    'overdue_credit_date', 'transaction_date', 'erp_id'
)
```

**SQL**:
```sql
SELECT id, status, amount, prepaid_amount,
       overdue_credit_date, transaction_date, erp_id
FROM invoice_invoice
WHERE partner_id = '{user_id}'
  AND status IN ('DRAFT', 'YET_TO_PROCESS', 'LOAN_CREATION_FAILED', 'INVOICE_CREATED');
```

**Performance**: < 20ms.
**Index**: `invoice_invoice(partner_id)`.
**Safety**: Lightweight.

---

## 8. Celery Task Queries

### 8.1 Task Result by Task ID

**Description**: Retrieve a specific Celery task result by its unique task ID.

**Source**: [05-celery-workflows.md](05-celery-workflows.md)

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(task_id='{task_id}')
```

**SQL**:
```sql
SELECT id, task_id, task_name, status, result,
       date_done, traceback, task_args, task_kwargs
FROM django_celery_results_taskresult
WHERE task_id = '{task_id}';
```

**Performance**: < 10ms. Uses unique index on `task_id`.
**Index**: `django_celery_results_taskresult.task_id` (unique).
**Safety**: Lightweight single-row lookup.

---

### 8.2 All Task Results for a User (Last 7 Days)

**Description**: Retrieve all Celery task results that reference a specific user in their arguments.

**Source**: [05-celery-workflows.md](05-celery-workflows.md)

**ORM**:
```python
from django.db.models import Q
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    Q(task_args__contains='{user_id}') | Q(task_kwargs__contains='{user_id}'),
    date_done__gte=timezone.now() - timedelta(days=7),
).order_by('-date_done')[:50]
```

**SQL**:
```sql
SELECT id, task_id, task_name, status, result, date_done,
       traceback, task_args, task_kwargs
FROM django_celery_results_taskresult
WHERE (task_args LIKE '%{user_id}%' OR task_kwargs LIKE '%{user_id}%')
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 50;
```

**Performance**: 200–2000ms depending on table size.
**Index**: None on `task_args`/`task_kwargs` — full text scan.
⚠ **Safety**: `LIKE '%...%'` does not use indexes. **Always include `date_done` filter** to limit scan scope. Reduce interval for large tables.

---

### 8.3 Failed Tasks for Loan-to-Lender Pipeline

**Description**: Retrieve failed Celery tasks in the loan-to-lender workflow for a specific user.

**Source**: [05-celery-workflows.md](05-celery-workflows.md) Workflow 1, [02-user-flows/approval-workflow.md](02-user-flows/approval-workflow.md) Q6

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'loan.tasks.share_oldest_loan_to_lender',
        'loan.tasks.send_invoice_to_saraloan',
        'loan.tasks.create_tranche_in_blacksoil',
        'loan.tasks.create_invoice_in_blacksoil',
        'loan.tasks.update_subvention_details_in_saraloan',
        'credit_line.tasks.process_saraloan_loan_webhook',
    ],
    status='FAILURE',
    task_args__contains='{user_id}',
    date_done__gte=timezone.now() - timedelta(days=30),
).values(
    'task_id', 'task_name', 'status', 'result',
    'date_created', 'date_done', 'traceback'
).order_by('-date_done')[:20]
```

**SQL**:
```sql
SELECT task_id, task_name, status, result,
       date_created, date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE task_name IN (
    'loan.tasks.share_oldest_loan_to_lender',
    'loan.tasks.send_invoice_to_saraloan',
    'loan.tasks.create_tranche_in_blacksoil',
    'loan.tasks.create_invoice_in_blacksoil',
    'loan.tasks.update_subvention_details_in_saraloan',
    'credit_line.tasks.process_saraloan_loan_webhook'
)
  AND status = 'FAILURE'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '30 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: < 500ms with date filter.
**Index**: `django_celery_results_taskresult(task_name, status)`.
⚠ **Safety**: `LIKE` on `task_args` adds scan cost. Always include `date_done` filter.

---

### 8.4 Repayment Sync Task History

**Description**: Retrieve task results for repayment sync workflow tasks.

**Source**: [05-celery-workflows.md](05-celery-workflows.md) Workflow 2, [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q8

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'payment.tasks.sync_repayment_info_for_all_dc',
        'payment.tasks.fetch_and_update_repayments_info',
        'payment.tasks.process_repayment_data',
        'payment.tasks.process_saraloan_repayment_webhook',
    ],
    task_args__contains='{user_id}',
    date_done__gte=timezone.now() - timedelta(days=30),
).values(
    'task_id', 'task_name', 'status', 'result',
    'date_created', 'date_done', 'traceback'
).order_by('-date_done')[:20]
```

**SQL**:
```sql
SELECT task_id, task_name, status, result,
       date_created, date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE task_name IN (
    'payment.tasks.sync_repayment_info_for_all_dc',
    'payment.tasks.fetch_and_update_repayments_info',
    'payment.tasks.process_repayment_data',
    'payment.tasks.process_saraloan_repayment_webhook'
)
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '30 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: < 500ms with date filter.
**Index**: `django_celery_results_taskresult(task_name, date_done)`.
⚠ **Safety**: `LIKE` on `task_args` adds scan cost. Always include `date_done` filter.

---

### 8.5 Credit Line Sync Task History

**Description**: Retrieve task results for credit line sync from Saraloan. Requires looking up `CustomerCreditLine` IDs first.

**Source**: [05-celery-workflows.md](05-celery-workflows.md) Workflow 3, [02-user-flows/credit-limit-calculation.md](02-user-flows/credit-limit-calculation.md) Q6

**SQL**:
```sql
-- Step 1: Get CCL IDs for user
SELECT ccl.id
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';

-- Step 2: Search task results by CCL ID (substitute {ccl_id} from step 1)
SELECT task_id, task_name, status, result,
       date_created, date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE task_name IN (
    'credit_line.tasks.sync_credit_line_info_from_saraloan',
    'credit_line.tasks.fetch_and_update_credit_line_info'
)
  AND task_args LIKE '%{ccl_id}%'
  AND date_done >= NOW() - INTERVAL '30 days'
ORDER BY date_done DESC
LIMIT 10;
```

**Performance**: Step 1 < 10ms. Step 2 < 500ms with date filter.
**Index**: Step 1 uses `credit_line_customer.source_identifier_id`. Step 2 uses `task_name`.
⚠ **Safety**: Two-step query. Always include `date_done` filter on step 2.

---

### 8.6 Risk Evaluation Task History

**Description**: Retrieve task results for risk evaluation tasks (credit line status update, FinBox, overdue notifications).

**Source**: [02-user-flows/risk-evaluation.md](02-user-flows/risk-evaluation.md) Query 8

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'credit_line.tasks.update_credit_lines_status',
        'credit_line.tasks.get_aged_outstanding_status_info',
        'credit_line.tasks.collect_user_profile_data_from_finbox',
        'credit_line.tasks.get_finbox_data',
        'credit_line.tasks.notify_overdue_partners_v2',
        'credit_line.tasks.verify_OD_and_OS_and_send_notifs_if_required',
    ],
    task_args__contains='{user_id}',
    date_done__gte=timezone.now() - timedelta(days=7),
).values(
    'task_id', 'task_name', 'status', 'date_done', 'result', 'traceback'
).order_by('-date_done')[:20]
```

**SQL**:
```sql
SELECT task_id, task_name, status, date_done, result, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'credit_line.tasks.update_credit_lines_status',
    'credit_line.tasks.get_aged_outstanding_status_info',
    'credit_line.tasks.collect_user_profile_data_from_finbox',
    'credit_line.tasks.get_finbox_data',
    'credit_line.tasks.notify_overdue_partners_v2',
    'credit_line.tasks.verify_OD_and_OS_and_send_notifs_if_required'
)
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: < 500ms with date filter.
**Index**: `django_celery_results_taskresult(task_name)`.
⚠ **Safety**: `LIKE` on `task_args` — always include `date_done` filter.

---

### 8.7 Reconciliation Task History

**Description**: Retrieve task results for reconciliation workflow tasks.

**Source**: [05-celery-workflows.md](05-celery-workflows.md) Workflow 5

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'loan.tasks.check_and_run_reconciliation_for_all_customers',
        'loan.tasks.run_reconciliation_for_customers',
        'loan.utility.run_reconciliation_for_customer_main',
        'loan.tasks.fire_loan_reconciliation_event',
        'loan.tasks.fire_locus_reconciliation_event',
    ],
    task_args__contains='{user_id}',
    date_done__gte=timezone.now() - timedelta(days=30),
).values(
    'task_id', 'task_name', 'status', 'result',
    'date_done', 'traceback'
).order_by('-date_done')[:20]
```

**SQL**:
```sql
SELECT task_id, task_name, status, result,
       date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE task_name IN (
    'loan.tasks.check_and_run_reconciliation_for_all_customers',
    'loan.tasks.run_reconciliation_for_customers',
    'loan.utility.run_reconciliation_for_customer_main',
    'loan.tasks.fire_loan_reconciliation_event',
    'loan.tasks.fire_locus_reconciliation_event'
)
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '30 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: < 500ms with date filter.
**Index**: `django_celery_results_taskresult(task_name, date_done)`.
⚠ **Safety**: `LIKE` on `task_args` — always include `date_done` filter.

---

### 8.8 Payment Transfer Task History

**Description**: Retrieve task results for payment aggregation and transfer tasks. Requires looking up `AggregatedPaymentTransfer` IDs first.

**Source**: [05-celery-workflows.md](05-celery-workflows.md) Workflow 4

**SQL**:
```sql
-- Step 1: Get aggregated payment IDs for user
SELECT apt.id
FROM payment_aggregatedpaymenttransfer apt
JOIN credit_line_customer c ON apt.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';

-- Step 2: Search task results (substitute {agg_id} from step 1)
SELECT task_id, task_name, status, result,
       date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE task_name IN (
    'payment.tasks.aggregate_ccl_payment_transfer',
    'payment.tasks.transfer_agg_payment',
    'payment.tasks.sync_aggregated_payment'
)
  AND task_args LIKE '%{agg_id}%'
  AND date_done >= NOW() - INTERVAL '30 days'
ORDER BY date_done DESC
LIMIT 10;
```

**Performance**: Step 1 < 50ms. Step 2 < 500ms with date filter.
**Index**: Step 1 uses `payment_aggregatedpaymenttransfer(customer_id)`. Step 2 uses `task_name`.
⚠ **Safety**: Two-step query. Always include `date_done` filter.

---

### 8.9 Task Execution Summary by Status (Last 7 Days)

**Description**: Count task executions grouped by task name and status for a user.

**Source**: [05-celery-workflows.md](05-celery-workflows.md)

**SQL**:
```sql
SELECT task_name, status, COUNT(*) AS count
FROM django_celery_results_taskresult
WHERE task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
GROUP BY task_name, status
ORDER BY task_name, status;
```

**Performance**: 500–3000ms depending on table size.
**Index**: None on `task_args`.
⚠ **Safety**: Full scan on `task_args`. **Always use date filter.** Reduce interval for large tables.

---

### 8.10 Tasks Stuck in STARTED State (Potential Hangs)

**Description**: Find tasks that have been in STARTED state for more than 10 minutes — potential hangs or zombie tasks.

**Source**: [05-celery-workflows.md](05-celery-workflows.md), [08-failure-scenarios.md](08-failure-scenarios.md) §1.3

**SQL**:
```sql
SELECT id, task_id, task_name, date_done, task_args
FROM django_celery_results_taskresult
WHERE status = 'STARTED'
  AND date_done <= NOW() - INTERVAL '10 minutes'
  AND task_args LIKE '%{user_id}%'
ORDER BY date_done DESC;
```

**Performance**: < 100ms.
**Index**: `django_celery_results_taskresult(status, date_done)`.
**Safety**: Lightweight with status filter.

---

### 8.11 Retried Tasks (Transient Failures)

**Description**: Find tasks in RETRY state indicating transient failures with automatic retry.

**Source**: [05-celery-workflows.md](05-celery-workflows.md), [08-failure-scenarios.md](08-failure-scenarios.md) §1.2

**SQL**:
```sql
SELECT id, task_id, task_name, status, result,
       date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE status = 'RETRY'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Performance**: < 200ms.
**Index**: `django_celery_results_taskresult(status, date_done)`.
⚠ **Safety**: `LIKE` on `task_args` — include `date_done` filter.

---

## 9. External API / Webhook Queries

### 9.1 Webhook Events for a User (Disbursal)

**Description**: Retrieve Saraloan webhook events for disbursal notifications.

**Source**: [02-user-flows/approval-workflow.md](02-user-flows/approval-workflow.md) Q5, [03-runtime-data.md](03-runtime-data.md) §3.5

**ORM**:
```python
from external.models import ExternalWebhook

ExternalWebhook.objects.filter(
    data__identifiers__partner_lead_id='{user_id}'
).values(
    'id', 'event', 'data', 'created_at'
).order_by('-created_at')[:20]
```

**SQL**:
```sql
SELECT id, event, data, created_at
FROM external_externalwebhook
WHERE data::jsonb -> 'identifiers' ->> 'partner_lead_id' = '{user_id}'
ORDER BY created_at DESC
LIMIT 20;
```

**Performance**: Variable — depends on table size.
**Index**: None on JSON field.
⚠ **Safety**: JSON field query without index. **Always add date range filter for production**:
```sql
AND created_at >= NOW() - INTERVAL '7 days'
```

---

### 9.2 Webhook Events for Repayment Notifications

**Description**: Retrieve Saraloan webhook events specifically for repayment events.

**Source**: [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q9

**SQL**:
```sql
SELECT id, event, data, created_at
FROM external_externalwebhook
WHERE data::jsonb -> 'identifiers' ->> 'partner_lead_id' = '{user_id}'
  AND event IN ('repayment_done', 'repayment_captured', 'repayment_bounced')
ORDER BY created_at DESC
LIMIT 20;
```

**Performance**: Variable.
**Index**: None on JSON field.
⚠ **Safety**: JSON field query without index. **Always add date range filter**:
```sql
AND created_at >= NOW() - INTERVAL '7 days'
```

---

## 10. History / Audit Queries

### 10.1 Credit Line Change History (via `django-simple-history`)

**Description**: Trace when and how credit limits, status, and other fields changed over time.

**Source**: [02-user-flows/credit-limit-calculation.md](02-user-flows/credit-limit-calculation.md) Q3, [03-runtime-data.md](03-runtime-data.md) §2.3, [06-playbooks/credit-eligibility-playbook.md](06-playbooks/credit-eligibility-playbook.md) Step 6

**ORM**:
```python
from credit_line.model import CustomerCreditLine

ccl = CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).first()

ccl.history.all().values(
    'history_date', 'history_type', 'history_user__username',
    'credit_limit', 'operational_limit', 'available_credit_limit',
    'lender_available_credit_limit', 'principal_outstanding',
    'previous_credit_limit', 'status', 'sub_status'
).order_by('-history_date')[:20]
```

**SQL**:
```sql
SELECT h.history_date, h.history_type, au.username,
       h.credit_limit, h.operational_limit, h.available_credit_limit,
       h.lender_available_credit_limit, h.principal_outstanding,
       h.previous_credit_limit, h.status, h.sub_status
FROM credit_line_historicalcustomercreditline h
LEFT JOIN auth_user au ON h.history_user_id = au.id
WHERE h.customer_id = (
    SELECT id FROM credit_line_customer
    WHERE source_identifier_id = '{user_id}'
)
ORDER BY h.history_date DESC
LIMIT 20;
```

**Performance**: < 50ms with LIMIT.
**Index**: `credit_line_historicalcustomercreditline(customer_id)`.
⚠ **Safety**: History tables can be very large. **Always use `LIMIT`** and consider adding date range:
```sql
AND h.history_date >= NOW() - INTERVAL '30 days'
```

---

### 10.2 Credit Line Status Change History (Risk Evaluation)

**Description**: Focused history view for risk-related fields: status, sub_status, aged_outstanding_amount, business_override.

**Source**: [02-user-flows/risk-evaluation.md](02-user-flows/risk-evaluation.md) Query 9

**SQL**:
```sql
SELECT h.id, h.status, h.sub_status, h.aged_outstanding_amount,
       h.repayment_unblock_amount, h.business_override,
       h.history_date, h.history_type, h.history_change_reason
FROM credit_line_historicalcustomercreditline h
JOIN credit_line_customercreditline ccl ON h.id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY h.history_date DESC
LIMIT 50;
```

**Performance**: < 100ms with date range filter.
**Index**: History table indexed by `id`.
⚠ **Safety**: History tables can grow large. **Add `AND h.history_date >= '{start_date}'`** for production queries.

---

### 10.3 Customer `is_credit_allowed` Change History

**Description**: Trace who changed the `is_credit_allowed` flag and when.

**Source**: [06-playbooks/credit-eligibility-playbook.md](06-playbooks/credit-eligibility-playbook.md) Step 2, [07-hypothesis-validation.md](07-hypothesis-validation.md) §1.1

**SQL**:
```sql
SELECT h.history_date, h.history_type, h.is_credit_allowed, au.username
FROM credit_line_historicalcustomer h
LEFT JOIN auth_user au ON h.history_user_id = au.id
WHERE h.source_identifier_id = '{user_id}'
  AND h.history_date >= NOW() - INTERVAL '30 days'
ORDER BY h.history_date DESC
LIMIT 10;
```

**Performance**: < 50ms with date filter.
**Index**: `credit_line_historicalcustomer(source_identifier_id)`.
**Safety**: Lightweight with date filter.

---

## 11. Cross-Table Consistency Queries

### 11.1 Payment-to-Ledger Cross-Reference (Mismatch Detection)

**Description**: Cross-reference payments with their corresponding ledger entries to detect orphaned payments or amount mismatches.

**Source**: [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q4, [03-runtime-data.md](03-runtime-data.md) §4.4, [06-playbooks/repayment-playbook.md](06-playbooks/repayment-playbook.md) Step 4, [08-failure-scenarios.md](08-failure-scenarios.md) §5

**SQL**:
```sql
SELECT p.id AS payment_id, p.payment_amount, p.status AS payment_status,
       p.settlement_date, le.id AS ledger_id, le.amount AS ledger_amount,
       le.active AS ledger_active, le.visible AS ledger_visible,
       le.unrealized_payment
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
LEFT JOIN ledger_ledgerentry le ON le.locus_id = p.id AND le.type = 'PAYMENT'
WHERE c.source_identifier_id = '{user_id}'
ORDER BY p.created_at DESC;
```

**Performance**: < 50ms.
**Index**: `payment_payment(customer_credit_line_id)`, `ledger_ledgerentry(locus_id, type)`.
**Safety**: Lightweight.

---

### 11.2 Orphaned Payments (No Ledger Entry)

**Description**: Detect POSTED payments that have no corresponding ledger entry — indicates a data inconsistency.

**Source**: [02-user-flows/repayment-workflow.md](02-user-flows/repayment-workflow.md) Q10, [08-failure-scenarios.md](08-failure-scenarios.md) §5

**SQL**:
```sql
SELECT p.id, p.lender_payment_id, p.payment_amount,
       p.payment_date, p.created_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
LEFT JOIN ledger_ledgerentry le ON le.locus_id = p.id AND le.type = 'PAYMENT'
WHERE c.source_identifier_id = '{user_id}'
  AND p.status = 'POSTED'
  AND le.id IS NULL
ORDER BY p.created_at DESC;
```

**Performance**: < 50ms.
**Index**: `payment_payment(customer_credit_line_id, status)`, `ledger_ledgerentry(locus_id, type)`.
**Safety**: Lightweight.

---

### 11.3 Credit Line Outstanding vs Loan Sum Consistency

**Description**: Compare stored `outstanding_amount` on credit lines against the computed sum of active loan `remaining_amount` values and posted payment `reconcilable_amount`.

**Source**: [06-playbooks/credit-eligibility-playbook.md](06-playbooks/credit-eligibility-playbook.md) Step 9, [08-failure-scenarios.md](08-failure-scenarios.md) §5.3

**SQL**:
```sql
SELECT ccl.id AS credit_line_id,
       cp.credit_product_name,
       ccl.credit_limit,
       ccl.operational_limit,
       ccl.available_credit_limit,
       ccl.outstanding_amount,
       ccl.principal_outstanding,
       ccl.lender_available_credit_limit,
       ccl.lender_outstanding_amount,
       ccl.overdue_amount,
       ccl.unrealised_outstanding_payment,
       ccl.lender_advance_payment,
       ccl.updated_at,
       (SELECT COALESCE(SUM(ll.remaining_amount), 0)
        FROM loan_loan ll
        WHERE ll.customer_credit_line_id = ccl.id
          AND ll.status NOT IN ('REJECTED', 'CANCELLED', 'PAID')
       ) AS computed_loan_outstanding,
       (SELECT COALESCE(SUM(pp.reconcilable_amount), 0)
        FROM payment_payment pp
        WHERE pp.customer_credit_line_id = ccl.id
          AND pp.status = 'POSTED'
       ) AS posted_payment_reconcilable
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: < 100ms.
**Index**: Subqueries use indexed FKs on `loan_loan(customer_credit_line_id)` and `payment_payment(customer_credit_line_id)`.
⚠ **Safety**: For users with many loans/payments, subqueries may be slower. Still read-only and safe.

---

### 11.4 Loan Amount vs Disbursed Amount Mismatch

**Description**: Detect loans where `disbursed_amount` differs from `loan_amount` — indicates partial disbursal or data inconsistency.

**Source**: [08-failure-scenarios.md](08-failure-scenarios.md) §5.1

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.disbursed_amount, ll.remaining_amount,
       ll.transaction_date, ll.disbursement_date,
       cp.credit_product_name
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status = 'DISBURSED'
  AND ll.disbursed_amount != ll.loan_amount;
```

**Performance**: < 30ms.
**Index**: `loan_loan(customer_credit_line_id)`.
**Safety**: Lightweight.

---

### 11.5 Ledger Entry Missing for Disbursed Loan

**Description**: Detect disbursed loans that have no corresponding ledger entry — indicates a missing ledger record.

**Source**: [08-failure-scenarios.md](08-failure-scenarios.md) §5.5

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.loan_amount, ll.disbursement_date,
       ll.status, cp.credit_product_name
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
LEFT JOIN ledger_ledgerentry le ON le.source_no = ll.loan_id
  AND le.partner_id = c.source_identifier_id
  AND le.type = 'PURCHASE'
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status IN ('DISBURSED', 'PARTIALLY_PAID', 'OVERDUE', 'PAID')
  AND le.id IS NULL;
```

**Performance**: < 50ms.
**Index**: `loan_loan(customer_credit_line_id)`, `ledger_ledgerentry(partner_id, type)`.
**Safety**: Lightweight.

---

### 11.6 Orphaned LenderLoanMap Records

**Description**: Detect `LenderLoanMap` records whose parent loan has been cancelled or rejected — indicates stale lender mappings.

**Source**: [08-failure-scenarios.md](08-failure-scenarios.md) §5.4

**SQL**:
```sql
SELECT llm.id, ll.loan_id, ll.status AS loan_status,
       llm.invoice_upload_status, llm.invoice_status_at_lender,
       llm.created_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status IN ('CANCELLED', 'REJECTED');
```

**Performance**: < 30ms.
**Index**: `loan_lenderloanmap(loan_id)`.
**Safety**: Lightweight.

---

## Quick Reference: Index Summary

| Table | Key Indexed Columns | Notes |
|-------|-------------------|-------|
| `credit_line_customer` | `source_identifier_id` (unique) | Primary user lookup |
| `credit_line_customercreditline` | `(customer_id, credit_product_id)` | Credit line lookup |
| `credit_line_customerlendermap` | `customer_id` | Lender mapping lookup |
| `loan_loan` | `customer_credit_line_id`, `status` | Loan lookup |
| `loan_lenderloanmap` | `loan_id` | Lender loan map lookup |
| `loan_invoiceloanmap` | `loan_id` | Invoice-loan mapping |
| `payment_payment` | `customer_credit_line_id`, `status`, `sub_status` | Payment lookup |
| `payment_creditnote` | `customer_credit_line_id` | Credit note lookup |
| `payment_aggregatedpaymenttransfer` | `customer_id` | Aggregated transfer lookup |
| `ledger_ledgerentry` | `partner_id`, `type`, `locus_id` | Ledger lookup |
| `repayment_transaction` | `transaction_type`, `active` | Transaction lookup |
| `repayment_demandsheet` | `user_id` | Demand sheet lookup |
| `repayment_customervirtualaccount` | `(customer_id, credit_product_id)` (unique) | Virtual account lookup |
| `invoice_invoice` | `partner_id` | Invoice lookup |
| `django_celery_results_taskresult` | `task_id` (unique), `task_name`, `status`, `date_done` | Task result lookup |
| `external_externalwebhook` | `created_at` | Webhook lookup (no JSON index) |
| `lead_lead` | `partner_id` | Lead lookup |
| `credit_line_finboxdata` | `customer_id` (unique) | FinBox data lookup |
| `credit_line_historicalcustomercreditline` | `customer_id` | History lookup |
| `credit_line_historicalcustomer` | `source_identifier_id` | Customer history lookup |

---

## Safety Guidelines

1. **Always use `LIMIT`** on queries against history tables (`credit_line_historicalcustomercreditline`, `credit_line_historicalcustomer`) and task result tables (`django_celery_results_taskresult`).
2. **Always add `date_done` / `date` / `created_at` filters** on queries that use `LIKE '%...%'` on text fields (`task_args`, `task_kwargs`).
3. **Webhook queries** (`external_externalwebhook`) use JSON field lookups without indexes — always add `created_at` date range filters.
4. **Ledger queries** for users with high transaction volume (1000+ entries) should include date range filters.
5. All queries in this document are **read-only** (`SELECT` only) and safe for production use with the recommended filters applied.
