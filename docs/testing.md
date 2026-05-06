# Testing

## Current Automated Coverage
- `Confirmed`: Bats tests exercise real SQLite initialization and permissions.
- `Confirmed`: Woffu calls are mocked through a fake `curl` executable.
- `Confirmed`: cron mutation is tested through a fake `crontab` executable.
- `Confirmed`: tests cover login, token/card persistence, selected-user status, sign events, run-due duplicate guard, aggregate reports, schedule install/list/clear, user enable/disable/delete, per-user schedule editing, event history filtering, doctor JSON, and update branch selection.

## CI
- `Confirmed`: GitHub Actions installs `shellcheck`, `shfmt`, `bats`, and `sqlite3`.
- `Confirmed`: `shellcheck` is blocking.
- `Confirmed`: `shfmt -d` is still non-blocking.
- `Confirmed`: Bats is blocking.

## Remaining Test Gaps
- Woffu malformed JSON and HTTP failures.
- Token expiry edge cases.
- Telegram settings and delivery filters.
- Backup/restore DB roundtrip.
- More output-format edge cases for JSON/CSV escaping.
