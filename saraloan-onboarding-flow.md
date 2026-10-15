# Saraloan onboarding flow (Locus)

How DC (ME-Blacksoil) and farmer (Farmer-Blacksoil) customers are onboarded on Saraloan from Locus: KYC push, LOS lifecycle, e-sign/NACH, activation, and which Saraloan IDs are used.

**Client:** `common/external/saraloan/saraloan.py` (`Saraloan`)  
**Credentials:** `SaraloanCredConstants.DC`, `SaraloanCredConstants.FARMER`  
**HTTP base:** v1 Core + LOS + e-sign for onboarding (see `.cursor/saraloan-api-flows.md` §1)

**Related:** `.cursor/lead_processing.md`, `.cursor/saraloan-api-flows.md`, `.cursor/credit-eligibility.md`, `.cursor/loan_lifecycle.md`

---

## Two paths

| Path | Product | Code | Trigger |
|------|---------|------|---------|
| DC lead | ME-Blacksoil | `lead/` | IB → lead API → Celery KYC chain |
| Farmer application | Farmer-Blacksoil | `farmer_financing/saraloan.py`, `farmer_financing/tasks.py` | Kheti `UserApplication` → KYC + status sync |

Both paths create Saraloan **business** + **person**, upload documents, and eventually produce **`business_id`**, **`application_id`**, and (after activation) **`loan_account_id`** on Locus (`CustomerLenderMap`, optionally `BusinessApplicationMap` for LOC-63).

---

## Saraloan APIs used in onboarding (full list)

Onboarding uses **v1 Core / LOS / service e-sign**. It does **not** call LMS `get_account_details`, `get_business_loan_accounts`, or v2 business invoice/repayment APIs—those are **post-onboarding partner sync** (LOC-63).

### DC (ME-Blacksoil) — `SaraloanCredConstants.DC`

| Phase | Saraloan method | Path param / input | HTTP (typical) |
|-------|-----------------|-------------------|----------------|
| KYC | `create_business` | body | `POST /core/businesses/` |
| KYC | `get_business_details` | **business_id** (`expand=extra`) | `GET /core/businesses/{business_id}/` |
| KYC | `create_business_documents` | **business_id** | `POST /core/businesses/{business_id}/documents/` |
| KYC | `create_business_address` | **business_id** | `POST /core/businesses/{business_id}/addresses/` |
| KYC | `create_bank` | **business_id** | `POST /core/businesses/{business_id}/banks/` |
| KYC | `update_personal_details` | **person_id** (in payload) | `PATCH /core/persons/{person_id}/` |
| KYC | `get_person_documents` | **person_id** | `GET /core/persons/{person_id}/documents/` |
| KYC | `update_person_documents` | **person_id** | `PATCH /core/persons/{person_id}/documents/...` |
| KYC | `create_person_address` | **person_id** | `POST /core/persons/{person_id}/addresses/` |
| PDC | `get_bank_id` | **business_id** | `GET /core/businesses/{business_id}/banks?...` |
| PDC | `create_pdc_documents` | **application_id** | `POST /los/applications/{application_id}/cheques/` |
| PDC | `update_pdc_documents` | **application_id** | `PATCH /los/applications/.../cheques/{id}/` |
| Status sync | `get_business_details` | **business_id** | `GET /core/businesses/{business_id}/` |
| Status sync | `get_application_details` | **application_id** | `GET /los/applications/{application_id}/` |
| Recovery | `get_partner_all_ids` | **mobile** or **partner_id** | `GET /core/business_query/?...` |
| E-sign | `get_application_document` | **application_id** | `GET /los/applications/{id}/documents/` |
| E-sign | `get_attached_stamp_paper` | **application_id** | attach stamp API |
| E-sign | `create_or_initiate_esign` | document id | `POST /service/esigns/` |
| E-sign | `get_application_esign` | **application_id** | `GET /los/applications/{id}/esigns/` |
| E-sign | `get_updated_esign_data` | esign id | `GET /service/esigns/{id}/` |
| NACH | `get_bank_id`, `nach_status_refresh`, `get_nach_status`, `create_emandate_registration_link` | **business_id** + **bank_id** | Core banks |
| Activation | `update_partner_id` | **business_id** + extra id | `PATCH /core/businesses/{business_id}/extras/{extra_id}/` |
| Limit enhancement | `create_business_documents` | **business_id** | same as KYC docs |

**Not used in live DC chain:** `send_to_los` (`PUT /core/businesses/{business_id}/send_to_los/`) is commented out in `lead/tasks.py`; Saraloan moves to LOS after data is complete.

### Farmer (Farmer-Blacksoil) — same Core patterns + LOS credit-line steps

| Area | Saraloan method | Path param / input |
|------|-----------------|-------------------|
| Lookup | `get_auth_details` | **mobile** |
| KYC | `create_business`, `get_business_details`, `create_business_address`, person doc/address APIs | **business_id**, **person_id** (same as DC) |
| LOS | `send_to_los` | **business_id** (farmer **calls** this; DC does not) |
| Status / UW | `get_business_details`, `get_application_details`, `get_linked_person_details` | **business_id**, **application_id** |
| Credit line | `update_business_details`, `update_credit_line` | **business_id** |
| Credit line | `get_approve_credit_line`, `get_initiate_credit_line`, `get_activate_credit_line` | **application_id** |
| Co-borrower / guarantor | `link_signers_to_business` | **business_id** (+ linked business ids) |
| Person | `update_person_email`, `update_personal_details_dob`, `create_person_document` | **person_id** |
| E-sign / forms | `get_application_form`, `get_application_document`, `get_attached_stamp_paper`, `create_document_esign`, `get_updated_esign_data` | **application_id** and/or **business_id** (per method) |

