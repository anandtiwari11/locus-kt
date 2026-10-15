# Flow: Credit Limit Calculation

> Traces how credit limits are set and updated across the system — via admin CSV uploads, Saraloan sync, and scheduled tasks.
> This flow answers: "For a given `source_identifier_id`, what is the current credit limit, operational limit, and lender available credit limit, and how were they set?"

**Primary Entry Points**: Admin CSV upload via `CustomerCreditLineUpload` form, Saraloan daily sync
**Key Functions**: `credit_line/tasks.py:update_credit_limit_in_bulk()`, `update_operational_limit_in_bulk()`, `fetch_and_update_credit_line_info()`

---

## Entry Points

| Entry Point | Type | user_id Location | File Path |
|-------------|------|-----------------|-----------|
| Django Admin → `CustomerCreditLineUpload` (action: `UPDATE_CREDIT_LIMIT`) | Admin CSV upload | CSV column: `Partner ID` | `credit_line/forms.py:CustomerCreditLineUploadForm.clean()` → `credit_line/tasks.py:customer_credit_line_update()` |
| Django Admin → `CustomerCreditLineUpload` (action: `UPDATE_OPERATIONAL_LIMIT`) | Admin CSV upload | CSV column: `Partner ID` | `credit_line/forms.py:CustomerCreditLineUploadForm.clean()` → `credit_line/tasks.py:customer_credit_line_update()` |
| Django Admin → `CustomerCreditLineUpload` (action: `UPDATE_LENDER_AVAILABLE_CREDIT_LIMIT`) | Admin CSV upload | CSV column: `Partner ID` | `credit_line/forms.py:CustomerCreditLineUploadForm.clean()` → `credit_line/tasks.py:customer_credit_line_update()` |
| Django Admin → `CustomerFileUpload` (action: `LIMIT_ENHANCEMENT_AMOUNT`) | Admin CSV upload | CSV column: `Source Identifier ID` | `credit_line/tasks.py:update_customer_data()` → `update_limit_enhancement_amount_in_bulk()` |
| Celery Beat: `sync_credit_lines_info_from_saraloan` | Scheduled (daily 22:00) | Derived from `CustomerCreditLine` → `Customer.source_identifier_id` | `credit_line/tasks.py:sync_credit_lines_info_from_saraloan()` |
| Celery Beat: `buffer_date_actions` | Scheduled (daily 16:30) | Derived from `CustomerCreditLine` with `buffer_limit_end_date = today` | `credit_line/tasks.py:buffer_date_actions()` |
| Django Signal: `pre_save` on `CustomerCreditLine` | Implicit (every save) | Instance `customer_id` | `credit_line/signals.py:update_operational_limit()` |

---

## Execution Sequence

### Flow A: Credit Limit Update via Admin CSV Upload (`UPDATE_CREDIT_LIMIT`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `CustomerCreditLineUploadForm.clean()` | `credit_line/forms.py:30` | Validates uploaded CSV. Checks headers match `mandatory_create_action_fields`. Parses CSV into `DictReader`. |
| 2 | `customer_credit_line_update('UPDATE_CREDIT_LIMIT', d_reader)` | `credit_line/tasks.py:172` | Dispatches to function via `UPLOAD_ACTION_FUNCTION_MAP`. |
| 3 | `update_credit_limit_in_bulk(upload_data)` | `credit_line/tasks.py:290` | Core function. Passes CSV rows to serializer. |
| 4 | `UpdateCustCLLimitFileUploadSerializer.to_internal_value()` | `credit_line/serializers.py:100` | For each row: validates `Partner ID` and `Credit Product ID` via `validate_partner_n_credit_product()`, validates `Sanctioned Credit Limit` via `validate_credit_limit()`, fetches `CustomerCreditLine` via `fetch_cust_cl_by_source_n_product()`, sets `customer_credit_line.credit_limit = credit_limit`. For ME_ADANI_CAPITAL/ME_PROGCAP products: also computes `principal_outstanding = credit_limit - lender_available_credit_limit`. |
| 5 | `validate_partner_n_credit_product(cust_raw_data)` | `credit_line/serializers.py:627` | Extracts and validates `Partner ID` and `Credit Product ID` from CSV row. |
| 6 | `validate_credit_limit(cust_raw_data, partner_id)` | `credit_line/serializers.py:637` | Validates credit limit is within `CREDIT_LIMIT_MIN_VALUE` and `CREDIT_LIMIT_MAX_VALUE` bounds. |
| 7 | `fetch_cust_cl_by_source_n_product(partner_id, credit_product_id)` | `common/utils.py:246` | Fetches `CustomerCreditLine` with `select_related('customer', 'credit_product')`. Raises `ValidationError` if not found. |
| 8 | `bulk_update_with_history(updated_credit_lines, CustomerCreditLine, ['credit_limit', 'available_credit_limit', 'principal_outstanding'])` | `common/utils.py:494` | Sets `updated_at` on each object, then calls `simple_history.utils.bulk_update_with_history()` to persist changes and create history records. |

