# Abroa P5 — formal backend acceptance

Date: 2026-11-26; branch: abroa/development. All development/test artifacts were confined to D: and its D-backed WSL distro.

Baseline P1–P4: 1f6dee513d0c0c1934b7e289f089ade1016492c4.
P5.1 commit a082b05d4; P5.2 ba220b8e9; P5.3 0716d1b6f; P5.4 6f8fc5f19.

**VERIFIED for P5.1–P5.4 backend scope only.** P6–P8 are not included.

Complete P1–P5 Rails regression: **19,328 tests, 118,189 assertions, 0 failures, 0 errors, 9 historical skips; exit 0**. Early attempts with environment defects were archived and not counted as passing.

P5.1: platform RBAC and immutable audit, suspension/revocation, impersonation protection; focused 26/143 and inherited auth 257/1086 passed.
P5.2: non-gated finance core, optional entitlements, quotas, subscriptions and simulated billing; focused 15/82 and concurrent PG quota 8/35 passed. No real payments or synthetic prices.
P5.3: real-source operational metrics, typed configuration and governance controls; focused 14/114 passed, no actual account deletion.
P5.4: selfhost/cloud Docker Compose config passes, isolated Web/Worker/PG17/Redis7 run, protected 401 and synthetic job execution, worker/Web restart, deterministic encryption fixture, preexisting-column checks and backups for old Sure P2 and Abroa P4, fresh schema installation and append-only audit SQL trigger, deliberate wrong-credential path, Redis/PG fault injection and recovery. Final rebuilt Docker image and running Web/Worker BUILD_COMMIT_SHA=6f8fc5f19; runtime HTTP200, DB migration 20261126130100.
Security: Brakeman scanned 902 models and 847 templates, zero reported security warnings/errors, 8 inherited ignored and one stale ignore entry. P5 RuboCop 0 offenses. rswag 676 examples / 0 failures / 89 documentation-only pending; API consistency checker exits 0. The 9 skipped Rails cases and 89 documentation-only pending examples were not executed and are not described as passing tests.

No live payments, banking/AI providers, SMTP, production account, production database or real deployment was touched. Therefore real external E2E and production-readiness checks are NOT claimed. P6 all-backend consolidation, P7 frontend and P8 release stay separate.

Evidence logs on D:\开发\Abroa\.p5-env\logs:
p5-full-regression.log; p5-final-evidence-gate.json; p5-final-image-runtime-verification.jsonl; p5-service-fault-verification.jsonl; p5-compose-modes-verification.jsonl; p5-runtime-verification.jsonl; p5-synthetic-upgrade-b.log; p5-sure-legacy-upgrade.log; p5-fresh-schema-verification.jsonl; p5-brakeman.log.

Details: docs/P5_BACKEND_ACCEPTANCE.md, docs/P5_TEST_EVIDENCE.md, docs/P5_SECURITY_REVIEW.md, docs/P5_DEPLOYMENT_VERIFICATION.md, docs/P5_DEFECTS_AND_FIXES.md.
Unrelated P0 matrix row/user files are intentionally excluded from the final P5 Git commit.
