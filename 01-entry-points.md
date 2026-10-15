# Entry Point Registry

> All system entry points that trigger credit operations in the Locus credit system.
> For each entry point, the **user_id parameter location** and **file path + function name** are specified.

**User Identifier Convention**: The system uses `source_identifier_id` (on `Customer`) and `partner_id` (on `LedgerEntry`). These are used interchangeably in many contexts.

---

## 1. Django API Endpoints

All endpoints are registered in `config/urls.py` and delegated to app-level URL configs.

### 1.1 Credit Line (`credit_line/`)

| Endpoint | View Class | Method | user_id Location | File Path |
|----------|-----------|--------|-----------------|-----------|
| `credit-line/business/<source_identifier_id>` | `ListCreditLines` | GET | URL path: `source_identifier_id` | `credit_line/views.py:ListCreditLines.get()` |
| `credit-line/v2/business/<source_identifier_id>` | `ListCreditLinesV2` | GET | URL path: `source_identifier_id` | `credit_line/views.py:ListCreditLinesV2.get()` |
| `credit-line/dba/business/<farmer_auth_id>/<dc_sap_id>` | `ListCreditLinesDBA` | GET | URL path: `farmer_auth_id` | `credit_line/views.py:ListCreditLinesDBA.get()` |
| `credit-line/v1/ivr/credit-line-status` | `CreditLinesStatus` | GET | Query param: `source_identifier_id` | `credit_line/views.py:CreditLinesStatus.get()` |
| `credit-line/v1/ivr/check-outstanding-amount` | `CreditLinesOutstandingAmount` | GET | Query param: `source_identifier_id` | `credit_line/views.py:CreditLinesOutstandingAmount.get()` |
| `credit-line/v2/ivr/menu-url-msg` | `GetMenuUrlMsg` | GET | Query param: `source_identifier_id` | `credit_line/views.py:GetMenuUrlMsg.get()` |
| `credit-line/v2/ivr/order-details` | `LenderCreditOrderDetails` | GET | Query param: `source_identifier_id` | `credit_line/views.py:LenderCreditOrderDetails.get()` |
| `credit-line/v2/ivr/credit-line-status` | `CreditLineStatusV2` | GET | Query param: `source_identifier_id` | `credit_line/views.py:CreditLineStatusV2.get()` |
| `credit-line/v2/ivr/credit-line-failure` | `CreditLineStatusFailureView` | GET | Query param: `source_identifier_id` | `credit_line/views.py:CreditLineStatusFailureView.get()` |
| `credit-line/v2/ivr/check-outstanding-amount` | `CreditLinesOutstandingAmountV2` | GET | Query param: `source_identifier_id` | `credit_line/views.py:CreditLinesOutstandingAmountV2.get()` |
| `credit-line/v1/business/creditlines` | `ListMultipleCustomersCreditLines` | GET | Query param: `source_identifier_ids` (list) | `credit_line/views.py:ListMultipleCustomersCreditLines.get()` |
| `credit-line/v1/customer/<source_identifier_id>` | `CustomerInfo` | GET | URL path: `source_identifier_id` | `credit_line/views.py:CustomerInfo.get()` |
| `credit-line/v1/customer-with-gapl-line` | `CustomerWithGaplLineViewSet` | POST | Request body: `source_identifier_id` | `credit_line/views.py:CustomerWithGaplLineViewSet.post()` |
| `credit-line/v1/ivr/credit-limit-status` | `CreditLimitStatus` | GET | Query param: `source_identifier_id` | `credit_line/views.py:CreditLimitStatus.get()` |
| `credit-line/fsfe_user/<source_id>` | `BusinessUserCreateViewSet` | GET/DELETE | URL path: `source_id` | `credit_line/views.py:BusinessUserCreateViewSet` |
| `credit-line/fsfe_user` | `BusinessUserCreateViewSet` | POST | Request body | `credit_line/views.py:BusinessUserCreateViewSet` |
| `credit-line/user-dc-map/<user_source_id>` | `BusinessUserMappingViewSet` | GET | URL path: `user_source_id` | `credit_line/views.py:BusinessUserMappingViewSet` |
| `credit-line/v1/credit-summary-dashboard` | `CreditSummaryDashboardView` | GET | Query param: `source_identifier_id` | `credit_line/views.py:CreditSummaryDashboardView.get()` |
| `credit-line/v1/credit-program-detail-list` | `ListCreditProgramDetailsView` | GET | Query param | `credit_line/views.py:ListCreditProgramDetailsView.list()` |
| `credit-line/business/get_customer_tag` | `ListCustomerTag` | GET | Query param | `credit_line/views.py:ListCustomerTag.get()` |
| `credit-line/v1/ivr/notify-inactive-farmers` | `NotificationInactiveFarmers` | GET | N/A (batch) | `credit_line/views.py:NotificationInactiveFarmers.get()` |
| `credit-line/v1/customer-consent` | `UpdateCustomerConsent` | PATCH | Request body: `source_identifier_id` | `credit_line/views.py:UpdateCustomerConsent.patch()` |
| `credit-line/v1/customer-device-info/<source_identifier_id>` | `CustomerDeviceConsentInfo` | GET | URL path: `source_identifier_id` | `credit_line/views.py:CustomerDeviceConsentInfo.get()` |
| `credit-line/customer-credit-data` | `CustomerCreditData` | GET | Query param: `source_identifier_id` | `credit_line/views.py:CustomerCreditData.get()` |
| `credit-line/get-otg-filter-data/<filter_type>` | `GetOtgFilterData` | GET | Query param | `credit_line/views.py:GetOtgFilterData.get()` |
| `credit-line/update-customer-node` | `UpdateCustomerNode` | PATCH | Request body | `credit_line/views.py:UpdateCustomerNode.patch()` |
| `credit-line/v1/overdue-by-date` | `ListMultipleCustomerOverdueByDate` | GET | Query param: `source_identifier_ids` | `credit_line/views.py:ListMultipleCustomerOverdueByDate.get()` |
| `credit-line/customers/` | `CustomerListView` | GET | Query param | `credit_line/views.py:CustomerListView.get()` |


### 1.2 Loan (`loan/`)

