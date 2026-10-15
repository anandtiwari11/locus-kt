# Locus vs Ledger reconciliation playbook (T-codes)

Use this playbook to debug **`Locus_Outstanding − Ledger_Outstanding`** at scale. Replace `:partner_id` with the partner’s `source_identifier_id` (text).

Executable excerpts for **T0**, **T-LedgerOS**, and **T-Visibility** (search-replace partner id) live in [`locus_ledger_tcodes.sql`](locus_ledger_tcodes.sql).

**Do not** use `credit_line_customercreditline.outstanding_amount` alone as “Locus OS”: it can be stale or zero while loans and ledger are active. Use **T0** (computed OS) as the canonical Locus number aligned with [`compute_outstanding_amount`](../../credit_line/utils.py).

---

## Parameter

```sql
-- Set once per session (PostgreSQL):
-- \set partner_id '1048357'
```

All queries below use `WHERE ... source_identifier_id = :partner_id` — substitute your bind or literal.

---

## T0 — Locus computed outstanding (canonical)

**Formula (per credit line, then sum):**

- If **`belongs_to_gapl`:**  
  `get_gapl_outstanding_amount` =  
  `sum(loan_amount | eligible loans)` + `posted DE` + `posted (DN+DH net of prepaid_amount_settled)` − `(sum(payment_amount) − sum(transfer_to_lender_amount) | GAPL payment statuses)`.
- Else:  
  `lender_outstanding_amount − unrealised_outstanding_payment + non_disbursed`  
  (`DRAFT` + `YET_TO_BE_DISBURSED` loan amounts).

**SQL (matches Python defaults: `aged_duration_in_days=0`, `outstanding_computation_date=NULL` → loans with `transaction_date <= CURRENT_DATE`):**

```sql
WITH cl AS (
  SELECT clc.id AS clc_id,
         cp.belongs_to_gapl,
         clc.lender_outstanding_amount,
         clc.unrealised_outstanding_payment
  FROM credit_line_customercreditline clc
  JOIN credit_line_customer c ON c.id = clc.customer_id
  JOIN credit_line_creditproduct cp ON cp.id = clc.credit_product_id
  WHERE c.source_identifier_id = :partner_id
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
SELECT cl.clc_id,
       cl.belongs_to_gapl,
       CASE
         WHEN cl.belongs_to_gapl THEN
           COALESCE(gl.loan_amt, 0) + COALESCE(gde.de_amt, 0) + COALESCE(gdn.dn_amt, 0)
           - COALESCE(gp.paid_net, 0)
         ELSE
           COALESCE(cl.lender_outstanding_amount, 0)
           - COALESCE(cl.unrealised_outstanding_payment, 0)
           + COALESCE(nd.nd_amt, 0)
       END AS line_os
FROM cl
LEFT JOIN gapl_loans gl ON gl.clc_id = cl.clc_id AND cl.belongs_to_gapl
LEFT JOIN gapl_de gde ON gde.clc_id = cl.clc_id AND cl.belongs_to_gapl
LEFT JOIN gapl_dn gdn ON gdn.clc_id = cl.clc_id AND cl.belongs_to_gapl
LEFT JOIN gapl_pay gp ON gp.clc_id = cl.clc_id AND cl.belongs_to_gapl
LEFT JOIN non_disbursed nd ON nd.clc_id = cl.clc_id AND NOT cl.belongs_to_gapl;
```

**Drill-down:** Filter `cl` to a single `clc_id` and dump `loan_loan`, `payment_payment`, `payment_debitnote` for that line.

**Failure / interpretation:** If T0 sum diverges from on-call expectations, first confirm GAPL vs non-GAPL branch and payment status filters match [`PaymentStatus`](../../payment/constants.py).

---

## T0b — Debit hold: Locus net vs ledger gross (OS bridge)

**Why:** [`get_total_debit_notes`](../../credit_line/utils.py) counts **DH** as `amount - prepaid_amount_settled`. Ledger may still carry **`DEBIT_HOLD`** at full face while prepaid has consumed the hold in Locus logic — a major source of **`Ledger_OS > T0`** for GAPL partners.

**SQL (run both; compare totals):**

