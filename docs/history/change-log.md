# Change Log

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
