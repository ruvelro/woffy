# Architecture Decisions

## ADR-001: SQLite Local Database For Multi-User State
- Date: 2026-05-06
- Status: Accepted
- Decision: Use `~/.woffy/woffy.db` as the source of truth for users, credentials, tokens, schedules, user cards, events, settings, and run guards.
- Rationale: The product is now operated from a trusted VPS by one administrator. SQLite gives reliable queries and auditability without introducing a server process.
- Consequences:
  - `sqlite3` is a required runtime dependency.
  - Secrets are protected by local filesystem permissions, not by application-level encryption.
  - The old single-user `.woffy.conf`, `.woffy.token`, and `.woffy.user` model is no longer the primary interface.

## ADR-002: One Cron Orchestrator
- Date: 2026-05-06
- Status: Accepted
- Decision: Install one cron entry that runs `woffy run due --quiet` every minute.
- Rationale: Per-user cron entries would grow quickly and make centralized control harder.
- Consequences:
  - Due schedules are evaluated from SQLite.
  - `run_guard` prevents duplicate execution for a worker/action/date/time.
