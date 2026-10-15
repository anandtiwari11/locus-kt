# 08 — Failure Scenarios

> Known failure patterns with symptoms, investigation queries, affected flows, and resolution guidance.
> All queries are **read-only** (`SELECT` only) and accept `{user_id}` (`source_identifier_id` / `partner_id`) as input.

**Cross-references**:
- Celery Workflows: [`05-celery-workflows.md`](05-celery-workflows.md)
- Decision Logic: [`04-decision-logic.md`](04-decision-logic.md)
- Hypothesis Validation: [`07-hypothesis-validation.md`](07-hypothesis-validation.md)
- Playbooks: [`06-playbooks/`](06-playbooks/)
- Runtime Data: [`03-runtime-data.md`](03-runtime-data.md)

---

## Table of Contents

1. [Celery Task Failures](#1-celery-task-failures)
   - [1.1 Task Hard-Killed by Time Limit](#11-task-hard-killed-by-time-limit)
   - [1.2 Task Exhausted Max Retries](#12-task-exhausted-max-retries)
   - [1.3 Task Stuck in STARTED State](#13-task-stuck-in-started-state)
   - [1.4 Beat Schedule Task Did Not Fire](#14-beat-schedule-task-did-not-fire)
2. [Stale Data Reads](#2-stale-data-reads)
   - [2.1 Credit Line Data Not Synced from Saraloan](#21-credit-line-data-not-synced-from-saraloan)
   - [2.2 Repayment Data Not Synced](#22-repayment-data-not-synced)
   - [2.3 Loan Parameters Stale After Lender Update](#23-loan-parameters-stale-after-lender-update)
3. [Race Conditions](#3-race-conditions)
   - [3.1 Concurrent Reconciliation Runs](#31-concurrent-reconciliation-runs)
   - [3.2 Concurrent Loan Creation for Same Invoices](#32-concurrent-loan-creation-for-same-invoices)
   - [3.3 Concurrent Payment Transfer](#33-concurrent-payment-transfer)
   - [3.4 Duplicate Disbursal Webhook Processing](#34-duplicate-disbursal-webhook-processing)
4. [External API Failures](#4-external-api-failures)
   - [4.1 Saraloan API Timeout or Error](#41-saraloan-api-timeout-or-error)
   - [4.2 FinBox Data Collection Failure](#42-finbox-data-collection-failure)
   - [4.3 SAP/ERP Posting Failure](#43-saperp-posting-failure)
   - [4.4 Payment Service Transfer Failure](#44-payment-service-transfer-failure)
5. [Data Inconsistency](#5-data-inconsistency)
   - [5.1 Loan Amount vs Disbursed Amount Mismatch](#51-loan-amount-vs-disbursed-amount-mismatch)
   - [5.2 Payment Reconcilable Amount Drift](#52-payment-reconcilable-amount-drift)
   - [5.3 Credit Line Outstanding vs Loan Sum Mismatch](#53-credit-line-outstanding-vs-loan-sum-mismatch)
   - [5.4 Orphaned LenderLoanMap Records](#54-orphaned-lenderloanmap-records)
   - [5.5 Ledger Entry Missing for Disbursed Loan](#55-ledger-entry-missing-for-disbursed-loan)

---

## 1. Celery Task Failures

### 1.1 Task Hard-Killed by Time Limit

**Symptoms**:
- A user operation (loan sharing, reconciliation, payment sync) appears to hang and never completes.
- Task result shows `status = FAILURE` with `WorkerLostError` or `TimeLimitExceeded` in traceback.
- The system has `CELERY_TASK_TIME_LIMIT = 300s` (hard kill) and `CELERY_TASK_SOFT_TIME_LIMIT = 60s` (`SoftTimeLimitExceeded` raised). See `config/settings/base.py`.

**Investigation Queries**:

**ORM**:
```python
from django_celery_results.models import TaskResult
from django.db.models import Q

TaskResult.objects.filter(
    Q(task_args__contains='{user_id}') | Q(task_kwargs__contains='{user_id}'),
    status='FAILURE',
).filter(
    Q(traceback__contains='TimeLimitExceeded') |
    Q(traceback__contains='SoftTimeLimitExceeded') |
    Q(traceback__contains='WorkerLostError')
).order_by('-date_done')[:10]
```

**SQL**:
```sql
-- ⚠ Performance warning: LIKE on task_args + traceback. Always include date filter.
-- Expected 500–2000ms depending on table size.
SELECT id, task_id, task_name, status, date_done, traceback
FROM django_celery_results_taskresult
WHERE (task_args LIKE '%{user_id}%' OR task_kwargs LIKE '%{user_id}%')
  AND status = 'FAILURE'
  AND (traceback LIKE '%TimeLimitExceeded%'
       OR traceback LIKE '%SoftTimeLimitExceeded%'
       OR traceback LIKE '%WorkerLostError%')
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 10;
```

**Affected Flows**:
- Reconciliation (`run_reconciliation_for_customer_main`) — partners with many loans/payments can exceed 60s soft limit. See [`05-celery-workflows.md` § Workflow 5](05-celery-workflows.md).
- Credit line sync (`fetch_and_update_credit_line_info`) — Saraloan API latency can push past soft limit.
- Loan-to-lender pipeline (`share_oldest_loan_to_lender`) — complex pre-share reconciliation can be slow.

**Resolution**:
1. Check the `traceback` field for the specific task that timed out.
2. If reconciliation: verify the partner has an unusually large number of unreconciled payments or outstanding loans. Consider adding the partner to `BLACKLIST_RECONCILIATION_FOR_PARTNERS` temporarily.
3. If Saraloan sync: check Saraloan API health. The `fetch_and_update_credit_line_info` task has `autoretry_for=(Exception,)` with `retry_backoff=1800` and `max_retries=2` — verify if retries succeeded.
4. For recurring timeouts, the task may need optimization or the time limits may need adjustment in `config/settings/base.py`.

---

### 1.2 Task Exhausted Max Retries

**Symptoms**:
- A task that normally retries on failure (e.g., `share_oldest_loan_to_lender`, `process_repayment_data`, `transfer_agg_payment`) has stopped retrying and the operation is stuck.
- Task result shows `status = FAILURE` with `MaxRetriesExceededError` in traceback.

**Investigation Queries**:

**ORM**:
```python
from django_celery_results.models import TaskResult
from django.db.models import Q

TaskResult.objects.filter(
    Q(task_args__contains='{user_id}') | Q(task_kwargs__contains='{user_id}'),
    status__in=['FAILURE', 'RETRY'],
    task_name__in=[
        'loan.tasks.share_oldest_loan_to_lender',
        'payment.tasks.process_repayment_data',
        'payment.tasks.transfer_agg_payment',
        'credit_line.tasks.fetch_and_update_credit_line_info',
    ],
).order_by('-date_done')[:20]
```

**SQL**:
```sql
-- Performance: Index on (task_name, status, date_done). LIKE on task_args adds scan cost.
-- Expected < 500ms with date filter.
SELECT id, task_id, task_name, status, result, date_done, traceback
FROM django_celery_results_taskresult
WHERE (task_args LIKE '%{user_id}%' OR task_kwargs LIKE '%{user_id}%')
  AND status IN ('FAILURE', 'RETRY')
  AND task_name IN (
      'loan.tasks.share_oldest_loan_to_lender',
      'payment.tasks.process_repayment_data',
      'payment.tasks.transfer_agg_payment',
      'credit_line.tasks.fetch_and_update_credit_line_info'
  )
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Affected Flows**:
- Loan-to-lender pipeline: `share_oldest_loan_to_lender` — `max_retries=3`, `retry_backoff=180s`. See [`05-celery-workflows.md` § Workflow 1](05-celery-workflows.md).
- Repayment sync: `process_repayment_data` — `max_retries=3`, `retry_backoff=180s`. See [`05-celery-workflows.md` § Workflow 2](05-celery-workflows.md).
- Payment transfer: `transfer_agg_payment` — `max_retries=3`, `retry_backoff=300s`. See [`05-celery-workflows.md` § Workflow 4](05-celery-workflows.md).
- Credit line sync: `fetch_and_update_credit_line_info` — `max_retries=2`, `retry_backoff=1800s`. See [`05-celery-workflows.md` § Workflow 3](05-celery-workflows.md).

**Resolution**:
1. Examine the `traceback` of the final `FAILURE` entry to identify the root cause (API error, database error, validation error).
2. Look at the sequence of `RETRY` → `RETRY` → `FAILURE` entries to see if the error is consistent or transient.
3. If the underlying issue is resolved (e.g., external API is back up), manually re-trigger the task or wait for the next beat schedule run.
4. For `transfer_agg_payment`: check `AggregatedPaymentTransfer.transfer_try_count` — the system also limits retries at the application level.

---

### 1.3 Task Stuck in STARTED State

**Symptoms**:
- A user's operation appears to be in progress indefinitely.
- Task result shows `status = STARTED` with `date_done` older than 10 minutes.
- The Celery worker may have crashed without updating the result backend.

**Investigation Queries**:

**ORM**:
```python
from django_celery_results.models import TaskResult
from django.utils import timezone
from datetime import timedelta

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

**Affected Flows**:
- Any flow that uses Celery tasks. Most commonly seen in long-running reconciliation or Saraloan sync tasks.

**Resolution**:
1. Check if the Celery worker is still running (`celery inspect active`).
2. If the worker crashed, the task will remain in `STARTED` forever. The operation needs to be re-triggered manually.
3. For reconciliation tasks: check if a Redis lock is still held (see [§ 3.1](#31-concurrent-reconciliation-runs)). The lock may need manual cleanup.
4. For tasks with `@transaction.atomic` (e.g., `run_reconciliation_for_customer_main`), a worker crash will roll back the database transaction, but the Redis lock may persist.

---

### 1.4 Beat Schedule Task Did Not Fire

**Symptoms**:
- A daily sync or batch operation did not run at its scheduled time.
- Data is stale (e.g., credit line info not updated, repayments not synced).
- No task results exist for the expected time window.

**Investigation Queries**:

**ORM**:
```python
from django_celery_results.models import TaskResult
from django.utils import timezone
from datetime import timedelta

# Check if the beat task ran in the last 48 hours
TaskResult.objects.filter(
    task_name='credit_line.tasks.sync_credit_lines_info_from_saraloan',
    date_done__gte=timezone.now() - timedelta(hours=48),
).values('task_id', 'status', 'date_done').order_by('-date_done')[:5]
```

**SQL**:
```sql
-- Performance: Index on (task_name, date_done). Expected < 50ms.
SELECT task_id, status, date_done
FROM django_celery_results_taskresult
WHERE task_name = 'credit_line.tasks.sync_credit_lines_info_from_saraloan'
  AND date_done >= NOW() - INTERVAL '48 hours'
ORDER BY date_done DESC
LIMIT 5;
```

Replace the `task_name` with any beat-scheduled task:
- `payment.tasks.sync_repayment_info_for_all_dc` (daily 19:30 UTC)
- `loan.tasks.check_and_run_reconciliation_for_all_customers` (daily 04:00 UTC)
- `loan.tasks.share_oldest_loan_to_lender_for_all_partners` (daily 03:00 UTC)
- `credit_line.tasks.update_credit_lines_status` (daily 02:00 UTC)

**Affected Flows**:
- All flows that depend on scheduled data sync. See [`05-celery-workflows.md` § Celery Beat Schedule Reference](05-celery-workflows.md).

**Resolution**:
1. Check the Celery Beat process is running and connected to the broker.
2. Verify the `django_celery_beat` schedule entries in the database (`django_celery_beat_periodictask` table).
3. Check the broker (Redis/RabbitMQ) health — if the broker was down during the scheduled time, the task was never enqueued.
4. Manually trigger the missed task if needed.

---

## 2. Stale Data Reads

### 2.1 Credit Line Data Not Synced from Saraloan

**Symptoms**:
- Credit limit, available limit, or outstanding amount on the lender credit line is outdated.
- The `updated_at` timestamp on `CustomerCreditLine` is older than 48 hours.
- User sees incorrect available credit or limit values.

**Investigation Queries**:

**ORM**:
```python
from credit_line.model import CustomerCreditLine
from django.utils import timezone
from datetime import timedelta

# Check credit line freshness
stale_threshold = timezone.now() - timedelta(hours=48)

CustomerCreditLine.objects.filter(
    customer__source_identifier_id='{user_id}',
    credit_product__belongs_to_gapl=False,
).values(
    'id', 'credit_limit', 'lender_available_credit_limit',
    'lender_outstanding_amount', 'updated_at',
    'credit_product__credit_product_name'
).filter(updated_at__lt=stale_threshold)
```

**SQL**:
```sql
-- Performance: Index on customer_id + credit_product_id. Expected < 10ms.
SELECT ccl.id, ccl.credit_limit, ccl.lender_available_credit_limit,
       ccl.lender_outstanding_amount, ccl.updated_at,
       cp.credit_product_name,
       CASE WHEN ccl.updated_at < NOW() - INTERVAL '48 hours'
            THEN 'STALE'
            ELSE 'FRESH'
       END AS freshness
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
  AND cp.belongs_to_gapl = false;
```

**Confirm staleness with sync task history**:

```sql
-- Performance: Index on (task_name, date_done). Expected < 100ms with date filter.
SELECT task_name, status, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'credit_line.tasks.sync_credit_line_info_from_saraloan',
    'credit_line.tasks.fetch_and_update_credit_line_info'
)
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 5;
```

**Affected Flows**:
- Credit eligibility — stale `lender_available_credit_limit` may incorrectly block or allow operations. See [`02-user-flows/credit-eligibility.md`](02-user-flows/credit-eligibility.md).
- Credit limit calculation — `credit_limit` from Saraloan not updated. See [`02-user-flows/credit-limit-calculation.md`](02-user-flows/credit-limit-calculation.md).
- Loan sharing — stale limits may cause incorrect loan amount calculations.

**Resolution**:
1. Check if the `sync_credit_lines_info_from_saraloan` beat task ran (see [§ 1.4](#14-beat-schedule-task-did-not-fire)).
2. Check if `CustomerLenderMap` exists with valid `business_id` and `loan_account_id` — missing maps cause the sync to skip the customer.
3. Manually trigger `fetch_and_update_credit_line_info` for the affected credit line.
4. See [Hypothesis 2.1 in `07-hypothesis-validation.md`](07-hypothesis-validation.md) for detailed verification.

---

### 2.2 Repayment Data Not Synced

**Symptoms**:
- Payments from the lender are not reflected in the system.
- `Payment` records are missing or have outdated amounts.
- Credit line status not updated after lender-side repayment.

**Investigation Queries**:

**ORM**:
```python
from payment.model import Payment
from credit_line.model import CustomerCreditLine

# Check latest payment timestamps
Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values(
    'id', 'payment_amount', 'status', 'sub_status',
    'payment_date', 'created_at', 'updated_at'
).order_by('-created_at')[:10]
```

**SQL**:
```sql
-- Performance: Index on customer_credit_line_id. Expected < 20ms.
SELECT p.id, p.payment_amount, p.status, p.sub_status,
       p.payment_date, p.created_at, p.updated_at,
       cp.credit_product_name
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY p.created_at DESC
LIMIT 10;
```

**Check repayment sync task history**:

```sql
-- Performance: Index on (task_name, date_done). Expected < 500ms with date filter.
SELECT task_name, status, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'payment.tasks.sync_repayment_info_for_all_dc',
    'payment.tasks.fetch_and_update_repayments_info',
    'payment.tasks.process_repayment_data'
)
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 10;
```

**Affected Flows**:
- Repayment workflow — payments not created or updated. See [`02-user-flows/repayment-workflow.md`](02-user-flows/repayment-workflow.md).
- Reconciliation — unreconciled payments not available for matching. See [`06-playbooks/payment-reconciliation-playbook.md`](06-playbooks/payment-reconciliation-playbook.md).
- Risk evaluation — credit line status not updated based on repayments.

**Resolution**:
1. Check if `sync_repayment_info_for_all_dc` ran (daily 19:30 UTC). See [§ 1.4](#14-beat-schedule-task-did-not-fire).
2. Check if `fetch_and_update_repayments_info` failed for this credit line — look for `PAYMENT_SYNC_FAILURE_EVENT` emails.
3. If the repayment came via webhook, check `external_externalwebhook` for the event (see [§ 4.1](#41-saraloan-api-timeout-or-error)).
4. Manually trigger `process_repayment_data` for the affected repayment.

---

### 2.3 Loan Parameters Stale After Lender Update

**Symptoms**:
- Loan interest rates, overdue dates, or subvention details are outdated compared to lender records.
- The `sync_loans_params_from_saraloan` task (daily 21:30 UTC) may have failed.

**Investigation Queries**:

**ORM**:
```python
from loan.model import Loan, LenderLoanMap

# Check loan parameter freshness
Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    status__in=['DISBURSED', 'PARTIALLY_PAID', 'OVERDUE', 'OVERDUE_AND_PARTIALLY_PAID'],
).values(
    'id', 'loan_id', 'total_interest', 'overdue_date',
    'subvention_date', 'updated_at'
).order_by('-updated_at')[:10]
```

**SQL**:
```sql
-- Performance: Index on customer_credit_line_id. Expected < 20ms.
SELECT ll.id, ll.loan_id, ll.total_interest, ll.overdue_date,
       ll.subvention_date, ll.updated_at,
       CASE WHEN ll.updated_at < NOW() - INTERVAL '48 hours'
            THEN 'STALE'
            ELSE 'FRESH'
       END AS freshness
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status IN ('DISBURSED', 'PARTIALLY_PAID', 'OVERDUE', 'OVERDUE_AND_PARTIALLY_PAID')
ORDER BY ll.updated_at DESC
LIMIT 10;
```

**Affected Flows**:
- Risk evaluation — overdue calculations use stale interest/date data. See [`02-user-flows/risk-evaluation.md`](02-user-flows/risk-evaluation.md).
- Reconciliation — incorrect remaining amounts affect payment matching.

**Resolution**:
1. Check if `sync_loans_params_from_saraloan` ran (daily 21:30 UTC).
2. Manually trigger `fetch_and_update_loans_params` for the affected credit line.
3. See [`05-celery-workflows.md` § Workflow 3](05-celery-workflows.md) for the full sync chain.

---

## 3. Race Conditions

### 3.1 Concurrent Reconciliation Runs

**Symptoms**:
- Duplicate payment-to-loan mappings created.
- Loan marked as `PAID` but payments still show `UNRECONCILED`.
- Error log: `"Locus Reconciliation already running for partner - {partner_id}"`.
- `@transaction.atomic` on `run_reconciliation_for_customer_main` (`loan/utility.py:482`) rolls back on conflict, but Redis lock may persist.

**Investigation Queries**:

**ORM**:
```python
from django_celery_results.models import TaskResult
from django.db.models import Q

# Find overlapping reconciliation tasks
TaskResult.objects.filter(
    task_name__in=[
        'loan.utility.run_reconciliation_for_customer_main',
        'loan.tasks.run_reconciliation_for_customers',
    ],
    task_args__contains='{user_id}',
).values(
    'task_id', 'status', 'date_done', 'result'
).order_by('-date_done')[:20]
```

**SQL**:
```sql
-- Performance: Index on (task_name, date_done). Expected < 500ms with date filter.
SELECT task_id, task_name, status, date_done, result
FROM django_celery_results_taskresult
WHERE task_name IN (
    'loan.utility.run_reconciliation_for_customer_main',
    'loan.tasks.run_reconciliation_for_customers'
)
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Check for overlapping execution windows** (two tasks running within seconds of each other):

```sql
-- Performance: Same as above. Expected < 500ms.
SELECT t1.task_id AS task_1, t1.date_done AS done_1,
       t2.task_id AS task_2, t2.date_done AS done_2,
       ABS(EXTRACT(EPOCH FROM (t1.date_done - t2.date_done))) AS gap_seconds
FROM django_celery_results_taskresult t1
JOIN django_celery_results_taskresult t2
  ON t1.task_name = t2.task_name
  AND t1.task_id < t2.task_id
  AND ABS(EXTRACT(EPOCH FROM (t1.date_done - t2.date_done))) < 60
WHERE t1.task_name = 'loan.utility.run_reconciliation_for_customer_main'
  AND t1.task_args LIKE '%{user_id}%'
  AND t2.task_args LIKE '%{user_id}%'
  AND t1.date_done >= NOW() - INTERVAL '7 days';
```

**Check `locus_recon_last_ran_at` timestamp**:

```sql
-- Performance: Unique index on source_identifier_id. Expected < 10ms.
SELECT id, source_identifier_id, locus_recon_last_ran_at
FROM credit_line_customer
WHERE source_identifier_id = '{user_id}';
```

**Affected Flows**:
- Reconciliation — the primary flow affected. See [`05-celery-workflows.md` § Workflow 5](05-celery-workflows.md).
- Reconciliation is triggered by: beat schedule (04:00 UTC), payment creation, credit note creation, loan sharing, and invoice actions.

**Resolution**:
1. The system uses `check_or_add_redis_cache_for_reconciliation(partner_id)` as a distributed lock (`credit_line/utility/invoice_share_utils.py`). If a lock is stuck, it needs manual cleanup.
2. Verify `locus_recon_last_ran_at` on the `Customer` record — if it's recent, reconciliation did complete.
3. If duplicate mappings exist, run `run_unreconciliation_for_customer` followed by `run_reconciliation_for_customer_main` to re-reconcile cleanly.
4. Check if the partner is in `BLACKLIST_RECONCILIATION_FOR_PARTNERS` or `PARTNER_LIST_FOR_RECONCILIATION` app constants.

---

### 3.2 Concurrent Loan Creation for Same Invoices

**Symptoms**:
- `IntegrityError` in loan creation tasks.
- Duplicate loans created for the same invoice set.
- Error log from `check_if_loan_creation_from_invoice_already_running()` (`loan/utility.py:2180`).

**Investigation Queries**:

**ORM**:
```python
from loan.model import Loan, InvoiceLoanMap
from django.db.models import Count

# Find invoices mapped to multiple loans
InvoiceLoanMap.objects.filter(
    loan__customer_credit_line__customer__source_identifier_id='{user_id}'
).values('invoice_id').annotate(
    loan_count=Count('loan_id', distinct=True)
).filter(loan_count__gt=1)
```

**SQL**:
```sql
-- Performance: Index on loan_id. Expected < 50ms.
SELECT ilm.invoice_id, COUNT(DISTINCT ilm.loan_id) AS loan_count,
       ARRAY_AGG(DISTINCT ll.loan_id) AS loan_ids,
       ARRAY_AGG(DISTINCT ll.status) AS loan_statuses
FROM loan_invoiceloanmap ilm
JOIN loan_loan ll ON ilm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
GROUP BY ilm.invoice_id
HAVING COUNT(DISTINCT ilm.loan_id) > 1;
```

**Check for IntegrityError in task results**:

```sql
-- Performance: Expected < 500ms with date filter.
SELECT task_id, task_name, status, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_args LIKE '%{user_id}%'
  AND traceback LIKE '%IntegrityError%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 10;
```

**Affected Flows**:
- Approval workflow — loan creation via `LoanViewSet.post()` and `create_loan_in_bulk()`. See [`02-user-flows/approval-workflow.md`](02-user-flows/approval-workflow.md).

**Resolution**:
1. The system uses a `RedLock` (`LOCK_LOAN_CREATION`) in `loan/utility.py:2191` to prevent concurrent loan creation for the same invoices.
2. If the lock failed (Redis issue), duplicate loans may exist. Cancel the duplicate loan(s) and verify invoice mappings.
3. Check if the API was called multiple times (duplicate POST requests) by examining request logs. See [`09-log-correlation.md`](09-log-correlation.md).

---

### 3.3 Concurrent Payment Transfer

**Symptoms**:
- Duplicate NEFT transfers for the same aggregated payment.
- `AggregatedPaymentTransfer` shows `transfer_try_count` higher than expected.
- Error in `transfer_agg_payment` task.

**Investigation Queries**:

**ORM**:
```python
from payment.model import AggregatedPaymentTransfer

AggregatedPaymentTransfer.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'transfer_try_count', 'amount',
    'created_at', 'updated_at'
).order_by('-created_at')[:10]
```

**SQL**:
```sql
-- Performance: Index on customer_id. Expected < 20ms.
SELECT apt.id, apt.status, apt.transfer_try_count, apt.amount,
       apt.created_at, apt.updated_at
FROM payment_aggregatedpaymenttransfer apt
JOIN credit_line_customer c ON apt.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY apt.created_at DESC
LIMIT 10;
```

**Affected Flows**:
- Payment transfer workflow. See [`05-celery-workflows.md` § Workflow 4](05-celery-workflows.md).

**Resolution**:
1. The `transfer_agg_payment` task uses a Redis lock to prevent concurrent transfers. Check if the lock is functioning.
2. If duplicate transfers occurred, use the `reverse_aggregated_payments` task (weekdays 04:00 UTC) to reverse failed transfers.
3. Check `transfer_try_count` against the max allowed count configured in `AGGREGATED_PAYMENT_TRANSFER_MAX_COUNT`.

---

### 3.4 Duplicate Disbursal Webhook Processing

**Symptoms**:
- Loan disbursed twice or loan amount doubled.
- Multiple `process_saraloan_loan_webhook` task results for the same loan.
- Lender sent the same webhook event multiple times.

**Investigation Queries**:

**SQL**:
```sql
-- Check for duplicate webhook events
-- Performance: Index on (created_at, event_type). Expected < 100ms with date filter.
SELECT id, event_type, timestamp, created_at,
       request_body::text
FROM external_externalwebhook
WHERE request_body::text LIKE '%{user_id}%'
  AND event_type LIKE '%disbursal%'
  AND created_at >= NOW() - INTERVAL '7 days'
ORDER BY created_at DESC
LIMIT 20;
```

**Check for duplicate disbursal processing tasks**:

```sql
-- Performance: Index on (task_name, date_done). Expected < 500ms with date filter.
SELECT task_id, task_name, status, date_done, task_args
FROM django_celery_results_taskresult
WHERE task_name = 'credit_line.tasks.process_saraloan_loan_webhook'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Affected Flows**:
- Approval workflow — disbursal processing via `process_disbursal_event()`. See [`04-decision-logic.md` § 5](04-decision-logic.md).

**Resolution**:
1. The system uses a Redis cache check (`check_or_add_redis_cache_common(BLACKSOIL_DISBURSAL, lender_loan_id, ...)`) in `credit_line/tasks.py` to prevent duplicate disbursal processing. See [`04-decision-logic.md` § Branch 5.2](04-decision-logic.md).
2. If the Redis lock expired between duplicate webhooks, both may have been processed. Check loan amounts and status.
3. If a loan was disbursed twice, verify the `disbursed_amount` and `remaining_amount` fields on the loan.

---

## 4. External API Failures

### 4.1 Saraloan API Timeout or Error

**Symptoms**:
- Invoice upload to Saraloan fails — `LenderLoanMap.invoice_upload_status` shows `TRANSACTION_CREATION_FAILED`, `INVOICE_UPLOAD_FAILED`, or `APPLICATION_NOT_FOUND`.
- Credit line sync fails — lender credit limit and outstanding not updated.
- Repayment sync fails — payments from lender not reflected.
- Failure emails sent via `_send_invoice_upload_fail_email` or `_send_credit_line_info_failure_mail`.
- Saraloan API has a configurable timeout (default 5s) in `common/external/saraloan/saraloan.py`.

**Investigation Queries**:

**ORM**:
```python
from external.models import ExternalWebhook

# Check recent webhook events for this user
ExternalWebhook.objects.filter(
    request_body__contains='{user_id}',
    created_at__gte=timezone.now() - timedelta(days=7),
).values(
    'id', 'event_type', 'timestamp', 'created_at'
).order_by('-created_at')[:20]
```

**SQL**:
```sql
-- Performance: Index on (created_at, event_type). Expected < 100ms with date filter.
-- ⚠ Warning: request_body text search may be slow on large tables.
SELECT id, event_type, timestamp, created_at,
       LEFT(request_body::text, 500) AS request_body_preview
FROM external_externalwebhook
WHERE request_body::text LIKE '%{user_id}%'
  AND created_at >= NOW() - INTERVAL '7 days'
ORDER BY created_at DESC
LIMIT 20;
```

**Check LenderLoanMap for upload failures**:

```sql
-- Performance: Index on loan_id. Expected < 20ms.
SELECT llm.id, ll.loan_id, llm.invoice_upload_status,
       llm.invoice_upload_status_desc,
       llm.lender_application_id, llm.lender_invoice_id,
       llm.created_at, llm.updated_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND llm.invoice_upload_status NOT IN ('INVOICE_UPLOADED', 'DISBURSED')
ORDER BY llm.created_at DESC;
```

**Check Saraloan-related task failures**:

```sql
-- Performance: Index on (task_name, status, date_done). Expected < 500ms.
SELECT task_id, task_name, status, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'loan.tasks.send_invoice_to_saraloan',
    'loan.tasks.create_tranche_in_blacksoil',
    'loan.tasks.create_invoice_in_blacksoil',
    'loan.tasks.update_subvention_details_in_saraloan',
    'credit_line.tasks.fetch_and_update_credit_line_info',
    'payment.tasks.fetch_and_update_repayments_info'
)
  AND status = 'FAILURE'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 20;
```

**Affected Flows**:
- Loan-to-lender pipeline — invoice upload, tranche creation. See [`05-celery-workflows.md` § Workflow 1](05-celery-workflows.md).
- Credit line sync — limit and outstanding updates. See [`05-celery-workflows.md` § Workflow 3](05-celery-workflows.md).
- Repayment sync — payment data from lender. See [`05-celery-workflows.md` § Workflow 2](05-celery-workflows.md).

**Resolution**:
1. Check `invoice_upload_status_desc` on `LenderLoanMap` for the specific API error message.
2. Common Saraloan errors:
   - `APPLICATION_NOT_FOUND` — `CustomerLenderMap.business_id` or `application_id` is missing or invalid. Run `sync_partner_ids_from_saraloan` to resolve.
   - `PARTNER_NOT_FOUND` — partner not registered in Saraloan. Check `CustomerLenderMap`.
   - `ReadTimeout` — Saraloan API took longer than the configured timeout (default 5s). Retry the task.
3. For `fetch_and_update_credit_line_info`: has `autoretry_for=(Exception,)` with `retry_backoff=1800` and `max_retries=2`. Check if retries succeeded.
4. See [Hypothesis 3.3 in `07-hypothesis-validation.md`](07-hypothesis-validation.md) for invoice upload failure investigation.

---

### 4.2 FinBox Data Collection Failure

**Symptoms**:
- Risk evaluation data is missing or outdated for a customer.
- `FinBoxData` records not created or updated.
- The `collect_user_profile_data_from_finbox` task (daily 17:00 UTC) failed for this customer.
- FinBox API (`common/external/finbox/finbox.py`) returned an error or timeout.

**Investigation Queries**:

**ORM**:
```python
from credit_line.model import FinBoxData

FinBoxData.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'status', 'created_at', 'updated_at'
).order_by('-updated_at')[:5]
```

**SQL**:
```sql
-- Performance: Index on customer_id. Expected < 10ms.
SELECT fbd.id, fbd.status, fbd.created_at, fbd.updated_at
FROM credit_line_finboxdata fbd
JOIN credit_line_customer c ON fbd.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
ORDER BY fbd.updated_at DESC
LIMIT 5;
```

**Check FinBox task results**:

```sql
-- Performance: Index on (task_name, date_done). Expected < 100ms.
SELECT task_id, task_name, status, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'credit_line.tasks.collect_user_profile_data_from_finbox',
    'credit_line.tasks.get_finbox_data'
)
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 10;
```

**Affected Flows**:
- Risk evaluation — FinBox data used for credit assessment. See [`02-user-flows/risk-evaluation.md`](02-user-flows/risk-evaluation.md).

**Resolution**:
1. Check `FinBoxData.status` — the `get_finbox_data` task (`credit_line/tasks.py:3505`) checks `is_retrial_needed_for_finbox_error_codes` to determine if a retry is warranted.
2. FinBox API timeout is configured in `settings.FINBOX['TIMEOUT']`.
3. Manually trigger `get_finbox_data` for the affected customer.

---

### 4.3 SAP/ERP Posting Failure

**Symptoms**:
- Disbursement payment not posted to SAP/ERP.
- `Loan.erp_payment_upload_status` shows an error status.
- Credit note or debit note not reflected in SAP.
- Failure emails sent for ERP posting errors.

**Investigation Queries**:

**ORM**:
```python
from loan.model import Loan

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    erp_payment_upload_status__in=[
        'FAILED', 'ERROR', 'PENDING'
    ],
).values(
    'id', 'loan_id', 'erp_payment_upload_status',
    'status', 'disbursement_date', 'updated_at'
)
```

**SQL**:
```sql
-- Performance: Index on customer_credit_line_id. Expected < 20ms.
SELECT ll.id, ll.loan_id, ll.erp_payment_upload_status,
       ll.status, ll.disbursement_date, ll.updated_at
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.erp_payment_upload_status NOT IN ('POSTED', 'NOT_APPLICABLE')
ORDER BY ll.updated_at DESC;
```

**Check ERP posting task results**:

```sql
-- Performance: Index on (task_name, status, date_done). Expected < 500ms.
SELECT task_id, task_name, status, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name IN (
    'loan.tasks.send_disbursement_payment_to_erp',
    'loan.tasks.send_disbursement_posted_payment_to_erp',
    'loan.tasks.send_disbursal_refund_payment_to_sap',
    'payment.tasks.check_and_create_la_entries_in_sap',
    'payment.tasks.create_la_entry_in_sap'
)
  AND status = 'FAILURE'
  AND task_args LIKE '%{user_id}%'
  AND date_done >= NOW() - INTERVAL '7 days'
ORDER BY date_done DESC
LIMIT 10;
```

**Affected Flows**:
- Approval workflow — disbursement posting to ERP. See [`05-celery-workflows.md` § SAP/ERP Posting Workflow](05-celery-workflows.md).
- Payment transfer — LA entry creation in SAP.

**Resolution**:
1. Check the `traceback` for the specific SAP API error.
2. The `send_disbursement_payments_to_erp` beat task (daily 01:00 UTC) retries failed postings. Verify it ran.
3. `send_disbursal_refund_payment_to_sap` self-retries via `apply_async(countdown=5)` on missing data — check if the prerequisite data is now available.
4. For LA entries: `check_and_create_la_entries_in_sap` runs on the `celery` queue. Check if the queue is backed up.

---

### 4.4 Payment Service Transfer Failure

**Symptoms**:
- Aggregated payment transfer to lender failed.
- `AggregatedPaymentTransfer.status` shows `ERROR` or `YET_TO_TRANSFER` with high `transfer_try_count`.
- NEFT transfer API returned an error.
- Failure email sent via `send_payment_transfer_failed_email`.

**Investigation Queries**:

**ORM**:
```python
from payment.model import AggregatedPaymentTransfer

AggregatedPaymentTransfer.objects.filter(
    customer__source_identifier_id='{user_id}',
    status__in=['ERROR', 'YET_TO_TRANSFER'],
).values(
    'id', 'status', 'amount', 'transfer_try_count',
    'created_at', 'updated_at'
)
```

**SQL**:
```sql
-- Performance: Index on customer_id. Expected < 20ms.
SELECT apt.id, apt.status, apt.amount, apt.transfer_try_count,
       apt.created_at, apt.updated_at
FROM payment_aggregatedpaymenttransfer apt
JOIN credit_line_customer c ON apt.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND apt.status IN ('ERROR', 'YET_TO_TRANSFER')
ORDER BY apt.created_at DESC;
```

**Affected Flows**:
- Payment transfer workflow. See [`05-celery-workflows.md` § Workflow 4](05-celery-workflows.md).

**Resolution**:
1. Check `transfer_try_count` against `AGGREGATED_PAYMENT_TRANSFER_MAX_COUNT`. If exceeded, the system will not retry automatically.
2. The `reverse_aggregated_payments` task (weekdays 04:00 UTC) handles reversal of failed transfers.
3. Check if the SAP draft payment was created successfully before the NEFT transfer failed — if so, the draft may need to be deleted via `mark_sap_draft_payment_deleted`.
4. Verify the payment service health and the lender's bank account details.

---

## 5. Data Inconsistency

### 5.1 Loan Amount vs Disbursed Amount Mismatch

**Symptoms**:
- Loan shows `status = DISBURSED` but `disbursed_amount` is `NULL` or differs from `loan_amount`.
- `remaining_amount` does not match expected value after reconciliation.
- Partial disbursal may have created a new loan but the original was not properly rejected.

**Investigation Queries**:

**ORM**:
```python
from loan.model import Loan
from django.db.models import F, Q

Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
).filter(
    Q(disbursed_amount__isnull=True, status='DISBURSED') |
    Q(remaining_amount__isnull=True, status__in=['DISBURSED', 'PARTIALLY_PAID']) |
    Q(disbursed_amount__gt=F('loan_amount'))
).values(
    'id', 'loan_id', 'status', 'loan_amount',
    'disbursed_amount', 'remaining_amount', 'approved_amt',
    'rejected_amt', 'comment'
)
```

**SQL**:
```sql
-- Performance: Index on customer_credit_line_id. Expected < 20ms.
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.disbursed_amount, ll.remaining_amount,
       ll.approved_amt, ll.rejected_amt, ll.comment,
       CASE
           WHEN ll.status = 'DISBURSED' AND ll.disbursed_amount IS NULL
               THEN 'ANOMALY: disbursed but no disbursed_amount'
           WHEN ll.status IN ('DISBURSED', 'PARTIALLY_PAID') AND ll.remaining_amount IS NULL
               THEN 'ANOMALY: active loan with no remaining_amount'
           WHEN ll.disbursed_amount > ll.loan_amount
               THEN 'ANOMALY: disbursed_amount > loan_amount'
           WHEN ll.remaining_amount < 0
               THEN 'ANOMALY: negative remaining_amount'
           ELSE 'OK'
       END AS check_result
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status IN ('DISBURSED', 'PARTIALLY_PAID', 'OVERDUE', 'OVERDUE_AND_PARTIALLY_PAID')
ORDER BY ll.created_at DESC;
```

**Affected Flows**:
- Approval workflow — partial disbursal processing. See [`04-decision-logic.md` § 5](04-decision-logic.md).
- Reconciliation — `fetch_loan_amount_to_consider_for_reconciliation()` (`loan/utility.py:470`) falls back through `remaining_amount` → `disbursed_amount` → `loan_amount`.

**Resolution**:
1. If `disbursed_amount` is `NULL` on a `DISBURSED` loan, the disbursal webhook may have been processed incompletely. Check webhook events (see [§ 4.1](#41-saraloan-api-timeout-or-error)).
2. If `remaining_amount` is negative, reconciliation over-applied payments. Run `run_unreconciliation_for_customer` and re-reconcile.
3. For partial disbursal anomalies, check if the original loan was properly rejected and a new loan created. See [`04-decision-logic.md` § Branch 5.3–5.4](04-decision-logic.md).

---

### 5.2 Payment Reconcilable Amount Drift

**Symptoms**:
- Payment shows `sub_status = UNRECONCILED` but `reconcilable_amount` is 0 or negative.
- Payment `reconcilable_amount` does not equal `payment_amount - hold_amount - refund_amount`.
- Reconciliation skips the payment because `reconcilable_amount` is not > 0.

**Investigation Queries**:

**ORM**:
```python
from payment.model import Payment
from django.db.models import F

Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    status='POSTED',
).annotate(
    expected_reconcilable=F('payment_amount') - F('hold_amount') - F('refund_amount')
).values(
    'id', 'payment_amount', 'hold_amount', 'refund_amount',
    'reconcilable_amount', 'expected_reconcilable',
    'status', 'sub_status'
)
```

**SQL**:
```sql
-- Performance: Index on customer_credit_line_id. Expected < 20ms.
SELECT p.id, p.payment_amount, p.hold_amount,
       COALESCE(p.refund_amount, 0) AS refund_amount,
       p.reconcilable_amount,
       (p.payment_amount - p.hold_amount - COALESCE(p.refund_amount, 0)) AS expected_reconcilable,
       p.status, p.sub_status,
       CASE
           WHEN p.reconcilable_amount != (p.payment_amount - p.hold_amount - COALESCE(p.refund_amount, 0))
               THEN 'ANOMALY: reconcilable_amount drift'
           WHEN p.reconcilable_amount <= 0 AND p.sub_status = 'UNRECONCILED'
               THEN 'ANOMALY: unreconciled but no reconcilable amount'
           ELSE 'OK'
       END AS check_result
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND p.status = 'POSTED'
ORDER BY p.created_at DESC;
```

**Affected Flows**:
- Reconciliation — `check_and_run_reconciliation_for_all_customers` filters payments by `reconcilable_amount__gt=0`. See [`04-decision-logic.md` § Branch 6.2](04-decision-logic.md).
- Repayment workflow — payment creation and updates. See [`06-playbooks/payment-reconciliation-playbook.md`](06-playbooks/payment-reconciliation-playbook.md).

**Resolution**:
1. The `update_reconcilable_amount_in_payments()` function (`loan/utility.py:424`) recalculates `reconcilable_amount` for GAPL credit lines. It runs during reconciliation setup.
2. If drift exists, trigger reconciliation for the partner — it will recalculate before matching.
3. Check if a partial refund was processed that reduced `payment_amount` without updating `reconcilable_amount`.

---

### 5.3 Credit Line Outstanding vs Loan Sum Mismatch

**Symptoms**:
- `CustomerCreditLine.principal_outstanding` does not match the sum of `remaining_amount` on active loans.
- Available credit limit appears incorrect.
- User sees wrong outstanding amount in the dashboard.

**Investigation Queries**:

**SQL**:
```sql
-- Performance: Index on customer_credit_line_id. Expected < 50ms.
SELECT ccl.id AS ccl_id,
       ccl.principal_outstanding AS recorded_outstanding,
       COALESCE(SUM(
           CASE WHEN ll.status IN ('DISBURSED', 'PARTIALLY_PAID', 'OVERDUE', 'OVERDUE_AND_PARTIALLY_PAID')
                THEN COALESCE(ll.remaining_amount, ll.disbursed_amount, ll.loan_amount)
                ELSE 0
           END
       ), 0) AS calculated_outstanding,
       ccl.principal_outstanding - COALESCE(SUM(
           CASE WHEN ll.status IN ('DISBURSED', 'PARTIALLY_PAID', 'OVERDUE', 'OVERDUE_AND_PARTIALLY_PAID')
                THEN COALESCE(ll.remaining_amount, ll.disbursed_amount, ll.loan_amount)
                ELSE 0
           END
       ), 0) AS discrepancy,
       cp.credit_product_name
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
LEFT JOIN loan_loan ll ON ll.customer_credit_line_id = ccl.id
WHERE c.source_identifier_id = '{user_id}'
GROUP BY ccl.id, ccl.principal_outstanding, cp.credit_product_name
HAVING ABS(ccl.principal_outstanding - COALESCE(SUM(
    CASE WHEN ll.status IN ('DISBURSED', 'PARTIALLY_PAID', 'OVERDUE', 'OVERDUE_AND_PARTIALLY_PAID')
         THEN COALESCE(ll.remaining_amount, ll.disbursed_amount, ll.loan_amount)
         ELSE 0
    END
), 0)) > 1;
```

**Affected Flows**:
- Credit eligibility — outstanding affects available credit. See [`02-user-flows/credit-eligibility.md`](02-user-flows/credit-eligibility.md).
- Credit limit calculation — `compute_outstanding_amount()` (`credit_line/utils.py`). See [`02-user-flows/credit-limit-calculation.md`](02-user-flows/credit-limit-calculation.md).
- Risk evaluation — overdue calculations depend on accurate outstanding. See [`02-user-flows/risk-evaluation.md`](02-user-flows/risk-evaluation.md).

**Resolution**:
1. For lender credit lines: `principal_outstanding` is set by the `pre_save` signal for specific products (Adani Capital, Progcap) as `credit_limit - lender_available_credit_limit`. See [`04-decision-logic.md` § Branch 2.3](04-decision-logic.md). If the Saraloan sync failed, this value may be stale.
2. For GAPL credit lines: `principal_outstanding` is computed from loan data. Trigger reconciliation to recalculate.
3. Run `compute_outstanding_amount()` for the affected credit line to verify and correct.

---

### 5.4 Orphaned LenderLoanMap Records

**Symptoms**:
- `LenderLoanMap` records exist for loans that have been cancelled or no longer exist.
- Invoice upload status stuck in an intermediate state with no corresponding active loan.
- Lender-side records out of sync with Locus.

**Investigation Queries**:

**SQL**:
```sql
-- Performance: Index on loan_id. Expected < 30ms.
SELECT llm.id, ll.loan_id, ll.status AS loan_status,
       llm.invoice_upload_status, llm.invoice_status_at_lender,
       llm.lender_invoice_id, llm.created_at, llm.updated_at
FROM loan_lenderloanmap llm
JOIN loan_loan ll ON llm.loan_id = ll.id
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
WHERE c.source_identifier_id = '{user_id}'
  AND (
      ll.status IN ('CANCELLED', 'REJECTED')
      OR (llm.invoice_upload_status NOT IN ('INVOICE_UPLOADED', 'DISBURSED')
          AND llm.created_at < NOW() - INTERVAL '48 hours')
  )
ORDER BY llm.created_at DESC;
```

**Affected Flows**:
- Loan-to-lender pipeline — stale `LenderLoanMap` entries may interfere with re-sharing. See [`05-celery-workflows.md` § Workflow 1](05-celery-workflows.md).
- External lender support — `check_and_update_external_lender_supported` uses `LenderLoanMap` data. See [`04-decision-logic.md` § 7](04-decision-logic.md).

**Resolution**:
1. For cancelled/rejected loans with `LenderLoanMap`: the system should have cancelled the lender-side record via `sync_and_cancel_ytd_undisbursed_loans_saraloan()`. Verify the lender-side status.
2. For stuck upload statuses: check `invoice_upload_status_desc` for the API error. The `check_for_retry_invoice_upload()` function (`loan/utility.py:2552`) determines if a retry is possible.
3. Stale intermediate records older than 48 hours likely indicate a failed upload that was not retried.

---

### 5.5 Ledger Entry Missing for Disbursed Loan

**Symptoms**:
- A loan is in `DISBURSED` status but no corresponding `LedgerEntry` exists.
- The user's ledger view is incomplete.
- Outstanding calculations may be incorrect.

**Investigation Queries**:

**SQL**:
```sql
-- Performance: Index on partner_id for ledger, customer_credit_line_id for loans. Expected < 50ms.
SELECT ll.id, ll.loan_id, ll.status, ll.loan_amount,
       ll.disbursement_date, ll.created_at,
       le.id AS ledger_entry_id, le.type AS ledger_type
FROM loan_loan ll
JOIN credit_line_customercreditline ccl ON ll.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
LEFT JOIN ledger_ledgerentry le ON le.source_no = ll.loan_id
  AND le.partner_id = c.source_identifier_id
WHERE c.source_identifier_id = '{user_id}'
  AND ll.status IN ('DISBURSED', 'PARTIALLY_PAID', 'OVERDUE', 'OVERDUE_AND_PARTIALLY_PAID', 'PAID')
  AND le.id IS NULL
ORDER BY ll.created_at DESC;
```

**ORM**:
```python
from loan.model import Loan
from ledger.model import LedgerEntry

# Get all disbursed+ loans
loans = Loan.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    status__in=['DISBURSED', 'PARTIALLY_PAID', 'OVERDUE', 'OVERDUE_AND_PARTIALLY_PAID', 'PAID'],
).values_list('loan_id', flat=True)

# Check which have ledger entries
ledger_loan_ids = LedgerEntry.objects.filter(
    partner_id='{user_id}',
    source_no__in=list(loans),
).values_list('source_no', flat=True)

# Missing entries
missing = set(loans) - set(ledger_loan_ids)
```

**Affected Flows**:
- Repayment workflow — ledger entries drive the user's financial view. See [`02-user-flows/repayment-workflow.md`](02-user-flows/repayment-workflow.md).
- Reconciliation — ledger visibility affects payment matching.

**Resolution**:
1. Ledger entries are created by Django signals on `Loan` post-save (`loan/signals.py:send_disbursement_payment_to_erp`). If the signal failed, the ledger entry was not created.
2. Check if the `_update_debit_record_payment_visibility` task (every 5 minutes) has processed the loan. See [`05-celery-workflows.md` § Ledger Visibility Updates](05-celery-workflows.md).
3. The `populate_is_parent_entry` task has `autoretry_for=(LedgerEntry.DoesNotExist,)` with `max_retries=2` — it may be waiting for the entry to be created.
4. Manually create the ledger entry or trigger the disbursement signal handler.

---

## Quick Reference — Failure Scenario Index

| # | Scenario | Category | Key Table | Primary Query Target |
|---|----------|----------|-----------|---------------------|
| 1.1 | Task hard-killed by time limit | Celery | `django_celery_results_taskresult` | `traceback LIKE '%TimeLimitExceeded%'` |
| 1.2 | Task exhausted max retries | Celery | `django_celery_results_taskresult` | `status IN ('FAILURE', 'RETRY')` |
| 1.3 | Task stuck in STARTED | Celery | `django_celery_results_taskresult` | `status = 'STARTED'` |
| 1.4 | Beat task did not fire | Celery | `django_celery_results_taskresult` | Missing task results for time window |
| 2.1 | Credit line data stale | Stale Data | `credit_line_customercreditline` | `updated_at < NOW() - INTERVAL '48 hours'` |
| 2.2 | Repayment data not synced | Stale Data | `payment_payment` | Missing recent payments |
| 2.3 | Loan parameters stale | Stale Data | `loan_loan` | `updated_at < NOW() - INTERVAL '48 hours'` |
| 3.1 | Concurrent reconciliation | Race Condition | `django_celery_results_taskresult` | Overlapping task execution windows |
| 3.2 | Concurrent loan creation | Race Condition | `loan_invoiceloanmap` | Duplicate invoice-to-loan mappings |
| 3.3 | Concurrent payment transfer | Race Condition | `payment_aggregatedpaymenttransfer` | High `transfer_try_count` |
| 3.4 | Duplicate disbursal webhook | Race Condition | `external_externalwebhook` | Duplicate webhook events |
| 4.1 | Saraloan API failure | External API | `loan_lenderloanmap`, `external_externalwebhook` | `invoice_upload_status` errors |
| 4.2 | FinBox collection failure | External API | `credit_line_finboxdata` | Missing/stale FinBox records |
| 4.3 | SAP/ERP posting failure | External API | `loan_loan` | `erp_payment_upload_status` errors |
| 4.4 | Payment transfer failure | External API | `payment_aggregatedpaymenttransfer` | `status IN ('ERROR', 'YET_TO_TRANSFER')` |
| 5.1 | Loan amount mismatch | Data Inconsistency | `loan_loan` | `disbursed_amount` vs `loan_amount` |
| 5.2 | Payment reconcilable drift | Data Inconsistency | `payment_payment` | `reconcilable_amount` vs calculated |
| 5.3 | Outstanding vs loan sum | Data Inconsistency | `credit_line_customercreditline`, `loan_loan` | Cross-table sum comparison |
| 5.4 | Orphaned LenderLoanMap | Data Inconsistency | `loan_lenderloanmap` | Cancelled loans with active maps |
| 5.5 | Missing ledger entry | Data Inconsistency | `loan_loan`, `ledger_ledgerentry` | LEFT JOIN with NULL check |
