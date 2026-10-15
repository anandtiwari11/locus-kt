## Flow documentation maintenance

This document defines when and how to keep the flow documentation in `docs/flows/` up to date.

### When to update flow docs

Update the relevant flow document when any of the following happens:

- You add, remove, or rename a public API endpoint involved in a flow.
- You add, remove, or significantly change a Celery task that participates in a flow.
- You introduce new statuses, constants, or state transitions that affect a flow.
- You add or remove a significant integration (e.g., Saraloan, SAP, payment gateway).
- You change the success criteria or error handling of a flow.

### What to update

When you modify a flow:

- **Overview**: Ensure the high-level description still matches what the code does.
- **Entry points**: Add/remove updated view functions, tasks, or utility entry points.
- **Step-by-step breakdown**: Adjust steps to reflect new logic and important branches.
- **Key models/constants**: Add new models/status enums or remove deprecated ones.
- **Mermaid diagram**: Update to reflect new or removed steps, decisions, or outcomes.

### PR checklist

For any PR that touches flows:

- [ ] Checked whether any existing flow doc in `docs/flows/` is affected.
- [ ] Updated the relevant flow doc(s) if needed.
- [ ] Added a new flow doc if a new end-to-end business flow was introduced.

### Suggested review cadence

- **Quarterly**:
  - Skim all docs in `docs/flows/` and confirm they still match the current code.
  - Cross-check `FLOW_INVENTORY.md` against major packages (`lead`, `loan`, `payment`, `farmer_financing`, `credit_line`, etc.).
- **Onboarding**:
  - Ask new developers to read relevant flow docs and flag inconsistencies.

