# Runtime Data Dependencies

> Consolidated reference of all runtime data retrieved during each user flow, the queries that fetch it, and the decision logic that consumes it.
> For a given `{user_id}` (`source_identifier_id` or `partner_id`), this document answers: "What data did the system read, from where, and which decisions did it feed?"

**Cross-reference**: Decision logic details → [`04-decision-logic.md`](04-decision-logic.md)
**Query conventions**: All queries are read-only (`SELECT`), use `{user_id}` placeholder, and target indexed columns.

---

## Table of Contents

1. [Credit Eligibility Check — Runtime Data](#1-credit-eligibility-check--runtime-data)
2. [Credit Limit Calculation — Runtime Data](#2-credit-limit-calculation--runtime-data)
3. [Approval Workflow — Runtime Data](#3-approval-workflow--runtime-data)
4. [Repayment Workflow — Runtime Data](#4-repayment-workflow--runtime-data)
5. [Risk Evaluation — Runtime Data](#5-risk-evaluation--runtime-data)
6. [External API Dependencies](#6-external-api-dependencies)

---

## 1. Credit Eligibility Check — Runtime Data

> Flow doc: [`02-user-flows/credit-eligibility.md`](02-user-flows/credit-eligibility.md)

### 1.1 Customer Profile and Credit Eligibility

**Used by**: `credit_line/views.py:ListCreditLines.get()` → `populate_all_credit_lines()`
**Decides**: Whether credit is allowed, customer type routing (Farmer vs DC) → `04-decision-logic.md` D1–D3

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
**Performance**: Unique index on `credit_line_customer.source_identifier_id`. Expected < 10ms.

---

### 1.2 Credit Lines with Product and Lender Details

**Used by**: `credit_line/utils.py:populate_all_credit_lines()` (raw SQL join)
**Decides**: Available credit limit, outstanding amounts, status/sub_status, GAPL vs lender routing → `04-decision-logic.md` D4–D7

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
**Performance**: Index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 20ms.

---

### 1.3 Loan Data (Outstanding and Overdue Calculations)

**Used by**: `credit_line/utils.py:populate_all_credit_lines()` raw SQL
**Decides**: Outstanding amount, overdue amount, available credit limit computation → `04-decision-logic.md` D4, D5

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
**Performance**: Index on `loan_loan(customer_credit_line_id)`. Expected < 50ms for typical user.

---

### 1.4 Payment Data

**Used by**: `credit_line/utils.py:populate_all_credit_lines()` raw SQL
**Decides**: Outstanding amount reduction, reconcilable amounts → `04-decision-logic.md` D4

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
**Performance**: Index on `payment_payment(customer_credit_line_id)`. Expected < 50ms.

---

### 1.5 Ledger Entries (DC Customers)

**Used by**: `credit_line/utils.py:fetch_ledger_aggregated_data()` raw SQL
**Decides**: Ledger outstanding, financing fees, app block calculations → `04-decision-logic.md` D4

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
**Performance**: Index on `ledger_ledgerentry(partner_id)`. Expected < 100ms.
**Warning**: Users with large ledger history may have 1000+ entries. Add date range filter for production:
```sql
AND date >= NOW() - INTERVAL '365 days'
```

---

### 1.6 Invoices Under Process

**Used by**: `credit_line/utils.py:populate_all_credit_lines()` raw SQL
**Decides**: Available credit limit reduction for pending invoices → `04-decision-logic.md` D4

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
**Performance**: Index on `invoice_invoice(partner_id)`. Expected < 20ms.

---

### 1.7 Limit Enhancement Status

**Used by**: `credit_line/utils.py:get_limit_enhancement_status_and_amount_util()`
**Decides**: Whether limit enhancement banner is shown, enhancement status → `04-decision-logic.md` D8

**ORM**:
```python
from lead.models import Lead

Lead.objects.filter(
    partner_id='{user_id}',
    application_status__in=['IN_PROGRESS', 'YET_TO_PROCESS'],
    ib_ticket_status='LIMIT_ENHANCEMENT'
).values('id', 'limit_enhancement_status', 'application_status', 'ib_ticket_status')
```

**SQL**:
```sql
SELECT id, limit_enhancement_status, application_status, ib_ticket_status
FROM lead_lead
WHERE partner_id = '{user_id}'
  AND application_status IN ('IN_PROGRESS', 'YET_TO_PROCESS')
  AND ib_ticket_status = 'LIMIT_ENHANCEMENT';
```
**Performance**: Expected < 10ms.

---

## 2. Credit Limit Calculation — Runtime Data

> Flow doc: [`02-user-flows/credit-limit-calculation.md`](02-user-flows/credit-limit-calculation.md)

### 2.1 Current Credit Limits

**Used by**: `credit_line/tasks.py:update_credit_limit_in_bulk()`, `update_operational_limit_in_bulk()`, `fetch_and_update_credit_line_info()`
**Decides**: Credit limit bounds, operational limit capping, principal outstanding computation → `04-decision-logic.md` D1–D3

**ORM**:
```python
from credit_line.model import CustomerCreditLine

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}'
).select_related('customer', 'credit_product').values(
    'id', 'credit_limit', 'operational_limit', 'available_credit_limit',
    'lender_available_credit_limit', 'lender_outstanding_amount',
    'principal_outstanding', 'lender_advance_payment',
    'previous_credit_limit', 'buffer_limit_end_date',
    'unrealised_outstanding_payment', 'lender_status',
    'status', 'sub_status',
    'credit_product__credit_product_name', 'credit_product__belongs_to_gapl',
    'updated_at'
)
```

**SQL**:
```sql
SELECT ccl.id, ccl.credit_limit, ccl.operational_limit,
       ccl.available_credit_limit, ccl.lender_available_credit_limit,
       ccl.lender_outstanding_amount, ccl.principal_outstanding,
       ccl.lender_advance_payment, ccl.previous_credit_limit,
       ccl.buffer_limit_end_date, ccl.unrealised_outstanding_payment,
       ccl.lender_status, ccl.status, ccl.sub_status,
       cp.credit_product_name, cp.belongs_to_gapl,
       ccl.updated_at
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```
**Performance**: Index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 10ms.

---

### 2.2 CustomerLenderMap (Saraloan Sync Context)

**Used by**: `credit_line/tasks.py:sync_credit_line_info_from_saraloan()` → `fetch_and_update_credit_line_info()`
**Decides**: Whether Saraloan sync proceeds, which `business_id` and `loan_account_id` to use → `04-decision-logic.md` D4, D5

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
**Performance**: Expected < 10ms.

---

### 2.3 Credit Limit Change History

**Used by**: Investigation — trace when and how credit limits changed
**Decides**: Historical context for limit changes (admin upload vs Saraloan sync vs buffer expiry)

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
    'previous_credit_limit'
).order_by('-history_date')[:20]
```

**SQL**:
```sql
SELECT h.history_date, h.history_type, au.username,
       h.credit_limit, h.operational_limit, h.available_credit_limit,
       h.lender_available_credit_limit, h.principal_outstanding,
       h.previous_credit_limit
FROM credit_line_historicalcustomercreditline h
LEFT JOIN auth_user au ON h.history_user_id = au.id
WHERE h.customer_id = (
    SELECT id FROM credit_line_customer
    WHERE source_identifier_id = '{user_id}'
)
ORDER BY h.history_date DESC
LIMIT 20;
```
**Performance**: Expected < 50ms. **Warning**: History tables can be large; always use `LIMIT` and consider:
```sql
AND h.history_date >= NOW() - INTERVAL '30 days'
```

---

### 2.4 Buffer Limit Expiry Status

**Used by**: `credit_line/tasks.py:buffer_date_actions()` → `update_minimum_sanctioned_amount()`
**Decides**: Whether credit limit is reset to minimum → `04-decision-logic.md` D8

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

---

### 2.5 Limit Enhancement Lead Status

**Used by**: `credit_line/tasks.py:fetch_and_update_credit_line_info()` (limit enhancement reset check)
**Decides**: Whether `limit_enhancement_amount` is reset after Saraloan sync → `04-decision-logic.md` D6

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
**Performance**: Expected < 10ms.

---

## 3. Approval Workflow — Runtime Data

> Flow doc: [`02-user-flows/approval-workflow.md`](02-user-flows/approval-workflow.md)

### 3.1 Loans with Status and Credit Line Details

**Used by**: `loan/views.py:LoanViewSet.post()` → `loan/utility.py:create_loan()`, `loan/tasks.py:share_oldest_loan_to_lender()`
**Decides**: Loan creation eligibility, loan breakup across credit lines, share-to-lender eligibility → `04-decision-logic.md` D1, D2, D6, D7

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
    'creation_reason', 'comment', 'created_at', 'updated_at',
    'customer_credit_line__credit_product__credit_product_name',
    'customer_credit_line__credit_product__belongs_to_gapl',
).order_by('-created_at')
```

**SQL**:
```sql
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount, ll.disbursed_amount,
       ll.remaining_amount, ll.transaction_date, ll.disbursement_date,
       ll.creation_reason, ll.comment, ll.created_at, ll.updated_at,
       cp.credit_product_name, cp.belongs_to_gapl
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY ll.created_at DESC;
```
**Performance**: Index on `loan_loan(customer_credit_line_id)`. Expected < 50ms.

---

### 3.2 LenderLoanMap Upload Status

**Used by**: `loan/tasks.py:send_invoice_to_saraloan()`, `create_tranche_in_blacksoil()`, `create_invoice_in_blacksoil()`
**Decides**: Invoice upload progression (YET_TO_UPLOAD → PARTNER_FOUND → TRANSACTION_CREATED → INVOICE_UPLOADED) → `04-decision-logic.md` D8–D10

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
**Performance**: Index on `loan_lenderloanmap(loan_id)`. Expected < 30ms.

---

### 3.3 InvoiceLoanMap Entries

**Used by**: `loan/utility.py:create_loan()`, `loan/tasks.py:create_loan_in_bulk()`, `process_disbursal_event()`
**Decides**: Invoice-to-loan mapping, disbursement amount allocation → `04-decision-logic.md` D11

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
**Performance**: Index on `loan_invoiceloanmap(loan_id)`. Expected < 30ms.

---

### 3.4 Lender Credit Line Availability (for Sharing)

**Used by**: `loan/tasks.py:share_oldest_loan_to_lender()` step 6
**Decides**: Whether a lender credit line is available for loan sharing → `04-decision-logic.md` D4, D5

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
**Performance**: Index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 10ms.

---

### 3.5 Webhook Events (Lender Callbacks)

**Used by**: `external/views.py:SaraloanWebhookView.post()` → `credit_line/tasks.py:process_saraloan_loan_webhook()`
**Decides**: Disbursal processing (full vs partial), loan status transitions → `04-decision-logic.md` D11, D12

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
**Performance**: **Warning** — JSON field query without index. May be slow on large tables. Add date range:
```sql
AND created_at >= NOW() - INTERVAL '7 days'
```

---

### 3.6 Loans Stuck in YET_TO_BE_DISBURSED (No LenderLoanMap)

**Used by**: Investigation — detect loans that were never shared to lender
**Decides**: Identifies stalled loan-to-lender pipeline

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
**Performance**: Index on `loan_loan(customer_credit_line_id, status)`. Expected < 20ms.

---

## 4. Repayment Workflow — Runtime Data

> Flow doc: [`02-user-flows/repayment-workflow.md`](02-user-flows/repayment-workflow.md)

### 4.1 Repayment Transactions (Farmer)

**Used by**: `repayment/views.py:ListCreateTransactionView.post()`, `repayment/utils.py:process_post_save_transaction()`
**Decides**: Transaction type routing (Collection vs Deposit), idempotency, collection-to-deposit mapping → `04-decision-logic.md` D1–D4

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
**Performance**: Index on `repayment_transaction(transaction_type, active)`. Expected < 50ms.

---

### 4.2 Payments for Credit Line (Lender Repayments)

**Used by**: `payment/utils.py:validate_and_create_or_update_payment()`, `payment/tasks.py:process_repayment_data()`
**Decides**: Create vs update path, status transition validity, bounced handling → `04-decision-logic.md` D8–D14

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
    'payment_transfer_number', 'created_at', 'updated_at'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT p.id, p.lender_payment_id, p.lender_payment_ref_number,
       p.payment_amount, p.payment_amount_settled, p.advance_amount,
       p.payment_date, p.settlement_date, p.payment_mode, p.status,
       p.sub_status, p.interest, p.principal, p.penal_interest,
       p.overdue_interest, p.refund_amount, p.refund_utr,
       p.payment_transfer_number, p.created_at, p.updated_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY p.created_at DESC;
```
**Performance**: Index on `payment_payment(customer_credit_line_id)`. Expected < 50ms.

---

### 4.3 Ledger Entries (Repayment Type)

**Used by**: `payment/utils.py:create_or_update_ledger_entry()`, `cancel_ledger_entry()`
**Decides**: Ledger entry creation/update, visibility, unrealized payment status → `04-decision-logic.md` D10, D14

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
**Performance**: Index on `ledger_ledgerentry(partner_id, type)`. Expected < 30ms.

---

### 4.4 Payment-to-Ledger Cross-Reference (Mismatch Detection)

**Used by**: Investigation — detect orphaned payments or amount mismatches
**Decides**: Data consistency between `payment_payment` and `ledger_ledgerentry`

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
**Performance**: Indexes on `payment_payment(customer_credit_line_id)` and `ledger_ledgerentry(locus_id, type)`. Expected < 50ms.

---

### 4.5 Demand Sheets (Farmer)

**Used by**: `repayment/tasks.py:correct_repayment_transaction()`, demand-related queries
**Decides**: Expected repayment amounts, overdue status for farmers

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
**Performance**: Index on `repayment_demandsheet(user_id)`. Expected < 30ms.

---

### 4.6 Virtual Account Info

**Used by**: `repayment/views.py:RetrieveVirtualAccountInfoView`, VPA deposit flows
**Decides**: Which virtual account to use for deposits

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
**Performance**: Unique constraint on `(customer_id, credit_product_id)`. Expected < 10ms.

---

### 4.7 Webhook Events (Repayment Notifications)

**Used by**: `payment/tasks.py:process_saraloan_repayment_webhook()` → `process_repayment_data()`
**Decides**: Repayment event routing, payment creation/update → `04-decision-logic.md` D5–D7

**SQL**:
```sql
SELECT id, event, data, created_at
FROM external_externalwebhook
WHERE data::jsonb -> 'identifiers' ->> 'partner_lead_id' = '{user_id}'
  AND event IN ('repayment_done', 'repayment_captured', 'repayment_bounced')
ORDER BY created_at DESC
LIMIT 20;
```
**Performance**: **Warning** — JSON field query without index. Add date range:
```sql
AND created_at >= NOW() - INTERVAL '7 days'
```

---

## 5. Risk Evaluation — Runtime Data

> Flow doc: [`02-user-flows/risk-evaluation.md`](02-user-flows/risk-evaluation.md)

### 5.1 Customer Risk Profile

**Used by**: `credit_line/tasks.py:update_credit_lines_status()` → `get_aged_outstanding_status_info()`
**Decides**: Whether customer is eligible for risk evaluation (DC + external_lender_supported) → `04-decision-logic.md` D1, D2

**ORM**:
```python
from credit_line.model.customer import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'source_identifier_id', 'name',
    'external_lender_supported', 'overdue_credit_limit',
    'overdue_credit_days', 'overdue_threshold_limit',
    'overdue_threshold_limit_end_date', 'is_credit_allowed',
    'data_permissions_consent', 'customer_type__name'
)
```

**SQL**:
```sql
SELECT c.id, c.source_identifier_id, c.name,
       c.external_lender_supported, c.overdue_credit_limit,
       c.overdue_credit_days, c.overdue_threshold_limit,
       c.overdue_threshold_limit_end_date, c.is_credit_allowed,
       c.data_permissions_consent, ct.name AS customer_type
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';
```
**Performance**: Unique index on `credit_line_customer.source_identifier_id`. Expected < 10ms.

---

### 5.2 Credit Line Status and Risk Fields

**Used by**: `credit_line/tasks.py:get_aged_outstanding_status_info()`, `get_repayment_frequency_sub_status_info()`
**Decides**: Aged outstanding threshold, repayment frequency check, business override guard → `04-decision-logic.md` D1–D5

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
**Performance**: Index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 20ms.

---

### 5.3 Overdue Loans Contributing to Risk

**Used by**: `credit_line/utils.py:populate_all_credit_lines()`, `populate_only_limit_data()`
**Decides**: `overdue_amount` per credit line, `total_overdue_amount` for aged outstanding check → `04-decision-logic.md` D1

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
**Performance**: Index on `loan_loan.customer_credit_line_id`. Expected < 50ms.

---

### 5.4 Ledger Entries for Repayment Frequency Check

**Used by**: `ledger/utils.py:get_outstanding_before_last_repayment_date()`, `get_payments_made_after_repayment_date()`
**Decides**: `repayment_unblock_amount` computation → `04-decision-logic.md` D4, D5

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
**Performance**: Index on `ledger_ledgerentry.partner_id`. Expected < 100ms.
**Warning**: Partners with high transaction volume may have thousands of entries. Add date bounds.

---

### 5.5 FinBox Profile Data

**Used by**: `credit_line/tasks.py:get_finbox_data()` → stores to `credit_line_finboxdata`
**Decides**: Whether FinBox profile data exists and when last updated → `04-decision-logic.md` D6–D8

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
**Performance**: Unique constraint on `credit_line_finboxdata.customer_id` (OneToOneField). Expected < 10ms.

> **Note**: To inspect the actual FinBox profile data JSON, add `fd.profile_data` to the SELECT. This field can be large.

---

### 5.6 FinBox Consent Status

**Used by**: `credit_line/tasks.py:is_consent_available_for_fetching_finbox_data()`
**Decides**: Whether FinBox data collection proceeds → `04-decision-logic.md` D6

**SQL**:
```sql
SELECT data_permissions_consent
FROM credit_line_customer
WHERE source_identifier_id = '{user_id}';
```
**Performance**: Unique index on `source_identifier_id`. Expected < 5ms.

> **Check**: All four keys must be `true` in the JSON: `sms_consent`, `apps_consent`, `device_consent`, `location_consent`.

---

### 5.7 Credit Line Status Change History

**Used by**: Investigation — trace when status/sub_status changed for risk evaluation
**Decides**: Historical context for ONHOLD/ACTIVE transitions

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
**Performance**: Expected < 100ms with date range filter. **Warning**: History tables can grow large. Add:
```sql
AND h.history_date >= NOW() - INTERVAL '30 days'
```

---

## 6. External API Dependencies

These external services provide runtime data that feeds into decision logic. None of these are queryable via SQL — they are called at runtime and their results are stored in the database or used transiently.

### 6.1 Saraloan (BlackSoil) API

**Integration file**: `common/external/saraloan/saraloan.py` — class `Saraloan`
**Credential types**: Configured per lender via `use_cred_for` parameter (DC vs Farmer credentials)

| Method | Endpoint Alias | Data Fields Provided | Used By (Flow → Function) | Decision Logic |
|--------|---------------|---------------------|--------------------------|----------------|
| `get_credit_line(business_id)` | `get_credit_line` | `usable_limit_amount` (sanctioned credit limit), `line_status` | Credit Limit Calc → `fetch_and_update_credit_line_info()` | Updates `credit_limit`, `lender_status` → `04-decision-logic.md` D6, D7 |
| `get_account_details(loan_account_id)` | `get_account_details` | `remaining_amount`, `principal_outstanding`, `total_outstanding`, `total_interest_outstanding`, `total_interest_paid`, `lender_advance_payment` | Credit Limit Calc → `fetch_and_update_credit_line_info()` | Updates `lender_available_credit_limit`, `lender_outstanding_amount`, `principal_outstanding` → `04-decision-logic.md` D6 |
| `get_repayment_details(loan_account_id)` | `get_repayment_details` | Paginated repayment records: `id`, `amount`, `status`, `settlement_date`, `payment_mode`, `utr`, `refund_amount` | Repayment → `fetch_and_update_repayments_info()` | Creates/updates `Payment` records → `04-decision-logic.md` D8–D14 |
| `get_withdrawal_requests_for_invoice_id(application_id, invoice_id)` | `get_withdrawal` | Withdrawal details: `disbursement_amount`, `disbursement_date`, `status`, `loan_data`, invoice details | Approval → `process_saraloan_loan_webhook()` | Full vs partial disbursal decision → `04-decision-logic.md` D11, D12 |
| `create_invoice_tranche(application_id)` | `create_invoice_tranche` | `status_code`, `tranche_id` (transaction ID) | Approval → `create_tranche_in_blacksoil()` | Tranche creation success/failure → `04-decision-logic.md` D9 |
| `send_invoice(lender_loan_map, invoice_doc)` | `send_invoice` | Upload status, `invoice_id_at_lender` | Approval → `create_invoice_in_blacksoil()` | Invoice upload success/failure → `04-decision-logic.md` D10 |
| `get_partner_all_ids(partner_id, mobile)` | `get_partner_all_ids` | `business_id`, `loan_account_id`, `application_id` | Credit Limit Calc → `sync_partner_ids_from_saraloan()` | Populates `CustomerLenderMap` for subsequent API calls |
| `update_subvention_detail(url, subvention_days)` | `update_subvention_detail` | Subvention update status | Approval → `update_subvention_details_in_saraloan()` | Subvention eligibility → `04-decision-logic.md` D10 |
| `refresh_loan_account(loan_account_id)` | `refresh_loan_account` | Refreshed account data | Credit Limit Calc → `fetch_and_update_credit_line_info()` | Triggers account data refresh before fetching details |

**Investigation query** — Check Celery task results for Saraloan-related tasks:
```sql
SELECT task_id, task_name, status, result, date_created, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'credit_line.tasks.sync_credit_line_info_from_saraloan',
    'credit_line.tasks.fetch_and_update_credit_line_info',
    'loan.tasks.send_invoice_to_saraloan',
    'loan.tasks.create_tranche_in_blacksoil',
    'loan.tasks.create_invoice_in_blacksoil',
    'credit_line.tasks.process_saraloan_loan_webhook',
    'payment.tasks.fetch_and_update_repayments_info',
    'payment.tasks.process_repayment_data'
)
AND task_args LIKE '%{user_id}%'
ORDER BY date_done DESC
LIMIT 20;
```
**Performance**: Index on `task_name`. `LIKE` on `task_args` may be slow — add `AND date_done >= NOW() - INTERVAL '7 days'`.

---

### 6.2 FinBox API

**Integration file**: `common/external/finbox/finbox.py` — class `FinBox`
**Configuration**: `settings.FINBOX` dict (`URL`, `SERVER_API_KEY`, `SERVER_HASH`, `DC_PREDICTORS_VERSION`, `TIMEOUT`)

| Method | Data Fields Provided | Used By (Flow → Function) | Decision Logic |
|--------|---------------------|--------------------------|----------------|
| `collect_user_data(unique_identifier)` | `status` (`COMPLETE`, `IN_PROGRESS`, `ERROR`), `profile_data` JSON (risk predictors, device data, SMS analysis, app usage) | Risk Evaluation → `get_finbox_data()` | FinBox data stored in `credit_line_finboxdata.profile_data` → `04-decision-logic.md` D6–D8 |

**Request payload**:
- `customer_id`: FinBox customer ID (format: `DC` or `FR` prefix + zero-padded `customer.id`)
- `version`: `DC_PREDICTORS_VERSION` from settings
- `salt`: MD5+SHA256 hash of `customer_id` + `SERVER_HASH`

**Polling behavior**: If status is `IN_PROGRESS`, retries every 10s for up to 120s. On `ERROR` with HTTP 429/5xx, exponential backoff up to 2 retries.

**Consent prerequisite**: Requires all four consent flags in `Customer.data_permissions_consent` JSON:
- `sms_consent = true`
- `apps_consent = true`
- `device_consent = true`
- `location_consent = true`

**Investigation query** — Check FinBox data freshness:
```sql
SELECT fd.id, fd.profile_data_updated_at, c.source_identifier_id
FROM credit_line_finboxdata fd
JOIN credit_line_customer c ON fd.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';
```
**Performance**: Unique constraint on `customer_id`. Expected < 10ms.

---

### 6.3 SAP/ERP (InputBackend) API

**Integration file**: `common/external/ib.py` — class `InputBackend`
**Configuration**: `settings.INPUT_BACKEND` dict (`BASE_URL`, `ENDPOINTS`, `TIMEOUT`, `API_KEY`)

| Method | Data Fields Provided | Used By (Flow → Function) | Decision Logic |
|--------|---------------------|--------------------------|----------------|
| `get_invoice_copy(invoice_number, source)` | Invoice PDF/document binary | Approval → `loan/tasks.py:create_invoice_in_blacksoil()` → `fetch_invoice_copy_from_ib()` | Required for lender invoice upload (DC customers) |
| `create_payment(post_data)` | Payment creation response (SAP document number) | Approval → `loan/tasks.py:send_disbursement_payments_to_erp()` → `prep_disbursal_payment_to_send_to_sap()` | Disbursal payment posting to ERP |
| `create_posted_payment(post_data)` | Posted payment response | Approval → `loan/signals.py:send_disbursement_payment_to_erp` signal | Direct posted payment for eligible loan statuses |
| `create_credit_note(post_data)` | Credit note creation response | Repayment → `payment/tasks.py:check_and_create_la_entries_in_sap()` | Credit note posting to ERP |
| `create_la_entry_in_sap(post_data)` | LA entry response | Repayment → `payment/tasks.py:check_and_create_la_entries_in_sap()` | Ledger account entry in SAP |
| `create_draft_payment_transfer_entry_on_sap(post_data)` | Draft transfer entry response | Repayment → payment transfer flow | Draft payment transfer to SAP |
| `post_draft_transfer_to_lender_payment_on_sap(post_data)` | Posted transfer response | Repayment → lender payment transfer | Posts draft transfer to lender |
| `get_customer_data(partner_id_list, fields)` | Customer data from SAP (SAP IDs, addresses, etc.) | Risk Evaluation → `overdue_notification_batch()` | SAP ID resolution for notifications |
| `fetch_recon_entries(partner_sap_id, doc_no_list, fiscal_year)` | Reconciliation entries from SAP | Approval → `loan/tasks.py:run_reconciliation_for_customers()` | Reconciliation data for loan status updates |

**Investigation query** — Check ERP-related task results:
```sql
SELECT task_id, task_name, status, result, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'loan.tasks.send_disbursement_payments_to_erp',
    'payment.tasks.check_and_create_la_entries_in_sap'
)
AND task_args LIKE '%{user_id}%'
ORDER BY date_done DESC
LIMIT 10;
```
**Performance**: Index on `task_name`. Add date filter for production.

---

### 6.4 Kheti API

**Integration file**: `common/external/kheti.py` — class `Kheti`
**Configuration**: `settings.KHETI_DB` dict (`BASE_URL`, `ENDPOINTS`), `settings.KHETI_WEBHOOK_API_SECRET_KEY`

| Method | Data Fields Provided | Used By (Flow → Function) | Decision Logic |
|--------|---------------------|--------------------------|----------------|
| `get_or_create_user(phone_number)` | `user_id`, user profile data | Repayment → `payment/tasks.py:process_repayment_data()` (mobile number fallback) | Resolves `source_identifier_id` from mobile number when `partner_lead_id` is missing |
| `send_notification(data)` | Notification delivery status | Risk Evaluation → overdue notification flows | Sends FCM push notifications to farmers/DCs |
| `get_farmer_dc_repayment_transactions(farmer_id, dc_id, ...)` | Farmer-DC repayment transaction history | Repayment → transaction reconciliation | Cross-references Kheti transaction data |
| `get_credit_by_lender_orders_list(farmer_ids)` | Credit-by-lender order data | Credit Eligibility → farmer credit checks | Farmer credit order data from Kheti |
| `get_product_details_against_loan(loan_id)` | Product details linked to loan | Approval → loan product resolution | Product metadata for loan processing |

**Investigation**: Kheti API calls are not logged to a dedicated table. Check Celery task logs for failures:
```sql
SELECT task_id, task_name, status, traceback, date_done
FROM django_celery_results_taskresult
WHERE task_name LIKE '%kheti%'
  OR (traceback LIKE '%kheti%' AND task_args LIKE '%{user_id}%')
ORDER BY date_done DESC
LIMIT 10;
```

---

### 6.5 BlackSoil API (via Saraloan Client)

**Integration**: BlackSoil operations are accessed through the `Saraloan` client class with appropriate credential types. The "BlackSoil" name refers to the lender-side operations.

| Operation | Saraloan Method | Data Fields Provided | Used By (Flow → Function) | Decision Logic |
|-----------|----------------|---------------------|--------------------------|----------------|
| Tranche creation | `create_invoice_tranche(application_id)` | `tranche_id`, `status_code` | Approval → `loan/tasks.py:create_tranche_in_blacksoil()` | Tranche success/failure determines invoice upload path → `04-decision-logic.md` D9 |
| Invoice upload | `send_invoice(lender_loan_map, doc)` | Upload status, `invoice_id_at_lender` | Approval → `loan/tasks.py:create_invoice_in_blacksoil()` | Invoice upload status progression → `04-decision-logic.md` D10 |
| Parent loan rejection check | `check_if_parent_loan_is_rejected_blacksoil(source_loan)` | Rejection status | Approval → `loan/tasks.py:share_oldest_loan_to_lender()` | Skips loans with rejected parent at BlackSoil → `04-decision-logic.md` D13 |

**Investigation query** — Check LenderLoanMap for BlackSoil upload status:
```sql
SELECT llm.id, ll.loan_id, llm.invoice_upload_status,
       llm.invoice_upload_status_desc, llm.lender_invoice_id,
       llm.lender_invoice_transaction_id, llm.created_at, llm.updated_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY llm.updated_at DESC;
```
**Performance**: Index on `loan_lenderloanmap(loan_id)`. Expected < 30ms.

---

## 7. Cross-Flow Celery Task State Queries

All flows depend on Celery task execution. These queries retrieve task state from `django_celery_results_taskresult`.

### 7.1 All Task Results for a User

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_args__contains='{user_id}'
).values(
    'task_id', 'task_name', 'status', 'result',
    'date_created', 'date_done', 'traceback'
).order_by('-date_done')[:50]
```

**SQL**:
```sql
SELECT task_id, task_name, status, result,
       date_created, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 50;
```
**Performance**: **Warning** — `LIKE '%...%'` on `task_args` does not use indexes. Always include `date_done` filter. Expected < 500ms with 7-day window.

---

### 7.2 Failed Tasks for a User

**SQL**:
```sql
SELECT task_id, task_name, status, result, traceback,
       date_created, date_done
FROM django_celery_results_taskresult
WHERE task_args LIKE '%{user_id}%'
  AND status = 'FAILURE'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```
**Performance**: Same warning as 7.1. Add `task_name` filter for better performance:
```sql
AND task_name IN ('specific.task.name', ...)
```

---

## Query Performance Summary

| Query Category | Typical Execution Time | Index Used | Notes |
|---------------|----------------------|------------|-------|
| Customer lookup by `source_identifier_id` | < 10ms | Unique index | Single row |
| Credit line lookup by `customer_id` | < 20ms | Composite index | 1–5 rows typical |
| Loan lookup by `customer_credit_line_id` | < 50ms | FK index | Varies by user activity |
| Payment lookup by `customer_credit_line_id` | < 50ms | FK index | Varies by user activity |
| Ledger entries by `partner_id` | < 100ms | Index | **Add date filter for high-volume users** |
| History table queries | < 100ms | Subquery on `customer_id` | **Always use LIMIT and date filter** |
| Celery task results by `task_args` | < 500ms | No index on `task_args` | **Always use date_done filter** |
| Webhook JSON queries | Variable | No index on JSON | **Always use date filter, may be slow** |
| FinBox data lookup | < 10ms | Unique constraint | Single row (OneToOneField) |
| Demand sheet lookup | < 30ms | Index on `user_id` | Varies by farmer history |
