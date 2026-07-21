# Testing

## Current Automated Coverage
- `Confirmed`: Bats tests exercise real SQLite initialization and permissions.
- `Confirmed`: Woffu calls are mocked through a fake `curl` executable.
- `Confirmed`: cron mutation is tested through a fake `crontab` executable.
- `Confirmed`: tests cover login, token/card persistence, selected-user status, sign events, run-due duplicate guard, aggregate reports, schedule install/list/clear, user enable/disable/delete, per-user schedule editing, event history filtering, doctor JSON, and update branch selection.

## CI
- `Confirmed`: GitHub Actions installs `shellcheck`, `shfmt`, `bats`, and `sqlite3`.
- `Confirmed`: `shellcheck` is blocking.
- `Confirmed`: `shfmt -d` is blocking in v3 CI.
- `Confirmed`: Bats is blocking.

## Remaining Test Gaps
- `Confirmed`: the suite contains 34 Bats cases plus a VPS update/rollback smoke test.
- `Confirmed`: v3 adds migration, atomic schedule, strict date, JSON escaping, fail-closed workday, official OAuth, dry-run, parallel/catch-up/retry, backup/restore and updater rollback coverage.
- `Pending confirmation`: real Woffu Swagger/API contract and Telegram delivery require external integration credentials.
- `Pending confirmation`: crash timing and same-worker serialization benefit from a longer-running stress test in staging.
