# 05 — Celery Workflow Tracing

> Trace asynchronous task execution to debug delayed or failed operations for a specific `{user_id}` (`source_identifier_id` / `partner_id`).

**Cross-references**: [01-entry-points.md](01-entry-points.md) · [03-runtime-data.md](03-runtime-data.md) · [04-decision-logic.md](04-decision-logic.md) · [08-failure-scenarios.md](08-failure-scenarios.md)

---

## Celery Configuration

| Setting | Value | Source |
|---------|-------|--------|
| `CELERY_RESULT_BACKEND` | `django-db` | `config/settings/base.py` |
| `CELERY_BEAT_SCHEDULER` | `django_celery_beat.schedulers:DatabaseScheduler` | `config/settings/base.py` |
| `CELERY_TASK_TIME_LIMIT` | **300 s** (5 min hard kill) | `config/settings/base.py` |
| `CELERY_TASK_SOFT_TIME_LIMIT` | **60 s** (SoftTimeLimitExceeded raised) | `config/settings/base.py` |
| `CELERY_ACCEPT_CONTENT` | `["json", "pickle"]` | `config/settings/base.py` |
| `CELERY_TASK_SERIALIZER` | `json` | `config/settings/base.py` |
| `BROKER_POOL_LIMIT` | `0` | `config/settings/base.py` |
| App name | `locus` | `config/celery_app.py` |
| Autodiscover | All registered Django apps | `config/celery_app.py` |
| `result_chord_join_timeout` | `10` | `config/celery_app.py` |

### Configured Queues

| Queue | Typical Usage |
|-------|---------------|
| `top_priority` | SAP/ERP postings, payment transfers, auto-pay, lender onboarding |
| `medium_priority` | FinBox data retrieval, SAP draft payment operations |
| `saraloan` | Saraloan API sync (credit lines, repayments, loans, webhooks) |
| `saraloan_invoice` | Invoice upload to Saraloan / BlackSoil |
| `saraloan_credit_line` | Credit line info fetch from Saraloan |
| `saraloan_failure` | Retry of failed Saraloan partner syncs |
| `celery` | Default queue — demand sheets, repayment corrections, nodes sync |
| `email` | Email notifications, failure alerts |
| `event` | MoEngage/Mixpanel events, overdue notifications, reconciliation events |
| `notification` | Mailman payment notifications |
| `sap_migration` | Odoo-to-SAP migration (disabled) |
| `reconciliation` | Reconciliation-specific tasks |

---

## Workflow 1 — Loan-to-Lender Pipeline

**Purpose**: Share the oldest GAPL loan to an external lender (Saraloan / BlackSoil) by uploading invoices and creating tranches.

**Beat trigger**: `share_oldest_loan_to_lender_for_all_partners` — daily at **03:00 UTC**

### Task Execution Order

```
share_oldest_loan_to_lender_for_all_partners()          [celery]
  └─► share_oldest_loan_to_lender(partner_id)            [celery] (staggered countdown=15*n)
        ├─► run_reconciliation_for_customer_main()        [celery] (inline before share)
        └─► prepare_loan_to_send_to_saraloan(loan_id)    [celery]
              ├─► send_invoice_to_saraloan(llm_id)        [saraloan_invoice]
              │     └─► create_tranche_in_blacksoil()     [saraloan_invoice]
              │           ├─► update_subvention_details_in_saraloan()  [saraloan_invoice]
              │           │     └─► create_invoice_in_blacksoil()      [saraloan_invoice]
              │           └─► create_invoice_in_blacksoil()            [saraloan_invoice] (countdown=3)
              ├─► create_tranche_in_blacksoil(llm_id)     [saraloan_invoice] (direct path)
              └─► create_invoice_in_blacksoil(llm_id)     [saraloan_invoice] (direct path)
```

**Webhook callback** (asynchronous, triggered by lender):
```
External webhook → process_saraloan_loan_webhook(request, status)  [saraloan]
  └─► process_disbursal_event(vals)
        ├─► process_full_disbursal(vals)
        └─► process_partial_disbursal(comment, vals, remaining_amount)
```

### Task Details