| Endpoint | View Class | Method | user_id Location | File Path |
|----------|-----------|--------|-----------------|-----------|
| `loan/loans` | `LoanViewSet` | GET/POST | Query param: `customer_credit_line` (GET), Request body: `customer_credit_line` (POST) | `loan/views.py:LoanViewSet.post()`, `LoanViewSet.get_queryset()` |
| `loan/invoices` | `InvoiceLoanViewSet` | GET | Query param: `customer_credit_line` | `loan/views.py:InvoiceLoanViewSet.get_queryset()` |
| `loan/interest-invoices` | `InvoicesWithInterestViewSet` | GET | Query param: `customer_credit_line` | `loan/views.py:InvoicesWithInterestViewSet.list()` |
| `loan/invoice-summary` | `InvoiceSummaryViewSet` | GET/POST | Query param / Request body: `source_identifier_id` | `loan/views.py:InvoiceSummaryViewSet.get()`, `.post()` |
| `loan/invoice/cancel` | `InvoiceCancelView` | PATCH | Request body: invoice identifiers | `loan/views.py:InvoiceCancelView.patch()` |
| `loan/update-status` | `LoanStatusViewSet` | POST | Request body: loan identifiers | `loan/views.py:LoanStatusViewSet.post()` |
| `loan/create-breakup` | `LoansBreakupViewSet` | GET | Query param: `source_identifier_id` | `loan/views.py:LoansBreakupViewSet.get()` |
| `loan/total-purchase-repayment` | `TotalPurchaseAndRepaymentViewSet` | GET | Query param: `source_identifier_id` | `loan/views.py:TotalPurchaseAndRepaymentViewSet.get()` |
| `loan/simulate-reconciliation` | `SimulateReconciliation` | GET | Query param: `source_identifier_id` | `loan/views.py:SimulateReconciliation.get()` |

### 1.3 Payment (`payment/`)

| Endpoint | View Class | Method | user_id Location | File Path |
|----------|-----------|--------|-----------------|-----------|
| `payment/payments` | `PaymentViewSet` | GET/POST/PATCH | Query param: `customer_credit_line` (GET), Request body (POST/PATCH) | `payment/views.py:PaymentViewSet.list()`, `.post()`, `.patch()` |
| `payment/creditnotes` | `CreditNoteViewSet` | GET/POST | Query param: `customer_credit_line` (GET), Request body (POST) | `payment/views.py:CreditNoteViewSet.post()` |
| `payment/debitnotes` | `DebitNoteViewSet` | POST | Request body | `payment/views.py:DebitNoteViewSet.post()` |
| `payment/breakup` | `PaymentBreakupViewSet` | GET | Query param: `source_identifier_id` | `payment/views.py:PaymentBreakupViewSet.get()` |
| `payment/payment/cancel` | `PaymentCancelView` | PATCH | Request body: payment identifiers | `payment/views.py:PaymentCancelView.patch()` |
| `payment/credit-note/cancel` | `CreditNoteCancelView` | PATCH | Request body | `payment/views.py:CreditNoteCancelView.patch()` |
| `payment/debit-note/cancel` | `DebitNoteCancelView` | PATCH | Request body | `payment/views.py:DebitNoteCancelView.patch()` |
| `payment/v1/user/<user_source_id>/vpa-lender-repayment` | `RetrieveUpdateTransactionInfoView` | GET/POST/PATCH | URL path: `user_source_id` | `payment/views.py:RetrieveUpdateTransactionInfoView` |
| `payment/disbursal-payments` | `DisbPaymentViewSet` | POST | Request body | `payment/views.py:DisbPaymentViewSet.post()` |
| `payment/disbursal-payments/cancel` | `DisbPaymentCancelViewSet` | PATCH | Request body | `payment/views.py:DisbPaymentCancelViewSet.patch()` |
| `payment/sap-disbursal-payments-ack` | `SapPaymentPostingAckViewSet` | PATCH | Request body | `payment/views.py:SapPaymentPostingAckViewSet.patch()` |
| `payment/publish-reconcile-payments` | `ReconcilePaymentsAPIView` | GET | Query param: `source_identifier_id` | `payment/views.py:ReconcilePaymentsAPIView.get()` |

### 1.4 Repayment (`repayment/`)