```sql
-- Ledger DEBIT_HOLD (visible, active)
SELECT COALESCE(SUM(amount), 0) AS ledger_dh
FROM ledger_ledgerentry
WHERE partner_id = :partner_id AND type = 'DEBIT_HOLD' AND active AND visible;

-- Locus DH net (posted), all lines for partner
SELECT COALESCE(SUM(COALESCE(pd.amount, 0) - COALESCE(pd.prepaid_amount_settled, 0)), 0) AS locus_dh_net
FROM payment_debitnote pd
JOIN credit_line_customercreditline clc ON clc.id = pd.customer_credit_line_id
JOIN credit_line_customer c ON c.id = clc.customer_id
WHERE c.source_identifier_id = :partner_id AND pd.type = 'DH' AND pd.status = 'POSTED';
```

**Interpretation:** Large **`ledger_dh − locus_dh_net`** with **`prepaid_amount_settled ≈ amount`** on DH rows → explain residual OS gap without implying missing payments.

---

## T-LedgerOS — Ledger outstanding (aligned with type lists)

**Formula (signed, same spirit as [`LedgerEntryTypes`](../../ledger/constants.py) and [`_fetch_ledger_limit_partner_aggregation_rows`](../../credit_line/utils.py)):

```
+ INVOICE + FINANCING_FEE + INTEREST + DEBIT_NOTE + DEBIT_ENTRY + DEBIT_HOLD
- PAYMENT - CREDIT_NOTE - RELEASE_PAYMENT
- unrealised_outstanding_payment   -- from credit lines (Locus field)
```

Optional alternate: subtract **`ABS_PAYMENT`** as in `ledger_outstanding_less_abs_payment` in the same Python function.

**SQL — visible + active (operational “statement” view):**

```sql
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
  WHERE partner_id = :partner_id AND active AND visible
),
ur AS (
  SELECT COALESCE(SUM(clc.unrealised_outstanding_payment), 0) AS unrealised
  FROM credit_line_customercreditline clc
  JOIN credit_line_customer c ON c.id = clc.customer_id
  WHERE c.source_identifier_id = :partner_id
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
```

**Drill-down:** Filter by `type` and `date` range; include `visible = false` to reconcile with T-Visibility.

---

## T1 — Invoice + financing fee conservation (refined seed)

**Formula:**  
`loans (seed statuses) + creditnote_used_in_loans + prepaid = ledger INVOICE + ledger FINANCING_FEE`  
(same `active`/`visible` policy on ledger as you standardize — recommend **`active AND visible`** for “statement” recon).

**SQL — LHS pieces:**

```sql
SELECT COALESCE(SUM(ll.loan_amount), 0) AS loans
FROM loan_loan ll
JOIN credit_line_customercreditline clc ON ll.customer_credit_line_id = clc.id
JOIN credit_line_customer c ON clc.customer_id = c.id
WHERE c.source_identifier_id = :partner_id
  AND ll.status IN (
    'DISBURSED', 'PARTIALLY_PAID', 'PAID', 'OVERDUE_AND_PARTIALLY_PAID', 'YET_TO_BE_DISBURSED'
  );

SELECT COALESCE(SUM(pc.amount_used), 0) AS cn_used
FROM payment_creditnote pc
JOIN credit_line_customercreditline clc ON pc.customer_credit_line_id = clc.id
JOIN credit_line_customer c ON clc.customer_id = c.id
WHERE c.source_identifier_id = :partner_id;

SELECT COALESCE(SUM(ii.prepaid_amount), 0) AS prepaid
FROM invoice_invoice ii
WHERE ii.partner_id = :partner_id AND ii.status != 'CANCELLED';
```

**SQL — RHS:**

```sql
SELECT COALESCE(SUM(CASE WHEN type = 'INVOICE' THEN amount ELSE 0 END), 0) AS ledger_inv,
       COALESCE(SUM(CASE WHEN type = 'FINANCING_FEE' THEN amount ELSE 0 END), 0) AS ledger_ff
FROM ledger_ledgerentry
WHERE partner_id = :partner_id AND active AND visible;
```

**Failure:** If `loans + cn_used + prepaid ≠ ledger_inv + ledger_ff`, check duplicate `INVOICE`, wrong `source_no`, cancelled invoices, or PF booked outside `FINANCING_FEE`.

