## Loan lifecycle flow

**Goal**: Explain how loans are created from invoices, how their state evolves (disbursed, overdue, paid, moved to lender), and how they participate in reconciliation and lender-sharing flows.

This is a deep-dive aimed at developers working on credit, loans, and reconciliation behaviour.

### Overview

At a high level:

1. Invoices are generated and shared from upstream systems (e.g. ERP/Saraloan) into Locus.
2. Locus groups invoice data per customer credit line and creates one or more `Loan` records.
3. Loans progress through an FSM status model (DRAFT → YET_TO_BE_DISBURSED → DISBURSED → PARTIALLY_PAID / OVERDUE / PAID → MOVED_TO_LENDER / CANCELLED, etc.).
4. Invoices and loans are linked for reconciliation.
5. Background jobs periodically share loans to lenders, sync statuses, and adjust or cancel loans when needed.

### Core models and constants

- `loan/model/loans.py::Loan`
  - Fields:
    - `loan_id` – unique id with prefix `LoanConstants.LOAN_PREFIX`.
    - `customer_credit_line` – which credit line this loan belongs to.
    - Multiple financial fields: `loan_amount`, `remaining_amount`, `total_interest`, `remaining_interest`, `total_penal_interest`, `remaining_penal_interest`, etc.
    - Dates: `transaction_date`, `disbursement_date`, `invoice_overdue_date`, `overdue_date`, `interest_free_period_end_date`, etc.
    - Status: `status = FSMField(choices=LoanConstants.LOAN_STATUS_CHOICES, default=LoanConstants.YET_TO_BE_DISBURSED)`.
    - Overdue-credit dates: `origin_overdue_credit_date`, `financier_overdue_credit_date`.
    - ERP integration flags: `erp_payment_upload_status`, interest refund fields, subvention refund fields.
- `loan/constants.py::LoanConstants`
  - Status constants: `DRAFT`, `YET_TO_BE_DISBURSED`, `DISBURSED`, `PARTIALLY_PAID`, `PARTIALLY_REPAID`, `OVERDUE`, `OVERDUE_AND_PARTIALLY_PAID`, `PAID`, `REJECTED`, `CANCELLED`, `MOVED_TO_LENDER`.
  - Creation reasons: `OVER_LIMIT`, `INVOICE_DELETED`, `SHARE_OLDEST_LOAN_TO_LENDER`.
  - Groupings like `POST_DISBURSAL_LOAN_STATUS`, `INACTIVE_LOANS_STATUSES`.
- Mapping and related entities:
  - `loan/model/InvoiceLoanMap` – ties invoices and loans.
  - Lender-facing mapping: `LenderLoanMap` (in `invoice` or `loan` package) is used for lender upload and status sync.

### Status machine (FSM)

The `Loan` model uses `django_fsm` to enforce allowed transitions:

- `update_status_to_yet_to_disbursed`:
  - Source: `DRAFT`
  - Target: `YET_TO_BE_DISBURSED`
- `update_status_to_cancelled`:
  - Source: `CANCELLED`, `DRAFT`, `YET_TO_BE_DISBURSED`
  - Target: `CANCELLED`
- `update_status_to_disbursed`:
  - Source: `YET_TO_BE_DISBURSED`, `DISBURSED`
  - Target: `DISBURSED`
- `update_status_to_rejected`:
  - Source: `REJECTED`, `YET_TO_BE_DISBURSED`
  - Target: `REJECTED`
- `update_loan_status_to_overdue`:
  - Source: `PARTIALLY_PAID`, `DISBURSED`, `OVERDUE`
  - Target: `OVERDUE`
- `update_status_to_partially_paid`:
  - Source: `DISBURSED`, `PARTIALLY_PAID`
  - Target: `PARTIALLY_PAID`
- `update_status_to_paid`:
  - Source: `PAID`, `PARTIALLY_PAID`, `OVERDUE`, `DISBURSED`, `OVERDUE_AND_PARTIALLY_PAID`
  - Target: `PAID`
