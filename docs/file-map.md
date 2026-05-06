# File Map

## Root
- `woffy.sh`: main Bash application, SQLite schema, Woffu API access, scheduling, reporting, Telegram, and maintenance commands.
- `install-woffy.sh`: user-mode installer that downloads `woffy.sh`, optionally logs in the first worker, clears old cron entries, and installs the central orchestrator.
- `README.md`: user-facing multi-user usage summary.
- `CHECKLIST.md`: release checklist.

## CI
- `.github/workflows/shell-ci.yml`: Ubuntu CI for `shellcheck`, non-blocking `shfmt`, Bats, and SQLite tooling.

## Tests
- `tests/woffy.bats`: Bats suite using real `sqlite3` plus mocked `curl` and `crontab`; covers user admin, schedule editing, and event history.

## Docs
- `docs/architecture.md`: current SQLite architecture.
- `docs/data-flow.md`: login, sign, run-due, report, backup, and restore flows.
- `docs/integrations.md`: Woffu, Telegram, SQLite, GitHub, and local tools.
- `docs/tasks/`: backlog, in-progress, and done task queues.
- `docs/decisions/architecture-decisions.md`: accepted SQLite and cron-orchestrator decisions.