| Task | File | Queue | Retry Config | Failure Handling |
|------|------|-------|-------------|------------------|
| `share_oldest_loan_to_lender_for_all_partners` | `loan/tasks.py:1607` | `celery` | None | Honeybadger wrapper; iterates partners, failures isolated per partner |
| `share_oldest_loan_to_lender` | `loan/tasks.py:1671` | `celery` | `autoretry_for=(Exception,)`, `retry_backoff=180`, `retry_backoff_max=1800`, `max_retries=3` | Redis lock prevents concurrent runs per partner; Honeybadger wrapper |
| `prepare_loan_to_send_to_saraloan` | `loan/tasks.py:1465` | `celery` | None | Creates `LenderLoanMap`, routes to appropriate lender task |
| `send_invoice_to_saraloan` | `loan/tasks.py:465` | `saraloan_invoice` | None | Sends failure email via `_send_invoice_upload_fail_email`; fires MoEngage event |
| `create_tranche_in_blacksoil` | `loan/tasks.py:581` | `saraloan_invoice` | None | Sends failure email; fires MoEngage event; chains to `create_invoice_in_blacksoil` on success |
| `create_invoice_in_blacksoil` | `loan/tasks.py:710` | `saraloan_invoice` | None | Sends failure email; on success may re-trigger `share_oldest_loan_to_lender` with countdown=3 |
| `update_subvention_details_in_saraloan` | `loan/tasks.py:895` | `saraloan_invoice` | None | Sends failure email; chains to `create_invoice_in_blacksoil` on success |
| `process_saraloan_loan_webhook` | `credit_line/tasks.py:1261` | `saraloan` | None | Processes lender webhook; calls `process_disbursal_event` for disbursal status |


---

## Workflow 2 — Repayment Sync

**Purpose**: Fetch repayment data from Saraloan for all financed DCs, create/update `Payment` records, and update credit line status.

**Beat trigger**: `sync_repayment_info_for_all_dc` — daily at **19:30 UTC**

### Task Execution Order

```
sync_repayment_info_for_all_dc()                         [saraloan]
  └─► fetch_and_update_repayments_info(ccl_id, ...)       [saraloan]
        ├─► process_records()                              (sync function, not a task)
        │     └─► validate_and_create_or_update_payment()  (sync function)
        └─► update_credit_lines_status(partner_id)         [celery] (countdown=3)
```

**Webhook path** (real-time repayment events from Saraloan):
```
External webhook → process_saraloan_repayment_webhook(event, data)  (sync function)
  └─► process_repayment_data(repayment_data, event)       [saraloan] (countdown=300 on retry)
        └─► update_credit_lines_status(partner_id)         [celery]
```

### Task Details

| Task | File | Queue | Retry Config | Failure Handling |
|------|------|-------|-------------|------------------|
| `sync_repayment_info_for_all_dc` | `payment/tasks.py:596` | `saraloan` | None | Iterates credit lines; failures isolated per partner; logs + skips missing lender maps |
| `fetch_and_update_repayments_info` | `payment/tasks.py:682` | `saraloan` | None | Sends `PAYMENT_SYNC_FAILURE_EVENT` email on exception; re-raises for Honeybadger |
| `process_repayment_data` | `payment/tasks.py:854` | `saraloan` | `autoretry_for=(Exception,)`, `retry_backoff=180`, `max_retries=3` | Retries on any exception with 3-min exponential backoff |
| `update_credit_lines_status` | `credit_line/tasks.py:2648` | `celery` | None | Updates status/sub-status of credit lines based on overdue calculations |

---

## Workflow 3 — Credit Line Sync

**Purpose**: Sync credit line information (available limit, outstanding, lender status) from Saraloan for all financed customers.

**Beat trigger**: `sync_credit_lines_info_from_saraloan` — daily at **22:00 UTC**

### Task Execution Order

```
sync_credit_lines_info_from_saraloan()                    [saraloan]
  └─► sync_credit_line_info_from_saraloan(ccl_id)         [saraloan]
        └─► fetch_and_update_credit_line_info(ccl_id, ...) [saraloan_credit_line]
```

**Related loan params sync** (separate beat entry):
```
sync_loans_params_from_saraloan()                         [saraloan]  (daily 21:30 UTC)
  └─► sync_credit_line_loans_params_from_saraloan(ccl_id) [saraloan]
        └─► fetch_and_update_loans_params(ccl_id, ...)     [saraloan]
```

