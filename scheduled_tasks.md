## Scheduled tasks overview

**Goal**: Reference guide for all Celery scheduled tasks (beat schedule) that run periodically to sync data, reconcile balances, send notifications, and perform maintenance.

All tasks are defined in `config/settings/base.py::CELERY_BEAT_SCHEDULE`. This document groups them by functional area and explains what each task does.

---

## Lead and Saraloan sync tasks

### Send Leads To Saraloan
- **Schedule**: Every hour (`minute="0", hour="*/1"`)
- **Task**: `lead.tasks.send_lead_to_saraloan`
- **Purpose**: Processes leads that are ready to be shared with Saraloan and initiates the sharing process.
- **Dependencies**: Requires leads in appropriate status (`LeadSharingStatus.YET_TO_PROCESS` or similar).
- **Related flow**: See `lead_processing.md` for the complete lead flow.

### Sync Saraloan Lead Status
- **Schedule**: Every hour (`minute="0", hour="*/1"`)
- **Task**: `lead.tasks.sync_saraloan_leads_status`
- **Purpose**: Syncs lead statuses from Saraloan back to Locus to keep lead records up to date with lender decisions.
- **Dependencies**: Requires active `LeadLenderMap` and `LeadSaraloanMap` records.

### Retry Update Saraloan Partner Id
- **Schedule**: Every hour (`minute="0", hour="*/1"`)
- **Task**: `lead.tasks.saraloan_retry_partner_id_update`
- **Purpose**: Retries failed attempts to update partner IDs in Saraloan after customer activation.
- **Dependencies**: Leads that have been activated but partner ID sync failed.

### Saraloan Phase 1 Onboarding Rule Engine
- **Schedule**: Every hour (`minute="0", hour="*/1"`)
- **Task**: `lead.tasks.saraloan_phase_one_eligible_leads`
- **Purpose**: Evaluates leads for Phase 1 eligibility and triggers appropriate actions based on business rules.
- **Dependencies**: Leads in Phase 1 status with documents.

### Sync Failed PDC to Saraloan
- **Schedule**: Every hour (`minute="0", hour="*/1"`)
- **Task**: `lead.tasks.sync_pdc_to_saraloan`
- **Purpose**: Retries sharing Post Dated Cheques (PDC) to Saraloan that previously failed.
- **Dependencies**: Leads with PDC documents that failed to sync.

### Saraloan Customer Limit Enhancement
- **Schedule**: Every 30 minutes (`minute="30", hour="*"`)
- **Task**: `lead.tasks.saraloan_customer_limit_enhancement`
- **Purpose**: Processes limit enhancement requests by sharing required documents and transaction data to Saraloan.
- **Dependencies**: Leads with `ib_ticket_status == "limit_enhancement"`.

---

## Loan lifecycle and reconciliation tasks

### Create Loan From Invoice
- **Schedule**: Every hour (`minute="0", hour="*/1"`)
- **Task**: `invoice.tasks.create_loan_from_invoice`
- **Purpose**: Creates loans from invoices that are ready for loan creation. This is a key entry point for the loan lifecycle.
- **Dependencies**: Invoices in appropriate status, customer credit lines configured.
- **Related flow**: See `loan_lifecycle.md` for loan creation details.

### reconcile_all_gapl_loans
- **Schedule**: Twice daily at midnight and 1 PM (`minute="0", hour="0,13"`)
- **Task**: `loan.utility.reconcile_all_gapl_loans`
- **Purpose**: Runs reconciliation for all GAPL (internal) loans to ensure loan balances match payments and other adjustments.
- **Dependencies**: Payments, loans, and reconciliation entries.
- **Related flow**: See `loan_lifecycle.md` and `payment_processing.md` for reconciliation details.

### check_and_run_reconciliation_for_all_customers
- **Schedule**: Daily at 4 AM (`minute="0", hour="4"`)
- **Task**: `loan.tasks.check_and_run_reconciliation_for_all_customers`
- **Purpose**: Checks all customers for reconciliation needs and triggers reconciliation where required.
- **Dependencies**: Customer credit lines, loans, payments.

### share_oldest_loan_to_lender_for_all_partner
- **Schedule**: Daily at 3 AM (`minute="0", hour="3"`)
- **Task**: `loan.tasks.share_oldest_loan_to_lender_for_all_partners`
- **Purpose**: Shares the oldest eligible loans to external lenders (e.g., Saraloan) for all partners.
- **Dependencies**: Loans in `YET_TO_BE_DISBURSED` status, lender mappings configured.

