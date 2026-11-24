# P2 Backend Acceptance Evidence — Abroa

Validated on 2026-11-24 in isolated WSL distro `Abroa-P1-Test`, PostgreSQL 17 on port 55433. All application files and test artifacts are on `D:\开发\Abroa`. This document records **backend** acceptance only; it is not a production-deployment or user-interface sign-off.

| Scope | Implemented and tested |
| --- | --- |
| P2.1 Study project, periods, accounts, allocations | Project ownership, write/read scopes, optimistic locking, archive/restore, shared-account authorization, ledger conservation, idempotent retries, concurrent entry allocation, scoped cursors, history and project summary |
| P2.2 Layered budgets | Parent/child date and scope constraints, period budget rollover and version history, budget execution with expenses vs committed amounts, category splits, refund timing, deficit and missing-rate warnings |
| P2.3 Funding pools | Native-currency virtual allocations, reserved/free cash, shared ceiling with Sure Goal, account authorization, audit events, posted-entry spending and refund binding, idempotent movement replays, PostgreSQL two-connection concurrency and lock ordering. Linked Goal pool consume/refund now binds to Sure Goal's authoritative original transaction and earmark without counting twice; maintained reserves refuse consumption. |
| P2.4 Fixed fees | Tuition/visa/rent/deposit plans, discount/waiver/scholarship_offset/surcharge adjustments without fictional cash receipts, installment schedules, verified ledger payment and refund links, no double settlement, permissions on private payment totals, automatic reservation release on unpaid cancellation, money pool and Sure Goal settlement synchronization, durable due-soon and overdue reminder event outbox. |
| P2.4 Sure recurring bridge | Explicit date-scoped import and daily scheduled job (`05:45 UTC`, after Sure's `05:30 UTC` occurrence generation) to copy authorized `RecurringOccurrence` snapshots into Abroa installments; unique occurrence binding, replay protection, source-account permissions, no extra `Entry`, fail-closed currency matching; occurrence FK nullifies on source deletion. A second daily `05:55 UTC` job emits deduplicated fee reminder events. |

## Acceptance runs

- Focused Abroa + selected Sure original regression: **1,043 tests, 3,783 assertions, 0 failures, 0 errors, 0 skips**. Evidence: `D:\开发\Abroa\.p2-env\logs\p2-remaining-complete-regression.log`.
- Complete P1/P2 Abroa-focused directory sweep of **48 test files, 215 tests, 1,260 assertions, 0 failures, 0 errors, 0 skips**; covers models, API controllers, jobs and P1 integration tests. Evidence: `D:\开发\Abroa\.p2-env\logs\p2-p1-full-regression-2.log` and `p2-p1-full-test-files.txt`.
- Fresh database (`abroa_p2_final_remaining_fresh_test`) loaded with `db:schema:load`, followed by **68 tests, 399 assertions, 0 failures/errors**. Evidence: `D:\开发\Abroa\.p2-env\logs\p2-final-remaining-fresh.log`. Existing isolated databases were never dropped or overwritten.
- OpenAPI regeneration and semantic merge: **566 examples, 0 failures, 89 existing documentation-only pending**; prior API routes and components retained. Evidence: `p2-remaining-openapi-generate.log`, `p2-remaining-openapi-merge.log`.
- Ruby lint: `p2-remaining-rubocop1.log` (17 changed files; no offenses).
- Security scan: `p2-remaining-brakeman.log` (0 unignored warnings, 8 pre-existing ignored warnings).
- API endpoint consistency verifier passed. Existing baseline compliance notices: `financekit_spec.rb` uses OAuth in rswag; `transactions_spec.rb` and `transfers_spec.rb` contain rswag expectations. Those are pre-existing and not introduced by P2.

## Boundary and follow-on work

- Recurring bills are imported by both **explicit API action** and a **daily scheduled ActiveJob**. The schedule has been validated in code and isolated tests; no production worker runtime or actual cron fire has been certified. Sure remains the source of the recurrence schedule.
- A pool directly linked to a Sure Goal is a view of that existing earmark, not a second balance. Posted transaction `consume` calls Sure Goal's native consumption workflow atomically; verified linked refunds restore its fixed earmark. Maintained Sure reserve consumption is still intentionally refused under upstream financial rules.
- Reminder events are persisted as an outbox, **not delivered** by email or a user inbox in P2; P4.3 owns the notification delivery channels. Parent/family collaboration (P3), front-end/PWA (P7), public payment integration and production deployment (P5/P8) are outside P2. None are certified here.
- The zero-warning security result refers to non-ignored Brakeman warnings. The repository retains existing ignored findings; review their justification separately before production release.

## Main commits

- P2.1: `ae9aa85cc`, `6adc918aa`, `843bdd645`
- P2.2: `578700898`, `9a3803484`
- P2.3: `cfb87862b`, `35fdf2b99`
- P2.4: `73d4eb91d`, `268e29f83`
- P2.4 recurring bridge: `45a747ac0`, `3154c4ca7`.
- P2 final completion: `ec4f19f54` (Sure Goal consumption/refund), `98461cc28` (scheduled recurring sync and fee reminders), `7b4edfde2` (audited fee adjustments, API and OpenAPI).

The original Sure ledger remains authoritative. Virtual allocations, funds, budgets, fees and credits are references or projections of confirmed source facts, not replacement transactions.