| Endpoint | View Class | Method | user_id Location | File Path |
|----------|-----------|--------|-----------------|-----------|
| `repayment/<api_version>/transaction` | `ListCreateTransactionView` | GET/POST | Query param: `farmer_id` (GET), Request body: `payer` (POST) | `repayment/views.py:ListCreateTransactionView.post()`, `.list()` |
| `repayment/v1/transaction/<transaction_id>` | `ListModifyTransactionView` | PATCH | URL path: `transaction_id` | `repayment/views.py:ListModifyTransactionView.patch()` |
| `repayment/v1/create-multiple-deposit` | `DepositView.create_multiple_vpa_deposits` | POST | Request body: `payer` | `repayment/views.py:DepositView.create_multiple_vpa_deposits()` |
| `repayment/v1/update-multiple-deposit` | `DepositView.update_multiple_vpa_deposits` | POST | Request body | `repayment/views.py:DepositView.update_multiple_vpa_deposits()` |
| `repayment/v1/create-full-deposits` | `DepositView.create_full_amount_deposits` | POST | Request body | `repayment/views.py:DepositView.create_full_amount_deposits()` |
| `repayment/v1/save-csc-bank-deposits` | `DepositView.save_multiple_bank_csc_deposits` | POST | Request body | `repayment/views.py:DepositView.save_multiple_bank_csc_deposits()` |
| `repayment/v1/aggregated-amount` | `RetrieveAggregatedAmountView` | GET | Query param: `farmer_id` | `repayment/views.py:RetrieveAggregatedAmountView.retrieve()` |
| `repayment/v1/dba-aggregated-details` | `RetrieveDBAAggregateDetailsView` | GET | Query param | `repayment/views.py:RetrieveDBAAggregateDetailsView.retrieve()` |
| `repayment/v1/farmers` | `ListFarmersView` | GET | Query param: `dc_id` (lists farmers for DC) | `repayment/views.py:ListFarmersView.list()` |
| `repayment/v1/group-leaders` | `ListGroupLeadersView` | GET | Query param | `repayment/views.py:ListGroupLeadersView.list()` |
| `repayment/v1/group-leader/<group_leader>/transaction` | `ListGroupLeaderTransactionView` | GET | URL path: `group_leader` | `repayment/views.py:ListGroupLeaderTransactionView.get_queryset()` |
| `repayment/v1/farmer/<farmer_id>/lender-interest` | `GetLenderAndInterestRateView` | GET | URL path: `farmer_id` | `repayment/views.py:GetLenderAndInterestRateView.get()` |
| `repayment/v1/farmer/<farmer_id>/collections` | `ListFarmerCollectionsView` | GET | URL path: `farmer_id` | `repayment/views.py:ListFarmerCollectionsView.get_queryset()` |
| `repayment/<api_version>/collections-without-deposit` | `ListCollectionsWithoutDeposit` | GET | Query param | `repayment/views.py:ListCollectionsWithoutDeposit.list()` |
| `repayment/v1/non-deposited-collections-aggregated` | `RetrieveAggregatedNonDepositedCollections` | GET | Query param | `repayment/views.py:RetrieveAggregatedNonDepositedCollections.retrieve()` |
| `repayment/v1/ivr-repayment-otp` | `IVRRepaymentOTPView` | GET | Query param: `source_identifier_id` | `repayment/views.py:IVRRepaymentOTPView.get()` |
| `repayment/v1/ivr/next-installment-status` | `IVRNextInstallmentStatus` | GET | Query param: `source_identifier_id` | `repayment/views.py:IVRNextInstallmentStatus.get()` |
| `repayment/v1/ivr/repayment-status` | `IVRRepaymentStatus` | GET | Query param: `source_identifier_id` | `repayment/views.py:IVRRepaymentStatus.get()` |
| `repayment/v1/ivr/fsfe-deposit-otp` | `IVRDepositToFSFEOTPView` | GET | Query param | `repayment/views.py:IVRDepositToFSFEOTPView.get()` |
| `repayment/v1/ivr/demand-message` | `DemandMessage` | GET | Query param: `source_identifier_id` | `repayment/views.py:DemandMessage.get()` |
| `repayment/v2/ivr/repayment-status` | `IVRRepaymentStatusV2` | GET | Query param: `source_identifier_id` | `repayment/views.py:IVRRepaymentStatusV2.get()` |
| `repayment/v2/ivr/next-installment-status` | `IVRNextInstallmentStatusV2` | GET | Query param: `source_identifier_id` | `repayment/views.py:IVRNextInstallmentStatusV2.get()` |
| `repayment/v1/farmer/<farmer_id>` | `RetrieveFarmerDetailsView` | GET | URL path: `farmer_id` | `repayment/views.py:RetrieveFarmerDetailsView.get_object()` |
| `repayment/v1/new-farmer-group` | `CheckNewFarmerGroupView` | GET | Query param | `repayment/views.py:CheckNewFarmerGroupView.retrieve()` |
| `repayment/v1/user/<user_source_id>/virtual-account-info` | `RetrieveVirtualAccountInfoView` | GET | URL path: `user_source_id` | `repayment/views.py:RetrieveVirtualAccountInfoView.get()` |
| `repayment/v1/gapl-virtual-account-info` | `RetrieveGAPLVirtualAccountInfoView` | GET | Query param: `source_identifier_id` | `repayment/views.py:RetrieveGAPLVirtualAccountInfoView.get()` |
| `repayment/v1/farmer/<farmer_id>/cash-in-hand` | `GetCollectionCashInHandView` | GET | URL path: `farmer_id` | `repayment/views.py:GetCollectionCashInHandView.get()` |
| `repayment/<api_version>/transaction/<transaction_id>/related-transactions` | `RetrieveRelatedTransactionsView` | GET | URL path: `transaction_id` | `repayment/views.py:RetrieveRelatedTransactionsView.get_queryset()` |
| `repayment/v1/trigger_demand_notification_to_farmer` | `TriggerDemandNotificationFarmer` | GET/POST | Request body / Query param: `farmer_id` | `repayment/views.py:TriggerDemandNotificationFarmer` |
| `repayment/v1/payout/download-transactions` | `DownloadTransactionForPayout` | GET | Query param | `repayment/views.py:DownloadTransactionForPayout.get()` |
| `repayment/v1/incentive/dashboard/<phone_number>` | `ListAggregatedIncentivesView` | GET | URL path: `phone_number` | `repayment/views.py:ListAggregatedIncentivesView.list()` |
| `repayment/v1/incentive/<reward_id>` | `IncentiveByRewardIdView` | GET | URL path: `reward_id` | `repayment/views.py:IncentiveByRewardIdView.get()` |
| `repayment/v1/pending-info` | `RetrieveCIHCreateBankReferenceView` | POST | Request body: `source_identifier_id` | `repayment/views.py:RetrieveCIHCreateBankReferenceView.post()` |
| `repayment/v1/cms-callback` | `UpdateBankReferenceView` | POST | Request body | `repayment/views.py:UpdateBankReferenceView.post()` |


### 1.5 Ledger (`ledger/`)

| Endpoint | View Class | Method | user_id Location | File Path |
|----------|-----------|--------|-----------------|-----------|
| `ledger/entry` | `LedgerEntryView` | GET | Query param: `partner_id` | `ledger/views.py:LedgerEntryView.list()` |
| `ledger/summary` | `SummaryView` | GET | Query param: `partner_id` | `ledger/views.py:SummaryView.get()` |
| `ledger/transaction/breakdown` | `TransactionBreakdownView` | GET | Query param: `partner_id` | `ledger/views.py:TransactionBreakdownView.list()` |
| `ledger/invoice/create` | `InvoiceCreateView` | POST | Request body: `partner_id` | `ledger/views.py:InvoiceCreateView.create()` |
| `ledger/invoice/mark-penalty` | `InvoiceUpdateView` | PATCH | Request body | `ledger/views.py:InvoiceUpdateView.patch()` |
| `ledger/invoice/cancel` | `InvoiceCancelView` | PATCH | Request body | `ledger/views.py:InvoiceCancelView.patch()` |
| `ledger/payment/create` | `PaymentCreateView` | POST | Request body: `partner_id` | `ledger/views.py:PaymentCreateView.create()` |
| `ledger/payment/update` | `PaymentUpdateView` | PATCH | Request body | `ledger/views.py:PaymentUpdateView.patch()` |
| `ledger/payment/cancel` | `PaymentCancelView` | PATCH | Request body | `ledger/views.py:PaymentCancelView.patch()` |
| `ledger/payment/refund/create` | `RefundPaymentCreateView` | POST | Request body: `partner_id` | `ledger/views.py:RefundPaymentCreateView.perform_create()` |
| `ledger/credit-note/create` | `CreditNoteCreateView` | POST | Request body: `partner_id` | `ledger/views.py:CreditNoteCreateView.create()` |
| `ledger/credit-note/cancel` | `CreditNoteCancelView` | PATCH | Request body | `ledger/views.py:CreditNoteCancelView.patch()` |
| `ledger/debit-record/create` | `DebitRecordCreateView` | POST | Request body: `partner_id` | `ledger/views.py:DebitRecordCreateView.create()` |
| `ledger/debit-record/update` | `DebitRecordUpdateView` | PATCH | Request body | `ledger/views.py:DebitRecordUpdateView.patch()` |
| `ledger/debit-record/cancel` | `DebitRecordCancelView` | PATCH | Request body | `ledger/views.py:DebitRecordCancelView.patch()` |
| `ledger/v1/download/<partner_id>` | `LedgerDownloadView` | GET | URL path: `partner_id` | `ledger/views.py:LedgerDownloadView.get()` |
| `ledger/interest-overdue-invoices/<partner_id>` | `InterestAndOverdueInvoicesView` | GET | URL path: `partner_id` | `ledger/views.py:InterestAndOverdueInvoicesView.get()` |
| `ledger/invoice-creditnotes` | `InvoiceCreditNoteViewSet` | GET | Query param: `partner_id` | `ledger/views.py:InvoiceCreditNoteViewSet.get()` |
| `ledger/creditnote-linked-invoice` | `CreditNoteWithLinkedInvoice` | GET | Query param | `ledger/views.py:CreditNoteWithLinkedInvoice.get()` |
| `ledger/update-visible-flag` | `UpdateVisibleFlagView` | PATCH | Request body | `ledger/views.py:UpdateVisibleFlagView.patch()` |
| `ledger/unpaid_invoices` | `UnpaidInvoiceView` | GET | Query param: `partner_id` | `ledger/views.py:UnpaidInvoiceView.list()` |
| `ledger/overdue-entry` | `OverdueEntryView` | GET | Query param: `partner_id` | `ledger/views.py:OverdueEntryView.get()` |
| `ledger/ledger-entries-outstanding` | `LedgerEntriesOutstanding` | POST | Request body: `partner_id` | `ledger/views.py:LedgerEntriesOutstanding.post()` |