### Move GAPL Loan to Lender
- **Schedule**: Daily at 12:30 AM (`minute="30", hour="0"`)
- **Task**: `loan.tasks.move_gapl_loan_to_lender`
- **Purpose**: Moves GAPL loans to lender status when conditions are met (e.g., overdue thresholds).
- **Dependencies**: Loans eligible for movement, lender integration configured.

### Sync Loan Accounts For Missed Notifs
- **Schedule**: Daily at 1 AM (`minute="0", hour="1"`)
- **Task**: `loan.tasks.sync_loan_account_processed_data_from_saraloan`
- **Purpose**: Syncs loan account data from Saraloan for loans that may have missed notification events.
- **Dependencies**: Active Saraloan integration, loan accounts.

### Send Loan Aging Severity Event
- **Schedule**: Daily at 2 AM (`minute="0", hour="2"`)
- **Task**: `loan.tasks.send_loan_aging_severity_event`
- **Purpose**: Emits events for loans that have aged beyond certain thresholds (for monitoring and alerting).
- **Dependencies**: Loans with aging data.

### Automated Action on Pending Invoice
- **Schedule**: Daily at 5 PM (`minute="0", hour="17"`)
- **Task**: `invoice.tasks.take_action_on_invoice_as_per_lender_action`
- **Enabled**: Yes
- **Purpose**: Takes automated actions on invoices based on lender responses (e.g., resharing, cancellation).
- **Dependencies**: Invoices with pending lender actions.

### Sync Invoice Status Saraloan
- **Schedule**: Daily at 4 PM (`minute="0", hour="16"`)
- **Task**: `invoice.tasks.fetch_and_update_invoice_status_at_lender`
- **Enabled**: No (disabled)
- **Purpose**: Syncs invoice status from Saraloan to update invoice records with lender-side status.
- **Dependencies**: Active Saraloan integration, invoice mappings.

### update_external_lender_supported_saraloan
- **Schedule**: Daily at 3 PM (`minute="0", hour="15"`)
- **Task**: `loan.tasks.update_external_lender_supported_saraloan`
- **Enabled**: Yes
- **Purpose**: Updates customer records to reflect whether they are supported by external lenders based on Saraloan data.
- **Dependencies**: Saraloan customer data.

### Interest Refund Automatic Credit Note Processing
- **Schedule**: Daily at 4:30 AM (`minute="30", hour="4"`)
- **Task**: `loan.tasks.interest_refund_automatic_credit_note_processing`
- **Purpose**: Processes automatic credit notes for interest refunds on loans.
- **Dependencies**: Loans with interest refund eligibility.

---

## Payment processing tasks

### Sync PG Payments
- **Schedule**: Every 2 minutes (`minute="*/2"`)
- **Task**: `payment_gateway.tasks.sync_pg_payments`
- **Purpose**: Syncs payment gateway (PG) payment statuses from external payment providers into Locus.
- **Dependencies**: Active payment gateway integrations, pending PG payments.
- **Related flow**: See `payment_processing.md` for payment creation and reconciliation.

### sync_repayment_info_for_all_dc
- **Schedule**: Daily at 7:30 PM (`minute="30", hour="19"`)
- **Task**: `payment.tasks.sync_repayment_info_for_all_dc`
- **Purpose**: Syncs repayment information from Saraloan for all Dehaat Centers (DCs).
- **Dependencies**: Saraloan repayment data, active DCs.

### unreconcile_gapl_payments
- **Schedule**: Twice daily at midnight and 1 PM (`minute="0", hour="0,13"`)
- **Task**: `payment.tasks.unreconcile_gapl_payments`
- **Purpose**: Unreconciles GAPL payments that meet certain conditions (e.g., stale reconciliations, data corrections).
- **Dependencies**: Reconciled payments, reconciliation entries.

### Check and Create LA Entries in SAP
- **Schedule**: Daily at 1 AM (`minute="0", hour="1"`)
- **Task**: `payment.tasks.check_and_create_la_entries_in_sap`
- **Purpose**: Checks for payments that need LA (Lender Adjustment) entries in SAP and creates them.
- **Dependencies**: Payments moved to lender, SAP integration configured.

