# Abroa P3 — Backend Code Review and Closure (2026-11-25)

**Review status: CLOSED for P3 scope** against accepted business-code commit `119317b9c` (parent P2 frozen `2f9152daa`). This is an implementation-agent source review, **not an independent human security assessment**. Detailed formal execution evidence: `docs/P3_BACKEND_ACCEPTANCE.md`.

## Security and accounting boundaries inspected

- P3 never merges or elevates Sure household tenancy. Parent and student retain independent `family_id` domains. Explicit active `Relationship` + student-issued `Grant` with role/user/family/project/resource/expiry checks gate cross-family projections and mutations.
- Relationship existence does **not** grant access; revocation immediately invalidates parent projections, proposal visibility and scoped writes. Unauthorized resources are 404. P3 API controllers use `current_resource_owner`, matching project-wide API identity architecture; pre-existing P2 Abroa controllers were updated for this constraint and exercised by P1/P2/P3 regressions.
- Parent-owned drafts remain isolated; proposal creation/submit/approve/reject/cancel are optimistic-version checked, and only accepted proposals apply changes to student project/budget. An independently authorized bounded direct budget edit remains explicit and resource-scoped.
- Funding plans/notices/suggestions do not create cash or Sure `Entry` rows. Student matching must use real, validated, already-posted inbound account `Entry` with unique reference. Refund reversal references a separate real outbound `Entry`. Both receipt and refund retain source amount/currency/date and historical FX evidence; drift marks aggregates `incomplete` instead of reporting trusted totals. Parent-facing projections omit private account and individual transaction identifiers by default.
- PostgreSQL foreign keys, check constraints, uniqueness, row locks, optimistic versions, idempotency digest and separate transaction sessions are exercised by direct negative/concurrent tests.

## Findings and closure

| Finding (initial priority) | Resolution | Actual verification |
|---|---|---|
| Receipt source-ledger drift could report a paid amount (high) | Source evidence checked by `FundingPlan.evidence_consistent?`; invalid projections return `incomplete` and null received amounts | Previously failing regression then model/API suite green; full Rails clean 19,164/116,966 |
| Parent could still read funding after relation revoked (high) | `FundingPlan.for_actor` and `payload_for` require active relation and matching parent family | Parent revocation negative tests and real stage HTTP 200 before / 404 after |
| Parent proposal visible after permission revocation (high) | `Proposal.for_actor` filters by active relationship and valid `propose` Grant; cancel revalidates scope | P3 model/API negative cases plus main regression |
| Unrelated-project grant could shadow valid budget target grant (medium) | SQL candidate selection requires matching budget project and resource | Direct budget edit cross-project test, regression |
| Original refund Entry could later change while reversal remained trusted (high) | New `entry_amount`/`entry_currency` in migration `20261125105000`; stored refund amount/currency/status/rate checked | Additional refund-drift test, clean Rails suite, migrated stage |
| Windows CRLF workspace caused legacy Sure fixture/AI markdown failures (test infrastructure) | Isolated test source rebuilt from Git archive exact LF bytes, overlay only actual changes; no original fixtures modified | Full Rails clean 19,164 tests, 0 failure/error, exit 0 |
| P3 API controllers used session bridge instead of `current_resource_owner` (architecture) | API identity references in P3 and legacy P2 Abroa controllers replaced with authenticated API resource owner, without changing established scope | Architecture check and P1/P2/P3 critical suite 1,232/4,903 clean |

## Final verification

- Ruby: RuboCop inspected 61 relevant files, **0 offenses, exit 0**; Brakeman inspected 234 controllers/871 models, **0 errors, 0 security warnings**, eight existing ignored warnings, exit 0. A separate independent audit remains advisable before public production.
- Minitest: **19,164 runs, 116,966 assertions, 0 failures/errors, 10 skips, exit 0**; later additional P3 API negative cases **21 runs, 215 assertions, 0 failures/errors/skips, exit 0**.
- PostgreSQL contention: **5 tests, 26 assertions, 0 failures/errors, exit 0**.
- Rswag/API: P3 52 examples no failure; full OpenAPI 618 examples, 89 explicitly documentation-only pending, no failures; regenerated `docs/api/openapi.yaml`; endpoint consistency after commit pass (exit 0).
- Docker: P3 stage isolated from P2, overlay image `abroa-p3-overlay:119317b9c` built from frozen verified P2 base and *full frozen P3 code tree*. Web HTTP 200, six migrations up, real synthetic API funds 400-100=300 GBP, role revoke 200→404, Sidekiq's two fee jobs processed before and after Worker restart; exit 0. **After P3-only encryption backfill**, the entire stage smoke was rerun and passed again with exit 0.
- Known exclusions: skips/pending docs, real Google OIDC/bank credentials/live payments, public deployment and from-scratch independent Docker build. This review cannot verify P4/P5/P6/P7/P8; no unknown issues are intentionally marked accepted without scope notation.

Formal evidence and log locations: `docs/P3_BACKEND_ACCEPTANCE.md`. Code review is closed **for P3 backend acceptance only**.
