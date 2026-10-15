## Lead processing flow

**Goal**: Ingest leads from IB, keep `Lead` and related records up to date across phases, and integrate with Saraloan and customer activation.

This document covers the end-to-end journey from receiving lead data to activating a customer.

### Overview

At a high level:

1. IB sends lead data to the Locus lead API.
2. Locus creates or updates a `Lead` record and associated documents.
3. Depending on the phase, documents and PDCs are validated and shared to Saraloan.
4. Saraloan decisions and statuses are synced back to Locus.
5. Once approved, a customer is created/activated and linked to credit lines.

### Key entry points

- **HTTP API**:
  - `lead/views.py::CreateLeadViewSet.post` – receives lead payloads from IB and calls `validate_and_create_lead`.
  - `lead/views.py::LeadViewSet` – reads lead and lender status.
  - `lead/views.py::GetSaraloanLeadEsignUrl` – exposes Saraloan e-sign details.
  - `lead/views.py::ActivateCustomer` – activates the customer and marks the lead as on-boarded.
- **Background tasks** (Celery):
  - `lead/tasks.py::retry_update_lead` – retries lead updates when they fail.
  - Other tasks in `lead/tasks.py` coordinate Saraloan sync, PDC sharing, and limit enhancement flows.

### Core models and constants

- `lead/model/leads.py::Lead` – primary lead entity.
- `lead/model/leads.py::LeadFileUpload` – uploaded lead files.
- `lead/model` (other files) – `LeadDocument`, `LeadLenderMap`, `LeadSaraloanMap` (not shown here but referenced from views/utils/tasks).
- `lead/constants.py` – includes:
  - `LeadApplicationStatus` – application level status.
  - `IBTicketStatus` – inbound ticket status from IB.
  - `LeadDocumentTypes` – types of documents involved.
  - `LeadSharingStatus` – status of sharing leads with Saraloan/lenders.

These constants define the allowed states that a lead can transition through.

### Step-by-step flow

#### 1. Lead creation / update from IB

- IB calls the lead endpoint:
  - `POST /lead/lead` → `CreateLeadViewSet.post`
- The view:
  - Reads `payload.data["data"]` from the request.
  - Invokes:
    - `lead/utils.py::validate_and_create_lead(data, raise_error=True)`

`validate_and_create_lead`:

- Ensures the customer is valid for lead creation (except for limit enhancement):
  - `validate_customer_for_lead_creation(partner_id, mobile_no)`
- Attempts to find an existing lead:
  - `check_lead_exists(lead_identifier_id, partner_id, mobile_no)`
- **If no lead exists**:
  - Builds `lead_data` with:
    - `lead_id`, `mobile_number`, `last_updated_at_ib`, `document_last_updated_at_ib`,
    - `dc_name`, `ib_ticket_status`, and optionally `partner_id`.
  - For `application_status == "limit_enhancement"`, sets `application_status = LeadApplicationStatus.IN_PROGRESS`.
  - Creates a new `Lead` instance.
- **If a lead exists**:
  - Looks up `LeadLenderMap` and, if present, triggers:
    - `lead.tasks.sync_each_saraloan_lead_status.apply_async((lead_lender_map_obj.id,))`
  - Backfills `partner_id` if missing.

Phase-specific handling:

- **Phase one (`application_status == "phase_one"`)**:
  - If the IB timestamp is newer, updates:
    - `mobile_number`, `last_updated_at_ib`, `document_last_updated_at_ib`,
    - `dc_name`, and `ib_ticket_status`.
  - Calls:
    - `validate_and_update_documents(data, lead, raise_error)`
  - `validate_and_update_documents`:
    - Checks if existing documents are stale.
    - Iterates over `data["documents"]`.
    - For documents whose `doc_key` is in `LeadDocumentTypes.LENDER_REQUIRED_DOCUMENTS`, calls `check_and_update_document`.

- **Phase two (`application_status == "phase_two"`)**:
  - If the IB timestamp is newer, updates `ib_ticket_status`.
  - Calls:
    - `validate_and_share_pdc(data, lead, raise_error)` – validates PDC documents and shares them with Saraloan.

