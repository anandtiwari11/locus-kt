# Task & Event Dependency Graph

This document traces the key async chains in the system. When debugging async issues, use this to understand what triggers what and where a chain can break.

## Order Processing Chain

```
User → POST /sale-management/order-requests/v2
  └→ OrderRequest created (status=processing)
  └→ RabbitMQ: order_request.created → order-request-exchange
       └→ Consumer: PROCESS_ORDER_REQUEST
            └→ sale.event_processor.process_order_request
                 └→ Celery: process_order_request_task (queue: process_order_request)
                      ├→ process_payment (wallet, PG, coupon hold)
                      ├→ process_order_request_split → creates SaleOrder(s)
                      ├→ process_sale_order_sync_to_sap
                      │    └→ Celery: sync_sale_order_to_sap_task (queue: sale_order_sync)
                      │         ├→ Redis lock (per sale order)
                      │         ├→ SAP: create_sale_order
                      │         ├→ On success: status=confirmed, sync=migrated
                      │         │    └→ RabbitMQ: sale_order.update → sale-order-exchange
                      │         │         ├→ Consumer: SALE_ORDER → products event_processor (inventory resync)
                      │         │         ├→ Consumer: ORDER_EVENTS_FOR_DS → DS event publishing
                      │         │         └→ Consumer: SAP_ACCOUNTING_ENTRY → accounting holds
                      │         └→ On failure: sync=failed
                      │              └→ RabbitMQ: sale_order.cancelled
                      └→ OrderRequest status → processed/failed

Sweep: process_order_requests (every 15 min) picks up stale "processing" ORs
```

## Payment Webhook Chain

```
PG/VA Webhook → POST /webhook/payment-service or /webhook/va-payment
  └→ PaymentTransaction updated
  └→ Celery: process_payments_via_dehaat_pg / process_virtual_account_payment
       ├→ VA path: Redis distributed lock → SAP payment posting
       ├→ PG path: SAP posting → side effects based on entity_type:
       │    ├→ order_request → order processing / intent allocation
       │    ├→ abs_booking → ABS payment successful task
       │    ├→ security_deposit → security deposit payment
       │    └→ ledger_entries → PBI settlement PROCESSING
       └→ Mixpanel tracking

Sweep: process_payments_via_dehaat_pg (every 15 min) retries pending PG txns
Sweep: process_virtual_account_payments (every 15 min) retries pending VA txns
```

## SAP Entity Polling Chain (sap_wrap)

```
Celery Beat (every 30 min each):
  ├→ sync_invoices_from_sap
  ├→ sync_payments_from_sap
  ├→ sync_credit_notes_from_sap
  ├→ sync_debit_entries_from_sap
  ├→ sync_debit_notes_from_sap
  └→ sync_cust_line_items_from_sap
       │
       ├→ Read cursor from ConfigVariable (SAP_SYNC.*_LAST_UPDATE_TIME)
       ├→ Fetch entities from SAP since cursor
       ├→ Process each entity through webhook.utils:
       │    ├→ create_invoice / deliver_invoice / cancel_invoice
       │    ├→ create_or_update_gapl_payment / create_or_update_disb_payment
       │    ├→ create_credit_note / cancel_credit_note
       │    └→ create_debit_record / cancel_debit_note
       │         └→ Each processor may call: Odoo, Locus, Ledger service, RabbitMQ
       └→ Update cursor in ConfigVariable

Also: sap_sync_entity_publish_event → ShareablePublishedEvent (dedup by event_hash)
```

## SAP Webhook Inbound Chain

```
SAP → POST /webhook/invoice/create (or /credit-note/*, /payment/*, etc.)
  └→ SAPWebhook row created (status=PENDING)
  └→ RabbitMQ: SAP_WEBHOOK_RECEIVED
       └→ Consumer: maps to webhook.event_processor.process_sap_webhook
            └→ Celery: dispatch_event_processor (queue: consumer_tasks)
                 ├→ Redis lock per consumed_event_id
                 ├→ Maps SAPWebhookTypeChoices → handler function
                 ├→ Runs handler inside DB transaction
                 ├→ On success: SAPWebhook → PROCESSED, ConsumedEvent → PROCESSED
                 └→ On failure: retry_count++; at ≥3 retries → FAILED + Honeybadger
```

## Benefit Processing Chain

```
Sale order confirmed (via RabbitMQ event)
  └→ Consumer: ORDER_EVENTS_FOR_DS
       └→ DS event acknowledgement tracking
            └→ Celery: fetch_and_process_benefits
                 ├→ Fetch benefits from Discount Service
                 ├→ Create BenefitInvoice + BenefitInvoiceLine
                 └→ Celery: sync_credit_notes_to_sap
                      ├→ SAP credit note posting
                      └→ On failure: BenefitInvoice.sap_sync_status = failed

Also triggered by:
  - Delivery completion → update_delivery_status_order → discount event
  - Return deposit → create_benefit_invoice_for_return_order (debit note)
```

## Sale Order Cancellation → Payment Release Chain

