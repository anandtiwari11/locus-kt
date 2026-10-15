# System Overview

## What is Input Backend?

A Django 3.x / DRF monolith for **Dehaat's agri-input B2B commerce platform**. It manages catalog, orders, delivery, payments, accounting, customer onboarding, and field operations for Dehaat Centres (DCs) — retail points that sell agricultural inputs to farmers.

## Tech stack

| Layer | Technology |
|-------|-----------|
| Framework | Django 3.x + Django REST Framework |
| Language | Python 3.9 |
| Primary DB | PostgreSQL 14 |
| Cache / locks | Redis |
| Task queue | Celery (RabbitMQ broker, Django DB result backend) |
| Event bus | RabbitMQ (pika for producer, kube_kombu for consumers) |
| Object storage | AWS S3 |
| IAM | Keycloak |
| Error tracking | Honeybadger |
| Metrics | Prometheus (django_prometheus) |
| Analytics DB | AWS Redshift (read-only) |
| Growth plan DB | Noxl (separate PostgreSQL) |

## Application apps (Django INSTALLED_APPS)

### Core business
- `sale` — orders, intents, pre-orders, STOs
- `products` — catalog, pricing, inventory
- `delivery` — dispatch, PGI, invoicing
- `returns` — customer returns
- `stock_management` — warehouse operations
- `discount_schemes` — ABS, TOD, benefits, coupons
- `accounting` — holds, releases, refunds
- `payments` — PG transactions, refunds
- `pay_by_invoice` — ledger settlement
- `wallet` — external wallet integration

### Customer / user
- `customer_management` — DC master data
- `onboarding` — KYC, tickets, security deposits
- `user_management` — employee/coordinator APIs, FCM
- `input_backend.users` — core User model

### Integrations
- `webhook` — SAP/PG inbound events
- `sap_wrap` — SAP polling + read APIs
- `forward_request` — HTTP proxy to Core API
- `rabbitmq_producer` — transactional outbox pattern
- `rabbitmq_consumer` — event consumption adapters

### Operations / field
- `task_management` — visit planning, POG
- `attendance` — check-in/out, GPS distance
- `variable_pay` — performance metrics (Redshift)
- `growth_plan` — demand planning (Noxl)
- `finance` — credit/transaction read APIs
- `app_views` — merchandising strips/widgets

### Infrastructure
- `input_backend.common` — master data (geo, nodes, plants, config, roles)
- `common` (root) — auth, renderers, pagination, permissions, constants, coupon/credit helpers
- `transactional_notification` — push notification pipeline
- `sms_notification` — OTP storage/verification
- `audit_log` — HTTP request/response logging
- `product_search` — trigram autocomplete
- `health_check` — K8s probes
- `ledger_mock` — dev stub for ledger service

## Data stores

| Store | Purpose |
|-------|---------|
| PostgreSQL (primary) | All Django models, Celery results, Celery beat schedules |
| Redis | Cache (`ConfigVariable`, product lists, app views), distributed locks (SAP sync, event processing), OTP storage |
| S3 | Media uploads, coordinator images, CSV imports/exports, invoice PDFs |
| Redshift | Read-only analytics for variable pay metrics |
| Noxl (Postgres) | Growth plan / demand planning data |

## ConfigVariable — runtime feature flags

`input_backend.common.models.ConfigVariable` is a key/value store used **everywhere** for:
- Feature toggles (e.g. `bypass_publish_to_rmq`, `enable_va_creation_on_va_service`)
- Timeouts (service call timeouts)
- Sync cursors (`SAP_SYNC.*_LAST_UPDATE_TIME`)
- Business rules (e.g. `delivery_eligible_orders_days_limit`)
- Cache-invalidated on save/delete

## System interaction map

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        EXTERNAL SYSTEMS                                 │
├──────────┬──────────┬──────────┬──────────┬──────────┬─────────────────┤
│   SAP    │  Locus   │  Odoo    │ Keycloak │ Payment  │  Others:        │
│ (OData)  │ (Credit) │ (Legacy) │  (IAM)   │ Gateway  │ Mailman, Google,│
│          │          │          │          │ + VA Svc │ Discount, Rule  │
│          │          │          │          │          │ Engine, Identity │
│          │          │          │          │          │ Aeros, Redshift  │
└────┬─────┴────┬─────┴────┬─────┴────┬─────┴────┬─────┴────┬────────────┘
     │          │          │          │          │          │
     ▼          ▼          ▼          ▼          ▼          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    services/ (HTTP clients)                              │
