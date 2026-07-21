# Feature: Optional Web Panel

## Access And Security
- `Confirmed`: Woffy Web listens only on loopback and is intended for an SSH tunnel.
- `Confirmed`: one administrator authenticates with an Argon2id hash; sessions expire and password rotation invalidates all sessions.
- `Confirmed`: Host validation, CSP, CSRF and login throttling are enabled; every critical action requires exact confirmation and password revalidation.
- `Confirmed`: secrets use stdin and are excluded from argv, pages and audit detail.

## Operational Parity
- `Confirmed`: the panel covers users, Woffu state, schedules and seven-day preview, manual/dry-run/backdated signs, run-due and cron controls.
- `Confirmed`: events, guards, reports, CSV export, live Woffy logs, Telegram/API configuration and persistent runtime settings are available.
- `Confirmed`: backdated signs stay disabled until the API integration test succeeds.

## Maintenance And Delivery
- `Confirmed`: backup, restore with fallback, doctor, self-test, changelog, stable/nightly update, downgrade and uninstall are represented.
- `Confirmed`: SQLite reads are read-only and every mutation is an allowlisted `shell=False` CLI subprocess with a correlation ID.
- `Confirmed`: the first release artifact supports Linux x86_64/CPython 3.11-3.13, includes offline wheels and vendored HTMX, and is verified by SHA-256.
- `Confirmed`: the CLI remains independent when the panel is absent or stopped.
