# Abroa P3 Backend — Formal Acceptance (2026-11-25)

**Status: VERIFIED for P3.1–P3.4 backend scope.** This is not public-production or P5/P6 end-to-end sign-off.

- Repository: `D:\开发\Abroa\Abroa`
- Branch: `abroa/development`
- P2 frozen parent: `2f9152daaf976e9f9bd30bed82361d98061522b2`
- **Accepted P3 business-code Git commit: `119317b9c`** — `Add P3 parent collaboration and real-ledger funding`
- Test WSL `Abroa-P1-Test` and all P3 test/stage files: D-backed. No P1/P2 staged data, production database, live bank, or payment connection was changed.

## Executed evidence

| Gate | Actual result | Evidence |
|---|---|---|
| Full clean Rails suite (isolated PG17 database `abroa_p3_full_clean`) | **19,164 tests, 116,966 assertions; 0 failures, 0 errors, 10 skips; exit 0** | `D:\开发\Abroa\.p3-env\logs\20261125T034319Z-153906.log` |
| Follow-up API negative cases added after full-suite run | **21 tests, 215 assertions; 0 failures/errors/skips; exit 0** | `D:\开发\Abroa\.p3-env\logs\20261125T044218Z-188240.log` |
| P1/P2/P3 critical financial and identity regression | **1,232 tests, 4,903 assertions; 0 failures/errors/skips; exit 0** | `D:\开发\Abroa\.p3-env\logs\20261125T033937Z-150490.log` |
| Real PostgreSQL concurrent transactions | **5 tests, 26 assertions; 0 failures/errors/skips; exit 0** | `D:\开发\Abroa\.p3-env\logs\20261125T034108Z-151630.log` |
| P3 documentation-only rswag | 52 examples, 0 failures; exit 0 | `D:\开发\Abroa\.p3-env\logs\20261125T034150Z-152298.log` |
| Full OpenAPI regeneration | 618 examples, 0 failures; 89 documentation-only pending; exit 0, generated `docs/api/openapi.yaml` | `D:\开发\Abroa\.p3-env\logs\20261125T034218Z-152819.log` |
| Endpoint consistency after Git commit | Pass, exit 0 | `D:\开发\Abroa\.p3-env\logs\20261125T044855Z-192549.log` |
| Ruby lint | RuboCop 61 changed/relevant files, no offenses, exit 0, including late API test additions | `D:\开发\Abroa\.p3-env\logs\p3-rubocop.log` |
| Brakeman full app | 234 controllers, 871 models, 0 errors, 0 security warnings, exit 0; eight ignored historical warnings | `D:\开发\Abroa\.p3-env\logs\p3-brakeman.txt` |
| PG17 schema/migrations | Six P3 migrations `20261125100000` through `20261125105000` all `up`; `db/schema.rb` synchronized | P3 Docker stage `rails db:migrate:status`, same acceptance log |
| Independent Docker P3 stage after encryption backfill | **All checks passed, process exit 0**: PG, Redis, Web healthy; HTTP `/up=200`; real synthetic parent/student API flow; after revocation `200→404`; real ledger receipt 400 GBP and posted refund 100 GBP, net 300 GBP without creating synthetic Entries; Worker two cron jobs processed before **and** after restart | `D:\开发\Abroa\.p3-stage\logs\docker-p3-acceptance.log`, `P3_STAGE_ALL_CHECKS_PASSED sha=119317b9c` |

## P3 feature acceptance

- **P3.1 — Parent/student independent identities, invitation, relationship and grants**: One-time email-bound invite; reject/revoke/replay and cross-family IDOR checks; no implied permission; effective scope expiry/revoke; immediate API 404 after revocation.
- **P3.2 — Independent parent drafts, proposals, direct budget edit**: Draft-to-proposal snapshot and status synchronization; budget creation/adjustment and study project amendments effective only after student approval, except the explicitly granted bounded direct-budget-edit scope; optimistic versions, cross-project checks and audit history.
- **P3.3 — Parent funding and actual bank-backed receipts**: Parent funding plans, recurrence, bank-sent notices that never count as receipt, student-proposed modifications with parent approval, student-confirmed destination, one-to-one real posted Sure Entry allocation, immutable historical FX quote, real refund Entry reversal, source-ledger drift invalidation. New funding plans do **not** mint money.
- **P3.4 — Parent-only scoped project aggregation**: Read-only project, budgets, fees, pools, expense and funding summaries; private account/entry identifiers are not leaked without separate authorization. Scope and relationship revocation take effect immediately.

## Stage build and isolation

The accepted stage image **`abroa-p3-overlay:119317b9c`**, ID `sha256:2755fe3799e0f531a1fddf859526e763922ddf9b735aecf249947738c5afc051`, is built with `Dockerfile.p3-overlay` from the previously verified immutable P2 image `abroa-p2-stage:2f9152daa`, then **copies the complete frozen P3 Git archive** from `/var/lib/abroa-p3-stage/source`. `bundle check` passed. Dependencies were not changed by P3. This is an **incremental overlay image**, **not** a fully from-scratch image build; the latter was started but stopped during lengthy dependency downloads and is not claimed to have passed.

Staging files are `D:\开发\Abroa\.p3-stage`; Compose project `abroa-p3-stage`; isolated named PostgreSQL, Redis and app-storage volumes; Web bound only to `127.0.0.1:3043`. `P2` continues in its separate `abroa-p2-stage` project. All staging identities and financial entries are synthetic.

## Encryption warning resolved in P3 stage

Initial P3 stage boot showed the upstream Sure `ActiveRecord Encryption` backfill-completion warning. A **dry run** of `security:backfill_encryption[100,true]` passed with zero failed rows. The **actual write pass** `[100,false]` was then performed **only on the P3 stage database**, encrypting 2 synthetic user rows and 1 synthetic API-key row with zero failures, followed by P3 Web/Worker restart. Logs: `D:\开发\Abroa\.p3-stage\logs\p3-encryption-backfill-dryrun.log` and `p3-encryption-backfill-apply.log`. The complete P3 stage API/cron/restart acceptance was subsequently rerun with success, and the earlier backfill-incomplete warning did not recur. No other database was backfilled.

## Scope exclusions and qualifications

- Full Rails suite has **10 skips**, and rswag has **89 documentation-only pending** examples; these are not counted as passes.
- The source review (`docs/P3_CODE_REVIEW.md`) was performed by the implementation agent, not an independent human audit.
- No live Google OIDC/SSO credentials, real banking or external-provider callbacks, live payments, actual production deployment, real notification delivery or public traffic were exercised. Isolated stage logs intentionally note unavailable SSO/Posthog/Skylight configurations.
- The accepted image remains the pinned business-code SHA `119317b9c`. A later documentation-only sign-off commit must not be confused with a new business-code build.
- P4+ (receivables, forecasting, notification channels, AI, operational admin), P5 infrastructure/public deployment, P6 system-wide acceptance and P7/P8 frontend/release remain outside this phase. Do not infer their verification from P3 completion.