│  sap/ | locus/ | odoo/ | keycloak/ | payment_service/ | va_service/    │
│  mailman/ | discount_service/ | rule_engine/ | identity_master/ | ...  │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
┌────────────────────────────────┼────────────────────────────────────────┐
│                    DJANGO APPS (Business Logic)                         │
│                                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────┐             │
│  │ products │  │   sale   │  │ delivery │  │ accounting │             │
│  │ (catalog)│◄►│ (orders) │◄►│(dispatch)│  │(holds/rel) │             │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └─────┬──────┘             │
│       │              │              │              │                     │
│  ┌────┴─────┐  ┌─────┴──────┐  ┌──┴───────┐  ┌───┴──────┐            │
│  │ product  │  │  discount  │  │  returns  │  │ payments │            │
│  │ _search  │  │  _schemes  │  │           │  │          │            │
│  └──────────┘  └────────────┘  └───────────┘  └──────────┘            │
│                                                                         │
│  ┌──────────────┐ ┌──────────────┐ ┌───────────────┐                   │
│  │   customer   │ │  onboarding  │ │    webhook    │                   │
│  │  _management │ │   (KYC)      │ │  (SAP/PG in)  │                   │
│  └──────────────┘ └──────────────┘ └───────┬───────┘                   │
│                                            │                            │
│  ┌──────────┐ ┌──────────────┐ ┌───────────┴──┐                       │
│  │  wallet  │ │pay_by_invoice│ │   sap_wrap   │                       │
│  └──────────┘ └──────────────┘ │  (SAP poll)  │                       │
│                                └──────────────┘                        │
│  ┌──────────────┐ ┌────────────┐ ┌─────────────┐ ┌──────────┐        │
│  │    stock     │ │  finance   │ │task_mgmt    │ │attendance│        │
│  │  _management │ │  (read)    │ │(field visit)│ │          │        │
│  └──────────────┘ └────────────┘ └─────────────┘ └──────────┘        │
│  ┌──────────────┐ ┌────────────┐ ┌─────────────┐                      │
│  │ variable_pay │ │ growth_plan│ │  app_views  │                      │
│  └──────────────┘ └────────────┘ └─────────────┘                      │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
┌────────────────────────────────┼────────────────────────────────────────┐
│                    ASYNC INFRASTRUCTURE                                  │
│                                                                         │
│  ┌─────────────────┐    ┌──────────────────┐    ┌───────────────────┐  │
│  │   RabbitMQ      │    │    Celery         │    │   Redis           │  │
│  │  ┌───────────┐  │    │  ~197 tasks       │    │  - Caching        │  │
│  │  │ Producer  │  │    │  24 task modules  │    │  - Locks          │  │
│  │  │(outbox    │  │    │  DB beat scheduler│    │  - OTP            │  │
│  │  │ pattern)  │  │    │  Named queues     │    │  - Feature flags  │  │
│  │  └───────────┘  │    └──────────────────┘    └───────────────────┘  │
│  │  ┌───────────┐  │                                                    │
│  │  │ Consumer  │  │    ┌──────────────────┐    ┌───────────────────┐  │
│  │  │(kube_kombu│  │    │ Transactional    │    │  SMS Notification │  │
│  │  │ adapters) │  │    │ Notification     │    │  (OTP/templates)  │  │
│  │  └───────────┘  │    └──────────────────┘    └───────────────────┘  │
│  └─────────────────┘                                                    │
└─────────────────────────────────────────────────────────────────────────┘
                                 │
┌────────────────────────────────┼────────────────────────────────────────┐
│                    DATA STORES                                          │
│  PostgreSQL 14 (primary) | Redis | S3 | Redshift | Noxl (Postgres)    │
└─────────────────────────────────────────────────────────────────────────┘
```