### Send Disbursement Payments to ERP
- **Schedule**: Daily at 1 AM (`minute="0", hour="1"`)
- **Task**: `loan.tasks.send_disbursement_payments_to_erp`
- **Purpose**: Sends disbursement payment records to ERP systems (e.g., SAP) for accounting.
- **Dependencies**: Disbursed loans, ERP integration.

### Send Advance Refund Payments to ERP
- **Schedule**: Daily at 1 AM (`minute="0", hour="1"`)
- **Task**: `payment.tasks.send_failed_refund_payment_entries_to_sap`
- **Purpose**: Retries sending failed refund payment entries to SAP.
- **Dependencies**: Refund payments, SAP integration.

### Aggregate Payments for Transfer
- **Schedule**: Weekdays at 10:30 AM (`minute="30", hour="10", day_of_week="1-5"`)
- **Task**: `payment.tasks.aggregate_payment_transfer`
- **Purpose**: Aggregates `TRANSFER_TO_LENDER` payments per customer credit line into `AggregatedPaymentTransfer` records. See the \"Aggregated payment transfers to lenders\" section in `payment_processing.md` for the full pipeline.
- **Dependencies**: Payments in `TRANSFER_TO_LENDER` status, reconciliation consistency for the credit line.

### Transfer All Aggregated Payments
- **Schedule**: Weekdays at 10:35 AM (`minute="35", hour="10", day_of_week="1-5"`)
- **Task**: `payment.tasks.transfer_all_agg_payments`
- **Purpose**: Kicks off the actual bank/SAP transfer for all eligible aggregated payments by calling `transfer_agg_payment` and sending draft/transfer requests to external systems.
- **Dependencies**: `AggregatedPaymentTransfer` records created by the aggregation task.

### Sync All Aggregated Payments
- **Schedule**: Every hour at 15 minutes (`minute="15", hour="*/1"`)
- **Task**: `payment.tasks.sync_all_aggregated_payments`
- **Purpose**: Syncs status of aggregated payments from the payment service to update transfer status and complete the aggregated transfer flow.
- **Dependencies**: Aggregated payments, external transfer system.

### Reverse Aggregated Payments
- **Schedule**: Weekdays at 4 AM (`minute="0", hour="4", day_of_week="1-5"`)
- **Task**: `payment.tasks.reverse_aggregated_payments`
- **Purpose**: Reverses aggregated payments that failed, were rejected, or were refunded, and invokes `reverse_transfer_to_lender_partner_payments` to unwind the underlying payments.
- **Dependencies**: Failed/rejected/refunded aggregated payments, underlying payment mappings.

### Retry SAP Posting of Transfer to Lender Payments
- **Schedule**: Daily at 4 PM (`minute="0", hour="16"`)
- **Task**: `payment.tasks.retry_posting_or_deletion_of_transfer_to_lender_payments`
- **Enabled**: Yes
- **Purpose**: Retries posting or deletion of transfer-to-lender payments in SAP that previously failed.
- **Dependencies**: Transfer-to-lender payments, SAP integration.

### Update Interest Against Invoices
- **Schedule**: Every 5 minutes (`minute="*/5"`)
- **Task**: `invoice.tasks.update_interest_against_eligible_invoice`
- **Purpose**: Calculates and updates interest amounts for invoices that have entered interest-bearing periods.
- **Dependencies**: Invoices with interest start dates, interest calculation rules.

---

## Credit line management tasks

### sync_credit_lines_info_from_saraloan
- **Schedule**: Daily at 10 PM (`minute="0", hour="22"`)
- **Task**: `credit_line.tasks.sync_credit_lines_info_from_saraloan`
- **Purpose**: Syncs credit line information (limits, statuses, etc.) from Saraloan to Locus.
- **Dependencies**: Active Saraloan integration, customer credit lines.

### sync_loans_params_from_saraloan
- **Schedule**: Daily at 9:30 PM (`minute="30", hour="21"`)
- **Task**: `credit_line.tasks.sync_loans_params_from_saraloan`
- **Purpose**: Syncs loan parameters (interest rates, terms, etc.) from Saraloan.
- **Dependencies**: Saraloan loan parameter data.

