# Flow: Risk Evaluation

> Traces the risk evaluation flow covering credit line status updates (aged outstanding checks, repayment frequency checks), overdue sum calculations, overdue threshold limit expiry, and FinBox external data collection.
> This flow answers: "For a given `source_identifier_id`, why was a credit line placed on hold, what overdue amounts were calculated, and what external risk data was collected?"

**Primary Entry Points**:
- Cron: `credit_line.tasks.update_credit_lines_status()` (daily 02:00) — aged outstanding + repayment frequency checks
- Cron: `credit_line.tasks.collect_user_profile_data_from_finbox()` (daily 17:00) — FinBox profile data collection
- Cron: `credit_line.tasks.notify_overdue_partners_v2()` (daily 04:30) — overdue notification with OS aging brackets
- Cron: `credit_line.tasks.notify_overdue_partners()` (daily 00:30, disabled) — legacy overdue notification with `calculate_overdue_sum()`
- Called within `buffer_date_actions()`: `overdue_threshold_limit_end_date_actions()` resets expired threshold limits

---

## Entry Points

| Entry Point | Schedule | user_id Location | File Path |
|-------------|----------|-----------------|-----------|
| `update_credit_lines_status` | Celery Beat (02:00 daily) | Optional kwarg `partner_id` | `credit_line/tasks.py:update_credit_lines_status()` |
| `collect_user_profile_data_from_finbox` | Celery Beat (17:00 daily) | Optional kwarg `partner_ids` (comma-separated) | `credit_line/tasks.py:collect_user_profile_data_from_finbox()` |
| `notify_overdue_partners_v2` | Celery Beat (04:30 daily) | Derived from `Customer` queryset | `credit_line/tasks.py:notify_overdue_partners_v2()` |
| `notify_overdue_partners` | Celery Beat (00:30 daily, disabled) | Derived from `Customer` queryset | `credit_line/tasks.py:notify_overdue_partners()` |
| `overdue_threshold_limit_end_date_actions` | Called programmatically | Optional kwarg `partner_id` | `credit_line/tasks.py:overdue_threshold_limit_end_date_actions()` |

---

## Execution Sequence

### Path A: Credit Line Status Update (`update_credit_lines_status`)

