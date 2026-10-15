# Flow: Credit Eligibility Check

> Traces the complete credit eligibility check flow from API entry through data aggregation, status resolution, and response serialization.
> This flow answers: "For a given `source_identifier_id`, what credit lines exist, what is their status, and is the user eligible for credit?"

**Primary Entry Point**: `GET /credit-line/business/<source_identifier_id>`
**View**: `credit_line/views.py:ListCreditLines.get()`

---

## Entry Points

| Entry Point | Method | user_id Location | File Path |
|-------------|--------|-----------------|-----------|
| `credit-line/business/<source_identifier_id>` | GET | URL path: `source_identifier_id` | `credit_line/views.py:ListCreditLines.get()` |
| `credit-line/v2/business/<source_identifier_id>` | GET | URL path: `source_identifier_id` | `credit_line/views.py:ListCreditLinesV2.get()` |
| `credit-line/dba/business/<farmer_auth_id>/<dc_sap_id>` | GET | URL path: `farmer_auth_id` | `credit_line/views.py:ListCreditLinesDBA.get()` |
| `credit-line/v1/business/creditlines` | GET | Request body: `source_identifier_ids` (comma-separated) | `credit_line/views.py:ListMultipleCustomersCreditLines.get()` |

---

## Execution Sequence

### V1 Flow: `ListCreditLines.get()`

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `ListCreditLines.get()` | `credit_line/views.py:135` | Entry point. Receives `source_identifier_id` from URL path. |
| 2 | `CustomerCreditLine.objects.filter(customer__source_identifier_id=...).first()` | `credit_line/views.py:138` | Checks if any credit line exists for the user. Returns 422 if not found. |
| 3 | `populate_all_credit_lines([source_identifier_id])` | `credit_line/utils.py:727` | Core aggregation: executes a large raw SQL query joining `credit_line_customer`, `credit_line_customercreditline`, `credit_line_creditproduct`, `loan_loan`, `payment_payment`, `payment_creditnote`, `payment_debitnote`, `invoice_invoice` to compute per-credit-line financial summaries (outstanding, available limit, overdue amounts, etc.). Returns `is_credit_allowed` from `Customer` model. |
| 4 | `get_limit_enhancement_status_and_amount_util(source_identifier_id)` | `credit_line/utils.py:4638` | Fetches `Customer.limit_enhancement_amount`. For non-farmer customers with enhancement amount, queries `Lead` model for enhancement status. |
| 5 | **Branch: Customer type check** | `credit_line/views.py:163` | If `customer_type.name == 'Farmer'` → step 5a. Else → step 5b. |
| 5a | `adjust_outstanding_amount_if_pending_emi_greater(source_identifier_id, response_data)` | `credit_line/utils.py:4582` | For farmers: queries `UserApplication` and `get_pending_emi_of_user()`. Adjusts `total_outstanding_amount` upward if pending EMI exceeds it. |
| 5b | `fetch_ledger_aggregated_data([source_identifier_id])` | `credit_line/utils.py:3920` | For DCs: executes raw SQL aggregating `ledger_ledgerentry` data — purchase amounts, payments, credit notes, debit entries/notes, financing fees, interest, app block calculations. Joins with `credit_line_customercreditline` for unrealised payments and `credit_line_creditproduct` for app block days. |
| 6 | Merge ledger data into response | `credit_line/views.py:169` | Updates response with ledger outstanding, financing fees, computed amounts. |
| 7 | `fetch_final_status_and_sub_status_of_credit_lines(credit_lines)` | `credit_line/utils.py:4341` | Iterates credit lines, separates GAPL vs lender lines, aggregates `aged_outstanding_amount`, determines `repayment_unblock_amount`. Calls `credit_line_status_sub_status_priority_wise()` and `finalise_credit_line_status_sub_status()` to compute final status/sub_status. |
| 8 | `get_save_interest_banner_details_map(response_data)` | `credit_line/utils.py:6153` | Computes save-interest banner visibility based on `interest_eligible_invoice_amount` and `interest_warning_invoice_amount`. Reads `ENABLE_SAVE_INTEREST_BANNER` app constant. |
| 9 | AutoPay configuration | `credit_line/views.py:237` | Reads `AUTOPAY_ENABLED_PARTNERS` and `DC_AUTO_PAY_SETUP_PARAMETERS` app constants to populate `auto_pay` response fields. |
| 10 | Log and return `Response(response_data)` | `credit_line/views.py:252` | Logs full response data, returns unserialized dict. |