### Task Details

| Task | File | Queue | Retry Config | Failure Handling |
|------|------|-------|-------------|------------------|
| `sync_credit_lines_info_from_saraloan` | `credit_line/tasks.py:634` | `saraloan` | None | Iterates credit lines; dispatches per-CCL tasks |
| `sync_credit_line_info_from_saraloan` | `credit_line/tasks.py:646` | `saraloan` | None | Returns early if non-financed DC or missing lender map; calls `sync_partner_ids_from_saraloan` to resolve missing maps |
| `fetch_and_update_credit_line_info` | `credit_line/tasks.py:479` | `saraloan_credit_line` | `autoretry_for=(Exception,)`, `retry_backoff=1800`, `max_retries=2` | 30-min exponential backoff; sends failure email via `_send_credit_line_info_failure_mail` |
| `sync_loans_params_from_saraloan` | `credit_line/tasks.py:733` | `saraloan` | None | Iterates credit lines for unpaid loans |
| `sync_credit_line_loans_params_from_saraloan` | `credit_line/tasks.py:745` | `saraloan` | None | Fetches and updates loan parameters per credit line |
| `fetch_and_update_loans_params` | `credit_line/tasks.py:1752` | `saraloan` | None | Updates loan data from Saraloan withdrawal details |
| `refresh_saraloan_loan_account` | `credit_line/tasks.py:459` | `saraloan` | `autoretry_for=(ValidationError,)`, `retry_backoff=7200`, `max_retries=1` | 2-hour backoff on validation errors |

---

## Workflow 4 — Payment Transfer

**Purpose**: Aggregate GAPL payments per credit line, create SAP draft entries, and transfer funds to the external lender via NEFT.

**Beat triggers**:
- `aggregate_payment_transfer` — weekdays at **10:30 UTC**
- `transfer_all_agg_payments` — weekdays at **10:35 UTC**

### Task Execution Order

```
aggregate_payment_transfer()                              [top_priority*]
  └─► aggregate_ccl_payment_transfer(ccl_id)              [top_priority*]
        └─► (creates AggregatedPaymentTransfer records)

transfer_all_agg_payments()                               [top_priority*]
  └─► transfer_agg_payment(agg_payment_id)                [top_priority*]
        ├─► create_transfer_to_lender_payment_in_draft_mode()  (sync)
        ├─► prep_transfer_payment_data()                       (sync)
        ├─► transfer_payment()                                 (sync — NEFT API call)
        └─► send_payment_transfer_failed_email()          [top_priority] (on failure)
```

*Note: `aggregate_payment_transfer`, `aggregate_ccl_payment_transfer`, `transfer_all_agg_payments`, and `transfer_agg_payment` use `celery="top_priority"` (a typo in the codebase — should be `queue=`). These tasks route to the default `celery` queue unless the broker routes them differently.*

**Post-transfer sync** (hourly):
```
sync_all_aggregated_payments()                            [top_priority*]
  └─► sync_aggregated_payment(agg_payment_id)             [top_priority*]
```

**Reversal** (weekdays at 04:00 UTC):
```
reverse_aggregated_payments()                             [top_priority*]
  └─► reverse_transfer_to_lender_partner_payments(partner_id, payment_ids)  [top_priority*]
```

### Task Details

| Task | File | Queue | Retry Config | Failure Handling |
|------|------|-------|-------------|------------------|
| `aggregate_payment_transfer` | `payment/tasks.py:2066` | `celery`* | None | Checks app constant for allowed partners; skips if disabled |
| `aggregate_ccl_payment_transfer` | `payment/tasks.py:2131` | `celery`* | None | Verifies reconciliation consistency; marks inconsistent credit lines |
| `transfer_all_agg_payments` | `payment/tasks.py:2349` | `celery`* | None | Filters `YET_TO_TRANSFER` / `ERROR` with `transfer_try_count < max` |
| `transfer_agg_payment` | `payment/tasks.py:2260` | `celery`* | `autoretry_for=(Exception,)`, `retry_backoff=300`, `retry_backoff_max=1800`, `max_retries=3` | Redis lock prevents concurrent transfers; sends failure email; tracks `transfer_try_count` |
| `sync_all_aggregated_payments` | `payment/tasks.py:2383` | `celery`* | None | Syncs payment status from payment service |
| `sync_aggregated_payment` | `payment/tasks.py:2401` | `celery`* | None | Updates individual aggregated payment status |
| `reverse_aggregated_payments` | `payment/tasks.py:2456` | `celery`* | None | Reverses failed/errored transfers |
| `send_payment_transfer_failed_email` | `payment/tasks.py:2330` | `top_priority` | None | Sends `PAYMENT_TRANSFER_FAILED` email |
| `mark_sap_draft_payment_deleted` | `payment/tasks.py:2424` | `medium_priority` | None | Marks SAP draft as deleted |
| `mark_sap_draft_payment_posted` | `payment/tasks.py:2438` | `medium_priority` | None | Marks SAP draft as posted |