### Update Credit Line Status Sub_Status
- **Schedule**: Daily at 2 AM (`minute="0", hour="2"`)
- **Task**: `credit_line.tasks.update_credit_lines_status`
- **Purpose**: Updates credit line status and sub-status based on current loan and payment state.
- **Dependencies**: Credit lines, loans, payments.

### Buffer End Date Actions
- **Schedule**: Daily at 4:30 PM (`minute="30", hour="16"`)
- **Task**: `credit_line.tasks.buffer_date_actions`
- **Purpose**: Performs actions when credit line buffer periods end (e.g., updating limits, triggering notifications).
- **Dependencies**: Credit lines with buffer periods.

### Sync Customers Saraloan Data
- **Schedule**: Daily at 4:30 PM (`minute="30", hour="16"`)
- **Task**: `credit_line.tasks.sync_customers_from_saraloan`
- **Enabled**: No (disabled)
- **Purpose**: Syncs customer data from Saraloan to keep customer records synchronized.
- **Dependencies**: Saraloan customer data.

### Sync Nodes from IB
- **Schedule**: Daily at 1 AM (`minute="0", hour="1"`)
- **Task**: `credit_line.tasks.sync_nodes_from_ib`
- **Purpose**: Syncs node (Dehaat Center) information from Integration Bridge (IB).
- **Dependencies**: IB integration, node data.

### Sync NACH Mandate Status on Credit Line
- **Schedule**: Daily at 10 PM (`minute="0", hour="22"`)
- **Task**: `credit_line.tasks.sync_nach_status_from_saraloan`
- **Purpose**: Syncs NACH (National Automated Clearing House) mandate status from Saraloan to credit lines.
- **Dependencies**: NACH mandates, Saraloan integration.

### Overdue Threshold Limit End Date Actions
- **Schedule**: Daily at 12:01 AM (`minute="1", hour="0"`)
- **Task**: `credit_line.tasks.overdue_threshold_limit_end_date_actions`
- **Purpose**: Performs actions when overdue threshold limits reach their end dates (e.g., reducing credit limits).
- **Dependencies**: Credit lines with overdue threshold limits.

### Collect User Profile Data From FinBox
- **Schedule**: Daily at 5 PM (`minute="0", hour="17"`)
- **Task**: `credit_line.tasks.collect_user_profile_data_from_finbox`
- **Purpose**: Collects user profile and creditworthiness data from FinBox for credit decisions.
- **Dependencies**: FinBox integration, user profiles.

---

## Notification and communication tasks

### Send Overdue Notification and Whatsapp Message
- **Schedule**: Daily at 4:30 AM (`minute="30", hour="4"`)
- **Task**: `credit_line.tasks.notify_overdue_partners_v2`
- **Purpose**: Sends overdue notifications and WhatsApp messages to partners with overdue amounts.
- **Dependencies**: Overdue loans/payments, partner contact information.

### Notify Overdue Invoices
- **Schedule**: Daily at 2:30 AM (`minute="30", hour="2"`)
- **Task**: `credit_line.tasks.notify_partners_for_overdue_invoices`
- **Purpose**: Sends notifications to partners about overdue invoices.
- **Dependencies**: Overdue invoices, partner contact information.

### Notify Overdue Partners
- **Schedule**: Daily at 12:30 AM (`minute="30", hour="0"`)
- **Task**: `credit_line.tasks.notify_overdue_partners`
- **Enabled**: No (disabled)
- **Purpose**: Legacy task for notifying overdue partners (replaced by `notify_overdue_partners_v2`).

### Notify Inactive Farmers
- **Schedule**: 1st and 15th of each month at 8 AM (`minute="0", hour="8", day_of_month="1,15"`)
- **Task**: `credit_line.tasks.send_notification_to_inactive_farmers`
- **Purpose**: Sends notifications to farmers who have been inactive for extended periods.
- **Dependencies**: Farmer records, inactivity thresholds.

### FF Repayment Demand Notification Engine
- **Schedule**: Daily at 8 AM (`minute="0", hour="8"`)
- **Task**: `repayment.tasks.initiate_repayment_reminder`
- **Purpose**: Sends repayment reminder notifications for farmer financing loans.
- **Dependencies**: Farmer financing loans, repayment schedules.

