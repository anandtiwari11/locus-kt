## Flow inventory

This document lists the major business flows in the Locus system and where to find their implementation.

- **Lead processing flow**
  - **Description**: Ingests leads from IB, validates and updates lead records, manages phases, and integrates with Saraloan for credit decisions and onboarding.
  - **Entry points**:
    - HTTP: `lead/views.py::CreateLeadViewSet.post`
    - Tasks: selected jobs in `lead/tasks.py`
  - **Key modules/files**:
    - `lead/views.py`
    - `lead/utils.py`
    - `lead/model/leads.py`
    - `lead/tasks.py`
    - `lead/constants.py`
  - **Exit/outcomes**:
    - Updated `Lead` records with application and ticket statuses
    - Documents stored as `LeadDocument`
    - Lead shared to Saraloan and customer activated in `credit_line` / `farmer_financing`

- **Loan lifecycle flow**
  - **Description**: Creates loans from invoices, manages loan status transitions, and keeps loan state in sync with invoices and repayments.
  - **Entry points**:
    - Utility: `loan/utility.py::create_loan`
    - HTTP: `loan/views.py::LoanViewSet`
    - Tasks: `invoice.tasks.create_loan_from_invoice`, reconciliation tasks in `loan.tasks`
  - **Key modules/files**:
    - `loan/model/loans.py`
    - `loan/utility.py`
    - `loan/tasks.py`
    - `invoice/tasks.py`
    - `invoice/models/*.py`
  - **Exit/outcomes**:
    - Persisted `Loan` records with FSM-driven statuses
    - Invoice–loan mappings for reconciliation

- **Payment processing and reconciliation flow**
  - **Description**: Ingests and creates payments, links them to loans/invoices, and reconciles balances, including transfers to lenders and SAP.
  - **Entry points**:
    - HTTP: `payment/views.py::PaymentViewSet.post`
    - Tasks: `payment.tasks.create_payments`, `payment.tasks.check_and_create_la_entries_in_sap`
  - **Key modules/files**:
    - `payment/model/payment.py`
    - `payment/utils.py`
    - `payment/tasks.py`
    - `ledger/model/ledger_entry.py`
  - **Exit/outcomes**:
    - Updated `Payment` and `LedgerEntry` records
    - Reconciliation events emitted for downstream systems

- **Farmer financing application flow**
  - **Description**: Drives farmer onboarding and loan application across multiple statuses (draft, KYC, underwriting, completion).
  - **Entry points**:
    - HTTP/serializers in `farmer_financing` (forms and API endpoints)
    - Tasks: onboarding and status sync tasks in `farmer_financing/tasks.py`
  - **Key modules/files**:
    - `farmer_financing/models.py` (`UserApplication` and related models)
    - `farmer_financing/constants.py`
    - `farmer_financing/tasks.py`
    - `farmer_financing/utils.py`
  - **Exit/outcomes**:
    - Completed or rejected farmer applications
    - Assigned credit limits and group formations

- **Scheduled tasks / batch flows**
  - **Description**: Periodic Celery tasks that synchronize data with Saraloan, run reconciliations, send notifications, and perform maintenance.
  - **Entry points**:
    - `config/settings/base.py::CELERY_BEAT_SCHEDULE`
  - **Key modules/files**:
    - `credit_line/tasks.py`
    - `loan/tasks.py`
    - `payment/tasks.py`
    - `farmer_financing/tasks.py`
    - `repayment/tasks.py`
    - `customer_journal/tasks.py`
    - `common/tasks.py`
  - **Exit/outcomes**:
    - Updated credit line, loan, and payment states
    - Triggered communications and SAP sync jobs

