# Flow: Approval Workflow

> Traces the complete loan approval workflow from loan creation through lender submission, lender approval via webhook, and disbursal processing.
> This flow answers: "For a given `source_identifier_id`, how was a loan created, shared with the lender, and what happened after lender approval/disbursal?"

**Primary Entry Points**:
- API: `POST /loan/` via `loan/views.py:LoanViewSet.post()`
- Bulk upload: `loan/tasks.py:create_loan_in_bulk()`
- Cron: `loan/tasks.py:share_oldest_loan_to_lender_for_all_partners()` (daily 03:00)
- Webhook: `external/views.py:SaraloanWebhookView.post()` (lender callback)

---

## Entry Points

| Entry Point | Method | user_id Location | File Path |
|-------------|--------|-----------------|-----------|
| `loan/` | POST | Request body: `source_identifier_id` | `loan/views.py:LoanViewSet.post()` |
| Bulk upload (file) | Celery | Upload data: `Partner ID` column | `loan/tasks.py:create_loan_in_bulk()` |
| Cron: share to lender | Celery Beat (03:00) | Derived from `CustomerCreditLine` | `loan/tasks.py:share_oldest_loan_to_lender_for_all_partners()` |
| Webhook: disbursal event | POST | `data.identifiers.partner_lead_id` | `external/views.py:SaraloanWebhookView.post()` |
| Webhook: repayment status | POST | Request body | `external/views.py:SaraloanWebhookView.post()` |

---

## Execution Sequence

### Path A: Loan Creation via API (`LoanViewSet.post()`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `LoanViewSet.post()` | `loan/views.py:77` | Entry point. Calls `create_loan(data=request.data)`. |
| 2 | `create_loan(data)` | `loan/utility.py:2205` | Validates via `CreateLoanRequestSerializer`. Extracts `source_identifier_id`, `loan_amount`, and `invoices` from request. |
| 3 | `check_if_loan_exist_for_invoices(invoice_ids)` | `loan/utility.py` | Checks if loans already exist for the given invoice IDs. Returns `False` if duplicates found. |
| 4 | `check_if_loan_creation_from_invoice_already_running(invoice_ids)` | `loan/utility.py` | Redis-based concurrency guard — prevents duplicate loan creation for same invoices. |
| 5 | `generate_loan_breakup_for_customer(source_identifier_id, loan_amount)` | `loan/utility.py` | Splits loan amount across available credit lines (GAPL and lender). Returns list of `{customer_credit_line, amount, creation_reason}` breakups. |
| 6 | `LoanSerializer(data=new_loans, many=True).save()` | `loan/serializers.py` | Creates `Loan` records with status `DRAFT`. Each loan gets a unique `CRTX-*` loan_id. |
| 7 | `Loan.save()` → **Signal**: `loan_subvention_overdue_handler` | `loan/signals.py:97` | `post_save` signal fires `loan_signal_handler()` to compute subvention and overdue dates. |
| 8 | `InvLoanMapSerializer(data=new_invoices, many=True).save()` | `loan/serializers.py` | Creates `InvoiceLoanMap` records linking invoices to loans. |
| 9 | **Signal**: `perform_post_save` on `InvoiceLoanMap` | `loan/signals.py:68` | `post_save` triggers `verify_and_trigger_loan_created_event.apply_async()` (countdown=5s) for farmer financing events. |
| 10 | **Signal**: `update_ledger_invoice_for_payment_status_from_invoice_loan_map` | `loan/signals.py:115` | `post_save` on `InvoiceLoanMap` updates ledger invoice payment status. |