---

## T2a / T2b — Payment parity

**T2a (posting invariant):**  
`SUM(Locus posted payment_amount excluding CREDIT_NOTE) = SUM(ledger PAYMENT amount WHERE active)` — **include invisible ledger rows**.

```sql
SELECT COALESCE(SUM(pp.payment_amount), 0) AS locus_posted_non_cn
FROM payment_payment pp
JOIN credit_line_customercreditline clc ON clc.id = pp.customer_credit_line_id
JOIN credit_line_customer c ON c.id = clc.customer_id
WHERE c.source_identifier_id = :partner_id
  AND pp.status = 'POSTED'
  AND pp.payment_mode != 'CREDIT_NOTE';

SELECT COALESCE(SUM(amount), 0) AS ledger_payment_all_active
FROM ledger_ledgerentry
WHERE partner_id = :partner_id AND active AND type = 'PAYMENT';
```

**T2b (visible “bank” view):** Same ledger query with `AND visible`.

**Failure:** T2a fails → missing/wrong `locus_id` on ledger, wrong `active`, or duplicate payments. T2a passes, T2b fails → visibility pipeline ([`PaymentCreateView`](../../ledger/views.py), `VisibilityBlockedMapping`).

---

## T3-L / T3-ERP — Credit note split (refined seed)

**T3-L (Locus-linked):** Ledger rows with `locus_id` set (adjust join type: payment id vs credit note id as per your data).

```sql
SELECT COUNT(*) AS n_rows, COALESCE(SUM(amount), 0) AS amt
FROM ledger_ledgerentry
WHERE partner_id = :partner_id AND active AND type = 'CREDIT_NOTE' AND locus_id IS NOT NULL;
```

**T3-ERP:** `locus_id IS NULL` (ERP / file / manual).

```sql
SELECT COUNT(*) AS n_rows, COALESCE(SUM(amount), 0) AS amt
FROM ledger_ledgerentry
WHERE partner_id = :partner_id AND active AND type = 'CREDIT_NOTE' AND locus_id IS NULL;
```

**Drill-down — posted CN payments without CREDIT_NOTE ledger row on `locus_id`:**

```sql
SELECT pp.id, pp.payment_amount, pp.payment_date
FROM payment_payment pp
JOIN credit_line_customercreditline clc ON clc.id = pp.customer_credit_line_id
JOIN credit_line_customer c ON c.id = clc.customer_id
LEFT JOIN ledger_ledgerentry le
  ON le.locus_id::text = pp.id::text AND le.type = 'CREDIT_NOTE' AND le.active
WHERE c.source_identifier_id = :partner_id
  AND pp.status = 'POSTED'
  AND pp.payment_mode = 'CREDIT_NOTE'
  AND le.id IS NULL;
```

**Failure:** Do **not** expect aggregate `CN payments + amount_used = SUM(ledger CN)` when ERP rows dominate — fail on **T3-L** only for Locus-sourced CN.

---

## T-Visibility — Hidden vs visible ledger (cross-cutting)

**Formula:** For each type, `SUM(amount | active) − SUM(amount | active AND visible)`.

```sql
SELECT type,
       COALESCE(SUM(amount), 0) AS sum_active,
       COALESCE(SUM(CASE WHEN visible THEN amount ELSE 0 END), 0) AS sum_visible,
       COALESCE(SUM(amount), 0) - COALESCE(SUM(CASE WHEN visible THEN amount ELSE 0 END), 0) AS deferred
FROM ledger_ledgerentry
WHERE partner_id = :partner_id AND active
  AND type IN ('PAYMENT', 'CREDIT_NOTE', 'DEBIT_NOTE', 'DEBIT_HOLD', 'DEBIT_ENTRY', 'INVOICE')
GROUP BY type
ORDER BY type;
```

**Interpretation:** Large **`deferred`** on `PAYMENT` drives **visible** ledger OS down while Locus cash totals may still include those payments.

---

## T4 — Interest consistency

**Formula (pick one policy and stick to it):**

