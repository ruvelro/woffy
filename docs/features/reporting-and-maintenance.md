# Feature: Reporting And Maintenance

## Event Registry
- `Confirmed`: every login, administrative change, sign success, dry-run, warning, and error is stored in SQLite `events`.
- `Confirmed`: `woffy events all` lists recent events for all workers.
- `Confirmed`: `woffy events <email>` lists recent events for one worker.
- `Confirmed`: `woffy events <email> --days 30` and `--days 60` support operational investigation windows.
- `Confirmed`: event filters include `--status all|success|warning|error|dry-run`, `--format text|json|csv`, and `--limit N`.

## Reporting
- `Confirmed`: `woffy report all` aggregates SQLite events.
- `Confirmed`: output formats are `text`, `json`, and `csv`.
- `Confirmed`: optional `telegram` sends the rendered report to the global admin destination.

## Diagnostics
- `Confirmed`: `woffy doctor --json` reports version, binary path, SQLite availability, DB path, DB existence, user count, cron state, and Telegram state.
- `Confirmed`: `woffy config check` initializes and validates the SQLite DB.

## Backup And Restore
- `Confirmed`: backups archive the whole `~/.woffy` directory.
- `Confirmed`: restore extracts the archive and reapplies expected permissions.
- `Confirmed`: v3 backup uses SQLite `.backup`; restore validates archive paths and database integrity before replacement.
- `Confirmed`: events are retained by default and only `events purge --before ... --yes` deletes them.
- `Confirmed`: self-update validates release version, checksum and syntax, keeps `.previous`, and rolls back on failed post-check.
