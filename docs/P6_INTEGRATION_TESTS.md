# Abroa P6.1 — Integration and ledger acceptance evidence

Date: 2026-11-26. Branch: `abroa/development`; inherited Git SHA `a339eff9343c8da94ae88ed6b9c4f23eda60bc59`. All tests run inside **P6-only**, D-backed WSL Docker PostgreSQL 17 + Redis 7; source snapshot `/opt/abroa-p6-code`; evidence logs `D:\开发\Abroa\.p6-env\logs`. No real bank, payment, Google/AI or SMTP traffic.

## Independently run P6.1 checks

| Test/command (inside P6 Docker test image) | Log (under P6 logs) | Tests / assertions | Exit | Fail / error / skipped |
|---|---|---:|---:|---|
| `rails test test/integration/abroa_core_compatibility_test.rb test/integration/mixed_currency_test.rb test/models/abroa/ledger_concurrency_test.rb` | `p6-core-integration.log` | 12 / 91 | 0 | 0 / 0 / 0 |
| Parent relationship, overview, concurrency model tests | `p6-parent-integration.log` | 13 / 89 | 0 | 0 / 0 / 0 |
| Real PostgreSQL financial concurrency suite | `p6-finance-concurrency.log` | 8 / 31 | 0 | 0 / 0 / 0 |
| AI negative, malicious input, proposal concurrency | `p6-ai-security.log` | 37 / 216 | 0 | 0 / 0 / 0 |
| Platform roles, account operations and rights | `p6-platform-integrated.log` | 32 / 223 | 0 | 0 / 0 / 0 |
| New `test/integration/abroa_p6_cross_module_acceptance_test.rb` | `p6-final-golden.log` | 1 / 40 | 0 | 0 / 0 / 0 |
| Project/API and ledger model regressions after performance change | `p6-integrated-postfix.log` | 18 / 155 | 0 | 0 / 0 / 0 |
| Original Sure generator regression on LF-normalized *test-only* template copy | `p6-final-generator.log` | 31 / 175 | 0 | 0 / 0 / 0 |

Tests are overlapping subsets and **must not be added to claim a distinct complete test total**. Full Rails result is recorded separately in `P6_FINAL_SIGNOFF.md` after its exit and skip audit.

## Newly added real HTTP + database golden scenario

Source: `test/integration/abroa_p6_cross_module_acceptance_test.rb`. Creates separate student and parent API credentials, an actual Sure GBP account and original `Entry` (100.0000 GBP), projects London and Oxford, and then exercises application API routes with per-operation idempotency keys. Student attaches an account to both projects, allocates 60 GBP + 30 GBP, receives HTTP 422 for 20 GBP over-allocation, creates a 200 GBP pool reservation without ledger posting, creates 120 GBP tuition with an installment and a 50 GBP settlement, retries identical idempotency key without duplicate settlement, and checks 70 GBP due. Project report of 60 GBP must be exact; global budget allocation cannot exceed the 100 GBP original entry. A parent invited to the student relationship receives a summary-only grant for the London project; account name/id must be absent, the Oxford summary is not found, revoking the grant immediately changes London's summary response to 404, and inherited Sure `/api/v1/transactions` does not leak the original entry. Original `Entry.count`, original amount and account balance remain unchanged after the entire workflow. All 40 assertions passed.

This is a consolidated API golden path, **not** an assertion that every import provider, onboarding, FX conversion or external OAuth pathway was executed together; those are separately traced to earlier behavioral suites plus independent P6 focused suites. Unconfigured external integrations were simulated or code-reviewed, not connected to real providers.

## Model, API and schema cross-check

`app/models/abroa/entry_allocation.rb`, `project_summary.rb`, `fee_settlement.rb`, `relationship.rb`, `grant.rb`, `fund_pool.rb` were examined against actual Minitest and PostgreSQL constraints. Source of truth is the persisted Sure `Entry`, not a synthetic project ledger. Project allocations have global same-entry total constraints; idempotency/unique indexes protect repeated API writes. PG17 `rails db:prepare` completed exit 0; `rails db:migrate:status` shows the 2026-11-26 P5 migrations UP (P6 log `p6-schema-status.log`). API consistency checker and rswag were executed independently; former reports an intentional publisher Bearer header in `financekit_spec.rb` despite API client auth being API-key-only, discussed in security audit.

## Open external matters

Real Google OAuth, Alipay/WeChat/bank connections, remote model, SMTP, live payment provider, and production scaling are not verified by these fixture tests. No production data was used. Do not mark P6 VERIFIED until P6.2 performance, recovery, complete fresh Rails regression and all required checks are complete.

## Additional independently executed P6.1 proof (2026-11-26)

The genuinely new-user HTTP flow in `test/integration/abroa_p6_new_user_onboarding_test.rb` passed 1 test / 29 assertions / 0 failures / 0 errors / 0 skips, exit 0, P6 log `p6-onboarding-new-user.log`. This registers a fresh email, obtains an OAuth access/refresh token, independently logs in again, changes student/region/currency preferences, advances and idempotently completes onboarding, creates the first GBP study project, and verifies that a valid API credential from a separate household receives 404. Database rows and family ownership are checked.

The imported EUR-dividend response originally asserted in rswag now has a dedicated Minitest assertion in `test/controllers/api/v1/transactions_controller_test.rb`, executed as 1 test / 4 exact assertions / 0 failures / 0 errors / 0 skips, exit 0 (`p6-dividend-exchange-api.log`): exchange rate 1.08, original EUR, preserved native -12.40 amount. Transfer fee defaults and currencies were already asserted by the original Minitest in `test/controllers/api/v1/transfers_controller_test.rb`. Rswag examples remain documentation-only; the removed rswag-level `expect` statements were not removed without equivalent behavioral assertions.

Complete single-worker Rails regression after P6 golden and query optimization (but before the subsequently added new-user and EUR-dividend test files): **19,330 tests / 118,236 assertions / 0 failures / 0 errors / 9 skips**, exit 0, elapsed 1421.103531 seconds (`p6-full-regression-serial.log`). This is not a claim that tests added afterward were included in that exact run; each later new test was separately executed as above and must be included in final full run.

API endpoint consistency checker exit 0 (`p6-api-consistency.log`). FinanceKit uses genuine OAuth and API-key authentication through Api::V1::BaseController; both are correctly documented. The compliance scanner's broad `rswag using OAuth` warning is a static heuristic, **not** a reason to remove a real authorization mechanism. Rswag generation rerun: 676 examples / 0 failures / 89 documentation-only pending, exit 0 (`p6-rswag.log`).
