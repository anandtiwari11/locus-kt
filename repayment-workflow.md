# Flow: Repayment Workflow

> Traces the complete repayment workflow from collection/deposit creation through lender repayment sync, payment creation, ledger entry updates, and credit line status refresh.
> This flow answers: "For a given `source_identifier_id`, how was a repayment recorded, synced with the lender, and how did it update the ledger and credit line?"

**Primary Entry Points**:
- API: `POST /repayment/` via `repayment/views.py:ListCreateTransactionView.post()` (collection/deposit creation)
- API: `POST /repayment/deposit/` via `repayment/views.py:DepositView` (group deposits, VPA deposits)
- Cron: `payment/tasks.py:sync_repayment_info_for_all_dc()` (daily 19:30)
- Webhook: `external/views.py:SaraloanWebhookView.post()` → `payment/tasks.py:process_saraloan_repayment_webhook()`
- Bulk upload: `repayment/tasks.py:start_repayment_txns()` → `correct_repayment_transactions()`

---

## Entry Points

| Entry Point | Method | user_id Location | File Path |
|-------------|--------|-----------------|-----------|
| `repayment/` | POST | Request body: `farmer_id` (payer) | `repayment/views.py:ListCreateTransactionView.post()` |
| `repayment/deposit/` | POST | Derived from request entity | `repayment/views.py:DepositView` |
| Cron: sync repayments | Celery Beat (19:30) | Derived from `CustomerCreditLine` → `Customer.source_identifier_id` | `payment/tasks.py:sync_repayment_info_for_all_dc()` |
| Webhook: repayment event | POST | `data.identifiers.partner_lead_id` | `payment/tasks.py:process_saraloan_repayment_webhook()` |
| Bulk correction upload | Celery | Upload data: `Farmer Kheti Id` column | `repayment/tasks.py:start_repayment_txns()` |

---

## Execution Sequence

### Path A: Collection/Deposit via API (`ListCreateTransactionView.post()`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `ListCreateTransactionView.post()` | `repayment/views.py:365` | Entry point. Extracts `transaction_type` (Collection or Deposit), `transaction_channel`, `amount` from request body. |
| 2 | **Branch: Collection** — validates `amount > 0`, calls `get_entity_and_entity_type(request)` to resolve payee (GL/FSFE), sets `payer = farmer_id` from request body. | `repayment/views.py:378` | Builds data dict with `payee`, `payee_type`, `payer_type=FARMER`, `amount`, `transaction_type=Collection`, `transaction_channel=Cash`. |
| 3 | **Branch: Deposit** — calls `get_entity_and_entity_type(request)` to resolve payer (GL/FSFE). If cash channel, calls `__payee_for_deposit_to_fsfe(payer)` to find FSFE payee. | `repayment/views.py:396` | Builds data dict with `payer`, `payer_type`, `payee`, `payee_type=FSFE`, `amount`, `transaction_type=Deposit`. |
| 4 | `check_if_blocked(entity, entity_type)` | `repayment/views.py:389` | Validates entity is not blocked from transactions. |
| 5 | Idempotency check via Redis (`FFIdempotentConfigs.FF_IDEMPOTENT_REDIS_KEY`) | `repayment/views.py:416` | If `HTTP_IDEMPOTENCY_KEY` header present, checks Redis cache. Returns cached response if duplicate. |
| 6 | `serializer = self.get_serializer(data=data)` → `serializer.is_valid()` | `repayment/views.py:427` | Validates transaction data via `TransactionSerializer`. |
| 7 | `self.perform_create(serializer, payer, api_version, payer_type)` | `repayment/views.py:428` | Creates `Transaction` record. For v2 API: generates `transaction_id` UUID, caches farmer payers in Redis. For v1: saves with payer directly. |
| 8 | **Signal**: `process_post_save_transaction(instance)` | `repayment/utils.py:1208` | Post-save on `Transaction`. If Deposit type: triggers `trigger_repayment_created_event.apply_async(instance.id, countdown=10)`. Maps collections to deposit (links `related_transaction`). |
| 9 | **Branch: Cash Deposit** → `__handle_deposit_to_fsfe(payer, amount, payee, txn_id)` | `repayment/views.py:433` | Creates secondary collection entries on FSFE end for each farmer collection linked to the deposit. |
| 10 | Idempotency cache set (if key provided) | `repayment/views.py:440` | Caches response in Redis with TTL for deduplication. |

