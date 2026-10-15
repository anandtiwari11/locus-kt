-- Locus vs Ledger T-code queries (companion to locus_ledger_reconciliation_playbook.md)
-- Replace all occurrences of '1048357' with target partner source_identifier_id (text).

-- ---------------------------------------------------------------------------
-- T0: Locus computed outstanding (sum line_os from final SELECT, or use outer SUM)
-- ---------------------------------------------------------------------------
WITH cl AS (
  SELECT clc.id AS clc_id,
         cp.belongs_to_gapl,
         clc.lender_outstanding_amount,
         clc.unrealised_outstanding_payment
  FROM credit_line_customercreditline clc
  JOIN credit_line_customer c ON c.id = clc.customer_id
  JOIN credit_line_creditproduct cp ON cp.id = clc.credit_product_id
  WHERE c.source_identifier_id = '1048357'
),
gapl_loans AS (
  SELECT ll.customer_credit_line_id AS clc_id,
         COALESCE(SUM(ll.loan_amount), 0) AS loan_amt
  FROM loan_loan ll
  INNER JOIN cl ON cl.clc_id = ll.customer_credit_line_id
  WHERE ll.status NOT IN ('REJECTED', 'CANCELLED', 'MOVED_TO_LENDER')
    AND ll.transaction_date <= CURRENT_DATE
  GROUP BY 1
),
gapl_de AS (
  SELECT pd.customer_credit_line_id AS clc_id,
         COALESCE(SUM(pd.amount), 0) AS de_amt
  FROM payment_debitnote pd
  INNER JOIN cl ON cl.clc_id = pd.customer_credit_line_id
  WHERE pd.type = 'DE' AND pd.status = 'POSTED'
  GROUP BY 1
),
gapl_dn AS (
  SELECT pd.customer_credit_line_id AS clc_id,
         COALESCE(
           SUM(COALESCE(pd.amount, 0) - COALESCE(pd.prepaid_amount_settled, 0)),
           0
         ) AS dn_amt
  FROM payment_debitnote pd
  INNER JOIN cl ON cl.clc_id = pd.customer_credit_line_id
  WHERE pd.type IN ('DN', 'DH') AND pd.status = 'POSTED'
  GROUP BY 1
),
gapl_pay AS (
  SELECT pp.customer_credit_line_id AS clc_id,
         COALESCE(SUM(pp.payment_amount), 0)
         - COALESCE(SUM(pp.transfer_to_lender_amount), 0) AS paid_net
  FROM payment_payment pp
  INNER JOIN cl ON cl.clc_id = pp.customer_credit_line_id
  WHERE pp.status IN ('POSTED', 'TRANSFER_TO_LENDER', 'TRANSFER_INITIATED')
  GROUP BY 1
),
non_disbursed AS (
  SELECT ll.customer_credit_line_id AS clc_id,
         COALESCE(SUM(ll.loan_amount), 0) AS nd_amt
  FROM loan_loan ll
  INNER JOIN cl ON cl.clc_id = ll.customer_credit_line_id
  WHERE ll.status IN ('DRAFT', 'YET_TO_BE_DISBURSED')
  GROUP BY 1
)
SELECT SUM(
         CASE
           WHEN cl.belongs_to_gapl THEN
             COALESCE(gl.loan_amt, 0) + COALESCE(gde.de_amt, 0) + COALESCE(gdn.dn_amt, 0)
             - COALESCE(gp.paid_net, 0)
           ELSE
             COALESCE(cl.lender_outstanding_amount, 0)
             - COALESCE(cl.unrealised_outstanding_payment, 0)
             + COALESCE(nd.nd_amt, 0)
         END
       ) AS t0_locus_computed_os
FROM cl
LEFT JOIN gapl_loans gl ON gl.clc_id = cl.clc_id AND cl.belongs_to_gapl
LEFT JOIN gapl_de gde ON gde.clc_id = cl.clc_id AND cl.belongs_to_gapl
LEFT JOIN gapl_dn gdn ON gdn.clc_id = cl.clc_id AND cl.belongs_to_gapl
LEFT JOIN gapl_pay gp ON gp.clc_id = cl.clc_id AND cl.belongs_to_gapl
LEFT JOIN non_disbursed nd ON nd.clc_id = cl.clc_id AND NOT cl.belongs_to_gapl;

-- ---------------------------------------------------------------------------
-- T-LedgerOS: signed outstanding + unrealised (matches dashboard aggregation)
-- ---------------------------------------------------------------------------
WITH le AS (
  SELECT
    COALESCE(SUM(CASE WHEN type = 'INVOICE' THEN amount ELSE 0 END), 0) AS inv,
    COALESCE(SUM(CASE WHEN type = 'FINANCING_FEE' THEN amount ELSE 0 END), 0) AS ff,
    COALESCE(SUM(CASE WHEN type = 'INTEREST' THEN amount ELSE 0 END), 0) AS int_,
    COALESCE(SUM(CASE WHEN type = 'DEBIT_NOTE' THEN amount ELSE 0 END), 0) AS dn,
    COALESCE(SUM(CASE WHEN type = 'DEBIT_ENTRY' THEN amount ELSE 0 END), 0) AS de,
    COALESCE(SUM(CASE WHEN type = 'DEBIT_HOLD' THEN amount ELSE 0 END), 0) AS dh,
    COALESCE(SUM(CASE WHEN type = 'PAYMENT' THEN amount ELSE 0 END), 0) AS pay,
    COALESCE(SUM(CASE WHEN type = 'CREDIT_NOTE' THEN amount ELSE 0 END), 0) AS cn,
    COALESCE(SUM(CASE WHEN type = 'RELEASE_PAYMENT' THEN amount ELSE 0 END), 0) AS rel,
    COALESCE(SUM(CASE WHEN type = 'ABS_PAYMENT' THEN amount ELSE 0 END), 0) AS abs_pay
  FROM ledger_ledgerentry
  WHERE partner_id = '1048357' AND active AND visible
),
ur AS (
  SELECT COALESCE(SUM(clc.unrealised_outstanding_payment), 0) AS unrealised
  FROM credit_line_customercreditline clc
  JOIN credit_line_customer c ON c.id = clc.customer_id
  WHERE c.source_identifier_id = '1048357'
)
SELECT
  le.*,
  ur.unrealised,
  (
    le.inv + le.ff + le.int_ + le.dn + le.de + le.dh
    - le.pay - le.cn - le.rel - ur.unrealised
  ) AS ledger_os_operational,
  (
    le.inv + le.ff + le.int_ + le.dn + le.de + le.dh
    - le.pay - le.cn - le.rel - le.abs_pay - ur.unrealised
  ) AS ledger_os_less_abs
FROM le CROSS JOIN ur;

-- ---------------------------------------------------------------------------
-- T-Visibility
-- ---------------------------------------------------------------------------
SELECT type,
       COALESCE(SUM(amount), 0) AS sum_active,
       COALESCE(SUM(CASE WHEN visible THEN amount ELSE 0 END), 0) AS sum_visible,
       COALESCE(SUM(amount), 0)
       - COALESCE(SUM(CASE WHEN visible THEN amount ELSE 0 END), 0) AS deferred
FROM ledger_ledgerentry
WHERE partner_id = '1048357' AND active
  AND type IN (
    'PAYMENT', 'CREDIT_NOTE', 'DEBIT_NOTE', 'DEBIT_HOLD', 'DEBIT_ENTRY', 'INVOICE'
  )
GROUP BY type
ORDER BY type;
