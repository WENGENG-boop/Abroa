# Abroa P5 Backend Acceptance — evidence-based checkpoint

Date: 2026-11-26. Baseline: `1f6dee513d0c0c1934b7e289f089ade1016492c4`. Branch: `abroa/development`. All test infrastructure is in D: via the `Abroa-P1-Test` WSL distro and isolated PostgreSQL 17 / Redis 7 containers.

**Formal P5 sign-off: IN_PROGRESS.** Never interpret focused tests or a successful migration as full P5 verification. The mandatory final Rails regression must complete successfully and P5.4 fault recovery must be reconciled before changing this state.

| Phase | Code commit | Evidence obtained | Formal state |
|---|---|---|---|
| P5.1 A15-1 | `a082b05d4` | 26 tests / 143 assertions / 0 failures / 0 errors for platform RBAC, denied audit, impersonation and bootstrap; 257/1086 historic auth regression passed earlier | IN_PROGRESS, full regression pending |
| P5.2 A15-2/3 | `ba220b8e9` | 15/82 commercial suite plus 8/35 concurrency suite, all green. Four concurrent spend requests for a quota of two yielded exactly two accepted and two rejected. | IN_PROGRESS, full regression pending |
| P5.3 A15 | `0716d1b6f` | 14 tests / 114 assertions / 0 failures / 0 errors. Real aggregate sources and bounded metadata confirmed. | IN_PROGRESS, full regression pending |
| P5.4 A16-1/2 | pending | Isolated production candidate HTTP/Worker/DB/Redis, P4 and P2-era migrations, historical fingerprints, backup and restore and new schema load passed; Redis/PostgreSQL outage and recovery both passed; final image rebuild and complete regression pending | IN_PROGRESS |

Financial core remains unrestricted by official plans in self-hosted mode. Cloud plans may gate only explicitly listed operational add-ons. Price and cost unknowns remain `null`, never synthesized as zero. No payment processor or live bank/model credential was used.

No P7 frontend work, P6 combined sign-off or P8 production deployment is included in P5.

## Evidence references

- `docs/P5_TEST_EVIDENCE.md`
- `docs/P5_SECURITY_REVIEW.md`
- `docs/P5_DEPLOYMENT_VERIFICATION.md`
- `docs/P5_DEFECTS_AND_FIXES.md`
- D: isolated runtime evidence under `D:\开发\Abroa\.p5-env\logs\`

**Do not mark this file VERIFIED until exact final HEAD, exit codes, restored data invariants, Brakeman, RuboCop, rswag and complete Rails counts have been rechecked.**
