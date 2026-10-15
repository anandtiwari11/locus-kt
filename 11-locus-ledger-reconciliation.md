# Locus–ledger reconciliation (outstanding / overdue)

Use this when **partner-level outstanding or overdue** from ledger-backed views does not match **locus credit-line** aggregates.

## Canonical mapping

Full entity → ledger type → credit-line field reference:

- [`docs/locus-ledger-aggregate-mapping.md`](../locus-ledger-aggregate-mapping.md)

## Command-line evidence (NDJSON + stdout summary)

From the `locus` project root (with Django configured):

```bash
python manage.py debug_partner_reconcile <source_identifier_id> [--run-id my-run]
```

The command:

- Pulls **`fetch_ledger_limit_reconciliation_breakdown`**: per-type amounts, `ledger_outstanding`, `ledger_outstanding_less_abs_payment`, unrealised used in the limit formula.
- Pulls **`populate_all_credit_lines`** and compares **sum of all GAPL lines’** `total_outstanding_amount` to ledger (not only the first GAPL line).
- Retains checks for POSTED payments / GAPL debit notes missing ledger rows, and prepaid release bundles.

Evidence is appended to `.cursor/debug-afe3dd.log` (NDJSON). A one-line **stdout summary** includes ledger OS, ABS-adjusted OS, summed GAPL OS, and gap deltas.

## Read-only SQL angles

- **Ledger buckets:** group `ledger_ledgerentry` by `type` for `partner_id`, `active`, `visible`.
- **Locus GAPL stack:** use the same CTE structure as `populate_all_credit_lines` or inspect `loan_loan` + `payment_payment` for the partner’s GAPL credit line ids.
- **Drill:** `ledger_ledgerentry.source_no` ↔ `invoice_invoice.odn_no`, `locus_id` ↔ `payment_payment.id` / `payment_debitnote.id`.

## Identifier note

Prefer `source_identifier_id::text = partner_id` in SQL if either side was ingested as a different atomic type.