### Trigger event for GL for overdue communication
- **Schedule**: Daily at 8 AM (`minute="0", hour="8"`)
- **Task**: `farmer_financing.tasks.fetch_and_trigger_event_for_overdue_communication`
- **Purpose**: Triggers events for Group Leaders (GL) regarding overdue farmer financing loans.
- **Dependencies**: Farmer financing loans, group leader mappings.

### Trigger event with Cash in Hand
- **Schedule**: Daily at 7 PM (`minute="0", hour="19"`)
- **Task**: `farmer_financing.tasks.fetch_and_trigger_event_for_cash_in_hand`
- **Purpose**: Triggers events for farmers with cash-in-hand situations that need attention.
- **Dependencies**: Farmer financing records, cash-in-hand data.

### Trigger event having Over Due
- **Schedule**: Daily at 12:30 AM (`minute="30", hour="0"`)
- **Task**: `repayment.tasks.trigger_over_due_event`
- **Purpose**: Triggers overdue events for loans that have crossed overdue thresholds.
- **Dependencies**: Loans, overdue date calculations.

### Trigger DC_Authorization Notification
- **Schedule**: Daily at 9 AM (`minute="0", hour="9"`)
- **Task**: `farmer_financing.tasks.trigger_dc_authorization_notification`
- **Purpose**: Sends notifications for Dehaat Center (DC) authorization requests.
- **Dependencies**: DC authorization requests.

### Send Detailed Penalty Against OD PDF to DCs
- **Schedule**: Every hour (`minute="0", hour="*/1"`)
- **Task**: `credit_line.tasks.send_OD_invoice_penalty_detailed_breakup_PDFs_to_DC`
- **Enabled**: No (disabled)
- **Purpose**: Sends PDF reports of overdue invoice penalties to Dehaat Centers.

### Send Detailed Penalty Against OD PDF to SEs
- **Schedule**: Every hour (`minute="0", hour="*/1"`)
- **Task**: `credit_line.tasks.send_OD_invoice_penalty_detailed_breakup_PDFs_to_SEs`
- **Enabled**: No (disabled)
- **Purpose**: Sends PDF reports of overdue invoice penalties to Sales Executives.

---

## Farmer financing application tasks

### sync_application_status_from_saraloan_in_batches
- **Schedule**: Every 15 minutes (`minute="0,15,30,45"`)
- **Task**: `farmer_financing.tasks.sync_application_status_from_saraloan_in_batches`
- **Purpose**: Syncs farmer financing application statuses from Saraloan in batches.
- **Dependencies**: Farmer financing applications, Saraloan integration.

### batch_sync_single_farmer_application_status_from_saraloan
- **Schedule**: Every 2 minutes (`minute="*/2"`)
- **Task**: `farmer_financing.tasks.batch_sync_single_farmer_application_status_from_saraloan`
- **Purpose**: Syncs individual farmer application statuses from Saraloan more frequently.
- **Dependencies**: Single farmer applications, Saraloan integration.

### retry_single_farmer_onboarding_application
- **Schedule**: Every 4 minutes (`minute="*/4"`)
- **Task**: `farmer_financing.tasks.retry_single_farmer_onboarding_application`
- **Purpose**: Retries failed single farmer onboarding applications.
- **Dependencies**: Failed onboarding applications.

### update_esigned_applications_to_completed
- **Schedule**: Every 15 minutes (uses `CRONTAB_MINUTE_REPEAT_15`)
- **Task**: `farmer_financing.tasks.update_esigned_applications_to_completed`
- **Purpose**: Updates farmer financing applications to completed status after e-signature is confirmed.
- **Dependencies**: E-signed applications, signature verification.

### Assign Credit Limit To Underwriting Applications
- **Schedule**: Every 15 minutes (uses `CRONTAB_MINUTE_REPEAT_15`)
- **Task**: `farmer_financing.tasks.assign_credit_limit_to_underwriting_applications`
- **Purpose**: Assigns credit limits to applications that have completed underwriting.
- **Dependencies**: Underwriting applications, credit limit rules.

### Check and create payout
- **Schedule**: Daily at 3 AM (`minute="0", hour="3"`)
- **Task**: `farmer_financing.tasks.check_and_create_payout`
- **Enabled**: No (disabled)
- **Purpose**: Checks for eligible payouts and creates payout records for farmers.

---

## Customer journal and reconciliation tasks