---

## Workflow 5 — Reconciliation

**Purpose**: Match GAPL payments against outstanding loans and debit notes, update loan statuses (partially paid / paid), and fire reconciliation events.

**Beat trigger**: `check_and_run_reconciliation_for_all_customers` — daily at **04:00 UTC**

### Task Execution Order

```
check_and_run_reconciliation_for_all_customers()          [celery]
  └─► run_reconciliation_for_customer_main(partner_id)    [celery]
        ├─► (reconciliation logic in loan/utility.py)
        ├─► fire_loan_reconciliation_event(ccl_id, data)  [event]
        └─► fire_locus_reconciliation_event(cust_id, data) [event]
```

**Also triggered by**:
- `run_reconciliation_for_customers(partner_ids)` — dispatches `run_reconciliation_for_customer_main` per partner
- Payment creation (via `payment/views.py`, `payment/signals.py`)
- Credit note creation (via `payment/signals.py:create_payment_for_cn`)
- Invoice actions (via `invoice/views.py`, `invoice/tasks.py`)
- Loan sharing (via `share_oldest_loan_to_lender` — runs reconciliation before sharing)
- Payment cancellation (via `payment/utils.py` — runs synchronously)

### Task Details

| Task | File | Queue | Retry Config | Failure Handling |
|------|------|-------|-------------|------------------|
| `check_and_run_reconciliation_for_all_customers` | `loan/tasks.py:2126` | `celery` | None | Honeybadger wrapper; filters eligible partners (those with unreconciled payments + outstanding loans/debit notes) |
| `run_reconciliation_for_customers` | `loan/tasks.py:2103` | `celery` | None | Dispatches per-partner tasks |
| `run_reconciliation_for_customer_main` | `loan/utility.py:482` | `celery` | None | Honeybadger wrapper; `@transaction.atomic`; Redis lock for concurrency control |
| `fire_loan_reconciliation_event` | `loan/tasks.py:2495` | `event` | `autoretry_for=(Exception,)`, `retry_backoff=1800`, `max_retries=2` | 30-min backoff; fires MoEngage/Mixpanel event |
| `fire_locus_reconciliation_event` | `loan/tasks.py:2525` | `event` | `autoretry_for=(Exception,)`, `retry_backoff=1800`, `max_retries=2` | 30-min backoff; fires MoEngage/Mixpanel event |

---

## Additional Celery Workflows

### Auto-Pay Workflow

**Beat trigger**: `initiate_emi_auto_debit_request` — daily at **11:00 UTC**

```
initiate_emi_auto_debit_request()                         [top_priority]
  └─► trigger_emi_auto_debit_request(auto_debit_id)       [top_priority]
```

| Task | File | Queue | Retry Config |
|------|------|-------|-------------|
| `initiate_emi_auto_debit_request` | `auto_pay/tasks.py:255` | `top_priority` | None |
| `trigger_emi_auto_debit_request` | `auto_pay/tasks.py:223` | `top_priority` | None |
| `initiate_auto_pay_mandate_setup` | `auto_pay/tasks.py:49` | `top_priority` | None |
| `update_mandate_status` | `auto_pay/tasks.py:200` | `top_priority` | None |
| `update_auto_debit_status` | `auto_pay/tasks.py:385` | `top_priority` | None |
| `create_auto_debit_for_demand_sheet` | `auto_pay/tasks.py:269` | `top_priority` | None |

### SAP/ERP Posting Workflow