- **Limit enhancement (`application_status == "limit_enhancement"`)**:
  - If the IB timestamp is newer, updates `ib_ticket_status`.
  - Calls:
    - `create_and_save_transaction_data(lead)` – prepares transaction data for limit enhancement.
    - `validate_and_update_limit_enhancement_documents(data, lead)` – processes limit enhancement specific documents.

#### 2. Document handling

Key helpers:

- `validate_and_update_documents(data, lead, raise_error=False)`:
  - Updates or creates `LeadDocument` entries when new/updated docs appear.
- `validate_and_update_limit_enhancement_documents(data, lead)`:
  - Similar to above but restricted to `LeadDocumentTypes.LENDER_LIMIT_ENHANCEMENT_DOCUMENTS`.
- `check_and_update_document(doc, lead, data, raise_error)`:
  - Fetches existing `LeadDocument` or creates a new one.
  - Validates document payload with `validate_document_info`.
  - Saves the document or notifies IB and optionally raises `ValidationError`.

These functions ensure that documents used by Saraloan and internal underwriting are consistent and up to date.

#### 3. Exposure of lead status and lender status

- `LeadViewSet` provides read-only access to lead and lender statuses:
  - Filter types:
    - `lead` / `customer` – fetch leads by `lead_id` or `partner_id`.
    - `line_status` – fetch leads by lender line status (using `IB_LEAD_STATUS_MAP`).
  - For each requested id, it builds response entries including:
    - `line_status`, `approved_amount`, `rejection_reason`, `lender_name`.

This is used by upstream systems to understand where a lead is in the pipeline.

#### 4. Saraloan e-sign and Nach flows

- `GetSaraloanLeadEsignUrl`:
  - Resolves the relevant `LeadLenderMap` and `LeadSaraloanMap`.
  - Ensures the lead is in an eligible sharing status (e.g., `INITIATED`, `APPROVED`, `ACTIVATED`).
  - Uses `get_saraloan_esign_url_and_status` to obtain an e-sign URL and status.

- `GetNachDetails`:
  - Uses lead information to:
    - Determine Saraloan `business_id`, `application_id`, and bank id.
    - Either fetch current Nach status or create a new e-mandate link.

These endpoints are part of the onboarding step where the customer completes e-sign and Nach mandates with Saraloan.

#### 5. Customer activation

- `ActivateCustomer`:
  - Input:
    - `lead_identifier_id` in the URL and customer details in the body.
  - Steps:
    1. Validates request via `CreateCustomerAPISerializer`.
    2. Finds the `Lead` and its `LeadLenderMap`.
    3. Calls:
       - `activate_customer(validated_data, lead_obj, lead_lender_map_obj)` – creates/updates the customer and credit lines.
    4. If Saraloan mapping exists:
       - Calls `saraloan_update_partner_id.apply_async(...)` to update Saraloan with the new partner id.
    5. Updates the `Lead`:
       - Sets `partner_id`, `security_deposit`, and `application_status = LeadApplicationStatus.ONBOARDED`.
  - Returns:
    - `customer_id`, `overdue_credit_days`, `overdue_credit_limit`, and created `credit_lines`.

This is the final step of the lead processing flow, where a lead turns into an active customer with usable credit.

### Mermaid diagram

```mermaid
flowchart TD
    ib[\"IB sends lead data\"/] --> createLead[Create/Update Lead]
    createLead --> phaseCheck{\"application_status\"}
    phaseCheck -->|phase_one| phaseOne[Validate & update documents]
    phaseCheck -->|phase_two| phaseTwo[Validate & share PDC]
    phaseCheck -->|limit_enhancement| limitEnh[Txn data & LE docs]

    phaseOne --> shareDocs[Share documents to lender/Saraloan]
    phaseTwo --> sharePdc[Share PDC to Saraloan]
    limitEnh --> shareDocs

    shareDocs --> saraloan[\"Saraloan decisions & statuses\"]
    sharePdc --> saraloan

    saraloan --> statusSync[\"Sync lead status via tasks\"]
    statusSync --> eligible[Lead approved & eligible]
    eligible --> activate[Activate customer & credit lines]
    activate --> onboarded[Lead marked ONBOARDED]
```

### Where to read next

- For loan flow after activation, see `loan_lifecycle.md` (once created).
- For payment and reconciliation logic, see `payment_processing.md` (once created).