### 1.6 External Webhooks (`external/`)

| Endpoint | View Class | Method | user_id Location | File Path |
|----------|-----------|--------|-----------------|-----------|
| `external/v1/saraloan/webhook` | `SaraloanWebhookView` | POST | Request body (webhook payload contains loan/business identifiers) | `external/views.py:SaraloanWebhookView.post()` |
| `external/v1/razorpay/webhook` | `RazorpayWebhookView` | POST | Request body (webhook payload) | `external/views.py:RazorpayWebhookView.post()` |
| `external/v1/auto-pay` | `AutoPayWebHookView` | POST | Request body (webhook payload) | `external/views.py:AutoPayWebHookView.post()` |
| `external/v1/payment-service/webhook` | `PaymentServiceWebhookView` | POST | Request body (webhook payload) | `external/views.py:PaymentServiceWebhookView.post()` |
| `external/v1/payment-gateway/webhook` | `PaymentGatewayWebHookView` | POST | Request body (webhook payload) | `external/views.py:PaymentGatewayWebHookView.post()` |

### 1.7 Farmer Financing (`farmer_financing/`)

Key endpoints (selected for credit operations relevance):

| Endpoint | View Class | Method | user_id Location | File Path |
|----------|-----------|--------|-----------------|-----------|
| `farmer_financing/v1/generate-otp` | `generate_otp` | POST | Request body: `phone_number` | `farmer_financing/views.py:generate_otp()` |
| `farmer_financing/v1/validate-otp` | `ValidateOTPView` | POST | Request body: `phone_number`, `otp` | `farmer_financing/views.py:ValidateOTPView.post()` |
| `farmer_financing/v1/credit/<pk>` | `RetrieveUpdateCreditView` | GET/PATCH | URL path: `pk` (application ID) | `farmer_financing/views.py:RetrieveUpdateCreditView` |
| `farmer_financing/v1/applications` | `ListUserApplicationsView` | GET | Query param: `extension_agent`, `dehaat_center` | `farmer_financing/views.py:ListUserApplicationsView.list()` |
| `farmer_financing/v1/user-applications/<user_id>` | `RetrieveUserApplicationView` | GET | URL path: `user_id` | `farmer_financing/views.py:RetrieveUserApplicationView.get_object()` |
| `farmer_financing/v1/applications/<pk>` | `UpdateUserApplicationView` | PATCH | URL path: `pk` | `farmer_financing/views.py:UpdateUserApplicationView.patch()` |
| `farmer_financing/v1/application-details/<pk>` | `SendApplicationToLos` | GET | URL path: `pk` | `farmer_financing/views.py:SendApplicationToLos.get()` |
| `farmer_financing/v1/saraloan-params` | `GetSaraloanParams` | GET | Query param | `farmer_financing/views.py:GetSaraloanParams.get()` |
| `farmer_financing/v1/recommend-farmer` | `RecommendFarmerForCreditProgramView` | POST | Request body: `farmer_id` | `farmer_financing/views.py:RecommendFarmerForCreditProgramView.post()` |
| `farmer_financing/v1/farmer/<farmer_id>/is-credit-enrolled` | `CheckCreditEnrolledFarmerView` | GET | URL path: `farmer_id` | `farmer_financing/views.py:CheckCreditEnrolledFarmerView.get()` |
| `farmer_financing/v1/application-onboarding-status/<farmer_id>` | `UserApplicationTimelineView` | GET | URL path: `farmer_id` | `farmer_financing/views.py:UserApplicationTimelineView.get()` |
| `farmer_financing/v1/check-eligibility` | `UploadAadharCardCheckEligibility` | GET/POST | Request body / Query param | `farmer_financing/views.py:UploadAadharCardCheckEligibility` |
| `farmer_financing/v1/saraloan/upload-document/<id_type>` | `SaraloanUploadDocument` | POST | Request body | `farmer_financing/views.py:SaraloanUploadDocument.post()` |
| `farmer_financing/v1/dc-approval-applications` | `DCApprovalApplicationsView` | GET | Query param: `dehaat_center` | `farmer_financing/views.py:DCApprovalApplicationsView.list()` |
| `farmer_financing/v1/dc-approval-applications/<pk>` | `UpdateDCApprovalApplicationsView` | PATCH | URL path: `pk` | `farmer_financing/views.py:UpdateDCApprovalApplicationsView.patch()` |
| `farmer_financing/user/<user_id>/connected-dc` | `UserConnectedDCView` | GET | URL path: `user_id` | `farmer_financing/views.py:UserConnectedDCView.get()` |
| `farmer_financing/farmers` | `FarmersListView` | GET | Query param | `farmer_financing/views.py:FarmersListView.list()` |
| `farmer_financing/v1/farmers-list/<agent_id>` | `FarmerOnboardingListView` | GET | URL path: `agent_id` | `farmer_financing/views.py:FarmerOnboardingListView.list()` |

---

## 2. DRF Viewsets

All view classes with their file paths, organized by app.

### credit_line/views.py