- **Billed in ledger:** `SUM(ledger INTEREST)` vs loan accrual fields for the same partner.
- **Outstanding interest:** compare remaining interest components on loans to a scoped ledger slice (product-specific — see [`update_interest_data_into_ledger`](../../credit_line/utils.py)).

**SQL (drift check):**

```sql
SELECT COALESCE(SUM(ll.total_interest + COALESCE(ll.total_penal_interest, 0)
  + COALESCE(ll.total_overdue_interest, 0)), 0) AS loan_interest_components
FROM loan_loan ll
JOIN credit_line_customercreditline clc ON clc.id = ll.customer_credit_line_id
JOIN credit_line_customer c ON c.id = clc.customer_id
WHERE c.source_identifier_id = :partner_id
  AND ll.status NOT IN ('REJECTED', 'CANCELLED', 'MOVED_TO_LENDER');

SELECT COALESCE(SUM(amount), 0) AS ledger_interest
FROM ledger_ledgerentry
WHERE partner_id = :partner_id AND active AND visible AND type = 'INTEREST';
```

**Failure:** Interest job not run, wrong products in aggregation, or ledger stores net billed vs full components.

---

## T5 — Financing fee (ties to T1)

Already in T1 RHS as `ledger_ff`. Optionally join loans on `ledger_ledgerentry.locus_id::text = loan.id::text` and `type = 'FINANCING_FEE'` for row-level match ([`create_pf_entry_into_ledger`](../../credit_line/utils.py)).

---

## T6 — Debit note / hold / entry mapping

**Row-level:** Each posted `payment_debitnote` should have an `active` ledger row with `locus_id::text = debitnote.id::text` and type from [`DebitNoteTypes.LedgerEntryMap`](../../payment/constants.py).

```sql
SELECT pd.id, pd.type, pd.amount, pd.status, le.id AS le_id, le.type AS le_type, le.amount AS le_amt, le.visible
FROM payment_debitnote pd
JOIN credit_line_customercreditline clc ON clc.id = pd.customer_credit_line_id
JOIN credit_line_customer c ON c.id = clc.customer_id
LEFT JOIN ledger_ledgerentry le
  ON le.locus_id::text = pd.id::text
 AND le.type IN ('DEBIT_NOTE', 'DEBIT_HOLD', 'DEBIT_ENTRY')
 AND le.active
WHERE c.source_identifier_id = :partner_id
  AND pd.status = 'POSTED'
  AND (le.id IS NULL OR pd.amount != le.amount);
```

**Failure:** Upload pipeline, cancellation, or **visible=false** on prepaid-related DNs (see T-Visibility).

---

## T7 — Release payment

```sql
SELECT COALESCE(SUM(amount), 0) AS release_pay
FROM ledger_ledgerentry
WHERE partner_id = :partner_id AND active AND visible AND type = 'RELEASE_PAYMENT';
```

Map to Locus payments with context / release flows ([`PaymentCreateView`](../../ledger/views.py)).

---

## T8 — Roll-forward (incident window)

**Template:**

```sql
WITH bounds AS (
  SELECT :window_start::date AS d0, :window_end::date AS d1
),
opening AS (
  SELECT COALESCE(SUM(
    CASE
      WHEN ll.type IN ('INVOICE','DEBIT_HOLD','DEBIT_NOTE','INTEREST','FINANCING_FEE','DEBIT_ENTRY')
        THEN ll.amount
      WHEN ll.type IN ('PAYMENT','CREDIT_NOTE','RELEASE_PAYMENT','ABS_PAYMENT')
        THEN -ll.amount
      ELSE 0
    END
  ), 0) AS os
  FROM ledger_ledgerentry ll, bounds b
  WHERE ll.partner_id = :partner_id AND ll.active AND ll.visible AND ll.date::date < b.d0
),
flows AS (
  SELECT COALESCE(SUM(
    CASE
      WHEN ll.type IN ('INVOICE','DEBIT_HOLD','DEBIT_NOTE','INTEREST','FINANCING_FEE','DEBIT_ENTRY')
        THEN ll.amount
      WHEN ll.type IN ('PAYMENT','CREDIT_NOTE','RELEASE_PAYMENT','ABS_PAYMENT')
        THEN -ll.amount
      ELSE 0
    END
  ), 0) AS delta
  FROM ledger_ledgerentry ll, bounds b
  WHERE ll.partner_id = :partner_id AND ll.active AND ll.visible
    AND ll.date::date >= b.d0 AND ll.date::date < b.d1
),
closing AS (
  SELECT COALESCE(SUM(
    CASE
      WHEN ll.type IN ('INVOICE','DEBIT_HOLD','DEBIT_NOTE','INTEREST','FINANCING_FEE','DEBIT_ENTRY')
        THEN ll.amount
      WHEN ll.type IN ('PAYMENT','CREDIT_NOTE','RELEASE_PAYMENT','ABS_PAYMENT')
        THEN -ll.amount
      ELSE 0
    END
  ), 0) AS os
  FROM ledger_ledgerentry ll, bounds b
  WHERE ll.partner_id = :partner_id AND ll.active AND ll.visible AND ll.date::date < b.d1
)
SELECT opening.os AS opening_os, flows.delta AS window_delta, closing.os AS closing_os,
       opening.os + flows.delta - closing.os AS check_residual
FROM opening CROSS JOIN flows CROSS JOIN closing;
```