This is the primary risk evaluation path. It evaluates aged outstanding amounts and repayment frequency for each customer, potentially placing credit lines on `ONHOLD` status.

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `update_credit_lines_status(partner_id=None)` | `credit_line/tasks.py:2648` | Entry point (Celery Beat, daily 02:00). Filters `Customer` records where `customer_type__name=DC` and `external_lender_supported=True`. If `partner_id` provided, runs synchronously; otherwise dispatches `get_aged_outstanding_status_info.apply_async()` per customer. |
| 2 | `get_aged_outstanding_status_info(partner_id)` | `credit_line/tasks.py:2487` | Core evaluation function. Fetches all `CustomerCreditLine` records for the partner (with `select_related('credit_product')`). Calls `populate_all_credit_lines([partner_id], expand="only_limit_data")` to get overdue data. |
| 3 | `populate_all_credit_lines(source_identifier_ids, expand)` | `credit_line/utils.py:727` | Executes raw SQL joining `credit_line_customer`, `credit_line_customercreditline`, `credit_line_creditproduct`, and `loan_loan` tables. Returns per-partner dict with `overdue_credit_limit`, `overdue_threshold_limit`, and per-credit-line `overdue_amount`. |
| 4 | **Aged Outstanding Check** (inline in `get_aged_outstanding_status_info`) | `credit_line/tasks.py:2510–2555` | For each credit line with status in `[ACTIVE, ONHOLD]` and sub_status in `[ACTIVE, REPAYMENT_FREQUENCY, AGED_OUTSTANDING, MISCELLANEOUS, ONBOARDING_POD]`: computes `total_overdue_amount - overdue_credit_limit > overdue_threshold_limit`. If true and `business_override=False` → sets `status=ONHOLD`, `sub_status=AGED OUTSTANDING`. If false and currently `AGED OUTSTANDING` → reverts to `ACTIVE/ACTIVE` (or `ONHOLD/ONBOARDING POD` if `transition_from_onboarding_pod` is set). |
| 5 | `credit_line.save(auto_update=True)` | `credit_line/model/customer_credit_line.py:306` | Persists status/sub_status changes. The `pre_save_data_points()` method captures initial state for event tracking. |
| 6 | `send_update_aged_outstanding_to_onboarding_pod.apply_async((partner_id,))` | `credit_line/tasks.py:2475` | Triggered only when reverting from `AGED OUTSTANDING` back to `ONBOARDING POD`. Sends email notification via `EmailTemplates.MARKED_ONHOLD_ONBOARDING_POD_EVENT`. |
| 7 | `get_repayment_frequency_sub_status_info(partner_id, customer_credit_lines)` | `credit_line/tasks.py:2564` | Called after aged outstanding check completes. Evaluates repayment frequency for the same credit lines. |
| 8 | Fetch `repayment_duration`, `repayment_frequency_outstanding_cutoff`, `repayment_frequency_ratio` from `CreditProduct` | `credit_line/tasks.py:2570–2590` | Iterates credit lines to find non-GAPL credit product fields. Prefers non-DORMANT credit lines. |
| 9 | `get_outstanding_before_last_repayment_date(last_repayment_date, partner_id)` | `ledger/utils.py:975` | Queries `LedgerEntry` for outstanding before `now() - repayment_duration` days. Excludes `REFUNDED` entries. |
| 10 | `get_payments_made_after_repayment_date(last_repayment_date, partner_id)` | `ledger/utils.py:986` | Queries `LedgerEntry` for payments (CREDIT_NOTE + PAYMENT - DEBIT_ENTRY) after the repayment date. |
| 11 | **Repayment Frequency Check** (inline) | `credit_line/tasks.py:2610–2650` | Computes `repayment_unblock_amount = (outstanding × ratio) - payments`. If `> 1` and `business_override=False` → sets `status=ONHOLD`, `sub_status=REPAYMENT FREQUENCY`. If currently `REPAYMENT FREQUENCY` and amount ≤ 1 → reverts to `ACTIVE/ACTIVE`. |
| 12 | `credit_line.save(auto_update=True)` | `credit_line/model/customer_credit_line.py:306` | Persists repayment frequency status changes. Updates `repayment_date_outstanding_amount` and `repayment_unblock_amount` fields. |

### Path B: Overdue Sum Calculation (`calculate_overdue_sum` via `overdue_notification_batch`)

Used by the overdue notification flow to compute outstanding amounts across aging brackets (30, 45, 60, 75, 90, 120, 150 days).

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `notify_overdue_partners()` | `credit_line/tasks.py:3292` | Legacy entry point (Celery Beat, 00:30 daily, currently disabled). Filters `Customer` where `customer_type__name=DC`. Paginates by `OVERDUE_NOTIFICATION_PARTNERS_BATCH_SIZE` (default 100). |
| 2 | `overdue_notification_batch.apply_async((source_ids,))` | `credit_line/tasks.py:3312` | Async task per batch. Fetches SAP IDs via `OdooDB.get_sap_ids_from_odoo_id_list()`, credit line data via `populate_all_credit_lines()`, ledger outstanding via `fetch_ledger_aggregated_only_limit_data()`, and oldest overdue loan via `fetch_dcs_oldest_overdue_loan()`. |
| 3 | `calculate_overdue_sum(source_ids, "30", {}, first_attempt=True)` | `credit_line/tasks.py:3263` | First call: computes `post_outstanding_amount` sum for 30-day overdue window. Calls `populate_only_limit_data(source_ids, days="30")`. Returns dict of `{source_id: sum}` where sum > 0. |
| 4 | `populate_only_limit_data(source_identifier_ids, days)` | `credit_line/utils.py:193` | Executes raw SQL joining `credit_line_customer`, `credit_line_customercreditline`, `credit_line_creditproduct`, and `loan_loan`. The `days` parameter filters loans whose `overdue_date` falls within the specified window. Returns per-partner credit line data with `post_outstanding_amount`. |
| 5 | `calculate_overdue_sum(source_ids, "45", os_30_plus)` | `credit_line/tasks.py:3263` | Subsequent calls: uses previous result's keys as `source_ids` filter (cascading — only partners with positive 30-day outstanding are checked for 45-day, etc.). |
| 6 | Repeat for 60, 75, 90, 120, 150 day brackets | `credit_line/tasks.py:3325–3331` | Each call narrows the partner set progressively. |
| 7 | Build `event_data` per partner | `credit_line/tasks.py:3332–3395` | Assembles notification payload with overdue days, outstanding amounts, aging brackets, and fires `OverdueNotificationsEvent`. |