- `update_status_to_overdue_and_partially_paid`:
  - Source: `DISBURSED`, `PARTIALLY_PAID`, `OVERDUE`, `OVERDUE_AND_PARTIALLY_PAID`
  - Target: `OVERDUE_AND_PARTIALLY_PAID`
- `update_status_to_moved_to_lender`:
  - Source: `OVERDUE`, `YET_TO_BE_DISBURSED`, `DISBURSED`, `MOVED_TO_LENDER`, `PARTIALLY_PAID`
  - Target: `MOVED_TO_LENDER`

Every `Loan.save()` call:
- Assigns a `loan_id` if missing.
- Triggers `capture_and_trigger_event_for_loan_status_change(self.pk, self.status)` for non-new instances (used to emit events on status changes).

### Key entry points

- **HTTP API**:
  - `loan/views.py::LoanViewSet.post`:
    - `POST /loan/` with body containing loan creation payload.
    - Calls `loan.utility.create_loan(request.data)` and returns serialized loans.
- **Tasks and utilities**:
  - `loan/utility.py::create_loan(data)` – main entry for programmatic loan creation.
  - `invoice/tasks.py::create_loan_from_invoice` – scheduled job that creates loans from invoice data.
  - `loan/utility.py::run_reconciliation_for_customer_main` – orchestrates reconciliation by partner/credit line.
  - `invoice/tasks.py` and `loan/tasks.py` – various tasks to:
    - Share loans/invoices to Saraloan.
    - Sync lender statuses (`fetch_and_update_invoice_status_at_lender`, `check_lender_status_and_take_action_on_invoice`).
    - Reconcile and clean up stale loans.

### Step-by-step lifecycle

#### 1. Loan creation from request / invoice

`LoanViewSet.post`:
- Validates incoming payload and delegates to:
  - `create_loan(data=request.data)`

`create_loan` performs:

1. **Validation**:
   - Uses `CreateLoanRequestSerializer` to validate fields.
   - Extracts invoice list and checks:
     - `check_if_loan_exist_for_invoices(invoice_ids)` – prevents duplicate loan creation.
     - `check_if_loan_creation_from_invoice_already_running(invoice_ids)` – prevents concurrent creation for the same invoices.
2. **Breakup generation**:
   - Calls `generate_loan_breakup_for_customer(source_identifier_id, loan_amount)` to split the requested loan amount across invoices and credit lines.
3. **Loan construction**:
   - For each breakup:
     - Computes `_computed_overdue_date` based on:
       - `invoice_overdue_date`
       - Invoice vs delivery date
       - SKU-wise credit day subvention options (`is_sku_wise_credit_day_subvention_enabled`).
     - Builds `new_loan` dict:
       - `customer_credit_line`, `invoiced_amount`, `loan_amount`
       - `transaction_date`
       - `status = LoanConstants.DRAFT`
       - `loan_id` = `LOAN_PREFIX + uuid.node`
       - `origin_overdue_credit_date`, `interest_free_period_end_date`
       - `creation_reason`, `remaining_amount`, optional `comment`.
     - Derives `financier_overdue_credit_date` either from overdue date or from customer-specific overdue credit days.
4. **Persistence**:
   - Validates and saves all loans via `LoanSerializer`.
5. **Invoice mapping**:
   - For each invoice and created loan:
     - Constructs invoice–loan mapping payload with:
       - `invoice_id`, `invoice_internal_id`, `invoice_id_at_lender`,
       - `invoice_amount`, `disbursement_amount`,
       - `invoice_overdue_date`, `delivery_date`,
       - `loan` id and `source`.
   - Saves mappings via `InvLoanMapSerializer`.

Result:
- One or more `Loan` records in `DRAFT` status.
- One or more `InvoiceLoanMap` rows linking invoices to loans.

#### 1.a Prepaid and instant-discount handling

The **effective loan amount** for an invoice can be reduced (or eliminated) by **prepaid amounts** and **credit notes** before any `Loan` is created.

Key places:

- `invoice/models/invoiceline.py` and related models:
  - Store `prepaid_amount` at invoice/invoice-line level.
- `invoice/tasks.py::create_loan_from_invoice`:
  - Computes:
    - `loan_amount = invoice.amount - invoice.prepaid_amount - (sum of credit-note net amounts)`.
  - Uses this to decide whether to create a loan at all and for how much.