### Flow B: Operational Limit Update via Admin CSV Upload (`UPDATE_OPERATIONAL_LIMIT`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `CustomerCreditLineUploadForm.clean()` | `credit_line/forms.py:30` | Validates CSV headers match `mandatory_update_operational_limit_fields`. |
| 2 | `customer_credit_line_update('UPDATE_OPERATIONAL_LIMIT', d_reader)` | `credit_line/tasks.py:172` | Dispatches via `UPLOAD_ACTION_FUNCTION_MAP`. |
| 3 | `update_operational_limit_in_bulk(upload_data)` | `credit_line/tasks.py:277` | Passes CSV rows to serializer. |
| 4 | `UpdateOperationalLimitFileUploadSerializer.to_internal_value()` | `credit_line/serializers.py:228` | For each row: validates `Partner ID`, `Credit Product ID`, and `Operational Limit`. Fetches `CustomerCreditLine`. **Key logic**: `operational_limit = min(float(operational_limit), float(customer_credit_line.credit_limit))`. Calls `customer_credit_line.save()` (triggers `pre_save` signal). |
| 5 | `update_operational_limit` signal (pre_save) | `credit_line/signals.py:37` | **Redundant enforcement**: `operational_limit = min(operational_limit, credit_limit)`. If `operational_limit` is `None`, sets it to `credit_limit`. |
| 6 | `bulk_update_with_history(updated_credit_lines, CustomerCreditLine, ['operational_limit'])` | `common/utils.py:494` | Persists changes with history tracking. |

### Flow C: Lender Available Credit Limit Update via Admin CSV Upload

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1–2 | Same as Flow A steps 1–2 | — | Dispatches with action `UPDATE_LENDER_AVAILABLE_CREDIT_LIMIT`. |
| 3 | `update_lender_available_credit_limit_in_bulk(upload_data)` | `credit_line/tasks.py:305` | Passes CSV rows to serializer. |
| 4 | `UpdateLenderAvailableCreditLimitFileUploadSerializer.to_internal_value()` | `credit_line/serializers.py:123` | Validates and sets `lender_available_credit_limit`. For ME_ADANI_CAPITAL/ME_PROGCAP: computes `principal_outstanding = credit_limit - lender_available_credit_limit`. |
| 5 | `bulk_update_with_history(updated_credit_lines, CustomerCreditLine, ['lender_available_credit_limit', 'principal_outstanding'])` | `common/utils.py:494` | Persists with history. |

### Flow D: Limit Enhancement Amount Update via Admin CSV Upload

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `CustomerFileUpload` admin form | `credit_line/model/customer.py` | CSV upload with action `LIMIT_ENHANCEMENT_AMOUNT`. |
| 2 | `update_customer_data(upload_data, 'LIMIT_ENHANCEMENT_AMOUNT')` | `credit_line/tasks.py:260` | Dispatches to `update_limit_enhancement_amount_in_bulk()`. |
| 3 | `update_limit_enhancement_amount_in_bulk(upload_data)` | `credit_line/tasks.py:265` | Passes CSV rows to serializer. |
| 4 | `LimitEnhancementFileUploadSerializer.to_internal_value()` | `credit_line/serializers.py:83` | Validates `Source Identifier ID`, fetches `Customer`, sets `customer.limit_enhancement_amount`. |
| 5 | `bulk_update_with_history(updated_customers, Customer, ['limit_enhancement_amount'])` | `common/utils.py:494` | Persists with history. |