### Path C: Overdue Notification V2 (`notify_overdue_partners_v2`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `notify_overdue_partners_v2()` | `credit_line/tasks.py:3684` | Entry point (Celery Beat, 04:30 daily). Checks `OVERDUE_NOTIFICATION_ENABLED_FOR_ALL` app constant. Filters `Customer` where `customer_type__name=DC`. Paginates by `NOTIFY_OD_PARTNERS_BATCH_SIZE` (default 100). |
| 2 | `verify_OD_and_OS_and_send_notifs_if_required.apply_async((source_identifier_ids,))` | `credit_line/tasks.py:3740` | Async task per batch. Calls `populate_only_limit_data(source_identifier_ids)` to get overdue data. |
| 3 | Overdue amount aggregation (inline) | `credit_line/tasks.py:3762–3790` | For each partner, sums `overdue_amount` across non-DORMANT credit lines (or DORMANT with `OUTSTANDING REMAINING` sub_status). Compares against `overdue_credit_limit`. |
| 4 | `get_partners_os_with_variable_aging(OS_check_required_partners)` | `credit_line/utils.py:5284` | For partners exceeding overdue limit, fetches outstanding with aging brackets (pre-90, pre-120, pre-150 days). |
| 5 | Notification decision logic (inline) | `credit_line/tasks.py:3820–3870` | Determines notification type based on aging bracket and day-of-week eligibility. Types: `OD_NOTIF_FOR_150_OS_AND_CRITICAL_OD`, `OD_NOTIF_FOR_120_TO_150_OS`, `OD_NOTIF_FOR_90_TO_120_OS`, `OD_NOTIF_FOR_UNDER_90_OS`, `OD_WARNING_NOTIF`. |
| 6 | `send_overdue_notification_to_DCs(data_for_notification)` | `credit_line/tasks.py` | Sends notifications to eligible partners. |

