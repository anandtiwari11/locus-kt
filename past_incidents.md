# Past Incidents — Patterns & Root Causes

Use this file to record production incidents and their root causes. Over time this becomes the highest-value context for the RCA agent — pattern matching against real incidents is far more reliable than rule-based classification.

## How to add an incident

Copy the template below, fill in the details, and append to the appropriate category section.

```markdown
### YYYY-MM-DD: <Short title>
- **Symptom**: What was observed (alerts, user reports, metrics)
- **Impact**: Scope and duration
- **Root cause**: What actually went wrong
- **Detection query**: SQL or command that confirmed the issue
- **Fix**: What was done to resolve
- **Prevention**: What was done to prevent recurrence
```

---

## Order & Sale Incidents

_(Add incidents here as they occur)_

<!-- Example:
### 2025-01-15: Orders stuck in processing for 2 hours
- **Symptom**: ~200 orders in "processing" status; customer complaints
- **Impact**: All order processing blocked for 2h, ~200 orders affected
- **Root cause**: `process_order_request` queue workers scaled to 0 during deployment
- **Detection query**:
  ```sql
  SELECT COUNT(*), MIN(created_at) FROM sale_orderrequest
  WHERE status = 'processing' AND created_at > NOW() - INTERVAL '4 hours';
  ```
- **Fix**: Scaled workers back up; stale orders auto-recovered via `process_order_requests` sweep (every 15 min)
- **Prevention**: Added alerting on queue depth for `process_order_request` queue
-->

## Payment Incidents

_(Add incidents here)_

## Delivery & Logistics Incidents

_(Add incidents here)_

## SAP Integration Incidents

_(Add incidents here)_

<!-- Example:
### 2025-02-10: SAP sync cursor stuck for 6 hours
- **Symptom**: New SAP invoices not appearing in IB; ledger data stale
- **Impact**: Finance reconciliation delayed for all DCs
- **Root cause**: `sync_invoices_from_sap` task failing silently — SAP credentials rotated but ConfigVariable not updated
- **Detection query**:
  ```sql
  SELECT key, value FROM common_configvariable WHERE key LIKE 'SAP_SYNC%';
  -- Showed INVOICE_LAST_UPDATE_TIME stuck 6 hours behind
  SELECT task_name, status, traceback FROM django_celery_results_taskresult
  WHERE task_name LIKE '%sync_invoices%' ORDER BY date_done DESC LIMIT 5;
  -- Showed FAILURE with SAP 403 error
  ```
- **Fix**: Updated SAP credentials; cursor auto-advanced on next successful run
- **Prevention**: Added Honeybadger alert on SAP 403 errors in sap_wrap tasks
-->

## Event Bus Incidents

_(Add incidents here)_

<!-- Example:
### 2025-03-05: bypass_publish_to_rmq accidentally set to true
- **Symptom**: Accounting entries not syncing; consumed events not being created
- **Impact**: All async event processing bypassed for ~30 min
- **Root cause**: ConfigVariable `bypass_publish_to_rmq` set to `true` during debugging and not reverted
- **Detection query**:
  ```sql
  SELECT key, value, active FROM common_configvariable WHERE key = 'bypass_publish_to_rmq';
  ```
- **Fix**: Set `bypass_publish_to_rmq` back to `false`; ran `publish_pending_events` sweep manually
- **Prevention**: Added monitoring alert when bypass flag is true in production
-->

## Accounting & Refund Incidents

