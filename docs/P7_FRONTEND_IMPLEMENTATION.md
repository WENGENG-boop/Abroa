# P7 Frontend implementation — incremental evidence

Status: IN PROGRESS. This is not P7.1 or P7 final acceptance.

## Baseline and isolation

- Branch: abroa/development; base: b4054ea597a06a4a888b6dcf4ce4460f70f522a8.
- P0 existing working-tree changes are excluded.
- Environment: D:\开发\Abroa\.p7-env; private PostgreSQL 17, Redis 7, Selenium Chromium, Rails test container in D-backed WSL.
- Existing parallel frontend repositories were not merged or modified.

## Implemented slice

| Page / action | Implementation | Backend | Evidence |
|---|---|---|---|
| Dashboard project entry | app/views/pages/dashboard.html.erb | authenticated session | Browser pass |
| Project list / cursor pagination | app/views/abroa/projects/index.html.erb | Abroa::StudyProject.for_user, Abroa::Page.fetch | Browser and controller pass; cursor navigation not independently tested |
| Project creation | app/views/abroa/projects/new.html.erb | Abroa::StudyProject.create_for! | Browser and controller pass |
| Project details | app/views/abroa/projects/show.html.erb | Abroa::StudyProject.find_for! | Browser and controller pass |

New session-authenticated Rails controller: app/controllers/abroa/projects_controller.rb.
Uses original domain operations, not a mock or a second financial model. Existing external API authentication is unchanged. Direct API-v1 browser integration and complete project management remain unverified. English and Simplified Chinese translation keys added; independent translation/accessibility/responsive checks remain outstanding.

## Actual verification

Commands run inside the isolated test container:

- bundle exec rails test test/system/transaction_currency_totals_test.rb: 1 test / 1 assertion, exit 0.
- bundle exec rails test test/system/abroa_study_projects_test.rb: initial red 1 test / 0 assertions / 1 error (missing link), exit 1; after implementation 1 test / 3 assertions, exit 0.
- bundle exec rails test test/controllers/abroa/projects_controller_test.rb test/controllers/pages_controller_test.rb: 98 tests / 523 assertions, exit 0.
- bundle exec rubocop app/controllers/abroa/projects_controller.rb config/routes.rb test/controllers/abroa/projects_controller_test.rb test/system/abroa_study_projects_test.rb: 4 files, 0 offenses, exit 0.
- bundle exec erb_lint app/views/abroa/projects app/views/pages/dashboard.html.erb: 4 files, no errors, exit 0.

Passing test runs: zero failures/errors/skips. Source archive lacks .git; version metadata lookup generates non-fatal warnings. Initial schema initialization failed on directory permissions, corrected only in P7 snapshot; rerun passed. Logs: .p7-env/logs/prepare.log, p7-project-red.log, p7-project-green.log, p7-project-integration.log, p7-project-rubocop.log, p7-project-erblint.log. Screenshots: .p7-env/screenshots/.

## Unfinished

Remaining P7.1 modules, separate parent and administrator navigation, modes and onboarding, complete workflows, API integration, all P7.2 gates, independent adversarial review, full regression, full static checks and formal signoff. No VERIFIED claim.