### Path B: Bulk Loan Creation (`create_loan_in_bulk()`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `create_loan_in_bulk(upload_data)` | `loan/tasks.py:323` | Receives file upload data. Sorts by transaction date. |
| 2 | `fetch_cust_cl_by_source_n_product(source_identifier_id, credit_product_id)` | `loan/tasks.py` | Fetches `CustomerCreditLine` by partner ID and credit product. |
| 3 | `check_for_existing_invoices(invoices, invoices_at_lender, customer_credit_line)` | `loan/tasks.py:381` | Validates no duplicate invoices exist for the credit line. |
| 4 | `prepare_loan_data(customer_credit_line, txn_raw_data)` | `loan/tasks.py:347` | Builds loan dict: `loan_amount`, `invoiced_amount`, `transaction_date`, `interest_free_period_end_date` (transaction_date + 30 days), unique `CRTX-*` loan_id. |
| 5 | `LoanSerializers(data=new_loans, many=True).save()` | `loan/serializers.py` | Bulk creates `Loan` records. Default status: `YET_TO_BE_DISBURSED`. |
| 6 | `create_invoice_loan_map(serializer.instance, new_loans)` | `loan/tasks.py:404` | Creates `InvoiceLoanMap` records for each invoice-loan pair. Validates invoice/amount/date array lengths match. |
| 7 | Same signals as Path A steps 7–10 fire on each `Loan` and `InvoiceLoanMap` save. | | |

### Path C: Share Loan to Lender (`share_oldest_loan_to_lender`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `share_oldest_loan_to_lender_for_all_partners()` | `loan/tasks.py:1607` | Cron entry (daily 03:00). Filters eligible partners via `RUN_SHARE_OLDEST_LOAN_DAILY_CRON_FOR_ALL_PARTNER` app constant. Intersects with `get_loan_sharable_partner_ids()`. |
| 2 | `share_oldest_loan_to_lender.apply_async(partner_id, event_data, True)` | `loan/tasks.py:1643` | Dispatches per-partner async task with staggered countdown (15s × index). |
| 3 | `is_invoice_share_restricted(partner_id)` | `loan/tasks.py` | Checks if partner is restricted from sharing. |
| 4 | `check_or_add_redis_cache(partner_id)` | `loan/tasks.py` | Redis lock — prevents concurrent share operations for same partner. |
| 5 | `run_reconciliation_for_customer_main(partner_id, MOVEMENT_OF_LOANS)` | `loan/tasks.py` | Runs reconciliation before sharing to ensure loan data is current. |
| 6 | `CustomerCreditLine.objects.filter(...)` | `loan/tasks.py:1710` | Finds active lender credit line. Filters by `belongs_to_gapl=False`, `external_lender_supported=True`, and status `ACTIVE`/`ONHOLD`. |
| 7 | `fetch_latest_credit_line_info(lender_line, fetch_latest_credit_line)` | `loan/tasks.py` | Optionally syncs latest credit line info from Saraloan API. |
| 8 | `get_oldest_sharable_loan_and_usable_limit(lender_line, partner_id, ...)` | `loan/tasks.py` | Finds oldest GAPL loan eligible for sharing. Computes usable lender limit. Loops up to `MAX_REJECTED_PARENT_LOAN_SKIPS` (default 10) to skip loans with rejected parent at BlackSoil. |
| 9 | **Branch: GAPL loan** → `split_gapl_loan_to_share_lender()` | `loan/tasks.py` | If source loan is on GAPL line: marks as disbursed if YTD, splits loan amount between lender and GAPL lines. |
| 10 | **Branch: Non-GAPL loan, full amount fits** → `retry_invoice_upload_for_saraloan()` | `loan/tasks.py:1504` | If `usable_lender_limit >= source_loan.loan_amount`: directly retries/initiates upload. |
| 11 | **Branch: Non-GAPL loan, needs split** → `create_new_loan_from_source_loan()` × 2 | `loan/tasks.py` | Creates two new loans (lender portion + remaining), cancels source loan. |
| 12 | `prepare_loan_to_send_to_saraloan(loan_id, event_data)` | `loan/tasks.py:1465` | Creates `LenderLoanMap` with status `YET_TO_UPLOAD`. Dispatches `send_invoice_to_saraloan.apply_async()` (countdown=5s). |