```
Confirmed SaleOrder cancellation request
  └→ IB sends cancellation to SAP
  └→ SAP cancels the order
  └→ IB fires event: sale_order.cancellation_request → sale-order-exchange
       └→ Consumer: SaleOrderConsumerAdapter
            └→ sale.event_processor.process_payment_release_on_so_items_cancellation
                 │
                 ├→ Check: should_payment_release_be_processed_through_new_flow()
                 │    (compares hold entry created_at vs ConfigVariable 'new_payment_release_flow_start_date')
                 │
                 ├→ [NEW FLOW] release_payment_for_order_request()
                 │    ├→ Redis lock: acquire_lock_for_processing_release_payment (blocking=False)
                 │    ├→ get_confirmed_and_cancelled_ib_sale_orders(order_request)
                 │    │    ├─ confirmed_sale_orders (IB status still 'confirmed')
                 │    │    │    └→ SAP sub-path: get_sap_cancelled_order_release_amount_map
                 │    │    │         └→ creates release: "SO_{sap_order_id}/partial/{qty}"
                 │    │    └─ cancelled_sale_orders (IB status = 'cancelled')
                 │    │         └→ IB sub-path: get_ib_cancelled_order_release_data
                 │    │              └→ creates release: "Order-{ib_order_id}"
                 │    └→ create_payment_release_entries → create_release_payment (get_or_create)
                 │
                 └→ [OLD FLOW] (for holds before 2024-11-28)
                      └→ _create_sap_release_payment → start_sap_payment_release_process
                           └→ creates release: "SO_{sap_order_id}/partial/{qty}" with cancel_info metadata

CRITICAL TIMING NOTE:
  When the cancellation_request event is first processed, the IB sale order status
  may still be 'confirmed' (SAP hasn't synced status back yet). The order goes into
  confirmed_sale_orders → SAP sub-path. After SAP syncs the status, the same order
  becomes 'cancelled' in IB → IB sub-path on event replay. This timing gap was the
  root cause of the historical dual-path duplicate release bug (fixed ~Feb 2026).
```

## Refund Settlement Chain

```
Payment release event (order cancellation / delivery)
  └→ AccountingEntries (type=payment_release) created
  └→ RabbitMQ: payment release event
       └→ RefundPendingOrderData created (settlement_type=none)
            │
            ├→ User chooses settlement type via refund widget:
            │    ├→ prepaid_refund → PaymentRefundTransaction → PG/VA refund
            │    ├→ pay_by_invoice → LedgerSettlementRequest
            │    ├→ open_credit_limit → mark settled
            │    └→ FDFO (first due first out) → auto-allocated
            │
            └→ Sweep: settle_expired_refund_pending_order_data (every 15 min)
                 └→ Expired rows (no type chosen) → FDFO strategy
```

## RabbitMQ Producer Outbox Pattern

```
App code → save_and_publish_event_async(exchange, routing_key, payload)
  ├→ PublishedEvent created (state=PENDING) in DB transaction
  └→ Celery: publish_pending_event_task (queue: publish_tasks)
       ├→ pika.BlockingConnection → publish to exchange
       ├→ On success: state → SUCCESS
       └→ On failure: stays PENDING for sweep

Sweeps:
  - publish_pending_events (every 5 min): re-dispatches all PENDING events
  - mark_pending_events_failed (every 12h): PENDING > 5 days → FAILED
  - republish_unacknowledged_order_events (every 30 min): DS events without ack
```

## Consumer Event Processing

```
Message arrives on RabbitMQ queue
  └→ kube_kombu consumer process: BaseConsumerAdapter.callback
       ├→ Locus source: handler runs directly (no DB record)
       └→ Other: ConsumedEvent created (status=PENDING)
            └→ Celery: dispatch_event_processor (queue: consumer_tasks)
                 ├→ Redis lock per consumed_event_id
                 ├→ Import handler function by string path
                 ├→ Run handler with data
                 ├→ On success: PROCESSED
                 ├→ On failure: retry_count++; ≥3 retries → FAILED + Honeybadger
                 └→ LockError: return quietly (another worker processing)

Special routing (EventDispatcher):
  - Product/inventory handlers → products.tasks.dispatch_inventory_sync_consumer_tasks
  - Accounting handlers → accounting.tasks.hold_and_release_accounting_entry_sync_consumer_tasks

Sweep: run_pending_consumed_events (every 5 min): re-dispatches stuck PENDING events
```

## Delivery Chain

```
Eligible orders API → Picklist creation
  └→ POST /delivery/v1 (create)
       └→ Delivery + DeliveryLine rows
       └→ SAP: create_delivery
            └→ PGI: pgi_delivery_in_sap
                 └→ Invoice: create_invoice_for_delivery → SAP
                      └→ OTP: create_and_send_ofd_delivery_otp (queue: celery_otp)
                           └→ Verify OTP
                                └→ Complete delivery:
                                     ├→ Celery: update_delivery_status_order
                                     │    ├→ POG inventory update
                                     │    ├→ Discounting event
                                     │    └→ SaleOrder.order_delivery_status → completed
                                     └→ Celery: send_sms_on_delivery_completion → Mailman
```

## Onboarding Chain

```
Mobile app → POST /onboarding/tickets (create ticket)
  └→ OnboardingTicket (state=phase_one)
       └→ Document uploads → OnboardingTicketDocument per doc
            └→ Identity Master verification (PAN/GST/Aadhaar OCR)
                 └→ move_ticket_to_next_phase
                      ├→ phase_one → phase_two (more docs)
                      └→ phase_two → activated
                           ├→ Customer created
                           ├→ Celery: create_customer_virtual_account
                           ├→ Celery: create_lead_for_lender_in_locus
                           └→ Celery: nearest_dc_calculate
```
