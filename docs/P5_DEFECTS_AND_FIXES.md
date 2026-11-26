# P5 defect register and repair evidence

All defects below were observed during real implementation or validation. Original Sure/P1–P4 problems are recorded separately from newly introduced P5 behavior. Unverified actions must not be described as a repair.

| ID | Category | Observed failure / impact | Repair and evidence |
|---|---|---|---|
| P5-01 | P5 model | Namespaced role/audit models inferred wrong table names; 6 initial Minitest errors | Declared explicit `self.table_name`; P5.1 tests green |
| P5-02 | P5 security | Ruby schema restore lost PostgreSQL append-only audit trigger | Added SQL trigger migration and safe schema-load repair hook; direct SQL tampering tests green |
| P5-03 | P5 auth | Sure impersonation could bypass tenant privacy if combined with a platform role | Prohibit platform roles from impersonation and terminate already active impersonation; negative tests green |
| P5-04 | P5 audit | Rails before_action halt skipped after_action rejected-access audit | Record denial/conflict from the actual rejection path; audit-only negative test green |
| P5-05 | P5 authorization | Existing queued provider/AI/email work needed execution-time account suspension check | Added guards before financial/AI access; replay tests green |
| P5-06 | P5 operations | Secret-shaped string allowed in operational display metadata | Tightened allowlist and secret-like prefix rejection; 14/114 operations test suite green |
| P5-07 | P5 deploy | Source `db/schema.rb` contained only first P5 migration and omitted P5.2–P5.3 tables | Replaced with complete migrated schema; clean `db:schema:load` and repeat migrations verified |
| ENV-01 | isolated testing only | Sure AI key clear test returned empty string rather than nil because Docker explicitly injected `OPENAI_ACCESS_TOKEN=""` | Removed empty override in D-only test Compose; original 112/607 tests passed |
| ENV-02 | isolated testing only | Native test runner image lacked Node.js for original workflow tests | Built D-only test runtime with Node 20; original source/test assertions untouched |
| ENV-03 | isolated testing only | Original Sure release tests failed `Errno::ENOENT - git` in slim runtime | Built D-only test image with Git 2.47; full release workflow suite 12/399 passed |
| ENV-04 | isolated testing only | Windows CRLF in source generator templates broke exact textual comparison | Normalize LF solely in D-only Linux test worktree, not the canonical source or test assertions |
| ENV-05 | isolated test network only | Docker bridge with `internal: true` blocked host loopback port for candidate smoke test | Dual-homed only the isolated test Web with localhost-published edge network; `/up` 200 |
| ENV-06 | isolated testing only | Windows checkout retained CRLF in original Monarch CSV fixtures; two legacy tests append LF records, giving a mixed-line-ending CSV parse error | Added CSV LF normalization only in D-backed isolated Linux test worktree; unchanged original Monarch suite 25 tests / 51 assertions / 0 errors |
| ENV-07 | isolated testing only | Test image Git marked the isolated root-owned copied repository as dubious ownership | Set container-only `GIT_CONFIG_COUNT/KEY_0/VALUE_0` safe.directory `/rails`; no repository trust setting changed on the user's host |
| DOC-01 | API docs | New rswag specs initially lacked common API-key authentication declarations | Added API key pattern and preserved explicit anonymous 401 tests; rswag generation 676/0/89 pending |
| ACCEPT-01 | pending final | Fifth complete Rails run executed 19,328 tests / 118,185 assertions / 0 failures / 2 errors, both Monarch CSV line endings | Original tests unchanged; fixed isolated fixture normalization, Monarch suite 25/51 all green; sixth full suite running, not yet claimed VERIFIED |

Historical non-P5 issues: API consistency checker reports inherited FinanceKit OAuth usage and transaction/transfer request-spec assertions; Brakeman reports 8 previously ignored warnings and one stale ignore hash. These were not modified to make P5 appear green.

No pending item may be hidden, and no full sign-off should occur before all mandatory checks pass.
