# P2 Backend Acceptance Evidence — Abroa

Validated on 2026-11-24 in isolated WSL distro `Abroa-P1-Test`, PostgreSQL 17 on port 55433. All application files and test artifacts are on `D:\开发\Abroa`. This document records **backend** acceptance only; it is not a production-deployment or user-interface sign-off.

| Scope | Implemented and tested |
| --- | --- |
| P2.1 Study project, periods, accounts, allocations | Project ownership, write/read scopes, optimistic locking, archive/restore, shared-account authorization, ledger conservation, idempotent retries, concurrent entry allocation, scoped cursors, history and project summary |
| P2.2 Layered budgets | Parent/child date and scope constraints, period budget rollover and version history, budget execution with expenses vs committed amounts, category splits, refund timing, deficit and missing-rate warnings |
| P2.3 Funding pools | Native-currency virtual allocations, reserved/free cash, shared ceiling with Sure Goal, account authorization, audit events, posted-entry spending and refund binding, idempotent movement replays, PostgreSQL two-connection concurrency and lock ordering |
| P2.4 Fixed fees | Tuition/visa/rent/deposit plans, discounts without fictional cash receipts, installment schedules, verified ledger payment and refund links, no double settlement, permissions on private payment totals, automatic reservation release on unpaid cancellation, money pool settlement synchronization |
| P2.4 Sure recurring bridge | Explicit date-scoped import of existing Sure `RecurringOccurrence` into Abroa installment snapshots, unique occurrence binding, replay protection, source-account permissions, no extra `Entry`, fail-closed currency matching; occurrence FK nullifies on source deletion to avoid breaking Sure |

## Acceptance runs

- Focused Abroa + selected Sure original regression: **1,028 tests, 3,684 assertions, 0 failures, 0 errors, 0 skips**. Evidence: `D:\开发\Abroa\.p2-env\logs\p2.4-recurring-complete-regression.log`.
- Fresh database (`abroa_p24_recurring_fresh_test`) loaded with `db:schema:load`, followed by **53 tests, 300 assertions, 0 failures/errors**. Evidence: `D:\开发\Abroa\.p2-env\logs\p2.4-recurring-fresh.log`. Existing isolated databases were never dropped or overwritten.
- OpenAPI regeneration and semantic merge: **563 examples, 0 failures, 89 existing documentation-only pending**; prior API routes and components retained. Evidence: `p2.4-recurring-openapi-generate.log`, `p2.4-recurring-openapi-merge.log`.
- Ruby lint: `p2.4-recurring-lint-final.log`.
- Security scan: `p2.4-recurring-security-final.log`.
- API endpoint consistency verifier passed. Existing baseline compliance notices: `financekit_spec.rb` uses OAuth in rswag; `transactions_spec.rb` and `transfers_spec.rb` contain rswag expectations. Those are pre-existing and not introduced by P2.

## Boundary and follow-on work

- Recurring bills are imported by **explicit API action**. There is not yet a scheduled, autonomous recurring-fee sync job; Sure remains the source of its recurrence schedule.
- A pool directly linked to a Sure Goal is a view of that existing earmark, not a second balance. Direct pool `consume` for such a linked Goal is intentionally refused; the native Sure Goal consumption workflow must be used until a separately reviewed, atomic bridge is implemented.
- No parent/family collaboration UI, notification emails, public payment integration, or live production data migration is certified here. These require their own milestones and authorization.
- The zero-warning security result refers to non-ignored Brakeman warnings. The repository retains existing ignored findings; review their justification separately before production release.

## Main commits

- P2.1: `ae9aa85cc`, `6adc918aa`, `843bdd645`
- P2.2: `578700898`, `9a3803484`
- P2.3: `cfb87862b`, `35fdf2b99`
- P2.4: `73d4eb91d`, `268e29f83`
- P2.4 recurring bridge: `45a747ac0`, `3154c4ca7`.

The original Sure ledger remains authoritative. Virtual allocations, funds, budgets, fees and credits are references or projections of confirmed source facts, not replacement transactions.
