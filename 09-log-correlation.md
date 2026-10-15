# 09 — Log Correlation

How to trace execution across Django API requests and Celery tasks using the Locus logging infrastructure.

> Cross-reference: [05-celery-workflows.md](05-celery-workflows.md) for task chains, [08-failure-scenarios.md](08-failure-scenarios.md) for failure patterns, [01-entry-points.md](01-entry-points.md) for entry point identification.

---

## Table of Contents

1. [Logging Architecture Overview](#1-logging-architecture-overview)
2. [Request Log Middleware](#2-request-log-middleware)
3. [LocusLogger — Custom Log Record Factory](#3-locuslogger--custom-log-record-factory)
4. [Celery Task Logging](#4-celery-task-logging)
5. [External API Logging (Audit Log)](#5-external-api-logging-audit-log)
6. [Saraloan API Logging](#6-saraloan-api-logging)
7. [Logger Names and Sources](#7-logger-names-and-sources)
8. [Correlating Django Requests with Celery Tasks](#8-correlating-django-requests-with-celery-tasks)
9. [Log Search Patterns by User Flow](#9-log-search-patterns-by-user-flow)
10. [Production Search Commands](#10-production-search-commands)

---

## 1. Logging Architecture Overview

The Locus system uses a layered logging approach with a shared tracking ID (`Locus-Request-Identifier`) that flows from HTTP requests into Celery tasks.

```
HTTP Request
  │
  ├─ RequestLogMiddleware          → Locus-Request-Log / Locus-Response-Log
  │    assigns: Locus-Request-Identifier (UUID)
  │    stores on: request.META, current_thread().locus_tracking_id
  │
  ├─ LocusLogger (LogRecord factory) → Prepends "Locus-Tracking-ID:<uuid>:" to every log message
  │    reads: current_thread().locus_tracking_id
  │    format: JSON via pythonjsonlogger
  │
  ├─ audit_request_response decorator → BlackSoil-Request-Log / BlackSoil-Response-Log
  │    writes: audit_log_auditlog table
  │    includes: Locus-Request-Identifier in extra field
  │
  └─ Celery Task (via task_id_logger_decorator)
       sets: current_thread().locus_tracking_id = task.request.id
       sets: current_thread().parent_task_id = task.request.parent_id
       → All subsequent LocusLogger messages carry the Celery task_id as tracking ID
```

**Key constant**: `LOCUS_REQUEST_IDENTIFIER = "Locus-Request-Identifier"` (defined in `common/constants.py`).

---

## 2. Request Log Middleware

**Source**: `config/middleware/request_log.py:RequestLogMiddleware`
**Registered in**: `config/settings/base.py` → `MIDDLEWARE` list

### How It Works

1. Generates a UUID tracking ID per request
2. Stores it in `request.META["Locus-Request-Identifier"]` and `current_thread().locus_tracking_id`
3. Logs a combined request + response message after the view returns
4. Adds the tracking ID to the response headers

### Log Message Format

```
Locus-Request-Log: {log_data}
Locus-Response-Log: {resp_data}
API Response Time: {method}, {path}, {time} ms, status_code, {status}
```

### Request Log Fields (`log_data`)

| Field | Description | Contains `user_id`? |
|-------|-------------|---------------------|
| `remote_address` | Client IP (`request.META["REMOTE_ADDR"]`) | No |
| `server_hostname` | Server hostname (`socket.gethostname()`) | No |
| `request_method` | HTTP method (GET, POST, etc.) | No |
| `request_path` | Full URL path with query string | **Yes** — when `source_identifier_id` is in URL path or query params |
| `Locus-Request-Identifier` | UUID tracking ID for this request | No |
| `request_headers` | All request headers | No |
| `request_body` | Parsed JSON body (if `Content-Type: application/json`) | **Yes** — when `source_identifier_id` or `customer_id` is in POST body |

### Response Log Fields (`resp_data`)

| Field | Description | Contains `user_id`? |
|-------|-------------|---------------------|
| `response_headers` | Response headers | No |
| `response_body` | Parsed JSON response body | **Possibly** — depends on endpoint |
| `Locus-Request-Identifier` | Same UUID as request | No |
| `status_code` | HTTP status code | No |
| `total_response_time` | Response time in ms | No |

### Exception Logging

When an unhandled exception occurs, the middleware logs:

```
Unhandled Exception: {exception_str}
```

**Logger name**: `config.middleware.request_log` (via `logging.getLogger(__name__)`)

### Search Pattern

```bash
# Find all requests for a specific user
grep "Locus-Request-Log" app.log | grep "source_identifier_id.*{user_id}"

# Find a specific request by tracking ID
grep "{tracking_uuid}" app.log

# Find slow requests (>1000ms)
grep "API Response Time:" app.log | grep -E "[0-9]{4,}\.\d+ ms"
```

---

## 3. LocusLogger — Custom Log Record Factory

**Source**: `config/settings/locus_logger.py:LocusLogger`
**Activated by**: `logging.setLogRecordFactory(LocusLogger)` in `config/settings/base.py`

### How It Works

Every `logging.*()` call in the application goes through `LocusLogger`, which:

1. Reads `current_thread().locus_tracking_id` (set by `RequestLogMiddleware` or `task_id_logger_decorator`)
2. Prepends `Locus-Tracking-ID:<uuid>:` to every log message
3. Formats output as JSON using `pythonjsonlogger.JsonFormatter`
4. Includes `locus.trace_id` and `locus.parent_trace_id` as log record attributes

### JSON Log Format

```
%(timestamp)s [%(module)s.%(funcName)s:%(lineno)d] %(level)s %(name)s %(message)s
```

Example output:

```json
{
  "timestamp": "2024-01-15T10:30:45.123456Z",
  "module": "tasks",
  "funcName": "process_repayment_data",
  "lineno": 862,
  "level": "INFO",
  "name": "payment.tasks",
  "message": "Locus-Tracking-ID:abc123-def456: Webhook Repayment Data Received {...}",
  "locus.trace_id": "abc123-def456",
  "locus.parent_trace_id": "parent-task-id-or-null"
}
```

### Additional Fields from LocusLogger Methods

When using `LocusLogger` instance methods (`.info()`, `.error()`, etc.) with dict messages, the output includes:

| Field | Description |
|-------|-------------|
| `log_type` | Set to `"locus"` by default, or derived from caller module |
| `caller` | Full caller path: `module.ClassName.method_name` |

### user_id in LocusLogger Messages

The `user_id` is **not automatically included** in LocusLogger fields. It appears only when the application code explicitly includes `source_identifier_id` or `partner_id` in the log message string.

### Search Pattern

```bash
# Find all log entries for a specific tracking ID
grep "Locus-Tracking-ID:{tracking_id}" app.log

# Find all log entries with a parent task relationship
grep "locus.parent_trace_id" app.log | grep -v "null"
```

---

## 4. Celery Task Logging

### task_id_logger_decorator

**Source**: `common/decorators.py:task_id_logger_decorator`

This decorator is applied to virtually all Celery tasks in the system. It bridges the request tracking ID system into Celery:

```python
def task_id_logger_decorator(func):
    @wraps(func)
    def wrapper(*args, **kwargs):
        task = current_task
        if task:
            task_id = task.request.id
            parent_task_id = task.request.parent_id
            current_thread().locus_tracking_id = task_id       # ← replaces HTTP request UUID
            current_thread().parent_task_id = parent_task_id   # ← links to parent task
        return func(*args, **kwargs)
    return wrapper
```

**Effect**: After this decorator runs, all `LocusLogger` messages within the task will carry `Locus-Tracking-ID:<celery_task_id>` instead of the HTTP request UUID.

### Logger Names by App

| App | Logger Initialization | Logger Name |
|-----|----------------------|-------------|
| `loan/tasks.py` | `logger = logging.getLogger(__name__)` | `loan.tasks` |
| `credit_line/tasks.py` | `logger = logging.getLogger(__name__)` | `credit_line.tasks` |
| `payment/tasks.py` | `logger = get_task_logger(__name__)` | `payment.tasks` |
| `repayment/tasks.py` | `LOGGER = logging.getLogger("stdout-logger")` | `stdout-logger` |
| `auto_pay/tasks.py` | `LOGGER = logging.getLogger("stdout-logger")` | `stdout-logger` |
| `farmer_financing/tasks.py` | `LOGGER = logging.getLogger("stdout-logger")` | `stdout-logger` |

### Celery Task Log Patterns

#### loan/tasks.py — Structured Key-Value Logging

```
Locus-Tracking-ID:<task_id>: Attempting to create LenderLoanMap | loan_id=<id>
Locus-Tracking-ID:<task_id>: Attempting to send invoice to lender | llm_id=<id>
Locus-Tracking-ID:<task_id>: Attempting to create tranche | llm_id=<id>
Locus-Tracking-ID:<task_id>: Attempting to mark LLM as PARTNER_NOT_FOUND | llm_id=<id>
Locus-Tracking-ID:<task_id>: Invoice upload status has been changed for lender loan map id: <id>
Locus-Tracking-ID:<task_id>: prep_disbursal_payment_to_send_to_sap: entry | loan_id=<id> status=<status> erp_payment_upload_status=<status>
```

**user_id location**: Not directly in log messages. Correlate via `loan_id` → `Loan` → `CustomerCreditLine` → `Customer.source_identifier_id`.

#### payment/tasks.py — Mixed Format Logging

```
Locus-Tracking-ID:<task_id>: Syncing for partner_id- {source_identifier_id}
Locus-Tracking-ID:<task_id>: Sync Done for- {source_identifier_ids}
Locus-Tracking-ID:<task_id>: Webhook Repayment Data Received {repayment_data}
Locus-Tracking-ID:<task_id>: CreditLine Exists for the partner_id {source_identifier_id}
Locus-Tracking-ID:<task_id>: syncing repayments for Customer {source_identifier_id}
Locus-Tracking-ID:<task_id>: Recon::start: payment_id=<id> mode=<mode> amount=<amt> transfer_no=<no>
Locus-Tracking-ID:<task_id>: Recon::apt: payment_id=<id> apt_id=<id> via=<method>
Locus-Tracking-ID:<task_id>: Recon::result: ttl=<total> entries=<count>
```

**user_id location**: Directly in messages as `partner_id` or `source_identifier_id` in sync/webhook tasks. For reconciliation tasks, correlate via `payment_id`.

#### credit_line/tasks.py — Standard Python Logging

```
Locus-Tracking-ID:<task_id>: <message from credit_line operations>
```

**user_id location**: Varies by function. `update_credit_lines_status()` operates on `partner_id`. `process_saraloan_loan_webhook()` includes loan identifiers.

#### repayment/tasks.py — stdout-logger

```
Locus-Tracking-ID:<task_id>: send_sms for {template_name}, receiver:{receiver} & params:{parameters}
Locus-Tracking-ID:<task_id>: fetch_and_trigger_demand_communication_event STARTED for {trigger_for}
Locus-Tracking-ID:<task_id>: Unable to send due date coming notification to group leader with id: {group_leader}
```

**user_id location**: `farmer_id` in demand sheet operations, `receiver` in SMS tasks.

### Celery Task State Queries

To find task execution logs, first retrieve the task ID from the results backend:

**ORM**:
```python
from django_celery_results.models import TaskResult

# Find task results for a specific task name
TaskResult.objects.filter(
    task_name='payment.tasks.process_repayment_data',
    status='FAILURE'
).order_by('-date_done')[:10]
```

**SQL**:
```sql
SELECT task_id, task_name, status, result, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_name = 'payment.tasks.process_repayment_data'
  AND status = 'FAILURE'
ORDER BY date_done DESC
LIMIT 10;
```

Then search logs using the `task_id`:

```bash
grep "Locus-Tracking-ID:<task_id_from_query>" app.log
```

---

## 5. External API Logging (Audit Log)

**Source**: `audit_log/decorators.py:audit_request_response`
**Database table**: `audit_log_auditlog`

### How It Works

The `@audit_request_response` decorator wraps external API calls (applied to `Saraloan._call_api`). It:

1. Creates an `AuditLog` record before the API call with request details
2. Updates the record after the call with response details
3. Logs structured messages with `BlackSoil-Request-Log` / `BlackSoil-Response-Log` prefixes
4. Includes `Locus-Request-Identifier` from the originating HTTP request (if available)

### Log Message Format

```
BlackSoil-Request-Log: {log_data_before},
BlackSoil-Response-Log: {log_data_after},
Audit Log ID: {audit_instance.id}
```

### Request Log Fields (`log_data_before`)

| Field | Description | Contains `user_id`? |
|-------|-------------|---------------------|
| `Locus-Request-Identifier` | Tracking ID from originating request | No |
| `request_tracking_id` | UUID unique to this external API call | No |
| `method` | HTTP method | No |
| `url` | External API URL | **Possibly** — Saraloan URLs contain `business_id` (maps to partner) |
| `params` | Request parameters | **Possibly** — may contain `partner_id` or business identifiers |
| `headers` | Request headers (auth masked) | No |
| `timeout` | Request timeout | No |

### Response Log Fields (`log_data_after`)

| Field | Description |
|-------|-------------|
| `Locus-Request-Identifier` | Same tracking ID |
| `request_tracking_id` | Same per-call UUID |
| `status code` | External API response status |
| `audit_log_id` | ID of the `AuditLog` record |
| `headers` | Response headers |
| `response_time` | Response time in ms |

### Exception Log Format

```
Blacksoil-Exception-Log: {exception_str},
Audit Log ID: {audit_instance.id}
```

### Querying the Audit Log

**ORM**:
```python
from audit_log.models import AuditLog

# Find all external API calls related to a user
AuditLog.objects.filter(
    request_path__contains='{user_id}'
).order_by('-created_at')[:20]

# Find failed external API calls
AuditLog.objects.filter(
    response_status_code__gte=400,
    created_at__date='{date}'
).order_by('-created_at')
```

**SQL**:
```sql
SELECT id, method, request_path, response_status_code, response_time,
       extra, created_at
FROM audit_log_auditlog
WHERE request_path LIKE '%{user_id}%'
ORDER BY created_at DESC
LIMIT 20;
```

### Search Pattern

```bash
# Find external API logs by audit log ID
grep "Audit Log ID: {audit_id}" app.log

# Find all BlackSoil request/response logs for a tracking ID
grep "BlackSoil-.*-Log" app.log | grep "{tracking_id}"

# Find external API exceptions
grep "Blacksoil-Exception-Log" app.log
```

---

## 6. Saraloan API Logging

**Source**: `common/external/saraloan/saraloan.py`
**Logger name**: `common.external.saraloan.saraloan` (via `logging.getLogger(__name__)`)

### Log Patterns

| Level | Pattern | When |
|-------|---------|------|
| `EXCEPTION` | `ReadTimeout - {err}. for accessing Saraloan API - {url}. Parameters were - {params}. header - {headers}` | API call times out |
| `EXCEPTION` | `Error accessing Saraloan API - {url}. Parameters were - {params}. Response is - {response}. Status Code - {status}. header - {headers}` | HTTP error, request exception, or JSON decode error |
| `ERROR` | `Unknown error accessing Saraloan API - {url}. Parameters were - {params}. Response is - {response}. Status Code - {status}. header - {headers} error - {error}` | Unexpected exception |

**user_id location**: The `url` field contains Saraloan `business_id` which maps to the partner. The `params` field may contain `partner_id` or invoice identifiers.

### Search Pattern

```bash
# Find Saraloan API errors for a specific partner
grep "Saraloan API" app.log | grep "{business_id_or_partner_id}"

# Find all Saraloan timeouts
grep "ReadTimeout.*Saraloan API" app.log
```

---

## 7. Logger Names and Sources

Summary of all logger names used across the system:

| Logger Name | Source Files | Log Level |
|-------------|-------------|-----------|
| `config.middleware.request_log` | `config/middleware/request_log.py` | INFO (requests), EXCEPTION (errors) |
| `loan.tasks` | `loan/tasks.py` | INFO, ERROR |
| `credit_line.tasks` | `credit_line/tasks.py` | INFO, ERROR, WARNING |
| `payment.tasks` | `payment/tasks.py` (via `get_task_logger`) | INFO, ERROR, WARNING |
| `stdout-logger` | `repayment/tasks.py`, `auto_pay/tasks.py`, `farmer_financing/tasks.py`, `repayment/views.py`, `repayment/models.py`, `credit_line/serializers.py`, `farmer_financing/views.py`, and others | INFO, ERROR, EXCEPTION |
| `common.external.saraloan.saraloan` | `common/external/saraloan/saraloan.py` | ERROR, EXCEPTION |
| `audit_log.decorators` | `audit_log/decorators.py` | INFO, ERROR |
| `dehaat` | LocusLogger internal logger (all structured logs) | Configured via `LOGGING_LEVEL` env var |

---

## 8. Correlating Django Requests with Celery Tasks

### The Tracking ID Chain

```
HTTP Request
  │
  │  RequestLogMiddleware assigns UUID → stored in current_thread().locus_tracking_id
  │  All logs during request processing carry: Locus-Tracking-ID:<request_uuid>
  │
  ├─ View calls task.apply_async(...)
  │    Celery assigns a new task_id
  │
  └─ Celery Worker picks up task
       task_id_logger_decorator sets: current_thread().locus_tracking_id = task.request.id
       All logs during task carry: Locus-Tracking-ID:<celery_task_id>
       Parent chain: task.request.parent_id links to parent task (if chained)
```

### Correlation Strategy

The tracking ID **changes** when execution moves from Django to Celery. To correlate:

**Step 1**: Find the Django request log by user or endpoint.

```bash
grep "Locus-Request-Log" app.log | grep "{user_id}"
```

Extract the `Locus-Request-Identifier` UUID from the log entry.

**Step 2**: Find all log entries during that request (before the task was dispatched).

```bash
grep "Locus-Tracking-ID:{request_uuid}" app.log
```

**Step 3**: Identify which Celery task was triggered. Look for `.apply_async()` or `.delay()` calls in the code path. Then query the Celery results backend for tasks created around the same timestamp:

**ORM**:
```python
from django_celery_results.models import TaskResult
from datetime import timedelta

TaskResult.objects.filter(
    task_name='loan.tasks.send_invoice_to_saraloan',
    date_done__range=(request_time - timedelta(minutes=5), request_time + timedelta(minutes=30))
).filter(
    task_args__contains='{relevant_id}'
)
```

**SQL**:
```sql
SELECT task_id, task_name, status, date_done, task_args
FROM django_celery_results_taskresult
WHERE task_name = 'loan.tasks.send_invoice_to_saraloan'
  AND date_done BETWEEN '{request_time}' - INTERVAL '5 minutes'
                     AND '{request_time}' + INTERVAL '30 minutes'
  AND task_args LIKE '%{relevant_id}%';
```

**Step 4**: Search logs using the Celery `task_id`.

```bash
grep "Locus-Tracking-ID:{celery_task_id}" app.log
```

**Step 5**: For chained tasks, find child tasks using `parent_id`:

```bash
grep "locus.parent_trace_id.*{celery_task_id}" app.log
```

### Correlation via Audit Log

When a Celery task makes an external API call, the `audit_request_response` decorator captures the `Locus-Request-Identifier` from the originating HTTP request (if the thread still has it). Query:

```sql
SELECT id, method, request_path, extra, created_at
FROM audit_log_auditlog
WHERE extra LIKE '%{request_uuid}%'
ORDER BY created_at;
```

---

## 9. Log Search Patterns by User Flow

### Credit Eligibility Check

**Entry**: `GET /credit-line/business/{source_identifier_id}/`

```bash
# 1. Find the request
grep "Locus-Request-Log" app.log | grep "credit-line/business/{user_id}"

# 2. Extract tracking ID and find all related logs
grep "Locus-Tracking-ID:{tracking_id}" app.log
```

**user_id in logs**: Present in `request_path` field of the request log.

### Loan Approval Workflow

**Entry**: `POST /loan/` → Celery chain: `create_loan_in_bulk` → `prepare_loan_to_send_to_saraloan` → `send_invoice_to_saraloan` → `create_tranche_in_blacksoil`

```bash
# 1. Find the initial loan creation request
grep "Locus-Request-Log" app.log | grep "POST.*loan/"

# 2. Find loan task logs by loan_id
grep "loan_id={loan_id}" app.log

# 3. Find lender loan map operations
grep "llm_id={lender_loan_map_id}" app.log

# 4. Find external API calls to Saraloan/BlackSoil
grep "BlackSoil-Request-Log" app.log | grep "{business_id}"

# 5. Find webhook processing
grep "process_saraloan_loan_webhook" app.log
```

### Repayment Processing

**Entry**: `POST /repayment/transaction/` → Celery: `start_repayment_txns` → `process_repayment_data`

```bash
# 1. Find the repayment request
grep "Locus-Request-Log" app.log | grep "repayment/transaction"

# 2. Find repayment webhook data processing
grep "Webhook Repayment Data Received" app.log | grep "{user_id}"

# 3. Find credit line confirmation
grep "CreditLine Exists for the partner_id {user_id}" app.log

# 4. Find repayment sync operations
grep "syncing repayments for Customer {user_id}" app.log
```

### Payment Reconciliation

**Entry**: Celery beat: `check_and_run_reconciliation_for_all_customers`

```bash
# 1. Find reconciliation task logs
grep "Recon::" app.log | grep "payment_id={payment_id}"

# 2. Trace the full reconciliation sequence
grep "Recon::start" app.log | grep "payment_id={payment_id}"
grep "Recon::apt" app.log | grep "payment_id={payment_id}"
grep "Recon::result" app.log | grep "payment_id={payment_id}"

# 3. Find payment transfer logs
grep "Syncing for partner_id- {user_id}" app.log
```

### Risk Evaluation / Credit Line Status Update

**Entry**: Celery beat: `update_credit_lines_status` (daily at 02:00)

```bash
# 1. Find credit line status update task
grep "update_credit_lines_status" app.log

# 2. Find FinBox data collection
grep "collect_user_profile_data_from_finbox" app.log

# 3. Find overdue notifications
grep "notify_overdue_partners" app.log | grep "{user_id}"
```

### Saraloan Sync Operations

**Entry**: Celery beat: `sync_credit_lines_info_from_saraloan` (daily at 22:00)

```bash
# 1. Find sync task logs
grep "syncing Customer Data for Customer {user_id}" app.log
grep "syncing Loans for Customer {user_id}" app.log

# 2. Find Saraloan API errors during sync
grep "Saraloan API" app.log | grep "{user_id_or_business_id}"

# 3. Find audit log entries for the sync
grep "BlackSoil-Request-Log" app.log | grep "{business_id}"
```

---

## 10. Production Search Commands

### Find All Activity for a User

```bash
# Comprehensive search across all log sources
grep "{user_id}" app.log | head -100

# Filter to a specific date range (if logs have timestamps)
grep "{user_id}" app.log | grep "2024-01-15"
```

### Find Failed Operations

```bash
# Find all ERROR/EXCEPTION level logs
grep '"level": "ERROR"' app.log | grep "{user_id}"
grep '"level": "EXCEPTION"' app.log

# Find Celery task failures
grep "Task Failed" app.log

# Find unhandled exceptions in request processing
grep "Unhandled Exception" app.log
```

### Trace a Complete Request-to-Task Chain

```bash
# Step 1: Find the request
REQUEST_ID=$(grep "Locus-Request-Log" app.log | grep "{user_id}" | grep "{endpoint}" | head -1 | grep -oP 'Locus-Request-Identifier.: .\K[a-f0-9-]+')

# Step 2: Find all logs during the request
grep "$REQUEST_ID" app.log

# Step 3: Find related Celery tasks (by timestamp + task_args)
# Use the SQL queries from Section 8 to find task IDs

# Step 4: Find task logs
grep "Locus-Tracking-ID:{task_id}" app.log
```

### Query Audit Log for External API Failures

```sql
-- Find failed external API calls for a user in the last 24 hours
SELECT id, method, request_path, response_status_code,
       response_time, extra, created_at
FROM audit_log_auditlog
WHERE (request_path LIKE '%{user_id}%' OR request_body LIKE '%{user_id}%')
  AND response_status_code >= 400
  AND created_at >= NOW() - INTERVAL '24 hours'
ORDER BY created_at DESC;
```

**Performance**: Uses index on `audit_log_auditlog.updated_at`. For `request_path` LIKE queries, expect full scan — add date filter to limit scope. Expected < 500ms with date filter.

---

## Cross-References

- [01-entry-points.md](01-entry-points.md) — Entry point identification and `user_id` parameter locations
- [05-celery-workflows.md](05-celery-workflows.md) — Task chain relationships for tracing parent/child tasks
- [08-failure-scenarios.md](08-failure-scenarios.md) — Failure patterns that produce specific log signatures
- [10-investigation-queries.md](10-investigation-queries.md) — All investigation queries including Celery task result queries
