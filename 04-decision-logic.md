# Decision Logic Documentation

> For each user flow, this document lists all conditional branches in execution order.
> Each branch specifies the condition expression, runtime data fields, file path and line number, and behavior for each outcome.
> Cross-references: [Runtime Data](03-runtime-data.md) | [User Flows](02-user-flows/)

---

## Table of Contents

1. [Credit Eligibility Check](#1-credit-eligibility-check)
2. [Operational Limit Calculation](#2-operational-limit-calculation)
3. [Loan Status Transitions (FSM)](#3-loan-status-transitions-fsm)
4. [Lender Onboarding / Deboarding](#4-lender-onboarding--deboarding)
5. [Disbursal Processing (Full vs Partial)](#5-disbursal-processing-full-vs-partial)
6. [Payment Reconciliation](#6-payment-reconciliation)
7. [External Lender Support](#7-external-lender-support)
8. [Aged Outstanding Status](#8-aged-outstanding-status)
9. [Repayment Frequency Status](#9-repayment-frequency-status)
10. [Payment Validation & Status Transitions](#10-payment-validation--status-transitions)
11. [Loan Sharing to Lender](#11-loan-sharing-to-lender)

---

## 1. Credit Eligibility Check

**Flow**: [Credit Eligibility](02-user-flows/credit-eligibility.md)

### Branch 1.1: `is_credit_allowed` field check

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/model/customer.py` |
| **Line** | 87 |
| **Condition** | `Customer.is_credit_allowed` (BooleanField, default `True`) |
| **Runtime Data** | `credit_line_customer.is_credit_allowed` |
| **True** | Customer proceeds to credit line status checks |
| **False** | Customer is blocked from all credit operations |

### Branch 1.2: Credit line status check

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/model/customer_credit_line.py` |
| **Line** | 130 |
| **Condition** | `CustomerCreditLine.status` in `("ACTIVE", "ONHOLD", "DORMANT")` |
| **Runtime Data** | `credit_line_customercreditline.status`, `credit_line_customercreditline.sub_status` |
| **ACTIVE** | Credit line is fully operational; sub_status must be `ACTIVE` |
| **ONHOLD** | Credit line is restricted; sub_status is one of `ONBOARDING POD`, `AGED OUTSTANDING`, `REPAYMENT FREQUENCY`, `MISCELLANEOUS` |
| **DORMANT** | Credit line is closed/inactive; sub_status is one of `OUTSTANDING REMAINING`, `CLOSED` |

### Branch 1.3: Lender status override on save

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/model/customer_credit_line.py` |
| **Line** | 306–312 |
| **Condition** | `self.lender_status == CreditLineLenderStatus.OVERDUE and not self.business_override` |
| **Runtime Data** | `credit_line_customercreditline.lender_status`, `credit_line_customercreditline.business_override` |
| **True** | Forces `status = ONHOLD`, `sub_status = AGED OUTSTANDING` |
| **False** | Status remains as set by caller |

---

## 2. Operational Limit Calculation

**Flow**: [Credit Limit Calculation](02-user-flows/credit-limit-calculation.md)

### Branch 2.1: Null operational limit initialization

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/signals.py` |
| **Line** | 15–16 |
| **Condition** | `instance.operational_limit is None` |
| **Runtime Data** | `credit_line_customercreditline.operational_limit`, `credit_line_customercreditline.credit_limit` |
| **True** | Sets `operational_limit = float(credit_limit)` |
| **False** | Keeps existing `operational_limit` value |

### Branch 2.2: Operational limit cap

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/signals.py` |
| **Line** | 17–19 |
| **Condition** | `operational_limit > credit_limit` (implicit via `min()`) |
| **Runtime Data** | `credit_line_customercreditline.operational_limit`, `credit_line_customercreditline.credit_limit` |
| **True (op_limit > credit_limit)** | `operational_limit` is capped to `credit_limit` |
| **False (op_limit <= credit_limit)** | `operational_limit` remains unchanged |

> **Signal trigger**: `update_operational_limit` is a `pre_save` receiver on `CustomerCreditLine` (line 41–42). Fires on every save of a `CustomerCreditLine` instance.

### Branch 2.3: Principal outstanding override for specific products

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/signals.py` |
| **Line** | 80–87 |
| **Condition** | `instance.credit_product.credit_product_name in [CreditProductNames.ME_ADANI_CAPITAL, CreditProductNames.ME_PROGCAP]` |
| **Runtime Data** | `credit_line_creditproduct.credit_product_name`, `credit_line_customercreditline.credit_limit`, `credit_line_customercreditline.lender_available_credit_limit` |
| **True** | Sets `principal_outstanding = credit_limit - lender_available_credit_limit` |
| **False** | `principal_outstanding` is not recalculated on save |

---

## 3. Loan Status Transitions (FSM)

**Flow**: [Approval Workflow](02-user-flows/approval-workflow.md)

The `Loan.status` field is a `django_fsm.FSMField`. Each transition method enforces valid source states.

### Transition 3.1: `DRAFT` → `YET_TO_BE_DISBURSED`

| Attribute | Value |
|-----------|-------|
| **File** | `loan/model/loans.py` |
| **Line** | 281–287 |
| **Method** | `update_status_to_yet_to_disbursed()` |
| **Source** | `DRAFT` |
| **Target** | `YET_TO_BE_DISBURSED` |
| **Runtime Data** | `loan_loan.status` |

### Transition 3.2: → `CANCELLED`

| Attribute | Value |
|-----------|-------|
| **File** | `loan/model/loans.py` |
| **Line** | 291–300 |
| **Method** | `update_status_to_cancelled()` |
| **Source** | `CANCELLED`, `DRAFT`, `YET_TO_BE_DISBURSED` |
| **Target** | `CANCELLED` |

### Transition 3.3: → `DISBURSED`

| Attribute | Value |
|-----------|-------|
| **File** | `loan/model/loans.py` |
| **Line** | 304–309 |
| **Method** | `update_status_to_disbursed()` |
| **Source** | `YET_TO_BE_DISBURSED`, `DISBURSED` |
| **Target** | `DISBURSED` |

### Transition 3.4: → `REJECTED`

| Attribute | Value |
|-----------|-------|
| **File** | `loan/model/loans.py` |
| **Line** | 313–318 |
| **Method** | `update_status_to_rejected()` |
| **Source** | `REJECTED`, `YET_TO_BE_DISBURSED` |
| **Target** | `REJECTED` |

### Transition 3.5: → `OVERDUE`

| Attribute | Value |
|-----------|-------|
| **File** | `loan/model/loans.py` |
| **Line** | 322–331 |
| **Method** | `update_loan_status_to_overdue()` |
| **Source** | `PARTIALLY_PAID`, `DISBURSED`, `OVERDUE` |
| **Target** | `OVERDUE` |

### Transition 3.6: → `PARTIALLY_PAID`

| Attribute | Value |
|-----------|-------|
| **File** | `loan/model/loans.py` |
| **Line** | 335–343 |
| **Method** | `update_status_to_partially_paid()` |
| **Source** | `DISBURSED`, `PARTIALLY_PAID` |
| **Target** | `PARTIALLY_PAID` |

### Transition 3.7: → `PAID`

| Attribute | Value |
|-----------|-------|
| **File** | `loan/model/loans.py` |
| **Line** | 347–358 |
| **Method** | `update_status_to_paid()` |
| **Source** | `PAID`, `PARTIALLY_PAID`, `OVERDUE`, `DISBURSED`, `OVERDUE_AND_PARTIALLY_PAID` |
| **Target** | `PAID` |

### Transition 3.8: → `OVERDUE_AND_PARTIALLY_PAID`

| Attribute | Value |
|-----------|-------|
| **File** | `loan/model/loans.py` |
| **Line** | 362–372 |
| **Method** | `update_status_to_overdue_and_partially_paid()` |
| **Source** | `DISBURSED`, `PARTIALLY_PAID`, `OVERDUE`, `OVERDUE_AND_PARTIALLY_PAID` |
| **Target** | `OVERDUE_AND_PARTIALLY_PAID` |

### Transition 3.9: → `MOVED_TO_LENDER`

| Attribute | Value |
|-----------|-------|
| **File** | `loan/model/loans.py` |
| **Line** | 376–387 |
| **Method** | `update_status_to_moved_to_lender()` |
| **Source** | `OVERDUE`, `YET_TO_BE_DISBURSED`, `DISBURSED`, `MOVED_TO_LENDER`, `PARTIALLY_PAID` |
| **Target** | `MOVED_TO_LENDER` |

### FSM State Diagram

```
DRAFT → YET_TO_BE_DISBURSED → DISBURSED → PARTIALLY_PAID → PAID
                  ↓                ↓              ↓            ↑
              CANCELLED        OVERDUE    OVERDUE_AND_PP ──────┘
                  ↑                ↓              ↑
              REJECTED      PARTIALLY_PAID ───────┘
                                   ↓
                            MOVED_TO_LENDER
```

### Branch 3.10: Post-disbursal status override

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 1553–1556 |
| **Condition** | `status in LoanConstants.POST_DISBURSAL_LOAN_STATUS and loan.status in LoanConstants.PRE_DISBURSAL_LOAN_STATUS` |
| **Runtime Data** | `loan_loan.status`, incoming `status` from lender webhook |
| **True** | Stores final status as `next_status`, temporarily sets `status = DISBURSED` (two-step transition) |
| **False** | Uses incoming status directly |

> `POST_DISBURSAL_LOAN_STATUS` = `[PAID, PARTIALLY_PAID, OVERDUE_AND_PARTIALLY_PAID]`
> `PRE_DISBURSAL_LOAN_STATUS` = `[YET_TO_BE_DISBURSED]`

---

## 4. Lender Onboarding / Deboarding

**Flow**: [Credit Eligibility](02-user-flows/credit-eligibility.md)

### Branch 4.1: FSM guard — allow onboarding/deboarding

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/model/customer.py` |
| **Line** | 194–197 |
| **Condition** | `self.customer_type.name == CustomerTypeConstant.FARMER` |
| **Runtime Data** | `credit_line_customertype.name` |
| **True (FARMER)** | Returns `False` — blocks FSM transition |
| **False (DC)** | Returns `True` — allows FSM transition |

### Branch 4.2: Sync onboarding status with ELS — auto-complete onboarding

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/model/customer.py` |
| **Line** | 140–159 |
| **Condition** | `lender_supported_status == LENDER_ONBOARDING_INITIATED and initial_lender_supported_status != LENDER_ONBOARDING_INITIATED and external_lender_supported` |
| **Runtime Data** | `credit_line_customer.lender_supported_status`, `credit_line_customer.external_lender_supported` |
| **True** | Auto-transitions to `ONBOARDING_COMPLETED` |
| **False** | No auto-transition |

### Branch 4.3: Sync onboarding status with ELS — auto-complete deboarding

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/model/customer.py` |
| **Line** | 152–159 |
| **Condition** | `lender_supported_status == LENDER_DEBOARDING_INITIATED and initial_lender_supported_status != LENDER_DEBOARDING_INITIATED and not external_lender_supported` |
| **Runtime Data** | `credit_line_customer.lender_supported_status`, `credit_line_customer.external_lender_supported` |
| **True** | Auto-transitions to `DEBOARDING_COMPLETED` |
| **False** | No auto-transition |

### Branch 4.4: Trigger deboarding checks

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/model/customer.py` |
| **Line** | 160–175 |
| **Condition** | `customer_type.name == DC and lender_supported_status == LENDER_DEBOARDING_INITIATED and initial_lender_supported_status != LENDER_DEBOARDING_INITIATED and external_lender_supported` |
| **Runtime Data** | `credit_line_customer.lender_supported_status`, `credit_line_customer.external_lender_supported`, `credit_line_customertype.name` |
| **True** | Fires `perform_lender_onboarding_deboarding_checks` Celery task with `onboarding=False` |
| **False** | Falls through to onboarding check |

### Branch 4.5: Trigger onboarding checks

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/model/customer.py` |
| **Line** | 176–183 |
| **Condition** | `customer_type.name == DC and lender_supported_status == LENDER_ONBOARDING_INITIATED and initial_lender_supported_status != LENDER_ONBOARDING_INITIATED and not external_lender_supported` |
| **Runtime Data** | `credit_line_customer.lender_supported_status`, `credit_line_customer.external_lender_supported`, `credit_line_customertype.name` |
| **True** | Fires `perform_lender_onboarding_deboarding_checks` Celery task with `onboarding=True` |
| **False** | No task fired |

### FSM Transitions for `lender_supported_status`

| Method | Source States | Target |
|--------|-------------|--------|
| `initiate_lender_deboarding()` | `None`, `ONBOARDING_COMPLETED`, `DEBOARDING_FAILED` | `LENDER_DEBOARDING_INITIATED` |
| `initiate_lender_onboarding()` | `None`, `DEBOARDING_COMPLETED`, `ONBOARDING_FAILED` | `LENDER_ONBOARDING_INITIATED` |

---

## 5. Disbursal Processing (Full vs Partial)

**Flow**: [Approval Workflow](02-user-flows/approval-workflow.md)

### Branch 5.1: Partial vs full disbursal determination

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 1563–1568 |
| **Condition** | `Decimal(invoice_requested_amount) > Decimal(disbursement_amount)` |
| **Runtime Data** | `loan_loan.loan_amount` (as `invoice_requested_amount`), `disbursement_amount` from lender webhook |
| **True** | `is_partial_disbursement = True` → partial disbursal path |
| **False** | `is_partial_disbursement = False` → full disbursal path |

### Branch 5.2: Redis lock check

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 1569–1576 |
| **Condition** | `check_or_add_redis_cache_common(BLACKSOIL_DISBURSAL, lender_loan_id, ...)` returns `True` |
| **Runtime Data** | Redis cache key `LOCK_{BLACKSOIL_DISBURSAL}_{lender_loan_id}` |
| **True (lock exists)** | Returns early — duplicate disbursal prevented |
| **False (no lock)** | Proceeds with disbursal processing |

### Branch 5.3: Partial disbursal — customer type check

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 1582–1590 |
| **Condition** | `vals["customer_type"] != CustomerType.DC` |
| **Runtime Data** | `credit_line_customertype.name` |
| **True (non-DC, e.g. FARMER)** | Returns `False` — partial disbursal not supported for farmers |
| **False (DC)** | Proceeds with partial disbursal: rejects original loan, creates new loan with disbursed amount |

### Branch 5.4: Partial disbursal — DC path

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 1591–1640 |
| **Condition** | Customer is DC and `is_partial_disbursement` is `True` |
| **Runtime Data** | `loan_loan.loan_amount`, `disbursement_amount`, `loan_loan.loan_id` |
| **Behavior** | 1. Sends email notification. 2. Calls `reject_loan()` on original loan. 3. Creates new loan via `create_loan_and_invoiceloanmap()` with disbursed amount. 4. Calls `process_partial_disbursal()` to create remaining-amount loan entry. |

### Branch 5.5: Full disbursal path

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 1643–1650 |
| **Condition** | `is_partial_disbursement` is `False` |
| **Runtime Data** | `loan_loan.loan_id`, webhook `vals` |
| **Behavior** | Calls `process_full_disbursal()` → `update_loan()` → `update_gapl_loan()` |

### `process_full_disbursal` (line 1683)

Updates the loan object with lender data and marks associated GAPL loans as `DISBURSED`.

### `process_partial_disbursal` (line 1824)

Creates a new `InvoiceLoanMap` entry for the remaining undisbursed amount via `update_or_create_loan_invoice_for_partial_disbursal()`.

---

## 6. Payment Reconciliation

**Flow**: [Repayment Workflow](02-user-flows/repayment-workflow.md)

### Branch 6.1: GAPL credit line existence

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2135–2141 |
| **Condition** | `CustomerCreditLine.objects.filter(customer__source_identifier_id=partner_id, credit_product__belongs_to_gapl=True).first()` is `None` |
| **Runtime Data** | `credit_line_customercreditline.credit_product__belongs_to_gapl` |
| **True (no GAPL line)** | Skip this customer — `continue` |
| **False (GAPL line exists)** | Proceed to payment check |

### Branch 6.2: GAPL posted payments with reconcilable amount

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2143–2150 |
| **Condition** | `gapl_credit_line.payments.filter(status=POSTED, sub_status__in=[UNRECONCILED, PARTIALLY_RECONCILED], reconcilable_amount__gt=0).exists()` |
| **Runtime Data** | `payment_payment.status`, `payment_payment.sub_status`, `payment_payment.reconcilable_amount` |
| **True** | Proceed to loan/debit note check |
| **False (no eligible payments)** | Skip this customer — `continue` |

### Branch 6.3: GAPL loans eligible for reconciliation

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2153–2155 |
| **Condition** | `gapl_credit_line.loans.filter(status__in=[DISBURSED, PARTIALLY_PAID]).exists()` |
| **Runtime Data** | `loan_loan.status` |
| **True** | Customer is eligible — added to `eligible_partner_ids` |
| **False** | Falls through to debit note check |

### Branch 6.4: GAPL debit notes eligible for reconciliation

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2157–2162 |
| **Condition** | `gapl_credit_line.debit_notes.filter(status=POSTED, sub_status__in=[UNRECONCILED, PARTIALLY_RECONCILED]).exists()` |
| **Runtime Data** | Debit note `status`, `sub_status` |
| **True** | Customer is eligible — added to `eligible_partner_ids` |
| **False** | Falls through to external lender check |

### Branch 6.5: External lender supported — advance transfer check

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2164–2176 |
| **Condition** | `external_lender_supported and lender_credit_line exists and lender_credit_line.credit_product.advance_transfer and gapl_payments` |
| **Runtime Data** | `credit_line_customer.external_lender_supported`, `credit_line_creditproduct.advance_transfer` |
| **True** | Customer is eligible — added to `eligible_partner_ids` |
| **False** | Customer is skipped |

### Reconciliation Dispatch

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2178–2182 |
| **Behavior** | For each `eligible_partner_id`, fires `run_reconciliation_for_customer_main.apply_async((partner_id, trigger_point))` |

---

## 7. External Lender Support

**Flow**: [Credit Eligibility](02-user-flows/credit-eligibility.md)

### Branch 7.1: BlackSoil credit product — dormancy check

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2797–2802 |
| **Condition** | `credit_product.credit_product_name == CreditProductNames.ME_BLACKSOIL` |
| **Runtime Data** | `credit_line_creditproduct.credit_product_name` |
| **True** | Enters BlackSoil-specific loan account status determination |
| **False** | Uses simple dormancy check: `DORMANT` → `CLOSED`, else `OPEN` |

### Branch 7.2: BlackSoil dormancy override

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2799–2801 |
| **Condition** | `dormancy_check_for_blacksoil and credit_line.status != CreditLineStatus.DORMANT` |
| **Runtime Data** | `credit_line_customercreditline.status`, `dormancy_check_for_blacksoil` flag |
| **True** | Sets `loan_account_status = OPEN` (skip Saraloan API call) |
| **False** | Proceeds to Saraloan API check |

### Branch 7.3: CustomerLenderMap / Saraloan business details

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2803–2830 |
| **Condition** | `customer_lender_map exists and customer_lender_map.business_id` |
| **Runtime Data** | `credit_line_customerlendermap.business_id` |
| **True** | Calls `Saraloan.get_business_details()` → checks `credit_line.loan_closure_letter_file` |
| **False (no business_id)** | Sets `loan_account_status = CLOSED` |

### Branch 7.4: Loan closure letter check

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2825–2829 |
| **Condition** | `business_details["credit_line"]["loan_closure_letter_file"]` is truthy |
| **Runtime Data** | Saraloan API response |
| **True** | `loan_account_status = CLOSED` |
| **False** | `loan_account_status = OPEN` |

### Branch 7.5: Non-BlackSoil dormancy check

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2831–2835 |
| **Condition** | `credit_line.status == CreditLineStatus.DORMANT` |
| **Runtime Data** | `credit_line_customercreditline.status` |
| **True** | `loan_account_status = CLOSED` |
| **False** | `loan_account_status = OPEN` |

### Branch 7.6: Update flag — onboarding/deboarding decision

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2862–2873 |
| **Condition** | `update_flag and credit_line.id not in closed_lender_credit_lines_id_of_partner and credit_line.status != DORMANT` |
| **Runtime Data** | `credit_line_customer.external_lender_supported`, closed credit line IDs |
| **True (at least one open lender line)** | If `not customer.external_lender_supported` → calls `initiate_lender_onboarding()` |
| **False (all lender lines closed)** | If `customer.external_lender_supported` → calls `initiate_lender_deboarding()` |

### Branch 7.7: Cancel YTD loans on closed BlackSoil line

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 2838–2856 |
| **Condition** | `loan_account_status == CLOSED and credit_product == ME_BLACKSOIL` |
| **Runtime Data** | `loan_lenderloanmap.invoice_status_at_lender`, `loan_loan.status` |
| **True** | Syncs and cancels YTD undisbursed loans via `sync_and_cancel_ytd_undisbursed_loans_saraloan()`, then cancels unshared YTD loans via `cancel_loans_and_create_on_gapl_line()` |
| **False (non-BlackSoil closed)** | Cancels all YTD loans on that credit line via `cancel_loans_and_create_on_gapl_line()` |

---

## 8. Aged Outstanding Status

**Flow**: [Risk Evaluation](02-user-flows/risk-evaluation.md)

### Branch 8.1: Credit line eligible for aged outstanding check

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2509–2517 |
| **Condition** | `credit_line.status in [ACTIVE, ONHOLD] and credit_line.sub_status in [ACTIVE, REPAYMENT_FREQUENCY, AGED_OUTSTANDING, MISCELLANEOUS, ONBOARDING_POD]` |
| **Runtime Data** | `credit_line_customercreditline.status`, `credit_line_customercreditline.sub_status` |
| **True** | Proceeds to overdue threshold evaluation |
| **False** | Skips this credit line |

### Branch 8.2: Overdue threshold breached — put on hold

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2523–2528 |
| **Condition** | `total_overdue_amount - overdue_credit_limit > overdue_threshold_limit and not credit_line.business_override` |
| **Runtime Data** | `total_overdue_amount` (calculated), `credit_line_customer.overdue_credit_limit`, `credit_line_customer.overdue_threshold_limit`, `credit_line_customercreditline.business_override` |
| **True** | Sets `status = ONHOLD`, `sub_status = AGED OUTSTANDING` |
| **False** | Falls through to recovery check |

### Branch 8.3: Overdue threshold recovered — reactivate

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2530–2539 |
| **Condition** | `total_overdue_amount - overdue_credit_limit <= overdue_threshold_limit and not business_override and sub_status == AGED_OUTSTANDING` |
| **Runtime Data** | Same as 8.2 |
| **True** | Sets `status = ACTIVE`, `sub_status = ACTIVE` |
| **False** | No status change |

### Branch 8.4: Transition from onboarding pod

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2540–2545 |
| **Condition** | `credit_line.transition_from_onboarding_pod` (during recovery from aged outstanding) |
| **Runtime Data** | `credit_line_customercreditline.transition_from_onboarding_pod` |
| **True** | Reverts to `ONHOLD / ONBOARDING POD` instead of `ACTIVE / ACTIVE`; fires `send_update_aged_outstanding_to_onboarding_pod` task |
| **False** | Stays at `ACTIVE / ACTIVE` |

### Branch 8.5: Business override guard

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2551–2552 |
| **Condition** | `not credit_line.business_override` |
| **Runtime Data** | `credit_line_customercreditline.business_override` |
| **True** | Saves the credit line (status changes applied) |
| **False** | Skips save — business override prevents automated status changes |

---

## 9. Repayment Frequency Status

**Flow**: [Risk Evaluation](02-user-flows/risk-evaluation.md)

### Branch 9.1: Repayment parameters from lender credit product

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2571–2585 |
| **Condition** | `not credit_line.credit_product.belongs_to_gapl` |
| **Runtime Data** | `credit_line_creditproduct.belongs_to_gapl`, `credit_line_creditproduct.repayment_duration`, `credit_line_creditproduct.repayment_frequency_outstanding_cutoff`, `credit_line_creditproduct.repayment_frequency_ratio` |
| **True (lender product)** | Extracts `repayment_duration`, `repayment_frequency_outstanding_cutoff`, `repayment_frequency_ratio` from credit product |
| **False (GAPL product)** | Skips — parameters come from lender credit product only |

### Branch 9.2: Outstanding exceeds cutoff — calculate unblock amount

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2596–2602 |
| **Condition** | `net_outstanding_on_last_repayment_date and net_outstanding_on_last_repayment_date > repayment_frequency_outstanding_cutoff` |
| **Runtime Data** | `net_outstanding_on_last_repayment_date` (calculated), `repayment_frequency_outstanding_cutoff` (from credit product) |
| **True** | `repayment_unblock_amount = (outstanding * ratio) - payments_after_date` |
| **False** | `repayment_unblock_amount = 0` |

### Branch 9.3: Credit line eligible for repayment frequency check

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2605–2611 |
| **Condition** | `credit_line.status in [ACTIVE, ONHOLD] and credit_line.sub_status in [ACTIVE, REPAYMENT_FREQUENCY]` |
| **Runtime Data** | `credit_line_customercreditline.status`, `credit_line_customercreditline.sub_status` |
| **True** | Proceeds to repayment frequency evaluation |
| **False** | Skips this credit line |

### Branch 9.4: Repayment frequency breached — put on hold

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2615–2617 |
| **Condition** | `not business_override and repayment_unblock_amount > 1` |
| **Runtime Data** | `credit_line_customercreditline.business_override`, `repayment_unblock_amount` (calculated) |
| **True** | Sets `status = ONHOLD`, `sub_status = REPAYMENT FREQUENCY` |
| **False** | Falls through to recovery check |

### Branch 9.5: Repayment frequency recovered — reactivate

| Attribute | Value |
|-----------|-------|
| **File** | `credit_line/tasks.py` |
| **Line** | 2618–2622 |
| **Condition** | `not business_override and sub_status == REPAYMENT_FREQUENCY and repayment_unblock_amount <= 1` |
| **Runtime Data** | Same as 9.4 |
| **True** | Sets `status = ACTIVE`, `sub_status = ACTIVE` |
| **False** | No status change |

---

## 10. Payment Validation & Status Transitions

**Flow**: [Repayment Workflow](02-user-flows/repayment-workflow.md)

### Branch 10.1: Event-based vs pull-based status resolution

| Attribute | Value |
|-----------|-------|
| **File** | `payment/utils.py` |
| **Line** | 365–376 |
| **Condition** | `event` parameter is provided |
| **Runtime Data** | `event` parameter, `data["status"]` |
| **True (event provided)** | `status = REPAYMENT_STATUS_MAP[event]` |
| **False (no event)** | Checks `data["status"]` against `PULL_REPAYMENT_STATUS_MAP`; if not found, returns `None` |

### Branch 10.2: Unrealized payment — PG mode only

| Attribute | Value |
|-----------|-------|
| **File** | `payment/utils.py` |
| **Line** | 378–379 |
| **Condition** | `status == PaymentStatus.UNREALIZED and data["payment_mode"].lower() != "pg"` |
| **Runtime Data** | Resolved `status`, `data["payment_mode"]` |
| **True** | Returns `None` — unrealized status only valid for PG payments |
| **False** | Proceeds with payment processing |

### Branch 10.3: Full refund — cancel payment

| Attribute | Value |
|-----------|-------|
| **File** | `payment/utils.py` |
| **Line** | 413–416 |
| **Condition** | `data["payment_amount"] == data["refund_amount"]` |
| **Runtime Data** | `data["payment_amount"]`, `data["refund_amount"]` |
| **True** | Sets `status = CANCELLED`, `sub_status = REFUNDED` |
| **False** | Proceeds with partial refund or normal processing |

### Branch 10.4: Partial refund — reduce payment amount

| Attribute | Value |
|-----------|-------|
| **File** | `payment/utils.py` |
| **Line** | 417–420 |
| **Condition** | `data["refund_amount"] > 0 and data["payment_amount"] > data["refund_amount"]` |
| **Runtime Data** | `data["payment_amount"]`, `data["refund_amount"]` |
| **True** | `payment_amount = payment_amount - refund_amount` |
| **False** | `payment_amount` unchanged |

### Branch 10.5: Existing payment — status transition validation

| Attribute | Value |
|-----------|-------|
| **File** | `payment/utils.py` |
| **Line** | 422–436 |
| **Condition** | `payment_obj.exists()` (matching `lender_payment_id` + `customer_credit_line_id`) |
| **Runtime Data** | `payment_payment.lender_payment_id`, `payment_payment.customer_credit_line_id` |
| **True** | Validates transition via `is_lender_payment_status_transition_valid()` |
| **False** | Creates new payment |

### Branch 10.6: Lender payment status transition validation

| Attribute | Value |
|-----------|-------|
| **File** | `payment/utils.py` |
| **Line** | 339–348 |
| **Condition** | `(payment_obj.status == CANCELLED and new_status == POSTED) or (payment_obj.status == POSTED and new_status == UNREALIZED)` |
| **Runtime Data** | `payment_payment.status`, incoming `new_status` |
| **True (invalid transition)** | Returns `False` — sends invalid transition email, returns `None` |
| **False (valid transition)** | Returns `True` — proceeds with update |

> **Invalid transitions**: `CANCELLED → POSTED` and `POSTED → UNREALIZED`

### Branch 10.7: Existing payment — update conditions

| Attribute | Value |
|-----------|-------|
| **File** | `payment/utils.py` |
| **Line** | 447–458 |
| **Condition** | Any of: `lender_payment_ref_number` changed, `payment_amount_settled` changed, `payment_amount` changed, `payment_transfer_number` changed, `status` changed, `settlement_date` changed, `refund_utr` changed |
| **Runtime Data** | Multiple `payment_payment` fields compared to incoming `data` |
| **True** | Updates payment object and saves |
| **False** | Falls through to `lender_updated_at` comparison |

### Branch 10.8: Backdated notification check

| Attribute | Value |
|-----------|-------|
| **File** | `payment/utils.py` |
| **Line** | 478–500 |
| **Condition** | `data["lender_updated_at"] and payment_object.lender_updated_at and payment_object.lender_updated_at < data["lender_updated_at"]` |
| **Runtime Data** | `payment_payment.lender_updated_at`, incoming `data["lender_updated_at"]` |
| **True (newer notification)** | If `status == repayment_bounced` → updates status and cancels ledger entry; otherwise ignores |
| **False (backdated)** | Ignores notification entirely |

### Branch 10.9: New payment — farmer unrealized payment matching

| Attribute | Value |
|-----------|-------|
| **File** | `payment/utils.py` |
| **Line** | 516–520 |
| **Condition** | `for_farmer and status == PaymentStatus.POSTED` |
| **Runtime Data** | `for_farmer` flag, resolved `status` |
| **True** | Calls `validate_and_update_existing_unrealized_payment()` — if match found, updates existing instead of creating new |
| **False** | Creates new payment via `Payment.objects.create()` |

---

## 11. Loan Sharing to Lender

**Flow**: [Approval Workflow](02-user-flows/approval-workflow.md)

### Branch 11.1: Sharing restriction / Redis lock

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 1678–1679 |
| **Condition** | `is_invoice_share_restricted(partner_id) or check_or_add_redis_cache(partner_id)` |
| **Runtime Data** | App constant config, Redis cache |
| **True** | Returns early — process already running or restricted |
| **False** | Proceeds with loan sharing |

### Branch 11.2: Lender credit line resolution (with override)

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 1697–1730 |
| **Condition** | `override` flag (from `use_min_adv_avl_override(partner_id)`) |
| **Runtime Data** | `credit_line_customer.external_lender_supported`, `credit_line_customercreditline.status`, `credit_line_customercreditline.lender_advance_payment` |
| **True (override)** | Simplified filter: DC + external_lender_supported only |
| **False (no override)** | Complex filter: FARMER with ACTIVE/ONHOLD, or DC with external_lender_supported and (ONHOLD + advance_payment > 0, or ACTIVE) |

### Branch 11.3: No lender credit line found

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 1731–1735 |
| **Condition** | `not lender_line` |
| **Runtime Data** | Query result |
| **True** | Returns "There is no active lender credit line" |
| **False** | Proceeds to find oldest sharable loan |

### Branch 11.4: Usable lender limit below minimum

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 1790–1803 |
| **Condition** | `usable_lender_limit < min_shareable_lender_loan_amount` (default: 10) |
| **Runtime Data** | `usable_lender_limit` (calculated), app constant `MIN_SHAREABLE_LENDER_LOAN_AMOUNT` |
| **True** | Returns — calls `move_gapl_loans_based_on_optimistic_and_advanced_amount()` |
| **False** | Proceeds with loan sharing |

### Branch 11.5: Source loan belongs to GAPL

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 1818–1820 |
| **Condition** | `source_loan.customer_credit_line.credit_product.belongs_to_gapl` |
| **Runtime Data** | `credit_line_creditproduct.belongs_to_gapl` |
| **True (GAPL loan)** | GAPL path: marks as disbursed if YTD, splits via `split_gapl_loan_to_share_lender()`, then sends to Saraloan or recurses |
| **False (lender loan)** | Non-GAPL path: either retries upload or splits loan between lender and GAPL lines |

### Branch 11.6: GAPL loan — YTD status check

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 1826–1833 |
| **Condition** | `source_loan.status in [LoanConstants.YET_TO_BE_DISBURSED]` |
| **Runtime Data** | `loan_loan.status` |
| **True** | Calls `mark_gapl_loan_as_disbursed(source_loan)` before splitting |
| **False** | Proceeds directly to split |

### Branch 11.7: Non-GAPL — usable limit vs loan amount

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 1876–1878 |
| **Condition** | `usable_lender_limit >= source_loan.loan_amount` |
| **Runtime Data** | `usable_lender_limit`, `loan_loan.loan_amount` |
| **True** | Retries invoice upload for full loan amount via `retry_invoice_upload_for_saraloan()` |
| **False** | Splits loan: creates lender loan (usable_limit amount) + remaining loan, cancels source, sends lender portion to Saraloan |

### Branch 11.8: Non-GAPL split — GAPL line existence

| Attribute | Value |
|-----------|-------|
| **File** | `loan/tasks.py` |
| **Line** | 1880–1889 |
| **Condition** | `not gapl_line` |
| **Runtime Data** | GAPL credit line query result |
| **True** | Returns error — "Loan can't be split and gapl line does not exist or not active" |
| **False** | Proceeds with loan split |

---

## Business Rules Summary

| Rule | Location | Key Condition |
|------|----------|---------------|
| Credit allowed | `credit_line/model/customer.py:87` | `Customer.is_credit_allowed` boolean field |
| Operational limit cap | `credit_line/signals.py:17–19` | `min(operational_limit, credit_limit)` on every `CustomerCreditLine` save |
| Lender status override | `credit_line/model/customer_credit_line.py:306–312` | `lender_status == OVERDUE and not business_override` → forces ONHOLD |
| Aged outstanding hold | `credit_line/tasks.py:2523–2528` | `overdue - credit_limit > threshold and not business_override` |
| Repayment frequency hold | `credit_line/tasks.py:2615–2617` | `repayment_unblock_amount > 1 and not business_override` |
| Partial disbursal | `credit_line/tasks.py:1563–1568` | `invoice_requested_amount > disbursement_amount` |
| Invalid payment transitions | `payment/utils.py:339–348` | `CANCELLED → POSTED` and `POSTED → UNREALIZED` blocked |
| Loan sharing minimum | `loan/tasks.py:1790–1803` | `usable_lender_limit < MIN_SHAREABLE_LENDER_LOAN_AMOUNT` (default 10) |
| External lender deboarding | `loan/tasks.py:2862–2873` | All lender credit lines closed → `initiate_lender_deboarding()` |
| Farmer partial disbursal blocked | `credit_line/tasks.py:1582–1590` | `customer_type != DC` → partial disbursal returns `False` |