**Orchestration:** `farmer_financing/saraloan.py` (`LoanCredibilityChecker`), tasks `sync_application_status_from_saraloan*`, `approve_and_initiate_cl_for_application`, e-sign crons.

---

## Which ID is used when?

| Identifier | Request param during onboarding? | Notes |
|------------|----------------------------------|--------|
| **loan_account_id** | **No (0 APIs)** | No `lead/` or `farmer_financing/` onboarding call passes `loan_account_id` to Saraloan. It appears only in **responses** (e.g. `get_partner_all_ids` → `business_id`, `application_id`, `loan_account_id`) and is stored on `CustomerLenderMap` via **post-onboarding sync**. |
| **application_id** | **Yes (~12–14 methods)** | PDC, LOS status, e-sign, farmer credit-line approve/initiate/activate, linked persons. Usually **learned** from `get_business_details` / auth after `create_business`, then stored on `LeadSaraloanMap` or farmer app data. |
| **business_id** | **Yes (~15–18 methods)** | Core KYC, NACH, partner patch, farmer LOS and credit-line updates. |
| **person_id** | **Yes (~6 methods)** | Person KYC chain. |
| **mobile / partner_id** | **Yes (2 methods)** | `get_auth_details`, `get_partner_all_ids`. |

---

## DC flow (operational summary)

### Entry and models

- **Intake:** `lead/views.py` → `validate_and_create_lead` (phase one/two docs, PDC).
- **Models:** `Lead`, `LeadDocument`, `LeadLenderMap`, `LeadSaraloanMap`.

### Celery

| Task | Role |
|------|------|
| `saraloan_phase_one_eligible_leads` | Eligible leads → `LeadLenderMap` (ME-Blacksoil) |
| `send_lead_to_saraloan` | Start/retry KYC chain or `retry_onboarding_process` |
| KYC chain (`lead/tasks.py`, `medium_priority`) | `saraloan_create_business` → … → `saraloan_create_person_address` (see API table above) |
| `sync_saraloan_leads_status` | `get_business_details` + `get_application_details` → `LeadSharingStatus` |
| `sync_pdc_to_saraloan` | Retry failed PDC |
| `saraloan_retry_partner_id_update` | Retry `update_partner_id` |

### HTTP

| View | Saraloan usage |
|------|----------------|
| `GetSaraloanLeadEsignUrl` | E-sign helpers in `lead/utils.py` |
| `GetNachDetails` | NACH / e-mandate |
| `ActivateCustomer` | Locus customer + `update_partner_id` on Saraloan |

### After activation (not onboarding, but fills IDs)

| Mechanism | Saraloan |
|-----------|----------|
| `sync_partners_saraloan_data` | `get_partner_all_ids`, then sync chain (v1/v2 LMS + business APIs) |
| `sync_customers_from_saraloan` | Batch partner sync |
| `fetch_and_update_credit_line_info` | Credit line + loan outstanding (LOC-63: business-level aggregate) |
| `sync_business_application_maps` | BAM reconcile |

---

## Business `expand=loan_account` vs `loan_accounts` (LOC-63)

**Not part of onboarding KYC.** Used in **`get_business_loan_accounts`** for post-onboarding sync/aggregation.

- Saraloan business details expect expand **`loan_account`** (singular), e.g.  
  `loan_account.extra,loan_account.topups.extra,loan_account.topups.invoice`
- LOC-63 initially used **`loan_accounts`** (plural) → HTTP **500** on staging; fixed in `common/external/saraloan/utils.py` (`BUSINESS_LOAN_ACCOUNTS_EXPAND` + aggregator reads `loan_account` or legacy `loan_accounts` list).
- Farmer default business expand in `get_business_details` already included **`loan_account`** (singular) for full profile fetch.

Onboarding itself uses **`expand=extra`** (DC step 2) or farmer-specific expands—not the full loan topup aggregate.

---

## Key Locus entities

| Entity | Role |
|--------|------|
| `Lead` / `LeadDocument` | IB payload and KYC docs |
| `LeadLenderMap` | Lender pipeline: `status`, `lender_status` |
| `LeadSaraloanMap` | `business_id`, `person_id`, `application_id` |
| `Customer`, `CustomerCreditLine` | Created at activation |
| `CustomerLenderMap` | Runtime Saraloan ids (often filled by sync) |
| `BusinessApplicationMap` | Multi-application per business (LOC-63) |

---

## Debug checklist

1. Phase-one docs complete; `LeadLenderMap.lender_status` for failed step.
2. `LeadSaraloanMap.business_id` / `application_id`.
3. Saraloan application status vs `SARALOAN_LEAD_STATUS_MAP` (`lead/constants.py`).
4. After activation: run partner sync if `CustomerLenderMap.loan_account_id` missing.
5. Do not debug onboarding with `get_business_loan_accounts` / LMS loan account APIs—use Core/LOS calls above.

**Smoke (post-onboarding APIs):** `scripts/smoke_saraloan_sync_apis.py` (read-only).