### Path D: FinBox Data Collection (`collect_user_profile_data_from_finbox`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `collect_user_profile_data_from_finbox(partner_ids="")` | `credit_line/tasks.py:3417` | Entry point (Celery Beat, 17:00 daily, queue `top_priority`). Reads `FINBOX_CONSTANTS` app constant for base filters and retrieval frequency (`DAILY`, `WEEKLY`, `MONTHLY`). |
| 2 | Frequency gate check (inline) | `credit_line/tasks.py:3435–3460` | Validates retrieval frequency type and checks if current day matches `FINBOX_RETRIEVAL_ENABLED_DAY` (weekday for WEEKLY, day-of-month for MONTHLY). |
| 3 | Partner filter (inline) | `credit_line/tasks.py:3460–3470` | If `FINBOX_RETRIEVAL_ENABLED_FOR_ALL` is false, restricts to `FINBOX_RETRIEVAL_ENABLED_PARTNERS` (comma-separated list). |
| 4 | `Customer.objects.filter(**customer_filter)` | `credit_line/tasks.py:3472` | Fetches eligible customers from `credit_line_customer`. |
| 5 | `is_consent_available_for_fetching_finbox_data(customer)` | `credit_line/tasks.py:3403` | Checks `customer.data_permissions_consent` JSON field for `sms_consent`, `apps_consent`, `device_consent`, `location_consent` — all must be `True`. |
| 6 | `convert_source_identifier_id_to_finbox_customer_id(customer)` | `credit_line/utils.py:4549` | Converts customer to FinBox ID format: `"DC"` or `"FR"` prefix + zero-padded `customer.id` (8 digits). |
| 7 | `get_finbox_data.apply_async((finbox_customer_id, partner_id), countdown=countdown_timer)` | `credit_line/tasks.py:3478` | Dispatches async task per customer (queue `medium_priority`). Countdown increments by 1 second per customer to respect FinBox rate limit (5 req/sec). |
| 8 | `get_finbox_data(finbox_customer_id, partner_id)` | `credit_line/tasks.py:3505` | Polls FinBox API in a loop. Calls `retrieve_user_data_from_finbox(finbox, finbox_customer_id)` → `FinBox.collect_user_data()`. |
| 9 | `FinBox.collect_user_data(unique_identifier)` | `common/external/finbox/finbox.py:33` | POST to FinBox API URL with `customer_id`, `version` (DC_PREDICTORS_VERSION), and `salt` (MD5+SHA256 hash). Timeout from `FINBOX.TIMEOUT` setting. |
| 10 | Polling loop (inline) | `credit_line/tasks.py:3512–3530` | If status is `IN_PROGRESS` and < 120s elapsed → sleep 10s and retry. If `ERROR` with 429/5xx status and < 2 retries → exponential backoff. Otherwise breaks. |
| 11 | `is_retrial_needed_for_finbox_error_codes(status, time_passed, status_code, error_retrial)` | `credit_line/tasks.py:3485` | Returns `True` if status is `ERROR`, time < 120s, HTTP 429 or 5xx, and retrial count < 2. |
| 12 | On `COMPLETE` status: save to `FinBoxData` | `credit_line/tasks.py:3535–3555` | Updates existing `FinBoxData` record (by `customer__source_identifier_id`) or creates new one via `FinBoxDataSerializer`. Stores `profile_data` JSON and `profile_data_updated_at` timestamp. |
| 13 | On non-COMPLETE status: send failure email | `credit_line/tasks.py:3557–3565` | Sends `FINBOX_SYNC_FAILURE` email with partner_id, API status, and message. |

### Path E: Overdue Threshold Limit Expiry (`overdue_threshold_limit_end_date_actions`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `overdue_threshold_limit_end_date_actions(today_date=None, partner_id=None)` | `credit_line/tasks.py:3663` | Filters `Customer` records where `overdue_threshold_limit_end_date < today`. Optionally filtered by `partner_id`. |
| 2 | Reset fields (inline) | `credit_line/tasks.py:3670–3672` | Sets `overdue_threshold_limit = 0` and `overdue_threshold_limit_end_date = None` for each matched customer. |
| 3 | `bulk_update_with_history(customers, Customer, fields)` | `credit_line/tasks.py:3673` | Bulk updates the `credit_line_customer` table with history tracking. |

---

## Celery Tasks Triggered

