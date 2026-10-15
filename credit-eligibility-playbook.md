# Playbook: Credit Eligibility Investigation

> Step-by-step debugging procedure for investigating why a user cannot access credit or sees unexpected credit eligibility results.
> All queries are **read-only** (`SELECT` only) and accept `{user_id}` (`source_identifier_id` / `partner_id`) as input.

**Cross-references**:
- Flow: [`02-user-flows/credit-eligibility.md`](../02-user-flows/credit-eligibility.md)
- Decision Logic: [`04-decision-logic.md`](../04-decision-logic.md) — Branches 1.1–1.3, 7.1–7.7
- Runtime Data: [`03-runtime-data.md`](../03-runtime-data.md) — Section 1

---

## Common Hypotheses

| # | Hypothesis | Summary | Jump To |
|---|-----------|---------|---------|
| H1 | Credit not allowed | `Customer.is_credit_allowed` is `False` | [Step 2](#step-2-check-is_credit_allowed-flag) |
| H2 | Credit line inactive | `CustomerCreditLine.status` is `ONHOLD` or `DORMANT` | [Step 3](#step-3-retrieve-credit-lines-and-check-status) |
| H3 | Credit product mismatch | No credit line exists for the expected product, or product is misconfigured | [Step 4](#step-4-verify-credit-product-configuration) |
| H4 | Lender limit exhausted | `lender_available_credit_limit` is 0 or negative; lender status is `INACTIVE`/`OVERDUE` | [Step 5](#step-5-check-lender-limits-and-lender-status) |
| H5 | Operational limit capped | `operational_limit` is lower than expected or `None` | [Step 6](#step-6-check-operational-limit) |
| H6 | External lender not supported | `Customer.external_lender_supported` is `False` when lender line is expected | [Step 2](#step-2-check-is_credit_allowed-flag) |
| H7 | Overdue threshold breached | Automated status change to `ONHOLD / AGED OUTSTANDING` | [Step 7](#step-7-check-overdue-threshold-breach) |

---

## Step 1: Verify Customer Exists

**Goal**: Confirm the customer record exists in Locus. If not, the API returns HTTP 422.

**ORM**:
```python
from credit_line.model import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'source_identifier_id', 'name', 'customer_type__name'
)
```

**SQL**:
```sql
SELECT c.id, c.source_identifier_id, c.name, ct.name AS customer_type
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Unique index on `credit_line_customer.source_identifier_id`. Expected < 10ms.

**What to Check**:
- Does a row exist?
- What is the `customer_type` (`DC` or `Farmer`)?

**Decision**:
- **No row returned** → Customer does not exist in Locus. The `ListCreditLines.get()` endpoint (`credit_line/views.py:138`) returns 422 "Credit Line not found". Investigate upstream onboarding.
- **Row exists** → Proceed to [Step 2](#step-2-check-is_credit_allowed-flag).

---

## Step 2: Check `is_credit_allowed` Flag

**Goal**: Determine if credit is globally blocked for this customer. This boolean field on `Customer` gates all credit operations.

> Decision Logic ref: [`04-decision-logic.md`](../04-decision-logic.md) Branch 1.1

**ORM**:
```python
from credit_line.model import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'is_credit_allowed', 'external_lender_supported',
    'lender_supported_status', 'overdue_credit_limit',
    'overdue_threshold_limit', 'limit_enhancement_amount'
)
```

**SQL**:
```sql
SELECT c.id, c.is_credit_allowed, c.external_lender_supported,
       c.lender_supported_status, c.overdue_credit_limit,
       c.overdue_threshold_limit, c.limit_enhancement_amount
FROM credit_line_customer c
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Unique index on `source_identifier_id`. Expected < 10ms.

**What to Check**:
- `is_credit_allowed`: Is it `True` or `False`?
- `external_lender_supported`: Is the customer expected to use external lenders?
- `lender_supported_status`: Current onboarding/deboarding state.

**Decision**:
- **`is_credit_allowed = False`** → **Hypothesis H1 confirmed**. Credit is blocked at the customer level. This field is set via admin upload (`UPDATE_IS_CREDIT_ALLOWED` action in `CustomerCreditLineUpload`). Check who changed it:
  ```sql
  SELECT h.history_date, h.history_type, h.is_credit_allowed, au.username
  FROM credit_line_historicalcustomer h
  LEFT JOIN auth_user au ON h.history_user_id = au.id
  WHERE h.source_identifier_id = '{user_id}'
    AND h.history_date >= NOW() - INTERVAL '30 days'
  ORDER BY h.history_date DESC
  LIMIT 10;
  ```
  **Performance**: Expected < 50ms with date filter.
- **`is_credit_allowed = True`** → Proceed to [Step 3](#step-3-retrieve-credit-lines-and-check-status).
- **`external_lender_supported = False` but lender line expected** → **Hypothesis H6 confirmed**. Check `lender_supported_status` for onboarding state. See [`04-decision-logic.md`](../04-decision-logic.md) Branch 4.1–4.5.

---

## Step 3: Retrieve Credit Lines and Check Status

**Goal**: Fetch all credit lines for the user and inspect their `status` / `sub_status` combinations.

> Decision Logic ref: [`04-decision-logic.md`](../04-decision-logic.md) Branch 1.2, 1.3

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).select_related('credit_product').values(
    'id', 'status', 'sub_status', 'lender_status',
    'credit_limit', 'operational_limit', 'available_credit_limit',
    'lender_available_credit_limit', 'outstanding_amount',
    'overdue_amount', 'business_override', 'lender_stress_case',
    'effective_from', 'effective_to',
    'credit_product__credit_product_name',
    'credit_product__belongs_to_gapl'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.status, ccl.sub_status, ccl.lender_status,
       ccl.credit_limit, ccl.operational_limit,
       ccl.available_credit_limit, ccl.lender_available_credit_limit,
       ccl.outstanding_amount, ccl.overdue_amount,
       ccl.business_override, ccl.lender_stress_case,
       ccl.effective_from, ccl.effective_to,
       cp.credit_product_name, cp.belongs_to_gapl
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 20ms.

**What to Check**:
- How many credit lines exist? (Typically one GAPL line + zero or more lender lines.)
- For each line: what is the `status` / `sub_status` pair?
- Valid combinations (enforced by DB constraint `valid_sub_status`):
  - `ACTIVE` / `ACTIVE`
  - `ONHOLD` / `AGED OUTSTANDING`, `REPAYMENT FREQUENCY`, `ONBOARDING POD`, `MISCELLANEOUS`
  - `DORMANT` / `OUTSTANDING REMAINING`, `CLOSED`

**Decision**:
- **No credit lines returned** → Customer exists but has no credit line. Investigate onboarding or data migration.
- **All lines `DORMANT / CLOSED`** → **Hypothesis H2 confirmed**. Credit line is fully closed. No credit operations possible.
- **Line is `DORMANT / OUTSTANDING REMAINING`** → Credit line is inactive but has remaining outstanding. Overdue amounts still contribute to totals. No new credit.
- **Line is `ONHOLD / AGED OUTSTANDING`** → **Hypothesis H2 confirmed** (variant). Automated hold due to overdue threshold breach. Go to [Step 7](#step-7-check-overdue-threshold-breach).
- **Line is `ONHOLD / REPAYMENT FREQUENCY`** → Hold due to repayment frequency breach. Check `repayment_unblock_amount` on the credit line.
- **Line is `ONHOLD / ONBOARDING POD`** → Manual hold during onboarding. Check with operations team.
- **Line is `ONHOLD / MISCELLANEOUS`** → Manual hold. Check `comment` field for reason.
- **Line is `ACTIVE / ACTIVE`** → Status is fine. Proceed to [Step 4](#step-4-verify-credit-product-configuration).

---

## Step 4: Verify Credit Product Configuration

**Goal**: Confirm the credit product is correctly configured and matches expectations.

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

**Performance**: Uses join through indexed FKs. Expected < 10ms.

**What to Check**:
- Is there a GAPL line (`belongs_to_gapl = True`)? Every customer should have one.
- Is there a lender line (`belongs_to_gapl = False`)? Only if `external_lender_supported = True`.
- Known credit product names: `DeHaat-CL` (GAPL buffer), `ME-Blacksoil`, `ME-Adani_Capital`, `ME-Progcap`, `Farmer-Blacksoil`.
- Is `priority` set correctly? (Used for loan sharing order.)

**Decision**:
- **Missing GAPL line** → **Hypothesis H3 confirmed**. Customer was not properly onboarded. Check `CustomerCreditLineUpload` history.
- **Missing lender line when `external_lender_supported = True`** → **Hypothesis H3 confirmed** (variant). Lender credit line was not created or was set to DORMANT.
- **Product configuration looks correct** → Proceed to [Step 5](#step-5-check-lender-limits-and-lender-status).

---

## Step 5: Check Lender Limits and Lender Status

**Goal**: Verify lender-side credit availability. The `lender_available_credit_limit` is synced from Saraloan and determines how much credit the lender will fund.

> Decision Logic ref: [`04-decision-logic.md`](../04-decision-logic.md) Branch 7.1–7.7

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}',
    credit_product__belongs_to_gapl=False
).values(
    'id', 'credit_limit', 'lender_available_credit_limit',
    'lender_outstanding_amount', 'lender_advance_payment',
    'lender_status', 'unrealised_outstanding_payment',
    'principal_outstanding', 'available_credit_limit',
    'credit_product__credit_product_name',
    'updated_at'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.credit_limit, ccl.lender_available_credit_limit,
       ccl.lender_outstanding_amount, ccl.lender_advance_payment,
       ccl.lender_status, ccl.unrealised_outstanding_payment,
       ccl.principal_outstanding, ccl.available_credit_limit,
       cp.credit_product_name, ccl.updated_at
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = false;
```

**Performance**: Index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 10ms.

**What to Check**:
- `lender_available_credit_limit`: Is it > 0? If 0 or negative, lender has no remaining capacity.
- `lender_status`: `ACTIVE`, `INACTIVE`, or `OVERDUE`?
- `lender_outstanding_amount`: How much is currently outstanding with the lender?
- `updated_at`: When was this last synced? (Saraloan sync runs daily at 22:00.)

**Decision**:
- **`lender_available_credit_limit <= 0`** → **Hypothesis H4 confirmed**. Lender limit exhausted. Check if Saraloan sync ran recently:
  ```sql
  SELECT task_name, status, date_done, result
  FROM django_celery_results_taskresult
  WHERE task_name = 'credit_line.tasks.sync_credit_lines_info_from_saraloan'
    AND date_done >= NOW() - INTERVAL '2 days'
  ORDER BY date_done DESC
  LIMIT 5;
  ```
  **Performance**: Index on `task_name`. Expected < 50ms.
- **`lender_status = INACTIVE`** → Lender has deactivated this credit line. Check `CustomerLenderMap` for lender-side details. Go to [Step 5a](#step-5a-check-customerlendermap).
- **`lender_status = OVERDUE`** → Lender flagged overdue. If `business_override = False`, this forces `status = ONHOLD, sub_status = AGED OUTSTANDING` on save (see `CustomerCreditLine.save()` at `credit_line/model/customer_credit_line.py:306`).
- **`lender_status = ACTIVE` and limit > 0** → Lender side is fine. Proceed to [Step 6](#step-6-check-operational-limit).

### Step 5a: Check CustomerLenderMap

**ORM**:
```python
from credit_line.model import CustomerLenderMap

CustomerLenderMap.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'credit_product__credit_product_name',
    'business_id', 'loan_account_id', 'application_id',
    'created_at', 'updated_at'
)
```

**SQL**:
```sql
SELECT clm.id, cp.credit_product_name,
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
- Is `business_id` populated? (Required for Saraloan API calls.)
- Is `loan_account_id` populated? (Required for credit line sync.)

**Decision**:
- **No entry** → Lender mapping was never created. Check onboarding flow.
- **`business_id` is null/empty** → Saraloan sync cannot fetch data. Investigate Saraloan onboarding.
- **Entry exists with valid IDs** → Lender mapping is fine. Return to [Step 5](#step-5-check-lender-limits-and-lender-status) analysis.

---

## Step 6: Check Operational Limit

**Goal**: The `operational_limit` caps the effective credit limit. It is set via admin upload or the `update_operational_limit` pre_save signal.

> Decision Logic ref: [`04-decision-logic.md`](../04-decision-logic.md) Branch 2.1, 2.2

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'credit_limit', 'operational_limit',
    'available_credit_limit',
    'credit_product__credit_product_name',
    'credit_product__belongs_to_gapl'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.credit_limit, ccl.operational_limit,
       ccl.available_credit_limit,
       cp.credit_product_name, cp.belongs_to_gapl
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Expected < 10ms.

**What to Check**:
- `operational_limit`: Is it `NULL`, 0, or lower than `credit_limit`?
- The pre_save signal (`credit_line/signals.py:15–19`) enforces: `operational_limit = min(operational_limit, credit_limit)`. If `operational_limit` was `NULL`, it gets initialized to `credit_limit`.
- `available_credit_limit`: This is the effective limit used in the API response.

**Decision**:
- **`operational_limit` is 0 or very low** → **Hypothesis H5 confirmed**. Operational limit was manually reduced. Check history:
  ```sql
  SELECT h.history_date, h.operational_limit, h.credit_limit,
         au.username, h.history_type
  FROM credit_line_historicalcustomercreditline h
  LEFT JOIN auth_user au ON h.history_user_id = au.id
  WHERE h.customer_id = (
      SELECT id FROM credit_line_customer
      WHERE source_identifier_id = '{user_id}'
  )
  ORDER BY h.history_date DESC
  LIMIT 20;
  ```
  **Performance**: Expected < 50ms. **Warning**: History tables can be large; always use `LIMIT`.
- **`operational_limit >= credit_limit`** → Operational limit is not the bottleneck. Proceed to [Step 7](#step-7-check-overdue-threshold-breach).

---

## Step 7: Check Overdue Threshold Breach

**Goal**: The daily task `update_credit_lines_status` (`credit_line/tasks.py:2648`) automatically sets credit lines to `ONHOLD / AGED OUTSTANDING` when overdue amounts exceed the threshold.

> Decision Logic ref: [`04-decision-logic.md`](../04-decision-logic.md) Branch 8.1–8.5

**ORM**:
```python
from credit_line.model import CustomerCreditLine, Customer

customer = Customer.objects.get(source_identifier_id='{user_id}')

# Get overdue configuration
print(f"overdue_credit_limit: {customer.overdue_credit_limit}")
print(f"overdue_threshold_limit: {customer.overdue_threshold_limit}")

# Get credit line overdue data
CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'sub_status', 'overdue_amount',
    'business_override', 'lender_status',
    'credit_product__credit_product_name'
)
```

**SQL**:
```sql
-- Customer overdue configuration
SELECT c.overdue_credit_limit, c.overdue_threshold_limit,
       c.overdue_threshold_limit_end_date
FROM credit_line_customer c
WHERE c.source_identifier_id = '{user_id}';

-- Credit line overdue data
SELECT ccl.id, ccl.status, ccl.sub_status, ccl.overdue_amount,
       ccl.business_override, ccl.lender_status,
       cp.credit_product_name
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```

**Performance**: Expected < 10ms each.

**What to Check**:
- The automated hold condition is: `overdue_amount - overdue_credit_limit > overdue_threshold_limit AND NOT business_override`
- `overdue_credit_limit`: Allowed overdue buffer (default 1).
- `overdue_threshold_limit`: Maximum allowed overdue beyond the buffer (default 0).
- `business_override`: If `True`, automated status changes are blocked.

**Decision**:
- **`overdue_amount - overdue_credit_limit > overdue_threshold_limit` and `business_override = False`** → **Hypothesis H7 confirmed**. The daily task put this line on hold. To verify when:
  ```sql
  SELECT task_name, status, date_done, result
  FROM django_celery_results_taskresult
  WHERE task_name = 'credit_line.tasks.update_credit_lines_status'
    AND date_done >= NOW() - INTERVAL '7 days'
  ORDER BY date_done DESC
  LIMIT 5;
  ```
  **Performance**: Index on `task_name`. Expected < 50ms.
- **`business_override = True`** → Automated holds are bypassed. Status was set manually. Check the `comment` field and history.
- **Overdue is within threshold** → Overdue is not the issue. Proceed to [Step 8](#step-8-check-outstanding-loans-and-available-limit).

---

## Step 8: Check Outstanding Loans and Available Limit

**Goal**: Verify that the available credit limit is not consumed by outstanding loans and pending invoices.

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).exclude(
    status__in=['REJECTED', 'CANCELLED', 'PAID']
).values(
    'id', 'status', 'loan_amount', 'remaining_amount',
    'overdue_date', 'transaction_date',
    'customer_credit_line__credit_product__credit_product_name'
).order_by('-transaction_date')
```

**SQL**:
```sql
SELECT ll.id, ll.status, ll.loan_amount, ll.remaining_amount,
       ll.overdue_date, ll.transaction_date,
       cp.credit_product_name
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status NOT IN ('REJECTED', 'CANCELLED', 'PAID')
ORDER BY ll.transaction_date DESC;
```

**Performance**: Index on `loan_loan(customer_credit_line_id)`. Expected < 50ms.

**What to Check**:
- Sum of `remaining_amount` across active loans — this contributes to outstanding.
- Any loans in `OVERDUE` status? These affect the overdue calculation.
- Any loans stuck in `YET_TO_BE_DISBURSED` or `DRAFT`? These consume available limit but haven't been funded.

Also check pending invoices that reduce available credit:

```sql
SELECT id, status, amount, prepaid_amount, transaction_date
FROM invoice_invoice
WHERE partner_id = '{user_id}'
  AND status IN ('DRAFT', 'YET_TO_PROCESS', 'LOAN_CREATION_FAILED', 'INVOICE_CREATED');
```

**Performance**: Index on `invoice_invoice(partner_id)`. Expected < 20ms.

**Decision**:
- **Large outstanding consuming all available limit** → Credit limit is fully utilized. Not a bug — user needs to repay.
- **Loans stuck in `YET_TO_BE_DISBURSED`** → Loans are blocking limit but not disbursed. Investigate the loan-to-lender pipeline. See [`06-playbooks/loan-lifecycle-playbook.md`](loan-lifecycle-playbook.md).
- **Pending invoices consuming limit** → Invoices in `DRAFT`/`YET_TO_PROCESS` reduce available credit. Check if they are stale.
- **Available limit should be positive but isn't** → Possible data inconsistency. Proceed to [Step 9](#step-9-verify-data-consistency).

---

## Step 9: Verify Data Consistency

**Goal**: Cross-check computed values against source data to detect inconsistencies.

**SQL** (compare credit line available limit against loan/payment data):
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

**Performance**: Subqueries use indexed FKs. Expected < 100ms. **Warning**: For users with many loans/payments, this may be slower.

**What to Check**:
- Does `outstanding_amount` roughly match `computed_loan_outstanding`?
- Is `available_credit_limit` consistent with `credit_limit - outstanding`?
- Are there posted payments with `reconcilable_amount > 0` that haven't reduced outstanding?

**Decision**:
- **Values are consistent** → The system is working correctly; the user's credit is genuinely consumed.
- **Values are inconsistent** → Data inconsistency detected. Check when reconciliation last ran:
  ```sql
  SELECT task_name, status, date_done, result
  FROM django_celery_results_taskresult
  WHERE task_name = 'loan.tasks.check_and_run_reconciliation_for_all_customers'
    AND date_done >= NOW() - INTERVAL '3 days'
  ORDER BY date_done DESC
  LIMIT 5;
  ```
  Also check `Customer.locus_recon_last_ran_at`:
  ```sql
  SELECT locus_recon_last_ran_at
  FROM credit_line_customer
  WHERE source_identifier_id = '{user_id}';
  ```
  See failure scenarios: [`08-failure-scenarios.md`](../08-failure-scenarios.md).

---

## Quick Reference: Status/Sub-Status Matrix

| Status | Valid Sub-Statuses | Credit Operations | Automated Transition |
|--------|-------------------|-------------------|---------------------|
| `ACTIVE` | `ACTIVE` | Fully operational | Can be put `ONHOLD` by daily task |
| `ONHOLD` | `AGED OUTSTANDING` | Blocked | Auto: overdue threshold breach |
| `ONHOLD` | `REPAYMENT FREQUENCY` | Blocked | Auto: repayment frequency breach |
| `ONHOLD` | `ONBOARDING POD` | Blocked | Manual: during onboarding |
| `ONHOLD` | `MISCELLANEOUS` | Blocked | Manual: ops team |
| `DORMANT` | `OUTSTANDING REMAINING` | Blocked (outstanding still tracked) | Manual or lender closure |
| `DORMANT` | `CLOSED` | Fully closed | Manual or lender closure |

## Quick Reference: Lender Status Impact

| `lender_status` | `business_override` | Effect |
|-----------------|--------------------|---------| 
| `ACTIVE` | any | Normal operation |
| `INACTIVE` | any | Lender has deactivated the line |
| `OVERDUE` | `True` | No automated status change (override active) |
| `OVERDUE` | `False` | Forces `ONHOLD / AGED OUTSTANDING` on next save |