### Path D: Invoice Upload to Lender (Saraloan/BlackSoil)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `send_invoice_to_saraloan(lender_loan_map_id, event_data)` | `loan/tasks.py:465` | Fetches `LenderLoanMap`, resolves `CustomerLenderMap.application_id`. If no application_id, calls `sync_partner_ids_from_saraloan()`. |
| 2 | Sets `lender_application_id` and `invoice_upload_status = PARTNER_FOUND` | `loan/tasks.py:533` | Updates `LenderLoanMap` with application ID. |
| 3 | `create_tranche_in_blacksoil.apply_async(lender_loan_map_id, event_data)` | `loan/tasks.py:540` | Dispatches tranche creation (countdown=3s). |
| 4 | `create_tranche_in_blacksoil(lender_loan_map_id, event_data)` | `loan/tasks.py:581` | Calls `Saraloan(cred_type).create_invoice_tranche(application_id)`. On success: sets `invoice_upload_status = TRANSACTION_CREATED`. |
| 5 | **Branch: Subvention eligible** → `update_subvention_details_in_saraloan.apply_async()` | `loan/tasks.py:672` | If DC customer with `interest_subvention_enabled` and eligible: updates subvention before invoice. |
| 6 | **Branch: Standard** → `create_invoice_in_blacksoil.apply_async(lender_loan_map_id, event_data)` | `loan/tasks.py:678` | Dispatches invoice creation (countdown=3s). |
| 7 | `create_invoice_in_blacksoil(lender_loan_map_id, event_data)` | `loan/tasks.py:710` | For DC: fetches invoice copy from ERP via `fetch_invoice_copy_from_ib()`. Calls `Saraloan(cred_type).send_invoice(lender_loan_map, invoice_copy)`. |
| 8 | On success: sets `invoice_upload_status = INVOICE_UPLOADED`, `invoice_status_at_lender = Pending` | `loan/tasks.py:830` | Updates `LenderLoanMap`. Removes Redis lock. |
| 9 | `share_oldest_loan_to_lender.apply_async(partner_id, event_data, True)` | `loan/tasks.py:843` | Recursively shares next oldest loan (countdown=3s). |

### Path E: Lender Approval Webhook → Disbursal Processing

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `SaraloanWebhookView.post()` | `external/views.py:32` | Receives webhook. Deserializes via `WebhookSerializer`. Saves raw payload to `ExternalWebhook` table. |
| 2 | Event routing: checks `request.data["event"]` | `external/views.py:44` | Routes by event type: repayment status, disbursal event, loan_account_processed, application_created, application_line_*. |
| 3 | **Disbursal event**: validates `event == DISBURSAL_EVENT` and `invoice.status == "disbursed"` | `external/views.py:68` | Extracts `source_identifier_id` from `data.identifiers.partner_lead_id`. Falls back to mobile number lookup via `fetch_customer_id_from_mobile_no()`. |
| 4 | `is_eligible_to_process_data(source_identifier_id, "PROCESS_LOAN_DISBURSAL_EVENT")` | `external/views.py:79` | Eligibility check — verifies customer should process disbursal events. |
| 5 | `process_saraloan_loan_webhook.apply_async((data, status_map), countdown=300)` | `external/views.py:90` | Dispatches async processing with 5-minute delay. |
| 6 | `process_saraloan_loan_webhook(request, status)` | `credit_line/tasks.py:1261` | Looks up `LenderLoanMap` by `topup_id` (lender invoice ID). Fetches customer and credit line. |
| 7 | `fetch_account_detail_and_validate_interest_component(ccl, True)` | `credit_line/tasks.py` | Validates interest component from Saraloan account details. Returns early if interest discrepancy found. |
| 8 | `Saraloan(cred_type).get_withdrawal_requests_for_invoice_id(application_id, invoice_id, extra_params)` | `credit_line/tasks.py:1310` | Fetches full withdrawal details from Saraloan API for the specific invoice. |
| 9 | `process_loan_saraloan(withdrawal_details, response)` | `credit_line/tasks.py:1343` | Validates withdrawal data via `initial_check()` and `get_vals()`. Checks loan exists and timestamp is newer. |
| 10 | `process_disbursal_event(vals)` | `credit_line/tasks.py:1541` | Core disbursal logic. Compares `disbursement_amount` vs `loan_amount` to determine full vs partial disbursal. |
| 11a | **Full disbursal**: `process_full_disbursal(vals)` | `credit_line/tasks.py:1683` | Calls `update_loan(vals)` → `update_loan_obj()` to update loan with disbursal data (amounts, dates, status). Then `update_gapl_loan(vals)` to mark corresponding GAPL loans as DISBURSED. |
| 11b | **Partial disbursal** (DC only): `reject_loan(vals)` → `create_loan_and_invoiceloanmap(vals, comment)` → `process_partial_disbursal(comment, vals, remaining_amount)` | `credit_line/tasks.py:1620–1670` | Rejects original loan. Creates new loan with disbursed amount on lender line. Creates remaining amount loan on GAPL line via `update_or_create_loan_invoice_for_partial_disbursal()`. |
| 12 | On success: `sync_credit_line_info_from_saraloan.apply_async(ccl_id, account_details)` | `credit_line/tasks.py:1327` | Syncs credit line info from Saraloan after disbursal. |
| 13 | `update_credit_lines_status.apply_async(partner_id=source_identifier_id)` | `credit_line/tasks.py:1330` | Updates credit line status (countdown=3s). |

