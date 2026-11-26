# Abroa P6 — Back-end acceptance trace (A00–A17)

Status: IN_PROGRESS, NOT SIGNED. Date 2026-11-26. Baseline branch abroa/development SHA a339eff9343c8da94ae88ed6b9c4f23eda60bc59. All P6 executable checks use D-backed WSL P6-only Docker PostgreSQL 17, Redis 7 and a detached local source snapshot; evidence root D:\开发\Abroa\.p6-env\logs. Never use historical VERIFIED statuses as P6 evidence.

## Requirement — implementation — P6 independent proof — gap

| ID | Implemented modules/route families | P6 independently executed evidence | Completion state |
|---|---|---|---|
| A00 P0 source/environment | Git baseline, AGENTS, P0 docs, historical P1–P5 receipts | HEAD matched all P5 commits, preexisting P0 working changes preserved, fresh P6 PG17/Redis7 separate volumes | Repository verified; historical P0 signoff not substituted |
| A01 registration/OAuth/onboarding | User, Abroa Profile, authentication and identity/controllers | P6 full Rails inherited auth suite in progress; AI/parent API keys golden | Live Google OAuth not tested |
| A02 FX/regions/wallet | ExchangeRate, Abroa RateSnapshot, wallet and transfers | P6 core compatibility + mixed currency: 12 tests / 91 assertions, exit 0; full suite in progress | Real FX API external not tested |
| A03-1–9 imports, normalized records, bank sync | Sure Import, transaction/entry, provider capture, financial import normalization | P6 ledger concurrency subset pass; full Sure import suite in progress | No live banking or Alipay/WeChat |
| A04 study projects, sharing, allocations | StudyProject, ProjectAccount, EntryAllocation, ProjectSummary | New API end-to-end 1/40; P6 integrated model/controller subset 18/155, both exit 0 | Contract invariants checked |
| A05 budgets/rollover | BudgetNode, BudgetVersion and budget APIs | P6 parent and finance subsets pass; inherited budget suite in full run | Large dataset P6.2 pending |
| A06 pools/goal reserve | FundPool, PoolMovement, AllocationGuard, Goal bridge | New golden pool allocate 200 GBP without touching original entry/account; PG financial concurrency pass | Cross pool-scale P6.2 pending |
| A07 fees/instalment/recurring | FeePlan, FeeInstallment, FeeSettlement, reminder worker | API new golden 120 GBP tuition, 50 GBP idempotent settlement, 70 GBP outstanding | Real SMTP excluded |
| A08 parent collaboration | Relationship, RelationshipInvite, Grant, Proposal, ParentOverview | 13/89 P6 parent subset; new golden parent summary only, foreign project 404, immediate revocation 404 | No real provider inbox |
| A09 allowance/transfers | Remittance, disbursement and genuine Entry match | P6 full Rails inherited P3 allowance tests in progress | External remittance provider not tested |
| A10 receivables/debt | Debt/repayment, partial settlement and callbacks | P6 finance concurrency subset and inherited full P4 tests | Third-party real money excluded |
| A11 forecasting | Cashflow/recurring forecast, projection and anomaly models | P6 full P4 inherited forecast suite in progress | Scale benchmark pending |
| A12 notifications | InboxNotification, EmailOutbox, retry jobs | P6 AI/platform subset plus inherited full suite; P6 Sidekiq recovery pending | SMTP not connected |
| A13 reports/exports | FinancialReport, ReportExport, parent projection, historical rate | Project summary exact 60 GBP new golden; report export permissions reviewed; N+1 144 to 8 SQL | Scale and export recovery pending |
| A14 AI explanation/confirmation | AiModelProvider, AiModelGateway, AI proposals and rate limit | P6 37 tests/216 assertions exit 0; gateway and source/IP pin code reviewed | Real LLM endpoint untested |
| A15.1 platform RBAC/security | Platform user/role/audit/controller | P6 32 tests/223 assertions exit 0; immutable PG trigger source checked | Direct SQL mutation test pending |
| A15.2 entitlements/quotas/billing fixture | Subscription, service entitlements, usage counters | P6 platform subset exit 0, full suite pending | Real billing/webhook not connected |
| A15.3 ops configuration/governance | Operational management/platform API | P6 platform subset exit 0, full suite pending | Production telemetry not connected |
| A16 cloud/selfhost/migration/recovery | Docker Compose, migrations, backup, worker | New PG17/Redis7 healthy and Rails db:prepare plus db:migrate:status exit 0 | Independent P4 upgrade, backup/restore, fault injection pending |
| A17-1 cross-module E2E | All above paths plus inherited Sure API | New API 1 test/40 assertions + grouped 18/155 exact DB invariants, exit 0 | Full 19,330 test zero-failure gate still pending |
| A17-2 scale/performance | allocations, reports, PG indexes, Sidekiq | 35 allocations: measured 144 SQL before, 8 SQL after; 350.0 GBP unchanged, 1/7 passing perf test | Large seeded performance benchmark pending |
| A18 frontend & PWA | Out of scope | Not started | P7 |
| A19 production release | Out of scope | Not started | P8 |

Focused suites listed above overlap; no double-counted combined total. The first complete P6 Rails run executed 19,330 tests, 118,233 assertions, with one failure in the inherited FamilyMerchant concurrency race observation, zero errors, nine skips. The exact same race passed alone with 1 test/4 assertions; a new full low-contention run is in progress, unchanged test assertions. Full green must be independently proven.

Test strategy: external Google, AI, bank, SMTP, payments are exercised only through fixtures/mocks where available and source-reviewed otherwise; this is not real vendor integration. P6 VERIFIED is forbidden until P6.1 and P6.2, all specified lints/security/rswag checks, skip reason audit, archive/persistence comparison, source/Git evidence and final signoff all complete.

## P6.1 fresh independent retest update (2026-11-26)

Following the previously observed inherited merchant-race timing failure, the complete original-and-P6 test suite passed single-worker with **19,330 runs, 118,236 assertions, 0 failures, 0 errors, 9 skips**, exit code 0 (`p6-full-regression-serial.log`), without modifying original test assertions or timeout. Newly added after this run: real new student signup/OAuth/onboarding/project integration 1/29 passing and currency transaction API 1/4 passing, which require inclusion in final post-change full regression. The 9 skipped historical tests have been independently enumerated in `p6-skipped-test-audit.log`; 220-run selective retest in the matching cloud test environment passed 0 failures and 9 skips. P6.1 standalone acceptance evidence is now available, but overall P6 remains IN_PROGRESS pending P6.2 runtime, security and performance gates.
