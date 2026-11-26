# Abroa P5 Backend Acceptance — evidence-based checkpoint

Date: 2026-11-26. Baseline: `1f6dee513d0c0c1934b7e289f089ade1016492c4`. Branch: `abroa/development`. All test infrastructure is in D: via the `Abroa-P1-Test` WSL distro and isolated PostgreSQL 17 / Redis 7 containers.

**Formal P5 sign-off: VERIFIED for the P5.1–P5.4 backend-only scope.** Complete Rails regression: 19,328 tests / 118,189 assertions / 0 failures / 0 errors / 9 historical skips. No P6, P7, P8 or live production/external integrations are included.

| Phase | Code commit | Evidence obtained | Formal state |
|---|---|---|---|
| P5.1 A15-1 | `a082b05d4` | 26 tests / 143 assertions / 0 failures / 0 errors for platform RBAC, denied audit, impersonation and bootstrap; 257/1086 historic auth regression passed earlier | VERIFIED |
| P5.2 A15-2/3 | `ba220b8e9` | 15/82 commercial suite plus 8/35 concurrency suite, all green. Four concurrent spend requests for a quota of two yielded exactly two accepted and two rejected. | VERIFIED |
| P5.3 A15 | `0716d1b6f` | 14 tests / 114 assertions / 0 failures / 0 errors. Real aggregate sources and bounded metadata confirmed. | VERIFIED |
| P5.4 A16-1/2 | `6f8fc5f19` | Isolated production candidate HTTP/Worker/DB/Redis, P4 and P2-era migrations, historical fingerprints, backup and restore and new schema load passed; Redis/PostgreSQL outage and recovery both passed; final P5.4 image SHA 6f8fc5f19 recreated and Web/Worker health verified; complete regression 19328/118189/0/0/9 | VERIFIED |

Financial core remains unrestricted by official plans in self-hosted mode. Cloud plans may gate only explicitly listed operational add-ons. Price and cost unknowns remain `null`, never synthesized as zero. No payment processor or live bank/model credential was used.

No P7 frontend work, P6 combined sign-off or P8 production deployment is included in P5.

## Evidence references

- `docs/P5_TEST_EVIDENCE.md`
- `docs/P5_SECURITY_REVIEW.md`
- `docs/P5_DEPLOYMENT_VERIFICATION.md`
- `docs/P5_DEFECTS_AND_FIXES.md`
- D: isolated runtime evidence under `D:\开发\Abroa\.p5-env\logs\`

**Sign-off evidence:** final source commit 6f8fc5f19; complete Rails 19328/118189/0/0/9; P5 focused/concurrency tests; Brakeman zero reported warnings, 8 previously ignored; RuboCop zero offenses; rswag 676 examples/0 failures/89 documentation-only pending; Sure/P4 migration and backup/restore invariants, isolated PostgreSQL/Redis recovery and new-image Web/Worker verification. Real provider credentials and production deployments were excluded by design.
