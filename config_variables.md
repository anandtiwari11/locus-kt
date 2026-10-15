# ConfigVariable — Critical Runtime Flags & Tunables

`common_configvariable` (model: `input_backend.common.models.ConfigVariable`) is a key/value store used across the entire system. Values are cached for 24 hours and invalidated on save/delete.

**During any production RCA, check whether a ConfigVariable was recently changed** — it's one of the most common silent root causes.

## Feature flags

| Key | Expected value | Effect when wrong |
|-----|---------------|-------------------|
| `bypass_publish_to_rmq` | `false` | If `true`, all RabbitMQ events skip the broker and run in-process — consumer isolation is lost, failures cascade into the request path. **Very dangerous in production.** |
| `dispatch_flow_allowed` | `true` / `false` per setup | Toggles SAP-direct delivery vs dispatch-service-based delivery. Changing mid-day can cause misrouted picklists. |
| `enable_va_creation_on_va_service` | `true` | If `false`, VA creation falls back to Locus-only path. |
| `restrict_sales_return_partial_delivery` | depends | Gates whether partial return deposits are allowed. |

## Timeouts (service call)

| Key pattern | Default | Risk |
|-------------|---------|------|
| `core_api_timeout` | 10 | Forward request timeout to Core API. Too low → 504s; too high → thread starvation. |
| `*_timeout` (service-specific) | varies | Each external service may have its own timeout via `ConfigVariable.objects.get_timeout(...)`. Check when seeing service timeouts. |

## SAP sync cursors

| Key pattern | Format | Purpose |
|-------------|--------|---------|
| `SAP_SYNC.INVOICE_LAST_UPDATE_TIME` | ISO timestamp | Last invoice polled from SAP |
| `SAP_SYNC.PAYMENT_LAST_UPDATE_TIME` | ISO timestamp | Last payment polled from SAP |
| `SAP_SYNC.CREDIT_NOTE_LAST_UPDATE_TIME` | ISO timestamp | Last credit note polled from SAP |
| `SAP_SYNC.DEBIT_ENTRY_LAST_UPDATE_TIME` | ISO timestamp | Last debit entry polled from SAP |
| `SAP_SYNC.DEBIT_NOTE_LAST_UPDATE_TIME` | ISO timestamp | Last debit note polled from SAP |
| `SAP_SYNC.CUST_LINE_ITEM_LAST_UPDATE_TIME` | ISO timestamp | Last customer line item polled from SAP |

If a cursor is stuck (timestamp not advancing), `sap_wrap` tasks are either failing or not running. Check `django_celery_results_taskresult` for `sync_*_from_sap` tasks.

## Business rules

| Key | Purpose |
|-----|---------|
| `delivery_eligible_orders_days_limit` | Max age (days) for orders to appear in delivery eligibility API |
| `plan_auto_approve_expiry` | Hours before a field plan auto-promotes to `AUTO_APPROVED` |
| `PRODUCT_SYNC_INTERVAL_IN_MINUTES` | Frequency of inventory/price sync from SAP |

## Debugging queries

```sql
-- Check all active config variables
SELECT key, value, active, updated_at
FROM common_configvariable
WHERE active = true
ORDER BY key;

-- Check if bypass mode is on (event bus)
SELECT key, value
FROM common_configvariable
WHERE key = 'bypass_publish_to_rmq';

-- Check SAP sync health (are cursors advancing?)
SELECT key, value
FROM common_configvariable
WHERE key LIKE 'SAP_SYNC%'
ORDER BY key;

-- Recently modified config variables (possible root cause)
SELECT key, value, active, updated_at
FROM common_configvariable
WHERE updated_at > NOW() - INTERVAL '24 hours'
ORDER BY updated_at DESC;
```
