# Abroa P6.2 — Independent PostgreSQL concurrency and performance validation

Date: 2026-11-26. Baseline P5 Git SHA `a339eff9343c8da94ae88ed6b9c4f23eda60bc59`; P6.1 local Git SHA `421c68e13ed9f547045d166318d27a594e2e4063`. Environment: dedicated D-backed WSL PostgreSQL 17, Redis 7, Minitest fixtures and separate PostgreSQL transaction connections. All evidence under `D:\开发\Abroa\.p6-env\logs`.

## Actual PostgreSQL race tests

| Threat | Independent P6 suite | Result |
|---|---|---|
| Same-entry ledger allocation and duplicate writes | core compatibility + `ledger_concurrency_test.rb` | 12 tests / 91 assertions, 0 fail/error/skip, exit 0 |
| Fund-pool over-reservation; duplicate settlement; debt and study allocation competition | `study_allocation_concurrency_test.rb`, `fund_pool_concurrency_test.rb`, `fee_settlement_concurrency_test.rb`, `debt_concurrency_test.rb` | 8 tests / 31 assertions, 0 fail/error/skip, exit 0 |
| Parent/grant change and repeated proposal execution | parent relationship/overview and `p3_concurrency_test.rb` | 13 tests / 89 assertions, 0 fail/error/skip, exit 0 |
| AI proposal races and malicious model failures | `ai_financial_assistant_test.rb`, `ai_proposal_concurrency_test.rb`, `ai_model_gateway_test.rb` | 37 tests / 216 assertions, 0 fail/error/skip, exit 0 |
| Platform roles/suspension/subscription simulated | `service_entitlements_test.rb`, `platform_users_controller_test.rb`, `platform_operations_controller_test.rb` | 32 tests / 223 assertions, 0 fail/error/skip, exit 0 |
| Inherited Sure merchant PostgreSQL unique-index collision | `test/models/family_merchant_test.rb:155` | Concurrent two-worker full-suite race observation did not synchronize in time (one failure); original test standalone passed 1/4, and complete one-worker Rails suite passed **19,330 / 118,236 / 0 failures / 0 errors / 9 skips**, exit 0, without weakening assertions or timeout |

The above subsets overlap; adding their results is *not* an independent full-suite count. Logs: `p6-core-integration.log`, `p6-finance-concurrency.log`, `p6-parent-integration.log`, `p6-ai-security.log`, `p6-platform-integrated.log`, `p6-family-merchant-race-isolated.log`, `p6-full-regression-serial.log`. Real PostgreSQL connections/locking were used, not a fake in-memory concurrency engine.

## Reproduced query N+1; database and amount invariants preserved

A deterministic P6-only Minitest creates 35 valid, globally limited GBP Entry allocations, measures all noncached SQL notifications and requires 350.0 GBP net consumption and 35 allocated entries. Initially **144 SQL queries**; the new query cap (<=40) failed as intended. After first preload/group-sum repair **42 SQL** still failed; after batching split-child predicates, final result **8 SQL**. New test **1 run / 7 assertions / 0 failures / 0 errors / 0 skips**, exit 0 (`p6-project-summary-query.log`). Post-fix related financial models/controllers/API integration **18 tests / 155 assertions / 0 failures**, exit 0 (`p6-integrated-postfix.log`). Implementation: `app/models/abroa/project_summary.rb` and `app/models/abroa/entry_allocation.rb`. The native entry/currency, global per-entry allocation cap, FX snapshot logic and ledger balance were not relaxed.

## Independent fixed-seed scale benchmark (A17-2), exit 0

Script: `logs/p6_scale_benchmark.rb` with deterministic seed **20261126** on a new PostgreSQL database `abroa_p6_perf_2`. Output: `logs/p6-scale-run.log` (exit 0) and machine-readable `logs/p6-scale-benchmark.json`. All data synthetic; no real people or accounts.

| Measured metric | Actual result |
|---|---:|
| Households/users/accounts | 16 / 16 / 16 |
| Source transactions and Entries | 20,000 / 20,000 |
| Study allocations and monthly budgets | 1,250 / 12 |
| Import headers and inbox notifications | 500 / 1,200 |
| Bulk seed time (not migrations) | 3.492 seconds |
| Project financial summary, 1,250 allocations | 8 SQL queries; 312.88 ms |
| Total summary amount | 27,698.0 GBP, equal to independently aggregated SQL amount |
| Entry list, 100 rows | 2.72 ms |
| Import list, 100 rows | 28.78 ms |
| Inbox list, 100 rows | 9.19 ms |
| Unauthorized other-household account count | 0 |
| Ruby process resident memory | 365,948 kB (approximately 357 MiB) |

`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` on the 1,250-row allocation lookup showed `Bitmap Index Scan` via `index_abroa_entry_allocations_on_project_id` followed by bitmap heap scan and bounded in-memory top-N sort, **0.254 ms execution**, 0.071 ms planning, 27 shared buffer hits, 0 disk reads, no temp spill. Full plan is retained verbatim in JSON evidence; do not misinterpret this SQL plan time as the Rails 312.88-ms summary request time. There was no per-allocation SQL explosion (8 total SQL over 1,250 allocations).

The first synthetic run failed due to a *test fixture generator's SQL quoting error* around recipient UUIDs; the fixture script was corrected, and the second run used a fresh separate DB and exited 0. This was not a product bug. No absolute performance SLO existed in the P0 requirements; these values establish the reproducible P6 observed baseline rather than an invented pass/fail threshold. No unbounded 20,000-entry scan or cross-tenant leak was observed in the exercised queries. Remaining production-like deployment scale and real providers were not tested.

## Independent matching, forecast, budgets and uniqueness extension (exit 0)

A second actual run, `D:\开发\Abroa\.p6-env\run_extended_performance.sh`, executed `logs/p6_extended_performance.rb` against the same **dedicated P6-only seeded performance PostgreSQL database** `abroa_p6_perf_2` and produced `logs/p6-extended-performance.log` and `logs/p6-extended-performance.json`. It asserted exact inputs/outputs rather than type-only responses:

| Tested operation | Data and exact assertion | Real measured time |
|---|---|---:|
| Imported source matching | 500 chosen external IDs matched 500 rows under one account/source | 15.842 ms |
| Aggregate study budgets | 12 monthly budgets summed exactly to **30,000.0 GBP** | 46.148 ms |
| Platform cross-family transaction count | 16 families aggregated exactly **20,000** source Entries | 12.117 ms |
| Real student 180-day projection | `Abroa::Forecast.for_student`, 21 SQL queries, only the authorized GBP cash account, historical 30-day daily spending 185.3667 GBP, day-30 balance 4438.999 GBP, `incomplete=false` | 586.714 ms |
| Duplicate provider/source entry | An actual duplicate SQL INSERT was **rejected by PostgreSQL unique constraint**, transaction rolled back; count remained 20,000 and native amount sum remained **927,928.0** | 12.158 ms |

The forecast model explicitly returns `cache_policy: "no_persistent_cache"`, so persistent forecast cache invalidation is not an applicable P6 operation; fresh projections are recomputed from authoritative ledger. SQL duplicate replay was **actually attempted against the isolated synthetic performance database**, not just inferred from code. The complete 20,000-record native amount fingerprint was unaffected. No fictional SLO threshold is claimed; these are reproducible measured baseline values.