### 2025-03-19: Duplicate payment release entries for OR 1437621 (and systemic across many ORs)
- **Symptom**: User reported excess payment release entries for order request 1437621. Hold of ₹3,065 but 4 release entries created (3 active + 1 deactivated) instead of 3 (one per cancelled sale order).
- **Impact**: Systemic — at least 20+ order requests affected since March 2025 with similar duplicate releases. Some orders had up to 37 release entries (e.g., OR 1611665). Duplicate entries were synced to SAP before being detected and reversed.
- **Root cause**: **New payment release flow dual-path race condition.** When a confirmed sale order (status=confirmed, sap_sync_status=migrated, sap_order_id exists) is cancelled:
  1. IB marks the order as cancelled **in SAP** and fires a `sale_order.cancellation_request` event.
  2. The event handler `process_payment_release_on_so_items_cancellation` routes to the new flow (`release_payment_for_order_request`) because `should_payment_release_be_processed_through_new_flow` returns True (hold created after `new_payment_release_flow_start_date` config).
  3. The new flow calls `get_confirmed_and_cancelled_ib_sale_orders(order_request)` to split orders. At this point, the **IB sale order status is still `confirmed`** (SAP cancellation is propagating but hasn't synced back yet).
  4. The order falls into `confirmed_sale_orders` → the SAP-cancelled-orders sub-path (`get_sap_cancelled_order_release_amount_map`) creates a release with `referring_document_string = "SO_{sap_order_id}/partial/{qty}"`.
  5. After some time, SAP syncs the cancellation status back to IB → the IB sale order status changes from `confirmed` to `cancelled`.
  6. When the event **replays** (or another cancellation event fires for a different SO on the same order request), the new flow calls `get_confirmed_and_cancelled_ib_sale_orders` again. Now the same order falls into `cancelled_sale_orders` → the IB-cancelled-orders sub-path (`get_ib_cancelled_order_release_data`) creates a second release with `referring_document_string = "Order-{ib_order_id}"`.
  7. The IB sub-path only checks for existing entries matching `Order-{id}` pattern (line ~2034 in `amount_release_utils.py`), so it doesn't see the already-created `SO_*/partial/*` entry → duplicate created.
- **Detection query**:
  ```sql
  -- Find order requests with deactivated-but-synced release entries (duplicate pattern)
  SELECT referring_entity_id AS order_request_id,
         COUNT(*) FILTER (WHERE type='payment_hold' AND is_active=true) AS holds,
         COUNT(*) FILTER (WHERE type='payment_release') AS all_releases,
         COUNT(*) FILTER (WHERE type='payment_release' AND is_active=true) AS active_releases,
         COUNT(*) FILTER (WHERE type='payment_release' AND is_active=false) AS inactive_releases,
         COUNT(*) FILTER (WHERE type='payment_release' AND is_active=false AND synced=true) AS synced_then_deactivated
  FROM accounting_accountingentries
  WHERE referring_entity_type = 'order_request'
    AND created_at > '2025-03-01'
  GROUP BY referring_entity_id
  HAVING COUNT(*) FILTER (WHERE type='payment_release' AND is_active=false AND synced=true) > 0
  ORDER BY referring_entity_id DESC;

  -- For a specific order request, check for the dual-pattern:
  SELECT id, type, amount, is_active, synced, inactive_reason,
         referring_document_string, sap_document_id, created_at
  FROM accounting_accountingentries
  WHERE referring_entity_type = 'order_request'
    AND referring_entity_id = '1437621'
  ORDER BY created_at;
  ```
- **Fix**: Bug was fixed ~Feb 2026 in the new payment release flow. Affected entries were cleaned up — duplicates deactivated with `inactive_reason = "Duplicate wrong release entry"` and reversals synced to SAP/Locus/Ledger.
- **Prevention**: The new flow now properly deduplicates across both `SO_*/partial/*` and `Order-*` `referring_document_string` patterns before creating release entries.
- **Key identifiers for OR 1437621**:
  - Hold: entry 173568 (₹3,065, SAP doc 4200047973)
  - Legitimate releases: 173691 (₹440, Order-773420), 173692 (₹1,575, SO_3000828125/partial/15), 173693 (₹1,050, Order-773418)
  - Duplicate (cleaned): 173694 (₹1,575, Order-773419, inactive, `"Duplicate wrong release entry"`)

## Product & Catalog Incidents

_(Add incidents here)_

## Customer & Onboarding Incidents

_(Add incidents here)_

## Infrastructure Incidents

_(Add incidents here)_

<!-- Example:
### 2025-04-20: Celery worker OOM on sale_order_sync queue
- **Symptom**: SAP order sync tasks timing out; SaleOrder.sap_sync_status stuck in "in_progress"
- **Impact**: ~50 orders not synced to SAP for 1 hour
- **Root cause**: Worker pod hit memory limit during large batch of concurrent SAP syncs
- **Detection query**:
  ```sql
  SELECT COUNT(*), sap_sync_status FROM sale_saleorder
  WHERE created_at > NOW() - INTERVAL '2 hours'
  GROUP BY sap_sync_status;
  -- Showed abnormal count in "in_progress"
  ```
- **Fix**: Restarted worker pod; stale "in_progress" orders picked up by retry logic
- **Prevention**: Increased memory limit; added concurrency limit on sale_order_sync queue
-->