**Beat trigger**: `send_disbursement_payments_to_erp` — daily at **01:00 UTC**

```
send_disbursement_payments_to_erp()                       [top_priority]
  ├─► send_disbursement_payment_to_erp(loan_id)           [top_priority]
  ├─► send_disbursement_posted_payment_to_erp(loan_id)    [top_priority]
  └─► send_disbursal_refund_payment_to_sap(loan_id)       [top_priority] (countdown=5)
```

| Task | File | Queue | Retry Config |
|------|------|-------|-------------|
| `send_disbursement_payments_to_erp` | `loan/tasks.py:1158` | `top_priority` | None |
| `send_disbursement_payment_to_erp` | `loan/tasks.py:1298` | `top_priority` | None — sends failure email on error |
| `send_disbursement_posted_payment_to_erp` | `loan/tasks.py:1289` | `top_priority` | None |
| `send_disbursal_refund_payment_to_sap` | `loan/tasks.py:1182` | `top_priority` | Self-retries via `apply_async(countdown=5)` on missing data |
| `check_and_create_la_entries_in_sap` | `payment/tasks.py:1702` | `celery` | None — Honeybadger wrapper |
| `create_la_entry_in_sap` | `payment/tasks.py:1626` | `top_priority` | None — Honeybadger wrapper |
| `send_refund_payment_to_sap` | `payment/tasks.py:1898` | `top_priority` | None |
| `send_failed_refund_payment_entries_to_sap` | `payment/tasks.py:1956` | `top_priority` | None |

### Overdue Notification Workflow

**Beat triggers**:
- `notify_overdue_partners_v2` — daily at **04:30 UTC**
- `trigger_over_due_event` — daily at **00:30 UTC**
- `notify_partners_for_overdue_invoices` — daily at **02:30 UTC** (via `credit_line/tasks.py`)

```
notify_overdue_partners_v2()                              [event]
  └─► verify_OD_and_OS_and_send_notifs_if_required(ids)   [event]

trigger_over_due_event()                                  [event]
  └─► trigger_event()                                     (per farmer with pending EMI)
```

### FinBox Data Collection

**Beat trigger**: `collect_user_profile_data_from_finbox` — daily at **17:00 UTC**

```
collect_user_profile_data_from_finbox()                   [top_priority]
  └─► get_finbox_data(finbox_customer_id, partner_id)     [medium_priority]
```

| Task | File | Queue | Retry Config |
|------|------|-------|-------------|
| `collect_user_profile_data_from_finbox` | `credit_line/tasks.py:3417` | `top_priority` | None — Honeybadger wrapper |
| `get_finbox_data` | `credit_line/tasks.py:3505` | `medium_priority` | None — Honeybadger wrapper; checks `is_retrial_needed_for_finbox_error_codes` |

### Ledger Visibility Updates

**Beat triggers**:
- `_update_debit_record_payment_visibility` — every **5 minutes**
- `_update_old_debit_record_payment_visibility` — at **01:05 and 13:05 UTC**

| Task | File | Queue | Retry Config |
|------|------|-------|-------------|
| `_update_debit_record_payment_visibility` | `ledger/tasks.py:233` | `celery` | None — Honeybadger wrapper |
| `_update_old_debit_record_payment_visibility` | `ledger/tasks.py:253` | `celery` | None — Honeybadger wrapper |
| `send_payment_notification_to_mailman` | `ledger/tasks.py:168` | `notification` | None — Honeybadger wrapper |
| `populate_is_parent_entry` | `ledger/tasks.py:322` | `celery` | `autoretry_for=(LedgerEntry.DoesNotExist,)`, `retry_backoff=True`, `max_retries=2`, `countdown=2` |

---

## Investigation Queries — Task State

### Retrieve task result by task name

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name='loan.tasks.share_oldest_loan_to_lender',
    status='FAILURE',
).order_by('-date_done')[:20]
```

**SQL**:
```sql
-- Performance: Uses index on (task_name, status, date_done). Expected < 100ms.
SELECT id, task_id, task_name, status, result, date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE task_name = 'loan.tasks.share_oldest_loan_to_lender'
  AND status = 'FAILURE'