Important branches in `create_loan_from_invoice`:

1. **Loan not required (very small net exposure)**:
   - If `0 <= loan_amount < 1`:
     - The invoice net exposure after prepaid and credit notes is less than 1 rupee.
     - The task:
       - Marks the invoice as `LOAN_NOT_REQUIRED`.
       - Optionally adds a comment like “Loan Amount is less than 1, so not creating loan.”
       - Does **not** create a `Loan`.
   - Effect:
     - No loan record exists; future repayments/adjustments are handled via invoices/notes only.

2. **Credit-note-heavy / prepaid scenario (negative loan amount)**:
   - If `loan_amount < 0`:
     - Credit notes plus prepaid amounts exceed the invoice amount.
     - The logic:
       - Iterates over eligible credit notes (`cns`) for the invoice.
       - Allocates `amount_used` per credit note, reducing `cn.amount` by net usage and populating:
         - `cn.amount_used`
         - `cn.prepaid_amount`-adjusted remaining value.
       - If, after allocation, some credit-note balance remains (i.e. still more credit than invoice exposure):
         - Creates payment(s) from the residual credit notes using `CreditNotePaymentSerializer`.
         - Schedules reconciliation for those created payments via:
           - `run_reconciliation_for_customer_main(..., ReconciliationTriggerPoints.CREDIT_NOTE_CREATION)`.
       - Marks the invoice as `LOAN_NOT_REQUIRED`.
   - Effect:
     - The **invoice is fully covered** by prepaid + credit notes.
     - Excess credit is converted into payments and reconciled, without ever creating a loan.

3. **Normal loan creation path**:
   - Only when `loan_amount >= 1`:
     - The task builds the `data` payload and calls `create_loan(data)` as described above.
   - This ensures:
     - Loans are only created for material net exposures after accounting for prepaid amounts and credit notes.

See the credit-note and prepaid sections in `payment_processing.md` for how these credit notes and resulting payments behave during cancellation and reconciliation.

#### 2. Disbursal and status updates

Disbursal flows depend on external systems (Saraloan/ERP); key patterns:

- Loan disbursal events are tied to:
  - `LoanConstants.LOAN_DISBURSEMENT_STATUS_FIELDS_TO_UPDATE` which include:
    - `disbursement_date`, `application_penality_date`,
    - `interest_free_period_end_date`, `status`, `lender_reference_loan_number`,
    - `remaining_principal`, `disbursed_amount`, `disbursal_payment_ref_id`.
- When disbursal information arrives (via uploads or tasks):
  - Status typically transitions from `YET_TO_BE_DISBURSED` → `DISBURSED`.
  - `disbursed_amount` and dates are filled from lender data.
  - `lender_reference_loan_number` is populated.

Some of this logic lives in utility functions and tasks that parse upload files and call the FSM transitions or direct field updates.

#### 3. Repayment and reconciliation

Repayment is primarily driven by `Payment` records:

- `Payment` model (in `payment/model/payment.py`) includes:
  - `payment_amount`, `reconcilable_amount`, `payment_amount_settled`,
  - `status` (FSM-based) and `sub_status` (`UNRECONCILED`, `PARTIALLY_RECONCILED`, `RECONCILED`, etc.).
- When a payment is created and moved to `POSTED`:
  - Reconciliation logic is triggered from:
    - `loan/utility.run_reconciliation_for_customer_main(partner_id, trigger_point)`.
  - That utility:
    - Evaluates outstanding loans and payments for a customer credit line.
    - Allocates `reconcilable_amount` across loans, updating:
      - `Loan.remaining_amount`
      - Loan `status`:
        - If `remaining_amount == 0` → `PAID`.
        - If `0 < remaining_amount < loan_amount` → `PARTIALLY_PAID`.
        - If overdue and partially paid → `OVERDUE_AND_PARTIALLY_PAID`.
    - Creates reconciliation entries linking loans and payments (often via `ReconciliationEntry` models).

When reconciliation needs to be reversed (e.g. cancellations):

