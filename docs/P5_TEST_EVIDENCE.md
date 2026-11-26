# P5 Test Evidence — 2026-11-26

All figures below refer to actual executed processes and named logs. Unknown/unfinished exit codes are not presumed successful. Existing P4 reference: 19,280 tests / 117,849 assertions / 0 failures / 0 errors / 9 skips.

| Area | Actual executed evidence | Exit/result |
|---|---|---|
| P5.1 platform auth/impersonation/bootstrap | `D:\开发\Abroa\.p5-env\logs\p5auth.log` was reused by subsequent focused runs; complete P5.1 test output was previously observed: 26 tests, 143 assertions, 0 failures, 0 errors. | 0 (focused run) |
| P5.1 Sure auth regression | `logs/p5-1-legacy-auth.log`: 257 tests / 1086 assertions / 0 failures / 0 errors | 0 |
| P5.2 entitlements and billing | `logs/p5-2-focused.log`: 15 tests / 82 assertions / 0 failures / 0 errors | 0 |
| P5.2 concurrent quota | `logs/p5concurrency.log`: 8 tests / 35 assertions / 0 failures / 0 errors | 0 |
| P5.3 operations and governance | `logs/p5-3-focused.log`: 14 tests / 114 assertions / 0 failures / 0 errors | 0 |
| Original Sure token clear regression | `logs/p5auth.log` subsequently recorded 112 tests / 607 assertions / 0 failures / 0 errors | 0 |
| Original Sure release workflow | `logs/p5auth.log` subsequently recorded 12 tests / 399 assertions / 0 failures / 0 errors after installing Git in the D-only test image | 0 |
| Brakeman | `logs/p5-brakeman.log`: 902 models, 847 templates, 0 scanner errors, 0 reported security warnings, 8 prior ignored warnings | 0 |
| rswag/OpenAPI | `logs/p5api.log` was reused; most recent rswag generation was observed as 676 examples / 0 failures / 89 documentation-only pending | 0 |
| API consistency | `ruby test/support/verify_api_endpoint_consistency.rb --compliance`: implementation verified, exit 0; inherited Sure compliance exceptions: financekit OAuth spec, transaction/transfer docs-only assertion violations | 0 |
| Original Monarch CSV regression | `logs/p5-monarch-regression.log`: 25 tests / 51 assertions / 0 failures / 0 errors / 0 skips. Isolated Linux fixture LF correction; original fixture and tests unchanged | 0 |
| Redis/PostgreSQL fault-recovery simulation | `logs/p5-service-fault-verification.jsonl`: induced Redis and PostgreSQL stalls, verified failure during outage, recovered PONG/SQL SELECT 1, persisted ledger count, HTTP 200 | 0 |
| Complete P1–P5 Rails suite | `logs/p5-full-regression.log`: fifth run 19,328 tests / 118,185 assertions / 0 failures / 2 errors caused solely by mixed CSV fixture line endings; sixth full run after correction underway | **PENDING sixth-run completion; fifth NOT accepted** |

The previous failed whole-suite attempts were preserved in D: as `p5-full-initial-environment-failure.log`, `p5-full-second-environment-generation-failure.log`, `p5-full-third-env-empty-token-failure.log`, and `p5-full-fourth-missing-git-failure.log`. These attempts cannot be described as green. Tests or assertions were not removed, skipped or relaxed.

New P5 tests cover anonymous/student/parent/operator/system-user denial; version conflicts; audit irreversibility; forbidden impersonation; immediate session/API-key/OAuth revocation; queued capture and AI response; self-hosted absence of subscription; quota idempotency and concurrency; simulated refunds, callbacks, subscription isolation; real source-based operations; bounded windows, validation, sensitive-field denial and governance transitions.

For exact execution arguments, see scripts `D:\开发\Abroa\.p5-env\run_checks.sh`, `run_next.sh`, `verify_runtime.py`, `verify_schema_load.py`, `verify_synthetic_upgrade.py`, and `verify_legacy_upgrade.py`.
