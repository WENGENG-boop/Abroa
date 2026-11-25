# Abroa P3 Backend Acceptance — execution evidence

Date: 2026-11-25
Repository: `D:\开发\Abroa\Abroa`
Branch: `abroa/development`
P2 frozen HEAD at start: `2f9152daaf976e9f9bd30bed82361d98061522b2`
Status: **IN_PROGRESS**. Do not interpret implemented source or isolated unit success as formal P3 verification.

## P3 execution and behavior

| Work package | Delivered code | Focused actual execution (not full stage sign-off) |
|---|---|---|
| P3.1 A08 | Isolated parent/student relation, hashed single-use invite, accepted/rejected/revoked state, student-scoped resource Grant, role-checked API | Early focused suite 7 tests, 51 assertions, 0 fail, 0 error, exit 0 |
| P3.2 A08 / BUDGET-05 | Independent parent drafts, budget-create/update and study-project-update proposals, student approval/rejection, revoke/expiry/version and budget-node direct edit, audit history | Expanded focused suite 10 tests, 61 assertions, 0 fail, 0 error, exit 0 |
| P3.3 A09 / FUND-03–06 | Parent funding plans and recurrence, student confirmation, separate bank-sent notices, student changes to parent's plan, real posted Entry matching and historical FX, refund ledger reversals | Prior full package-focused suite 15 tests, 105 assertions, 0 fail, 0 error, exit 0; later additional refund-drift negative test awaiting verification |
| P3.4 A08/A09 | Parent-scoped project listings, budget/fee/pool/cash/cost/funding aggregates, filtered entry visibility | Focused suite 7 tests, 62 assertions, 0 fail, 0 error, exit 0 |
| Concurrent PostgreSQL | Independent PG17 sessions and row locks for relation invite, grant revoke, proposal race, duplicate receipt, duplicate reversal | 5 tests, 26 assertions, 0 fail, 0 error, exit 0 |

These are distinct targeted suite files; initial cumulative completed test cases were 44 and assertions 305, **not** a substitute for the final suite. Logs are under `D:\开发\Abroa\.p3-env\logs\`. Final numbers are to be copied from the actual last green command and must not be inferred.

## Data and environmental isolation

- Test WSL distribution `Abroa-P1-Test` is backed by a VHDX on D, and P3 uses new PostgreSQL 17 cluster `abroap3`, port 55434, with `abroa_p3_test` and a separately allocated full regression database. Redis port 56381 DB 1. P1/P2 frozen databases, P2 Docker environment, and production databases are untouched.
- P3 new migrations: `20261125100000`, `20261125101000`, `20261125102000`, `20261125103000`, `20261125104000`; migrations completed successfully on P3 DB. If additional safety migrations are added, record their actual result here.
- All funds used in tests are synthetic local fixtures and posted mock Sure transactions. No real bank connections, external payments, or production credentials are used.
- Test runner: `D:\开发\Abroa\.p3-env\scripts\run-p3.sh`; creates a byte-accurate P2 `git archive` worktree and overlays only P3 modifications; Windows CRLF test fixture issue identified and corrected within isolated runner, source fixtures left unchanged.
- Full test and isolated Docker stage have not yet been signed off. Web/Worker 200/healthy is insufficient without test parent/student API and state transitions.

## Code and security audit

- Brakeman full-tree scan exit 0 with zero security warnings and zero errors; report `D:\开发\Abroa\.p3-env\logs\p3-brakeman.txt` (eight existing ignored warnings).
- RuboCop 40 Ruby files, initially 52 formatting errors; safe automatic correction completed, a fresh lint pass pending.
- Source review covers cross-tenant IDOR, revocation, stale historical ledger evidence and source/currency immutability, plus unique-index race protections. Findings in `docs/P3_CODE_REVIEW.md`.

## Remaining formal acceptance gates

1. Confirm full Rails run on LF-normalized Git baseline ends with actual final counts, no new P3 failures and known baseline exception classification.
2. Finish refund evidence drift repair and rerun all P3 tests + PostgreSQL concurrency against a fresh isolated database.
3. Complete P3 rswag documentation tests, generate and validate OpenAPI and endpoint consistency.
4. Confirm RuboCop clean and Brakeman no security warnings after final modifications.
5. Generate repository `db/schema.rb` from migrated P3 schema; ensure P2→P3 upgrade and fresh schema load both work.
6. Commit feature groups, freeze a final SHA; build **independent** P3 Docker image from that SHA and start isolated DB, Redis, Web, Worker.
7. Exercise test-only P3 HTTP API and real task processing/restart in staging; record logs, exit codes, image and SHA.
8. Update implementation matrix to VERIFIED only after all gates are evidenced. State any unresolved external/noncritical risks explicitly.

P4+ work not required for P3: receivables, forecasts, notification-channel delivery, AI workflow, operational admin/paid plans, Web/PWA frontend, public deployment.