| Task | Queue | Triggered By | Description |
|------|-------|-------------|-------------|
| `update_credit_lines_status` | `celery` (default) | Celery Beat (02:00) | Orchestrator: dispatches `get_aged_outstanding_status_info` per customer |
| `get_aged_outstanding_status_info` | `celery` (default) | `update_credit_lines_status` | Per-partner aged outstanding + repayment frequency evaluation |
| `send_update_aged_outstanding_to_onboarding_pod` | `email` | `get_aged_outstanding_status_info` | Email notification when reverting from AGED OUTSTANDING to ONBOARDING POD |
| `collect_user_profile_data_from_finbox` | `top_priority` | Celery Beat (17:00) | Orchestrator: dispatches `get_finbox_data` per customer |
| `get_finbox_data` | `medium_priority` | `collect_user_profile_data_from_finbox` | Per-customer FinBox API polling and data storage |
| `notify_overdue_partners_v2` | `event` | Celery Beat (04:30) | Orchestrator: dispatches `verify_OD_and_OS_and_send_notifs_if_required` per batch |
| `verify_OD_and_OS_and_send_notifs_if_required` | `event` | `notify_overdue_partners_v2` | Per-batch overdue verification and notification |
| `notify_overdue_partners` | `event` | Celery Beat (00:30, disabled) | Legacy orchestrator: dispatches `overdue_notification_batch` per batch |
| `overdue_notification_batch` | `event` | `notify_overdue_partners` | Per-batch overdue sum calculation and notification |
| `capture_status_change_event` | `event` | `CustomerCreditLine.save(auto_update=True)` | Captures status/sub_status change events for tracking |

---

## Database Tables Accessed

| Table | Operation | Accessed By | Key Columns |
|-------|-----------|-------------|-------------|
| `credit_line_customer` | READ | `update_credit_lines_status`, `collect_user_profile_data_from_finbox`, `overdue_threshold_limit_end_date_actions`, `get_finbox_data` | `source_identifier_id`, `customer_type_id`, `external_lender_supported`, `overdue_credit_limit`, `overdue_threshold_limit`, `overdue_threshold_limit_end_date`, `data_permissions_consent` |
| `credit_line_customer` | WRITE | `overdue_threshold_limit_end_date_actions` | `overdue_threshold_limit`, `overdue_threshold_limit_end_date` |
| `credit_line_customercreditline` | READ | `get_aged_outstanding_status_info`, `populate_all_credit_lines`, `populate_only_limit_data` | `customer_id`, `credit_product_id`, `status`, `sub_status`, `business_override`, `overdue_days`, `aged_outstanding_amount`, `repayment_unblock_amount` |
| `credit_line_customercreditline` | WRITE | `get_aged_outstanding_status_info`, `get_repayment_frequency_sub_status_info` | `status`, `sub_status`, `aged_outstanding_amount`, `repayment_date_outstanding_amount`, `repayment_unblock_amount`, `transition_from_onboarding_pod` |
| `credit_line_creditproduct` | READ | `get_aged_outstanding_status_info`, `get_repayment_frequency_sub_status_info` | `belongs_to_gapl`, `repayment_duration`, `repayment_frequency_outstanding_cutoff`, `repayment_frequency_ratio` |
| `credit_line_finboxdata` | READ/WRITE | `get_finbox_data` | `customer_id`, `profile_data`, `profile_data_updated_at` |
| `loan_loan` | READ | `populate_all_credit_lines`, `populate_only_limit_data`, `fetch_dcs_oldest_overdue_loan` | `customer_credit_line_id`, `status`, `overdue_date`, `remaining_amount`, `loan_amount` |
| `ledger_ledgerentry` | READ | `get_outstanding_before_last_repayment_date`, `get_payments_made_after_repayment_date`, `fetch_ledger_aggregated_only_limit_data` | `partner_id`, `date`, `type`, `amount`, `active`, `visible` |
| `credit_line_customertype` | READ | `populate_only_limit_data` | `name` |
| `django_celery_results_taskresult` | READ (investigation) | N/A | `task_name`, `status`, `date_done`, `task_args` |

---

## Decision Points

> Cross-reference: See `docs/forensic/04-decision-logic.md` for full condition expressions and line numbers.