### Reconciliation Entries
- **Schedule**: Daily at 11:15 PM (`minute="15", hour="23"`)
- **Task**: `customer_journal.tasks.reconcile_customers_entries`
- **Purpose**: Reconciles customer journal entries to ensure accounting accuracy.
- **Dependencies**: Customer journal entries, reconciliation rules.

### Send Reconciliation Entries to SAP
- **Schedule**: Daily at 10:45 PM (`minute="45", hour="22"`)
- **Task**: `customer_journal.tasks.send_recon_entries_to_sap`
- **Purpose**: Sends reconciled journal entries to SAP for accounting integration.
- **Dependencies**: Reconciliation entries, SAP integration.

### Update Long time in_progress recon entries
- **Schedule**: Twice daily at 10:30 AM and 10:30 PM (`minute="30", hour="10,22"`)
- **Task**: `customer_journal.tasks.update_in_progress_remained_entries`
- **Purpose**: Updates reconciliation entries that have been in progress for too long (stale entries).
- **Dependencies**: In-progress reconciliation entries.

### Move Line Items SAP to Entry
- **Schedule**: Every 30 minutes (`minute="*/30"`)
- **Task**: `customer_journal.tasks.move_line_items`
- **Purpose**: Moves line items from SAP into customer journal entries.
- **Dependencies**: SAP line items, journal entry structure.

### Move Raw Line Items
- **Schedule**: Every 5 minutes (`minute="*/5"`)
- **Task**: `customer_journal.tasks.move_raw_line_items`
- **Purpose**: Processes raw line items and converts them into structured journal entries.
- **Dependencies**: Raw line item data.

---

## Virtual account and repayment tasks

### Sync Customer Virtual Accounts
- **Schedule**: Daily at 11 PM (`minute="0", hour="23"`)
- **Task**: `repayment.tasks.fetch_virtual_account_details_saraloan`
- **Purpose**: Syncs virtual account details from Saraloan for customers.
- **Dependencies**: Virtual accounts, Saraloan integration.

### Sync Customer Virtual Accounts from Saraloan
- **Schedule**: Daily at 11 PM (`minute="0", hour="23"`)
- **Task**: `virtual_account.tasks.sync_virtual_account_details_from_saraloan`
- **Purpose**: Alternative/additional sync for virtual account details from Saraloan.
- **Dependencies**: Virtual accounts, Saraloan integration.

### Sync Customer Virtual Accounts to Sap
- **Schedule**: Every 2 hours (`minute="0", hour="*/2"`)
- **Task**: `virtual_account.tasks.sync_va_to_sap`
- **Enabled**: No (disabled)
- **Purpose**: Syncs virtual account information to SAP.

### Mark Inactive Transaction References
- **Schedule**: Daily at 2 AM (`minute="0", hour="2"`)
- **Task**: `repayment.tasks.update_failure_for_stale_transaction_references`
- **Purpose**: Marks transaction references as failed if they have been inactive/stale for too long.
- **Dependencies**: Transaction references, staleness thresholds.

---

## Maintenance and utility tasks

### collect_and_send_emails
- **Schedule**: Daily at 3 AM (`minute="0", hour="3"`)
- **Task**: `common.tasks.collect_and_send_emails`
- **Purpose**: Collects queued emails and sends them in batches.
- **Dependencies**: Email queue, email service configuration.

### purge_events_and_emails
- **Schedule**: Daily at 4 PM (`minute="0", hour="16"`)
- **Task**: `common.tasks.purge_sent_emails`
- **Purpose**: Purges old sent emails and events to maintain database size.
- **Dependencies**: Sent emails, retention policies.

### Retry Pending PubSub Events
- **Schedule**: Daily at 3:30 PM (`minute="30", hour="15"`)
- **Task**: `common.tasks.retry_pending_and_failed_pubsub_events`
- **Purpose**: Retries failed PubSub events (e.g., Google Cloud Pub/Sub) that need to be republished.
- **Dependencies**: PubSub event queue, PubSub service.

### Update Entries visible active flag
- **Schedule**: Every 5 minutes (`minute="*/5"`)
- **Task**: `ledger.tasks._update_debit_record_payment_visibility`
- **Purpose**: Updates visibility flags on ledger entries based on payment reconciliation status.
- **Dependencies**: Ledger entries, payment reconciliation status.

