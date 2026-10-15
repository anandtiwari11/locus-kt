# Lender Invoice Share Flow (SLINV Churn) - Current vs Proposed

This document captures the current and proposed flow for lender invoice sharing, focused on the SLINV churn issue (same loan/invoice getting multiple tranche IDs over retries).

Related Jira issues:
- `LOC-28` (parent bug)
- `LOC-29` idempotent tranche guard + lock
- `LOC-30` prevent `YET_TO_UPLOAD` reset when tranche exists
- `LOC-31` duplicate-400 recovery via lender verification
- `LOC-32` stop `MANUAL_UPDATE_REQUIRED` auto-retry loop
- `LOC-33` tighten action-job eligibility + state-authority matrix

---

## Current Flow

```mermaid
flowchart TD
    A["Loan selected for lender share"] --> B["share_oldest_loan_to_lender"]
    B --> C["prepare_loan_to_send_to_saraloan"]
    C --> D["send_invoice_to_saraloan (PARTNER_FOUND)"]
    D --> E["create_tranche_in_blacksoil"]
    E --> E1{"Retry guard allows create_tranche?"}
    E1 -->|Yes| E2["Saraloan.create_invoice_tranche (NEW SLINV/Tx)"]
    E2 --> E3["Save TRANSACTION_CREATED + lender_invoice_id/transaction_id"]
    E3 --> F{"Subvention needed?"}
    F -->|Yes| G["update_subvention_details_in_saraloan"]
    F -->|No| H["create_invoice_in_blacksoil"]
    G --> H
    H --> H1["Saraloan.send_invoice(invoice_number)"]
    H1 --> H2{"HTTP 201?"}
    H2 -->|Yes| H3["INVOICE_UPLOADED"]
    H2 -->|No| H4{"HTTP 400?"}
    H4 -->|Yes| H5["MANUAL_UPDATE_REQUIRED (already exists)"]
    H4 -->|No| H6["INVOICE_UPLOAD_FAILED"]

    P["Scheduled: take_action_on_invoice_as_per_lender_action"] --> Q["check_lender_status_and_take_action_on_invoice"]
    Q --> R["sync_invoice_status_from_saraloan"]
    R --> S{"invoice_upload_status not in (INVOICE_UPLOADED, CANCELLED)?"}
    S -->|Yes| T["reshare_or_delete_invoice_saraloan"]
    T --> U["Set YET_TO_UPLOAD"]
    U --> V["Requeue share_oldest_loan_to_lender"]
    V --> D

    H5 -.included in non-uploaded bucket.-> S
```

### Current behavior summary
- `MANUAL_UPDATE_REQUIRED` can re-enter periodic reset/re-share flow.
- `create_tranche_in_blacksoil` can create a new tranche on re-entry.
- Same LLM can get reassigned from one `SLINV` to another over time.

---

## Proposed Flow

```mermaid
flowchart TD
    A["Loan selected for lender share"] --> B["share_oldest_loan_to_lender"]
    B --> C["prepare_loan_to_send_to_saraloan"]
    C --> D["send_invoice_to_saraloan"]
    D --> E["create_tranche_in_blacksoil + select_for_update"]

    E --> E0{"Existing tranche already present?"}
    E0 -->|Yes| Eskip["Skip tranche creation; preserve existing SLINV/Tx"]
    E0 -->|No| Ecreate["Create tranche once; save TRANSACTION_CREATED + SLINV/Tx"]

    Eskip --> F{"Subvention needed?"}
    Ecreate --> F
    F -->|Yes| G["update_subvention_details_in_saraloan"]
    F -->|No| H["create_invoice_in_blacksoil"]
    G --> H

    H --> H1["Saraloan.send_invoice(invoice_number)"]
    H1 --> H2{"HTTP 201?"}
    H2 -->|Yes| H3["INVOICE_UPLOADED"]
    H2 -->|No| H4{"HTTP 400 duplicate already exists?"}
    H4 -->|Yes| H5["Run lender verification/sync"]
    H5 --> H6{"Invoice exists at lender?"}
    H6 -->|Yes| H7["Mark INVOICE_UPLOADED"]
    H6 -->|No| H8["Fallback MANUAL_UPDATE_REQUIRED"]
    H4 -->|No| H9["Normal failure handling"]

    P["Scheduled invoice action job"] --> Q["check_lender_status_and_take_action_on_invoice"]
    Q --> R["sync_invoice_status_from_saraloan"]
    R --> S{"Need reshare/reset?"}
    S -->|Yes| T{"Tranche already exists?"}
    T -->|Yes| T1["Do NOT set YET_TO_UPLOAD; route to re-upload/reconcile"]
    T -->|No| T2["Set YET_TO_UPLOAD + reshare"]
    T2 --> B

    M["Retry policy"] --> M1["MANUAL_UPDATE_REQUIRED not auto-retried by default"]
```

### Proposed behavior summary
- Once tranche exists, it is reused (no SLINV churn).
- Duplicate-400 is handled as recoverable with lender verification.
- `MANUAL_UPDATE_REQUIRED` no longer loops automatically.

---

## Ticket to Flow Mapping

- `LOC-29`: `create_tranche_in_blacksoil` idempotency + lock (`E`, `E0`, `Eskip`, `Ecreate`)
- `LOC-30`: prevent `YET_TO_UPLOAD` reset for already-tranched rows (`S`, `T`, `T1`)
- `LOC-31`: duplicate-400 recovery (`H4`, `H5`, `H6`, `H7`)
- `LOC-32`: stop `MANUAL_UPDATE_REQUIRED` auto-retry (`M1`)
- `LOC-33`: tighten action-job eligibility and status authority (`P`, `Q`, `R`, `S`)

---

## Example Incident (Reference)

For `LenderLoanMap` `id=392216` (loan `1901771`, invoice `2026$$TI20261001001450`), historical transitions showed multiple tranche IDs over time:
- `SLINV658114`
- `SLINV658170`
- `SLINV658301`

With repeated duplicate error: `already exists`.

This is the concrete scenario the proposed flow is designed to prevent.
