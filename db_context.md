# Database Context — Models, Relationships & Debugging

## Table of contents

1. [Overview](#overview)
2. [Tables by domain](#tables-by-domain)
3. [Relationship map](#relationship-map)
4. [Debug and infrastructure tables](#debug-and-infrastructure-tables)
5. [Risky patterns and known bugs](#risky-patterns-and-known-bugs)
6. [Example debugging queries](#example-debugging-queries)

---

## Overview

~120 Django models across ~25 apps. Primary database is PostgreSQL 14. All models use Django ORM. Key patterns:
- `on_delete=RESTRICT` is dominant (prevents accidental cascade deletes)
- `ConfigVariable` drives runtime feature flags with 24h cache
- `JSONField` used extensively for flexible payloads (webhooks, payment breakups, verification data)
- `simple_history` (`HistoricalRecords`) on select models for audit trail
- Conditional `UniqueConstraint`s (partial indexes) used for state-dependent uniqueness

---

## Tables by domain

### Sale & orders

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `sale_orderrequest` | Checkout unit — one cart submission | `status` (processing/processed/failed/cancelled), `cart_id` (unique), `reference_id` (unique UUID), `payment_breakup` (JSON) | `cart_id` unique; `reference_id` unique |
| `sale_orderrequestline` | Line items in a cart | `payment_mode` (prepaid/credit), `delivery_slot` (JSON), `bundle` FK | — |
| `sale_saleorder` | Fulfilment unit synced to SAP | `status` (draft/confirmed/cancelled/failed), `sap_sync_status` (pending/in_progress/migrated/failed), `sap_order_id` (unique), `order_delivery_status`, `type` (preorder/order/virtual_order/clearance) | `sap_order_id` unique |
| `sale_saleorderline` | Lines on a sale order | `product_id` (char, not FK), `payment_mode`, `delivery_fee` | — |
| `sale_preorderconfig` | Pre-order time windows | `status` (draft→confirmed→active→completed/paused/archived), `quantity_to_be_received`, `reserved_quantity` | Conditional unique on `(product, sales_office)` where status is active/confirmed; 6 CheckConstraints on quantities and dates |
| `sale_preorderconfigsaleordermap` | Links pre-order config to sale orders | `sale_order` FK, `config` FK | — |
| `sale_orderintent` | Money reservation (parked funds) | `status` (open/expired/allocated/cancelled), `referring_entity_type` (order_request/abs_booking/security_deposit), `amount`, `expiry` | `unique_together = (referring_entity_id, referring_entity_type)` |
| `sale_orderintentconfig` | Per-customer intent rules | `expiry_in_hours`, `max_concurrent_open_intent_count`, `is_hidden` | — |
| `sale_intransitsto` / `sale_intransitstoline` | Inter-warehouse stock transfers | `sto_id`, `order_delivery_status`, line quantities | Conditional unique on `sto_id` where `is_unique_indexed=True`; `unique (sto_id, product_id)` on lines |
| `sale_stoblockedinventories` | Reserved inventory per sale order line | `reserved_qty`, links `SaleOrderLine` ↔ `InTransitStoLine` | — |
| `sale_posaleordermap` | PO number gating for pre-orders | `po_number`, `sale_order` FK | — |
| `sale_saleplan` | Planned quantity per product/partner/month | `planned_qty`, `month`, `year` | `unique_together = (product, partner, month, year)` |
| `sale_saleschannel` | AIMS / DBA identifiers | `key` (unique) | — |

### Delivery & logistics

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `delivery_delivery` | Delivery header linked to sale/return/STO | `sap_delivery_no` (unique), `delivery_status` (created/completed), `delivery_type` (sales/return/sto), `sap_sync_status` | `sap_delivery_no` unique |
| `delivery_deliveryline` | Delivery line items with invoice/IRN data | `quantity`, `invoice_no`, `irn_no`, `is_grn_success`, links to `SaleOrderLine`/`ReturnSaleOrderLine`/`InTransitStoLine` | — |
| `delivery_deliveryreschedule` | Cancel/reschedule segments | `reschedule_quantity`, `reschedule_type` ("C" for cancel) | — |
| `delivery_deliveryslot` | Product × sales office time windows | `start_time`, `end_time`, `threshold_days`, `is_active` | — |

### Returns

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `returns_returnsaleorder` | Customer return header | `sap_order_id`, `order_approval_status` (pending/confirmed/rejected), `sap_sync_status`, `return_type` (ZRIN/ZPOD), `discount_reversal` on lines | — |
| `returns_returnsaleorderline` | Return line items | `quantity`, `price_unit`, `discount_reversal` (decimal) | — |
| `returns_returnorderupload` | CSV bulk upload tracking | `is_processed`, `errors` (JSON) | — |

### Products & catalog

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `products_template` | Product or bundle template | `type` (product/bundle), `brand`/`category`/`sub_category` FKs, `tax`, `hsn_code` | Indexes on `type`, `(brand, category, sub_category)` |
| `products_product` | Product variant | `id` (int PK, SAP material number), `template` FK, `is_blocked`, `is_deleted` | Indexes on `(template, is_blocked, is_deleted)` |
| `products_productnode` | Product × sales office pricing | `dehaat_price`, `is_prepaid`, `credit_days`, `delivery_fee` | `unique_together = (product, node)` |
| `products_productplant` | Product × plant inventory | `inventory` (int), `is_purchase_blocked`, `is_sale_blocked` | `unique_together = (product, plant)` |
| `products_batch` | Batch/lot tracking | `batch_id`, `inventory`, `expiry_date` | Indexes on `(product, plant)`, `(batch_id, product)` |
| `products_bundle` / `products_bundleline` / `products_bundlenode` | Bundle definitions | `hash` (unique, deterministic), `is_active`, `discounted_price` | `unique_together` on bundle+product, bundle+sales_office; CheckConstraints on prices |
| `products_productlistapidata` | Precomputed JSON for fast list APIs | `template` (JSON), `sales_office_id`, `template_fk` FK | Expression-based indexes |
| `products_productpriceupdaterequest` | Price update to SAP | `status` (to_be_synced/synced/cancelled) | Conditional unique on `(product, node, status)` where status=to_be_synced |
| `products_productrank` | Product ordering by rank | `rank`, `template`/`sales_office`/`customer` | Conditional unique: with customer and without customer (partial indexes) |
| `products_sappricechange` / `products_sappricechangeitem` | Price change approval workflow | `status` (raised/approved/rejected/partially_rejected) | Indexes on `(node, status)`, `(product, status)` |
| `product_search_productsearchdata` | Denormalized search autocomplete | Hindi/English names, `sales_office` FK | `unique_together = (template_id, sales_office_id)`; 7 GiST trigram indexes |

### Accounting & payments

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `accounting_accountingentries` | Payment hold/release ledger | `type` (payment_hold/payment_release), `source_gl`/`dest_gl` (customer/abs/prepaid/park/security_deposit), `synced`, `is_active`, `reference_key` (unique, from sequence) | Conditional unique on hold per entity; conditional unique on active release per document; CheckConstraints requiring release_reason and SAP source docs for releases |
| `accounting_refundaccountingentries` | Refund-side SAP entries | `source_gl`/`dest_gl` (customer/yesbank/hdfc), `synced` | Unique on `(referring_entity_id, referring_entity_type)`; unique on SAP doc triple |
| `accounting_refundpendingorderdata` | Post-release refund settlement tracking | `settlement_type` (none/prepaid_refund/FDFO/pay_by_invoice/open_credit_limit), `status`, `expiry`, `expired` | Unique on `(accounting_entry, referring_entity_type, referring_entity_id)` |
| `payments_paymentreferncemap` | External payment ref → entity mapping | `reference_system_identifier` (dehaat_wallet/sap), `amount` | `unique_together = (reference_system_identifier, reference_number)` |
| `payments_paymenttransaction` | PG/wallet/Odoo transactions | `status` (pending/success/failed/cancelled), `is_va_payment`, `pg_payment_mode` | Unique on `(ref_system, ref_number)`; unique on 4-tuple (system, number, entity_type, entity_id) |
| `payments_paymentrefundtransaction` | Refund transactions | `status` (pending/success/failed), `ib_reference_key` (unique UUID), `origin_transaction` FK | Same uniqueness as PaymentTransaction |
| `ledger_settlement_requests` | Pay-by-invoice settlement | `hash_code` (SHA-256 dedup), `status` (PENDING/PROCESSING/COMPLETED/FAILED), `allocation_flow` | Indexes on `(partner_id, created_at)`, `(status, created_at)` |
| `wallet_walletcustomerconfig` | Customer ↔ external wallet link | `wallet_id`, `status`, `is_active` | OneToOne on Customer; pre_save signal auto-creates wallet |

### Customer & onboarding

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `customer_management_customer` | Dehaat Centre (DC) master record | `partner_id` (unique, SAP ID), `org_id` (unique UUID), `sales_office`, `credit_limit`, `onboarded`, `gstin_no`, `label` (priority/non_priority), `pending_documents_exists` | Custom `save()` triggers Freshdesk sync + nearest DC update |
| `customer_management_customerbankdata` | DC bank account details | `account_name`, `bank_account_number`, `ifsc_code` | — |
| `onboarding_ticket` | KYC onboarding ticket | `mobile`, `ticket_type` (new/existing), `state` (phase_one/phase_two/activated/rejected), `nearest_dc` FK | Conditional unique: `(mobile, ticket_type)` where new; `(mobile)` where existing + active |
| `onboarding_ticket_document` | Per-ticket KYC document instance | `state` (pending/submitted/verified/rejected/skipped), `verification_data` (JSON), `meta_data` (JSON) | CheckConstraint: at least one of ticket/customer must be non-null; conditional unique on (ticket,customer,document) |
| `security_deposit` | Security deposit tracking | `sap_payment_id`, `sap_payment_status` (D/P/C/N), `settlement_status` (AVAILABLE/PARTIALLY_SETTLED/SETTLED) | — |

### Discount schemes

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `discount_schemes_bookingorder` | ABS booking | `booking_request_id` (unique UUID), `status` (draft/cancelled/done), `scheme_id` | — |
| `discount_schemes_benefitinvoice` | Credit/debit notes for SAP | `invoice_type` (credit_note/debit_note), `sap_sync_status`, `unique_key` (unique), `reversal_details` (JSON), `benefit_details` (JSON) | Indexes on partner, scheme_id, sap_invoice_id |
| `discount_schemes_benefitinvoiceline` | Benefit invoice line items | `unit_price`, `quantity`, `reversal_amount`, `total_delivery_fee` | — |
| `discount_schemes_couponprocessing` | Coupon processing queue | `mode` (wallet/accounting_entity), `type` (benefit_credit/reversal), `status` (pending/processed) | — |
| `discount_schemes_orderschemebenefit` | Links sale order to scheme benefit | `order` FK, `scheme_id`, `status` (pending/processed/failed/ignored), event ack FKs | — |
| `discount_schemes_schemebenefitstatus` | Benefit processing flags per customer/scheme | `benefit_calculated`, `benefit_processed` | `unique_together = (customer, scheme_id)` |

### Users & auth

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `users_user` | Core user (AUTH_USER_MODEL) | `auth_id` (unique, Keycloak sub), `mobile` (unique), `email` (unique), `my_dehaat_center` FK, `sales_office` FK, `roles` M2M | Custom `save()` triggers Ticketmaster sync |
| `users_sapuser` / `users_sapcoordinator` | SAP ID links | OneToOne on User (PK) | — |
| `user_management_fcmtoken` | Push notification tokens | `token`, `user` FK, `application` (DBA/AIMS) | `unique_together = (user, application)` |

### Stock management

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `stock_management_reasontype` | Reason type master | `reason_type` (unique), `reason_source` (sap/ib) | — |
| `stock_management_reasons` | Reason codes | `reason_id` (unique), `reason_type` FK | `unique_together = (reason_type, reason_id)` |

### Master data (input_backend.common)

| Table | Business meaning | Critical fields | Key constraints |
|-------|-----------------|-----------------|-----------------|
| `common_salesoffice` | Sales node / DC | `sales_office_id` (unique), `name` (CICharField, unique constraint), `active`, license flags | Custom `clean()` normalizes whitespace |
| `common_plant` | SAP plant/warehouse | `plant_id` (unique), `active` | — |
| `common_salesofficeplanttypemap` | Office ↔ plant with type (primary/secondary/tertiary) | `plant_type` | — |
| `common_configvariable` | Runtime feature flags & tunables | `key` (unique), `value` (text), `active` | Custom `save()`/`delete()` invalidates 24h cache |
| `common_salesofficeroutes` | Supply chain routing between nodes | `is_active`, `priority`, delivery time fields | Conditional unique on `receiving_node` where active; CheckConstraint prevents self-loops |
| `common_vendor` | Vendor (transporter) master | `sap_id` (unique nullable), `type`, `primary_mobile_number` | `unique_together = (type, primary_mobile_number)` |
| `common_state` / `common_district` / `common_block` | Geographic hierarchy | `reference_id` (unique UUID on each), `odoo_id` | — |

---

## Relationship map

### Core commerce flow
```
Customer ←──── OrderRequest ────► OrderRequestLine ────► Product
    │               │                                      ▲
    │               ▼                                      │
    │          SaleOrder ──────► SaleOrderLine ─────────────┘
    │            │    │               │
    │            │    │               ▼
    │            │    │       StoBlockedInventories ──► InTransitStoLine
    │            │    │
    │            │    ▼
    │            │  PreOrderConfigSaleOrderMap ──► PreOrderConfig ──► Product
    │            │
    │            ▼
    │        Delivery ──────► DeliveryLine
    │            │                 │
    │            │                 ▼
    │            │          DeliveryReschedule
    │            │
    │            ▼
    │      ReturnSaleOrder ──► ReturnSaleOrderLine
    │
    ▼
OrderIntent
AccountingEntries ──► RefundPendingOrderData
PaymentTransaction ──► PaymentRefundTransaction
```

### Key cross-domain FKs

| From | To | Via field |
|------|----|----------|
| `SaleOrder` | `OrderRequest` | `order_request` FK |
| `SaleOrder` | `Customer` | `partner` FK |
| `SaleOrder` | `SalesOffice` | `sales_office` FK |
| `Delivery` | `SaleOrder` | `order` FK |
| `Delivery` | `ReturnSaleOrder` | `return_order` FK |
| `Delivery` | `InTransitSto` | `sto_order` FK |
| `DeliveryLine` | `SaleOrderLine` | `order_line` FK |
| `OrderRequest` | `Customer` | `partner` FK |
| `OrderIntent` | `Customer` | `customer` FK |
| `AccountingEntries` | `Customer` | `partner` FK |
| `RefundPendingOrderData` | `AccountingEntries` | `accounting_entry` FK |
| `PaymentRefundTransaction` | `PaymentTransaction` | `origin_transaction` FK |
| `BenefitInvoice` | `Customer` | `partner` FK |
| `BenefitInvoice` | `BookingOrder` | `booking_order` FK |
| `OnboardingTicket` | `Customer` | `customer` FK, `nearest_dc` FK |
| `User` | `Customer` | `my_dehaat_center` FK |
| `WalletCustomerConfig` | `Customer` | `customer` O2O |

---

## Debug and infrastructure tables

### Event pipeline (RabbitMQ)

| Table | Purpose | Key debug fields |
|-------|---------|-----------------|
| `rabbitmq_producer_publishedevent` | Transactional outbox for RabbitMQ events | `state` (pending/success/failed), `config_params` (JSON: exchange, routing_key), `payload`, `created_at` (db_index) |
| `rabbitmq_producer_shareablepublishedevent` | Deduped SAP sync events | `event_hash` (unique), `state` (created/acknowledged/ignored), `acknowledged_at` |
| `rabbitmq_producer_publishedeventacknowledgement` | DS event acknowledgement tracking | `event` FK (unique, acts as O2O), `status` (pending/failed/success/ignored), `service` |
| `rabbitmq_consumer_consumedevent` | Consumed event processing log | `function_name`, `status` (pending/processed/failed), `retry_count`, `payload` (JSON) |

### Webhook processing

| Table | Purpose | Key debug fields |
|-------|---------|-----------------|
| `webhook_sapwebhook` | SAP-originated webhook payloads | `type` (SAPWebhookTypeChoices), `status` (PENDING/PROCESSED/FAILED), `payload` (JSON). Indexed on created_at, status, type |
| `webhook_webhook` | Non-SAP webhooks (e.g. process-discounts) | Same structure as SAPWebhook |

### Notifications

| Table | Purpose | Key debug fields |
|-------|---------|-----------------|
| `transactional_notification_receivedevent` | Incoming notification payloads | `data` (JSON), `tasks_created` (bool) |
| `transactional_notification_mailmanevent` | Per-template processing row | `status` (pending/in_progress/done/error), `error_message`, linked to received_event and template_event |

### OTP

| Table | Purpose | Key debug fields |
|-------|---------|-----------------|
| `sms_notification_otp` | RSA-encrypted OTP records | `encrypted_otp`, `mobile`, `verified`, `purpose`, `expiry_time`, `create_time` |

### Audit

| Table | Purpose | Key debug fields |
|-------|---------|-----------------|
| `audit_log_auditlog` | HTTP request/response logging | `method`, `request_path`, `request_body`, `response_status_code`, `response_body`, `response_time`, `user` FK. Indexed on `updated_at` |

### Celery results

| Table | Purpose | Key debug fields |
|-------|---------|-----------------|
| `django_celery_results_taskresult` | Celery task results (Django DB backend) | `task_id`, `status`, `result`, `traceback`, `date_done` |
| `django_celery_beat_*` | Celery beat schedule tables | Periodic task definitions and execution state |

### History tracking

| Table | Purpose | Key debug fields |
|-------|---------|-----------------|
| `products_historicaldcskupaymentmoderequest` | `simple_history` for DcSkuPaymentModeRequest | Full field snapshot with `history_date`, `history_type` (+/~/−), `history_user` |

---

## Risky patterns and known bugs

### Mutable default values on JSONField

These fields use `default={}` or `default=[]` instead of `default=dict` / `default=list`. This means **all instances share the same default object** — mutations leak across rows if the default isn't overwritten on create.

| Model | Field | Default |
|-------|-------|---------|
| `PaymentTransaction` | `metadata` | `default={}` |
| `PaymentRefundTransaction` | `metadata` | `default={}` |
| `EventOrderInvoiceProduct` | `slab_wise_data` | `default=[]` |
| `EventOrderInvoiceProduct` | `discount` | `default={}` |
| `EventOrderInvoiceProduct` | `lower_bound_applied_bundle_list` | `default=[]` |

### Datetime default evaluated at import time

| Model | Field | Issue |
|-------|-------|-------|
| `CarousalWidgetItem` | `start_date`, `end_date` | `default=datetime.datetime.today()` — evaluated once at server startup, not per-row |

### Dead code / latent bugs

| Model | Issue |
|-------|-------|
| `PaymentRefundTransaction` | `set_payment_reference()` sets `self.payment_reference` but model has no `payment_reference` field |

### Missing FK constraints (denormalized string IDs)

These store IDs as CharField instead of ForeignKey — no referential integrity at DB level:

| Model | Field | What it references |
|-------|-------|--------------------|
| `SaleOrderLine` | `product_id` (CharField) | Should reference `Product` |
| `ReturnSaleOrderLine` | `product_id` (CharField) | Should reference `Product` |
| `LedgerSettlementRequest` | `partner_id` (CharField) | Should reference `Customer` |
| `BookingPayment` | `booking_order_id` (CharField) | Should reference `BookingOrder` |
| `AccountingEntries` | `referring_entity_id` (CharField) | Polymorphic — references different tables based on `referring_entity_type` |
| `OrderIntent` | `referring_entity_id` (CharField) | Polymorphic — references different tables based on `referring_entity_type` |

### Heavy JSON fields with no schema validation

These JSONFields store critical business data with no DB-level or model-level schema validation:

| Model | Field | Risk |
|-------|-------|------|
| `OrderRequest` | `payment_breakup` | Payment details — silently accepts malformed JSON |
| `AccountingEntries` | `metadata` | SAP document context |
| `OnboardingTicketDocument` | `verification_data`, `meta_data` | KYC verification results |
| `SecurityDeposit` | `meta_data` | Security deposit context |
| `BenefitInvoice` | `reversal_details`, `benefit_details`, `metadata` | Scheme calculation data |

### Nullable unique fields

| Model | Field | Issue |
|-------|-------|-------|
| `Vendor` | `sap_id` | `unique=True, null=True` — PostgreSQL allows multiple NULLs in unique, but Django admin may not handle cleanly |
| `SaleOrder` | `sap_order_id` | `unique=True, null=True` — same pattern; orders before SAP sync have NULL |

### on_delete=DO_NOTHING (no cascade protection)

| Model | Field | Risk |
|-------|-------|------|
| `CardsFeed` | `parent_card` | Deleting parent leaves orphaned children with dangling FK |
| `PerformanceMetric` | `payout_parameter` | Deleting payout parameter leaves orphaned metrics |

### on_delete=CASCADE (may delete too much)

| Model | Field | Risk |
|-------|-------|------|
| `AuditLog` | `user` | Deleting a user deletes all their audit logs |
| `Delivery` | `order` / `return_order` / `sto_order` | Deleting sale/return/STO order cascades to all deliveries |

---

## Example debugging queries

### Order stuck in "processing"

```sql
-- Find the order request and its current state
SELECT id, status, failure_reason, failure_info, created_at, 
       payment_breakup->'payment_details' as payment_details
FROM sale_orderrequest
WHERE id = <order_request_id>;

-- Check if sale orders were created
SELECT id, status, sap_sync_status, sap_order_id, failure_info, type
FROM sale_saleorder
WHERE order_request_id = <order_request_id>;

-- Check for pending Celery tasks
SELECT task_id, status, result, date_done, traceback
FROM django_celery_results_taskresult
WHERE task_args LIKE '%<order_request_id>%'
ORDER BY date_done DESC LIMIT 5;
```

### SAP sync failure

```sql
-- Find failed sale orders
SELECT id, sap_order_id, sap_sync_status, failure_info, failure_reason, 
       created_at, updated_at
FROM sale_saleorder
WHERE sap_sync_status = 'failed'
  AND created_at > NOW() - INTERVAL '24 hours'
ORDER BY created_at DESC;

-- Check published events for the order
SELECT pe.id, pe.state, pe.config_params->>'routing_key' as routing_key,
       pe.created_at, pe.error
FROM rabbitmq_producer_publishedevent pe
WHERE pe.payload::text LIKE '%<sale_order_id>%'
ORDER BY pe.created_at DESC;
```

### Delivery not completing

```sql
-- Delivery and line status
SELECT d.id, d.sap_delivery_no, d.delivery_status, d.sap_sync_status,
       d.delivery_type, d.failure_info
FROM delivery_delivery d
WHERE d.order_id = <sale_order_id>;

-- Delivery lines with invoice info
SELECT dl.id, dl.quantity, dl.invoice_no, dl.irn_no, dl.irn_error_status,
       dl.irn_error_msg, dl.is_grn_success
FROM delivery_deliveryline dl
JOIN delivery_delivery d ON dl.delivery_id = d.id
WHERE d.order_id = <sale_order_id>;

-- Check for reschedule/cancel segments
SELECT dr.reschedule_quantity, dr.reschedule_type, dr.reschedule_reason
FROM delivery_deliveryreschedule dr
JOIN delivery_deliveryline dl ON dr.delivery_line_id = dl.id
JOIN delivery_delivery d ON dl.delivery_id = d.id
WHERE d.order_id = <sale_order_id>;
```

### Payment not reflecting

```sql
-- Find payment transactions for an order request
SELECT id, reference_system_identifier, reference_number, status,
       referring_entity_type, referring_entity_id, is_va_payment,
       created_at, updated_at, metadata
FROM payments_paymenttransaction
WHERE referring_entity_id = '<order_request_id>'
ORDER BY created_at DESC;

-- Check webhook processing
SELECT id, type, status, created_at,
       payload->>'DocumentNumber' as doc_number
FROM webhook_sapwebhook
WHERE payload::text LIKE '%<reference_number>%'
ORDER BY created_at DESC;
```

### Accounting entry not synced

```sql
-- Find unsynced accounting entries for a partner
SELECT id, reference_key, type, amount, source_gl, dest_gl,
       synced, is_active, is_settled, referring_entity_type,
       referring_entity_id, release_reason, created_at
FROM accounting_accountingentries
WHERE partner_id = <customer_id>
  AND synced = false
ORDER BY created_at DESC;

-- Check refund settlement status
SELECT rpod.id, rpod.settlement_type, rpod.status, rpod.expiry,
       rpod.expired, rpod.prepaid_amount, rpod.refunded_amount,
       ae.reference_key, ae.type as ae_type
FROM accounting_refundpendingorderdata rpod
JOIN accounting_accountingentries ae ON rpod.accounting_entry_id = ae.id
WHERE rpod.customer_id = <customer_id>
  AND rpod.status != 'COMPLETED'
ORDER BY rpod.created_at DESC;
```

### Event pipeline stuck

```sql
-- Pending published events (producer side)
SELECT id, state, config_params->>'routing_key' as routing_key,
       created_at, error
FROM rabbitmq_producer_publishedevent
WHERE state = 'pending'
  AND created_at > NOW() - INTERVAL '1 hour'
ORDER BY created_at ASC
LIMIT 20;

-- Failed consumed events (consumer side)
SELECT id, function_name, status, retry_count, created_at,
       payload::text
FROM rabbitmq_consumer_consumedevent
WHERE status = 'failed'
  AND created_at > NOW() - INTERVAL '24 hours'
ORDER BY created_at DESC
LIMIT 20;

-- Stuck pending consumed events
SELECT id, function_name, status, retry_count, created_at
FROM rabbitmq_consumer_consumedevent
WHERE status = 'pending'
  AND created_at < NOW() - INTERVAL '10 minutes'
ORDER BY created_at ASC;
```

### Product data stale

```sql
-- Check last sync timestamp
SELECT task, start_time
FROM products_synctimestamp;

-- Check ProductListAPIData freshness per sales office
SELECT sales_office_id, COUNT(*) as row_count
FROM products_productlistapidata
GROUP BY sales_office_id
ORDER BY sales_office_id;

-- Check inventory for a product across plants
SELECT pp.plant_id, p.plant_name, pp.inventory, pp.is_sale_blocked
FROM products_productplant pp
JOIN common_plant p ON pp.plant_id = p.id
WHERE pp.product_id = <product_id>;
```

### Onboarding ticket stuck

```sql
-- Ticket status and documents
SELECT ot.id, ot.mobile, ot.ticket_type, ot.state, ot.created_at,
       ot.nearest_dc_id, ot.sent_to_locus
FROM onboarding_ticket ot
WHERE ot.mobile = '<mobile_number>';

-- Document verification status
SELECT otd.id, od.doc_key, od.title, otd.state as doc_state,
       otd.verification_data, otd.meta_data
FROM onboarding_ticket_document otd
JOIN onboarding_document_config od ON otd.document_id = od.id
WHERE otd.ticket_id = <ticket_id>
ORDER BY od.doc_key;
```

### Notification not delivered

```sql
-- Check MailManEvent processing
SELECT mme.id, mme.status, mme.error_message, mme.created_at,
       re.data as event_data
FROM transactional_notification_mailmanevent mme
JOIN transactional_notification_receivedevent re ON mme.received_event_id = re.id
WHERE re.data::text LIKE '%<entity_id>%'
ORDER BY mme.created_at DESC;
```

### ConfigVariable check

```sql
-- Inspect a feature flag
SELECT key, value, active
FROM common_configvariable
WHERE key = '<config_key>';

-- List all active config variables
SELECT key, value
FROM common_configvariable
WHERE active = true
ORDER BY key;
```

### Benefit / discount issues

```sql
-- Benefit invoice status for an order
SELECT bi.id, bi.invoice_type, bi.sap_sync_status, bi.amount,
       bi.sap_invoice_id, bi.failure_reasons, bi.unique_key
FROM discount_schemes_benefitinvoice bi
WHERE bi.sale_order_id = '<sap_order_id>'
ORDER BY bi.id;

-- OrderSchemeBenefit processing status
SELECT osb.id, osb.scheme_id, osb.status, osb.benefit,
       osb.created_at, osb.updated_at
FROM discount_schemes_orderschemebenefit osb
WHERE osb.order_id = <sale_order_id>;

-- Coupon processing queue
SELECT id, coupon, type, mode, status, referring_entity_id
FROM discount_schemes_couponprocessing
WHERE referring_entity_id = '<order_request_id>';
```