### Flow E: Saraloan Sync (Automated Credit Limit + Lender Available Credit Limit)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `sync_credit_lines_info_from_saraloan()` | `credit_line/tasks.py:634` | Celery Beat task (daily 22:00). Fetches all eligible credit lines via `get_credit_lines_for_saraloan_customers()`. |
| 2 | `sync_credit_line_info_from_saraloan(credit_line_id)` | `credit_line/tasks.py:646` | Per-credit-line async task. Checks `external_lender_supported` and customer type. Fetches `CustomerLenderMap` for `business_id` and `loan_account_id`. |
| 3 | `fetch_and_update_credit_line_info(credit_line_id, customer_type, business_id, loan_account_id)` | `credit_line/tasks.py:479` | Core sync function. Calls Saraloan API to get credit line and account details. |
| 4 | `get_saraloan_credit_line(business_id, creds_type)` | External API call | Fetches `usable_limit_amount` (sanctioned credit limit) and `line_status` from Saraloan. |
| 5 | `Saraloan(creds_type).get_account_details(loan_account_id)` | External API call | Fetches `remaining_amount`, `principal_outstanding`, `total_outstanding`, interest data from Saraloan. |
| 6 | Compute derived values | `credit_line/tasks.py:510` | `available_credit_limit = sanctioned_credit_limit - principal_outstanding`. Extracts `lender_outstanding_amount`, `total_interest_outstanding`, `total_interest_paid`. |
| 7 | Limit enhancement reset check | `credit_line/tasks.py:540` | If new `sanctioned_credit_limit > current credit_limit` and `CustomerLenderMap` exists with loan agreements > 1: resets `customer.limit_enhancement_amount = None`, updates `Lead` status to `LIMIT_ENHANCED`. |
| 8 | `customer_credit_line.save(auto_update=True)` | `credit_line/model/customer_credit_line.py:306` | Saves updated fields: `credit_limit`, `lender_available_credit_limit`, `lender_outstanding_amount`, `principal_outstanding`, `lender_status`, `lender_advance_payment`, `total_interest_outstanding`, `total_interest_paid`. Triggers `pre_save` signal (operational limit enforcement). |
| 9 | `update_operational_limit` signal (pre_save) | `credit_line/signals.py:37` | Enforces `operational_limit = min(operational_limit, credit_limit)`. |
| 10 | `update_principal_outstanding` signal (pre_save) | `credit_line/signals.py:44` | For ME_ADANI_CAPITAL/ME_PROGCAP: `principal_outstanding = credit_limit - lender_available_credit_limit`. |
| 11 | `capture_status_change_event.apply_async()` | `credit_line/tasks.py:2690` | Post-save: captures status/limit change events for DC customers. |
| 12 | `share_oldest_loan_to_lender.apply_async()` | `loan/tasks.py` | Post-save: if `lender_available_credit_limit` or `lender_advance_payment` changed, triggers loan-to-lender pipeline. |

### Flow F: Buffer Date Actions (Scheduled Credit Limit Reset)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `buffer_date_actions()` | `credit_line/tasks.py:2058` | Celery Beat task (daily 16:30). Queries GAPL credit lines where `buffer_limit_end_date = today`. |
| 2 | `update_minimum_sanctioned_amount(credit_line_id)` | `credit_line/tasks.py:2072` | Per-credit-line async task. Sets `previous_credit_limit = credit_limit`, then `credit_limit = CREDIT_LIMIT_MIN_VALUE`. Calls `save()`. |
| 3 | `update_operational_limit` signal (pre_save) | `credit_line/signals.py:37` | Enforces `operational_limit = min(operational_limit, CREDIT_LIMIT_MIN_VALUE)`. |

---

## Celery Tasks Triggered