### V2 Flow: `ListCreditLinesV2.get()` (additional steps)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `Customer.objects.get(source_identifier_id=...)` | `credit_line/views.py:315` | Fetches Customer object directly. Returns 422 if not found. |
| 2 | `populate_all_credit_lines([source_identifier_id])` | `credit_line/utils.py:727` | Same as V1 step 3. |
| 3 | `get_save_interest_amount(customer)` | `credit_line/utils.py:3461` | Calls `get_save_interest_amount_from_ledger()` in `ledger/utils.py:922` to compute save-interest amount from ledger entries. |
| 4 | `fetch_ledger_aggregated_data([source_identifier_id])` | `credit_line/utils.py:3920` | Always called (not conditional on customer type in V2). |
| 5 | `fetch_final_status_and_sub_status_of_credit_lines(credit_lines)` | `credit_line/utils.py:4341` | Same as V1 step 7. |
| 6 | Credit line iteration loop | `credit_line/views.py:380` | Iterates each credit line to compute aggregated totals: `total_available_credit_limit`, `total_credit_limit`, `overdue_amount`, `total_outstanding_amount`, etc. Applies DORMANT filtering logic. |
| 7 | `get_ageing_outstanding_message(...)` | `credit_line/utils.py` | Computes ageing banner message from oldest overdue date and overdue amount. |
| 8 | `get_min_os_amount_and_interest_amount_due(customer, interest_computation_date)` | `credit_line/utils.py` | Computes minimum outstanding and interest amounts due. |
| 9 | `get_minimum_repayment_amount_and_repayment_date(...)` | `credit_line/utils.py` | Computes minimum repayment amount from save_interest, overdue, and overdue_credit_limit. |
| 10 | Invoice/payment amount aggregations | `credit_line/utils.py` | Calls `get_total_invoice_amount()`, `get_total_credit_note_amount()`, `get_total_debit_entry_amount()`, `get_total_debit_note_amount()`, `get_total_interest_till_date()`, `get_total_payment_amount()`. |
| 11 | `CustomerCreditLineResponseSerializerV2(response_data)` | `credit_line/serializers.py:505` | Serializes response through V2 serializer. |

---

## Celery Tasks Triggered

This flow is **read-only** — no Celery tasks are directly triggered during the API request execution.

However, the following Celery tasks run on schedules and **affect the data read by this flow**:

| Task | Schedule | Queue | Effect on Flow |
|------|----------|-------|----------------|
| `credit_line.tasks.update_credit_lines_status` | Daily 02:00 | `celery` | Updates `CustomerCreditLine.status` and `sub_status` |
| `credit_line.tasks.sync_credit_lines_info_from_saraloan` | Daily 22:00 | `saraloan` | Syncs `lender_available_credit_limit`, `lender_outstanding_amount` from Saraloan |
| `credit_line.tasks.update_credit_limit_in_bulk` | On-demand | `celery` | Updates `credit_limit`, `operational_limit` |
| `credit_line.tasks.buffer_date_actions` | Daily 16:30 | `celery` | Manages buffer limit end dates, may change credit limits |
| `loan.tasks.check_and_run_reconciliation_for_all_customers` | Daily 04:00 | `reconciliation` | Updates loan statuses and remaining amounts that affect outstanding calculations |

---

## Database Tables Accessed

### Direct Queries (from `populate_all_credit_lines` raw SQL)

| Table | Alias in Query | Key Columns Used | Access Pattern |
|-------|---------------|-----------------|----------------|
| `credit_line_customer` | `clc` | `source_identifier_id`, `external_lender_supported`, `overdue_credit_limit`, `is_credit_allowed`, `overdue_credit_days`, `customer_type_id`, `overdue_threshold_limit` | Filter by `source_identifier_id IN (...)` |
| `credit_line_customercreditline` | `clc2` | `customer_id`, `credit_product_id`, `status`, `sub_status`, `credit_limit`, `operational_limit`, `lender_available_credit_limit`, `lender_outstanding_amount`, `unrealised_outstanding_payment`, `lender_advance_payment`, `principal_outstanding`, `total_interest_paid`, `total_interest_outstanding`, `overdue_days`, `lender_status`, `repayment_unblock_amount` | JOIN on `customer_id` |
| `credit_line_creditproduct` | `clc3` | `credit_product_name`, `belongs_to_gapl`, `unrealised_percentage`, `repayment_duration`, `interest_per_day`, `interest_warning_days` | JOIN on `credit_product_id` |
| `credit_line_customertype` | `clct` | `name` | JOIN on `customer_type_id` |
| `loan_loan` | `ll` | `customer_credit_line_id`, `status`, `loan_amount`, `remaining_amount`, `overdue_date`, `interest_free_period_end_date`, `transaction_date`, `total_interest`, `total_penal_interest`, `total_overdue_interest`, `total_processing_fee`, `remaining_principal`, `remaining_interest`, `remaining_penal_interest`, `remaining_overdue_interest`, `remaining_processing_fee` | JOIN on `customer_credit_line_id` |
| `payment_payment` | `pp` | `customer_credit_line_id`, `status`, `payment_amount`, `transfer_to_lender_amount`, `hold_amount`, `reconcilable_amount`, `payment_mode` | JOIN on `customer_credit_line_id` |
| `payment_creditnote` | `pc` | `customer_credit_line_id`, `status`, `amount`, `prepaid_amount`, `linked_invoice`, `is_instant_discount_cn` | JOIN on `customer_credit_line_id` |
| `payment_debitnote` | `pd` | `customer_credit_line_id`, `type` (DE/DN/DH), `status`, `amount`, `reconcilable_amount`, `date`, `credit_amount_settled`, `reason_id` | JOIN on `customer_credit_line_id` |
| `payment_debitnotereason` | `pdr` | `aging_days` | JOIN on `reason_id` |
| `invoice_invoice` | `ii` | `partner_id`, `status`, `amount`, `prepaid_amount`, `overdue_credit_date`, `transaction_date`, `erp_id` | Filter by `partner_id IN (...)` and `status IN ('DRAFT', 'YET_TO_PROCESS', 'LOAN_CREATION_FAILED', 'INVOICE_CREATED')` |

