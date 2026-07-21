# Testing

## Current Automated Coverage
- `Confirmed`: Bats tests exercise real SQLite initialization and permissions.
- `Confirmed`: Woffu calls are mocked through a fake `curl` executable.
- `Confirmed`: cron mutation is tested through a fake `crontab` executable.
- `Confirmed`: tests cover login, token/card persistence, selected-user status, sign events, run-due duplicate guard, aggregate reports, schedule install/list/clear, user enable/disable/delete, per-user schedule editing, event history filtering, doctor JSON, and update branch selection.
- `Confirmed`: v3.1 tests persistent tunables, environment precedence, Telegram stdin, event request correlation and deferred stable/nightly web updates.
- `Confirmed`: FastAPI integration tests cover auth, sessions, CSRF, Host validation, command injection, secret redaction, critical confirmation, read-only SQLite, CSV formulas, API gating, reports, cron, backup and restore.
- `Confirmed`: Playwright drives Chromium through login, navigation and a real allowlisted CLI action.

## CI
- `Confirmed`: GitHub Actions installs `shellcheck`, `shfmt`, `bats`, and `sqlite3`.
- `Confirmed`: `shellcheck` is blocking.
- `Confirmed`: `shfmt -d` is blocking in v3 CI.
- `Confirmed`: Bats is blocking.
- `Confirmed`: pytest, Chromium and offline web artifact installation are blocking in the web CI job.

## Remaining Test Gaps
- `Confirmed`: the suite contains 38 Bats cases, 14 HTTP integration cases, one Chromium E2E case and two VPS-style smoke scripts.
- `Confirmed`: v3 adds migration, atomic schedule, strict date, JSON escaping, fail-closed workday, official OAuth, dry-run, parallel/catch-up/retry, backup/restore and updater rollback coverage.
- `Pending confirmation`: real Woffu Swagger/API contract and Telegram delivery require external integration credentials.
- `Pending confirmation`: crash timing and same-worker serialization benefit from a longer-running stress test in staging.
- `Pending confirmation`: the first real Linux VPS canary must confirm user-service lingering and host-specific systemd hardening.