| Task | Trigger | Queue | Description |
|------|---------|-------|-------------|
| `credit_line.tasks.sync_credit_lines_info_from_saraloan` | Celery Beat (daily 22:00) | `saraloan` | Orchestrator: fans out to per-credit-line sync tasks |
| `credit_line.tasks.sync_credit_line_info_from_saraloan` | Called by `sync_credit_lines_info_from_saraloan` | `celery` | Per-credit-line: validates lender map, dispatches to `fetch_and_update_credit_line_info` |
| `credit_line.tasks.fetch_and_update_credit_line_info` | Called by `sync_credit_line_info_from_saraloan` | `celery` | Fetches from Saraloan API, updates `credit_limit`, `lender_available_credit_limit`, `lender_outstanding_amount` |
| `credit_line.tasks.buffer_date_actions` | Celery Beat (daily 16:30) | `celery` | Finds GAPL credit lines with expired buffer dates |
| `credit_line.tasks.update_minimum_sanctioned_amount` | Called by `buffer_date_actions` | `celery` | Resets credit limit to minimum for expired buffer credit lines |
| `credit_line.tasks.capture_status_change_event` | Post-save on `CustomerCreditLine` (DC customers) | `celery` | Captures limit/status change events |
| `loan.tasks.share_oldest_loan_to_lender` | Post-save on `CustomerCreditLine` when `lender_available_credit_limit` changes | `celery` | Triggers loan-to-lender pipeline when available credit changes |
| `credit_line.tasks.credit_limit_upload_ivr_and_sms` | Post `bulk_create` on `CustomerCreditLine` | `celery` | Sends IVR call and SMS to farmers on credit line creation |
| `virtual_account.tasks.sync_customer_virtual_account_details_from_saraloan` | Called by `fetch_and_update_credit_line_info` | `celery` | Syncs virtual account details after credit line sync |

---

## Database Tables Accessed

| Table | Access Type | Key Columns | Accessed By |
|-------|------------|-------------|-------------|
| `credit_line_customercreditline` | READ + WRITE | `credit_limit`, `operational_limit`, `available_credit_limit`, `lender_available_credit_limit`, `principal_outstanding`, `lender_outstanding_amount`, `lender_advance_payment`, `lender_status`, `buffer_limit_end_date`, `previous_credit_limit`, `unrealised_outstanding_payment` | All flows |
| `credit_line_customer` | READ + WRITE | `source_identifier_id`, `limit_enhancement_amount`, `external_lender_supported`, `customer_type_id` | Serializer lookups, limit enhancement update, Saraloan sync |
| `credit_line_creditproduct` | READ | `credit_product_name`, `belongs_to_gapl` | Serializer lookups, product-specific logic (ME_ADANI_CAPITAL, ME_PROGCAP) |
| `credit_line_customerlendermap` | READ | `customer_id`, `credit_product_id`, `business_id`, `loan_account_id`, `application_id` | Saraloan sync (Flow E) |
| `credit_line_customercreditlineupload` | READ | `upload_action`, `file` | Admin CSV upload entry point |
| `credit_line_customerfileupload` | READ | `upload_action`, `file` | Limit enhancement CSV upload |
| `lead_lead` | READ + WRITE | `partner_id`, `ib_ticket_status`, `limit_enhancement_status`, `application_status` | Limit enhancement reset in Saraloan sync |
| `credit_line_customertype` | READ | `name` | Customer type checks (DC vs Farmer) |
| History tables (`simple_history`) | WRITE | All fields of updated model | `bulk_update_with_history()` creates audit records |

---

## Decision Points

> Cross-reference: See `04-decision-logic.md` for full condition expressions and branch outcomes.

