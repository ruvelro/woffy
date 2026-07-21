# Done

## Completed Tasks

### WFY-AUDIT-001
- Title: Audit existing repository and create operational documentation baseline
- Completed on: 2026-03-14
- Outcome: repo structure, architecture, file map, integrations, setup, testing status, debt, roadmap, and task system documented.

### WFY-020
- Title: Implement SQLite multi-user VPS architecture
- Completed on: 2026-05-06
- Outcome:
  - Added SQLite state model.
  - Added email-scoped login, status, in, out, dry-run, users, user, run due, report all, and schedule commands.
  - Replaced per-user cron entries with one run-due orchestrator.
  - Added multi-user Bats coverage and CI SQLite dependency.

### WFY-012
- Title: Add first-class user activation and schedule editing commands
- Completed on: 2026-05-06
- Outcome:
  - Added `woffy users enable|disable|delete <email>`.
  - Added per-worker schedule commands: `list`, `add`, `set`, `remove`, `clear`, and `defaults`.
  - Added per-worker/global event history with `woffy events`.

### WFY-013
- Title: Expand failure-mode coverage for multi-user Woffu flows
- Completed on: 2026-07-21
- Outcome: added migration, scheduler retry, catch-up, workday outage, official OAuth, backup/restore and updater rollback tests.

### WFY-016
- Title: Reduce shell monolith coupling after SQLite migration
- Completed on: 2026-07-21
- Outcome: canonical `src/` modules now generate the single-file distribution and CI verifies synchronization.

### WFY-014
- Title: Add operator summaries for last run and last error per worker
- Completed on: 2026-07-21
- Outcome: `woffy users` now includes `LAST_RUN` and `LAST_ERROR` timestamps from SQLite events.

### WFY-015
- Title: Document a systemd equivalent for the cron orchestrator
- Completed on: 2026-07-21
- Outcome: setup/ops documents a mutually exclusive `systemd --user` timer equivalent while cron remains primary.

### WFY-021
- Title: Deliver Woffy v3 scheduler, migration, security and official API architecture
- Completed on: 2026-07-21
- Outcome: additive migrations, leased retries, catch-up, bounded concurrency, fail-closed workday and official OAuth implemented.

### WFY-022
- Title: Deliver verified release installer, self-update and VPS rollback simulation
- Completed on: 2026-07-21
- Outcome: checksummed releases, `.previous` rollback, negative updater tests and VPS smoke simulation implemented.