| # | Decision | Condition | Outcomes | Location |
|---|----------|-----------|----------|----------|
| D1 | Aged Outstanding Threshold | `total_overdue_amount - overdue_credit_limit > overdue_threshold_limit` | **True** → `ONHOLD / AGED OUTSTANDING`; **False + currently AGED OUTSTANDING** → revert to `ACTIVE / ACTIVE` (or `ONHOLD / ONBOARDING POD`) | `credit_line/tasks.py:get_aged_outstanding_status_info()` |
| D2 | Business Override Guard | `credit_line.business_override == True` | **True** → skip status change (no auto-update); **False** → apply status change | `credit_line/tasks.py:get_aged_outstanding_status_info()` |
| D3 | Transition from Onboarding Pod | `credit_line.transition_from_onboarding_pod == True` (on revert) | **True** → revert to `ONHOLD / ONBOARDING POD` + send email; **False** → revert to `ACTIVE / ACTIVE` | `credit_line/tasks.py:get_aged_outstanding_status_info()` |
| D4 | Repayment Unblock Amount | `repayment_unblock_amount > 1` | **True** → `ONHOLD / REPAYMENT FREQUENCY`; **False + currently REPAYMENT FREQUENCY** → revert to `ACTIVE / ACTIVE` | `credit_line/tasks.py:get_repayment_frequency_sub_status_info()` |
| D5 | Repayment Outstanding Cutoff | `net_outstanding_on_last_repayment_date > repayment_frequency_outstanding_cutoff` | **True** → compute `repayment_unblock_amount`; **False** → `repayment_unblock_amount = 0` | `credit_line/tasks.py:get_repayment_frequency_sub_status_info()` |
| D6 | FinBox Consent Check | All 4 consent flags `True` in `data_permissions_consent` JSON | **True** → proceed with FinBox API call; **False** → skip partner, log message | `credit_line/tasks.py:is_consent_available_for_fetching_finbox_data()` |
| D7 | FinBox Retrieval Frequency Gate | `retrieval_frequency_type` + `FINBOX_RETRIEVAL_ENABLED_DAY` vs current day | **Match** → proceed; **No match** → return early | `credit_line/tasks.py:collect_user_profile_data_from_finbox()` |
| D8 | FinBox API Status | `status == COMPLETE` | **COMPLETE** → save profile data; **IN_PROGRESS** → retry (up to 120s); **ERROR** → retry with backoff (up to 2 retries); **Other** → send failure email | `credit_line/tasks.py:get_finbox_data()` |
| D9 | Overdue Threshold Expiry | `overdue_threshold_limit_end_date < today` | **True** → reset `overdue_threshold_limit = 0` and `overdue_threshold_limit_end_date = None`; **False** → no action | `credit_line/tasks.py:overdue_threshold_limit_end_date_actions()` |
| D10 | Overdue Notification Eligibility (V2) | `overdue_amount > overdue_credit_limit` + aging bracket + day-of-week | Determines notification type: `150_OS_CRITICAL`, `150_OS_NON_CRITICAL`, `120_TO_150_OS`, `90_TO_120_OS`, `UNDER_90_OS`, `OD_WARNING` | `credit_line/tasks.py:verify_OD_and_OS_and_send_notifs_if_required()` |

---

## Investigation Queries

### Query 1: Customer Risk Profile

**Used by**: Path A → `update_credit_lines_status()` → `get_aged_outstanding_status_info()`
**Decides**: Whether the customer's credit lines should be evaluated for risk (D1, D2)

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
**Performance**: Uses unique index on `credit_line_customer.source_identifier_id`. Expected < 10ms.

---

### Query 2: Credit Line Status and Risk Fields

**Used by**: Path A → `get_aged_outstanding_status_info()`
**Decides**: Current status/sub_status, business_override, aged_outstanding_amount (D1, D2, D3, D4)

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
**Performance**: Uses index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 20ms.

---

### Query 3: Overdue Loans Contributing to Risk

**Used by**: Path A → `populate_all_credit_lines()` (raw SQL), Path B → `populate_only_limit_data()`
**Decides**: `overdue_amount` per credit line, `total_overdue_amount` (D1)

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
**Performance**: Uses index on `loan_loan.customer_credit_line_id`. Expected < 50ms for typical partner.