### Signals Triggered During Approval Workflow

| Signal | Sender | Handler | File | Trigger Condition |
|--------|--------|---------|------|-------------------|
| `post_save` | `Loan` | `send_disbursement_payment_to_erp` | `loan/signals.py:33` | Loan status in `LOAN_STATUSES_TO_UPLOAD_DISBURSAL_ON_SAP` AND `disbursal_payment_ref_id` set AND no `erp_payment_upload_status` → calls `prep_disbursal_payment_to_send_to_sap()` |
| `post_save` | `Loan` | `loan_subvention_overdue_handler` | `loan/signals.py:97` | On created: computes subvention and overdue dates via `loan_signal_handler()` |
| `pre_update` | `Loan` | `event_trigger_for_loan_status_change` | `loan/signals.py:106` | Before status change: fires loan status change event via `trigger_loan_status_change_event_signal()` |
| `post_save` | `Loan` | `update_ledger_invoice_for_payment_status_from_loan` | `loan/signals.py:113` | On update: syncs ledger invoice payment status |
| `post_save` | `InvoiceLoanMap` | `perform_post_save` | `loan/signals.py:68` | On created: triggers `verify_and_trigger_loan_created_event` (farmer financing) |
| `post_save` | `InvoiceLoanMap` | `update_ledger_invoice_for_payment_status_from_invoice_loan_map` | `loan/signals.py:115` | On created: updates ledger invoice payment status |
| `pre_save` | `Loan` | `loan_total_interest_amount_change_signal` | `loan/signals.py:127` | Detects interest field changes, updates ledger flow |
| `post_save` | `Loan` | `process_interest_refund_when_loan_marked_paid` | `loan/signals.py:148` | On update: processes interest refund when loan marked PAID |

---

## Celery Tasks Triggered

