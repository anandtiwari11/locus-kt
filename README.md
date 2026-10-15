# Input Backend — System Context for RCA Agent

This directory contains structured system context for the Input Backend monolith.
An AI agent uses these files to understand the system when debugging production issues.

## How to use

1. **Start here** — read `system_overview.md` for architecture, tech stack, and the interaction map.
2. **Identify the module** — use the symptom or error to pick the right file under `modules/`.
3. **Check infrastructure** — if the issue involves async processing, events, or external calls, read the relevant file under `infrastructure/`.
4. **RCA patterns** — `rca_patterns.md` maps common symptoms to modules and investigation steps.

## File index

### Top-level

| File | Purpose |
|------|---------|
| `system_overview.md` | Tech stack, app list, data stores, interaction map |
| `rca_patterns.md` | Symptom → module → investigation checklist |
| `db_context.md` | All Django models, relationships, constraints, risky patterns, debug queries |
| `config_variables.md` | Critical ConfigVariable flags, SAP sync cursors, timeouts |
| `error_catalog.md` | Common error messages by system with root causes and fixes |
| `task_graph.md` | Async task and event dependency chains for tracing flows |
| `past_incidents.md` | Historical incident log — add resolved incidents here for pattern matching |

### `modules/` — one file per business domain

| File | Django app(s) | Domain |
|------|--------------|--------|
| `products.md` | `products`, `product_search` | Catalog, pricing, inventory, search |
| `sale.md` | `sale` | Orders, intents, pre-orders, STOs, SAP sync |
| `delivery.md` | `delivery` | Dispatch, PGI, invoicing, OTP, slots |
| `accounting.md` | `accounting` | Holds, releases, refunds, SAP sync |
| `payments.md` | `payments`, `pay_by_invoice`, `wallet` | PG, VA, refunds, ledger settlement, wallet |
| `webhook.md` | `webhook`, `sap_wrap` | SAP/PG inbound events, scheduled SAP polling |
| `customer_management.md` | `customer_management` | DC master data, VA, WhatsApp, Freshdesk |
| `onboarding.md` | `onboarding` | KYC, tickets, security deposits, lender leads |
| `user_management.md` | `user_management`, `input_backend/users` | Employees, coordinators, FCM, auth |
| `stock_management.md` | `stock_management` | Warehouse ops, GRN, picklists, trips, e-way |
| `returns.md` | `returns` | Customer returns, SAP sync, discount reversal |
| `discount_schemes.md` | `discount_schemes` | ABS, TOD, benefits, coupons, reward tiers |
| `finance.md` | `finance` | Credit, transactions, invoices (read APIs) |
| `field_ops.md` | `task_management`, `attendance`, `variable_pay` | Visit planning, GPS, performance metrics |
| `app_views.md` | `app_views`, `growth_plan` | Merchandising, widgets, demand planning |

### `infrastructure/` — cross-cutting systems

| File | Covers |
|------|--------|
| `celery.md` | Task engine config, queues, beat schedule, all tasks by app |
| `rabbitmq.md` | Producer outbox, consumer adapters, exchanges, routing keys |
| `services.md` | All external service clients, auth, error patterns |
| `middleware_and_auth.md` | Middleware stack, Keycloak auth, permissions, notifications, audit |
