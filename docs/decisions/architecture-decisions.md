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

## ADR-003: Stateful Catch-Up Scheduler
- Date: 2026-07-21
- Status: Accepted
- Decision: query a bounded catch-up window, parallelize workers, serialize each worker and persist leased attempts in `run_guard`.
- Consequences: transient failures can recover without silently losing slots; external exactly-once still depends on Woffu status reconciliation.

## ADR-004: Official OAuth For Retroactive Signs
- Date: 2026-07-21
- Status: Accepted pending integration validation
- Decision: use CompanyId/API key with OAuth client credentials and Bearer `/api/v1/signs`; do not use Basic auth or undocumented user-token fallback.

## ADR-005: Checksummed Release Updates
- Date: 2026-07-21
- Status: Accepted
- Decision: install and update only from versioned GitHub Release assets after SemVer, SHA-256 and syntax checks, preserving `.previous` for rollback.

## ADR-006: Modular Source, Single-File Distribution
- Date: 2026-07-21
- Status: Accepted
- Decision: maintain canonical Bash modules under `src/` and generate `woffy.sh`; keep single-file runtime distribution.

## ADR-007: Optional Loopback Web Companion
- Date: 2026-07-21
- Status: Accepted
- Decision: deliver FastAPI/Jinja/HTMX as an optional Linux companion, bind only to loopback and use SSH forwarding.
- Rationale: operators need a clearer interface without making the single-file CLI or SQLite state dependent on a permanent public service.
- Consequences:
  - Read models use SQLite read-only connections; all mutations cross the existing CLI validation/lock boundary.
  - Authentication, sessions, jobs and web audit live in a separate protected DB.
  - Destructive operations require CSRF, recent password verification and exact confirmation.

## ADR-008: Offline Checksummed Web Releases
- Date: 2026-07-21
- Status: Accepted
- Decision: publish the app, pinned Linux x86_64 wheelhouse and vendored HTMX as one SHA-256-protected archive.
- Consequences: VPS installation does not contact PyPI/CDNs, CPython 3.11-3.13 is required, and other architectures remain backlog work.