| Task | Queue | Triggered By | Countdown | Description |
|------|-------|-------------|-----------|-------------|
| `share_oldest_loan_to_lender` | `celery` | `share_oldest_loan_to_lender_for_all_partners` (cron) | 15s × index | Per-partner loan sharing |
| `send_invoice_to_saraloan` | `saraloan` | `prepare_loan_to_send_to_saraloan` | 5s | Resolves application ID, initiates tranche creation |
| `create_tranche_in_blacksoil` | `saraloan` | `send_invoice_to_saraloan` | 3s | Creates tranche at lender |
| `update_subvention_details_in_saraloan` | `saraloan` | `create_tranche_in_blacksoil` | 3s | Updates subvention (DC + subvention eligible) |
| `create_invoice_in_blacksoil` | `saraloan` | `create_tranche_in_blacksoil` or `update_subvention_details_in_saraloan` | 3s | Uploads invoice document to lender |
| `process_saraloan_loan_webhook` | `saraloan` | `SaraloanWebhookView.post()` | 300s (5 min) | Processes lender disbursal webhook |
| `sync_credit_line_info_from_saraloan` | `saraloan` | `process_saraloan_loan_webhook` | — | Syncs credit line after disbursal |
| `update_credit_lines_status` | `celery` | `process_saraloan_loan_webhook` | 3s | Updates credit line status post-disbursal |
| `verify_and_trigger_loan_created_event` | `event` | `InvoiceLoanMap` post_save signal | 5s | Farmer financing loan created event |
| `_send_invoice_upload_fail_email` | `email` | Various failure paths | — | Failure notification email |
| `fire_move_to_lender_event` | `event` | Various steps in share flow | — | Mixpanel event tracking |

---

## Database Tables Accessed

| Table | Access Type | Key Columns | Accessed By |
|-------|------------|-------------|-------------|
| `loan_loan` | Read/Write | `customer_credit_line_id`, `status`, `loan_id`, `loan_amount`, `remaining_amount`, `disbursement_date`, `disbursed_amount` | `create_loan()`, `create_loan_in_bulk()`, `process_disbursal_event()`, `update_loan()`, `update_gapl_loan()` |
| `loan_invoiceloanmap` | Read/Write | `loan_id`, `invoice_id`, `invoice_id_at_lender`, `delivery_date`, `disbursement_amount` | `create_invoice_loan_map()`, `create_loan()`, `process_disbursal_event()` |
| `loan_lenderloanmap` | Read/Write | `loan_id`, `lender_invoice_id`, `invoice_upload_status`, `lender_application_id`, `invoice_status_at_lender` | `prepare_loan_to_send_to_saraloan()`, `send_invoice_to_saraloan()`, `create_tranche_in_blacksoil()`, `create_invoice_in_blacksoil()`, `process_saraloan_loan_webhook()` |
| `credit_line_customer` | Read | `source_identifier_id`, `external_lender_supported`, `customer_type_id` | `share_oldest_loan_to_lender()`, `send_invoice_to_saraloan()`, `process_saraloan_loan_webhook()` |
| `credit_line_customercreditline` | Read/Write | `customer_id`, `credit_product_id`, `status`, `lender_available_credit_limit` | `share_oldest_loan_to_lender()`, `create_loan()`, `sync_credit_line_info_from_saraloan()` |
| `credit_line_creditproduct` | Read | `credit_product_name`, `belongs_to_gapl`, `interest_subvention_enabled` | `share_oldest_loan_to_lender()`, `create_tranche_in_blacksoil()` |
| `credit_line_customerlendermap` | Read/Write | `customer_id`, `credit_product_id`, `application_id` | `send_invoice_to_saraloan()` |
| `external_externalwebhook` | Write | `event`, `data`, `created_at` | `SaraloanWebhookView.post()` |
| `django_celery_results_taskresult` | Read | `task_name`, `status`, `date_done`, `task_args` | Task state investigation |
| `ledger_ledgerentry` | Read | `partner_id`, `type`, `source_no` | Ledger updates via signals |

---

## Decision Points

> Cross-reference: See `04-decision-logic.md` for full condition expressions and branch outcomes.

