# Forensic Debugging Documentation

Systematic investigation documentation for the Locus credit system (Django + Celery). This guide enables engineers to answer: **"For a specific user, why did the system behave a certain way?"**

---

## Table of Contents

| # | Document | Description |
|---|----------|-------------|
| 01 | [Entry Points](01-entry-points.md) | All API endpoints, DRF viewsets, management commands, cron jobs, Celery tasks, and Django signals that trigger credit operations |
| 02 | [User Flows](02-user-flows/) | End-to-end execution sequences for each major user action |
|    | ├ [Credit Eligibility](02-user-flows/credit-eligibility.md) | Credit eligibility check flow |
|    | ├ [Credit Limit Calculation](02-user-flows/credit-limit-calculation.md) | Credit limit and operational limit calculation flow |
|    | ├ [Approval Workflow](02-user-flows/approval-workflow.md) | Loan creation through lender approval flow |
|    | ├ [Repayment Workflow](02-user-flows/repayment-workflow.md) | Repayment processing through ledger updates flow |
|    | └ [Risk Evaluation](02-user-flows/risk-evaluation.md) | Overdue checks and FinBox risk assessment flow |
| 03 | [Runtime Data](03-runtime-data.md) | ORM and SQL queries that retrieve the exact data used in decision-making |
| 04 | [Decision Logic](04-decision-logic.md) | Conditional branches, business rules, and FSM transitions with file paths |
| 05 | [Celery Workflows](05-celery-workflows.md) | Task chains, retry config, failure handling, and queue assignments |
| 06 | [Playbooks](06-playbooks/) | Step-by-step investigation procedures with branching logic |
|    | ├ [Credit Eligibility Playbook](06-playbooks/credit-eligibility-playbook.md) | Investigate credit eligibility issues |
|    | ├ [Loan Lifecycle Playbook](06-playbooks/loan-lifecycle-playbook.md) | Investigate loan creation, approval, and disbursement issues |
|    | ├ [Repayment Playbook](06-playbooks/repayment-playbook.md) | Investigate repayment processing issues |
|    | └ [Payment Reconciliation Playbook](06-playbooks/payment-reconciliation-playbook.md) | Investigate payment reconciliation issues |
| 07 | [Hypothesis Validation](07-hypothesis-validation.md) | Common failure hypotheses with verification queries and expected results |
| 08 | [Failure Scenarios](08-failure-scenarios.md) | Known failure patterns: Celery failures, stale reads, race conditions, API failures, data inconsistencies |
| 09 | [Log Correlation](09-log-correlation.md) | Logging patterns, request tracking, and cross-service log correlation |
| 10 | [Investigation Queries](10-investigation-queries.md) | Central reference of all read-only investigation queries with performance annotations |
| 11 | [Locus–Ledger Reconciliation](11-locus-ledger-reconciliation.md) | Mapping ledger vs credit-line aggregates, `debug_partner_reconcile`, parity checklist |

---

## User Identifier Conventions

The Locus credit system uses two primary user identifiers across its data model:

| Identifier | Model | Column | Description |
|------------|-------|--------|-------------|
| `source_identifier_id` | `Customer` | `credit_line_customer.source_identifier_id` | Primary user identifier. Unique per customer. Used in API URL paths and query parameters. |
| `partner_id` | `LedgerEntry` | `ledger_ledgerentry.partner_id` | Used in ledger and financial contexts. Equivalent to `source_identifier_id` for the same user. |

Throughout this documentation, `{user_id}` is used as a placeholder in all investigation queries. Substitute it with either `source_identifier_id` or `partner_id` depending on the table being queried:

- Use `source_identifier_id` when querying `credit_line_customer` and tables joined through `Customer`.
- Use `partner_id` when querying `ledger_ledgerentry` directly.

### Identifier Lookup

To find a user's records across both identifiers:

**ORM:**
```python
from credit_line.models import Customer

customer = Customer.objects.get(source_identifier_id='{user_id}')
# customer.source_identifier_id == partner_id in ledger context
```

**SQL:**
```sql
SELECT id, source_identifier_id, is_credit_allowed, customer_type_id
FROM credit_line_customer
WHERE source_identifier_id = '{user_id}';
```

---

## Query Usage Instructions

### Format

Every investigation query in this documentation is provided in two formats:

1. **Django ORM** — for use in `python manage.py shell` or application code
2. **Raw SQL** — for use in database clients or read-replica connections

### Placeholders

All queries use `{user_id}` as the parameter placeholder. Replace it with the actual `source_identifier_id` or `partner_id` value before executing.

### Safety Guarantees

All investigation queries in this documentation follow these conventions:

- **Read-only**: Only `SELECT` statements are used. No `UPDATE`, `DELETE`, or `INSERT` operations.
- **Parameterized**: All user-specific filtering uses `{user_id}` placeholders to prevent injection.
- **Index-aware**: Queries filter on indexed columns (`source_identifier_id`, `partner_id`, `customer_id`, `customer_credit_line_id`) to ensure fast execution.
- **Time-bounded**: Date range filters are included where applicable to limit scan scope on large tables.

### Performance Annotations

Each query includes a performance note indicating:

- **Expected execution time** (e.g., `< 50ms`)
- **Index used** (e.g., `Uses index on credit_line_customer.source_identifier_id`)
- **⚠ Warning** if the query may be expensive on large datasets

### Example Usage

**In Django shell:**
```python
python manage.py shell

from credit_line.models import Customer, CustomerCreditLine

# Replace {user_id} with actual source_identifier_id
user_id = 'PARTNER-12345'

customer = Customer.objects.get(source_identifier_id=user_id)
credit_lines = CustomerCreditLine.objects.filter(
    customer=customer
).select_related('credit_product', 'lender')
```

**In database client:**
```sql
-- Replace {user_id} with actual source_identifier_id
SELECT ccl.*, c.source_identifier_id, cp.name as product_name
FROM credit_line_customercreditline ccl
JOIN credit_line_customer c ON ccl.customer_id = c.id
JOIN credit_line_creditproduct cp ON ccl.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```
