# Error Catalog — Common Errors, Sources & Fixes

## SAP (OData / NetWeaver)

| Error / Pattern | Source | Root Cause | Action |
|----------------|--------|-----------|--------|
| `CSRF token validation failed` / 403 on first call | SAP Gateway | CSRF token expired after credential rotation or idle period | Auto-retried with refreshed CSRF; if persists, check credential rotation schedule |
| `error.innererror.message` in OData response | SAP business logic | Business rule violation (e.g. duplicate order, missing material, plant mismatch) | Parse the `innererror` — it contains the SAP-side rejection reason |
| Timeout / connection refused | SAP infrastructure | SAP system down or network partition | Check SAP system status; increase `ConfigVariable` timeout if transient |
| `No data found for the given criteria` | SAP OData | Query returned empty — entity doesn't exist in SAP | Verify entity IDs; check if SAP sync hasn't run yet |
| `Lock object` errors | SAP | Concurrent SAP document update | Retry; check if a batch job is locking the same document |

## Locus (Credit/Lending)

| Error / Pattern | Source | Root Cause | Action |
|----------------|--------|-----------|--------|
| `ServiceUnavailableException` + Honeybadger | Locus HTTP | Locus service down or 5xx | Check Locus service status; operations continue without Locus but credit data may be stale |
| `ValidationError` with `get_error_message` | Locus business logic | Invalid request (e.g. credit limit exceeded, invalid partner mapping) | Check error message for details |
| `insufficient_balance` / `credit_limit_exceeded` | Locus | Customer's credit line fully utilized | Check customer's credit limit vs utilization via `common.credit.utils` |

## Payment Gateway / VA Service

| Error / Pattern | Source | Root Cause | Action |
|----------------|--------|-----------|--------|
| `resp.raise_for_status()` → 4xx/5xx | PG or VA service | Bad request or service failure | Check `PaymentTransaction` status and metadata JSON for error details |
| Payment stuck in `pending` | PG/VA | Webhook not received or not processed | Check `webhook_sapwebhook` or PG webhook table; check `process_payments_via_dehaat_pg` task |
| Refund stuck in `pending` | VA / PG | Refund initiation failed or status not polled | Check `PaymentRefundTransaction`; check `sync_refund_settlement_transaction_status` task |

## Discount Service

| Error / Pattern | Source | Root Cause | Action |
|----------------|--------|-----------|--------|
| `DiscountServiceTemporarilyUnavailableException` | DS HTTP 502/503 | Discount service overloaded or down | Retry; check DS service health |
| `DiscountServiceClientException` | DS HTTP 4xx | Bad request from IB | Check request payload in logs |
| `DiscountServiceServerException` | DS HTTP 5xx | DS internal error | Check DS service logs |

## Rule Engine

| Error / Pattern | Source | Root Cause | Action |
|----------------|--------|-----------|--------|
| `RuleEngineServiceTemporarilyUnavailableException` | RE HTTP 502/503/504 | Rule engine overloaded or down | Retry; MOQ and delivery fee rules will fail without it |

## Keycloak (Auth)

| Error / Pattern | Source | Root Cause | Action |
|----------------|--------|-----------|--------|
| `TokenValidationError` | JWT validation | Invalid/expired JWT or wrong realm keys | Check if Keycloak rotated keys; check `BearerAuthentication` key fetch |
| `BadConfigError` | Keycloak client | Keycloak misconfigured (wrong URL, realm, client) | Check `KEYCLOAK_*` settings |
| `KeycloakServiceUnavailableError` | Keycloak HTTP | Keycloak down | Critical — all auth fails; check Keycloak pods |

## Redis

| Error / Pattern | Source | Root Cause | Action |
|----------------|--------|-----------|--------|
| `LockError` / `Lock already acquired` | Redis distributed lock | Another process holds the lock (or lock leaked) | Check if prior task completed; lock should auto-expire; in emergency, manually delete lock key |
| `ConnectionError` / `TimeoutError` | Redis | Redis down or network partition | Critical — caching, locks, OTP all fail; check Redis health |

## Celery / RabbitMQ

| Error / Pattern | Source | Root Cause | Action |
|----------------|--------|-----------|--------|
| Task stuck as `PENDING` forever | Celery | Worker not listening to the queue the task is routed to | Check `celery inspect active_queues`; ensure worker subscribes to the right queue |
| `SoftTimeLimitExceeded` | Celery | Task exceeded 60s soft limit | Check if task does blocking I/O or external calls that stalled |
| `TimeLimitExceeded` | Celery | Task exceeded 300s hard limit | Serious — task killed mid-execution; check for long-running queries or service timeouts |
| `AMQPConnectionError` | pika (producer) | RabbitMQ connection lost | Auto-retried 3 times with 5s delay; if persists, check RabbitMQ cluster |
| Queue depth growing | RabbitMQ | Workers not consuming fast enough | Scale workers for the affected queue |

## Application-level

| Error / Pattern | Source | Root Cause | Action |
|----------------|--------|-----------|--------|
| `ConflictException` (409) | Business logic | Concurrent modification detected | Check for duplicate requests; idempotency keys |
| `ServiceUnavailableException` (503) | Exception handler | Upstream service call failed | Check which service by tracing `IB_REQUEST_IDENTIFIER` |
| `ValidationError` (400) | DRF serializers | Invalid input data | Check request body in audit log |
| `IntegrityError` / unique constraint violation | PostgreSQL | Duplicate data insertion (race condition or retry) | Check for concurrent task execution; verify idempotency |