ORDER BY date_done DESC
LIMIT 20;
```

### Retrieve task result by task ID

**ORM**:
```python
TaskResult.objects.filter(task_id='{task_id}')
```

**SQL**:
```sql
-- Performance: Uses unique index on task_id. Expected < 10ms.
SELECT id, task_id, task_name, status, result, date_done, traceback, task_args, task_kwargs
FROM django_celery_results_taskresult
WHERE task_id = '{task_id}';
```

### Retrieve all task results for a specific user

Tasks store `{user_id}` in `task_args` or `task_kwargs`. Since these are text fields, use pattern matching:

**ORM**:
```python
from django.db.models import Q

TaskResult.objects.filter(
    Q(task_args__contains='{user_id}') | Q(task_kwargs__contains='{user_id}')
).order_by('-date_done')[:50]
```

**SQL**:
```sql
-- ⚠ Performance warning: Full text scan on task_args/task_kwargs.
-- Add date_done filter to limit scan scope. Expected 200–2000ms depending on table size.
SELECT id, task_id, task_name, status, result, date_done, traceback,
       task_args, task_kwargs
FROM django_celery_results_taskresult
WHERE (task_args LIKE '%{user_id}%' OR task_kwargs LIKE '%{user_id}%')
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 50;
```

### Retrieve failed tasks for a user in a specific workflow

**ORM**:
```python
TaskResult.objects.filter(
    task_name__in=[
        'loan.tasks.share_oldest_loan_to_lender_for_all_partners',
        'loan.tasks.share_oldest_loan_to_lender',
        'loan.tasks.prepare_loan_to_send_to_saraloan',
        'loan.tasks.send_invoice_to_saraloan',
        'loan.tasks.create_tranche_in_blacksoil',
        'loan.tasks.create_invoice_in_blacksoil',
        'loan.tasks.update_subvention_details_in_saraloan',
    ],
    status='FAILURE',
    task_args__contains='{user_id}',
).order_by('-date_done')[:20]
```

**SQL**:
```sql
-- Performance: Uses index on (task_name, status). LIKE on task_args adds scan cost.
-- Bound with date_done for production safety. Expected < 500ms.
SELECT id, task_id, task_name, status, result, date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE task_name IN (
    'loan.tasks.share_oldest_loan_to_lender_for_all_partners',
    'loan.tasks.share_oldest_loan_to_lender',
    'loan.tasks.prepare_loan_to_send_to_saraloan',
    'loan.tasks.send_invoice_to_saraloan',
    'loan.tasks.create_tranche_in_blacksoil',
    'loan.tasks.create_invoice_in_blacksoil',
    'loan.tasks.update_subvention_details_in_saraloan'
)
  AND status = 'FAILURE'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '30 days'
ORDER BY date_done DESC
LIMIT 20;
```

### Retrieve repayment sync task history for a user

**ORM**:
```python
TaskResult.objects.filter(
    task_name__in=[
        'payment.tasks.sync_repayment_info_for_all_dc',
        'payment.tasks.fetch_and_update_repayments_info',
        'payment.tasks.process_repayment_data',
    ],
    task_args__contains='{user_id}',
).order_by('-date_done')[:20]
```

**SQL**:
```sql
-- Performance: Index on (task_name, date_done). LIKE on task_args adds scan cost.
-- Expected < 500ms with date filter.
SELECT id, task_id, task_name, status, result, date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE task_name IN (
    'payment.tasks.sync_repayment_info_for_all_dc',
    'payment.tasks.fetch_and_update_repayments_info',
    'payment.tasks.process_repayment_data'
)
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '30 days'
ORDER BY date_done DESC
LIMIT 20;
```

### Retrieve credit line sync task history for a user

First, find the `CustomerCreditLine` ID for the user:

**ORM**:
```python
from credit_line.model import CustomerCreditLine

ccl_ids = list(
    CustomerCreditLine.objects.filter(
        customer__source_identifier_id='{user_id}'
    ).values_list('id', flat=True)
)

# Then search task results by CCL ID
for ccl_id in ccl_ids:
    results = TaskResult.objects.filter(
        task_name__in=[
            'credit_line.tasks.sync_credit_line_info_from_saraloan',
            'credit_line.tasks.fetch_and_update_credit_line_info',
        ],
        task_args__contains=str(ccl_id),
    ).order_by('-date_done')[:10]