### Path B: Group/VPA Deposits (`DepositView`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `DepositView.create_multiple_vpa_deposits()` or `create_full_amount_deposits()` | `repayment/views.py:937` | Entry point for group VPA or full-amount deposits. Resolves entity via `get_entity_and_entity_type()`. |
| 2 | `DepositView.create_group_transaction(entity, entity_type, payer_data, txn_channel)` | `repayment/views.py:747` | Creates `TransactionReferenceGroupInfo` and `TransactionReferenceInfo` records for each payer. Caches `txn_{transaction_id}` → payer in Redis. |
| 3 | `DepositView.__update_deposits(data, entity, entity_type, ...)` | `repayment/views.py:865` | On success callback: creates `AggregatedDeposit`, iterates payer info, creates `Transaction` (Deposit) per payer, creates `AggregatedTransactionDepositMapping` linking each transaction to the aggregated deposit. |
| 4 | **Signal**: `process_post_save_transaction(instance)` | `repayment/utils.py:1208` | Same as Path A step 8 — triggers `trigger_repayment_created_event` and maps collections to deposits. |
| 5 | `DepositView._update_txn_references(grp_txn, status, psp_app, ...)` | `repayment/views.py:826` | Updates `TransactionReferenceInfo` status for all references in the group. |

### Path C: Lender Repayment Sync (`sync_repayment_info_for_all_dc()`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `sync_repayment_info_for_all_dc()` | `payment/tasks.py:596` | Cron entry (daily 19:30). Fetches all eligible `CustomerCreditLine` records via `get_credit_lines_for_saraloan_customers(REPAYMENT_INFO)`. |
| 2 | For each credit line: resolves `CustomerLenderMap` | `payment/tasks.py:607` | Looks up `CustomerLenderMap` by customer + credit product. If missing, calls `sync_partner_ids_from_saraloan()` to fetch from lender. |
| 3 | `fetch_and_update_repayments_info.delay(ccl_id, loan_account_id, source_identifier_id)` | `payment/tasks.py:643` | Dispatches async task per credit line (skips if no `loan_account_id`). |
| 4 | `fetch_and_update_repayments_info()` | `payment/tasks.py:682` | Calls `Saraloan.get_repayment_details(loan_account_id)` to fetch repayment records from lender API. Paginates through all results. |
| 5 | `process_records(ccl_id, repayment_details, source_identifier_id, ...)` | `payment/tasks.py:767` | Iterates each repayment detail. Calls `validate_and_create_or_update_payment()` for each record. |
| 6 | `validate_and_create_or_update_payment(source_identifier_id, ccl_id, data, event, for_farmer)` | `payment/utils.py:352` | Core payment creation/update logic (see Path E below). |
| 7 | `check_lender_deleted_payments(source_identifier_id, ccl_id, payments_with_lender)` | `payment/tasks.py:654` | Checks for payments that exist locally but were deleted at lender. |
| 8 | `update_credit_lines_status.apply_async(partner_id=source_identifier_id, countdown=3)` | `payment/tasks.py:741` | Refreshes credit line status after sync. |

### Path D: Webhook Repayment Processing (`process_saraloan_repayment_webhook()`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `SaraloanWebhookView.post()` | `external/views.py` | Receives webhook. Saves raw payload to `ExternalWebhook` table. Routes repayment events. |
| 2 | `process_saraloan_repayment_webhook(event, data)` | `payment/tasks.py:820` | **Branch: `REPAYMENT_CAPTURED`** → calls `process_repayment_data(data, event, sync_credit_line=False)` synchronously. On exception, retries with 300s countdown. |
| 3 | **Branch: Other events** → `process_repayment_data.apply_async((data, event, True), countdown=300)` | `payment/tasks.py:838` | Dispatches async with 5-minute delay and `sync_credit_line=True`. |
| 4 | `process_repayment_data(repayment_data, event, sync_credit_line)` | `payment/tasks.py:854` | Resolves `source_identifier_id` from `identifiers.partner_lead_id` (falls back to mobile number lookup via KhetiDB). |
| 5 | Fetches `Customer` and determines `CreditProduct` | `payment/tasks.py:866` | **DC** → `ME_BLACKSOIL` product (requires `external_lender_supported`). **Farmer** → `FARMER_BLACKSOIL` product. |
| 6 | `fetch_cust_cl_by_source_n_product(source_identifier_id, credit_product_id)` | `common/utils.py:246` | Fetches `CustomerCreditLine` by partner ID and credit product. |
| 7 | `fetch_account_detail_and_validate_interest_component(ccl)` (if `sync_credit_line=True`) | `payment/tasks.py:889` | Validates interest component from Saraloan account details. Returns early if interest discrepancy. |
| 8 | `validate_and_create_or_update_payment(source_identifier_id, ccl_id, data, event, for_farmer)` | `payment/utils.py:352` | Core payment creation/update logic (see Path E below). |
| 9 | **If result and sync_credit_line**: `sync_credit_line_loans_params_from_saraloan.apply_async(ccl_id, sync_only_unpaid_loan)` | `payment/tasks.py:901` | Syncs loan params from Saraloan. |
| 10 | `sync_credit_line_info_from_saraloan.apply_async(ccl_id, account_details)` | `payment/tasks.py:904` | Syncs credit line info from Saraloan. |
| 11 | `update_credit_lines_status.apply_async(partner_id=source_identifier_id, countdown=3)` | `payment/tasks.py:907` | Refreshes credit line status. |