| Class | Base Class(es) | Key Methods |
|-------|---------------|-------------|
| `ListCreditLines` | APIView | `get()` |
| `ListCreditLinesV2` | APIView | `get()` |
| `ListCreditLinesDBA` | APIView | `get()` |
| `CreditLinesStatus` | APIView | `get()` |
| `CreditLimitStatus` | APIView | `get()` |
| `CreditLinesOutstandingAmount` | APIView | `get()` |
| `CreditLinesOutstandingAmountV2` | APIView | `get()` |
| `CustomerInfo` | APIView | `get()` |
| `ListMultipleCustomersCreditLines` | APIView | `get()` |
| `CustomerWithGaplLineViewSet` | APIView | `post()` |
| `BusinessUserCreateViewSet` | ModelViewSet | `get_queryset()`, `destroy()` |
| `BusinessUserMappingViewSet` | ModelViewSet | `get_queryset()` |
| `ListCreditProgramDetailsView` | ListAPIView | `list()` |
| `CreditSummaryDashboardView` | APIView | `get()` |
| `ListCustomerTag` | APIView | `get()` |
| `GetMenuUrlMsg` | APIView | `get()` |
| `CreditLineStatusV2` | APIView | `get()` |
| `CreditLineStatusFailureView` | APIView | `get()` |
| `LenderCreditOrderDetails` | APIView | `get()` |
| `UpdateCustomerConsent` | APIView | `patch()` |
| `UpdateCustomerNode` | APIView | `patch()` |
| `CustomerDeviceConsentInfo` | RetrieveAPIView | `get()` |
| `CustomerCreditData` | APIView | `get()` |
| `GetOtgFilterData` | APIView | `get()` |
| `ListMultipleCustomerOverdueByDate` | APIView | `get()` |
| `CustomerListView` | APIView | `get()` |
| `NotificationInactiveFarmers` | APIView | `get()` |
| `TestEvent` | APIView | `get()` |
| `TestReadDbConnection` | APIView | `get()` |

### loan/views.py

| Class | Base Class(es) | Key Methods |
|-------|---------------|-------------|
| `LoanViewSet` | ListCreateAPIView | `get_queryset()`, `post()` |
| `InvoiceLoanViewSet` | ListAPIView | `get_queryset()` |
| `InvoicesWithInterestViewSet` | ListAPIView | `list()` |
| `InvoiceSummaryViewSet` | APIView | `get()`, `post()` |
| `LoanStatusViewSet` | APIView | `post()` |
| `LoansBreakupViewSet` | APIView | `get()` |
| `TotalPurchaseAndRepaymentViewSet` | APIView | `get()` |
| `InvoiceCancelView` | APIView | `patch()` |
| `SimulateReconciliation` | APIView | `get()` |

### payment/views.py

| Class | Base Class(es) | Key Methods |
|-------|---------------|-------------|
| `PaymentViewSet` | ListCreateAPIView | `list()`, `post()`, `patch()` |
| `CreditNoteViewSet` | ListCreateAPIView | `post()` |
| `DebitNoteViewSet` | CreateAPIView | `post()` |
| `PaymentBreakupViewSet` | APIView | `get()` |
| `PaymentCancelView` | APIView | `patch()` |
| `CreditNoteCancelView` | APIView | `patch()` |
| `DebitNoteCancelView` | APIView | `patch()` |
| `RetrieveUpdateTransactionInfoView` | APIView | `get_object()`, `post()`, `patch()` |
| `DisbPaymentViewSet` | CreateAPIView | `post()` |
| `DisbPaymentCancelViewSet` | APIView | `patch()` |
| `SapPaymentPostingAckViewSet` | APIView | `patch()` |
| `ReconcilePaymentsAPIView` | APIView | `get()` |

### repayment/views.py

| Class | Base Class(es) | Key Methods |
|-------|---------------|-------------|
| `ListCreateTransactionView` | ListCreateAPIView | `post()`, `list()` |
| `DepositView` | APIView | `create_multiple_vpa_deposits()`, `update_multiple_vpa_deposits()`, `create_full_amount_deposits()`, `save_multiple_bank_csc_deposits()` |
| `ListModifyTransactionView` | APIView | `patch()` |
| `RetrieveAggregatedAmountView` | BaseAggregatedAmountView | `retrieve()` |
| `RetrieveDBAAggregateDetailsView` | BaseAggregatedAmountView | `retrieve()` |
| `ListFarmersView` | ListAPIView | `list()` |
| `GetLenderAndInterestRateView` | APIView | `get()` |
| `ListGroupLeadersView` | ListAPIView | `list()` |
| `ListGroupLeaderTransactionView` | ListAPIView | `get_queryset()` |
| `IVRRepaymentOTPView` | APIView | `get()` |
| `IVRNextInstallmentStatus` | APIView | `get()` |
| `IVRRepaymentStatus` | APIView | `get()` |
| `IVRDepositToFSFEOTPView` | APIView | `get()` |
| `RetrieveVirtualAccountInfoView` | APIView | `get()` |
| `RetrieveFarmerDetailsView` | RetrieveAPIView | `get_object()` |
| `CheckNewFarmerGroupView` | APIView | `retrieve()` |
| `DemandMessage` | APIView | `get()` |
| `ListFarmerCollectionsView` | ListAPIView | `get_queryset()` |
| `ListCollectionsWithoutDeposit` | ListAPIView | `list()` |
| `GetCollectionCashInHandView` | APIView | `get()` |
| `RetrieveRelatedTransactionsView` | ListAPIView | `get_queryset()` |
| `IVRRepaymentStatusV2` | APIView | `get()` |
| `IVRNextInstallmentStatusV2` | APIView | `get()` |
| `TriggerDemandNotificationFarmer` | APIView | `post()`, `get()` |
| `DownloadTransactionForPayout` | APIView | `get()` |
| `RetrieveAggregatedNonDepositedCollections` | APIView | `retrieve()` |
| `RetrieveGAPLVirtualAccountInfoView` | APIView | `get()` |
| `ListAggregatedIncentivesView` | ListAPIView | `list()` |
| `IncentiveByRewardIdView` | APIView | `get()` |
| `RetrieveCIHCreateBankReferenceView` | CreateAPIView | `post()` |
| `UpdateBankReferenceView` | APIView | `post()` |

### ledger/views.py

| Class | Base Class(es) | Key Methods |
|-------|---------------|-------------|
| `LedgerEntryView` | ListAPIView | `list()` |
| `TransactionBreakdownView` | ListAPIView | `list()` |
| `InvoiceCreateView` | CreateAPIView | `create()` |
| `InvoiceUpdateView` | APIView | `patch()` |
| `InvoiceCancelView` | APIView | `patch()` |
| `PaymentCreateView` | CreateAPIView | `create()` |
| `PaymentUpdateView` | APIView | `patch()` |
| `PaymentCancelView` | APIView | `patch()` |
| `RefundPaymentCreateView` | CreateAPIView | `perform_create()` |
| `CreditNoteCreateView` | CreateAPIView | `create()` |
| `CreditNoteCancelView` | APIView | `patch()` |
| `DebitRecordCreateView` | CreateAPIView | `create()` |
| `DebitRecordUpdateView` | APIView | `patch()` |
| `DebitRecordCancelView` | APIView | `patch()` |
| `SummaryView` | APIView | `get()` |
| `LedgerDownloadView` | APIView | `get()` |
| `InterestAndOverdueInvoicesView` | APIView | `get()` |
| `InvoiceCreditNoteViewSet` | APIView | `get()` |
| `CreditNoteWithLinkedInvoice` | APIView | `get()` |
| `UpdateVisibleFlagView` | APIView | `patch()` |
| `UnpaidInvoiceView` | ListAPIView | `list()` |
| `OverdueEntryView` | APIView | `get()` |
| `LedgerEntriesOutstanding` | APIView | `post()` |

