# Change Log

## 2026-07-21 — v3.0.0 development
- Rollback base: `b4a12a3f1c640bcff90aefde399534b48e12f59f` (`main` before v3).
- Snapshot commit: `faeb74bf4c856a1f7aa2cc1105299a135a9443ab` on `codex/v3-massive-update`.
- Added additive schema v3 migrations, WAL/FK connections and consistent backup/restore.
- Added catch-up scheduling, per-worker serialization, bounded parallelism, leases and persistent retries.
- Added fail-closed workday checks and secure credential input.
- Added official OAuth client-credentials integration and retroactive signs.
- Added checksummed stable/nightly release update with rollback and VPS smoke simulation.
- Added modular sources, blocking formatting checks and Ubuntu/macOS test matrix.

## 2026-05-06
- Implemented v2.0.0 multi-user SQLite architecture.
- Added user administration commands for enable, disable, and delete.
- Added per-user schedule editing commands.
- Added event history queries for all users or one worker, with days/status/format/limit filters.
- Added `~/.woffy/woffy.db` as the source of truth for users, credentials, tokens, user cards, schedules, events, settings, and run guards.
- Added email-scoped commands: `login`, `status`, `in`, `out`, `dry-run`, `user`, and `users`.
- Added central scheduler command `woffy run due` and cron installer `woffy schedule install`.
- Added `woffy report all` based on SQLite events.
- Updated CI to install `sqlite3`.

## 2026-03-14
- Created repo-local `AGENTS.md`.
- Created `/docs` operational baseline for architecture, flows, files, functions, integrations, setup, testing, debt, roadmap, and tasks.