### Path E: Payment Creation/Update (`validate_and_create_or_update_payment()`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `validate_and_create_or_update_payment()` | `payment/utils.py:352` | Atomic transaction. Maps event to `PaymentStatus` via `REPAYMENT_STATUS_MAP` or `PULL_REPAYMENT_STATUS_MAP`. |
| 2 | Checks existing `Payment` by `lender_payment_id` + `customer_credit_line_id` | `payment/utils.py:393` | Determines create vs update path. |
| 3a | **Existing payment** → `is_lender_payment_status_transition_valid(payment_object, status)` | `payment/utils.py:420` | Validates status transition. Invalid → sends `INVALID_LENDER_PAYMENT_TRANSITION` email, returns `None`. |
| 3b | **Existing payment** → `create_or_update_ledger_entry(data, payment_obj, ...)` | `payment/utils.py:437` | Creates or updates `LedgerEntry` (see Path F). |
| 3c | **Existing payment** → `payment_object.save()` | `payment/utils.py:457` | Updates payment fields if changed (amount, status, settlement_date, refund_utr, etc.). |
| 3d | **Existing payment, bounced** → `cancel_ledger_entry(payment_object.id)` | `payment/utils.py:472` | If `repayment_bounced` and newer `lender_updated_at`: cancels ledger entry (sets `active=False`, `visible=False`). |
| 4a | **New payment** → `Payment.objects.create(**upload_raw_data)` | `payment/utils.py:510` | Creates new `Payment` record. For farmer with `POSTED` status: first tries `validate_and_update_existing_unrealized_payment()`. |
| 4b | **New payment** → `create_or_update_ledger_entry(data, payment_obj, ...)` | `payment/utils.py:527` | Creates `LedgerEntry` for the new payment. |
| 5 | **BlackSoil ME payments** → `map_saraloan_payment_to_loan(payment_obj)` | `payment/utils.py:462` | If credit product is `ME_BLACKSOIL` and `lender_payment_id` starts with `SLR`: maps payment to loan via `_map_payment_to_loans_common_logic()`. |
| 6 | **Signal**: `payment_pre_signal` (pre_save on `Payment`) | `payment/signals.py:100` | Captures status changes. If status changed to `POSTED`: triggers `payment_transfer_rejected_notification.apply_async(pk, countdown=5)`. |
| 7 | **Signal**: `process_payment_post_created_or_updated(instance)` (post_save on `Payment`) | `payment/signals.py:309` | For Farmer customers: maps payment to transactions via `handle_payment_to_vpa_transactions_mapping()` (PG mode) or `handle_payment_to_transactions_mapping()` (other modes). |

### Path F: Ledger Entry Creation/Update (`create_or_update_ledger_entry()`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `create_or_update_ledger_entry(data, payment_obj, gapl_payment_exists, source_identifier_id, upload_raw_data)` | `payment/utils.py:631` | Checks for existing `LedgerEntry` by `locus_id=payment_obj.id` and `type=PAYMENT`. |
| 2a | **No existing entry** → `LedgerEntry.objects.create(...)` | `payment/utils.py:639` | Creates ledger entry with `partner_id`, `type=PAYMENT`, `source=LOCUS`, `date` (settlement_date or payment_date), `amount`, `payment_mode`, `source_no=lender_payment_id`. Sets `unrealized_payment=True` if status is `UNREALIZED`. |
| 2b | **Existing entry** → updates `amount`, `date`, `unrealized_payment`, `visible` if changed | `payment/utils.py:658` | Updates entry when amount changes, or when status transitions from UNREALIZED to POSTED (updates date to settlement_date). |