### external/views.py

| Class | Base Class(es) | Key Methods |
|-------|---------------|-------------|
| `SaraloanWebhookView` | APIView | `post()` |
| `RazorpayWebhookView` | APIView | `post()` |
| `AutoPayWebHookView` | APIView | `post()` |
| `PaymentServiceWebhookView` | APIView | `post()` |
| `PaymentGatewayWebHookView` | APIView | `post()` |

---

## 3. Management Commands

No Django management commands (`BaseCommand` subclasses) were found in the codebase. All batch operations are handled via Celery beat scheduled tasks (see Section 4).

---

## 4. Celery Beat Schedule Tasks

Source: `config/settings/base.py` → `CELERY_BEAT_SCHEDULE`

Celery configuration:
- `CELERY_TASK_TIME_LIMIT`: 300s (5 min hard limit)
- `CELERY_TASK_SOFT_TIME_LIMIT`: 60s
- `CELERY_RESULT_BACKEND`: `django-db` (results in `django_celery_results` tables)
- `CELERY_BEAT_SCHEDULER`: `django_celery_beat.schedulers:DatabaseScheduler`

Available queues: `top_priority`, `medium_priority`, `sap_migration`, `celery`, `saraloan`, `email`, `event`, `saraloan_failure`, `saraloan_invoice`, `reconciliation`, `notification`

### 4.1 Credit Line Tasks

| Schedule Name | Task Path | Schedule | Queue | user_id |
|--------------|-----------|----------|-------|---------|
| `sync_credit_lines_info_from_saraloan` | `credit_line.tasks.sync_credit_lines_info_from_saraloan` | Daily 22:00 | `saraloan` | Iterates all `CustomerCreditLine` records |
| `sync_loans_params_from_saraloan` | `credit_line.tasks.sync_loans_params_from_saraloan` | Daily 21:30 | `saraloan` | Iterates all unpaid loans |
| `Buffer End Date Actions` | `credit_line.tasks.buffer_date_actions` | Daily 16:30 | `celery` (default) | Batch — all eligible customers |
| `Update Credit Line Status Sub_Status` | `credit_line.tasks.update_credit_lines_status` | Daily 02:00 | `celery` (default) | Optional `partner_id` param, defaults to all |
| `Notify Inactive Farmers` | `credit_line.tasks.send_notification_to_inactive_farmers` | 1st & 15th of month, 08:00 | `celery` (default) | Batch — inactive customers |
| `Send Overdue Notification and Whatsapp Message` | `credit_line.tasks.notify_overdue_partners_v2` | Daily 04:30 | `event` | Batch — overdue partners |
| `Notify Overdue Invoices` | `credit_line.tasks.notify_partners_for_overdue_invoices` | Daily 02:30 | N/A | Batch — partners with overdue invoices |
| `Notify Overdue Partners` | `credit_line.tasks.notify_overdue_partners` | Daily 00:30 | `event` | **Disabled** |
| `Collect User Profile Data From FinBox` | `credit_line.tasks.collect_user_profile_data_from_finbox` | Daily 17:00 | `top_priority` | Optional `partner_ids` param |
| `Overdue Threshold Limit End Date Actions` | `credit_line.tasks.overdue_threshold_limit_end_date_actions` | Daily 00:01 | N/A | Batch |
| `Sync Nodes from IB` | `credit_line.tasks.sync_nodes_from_ib` | Daily 01:00 | `celery` | N/A (node sync) |
| `Sync Customers Saraloan Data` | `credit_line.tasks.sync_customers_from_saraloan` | Daily 16:30 | N/A | **Disabled** |

### 4.2 Loan Tasks

| Schedule Name | Task Path | Schedule | Queue | user_id |
|--------------|-----------|----------|-------|---------|
| `Move GAPL Loan to Lender` | `loan.tasks.move_gapl_loan_to_lender` | Daily 00:30 | `celery` (default) | Optional `partner_ids` param |
| `share_oldest_loan_to_lender_for_all_partner` | `loan.tasks.share_oldest_loan_to_lender_for_all_partners` | Daily 03:00 | `celery` (default) | Batch — all eligible partners |
| `check_and_run_reconciliation_for_all_customers` | `loan.tasks.check_and_run_reconciliation_for_all_customers` | Daily 04:00 | `celery` (default) | Batch — all customers |
| `Send Disbursement Payments to ERP` | `loan.tasks.send_disbursement_payments_to_erp` | Daily 01:00 | `top_priority` | Batch — pending disbursements |
| `reconcile_all_gapl_loans` | `loan.utility.reconcile_all_gapl_loans` | Daily 00:00, 13:00 | `celery` (default) | Batch |
| `Sync Loan Accounts For Missed Notifs` | `loan.tasks.sync_loan_account_processed_data_from_saraloan` | Daily 01:00 | `celery` (default) | Batch |
| `update_external_lender_supported_saraloan` | `loan.tasks.update_external_lender_supported_saraloan` | Daily 15:00 | `saraloan` | Optional `partner_id` |
| `Send Loan Aging Severity Event` | `loan.tasks.send_loan_aging_severity_event` | Daily 02:00 | N/A | Batch |
| `Interest Refund Automatic Credit Note Processing` | `loan.tasks.interest_refund_automatic_credit_note_processing` | Daily 04:30 | N/A | Batch |

### 4.3 Payment Tasks

