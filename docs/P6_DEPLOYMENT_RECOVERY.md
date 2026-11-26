# Abroa P6 — Independent deployment, upgrade, backup/restore and fault recovery

Date: 2026-11-26. Branch: abroa/development. Original P5 SHA: `a339eff9343c8da94ae88ed6b9c4f23eda60bc59`; P6.1 SHA: `421c68e13ed9f547045d166318d27a594e2e4063`. All writes/data/logs are in D-backed WSL, `D:\开发\Abroa\.p6-env`; no P1–P5 or production containers/data were modified. PostgreSQL 17, Redis 7, dedicated Compose project `abroa-p6-isolated`, internal-only network, independent Docker volumes. Source snapshot: `/opt/abroa-p6-code`.

## A16 historical upgrades — real execution, exit 0

Independent executable: `D:\开发\Abroa\.p6-env\verify_upgrade.py`, twice, with arguments `sure` and `p4`. Both commands completed exit code **0**, independently restored the historical D: pg_dump fixture, computed row/column hashes and precise financial sums, ran current Abroa migrations, repeated migrations, took a fresh pg_dump, restored into a different PostgreSQL database, confirmed identical original-column hashes and amounts, created a fresh install with schema version checks, rejected invalid DB credentials, and verified the original database stayed unchanged.

| Source fixture | Historic tables verified | Original account balance total | Original Entries total | Verified latest migration | Audit evidence |
|---|---:|---:|---:|---|---|
| Older Sure / early-stage synthetic dump | 12 | 1,099,750.0000 | 7,145.0000 | 20261126130100 | `logs/p6-independent-legacy-upgrade-sure.jsonl` |
| P4 synthetic database dump | 13 | 1,099,750.0000 | 7,145.0000 | 20261126130100 | `logs/p6-independent-legacy-upgrade-p4.jsonl` |

Both comparison scripts independently logged `P6_A16_VERIFIED` (repeat migration, backup restore, fresh install, invalid credential rejection, historical fingerprint preservation all true). Backups `backups/p6-sure-upgraded-20261126.dump`, `backups/p6-p4-upgraded-20261126.dump` have recorded SHA256 hashes and D-only paths; prior dumps were read-only. Separate baseline P6 `rails db:prepare` and `rails db:migrate:status` also exited 0 (logs `p6-db-prepare.log`, `p6-schema-status.log`).

## Actual P6 Web/Worker/Redis/PostgreSQL failure injection — exit 0

Independent runner: `D:\开发\Abroa\.p6-env\verify_runtime.py`; complete structured evidence `logs/p6-runtime-recovery.jsonl`. Two isolated services (Web and Sidekiq Worker) started and passed healthchecks; `GET /up` returned 200. Worker was **stopped** and one real Redis-backed `low_priority` job enqueued (queue=1), then worker restarted and drained (queue=0). Web restarted and a deliberately generated AES-256-GCM sealed synthetic value decrypted using the unchanged secret. Redis pause caused a real read failure (exit=1), unpause recovered `PONG`; PostgreSQL pause caused timed failure (exit=124), unpause recovered `SELECT 1`; after faults `GET /up` returned 200.

Stored Entries fingerprint before and after all faults was **identical**: `5:7145.0000:da465b54d9488c69fd32f84d747b4821`. An artificial nonfinancial platform-audit row was inserted in the isolated test DB; direct PostgreSQL `UPDATE` and `DELETE` each exited **1** with the error `Abroa platform audit is append-only`. The row and its original action/outcome remained identical. Last event: `P6_RUNTIME_A16_VERIFIED` with all verification flags true. Web/Worker were then stopped gracefully after runtime validation to prevent interference with later automated tests; PostgreSQL and Redis remained independent and healthy.

## Boundaries and unverified external work

All upgrade data and credentials were synthetic; Docker passwords and encryption strings were fixture-only. Neither a production deployment nor a production restore was performed. Real mail transport, Google OAuth, bank/Alipay/WeChat APIs, FX feeds, live billing and actual customer finance cannot be inferred from this result; these remain explicitly listed for real provider integration. The self-hosted P6 runtime path was exercised; independent cloud-mode and JS/System lint are separate gates, and must not be inferred from this A16 report.

## Independent cloud-mode runtime, forked Redis arbitration and actual Sidekiq retry

Separate P6 Docker cloud override `compose.cloud.yml` was run via `run_cloud_runtime.sh`: healthy Web/Worker (environment `SELF_HOSTED=false`), actual internal HTTP `/up=200` and unauthenticated `/api/v1/accounts=401`, no exposure of ports to host/public network; Web/Worker stopped after test. **Exit 0**, `logs/p6-cloud-runtime.log`. This complements the P6 self-hosted Web/Worker runtime and tests both product deployment modes in isolation.

Originally optional Sure Redis-atomic-claims cross-process test was explicitly opted in against **disposable Redis database 12** with `DAILY_USAGE_REDIS_TESTS=1`; it forked 8 child processes and asserted atomic once-only event claims and TTL. **1 run / 36 assertions / 0 failures / 0 errors / 0 skips, exit 0** (`logs/p6-redis-atomic-claims.log`). The original default full suite's skip is still honestly documented, but this test was also really executed without skipping.

A *P6-only synthetic* Sidekiq fixture `p6_retry_fixture_job.rb` (never committed to product source) was temporarily copied into the detached P6 test snapshot and run against the real P6 Redis worker. The first execution raised an intentional transient error; **Sidekiq retried and the second execution succeeded**. Redis counted **2 attempts**, completion flag `yes`; the job's fixture Redis keys were deleted, Worker stopped and test fixture removed from P6 snapshot. Script `run_sidekiq_retry.sh`, log `logs/p6-sidekiq-retry-real.log`, **exit 0** (last line `P6_REAL_RETRY_VERIFIED attempts=2 initial_failure=true retry_success=true EXIT=0`). This is not an email/financial external transaction or real SMTP retry; it proves internal job scheduling and recovery under failure.

For every substep above, the only persistent resources are isolated P6 Docker data and logs on D. No accounts, payout or production services were modified.