### Path G: Bulk Repayment Correction (`start_repayment_txns()`)

| Step | Function | File | Description |
|------|----------|------|-------------|
| 1 | `start_repayment_txns(data)` | `repayment/tasks.py:736` | Entry point. Dispatches `correct_repayment_transactions.delay(data)`. |
| 2 | `correct_repayment_transactions(d_reader)` | `repayment/tasks.py:731` | Iterates each row in uploaded data. Calls `correct_repayment_transaction(row)` per row. |
| 3 | `correct_repayment_transaction(row)` | `repayment/tasks.py:666` | Extracts `farmer_id`, `digitally_recorded_amount`, `actual_reconciled_amount`, date range. Queries `Transaction` records for the farmer within the date range. |
| 4 | `create_upi_txns_list(recorded_transactions)` | `repayment/tasks.py:641` | Separates UPI transactions from non-UPI. UPI transactions are excluded from correction. |
| 5 | `start_correction_process_for_transactions(upi_excluded_txns, digitally_recorded_amount, actual_reconciled_amount)` | `repayment/tasks.py:462` | Adjusts transaction amounts to match actual reconciled amounts. |
| 6 | On failure: `send_email_for_failure.delay(row, error_message)` | `repayment/tasks.py:653` | Sends failure notification email for rows that cannot be processed. |

---

## Celery Tasks Triggered

| Task | Queue | Triggered By | Countdown | Description |
|------|-------|-------------|-----------|-------------|
| `sync_repayment_info_for_all_dc` | `celery` | Celery Beat (daily 19:30) | — | Iterates all eligible credit lines, dispatches per-line sync |
| `fetch_and_update_repayments_info` | `celery` | `sync_repayment_info_for_all_dc` | — | Fetches repayment details from Saraloan API, processes records |
| `process_repayment_data` | `celery` | `process_saraloan_repayment_webhook` | 300s | Processes webhook repayment data, creates/updates payments |
| `process_saraloan_repayment_webhook` | `saraloan` | `SaraloanWebhookView.post()` | — | Routes webhook events to `process_repayment_data` |
| `correct_repayment_transactions` | `celery` | `start_repayment_txns` | — | Bulk correction of repayment transaction amounts |
| `trigger_repayment_created_event` | `event` | `process_post_save_transaction` (Transaction post_save) | 10s | Fires "FF Repayment Created" event to Mixpanel/MoEngage |
| `send_sms` | `celery` | `process_post_save_transaction` (Collection post_save) | — | Sends SMS to farmer on collection success |
| `sync_credit_line_loans_params_from_saraloan` | `saraloan` | `process_repayment_data` | — | Syncs loan params after repayment |
| `sync_credit_line_info_from_saraloan` | `saraloan` | `process_repayment_data` | — | Syncs credit line info after repayment |
| `update_credit_lines_status` | `celery` | `process_repayment_data`, `fetch_and_update_repayments_info` | 3s | Refreshes credit line status post-repayment |
| `fire_repayment_event` | `event` | Payment signal receiver | — | Fires repayment analytics event (Mixpanel/MoEngage) |
| `trigger_payment_under_process_event` | `event` | `process_payment_post_created_or_updated` (PG mode) | — | Fires payment-under-process event for PG payments |
| `send_email_for_failure` | `email` | `correct_repayment_transaction` | — | Sends failure notification for bulk correction errors |
| `payment_transfer_rejected_notification` | `celery` | `capture_payment_status_change` (pre_save signal) | 5s | Notification when payment status changes to POSTED |

---

## Database Tables Accessed

