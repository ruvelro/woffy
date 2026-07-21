# Change Log

## 2026-07-21 — v3.1.1
- Fixed a broken release pipeline: a pre-existing empty GitHub Release blocked asset publication for `v3.1.0`, and a follow-up tag was pushed without bumping `VERSION`, leaving no installable release. Republished under `v3.1.1` with `VERSION` synced across `src/00-core.sh`, `web/manifest.json` and `web/woffy_web/__init__.py`.
- Hardened `woffy update`: the downloaded binary is now staged on the same filesystem as the installed one (true atomic `mv`), rejected if it contains CRLF line endings, and preceded by a safety backup of settings/DB via `backup_files` before the binary is replaced. The post-update health check now runs `woffy doctor` (not just a version string match) and auto-restores `woffy.previous` on any failure.

## 2026-07-21 — v3.1.0 development
- Added schema v4 event request correlation and persistent validated runtime settings with environment precedence.
- Added secure Telegram token stdin configuration and deprecated positional token use.
- Added optional loopback-only FastAPI/Jinja/HTMX administration for users, schedules, attendance, events, reports, logs, integrations, configuration and maintenance.
- Added Argon2id authentication, expiring sessions, CSRF, login throttling, critical reauthentication, separate web audit/jobs and read-only main DB access.
- Added offline checksummed Linux x86_64 web artifacts, systemd user service, deferred self-update, health rollback and SSH-tunnel operation.
- Added pytest security/integration coverage, Chromium E2E and VPS-style web install/checksum rollback simulation.

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