### Update Old Entries visible active flag
- **Schedule**: Twice daily at 1:05 AM and 1:05 PM (`minute="5", hour="1,13"`)
- **Task**: `ledger.tasks._update_old_debit_record_payment_visibility`
- **Purpose**: Updates visibility flags on older ledger entries that may have been missed.
- **Dependencies**: Older ledger entries, payment reconciliation status.

### Copy S3 data
- **Schedule**: February 29th at midnight (`minute="0", hour="0", day_of_month="29", month_of_year="2"`)
- **Task**: `common.tasks.copy_s3_object`
- **Enabled**: No (disabled)
- **Purpose**: One-time or periodic S3 data copy operation (likely for backups or migrations).

### Multiple create virtual gapl accounts
- **Schedule**: February 29th at midnight (`minute="0", hour="0", day_of_month="29", month_of_year="2"`)
- **Task**: `virtual_account.utils.async_multiple_virtual_account_create_delete`
- **Enabled**: No (disabled)
- **Purpose**: Bulk operation for creating or deleting virtual GAPL accounts.

---

## Disabled or legacy tasks

The following tasks are defined but currently disabled (`"enabled": False`):

- `initiate_emi_auto_debit_request` - Auto-debit for EMI payments
- `Revert LOCUS and Ledger Migrations` - Odoo migration rollback
- `Migrate Odoo Nodes to LOCUS` - Odoo migration
- `Migrate Overdue Credit Dates from Odoo` - Odoo migration
- `Migrate Lender Payments to Ledger` - Odoo migration
- `Migrate Odoo Data to LOCUS/Ledger` - Odoo migration
- `Sync Partner's Saraloan Data` - Partner-level sync
- `Move GAPL Payment to Lender` - Payment movement
- `Sync Customers Saraloan Data` - Customer sync
- `Sync Invoice Status Saraloan` - Invoice status sync
- `Sync Customer Virtual Accounts to Sap` - VA sync
- `Generate gapl virtual accounts for financed dc` - VA generation
- `Check and create payout` - Payout creation
- `Notify Overdue Partners` - Legacy notification
- `Send Detailed Penalty Against OD PDF to DCs` - PDF reports
- `Send Detailed Penalty Against OD PDF to SEs` - PDF reports

These tasks may be re-enabled for specific operations or kept for historical reference.

---

## Task dependencies and execution order

Some tasks depend on others completing first. Key sequences:

1. **Loan creation flow**:
   - `Create Loan From Invoice` (hourly) → creates loans
   - `share_oldest_loan_to_lender_for_all_partner` (3 AM) → shares to lenders
   - `reconcile_all_gapl_loans` (midnight, 1 PM) → reconciles balances

2. **Payment processing flow**:
   - `Sync PG Payments` (every 2 min) → syncs payment status
   - `check_and_run_reconciliation_for_all_customers` (4 AM) → reconciles
   - `Check and Create LA Entries in SAP` (1 AM) → creates SAP entries

3. **Daily sync sequence** (evening):
   - `sync_credit_lines_info_from_saraloan` (10 PM)
   - `Sync NACH Mandate Status on Credit Line` (10 PM)
   - `Sync Customer Virtual Accounts` (11 PM)
   - `Reconciliation Entries` (11:15 PM)
   - `Send Reconciliation Entries to SAP` (10:45 PM)

4. **Notification sequence** (morning):
   - `Send Overdue Notification and Whatsapp Message` (4:30 AM)
   - `FF Repayment Demand Notification Engine` (8 AM)
   - `Trigger event for GL for overdue communication` (8 AM)

---

## Monitoring and troubleshooting

When investigating issues:

1. **Check task execution logs**: Look for Celery worker logs and task-specific error messages.
2. **Verify dependencies**: Ensure upstream data (e.g., Saraloan responses, payment gateway data) is available.
3. **Check enabled status**: Some tasks may be disabled; verify in `CELERY_BEAT_SCHEDULE`.
4. **Review task frequency**: High-frequency tasks (every 2-5 minutes) may indicate real-time sync needs.
5. **Monitor reconciliation tasks**: Reconciliation tasks run at specific times; ensure they complete successfully.

---

## Where to read next

- For understanding how loans are created and managed, see `loan_lifecycle.md`.
- For payment processing and reconciliation details, see `payment_processing.md`.
- For lead processing that triggers many of these syncs, see `lead_processing.md`.