| Schedule Name | Task Path | Schedule | Queue | user_id |
|--------------|-----------|----------|-------|---------|
| `sync_repayment_info_for_all_dc` | `payment.tasks.sync_repayment_info_for_all_dc` | Daily 19:30 | `saraloan` | Batch — all DCs |
| `Aggregate Payments for Transfer` | `payment.tasks.aggregate_payment_transfer` | Weekdays 10:30 | N/A | Batch |
| `Transfer All Aggregated Payments` | `payment.tasks.transfer_all_agg_payments` | Weekdays 10:35 | N/A | Batch |
| `Sync All Aggregated Payments` | `payment.tasks.sync_all_aggregated_payments` | Every hour :15 | N/A | Batch |
| `Reverse Aggregated Payments` | `payment.tasks.reverse_aggregated_payments` | Weekdays 04:00 | N/A | Batch |
| `Check and Create LA Entries in SAP` | `payment.tasks.check_and_create_la_entries_in_sap` | Daily 01:00 | `celery` (default) | Batch |
| `Send Advance Refund Payments to ERP` | `payment.tasks.send_failed_refund_payment_entries_to_sap` | Daily 01:00 | `top_priority` | Batch |
| `unreconcile_gapl_payments` | `payment.tasks.unreconcile_gapl_payments` | Daily 00:00, 13:00 | N/A | Batch |
| `Move GAPL Payment to Lender` | `payment.tasks.move_gapl_payment_to_lender` | Daily 00:30 | `celery` (default) | **Disabled** |
| `Retry SAP Posting of Transfer to Lender Payments` | `payment.tasks.retry_posting_or_deletion_of_transfer_to_lender_payments` | Daily 16:00 | N/A | Batch |

### 4.4 Repayment Tasks

| Schedule Name | Task Path | Schedule | Queue | user_id |
|--------------|-----------|----------|-------|---------|
| `FF Repayment Demand Notification Engine` | `repayment.tasks.initiate_repayment_reminder` | Daily 02:30 | `celery` | Batch — all eligible farmers |
| `Trigger event having Over Due` | `repayment.tasks.trigger_over_due_event` | Daily 00:30 | `event` | Batch |
| `Sync Customer Virtual Accounts` | `repayment.tasks.fetch_virtual_account_details_saraloan` | Daily 23:00 | `saraloan` | Batch |
| `Mark Inactive Transaction References` | `repayment.tasks.update_failure_for_stale_transaction_references` | Daily 02:00 | `celery` | Batch |

### 4.5 Farmer Financing Tasks

| Schedule Name | Task Path | Schedule | Queue | user_id |
|--------------|-----------|----------|-------|---------|
| `sync_application_status_from_saraloan_in_batches` | `farmer_financing.tasks.sync_application_status_from_saraloan_in_batches` | Every 15 min | `sap_migration` | Batch |
| `batch_sync_single_farmer_application_status_from_saraloan` | `farmer_financing.tasks.batch_sync_single_farmer_application_status_from_saraloan` | Every 2 min | `top_priority` | Batch |
| `retry_single_farmer_onboarding_application` | `farmer_financing.tasks.retry_single_farmer_onboarding_application` | Every 4 min | `top_priority` | Batch |
| `update_esigned_applications_to_completed` | `farmer_financing.tasks.update_esigned_applications_to_completed` | Every 15 min | `saraloan` | Batch |
| `Trigger event with Cash in Hand` | `farmer_financing.tasks.fetch_and_trigger_event_for_cash_in_hand` | Daily 19:00 | `event` | Batch |
| `Trigger event for GL for overdue communication` | `farmer_financing.tasks.fetch_and_trigger_event_for_overdue_communication` | Daily 08:00 | `event` | Batch |
| `Trigger DC_Authorization Notification` | `farmer_financing.tasks.trigger_dc_authorization_notification` | Daily 09:00 | `celery` | Batch |
| `Assign Credit Limit To Underwriting Applications` | `farmer_financing.tasks.assign_credit_limit_to_underwriting_applications` | Every 15 min | `saraloan` | Optional `application_id` |
| `sync_pending_loan_agreement_esign_status` | `farmer_financing.tasks.sync_pending_loan_agreement_esign_status` | Every 5 min | N/A | Batch |

### 4.6 Other Tasks

| Schedule Name | Task Path | Schedule | Queue | user_id |
|--------------|-----------|----------|-------|---------|
| `Create Loan From Invoice` | `invoice.tasks.create_loan_from_invoice` | Every hour | N/A | Batch |
| `Automated Action on Pending Invoice` | `invoice.tasks.take_action_on_invoice_as_per_lender_action` | Daily 17:00 | N/A | Batch |
| `Update Interest Against Invoices` | `invoice.tasks.update_interest_against_eligible_invoice` | Every 5 min | N/A | Batch |
| `Reconciliation Entries` | `customer_journal.tasks.reconcile_customers_entries` | Daily 23:15 | `reconciliation` | Batch |
| `Send Reconciliation Entries to SAP` | `customer_journal.tasks.send_recon_entries_to_sap` | Daily 22:45 | `reconciliation` | Batch |
| `Update Long time in_progress recon entries` | `customer_journal.tasks.update_in_progress_remained_entries` | Daily 10:30, 22:30 | `reconciliation` | Batch |
| `Move Line Items SAP to Entry` | `customer_journal.tasks.move_line_items` | Every 30 min | `reconciliation` | Batch |
| `Move Raw Line Items` | `customer_journal.tasks.move_raw_line_items` | Every 5 min | `line_item_sync` | Batch |
| `Update Entries visible active flag` | `ledger.tasks._update_debit_record_payment_visibility` | Every 5 min | `celery` (default) | Batch |
| `Update Old Entries visible active flag` | `ledger.tasks._update_old_debit_record_payment_visibility` | Daily 01:05, 13:05 | `celery` (default) | Batch |
| `initiate_emi_auto_debit_request` | `auto_pay.tasks.initiate_emi_auto_debit_request` | Daily 11:00 | N/A | Batch |
| `Sync PG Payments` | `payment_gateway.tasks.sync_pg_payments` | Every 2 min | N/A | Batch |
| `Sync Customer Virtual Accounts from Saraloan` | `virtual_account.tasks.sync_virtual_account_details_from_saraloan` | Daily 23:00 | N/A | Batch |
| `collect_and_send_emails` | `common.tasks.collect_and_send_emails` | Daily 03:00 | N/A | N/A |
| `purge_events_and_emails` | `common.tasks.purge_sent_emails` | Daily 16:00 | N/A | N/A |
| `Retry Pending PubSub Events` | `common.tasks.retry_pending_and_failed_pubsub_events` | Daily 15:30 | N/A | N/A |
| `Send Leads To Saraloan` | `lead.tasks.send_lead_to_saraloan` | Every hour | N/A | Batch |
| `Saraloan Phase 1 Onboarding Rule Engine` | `lead.tasks.saraloan_phase_one_eligible_leads` | Every hour | N/A | Batch |
| `Sync Saraloan Lead Status` | `lead.tasks.sync_saraloan_leads_status` | Every hour | N/A | Batch |
| `Retry Update Saraloan Partner Id` | `lead.tasks.saraloan_retry_partner_id_update` | Every hour | N/A | Batch |
| `Sync Failed PDC to Saraloan` | `lead.tasks.sync_pdc_to_saraloan` | Every hour | N/A | Batch |
| `Saraloan Customer Limit Enhancement` | `lead.tasks.saraloan_customer_limit_enhancement` | Every hour :30 | N/A | Batch |