| # | Decision | Location | Condition | Outcomes |
|---|----------|----------|-----------|----------|
| D1 | Operational limit capping | `credit_line/signals.py:14` | `operational_limit` is `None` or `> credit_limit` | **None** → set to `credit_limit`. **> credit_limit** → cap to `min(operational_limit, credit_limit)`. |
| D2 | Principal outstanding for ME products | `credit_line/serializers.py:110` and `credit_line/signals.py:44` | `credit_product_name in [ME_ADANI_CAPITAL, ME_PROGCAP]` | **Yes** → `principal_outstanding = credit_limit - lender_available_credit_limit`. **No** → no change. |
| D3 | Credit limit validation bounds | `credit_line/serializers.py:637` | `CREDIT_LIMIT_MIN_VALUE <= credit_limit <= CREDIT_LIMIT_MAX_VALUE` | **Out of bounds** → `ValidationError`. **In bounds** → proceed. |
| D4 | External lender supported check (Saraloan sync) | `credit_line/tasks.py:653` | `not customer.external_lender_supported and customer_type == DC` | **True** → skip sync ("Non Financed Customer"). **False** → proceed with sync. |
| D5 | CustomerLenderMap availability | `credit_line/tasks.py:660` | `CustomerLenderMap` exists with `business_id` and `loan_account_id` | **Missing** → attempt `sync_partner_ids_from_saraloan()`. **Still missing** → skip. **Found** → proceed to `fetch_and_update_credit_line_info`. |
| D6 | Limit enhancement reset | `credit_line/tasks.py:540` | `new sanctioned_credit_limit > current credit_limit` and loan agreements > 1 | **Yes** → reset `limit_enhancement_amount = None`, update Lead to `LIMIT_ENHANCED`. **No** → no change. |
| D7 | Lender overdue status override | `credit_line/tasks.py:570` | `lender_loan_overdue and lender_status == ACTIVE` | **Yes** → override `lender_status` to `OVERDUE`, update `aged_outstanding_amount` if increased. **No** → keep API-returned status. |
| D8 | Buffer limit expiry | `credit_line/tasks.py:2058` | `buffer_limit_end_date == today and belongs_to_gapl` | **Match** → reset `credit_limit` to `CREDIT_LIMIT_MIN_VALUE`. **No match** → no action. |
| D9 | Post-save loan-to-lender trigger | `credit_line/model/customer_credit_line.py:330` | `lender_available_credit_limit` or `lender_advance_payment` changed (non-GAPL DC) | **Changed** → trigger `share_oldest_loan_to_lender`. **Unchanged** → no action. |

---

## Investigation Queries

### Q1: Current credit limits for a user

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
**Performance**: Uses index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 10ms.

---

### Q2: Limit enhancement amount for a user

**ORM**:
```python
from credit_line.model import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'id', 'limit_enhancement_amount', 'external_lender_supported',
    'lender_supported_status', 'customer_type__name'
)
```

**SQL**:
```sql
SELECT c.id, c.limit_enhancement_amount, c.external_lender_supported,
       c.lender_supported_status, ct.name AS customer_type
FROM credit_line_customer c
JOIN credit_line_customertype ct ON c.customer_type_id = ct.id
WHERE c.source_identifier_id = '{user_id}';
```
**Performance**: Uses unique index on `credit_line_customer.source_identifier_id`. Expected < 5ms.

---

### Q3: Credit limit change history (via `django-simple-history`)

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
**Performance**: Expected < 50ms. **Warning**: History tables can be large; always use `LIMIT` and consider adding date range filter:
```sql
AND h.history_date >= NOW() - INTERVAL '30 days'
```

---

### Q4: CustomerLenderMap for Saraloan sync context

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

### Q5: Limit enhancement Lead status

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

### Q6: Recent Celery task results for credit limit sync

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'credit_line.tasks.sync_credit_line_info_from_saraloan',
        'credit_line.tasks.fetch_and_update_credit_line_info',
        'credit_line.tasks.update_minimum_sanctioned_amount',
    ],
    task_args__contains='{user_id}'
).values(
    'task_id', 'task_name', 'status', 'result',
    'date_created', 'date_done', 'traceback'
).order_by('-date_done')[:10]
```

**SQL**:
```sql
SELECT task_id, task_name, status, result,
       date_created, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'credit_line.tasks.sync_credit_line_info_from_saraloan',
    'credit_line.tasks.fetch_and_update_credit_line_info',
    'credit_line.tasks.update_minimum_sanctioned_amount'
)
AND task_args LIKE '%{user_id}%'
ORDER BY date_done DESC
LIMIT 10;
```
**Performance**: Uses index on `django_celery_results_taskresult(task_name)`. Expected < 100ms. **Warning**: `task_args LIKE` may be slow on large tables; add date filter:
```sql
AND date_done >= NOW() - INTERVAL '7 days'
```

---

### Q7: Verify operational limit is correctly capped

**SQL** (diagnostic query to detect operational_limit > credit_limit anomalies):
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
**Performance**: Expected < 10ms.

---

### Q8: Check buffer limit expiry status

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