| Table | Access Type | Key Columns | Accessed By |
|-------|------------|-------------|-------------|
| `repayment_transaction` | Read/Write | `payer`, `payer_type`, `transaction_type`, `transaction_id`, `active`, `payment_id`, `related_transaction_id` | `ListCreateTransactionView.post()`, `DepositView`, `process_post_save_transaction()`, `correct_repayment_transaction()`, `handle_payment_to_vpa_transactions_mapping()` |
| `repayment_aggregated_deposit` | Write | `aggregated_amount`, `payee`, `ref_num` | `DepositView.__update_deposits()` |
| `repayment_aggregated_transaction_deposit_mapping` | Write | `aggregated_deposit_id`, `transaction_id` | `DepositView.__update_deposits()` |
| `repayment_demandsheet` | Read | `user_id`, `from_date`, `to_date`, `net_demand_amount`, `overdue_amount` | `correct_repayment_transaction()`, demand-related queries |
| `repayment_customervirtualaccount` | Read | `customer_id`, `credit_product_id`, `virtual_account_number` | `RetrieveVirtualAccountInfoView`, VPA deposit flows |
| `payment_payment` | Read/Write | `customer_credit_line_id`, `lender_payment_id`, `status`, `payment_amount`, `settlement_date`, `payment_transfer_number` | `validate_and_create_or_update_payment()`, `process_repayment_data()` |
| `ledger_ledgerentry` | Read/Write | `partner_id`, `locus_id`, `type`, `amount`, `date`, `source_no`, `visible`, `unrealized_payment` | `create_or_update_ledger_entry()`, `cancel_ledger_entry()` |
| `credit_line_customer` | Read | `source_identifier_id`, `customer_type_id`, `external_lender_supported` | `process_repayment_data()`, `fetch_and_update_repayments_info()` |
| `credit_line_customercreditline` | Read | `customer_id`, `credit_product_id`, `status` | `process_repayment_data()`, `sync_repayment_info_for_all_dc()` |
| `credit_line_creditproduct` | Read | `credit_product_name` | `process_repayment_data()` |
| `credit_line_customerlendermap` | Read | `customer_id`, `credit_product_id`, `loan_account_id`, `business_id` | `sync_repayment_info_for_all_dc()` |
| `payment_aggregatedpaymenttransfer` | Read | `bank_generated_utr` | `map_payment_to_loan_on_transfer()` |
| `external_externalwebhook` | Write | `event`, `data`, `created_at` | `SaraloanWebhookView.post()` |
| `django_celery_results_taskresult` | Read | `task_name`, `status`, `date_done`, `task_args` | Task state investigation |

---

## Decision Points

> Cross-reference: See `04-decision-logic.md` for full condition expressions and branch outcomes.

| # | Decision | Location | Condition | Outcomes |
|---|----------|----------|-----------|----------|
| D1 | Transaction type? | `repayment/views.py:375` | `transaction_type == Collection` vs `Deposit` | **Collection** → farmer is payer, GL/FSFE is payee. **Deposit** → GL/FSFE is payer, FSFE is payee (cash) or no payee (VPA). |
| D2 | Entity blocked? | `repayment/views.py:389` | `check_if_blocked(entity, entity_type)` | **Blocked** → raises exception. **Not blocked** → continue. |
| D3 | Idempotent request? | `repayment/views.py:416` | `HTTP_IDEMPOTENCY_KEY` present and cached | **Cached** → return cached response. **Not cached** → create transaction. |
| D4 | Cash deposit channel? | `repayment/views.py:405` | `transaction_channel == Cash` | **Cash** → creates secondary FSFE collection entries via `__handle_deposit_to_fsfe()`. **VPA/PG** → no secondary entries. |
| D5 | Customer type (DC vs Farmer)? | `payment/tasks.py:866` | `customer.customer_type.name` | **DC** → `ME_BLACKSOIL` product, requires `external_lender_supported`. **Farmer** → `FARMER_BLACKSOIL` product. |
| D6 | Credit line exists? | `payment/tasks.py:883` | `fetch_cust_cl_by_source_n_product()` returns `None` | **None** → logs error, returns `False`. **Found** → continue processing. |
| D7 | Interest discrepancy? | `payment/tasks.py:893` | `fetch_account_detail_and_validate_interest_component()` returns discrepancy | **Discrepancy** → returns `None`, stops processing. **No discrepancy** → continue. |
| D8 | Payment exists at lender? | `payment/utils.py:393` | `Payment.objects.filter(lender_payment_id, ccl_id).exists()` | **Exists** → update path (validate transition, update fields). **New** → create path. |
| D9 | Status transition valid? | `payment/utils.py:420` | `is_lender_payment_status_transition_valid(payment, status)` | **Invalid** → sends email, returns `None`. **Valid** → proceed with update. |
| D10 | Repayment bounced? | `payment/utils.py:472` | `status == repayment_bounced` and `lender_updated_at` is newer | **Bounced** → cancels ledger entry (`active=False`, `visible=False`). **Not bounced** → normal update. |
| D11 | Full refund? | `payment/utils.py:413` | `payment_amount == refund_amount` | **Full refund** → status set to `CANCELLED`, sub_status to `REFUNDED`. **Partial refund** → reduces `payment_amount` by `refund_amount`. |
| D12 | Farmer with POSTED status (new payment)? | `payment/utils.py:505` | `for_farmer and status == POSTED` | **True** → tries `validate_and_update_existing_unrealized_payment()` first. **False** → creates new payment directly. |
| D13 | BlackSoil ME payment with SLR ID? | `payment/utils.py:462` | `credit_product == ME_BLACKSOIL` and `lender_payment_id.startswith("SLR")` | **True** → maps payment to loan via `map_saraloan_payment_to_loan()`. **False** → skip loan mapping. |
| D14 | GAPL payment exists for transfer number? | `payment/utils.py:399` | `Payment.objects.filter(payment_transfer_number, belongs_to_gapl=True).exists()` | **True** → sets `visible=False` on ledger entry, calls `mark_gapl_payments_as_moved_to_lender()`. **False** → normal visibility. |