```

**SQL**:
```sql
-- Step 1: Get CCL IDs for user. Uses index on source_identifier_id. Expected < 10ms.
SELECT ccl.id
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';

-- Step 2: Search task results by CCL ID (substitute {ccl_id} from step 1).
-- Performance: Index on (task_name, date_done). Expected < 500ms with date filter.
SELECT id, task_id, task_name, status, result, date_done, traceback, task_args
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

### Retrieve payment transfer task history for a user

**ORM**:
```python
from payment.model import AggregatedPaymentTransfer

agg_payments = AggregatedPaymentTransfer.objects.filter(
    customer__source_identifier_id='{user_id}'
).values_list('id', flat=True)

for agg_id in agg_payments:
    results = TaskResult.objects.filter(
        task_name__in=[
            'payment.tasks.aggregate_ccl_payment_transfer',
            'payment.tasks.transfer_agg_payment',
            'payment.tasks.sync_aggregated_payment',
        ],
        task_args__contains=str(agg_id),
    ).order_by('-date_done')[:10]
```

**SQL**:
```sql
-- Step 1: Get aggregated payment IDs for user. Expected < 50ms.
SELECT apt.id
FROM payment_aggregatedpaymenttransfer apt
JOIN credit_line_customer c ON apt.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}';

-- Step 2: Search task results (substitute {agg_id} from step 1).
-- Performance: Expected < 500ms with date filter.
SELECT id, task_id, task_name, status, result, date_done, traceback, task_args
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

### Retrieve reconciliation task history for a user

**ORM**:
```python
TaskResult.objects.filter(
    task_name__in=[
        'loan.tasks.check_and_run_reconciliation_for_all_customers',
        'loan.tasks.run_reconciliation_for_customers',
        'loan.utility.run_reconciliation_for_customer_main',
        'loan.tasks.fire_loan_reconciliation_event',
        'loan.tasks.fire_locus_reconciliation_event',
    ],
    task_args__contains='{user_id}',
).order_by('-date_done')[:20]
```

**SQL**:
```sql
-- Performance: Index on (task_name, date_done). Expected < 500ms with date filter.
SELECT id, task_id, task_name, status, result, date_done, traceback, task_args
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

---

## Investigation Queries — Task Execution Summary

### Count task executions by status for a user (last 7 days)

**ORM**:
```python
from django.db.models import Count

TaskResult.objects.filter(
    task_args__contains='{user_id}',
    date_done__gte=timezone.now() - timedelta(days=7),
).values('task_name', 'status').annotate(
    count=Count('id')
).order_by('task_name', 'status')
```

**SQL**:
```sql
-- ⚠ Performance warning: Full scan on task_args. Use date filter.
-- Expected 500–3000ms depending on table size.
SELECT task_name, status, COUNT(*) as count
FROM django_celery_results_taskresult
WHERE task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
GROUP BY task_name, status
ORDER BY task_name, status;
```

### Find tasks stuck in STARTED state (potential hangs)

**ORM**:
```python
TaskResult.objects.filter(
    status='STARTED',
    date_done__lte=timezone.now() - timedelta(minutes=10),
    task_args__contains='{user_id}',
)
```

**SQL**:
```sql
-- Performance: Index on (status, date_done). Expected < 100ms.
SELECT id, task_id, task_name, date_done, task_args
FROM django_celery_results_taskresult
WHERE status = 'STARTED'
  AND date_done <= NOW() - INTERVAL '10 minutes'
  AND task_args LIKE '%{user_id}%'
ORDER BY date_done DESC;
```

### Find retried tasks (indicates transient failures)

**ORM**:
```python
TaskResult.objects.filter(
    status='RETRY',
    task_args__contains='{user_id}',
    date_done__gte=timezone.now() - timedelta(days=7),
).order_by('-date_done')[:20]
```