### Additional Queries (from `fetch_ledger_aggregated_data`)

| Table | Key Columns Used | Access Pattern |
|-------|-----------------|----------------|
| `ledger_ledgerentry` | `partner_id`, `type`, `amount`, `date`, `active`, `visible`, `source_no`, `outstanding_amount`, `paid_amount`, `credit_note_reason` | Filter by `partner_id IN (...)`, `active=true`, `visible=true` |
| `loan_invoiceloanmap` | `loan_id`, `invoice_id` | JOIN for app block interest calculation |

### ORM Queries

| Table | Query Location | Purpose |
|-------|---------------|---------|
| `credit_line_customer` | `ListCreditLines.get()` line 138 | Initial existence check via `CustomerCreditLine.objects.filter(customer__source_identifier_id=...)` |
| `credit_line_customer` | `get_limit_enhancement_status_and_amount_util()` | Fetch `limit_enhancement_amount`, `customer_type` |
| `farmer_financing_userapplication` | `adjust_outstanding_amount_if_pending_emi_greater()` | Farmer EMI lookup |
| `lead_lead` | `get_limit_enhancement_status_and_amount_util()` | Limit enhancement status for ELS customers |

---

## Decision Points

> Cross-reference: See `04-decision-logic.md` for full condition expressions and branch outcomes.

| # | Decision | Location | Condition | Outcomes |
|---|----------|----------|-----------|----------|
| D1 | Credit line exists? | `credit_line/views.py:140` | `CustomerCreditLine.objects.filter(...).first()` returns `None` | **None** → 422 response "Credit Line not found". **Found** → continue. |
| D2 | Customer type (Farmer vs DC) | `credit_line/views.py:163` | `customer_credit_line.customer.customer_type.name == 'Farmer'` | **Farmer** → call `adjust_outstanding_amount_if_pending_emi_greater()`. **DC** → call `fetch_ledger_aggregated_data()`. |
| D3 | `is_credit_allowed` | `credit_line/model/customer.py` | `Customer.is_credit_allowed` boolean field | Returned in `populate_all_credit_lines()` output. Consumed by frontend to gate credit operations. |
| D4 | Credit line status (ACTIVE / ONHOLD / DORMANT) | `credit_line/model/customer_credit_line.py` | `CustomerCreditLine.status` field | Determines available credit limit calculations and whether credit line is included in totals. DORMANT lines with `sub_status='OUTSTANDING REMAINING'` still contribute to overdue. |
| D5 | GAPL vs Lender credit line | `credit_line/model/credit_product.py` | `CreditProduct.belongs_to_gapl` boolean | Different outstanding and available limit formulas in `populate_all_credit_lines()` SQL. |
| D6 | External lender supported | `credit_line/model/customer.py` | `Customer.external_lender_supported` boolean | Affects available credit limit calculation and overdue computation for non-GAPL lines. |
| D7 | Final status resolution | `credit_line/utils.py:4341` | Priority-based merge of GAPL and lender line statuses | Calls `credit_line_status_sub_status_priority_wise()` then `finalise_credit_line_status_sub_status()`. |
| D8 | Limit enhancement eligibility | `credit_line/utils.py:4638` | `customer.limit_enhancement_amount` is not None/0 | If set and ELS → query `Lead` for status. If set and non-ELS → call `get_lead_status()`. |

---

## Investigation Queries

### Q1: Check if customer exists and credit is allowed

**ORM**:
```python
from credit_line.model import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'source_identifier_id', 'name', 'is_credit_allowed',
    'external_lender_supported', 'customer_type__name',
    'overdue_credit_limit', 'overdue_threshold_limit',
    'limit_enhancement_amount', 'lender_supported_status'
)
```