| # | Decision | Location | Condition | Outcomes |
|---|----------|----------|-----------|----------|
| D1 | Loan already exists for invoices? | `loan/utility.py:2218` | `check_if_loan_exist_for_invoices(invoice_ids)` | **True** → return `False`, no loan created. **False** → continue. |
| D2 | Loan breakup available? | `loan/utility.py:2226` | `generate_loan_breakup_for_customer()` returns empty | **Empty** → return `False`. **Has breakups** → create loans per breakup. |
| D3 | Invoice share restricted? | `loan/tasks.py:1672` | `is_invoice_share_restricted(partner_id)` | **True** → skip partner. **False** → continue. |
| D4 | Active lender credit line exists? | `loan/tasks.py:1710` | `CustomerCreditLine` query for non-GAPL, active/onhold | **None** → "No active lender credit line", exit. **Found** → continue. |
| D5 | Usable lender limit sufficient? | `loan/tasks.py:1850` | `usable_lender_limit < min_shareable_lender_loan_amount` (default 10) | **Below minimum** → exit with "balance less than one". **Sufficient** → continue. |
| D6 | Source loan on GAPL line? | `loan/tasks.py:1870` | `source_loan.customer_credit_line.credit_product.belongs_to_gapl` | **True** → GAPL split path. **False** → direct lender path. |
| D7 | Lender limit covers full loan? | `loan/tasks.py:1920` | `usable_lender_limit >= source_loan.loan_amount` | **True** → share full loan. **False** → split loan (lender portion + GAPL remainder). |
| D8 | Application ID found at lender? | `loan/tasks.py:508` | `customer_lender_map.application_id` is None | **None** → mark `APPLICATION_NOT_FOUND`, send failure email. **Found** → proceed to tranche creation. |
| D9 | Tranche creation successful? | `loan/tasks.py:618` | `tranche_detail["status_code"] != 201` | **Failed** → mark `TRANSACTION_CREATION_FAILED`, send email. **Success** → proceed to invoice upload. |
| D10 | Subvention eligible? | `loan/tasks.py:672` | DC customer AND `interest_subvention_enabled` AND `is_customer_eligible_for_subvention()` | **True** → `update_subvention_details_in_saraloan` first. **False** → direct `create_invoice_in_blacksoil`. |
| D11 | Full vs partial disbursal? | `credit_line/tasks.py:1575` | `invoice_requested_amount > disbursement_amount` | **Partial** → reject original, create new loans. **Full** → `process_full_disbursal()`. |
| D12 | Partial disbursal for Farmer? | `credit_line/tasks.py:1590` | `customer_type != CustomerType.DC` and partial | **Farmer** → return `False` (partial disbursal not supported for farmers). **DC** → process partial. |
| D13 | Parent loan rejected at BlackSoil? | `loan/tasks.py:1808` | `check_if_parent_loan_is_rejected_blacksoil(source_loan)` AND partner not in allowed list | **True** → skip loan, try next. **False** → proceed with sharing. |

---

## Loan Status Transitions (FSM)

The `Loan.status` field uses `django-fsm` with these transitions relevant to the approval workflow:

| Transition | Source Status | Target Status | Method | Trigger |
|-----------|-------------|--------------|--------|---------|
| Creation (API) | — | `DRAFT` | `create_loan()` | `LoanViewSet.post()` |
| Creation (bulk) | — | `YET_TO_BE_DISBURSED` | `create_loan_in_bulk()` | Bulk upload |
| Move to YTD | `DRAFT` | `YET_TO_BE_DISBURSED` | `update_status_to_yet_to_disbursed()` | Admin / status update |
| Disbursal | `YET_TO_BE_DISBURSED` | `DISBURSED` | `update_status_to_disbursed()` | `process_full_disbursal()` / `update_gapl_loan()` |
| Rejection | `YET_TO_BE_DISBURSED` | `REJECTED` | `update_status_to_rejected()` | `reject_loan()` (partial disbursal) |
| Cancellation | `DRAFT` / `YET_TO_BE_DISBURSED` / `CANCELLED` | `CANCELLED` | `update_status_to_cancelled()` | Loan split / cancellation |
| Move to lender | `YET_TO_BE_DISBURSED` / `DISBURSED` / `OVERDUE` / `PARTIALLY_PAID` | `MOVED_TO_LENDER` | `update_status_to_moved_to_lender()` | `split_gapl_loan_to_share_lender()` |

