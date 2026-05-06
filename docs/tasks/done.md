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
