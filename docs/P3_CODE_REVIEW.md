# Abroa P3 — Backend code-review record

Date: 2026-11-25
Branch: `abroa/development`
Parent baseline: `2f9152daa` (P2 passed and frozen)
Scope: P3.1 relationships/grants, P3.2 drafts/proposals/direct-edit, P3.3 real-ledger funding and reversals, P3.4 parent aggregate projection.

This is a separate source review after implementation by the current execution agent, not an external human or independent-organization audit. Findings are recorded with failing regression tests before repairs. Formal approval is conditional on the final P3 acceptance report and staging run.

## Trust boundaries reviewed

- Sure `Current.family` is unchanged. Cross-tenant access requires explicit `Relationship` / `Grant` checks against both user and family, active status, scope, project ownership, resource kind/id and expiration. The relationship alone grants no project rights.
- Parent project discovery uses a project-level `summary` grant; scope-restricted views never instantiate an arbitrary family as `Current.family`. All IDOR paths respond 404 and role-restricted writes use the original API-key scope requirement.
- Parent drafts live in the parent's family. Proposals are recorded against the student's project and only become effective within a version-checked student-confirmation transaction, with a separate audit record.
- Funding plans, notices and suggestions never create `Entry`, `Transaction`, `Account.balance` mutations or synthetic money. Student matching references only validated posted real ledger entries in the student's account, one entry at most once. Refunds require separate real outgoing entries. Historical FX captured at match time, source-ledger drift invalidates projections.
- P3 PostgreSQL migrations include idempotency hashes, tenant FKs, unique active relation/grant and unique real-ledger entry references. PostgreSQL concurrent acceptance, grant revoke/direct edit, proposal approval/rejection, duplicate receipt and duplicate reversal are verified in the dedicated nontransactional tests.

## Concrete issues and repair evidence

| Finding | Severity | Before | Resolution / verification |
|---|---|---|---|
| Funding receipt whose source ledger amount later changes could still appear as paid | High | New regression first failed (`8 runs, 50 assertions, 1 failure`) | `FundingPlan.evidence_consistent?` checks every receipt and reversal; invalid projections return `incomplete` with amounts null rather than false confidence; follow-up model suite `12/93` green. |
| Parent could still read funding plan metadata after relationship revocation | High | New negative test first failed (`14 runs, 80 assertions, 2 failures`) | `FundingPlan.for_actor` restricts to active relationship and corresponding parent family, `payload_for` denies revoked-parent reads; group `20/136` green. |
| Parent proposal could remain visible after effective `propose` permission revoked | High | Found during separate access audit | `Proposal.for_actor` filters parent view by active relation and effective `propose` Grant; student retains review history. Parent cancellation also requires renewed authorization. |
| An unrelated project-level `budget_manage` grant could shadow a valid resource-specific grant | Medium | Targeted extra-resource test added | Direct edit grant selection now requires the actual target budget's project in SQL; tests ensure target edited once and unrelated project unchanged. |
| Windows CRLF checkout made legacy CSV and AI routing markdown tests fail, unlike P2 Git archive source | Test infrastructure | Full test showed Monarch CSV parse and AI matrix errors; Git blob has LF, Windows file CRLF | P3 isolated runner now creates its baseline from `git archive HEAD`, then overlays only working changes. Original P2 files and source repository fixtures are unchanged. Final full rerun must be recorded. |
| Changed refund source ledger amount could be trusted as an original reversal | High | New regression test added in `funding_plan_test.rb`; awaiting isolated execution | Fix must store and validate original refund entry amount and currency, including cross-FX audit provenance; unresolved until green rerun. |

## Automated static checks

- RuboCop: first run, 40 relevant Ruby files, 52 formatting errors (104 source positions); safe autocorrection applied to all 52. A clean post-correction run is required for final sign-off; no test assertions were altered as a fix.
- Brakeman: full source scan reported 0 errors, 0 security warnings, 8 existing ignored warnings and one obsolete ignore entry (log `D:\开发\Abroa\.p3-env\logs\p3-brakeman.txt`); security scan exit 0. Ignored warnings do not constitute independent review of all business rules.
- Dedicated PostgreSQL concurrency run: 5 tests, 26 assertions, no failures/errors, exit 0.
- Rswag: documentation coverage exists for P3 routes; initial run failed from missing documentation-only request header, corrected; full confirmation pending.

## Open review obligations

Full Rails regression, all P3 unit/API tests after final corrections, post-correction RuboCop, documentation rswag run, OpenAPI route consistency, fresh DB upgrade, staged Docker Web/Worker and task restart, staging real HTTP API smoke, Git commit and final SHA verification must all complete before setting VERIFIED. No production bank, provider secrets, or user data may be used.

P4+ tasks (receivables, forecasting, notification delivery, AI, subscription/administration, PWA) are explicitly excluded from this P3 review.