**SQL**:
```sql
SELECT c.id, c.source_identifier_id, c.name, c.is_credit_allowed,
       c.external_lender_supported, ct.name AS customer_type,
       c.overdue_credit_limit, c.overdue_threshold_limit,
       c.limit_enhancement_amount, c.lender_supported_status
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';
```
**Performance**: Uses unique index on `credit_line_customer.source_identifier_id`. Expected < 10ms.

---

### Q2: Retrieve all credit lines for a user with product and lender details

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
    'credit_product__credit_product_name', 'credit_product__belongs_to_gapl',
    'credit_product__unrealised_percentage',
    'credit_product__interest_per_day',
    'credit_product__repayment_duration',
    'credit_product__interest_warning_days',
    'credit_product__app_block_days'
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
       cp.credit_product_name, cp.belongs_to_gapl,
       cp.unrealised_percentage, cp.interest_per_day,
       cp.repayment_duration, cp.interest_warning_days, cp.app_block_days
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```
**Performance**: Uses index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 20ms.

---

### Q3: Check loan data contributing to outstanding and overdue calculations

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).exclude(
    status__in=['REJECTED', 'CANCELLED']
).values(
    'id', 'status', 'loan_amount', 'remaining_amount',
    'overdue_date', 'interest_free_period_end_date',
    'transaction_date', 'total_interest', 'total_penal_interest',
    'remaining_principal', 'remaining_interest',
    'customer_credit_line__credit_product__credit_product_name'
).order_by('-transaction_date')
```

**SQL**:
```sql
SELECT ll.id, ll.status, ll.loan_amount, ll.remaining_amount,
       ll.overdue_date, ll.interest_free_period_end_date,
       ll.transaction_date, ll.total_interest, ll.total_penal_interest,
       ll.remaining_principal, ll.remaining_interest,
       cp.credit_product_name
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status NOT IN ('REJECTED', 'CANCELLED')
ORDER BY ll.transaction_date DESC;
```
**Performance**: Uses index on `loan_loan(customer_credit_line_id)`. Expected < 50ms for typical user.

---

### Q4: Check payment data for the user

**ORM**:
```python
from payment.models import Payment

Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'payment_amount', 'payment_mode',
    'transfer_to_lender_amount', 'hold_amount',
    'reconcilable_amount', 'created_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT pp.id, pp.status, pp.payment_amount, pp.payment_mode,
       pp.transfer_to_lender_amount, pp.hold_amount,
       pp.reconcilable_amount, pp.created_at
FROM payment_payment pp
JOIN credit_line_customercreditline ccl ON pp.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY pp.created_at DESC;
```
**Performance**: Uses index on `payment_payment(customer_credit_line_id)`. Expected < 50ms.

---

### Q5: Check ledger entries for the user

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
**Performance**: Uses index on `ledger_ledgerentry(partner_id)`. Expected < 100ms. **Warning**: Users with large ledger history may have 1000+ entries; add date range filter for production use:
```sql
AND date >= NOW() - INTERVAL '365 days'
```

---

### Q6: Check invoices under process (affecting available credit limit)

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
**Performance**: Uses index on `invoice_invoice(partner_id)`. Expected < 20ms.

---

### Q7: Verify final credit line status computation inputs

**SQL** (reproduces the status aggregation logic):
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
**Performance**: Uses composite index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 10ms.

---

### Q8: Check limit enhancement status

**ORM**:
```python
from credit_line.model import Customer
from lead.models import Lead

customer = Customer.objects.get(source_identifier_id='{user_id}')

# Check if limit enhancement is configured
print(f"limit_enhancement_amount: {customer.limit_enhancement_amount}")
print(f"external_lender_supported: {customer.external_lender_supported}")

# If external_lender_supported, check Lead model
Lead.objects.filter(
    partner_id='{user_id}',
    application_status__in=['IN_PROGRESS', 'YET_TO_PROCESS'],
    ib_ticket_status='LIMIT_ENHANCEMENT'
).values('id', 'limit_enhancement_status', 'application_status', 'ib_ticket_status')
```

**SQL**:
```sql
-- Check customer enhancement config
SELECT c.limit_enhancement_amount, c.external_lender_supported
FROM credit_line_customer c
WHERE c.source_identifier_id = '{user_id}';

-- Check lead status (if external_lender_supported = true)
SELECT id, limit_enhancement_status, application_status, ib_ticket_status
FROM lead_lead
WHERE partner_id = '{user_id}'
  AND application_status IN ('IN_PROGRESS', 'YET_TO_PROCESS')
  AND ib_ticket_status = 'LIMIT_ENHANCEMENT';
```
**Performance**: Expected < 10ms each.