---

### Query 4: Ledger Entries for Repayment Frequency Check

**Used by**: Path A → `get_outstanding_before_last_repayment_date()`, `get_payments_made_after_repayment_date()`
**Decides**: `repayment_unblock_amount` (D4, D5)

**ORM**:
```python
from ledger.models import LedgerEntry

# Outstanding before last repayment date
LedgerEntry.objects.filter(
    partner_id='{user_id}',
    date__lt=last_repayment_date,
    active=True, visible=True
).exclude(type='REFUNDED')

# Payments after last repayment date
LedgerEntry.objects.filter(
    partner_id='{user_id}',
    date__gte=last_repayment_date,
    active=True, visible=True
).values('type', 'amount', 'date')
```

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
**Performance**: Uses index on `ledger_ledgerentry.partner_id`. Add date range filter for large datasets. Expected < 100ms.
**Warning**: Partners with high transaction volume may have thousands of ledger entries. Add `AND date >= '{start_date}'` to bound the query.

---

### Query 5: FinBox Data for User

**Used by**: Path D → `get_finbox_data()`
**Decides**: Whether FinBox profile data exists and when it was last updated (D8)

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
**Performance**: Uses unique constraint on `credit_line_finboxdata.customer_id` (OneToOneField). Expected < 10ms.

> **Note**: To inspect the actual FinBox profile data JSON, add `fd.profile_data` to the SELECT. This field can be large.

---

### Query 6: FinBox Consent Status

**Used by**: Path D → `is_consent_available_for_fetching_finbox_data()`
**Decides**: Whether FinBox data collection proceeds for this user (D6)

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
**Performance**: Uses unique index on `source_identifier_id`. Expected < 5ms.

> **Check**: All four keys must be `true`: `sms_consent`, `apps_consent`, `device_consent`, `location_consent`.

---

### Query 7: Overdue Threshold Limit Expiry Status

**Used by**: Path E → `overdue_threshold_limit_end_date_actions()`
**Decides**: Whether the overdue threshold limit has expired (D9)

**ORM**:
```python
from credit_line.model.customer import Customer

Customer.objects.filter(
    source_identifier_id='{user_id}'
).values(
    'overdue_threshold_limit', 'overdue_threshold_limit_end_date'
)
```

**SQL**:
```sql
SELECT overdue_threshold_limit, overdue_threshold_limit_end_date
FROM credit_line_customer
WHERE source_identifier_id = '{user_id}';
```
**Performance**: Uses unique index on `source_identifier_id`. Expected < 5ms.

---

### Query 8: Celery Task History for Risk Evaluation Tasks

**Used by**: All paths — trace task execution for a specific user
**Decides**: Whether tasks ran successfully, failed, or are pending

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
        'credit_line.tasks.overdue_notification_batch',
    ],
    task_args__contains='{user_id}'
).order_by('-date_done').values(
    'task_id', 'task_name', 'status', 'date_done', 'result', 'traceback'
)[:20]
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
    'credit_line.tasks.verify_OD_and_OS_and_send_notifs_if_required',
    'credit_line.tasks.overdue_notification_batch'
)
AND task_args LIKE '%{user_id}%'
ORDER BY date_done DESC
LIMIT 20;
```
**Performance**: Uses index on `django_celery_results_taskresult.task_name`. The `LIKE` on `task_args` may be slow — add `AND date_done >= '{start_date}'` to bound.
**Warning**: `task_args` is a text field; `LIKE '%...%'` does not use indexes. Restrict date range for production use.

---

### Query 9: Credit Line Status Change History (via `django-simple-history`)

**Used by**: Path A — trace when status/sub_status changed
**Decides**: Historical context for risk evaluation decisions

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
**Performance**: Expected < 100ms with date range filter. History tables can grow large.
**Warning**: Add `AND h.history_date >= '{start_date}'` for production queries.
