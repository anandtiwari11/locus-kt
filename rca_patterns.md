# RCA Patterns — Symptom → Module → Investigation

Use this file to quickly map a production symptom to the right module and investigation steps.

## Order & Sale issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| Order stuck in `processing` | `sale` | `OrderRequest` status; `process_order_request` queue; payment service response; `process_order_request_task` logs |
| SAP order sync failed | `sale` | `SaleOrder.sap_sync_status`; Redis lock in `sap_order_sync/utils.py`; SAP error in `SaleOrder` fields; `sale_order_sync` queue |
| Pre-order not syncing to SAP | `sale` | `PreOrderConfig` status; `POSaleOrderMap` for PO gating; inventory/dropship rules; `sync_eligible_pre_orders_to_sap` task |
| Order intent expired unexpectedly | `sale` | `OrderIntentConfig` expiry hours; `expire_order_request_order_intents` cron timing |
| Cart validation error | `sale` | `validate-cart/v3` view logs; product/inventory availability; rule engine MOQ response |

## Payment issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| Payment not reflecting | `payments`, `webhook` | `PaymentTransaction` status; PG webhook delivery; `process_payments_via_dehaat_pg` task |
| VA payment stuck | `payments`, `webhook` | `process_virtual_account_payment` task; VA service response; distributed lock |
| Refund not processed | `payments`, `accounting` | `PaymentRefundTransaction` status; `sync_refund_settlement_transaction_status` task; VA/PG service |
| Payment hold/release mismatch | `accounting` | `AccountingEntries` pairs by `reference_key`; `synced` flag; SAP doc fields |
| Duplicate/excess release entries | `accounting`, `sale` | Check for dual-pattern releases: `SO_*/partial/*` AND `Order-*` for same SO; look for `inactive_reason = "Duplicate wrong release entry"`; known bug (fixed ~Feb 2026) caused by IB status lag during SO cancellation — see `past_incidents.md` |
| Refund settlement stuck | `accounting` | `RefundPendingOrderData` status/expiry; settlement strategy execution; `settle_expired_refund_pending_order_data` task |

## Delivery & logistics issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| Delivery stuck in `created` | `delivery` | SAP sync status; `delivery.utils` SAP call response |
| PGI failure | `delivery` | `pgi_delivery_in_sap` response; SAP error |
| Invoice not generated | `delivery` | `create_invoice_for_delivery`; SAP invoicing response |
| OTP not received | `delivery`, `stock_management` | `celery_otp` queue; Mailman SMS response |
| Delivery completion not triggered | `delivery` | `complete_delivery` flow; `update_delivery_status_order` task |
| Return credit note not generated | `delivery` | `create_return_deliver_credit_note` task; SAP invoicing |
| E-way bill error | `stock_management` | `create_eway_bill_sap`; SAP response |
| GRN failure | `stock_management` | SAP GRN response; linked pre-order sync status |

## Product & catalog issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| Product list stale | `products` | `SyncTimestamp`; `ProductListAPIData` refresh task; `celery_referesh_productlistapidata` queue |
| Inventory mismatch | `products` | SAP inventory sync task; `celery_inventory_sync` queue |
| Price wrong | `products` | `ProductNode` for the sales office; SAP price sync timing |
| Search returning wrong results | `product_search` | `ProductSearchData` row count; trigram index; `refresh_productsearchdata` task |

## SAP integration issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| SAP webhook not processed | `webhook` | `SAPWebhook` status; RabbitMQ `SAP_WEBHOOK_RECEIVED`; consumer logs |
| SAP entity sync cursor stuck | `sap_wrap` | `ConfigVariable` `SAP_SYNC.*_LAST_UPDATE_TIME`; sap_wrap task logs |
| SAP credentials error | `services/sap` | Credential rotation; CSRF refresh; `SAPWrap` error logs |
| SAP OData error | `services/sap` | Parse `error.innererror` from response; check endpoint URL |

## Event bus issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| Event not published | `rabbitmq_producer` | `PublishedEvent` state; `publish_pending_event_task`; pika connection |
| Event published but not consumed | `rabbitmq_consumer` | Queue bindings in `pub_sub.py`; consumer process running; kube_kombu logs |
| ConsumedEvent stuck PENDING | `rabbitmq_consumer` | `dispatch_event_processor` task; Redis lock; handler import path |
| ConsumedEvent FAILED | `rabbitmq_consumer` | `retry_count`; handler exception in Honeybadger |
| Bypass mode accidentally on | `rabbitmq_producer` | `ConfigVariable` `bypass_publish_to_rmq` |

## Customer & onboarding issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| Customer data inconsistency | `customer_management` | `Customer.save()` side effects; Odoo/SAP/Locus sync tasks |
| VA creation failed | `customer_management` | `create_customer_virtual_account` task; VA service + Locus responses |
| Onboarding ticket stuck | `onboarding` | `business_logic.py` phase transition rules; document verification status |
| KYC verification failed | `onboarding` | Identity Master API response; `OnboardingTicketDocument` verification JSON |
| Nearest DC wrong | `onboarding` | `nearest_dc_calculate` task; PostGIS query; Google distance response |

## Notification issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| Push notification not sent | `transactional_notification` | `MailManEvent` status; Mailman API response; `FCMToken` existence |
| SMS/OTP not received | `sms_notification` | `OTP` record creation; RSA key availability; Mailman SMS delivery |
| WhatsApp not delivered | `customer_management` | `send_whatsapp_message` task; Mailman response; `DCWhatsAppEventResponse` |

## Discount & benefit issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| ABS booking failed | `discount_schemes` | Discount Service response; `BookingOrder` status; payment task |
| Benefit not applied | `discount_schemes` | `BenefitInvoice` status; Discount Service benefit fetch |
| CN SAP sync failed | `discount_schemes` | `sync_credit_notes_to_sap` task; SAP credit note response |
| Discount reversal wrong | `discount_schemes`, `returns` | `create_benefit_invoice_for_return_order`; ZPOD flow |

## Infrastructure issues

| Symptom | Module | First checks |
|---------|--------|-------------|
| Celery task not executing | `celery` | Worker listening to correct queue; beat schedule; task routing |
| Task timeout | `celery` | Soft/hard time limits; task-specific overrides |
| Auth failure | `middleware_and_auth` | Keycloak service; JWT expiry; `User.auth_id` |
| Permission denied | `middleware_and_auth` | `User.roles`; permission class logic |
| External service unavailable | `services` | Service health; timeout config; retry behavior |

## General debugging steps

1. **Get the trace ID**: Find `IB_REQUEST_IDENTIFIER` from the request/response or logs
2. **Check the model state**: Look at relevant model status/sync fields in the database
3. **Check async pipeline**: If the operation is async, trace through Celery task → RabbitMQ event → consumer handler
4. **Check external service**: If an integration is involved, check the service client response in logs
5. **Check ConfigVariable**: Many behaviors are gated by `ConfigVariable` flags and timeouts
6. **Check Honeybadger**: Look for error reports with the trace ID