- `payment/utils.py::unrecon_payment_and_adjust_with_debit_entry`:
  - Uses `perform_unreconciliation_during_cancellation` to undo reconciliation entries.
  - Calls `create_debit_entry_for_cancelled_payment` to record adjustments.
  - Reconciles new debit notes with the previously reconciled payment.
- `payment/utils.py::unreconcile_oustanding_entity`:
  - For outstanding entities of type `GAPL_LOAN`, it:
    - Increases `Loan.remaining_amount` by the amount previously reconciled.
    - Updates loan `status` back to `DISBURSED` or `PARTIALLY_PAID` based on new `remaining_amount`.

#### 4. Movement to lender and external systems

Loans can be moved or shared to external lenders (e.g. Saraloan).

Key elements:

- `LoanConstants.MOVED_TO_LENDER` – terminal status once responsibility has shifted.
- Lender-side tracking via:
  - `LenderLoanMap` – tracks invoice upload and status at lender.
  - Status fields like `invoice_upload_status`, `invoice_status_at_lender`.
- Periodic tasks:
  - `invoice/tasks.py::fetch_and_update_invoice_status_at_lender`:
    - Schedules per-invoice calls to `sync_invoice_status_from_saraloan`.
  - `invoice/tasks.py::check_lender_status_and_take_action_on_invoice`:
    - Checks lender decisions (e.g. pending too long).
    - May:
      - Reshare invoices (`share_oldest_loan_to_lender`).
      - Or cancel invoices/loans if they are too old or rejected.

When moved to lender:

- Tasks update:
  - `Loan.status` → `MOVED_TO_LENDER`.
  - `LenderLoanMap.invoice_upload_status` etc.
- Downstream:
  - Payment and reconciliation logic treats moved loans differently (e.g. using different triggers and mappings).

Note: The beat schedule includes `loan.tasks.move_gapl_loan_to_lender`, but in code this task is marked `@deprecated` in favour of newer sharing utilities (for example, `share_oldest_loan_to_lender_for_all_partners`). When reading scheduled tasks, treat `move_gapl_loan_to_lender` as a legacy entry; the effective behaviour for moving exposure from internal (GAPL) credit lines to lenders is implemented via the newer share-to-lender flows.

#### 5. Cancellation and clean-up

Loans can be cancelled for multiple reasons:

- `LoanConstants.INVOICE_DELETED` or `LoanConstants.OVER_LIMIT` as `creation_reason`.
- Cancellation flows are usually triggered by:
  - Invoice cancellation (`InvoiceCancelView` → `cancel_loan(data)`).
  - Lender-side status changes.

Typical cancellation behaviour:

- `cancel_loan`:
  - Identifies the loan and related invoice mappings.
  - If already reconciled, it may:
    - Trigger unreconciliation.
    - Adjust payments and create debit notes via payment utilities.
  - Updates `Loan.status` → `CANCELLED` and possibly resets mapping statuses.

### Mermaid diagram (high-level)

```mermaid
flowchart TD
    inv[\"Invoices imported\"] --> breakup[Generate loan breakup]
    breakup --> createLoan[Create Loan records (DRAFT)]
    createLoan --> status1[YET_TO_BE_DISBURSED]
    status1 --> disbursal[Disbursal event from lender/ERP]
    disbursal --> status2[DISBURSED]

    status2 --> repay[Repayments (Payments POSTED)]
    repay --> recon[Reconciliation engine]
    recon -->|full| paid[PAID]
    recon -->|partial| partPaid[PARTIALLY_PAID / OVERDUE & partially paid]

    status2 --> overdue[Overdue thresholds crossed]
    overdue --> odStatus[OVERDUE]

    status2 --> moveLender[Move to lender / share]
    moveLender --> moved[MOVED_TO_LENDER]

    status1 --> cancel[Cancellation (e.g. invoice deleted)]
    status2 --> cancel
    cancel --> cancelled[CANCELLED]
```

### Where to read next

- For how repayments are created and reconciled in detail, see `payment_processing.md`.
- For how lender status and invoice uploads are handled, see the invoice tasks and lender-mapping docs (once created).

