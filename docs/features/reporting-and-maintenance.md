# Feature: Reporting And Maintenance

## Event Registry
- `Confirmed`: every login, administrative change, sign success, dry-run, warning, and error is stored in SQLite `events`.
- `Confirmed`: web-originated events include a request ID that correlates them with the independent web audit.
- `Confirmed`: `woffy events all` lists recent events for all workers.
- `Confirmed`: `woffy events <email>` lists recent events for one worker.
- `Confirmed`: `woffy events <email> --days 30` and `--days 60` support operational investigation windows.
- `Confirmed`: event filters include `--status all|success|warning|error|dry-run`, `--format text|json|csv`, and `--limit N`.

## Reporting
- `Confirmed`: `woffy report all` aggregates SQLite events.
- `Confirmed`: output formats are `text`, `json`, and `csv`.
- `Confirmed`: optional `telegram` sends the rendered report to the global admin destination.

## Diagnostics
- `Confirmed`: `woffy doctor --json` reports version, binary path, SQLite availability/version, DB path, DB existence, schema version, journal mode, user count, cron state, Telegram state, official Woffu API state, and scheduler tunables (`max_parallel`, `catchup_minutes`).
- `Confirmed`: `woffy config check` initializes and validates the SQLite DB.
- `Confirmed`: `woffy update` runs `woffy doctor` against the newly installed binary as an automatic post-install health check (see below).

## Backup And Restore
- `Confirmed`: backups archive the whole `~/.woffy` directory.
- `Confirmed`: restore extracts the archive and reapplies expected permissions.
- `Confirmed`: v3 backup uses SQLite `.backup`; restore validates archive paths and database integrity before replacement.
- `Confirmed`: events are retained by default and only `events purge --before ... --yes` deletes them.
- `Confirmed`: self-update downloads the new binary onto the same filesystem as the installed one for an atomic `mv`, verifies checksum/syntax, rejects CRLF payloads, confirms the reported version, keeps `.previous`, takes a settings/DB safety backup before replacing the binary, and rolls back to `.previous` automatically if the post-install `woffy doctor` check fails.
- `Confirmed`: the optional panel performs pre-maintenance backups, restore post-check/rollback and detached self-update so service restart cannot kill its updater.