---

## Payment Status Transitions

| Source Status | Target Status | Trigger | Notes |
|--------------|--------------|---------|-------|
| — | `POSTED` | `process_repayment_data()` (event: `repayment_done`) | New payment from lender confirmation |
| — | `UNREALIZED` | `process_repayment_data()` (PG mode only) | PG payment pending realization |
| `UNREALIZED` | `POSTED` | `validate_and_create_or_update_payment()` | Payment realized, ledger date updated to settlement_date |
| `POSTED` | `CANCELLED` | `validate_and_create_or_update_payment()` | Full refund (`payment_amount == refund_amount`) |
| Any | `BOUNCED` | `validate_and_create_or_update_payment()` (event: `repayment_bounced`) | Ledger entry cancelled |
| Any | `MOVED_TO_LENDER` | `map_payment_to_loan_on_transfer()` signal | Payment transferred to lender |

---

## Investigation Queries

### Q1: Find all repayment transactions for a farmer

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
**Performance**: Uses index on `repayment_transaction(transaction_type, active)`. Expected < 50ms.

---

### Q2: Find payments for a user's credit line (lender repayments)

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
**Performance**: Uses index on `payment_payment(customer_credit_line_id)`. Expected < 50ms.

---

### Q3: Find ledger entries for a user (repayment type)

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
**Performance**: Uses index on `ledger_ledgerentry(partner_id, type)`. Expected < 30ms.

---

### Q4: Cross-reference payment with ledger entry (detect mismatches)

**ORM**:
```python
from payment.models import Payment
from ledger.models import LedgerEntry

payments = Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}'
).values_list('id', 'payment_amount', 'status', 'settlement_date')

for pid, amt, st, sd in payments:
    entry = LedgerEntry.objects.filter(locus_id=pid, type='PAYMENT').first()
    if not entry:
        print(f"MISSING LEDGER: Payment {pid} amount={amt} status={st}")
    elif entry.amount != amt:
        print(f"AMOUNT MISMATCH: Payment {pid} pay_amt={amt} ledger_amt={entry.amount}")
```

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
**Performance**: Uses indexes on `payment_payment(customer_credit_line_id)` and `ledger_ledgerentry(locus_id, type)`. Expected < 50ms.

---

### Q5: Find demand sheets for a farmer

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
**Performance**: Uses index on `repayment_demandsheet(user_id)`. Expected < 30ms.

---

### Q6: Find aggregated deposits and their mapped transactions

**ORM**:
```python
from repayment.models import AggregatedTransactionDepositMapping, Transaction

deposit_txns = Transaction.objects.filter(
    payer='{user_id}',
    transaction_type='Deposit',
    active=True
).values_list('id', flat=True)

AggregatedTransactionDepositMapping.objects.filter(
    transaction_id__in=deposit_txns
).select_related('aggregated_deposit', 'transaction').values(
    'aggregated_deposit__id', 'aggregated_deposit__aggregated_amount',
    'aggregated_deposit__ref_num', 'aggregated_deposit__created_at',
    'transaction__id', 'transaction__amount', 'transaction__transaction_channel',
    'transaction__created_at'
)
```