> **Note**: Tasks marked **Disabled** have `"enabled": False` in the beat schedule and do not run automatically.

---

## 5. Django Signals as Implicit Entry Points

Signals fire automatically on model save/update operations and act as implicit entry points that trigger side effects.

### 5.1 Loan Signals (`loan/signals.py`)

| Signal | Trigger | Sender | Function | Effect |
|--------|---------|--------|----------|--------|
| `post_save` | `Loan` created/updated | `Loan` | `send_disbursement_payment_to_erp()` | Calls `prep_disbursal_payment_to_send_to_sap()` when loan status is in `LOAN_STATUSES_TO_UPLOAD_DISBURSAL_ON_SAP`, has `disbursal_payment_ref_id`, and no `erp_payment_upload_status` |
| `post_save` | `InvoiceLoanMap` created | `InvoiceLoanMap` | `perform_post_save()` | Triggers `verify_and_trigger_loan_created_event` Celery task with 5s countdown |
| `post_bulk_create` | `InvoiceLoanMap` bulk created | `InvoiceLoanMap` | `post_create_invoice_loan_map_trigger_event()` | Triggers `trigger_event_for_loan_related` for each created invoice |
| `post_save`, `post_bulk_create` | `Loan` created | `Loan` | `loan_subvention_overdue_handler()` | Calls `loan_signal_handler()` for subvention/overdue processing |
| `pre_update`, `pre_bulk_update` | `Loan` status changing | `Loan` | `event_trigger_for_loan_status_change()` | Calls `trigger_loan_status_change_event_signal()` |
| `post_save`, `post_bulk_update` | `Loan` updated | `Loan` | `update_ledger_invoice_for_payment_status_from_loan()` | Updates ledger invoice payment status via `update_ledger_invoice_for_payment_status_via_loan_signal()` |
| `post_save`, `post_bulk_create` | `InvoiceLoanMap` created | `InvoiceLoanMap` | `update_ledger_invoice_for_payment_status_from_invoice_loan_map()` | Updates ledger invoice payment status |
| `pre_save`, `pre_update`, `pre_bulk_update` | `Loan` interest amount changing | `Loan` | `loan_total_interest_amount_change_signal()` | Calls `check_for_loan_interest_change_and_flow_updates_in_ledger()` |
| `post_save`, `post_bulk_update` | `Loan` marked paid | `Loan` | `process_interest_refund_when_loan_marked_paid()` | Calls `post_interest_refund_when_loan_marked_paid()` |

**user_id tracing**: `Loan` → `customer_credit_line` FK → `Customer.source_identifier_id`

### 5.2 Payment Signals (`payment/signals.py`)

| Signal | Trigger | Sender | Function | Effect |
|--------|---------|--------|----------|--------|
| `post_save` | `CreditNote` created | `CreditNote` | `create_payment_for_cn()` | Creates payment for credit note via `check_and_create_payment()`, triggers reconciliation via `run_reconciliation_for_customer_main` |
| `post_save`, `pre_save`, `pre_update`, `pre_bulk_update`, `post_bulk_create` | `Payment`, `CreditNote`, `DebitNote`, `DisbursalPayment` | Multiple | `payment_pre_signal()` | Routes to `signal_receiver()` for SAP refund processing, status change capture, and event triggering |
| `post_save` | `Payment` created | `Payment` | `update_payment_paid_to()` | Calls `process_payment_post_created_or_updated()` — maps payment to VPA/non-VPA transactions for Farmer customers |
| `post_save` | `Payment` with transfer number | `Payment` | `map_payment_to_loan_on_transfer()` | Maps payment to loans when status is `MOVED_TO_LENDER` via `_map_payment_to_loans_common_logic()` |

**user_id tracing**: `Payment` → `customer_credit_line` FK → `Customer.source_identifier_id`

### 5.3 Credit Line Signals (`credit_line/signals.py`)

| Signal | Trigger | Sender | Function | Effect |
|--------|---------|--------|----------|--------|
| `pre_save` | `CustomerCreditLine` saving | `CustomerCreditLine` | `update_operational_limit()` | Enforces `operational_limit = min(operational_limit, credit_limit)` via `update_operational_limit_signal_helper()` |
| `pre_save`, `pre_update`, `pre_bulk_update`, `pre_bulk_create` | `Customer` saving/updating | `Customer` | `customer_pre_signal()` | Routes to `customer_receiver()` in `credit_line/utils.py` for lender onboarding/deboarding checks |
| `pre_save` | `CustomerCreditLine` saving | `CustomerCreditLine` | `update_principal_outstanding()` | Updates `principal_outstanding` for ME_ADANI_CAPITAL and ME_PROGCAP credit products |
| `post_bulk_create` | `CustomerCreditLine` bulk created | `CustomerCreditLine` | `update_customer_credit_line()` | Triggers `credit_limit_upload_ivr_and_sms()` for each new credit line |
| `post_save` | `CustomerCreditLine` created | `CustomerCreditLine` | `send_credit_line_activated_event()` | Triggers `trigger_event_for_credit_line_activated` Celery task |

**user_id tracing**: `CustomerCreditLine` → `customer` FK → `Customer.source_identifier_id`

---

## 6. Quick Reference: user_id Parameter Locations

| Location Type | Parameter Names | Example Entry Points |
|--------------|----------------|---------------------|
| **URL path** | `source_identifier_id`, `farmer_auth_id`, `source_id`, `user_source_id`, `farmer_id`, `user_id`, `partner_id` | `credit-line/business/<source_identifier_id>`, `ledger/v1/download/<partner_id>`, `repayment/v1/farmer/<farmer_id>` |
| **Query param** | `source_identifier_id`, `partner_id`, `farmer_id`, `customer_id`, `customer_credit_line`, `dc_id` | IVR endpoints, list endpoints, summary endpoints |
| **Request body** | `source_identifier_id`, `customer_id`, `customer_credit_line`, `payer`, `partner_id` | POST/PATCH endpoints for creating loans, payments, transactions |
| **Webhook payload** | Embedded in request body JSON | `external/v1/saraloan/webhook`, `external/v1/razorpay/webhook` |
| **Implicit (signals)** | Derived from model FK chain: `Model` → `customer_credit_line` → `Customer.source_identifier_id` | All signal handlers |
| **Celery task args** | `partner_id`, `source_identifier_id`, `customer_credit_line_id` in task arguments | Stored in `django_celery_results_taskresult.task_args` |