**Failure:** Non-zero **check_residual** → backdated `date`, `active`/`visible` toggles, or types outside the CASE.

---

## T9 — Loan vs ledger invoice linkage

**Drill-down:**

```sql
SELECT ll.id AS loan_id, ll.loan_amount, le.id AS le_id, le.amount, le.source_no, le.visible
FROM loan_loan ll
JOIN credit_line_customercreditline clc ON clc.id = ll.customer_credit_line_id
JOIN credit_line_customer c ON c.id = clc.customer_id
LEFT JOIN ledger_ledgerentry le
  ON le.partner_id = c.source_identifier_id::text
 AND le.type = 'INVOICE'
 AND (le.source_no = ll.invoice_number OR le.locus_id::text = ll.id::text)  -- adjust to your canonical link
WHERE c.source_identifier_id = :partner_id
  AND ll.status NOT IN ('REJECTED', 'CANCELLED', 'MOVED_TO_LENDER')
LIMIT 200;
```

Adjust the `JOIN` condition to the field your pipeline actually uses (`source_no`, `locus_id`, etc.).

---

## T10 — Utilization / limit (operational)

Use [`compute_available_credit_limit`](../../credit_line/utils.py) in application code or mirror its SQL in a dedicated runbook — too many inputs for a short template here. **Flag:** mixed **GAPL** + **ONHOLD** lines on one partner require per-line computation first.

---

## Decision tree (triage order)

1. **T0** vs **T-LedgerOS** (or your legacy signed query) — confirm **definition** of Locus OS and ledger buckets.
2. **T0b** if **`Ledger_OS >> T0`** on GAPL — **DEBIT_HOLD** vs **DH net** (prepaid settled).
3. **T-Visibility** — hidden **PAYMENT** / **DEBIT_NOTE** inflating gap vs visible-only ledger.
4. **T1** — invoice + **FINANCING_FEE**.
5. **T2a** then **T2b** — posting vs visibility.
6. **T3-L** / **T3-ERP** — CN attribution (do not false-fail on ERP totals).
7. **T4** / **T6** — interest and debit instruments.
8. **T8** for dated incidents.

---

## Worked example: partner `1048357` (validated snapshots)

| Check | Result (historical snapshot) |
|-------|------------------------------|
| Ledger OS (user signed formula, visible+active) | 151042.65 |
| Sum `outstanding_amount` column | 0 — misleading |
| T0 line OS (GAPL + non-GAPL) | ~131044.21 (see T0 SQL; uses code-aligned GAPL math) |
| T0b | Ledger **DEBIT_HOLD** 20000; Locus DH **net** 0 when prepaid settles hold → bridges most of OS gap |
| T1 refined | LHS = RHS when RHS includes **FINANCING_FEE** (delta was 1.18 before) |
| T2a | Locus non-CN posted = ledger **active** PAYMENT totals |
| T2b | Delta explained by **hidden** payments (~184196.65) |
| T3 | Split **95** CN rows: **92** with `locus_id` null (ERP-heavy) |
| T4 | Small drift (~1–2) between loan interest components and ledger **INTEREST** |