**SQL**:
```sql
SELECT ad.id AS agg_deposit_id, ad.aggregated_amount, ad.ref_num,
       ad.created_at AS agg_created_at,
       t.id AS txn_id, t.amount, t.transaction_channel,
       t.created_at AS txn_created_at
FROM repayment_aggregated_transaction_deposit_mapping atdm
JOIN repayment_aggregated_deposit ad ON atdm.aggregated_deposit_id = ad.id
JOIN repayment_transaction t ON atdm.transaction_id = t.id
WHERE t.payer = '{user_id}'
  AND t.transaction_type = 'Deposit'
  AND t.active = true
ORDER BY ad.created_at DESC;
```
**Performance**: Uses index on `repayment_transaction(transaction_type, active)`. Expected < 50ms.

---

### Q7: Find virtual account info for a user

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
**Performance**: Uses unique constraint on `(customer_id, credit_product_id)`. Expected < 10ms.

---

### Q8: Check Celery task results for repayment-related tasks

**ORM**:
```python
from django_celery_results.models import TaskResult

TaskResult.objects.filter(
    task_name__in=[
        'payment.tasks.sync_repayment_info_for_all_dc',
        'payment.tasks.fetch_and_update_repayments_info',
        'payment.tasks.process_repayment_data',
        'payment.tasks.process_saraloan_repayment_webhook',
        'repayment.tasks.start_repayment_txns',
        'repayment.tasks.correct_repayment_transactions',
        'repayment.tasks.trigger_repayment_created_event',
        'credit_line.tasks.update_credit_lines_status',
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
    'payment.tasks.sync_repayment_info_for_all_dc',
    'payment.tasks.fetch_and_update_repayments_info',
    'payment.tasks.process_repayment_data',
    'payment.tasks.process_saraloan_repayment_webhook',
    'repayment.tasks.start_repayment_txns',
    'repayment.tasks.correct_repayment_transactions',
    'repayment.tasks.trigger_repayment_created_event',
    'credit_line.tasks.update_credit_lines_status'
)
AND task_args LIKE '%{user_id}%'
ORDER BY date_done DESC
LIMIT 50;
```
**Performance**: Uses index on `django_celery_results_taskresult(task_name)`. `LIKE` on `task_args` may be slow — add date filter:
```sql
AND date_done >= NOW() - INTERVAL '7 days'
```

---

### Q9: Check webhook events for repayment notifications

**ORM**:
```python
from external.models import ExternalWebhook

ExternalWebhook.objects.filter(
    data__identifiers__partner_lead_id='{user_id}',
    event__in=['repayment_done', 'repayment_captured', 'repayment_bounced']
).values(
    'id', 'event', 'data', 'created_at'
).order_by('-created_at')[:20]
```

**SQL**:
```sql
SELECT id, event, data, created_at
FROM external_externalwebhook
WHERE data::jsonb -> 'identifiers' ->> 'partner_lead_id' = '{user_id}'
  AND event IN ('repayment_done', 'repayment_captured', 'repayment_bounced')
ORDER BY created_at DESC
LIMIT 20;
```
**Performance**: **Warning** — JSON field query without index. May be slow on large tables. Add date range filter for production:
```sql
AND created_at >= NOW() - INTERVAL '7 days'
```

---

### Q10: Detect orphaned payments (no ledger entry)

**ORM**:
```python
from payment.models import Payment
from ledger.models import LedgerEntry

payments = Payment.objects.filter(
    customer_credit_line__customer__source_identifier_id='{user_id}',
    status='POSTED'
).exclude(
    id__in=LedgerEntry.objects.filter(type='PAYMENT').values_list('locus_id', flat=True)
).values('id', 'lender_payment_id', 'payment_amount', 'payment_date', 'created_at')
```

**SQL**:
```sql
SELECT p.id, p.lender_payment_id, p.payment_amount, p.payment_date, p.created_at
FROM payment_payment p
JOIN credit_line_customercreditline ccl ON p.customer_credit_line_id = ccl.id
JOIN credit_line_customer c ON ccl.customer_id = c.id
LEFT JOIN ledger_ledgerentry le ON le.locus_id = p.id AND le.type = 'PAYMENT'
WHERE c.source_identifier_id = '{user_id}'
  AND p.status = 'POSTED'
  AND le.id IS NULL
ORDER BY p.created_at DESC;
```
**Performance**: Uses indexes on `payment_payment(customer_credit_line_id, status)` and `ledger_ledgerentry(locus_id, type)`. Expected < 50ms.