### LenderLoanMap Upload Status Progression

```
YET_TO_UPLOAD → PARTNER_FOUND → TRANSACTION_CREATED → INVOICE_UPLOADED
                     ↓                    ↓                    ↓
              APPLICATION_NOT_FOUND  TRANSACTION_CREATION_FAILED  INVOICE_UPLOAD_FAILED
                                                                       ↓
                                                              MANUAL_UPDATE_REQUIRED
```

---

## Investigation Queries

### Q1: Find all loans for a user with status and credit line details

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
**Performance**: Uses index on `loan_loan(customer_credit_line_id)`. Expected < 50ms.

---

### Q2: Check LenderLoanMap upload status for a user's loans

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
**Performance**: Uses index on `loan_lenderloanmap(loan_id)`. Expected < 30ms.

---

### Q3: Check InvoiceLoanMap entries for a user

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
**Performance**: Uses index on `loan_invoiceloanmap(loan_id)`. Expected < 30ms.

---

### Q4: Check CustomerLenderMap (application ID) for a user

**ORM**:
```python
from credit_line.model import CustomerLenderMap

CustomerLenderMap.objects.filter(
    customer__source_identifier_id='{user_id}'
).values(
    'id', 'customer__source_identifier_id', 'application_id',
    'credit_product__credit_product_name', 'created_at', 'updated_at'
)
```

**SQL**:
```sql
SELECT clm.id, c.source_identifier_id, clm.application_id,
       cp.credit_product_name, clm.created_at, clm.updated_at
FROM credit_line_customerlendermap clm
JOIN credit_line_customer c ON clm.customer_id = c.id
JOIN credit_line_creditproduct cp ON clm.credit_product_id = cp.id
WHERE c.source_identifier_id = '{user_id}';
```
**Performance**: Uses index on `credit_line_customerlendermap(customer_id)`. Expected < 10ms.

---

### Q5: Check webhook events received for a user's loans

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
**Performance**: **Warning** — JSON field query without index. May be slow on large tables. Add date range filter for production:
```sql
AND created_at >= NOW() - INTERVAL '7 days'
```

---

### Q6: Check Celery task results for loan-related tasks

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'loan.tasks.share_oldest_loan_to_lender',
        'loan.tasks.send_invoice_to_saraloan',
        'loan.tasks.create_tranche_in_blacksoil',
        'loan.tasks.create_invoice_in_blacksoil',
        'credit_line.tasks.process_saraloan_loan_webhook',
    ],
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
WHERE task_name IN (
    'loan.tasks.share_oldest_loan_to_lender',
    'loan.tasks.send_invoice_to_saraloan',
    'loan.tasks.create_tranche_in_blacksoil',
    'loan.tasks.create_invoice_in_blacksoil',
    'credit_line.tasks.process_saraloan_loan_webhook'
)
AND task_args LIKE '%{user_id}%'
ORDER BY date_done DESC
LIMIT 50;
```
**Performance**: Uses index on `django_celery_results_taskresult(task_name)`. `LIKE` on `task_args` may be slow — add `date_done` filter:
```sql
AND date_done >= NOW() - INTERVAL '7 days'
```

---

### Q7: Find loans stuck in YET_TO_BE_DISBURSED with no LenderLoanMap

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
**Performance**: Uses index on `loan_loan(customer_credit_line_id, status)`. Expected < 20ms.

---

### Q8: Check lender credit line availability for sharing

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
**Performance**: Uses index on `credit_line_customercreditline(customer_id, credit_product_id)`. Expected < 10ms.

---

### Q9: Trace loan movement history (GAPL → Lender splits)

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
**Performance**: Uses index on `loan_loan(customer_credit_line_id)`. Expected < 30ms.