**SQL**:
```sql
-- Performance: Index on (status, date_done). Expected < 200ms.
SELECT id, task_id, task_name, status, result, date_done, traceback, task_args
FROM django_celery_results_taskresult
WHERE status = 'RETRY'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

---

## Celery Beat Schedule Reference

Key scheduled tasks relevant to the five workflows above:

| Beat Entry | Task | Schedule | Queue |
|------------|------|----------|-------|
| `share_oldest_loan_to_lender_for_all_partner` | `loan.tasks.share_oldest_loan_to_lender_for_all_partners` | Daily 03:00 UTC | `celery` |
| `check_and_run_reconciliation_for_all_customers` | `loan.tasks.check_and_run_reconciliation_for_all_customers` | Daily 04:00 UTC | `celery` |
| `sync_repayment_info_for_all_dc` | `payment.tasks.sync_repayment_info_for_all_dc` | Daily 19:30 UTC | `saraloan` |
| `sync_credit_lines_info_from_saraloan` | `credit_line.tasks.sync_credit_lines_info_from_saraloan` | Daily 22:00 UTC | `saraloan` |
| `sync_loans_params_from_saraloan` | `credit_line.tasks.sync_loans_params_from_saraloan` | Daily 21:30 UTC | `saraloan` |
| `Aggregate Payments for Transfer` | `payment.tasks.aggregate_payment_transfer` | Weekdays 10:30 UTC | `celery`* |
| `Transfer All Aggregated Payments` | `payment.tasks.transfer_all_agg_payments` | Weekdays 10:35 UTC | `celery`* |
| `Sync All Aggregated Payments` | `payment.tasks.sync_all_aggregated_payments` | Hourly :15 | `celery`* |
| `Reverse Aggregated Payments` | `payment.tasks.reverse_aggregated_payments` | Weekdays 04:00 UTC | `celery`* |
| `Move GAPL Loan to Lender` | `loan.tasks.move_gapl_loan_to_lender` | Daily 00:30 UTC | `celery` |
| `Send Disbursement Payments to ERP` | `loan.tasks.send_disbursement_payments_to_erp` | Daily 01:00 UTC | `top_priority` |
| `Check and Create LA Entries in SAP` | `payment.tasks.check_and_create_la_entries_in_sap` | Daily 01:00 UTC | `celery` |
| `Update Credit Line Status Sub_Status` | `credit_line.tasks.update_credit_lines_status` | Daily 02:00 UTC | `celery` |
| `Collect User Profile Data From FinBox` | `credit_line.tasks.collect_user_profile_data_from_finbox` | Daily 17:00 UTC | `top_priority` |
| `FF Repayment Demand Notification Engine` | `repayment.tasks.initiate_repayment_reminder` | Daily 02:30 UTC | `celery` |
| `Trigger event having Over Due` | `repayment.tasks.trigger_over_due_event` | Daily 00:30 UTC | `event` |
| `Send Overdue Notification and Whatsapp Message` | `credit_line.tasks.notify_overdue_partners_v2` | Daily 04:30 UTC | `event` |
| `initiate_emi_auto_debit_request` | `auto_pay.tasks.initiate_emi_auto_debit_request` | Daily 11:00 UTC | `top_priority` |
| `Buffer End Date Actions` | `credit_line.tasks.buffer_date_actions` | Daily 16:30 UTC | `celery` |

---

## Retry Configuration Summary

| Task | Retry Trigger | Backoff (s) | Max Backoff (s) | Max Retries |
|------|--------------|-------------|-----------------|-------------|
| `share_oldest_loan_to_lender` | `Exception` | 180 | 1800 | 3 |
| `fetch_and_update_credit_line_info` | `Exception` | 1800 | — | 2 |
| `process_repayment_data` | `Exception` | 180 | — | 3 |
| `transfer_agg_payment` | `Exception` | 300 | 1800 | 3 |
| `fire_loan_reconciliation_event` | `Exception` | 1800 | — | 2 |
| `fire_locus_reconciliation_event` | `Exception` | 1800 | — | 2 |
| `fire_repayment_event` | `Exception` | 1800 | — | 2 |
| `refresh_saraloan_loan_account` | `ValidationError` | 7200 | — | 1 |
| `sync_failed_partners_saraloan_data` | `Exception` | 180 | 1800 | 3 |
| `update_minimum_sanctioned_amount` | `Exception` | 1800 | — | 2 |
| `send_notification_event_to_moengage` | `Exception` | 1800 | — | 3 |
| `prepare_trigger_gl_incentive_notification` | `Exception` | True (exponential) | — | 1 |
| `populate_is_parent_entry` | `LedgerEntry.DoesNotExist` | True (exponential) | — | 2 |
