# Domain Glossary

- `Worker`: an employee managed by email in the local SQLite DB.
- `Admin`: the VPS operator who controls all workers.
- `User card`: cached Woffu metadata for a worker.
- `Schedule`: per-worker action/time/weekday row in SQLite.
- `Run due`: orchestration command that executes schedules due at the current minute.
- `Run guard`: SQLite duplicate-prevention key for worker/action/date/time.
- `Event`: audit row written for login, sign, dry-run, warning, or error outcomes.
- `Event window`: the lookback period used by `woffy events`, commonly 30 or 60 days.
- `Inactive worker`: a worker with `active=0`; retained in DB but skipped by sign flows and `run due`.
- `Telegram admin`: one global Telegram destination for multi-user notifications and reports.
